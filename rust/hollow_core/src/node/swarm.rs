use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

pub(crate) const MLS_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(60);

/// How long undecryptable frames have to keep arriving before the ladder calls
/// the group broken. Below this it is a BURST (a relay catch-up replay on
/// rejoin), which is one event and not evidence of a broken group.
pub(crate) const MLS_DECRYPT_FAIL_WINDOW: Duration = Duration::from_secs(3);

/// How long the decrypt-fail ladder holds off after an epoch probe went out.
/// A commit catch-up is one round trip and costs no epoch churn; the ladder's
/// remove + re-add costs two epochs and rekeys everyone, so the probe gets first
/// refusal. Short enough that a probe nobody answers barely delays the heal.
pub(crate) const EPOCH_PROBE_GRACE: Duration = Duration::from_secs(5);

/// How long a served `ServerJoinRequest` is remembered, so a REPEAT ask from the
/// same joiner is recognised as the joiner's 4s retry and bypasses the
/// coordinator gate. Comfortably longer than that retry and shorter than the
/// 15s join timeout, so one pending join produces at most one escalation.
pub(crate) const JOIN_SERVE_RETRY_WINDOW: Duration = Duration::from_secs(12);

/// How long an in-flight Olm KeyRequest is considered "live" before the
/// session-reconciliation sweep is allowed to resend it. The relay never ACKs a
/// direct message, so a dropped KeyRequest/KeyBundle would otherwise strand the
/// in-flight flag forever (recoverable only by a full relay reconnect). Mirrors
/// MLS_BOOTSTRAP_TIMEOUT — same timestamped-retry idiom.
const OLM_KEY_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Returns true if we have a KeyRequest in flight to `peer` that is still fresh
/// (sent within OLM_KEY_REQUEST_TIMEOUT). A stale or absent entry returns false,
/// allowing a resend. `key_request_in_flight` maps peer_id -> when the request
/// was sent.
fn key_request_is_fresh(
    key_request_in_flight: &HashMap<String, std::time::Instant>,
    peer: &str,
) -> bool {
    key_request_in_flight
        .get(peer)
        .is_some_and(|t| t.elapsed() < OLM_KEY_REQUEST_TIMEOUT)
}

/// True for the media-forwarder control-plane rooms (`fwd:{forwarder_id}`).
///
/// These rooms exist ONLY to carry Olm-encrypted `fwd_*` envelopes between a
/// client and a forwarder engine. A forwarder is not a social peer: it holds no
/// group keys, is in no server, shares no DMs, and DISCARDS every discovery
/// frame we could send it. Presence in one must therefore not trigger the
/// normal peer-discovery cascade — see [`ensure_olm_session_and_drain`].
pub(crate) fn is_forwarder_room(room: &str) -> bool {
    room.starts_with("fwd:")
}

/// True when EVERY room we currently share with `peer` is a forwarder
/// control-plane room — i.e. this peer is a media forwarder to us, not a social
/// peer. Structural (no configured-id lookup), so it holds for peer forwarders
/// as well as the VPS one.
///
/// False when we share any ordinary room (a friend who is ALSO watching through
/// our embedded engine shares their DM room, so they keep every social path),
/// and false when we share no room at all — "unknown" must never be treated as
/// "forwarder".
fn peer_is_forwarder_only(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer: &str,
) -> bool {
    let mut shares_a_room = false;
    for (room, peers) in ws_room_peers.iter() {
        if peers.contains(peer) {
            if !is_forwarder_room(room) {
                return false;
            }
            shares_a_room = true;
        }
    }
    shares_a_room
}

/// The ONE piece of the peer-discovery cascade the forwarder lane genuinely
/// needs: an Olm session, plus the drain of anything queued while we had none.
///
/// Returns true when a confirmed session already existed (so the caller can run
/// the discovery work that belongs after it — the full path also flushes
/// pending sync requests there; the fwd lane must not).
///
/// Load-bearing for the fwd lane: `forwarder_client::send_fwd_envelope_via_room`
/// QUEUES into `pending_messages` and fires a KeyRequest when no session exists,
/// so this drain is exactly what delivers the first `fwd_stream_register` of a
/// share. Cutting it would wedge the lane.
#[allow(clippy::too_many_arguments)]
async fn ensure_olm_session_and_drain(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id: &str,
    context: &str,
) -> bool {
    // Proactive key exchange if no CONFIRMED Olm session. An outbound-only
    // session is NOT proof the peer can decrypt us — only a confirmed
    // (bidirectional) session is. Reporting SessionEstablished for an
    // unconfirmed session is the bug where "A writes and B doesn't see it"
    // (B never built its half).
    if olm.has_confirmed_session(peer_id) {
        let _ = event_tx
            .send(NetworkEvent::SessionEstablished {
                peer_id: peer_id.to_string(),
            })
            .await;
        // Drain any pending messages queued while the peer was offline.
        if let Some(queued) = pending_messages.remove(peer_id) {
            hollow_log!(
                "[HOLLOW-CRYPTO] {context}: draining {} pending messages for {peer_id}",
                queued.len()
            );
            for text in queued {
                send_encrypted_message(
                    olm,
                    crypto_store,
                    peer_id,
                    &text,
                    event_tx,
                    ws_cmd_tx,
                    ws_room_peers,
                )
                .await;
            }
        }
        true
    } else if !key_request_is_fresh(key_request_in_flight, peer_id) {
        // No session, or only an unconfirmed outbound session — send (or
        // resend, if the prior request went stale) a KeyRequest. The
        // reconciliation sweep retries if this frame is dropped.
        hollow_log!("[HOLLOW-WS] Proactive key exchange for {peer_id}");
        send_message_to_peer(
            ws_cmd_tx,
            ws_room_peers,
            peer_id,
            signed_key_request(device_keypair, device_peer_id, peer_id),
        );
        key_request_in_flight.insert(peer_id.to_string(), std::time::Instant::now());
        false
    } else {
        false
    }
}

/// Run the full sibling-convergence machinery for a peer we have CRYPTOGRAPHICALLY
/// PROVEN is our own other device (it appeared in `inbox:{our_master}` AND either
/// already resolves to us OR answered a [`HavenMessage::SiblingProveRequest`] with a
/// valid master-signed proof). This was previously inline in the `PeerJoined` handler,
/// gated only on bare inbox-room membership — which a friend-request sender (a
/// stranger) satisfies, causing a mis-merge. It is now called ONLY behind a
/// same-identity / verified-proof gate, from both the `PeerJoined` and `RoomMembers`
/// inbox paths and the `SiblingProveResponse` dispatch arm.
///
/// Seeds the resolver, unions the sibling into our master-signed device list, pushes
/// our profile/friends to it and pulls theirs, requests a DM backfill, re-announces
/// our servers, and (if WE are an empty device) auto-requests a full snapshot. Sync —
/// none of these calls await.
#[allow(clippy::too_many_arguments)]
fn on_verified_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    local_peer_str: &str,
    server_states: &HashMap<String, ServerState>,
    link_snapshot_requested: &mut std::collections::HashSet<String>,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
    peer_id: &str,
) {
    let own_inbox = format!("inbox:{}", local_peer_str);
    // The joining device belongs to our master identity.
    super::resolver::update(peer_id, local_peer_str);

    // CRITICAL (presence collapse): the verified proof tells us `peer_id` is OUR
    // sibling device. Merge it into our own master-signed device list RIGHT HERE — do
    // not wait for a ProfileUpdate carrying a device_list (a freshly-imported sibling
    // has no profile, so it never sends one, and our list would stay 1 device forever
    // → a friend like AL only ever learns ONE of our devices and shows us offline when
    // that one quits). Union + re-sign + persist, then re-announce our profile (now
    // carrying BOTH devices) to every friend we share a room with so they converge
    // immediately.
    let our_set_grew = super::crypto_handler::merge_sibling_device_id(
        master_keypair, device_peer_id, peer_id,
        db_path, db_passphrase,
    );
    if our_set_grew {
        let peers: Vec<String> = ws_room_peers.values()
            .flat_map(|p| p.iter().cloned())
            .collect();
        hollow_log!(
            "[HOLLOW-DEVICES] Inbox sibling {peer_id} merged — re-announcing to {} room peer(s)",
            peers.len()
        );
        for pid in peers {
            if pid == local_peer_str || pid == device_peer_id { continue; }
            if super::resolver::same_identity(&pid, local_peer_str) { continue; }
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers,
                local_peer_str, master_keypair, device_peer_id, &pid,
                is_invisible,
                db_path, db_passphrase,
            );
        }
    }
    // Also hand the sibling our device list directly (via a ProfileUpdate) so IT
    // converges on the union too — covers the case where the sibling is the one with a
    // profile and we are the fresh device.
    social::send_own_profile_to_peer(
        ws_cmd_tx, ws_room_peers,
        local_peer_str, master_keypair, device_peer_id, peer_id,
        is_invisible,
        db_path, db_passphrase,
    );

    // SIBLING PROFILE SYNC: a freshly-imported device holds the master KEY but none of
    // the master's profile CONTENT (name/avatar). If our OWN identity profile is
    // empty/absent, pull it from the sibling — the incoming ProfileUpdate resolves to
    // our master (== local_peer_str), so save_incoming_profile adopts it as our own.
    // Without this the substitute device shows the identity online but nameless.
    let need_profile = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|s| s.load_profile(local_peer_str).ok().flatten())
        .map(|p| p.display_name.trim().is_empty())
        .unwrap_or(true);
    if need_profile {
        hollow_log!(
            "[HOLLOW-MULTIDEV] Own profile empty — requesting it from sibling {peer_id}"
        );
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            peer_id, HavenMessage::ProfileRequest,
        );
    }

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        if let Ok(friends) = store.load_friends(Some("accepted")) {
            if !friends.is_empty() {
                let entries: Vec<FriendListEntry> = friends
                    .into_iter()
                    .map(|(pid, status, direction, requested_at, _updated)| FriendListEntry {
                        peer_id: pid,
                        status,
                        direction,
                        requested_at,
                    })
                    .collect();
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Sibling device {peer_id} verified — sharing {} friends",
                    entries.len()
                );
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    peer_id, HavenMessage::FriendListSync { friends: entries },
                );
            }
        }
    }
    // Pull theirs too (in case WE are the empty device).
    hollow_log!(
        "[HOLLOW-MULTIDEV] Sibling {peer_id} verified — requesting their friend list"
    );
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers,
        peer_id, HavenMessage::FriendListRequest,
    );

    // Multi-device backfill (Step 5): ask the sibling for the FULL DM history across
    // all conversations, both directions, since our per-conversation high-water mark.
    super::crypto_handler::request_sibling_dm_backfill(
        ws_cmd_tx, ws_room_peers, peer_id,
        db_path, db_passphrase,
    );

    // Multi-device (Step 9D follow-up): RE-ANNOUNCE every non-deleted server we belong
    // to, to this freshly-verified sibling (idempotent on the receiver).
    // MEMBERSHIP filter, not just the tombstone: a shell retained after our own
    // LEAVE (legacy pre-teardown DBs) must never be re-announced — the announce
    // handler runs an unconditional join and the sibling fast-path would re-ADD
    // our identity to a server we left (authored by a non-member → real members
    // reject the op → the actor's devices fork from the server).
    for (sid, st) in server_states.iter() {
        if st.is_deleted() || !st.is_member(local_peer_str) { continue; }
        let announce = serde_json::to_vec(
            &HavenMessage::SiblingServerAnnounce { server_id: sid.clone() },
        ).unwrap_or_default();
        if !announce.is_empty() {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: own_inbox.clone(),
                target_peer: peer_id.to_string(),
                data: announce,
            });
        }
    }
    hollow_log!(
        "[HOLLOW-CRDT] Re-announced {} server(s) to verified sibling {peer_id}",
        server_states.values()
            .filter(|s| !s.is_deleted() && s.is_member(local_peer_str))
            .count()
    );

    // Multi-device link (Step 4): if WE are essentially empty (a fresh mnemonic
    // import) and a populated sibling is now online, AUTO-REQUEST a full snapshot from
    // it. The sibling shows a Confirm before sending. Gate on a near-empty DB so a
    // populated device never re-pulls, and only fire once per sibling per session.
    let (my_msgs, my_friends, _my_servers, _hp) =
        crate::api::storage::snapshot_state_summary();
    if my_msgs == 0 && my_friends == 0
        && link_snapshot_requested.insert(peer_id.to_string())
    {
        hollow_log!(
            "[HOLLOW-LINK] Empty device — auto-requesting snapshot from sibling {peer_id}"
        );
        // Mnemonic path has no typed code; both siblings share the master id, so use it
        // as the .hollow passphrase.
        link_handler::set_my_link_code(local_peer_str);
        link_handler::handle_request_link_snapshot(
            ws_cmd_tx, ws_room_peers, peer_id, false, false,
        );
    }
}

/// Issue a sibling-proof challenge to an UNPROVEN peer that appeared in our own
/// `inbox:{master}` room. Dedupes against a live unexpired challenge for the same
/// peer, bounds the map, and sends a fresh-nonce [`HavenMessage::SiblingProveRequest`].
/// Only a peer holding our SHARED MASTER key can answer it (see `on_verified_sibling`);
/// a friend-request sender (a stranger) cannot, so it is never mis-merged as our device.
fn issue_sibling_challenge(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_sibling_challenges: &mut HashMap<String, (String, std::time::Instant)>,
    peer_id: &str,
) {
    const CHALLENGE_TTL: Duration = Duration::from_secs(60);
    const MAX_PENDING: usize = 64;
    // Live unexpired challenge already out for this peer → don't spam.
    if pending_sibling_challenges
        .get(peer_id)
        .is_some_and(|(_, t)| t.elapsed() < CHALLENGE_TTL)
    {
        return;
    }
    // Bound the map: drop expired entries, and if still full, refuse a new challenge.
    if pending_sibling_challenges.len() >= MAX_PENDING {
        pending_sibling_challenges.retain(|_, (_, t)| t.elapsed() < CHALLENGE_TTL);
        if pending_sibling_challenges.len() >= MAX_PENDING {
            hollow_log!("[HOLLOW-SIBLING] Challenge map full — dropping new challenge to {peer_id}");
            return;
        }
    }
    let nonce = hex::encode({
        let mut b = [0u8; 16];
        getrandom::fill(&mut b)
            .expect("system RNG unavailable — cannot generate secure random bytes");
        b
    });
    pending_sibling_challenges.insert(peer_id.to_string(), (nonce.clone(), std::time::Instant::now()));
    hollow_log!("[HOLLOW-SIBLING] Challenging unproven inbox peer {peer_id} for sibling proof");
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers,
        peer_id, HavenMessage::SiblingProveRequest { nonce },
    );
}

use crate::crdt::hlc::Hlc;
use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{self as crdt_sync, StateVector};
use crate::crypto::{CryptoStore, MlsManager, OlmManager};

use super::types::*;

use super::crypto_handler;
use super::crypto_handler::{
    clip_text,
    key_bundle_signing_payload, key_request_signing_payload, signed_key_bundle, signed_key_request,
    verify_key_exchange, key_exchange_device_unauthorized,
    KeyExchangeAuth, REQUIRE_SIGNED_KEY_EXCHANGE,
    check_backfill_signature, BackfillSig, PkCache,
    persist_mls_state, persist_crypto_state, persist_olm_session,
    peer_is_reachable, is_mls_coordinator, is_vault_coordinator, elect_coordinator, ws_room_for_peer,
    send_mls_broadcast, send_encrypted_message,
    send_message_to_peer, send_raw_to_peer, send_raw_to_identity,
};
use super::file_handler;
use super::forwarder_client;
use super::link_handler;
use super::message_ops;
use super::emotes;
use super::social;
use super::sync_handler;
use super::vault_ops;
use super::twitch;
use super::voice_handler;

/// Embedded peer-forwarder handle threaded into the shared inbound dispatch
/// (`handle_incoming_request`) so forwarder-bound `fwd_*` envelopes can reach
/// the embedded engine (media forwarding step 3 phase 2). Desktop-only in
/// substance; a PhantomData elsewhere so the shared signature stays identical
/// on every platform.
#[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
type FwdBridge<'a> = (
    &'a mut super::embedded_forwarder::EmbeddedForwarder,
    &'a mpsc::Sender<NodeCommand>,
);
#[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
type FwdBridge<'a> = std::marker::PhantomData<&'a ()>;

/// Build and spawn the networking layer. Returns the MASTER peer ID and a join
/// handle.
///
/// Multi-device key routing (Phase 6, Step 7): the **device** keypair drives the
/// WS relay auth and the signaling register — so each physical device gets its
/// OWN distinct relay socket and never clobbers another device of the same
/// identity. The **master** keypair (`native_keypair`) drives EVERYTHING else
/// (the event loop's `local_peer_str`, MLS/server membership, message-content
/// signing, the DB passphrase). The rooms the device joins are master-derived
/// (`inbox:{master}`, `dm_room_code` resolves to masters, `server_id`), so the
/// device authenticates as itself yet sits in its identity's rooms. On a
/// pre-multi-device install device==master (migration keystone) so this is
/// behavior-neutral. See `node::resolver` header for the full rationale.
pub(crate) async fn spawn_node(
    native_keypair: crate::identity::native_identity::NativeKeypair,
    device_keypair: crate::identity::native_identity::NativeKeypair,
    event_tx: mpsc::Sender<NetworkEvent>,
    cmd_rx: mpsc::Receiver<NodeCommand>,
    cmd_tx: mpsc::Sender<NodeCommand>,
    olm: OlmManager,
    crypto_store: CryptoStore,
    crdt_store: super::crdt_store::CrdtStore,
    license_key: Option<String>,
    initial_invisible: bool,
    relay_domain: String,
) -> Result<(String, tokio::task::JoinHandle<()>), String> {
    // MASTER drives the event loop / identity; DEVICE drives transport (relay
    // auth + signaling register) so two devices of one identity get distinct
    // sockets.
    let bundle_keypair = native_keypair.clone();
    let master_peer_id = native_keypair.peer_id();
    let device_peer_id = device_keypair.peer_id();

    // Legacy HTTP signaling (register/bootstrap/unregister) RETIRED 2026-07:
    // peer discovery rides the live WS connection (`discover_peers` frame +
    // RoomMembers on join), which replaced the per-poll TLS handshake that
    // produced the "[HOLLOW-SIGNALING] Bootstrap failed" noise. The relay
    // keeps its HTTP endpoints for older clients.

    // Spawn the WebSocket relay client (device-keyed auth).
    let ws_proto = device_keypair.to_protobuf_encoding().unwrap_or_default();
    let ws_pub_b64 = base64::engine::general_purpose::STANDARD.encode(
        device_keypair.public_key_protobuf(),
    );
    let (ws_cmd_tx, ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
    let (ws_event_tx, ws_event_rx) = tokio::sync::mpsc::unbounded_channel();
    let ws_relay_url = format!("wss://{relay_domain}/ws");
    let _ws_handle = super::ws_client::spawn_ws_client(
        ws_relay_url, device_peer_id.clone(), ws_proto, ws_pub_b64,
        license_key, false, ws_cmd_rx, ws_event_tx,
    );

    // Derive DB path/passphrase from the global data dir + master keypair (the
    // production behavior, unchanged — now passed into the loop explicitly).
    let db_path = {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        data_dir.join("messages.db").to_string_lossy().to_string()
    };
    let db_passphrase = {
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        hex::encode(&proto[..32.min(proto.len())])
    };

    let handle = tokio::spawn(run_event_loop(
        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store,
        bundle_keypair, device_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,
        initial_invisible, db_path, db_passphrase,
    ));

    // The app's "my peer id" (friendships, display) is the MASTER id.
    Ok((master_peer_id, handle))
}

/// Test-only spawn variant for the headless multi-node integration harness
/// (`node::test_harness`). Identical to `spawn_node` EXCEPT it does NOT open a
/// real WebSocket socket or the HTTP signaling task — instead it accepts an
/// injected WS channel pair so an in-process `MockRelay` can route between
/// several nodes with no network/TLS/auth. The signaling side is a dead pair
/// (its event receiver never fires; DM/room delivery never depends on signaling
/// — it's a non-fatal HTTP peer-discovery fallback).
///
/// Returns `(master_peer_id, event_loop_handle, ws_cmd_rx, ws_event_tx)`: the
/// caller (broker) drains `ws_cmd_rx` (this node's outbound relay commands) and
/// pushes into `ws_event_tx` (this node's inbound relay events).
///
/// Production `spawn_node` above is untouched; this only exists under `cfg(test)`.
#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) async fn spawn_node_mock(
    native_keypair: crate::identity::native_identity::NativeKeypair,
    device_keypair: crate::identity::native_identity::NativeKeypair,
    event_tx: mpsc::Sender<NetworkEvent>,
    cmd_rx: mpsc::Receiver<NodeCommand>,
    cmd_tx: mpsc::Sender<NodeCommand>,
    olm: OlmManager,
    crypto_store: CryptoStore,
    crdt_store: super::crdt_store::CrdtStore,
    initial_invisible: bool,
    db_path: String,
    db_passphrase: String,
) -> Result<(
    String,
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::UnboundedReceiver<super::ws_client::WsCommand>,
    tokio::sync::mpsc::UnboundedSender<super::ws_client::WsEvent>,
), String> {
    let bundle_keypair = native_keypair.clone();
    let master_peer_id = native_keypair.peer_id();
    let device_peer_id = device_keypair.peer_id();

    // Injected WS channels (the broker owns the other ends).
    let (ws_cmd_tx, ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
    let (ws_event_tx, ws_event_rx) = tokio::sync::mpsc::unbounded_channel();

    let handle = tokio::spawn(run_event_loop(
        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store,
        bundle_keypair, device_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,
        initial_invisible, db_path, db_passphrase,
    ));

    Ok((master_peer_id, handle, ws_cmd_rx, ws_event_tx))
}

/// The main event loop. Runs until the task is aborted.
async fn run_event_loop(
    event_tx: mpsc::Sender<NetworkEvent>,
    mut cmd_rx: mpsc::Receiver<NodeCommand>,
    cmd_tx: mpsc::Sender<NodeCommand>,
    mut olm: OlmManager,
    crypto_store: CryptoStore,
    crdt_store: super::crdt_store::CrdtStore,
    bundle_keypair: crate::identity::native_identity::NativeKeypair,
    // THIS device's keypair. Distinct from `bundle_keypair` (the master): it
    // signs the Olm key exchange, which the receiver verifies against the
    // device peer_id the transport reports. See `crypto_handler::signed_key_request`.
    device_keypair: crate::identity::native_identity::NativeKeypair,
    ws_cmd_tx: tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    mut ws_event_rx: tokio::sync::mpsc::UnboundedReceiver<super::ws_client::WsEvent>,
    local_peer_str: String,
    device_peer_id: String,
    initial_invisible: bool,
    // DB path + passphrase, injected by the caller (production derives them from
    // the global data dir + master keypair; the test harness injects per-node
    // temp paths so several nodes can run in one process without colliding on the
    // process-global `data_dir()`).
    db_path: String,
    db_passphrase: String,
) {
    // Precompute public key base64 for prekey bundle signing.
    let pub_key_proto = bundle_keypair.public_key_protobuf();
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(&pub_key_proto);

    // -- Multi-device identity (Phase 6) --
    // `local_peer_str` IS the master id (the event loop runs in identity terms);
    // `bundle_keypair` IS the master keypair (message signing, device-list sig).
    // `device_peer_id` (passed in) is THIS device's transport peer_id — the id we
    // authenticate to the relay with. On a pre-multi-device install they are
    // equal (migration keystone). See `spawn_node` + `node::resolver` for the
    // key-routing rationale.
    let master_keypair = bundle_keypair.clone();
    let master_peer_str = local_peer_str.clone();

    // Decrypt failure cooldown: track last session-kill time per peer.
    // Prevents rapid session thrashing when many in-flight chunks fail decrypt
    // (e.g., 340MB file = 1360 chunks, all fail after session reset).
    let mut decrypt_fail_cooldown: HashMap<String, std::time::Instant> = HashMap::new();
    const REKEY_COOLDOWN: Duration = Duration::from_secs(5);

    // Buffer messages while key exchange is in progress.
    let mut pending_messages: HashMap<String, Vec<String>> = HashMap::new();

    // Track which peers have an active key request in flight (avoid duplicate requests).
    // Maps peer_id -> when the KeyRequest was sent. Entries older than
    // OLM_KEY_REQUEST_TIMEOUT are treated as stale so the reconciliation sweep can
    // resend (the relay never ACKs, so a dropped frame must self-heal via retry).
    let mut key_request_in_flight: HashMap<String, std::time::Instant> = HashMap::new();
    // Track peers we've sent a KeyBundle to (for glare detection at KeyBundle reception).
    let mut key_bundle_sent_to: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track the active room code so we can re-bootstrap after getting a relay circuit address.
    let mut active_room: Option<String> = None;

    // -- Vault shard assembly state (Phase 4) --
    // Tracks chunked shard reassembly. Key = "content_id:shard_index:sender_peer".
    let mut pending_shard_assembly: HashMap<String, PendingShardAssembly> = HashMap::new();

    // -- Pending stream transfer state --
    let mut pending_file_streams: HashMap<String, PendingFileStream> = HashMap::new();
    // Early-arrival file streams: WebRTC bytes arrived before the FileHeader.
    // Key: file_id, Value: (temp_path, size, sender_peer_id)
    let mut early_file_streams: HashMap<String, (std::path::PathBuf, u64, String)> = HashMap::new();
    let mut pending_shard_streams: HashMap<String, PendingShardStream> = HashMap::new();

    // Pending multi-device link snapshots awaiting reassembly. Key: link session id,
    // Value: the AES key/nonce to decrypt the assembled snapshot bytes with.
    let mut pending_link_snapshots: HashMap<String, file_handler::LinkSnapshotState> = HashMap::new();

    // Pending vault downloads waiting for remote shards.
    // Key: content_id, Value: (server_id, shards_needed: k, shards_requested: count)
    let mut pending_vault_downloads: HashMap<String, (String, usize, usize)> = HashMap::new();

    // -- WebSocket relay peer tracking --
    // Tracks which peers are in which WS rooms. Key: room_code, Value: set of peer_id strings.
    let mut ws_room_peers: HashMap<String, std::collections::HashSet<String>> = HashMap::new();

    // Embedded peer forwarder (media forwarding step 3 phase 2): this desktop
    // can serve as a blind packet forwarder for screen shares it watches.
    // Desktop-only + feature-gated; every use site carries the same cfg.
    #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
    let mut embedded_fwd =
        super::embedded_forwarder::EmbeddedForwarder::new(device_peer_id.clone());

    // Peers we've already triggered sync for this session.
    let mut synced_peers: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Asset hashes already requested THIS connection (pull-once throttle),
    // each recorded with the kind WE asked for — handle_emote_assets sizes
    // the receipt cap from this map, never from anything the sender says.
    // Cleared on WS disconnect so a lost reply can be re-pulled after reconnect.
    let mut requested_asset_kinds: std::collections::HashMap<String, emotes::AssetKind> =
        std::collections::HashMap::new();

    // Guest public-file downloads: file_id -> (server_id, requested-at). The
    // receipt cap for plaintext `PublicFileHeader`s — only headers answering a
    // request WE made (fresh, matching server) are accepted, mirroring
    // `requested_asset_kinds`. An unsolicited header would otherwise register
    // a decrypt key + let a stranger stream bytes onto our disk.
    let mut pending_public_file_requests: std::collections::HashMap<String, (String, std::time::Instant)> =
        std::collections::HashMap::new();

    // Files WE explicitly asked for (manual Download button, missing-file
    // sweeps, guest pulls): file_id -> requested-at. A FileHeader answering one
    // of these bypasses BOTH the per-context size cap and the auto-download
    // gate — the user asked for exactly these bytes (issue #41). Receipts are
    // consumed on first matching header and expire after 5 minutes.
    let mut requested_file_receipts: std::collections::HashMap<String, std::time::Instant> =
        std::collections::HashMap::new();

    // Pushed files declined by the auto-download gate THIS session. Stream
    // bytes that arrive for these (the sender queues its push before any
    // response could reach it) are deleted instead of being parked forever in
    // `early_file_streams`.
    let mut declined_file_ids: std::collections::HashSet<String> =
        std::collections::HashSet::new();

    // Auto-download preferences ADVERTISED by peer devices (issue #41
    // pre-negotiation): device peer_id -> effective threshold MB for pushes
    // from us (0 = off). Consulted by the DM file fan-out so we skip streaming
    // bytes a gated receiver would only discard. Connection state — cleared on
    // WsEvent::Disconnected; peers re-advertise when they rejoin our rooms.
    let mut peer_auto_dl: std::collections::HashMap<String, u32> =
        std::collections::HashMap::new();

    // (server room, channel) pairs whose relay offline catch-up replay already
    // ran THIS connection — fed by both the connect-time sweep (RoomMembers)
    // and the channel-open hook (SubscribeChannels). Cleared on
    // WsEvent::Disconnected like every sync gate — a new socket needs a fresh
    // registration + replay.
    let mut relay_catchup_done: std::collections::HashSet<(String, String)> = std::collections::HashSet::new();

    let mut is_invisible = initial_invisible;
    if initial_invisible {
        hollow_log!("[HOLLOW-STATUS] Node starting in invisible mode (persisted preference)");
    }

    // -- WebRTC peer tracking (Phase 5A) --
    // Peers with active GENERAL 'hollow-data' channels (Dart notifies us via
    // NodeCommand). Carries DM/channel files, vault shards, screen audio, gossip.
    let mut webrtc_peers: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Peers with an active HOLLOW SHARE channel — a SECOND, STUN-only peer
    // connection (HOLLOW_PLAN §7A). Kept separate on purpose: the general
    // channel above carries TURN, so a Share scheduled against it would push
    // multi-GB payloads through the relay. See node/share_handler.rs.
    let mut webrtc_share_peers: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Pending WebRTC sends — stored so we can retry via WSS on failure.
    // Key: transfer_id, Value: (peer_id, kind, id, source_path, total_size)
    let mut pending_webrtc_sends: HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)> = HashMap::new();

    // Startup sweep: delete orphaned sender-side stream temps (`.stream_send_*`,
    // `.stream_shard_*`) left in files/ by a previous run. These are always
    // transient ciphertext artifacts of an in-flight send — none can legitimately
    // exist on a fresh boot — so they're safe to remove. Reclaims leaks from the
    // pre-fix WS-relay send path that never deleted its temp (doubled disk usage).
    {
        let files_dir = crate::node::file_transfer::files_dir();
        if let Ok(entries) = std::fs::read_dir(&files_dir) {
            let mut swept = 0u32;
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(".stream_send_") || name.starts_with(".stream_shard_") {
                    if std::fs::remove_file(entry.path()).is_ok() {
                        swept += 1;
                    }
                }
            }
            if swept > 0 {
                hollow_log!("[HOLLOW-FILE] Startup swept {swept} orphaned stream temp(s) from files/");
            }
        }
    }

    // -- Profile sync state --
    // Flag: have we broadcast our profile on first connection?
    let mut profile_broadcast_done = false;

    // -- Gossip relay tree state (Phase 5D) --
    let mut gossip_overlays: HashMap<String, super::gossip::GossipOverlay> = HashMap::new();

    // -- Voice channel participant tracking (Phase 5D) --
    // Key: "server_id:channel_id", Value: set of peer_ids in the voice channel.
    let mut voice_channel_participants: HashMap<String, std::collections::HashSet<String>> = HashMap::new();
    // Track the current voice mode per channel: true = gossip, false = mesh.
    let mut voice_channel_gossip_mode: HashMap<String, bool> = HashMap::new();

    // -- Conference host state (active meetings we host; node/conference.rs) --
    let mut conference_host: HashMap<String, super::conference::ConferenceHostState> = HashMap::new();

    // -- WS stream transfer reassembly state (Phase 5.5) --
    let mut pending_ws_transfers: HashMap<String, super::ws_stream_transfer::WsTransferState> = HashMap::new();

    // -- Recovery pool state (Evidence Recovery) --
    let mut recovery_pool_state: Option<crate::node::recovery_pool::RecoveryPoolState> = None;

    // -- Hollow Share --
    // Registry of active share swarms. Owned by this event loop and passed
    // as &mut into every handler — same pattern as other domain modules.
    let mut share_registry: super::share_handler::ShareRegistry = super::share_handler::new_registry();
    // Process-wide outbound seed bandwidth bucket — caps share uploads at
    // SEED_REFILL_BPS so messaging/voice never starve.
    let mut seed_budget = super::share_handler::SeedBudget::new();
    // Coexistence: any messaging/voice send bumps this; the share scheduler
    // pauses chunk requests while it's recent.
    let mut last_message_traffic: std::time::Instant = std::time::Instant::now()
        .checked_sub(std::time::Duration::from_secs(60))
        .unwrap_or_else(std::time::Instant::now);
    // Auto-rejoin every share row with seeding=1 so we keep serving across restarts.
    super::share_handler::auto_rejoin_seeders(&mut share_registry, &bundle_keypair, &ws_cmd_tx);

    // `db_path` / `db_passphrase` are now injected by the caller (see signature).

    // -- Multi-device resolver warm-up (Phase 6) --
    // Load persisted device links + our own device(s) into the process-global
    // resolver BEFORE the event loop processes any incoming message — otherwise
    // an early message from another device of a friend would misattribute
    // (resolver hazard R4). On a pre-multi-device install this is a no-op
    // self-mapping (device_peer_id == master).
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            if let Ok(links) = store.get_all_device_links() {
                super::resolver::warm_from_links(&links);
            }
            // Always include THIS running device in the self-seed, UNIONed with any
            // persisted list. On a freshly LINKED sibling (Step 9C/C5) the imported
            // list is the SOURCE device's and does NOT yet contain our brand-new
            // device id — without this union our own id resolves to itself (not the
            // master), so `myMaster`/`myDevicesProvider` are wrong and the "Your
            // devices" panel shows only one device until the source comes online and
            // the inbox-proof merge fires. Seeding our own id here makes the resolver
            // (and the panel) correct immediately: {source_dev, this_dev} → master.
            match store.load_device_list(&master_peer_str) {
                Ok(Some(list)) => {
                    let mut devs = list.devices.clone();
                    if !devs.iter().any(|d| d == &device_peer_id) {
                        devs.push(device_peer_id.clone());
                    }
                    super::resolver::seed_self(&master_peer_str, &devs);
                }
                _ => super::resolver::seed_self(&master_peer_str, &[device_peer_id.clone()]),
            }
            // Warm the block list alongside the resolver — the ingest guards
            // must see persisted blocks before the first message arrives.
            if let Ok(blocked) = store.load_blocked_peers() {
                super::blocklist::warm(&blocked);
            }
        }
    }
    // Multi-device (Step 6): install the device→master resolver into the `crdt`
    // module so ServerState's role/ban/permission/membership accessors collapse a
    // device id to its master internally (one chokepoint for dozens of call sites).
    crate::crdt::set_identity_resolver(super::resolver::resolve);

    // -- Friend-table canonicalization sweep (multi-device heal) --
    // INVARIANT: every friend row is keyed by the friend's MASTER identity. Older
    // builds (and the temp-nickname add path) could strand a row under a friend's
    // DEVICE id, which then diverged from presence/DM/profile (all master-keyed) —
    // the friend showed offline, removal missed, favourites went stale, etc. The
    // resolver is now warm (persisted device links loaded above), so fold any
    // device-keyed row into its master in one pass. Idempotent: a row already
    // under its master resolves to itself and is skipped. This heals an existing
    // broken DB on the very next launch — no re-add required.
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            if let Ok(rows) = store.load_friends(None) {
                let mut folded = 0u32;
                for (peer_id, _status, _dir, _req, _upd) in rows {
                    let master = super::resolver::resolve(&peer_id);
                    if master != peer_id {
                        if let Ok(true) = store.migrate_friend_to_master(&peer_id, &master) {
                            folded += 1;
                        }
                    }
                }
                if folded > 0 {
                    hollow_log!(
                        "[HOLLOW-FRIENDS] Canonicalized {folded} device-keyed friend row(s) → master at startup"
                    );
                }
            }
        }
    }

    // -- CRDT state (Phase 3) --
    // Server states keyed by server_id. Reload from DB so servers survive restarts.
    let mut server_states: HashMap<String, ServerState> = HashMap::new();
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            match store.load_all_servers() {
                Ok(rows) => {
                    for (server_id, json) in rows {
                        match serde_json::from_str::<ServerState>(&json) {
                            Ok(mut state) => {
                                state.set_hlc(Hlc::new(local_peer_str.to_string()));
                                // Restore op_log from crdt_ops table (no longer serialized in state JSON).
                                if state.op_log.is_empty() {
                                    if let Ok(ops) = store.load_ops_for_server(&server_id) {
                                        state.restore_op_log(ops);
                                    }
                                }
                                // Multi-device (Step 6): fold any legacy device-keyed
                                // member entries into their master identity (resolver
                                // warmed just above). No-op for single-device.
                                if state.canonicalize_members(|id| super::resolver::resolve(id)) {
                                    if let Ok(json) = serde_json::to_string(&state) {
                                        let _ = store.save_server_state(&server_id, &json);
                                    }
                                    hollow_log!("[HOLLOW-MULTIDEV] Canonicalized device-keyed members → master for server {server_id}");
                                }
                                server_states.insert(server_id.clone(), state);
                                // Join the WS relay room for this server.
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                    room_code: server_id,
                                });
                            }
                            Err(e) => {
                                hollow_log!("Failed to deserialize server {}: {}", server_id, e);
                            }
                        }
                    }
                    if !server_states.is_empty() {
                        hollow_log!("Loaded {} server(s) from DB", server_states.len());
                    }
                }
                Err(e) => {
                    hollow_log!("Failed to load servers from DB: {}", e);
                }
            }
        }
    }

    // -- MLS state --
    let mut mls: Option<MlsManager> = {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            match store.load_mls_identity() {
                Ok(Some((signer_data, credential_data, storage_data))) => {
                    // Enumerate every MLS group key to reload: each server's bare id
                    // (server-wide group) PLUS each restricted channel's subgroup id
                    // (Option B). The storage blob already holds the group data; this
                    // list is what gets instantiated into the live `groups` map.
                    let mut server_ids: Vec<String> = Vec::new();
                    for (sid, state) in server_states.iter() {
                        server_ids.push(sid.clone());
                        for cid in state.subgroup_channel_ids() {
                            server_ids.push(crate::crypto::subgroup_id(sid, &cid));
                        }
                    }
                    match MlsManager::from_persisted(
                        &signer_data,
                        &credential_data,
                        storage_data.as_deref(),
                        &server_ids,
                    ) {
                        Ok(mgr) => {
                            // Multi-device (Step 6): a linked sibling imported the
                            // SOURCE device's whole DB — including its MLS signer +
                            // credential. Two devices sharing one MLS signature key
                            // can't both be leaves (OpenMLS `DuplicateSignatureKey` on
                            // add; `CannotDecryptOwnMessage` on receive). Detect an
                            // inherited credential (belongs to neither THIS device nor
                            // our master) and discard it so a FRESH, distinct MLS
                            // identity is minted below. Legacy single-device installs
                            // (credential == master) are kept untouched — no re-key.
                            // Detect an MLS credential that doesn't belong to THIS
                            // device and must be regenerated (a linked sibling reused
                            // the source device's MLS identity → DuplicateSignatureKey
                            // on add / CannotDecryptOwnMessage on receive). Two cases:
                            //  (a) credential is some OTHER device's id → clearly foreign.
                            //  (b) credential is our MASTER, but we are a multi-device
                            //      identity (we know sibling devices) → it's the
                            //      inherited keystone-master leaf shared with a sibling;
                            //      regenerate to a distinct device-id leaf. A LEGACY
                            //      SOLE single-device install (no known siblings) keeps
                            //      its master-credentialed leaf untouched — re-keying it
                            //      would orphan servers it owns (no peer can re-add it).
                            let cred_id = mgr.credential_identity();
                            let siblings = super::resolver::devices_for(&master_peer_str);
                            let has_sibling = siblings.iter().any(|d| d != &device_peer_id);
                            // The KEYSTONE device (device_peer_id == master) kept its old
                            // MASTER-credentialed leaf, but the rest of the multi-device
                            // system assumes DEVICE-credentialed leaves — so once a sibling
                            // is linked + groups re-key, a friend's group view advances past
                            // the keystone's stale leaf and can no longer decrypt its channel
                            // messages/typing. Regenerate to a device-credentialed leaf ONLY
                            // when we have a sibling (a legacy SOLE single-device install keeps
                            // its master leaf untouched — re-keying it would orphan servers it
                            // owns with no peer to re-add it). After regenerate, the
                            // sibling-re-adds-sibling path + reactive bootstrap re-join groups.
                            let stale_keystone = cred_id == master_peer_str
                                && device_peer_id == master_peer_str
                                && has_sibling;
                            let foreign = (cred_id != device_peer_id
                                && (cred_id != master_peer_str || has_sibling))
                                || stale_keystone;
                            if foreign {
                                hollow_log!("[HOLLOW-MLS] MLS credential {cred_id} not ours / stale keystone (device={device_peer_id}, has_sibling={has_sibling}, stale_keystone={stale_keystone}); discarding inherited identity + groups, will mint fresh");
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                    let _ = store.clear_mls_identity();
                                }
                                None
                            } else {
                                hollow_log!("[HOLLOW-MLS] Restored MLS identity from DB (credential {cred_id})");
                                Some(mgr)
                            }
                        }
                        Err(e) => {
                            hollow_log!("[HOLLOW-MLS] Failed to restore MLS identity: {e}");
                            None
                        }
                    }
                }
                Ok(None) => None,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Failed to load MLS identity: {e}");
                    None
                }
            }
        } else {
            None
        }
    };
    // Create MLS identity if none exists.
    // Multi-device (Step 6): a FRESH MLS identity is credentialed by THIS
    // device's transport peer_id, so two devices of one human hold two leaves
    // with two distinct credentials. Existing installs took the `from_persisted`
    // branch above and keep their old (master) credential untouched — no re-key.
    // A never-rotated single-device install has no siblings, so the device id
    // resolves to itself and everything stays self-consistent.
    if mls.is_none() {
        match MlsManager::new(&device_peer_id) {
            Ok(mgr) => {
                hollow_log!("[HOLLOW-MLS] Created new MLS identity");
                // Persist immediately.
                if let Ok(signer) = mgr.signer_bytes() {
                    if let Ok(cred) = mgr.credential_bytes() {
                        if let Ok(storage) = mgr.serialize_storage() {
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                let _ = store.save_mls_identity(&signer, &cred, &storage);
                            }
                        }
                    }
                }
                mls = Some(mgr);
            }
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] Failed to create MLS identity: {e}");
            }
        }
    }

    // Track server_ids we're trying to join (waiting for SyncResponse from existing members).
    // Value is the optional Twitch proof JSON to attach to join requests.
    let mut pending_server_joins: HashMap<String, PendingJoin> = HashMap::new();
    // "{server_id}|{joiner_device}" -> when we last saw that join request, so the
    // coordinator gate can tell a first ask from the joiner's escalation retry.
    let mut join_request_seen: HashMap<String, std::time::Instant> = HashMap::new();
    // Pending friend requests: peer_id → requested_at timestamp.
    // Queued when peer isn't reachable (no shared rooms), sent when they appear.
    let mut pending_friend_requests: HashMap<String, i64> = HashMap::new();
    let mut pending_nickname_resolve: Option<String> = None;
    // Multi-device linking (Step 4). `pending_link_resolve` = (code, include_vault,
    // include_files) carried from ResolveLinkCode to the LinkCodeResolved event.
    // `pending_link_code` = the code WE claimed (populated device), so we can leave
    // its room on release.
    let mut pending_link_resolve: Option<(String, bool, bool)> = None;
    let mut pending_link_code: Option<String> = None;
    // Siblings we've already auto-requested a snapshot from this session (fire-once).
    let mut link_snapshot_requested: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Sibling-proof challenges in flight: unknown inbox peer_id -> (nonce, issued_at).
    // An unproven peer joining `inbox:{our_master}` is challenged to sign the nonce with
    // our shared master key; only a genuine sibling can, gating the merge/snapshot.
    // 60s TTL, bounded, one live challenge per peer (see issue_sibling_challenge).
    let mut pending_sibling_challenges: HashMap<String, (String, std::time::Instant)> = HashMap::new();
    // Pending friend removals: peer_ids whose FriendRemove wasn't delivered (peer offline).
    let mut pending_friend_removals: std::collections::HashSet<String> = std::collections::HashSet::new();
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            if let Ok(friends) = store.load_friends(Some("pending")) {
                for (peer_id, _status, direction, requested_at, _updated_at) in friends {
                    if direction == "outgoing" {
                        pending_friend_requests.insert(peer_id, requested_at);
                    }
                }
                if !pending_friend_requests.is_empty() {
                    hollow_log!(
                        "[HOLLOW-FRIENDS] Restored {} pending outgoing friend requests from DB",
                        pending_friend_requests.len()
                    );
                }
            }
            if let Ok(friends) = store.load_friends(Some("removed")) {
                for (peer_id, _status, direction, _requested_at, _updated_at) in friends {
                    if direction == "outgoing" {
                        pending_friend_removals.insert(peer_id);
                    }
                }
                if !pending_friend_removals.is_empty() {
                    hollow_log!(
                        "[HOLLOW-FRIENDS] Restored {} pending friend removals from DB",
                        pending_friend_removals.len()
                    );
                }
            }
        }
    }

    // Pending friend ACCEPTS: master → timestamp. A FriendAccept we sent may not have
    // reached the requester (its device raced our accept and wasn't in our room yet, or
    // it was offline) — without redelivery the requester stays stuck "pending outgoing"
    // forever (it accepted on our side but never on theirs). Seed with EVERY accepted
    // friend so that on this session's first contact with each, we (re)send an
    // idempotent FriendAccept — guaranteeing the requester converges even across a
    // restart. Drained on the peer's appearance (PeerJoined/RoomMembers); the entry is
    // removed on first delivery so it's at most one extra message per friend per session.
    let mut pending_friend_accepts: HashMap<String, i64> = HashMap::new();
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            if let Ok(friends) = store.load_friends(Some("accepted")) {
                for (peer_id, _status, _direction, requested_at, _updated_at) in friends {
                    pending_friend_accepts.insert(peer_id, requested_at);
                }
            }
        }
    }

    // Track failed sync requests per peer — retried after session re-establishment.
    // Maps peer_id_str → Vec<(server_id, channel_id, since_timestamp)>
    let mut pending_sync_requests: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();

    // Track server_ids for which we've already requested MLS bootstrap (KeyPackage sent to owner).
    // Prevents spamming the owner on every MlsChannelMessage for an unknown group.
    // Value = when the request was sent; entries expire after MLS_BOOTSTRAP_TIMEOUT to allow retry.
    let mut mls_bootstrap_requested: HashMap<String, std::time::Instant> = HashMap::new();

    // Per-(group, peer) cooldowns for MLS epoch-hint service and self-probes
    // (join-order SFrame race fix). Key: "{group_key}|{master}" for serving,
    // "{group_key}|probe" for our own probes.
    let mut mls_epoch_hint_cooldown: HashMap<String, std::time::Instant> = HashMap::new();

    // Track which channels the Dart UI is subscribed to per server (for scoped sync on decrypt failure).
    let mut subscribed_channels: HashMap<String, Vec<String>> = HashMap::new();

    // MLS batch addition queue: collect KeyPackages and process them in a single commit.
    let mut pending_mls_key_packages: HashMap<String, Vec<(String, Vec<u8>)>> = HashMap::new();
    // MLS batch removal queue: collect peers needing removal before re-add (recovery).
    let mut pending_mls_removals: HashMap<String, Vec<String>> = HashMap::new();
    let mut mls_batch_interval = Duration::from_secs(2);
    let mut mls_batch_timer = tokio::time::interval(mls_batch_interval);
    mls_batch_timer.tick().await; // consume immediate first tick

    // MLS decrypt failure counter per server — triggers recovery after 3 consecutive failures.
    let mut mls_decrypt_failures: HashMap<String, (u32, std::time::Instant)> = HashMap::new();

    // Multi-peer fan-out sync coordinator.
    // Collects connected peers for 500ms, then assigns channels evenly across peers.
    let mut sync_coordinator = SyncCoordinator::new();

    // Sync coordinator dispatch timer (100ms tick — checks if collection window has elapsed).
    let mut sync_dispatch_timer = tokio::time::interval(Duration::from_millis(100));
    sync_dispatch_timer.tick().await; // consume immediate first tick

    // Channel sync dedup: tracks (server_id:channel_id) → last sync request time.
    // Prevents the same channel from being sync-requested multiple times in quick succession.
    let mut channel_sync_sent: HashMap<String, std::time::Instant> = HashMap::new();

    // Guest sync: rooms joined as a non-member for browsing public channels.
    let mut guest_rooms: std::collections::HashSet<String> = std::collections::HashSet::new();

    // SECURITY: Per-peer rate limiter — token bucket (100 burst, refill 20/sec).
    // Prevents message flooding from malicious peers.
    let mut peer_rate_tokens: HashMap<String, (u32, std::time::Instant)> = HashMap::new();
    const RATE_LIMIT_BURST: u32 = 100;
    const RATE_LIMIT_REFILL: u32 = 20; // tokens per second

    // SECURITY (Phase 6.25): Sub-rate-limiter for VC signaling messages within MLS.
    // Tighter limit: 30 burst, 10/sec per peer (VC signals are less frequent than chat).
    let mut vc_signal_rate_tokens: HashMap<String, (u32, std::time::Instant)> = HashMap::new();

    // Push notification token — cached for re-registration on WS reconnect.
    let mut push_token: Option<(String, String)> = None; // (token, platform)
    // Channel push prefs JSON — cached for re-registration on WS reconnect.
    let mut push_prefs: Option<String> = None;

    // Re-bootstrap timer (30 seconds) for signaling re-registration.
    let mut rebootstrap_timer = tokio::time::interval(Duration::from_secs(30));
    rebootstrap_timer.tick().await; // consume immediate first tick
    let mut eviction_counter: u32 = 0;

    // Vault rebalance + retention enforcement timer (30 min safety net).
    let mut rebalance_timer = tokio::time::interval(Duration::from_secs(1800));
    rebalance_timer.tick().await; // consume immediate first tick

    // Event-driven rebalance: debounced 10s timer + pending server set.
    let mut rebalance_debounce = tokio::time::interval(Duration::from_secs(10));
    rebalance_debounce.tick().await; // consume immediate first tick
    let mut rebalance_pending: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Stream transfer progress poll timer (500ms) — emits FileProgress events
    // to Dart based on bytes received by the FileStreamCodec.
    let mut stream_progress_timer = tokio::time::interval(Duration::from_millis(500));
    stream_progress_timer.tick().await; // consume immediate first tick

    // Gossip overlay rotation timer (5 minutes) — rotate neighbors based on scores.
    let mut gossip_rotation_timer = tokio::time::interval(Duration::from_secs(
        super::gossip::ROTATION_INTERVAL_SECS,
    ));
    gossip_rotation_timer.tick().await; // consume immediate first tick

    // Gossip broadcast dedup eviction timer (60s) — remove stale broadcast IDs.
    let mut gossip_eviction_timer = tokio::time::interval(Duration::from_secs(
        super::gossip::BROADCAST_DEDUP_TTL_SECS,
    ));
    gossip_eviction_timer.tick().await; // consume immediate first tick

    // Gossip peer exchange timer (2 minutes) — share neighbor lists with peers.
    let mut gossip_exchange_timer = tokio::time::interval(Duration::from_secs(120));
    gossip_exchange_timer.tick().await; // consume immediate first tick

    // Hollow Share scheduler: 1-second tick drives chunk requests, Have
    // rebroadcast every 10s, in-flight timeout/retry.
    let mut share_tick_timer = tokio::time::interval(Duration::from_millis(50));
    share_tick_timer.tick().await; // consume immediate first tick

    // MLS state debounce: persist dirty MLS state every 2s instead of per-message.
    let mut mls_persist_timer = tokio::time::interval(Duration::from_secs(2));
    mls_persist_timer.tick().await; // consume immediate first tick
    let mut mls_dirty = false;

    let mut peer_liveness_timer = tokio::time::interval(Duration::from_secs(60));
    peer_liveness_timer.tick().await; // consume immediate first tick

    // Temporary channel-grant expiry sweep. The predicate is lazy (an expired
    // grant already reads as denied); this timer drives the CONSEQUENCES:
    // MLS subgroup leaf removal (coordinator-gated, idempotent), voice
    // eviction, and a ServerUpdated so the expired member's own UI refreshes.
    // cfg(test) shortens the period so the harness can observe expiry without
    // 30-second waits.
    let grant_sweep_secs: u64 = if cfg!(test) { 2 } else { 30 };
    let mut grant_sweep_timer = tokio::time::interval(Duration::from_secs(grant_sweep_secs));
    grant_sweep_timer.tick().await; // consume immediate first tick
    // Last-tick watermark; 0 so the FIRST tick reconciles grants that expired
    // while this node was offline (one-time, idempotent).
    let mut grant_sweep_last_ms: u64 = 0;

    // TURN credential refresh: relay credentials last 1h; re-request at 50min
    // so long-lived sessions never expire mid-call. A fresh set is also
    // requested on every WsEvent::Connected, so this only matters for
    // continuously-connected sessions.
    let mut turn_refresh_timer = tokio::time::interval(Duration::from_secs(50 * 60));
    turn_refresh_timer.tick().await; // consume immediate first tick

    // -- Performance sentinels (quiet by default; see src/sentinel.rs) --
    // Runtime starvation heartbeat: once per process (harness nodes share it).
    crate::sentinel::spawn_runtime_heartbeat();
    let mut loop_stall = crate::sentinel::LoopStall::new();
    // (arm, variant, start) of the dispatch arm that just ran — measured at
    // the top of the NEXT iteration so the `continue;` early-exits scattered
    // through the arms are still covered.
    let mut arm_started: Option<(&'static str, &'static str, std::time::Instant)> = None;

    loop {
        if let Some((arm, name, t0)) = arm_started.take() {
            loop_stall.check(arm, name, t0);
        }
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                arm_started = Some(("cmd", cmd.kind(), std::time::Instant::now()));
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // If switching rooms, unregister from the old room and clear state.
                        if let Some(old_room) = active_room.as_ref().filter(|r| *r != &room_code) {
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                        }
                        active_room = Some(room_code.clone());
                        // Join the WS relay room for DMs.
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                            room_code: room_code.clone(),
                        });
                        // Also register with signaling for peer discovery.
                    }
                    NodeCommand::SendMessage { peer_id: peer_id_str, text, message_id, reply_to_mid, link_preview } => {
                        last_message_traffic = std::time::Instant::now();
                        message_ops::handle_send_message(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, text, message_id, reply_to_mid, link_preview,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendChannelMessage { server_id, channel_id, text, message_id, reply_to_mid, link_preview } => {
                        last_message_traffic = std::time::Instant::now();
                        message_ops::handle_send_channel_message(
                            &mut olm, &crypto_store, &mut mls, &server_states,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, text, message_id, reply_to_mid, link_preview,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    // -- CRDT commands (Phase 3) --

                    NodeCommand::CreateServer { name } => {
                        sync_handler::handle_create_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id, name,
                            &crypto_store, &crdt_store,
                        ).await;
                    }

                    NodeCommand::CreateChannel { server_id, channel_id, name, category, channel_type } => {
                        if sync_handler::handle_create_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, name, category, channel_type,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RemoveChannel { server_id, channel_id } => {
                        if sync_handler::handle_remove_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RenameServer { server_id, new_name } => {
                        if sync_handler::handle_rename_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, new_name,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RenameChannel { server_id, channel_id, new_name } => {
                        if sync_handler::handle_rename_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, new_name,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UpdateServerSetting { server_id, key, value } => {
                        sync_handler::handle_update_server_setting(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, key, value,
                            &crypto_store, &crdt_store,
                        ).await;
                    }

                    NodeCommand::DeleteServer { server_id } => {
                        if sync_handler::handle_delete_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::JoinServer { server_id, twitch_proof_json, nsfw_confirmed } => {
                        sync_handler::handle_join_server(
                            &mut pending_server_joins, &mls, &ws_cmd_tx,
                            &ws_room_peers, &cmd_tx,
                            server_id, twitch_proof_json, nsfw_confirmed,
                            &crdt_store,
                        ).await;
                    }

                    NodeCommand::ChangeRole { server_id, peer_id, new_role } => {
                        let sid = server_id.clone();
                        let handled = sync_handler::handle_change_role(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id, new_role,
                            &crdt_store,
                        ).await;
                        // A role change shifts who qualifies for restricted channels —
                        // reconcile every subgroup in this server (Option B). Idempotent
                        // + coordinator-gated, so safe even on the permission-denied path.
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, None,
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::KickMember { server_id, peer_id } => {
                        if sync_handler::handle_kick_member(
                            &mut server_states, &mut mls, &mut olm, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RevokeDevice { device_peer_id: target } => {
                        if let Some(revoked) = sync_handler::handle_revoke_device(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &master_keypair,
                            &master_peer_str, &local_peer_str, &device_peer_id,
                            is_invisible, target, &db_path, &db_passphrase,
                        ).await {
                            // Drop our Olm session to the revoked device + (coordinator)
                            // remove its MLS leaf from shared servers — same enforcement
                            // path a friend runs when it ingests the tombstoned list.
                            enforce_device_revocations(
                                &[revoked], &mut olm, &crypto_store, mls.as_ref(),
                                &local_peer_str, &ws_room_peers, &mut pending_mls_removals,
                            );
                        }
                    }

                    NodeCommand::ResetDeviceLists => {
                        if let Some(revoked) = sync_handler::handle_reset_device_lists(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &master_keypair,
                            &master_peer_str, &local_peer_str, &device_peer_id,
                            is_invisible, &db_path, &db_passphrase,
                        ).await {
                            // Drop Olm sessions to every revoked sibling + (coordinator)
                            // remove their MLS leaves from shared servers — same path a
                            // friend runs ingesting the tombstones.
                            enforce_device_revocations(
                                &revoked, &mut olm, &crypto_store, mls.as_ref(),
                                &local_peer_str, &ws_room_peers, &mut pending_mls_removals,
                            );
                        }
                    }

                    NodeCommand::RequestStateSync { source_device_id } => {
                        // Manual sync: ask a chosen SOURCE sibling to push us its
                        // servers + friends. SECURITY: only meaningful for our own
                        // device; the responder verifies same_identity anyway.
                        hollow_log!(
                            "[HOLLOW-SYNC] Manual state-sync request → source device {source_device_id}"
                        );
                        let req = serde_json::to_vec(&HavenMessage::SiblingStateSyncRequest)
                            .unwrap_or_default();
                        if !req.is_empty() {
                            // Target the source device directly via our own inbox room
                            // (only our devices are in inbox:{master}). Fall back to any
                            // room that currently lists it.
                            let own_inbox = format!("inbox:{local_peer_str}");
                            let room = if ws_room_peers.get(&own_inbox)
                                .is_some_and(|p| p.contains(&source_device_id))
                            {
                                Some(own_inbox)
                            } else {
                                ws_room_peers.iter()
                                    .find(|(_, peers)| peers.contains(&source_device_id))
                                    .map(|(r, _)| r.clone())
                            };
                            if let Some(room) = room {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                                    room_code: room,
                                    target_peer: source_device_id.clone(),
                                    data: req,
                                });
                            } else {
                                hollow_log!(
                                    "[HOLLOW-SYNC] Source device {source_device_id} not in any room — is it online?"
                                );
                            }
                        }
                    }

                    NodeCommand::LeaveServer { server_id } => {
                        if sync_handler::handle_leave_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::ChangeRolePermissions { server_id, role, permissions } => {
                        if sync_handler::handle_change_role_permissions(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, role, permissions,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::BanMember { server_id, peer_id } => {
                        if sync_handler::handle_ban_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnbanMember { server_id, peer_id } => {
                        if sync_handler::handle_unban_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::CreateLabel { server_id, name, color, access } => {
                        let label_id = format!("lbl-{}", hex::encode(&{
                            let mut buf = [0u8; 4];
                            getrandom::fill(&mut buf).expect("RNG");
                            buf
                        }));
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelCreated { label_id, name, color, access },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    // Delete/update/assign/unassign can all shift who qualifies
                    // for a label-gated channel — reconcile subgroups after each
                    // (all channels: one label can gate many). Runs even on a
                    // permission-denied handler result, matching the ChangeRole
                    // precedent (reconcile is coordinator-gated + idempotent).
                    NodeCommand::DeleteLabel { server_id, label_id } => {
                        let sid = server_id.clone();
                        let handled = sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelDeleted { label_id },
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, None,
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::UpdateLabel { server_id, label_id, name, color, access } => {
                        let sid = server_id.clone();
                        let handled = sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelUpdated { label_id, name, color, access: Some(access) },
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, None,
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::AssignLabel { server_id, label_id, peer_id } => {
                        let sid = server_id.clone();
                        let handled = sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelAssigned { label_id, peer_id },
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, None,
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::UnassignLabel { server_id, label_id, peer_id } => {
                        let sid = server_id.clone();
                        let handled = sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelUnassigned { label_id, peer_id },
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, None,
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::AddServerEmote { server_id, name, hash, animated } => {
                        if sync_handler::handle_emote_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::EmojiAdded { name, hash, animated },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RemoveServerEmote { server_id, name } => {
                        if sync_handler::handle_emote_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::EmojiRemoved { name },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::AddServerSticker { server_id, hash, name, pack, animated, w, h } => {
                        if sync_handler::handle_emote_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::StickerAdded { hash, name, pack, animated, w, h },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RemoveServerSticker { server_id, hash } => {
                        if sync_handler::handle_emote_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::StickerRemoved { hash },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RequestEmotes { hashes, kind, server_id, peer_hint } => {
                        emotes::handle_request_emotes(
                            &ws_cmd_tx, &ws_room_peers, &mut requested_asset_kinds,
                            hashes, kind, server_id, peer_hint, &local_peer_str,
                            &db_path, &db_passphrase,
                        );
                    }

                    NodeCommand::SetChannelVisibility { server_id, channel_id, visibility } => {
                        let sid = server_id.clone();
                        let cid = channel_id.clone();
                        let handled = sync_handler::handle_set_channel_visibility(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, visibility,
                            &crypto_store, &crdt_store,
                        ).await;
                        // If the channel became restricted, populate its subgroup
                        // (create + pull qualifying members' KeyPackages). Teardown of
                        // a now-Everyone channel already happened inside the handler.
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, Some(&cid),
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::SetChannelPosting { server_id, channel_id, posting } => {
                        if sync_handler::handle_set_channel_posting(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, posting,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelPublic { server_id, channel_id, is_public } => {
                        if sync_handler::handle_set_channel_public(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, is_public,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::GetServerStateSnapshot { server_id, reply } => {
                        // Live read of the ENFORCING copy — see the variant doc.
                        // A dropped receiver (FFI timeout) is fine to ignore.
                        let _ = reply.send(server_states.get(&server_id).cloned());
                    }

                    NodeCommand::MuteMember { server_id, peer_id, expires_at } => {
                        if sync_handler::handle_mute_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, peer_id, expires_at,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnmuteMember { server_id, peer_id } => {
                        if sync_handler::handle_unmute_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelSlowMode { server_id, channel_id, seconds } => {
                        if sync_handler::handle_set_channel_slow_mode(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, seconds,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelVisibilityLabels { server_id, channel_id, labels } => {
                        let sid = server_id.clone();
                        let cid = channel_id.clone();
                        let handled = sync_handler::handle_set_channel_visibility_labels(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, labels,
                            &crypto_store, &crdt_store,
                        ).await;
                        // A gated channel needs its subgroup populated with the
                        // label holders (and pruned of everyone else).
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, Some(&cid),
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::SetChannelPostingLabels { server_id, channel_id, labels } => {
                        // Posting never affects subgrouping — no reconcile.
                        if sync_handler::handle_set_channel_posting_labels(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, labels,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::GrantChannelAccess { server_id, channel_id, peer_id, expires_at } => {
                        let sid = server_id.clone();
                        let cid = channel_id.clone();
                        let handled = sync_handler::handle_grant_channel_access(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, peer_id, expires_at,
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, Some(&cid),
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::RevokeChannelAccess { server_id, channel_id, peer_id } => {
                        let sid = server_id.clone();
                        let cid = channel_id.clone();
                        let handled = sync_handler::handle_revoke_channel_access(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await;
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, Some(&cid),
                            );
                        }
                        if handled { continue; }
                    }

                    NodeCommand::SetChannelMediaOnly { server_id, channel_id, media_only } => {
                        if sync_handler::handle_set_channel_media_only(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &local_peer_str,
                            server_id, channel_id, media_only,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    // -- Guest sync commands (Public Channels Phase 3) --
                    NodeCommand::RequestPublicChannels { server_id } => {
                        hollow_log!("[HOLLOW-GUEST] RequestPublicChannels for {server_id}, is_member={}", server_states.contains_key(&server_id));
                        if server_states.contains_key(&server_id) {
                            let state = &server_states[&server_id];
                            let channels: Vec<PublicChannelEntryFfi> = state.channels.values()
                                .filter(|ch| ch.effective_public())
                                .map(|ch| PublicChannelEntryFfi {
                                    channel_id: ch.channel_id.clone(),
                                    name: ch.name.clone(),
                                    category: ch.category.clone(),
                                })
                                .collect();
                            hollow_log!("[HOLLOW-GUEST] Emitting {} public channels from local state", channels.len());
                            let local_avatar = state.settings.get("server_avatar")
                                .map(|reg| reg.read().clone())
                                .and_then(|b64| if b64.is_empty() { None } else {
                                    base64::engine::general_purpose::STANDARD.decode(&b64).ok()
                                });
                            let banner_thumb = super::assets::public_banner_thumb(state, &db_path, &db_passphrase);
                            let _ = event_tx.send(NetworkEvent::PublicChannelListReceived {
                                server_id: server_id.clone(),
                                server_name: state.name().to_string(),
                                channels,
                                server_avatar: local_avatar,
                                server_banner_thumb: banner_thumb,
                            }).await;
                        } else {
                            hollow_log!("[HOLLOW-GUEST] Not a member, joining room as guest: {server_id}");
                            guest_rooms.insert(server_id.clone());
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: server_id.clone() });
                            let msg = HavenMessage::PublicChannelListRequest { server_id: server_id.clone() };
                            if let Ok(data) = serde_json::to_vec(&msg) {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: server_id, data });
                            }
                        }
                    }

                    NodeCommand::RequestPublicChannelSync { server_id, channel_id, before_timestamp } => {
                        if server_states.contains_key(&server_id) {
                            // Already a member — serve from our own DB.
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                let limit = 50i32;
                                let messages_result = if let Some(before_ts) = before_timestamp {
                                    store.get_channel_messages_before(&server_id, &channel_id, before_ts, limit)
                                } else {
                                    // Initial request: LATEST messages, mirroring the
                                    // remote responder. `messages_since(0)` returned the
                                    // OLDEST 50, so an owner cold-starting into their own
                                    // public channel landed at the START of history (the
                                    // shared member store usually masked it — until the
                                    // member pane had loaded, the wrong window showed).
                                    store.get_channel_messages_before(&server_id, &channel_id, i64::MAX, limit)
                                };
                                if let Ok(msgs) = messages_result {
                                    let has_more = msgs.len() as i32 >= limit;
                                    let msg_ids: Vec<String> = msgs.iter().filter_map(|m| m.message_id.clone()).collect();
                                    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
                                    // File metadata for the cards — same batch
                                    // lookup the guest-serving responder does, so
                                    // the owner's preview equals the guest view.
                                    let file_ids: Vec<&str> = msgs.iter().filter_map(|m| m.file_id.as_deref()).collect();
                                    let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();
                                    let ffi_messages: Vec<GuestSyncMessageFfi> = msgs.iter().map(|m| {
                                        let reactions = m.message_id.as_ref()
                                            .and_then(|mid| reactions_map.get(mid))
                                            .map(|rs| rs.iter().map(|(e, p, ts, _sig, _pk)| GuestReactionFfi {
                                                emoji: e.clone(), peer_id: p.clone(), added_at: *ts,
                                            }).collect())
                                            .unwrap_or_default();
                                        let file_meta = m.file_id.as_deref()
                                            .and_then(|fid| file_meta_map.get(fid))
                                            .map(|f| GuestFileMetaFfi {
                                                file_id: f.file_id.clone(),
                                                file_name: f.file_name.clone(),
                                                file_ext: f.file_ext.clone(),
                                                mime_type: f.mime_type.clone(),
                                                size_bytes: f.size_bytes,
                                                is_image: f.is_image,
                                                width: f.width,
                                                height: f.height,
                                                // Our own disk — the owner preview
                                                // renders instantly, no peer fetch.
                                                disk_path: f.disk_path.clone()
                                                    .filter(|_| f.completed_at.is_some()),
                                            });
                                        GuestSyncMessageFfi {
                                            sender_id: m.sender_id.clone(),
                                            text: m.text.clone(),
                                            timestamp: m.timestamp,
                                            message_id: m.message_id.clone(),
                                            signature: m.signature.clone(),
                                            public_key: m.public_key.clone(),
                                            edited_at: m.edited_at,
                                            reply_to: m.reply_to_mid.clone(),
                                            hidden_at: m.hidden_at,
                                            reactions,
                                            file_meta,
                                            // Local branch: straight off our own
                                            // row, so the owner's preview shows
                                            // the same cards the guest view does.
                                            link_preview: m.link_preview.clone(),
                                        }
                                    }).collect();
                                    // Build sender profiles from local state
                                    // Priority: server nickname > profile display name > nothing
                                    let unique_senders: std::collections::HashSet<&str> = msgs.iter().map(|m| m.sender_id.as_str()).collect();
                                    let mut ffi_profiles = Vec::new();
                                    if let Some(state) = server_states.get(&server_id) {
                                        for sender in &unique_senders {
                                            let mut name = None;
                                            let nickname = state.get_nickname(sender);
                                            if !nickname.is_empty() {
                                                name = Some(nickname);
                                            } else if let Ok(Some(stored)) = store.load_profile_light(sender) {
                                                if !stored.display_name.is_empty() {
                                                    name = Some(stored.display_name);
                                                }
                                            }
                                            let avatar = store.load_avatar(sender).ok().flatten().and_then(|bytes| {
                                                crate::node::image_convert::process_sync_avatar(&bytes).ok()
                                            });
                                            ffi_profiles.push(SyncSenderProfileFfi { peer_id: sender.to_string(), name, avatar });
                                        }
                                    }
                                    hollow_log!("[HOLLOW-GUEST] Serving {} messages from local DB for {channel_id}", ffi_messages.len());
                                    let _ = event_tx.send(NetworkEvent::PublicChannelSyncReceived {
                                        server_id, channel_id, messages: ffi_messages, has_more, sender_profiles: ffi_profiles,
                                    }).await;
                                }
                            }
                        } else {
                            let msg = HavenMessage::PublicChannelSyncRequest {
                                server_id: server_id.clone(),
                                channel_id,
                                before_timestamp,
                            };
                            if let Ok(data) = serde_json::to_vec(&msg) {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: server_id, data });
                            }
                        }
                    }

                    NodeCommand::LeaveGuestRoom { server_id } => {
                        guest_rooms.remove(&server_id);
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom { room_code: server_id });
                    }

                    NodeCommand::SetNickname { server_id, peer_id, nickname } => {
                        if sync_handler::handle_set_nickname(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id, nickname,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetTwitchUsername { server_id, peer_id, twitch_username } => {
                        if sync_handler::handle_set_twitch_username(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id, twitch_username,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RequestChannelSync { server_id, channel_id } => {
                        if sync_handler::handle_request_channel_sync(
                            &server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            &mut channel_sync_sent, server_id, channel_id,
                            &crdt_store,
                            &db_path, &db_passphrase,
                        ).await { continue; }
                    }
                    NodeCommand::UpdateProfile { display_name, status, about_me, avatar_bytes, banner_bytes, twitch_username, showcase_board, showcase_assets, avatar_frame, avatar_anim, banner_anim } => {
                        social::handle_update_profile(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut mls, &server_states,
                            &crypto_store, &local_peer_str, &master_keypair, &device_peer_id,
                            display_name, status, about_me,
                            avatar_bytes, banner_bytes, is_invisible, twitch_username,
                            showcase_board, showcase_assets, avatar_frame,
                            avatar_anim, banner_anim,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::EditChannelMessage { server_id, channel_id, message_id, new_text } => {
                        message_ops::handle_edit_channel_message(
                            &mut olm, &crypto_store, &mut mls, &server_states,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, message_id, new_text,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::EditDmMessage { peer_id: peer_id_str, message_id, new_text } => {
                        message_ops::handle_edit_dm_message(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, message_id, new_text,
                            &db_path, &db_passphrase,
                        ).await;
                    }
                    NodeCommand::AttachChannelLinkPreview { server_id, channel_id, message_id, preview } => {
                        message_ops::handle_attach_channel_link_preview(
                            &mut olm, &crypto_store, &mut mls, &server_states, &event_tx,
                            &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, message_id, preview,
                            &db_path, &db_passphrase,
                        ).await;
                    }
                    NodeCommand::AttachDmLinkPreview { peer_id: peer_id_str, message_id, preview } => {
                        message_ops::handle_attach_dm_link_preview(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, message_id, preview,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::DeleteChannelMessage { server_id, channel_id, message_id } => {
                        message_ops::handle_delete_channel_message(
                            &mut olm, &crypto_store, &mut mls, &server_states,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, message_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::DeleteDmMessage { peer_id: peer_id_str, message_id } => {
                        message_ops::handle_delete_dm_message(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, message_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::AddChannelReaction { server_id, channel_id, message_id, emoji } => {
                        message_ops::handle_add_channel_reaction(
                            &mut olm, &crypto_store, &mut mls, &server_states,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, message_id, emoji,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::AddDmReaction { peer_id: peer_id_str, message_id, emoji } => {
                        message_ops::handle_add_dm_reaction(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, message_id, emoji,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RemoveChannelReaction { server_id, channel_id, message_id, emoji } => {
                        message_ops::handle_remove_channel_reaction(
                            &mut olm, &crypto_store, &mut mls, &server_states,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair, &pub_key_b64, &local_peer_str,
                            server_id, channel_id, message_id, emoji,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RemoveDmReaction { peer_id: peer_id_str, message_id, emoji } => {
                        message_ops::handle_remove_dm_reaction(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_keypair, &device_peer_id,
                            peer_id_str, message_id, emoji,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendFriendRequest { peer_id: peer_id_str } => {
                        social::handle_send_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_friend_requests,
                            &mut pending_friend_removals,
                            &local_peer_str, peer_id_str,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendFriendRequestByNickname { nickname } => {
                        pending_nickname_resolve = Some(nickname.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ResolveNickname { nickname });
                    }

                    NodeCommand::ClaimNickname { nickname } => {
                        // Send our MASTER id alongside: the relay returns it on
                        // resolve so strangers friend-request `inbox:{master}`
                        // (the room we listen on) instead of our device id.
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ClaimNickname {
                            nickname,
                            master: local_peer_str.to_string(),
                        });
                    }

                    NodeCommand::ReleaseNickname => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ReleaseNickname);
                    }

                    // -- Multi-device linking (Step 4) --
                    NodeCommand::ClaimLinkCode { code } => {
                        pending_link_code = Some(code.clone());
                        link_handler::handle_claim_link_code(&ws_cmd_tx, &code);
                    }
                    NodeCommand::ReleaseLinkCode => {
                        if let Some(code) = pending_link_code.take() {
                            link_handler::handle_release_link_code(&ws_cmd_tx, &code);
                        }
                    }
                    NodeCommand::ResolveLinkCode { code, include_vault, include_files } => {
                        pending_link_resolve = Some((code.clone(), include_vault, include_files));
                        link_handler::set_my_link_code(&code); // receiver: decrypts the blob
                        link_handler::handle_resolve_link_code(&ws_cmd_tx, &code);
                    }
                    NodeCommand::RequestLinkSnapshot { target_peer, include_vault, include_files } => {
                        link_handler::handle_request_link_snapshot(
                            &ws_cmd_tx, &ws_room_peers, &target_peer, include_vault, include_files,
                        );
                    }
                    NodeCommand::AcceptLinkPush { target_peer, include_vault, include_files } => {
                        // Code path: encrypt with the code WE claimed. Mnemonic path
                        // (no claimed code): the requester is a sibling sharing our
                        // master, so use the master id as the shared passphrase.
                        let code = match &pending_link_code {
                            Some(c) if !c.is_empty() => c.clone(),
                            _ => local_peer_str.to_string(),
                        };
                        link_handler::handle_accept_link_push(
                            &ws_cmd_tx, &ws_room_peers, &event_tx,
                            &target_peer, include_vault, include_files, &device_peer_id, &code,
                        ).await;
                    }
                    NodeCommand::DeclineLinkPush { target_peer } => {
                        send_message_to_peer(
                            &ws_cmd_tx, &ws_room_peers, &target_peer, HavenMessage::LinkDeclined,
                        );
                    }

                    NodeCommand::RegisterPushToken { token, platform } => {
                        push_token = Some((token.clone(), platform.clone()));
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::RegisterPushToken { token, platform });
                    }

                    NodeCommand::SetPushPrefs { prefs_json } => {
                        push_prefs = Some(prefs_json.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetPushPrefs { prefs_json });
                    }

                    NodeCommand::SetOfflineInbox { enabled, retention_secs } => {
                        // ws_client remembers the latest value and re-registers it
                        // on every reconnect (the relay registry is RAM-only).
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetOfflineBuffer {
                            enabled, retention_secs,
                        });
                    }

                    NodeCommand::ReportUser { target, category } => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ReportUser {
                            target, category,
                        });
                    }

                    NodeCommand::AcceptFriendRequest { peer_id: peer_id_str } => {
                        social::handle_accept_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &local_peer_str, &master_keypair, &device_peer_id, is_invisible,
                            peer_id_str,
                            &mut pending_friend_accepts,
                            &mut pending_friend_removals,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RejectFriendRequest { peer_id: peer_id_str } => {
                        social::handle_reject_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            peer_id_str,
                            &mut pending_friend_requests,
                            &mut pending_friend_accepts,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RemoveFriend { peer_id: peer_id_str } => {
                        social::handle_remove_friend(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            peer_id_str,
                            &mut pending_friend_removals,
                            &mut pending_friend_requests,
                            &mut pending_friend_accepts,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendTypingIndicator { server_id, channel_id } => {
                        if !is_invisible {
                            social::handle_send_typing_indicator(
                                &ws_cmd_tx, &ws_room_peers, &mut mls,
                                &server_states, &bundle_keypair, &crypto_store,
                                &local_peer_str, server_id, channel_id,
                            );
                        }
                    }

                    NodeCommand::SetInvisible { invisible } => {
                        social::handle_set_invisible(
                            &ws_cmd_tx, &ws_room_peers, &local_peer_str,
                            invisible, &mut is_invisible,
                        );
                    }

                    NodeCommand::SubscribeChannels { server_id, channel_ids } => {
                        hollow_log!("[HOLLOW-TOPIC] Subscribe room={server_id} topics={channel_ids:?}");
                        subscribed_channels.insert(server_id.clone(), channel_ids.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::Subscribe {
                            room_code: server_id.clone(),
                            topics: channel_ids.clone(),
                        });
                        // Relay offline catch-up on CHANNEL OPEN (safety net for
                        // the connect-time sweep): refresh the ring registration
                        // (covers channels created since anyone last registered)
                        // and replay any ring this connection hasn't pulled yet.
                        // Dedup-by-message_id makes a re-pull harmless.
                        // The watermark lookup is awaited on the CrdtStore actor,
                        // so gather the channel list and DROP the `server_states`
                        // borrow before crossing the await.
                        let fresh_channels: Vec<String> = match server_states.get(&server_id) {
                            Some(state) if state.relay_catchup_secs() > 0 => {
                                sync_handler::register_relay_catchup(&ws_cmd_tx, state, &server_id);
                                channel_ids
                                    .iter()
                                    .filter(|cid| {
                                        relay_catchup_done
                                            .insert((server_id.clone(), (*cid).clone()))
                                    })
                                    .cloned()
                                    .collect()
                            }
                            _ => Vec::new(),
                        };
                        if !fresh_channels.is_empty() {
                            let ages = sync_handler::catchup_watermark_ages(
                                &crdt_store, &server_id, fresh_channels,
                            ).await;
                            for (cid, max_age_secs) in ages {
                                hollow_log!("[HOLLOW-TOPIC] Catch-up request (channel open) {server_id}/{cid} max_age={max_age_secs}s");
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::TopicCatchup {
                                    room_code: server_id.clone(),
                                    channel_id: cid,
                                    max_age_secs,
                                });
                            }
                        }
                    }

                    NodeCommand::UpdateChannelLayout { server_id, layout_json } => {
                        if sync_handler::handle_update_channel_layout(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, layout_json,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::PinMessage { server_id, channel_id, message_id } => {
                        if sync_handler::handle_pin_message(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, channel_id, message_id,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnpinMessage { server_id, channel_id, message_id } => {
                        if sync_handler::handle_unpin_message(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, channel_id, message_id,
                            &crdt_store,
                        ).await { continue; }
                    }

                    // -- Storage pledge (Phase 4) --
                    NodeCommand::SetStoragePledge { server_id, pledge_bytes } => {
                        sync_handler::handle_set_storage_pledge(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, pledge_bytes,
                            &crdt_store,
                        ).await;
                    }

                    // -- Vault shard distribution (Phase 4) --
                    NodeCommand::VaultDownloadFile { server_id, content_id } => {
                        vault_ops::handle_vault_download_file(
                            &mut server_states, &mut pending_vault_downloads,
                            &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair,
                            server_id, content_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::VaultUploadFile(box_payload) => {
                        let VaultUploadFilePayload {
                            server_id, channel_id, file_name, mime_type, message_id,
                            ciphertext, aes_key, aes_nonce, original_size, content_id,
                        } = *box_payload;
                        vault_ops::handle_vault_upload_file(
                            &server_states, &event_tx, &ws_room_peers, &cmd_tx,
                            &local_peer_str,
                            server_id, channel_id, file_name, mime_type, message_id,
                            ciphertext, aes_key, aes_nonce, original_size, content_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    // Internal re-entry: erasure coding + local shard writes done
                    // on the blocking pool; resume distribution/broadcast.
                    NodeCommand::VaultUploadPrepared(box_payload) => {
                        let VaultUploadPreparedPayload {
                            server_id, channel_id, content_id, message_id, plan, fallback_info,
                        } = *box_payload;
                        vault_ops::handle_vault_upload_prepared(
                            &server_states, &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &webrtc_peers, &mut pending_webrtc_sends,
                            &local_peer_str,
                            server_id, channel_id, content_id, message_id, plan, fallback_info,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::DeleteVaultContent { server_id, content_id } => {
                        vault_ops::handle_delete_vault_content(
                            &server_states, &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &local_peer_str,
                            server_id, content_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RequestShardFromPeer { server_id, content_id, shard_index, shard_key, target_peer } => {
                        vault_ops::handle_request_shard_from_peer(
                            &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &bundle_keypair,
                            server_id, content_id, shard_index, shard_key, target_peer,
                        ).await;
                    }

                    NodeCommand::StoreShardOnPeer {
                        server_id, content_id, shard_index, shard_key,
                        k, m, total_data_size, storage_tier, data, target_peer,
                    } => {
                        vault_ops::handle_store_shard_on_peer(
                            &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &webrtc_peers, &mut pending_webrtc_sends,
                            &bundle_keypair, &local_peer_str,
                            server_id, content_id, shard_index, shard_key,
                            k, m, total_data_size, storage_tier, data, target_peer,
                        ).await;
                    }

                    // -- File sharing (Phase 3.5) --
                    NodeCommand::SendFile(box_payload) => {
                        let SendFilePayload { peer_id, server_id, channel_id, file_path, message_id, message_text, vthumb, override_width, override_height, share_ref, voice, poster } = *box_payload;
                        file_handler::handle_send_file(
                            peer_id, server_id, channel_id, file_path, message_id, message_text,
                            vthumb, override_width, override_height, share_ref, voice, poster,
                            &cmd_tx,
                            &event_tx, &server_states, &bundle_keypair, &device_keypair, &pub_key_b64, &local_peer_str,
                            &device_peer_id,
                            &mut olm, &crypto_store, &mut mls,
                            &ws_cmd_tx, &ws_room_peers, &webrtc_peers, &mut pending_webrtc_sends,
                            &peer_auto_dl,
                            &mut gossip_overlays,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    // Internal re-entry: image conversion finished on the blocking
                    // pool; resume the send at the store/fan-out steps.
                    NodeCommand::SendFileConverted(box_payload) => {
                        let SendFileConvertedPayload {
                            peer_id, server_id, channel_id, message_id, message_text,
                            vthumb, share_ref, original_name, is_image,
                            final_data, final_ext, width, height, thumb, voice,
                        } = *box_payload;
                        file_handler::finish_send_file(
                            peer_id, server_id, channel_id, message_id, message_text,
                            vthumb, share_ref, original_name, is_image,
                            final_data, final_ext, width, height, thumb, voice,
                            &event_tx, &server_states, &bundle_keypair, &device_keypair, &pub_key_b64, &local_peer_str,
                            &device_peer_id,
                            &mut olm, &crypto_store, &mut mls,
                            &ws_cmd_tx, &ws_room_peers, &webrtc_peers, &mut pending_webrtc_sends,
                            &peer_auto_dl,
                            &mut gossip_overlays,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    // Auto-download config changed (issue #41 pre-negotiation):
                    // re-advertise our per-conversation preference to every
                    // connected DM peer / sibling so senders adjust immediately.
                    NodeCommand::ReadvertiseAutoDlPref => {
                        file_handler::advertise_auto_dl_pref_to_all(
                            &ws_cmd_tx, &ws_room_peers, &local_peer_str, &device_peer_id,
                        );
                    }

                    NodeCommand::RequestFile { file_id, peer_id: peer_id_str, chunks } => {
                        // Explicit pull: the response header must pass the size
                        // cap and the auto-download gate (issue #41).
                        requested_file_receipts.insert(file_id.clone(), std::time::Instant::now());
                        declined_file_ids.remove(&file_id);
                        file_handler::handle_request_file(
                            file_id, peer_id_str, chunks,
                            &ws_cmd_tx, &ws_room_peers,
                            &pending_ws_transfers,
                            &server_states, &local_peer_str,
                            &db_path, &db_passphrase,
                        );
                    }

                    NodeCommand::RequestPublicFile { server_id, file_id, peer_hint } => {
                        // Guest download: pick ONE live room peer (hint first —
                        // usually the message sender; else any other peer, which
                        // may be another guest that simply won't answer — the UI
                        // retries). Mirrors the emote-rail peer pick.
                        let target = ws_room_peers.get(&server_id).and_then(|peers| {
                            peer_hint
                                .filter(|h| peers.contains(h))
                                .or_else(|| {
                                    peers.iter().find(|p| *p != &local_peer_str).cloned()
                                })
                        });
                        match target {
                            Some(t) => {
                                pending_public_file_requests.insert(
                                    file_id.clone(),
                                    (server_id.clone(), std::time::Instant::now()),
                                );
                                // The answering PublicFileHeader delegates into the
                                // shared header path — mark it explicitly requested
                                // so the auto-download gate lets it through.
                                requested_file_receipts.insert(file_id.clone(), std::time::Instant::now());
                                hollow_log!("[HOLLOW-GUEST] Requesting public file {file_id} in {server_id} from {t}");
                                super::crypto_handler::send_message_to_peer(
                                    &ws_cmd_tx, &ws_room_peers, &t,
                                    HavenMessage::FileRequest { file_id, chunks: Vec::new(), offset: 0 },
                                );
                            }
                            None => {
                                hollow_log!("[HOLLOW-GUEST] No room peer to serve public file {file_id} in {server_id}");
                            }
                        }
                    }

                    // -- WebRTC commands (Phase 5A) --
                    NodeCommand::WebRtcPeerConnected { peer_id } => {
                        voice_handler::handle_webrtc_peer_connected(
                            peer_id, &mut webrtc_peers, &mut gossip_overlays,
                        );
                    }
                    NodeCommand::WebRtcPeerDisconnected { peer_id } => {
                        voice_handler::handle_webrtc_peer_disconnected(
                            peer_id, &mut webrtc_peers, &mut gossip_overlays,
                        );
                    }
                    NodeCommand::WebRtcSharePeerConnected { peer_id } => {
                        super::share_handler::handle_share_peer_connected(
                            peer_id, &mut webrtc_share_peers,
                        );
                    }
                    NodeCommand::WebRtcSharePeerDisconnected { peer_id } => {
                        super::share_handler::handle_share_peer_disconnected(
                            peer_id, &mut webrtc_share_peers,
                        );
                    }
                    NodeCommand::WebRtcShareTransferFailed { transfer_id, peer_id, error } => {
                        super::share_handler::handle_share_transfer_failed(
                            transfer_id, peer_id, error, &mut webrtc_share_peers,
                        );
                    }
                    NodeCommand::WebRtcSendSignal { peer_id, signal_type, payload, conn_id } => {
                        voice_handler::handle_webrtc_send_signal(
                            peer_id, signal_type, payload, conn_id,
                            &ws_cmd_tx, &ws_room_peers,
                        );
                    }
                    NodeCommand::WebRtcTransferComplete { transfer_id, temp_path, sender_peer_id, kind, shard_index, chunk_index } => {
                        if kind == "share_chunk" {
                            // transfer_id is the share's root_hash hex.
                            super::share_handler::handle_webrtc_share_chunk_complete(
                                &mut share_registry, &bundle_keypair, &event_tx,
                                transfer_id, chunk_index, temp_path,
                            ).await;
                        } else if kind == "file" && declined_file_ids.contains(&transfer_id) {
                            // Auto-download gate (issue #41): discard pushed bytes
                            // for a declined file (see the BinaryDirect twin).
                            hollow_log!("[HOLLOW-FILE] Discarding declined pushed WebRTC transfer {transfer_id}");
                            let _ = std::fs::remove_file(&temp_path);
                            let _ = event_tx.send(NetworkEvent::FileFailed {
                                file_id: transfer_id.clone(),
                                error: "auto_download_off".to_string(),
                            }).await;
                        } else {
                            file_handler::handle_webrtc_transfer_complete(
                                transfer_id, temp_path, sender_peer_id, kind, shard_index,
                                &mut pending_file_streams, &mut pending_shard_streams,
                                &mut pending_vault_downloads, &mut early_file_streams,
                                &bundle_keypair, &event_tx,
                                &mut gossip_overlays, &webrtc_peers,
                                &ws_cmd_tx, &ws_room_peers,
                                &db_path, &db_passphrase,
                            ).await;
                        }
                    }
                    NodeCommand::WebRtcSendComplete { transfer_id } => {
                        file_handler::handle_webrtc_send_complete(
                            transfer_id, &mut pending_webrtc_sends,
                        );
                    }
                    NodeCommand::WebRtcTransferFailed { transfer_id, peer_id, error } => {
                        file_handler::handle_webrtc_transfer_failed(
                            transfer_id, peer_id, error,
                            &mut webrtc_peers, &mut pending_webrtc_sends,
                            &pending_file_streams, &mut early_file_streams,
                            &ws_cmd_tx, &ws_room_peers, &event_tx,
                        ).await;
                    }

                    // -- Voice call signaling (Phase 5B) --
                    NodeCommand::CallSendSignal { peer_id, signal_type, payload } => {
                        last_message_traffic = std::time::Instant::now();
                        voice_handler::handle_call_send_signal(
                            peer_id, signal_type, payload,
                            &ws_cmd_tx, &ws_room_peers,
                        );
                    }

                    // -- Voice channel commands (Phase 5C) --
                    NodeCommand::VoiceChannelJoin { server_id, channel_id } => {
                        voice_handler::handle_voice_channel_join(
                            server_id, channel_id,
                            &mut mls, &ws_cmd_tx, &ws_room_peers,
                            &server_states, &bundle_keypair, &crypto_store,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &gossip_overlays, &mut mls_epoch_hint_cooldown,
                            &local_peer_str, &device_peer_id, &event_tx,
                        ).await;
                    }

                    NodeCommand::VoiceChannelLeave { server_id, channel_id } => {
                        voice_handler::handle_voice_channel_leave(
                            server_id, channel_id,
                            &mut mls, &ws_cmd_tx, &ws_room_peers,
                            &server_states, &bundle_keypair, &crypto_store,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &gossip_overlays, &local_peer_str, &device_peer_id, &event_tx,
                        ).await;
                    }

                    NodeCommand::VoiceChannelSendSignal { server_id, channel_id, peer_id, signal_type, payload } => {
                        last_message_traffic = std::time::Instant::now();
                        voice_handler::handle_voice_channel_send_signal(
                            server_id, channel_id, peer_id, signal_type, payload,
                            &mut mls, &mut olm, &crypto_store,
                            &ws_cmd_tx, &ws_room_peers,
                            &server_states, &bundle_keypair,
                            &local_peer_str, &device_peer_id, &event_tx,
                        ).await;
                    }

                    NodeCommand::VoiceSframeHeal { server_id, channel_id, peer_id, escalate } => {
                        voice_handler::handle_voice_sframe_heal(
                            server_id, channel_id, peer_id, escalate,
                            &mut mls, &ws_cmd_tx, &ws_room_peers,
                            &server_states,
                            &mut pending_mls_removals,
                            &mut mls_bootstrap_requested,
                            &mut mls_epoch_hint_cooldown,
                            &crypto_store, &local_peer_str, &event_tx,
                        ).await;
                    }

                    // -- Media forwarder control plane (media forwarding step 3) --

                    NodeCommand::ForwarderSendSignal { forwarder_peer_id, signal_type, payload } => {
                        last_message_traffic = std::time::Instant::now();
                        // Phase 2: a signal addressed to OURSELVES is the peer
                        // forwarder's own display leg (viewer #0) — inject it
                        // straight into the embedded engine, no Olm round-trip.
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        if forwarder_peer_id == device_peer_id {
                            embedded_fwd.handle_self_signal(&signal_type, &payload, &cmd_tx);
                            continue;
                        }
                        forwarder_client::handle_forwarder_send_signal(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                            &mut pending_messages, &mut key_request_in_flight,
                            &device_keypair, &device_peer_id,
                            forwarder_peer_id, signal_type, payload,
                        ).await;
                    }

                    // Deliberately NOT NodeCommand::JoinRoom — that arm mutates
                    // `active_room` and fires `RoomCleared` (DM-conversation-pane
                    // semantics that would wipe the open chat). The fwd room is a
                    // pure transport join.
                    NodeCommand::JoinForwarderRoom { forwarder_peer_id } => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                            room_code: format!("fwd:{forwarder_peer_id}"),
                        });
                    }

                    NodeCommand::LeaveForwarderRoom { forwarder_peer_id } => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                            room_code: format!("fwd:{forwarder_peer_id}"),
                        });
                    }

                    // -- Embedded peer forwarder (media forwarding step 3 phase 2) --
                    // All three arms exist on every platform; the bodies are
                    // desktop-only no-ops elsewhere.
                    NodeCommand::SetPeerForwardingEnabled { enabled } => {
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        embedded_fwd.set_enabled(enabled, &ws_cmd_tx);
                        #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                        let _ = enabled;
                    }
                    NodeCommand::SetForwarderExpectation { origin_peer, kind, active } => {
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        embedded_fwd.set_expectation(origin_peer, kind, active, &ws_cmd_tx);
                        #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                        let _ = (origin_peer, kind, active);
                    }
                    NodeCommand::EmbeddedForwarderOut { to_peer, envelope_json, via_target_room } => {
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        super::embedded_forwarder::handle_engine_out(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                            &mut pending_messages, &mut key_request_in_flight,
                            &device_keypair, &device_peer_id,
                            to_peer, envelope_json, via_target_room,
                        ).await;
                        #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                        let _ = (to_peer, envelope_json, via_target_room);
                    }
                    NodeCommand::SetForwarderFeed { origin_peer, kind, stream, target_forwarder, active } => {
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        {
                            // Joining the target's room is what makes the feed
                            // offer deliverable (deterministic-room rule); we
                            // stay in it for the life of the feed.
                            if active {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                    room_code: format!("fwd:{target_forwarder}"),
                                });
                            } else {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                    room_code: format!("fwd:{target_forwarder}"),
                                });
                            }
                            embedded_fwd.set_feed(
                                Box::new(StreamOrigin { peer: origin_peer, kind, stream }),
                                target_forwarder,
                                active,
                                &cmd_tx,
                            );
                        }
                        #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                        let _ = (origin_peer, kind, stream, target_forwarder, active);
                    }

                    // -- Conference commands (node/conference.rs) --
                    NodeCommand::ConferenceStart { conf_id, waiting_room, access_code_hash, host_display_name, host_avatar_hash } => {
                        super::conference::handle_conference_start(
                            &mut conference_host, &mut mls, &crypto_store, &ws_cmd_tx,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            conf_id, waiting_room, access_code_hash,
                            host_display_name, host_avatar_hash,
                        );
                    }

                    NodeCommand::ConferenceEnd { conf_id } => {
                        super::conference::handle_conference_end(
                            &mut conference_host, &mut mls, &crypto_store, &ws_cmd_tx,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &conf_id,
                        );
                    }

                    NodeCommand::ConferenceRequestJoin { conf_id, display_name, avatar_hash, access_code } => {
                        super::conference::handle_conference_request_join(
                            &mut mls, &ws_cmd_tx,
                            conf_id, display_name, avatar_hash, access_code,
                        );
                    }

                    NodeCommand::ConferenceAdmit { conf_id, peer_id } => {
                        super::conference::handle_conference_admit(
                            &mut conference_host, &mut mls, &crypto_store,
                            &ws_cmd_tx, &event_tx,
                            &conf_id, &peer_id,
                        ).await;
                    }

                    NodeCommand::ConferenceDeny { conf_id, peer_id, reason } => {
                        super::conference::handle_conference_deny(
                            &mut conference_host, &ws_cmd_tx,
                            &conf_id, &peer_id, reason,
                        );
                    }

                    NodeCommand::ConferenceKick { conf_id, peer_id } => {
                        super::conference::handle_conference_kick(
                            &mut conference_host, &mut mls, &crypto_store,
                            &ws_cmd_tx, &event_tx,
                            &conf_id, &peer_id,
                        ).await;
                    }

                    NodeCommand::ConferenceLeave { conf_id } => {
                        super::conference::handle_conference_leave(
                            &ws_cmd_tx,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &conf_id,
                        );
                    }

                    NodeCommand::ConferenceSendChat { conf_id, text, timestamp } => {
                        last_message_traffic = std::time::Instant::now();
                        super::conference::handle_conference_send_chat(
                            &mut mls, &crypto_store, &ws_cmd_tx,
                            &conf_id, text, timestamp,
                        );
                    }

                    // -- Server join: coordinator window elapsed, ask everyone --
                    NodeCommand::RetryPendingJoin { server_id } => {
                        sync_handler::handle_retry_pending_join(
                            &pending_server_joins, &ws_cmd_tx, &ws_room_peers, server_id,
                        );
                    }

                    // -- Server join timeout --
                    NodeCommand::CheckPendingJoinTimeout { server_id } => {
                        sync_handler::handle_check_pending_join_timeout(
                            &mut pending_server_joins, &event_tx, &ws_cmd_tx,
                            server_id,
                            &crdt_store,
                        ).await;
                    }

                    // -- Gossip relay tree commands (Phase 5D) --
                    NodeCommand::WebRtcPingReport { peer_id, rtt_ms } => {
                        voice_handler::handle_webrtc_ping_report(
                            peer_id, rtt_ms, &mut gossip_overlays,
                        );
                    }

                    NodeCommand::WebRtcRouteReport { peer_id, is_direct } => {
                        voice_handler::handle_webrtc_route_report(
                            peer_id, is_direct, &mut gossip_overlays,
                        );
                    }

                    NodeCommand::WebRtcBroadcastReceived {
                        transfer_id: _, broadcast_id, ttl,
                        origin_peer_id, sender_peer_id,
                        temp_path, total_size,
                        kind, shard_index,
                    } => {
                        super::gossip_relay::handle_webrtc_broadcast_received(
                            &mut gossip_overlays, &event_tx, &webrtc_peers,
                            broadcast_id, ttl, origin_peer_id, sender_peer_id,
                            temp_path, total_size, kind, shard_index,
                        ).await;
                    }

                    NodeCommand::WebRtcGossipOpReceived { sender_peer_id, payload } => {
                        // Tier 2 (large-server scaling): a CRDT op arrived over the
                        // WebRTC mesh instead of the relay. Dedup by broadcast_id,
                        // then ingest through the EXACT same validated path as a
                        // relay CrdtOpBroadcast (op.author permission matrix, op_log
                        // dedup, ServerUpdated events, mesh re-flood on op-newness).
                        if let Some((server_id, op_json)) =
                            super::gossip_relay::accept_gossip_op(&mut gossip_overlays, &payload)
                        {
                            #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                            let fwd_bridge: FwdBridge = (&mut embedded_fwd, &cmd_tx);
                            #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                            let fwd_bridge: FwdBridge = std::marker::PhantomData;
                            handle_incoming_request(
                                &mut olm, &crypto_store, &crdt_store, &event_tx,
                                &mut pending_messages, &mut key_request_in_flight, &mut key_bundle_sent_to,
                                &mut server_states, &bundle_keypair,
                                &master_keypair, &device_keypair, &master_peer_str, &device_peer_id,
                                &mut pending_server_joins,
                                                                &mut join_request_seen,
                                &mut pending_sync_requests, &mut mls,
                                &mut mls_bootstrap_requested,
                                &mut pending_shard_assembly, &mut pending_file_streams,
                                &mut pending_shard_streams, &mut early_file_streams,
                                &mut pending_link_snapshots,
                                &mut decrypt_fail_cooldown,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                &mut mls_decrypt_failures,
                                &mut mls_epoch_hint_cooldown,
                                &ws_cmd_tx, &ws_room_peers,
                                &webrtc_peers, &mut pending_webrtc_sends,
                                &mut channel_sync_sent,
                                &mut gossip_overlays,
                                &mut voice_channel_participants,
                                &mut voice_channel_gossip_mode,
                                &mut conference_host,
                                &mut vc_signal_rate_tokens,
                                &mut mls_dirty,
                                &guest_rooms,
                                &subscribed_channels,
                                &db_path, &db_passphrase,
                                &local_peer_str, &sender_peer_id, is_invisible,
                                &mut link_snapshot_requested, &mut pending_sibling_challenges,
                                &mut pending_friend_accepts, &mut pending_friend_requests,
                                &mut pending_friend_removals,
                                &mut requested_asset_kinds,
                                &mut pending_public_file_requests,
                                &mut requested_file_receipts,
                                &mut declined_file_ids,
                                &mut peer_auto_dl,
                                fwd_bridge,
                                HavenMessage::CrdtOpBroadcast { server_id, op_json },
                            ).await;
                        }
                    }

                    // -- Recovery pool commands (Evidence Recovery) --
                    NodeCommand::InitiateRecoveryPool { server_id, token } => {
                        vault_ops::handle_initiate_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &local_peer_str,
                            server_id, token,
                            &db_path, &db_passphrase,
                        ).await;
                    }
                    NodeCommand::JoinRecoveryPool { server_id, token } => {
                        vault_ops::handle_join_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            &local_peer_str,
                            server_id, token,
                            &db_path, &db_passphrase,
                        ).await;
                    }
                    NodeCommand::StopRecoveryPool { server_id } => {
                        vault_ops::handle_stop_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx,
                            server_id,
                        ).await;
                    }

                    // ── Hollow Share (Phase 7A) ──
                    NodeCommand::ShareCreate { source_path } => {
                        super::share_handler::handle_command_share_create(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, source_path, false,
                        ).await;
                    }
                    NodeCommand::ShareCreateHidden { source_path } => {
                        super::share_handler::handle_command_share_create(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, source_path, true,
                        ).await;
                    }
                    NodeCommand::ShareOpenLink { link, server_id, context_type } => {
                        super::share_handler::handle_command_share_open_link(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, link, server_id, context_type,
                        ).await;
                    }
                    NodeCommand::ShareStart { root_hash, save_dir, link, sequential } => {
                        super::share_handler::handle_command_share_start(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, root_hash, save_dir, link, sequential,
                        ).await;
                    }
                    NodeCommand::ShareCancel { root_hash } => {
                        super::share_handler::handle_command_share_cancel(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, root_hash,
                        ).await;
                    }
                    NodeCommand::ShareSetSeeding { root_hash, seeding } => {
                        super::share_handler::handle_command_share_set_seeding(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, &event_tx, root_hash, seeding,
                        ).await;
                    }
                    NodeCommand::ShareRemove { root_hash, delete_file } => {
                        super::share_handler::handle_command_share_remove(
                            &mut share_registry, &bundle_keypair, &ws_cmd_tx, root_hash, delete_file,
                        ).await;
                    }
                    NodeCommand::ShareList => {
                        super::share_handler::handle_command_share_list(
                            &bundle_keypair, &mut share_registry, &event_tx,
                        ).await;
                    }

                    NodeCommand::NotifyShutdown => {
                        hollow_log!("[HOLLOW-SWARM] Notifying peers of shutdown");

                        // Unregister from signaling server so peers don't see us as online.
                        if let Some(room) = active_room.as_ref() {
                        }
                        for sid in server_states.keys() {
                        }
                    }

                    // TEST-ONLY: snapshot live in-memory MLS/Olm state for the
                    // multi-node harness (these managers are owned by this loop and
                    // are otherwise unreadable from a TestNode). Reads the SAME live
                    // state the production paths use — no persisted snapshot lag.
                    #[cfg(test)]
                    NodeCommand::DebugSnapshot { reply } => {
                        let mut snap = super::types::DebugSnapshotReply::default();
                        if let Some(ref mls_mgr) = mls {
                            for sid in mls_mgr.group_ids() {
                                snap.mls_members.insert(sid.clone(), mls_mgr.group_members(&sid));
                                if let Ok(ep) = mls_mgr.epoch(&sid) {
                                    snap.mls_epoch.insert(sid.clone(), ep);
                                }
                            }
                        }
                        for peer in olm.session_peer_ids() {
                            let status = if olm.has_confirmed_session(&peer) {
                                "confirmed"
                            } else if olm.has_unconfirmed_session(&peer) {
                                "unconfirmed"
                            } else {
                                "none"
                            };
                            snap.olm_sessions.insert(peer, status.to_string());
                        }
                        let _ = reply.send(snap);
                    }
                }
            }
            // -- WebSocket relay events --
            Some(ws_event) = ws_event_rx.recv() => {
                use super::ws_client::WsEvent;
                arm_started = Some(("ws", ws_event.kind(), std::time::Instant::now()));
                match ws_event {
                    WsEvent::Connecting { reconnecting } => {
                        let _ = event_tx.send(NetworkEvent::RelayConnecting { reconnecting }).await;
                    }
                    WsEvent::Connected => {
                        hollow_log!("[HOLLOW-WS] Relay connected — joining inbox + server + DM rooms");
                        // Pure UI signal — the room-join side effects below are
                        // unchanged. Tells Dart to show real "Connected".
                        let _ = event_tx.send(NetworkEvent::RelayConnected).await;
                        // TURN credentials over the authed socket (fresh set on
                        // every (re)connect; the 50-min timer below refreshes
                        // long-lived sessions before the 1h expiry).
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::GetTurnCredentials);
                        // Media forwarder discovery (step 3): static id, so
                        // reconnects are the only refresh needed — D5's
                        // fallback ladder corrects any staleness.
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::GetMediaForwarder);
                        // Phase 2: if we're serving as a peer forwarder, the
                        // relay forgot our fwd room on the reconnect — rejoin
                        // (media legs survive the signaling blip).
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        embedded_fwd.on_ws_connected(&ws_cmd_tx);
                        // Join personal inbox room (for receiving friend requests from strangers).
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                            room_code: format!("inbox:{}", local_peer_str),
                        });
                        // Auto-join rooms for all servers we're a member of.
                        for server_id in server_states.keys() {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: server_id.clone(),
                            });
                        }
                        // Auto-join DM rooms for all accepted friends.
                        {
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                if let Ok(friends) = store.load_friends(None) {
                                    let local_peer = local_peer_str.to_string();
                                    for (friend_pid, _, _, _, _) in &friends {
                                        let room = dm_room_code(&local_peer, friend_pid);
                                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                            room_code: room,
                                        });
                                    }
                                }
                            }
                        }
                        // Re-join guest rooms for public channel browsing.
                        for guest_sid in guest_rooms.iter() {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: guest_sid.clone(),
                            });
                            let msg = HavenMessage::PublicChannelListRequest {
                                server_id: guest_sid.clone(),
                            };
                            if let Ok(data) = serde_json::to_vec(&msg) {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                                    room_code: guest_sid.clone(),
                                    data,
                                });
                            }
                        }
                        // Verify local shard integrity on startup. Removes DB records
                        // for shards whose files are missing or corrupt.
                        //
                        // Gated on having servers: with none, the loop below has
                        // nothing to verify, yet opening a `ContentStore` (a SEPARATE
                        // SQLCipher connection that runs its own `PRAGMA key` page-1
                        // check) while the MessageStore/CrdtStore/CryptoStore
                        // connections are concurrently live raced the codec and
                        // logged a harmless `hmac check failed for pgno=1` on every
                        // connect. A node in ≥1 server has real shard data (page 1
                        // exists) so the legitimate open doesn't race.
                        if !server_states.is_empty() {
                            let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                            if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir) {
                                for server_id in server_states.keys() {
                                    if let Ok(bad_keys) = cs.verify_server_shards(server_id) {
                                        if !bad_keys.is_empty() {
                                            hollow_log!("[HOLLOW-VAULT] {} corrupt/missing shards in {server_id}, cleaning DB records", bad_keys.len());
                                            for key in &bad_keys {
                                                let _ = cs.delete_shard(server_id, key);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // Re-register push token + channel push prefs on reconnect.
                        if let Some((ref tok, ref plat)) = push_token {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::RegisterPushToken {
                                token: tok.clone(),
                                platform: plat.clone(),
                            });
                        }
                        if let Some(ref prefs) = push_prefs {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetPushPrefs {
                                prefs_json: prefs.clone(),
                            });
                        }
                    }

                    WsEvent::Disconnected => {
                        hollow_log!("[HOLLOW-WS] Relay disconnected — will auto-reconnect");
                        pending_nickname_resolve = None;
                        let _ = event_tx.send(NetworkEvent::RelayDisconnected).await;
                        ws_room_peers.clear();
                        synced_peers.clear();
                        requested_asset_kinds.clear();
                        pending_public_file_requests.clear();
                        // Explicit-pull receipts die with the socket (the pending
                        // request can't be answered on a new connection anyway);
                        // declined_file_ids intentionally survives — it reflects the
                        // auto-download setting, not connection state.
                        requested_file_receipts.clear();
                        // Advertised auto-download prefs are connection state:
                        // peers re-advertise on rejoin (issue #41 pre-negotiation).
                        peer_auto_dl.clear();
                        relay_catchup_done.clear();
                        key_request_in_flight.clear();
                        key_bundle_sent_to.clear();
                        mls_bootstrap_requested.clear();
                        mls_epoch_hint_cooldown.clear();
                        if !pending_messages.is_empty() {
                            hollow_log!("[HOLLOW-WS] Keeping {} pending message queues for delivery after reconnect", pending_messages.len());
                        }
                        // Clean up in-progress WS stream transfers.
                        // Resumption infrastructure exists (offset field in FileRequest,
                        // seek support in ws_stream_send) but transfer state is in-memory
                        // only — persistence needed for cross-restart resumption.
                        if !pending_ws_transfers.is_empty() {
                            hollow_log!("[HOLLOW-WS] Cleaning up {} in-progress WS transfers", pending_ws_transfers.len());
                            for (id, state) in pending_ws_transfers.drain() {
                                let _ = std::fs::remove_file(&state.temp_path);
                                hollow_log!("[HOLLOW-WS-STREAM] Abandoned transfer {id} due to disconnect");
                            }
                        }
                        // Remove all remote peers from voice channels (keep only self).
                        // On reconnect, PeerJoined re-broadcasts repopulate remote participants.
                        // Self is DEVICE-keyed (master kept as a legacy belt).
                        for participants in voice_channel_participants.values_mut() {
                            participants.retain(|p| *p == device_peer_id || *p == local_peer_str);
                        }
                        voice_channel_participants.retain(|_, p| !p.is_empty());
                        // Conference waiting rooms: knockers from the old socket can't
                        // receive a Welcome anymore — they re-knock on reconnect. Host
                        // meeting state itself survives (the conf room auto-rejoins).
                        for host_state in conference_host.values_mut() {
                            host_state.pending.clear();
                        }
                        voice_channel_gossip_mode.clear();
                        for overlay in gossip_overlays.values_mut() {
                            overlay.known_peers.clear();
                            overlay.neighbors.clear();
                            overlay.peer_scores.clear();
                            overlay.pending_relays.clear();
                        }
                    }
                    WsEvent::PeerJoined { room, peer_id } => {
                        hollow_log!("[HOLLOW-WS] Peer {peer_id} joined room {room}");
                        ws_room_peers.entry(room.clone()).or_default().insert(peer_id.clone());

                        // Media-forwarder control-plane room: run the MINIMAL path
                        // (Olm session + queued fwd envelope drain) and skip the whole
                        // discovery cascade. A forwarder discards every profile /
                        // sync / friend / MLS / DM frame we could send it, so the
                        // cascade was ~45 junk frames per join — pure join-burst
                        // bandwidth and journal noise at the forwarder, and the burst
                        // that used to drain the (now removed) fwd control-plane token
                        // bucket and eat the last large frame behind it.
                        //
                        // CRITICAL: this must NOT touch `synced_peers`. That set is
                        // GLOBAL, not per-room — inserting here would burn the `is_new`
                        // flag so a LATER join of a genuinely shared room would skip
                        // profile/sync forever (a silent discovery blackhole).
                        let is_fwd_room = is_forwarder_room(&room);
                        if is_fwd_room && peer_id != local_peer_str && peer_id != device_peer_id {
                            ensure_olm_session_and_drain(
                                &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                                &ws_room_peers, &mut pending_messages,
                                &mut key_request_in_flight, &device_keypair,
                                &device_peer_id, &peer_id, "PeerJoined(fwd)",
                            ).await;
                        }

                        // Conference: a peer appearing in a room we're still
                        // knocking on may be the HOST starting the meeting —
                        // re-send our join request (throttled, fresh KP).
                        if !is_fwd_room {
                            super::conference::reknock_if_pending(&mut mls, &ws_cmd_tx, &room);
                        }

                        // Recovery pool: when a peer joins our recovery room, send them our inventory.
                        if room.starts_with("recovery:") {
                            if let Some(pool) = recovery_pool_state.as_ref() {
                                if room == pool.room_code() && peer_id != local_peer_str && peer_id != device_peer_id {
                                    hollow_log!("[RECOVERY-POOL] Peer {peer_id} joined — sending our inventory");
                                    if let Some(our_inv) = pool.members.get(&local_peer_str) {
                                        let welcome = HavenMessage::RecoveryWelcome {
                                            manifest_ids: our_inv.manifest_ids.clone(),
                                            shard_inventory_json: serde_json::to_string(&our_inv.shards).unwrap_or_default(),
                                        };
                                        if let Ok(bytes) = serde_json::to_vec(&welcome) {
                                            let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendDirect {
                                                room_code: room.clone(),
                                                target_peer: peer_id.clone(),
                                                data: bytes,
                                            });
                                        }
                                    }
                                }
                            }
                        }

                        // Hollow Share: when a peer joins, immediately send our Have
                        // bitmap so they know we have chunks available.
                        if room.starts_with("share:") && peer_id != local_peer_str && peer_id != device_peer_id {
                            let root_hash = room.trim_start_matches("share:");
                            super::share_handler::broadcast_have(
                                &mut share_registry, &ws_cmd_tx, root_hash,
                            ).await;
                        }

                        // Trigger event-driven vault rebalance for this server room.
                        if server_states.contains_key(&room) {
                            rebalance_pending.insert(room.clone());
                        }

                        // Voice presence: tell a peer that just (re)appeared in this
                        // room which of its voice channels we are in.
                        //
                        // DELIBERATELY OUTSIDE the `is_new` guard below, which is
                        // where this used to live. `synced_peers` means "have we
                        // synced with this peer at all this session", and it is NOT
                        // cleared when a peer's socket dies: the relay only broadcasts
                        // PeerLeft for a CLEAN leave, so a peer that dropped and came
                        // back is `is_new == false` and skips the entire cascade. That
                        // is precisely the peer that needs this.
                        //
                        // Why it is load-bearing: `WsEvent::Disconnected` purges every
                        // REMOTE participant from `voice_channel_participants`, and
                        // that set gates EVERY inbound VC signal. Nothing else refills
                        // it, so the reconnecting side blackholes the offers its own
                        // peer is sending while its own requests still arrive.
                        // Field-caught 2026-08-27: the VM asked for a leg rebuild four
                        // times, the host dialed four times, and the VM dropped all
                        // four as `BLOCKED VC SDP offer from non-participant`.
                        //
                        // One small plaintext frame, idempotent at the receiver (a Set
                        // insert), and plaintext because a reconnecting peer's MLS
                        // epoch is very likely stale.
                        if !is_fwd_room && peer_id != local_peer_str && peer_id != device_peer_id {
                            for (vc_key, vc_peers) in voice_channel_participants.iter() {
                                if !vc_peers.contains(&device_peer_id)
                                    && !vc_peers.contains(&local_peer_str)
                                {
                                    continue;
                                }
                                // vc_key = "server_id:channel_id", and for a server
                                // voice channel the WS room code IS the server id.
                                let Some(colon) = vc_key.find(':') else { continue };
                                let (vc_sid, vc_cid) = (&vc_key[..colon], &vc_key[colon + 1..]);
                                if vc_sid != room { continue; }
                                hollow_log!("[HOLLOW-VC] Re-announcing our presence in {vc_cid} to {peer_id} (rejoined the room)");
                                // The room is KNOWN here, so send into it directly
                                // rather than through `ws_room_for_peer` (first-match
                                // is the silent one-way-loss trap).
                                super::crypto_handler::send_message_to_peer_in_room(
                                    &ws_cmd_tx, &room, &peer_id,
                                    HavenMessage::VoiceChannelJoin {
                                        server_id: vc_sid.to_string(),
                                        channel_id: vc_cid.to_string(),
                                    },
                                );
                            }
                        }

                            // Update gossip overlay: add this peer and maybe connect.
                            // Multi-device: the relay reports US under our DEVICE id, which
                            // differs from local_peer_str (= master). Exclude both, else a
                            // node key-exchanges / WebRTCs with its OWN device presence
                            // (endless MAC-mismatch re-key — the "VM fights itself" bug).
                            if peer_id != local_peer_str && peer_id != device_peer_id {
                                if let Some(overlay) = gossip_overlays.get_mut(&room) {
                                    if let Some(new_neighbor) = overlay.add_known_peer(&peer_id) {
                                        hollow_log!("[HOLLOW-GOSSIP] New neighbor {new_neighbor} joined server {room}");
                                        let _ = event_tx.send(NetworkEvent::GossipConnect { peer_id: new_neighbor }).await;
                                    }
                                }
                            }

                            if !is_fwd_room && peer_id != local_peer_str && peer_id != device_peer_id {

                                // Only trigger sync if not already synced this session
                                // (prevents duplicate sync when both WS and libp2p fire).
                                let is_new = synced_peers.insert(peer_id.clone());

                                let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: peer_id.clone(),
                                        addresses: vec!["ws-relay".to_string()],
                                    },
                                }).await;

                                // Drain pending friend requests for this peer. The request is
                                // keyed by the TARGET'S MASTER id (the friend-list/UI key), but
                                // the relay reports DEVICE ids in rooms — so match the joining
                                // device to a queued request by resolving device→master (a fresh
                                // target we've never linked resolves to itself, so a single-device
                                // peer still matches its own id). Deliver to the concrete device.
                                let pending_target = {
                                    let joined_master = super::resolver::resolve(&peer_id);
                                    if pending_friend_requests.contains_key(&peer_id) {
                                        Some(peer_id.clone())
                                    } else if pending_friend_requests.contains_key(&joined_master) {
                                        Some(joined_master)
                                    } else {
                                        None
                                    }
                                };
                                if let Some(target_key) = pending_target {
                                    if let Some(requested_at) = pending_friend_requests.remove(&target_key) {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared (target {target_key}), sending queued friend request");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, HavenMessage::FriendRequest { requested_at },
                                        );
                                        // Defense in depth: leave the target's inbox now that the
                                        // request is delivered (ordered after the send). Accept comes
                                        // back via the DM room, not the inbox.
                                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                            room_code: format!("inbox:{}", target_key),
                                        });
                                    }
                                }

                                // Drain pending friend removals for this peer. The
                                // tombstone is keyed by the friend's MASTER (the
                                // friend-list key), but the relay reports DEVICE ids
                                // — resolve the joining device→master to match (a
                                // single-device peer resolves to itself). Deliver the
                                // FriendRemove to the concrete device that appeared.
                                {
                                    let joined_master = super::resolver::resolve(&peer_id);
                                    let removal_key = if pending_friend_removals.contains(&peer_id) {
                                        Some(peer_id.clone())
                                    } else if pending_friend_removals.contains(&joined_master) {
                                        Some(joined_master)
                                    } else {
                                        None
                                    };
                                    if let Some(key) = removal_key {
                                        pending_friend_removals.remove(&key);
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared (master {key}), sending queued friend removal");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, HavenMessage::FriendRemove,
                                        );
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let _ = store.remove_friend(&key);
                                        }
                                    }
                                }

                                // (Re)deliver a queued FriendAccept to the requester. The
                                // accept can race the requester's DM-room join (it isn't in
                                // our room yet when we click Accept) or the requester may
                                // have been offline — so we send the FriendAccept to its
                                // device now that it has appeared. Idempotent (receiver
                                // re-saves "accepted"); the entry is removed on delivery so
                                // it fires at most once per friend per session.
                                {
                                    let joined_master = super::resolver::resolve(&peer_id);
                                    if (pending_friend_accepts.remove(&joined_master).is_some()
                                        || pending_friend_accepts.remove(&peer_id).is_some())
                                        && !super::blocklist::is_blocked(&peer_id)
                                    {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared (master {joined_master}), (re)sending FriendAccept");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, HavenMessage::FriendAccept,
                                        );
                                    }
                                }

                                if is_new {
                                    // Send our profile (with invisible flag) to the new peer.
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &local_peer_str, &master_keypair, &device_peer_id, &peer_id,
                                        is_invisible,
                                        &db_path, &db_passphrase,
                                    );

                                    // Auto-download pre-negotiation (issue #41): tell a
                                    // DM-room counterparty / our own sibling our effective
                                    // threshold so it can skip pushing bytes we'd discard.
                                    if super::resolver::same_identity(&peer_id, &local_peer_str)
                                        || room == dm_room_code(&local_peer_str, &super::resolver::resolve(&peer_id))
                                    {
                                        file_handler::advertise_auto_dl_pref_to_peer(
                                            &ws_cmd_tx, &ws_room_peers, &local_peer_str, &peer_id,
                                        );
                                    }

                                    // Multi-device (Phase 6): a peer in OUR OWN inbox room
                                    // (`inbox:{master}`) MIGHT be our own other device — but the
                                    // friend-request protocol makes a STRANGER (the requester) join
                                    // our inbox to deliver, so bare room membership is NOT proof
                                    // (that mis-merged strangers as siblings). Require a cryptographic
                                    // same-identity proof: a sibling we already resolve to ourselves
                                    // runs the convergence machinery directly; an UNPROVEN inbox peer
                                    // is challenged to sign a nonce with our SHARED MASTER key (only
                                    // a real sibling can) before any merge/resolver/snapshot.
                                    let own_inbox = format!("inbox:{}", local_peer_str);
                                    if room == own_inbox && peer_id != device_peer_id {
                                        if super::resolver::same_identity(&peer_id, &local_peer_str) {
                                            on_verified_sibling(
                                                &ws_cmd_tx, &ws_room_peers, &master_keypair,
                                                &device_peer_id, &local_peer_str, &server_states,
                                                &mut link_snapshot_requested, is_invisible,
                                                &db_path, &db_passphrase, &peer_id,
                                            );
                                        } else {
                                            issue_sibling_challenge(
                                                &ws_cmd_tx, &ws_room_peers,
                                                &mut pending_sibling_challenges, &peer_id,
                                            );
                                        }
                                    }

                                    // Olm session + queued-message drain. Shared verbatim with
                                    // the forwarder-room minimal path so the two can never
                                    // diverge on the signed-key-exchange rules.
                                    if ensure_olm_session_and_drain(
                                        &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                                        &ws_room_peers, &mut pending_messages,
                                        &mut key_request_in_flight, &device_keypair,
                                        &device_peer_id, &peer_id, "PeerJoined",
                                    ).await {
                                        sync_handler::flush_pending_sync_requests(
                                            &mut pending_sync_requests, &peer_id,
                                            &mut olm, &crypto_store,
                                            &bundle_keypair, &event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                                            &crdt_store,
                                            &db_path, &db_passphrase,
                                        ).await;
                                    }

                                    // CRDT sync + message sync for shared servers.
                                    // Members are master-keyed; `peer_id` is a DEVICE —
                                    // match by identity so a multi-device member's device
                                    // still triggers sync + MLS bootstrap.
                                    for (sid, state) in server_states.iter() {
                                        if state.members.keys().any(|k| super::resolver::same_identity(&peer_id, k)) {
                                            // CRDT state sync via MLS.
                                            let our_vector = StateVector::from_server_state(state);
                                            if let Ok(sv_json) = serde_json::to_string(&our_vector) {
                                                // Always use plaintext for post-reconnection SyncReq —
                                                // the peer's MLS epoch may be stale, causing silent decrypt failure.
                                                send_message_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    &peer_id, HavenMessage::SyncRequest {
                                                        server_id: sid.clone(),
                                                        state_vector_json: sv_json,
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                    },
                                                );
                                            }

                                            // Channel message sync via coordinator.
                                            {
                                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                                    let channels_ts: Vec<(String, i64)> = state.channels.keys()
                                                        .map(|cid| {
                                                            let ts = store
                                                                .get_latest_channel_timestamp(sid, cid)
                                                                .unwrap_or(None)
                                                                .unwrap_or(0);
                                                            (cid.clone(), ts)
                                                        })
                                                        .collect();
                                                    sync_coordinator.register_peer(sid, &peer_id, channels_ts);
                                                }
                                            }

                                            // MLS: request KeyPackage if we're the coordinator,
                                            // or send our own KeyPackage if we lost our group.
                                            if let Some(ref mls_mgr) = mls {
                                                if mls_mgr.has_group(sid) {
                                                    let mls_members = mls_mgr.group_members(sid);
                                                    if !mls_members.contains(&peer_id) {
                                                        if is_mls_coordinator(mls_mgr, sid, &local_peer_str, &ws_room_peers) {
                                                            send_message_to_peer(
                                                                &ws_cmd_tx, &ws_room_peers,
                                                                &peer_id, HavenMessage::MlsKeyPackageRequest {
                                                                    server_id: sid.clone(),
                                                                    channel_id: None,
                                                                },
                                                            );
                                                        }
                                                    }
                                                } else if !mls_bootstrap_requested.get(sid).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                                                    // We're a member but lost our MLS group — send
                                                    // KeyPackage to this peer for re-bootstrap.
                                                    hollow_log!("[HOLLOW-MLS] No group for {sid}, sending KeyPackage to {peer_id} for bootstrap (PeerJoined)");
                                                    if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                        send_message_to_peer(
                                                            &ws_cmd_tx, &ws_room_peers,
                                                            &peer_id, HavenMessage::MlsKeyPackage {
                                                                server_id: sid.clone(),
                                                                key_package: kp_b64,
                                                                channel_id: None,
                                                            },
                                                        );
                                                        mls_bootstrap_requested.insert(sid.clone(), std::time::Instant::now());
                                                    }
                                                }
                                            }

                                        }
                                    }

                                    // DM sync. High-water keyed by the friend's MASTER
                                    // (the conversation key), not the raw device id the
                                    // relay reported — else a multi-device friend's
                                    // timestamp lookup misses and we mis-page the sync.
                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let convo = super::resolver::resolve(&peer_id);
                                            // Multi-device peer-fallback: if WE have a
                                            // sibling, ask for BOTH directions from our
                                            // high-water-mark across both directions —
                                            // so a friend re-serves the messages we sent
                                            // from another (possibly-offline) device.
                                            let multi_device =
                                                !super::resolver::devices_for(&master_peer_str).is_empty();
                                            // Lookback overlap — mid-deduped
                                            // on receipt (watermark-gap heal).
                                            let since = (if multi_device {
                                                store.get_latest_dm_timestamp_any(&convo)
                                            } else {
                                                store.get_latest_dm_timestamp(&convo)
                                            }
                                            .unwrap_or(None)
                                            .unwrap_or(0)
                                                - crate::storage::messages::SYNC_LOOKBACK_MS)
                                                .max(0);
                                            send_message_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                &peer_id, HavenMessage::DmSyncRequest {
                                                    since_timestamp: since,
                                                    both_directions: multi_device,
                                                },
                                            );
                                        }
                                    }

                                }

                                // Send join request if this room matches a pending server join.
                                // Outside is_new guard — peer may already be synced from another room.
                                if pending_server_joins.contains_key(&room) {
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &peer_id, HavenMessage::ServerJoinRequest {
                                            server_id: room.clone(),
                                            twitch_proof_json: pending_server_joins.get(&room).and_then(|p| p.twitch_proof_json.clone()),
                                            nsfw_confirmed: pending_server_joins.get(&room).map(|p| p.nsfw_confirmed).unwrap_or(false),
                                        },
                                    );
                                    hollow_log!("[HOLLOW-CRDT] Sent pending join request to {peer_id} for {room}");
                                }

                                // DM-room co-presence re-key (outside is_new — the peer was
                                // already met in the inbox so is_new is false here). FIX for the
                                // friend-handshake Olm wedge: a friend-request requester joins
                                // the DM room, joins the target inbox to deliver, then LEAVES the
                                // inbox — and its DM-room join may not have reached the accepter's
                                // ws_room_peers yet when the accepter sends its KeyBundle reply.
                                // That bundle then targets a peer in NO shared room and is
                                // SILENTLY DROPPED (send_message_to_peer → ws_room_for_peer = None),
                                // so the lower-id side never builds an outbound session and the
                                // higher-id side defers forever (only the 30s sweep healed it).
                                // When the DURABLE DM room becomes mutually populated, re-issue a
                                // KeyRequest — bypassing the in-flight freshness gate, because a
                                // room transition is exactly the dropped-frame event the sweep was
                                // meant to catch, but at sub-second latency. KeyRequest is
                                // idempotent (the receiver rebuilds only a stale/unconfirmed half;
                                // a confirmed session under cooldown is preserved) and the
                                // device-vs-device glare tiebreaker still arbitrates who creates
                                // the outbound session. `local_peer_str` is the master, so this is
                                // the pure f(masters) DM room (resolver stays OUTSIDE dm_room_code).
                                // Siblings meet in inbox:{master}, never in dm_room_code(m,m), so
                                // this never fires for them; server members meet in the server
                                // room, not here; strangers/guests share neither → no key spam.
                                // Gate on `!has_session` (NO session object), not
                                // `!has_confirmed_session`: the wedged/deferred side holds no
                                // session at all, so this targets exactly it. A side that already
                                // built an unconfirmed OUTBOUND session has a handshake in flight —
                                // re-keying it would tear that down (the KeyRequest handler removes
                                // a held session) and cause needless glare churn. Skipping it lets
                                // the in-progress handshake finish; only the truly-stuck side kicks.
                                if !olm.has_session(&peer_id)
                                    && room == dm_room_code(&local_peer_str, &super::resolver::resolve(&peer_id))
                                {
                                    hollow_log!("[HOLLOW-CRYPTO] DM-room co-presence with {peer_id} and no session — re-keying (handshake-race heal)");
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &peer_id, signed_key_request(&device_keypair, &device_peer_id, &peer_id),
                                    );
                                    key_request_in_flight.insert(peer_id.clone(), std::time::Instant::now());
                                }
                            }
                    }
                    WsEvent::LeftRoom { room } => {
                        // WE left this room: purge its frozen member snapshot from
                        // the routing table. A self-left room receives no further
                        // PeerLeft/RoomMembers, so a stale entry lives forever and
                        // the flexible `ws_room_for_peer` first-match can route
                        // targeted sends into it — the relay then drops them
                        // (sender not in room), a silent one-way blackhole that
                        // persists until restart. Field-hit 2026-08-07 twice, both
                        // times right after a viewer's `fwd:` room detach: every
                        // later VC signal to the sharer vanished ("Connecting to
                        // screen share..." forever / lost screen_answer on revert).
                        if ws_room_peers.remove(&room).is_some() {
                            hollow_log!("[HOLLOW-WS] Left room {room} — purged its peer snapshot from routing");
                        }
                    }
                    WsEvent::PeerLeft { room, peer_id } => {
                        hollow_log!("[HOLLOW-WS] Peer {peer_id} left room {room}");
                        if let Some(peers) = ws_room_peers.get_mut(&room) {
                            peers.remove(&peer_id);
                            if peers.is_empty() {
                                ws_room_peers.remove(&room);
                            }
                        }

                        // Phase 2: presence lost in OUR fwd room — the peer's
                        // owned streams unregister, its egress legs detach
                        // (same semantics as the VPS forwarder's signaling).
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        if room == format!("fwd:{device_peer_id}") {
                            embedded_fwd.peer_gone(&peer_id);
                        }

                        // Drop any in-flight sibling-proof challenge for a peer that left
                        // our inbox (it'll be re-challenged on its next appearance).
                        pending_sibling_challenges.remove(&peer_id);

                        // Hollow Share: drop the peer from peer_have + free
                        // any in-flight chunk requests so the scheduler retries.
                        if room.starts_with("share:") {
                            super::share_handler::forget_peer(&mut share_registry, &peer_id);
                        }

                        // Conference waiting room: a knocker who left is no
                        // longer admittable (their Welcome would go nowhere).
                        super::conference::handle_peer_left_room(&mut conference_host, &room, &peer_id);
                        // Conference call roster: room presence is a prereq
                        // for call presence — drop the tile live.
                        super::conference::handle_conf_room_peer_gone(
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &event_tx, &room, &peer_id,
                        ).await;

                        // Recovery pool: track member departure.
                        if room.starts_with("recovery:") {
                            if let Some(pool) = recovery_pool_state.as_mut() {
                                if room == pool.room_code() && peer_id != local_peer_str {
                                    hollow_log!("[RECOVERY-POOL] Peer {peer_id} left pool");
                                    pool.remove_member(&peer_id);
                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberLeft {
                                        server_id: pool.server_id.clone(),
                                        peer_id: peer_id.clone(),
                                    }).await;
                                    // Update status.
                                    let status = pool.compute_status();
                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolStatus {
                                        server_id: pool.server_id.clone(),
                                        total_files: status.total_files,
                                        reconstructable: status.reconstructable,
                                        partial: status.partial,
                                        no_shards: status.no_shards,
                                        progress_pct: status.progress_pct,
                                    }).await;
                                }
                            }
                        }

                        // Trigger event-driven vault rebalance — peer leaving may cause under-replication.
                        if server_states.contains_key(&room) {
                            rebalance_pending.insert(room.clone());
                        }

                        // Update gossip overlay: remove peer and pick replacement if needed.
                        if let Some(overlay) = gossip_overlays.get_mut(&room) {
                            let (was_neighbor, replacement) = overlay.remove_known_peer(&peer_id);
                            if was_neighbor {
                                hollow_log!("[HOLLOW-GOSSIP] Neighbor {peer_id} left server {room}");
                                if let Some(repl) = replacement {
                                    hollow_log!("[HOLLOW-GOSSIP] Replacement neighbor: {repl}");
                                    let _ = event_tx.send(NetworkEvent::GossipConnect { peer_id: repl }).await;
                                }
                            }
                        }
                        // Clean up voice channel participants for this peer in this server room.
                        let vc_prefix = format!("{}:", room);
                        let vc_left: Vec<(String, String)> = voice_channel_participants.iter()
                            .filter(|(k, v)| k.starts_with(&vc_prefix) && v.contains(&peer_id))
                            .map(|(k, _)| {
                                let cid = &k[vc_prefix.len()..];
                                (room.clone(), cid.to_string())
                            })
                            .collect();
                        for (sid, cid) in &vc_left {
                            let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
                                server_id: sid.clone(),
                                channel_id: cid.clone(),
                                peer_id: peer_id.clone(),
                                is_self: false,
                            }).await;
                        }
                        voice_channel_participants.retain(|vc_key, participants| {
                            if vc_key.starts_with(&vc_prefix) {
                                participants.remove(&peer_id);
                                if participants.is_empty() {
                                    voice_channel_gossip_mode.remove(vc_key);
                                    return false;
                                }
                            }
                            true
                        });

                        // Only emit disconnect if peer is no longer reachable via any WS room.
                        let still_rooms: Vec<String> = ws_room_peers.iter()
                            .filter(|(_, ps)| ps.contains(&peer_id))
                            .map(|(r, _)| r.clone())
                            .collect();
                        if still_rooms.is_empty() {
                            synced_peers.remove(&peer_id);
                            let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                                peer_id: peer_id.clone(),
                            }).await;
                        } else {
                            // The peer may be genuinely in those rooms — or they
                            // may be STALE entries from a previous connection of
                            // theirs (the relay never sends PeerLeft for rooms a
                            // dead connection abandoned earlier). Re-join those
                            // rooms: the relay answers with a fresh RoomMembers
                            // snapshot, and the RoomMembers handler purges the
                            // peer + emits the disconnect if they're truly gone.
                            hollow_log!("[HOLLOW-WS] Peer {peer_id} still listed in {} room(s) {:?} — refreshing membership", still_rooms.len(), still_rooms);
                            for r in still_rooms {
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                    room_code: r,
                                });
                            }
                        }
                    }
                    WsEvent::RoomMembers { room, peers } => {
                        hollow_log!("[HOLLOW-WS] Room {room}: {} members", peers.len());
                        let local_peer = local_peer_str.to_string();
                        // Exclude BOTH our master (local_peer) and our DEVICE id: the relay
                        // lists us by our device id, so without this a node keeps its own
                        // presence in ws_room_peers and key-exchanges / sends profile to
                        // ITSELF (the "VM fights its own device id" loop).
                        let room_set: std::collections::HashSet<String> = peers.iter()
                            .filter(|p| *p != &local_peer && p.as_str() != device_peer_id)
                            .cloned()
                            .collect();
                        // RoomMembers is the relay's AUTHORITATIVE snapshot for
                        // this room — peers in our old set but missing from it
                        // are stale entries from a previous connection of
                        // theirs (the relay only broadcasts PeerLeft for rooms
                        // a connection is CURRENTLY in, so entries survive a
                        // peer's reconnect cycle and pin them "online" forever).
                        let vanished: Vec<String> = ws_room_peers.get(&room)
                            .map(|old| old.difference(&room_set).cloned().collect())
                            .unwrap_or_default();

                        // Media-forwarder control-plane room: presence bookkeeping
                        // (the authoritative snapshot + the vanished purge below)
                        // still runs — the embedded engine's tolerance depends on it —
                        // but the whole discovery cascade is skipped. See the
                        // PeerJoined arm for the rationale and the two "burn"
                        // hazards this must not touch (`synced_peers` there,
                        // `profile_broadcast_done` here).
                        let is_fwd_room = is_forwarder_room(&room);

                        if !is_fwd_room {
                            // Conference waiting room: sweep pending knockers
                            // against the authoritative snapshot (missed PeerLeft).
                            super::conference::retain_pending_in_room(&mut conference_host, &room, &room_set);
                            // Joiner side: peers already present when we (re)join a
                            // conf room we're knocking on — covers reconnects and
                            // "host already there" without waiting for a PeerJoined.
                            if !room_set.is_empty() {
                                super::conference::reknock_if_pending(&mut mls, &ws_cmd_tx, &room);
                            }
                        }
                        ws_room_peers.insert(room.clone(), room_set);
                        for gone in vanished {
                            // Phase 2: authoritative snapshot purged a peer
                            // from OUR fwd room (missed PeerLeft).
                            #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                            if room == format!("fwd:{device_peer_id}") {
                                embedded_fwd.peer_gone(&gone);
                            }
                            // Conference call roster: gone from the conf room
                            // (per the authoritative snapshot) = gone from the
                            // call, even if they still share other rooms.
                            super::conference::handle_conf_room_peer_gone(
                                &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                                &event_tx, &room, &gone,
                            ).await;
                            let still_ws = ws_room_peers.values().any(|ps| ps.contains(&gone));
                            if !still_ws {
                                hollow_log!("[HOLLOW-WS] Stale peer {gone} purged via RoomMembers refresh of {room} — emitting disconnect");
                                synced_peers.remove(&gone);
                                let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                                    peer_id: gone,
                                }).await;
                            }
                        }

                        // -- Gossip overlay: initialize or update for this server room --
                        // Check if this room corresponds to a server with 6+ members.
                        if let Some(state) = server_states.get(&room) {
                            if state.members.len() >= super::gossip::GOSSIP_ACTIVATION_THRESHOLD {
                                let overlay = gossip_overlays.entry(room.clone())
                                    .or_insert_with(|| super::gossip::GossipOverlay::new(room.clone()));
                                // Add all room members as known peers.
                                for pid in &peers {
                                    if pid != &local_peer && pid.as_str() != device_peer_id {
                                        overlay.add_known_peer(pid);
                                    }
                                }
                                // If no neighbors selected yet, do initial selection.
                                if overlay.neighbors.is_empty() {
                                    let total_webrtc = webrtc_peers.len();
                                    let initial = overlay.select_initial_neighbors(total_webrtc);
                                    for peer_id in initial {
                                        hollow_log!("[HOLLOW-GOSSIP] Initial neighbor: {peer_id} (server={})", room);
                                        let _ = event_tx.send(NetworkEvent::GossipConnect { peer_id }).await;
                                    }
                                }
                            }
                        }

                        // -- Relay offline catch-up (server-owner opt-in) --
                        // Once per connection per server room: refresh the relay's
                        // per-channel ring-buffer registration, then replay whatever
                        // buffered while nobody was online. Replayed frames arrive as
                        // ordinary topic messages (verify + dedup-by-message_id +
                        // CRDT merge — idempotent with peer sync). Runs even when the
                        // room has zero peers: that empty room is exactly the gap
                        // this feature closes.
                        // Gather the channel list first and drop the `server_states`
                        // borrow: the watermark lookup is awaited on the CrdtStore
                        // actor rather than opening a DB handle per channel here.
                        let fresh_channels: Vec<String> = match server_states.get(&room) {
                            Some(state) if state.relay_catchup_secs() > 0 => {
                                sync_handler::register_relay_catchup(&ws_cmd_tx, state, &room);
                                state
                                    .channels
                                    .values()
                                    .filter(|ch| {
                                        matches!(ch.channel_type, crate::crdt::server_state::ChannelType::Text)
                                            && state.can_see_channel(&local_peer, &ch.channel_id)
                                    })
                                    .map(|ch| ch.channel_id.clone())
                                    .filter(|cid| {
                                        relay_catchup_done.insert((room.clone(), cid.clone()))
                                    })
                                    .collect()
                            }
                            _ => Vec::new(),
                        };
                        if !fresh_channels.is_empty() {
                            let ages = sync_handler::catchup_watermark_ages(
                                &crdt_store, &room, fresh_channels,
                            ).await;
                            for (cid, max_age_secs) in ages {
                                hollow_log!("[HOLLOW-TOPIC] Catch-up request (connect) {room}/{cid} max_age={max_age_secs}s");
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::TopicCatchup {
                                    room_code: room.clone(),
                                    channel_id: cid,
                                    max_age_secs,
                                });
                            }
                        }

                        // Media-forwarder room: the ONE piece of the cascade the lane
                        // needs is an Olm session (+ the drain that delivers a queued
                        // fwd_stream_register). Everything below is skipped.
                        if is_fwd_room {
                            for pid_str in &peers {
                                if pid_str != &local_peer && pid_str.as_str() != device_peer_id {
                                    ensure_olm_session_and_drain(
                                        &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                                        &ws_room_peers, &mut pending_messages,
                                        &mut key_request_in_flight, &device_keypair,
                                        &device_peer_id, pid_str, "RoomMembers(fwd)",
                                    ).await;
                                }
                            }
                        }

                        // On first RoomMembers, broadcast our profile to all rooms.
                        // This ensures peers who were online while we were offline get our latest profile.
                        // NOT on a fwd room: that would BURN the one-shot flag on a
                        // forwarder that discards profiles, so real rooms never get it.
                        if !is_fwd_room && !profile_broadcast_done {
                            profile_broadcast_done = true;
                            hollow_log!("[HOLLOW-PROFILE] First RoomMembers — broadcasting our profile");
                            // Send our profile to all peers in this room (not ourselves —
                            // exclude both master and device id).
                            for pid in &peers {
                                if pid != &local_peer && pid.as_str() != device_peer_id {
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &local_peer_str, &master_keypair, &device_peer_id, pid,
                                        is_invisible,
                                        &db_path, &db_passphrase,
                                    );
                                }
                            }
                        }

                        // Pre-compute StateVectors once per server (reused across all peers).
                        // Skipped entirely for a fwd room — serializing every server's
                        // state vector for a peer that will never receive one is pure waste.
                        let sv_cache: std::collections::HashMap<&str, String> = if is_fwd_room {
                            std::collections::HashMap::new()
                        } else {
                            server_states.iter()
                                .filter_map(|(sid, state)| {
                                    let sv = StateVector::from_server_state(state);
                                    serde_json::to_string(&sv).ok().map(|json| (sid.as_str(), json))
                                })
                                .collect()
                        };

                        for pid_str in &peers {
                            if !is_fwd_room && pid_str != &local_peer && pid_str.as_str() != device_peer_id {
                                let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: pid_str.clone(),
                                        addresses: vec!["ws-relay".to_string()],
                                    },
                                }).await;

                                // Trigger CRDT sync for existing room members (RoomMembers fires
                                // on join with all current members, before individual PeerJoined).
                                let is_new = synced_peers.insert(pid_str.clone());
                                if is_new {
                                    // Send our profile (with invisible flag) so the peer sees our display name.
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &local_peer_str, &master_keypair, &device_peer_id, pid_str,
                                        is_invisible,
                                        &db_path, &db_passphrase,
                                    );

                                    // Auto-download pre-negotiation (issue #41) — the
                                    // RoomMembers twin of the PeerJoined advertise.
                                    if super::resolver::same_identity(pid_str, &local_peer_str)
                                        || room == dm_room_code(&local_peer_str, &super::resolver::resolve(pid_str))
                                    {
                                        file_handler::advertise_auto_dl_pref_to_peer(
                                            &ws_cmd_tx, &ws_room_peers, &local_peer_str, pid_str,
                                        );
                                    }

                                    // Request their profile if we don't have it.
                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            if let Ok(None) = store.load_profile(pid_str) {
                                                hollow_log!("[HOLLOW-PROFILE] No profile for {pid_str} — sending ProfileRequest");
                                                send_message_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    pid_str, HavenMessage::ProfileRequest,
                                                );
                                            }
                                        }
                                    }

                                    // Ask this peer for profiles of offline server members we don't have.
                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let mut proxy_count = 0u32;
                                            for (_sid, state) in server_states.iter() {
                                                if !state.is_member(pid_str) { continue; }
                                                for (member_id, _) in state.members.iter() {
                                                    if proxy_count >= 10 { break; }
                                                    if member_id == pid_str { continue; }
                                                    if member_id == &local_peer_str { continue; }
                                                    // Skip online peers (direct ProfileRequest works).
                                                    let is_online = ws_room_peers.values()
                                                        .any(|peers| peers.contains(member_id.as_str()));
                                                    if is_online { continue; }
                                                    // Skip if we already have their profile.
                                                    if let Ok(Some(_)) = store.load_profile_light(member_id) {
                                                        continue;
                                                    }
                                                    hollow_log!("[HOLLOW-PROFILE] Requesting proxy profile for {member_id} from {pid_str}");
                                                    send_message_to_peer(
                                                        &ws_cmd_tx, &ws_room_peers,
                                                        pid_str, HavenMessage::ProfileRequestFor {
                                                            target_peer_id: member_id.clone(),
                                                        },
                                                    );
                                                    proxy_count += 1;
                                                }
                                                if proxy_count >= 10 { break; }
                                            }
                                        }
                                    }

                                    // Send CRDT SyncReq + channel message sync for servers shared with this peer.
                                    for (sid, state) in server_states.iter() {
                                        if state.is_member(pid_str) {
                                            if let Some(sv_json) = sv_cache.get(sid.as_str()) {
                                                send_message_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    pid_str, HavenMessage::SyncRequest {
                                                        server_id: sid.clone(),
                                                        state_vector_json: sv_json.clone(),
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                    },
                                                );
                                            }

                                            // Channel message sync via coordinator (same as PeerJoined).
                                            // Without this, the joining peer never probes for missed
                                            // channel messages and never gets MessageSyncCompleted.
                                            {
                                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                                    let channels_ts: Vec<(String, i64)> = state.channels.keys()
                                                        .map(|cid| {
                                                            let ts = store
                                                                .get_latest_channel_timestamp(sid, cid)
                                                                .unwrap_or(None)
                                                                .unwrap_or(0);
                                                            (cid.clone(), ts)
                                                        })
                                                        .collect();
                                                    sync_coordinator.register_peer(sid, pid_str, channels_ts);
                                                }
                                            }
                                        }
                                    }

                                    // MLS: if we lost our group for any shared server,
                                    // send KeyPackage to this peer for re-bootstrap.
                                    // Multi-device (Step 6): members are master-keyed;
                                    // `pid_str` is a device — match by identity.
                                    if let Some(ref mls_mgr) = mls {
                                        for (sid, srv_state) in server_states.iter() {
                                            if !srv_state.members.keys().any(|k| super::resolver::same_identity(pid_str, k)) { continue; }
                                            if mls_mgr.has_group(sid) { continue; }
                                            if mls_bootstrap_requested.get(sid.as_str()).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) { continue; }
                                            hollow_log!("[HOLLOW-MLS] No group for {sid}, sending KeyPackage to {pid_str} for bootstrap (RoomMembers)");
                                            if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                send_message_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    pid_str, HavenMessage::MlsKeyPackage {
                                                        server_id: sid.clone(),
                                                        key_package: kp_b64,
                                                        channel_id: None,
                                                    },
                                                );
                                                mls_bootstrap_requested.insert(sid.clone(), std::time::Instant::now());
                                            }
                                        }
                                    }

                                    // (Friend request / removal / accept drains MOVED out of the
                                    // is_new guard — see below, after the block closes. A re-add to
                                    // an ALREADY-SYNCED peer (device already in synced_peers from a
                                    // prior friendship) produced is_new=false here, so the queued
                                    // re-add FriendRequest never drained and the peer never saw it.)

                                    // Multi-device sibling convergence on the RECONNECTING side.
                                    // RoomMembers fires on US (the device that just came back online)
                                    // and lists peers already there, so PeerJoined never fires for that
                                    // sibling on our side. THIS IS THE DIRECTIONAL HALF that matters for
                                    // a fresh mnemonic link: the new EMPTY device joins last → it learns
                                    // of the populated sibling via RoomMembers (not PeerJoined), and it
                                    // is the side that must PULL the snapshot. As with PeerJoined,
                                    // membership in `inbox:{master}` is NOT proof on its own (a stranger
                                    // delivering a friend request lands there too) — gate on a verified
                                    // same-identity proof. A proven sibling runs full convergence
                                    // (which re-announces our servers, idempotent); an unproven peer is
                                    // challenged to prove it holds our shared master key.
                                    {
                                        let own_inbox = format!("inbox:{}", local_peer_str);
                                        if room == own_inbox && pid_str.as_str() != device_peer_id {
                                            if super::resolver::same_identity(pid_str, &local_peer_str) {
                                                on_verified_sibling(
                                                    &ws_cmd_tx, &ws_room_peers, &master_keypair,
                                                    &device_peer_id, &local_peer_str, &server_states,
                                                    &mut link_snapshot_requested, is_invisible,
                                                    &db_path, &db_passphrase, pid_str,
                                                );
                                            } else {
                                                issue_sibling_challenge(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    &mut pending_sibling_challenges, pid_str,
                                                );
                                            }
                                        }
                                    }

                                    // Olm key exchange + pending_messages drain + DM sync.
                                    // RoomMembers fires on the JOINING peer (us) while PeerJoined
                                    // fires on the EXISTING peer (them). Without this, DM sync is
                                    // one-directional: they ask us, but we never ask them.
                                    if ensure_olm_session_and_drain(
                                        &mut olm, &crypto_store, &event_tx, &ws_cmd_tx,
                                        &ws_room_peers, &mut pending_messages,
                                        &mut key_request_in_flight, &device_keypair,
                                        &device_peer_id, pid_str, "RoomMembers",
                                    ).await {
                                        sync_handler::flush_pending_sync_requests(
                                            &mut pending_sync_requests, pid_str,
                                            &mut olm, &crypto_store,
                                            &bundle_keypair, &event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                                            &crdt_store,
                                            &db_path, &db_passphrase,
                                        ).await;
                                    }

                                    // DM sync: ask this peer for messages we missed.
                                    // High-water keyed by the peer's MASTER (conversation
                                    // key), not the raw device id (multi-device).
                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let convo = super::resolver::resolve(pid_str);
                                            // Multi-device peer-fallback (see PeerJoined
                                            // site): both directions from our both-way
                                            // high-water iff we have a sibling.
                                            let multi_device =
                                                !super::resolver::devices_for(&master_peer_str).is_empty();
                                            // Lookback overlap — mid-deduped
                                            // on receipt (watermark-gap heal).
                                            let since = (if multi_device {
                                                store.get_latest_dm_timestamp_any(&convo)
                                            } else {
                                                store.get_latest_dm_timestamp(&convo)
                                            }
                                            .unwrap_or(None)
                                            .unwrap_or(0)
                                                - crate::storage::messages::SYNC_LOOKBACK_MS)
                                                .max(0);
                                            send_message_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                pid_str, HavenMessage::DmSyncRequest {
                                                    since_timestamp: since,
                                                    both_directions: multi_device,
                                                },
                                            );
                                        }
                                    }

                                }

                                // Friend request / removal / accept drains — OUTSIDE the is_new
                                // guard. CRITICAL for RE-ADD while the peer stays ONLINE: the
                                // peer's device is already in `synced_peers` from the prior
                                // friendship, so the RoomMembers `is_new` was false and the queued
                                // re-add FriendRequest never drained — the peer never saw the new
                                // request (and, with the stale pending_friend_accepts now cleared on
                                // FriendRemove, it also no longer auto-accepts → it would see
                                // NOTHING). These drains are one-shot (`.remove()`), so running them
                                // on every RoomMembers for an already-synced peer is idempotent
                                // (no pending entry → no-op). Mirrors the PeerJoined drains, which
                                // already run unconditionally.
                                {
                                    let joined_master = super::resolver::resolve(pid_str);
                                    // Queued friend REQUEST (the re-add path).
                                    let req_key = if pending_friend_requests.contains_key(pid_str) {
                                        Some(pid_str.to_string())
                                    } else if pending_friend_requests.contains_key(&joined_master) {
                                        Some(joined_master.clone())
                                    } else {
                                        None
                                    };
                                    if let Some(target_key) = req_key {
                                        if let Some(requested_at) = pending_friend_requests.remove(&target_key) {
                                            hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers (target {target_key}), sending queued friend request");
                                            send_message_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                pid_str, HavenMessage::FriendRequest { requested_at },
                                            );
                                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                                room_code: format!("inbox:{}", target_key),
                                            });
                                        }
                                    }
                                    // Queued friend REMOVAL tombstone.
                                    let removal_key = if pending_friend_removals.contains(pid_str) {
                                        Some(pid_str.to_string())
                                    } else if pending_friend_removals.contains(&joined_master) {
                                        Some(joined_master.clone())
                                    } else {
                                        None
                                    };
                                    if let Some(key) = removal_key {
                                        pending_friend_removals.remove(&key);
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers (master {key}), sending queued friend removal");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            pid_str, HavenMessage::FriendRemove,
                                        );
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let _ = store.remove_friend(&key);
                                        }
                                    }
                                    // (Re)deliver a queued FriendAccept to the requester.
                                    if (pending_friend_accepts.remove(&joined_master).is_some()
                                        || pending_friend_accepts.remove(&pid_str.to_string()).is_some())
                                        && !super::blocklist::is_blocked(pid_str)
                                    {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers (master {joined_master}), (re)sending FriendAccept");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            pid_str, HavenMessage::FriendAccept,
                                        );
                                    }
                                }

                                // Send join request if this room matches a pending server join.
                                // Outside is_new guard — peer may already be in synced_peers
                                // from a DM room but we still need to send the join request.
                                if pending_server_joins.contains_key(&room) {
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        pid_str, HavenMessage::ServerJoinRequest {
                                            server_id: room.clone(),
                                            twitch_proof_json: pending_server_joins.get(&room).and_then(|p| p.twitch_proof_json.clone()),
                                            nsfw_confirmed: pending_server_joins.get(&room).map(|p| p.nsfw_confirmed).unwrap_or(false),
                                        },
                                    );
                                    hollow_log!("[HOLLOW-CRDT] Sent pending join request to {pid_str} for {room}");
                                }

                                // DM-room co-presence re-key (RoomMembers twin of the PeerJoined
                                // heal above — REQUIRED because, depending on join order, the
                                // wedged side may learn of the peer's DM-room entry via RoomMembers
                                // (it's the joiner) rather than PeerJoined (the incumbent). Same
                                // fix: when the durable DM room is mutually populated and we lack a
                                // confirmed session, re-issue a KeyRequest bypassing the freshness
                                // gate so a KeyBundle dropped during the inbox-leave race is retried
                                // promptly instead of waiting for the 30s sweep. See the PeerJoined
                                // arm for the full rationale (idempotent, antisymmetric, no sibling/
                                // server/guest regression; pure f(masters) DM room).
                                // See the PeerJoined arm: gate on `!has_session` so only the
                                // wedged/deferred side (which holds no session) kicks, not a side
                                // with an unconfirmed handshake already in flight.
                                if !olm.has_session(pid_str)
                                    && room == dm_room_code(&local_peer_str, &super::resolver::resolve(pid_str))
                                {
                                    hollow_log!("[HOLLOW-CRYPTO] DM-room co-presence (RoomMembers) with {pid_str} and no session — re-keying (handshake-race heal)");
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        pid_str, signed_key_request(&device_keypair, &device_peer_id, pid_str),
                                    );
                                    key_request_in_flight.insert(pid_str.clone(), std::time::Instant::now());
                                }
                            }
                        }
                    }
                    WsEvent::BinaryDirect { room: _, from, data } => {
                        if let Some(completed) = super::ws_stream_transfer::ws_stream_receive(
                            &mut pending_ws_transfers, &data,
                        ) {
                            // Auto-download gate (issue #41): the sender queues its
                            // push before our decline could ever reach it — bytes
                            // for a declined file are deleted here instead of being
                            // parked forever in early_file_streams.
                            if declined_file_ids.contains(&completed.id) {
                                hollow_log!("[HOLLOW-FILE] Discarding declined pushed stream {} ({} bytes)", completed.id, completed.size);
                                let _ = std::fs::remove_file(&completed.temp_path);
                                // Clear any transfer state the UI picked up from a
                                // progress tick that raced the decline — without
                                // this the bubble shows a spinner at 100% forever.
                                let _ = event_tx.send(NetworkEvent::FileFailed {
                                    file_id: completed.id.clone(),
                                    error: "auto_download_off".to_string(),
                                }).await;
                            } else {
                                file_handler::handle_completed_stream(
                                    completed,
                                    &from,
                                    &mut pending_file_streams,
                                    &mut pending_shard_streams,
                                    &mut pending_vault_downloads,
                                    &mut early_file_streams,
                                    &mut pending_link_snapshots,
                                    &bundle_keypair,
                                    &event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                    &db_path, &db_passphrase,
                                ).await;
                            }
                        }
                    }
                    WsEvent::LicenseError { reason } => {
                        hollow_log!("[HOLLOW-WS] License error: {reason}");
                        let _ = event_tx.send(NetworkEvent::LicenseError { reason }).await;
                    }
                    WsEvent::RoomBudgetUpdate { joined, limit } => {
                        let _ = event_tx.send(NetworkEvent::RoomBudgetUpdate { joined, limit }).await;
                    }
                    WsEvent::RoomCapHit { room } => {
                        hollow_log!("[HOLLOW] Room cap hit for room: {room}");
                        let _ = event_tx.send(NetworkEvent::RoomCapHit { room }).await;
                    }
                    WsEvent::PeerStatus { online, active_rooms: _ } => {
                        // Relay confirmed these friends are alive — re-join their
                        // DM + inbox rooms so we get RoomMembers → full state healing.
                        let local_peer = local_peer_str.to_string();
                        for peer_id in &online {
                            // `online` reports DEVICE ids; the DM room is master-paired
                            // (f(masters)) — resolve so we re-join the SAME room the
                            // friend is in (a device-keyed room would never match).
                            let dm_room = dm_room_code(&local_peer, &super::resolver::resolve(peer_id));
                            hollow_log!("[HOLLOW-WS] Liveness heal: {peer_id} is online, re-joining DM + inbox rooms");
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: dm_room,
                            });
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: format!("inbox:{}", local_peer),
                            });
                        }
                    }
                    WsEvent::DiscoveredPeers { room, peers } => {
                        // Peer discovery over the live WS connection (replaces HTTP
                        // /bootstrap). Populate ws_room_peers and proactively key-exchange
                        // with any peer we lack a confirmed session for — reusing the same
                        // freshness guard as the reconciliation sweep so a dropped frame
                        // self-heals. Mirrors the members-on-join flow for an explicit refresh.
                        hollow_log!("[HOLLOW-WS] Discovered {} peers in room {room}", peers.len());
                        let room_set = ws_room_peers.entry(room.clone()).or_default();
                        for pid in &peers {
                            // Exclude our own DEVICE id too (relay reports us by it,
                            // not by master = local_peer_str).
                            if *pid != local_peer_str && *pid != device_peer_id {
                                room_set.insert(pid.clone());
                            }
                        }
                        for pid in &peers {
                            if *pid == local_peer_str || *pid == device_peer_id { continue; }
                            if !olm.has_confirmed_session(pid)
                                && !key_request_is_fresh(&key_request_in_flight, pid)
                            {
                                hollow_log!("[HOLLOW-WS] DiscoveredPeers: key exchange for {pid}");
                                send_message_to_peer(&ws_cmd_tx, &ws_room_peers, pid, signed_key_request(&device_keypair, &device_peer_id, pid));
                                key_request_in_flight.insert(pid.clone(), std::time::Instant::now());
                            }
                        }
                    }
                    WsEvent::NicknameClaimed { nickname } => {
                        let _ = event_tx.send(NetworkEvent::NicknameClaimed { nickname }).await;
                    }
                    WsEvent::NicknameReleased => {
                        let _ = event_tx.send(NetworkEvent::NicknameReleased).await;
                    }
                    WsEvent::NicknameError { error, nickname } => {
                        if pending_nickname_resolve.as_deref() == Some(&nickname) {
                            pending_nickname_resolve = None;
                            let _ = event_tx.send(NetworkEvent::NicknameResolveFailed { nickname, error }).await;
                        } else {
                            let _ = event_tx.send(NetworkEvent::NicknameClaimFailed { error }).await;
                        }
                    }
                    WsEvent::NicknameResolved { nickname, peer_id, master_id } => {
                        if pending_nickname_resolve.as_deref() == Some(&nickname) {
                            pending_nickname_resolve = None;
                            // The relay binds a nickname to the claimer's WS-auth
                            // DEVICE id but also hands back the claimer's
                            // self-reported MASTER (`master_id`). Friendships key
                            // on the master AND delivery targets `inbox:{master}`
                            // — a device id has an inbox nobody joins, so a
                            // stranger's request queued under it never drained.
                            // Prefer master_id; fall back to the local resolver
                            // for old relays (cold resolver = identity, then the
                            // device-list ingest re-key repairs the row).
                            // SECURITY: master_id is self-reported by the claimer
                            // — use it ONLY as the friend-request target string,
                            // NEVER feed it into `resolver` (resolver mappings
                            // come only from master-signed device lists).
                            let target = if !master_id.is_empty() {
                                master_id
                            } else {
                                super::resolver::resolve(&peer_id)
                            };
                            social::handle_send_friend_request(
                                &event_tx, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_friend_requests,
                                &mut pending_friend_removals,
                                &local_peer_str, target,
                                &db_path, &db_passphrase,
                            ).await;
                        }
                    }
                    // TURN credentials from the authed relay socket → Dart's
                    // iceConfigProvider (replaces the HTTP fetch + its
                    // dead-chain-on-503 retry bug).
                    WsEvent::TurnCredentials { username, password, ttl, uris } => {
                        // Phase 2: the TURN URIs double as the embedded
                        // forwarder's STUN source for srflx discovery.
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        embedded_fwd.note_turn_uris(&uris);
                        let _ = event_tx.send(NetworkEvent::TurnCredentials {
                            username, password, ttl, uris,
                        }).await;
                    }
                    WsEvent::MediaForwarderInfo { peer_id, online } => {
                        let _ = event_tx.send(NetworkEvent::MediaForwarderInfo {
                            peer_id, online,
                        }).await;
                    }
                    // -- Multi-device link codes (Step 4) --
                    WsEvent::LinkCodeClaimed { code } => {
                        let _ = event_tx.send(NetworkEvent::LinkCodeClaimed { code }).await;
                    }
                    WsEvent::LinkCodeReleased => {
                        pending_link_code = None;
                    }
                    WsEvent::LinkCodeError { error, code } => {
                        // A resolve we initiated failing means the code was wrong/expired.
                        if pending_link_resolve.as_ref().map(|(c, _, _)| c.as_str()) == Some(code.as_str()) {
                            pending_link_resolve = None;
                        }
                        let _ = event_tx.send(NetworkEvent::LinkCodeError { error, code }).await;
                    }
                    WsEvent::LinkCodeResolved { code, peer_id } => {
                        if let Some((c, include_vault, include_files)) = pending_link_resolve.take() {
                            if c == code {
                                link_handler::handle_link_code_resolved(
                                    &ws_cmd_tx, &ws_room_peers, &peer_id, include_vault, include_files,
                                );
                            }
                        }
                    }
                    WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } => {
                        // Route incoming WS messages through the same handler as libp2p.
                        // A frame that dies here must SAY so with the sender tagged — the
                        // fwd-signal blackhole was only diagnosable from log absence on
                        // both ends (these payloads are always HavenMessage JSON; binary
                        // chunks ride 0x02 → BinaryDirect, so a failure here is abnormal).
                        let frame_len = data.len();
                        let utf8 = String::from_utf8(data);
                        if utf8.is_err() {
                            hollow_log!("[HOLLOW-SWARM] Inbound WS frame from {from} in {room} not UTF-8 ({frame_len} B) — dropped");
                        }
                        if let Ok(text) = utf8 {
                            let parsed = serde_json::from_str::<HavenMessage>(&text);
                            if let Err(ref e) = parsed {
                                hollow_log!("[HOLLOW-SWARM] Inbound WS frame from {from} ({frame_len} B) failed HavenMessage parse — dropped: {e}");
                            }
                            if let Ok(msg) = parsed {
                                    // Rate limiting (same as libp2p path).
                                    let rate_ok = {
                                        let (tokens, last_refill) = peer_rate_tokens
                                            .entry(from.clone())
                                            .or_insert((RATE_LIMIT_BURST, std::time::Instant::now()));
                                        let elapsed = last_refill.elapsed().as_secs_f64();
                                        let refill = (elapsed * RATE_LIMIT_REFILL as f64) as u32;
                                        if refill > 0 {
                                            *tokens = (*tokens + refill).min(RATE_LIMIT_BURST);
                                            *last_refill = std::time::Instant::now();
                                        }
                                        if *tokens == 0 {
                                            false
                                        } else {
                                            *tokens -= 1;
                                            true
                                        }
                                    };
                                    if !rate_ok {
                                        hollow_log!("[HOLLOW-SECURITY] Rate limited WS peer {from} — dropping message");
                                        continue;
                                    }

                                    // ── Recovery pool message interception ──
                                    // Handle recovery messages directly (plaintext, no Olm/MLS).
                                    let is_recovery = matches!(msg,
                                        HavenMessage::RecoveryHello { .. }
                                        | HavenMessage::RecoveryWelcome { .. }
                                        | HavenMessage::RecoveryManifestSync { .. }
                                        | HavenMessage::RecoveryTransferPlan { .. }
                                        | HavenMessage::RecoveryShardReceived { .. }
                                        | HavenMessage::RecoveryStatus { .. }
                                        | HavenMessage::RecoveryStop
                                    );
                                    if is_recovery {
                                        if let Some(pool) = recovery_pool_state.as_mut() {
                                            match msg {
                                                HavenMessage::RecoveryHello { server_id, manifest_ids, shard_inventory_json } => {
                                                    if server_id == pool.server_id {
                                                        hollow_log!("[RECOVERY-POOL] RecoveryHello from {from} — {} manifests", manifest_ids.len());
                                                        let shards: std::collections::HashMap<String, Vec<u16>> =
                                                            serde_json::from_str(&shard_inventory_json).unwrap_or_default();
                                                        let inventory = crate::node::recovery_pool::MemberInventory {
                                                            manifest_ids: manifest_ids.clone(),
                                                            shards,
                                                        };
                                                        pool.add_member(from.clone(), inventory);

                                                        // Reply with our own inventory as RecoveryWelcome.
                                                        if let Some(our_inv) = pool.members.get(&local_peer_str) {
                                                            let welcome = HavenMessage::RecoveryWelcome {
                                                                manifest_ids: our_inv.manifest_ids.clone(),
                                                                shard_inventory_json: serde_json::to_string(&our_inv.shards).unwrap_or_default(),
                                                            };
                                                            if let Ok(bytes) = serde_json::to_vec(&welcome) {
                                                                let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendDirect {
                                                                    room_code: pool.room_code(),
                                                                    target_peer: from.clone(),
                                                                    data: bytes,
                                                                });
                                                            }
                                                        }

                                                        let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberJoined {
                                                            server_id: pool.server_id.clone(),
                                                            peer_id: from.clone(),
                                                        }).await;

                                                        // Broadcast updated status.
                                                        let status = pool.compute_status();
                                                        let _ = event_tx.send(NetworkEvent::RecoveryPoolStatus {
                                                            server_id: pool.server_id.clone(),
                                                            total_files: status.total_files,
                                                            reconstructable: status.reconstructable,
                                                            partial: status.partial,
                                                            no_shards: status.no_shards,
                                                            progress_pct: status.progress_pct,
                                                        }).await;

                                                        // Coordinator election: if we're the lowest peer_id, compute and broadcast transfer plan.
                                                        if pool.is_coordinator() && pool.members.len() >= 2 {
                                                            let plan = pool.compute_transfer_plan();
                                                            if !plan.is_empty() {
                                                                hollow_log!("[RECOVERY-POOL] Coordinator: broadcasting transfer plan with {} assignments", plan.len());
                                                                let plan_json = serde_json::to_string(&plan).unwrap_or_default();
                                                                let msg = HavenMessage::RecoveryTransferPlan { plan_json };
                                                                if let Ok(bytes) = serde_json::to_vec(&msg) {
                                                                    let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendToRoom {
                                                                        room_code: pool.room_code(),
                                                                        data: bytes,
                                                                    });
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                HavenMessage::RecoveryWelcome { manifest_ids, shard_inventory_json } => {
                                                    hollow_log!("[RECOVERY-POOL] RecoveryWelcome from {from} — {} manifests", manifest_ids.len());
                                                    let shards: std::collections::HashMap<String, Vec<u16>> =
                                                        serde_json::from_str(&shard_inventory_json).unwrap_or_default();
                                                    let inventory = crate::node::recovery_pool::MemberInventory {
                                                        manifest_ids,
                                                        shards,
                                                    };
                                                    pool.add_member(from.clone(), inventory);

                                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberJoined {
                                                        server_id: pool.server_id.clone(),
                                                        peer_id: from.clone(),
                                                    }).await;

                                                    // Emit updated status with new member's data.
                                                    let status = pool.compute_status();
                                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolStatus {
                                                        server_id: pool.server_id.clone(),
                                                        total_files: status.total_files,
                                                        reconstructable: status.reconstructable,
                                                        partial: status.partial,
                                                        no_shards: status.no_shards,
                                                        progress_pct: status.progress_pct,
                                                    }).await;

                                                    // Coordinator election after welcome.
                                                    if pool.is_coordinator() && pool.members.len() >= 2 {
                                                        let plan = pool.compute_transfer_plan();
                                                        if !plan.is_empty() {
                                                            hollow_log!("[RECOVERY-POOL] Coordinator: broadcasting transfer plan with {} assignments", plan.len());
                                                            let plan_json = serde_json::to_string(&plan).unwrap_or_default();
                                                            let msg = HavenMessage::RecoveryTransferPlan { plan_json };
                                                            if let Ok(bytes) = serde_json::to_vec(&msg) {
                                                                let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendToRoom {
                                                                    room_code: pool.room_code(),
                                                                    data: bytes,
                                                                });
                                                            }
                                                        }
                                                    }
                                                }
                                                HavenMessage::RecoveryShardReceived { content_id, shard_index } => {
                                                    hollow_log!("[RECOVERY-POOL] ShardReceived: {content_id}:{shard_index} from {from}");
                                                    pool.mark_shard_received(&content_id, shard_index);

                                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolShardTransferred {
                                                        server_id: pool.server_id.clone(),
                                                        content_id,
                                                        shard_index,
                                                    }).await;
                                                }
                                                HavenMessage::RecoveryStatus { status_json } => {
                                                    if let Ok(status) = serde_json::from_str::<crate::node::recovery_pool::PoolStatus>(&status_json) {
                                                        let _ = event_tx.send(NetworkEvent::RecoveryPoolStatus {
                                                            server_id: pool.server_id.clone(),
                                                            total_files: status.total_files,
                                                            reconstructable: status.reconstructable,
                                                            partial: status.partial,
                                                            no_shards: status.no_shards,
                                                            progress_pct: status.progress_pct,
                                                        }).await;
                                                    }
                                                }
                                                HavenMessage::RecoveryStop => {
                                                    hollow_log!("[RECOVERY-POOL] Pool stopped by {from}");
                                                    let sid = pool.server_id.clone();
                                                    let room = pool.room_code();
                                                    recovery_pool_state = None;
                                                    let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::LeaveRoom {
                                                        room_code: room,
                                                    });
                                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolStopped {
                                                        server_id: sid,
                                                    }).await;
                                                }
                                                HavenMessage::RecoveryManifestSync { manifests_json } => {
                                                    hollow_log!("[RECOVERY-POOL] ManifestSync from {from}");
                                                    // Parse and merge manifests from coordinator.
                                                    if let Ok(manifests) = serde_json::from_str::<Vec<crate::vault::pipeline::VaultManifest>>(&manifests_json) {
                                                        for m in manifests {
                                                            if m.k > 0 || m.m > 0 {
                                                                pool.all_manifest_ids.insert(m.content_id.clone());
                                                                pool.file_k_values.insert(m.content_id.clone(), m.k);
                                                                pool.manifest_meta.insert(m.content_id.clone(), crate::node::recovery_pool::ManifestMeta {
                                                                    k: m.k,
                                                                    m: m.m,
                                                                    total_data_size: m.original_size,
                                                                    storage_tier: m.storage_tier.clone(),
                                                                    file_name: m.file_name.clone(),
                                                                });
                                                            }
                                                        }
                                                    }
                                                }
                                                HavenMessage::RecoveryTransferPlan { plan_json } => {
                                                    hollow_log!("[RECOVERY-POOL] TransferPlan from {from}");
                                                    if let Ok(plan) = serde_json::from_str::<Vec<crate::node::recovery_pool::TransferAssignment>>(&plan_json) {
                                                        hollow_log!("[RECOVERY-POOL] Processing {} transfer assignments", plan.len());

                                                        // Open ContentStore for shard I/O.
                                                        let vault_dir_r = crate::identity::data_dir().unwrap_or_default().join("vault");

                                                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir_r) {
                                                            for assignment in &plan {
                                                                // Register incoming shards we're expecting to receive.
                                                                if assignment.dest_peer == local_peer_str {
                                                                    if let Some(meta) = pool.manifest_meta.get(&assignment.content_id) {
                                                                        let key = format!("{}:{}", assignment.content_id, assignment.shard_index);
                                                                        let sk = crate::vault::content_store::shard_key(&assignment.content_id, assignment.shard_index);
                                                                        // Skip if we already have this shard locally.
                                                                        if cs.has_shard(&sk).unwrap_or(false) {
                                                                            continue;
                                                                        }
                                                                        pending_shard_streams.insert(key, PendingShardStream {
                                                                            server_id: pool.server_id.clone(),
                                                                            content_id: assignment.content_id.clone(),
                                                                            shard_index: assignment.shard_index,
                                                                            shard_key: sk,
                                                                            k: meta.k,
                                                                            m: meta.m,
                                                                            total_size: meta.total_data_size,
                                                                            tier: meta.storage_tier.clone(),
                                                                        });
                                                                        // Register for auto-reconstruction after shard arrives.
                                                                        pending_vault_downloads.entry(assignment.content_id.clone())
                                                                            .or_insert((pool.server_id.clone(), meta.k as usize, 0));
                                                                    }
                                                                }

                                                                // Send shards we have to peers that need them.
                                                                if assignment.source_peer == local_peer_str {
                                                                    let sk = crate::vault::content_store::shard_key(&assignment.content_id, assignment.shard_index);
                                                                    if let Ok(shard_bytes) = cs.read_shard_unchecked(&pool.server_id, &sk) {
                                                                        let temp_dir = std::env::temp_dir().join("hollow_recovery");
                                                                        let _ = std::fs::create_dir_all(&temp_dir);
                                                                        let temp_path = temp_dir.join(format!("{}_{}.shard",
                                                                            &assignment.content_id[..8.min(assignment.content_id.len())],
                                                                            assignment.shard_index));
                                                                        if std::fs::write(&temp_path, &shard_bytes).is_ok() {
                                                                            let total_size = shard_bytes.len() as u64;
                                                                            hollow_log!("[RECOVERY-POOL] Sending shard {}:{} ({} bytes) to {}",
                                                                                assignment.content_id, assignment.shard_index, total_size, assignment.dest_peer);
                                                                            crate::node::ws_stream_transfer::ws_stream_send(
                                                                                &ws_cmd_tx,
                                                                                &pool.room_code(),
                                                                                &assignment.dest_peer,
                                                                                &crate::node::ws_stream_transfer::StreamKind::Shard { shard_index: assignment.shard_index },
                                                                                &assignment.content_id,
                                                                                &temp_path,
                                                                                total_size,
                                                                                0,
                                                                            ).await;
                                                                            let _ = std::fs::remove_file(&temp_path);

                                                                            // Broadcast that this shard was sent.
                                                                            let received_msg = HavenMessage::RecoveryShardReceived {
                                                                                content_id: assignment.content_id.clone(),
                                                                                shard_index: assignment.shard_index,
                                                                            };
                                                                            if let Ok(bytes) = serde_json::to_vec(&received_msg) {
                                                                                let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendToRoom {
                                                                                    room_code: pool.room_code(),
                                                                                    data: bytes,
                                                                                });
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                _ => {}
                                            }
                                        }
                                        continue; // Don't pass to handle_incoming_request.
                                    }

                                    // ── Hollow Share message interception ──
                                    // Share envelopes ride HavenMessage (relay-room broadcast or
                                    // SendDirect within a share room), not MLS. Intercept before
                                    // Olm/MLS decryption attempts.
                                    let is_share = matches!(msg,
                                        HavenMessage::ShareManifestRequest { .. }
                                        | HavenMessage::ShareManifestResponse { .. }
                                        | HavenMessage::ShareHave { .. }
                                        | HavenMessage::ShareChunkRequest { .. }
                                        | HavenMessage::ShareChunkResponse { .. }
                                    );
                                    if is_share {
                                        match msg {
                                            HavenMessage::ShareManifestRequest { root_hash } => {
                                                super::share_handler::handle_envelope_share_manifest_request(
                                                    &mut share_registry, &ws_cmd_tx, &from, root_hash,
                                                ).await;
                                            }
                                            HavenMessage::ShareManifestResponse { root_hash, manifest_b64 } => {
                                                super::share_handler::handle_envelope_share_manifest_response(
                                                    &mut share_registry, &bundle_keypair, &event_tx, root_hash, manifest_b64,
                                                ).await;
                                            }
                                            HavenMessage::ShareHave { root_hash, bitmap_b64, chunk_count } => {
                                                super::share_handler::handle_envelope_share_have(
                                                    &mut share_registry, &from, root_hash, bitmap_b64, chunk_count,
                                                ).await;
                                            }
                                            HavenMessage::ShareChunkRequest { root_hash, indices } => {
                                                super::share_handler::handle_envelope_share_chunk_request(
                                                    &mut share_registry, &mut seed_budget, &bundle_keypair, &ws_cmd_tx,
                                                    &event_tx, &webrtc_share_peers, &from, root_hash, indices,
                                                ).await;
                                            }
                                            HavenMessage::ShareChunkResponse { root_hash, index, data_b64 } => {
                                                super::share_handler::handle_envelope_share_chunk_response(
                                                    &mut share_registry, &bundle_keypair, &event_tx, root_hash, index, data_b64,
                                                ).await;
                                            }
                                            _ => {}
                                        }
                                        continue;
                                    }

                                    #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                                    let fwd_bridge: FwdBridge = (&mut embedded_fwd, &cmd_tx);
                                    #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                                    let fwd_bridge: FwdBridge = std::marker::PhantomData;
                                    handle_incoming_request(
                                        &mut olm, &crypto_store, &crdt_store, &event_tx,
                                        &mut pending_messages, &mut key_request_in_flight, &mut key_bundle_sent_to,
                                        &mut server_states, &bundle_keypair,
                                        &master_keypair, &device_keypair, &master_peer_str, &device_peer_id,
                                        &mut pending_server_joins,
                                                                                &mut join_request_seen,
                                        &mut pending_sync_requests, &mut mls,
                                        &mut mls_bootstrap_requested,
                                        &mut pending_shard_assembly, &mut pending_file_streams,
                                        &mut pending_shard_streams, &mut early_file_streams,
                                        &mut pending_link_snapshots,
                                        &mut decrypt_fail_cooldown,
                                        &mut pending_mls_key_packages, &mut pending_mls_removals,
                                        &mut mls_decrypt_failures,
                                        &mut mls_epoch_hint_cooldown,
                                        &ws_cmd_tx, &ws_room_peers,
                                        &webrtc_peers, &mut pending_webrtc_sends,
                                        &mut channel_sync_sent,
                                        &mut gossip_overlays,
                                        &mut voice_channel_participants,
                                        &mut voice_channel_gossip_mode,
                                        &mut conference_host,
                                        &mut vc_signal_rate_tokens,
                                        &mut mls_dirty,
                                        &guest_rooms,
                                        &subscribed_channels,
                                        &db_path, &db_passphrase,
                                        &local_peer_str, &from, is_invisible,
                                        &mut link_snapshot_requested, &mut pending_sibling_challenges,
                                        &mut pending_friend_accepts, &mut pending_friend_requests,
                                        &mut pending_friend_removals,
                                        &mut requested_asset_kinds,
                                        &mut pending_public_file_requests,
                                        &mut requested_file_receipts,
                                        &mut declined_file_ids,
                                        &mut peer_auto_dl,
                                        fwd_bridge,
                                        msg,
                                    ).await;
                            } else {
                                hollow_log!("[HOLLOW-WS] Failed to parse HavenMessage from {from} in {room}");
                            }
                        }
                    }
                }
            }

            // MLS batch timer — process queued removals then additions (2 epochs max for N peers).
            _ = mls_batch_timer.tick() => {
                arm_started = Some(("timer", "mls_batch", std::time::Instant::now()));
                if let Some(ref mut mls_mgr) = mls {
                    // Phase 1: Batch removals (stale members + recovery re-adds) — single commit.
                    // Keys are MLS GROUP keys: a bare `server_id` (server-wide group)
                    // or `subgroup_id(server, channel)` (per-channel subgroup, Option B).
                    let removal_keys: Vec<String> = pending_mls_removals.keys().cloned().collect();
                    for group_key in removal_keys {
                        if let Some(peers_to_remove) = pending_mls_removals.remove(&group_key) {
                            if peers_to_remove.is_empty() { continue; }
                            let (server_id, channel_id) = crate::crypto::split_group_key(&group_key);
                            let unique: Vec<String> = {
                                let mut set = std::collections::HashSet::new();
                                peers_to_remove.into_iter().filter(|p| set.insert(p.clone())).collect()
                            };
                            let refs: Vec<&str> = unique.iter().map(|s| s.as_str()).collect();
                            hollow_log!("[HOLLOW-MLS] Batch-removing {} members from {group_key}: {:?}", refs.len(), refs);
                            match mls_mgr.remove_members_batch(&group_key, &refs) {
                                Ok(commit_bytes) => {
                                    if let Err(e) = mls_mgr.merge_pending_commit(&group_key) {
                                        hollow_log!("[HOLLOW-MLS] Failed to merge batch removal commit: {e}");
                                        continue;
                                    }
                                    persist_mls_state(mls_mgr, &crypto_store);
                                    // Rotate SFrame for remaining participants (forward
                                    // secrecy). For a restricted VOICE channel mid-call,
                                    // a demotion removal must re-key the voice cryptor so
                                    // the removed member can't decode further audio.
                                    if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                                        let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                                        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                            server_id: server_id.clone(), epoch, sframe_key,
                                            channel_id: channel_id.clone(),
                                        }).await;
                                    }
                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                    // Tier 1 (large-server scaling): ONE room broadcast
                                    // replaces the per-device SendDirect loop — the commit
                                    // bytes are identical for every recipient and the relay
                                    // fans out. Non-holders (subgroup non-qualifiers, the
                                    // removed devices) ignore it via has_group / the epoch
                                    // guard on the receive side.
                                    let commit_epoch = mls_mgr.epoch(&group_key).ok();
                                    crate::node::crypto_handler::broadcast_mls_commit(
                                        mls_mgr, &ws_cmd_tx, &server_id, channel_id.clone(),
                                        commit_b64, commit_epoch,
                                    );
                                }
                                Err(e) => hollow_log!("[HOLLOW-MLS] Batch removal failed for {group_key}: {e}"),
                            }
                        }
                    }

                    // Phase 2: Batch additions — single commit.
                    // Keys are MLS GROUP keys (bare server_id or subgroup_id).
                    let add_keys: Vec<String> = pending_mls_key_packages.keys().cloned().collect();
                    for group_key in add_keys {
                        if let Some(queued) = pending_mls_key_packages.remove(&group_key) {
                            if queued.is_empty() { continue; }
                            let (server_id, channel_id) = crate::crypto::split_group_key(&group_key);

                            // Deduplicate by peer_id — keep only the last KeyPackage per peer.
                            let mut deduped: HashMap<String, Vec<u8>> = HashMap::new();
                            for (peer_id, kp_bytes) in queued {
                                deduped.insert(peer_id, kp_bytes);
                            }
                            let queued: Vec<(String, Vec<u8>)> = deduped.into_iter().collect();
                            if queued.is_empty() { continue; }

                            hollow_log!("[HOLLOW-MLS] Processing batch of {} KeyPackages for {group_key}", queued.len());

                            match mls_mgr.add_members_batch(&group_key, &queued) {
                                Ok((commit_bytes, welcome_bytes, added_peers)) => {
                                    if let Err(e) = mls_mgr.merge_pending_commit(&group_key) {
                                        hollow_log!("[HOLLOW-MLS] Failed to merge batch commit: {e}");
                                        continue;
                                    }
                                    persist_mls_state(mls_mgr, &crypto_store);
                                    // Emit epoch change for SFrame key rotation. Voice
                                    // SFrame keys are derived per group key — a restricted
                                    // voice channel keys off its SUBGROUP, so a subgroup
                                    // add/remove must reach that channel's voice cryptor.
                                    if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                                        let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                                        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                            server_id: server_id.clone(), epoch, sframe_key,
                                            channel_id: channel_id.clone(),
                                        }).await;
                                    }

                                    let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(&welcome_bytes);
                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);

                                    // Send Welcome to all new joiners.
                                    let welcome_data = serde_json::to_vec(&HavenMessage::MlsWelcome {
                                        server_id: server_id.clone(),
                                        welcome: welcome_b64,
                                        channel_id: channel_id.clone(),
                                    }).unwrap_or_default();
                                    for peer_id_str in &added_peers {
                                            if peer_is_reachable(&ws_room_peers, peer_id_str) {
                                                send_raw_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    peer_id_str, welcome_data.clone(),
                                                );
                                            }
                                    }

                                    // Tier 1 (large-server scaling): broadcast the single
                                    // Commit to the whole server room in ONE frame instead
                                    // of the per-device SendDirect loop. Every existing
                                    // leaf (including our own siblings and a member's
                                    // already-joined sibling A when only sibling B was
                                    // just added) is in the room. The just-added devices
                                    // receive it too but skip it via the epoch guard —
                                    // their Welcome already lands them at this epoch.
                                    let commit_epoch = mls_mgr.epoch(&group_key).ok();
                                    crate::node::crypto_handler::broadcast_mls_commit(
                                        mls_mgr, &ws_cmd_tx, &server_id, channel_id.clone(),
                                        commit_b64, commit_epoch,
                                    );

                                    hollow_log!("[HOLLOW-MLS] Batch-added {} members to {group_key}: {:?}", added_peers.len(), added_peers);

                                    // Coordinator side: request channel sync FROM each
                                    // recovered peer.  During the stale epoch the
                                    // coordinator may have dropped messages that the
                                    // recovered peer sent (decrypt failed).  Syncing
                                    // from them fills the gap on this side.
                                    if let Some(state) = server_states.get(&server_id) {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            // Server group: sync all channels. Subgroup:
                                            // sync only the one restricted channel it serves.
                                            let sync_cids: Vec<String> = match &channel_id {
                                                Some(cid) => vec![cid.clone()],
                                                None => state.channels.keys().cloned().collect(),
                                            };
                                            for peer_id_str in &added_peers {
                                                if !peer_is_reachable(&ws_room_peers, peer_id_str) { continue; }
                                                for cid in &sync_cids {
                                                    let sender_ts = store.get_per_sender_timestamps(&server_id, cid)
                                                        .unwrap_or_default();
                                                    let our_latest = store.get_latest_channel_timestamp(&server_id, cid)
                                                        .unwrap_or(None).unwrap_or(0);
                                                    send_message_to_peer(
                                                        &ws_cmd_tx, &ws_room_peers,
                                                        peer_id_str, HavenMessage::ChannelSyncRequest {
                                                            server_id: server_id.clone(),
                                                            channel_id: cid.clone(),
                                                            since_timestamp: our_latest,
                                                            sender_timestamps: sender_ts,
                                                        },
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                                Err(e) => hollow_log!("[HOLLOW-MLS] Batch add failed for {group_key}: {e}"),
                            }
                        }
                    }

                    // Adaptive batch interval: scale up when queue is large, reset when empty.
                    let total_queued: usize = pending_mls_key_packages.values().map(|v| v.len()).sum();
                    let new_interval = if total_queued > 50 {
                        Duration::from_secs(10)
                    } else if total_queued > 20 {
                        Duration::from_secs(5)
                    } else {
                        Duration::from_secs(2)
                    };
                    if new_interval != mls_batch_interval {
                        mls_batch_interval = new_interval;
                        mls_batch_timer = tokio::time::interval(mls_batch_interval);
                        mls_batch_timer.tick().await;
                    }
                }
            }

            // Periodic re-bootstrap for signaling re-registration.
            _ = rebootstrap_timer.tick() => {
                arm_started = Some(("timer", "rebootstrap", std::time::Instant::now()));
                // Primary peer discovery now rides the LIVE WS connection (no fresh TLS
                // handshake — fixes the bootstrap stall under WS frame bursts). The HTTP
                // bootstrap below is kept as a non-fatal fallback (legacy address-based
                // discovery); its failures are logged quietly and never surfaced.
                if let Some(room) = &active_room {
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::DiscoverPeers {
                        room_code: room.clone(),
                    });
                }
                for sid in server_states.keys() {
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::DiscoverPeers {
                        room_code: sid.clone(),
                    });
                }

                if let Some(room) = &active_room {
                }
                for sid in server_states.keys() {
                }

                // ── Olm session reconciliation sweep (self-heal) ──────────────
                // The relay never ACKs a direct message, so a dropped KeyRequest/
                // KeyBundle/SessionAck/PreKey would otherwise strand the handshake
                // until BOTH peers restart (the only thing that clears the in-flight
                // map is a relay disconnect). This sweep repairs that: for every
                // online peer we have a relationship with but NO confirmed Olm
                // session, resend a KeyRequest once the prior request goes stale.
                // Heals wedges: stuck in-flight flag, dropped glare PreKey, and the
                // post-reconnect drain race.
                {
                    // Online peers across all rooms (deduped), excluding ourselves.
                    let mut online: std::collections::HashSet<String> = std::collections::HashSet::new();
                    for peers in ws_room_peers.values() {
                        for p in peers {
                            if p.as_str() != local_peer_str && p.as_str() != device_peer_id {
                                online.insert(p.clone());
                            }
                        }
                    }
                    // Accepted-friend masters (built once per sweep). BACKSTOP for the
                    // friend-handshake Olm wedge: the side that DEFERRED on glare holds NO
                    // session object at all (absent, not unconfirmed → `half_session` is
                    // false) and a freshly-friended peer is not a server member, so without
                    // this a wedged friend with no queued DM would never be swept. The
                    // prompt heal is the DM-room co-presence re-key (PeerJoined/RoomMembers);
                    // this guarantees EVENTUAL convergence if any co-presence signal is
                    // missed. One DB read per 30s tick — negligible. Master-keyed; a sibling
                    // resolves to our own master (not in our friends) so it's excluded.
                    let accepted_friends: std::collections::HashSet<String> =
                        crate::storage::MessageStore::open(&db_path, &db_passphrase)
                            .ok()
                            .and_then(|s| s.load_friends(Some("accepted")).ok())
                            .map(|v| v.into_iter().map(|(pid, ..)| pid).collect())
                            .unwrap_or_default();
                    for peer in &online {
                        // Only reconcile peers we actually have a relationship with —
                        // a shared-server member, an accepted friend, a peer with queued
                        // DMs, or one with a half-built (unconfirmed) session. Avoids
                        // spamming co-room strangers (e.g. public-channel guests we never DM).
                        let is_member = server_states.values()
                            .any(|s| s.is_member(peer));
                        let is_friend = accepted_friends.contains(&super::resolver::resolve(peer));
                        let has_pending = pending_messages.contains_key(peer);
                        let half_session = olm.has_unconfirmed_session(peer);
                        if !(is_member || is_friend || has_pending || half_session) {
                            continue;
                        }
                        // Confirmed session → nothing to do.
                        if olm.has_confirmed_session(peer) {
                            continue;
                        }
                        // A fresh request is still outstanding → give it time.
                        if key_request_is_fresh(&key_request_in_flight, peer) {
                            continue;
                        }
                        hollow_log!("[HOLLOW-CRYPTO] Reconciliation sweep: re-keying online peer {peer} (no confirmed session)");
                        send_message_to_peer(&ws_cmd_tx, &ws_room_peers, peer, signed_key_request(&device_keypair, &device_peer_id, peer));
                        key_request_in_flight.insert(peer.clone(), std::time::Instant::now());
                    }
                }

                // Every 10th tick (~5 min): evict stale entries from in-memory HashMaps.
                eviction_counter += 1;
                if eviction_counter % 10 == 0 {
                    let stale = Duration::from_secs(300);
                    peer_rate_tokens.retain(|_, (_, last)| last.elapsed() < stale);
                    vc_signal_rate_tokens.retain(|_, (_, last)| last.elapsed() < stale);
                    decrypt_fail_cooldown.retain(|_, instant| instant.elapsed() < REKEY_COOLDOWN);
                    channel_sync_sent.retain(|_, instant| instant.elapsed() < Duration::from_secs(30));
                    pending_shard_assembly.retain(|_, asm| asm.received_at.elapsed() < Duration::from_secs(600));
                    // Clean up orphaned early-arrival file streams (5 min TTL).
                    let stale_early: Vec<String> = early_file_streams.iter()
                        .filter(|(_, (tp, _, _))| {
                            std::fs::metadata(tp)
                                .and_then(|m| m.modified())
                                .map(|t| t.elapsed().unwrap_or_default() >= Duration::from_secs(300))
                                .unwrap_or(true)
                        })
                        .map(|(k, _)| k.clone())
                        .collect();
                    for id in &stale_early {
                        if let Some((tp, _, _)) = early_file_streams.remove(id) {
                            let _ = std::fs::remove_file(&tp);
                        }
                    }
                    if !stale_early.is_empty() {
                        hollow_log!("[HOLLOW-STREAM] Cleaned {} orphaned early-arrival file streams", stale_early.len());
                    }
                    let olm_ttl = Duration::from_secs(7 * 24 * 3600);
                    let pruned = olm.prune_stale_sessions(olm_ttl);
                    if !pruned.is_empty() {
                        hollow_log!("[HOLLOW-OLM] Pruned {} stale Olm sessions (>7d inactive)", pruned.len());
                        // Clear per-peer handshake bookkeeping for pruned peers so the
                        // reconciliation sweep can cleanly re-handshake if they're still
                        // online (a leftover in-flight/cooldown entry would block it).
                        for peer in &pruned {
                            key_request_in_flight.remove(peer);
                            decrypt_fail_cooldown.remove(peer);
                        }
                    }
                }
            }

            // Multi-peer fan-out sync coordinator dispatch.
            // Checks every 100ms if any servers have passed the 500ms collection window
            // and are ready to dispatch channel sync probes across peers.
            _ = sync_dispatch_timer.tick() => {
                arm_started = Some(("timer", "sync_dispatch", std::time::Instant::now()));
                let ready = sync_coordinator.collect_ready();
                for (server_id, assignments) in &ready {
                    let total_channels: usize = assignments.iter().map(|(_, chs)| chs.len()).sum();
                    let total_peers = assignments.len();
                    hollow_log!(
                        "[HOLLOW-SYNC] Fan-out dispatch for server {server_id}: {total_channels} channel probes across {total_peers} peers"
                    );

                    // Open DB for message count queries.
                    let sync_store = crate::storage::MessageStore::open(&db_path, &db_passphrase).ok();

                    for (peer, channels) in assignments {
                        let peer_str = peer.to_string();
                        for (channel_id, our_latest) in channels {
                            // Dedup: skip if we already sent a sync probe for this channel recently.
                            let dedup_key = format!("{server_id}:{channel_id}");
                            if let Some(last) = channel_sync_sent.get(&dedup_key) {
                                if last.elapsed() < Duration::from_secs(5) {
                                    continue;
                                }
                            }
                            channel_sync_sent.insert(dedup_key, std::time::Instant::now());

                            // Send direct ChannelSyncRequest (plaintext) instead of MLS ChannelProbe.
                            // MLS probes silently fail when the MLS epoch is stale after reconnection
                            // (peer can't decrypt → no response → sync never completes).
                            // ChannelSyncRequest works reliably because it's plaintext, and the
                            // response handler uses MLS if available, Olm fallback otherwise.
                            let sender_ts = sync_store.as_ref()
                                .map(|s| s.get_per_sender_timestamps(server_id, channel_id).unwrap_or_default())
                                .unwrap_or_default();
                            send_message_to_peer(
                                &ws_cmd_tx, &ws_room_peers,
                                &peer_str, HavenMessage::ChannelSyncRequest {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    since_timestamp: *our_latest,
                                    sender_timestamps: sender_ts,
                                },
                            );
                        }
                    }

                    // Emit sync started for UI feedback.
                    let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
                        server_id: server_id.clone(),
                        peer_id: "fan-out".to_string(),
                    }).await;
                }

                // Clean up stale entries (dispatched > 30s ago).
                sync_coordinator.cleanup_stale();
            }

            // Flush pending disconnects that have passed the debounce window.
            // -- Stream transfer progress poll (every 500ms) --
            _ = stream_progress_timer.tick() => {
                arm_started = Some(("timer", "stream_progress", std::time::Instant::now()));
                // Snapshot progress under lock, then emit events outside lock.
                let snapshot: Vec<(String, u64, u64)> = {
                    let Ok(map) = super::ws_stream_transfer::stream_progress().lock() else { continue };
                    map.iter().map(|(id, p)| {
                        (id.clone(), p.bytes_received.load(std::sync::atomic::Ordering::Relaxed), p.total_bytes)
                    }).collect()
                };
                for (file_id, received, total) in snapshot {
                    if received == 0 { continue; }
                    // Declined pushed streams (auto-download off, issue #41) still
                    // transit — never surface their progress, the UI is showing a
                    // manual Download button for this file.
                    if declined_file_ids.contains(&file_id) { continue; }
                    // Link snapshot ids carry a "link_" prefix so they emit real-byte
                    // LinkProgress (drives the device-link bar) instead of FileProgress.
                    if let Some(link_id) = file_id.strip_prefix("link_") {
                        let _ = event_tx.send(NetworkEvent::LinkProgress {
                            link_id: link_id.to_string(),
                            bytes_received: received,
                            total_bytes: total,
                        }).await;
                    } else {
                        let _ = event_tx.send(NetworkEvent::FileProgress {
                            file_id,
                            chunks_received: (received / (1024 * 1024)).max(1) as u32,
                            total_chunks: (total / (1024 * 1024)).max(1) as u32,
                        }).await;
                    }
                }
            }

            // -- Vault rebalance + retention enforcement (every 30 min) --
            _ = rebalance_timer.tick() => {
                arm_started = Some(("timer", "rebalance", std::time::Instant::now()));
                crdt_store.prune_ops(1000);
                hollow_log!("[HOLLOW-VAULT] Running rebalance + retention check");
                let local_peer = local_peer_str.to_string();
                let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir) {
                    // 1. Update last_seen for all connected server members
                    let now_ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs() as i64;

                    for (server_id, state) in &server_states {
                        for member_peer_str in state.members.keys() {
                                if peer_is_reachable(&ws_room_peers, member_peer_str) {
                                    let _ = cs.update_member_last_seen(server_id, member_peer_str, now_ts);
                                }
                        }

                        // 2. Retention enforcement: delete expired vault manifests
                        let policy = crate::vault::adaptive::retention_for_tier(
                            crate::vault::content_store::StorageTier::Standard, &state.settings);
                        if let Some(days) = crate::vault::adaptive::parse_retention_days(&policy) {
                            let cutoff = now_ts - (days as i64 * 86400);
                            if let Ok(expired) = cs.find_expired_manifests(server_id, cutoff) {
                                for manifest in &expired {
                                    hollow_log!("[HOLLOW-VAULT] Retention: deleting expired content {} (tier: {})", manifest.content_id, manifest.storage_tier);
                                    let _ = cs.delete_content(server_id, &manifest.content_id);
                                    let _ = cs.delete_placements(&manifest.content_id);
                                    let _ = cs.delete_manifest(&manifest.content_id);
                                }
                            }

                            // 2b. Retention for channel files not tracked by vault manifests
                            // (full-replication <6 member servers, or any channel files in ~/.hollow/files/)
                            let prefix = format!("{}:", server_id);
                            if let Ok(files) = cs.find_expirable_channel_files(&prefix, cutoff) {
                                for (file_id, disk_path) in &files {
                                    hollow_log!("[HOLLOW-VAULT] Retention: expiring channel file {}", file_id);
                                    if let Some(path) = disk_path {
                                        let _ = std::fs::remove_file(path);
                                    }
                                    let _ = cs.mark_file_expired(file_id, now_ts);
                                }
                            }
                        }
                    }

                    // 2c. Message retention: prune old messages per server setting.
                    // Forward-only: only prune messages sent after the policy was set.
                    if let Ok(msg_store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                        for (server_id, state) in &server_states {
                            let msg_policy = state.settings
                                .get("retention_messages")
                                .map(|r| r.read().clone())
                                .unwrap_or_else(|| "365d".to_string());
                            if let Some(days) = crate::vault::adaptive::parse_retention_days(&msg_policy) {
                                let since = state.settings
                                    .get("retention_messages_since")
                                    .and_then(|r| r.read().parse::<i64>().ok())
                                    .unwrap_or(0);
                                let cutoff = now_ts - (days as i64 * 86400);
                                if cutoff > since {
                                    match msg_store.prune_channel_messages_in_range(server_id, since, cutoff) {
                                        Ok(n) if n > 0 => hollow_log!("[HOLLOW-RETENTION] Pruned {n} channel messages older than {days}d for {server_id}"),
                                        _ => {}
                                    }
                                }
                            }
                        }
                    }

                    // 3. Shard health: detect under-replicated content and request repairs via MLS.
                    // Rooms hold DEVICE ids but placements/members are MASTER-keyed —
                    // include each room peer's resolved master so a multi-device
                    // member counts as an online shard holder/target (single-device
                    // resolves to itself; dedup via the set).
                    let online_peers: std::collections::HashSet<String> = ws_room_peers.values()
                        .flat_map(|peers| peers.iter())
                        .flat_map(|p| [p.clone(), super::resolver::resolve(p)])
                        .collect();

                    for (server_id, state) in &server_states {
                        if state.members.len() < 6 { continue; } // Only erasure-coded servers

                        // Only the vault coordinator runs repair to avoid duplicate requests.
                        if let Some(ref mls_mgr) = mls {
                            if mls_mgr.has_group(server_id) {
                                if !is_vault_coordinator(mls_mgr, server_id, &local_peer_str, &ws_room_peers) {
                                    continue;
                                }
                            }
                        }

                        let manifests = cs.list_manifests(server_id).unwrap_or_default();
                        if manifests.is_empty() { continue; }

                        let mut placements_map: HashMap<String, Vec<crate::vault::content_store::PlacementRecord>> = HashMap::new();
                        for manifest in &manifests {
                            if let Ok(p) = cs.load_placements(&manifest.content_id) {
                                placements_map.insert(manifest.content_id.clone(), p);
                            }
                        }

                        let under_rep = crate::vault::rebalancer::scan_under_replicated(
                            &manifests, &placements_map, &online_peers,
                        );
                        if under_rep.is_empty() { continue; }

                        hollow_log!("[HOLLOW-VAULT] Found {} under-replicated items in {server_id}", under_rep.len());

                        let members: Vec<String> = state.members.keys().cloned().collect();
                        let pledges: HashMap<String, u64> = state.storage_pledges.iter()
                            .map(|(k, v)| (k.clone(), *v.read()))
                            .collect();

                        let mut total_requested = 0u32;
                        for item in &under_rep {
                            let manifest = manifests.iter().find(|m| m.content_id == item.content_id);
                            let placements = placements_map.get(&item.content_id);
                            if let (Some(manifest), Some(placements)) = (manifest, placements) {
                                if let Some(plan) = crate::vault::rebalancer::compute_repair_plan(
                                    manifest, placements, &online_peers, &members, &pledges,
                                ) {
                                    // Request available shards from their online holders for reconstruction.
                                    // We need k shards to reconstruct — request all available ones.
                                    for (shard_idx, source_peer) in &plan.available_shards {
                                        let shard_key = placements.iter()
                                            .find(|p| p.shard_index as u16 == *shard_idx)
                                            .map(|p| p.shard_key.clone())
                                            .unwrap_or_default();
                                        let envelope = MessageEnvelope::ShardRequest {
                                            sid: server_id.clone(),
                                            cid: item.content_id.clone(),
                                            si: *shard_idx,
                                            sk: shard_key,
                                            target: None,
                                        };
                                        let env_json = serde_json::to_string(&envelope).unwrap_or_default();
                                        // source_peer may be a MASTER (placements are
                                        // master-keyed) — Olm/sockets are per-device.
                                        if let Some(dev) = crate::node::crypto_handler::preferred_online_device(&ws_room_peers, source_peer) {
                                            send_encrypted_message(
                                                &mut olm, &crypto_store, &dev, &env_json,
                                                &event_tx, &ws_cmd_tx, &ws_room_peers,
                                            ).await;
                                            total_requested += 1;
                                        }
                                    }
                                }
                            }
                        }

                        if total_requested > 0 {
                            hollow_log!("[HOLLOW-VAULT] Requested {total_requested} repair shards for {server_id}");
                            let _ = event_tx.send(NetworkEvent::RebalanceStarted {
                                server_id: server_id.clone(),
                                shards_to_move: total_requested,
                            }).await;
                        }
                    }

                    // 4. Cache eviction (user-configurable, default 1 GB)
                    let cache_cap = {
                        let store_lock = crate::api::storage::get_store();
                        store_lock.lock().ok()
                            .and_then(|guard| guard.as_ref()
                                .and_then(|store| store.load_setting("vault_cache_cap_mb").ok())
                                .flatten()
                                .and_then(|v| v.parse::<u64>().ok())
                                .map(|mb| mb * 1024 * 1024))
                            .unwrap_or(crate::vault::pipeline::VAULT_CACHE_CAP)
                    };
                    if let Ok(freed) = crate::vault::pipeline::evict_cache_if_needed(
                        cache_cap,
                        &std::collections::HashSet::new(),
                    ) {
                        if freed > 0 {
                            hollow_log!("[HOLLOW-VAULT] Cache eviction freed {} bytes", freed);
                        }
                    }
                }
            }

            // -- Event-driven vault rebalance (debounced 10s) --
            _ = rebalance_debounce.tick() => {
                arm_started = Some(("timer", "rebalance_debounce", std::time::Instant::now()));
                if !rebalance_pending.is_empty() {
                    let servers_to_check: Vec<String> = rebalance_pending.drain().collect();
                    hollow_log!("[HOLLOW-VAULT] Event-driven rebalance for {} servers", servers_to_check.len());

                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                    if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir) {
                        // DEVICE ids + resolved masters, same as the 30-min rebalance —
                        // placements/members are MASTER-keyed.
                        let online_peers: std::collections::HashSet<String> = ws_room_peers.values()
                            .flat_map(|peers| peers.iter())
                            .flat_map(|p| [p.clone(), super::resolver::resolve(p)])
                            .collect();

                        for server_id in &servers_to_check {
                            let state = match server_states.get(server_id) {
                                Some(s) => s,
                                None => continue,
                            };
                            if state.members.len() < 6 { continue; }

                            // Only the vault coordinator runs rebalance.
                            if let Some(ref mls_mgr) = mls {
                                if mls_mgr.has_group(server_id) {
                                    if !is_vault_coordinator(mls_mgr, server_id, &local_peer_str, &ws_room_peers) {
                                        continue;
                                    }
                                }
                            }

                            let manifests = cs.list_manifests(server_id).unwrap_or_default();
                            if manifests.is_empty() { continue; }

                            let mut placements_map: HashMap<String, Vec<crate::vault::content_store::PlacementRecord>> = HashMap::new();
                            for manifest in &manifests {
                                if let Ok(p) = cs.load_placements(&manifest.content_id) {
                                    placements_map.insert(manifest.content_id.clone(), p);
                                }
                            }

                            let members: Vec<String> = state.members.keys().cloned().collect();
                            let pledges: HashMap<String, u64> = state.storage_pledges.iter()
                                .map(|(k, v)| (k.clone(), *v.read()))
                                .collect();

                            let mut total_requested = 0u32;

                            // Repair: fix under-replicated content.
                            let under_rep = crate::vault::rebalancer::scan_under_replicated(
                                &manifests, &placements_map, &online_peers,
                            );
                            if !under_rep.is_empty() {
                                hollow_log!("[HOLLOW-VAULT] Event-driven: {} under-replicated items in {server_id}", under_rep.len());
                                for item in &under_rep {
                                    let manifest = manifests.iter().find(|m| m.content_id == item.content_id);
                                    let placements = placements_map.get(&item.content_id);
                                    if let (Some(manifest), Some(placements)) = (manifest, placements) {
                                        if let Some(plan) = crate::vault::rebalancer::compute_repair_plan(
                                            manifest, placements, &online_peers, &members, &pledges,
                                        ) {
                                            for (shard_idx, source_peer) in &plan.available_shards {
                                                let shard_key = placements.iter()
                                                    .find(|p| p.shard_index as u16 == *shard_idx)
                                                    .map(|p| p.shard_key.clone())
                                                    .unwrap_or_default();
                                                let envelope = MessageEnvelope::ShardRequest {
                                                    sid: server_id.clone(),
                                                    cid: item.content_id.clone(),
                                                    si: *shard_idx,
                                                    sk: shard_key,
                                                    target: None,
                                                };
                                                let env_json = serde_json::to_string(&envelope).unwrap_or_default();
                                                // source_peer may be a MASTER (placements
                                                // are master-keyed) — resolve to a device.
                                                if let Some(dev) = crate::node::crypto_handler::preferred_online_device(&ws_room_peers, source_peer) {
                                                    send_encrypted_message(
                                                        &mut olm, &crypto_store, &dev, &env_json,
                                                        &event_tx, &ws_cmd_tx, &ws_room_peers,
                                                    ).await;
                                                    total_requested += 1;
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Migration: shift shards to new members for balanced distribution.
                            for manifest in &manifests {
                                let old_placements = match placements_map.get(&manifest.content_id) {
                                    Some(p) => p,
                                    None => continue,
                                };
                                let n = if manifest.k > 0 { (manifest.k + manifest.m) as usize } else { old_placements.len() };
                                let new_placements = crate::vault::placement::compute_shard_placements(
                                    &manifest.content_id, n, &members, &pledges,
                                );
                                let migrations = crate::vault::rebalancer::compute_migration_plan(
                                    &manifest.content_id, old_placements, &new_placements,
                                );
                                for migration in &migrations {
                                    if !online_peers.contains(&migration.from_peer) { continue; }
                                    // Migrate shards we hold locally to new targets.
                                    if migration.from_peer == local_peer_str {
                                        if let Ok(shard_data) = cs.read_shard_unchecked(server_id, &migration.shard_key) {
                                            let data_b64 = base64::engine::general_purpose::STANDARD.encode(&shard_data);
                                            let envelope = MessageEnvelope::ShardMigrate {
                                                sid: server_id.clone(),
                                                cid: manifest.content_id.clone(),
                                                si: migration.shard_index,
                                                sk: migration.shard_key.clone(),
                                                data: data_b64,
                                                target: None,
                                            };
                                            let env_json = serde_json::to_string(&envelope).unwrap_or_default();
                                            send_encrypted_message(&mut olm, &crypto_store, &migration.to_peer, &env_json, &event_tx, &ws_cmd_tx, &ws_room_peers).await;
                                            total_requested += 1;
                                            hollow_log!("[HOLLOW-VAULT] Migrating shard {} of {} from local → {}", migration.shard_index, manifest.content_id, migration.to_peer);
                                        }
                                    }
                                }
                            }

                            if total_requested > 0 {
                                hollow_log!("[HOLLOW-VAULT] Event-driven: {total_requested} repair/migration shards for {server_id}");
                                let _ = event_tx.send(NetworkEvent::RebalanceStarted {
                                    server_id: server_id.clone(),
                                    shards_to_move: total_requested,
                                }).await;
                            }
                        }
                    }
                }
            }

            // -- Gossip overlay rotation timer (5 minutes) --
            _ = gossip_rotation_timer.tick() => {
                arm_started = Some(("timer", "gossip_rotation", std::time::Instant::now()));
                super::gossip_relay::handle_gossip_rotation(&mut gossip_overlays, &event_tx, webrtc_peers.len()).await;
            }

            // -- Gossip broadcast dedup eviction timer (60s) --
            _ = gossip_eviction_timer.tick() => {
                arm_started = Some(("timer", "gossip_eviction", std::time::Instant::now()));
                super::gossip_relay::handle_gossip_eviction(&mut gossip_overlays, &ws_cmd_tx, &ws_room_peers);
            }

            // -- Gossip peer exchange timer (2 minutes) --
            _ = gossip_exchange_timer.tick() => {
                arm_started = Some(("timer", "gossip_exchange", std::time::Instant::now()));
                super::gossip_relay::handle_gossip_exchange(&gossip_overlays, &ws_cmd_tx, &ws_room_peers);
                // Adaptive interval: scale with largest server's member count.
                let max_members = server_states.values().map(|s| s.members.len()).max().unwrap_or(0);
                let new_secs = super::gossip::gossip_exchange_interval_secs(max_members);
                gossip_exchange_timer = tokio::time::interval(Duration::from_secs(new_secs));
                gossip_exchange_timer.tick().await;
            }

            // -- Hollow Share scheduler (1 second) --
            // Drives chunk requests, Have rebroadcast, in-flight timeout/retry.
            // Pauses chunk requests when messaging/voice traffic is recent so
            // share never starves real-time traffic on the same peer connection.
            _ = share_tick_timer.tick() => {
                arm_started = Some(("timer", "share_tick", std::time::Instant::now()));
                let messaging_active = std::time::Instant::now()
                    .duration_since(last_message_traffic) < super::share_handler::COEXIST_PAUSE;
                super::share_handler::tick(&mut share_registry, &ws_cmd_tx, messaging_active, &webrtc_share_peers, &event_tx, &bundle_keypair).await;
            }

            // -- TURN credential refresh (50 min) --
            _ = turn_refresh_timer.tick() => {
                arm_started = Some(("timer", "turn_refresh", std::time::Instant::now()));
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::GetTurnCredentials);
            }

            // -- MLS state debounce (2s) --
            // RECEIVE-path only: a regressed receive ratchet can ratchet
            // forward again after a crash, so deferring its persistence is
            // safe. Send-path encrypts persist IMMEDIATELY (persist-on-encrypt
            // rule) — a regressed send ratchet re-uses generations and wedges
            // the group for every receiver.
            _ = mls_persist_timer.tick() => {
                arm_started = Some(("timer", "mls_persist", std::time::Instant::now()));
                if mls_dirty {
                    if let Some(ref mls_mgr) = mls {
                        persist_mls_state(mls_mgr, &crypto_store);
                    }
                    mls_dirty = false;
                }
            }

            // Peer liveness check — ask the relay if "offline" friends are actually alive.
            // Only checks friends (DM/inbox), NOT servers (MLS re-join disrupts group state).
            _ = peer_liveness_timer.tick() => {
                arm_started = Some(("timer", "peer_liveness", std::time::Instant::now()));
                let mut check_peers: Vec<String> = Vec::new();

                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                    if let Ok(friends) = store.load_friends(None) {
                        let local_peer = local_peer_str.to_string();
                        for (friend_pid, _, _, _, _) in &friends {
                            if friend_pid == &local_peer { continue; }
                            let is_reachable = ws_room_peers.values().any(|ps| ps.contains(friend_pid));
                            if !is_reachable {
                                check_peers.push(friend_pid.clone());
                            }
                        }
                    }
                }

                if !check_peers.is_empty() {
                    hollow_log!("[HOLLOW-WS] Liveness check: {} offline friends", check_peers.len());
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::CheckPeers {
                        peers: check_peers,
                        rooms: Vec::new(),
                    });
                }
            }

            // Temporary channel-grant expiry sweep: the predicate already
            // denies an expired grant lazily; this enacts the crypto/UI
            // consequences. Only (server, channel)s with a grant whose expiry
            // fell INSIDE the (last_tick, now] window fire — each expiry
            // triggers exactly one reconcile; long-expired rows (lazy,
            // unpruned) never re-fire after the first tick.
            _ = grant_sweep_timer.tick() => {
                arm_started = Some(("timer", "grant_sweep", std::time::Instant::now()));
                let now_ms = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                let mut expired: Vec<(String, Vec<String>)> = Vec::new();
                for (sid, state) in server_states.iter() {
                    let cids: Vec<String> = state.channel_grants.iter()
                        .filter(|(_, grants)| grants.values().any(|reg| {
                            let e = *reg.read();
                            e != u64::MAX && e > grant_sweep_last_ms && e <= now_ms
                        }))
                        .map(|(cid, _)| cid.clone())
                        .collect();
                    if !cids.is_empty() { expired.push((sid.clone(), cids)); }
                }
                grant_sweep_last_ms = now_ms;
                for (sid, cids) in expired {
                    hollow_log!("[HOLLOW-CRDT] Channel grant(s) expired in {sid}: {} channel(s)", cids.len());
                    if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                        for cid in &cids {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, &ws_cmd_tx, &ws_room_peers,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                state, &sid, &local_peer_str, Some(cid),
                            );
                        }
                    }
                    voice_handler::auto_leave_invisible_voice_channels(
                        &mut mls, &ws_cmd_tx, &ws_room_peers, &server_states,
                        &bundle_keypair, &crypto_store,
                        &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                        &gossip_overlays, &local_peer_str, &device_peer_id, &sid, &event_tx,
                    ).await;
                    let _ = event_tx.send(NetworkEvent::ServerUpdated {
                        server_id: sid.clone(),
                    }).await;
                }
            }
        }
    }

}

// check_voice_mode_transition moved to voice_handler.rs
// send_message_to_peer moved to crypto_handler.rs
// send_own_profile_to_peer moved to social.rs
// handle_completed_stream, stream_to_peer, broadcast_to_gossip_neighbors moved to file_handler.rs


/// Resolve the DM conversation a received edit/delete/reaction event belongs to
/// (multi-device self fan-out, Phase 6 Step 3). For a normal DM from a friend the
/// sender IS the conversation peer → `resolve(sender)`. For a copy echoed from our
/// OWN sibling device, the sender is US, so the event must be keyed to the OTHER
/// party — look that up from the message's stored row by `mid` (the edit/delete/
/// reaction envelopes carry no convo field). Falls back to `resolve(sender)` if
/// the row isn't found (e.g. not yet synced), which is the pre-fan-out behavior.
fn dm_event_convo(
    sender_peer: &str,
    local_master: &str,
    mid: &str,
    db_path: &str,
    db_passphrase: &str,
) -> String {
    if super::resolver::same_identity(sender_peer, local_master) {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if let Some(peer) = store.get_dm_message_peer(mid) {
                return peer;
            }
        }
    }
    super::resolver::resolve(sender_peer)
}

/// After a session is (re)established with `peer_str`, ask that peer to re-serve
/// our DM history from our high-water mark. This is the LIVE equivalent of the
/// restart-time DM re-sync: during an Olm session desync (glare) the peer kept
/// encrypting on a ratchet we couldn't decrypt, so its messages never rendered —
/// a restart recovered them only because it re-synced over a fresh session. Now
/// that we hold a fresh session, do the same without a restart. The DmSyncBatch
/// response rides the new (good) session; the receiver dedups by message_id, so a
/// redundant re-serve on an already-healthy session is harmless. Targets the
/// concrete device `peer_str` (the live socket); the convo key resolves to master.
fn request_dm_resync_after_rekey(
    peer_str: &str,
    master_peer_str: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    // A media forwarder is not a social peer: it has no DM history with us and
    // DISCARDS the request (one "non-fwd HavenMessage — ignored" line in its
    // journal per session). Detected structurally — the only room we share with
    // it is a `fwd:` room — so this covers peer forwarders as well as the VPS
    // one, without either side knowing the other's role.
    if peer_is_forwarder_only(ws_room_peers, peer_str) {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let convo = super::resolver::resolve(peer_str);
        // Multi-device: if WE have a sibling, request both directions from our
        // cross-direction high-water mark (mirrors the PeerJoined DM-sync) so a
        // friend also re-serves messages we sent from another device.
        let multi_device = !super::resolver::devices_for(master_peer_str).is_empty();
        // Lookback overlap — a high-watermark skips messages missed while a
        // newer one arrived; the overlap is mid-deduplicated on receipt.
        let since = (if multi_device {
            store.get_latest_dm_timestamp_any(&convo)
        } else {
            store.get_latest_dm_timestamp(&convo)
        }
        .unwrap_or(None)
        .unwrap_or(0)
            - crate::storage::messages::SYNC_LOOKBACK_MS)
            .max(0);
        hollow_log!("[HOLLOW-SYNC] Post-rekey DM resync from {peer_str} since {since} (both={multi_device})");
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            peer_str, HavenMessage::DmSyncRequest {
                since_timestamp: since,
                both_directions: multi_device,
            },
        );
    }
}

/// Pack a slice of stored DM messages into wire `DmSyncItem`s, joining in each
/// message's reactions and file metadata in two batch queries. Shared by the
/// friend `DmSyncRequest` responder and the multi-device sibling backfill
/// responder so the (reactions + file-meta) join logic lives in one place.
fn build_dm_sync_items(
    store: &crate::storage::MessageStore,
    messages: &[crate::storage::messages::StoredMessage],
) -> super::sync_handler::SyncPage<DmSyncItem> {
    let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
    let file_ids: Vec<&str> = messages.iter().filter_map(|m| m.file_id.as_deref()).collect();
    let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

    let mut budget = super::sync_handler::PreviewBudget::new();
    let mut items: Vec<DmSyncItem> = Vec::with_capacity(messages.len());
    let mut truncated = false;

    for m in messages {
        // Budget spent → END the page (the caller flags `has_more`), never
        // pack a message without the card it was signed with. See
        // `sync_handler::SYNC_PREVIEW_BUDGET_BYTES`.
        if let Some(lp) = &m.link_preview {
            if !budget.fits(lp, items.len()) {
                hollow_log!(
                    "[HOLLOW-SYNC] Preview budget spent after {} DM(s) — cutting the page short (has_more)",
                    items.len()
                );
                truncated = true;
                break;
            }
        }
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
                thumb: f.thumb_b64.clone(),
            })
        });
        // Deletion proof rides with the hidden flag (REJECT-ABSENT on apply).
        let (hidden_at, hidden_sig, hidden_pk) = message_ops::deletion_proof_fields(
            store, m.hidden_at, m.message_id.as_deref(),
        );
        items.push(DmSyncItem {
            t: m.text.clone(),
            ts: m.timestamp,
            mine: m.is_mine,
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
            lp_digest: m.link_preview.as_ref().map(crypto_handler::link_preview_digest),
            lp: m.link_preview.clone().map(Box::new),
            reactions,
        });
    }
    super::sync_handler::SyncPage { items, truncated }
}

/// Enforce device revocations (Step 7) that were just learned from an ingested
/// device list. For each freshly-revoked device id:
/// - **Olm (every node):** drop the in-RAM session AND delete the persisted pickle
///   so a friend never encrypts a DM to the revoked device, and a restart can't
///   resurrect it. (Olm has no coordinator — each holder of a session drops it.)
/// - **MLS (coordinator only, single leaf):** for each server where we are the
///   elected coordinator and the revoked id still holds a leaf, enqueue that ONE
///   leaf into `pending_mls_removals` — the existing `mls_batch_timer` issues a
///   single `remove_members_batch` commit + `MlsCommit` broadcast. We remove ONLY
///   that device's leaf; the device's MASTER is still a valid member.
fn enforce_device_revocations(
    newly_revoked: &[String],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: Option<&MlsManager>,
    local_peer_str: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
) {
    if newly_revoked.is_empty() {
        return;
    }
    for id in newly_revoked {
        // Olm — drop + erase. Never drop a session to OURSELVES (defensive).
        if id != local_peer_str {
            if olm.has_session(id) {
                olm.remove_session(id);
                crate::node::crypto_handler::persist_crypto_state(olm, crypto_store, id);
            }
            crypto_store.delete_session(id.to_string());
        }
        hollow_log!("[HOLLOW-REVOKE] Dropped Olm session to revoked device {id}");
    }
    // MLS single-leaf removal, coordinator-only.
    if let Some(mls_mgr) = mls {
        for id in newly_revoked {
            for server_id in mls_mgr.group_ids() {
                if !mls_mgr.group_members(&server_id).iter().any(|m| m == id) {
                    continue;
                }
                if !super::crypto_handler::is_mls_coordinator(
                    mls_mgr, &server_id, local_peer_str, ws_room_peers,
                ) {
                    continue;
                }
                let queue = pending_mls_removals.entry(server_id.clone()).or_default();
                if !queue.iter().any(|q| q == id) {
                    queue.push(id.clone());
                    hollow_log!(
                        "[HOLLOW-REVOKE] Coordinator queued MLS leaf removal for revoked device {id} in {server_id}"
                    );
                }
            }
        }
    }
}

/// Handle an incoming request from a peer.
async fn handle_incoming_request(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    key_bundle_sent_to: &mut std::collections::HashSet<String>,
    server_states: &mut HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    // THIS device's keypair — signs the Olm key exchange (Fix A/B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    device_peer_id: &str,
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    join_request_seen: &mut HashMap<String, std::time::Instant>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    mls: &mut Option<MlsManager>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    pending_shard_assembly: &mut HashMap<String, PendingShardAssembly>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (std::path::PathBuf, u64, String)>,
    pending_link_snapshots: &mut HashMap<String, file_handler::LinkSnapshotState>,
    decrypt_fail_cooldown: &mut HashMap<String, std::time::Instant>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    mls_decrypt_failures: &mut HashMap<String, (u32, std::time::Instant)>,
    mls_epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    channel_sync_sent: &mut HashMap<String, std::time::Instant>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conference_host: &mut HashMap<String, super::conference::ConferenceHostState>,
    vc_signal_rate_tokens: &mut HashMap<String, (u32, std::time::Instant)>,
    mls_dirty: &mut bool,
    guest_rooms: &std::collections::HashSet<String>,
    subscribed_channels: &HashMap<String, Vec<String>>,
    db_path: &str,
    db_passphrase: &str,
    local_peer_str: &str,
    peer_str: &str,
    is_invisible: bool,
    link_snapshot_requested: &mut std::collections::HashSet<String>,
    pending_sibling_challenges: &mut HashMap<String, (String, std::time::Instant)>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    requested_asset_kinds: &mut HashMap<String, emotes::AssetKind>,
    pending_public_file_requests: &mut HashMap<String, (String, std::time::Instant)>,
    requested_file_receipts: &mut HashMap<String, std::time::Instant>,
    declined_file_ids: &mut std::collections::HashSet<String>,
    peer_auto_dl: &mut HashMap<String, u32>,
    fwd_bridge: FwdBridge<'_>,
    request: HavenMessage,
) {

    match request {
        HavenMessage::KeyRequest { to, ts, sig, pk } => {
            // SECURITY (Fix B): this handler TEARS DOWN a working Olm session, so
            // an unauthenticated KeyRequest is a remote session-reset primitive
            // against any peer. Authenticate before acting on it.
            //
            // A device that is not in its master's SIGNED device list is refused
            // outright — a signature alone only proves that *some* device sent
            // this, not that it speaks for the identity we think we're talking to.
            let payload = key_request_signing_payload(peer_str, device_peer_id, ts.unwrap_or(0));
            let auth = verify_key_exchange(
                peer_str, device_peer_id, to.as_deref(), ts, sig.as_deref(), pk.as_deref(), &payload,
            );
            match auth {
                KeyExchangeAuth::Invalid => {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED KeyRequest from {peer_str} — authentication FAILED");
                    return;
                }
                KeyExchangeAuth::Unsigned => {
                    if REQUIRE_SIGNED_KEY_EXCHANGE {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED unsigned KeyRequest from {peer_str}");
                        return;
                    }
                    hollow_log!("[HOLLOW-SECURITY] Unsigned KeyRequest from {peer_str} — accepted (pre-rollout client)");
                }
                KeyExchangeAuth::Verified => {}
            }
            if key_exchange_device_unauthorized(peer_str) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED KeyRequest from {peer_str} — device not in its master's signed device list");
                return;
            }

            // A peer asking for a key bundle means THEIR side has no usable session.
            // If we hold a CONFIRMED session, our half is stale relative to theirs
            // (they pruned / lost / restarted) — silently ignoring it strands both
            // sides until a mutual restart. Tear ours down and re-handshake. If we
            // only have an UNCONFIRMED outbound session, the peer never got our
            // PreKey — also rebuild. A decrypt-fail-style cooldown prevents a
            // KeyRequest flood from thrashing the session.
            let now = std::time::Instant::now();
            let cooldown_ok = match decrypt_fail_cooldown.get(peer_str) {
                Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                None => true,
            };
            if olm.has_confirmed_session(peer_str) && !cooldown_ok {
                hollow_log!("[HOLLOW-CRYPTO] KeyRequest from {peer_str} but confirmed session + cooldown active, ignoring");
            } else {
                if olm.has_session(peer_str) {
                    // Drop our (now-known-stale) half before re-bundling so the new
                    // inbound session the peer builds isn't shadowed by a dead one.
                    hollow_log!("[HOLLOW-CRYPTO] KeyRequest from {peer_str} while we hold a session — peer lost theirs, re-keying");
                    olm.remove_session(peer_str);
                    decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                }
                let otk = olm.generate_one_time_key();
                let identity_key = olm.identity_key_base64();
                if let Ok(pickle) = olm.account_pickle_json() {
                    crypto_store.save_account(pickle);
                }
                persist_crypto_state(olm, crypto_store, peer_str);
                key_bundle_sent_to.insert(peer_str.to_string());
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers, peer_str,
                    signed_key_bundle(device_keypair, device_peer_id, peer_str, identity_key, otk),
                );
            }
        }

        HavenMessage::KeyBundle { identity_key, one_time_key, to, ts, sig, pk } => {
            // SECURITY (Fix A): these Curve25519 keys arrive over the relay and
            // become the Olm ratchet for this peer. Unauthenticated, a hostile
            // relay could substitute its own keys and sit in the middle of every
            // DM with no visible sign — the reported MITM.
            //
            // The signature binds them to the sender's Ed25519 DEVICE key, and
            // `verify_message_signature` re-derives the peer_id from `pk`, so the
            // keys are cryptographically tied to the peer_id the frame claims to
            // come from. The device-list check then ties that device to a master
            // the user actually trusts, completing the chain:
            //   master (known out of band) → signed device list → device key →
            //   signed bundle → Olm keys.
            let payload = key_bundle_signing_payload(
                peer_str, device_peer_id, &identity_key, &one_time_key, ts.unwrap_or(0),
            );
            let auth = verify_key_exchange(
                peer_str, device_peer_id, to.as_deref(), ts, sig.as_deref(), pk.as_deref(), &payload,
            );
            match auth {
                KeyExchangeAuth::Invalid => {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED KeyBundle from {peer_str} — authentication FAILED (possible key substitution)");
                    key_bundle_sent_to.remove(peer_str);
                    return;
                }
                KeyExchangeAuth::Unsigned => {
                    if REQUIRE_SIGNED_KEY_EXCHANGE {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED unsigned KeyBundle from {peer_str}");
                        key_bundle_sent_to.remove(peer_str);
                        return;
                    }
                    hollow_log!("[HOLLOW-SECURITY] Unsigned KeyBundle from {peer_str} — accepted (pre-rollout client)");
                }
                KeyExchangeAuth::Verified => {}
            }
            if key_exchange_device_unauthorized(peer_str) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED KeyBundle from {peer_str} — device not in its master's signed device list");
                key_bundle_sent_to.remove(peer_str);
                return;
            }

            // SECURITY (Issue 1-C): the bundle is authenticated at this point —
            // signed by the sender's device key, and that device is in its
            // master's signed list. Pin the Olm identity key so a LATER change
            // (a reinstall) is surfaced instead of passing silently. Done before
            // the glare/session branching so the fact is recorded even when this
            // particular bundle loses the tiebreaker and builds no session.
            super::security_alerts::note_olm_identity_key(
                event_tx, db_path, db_passphrase, master_peer_str,
                &super::resolver::resolve(peer_str), peer_str, &identity_key,
            ).await;

            // Peer responded with their key bundle — create outbound Olm session.
            if olm.has_session(peer_str) {
                hollow_log!("[HOLLOW-CRYPTO] Already have session with {peer_str}, ignoring KeyBundle");
                key_bundle_sent_to.remove(peer_str);
            } else if key_bundle_sent_to.remove(peer_str) && device_peer_id > peer_str {
                // Glare: we sent THEM a KeyBundle (responding to their KeyRequest) AND
                // they sent US a KeyBundle (responding to our KeyRequest). Both sides
                // would create outbound sessions → MAC mismatch. The lower peer ID
                // creates the outbound session; we're higher, so we wait for their
                // PreKey/SessionAck to create an inbound session instead.
                //
                // CRITICAL — compare DEVICE ids, not master. `peer_str` is the
                // SENDER'S DEVICE id (the relay reports device ids + authenticates
                // device sockets); the outbound Olm session lives on the SOCKET, so
                // the tiebreaker must be device↔device to stay antisymmetric. Using
                // the local MASTER (`local_peer_str`) here compared our master vs the
                // peer's device — two unrelated strings, so BOTH peers of a pair could
                // satisfy `local > peer` at once → both defer → deadlock (never keyed
                // until the 30s sweep). All `key_bundle_sent_to` / `key_request_in_flight`
                // / KeyRequest targets are already device-keyed, so `device_peer_id`
                // is the consistent id-kind to compare against `peer_str`.
                //
                // Do NOT clear key_request_in_flight here: if the low peer's PreKey/
                // SessionAck is dropped, clearing it would strand us sessionless with
                // no retry. Instead REFRESH the timestamp so the reconciliation sweep
                // re-requests once the deferral window lapses.
                hollow_log!("[HOLLOW-CRYPTO] KeyBundle glare with {peer_str} — we're higher, deferring to their PreKey (sweep will retry if dropped)");
                key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());
            } else {
                key_bundle_sent_to.remove(peer_str);
                match olm.create_outbound_session(peer_str, &identity_key, &one_time_key) {
                    Ok(()) => {
                        hollow_log!("[HOLLOW-CRYPTO] Created outbound (unconfirmed) session with {peer_str} via KeyBundle");
                        persist_crypto_state(olm, crypto_store, peer_str);
                        // Keep key_request_in_flight set (refreshed): the session is
                        // outbound-only/unconfirmed until the peer replies (SessionAck or
                        // any decrypt). If our PreKey is dropped, the sweep resends.
                        // Do NOT emit SessionEstablished yet — that would be the optimistic
                        // "A sends, B never sees it" bug. Confirmation happens on SessionAck.
                        key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());

                        // Send encrypted SessionAck to upgrade the ratchet.
                        let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck)
                            .unwrap_or_default();
                        send_encrypted_message(
                            olm, crypto_store, peer_str, &ack_json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;

                        // Drain pending messages for this peer.
                        if let Some(queued) = pending_messages.remove(peer_str) {
                            hollow_log!("[HOLLOW-CRYPTO] Draining {} pending messages for {peer_str}", queued.len());
                            for text in queued {
                                send_encrypted_message(
                                    olm, crypto_store, peer_str, &text, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                        }

                        // Flush pending sync requests.
                        sync_handler::flush_pending_sync_requests(
                            pending_sync_requests, peer_str,
                            olm, crypto_store, bundle_keypair, event_tx,
                            ws_cmd_tx, ws_room_peers,
                            crdt_store,
                            db_path, db_passphrase,
                        ).await;
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-CRYPTO] Failed to create outbound session with {peer_str}: {e}");
                        key_request_in_flight.remove(peer_str);
                    }
                }
            }
        }

        HavenMessage::Encrypted { message_type, body, identity_key } => {
            let ciphertext = match OlmManager::decode_base64(&body) {
                Ok(b) => b,
                Err(e) => {
                    hollow_log!("[HOLLOW-CRYPTO] Inbound Encrypted from {peer_str}: base64 decode failed ({} B) — dropped: {e}", body.len());
                    let _ = event_tx
                        .send(NetworkEvent::Error {
                            message: format!("Failed to decode message from {peer_str}: {e}"),
                        })
                        .await;

                    return;
                }
            };

            let plaintext = if message_type == 0 {
                // PreKeyMessage — create inbound session.
                let their_identity = match &identity_key {
                    Some(k) => k,
                    None => {
                        hollow_log!("[HOLLOW-CRYPTO] Inbound PreKey from {peer_str} missing identity_key — dropped");
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("PreKeyMessage from {peer_str} missing identity_key"),
                            })
                            .await;

                        return;
                    }
                };

                let had_existing_session = olm.has_session(&peer_str);

                if had_existing_session {
                    // We have an inbound-derived session (already good). Try to decrypt
                    // the PreKey using the existing session — this handles the race where
                    // two encrypted messages arrive as PreKeys (e.g. sync batch response +
                    // regular channel message overlap). The first creates a new session,
                    // the second should decrypt with it.
                    match olm.try_decrypt_prekey_with_existing(&peer_str, &ciphertext) {
                        Ok(pt) => {
                            hollow_log!("[HOLLOW-CRYPTO] Decrypted PreKey with existing session for {peer_str}");
                            pt
                        }
                        Err(e) => {
                            // Existing session can't handle this PreKey — it's a
                            // genuinely new session from the peer (e.g. they re-keyed).
                            // Replace our session with the new inbound one.
                            hollow_log!("[HOLLOW-CRYPTO] PreKey from {peer_str} undecryptable with existing session ({e}) — rebuilding inbound session");
                            olm.remove_session(&peer_str);
                            match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                                Ok(pt) => {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_str.to_string(),
                                        })
                                        .await;
                                    // SECURITY (Issue 1-C): pin only AFTER the session
                                    // was built — vodozemac has now proven this
                                    // identity key belongs to the sender, so a forged
                                    // key can't fabricate a "they re-keyed" notice.
                                    super::security_alerts::note_olm_identity_key(
                                        event_tx, db_path, db_passphrase, master_peer_str,
                                        &super::resolver::resolve(peer_str), peer_str,
                                        their_identity,
                                    ).await;
                                    key_request_in_flight.remove(peer_str);
                                    // Send encrypted SessionAck to upgrade peer's outbound ratchet.
                                    let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
                                    send_encrypted_message(
                                        olm, crypto_store, &peer_str, &ack_json, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                    ).await;
                                    if let Some(queued) = pending_messages.remove(peer_str) {
                                        for text in queued {
                                            send_encrypted_message(
                                                olm, crypto_store, &peer_str, &text, event_tx,
                                            ws_cmd_tx, ws_room_peers,
                                            ).await;
                                        }
                                    }
                                    sync_handler::flush_pending_sync_requests(
                                        pending_sync_requests, peer_str,
                                        olm, crypto_store,
                                        bundle_keypair, event_tx,
                                        ws_cmd_tx, ws_room_peers,
                                        crdt_store,
                                        db_path, db_passphrase,
                                    ).await;
                                    pt
                                }
                                Err(e2) => {
                                    // Both paths failed. ALWAYS log the drop (the re-key
                                    // below stays cooldown-gated) — a burst of failures
                                    // must never go dark on the receive side.
                                    hollow_log!("[HOLLOW-CRYPTO] Inbound PreKey from {peer_str} undecryptable on BOTH paths: {e2} — dropped");
                                    // Apply cooldown to prevent re-key flood.
                                    let now = std::time::Instant::now();
                                    let should_rekey = match decrypt_fail_cooldown.get(peer_str) {
                                        Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                                        None => true,
                                    };
                                    if should_rekey {
                                        hollow_log!("[HOLLOW-CRYPTO] Initiating re-key with {peer_str}");
                                        decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                                        if !key_request_is_fresh(key_request_in_flight, peer_str) {
                                            key_request_in_flight.insert(peer_str.to_string(), now);
                                            send_message_to_peer(
                                                ws_cmd_tx, ws_room_peers,
                                                peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                                            );
                                        }
                                    }
                                    persist_crypto_state(olm, crypto_store, &peer_str);
                                    
                                    return;
                                }
                            }
                        }
                    }
                } else {
                    // No existing session — standard path: create inbound session.
                    match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                        Ok(pt) => {
                            let _ = event_tx
                                .send(NetworkEvent::SessionEstablished {
                                    peer_id: peer_str.to_string(),
                                })
                                .await;
                            // SECURITY (Issue 1-C): see the sibling call above —
                            // pinning after successful session creation is what makes
                            // the pinned key trustworthy.
                            super::security_alerts::note_olm_identity_key(
                                event_tx, db_path, db_passphrase, master_peer_str,
                                &super::resolver::resolve(peer_str), peer_str,
                                their_identity,
                            ).await;
                            key_request_in_flight.remove(peer_str);
                            // Send encrypted SessionAck to upgrade peer's outbound ratchet.
                            let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
                            send_encrypted_message(
                                olm, crypto_store, &peer_str, &ack_json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                            ).await;
                            if let Some(queued) = pending_messages.remove(peer_str) {
                                for text in queued {
                                    send_encrypted_message(
                                        olm, crypto_store, &peer_str, &text, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                    ).await;
                                }
                            }
                            // Re-pull any DMs the peer sent on the now-dead ratchet
                            // (the glare-desync case: the peer kept encrypting on a
                            // session we couldn't decrypt, so those messages never
                            // rendered live — exactly what a RESTART recovers via DM
                            // sync). Now that we hold a FRESH session, ask the peer to
                            // re-serve from our high-water mark; the response rides this
                            // good session and the receiver dedups by message_id. This is
                            // the live equivalent of the restart-time re-sync.
                            request_dm_resync_after_rekey(
                                &peer_str, &master_peer_str,
                                &ws_cmd_tx, &ws_room_peers, db_path, db_passphrase,
                            );
                            sync_handler::flush_pending_sync_requests(
                                pending_sync_requests, peer_str,
                                olm, crypto_store,
                                bundle_keypair, event_tx,
                                ws_cmd_tx, ws_room_peers,
                                crdt_store,
                                db_path, db_passphrase,
                            ).await;
                            pt
                        }
                        Err(e) => {
                            let now = std::time::Instant::now();
                            // ALWAYS log (was cooldown-gated → silent under a burst).
                            hollow_log!("[HOLLOW-CRYPTO] PreKey session creation FAILED for {peer_str}: {e}");
                            // Throttle the teardown bookkeeping to 5s (anti-flood) but
                            // keep nudging the peer to re-key on a shorter 2s throttle so
                            // a glare resolves live instead of stalling until restart.
                            if matches!(decrypt_fail_cooldown.get(peer_str),
                                        None) || decrypt_fail_cooldown.get(peer_str)
                                .is_some_and(|last| now.duration_since(*last) >= Duration::from_secs(5))
                            {
                                decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                            }
                            let req_throttled = key_request_in_flight
                                .get(peer_str)
                                .is_some_and(|t| now.duration_since(*t) < Duration::from_secs(2));
                            if !req_throttled {
                                key_request_in_flight.insert(peer_str.to_string(), now);
                                send_message_to_peer(
                                    ws_cmd_tx, ws_room_peers,
                                    peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                                );
                            }
                            persist_crypto_state(olm, crypto_store, &peer_str);
                            return;
                        }
                    }
                }
            } else {
                // Normal encrypted message — decrypt with existing session.
                // Capture confirmation transition: if this was an unconfirmed outbound
                // session, a successful decrypt proves the peer replied (decrypt() clears
                // outbound_only internally), so we can now report SessionEstablished.
                let was_unconfirmed = olm.has_unconfirmed_session(&peer_str);
                match olm.decrypt(&peer_str, message_type, &ciphertext) {
                    Ok(pt) => {
                        if was_unconfirmed {
                            hollow_log!("[HOLLOW-CRYPTO] Session with {peer_str} confirmed via decrypted reply");
                            key_request_in_flight.remove(peer_str);
                            let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                peer_id: peer_str.to_string(),
                            }).await;
                            // Re-pull anything missed while this session was unconfirmed
                            // / desynced (live equivalent of the restart re-sync).
                            request_dm_resync_after_rekey(
                                peer_str, &master_peer_str,
                                ws_cmd_tx, ws_room_peers, db_path, db_passphrase,
                            );
                        }
                        pt
                    }
                    Err(e) => {
                        let now = std::time::Instant::now();
                        // ALWAYS log every decrypt failure (was gated behind the 5s
                        // teardown cooldown, so a burst of undecryptable frames after a
                        // glare-desynced session went completely UNLOGGED — the bug was
                        // invisible: 40+ frames delivered by the relay, zero trace here).
                        hollow_log!("[HOLLOW-SWARM] Decrypt FAILED for {peer_str}: {e}");

                        // Tear down the (known-dead) session at most once per 5s — this
                        // throttle prevents session thrashing under a 1000-chunk file
                        // transfer where many in-flight chunks fail at once.
                        let teardown_ok = match decrypt_fail_cooldown.get(peer_str) {
                            Some(last_kill) => now.duration_since(*last_kill) >= Duration::from_secs(5),
                            None => true,
                        };
                        if teardown_ok {
                            olm.remove_session(&peer_str);
                            persist_crypto_state(olm, crypto_store, &peer_str);
                            decrypt_fail_cooldown.insert(peer_str.to_string(), now);

                            let _ = event_tx
                                .send(NetworkEvent::Error {
                                    message: format!("Stale session with {peer_str}, re-keying..."),
                                })
                                .await;

                            // Emit MessageSyncFailed for any servers where this peer is a member
                            // so the UI doesn't stay stuck on "Syncing...".
                            for (sid, state) in server_states.iter() {
                                if state.is_member(peer_str) {
                                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                                        server_id: sid.clone(),
                                        error: format!("Decrypt failed with {peer_str}, re-keying"),
                                    }).await;
                                }
                            }
                        }

                        // Send a KeyRequest to re-establish the session — independent of
                        // the teardown throttle, lightly throttled on its own (2s). The
                        // sender keeps blasting messages on its live-but-dead ratchet and
                        // the relay never ACKs, so OUR repeated KeyRequest is the only
                        // signal that drives the peer to drop its half and re-handshake.
                        // Gating this behind the 5s teardown cooldown (the old bug) made
                        // us go silent for 5s after the first failure → the glare never
                        // resolved live and only a RESTART fixed it. Once the session is
                        // rebuilt, our pending_messages queue + the peer's re-send recover
                        // the missed messages (the receiver dedups by message_id).
                        let req_throttled = key_request_in_flight
                            .get(peer_str)
                            .is_some_and(|t| now.duration_since(*t) < Duration::from_secs(2));
                        if !req_throttled {
                            key_request_in_flight.insert(peer_str.to_string(), now);
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                            );
                        }

                        return;
                    }
                }
            };

            // Persist only session ratchet after decrypt (account unchanged).
            persist_olm_session(olm, crypto_store, &peer_str);

            // Detect message envelope and route accordingly.
            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::ChannelMessage { inner }) => {
                    let ChannelMessagePayload { sid, cid, text: msg_text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us } = *inner;
                    // Multi-device: this Olm-direct path (MLS-failure fallback +
                    // offline replay) authenticates the sender's DEVICE socket,
                    // but channel messages are SIGNED by — and attributed to —
                    // the sender's MASTER. Resolve first so the signature
                    // verifies and the row is master-keyed, exactly like the
                    // MLS and public-channel paths. Verifying against the raw
                    // device id REJECTED every multi-device fallback message.
                    let sender_master = super::resolver::resolve(peer_str);
                    // SECURITY: Verify sender is a member of the claimed server.
                    if let Some(state) = server_states.get(&sid) {
                        if !state.is_member(&sender_master) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — not a member of server {sid}");
                            return;
                        }
                    } else {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage for unknown server {sid}");
                        return;
                    }

                    // SECURITY: a LIVE channel message MUST carry a signature that
                    // verifies. The old `if sig.is_some()` gate was itself the
                    // bypass — strip `sig`/`pk` and verification was skipped
                    // entirely, leaving attribution resting on the relay-reported
                    // sender id. `ChannelSyncBatch` backfill applies the same rule
                    // since 0.8.5 (`REQUIRE_SIGNED_BACKFILL`); the live-enforce /
                    // backfill-tolerate split now survives only for the moderation
                    // trio, where a mute may legitimately postdate synced history.
                    {
                        // v2 only (0.8.5) — binds the wire's structured fields.
                        let lp_digest = link_preview.as_ref().map(crypto_handler::link_preview_digest);
                        let extras = crypto_handler::SignedExtras {
                            mid: mid.as_deref(),
                            reply_to: reply_to.as_deref(),
                            file_id: file_id.as_deref(),
                            order_us,
                            lp_digest: lp_digest.as_deref(),
                        };
                        if !crypto_handler::verify_message_signature_v2(
                            &sender_master, sig.as_deref(), pk.as_deref(),
                            "ch", &format!("{sid}:{cid}"), ts, &extras, &msg_text,
                            &mut PkCache::new(),
                        ) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — signature verification FAILED");
                            return;
                        }
                    }

                    // SECURITY: Enforce the 4,000 byte storage limit (already
                    // signature-verified above, against the raw text). Char-boundary
                    // safe: the old `msg_text[..4000]` PANICKED when byte 4,000 landed
                    // inside a multi-byte character, aborting the swarm event loop on a
                    // remote-controlled string.
                    let msg_text = clip_text(msg_text);

                    // Multi-device: a message authored by ANY of our own devices is ours.
                    let is_mine = super::resolver::same_identity(&sender_master, &local_peer_str);

                    // Persist channel message using sender's timestamp.
                    // Dedup by message_id (replays); the content UNIQUE index
                    // is legacy-only now (WHERE message_id IS NULL) — it used
                    // to swallow DISTINCT identical-text messages landing in
                    // the same millisecond, dropping the second message.
                    let mut is_new = true;
                    let mut reply_to_own = false;
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        // Reply-to-ME flag for the mentions-only notification
                        // gate (#42) — parent row's author vs our identity.
                        reply_to_own = reply_to.as_deref()
                            .and_then(|m| store.get_channel_message_sender(m))
                            .is_some_and(|a| super::resolver::same_identity(&a, &local_peer_str));
                        let already = mid.as_deref()
                            .map(|m| store.channel_message_exists(m))
                            .unwrap_or(false);
                        if already {
                            is_new = false;
                        } else {
                            match store.insert_channel_message(
                                &sid, &cid, &sender_master, &msg_text, is_mine, ts,
                                sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                reply_to.as_deref(), file_id.as_deref(), order_us,
                            ) {
                                Ok(0) => { is_new = false; } // Duplicate (legacy no-mid row)
                                Ok(_) => {}
                                Err(_) => { is_new = false; }
                            }
                        }
                        // Persist link preview for this message if present (Phase 6.75).
                        if is_new {
                            if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid.as_ref()) {
                                if let Ok(lp_json) = serde_json::to_string(lp) {
                                    let _ = store.update_channel_link_preview(message_id, &lp_json);
                                }
                            }
                        }
                    }

                    // ALWAYS emit — a ChannelSyncBatch racing this live message
                    // (channel-open fires requestChannelSync) inserts the row
                    // first without emitting; suppressing the live event too
                    // left the open pane stale. Dart dedups by message_id and
                    // skips unread/notifications when `duplicate`.
                    let _ = event_tx
                        .send(NetworkEvent::ChannelMessageReceived {
                            server_id: sid,
                            channel_id: cid,
                            from_peer: sender_master,
                            text: msg_text,
                            timestamp: ts,
                            message_id: mid.unwrap_or_default(),
                            reply_to_mid: reply_to.unwrap_or_default(),
                            link_preview,
                            signature: sig,
                            public_key: pk,
                            reply_to_own,
                            duplicate: !is_new,
                        })
                        .await;
                }
                Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, .. }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} sync messages for {cid} in {sid} (total: {total}, has_more: {has_more:?})", messages.len());
                    let local_peer = local_peer_str.to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.begin_transaction();
                        let mut pk_cache = PkCache::new();
                        for msg in &messages {
                            // Backfill signature rule (0.8.5): Valid or nothing —
                            // an unsigned item is an injection that can claim ANY
                            // sender via `msg.s`. An edited row verifies against its
                            // EDIT signature (edited_at + current text). See
                            // `check_backfill_signature`.
                            // Recomputed from the shipped card when there is
                            // one — that is what makes the preview
                            // signature-covered (`backfill_lp_digest`).
                            let lp_digest = crypto_handler::backfill_lp_digest(
                                msg.lp.as_deref(), msg.lp_digest.as_deref(),
                            );
                            let extras = crypto_handler::SignedExtras {
                                mid: msg.mid.as_deref(),
                                reply_to: msg.reply_to.as_deref(),
                                file_id: msg.file_id.as_deref(),
                                order_us: msg.order_us,
                                lp_digest: lp_digest.as_deref(),
                            };
                            let sig_check = check_backfill_signature(
                                &msg.s, "ch", &format!("{sid}:{cid}"),
                                msg.ts, msg.edited_at, &extras, &msg.t,
                                msg.sig.as_deref(), msg.pk.as_deref(), &mut pk_cache,
                            );
                            // SECURITY: drop the whole item — text, edit, file
                            // metadata, reactions and the hidden flag all ride it.
                            if !sig_check.is_acceptable() {
                                hollow_log!(
                                    "[HOLLOW-SECURITY] REJECTED synced channel message in {sid}/{cid} claiming sender {} — {} (mid={:?}, ts={}, text_len={}, has_pk={})",
                                    msg.s, sig_check.reject_reason(), msg.mid, msg.ts, msg.t.len(), msg.pk.is_some()
                                );
                                continue;
                            }
                            let sig_verified = sig_check == BackfillSig::Valid;

                            let is_mine = msg.s == local_peer;
                            let already_exists = msg.mid.as_ref()
                                .map(|mid| store.channel_message_exists(mid))
                                .unwrap_or(false);

                            if !already_exists {
                                match store.insert_channel_message(
                                    &sid, &cid, &msg.s, &msg.t, is_mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(), msg.order_us,
                                ) {
                                    Ok(1) => {
                                        new_count += 1;
                                        if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                            let _ = store.set_channel_message_edited_at(mid, edit_ts);
                                        }
                                    }
                                    _ => {}
                                }
                            } else if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                let _ = store.edit_channel_message(
                                    mid, &msg.t, edit_ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(),
                                );
                            } else if sig_verified {
                                // Multi-device self-heal: the row already exists but may
                                // have been stored under a sender DEVICE id (pre device→
                                // master resolve fix) with signature material that no
                                // longer verifies on this device — the "12D3KooW… +
                                // unverified signature" bubble. This synced copy's sig
                                // VERIFIED (authentic sender + text), so if our stored row
                                // is attributed to a different sender, repair it to the
                                // verified one. INSERT OR IGNORE blocked re-inserting the
                                // good copy, so this UPDATE is the only path to converge.
                                // Safe: we only ever replace with a cryptographically
                                // verified attribution (can't be used to forge).
                                if let Some(mid) = &msg.mid {
                                    let stored_sender = store.get_channel_message_sender(mid);
                                    if stored_sender.as_deref() != Some(msg.s.as_str()) {
                                        match store.repair_channel_message_sender(
                                            mid, &msg.s, is_mine,
                                            msg.sig.as_deref(), msg.pk.as_deref(),
                                        ) {
                                            Ok(true) => hollow_log!(
                                                "[HOLLOW-SYNC] Repaired channel msg {mid} sender {stored_sender:?} → {} (verified)", msg.s
                                            ),
                                            _ => {}
                                        }
                                    }
                                }
                            }

                            // The card the item's signature covers. Runs on
                            // every branch above — fresh row, pre-existing
                            // card-less row, edited row — so a peer catching
                            // up gets the preview with the message instead of
                            // a bare link. See `apply_synced_link_preview`.
                            if sig_verified
                                && let (Some(lp), Some(mid)) = (msg.lp.as_deref(), &msg.mid)
                                && message_ops::apply_synced_link_preview(
                                    &store, true, mid, &msg.t,
                                    lp, msg.sig.as_deref(), msg.pk.as_deref(),
                                )
                            {
                                let _ = event_tx.send(NetworkEvent::ChannelLinkPreviewUpdated {
                                    server_id: sid.clone(),
                                    channel_id: cid.clone(),
                                    message_id: mid.clone(),
                                    preview: Some(lp.clone()),
                                }).await;
                            }

                            // Apply deletion if the message was hidden on the syncing peer —
                            // ONLY with the author's own deletion proof (REJECT-ABSENT, 0.8.4).
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                let _ = message_ops::apply_verified_channel_deletion(
                                    &store, &sid, &cid, mid, hidden_ts,
                                    msg.hidden_sig.as_deref(), msg.hidden_pk.as_deref(),
                                    &mut pk_cache,
                                );
                            }

                            // Insert file metadata and emit FileHeaderReceived for late joiners.
                            // The item's v2 signature binds `file_id`, NOT this
                            // file_meta blob — so the owner guard is what stops a
                            // responder relabelling someone else's attachment.
                            if let Some(ref fm) = msg.file_meta
                                .as_ref()
                                .filter(|fm| file_handler::file_meta_write_allowed(&store, &fm.fid, &fm.sender))
                            {
                                let ctx_id = format!("{sid}:{cid}");
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    fm.mid.as_deref(), "channel", &ctx_id,
                                    &fm.sender, msg.s == local_peer, fm.ts,
                                    fm.vthumb.as_ref(),
                                    file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime).as_deref(),
                                );
                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fm.fid.clone(),
                                    file_name: fm.name.clone(),
                                    size_bytes: fm.size,
                                    is_image: fm.img,
                                    width: fm.w,
                                    height: fm.h,
                                    message_id: fm.mid.clone().unwrap_or_default(),
                                    sender_id: fm.sender.clone(),
                                    server_id: sid.clone(),
                                    channel_id: cid.clone(),
                                    video_thumb: fm.vthumb.clone(),
                                    share_ref: None,
                                    thumb_b64: file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime),
                                }).await;
                            }

                            // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                            // Each reaction names its own reactor, so it carries
                            // its own signature check — the item verdict above
                            // covers the message, not the reactions on it.
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
                                    if !message_ops::sync_reaction_accepted(mid, r) {
                                        continue;
                                    }
                                    let _ = store.add_reaction(
                                        mid, &r.e, &r.p, r.ts,
                                        r.sig.as_deref(), r.pk.as_deref(),
                                    );
                                }
                            }
                        }
                        let _ = store.commit_transaction();

                        // Pagination: if has_more, send a follow-up ChannelSyncRequest
                        // with updated per-sender timestamps from our DB.
                        if has_more == Some(true) {
                            let sender_ts = store
                                .get_per_sender_timestamps(&sid, &cid)
                                .unwrap_or_default();
                            let since = store
                                .get_latest_channel_timestamp(&sid, &cid)
                                .unwrap_or(None)
                                .unwrap_or(0);
                            hollow_log!("[HOLLOW-SYNC] Requesting next page for {cid} in {sid}");
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, HavenMessage::ChannelSyncRequest {
                                    server_id: sid.clone(),
                                    channel_id: cid.clone(),
                                    since_timestamp: since,
                                    sender_timestamps: sender_ts,
                                },
                            );
                        }
                    }

                    // Emit progress so the UI can show "Syncing 47/120..."
                    if total > 0 {
                        let _ = event_tx.send(NetworkEvent::MessageSyncProgress {
                            server_id: sid.clone(),
                            channel_id: cid.clone(),
                            received_count,
                            total_count: total,
                        }).await;
                    }

                    // Only emit completion when there are no more pages.
                    if has_more != Some(true) {
                        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                            server_id: sid.clone(),
                            new_message_count: new_count,
                        }).await;

                        // File sync happens from the Dart side after a delay
                        // to avoid interfering with the message sync pipeline.
                    }
                }
                Ok(MessageEnvelope::DirectMessage { inner }) => {
                    let DirectMessagePayload { text: msg_text, ts, sig, pk, mid, reply_to, file_id, link_preview, convo, order_us } = *inner;
                    // NOTE: the length clamp lives AFTER signature verification —
                    // the signature covers the text the sender actually sent, so
                    // clipping first would invalidate it. See below.

                    // Multi-device: attribute the DM to the sender's MASTER identity
                    // so messages from any of a friend's devices land in the single
                    // DM thread (and our own other-device sends attribute to us).
                    // Pre-multi-device this resolves to peer_str unchanged.
                    let is_own_device = super::resolver::same_identity(&peer_str, master_peer_str);
                    // Self fan-out (Step 3): a copy echoed from our OWN sibling carries
                    // `convo` = the OTHER party's master, so we file it under the real
                    // conversation rather than resolving it to ourselves (the sender).
                    // For a normal DM from a friend, `convo` is None → resolve the sender.
                    // PHANTOM-CHAT GUARD (Step 7): drop a DM from a device we just
                    // revoked but that is still alive and talking. Without this, a
                    // revoked device that hasn't yet self-nuked keeps sending DMs;
                    // since we `forget`-ed its device→master link, `resolve` returns
                    // its own id → the message spawns a standalone "unknown peer"
                    // conversation (the phantom chat). Drop it; it stops for good once
                    // the device self-nukes / disconnects.
                    if super::resolver::is_revoked(&peer_str) {
                        hollow_log!("[HOLLOW-REVOKE] Dropped DM from revoked-but-alive device {peer_str}");
                        return;
                    }
                    // BLOCK GUARD: drop before store + emit — a blocked identity's
                    // DM never reaches the DB, UI, or notifications. Own sibling
                    // echoes are exempt (you can't block yourself).
                    if !is_own_device && super::blocklist::is_blocked(&peer_str) {
                        return;
                    }
                    let convo_peer = match (is_own_device, convo.as_deref()) {
                        (true, Some(c)) => c.to_string(),
                        _ => super::resolver::resolve(&peer_str),
                    };

                    // SECURITY: a DM whose signature does not verify is DROPPED.
                    //
                    // This signature is the ONLY thing binding DM content to the
                    // sender's Ed25519 identity. The Olm session it arrived on proves
                    // only that someone holds the ratchet, and the KeyBundle that
                    // established that ratchet is itself unauthenticated (no
                    // signature, no pinning), so a hostile relay can sit in the
                    // middle. Verifying-then-storing-anyway (the old behaviour: log,
                    // no `return`) meant such a relay could FORGE DM content, not
                    // merely read it.
                    //
                    // A MISSING signature is rejected too. The old `if sig.is_some()`
                    // gate was itself the bypass: strip `sig`/`pk` and verification
                    // was skipped entirely. `verify_message_signature` already returns
                    // false for None, so the gate is simply gone. Signed DMs have been
                    // mandatory since e2cc8ab (2026-03-09).
                    //
                    // Verified against the RAW text, before the length clamp: the
                    // sender signed what they sent, and a 4,000-CHARACTER composer
                    // limit is up to ~16,000 BYTES in Cyrillic/CJK/emoji. Clipping
                    // first would have dropped every long non-Latin DM.
                    //
                    // Signer/context are SWAPPED for a self fan-out echo
                    // (`is_own_device`, our OWN sibling mirroring a message WE sent):
                    // WE signed it and the FRIEND (`convo_peer`) was the recipient.
                    {
                        let (recipient_m, signer_m): (&str, &str) = if is_own_device {
                            (&convo_peer, master_peer_str)
                        } else {
                            (master_peer_str, &convo_peer)
                        };
                        // v2 only (0.8.5) — binds the wire's structured fields.
                        let lp_digest = link_preview.as_ref().map(crypto_handler::link_preview_digest);
                        let extras = crypto_handler::SignedExtras {
                            mid: mid.as_deref(),
                            reply_to: reply_to.as_deref(),
                            file_id: file_id.as_deref(),
                            order_us,
                            lp_digest: lp_digest.as_deref(),
                        };
                        if !crypto_handler::verify_message_signature_v2(
                            signer_m, sig.as_deref(), pk.as_deref(),
                            "dm", recipient_m, ts, &extras, &msg_text,
                            &mut PkCache::new(),
                        ) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED DM from {peer_str} (signer {signer_m}) — signature verification FAILED");
                            return;
                        }
                    }

                    // Enforce the 4,000 byte storage limit, char-boundary safe: the
                    // old `msg_text[..4000]` PANICKED when byte 4,000 landed inside a
                    // multi-byte character, aborting the swarm event loop on a
                    // remote-controlled string.
                    let msg_text = clip_text(msg_text);

                    // Persist received DM using sender's timestamp (not Dart DateTime.now()).
                    // This ensures DM sync timestamps are consistent for deduplication.
                    // `is_own` flags a message echoed from our OWN other device as ours.
                    let mut is_new = true;
                    {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            // Dedup by message_id (replays: reconnect resend,
                            // pending drain, relay buffer). The content UNIQUE
                            // index is legacy-only now (WHERE message_id IS
                            // NULL) — it used to swallow DISTINCT identical-text
                            // messages landing in the same millisecond, dropping
                            // the second message and its MessageReceived event.
                            let already = mid.as_deref()
                                .map(|m| store.dm_message_exists(m))
                                .unwrap_or(false);
                            if already {
                                is_new = false;
                            } else {
                                match store.insert(
                                    &convo_peer, &msg_text, is_own_device, ts,
                                    sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                    reply_to.as_deref(), file_id.as_deref(), order_us,
                                ) {
                                    Ok(0) => { is_new = false; } // Duplicate (legacy no-mid row)
                                    Ok(_) => {}
                                    Err(_) => { is_new = false; }
                                }
                            }
                            // Persist link preview for this message if present (Phase 6.75).
                            if is_new {
                                if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid.as_ref()) {
                                    if let Ok(lp_json) = serde_json::to_string(lp) {
                                        let _ = store.update_link_preview(message_id, &lp_json);
                                    }
                                }
                            }
                        }
                    }

                    // ALWAYS emit — even when the row already existed. A sync
                    // batch racing this live delivery (chat-open triggers
                    // DmSyncRequest) inserts the row first WITHOUT emitting
                    // per-message events; suppressing the live event too left
                    // an OPEN chat stale until re-entry (typing animated,
                    // messages never appeared). The in-memory list dedups by
                    // message_id, and Dart skips unread/notifications when
                    // `duplicate` — so replays can't double-count.
                    let _ = event_tx
                        .send(NetworkEvent::MessageReceived {
                            from_peer: convo_peer.to_string(),
                            text: msg_text,
                            timestamp: ts,
                            message_id: mid.unwrap_or_default(),
                            reply_to_mid: reply_to.unwrap_or_default(),
                            link_preview,
                            signature: sig,
                            public_key: pk,
                            // Sibling echo of our OWN send → render outgoing.
                            is_own: is_own_device,
                            duplicate: !is_new,
                        })
                        .await;
                }
                Ok(MessageEnvelope::DmSyncBatch { messages, has_more }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} DM sync messages from {peer_str} (has_more: {has_more:?})", messages.len());
                    let local_peer = local_peer_str.to_string();
                    // Multi-device: the DM conversation key is the sender's MASTER id
                    // (transport target stays raw `peer_str`). No-op on single-device.
                    let convo_peer = super::resolver::resolve(&peer_str);
                    // BLOCK GUARD: a blocked friend must not backfill history
                    // through the sync path either. Siblings are exempt.
                    if !super::resolver::same_identity(&peer_str, local_peer_str)
                        && super::blocklist::is_blocked(&peer_str)
                    {
                        return;
                    }
                    // CRITICAL — `DmSyncItem.mine` is RESPONDER-relative (it's
                    // `is_mine` as stored in the SENDER's DB). A FRIEND's perspective is
                    // the OPPOSITE of ours: a message the friend SENT (their is_mine=1)
                    // is one WE RECEIVED (our is_mine=false), and a message the friend
                    // RECEIVED from us (their is_mine=0) is one WE SENT (our is_mine=
                    // true). So on the friend path we INVERT. From our own SIBLING
                    // (same_identity) is_mine already means the same on both our devices
                    // — keep as-is. (The pre-both-directions one-directional path served
                    // only the friend's own sends and hardcoded the insert to `false`,
                    // i.e. it was implicitly `!mine` for that single case — this
                    // generalizes it correctly to both directions.)
                    let from_sibling = super::resolver::same_identity(&peer_str, &local_peer);
                    let mut new_count = 0u32;

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.begin_transaction();
                        let mut pk_cache = PkCache::new();
                        for msg in &messages {
                            // Effective direction from OUR perspective (see the
                            // responder-relative note above): invert on the friend
                            // path, keep as-is from a sibling.
                            let is_mine = if from_sibling { msg.mine } else { !msg.mine };

                            // CRITICAL (multi-device): the signer is always a
                            // MASTER id, never the raw device id `peer_str` the
                            // relay reported. The original sig context is the
                            // FRIEND conversation, direction-dependent on OUR
                            // effective `is_mine`:
                            //   is_mine=true  → sender = our master, recipient = convo
                            //   is_mine=false → sender = convo,      recipient = our master
                            // (mirrors the sibling-batch receiver below). Verifying
                            // against the wrong end failed EVERY signature for a
                            // multi-device friend (the "Sig verify FAILED" flood).
                            let (sender_m, recipient_m): (&str, &str) = if is_mine {
                                (&local_peer, &convo_peer)
                            } else {
                                (&convo_peer, &local_peer)
                            };
                            // Backfill signature rule (0.8.5): Valid or nothing.
                            // The digest is recomputed from the shipped card
                            // when there is one (`backfill_lp_digest`).
                            let lp_digest = crypto_handler::backfill_lp_digest(
                                msg.lp.as_deref(), msg.lp_digest.as_deref(),
                            );
                            let extras = crypto_handler::SignedExtras {
                                mid: msg.mid.as_deref(),
                                reply_to: msg.reply_to.as_deref(),
                                file_id: msg.file_id.as_deref(),
                                order_us: msg.order_us,
                                lp_digest: lp_digest.as_deref(),
                            };
                            let sig_check = check_backfill_signature(
                                sender_m, "dm", recipient_m,
                                msg.ts, msg.edited_at, &extras, &msg.t,
                                msg.sig.as_deref(), msg.pk.as_deref(), &mut pk_cache,
                            );
                            // SECURITY: drop the whole item — the edit, file metadata,
                            // reactions and hidden flag all ride it.
                            if !sig_check.is_acceptable() {
                                hollow_log!(
                                    "[HOLLOW-SECURITY] REJECTED synced DM from {peer_str} (master {convo_peer}, is_mine={is_mine}) — {} (mid={:?}, ts={}, text_len={}, has_pk={})",
                                    sig_check.reject_reason(), msg.mid, msg.ts, msg.t.len(), msg.pk.is_some()
                                );
                                continue;
                            }

                            let already_exists = msg.mid.as_ref()
                                .map(|mid| store.dm_message_exists(mid))
                                .unwrap_or(false);
                            hollow_log!(
                                "[HOLLOW-SYNC] dm item mid={:?} ts={} wire_mine={} is_mine={is_mine} edited_at={:?} exists={} text_len={}",
                                msg.mid, msg.ts, msg.mine, msg.edited_at, already_exists, msg.t.len()
                            );

                            // Reconcile against a row delivered via another path
                            // (e.g. offline fetch) that has a NULL/different mid.
                            // Without this, an edited message whose original was
                            // fetched separately would insert as a duplicate row.
                            let reconciled = if !already_exists {
                                if let Some(mid) = msg.mid.as_deref() {
                                    store.reconcile_dm_by_timestamp(
                                        &convo_peer, mid, &msg.t, msg.ts, msg.edited_at,
                                        msg.sig.as_deref(), msg.pk.as_deref(),
                                    ).unwrap_or(false)
                                } else {
                                    false
                                }
                            } else {
                                false
                            };
                            if reconciled {
                                hollow_log!("[HOLLOW-SYNC] reconciled dm mid={:?} into existing row", msg.mid);
                                if let Some(mid) = &msg.mid {
                                    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        new_text: msg.t.clone(),
                                        edited_at: msg.edited_at.unwrap_or(msg.ts),
                                        signature: msg.sig.clone(),
                                        public_key: msg.pk.clone(),
                                    }).await;
                                }
                            }

                            if !already_exists && !reconciled {
                                match store.insert(
                                    &convo_peer, &msg.t, is_mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(), msg.order_us,
                                ) {
                                    Ok(id) if id > 0 => {
                                        new_count += 1;
                                        // Stamp edited_at directly for freshly inserted edited messages.
                                        // edit_dm_message would skip (old_text == new_text).
                                        if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                            let _ = store.set_dm_message_edited_at(mid, edit_ts);
                                        }
                                    }
                                    _ => {}
                                }
                            } else if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                // Message already exists — apply edit if text differs.
                                let edit_result = store.edit_dm_message(
                                    mid, &msg.t, edit_ts,
                                    msg.sig.as_deref(),
                                    msg.pk.as_deref(),
                                );
                                if edit_result.unwrap_or(false) {
                                    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        new_text: msg.t.clone(),
                                        edited_at: edit_ts,
                                        signature: msg.sig.clone(),
                                        public_key: msg.pk.clone(),
                                    }).await;
                                } else {
                                    // Text already matches (pending drain delivered edited text)
                                    // but edited_at may be missing — stamp it.
                                    let _ = store.set_dm_message_edited_at(mid, edit_ts);
                                }
                            }

                            // The card the item's signature covers. Runs on
                            // every branch above — fresh row, pre-existing
                            // card-less row, edited row — so a friend catching
                            // up after being offline gets the preview with the
                            // message. See `apply_synced_link_preview`.
                            if sig_check == BackfillSig::Valid
                                && let (Some(lp), Some(mid)) = (msg.lp.as_deref(), &msg.mid)
                                && message_ops::apply_synced_link_preview(
                                    &store, false, mid, &msg.t,
                                    lp, msg.sig.as_deref(), msg.pk.as_deref(),
                                )
                            {
                                let _ = event_tx.send(NetworkEvent::DmLinkPreviewUpdated {
                                    peer_id: convo_peer.clone(),
                                    message_id: mid.clone(),
                                    preview: Some(lp.clone()),
                                }).await;
                            }

                            // Apply deletion if the message was hidden on the syncing peer —
                            // ONLY with the author's own deletion proof (REJECT-ABSENT, 0.8.4).
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                if message_ops::apply_verified_dm_deletion(
                                    &store, &local_peer, mid, hidden_ts,
                                    msg.hidden_sig.as_deref(), msg.hidden_pk.as_deref(),
                                    &mut pk_cache,
                                ) {
                                    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        deleted_at: hidden_ts,
                                    }).await;
                                }
                            }

                            // Insert file metadata and emit FileHeaderReceived for late joiners.
                            // DM file context = the conversation MASTER (`convo_peer`),
                            // NOT the raw device id, so it matches where the message row
                            // is stored and `_reloadChatForFile` reloads the right thread.
                            // Owner guard: see the channel batch above.
                            if let Some(ref fm) = msg.file_meta
                                .as_ref()
                                .filter(|fm| file_handler::file_meta_write_allowed(&store, &fm.fid, &fm.sender))
                            {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    fm.mid.as_deref(), "dm", &convo_peer,
                                    &fm.sender, false, fm.ts,
                                    fm.vthumb.as_ref(),
                                    file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime).as_deref(),
                                );
                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fm.fid.clone(),
                                    file_name: fm.name.clone(),
                                    size_bytes: fm.size,
                                    is_image: fm.img,
                                    width: fm.w,
                                    height: fm.h,
                                    message_id: fm.mid.clone().unwrap_or_default(),
                                    sender_id: fm.sender.clone(),
                                    server_id: String::new(),
                                    channel_id: convo_peer.clone(),
                                    video_thumb: fm.vthumb.clone(),
                                    share_ref: None,
                                    thumb_b64: file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime),
                                }).await;
                            }

                            // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                            // Signature-checked per reaction; see the channel batch.
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
                                    if !message_ops::sync_reaction_accepted(mid, r) {
                                        continue;
                                    }
                                    let _ = store.add_reaction(
                                        mid, &r.e, &r.p, r.ts,
                                        r.sig.as_deref(), r.pk.as_deref(),
                                    );
                                }
                            }
                        }
                        let _ = store.commit_transaction();

                        // Pagination: if has_more, send follow-up DmSyncRequest.
                        // Carry the multi-device both-direction mode forward — else
                        // the next page reverts to is_mine=0-only and re-strands our
                        // own sends past message 200.
                        if has_more == Some(true) {
                            let multi_device =
                                !super::resolver::devices_for(master_peer_str).is_empty();
                            let since = if multi_device {
                                store.get_latest_dm_timestamp_any(&convo_peer)
                            } else {
                                store.get_latest_dm_timestamp(&convo_peer)
                            }
                            .unwrap_or(None)
                            .unwrap_or(0);
                            hollow_log!("[HOLLOW-SYNC] Requesting next DM page from {peer_str} since {since} (both_directions={multi_device})");
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, HavenMessage::DmSyncRequest {
                                    since_timestamp: since,
                                    both_directions: multi_device,
                                },
                            );
                        }
                    }

                    hollow_log!("[HOLLOW-SYNC] DM sync: {new_count} new messages from {peer_str}");
                    // Always emit DmSyncCompleted — even with 0 new messages.
                    // Dart may have cleared its in-memory cache on disconnect;
                    // this tells it to reload from DB regardless.
                    // Only emit completion when there are no more pages.
                    if has_more != Some(true) {
                        let _ = event_tx.send(NetworkEvent::DmSyncCompleted {
                            peer_id: convo_peer.clone(),
                            new_message_count: new_count,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::DmSiblingSyncBatch { convo, messages, has_more }) => {
                    // Multi-device (Phase 6 / Step 5): a sibling backfilled one of our
                    // conversations. Honor ONLY from our own other device.
                    if !super::resolver::same_identity(&peer_str, local_peer_str) {
                        hollow_log!("[HOLLOW-SYNC] Dropped DmSiblingSyncBatch from non-self peer {peer_str}");
                        return;
                    }
                    hollow_log!("[HOLLOW-SYNC] Received {} sibling DM(s) for convo {convo} from {peer_str} (has_more: {has_more:?})", messages.len());
                    let local_peer = local_peer_str.to_string();
                    // File these under the REAL conversation (the friend's master),
                    // NOT resolve(peer_str) (which would be our own master, since the
                    // sender is our sibling). Each item carries its own `mine` so both
                    // directions land on the correct side.
                    let convo_peer = convo.clone();
                    let mut new_count = 0u32;

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.begin_transaction();
                        let mut pk_cache = PkCache::new();
                        for msg in &messages {
                            // The original sig context is the FRIEND conversation, not us:
                            //   mine=true  → sender = our master, recipient = convo
                            //   mine=false → sender = convo,      recipient = our master
                            // The claimed signer (whose pubkey is checked) is the SENDER master.
                            let (sender_m, recipient_m): (&str, &str) = if msg.mine {
                                (&local_peer, &convo_peer)
                            } else {
                                (&convo_peer, &local_peer)
                            };
                            // Backfill signature rule (0.8.5): Valid or nothing. A
                            // sibling is still only as trustworthy as the batch it
                            // forwards — including the cards in it, which is why
                            // the digest comes from the shipped preview.
                            let lp_digest = crypto_handler::backfill_lp_digest(
                                msg.lp.as_deref(), msg.lp_digest.as_deref(),
                            );
                            let extras = crypto_handler::SignedExtras {
                                mid: msg.mid.as_deref(),
                                reply_to: msg.reply_to.as_deref(),
                                file_id: msg.file_id.as_deref(),
                                order_us: msg.order_us,
                                lp_digest: lp_digest.as_deref(),
                            };
                            let sig_check = check_backfill_signature(
                                sender_m, "dm", recipient_m,
                                msg.ts, msg.edited_at, &extras, &msg.t,
                                msg.sig.as_deref(), msg.pk.as_deref(), &mut pk_cache,
                            );
                            if !sig_check.is_acceptable() {
                                hollow_log!(
                                    "[HOLLOW-SECURITY] REJECTED sibling DM from {peer_str} (convo {convo_peer}, mine={}) — {} (mid={:?}, ts={})",
                                    msg.mine, sig_check.reject_reason(), msg.mid, msg.ts
                                );
                                continue;
                            }

                            let already_exists = msg.mid.as_ref()
                                .map(|mid| store.dm_message_exists(mid))
                                .unwrap_or(false);

                            // Reconcile against a row delivered via another path with a
                            // NULL/different mid (same guard as the friend batch).
                            let reconciled = if !already_exists {
                                if let Some(mid) = msg.mid.as_deref() {
                                    store.reconcile_dm_by_timestamp(
                                        &convo_peer, mid, &msg.t, msg.ts, msg.edited_at,
                                        msg.sig.as_deref(), msg.pk.as_deref(),
                                    ).unwrap_or(false)
                                } else {
                                    false
                                }
                            } else {
                                false
                            };
                            if reconciled {
                                if let Some(mid) = &msg.mid {
                                    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        new_text: msg.t.clone(),
                                        edited_at: msg.edited_at.unwrap_or(msg.ts),
                                        signature: msg.sig.clone(),
                                        public_key: msg.pk.clone(),
                                    }).await;
                                }
                            }

                            if !already_exists && !reconciled {
                                match store.insert(
                                    &convo_peer, &msg.t, msg.mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(), msg.order_us,
                                ) {
                                    Ok(id) if id > 0 => {
                                        new_count += 1;
                                        if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                            let _ = store.set_dm_message_edited_at(mid, edit_ts);
                                        }
                                        // NOTE: deliberately do NOT emit a per-message
                                        // MessageReceived here. That event drives the
                                        // unread counter (`onDmMessage` INCREMENTS), so
                                        // replaying a whole conversation's history as
                                        // live MessageReceived events inflated the unread
                                        // pill with already-seen messages (Home "Recent"
                                        // + friends-bar pill regression). Instead the
                                        // batch's terminal `DmSyncCompleted` triggers
                                        // Dart `loadHistory` (shows the messages, sorted)
                                        // + `recomputeDmUnread` (counts from the DB
                                        // against the seen-pointer — idempotent, no
                                        // over-count). This mirrors the friend
                                        // `DmSyncBatch` path exactly.
                                    }
                                    _ => {}
                                }
                            } else if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                let edit_result = store.edit_dm_message(
                                    mid, &msg.t, edit_ts,
                                    msg.sig.as_deref(),
                                    msg.pk.as_deref(),
                                );
                                if edit_result.unwrap_or(false) {
                                    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        new_text: msg.t.clone(),
                                        edited_at: edit_ts,
                                        signature: msg.sig.clone(),
                                        public_key: msg.pk.clone(),
                                    }).await;
                                } else {
                                    let _ = store.set_dm_message_edited_at(mid, edit_ts);
                                }
                            }

                            // The card the item's signature covers, so a sibling
                            // that was offline gets the preview alongside the
                            // message. See `apply_synced_link_preview`.
                            if sig_check == BackfillSig::Valid
                                && let (Some(lp), Some(mid)) = (msg.lp.as_deref(), &msg.mid)
                                && message_ops::apply_synced_link_preview(
                                    &store, false, mid, &msg.t,
                                    lp, msg.sig.as_deref(), msg.pk.as_deref(),
                                )
                            {
                                let _ = event_tx.send(NetworkEvent::DmLinkPreviewUpdated {
                                    peer_id: convo_peer.clone(),
                                    message_id: mid.clone(),
                                    preview: Some(lp.clone()),
                                }).await;
                            }

                            // Apply deletion if hidden on the sibling — ONLY with the
                            // author's own deletion proof (REJECT-ABSENT, 0.8.4).
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                if message_ops::apply_verified_dm_deletion(
                                    &store, &local_peer, mid, hidden_ts,
                                    msg.hidden_sig.as_deref(), msg.hidden_pk.as_deref(),
                                    &mut pk_cache,
                                ) {
                                    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        deleted_at: hidden_ts,
                                    }).await;
                                }
                            }

                            // File metadata (so the card renders; bytes fetch on demand).
                            // Owner guard: see the channel batch above.
                            if let Some(ref fm) = msg.file_meta
                                .as_ref()
                                .filter(|fm| file_handler::file_meta_write_allowed(&store, &fm.fid, &fm.sender))
                            {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    fm.mid.as_deref(), "dm", &convo_peer,
                                    &fm.sender, false, fm.ts,
                                    fm.vthumb.as_ref(),
                                    file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime).as_deref(),
                                );
                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fm.fid.clone(),
                                    file_name: fm.name.clone(),
                                    size_bytes: fm.size,
                                    is_image: fm.img,
                                    width: fm.w,
                                    height: fm.h,
                                    message_id: fm.mid.clone().unwrap_or_default(),
                                    sender_id: fm.sender.clone(),
                                    server_id: String::new(),
                                    channel_id: convo_peer.clone(),
                                    video_thumb: fm.vthumb.clone(),
                                    share_ref: None,
                                    thumb_b64: file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime),
                                }).await;
                            }

                            // Reactions (INSERT OR IGNORE — idempotent).
                            // Signature-checked per reaction; see the channel batch.
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
                                    if !message_ops::sync_reaction_accepted(mid, r) {
                                        continue;
                                    }
                                    let _ = store.add_reaction(
                                        mid, &r.e, &r.p, r.ts,
                                        r.sig.as_deref(), r.pk.as_deref(),
                                    );
                                }
                            }
                        }
                        let _ = store.commit_transaction();

                        // Pagination: this convo has more — re-request it from the new high-water.
                        if has_more == Some(true) {
                            let since = store
                                .get_latest_dm_timestamp_any(&convo_peer)
                                .unwrap_or(None)
                                .unwrap_or(0);
                            hollow_log!("[HOLLOW-SYNC] Requesting next sibling DM page for {convo_peer} from {peer_str} since {since}");
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                &peer_str, HavenMessage::DmSiblingSyncRequest {
                                    per_convo_since: vec![(convo_peer.clone(), since)],
                                },
                            );
                        }
                    }

                    hollow_log!("[HOLLOW-SYNC] Sibling DM sync: {new_count} new messages for convo {convo_peer}");
                    if has_more != Some(true) {
                        let _ = event_tx.send(NetworkEvent::DmSyncCompleted {
                            peer_id: convo_peer.clone(),
                            new_message_count: new_count,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-EDIT] Received edit for message {mid} from {peer_str}");

                    // Moderation (LIVE ingest, channel edits only): drop edits from
                    // muted members — mirrors the MLS twin in message_ops.rs.
                    if message_ops::live_muted_ingest_drop(
                        sid.as_deref().and_then(|s| server_states.get(s)), &peer_str, "edit",
                    ) {
                        return;
                    }

                    // Persist the edit to local DB (preserves old text).
                    let mut edit_applied = false;
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        if sid.is_some() {
                            // Channel edit — verify sender owns the message.
                            let sender = store.get_channel_message_sender(&mid);
                            if sender.as_deref() == Some(&peer_str) {
                                // SECURITY: a LIVE edit must carry a signature that
                                // verifies (v2 binds the row's structural fields; the
                                // ownership check above trusts the transport-reported
                                // sender). Mirrors message_ops::handle_envelope_edit_message.
                                let ctx = format!(
                                    "{}:{}", sid.as_deref().unwrap_or_default(), cid.as_deref().unwrap_or_default(),
                                );
                                let row = message_ops::RowExtras::load_channel(&store, &mid);
                                if !crypto_handler::verify_message_signature_v2(
                                    &peer_str, sig.as_deref(), pk.as_deref(), "ch", &ctx,
                                    ts, &row.as_signed(&mid), &new_text, &mut PkCache::new(),
                                ) {
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED channel edit of {mid} from {peer_str} — signature verification FAILED");
                                    return;
                                }
                                let _ = store.edit_channel_message(
                                    &mid, &new_text, ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                                edit_applied = true;
                            } else if sender.is_some() {
                                hollow_log!("[HOLLOW-EDIT] Rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
                            }
                            // sender == None → message not synced yet; sync batch will bring the edited version.
                        } else {
                            // DM edit. Normally the editor must be the SENDER (the
                            // message is NOT ours: is_mine==false). Self fan-out
                            // (Step 3) is the one exception: a sibling echoing OUR
                            // OWN edit carries is_mine==true, and is legitimate
                            // because it resolves to our own master.
                            let is_mine = store.get_dm_message_is_mine(&mid);
                            let is_sibling = super::resolver::same_identity(&peer_str, master_peer_str);
                            if is_mine == Some(false) || (is_mine == Some(true) && is_sibling) {
                                // SECURITY: verify the edit signature. Signer/context
                                // mirror the live-DM rule: a sibling echo of OUR edit
                                // was signed by US with the row's conversation peer as
                                // recipient; a friend's edit was signed by them with
                                // US as recipient.
                                let (signer, ctx): (String, String) = if is_sibling {
                                    (
                                        master_peer_str.to_string(),
                                        store.get_dm_message_peer(&mid).unwrap_or_default(),
                                    )
                                } else {
                                    (super::resolver::resolve(&peer_str), master_peer_str.to_string())
                                };
                                let row = message_ops::RowExtras::load_dm(&store, &mid);
                                if !crypto_handler::verify_message_signature_v2(
                                    &signer, sig.as_deref(), pk.as_deref(), "dm", &ctx,
                                    ts, &row.as_signed(&mid), &new_text, &mut PkCache::new(),
                                ) {
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED DM edit of {mid} from {peer_str} (signer {signer}) — signature verification FAILED");
                                    return;
                                }
                                let _ = store.edit_dm_message(
                                    &mid, &new_text, ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                                edit_applied = true;
                            } else {
                                hollow_log!("[HOLLOW-EDIT] Rejected: {peer_str} tried to edit DM {mid} (is_mine={is_mine:?})");
                            }
                        }
                    }

                    // Emit event so Dart updates UI — include sig/pk so the
                    // receiver's Proof dialog verifies against the edit's
                    // signature, not the original's.
                    if edit_applied {
                        if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                            let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                                server_id,
                                channel_id,
                                message_id: mid,
                                new_text,
                                edited_at: ts,
                                signature: sig,
                                public_key: pk,
                            }).await;
                        } else {
                            // Convo attribution: for a sibling self-echo the sender
                            // is US, so resolve(peer_str) would mis-key it — look up
                            // the row's real conversation peer by mid.
                            let convo_peer = dm_event_convo(&peer_str, master_peer_str, &mid, &db_path, &db_passphrase);
                            let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                peer_id: convo_peer,
                                message_id: mid,
                                new_text,
                                edited_at: ts,
                                signature: sig,
                                public_key: pk,
                            }).await;
                        }
                    }
                }
                Ok(MessageEnvelope::LinkPreviewSet { mid, lp, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-LP] Received link preview for message {mid} from {peer_str}");
                    message_ops::handle_envelope_link_preview_set(
                        event_tx,
                        sid.as_deref().and_then(|s| server_states.get(s)),
                        &peer_str, master_peer_str,
                        mid, lp, ts, sig, pk, sid, cid,
                        &db_path, &db_passphrase,
                    ).await;
                }
                Ok(MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-DELETE] Received delete for message {mid} from {peer_str}");

                    // Hide the message in local DB (preserves text in message_deletions).
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        if sid.is_some() {
                            // SECURITY: Verify sender owns the message before hiding.
                            let sender = store.get_channel_message_sender(&mid);
                            if sender.as_deref() != Some(&peer_str) {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED DeleteMessage from {peer_str} — not the sender of message {mid}");
                                return;
                            }
                            // SECURITY: verify the delete signature ("ch-delete" over
                            // the row's current text + structural fields) — an
                            // unauthenticated delete is a censorship primitive.
                            let ctx = format!(
                                "{}:{}", sid.as_deref().unwrap_or_default(), cid.as_deref().unwrap_or_default(),
                            );
                            let row = message_ops::RowExtras::load_channel(&store, &mid);
                            let current_text = row.text.clone().unwrap_or_default();
                            if !crypto_handler::verify_message_signature_v2(
                                &peer_str, sig.as_deref(), pk.as_deref(), "ch-delete", &ctx,
                                ts, &row.as_signed(&mid), &current_text, &mut PkCache::new(),
                            ) {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED channel delete of {mid} from {peer_str} — signature verification FAILED");
                                return;
                            }
                            let _ = store.hide_channel_message(
                                &mid, ts,
                                sig.as_deref(), pk.as_deref(),
                            );
                        } else {
                            // SECURITY: the deleter must own the DM message (is_mine
                            // ==false). Self fan-out (Step 3) exception: a sibling
                            // echoing OUR OWN delete carries is_mine==true and is
                            // legitimate (it resolves to our master).
                            let is_mine = store.get_dm_message_is_mine(&mid);
                            let is_sibling = super::resolver::same_identity(&peer_str, master_peer_str);
                            let allowed = is_mine == Some(false) || (is_mine == Some(true) && is_sibling);
                            if !allowed {
                                // is_mine None → message not found; true & not sibling
                                // → a peer trying to delete our message. Reject both.
                                hollow_log!("[HOLLOW-SECURITY] REJECTED DeleteMessage (DM) from {peer_str} — not the sender of message {mid}");
                                return;
                            }
                            // SECURITY: verify the delete signature ("dm-delete") —
                            // signer/context mirror the DM edit arm above.
                            let (signer, ctx): (String, String) = if is_sibling {
                                (
                                    master_peer_str.to_string(),
                                    store.get_dm_message_peer(&mid).unwrap_or_default(),
                                )
                            } else {
                                (super::resolver::resolve(&peer_str), master_peer_str.to_string())
                            };
                            let row = message_ops::RowExtras::load_dm(&store, &mid);
                            let current_text = row.text.clone().unwrap_or_default();
                            if !crypto_handler::verify_message_signature_v2(
                                &signer, sig.as_deref(), pk.as_deref(), "dm-delete", &ctx,
                                ts, &row.as_signed(&mid), &current_text, &mut PkCache::new(),
                            ) {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED DM delete of {mid} from {peer_str} (signer {signer}) — signature verification FAILED");
                                return;
                            }
                            let _ = store.hide_dm_message(
                                &mid, ts,
                                sig.as_deref(), pk.as_deref(),
                            );
                        }
                    }

                    // Emit event so Dart updates UI.
                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
                            server_id,
                            channel_id,
                            message_id: mid,
                            deleted_at: ts,
                        }).await;
                    } else {
                        let convo_peer = dm_event_convo(&peer_str, master_peer_str, &mid, &db_path, &db_passphrase);
                        let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                            peer_id: convo_peer,
                            message_id: mid,
                            deleted_at: ts,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    // SECURITY: short Unicode emoji or a well-formed custom
                    // emote token ([e:name:hash]) — nothing else.
                    if !emotes::valid_reaction_emoji(&emoji) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED AddReaction from {peer_str} — invalid emoji string ({} bytes)", emoji.len());
                        return;
                    }
                    hollow_log!("[HOLLOW-REACTION] Received reaction {emoji} on {mid} from {peer_str}");

                    // Moderation (LIVE ingest, channel reactions only): drop reactions
                    // from muted members — mirrors the MLS twin in message_ops.rs.
                    if message_ops::live_muted_ingest_drop(
                        sid.as_deref().and_then(|s| server_states.get(s)), &peer_str, "reaction",
                    ) {
                        return;
                    }

                    // DM (sid==None): the reactor is keyed by the sender's MASTER id so
                    // reactions from any of a friend's devices attribute to one person.
                    // Channel context keeps the raw device id (untouched).
                    let reactor_key = if sid.is_none() {
                        super::resolver::resolve(&peer_str)
                    } else {
                        peer_str.to_string()
                    };

                    // SECURITY: a LIVE reaction must carry a signature that verifies
                    // (the reactor identity below is otherwise transport-attested
                    // only). Reactions are signed by the MASTER keypair, so verify
                    // against the resolved master even where the stored reactor key
                    // stays the raw device id (channel branch).
                    if message_ops::reaction_sig_rejected(
                        &super::resolver::resolve(&peer_str), "reaction", &mid, &emoji, ts,
                        sig.as_deref(), pk.as_deref(),
                    ) {
                        return;
                    }

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.add_reaction(
                            &mid, &emoji, &reactor_key, ts,
                            sig.as_deref(), pk.as_deref(),
                        );
                    }

                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
                            server_id,
                            channel_id,
                            message_id: mid,
                            emoji,
                            reactor: peer_str.to_string(),
                            added_at: ts,
                        }).await;
                    } else {
                        // peer_id = the DM thread key (the OTHER party). For a normal
                        // friend reaction reactor==thread peer, but for a sibling
                        // self-echo the reactor is US while the thread is the friend —
                        // resolve the thread by the message's row, not the reactor.
                        let convo_peer = dm_event_convo(&peer_str, master_peer_str, &mid, &db_path, &db_passphrase);
                        let _ = event_tx.send(NetworkEvent::DmReactionAdded {
                            peer_id: convo_peer,
                            message_id: mid,
                            emoji,
                            reactor: reactor_key,
                            added_at: ts,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::RemoveReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-REACTION] Received remove reaction {emoji} on {mid} from {peer_str}");

                    // DM (sid==None): reactor keyed by sender's MASTER id (see AddReaction).
                    let reactor_key = if sid.is_none() {
                        super::resolver::resolve(&peer_str)
                    } else {
                        peer_str.to_string()
                    };

                    // SECURITY: same rule as the add path — verify against the
                    // resolved MASTER (reactions are master-signed).
                    if message_ops::reaction_sig_rejected(
                        &super::resolver::resolve(&peer_str), "unreaction", &mid, &emoji, ts,
                        sig.as_deref(), pk.as_deref(),
                    ) {
                        return;
                    }

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.remove_reaction(
                            &mid, &emoji, &reactor_key, ts,
                            sig.as_deref(), pk.as_deref(),
                        );
                    }

                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
                            server_id,
                            channel_id,
                            message_id: mid,
                            emoji,
                            reactor: peer_str.to_string(),
                            removed_at: ts,
                        }).await;
                    } else {
                        let convo_peer = dm_event_convo(&peer_str, master_peer_str, &mid, &db_path, &db_passphrase);
                        let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
                            peer_id: convo_peer,
                            message_id: mid,
                            emoji,
                            reactor: reactor_key,
                            removed_at: ts,
                        }).await;
                    }
                }
                // -- File transfer receive handlers --
                Ok(MessageEnvelope::FileHeader { inner }) => {
                    let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, sig, pk, aes_key, aes_nonce, vthumb, share_ref, order_us, inline_bytes, thumb, voice, .. } = *inner;
                    // Envelope-borne thumb: image blur placeholder or video
                    // poster, size-capped — see accept_header_thumb.
                    let thumb = file_handler::accept_header_thumb(thumb, img, &mime);
                    use crate::node::file_transfer;
                    hollow_log!("[HOLLOW-FILE] FileHeader received: {fid} ({name}, {size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());

                    // Explicit pull (manual Download / sweep / guest request)?
                    // Consumes the receipt; bypasses the size cap AND the
                    // auto-download gate — we asked for exactly this file.
                    let explicitly_requested = requested_file_receipts
                        .remove(&fid)
                        .map(|t| t.elapsed() < std::time::Duration::from_secs(300))
                        .unwrap_or(false);
                    if explicitly_requested {
                        declined_file_ids.remove(&fid);
                    }

                    // SECURITY: Validate file size against server limit (or default 34MB for DMs).
                    // Skip for share-backed files — Share handles delivery with no size limit.
                    // Skip for explicit pulls — the >34MB share-backed fallback re-serve
                    // arrives WITHOUT a share_ref and must not be rejected by our own cap.
                    if share_ref.is_none() && !explicitly_requested {
                        let max_bytes: u64 = if let Some(ref s) = sid {
                            if let Some(state) = server_states.get(s) {
                                let max_mb_str = state.settings.get("max_file_size_mb")
                                    .map(|r| r.read().clone())
                                    .unwrap_or_else(|| "34".to_string());
                                let max_mb = max_mb_str.parse::<u64>().unwrap_or(34);
                                max_mb * 1024 * 1024
                            } else {
                                34 * 1024 * 1024
                            }
                        } else {
                            34 * 1024 * 1024
                        };
                        if size > max_bytes {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED FileHeader from {peer_str} — size {size} exceeds max {max_bytes} bytes");
                            return;
                        }
                    }

                    // Moderation trio (receive-side, channel files only): drop files
                    // from muted members and non-media files headed into a media-only
                    // channel. Mirrors the MLS twin in file_handler.rs.
                    if let Some(state) = sid.as_ref().and_then(|s| server_states.get(s)) {
                        let now_ms = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        if state.is_muted(&peer_str, now_ms) {
                            hollow_log!("[HOLLOW-MOD] DROPPED FileHeader from muted member {peer_str}");
                            return;
                        }
                        if let Some(c) = &cid {
                            if state.is_channel_media_only(c) {
                                let is_media = img
                                    || vthumb.is_some()
                                    || mime.starts_with("video/")
                                    || file_transfer::is_image_mime(&mime);
                                if !is_media {
                                    hollow_log!("[HOLLOW-MOD] DROPPED non-media FileHeader ({mime}) from {peer_str} in media-only channel {c}");
                                    return;
                                }
                            }
                        }
                    }

                    let ctx_type = if sid.is_some() { "channel" } else { "dm" };
                    // BLOCK GUARD (DM files only — channel files are hidden in the
                    // UI layer): drop a blocked identity's file before the metadata
                    // insert. Own sibling echoes are exempt.
                    if sid.is_none()
                        && !super::resolver::same_identity(&peer_str, master_peer_str)
                        && super::blocklist::is_blocked(&peer_str)
                    {
                        return;
                    }
                    // Multi-device: a DM file's conversation key MUST be the sender's
                    // MASTER id (where the DM message row itself is stored), NOT the
                    // raw sender DEVICE id. Otherwise the file metadata is filed under
                    // the device id while the message is under the master, so
                    // `_reloadChatForFile` (Dart) reloads the wrong/empty conversation
                    // and the message renders its `[file:<id>]` placeholder until a
                    // manual tab-switch reloads the right thread. No-op single-device.
                    let dm_convo = super::resolver::resolve(&peer_str);
                    let ctx_id = match (&sid, &cid) {
                        (Some(s), Some(c)) => format!("{s}:{c}"),
                        _ => dm_convo.clone(),
                    };

                    // Save file metadata to DB. Owner guard (0.8.5): the header
                    // is Olm-authenticated, but that only proves WHO sent it —
                    // not that the `file_id` inside is theirs to relabel.
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        if file_handler::file_meta_write_allowed(&store, &fid, &peer_str) {
                            let _ = store.insert_file_metadata(
                                &fid, &name, &ext, &mime,
                                size, chunks, img,
                                w, h,
                                mid.as_deref(), ctx_type, &ctx_id,
                                &peer_str, false, ts,
                                vthumb.as_ref(), thumb.as_deref(),
                            );
                            // Persist the share back-reference (issue #41) so a
                            // manual download can rejoin the share swarm after a
                            // restart — the key otherwise lives only in Dart RAM.
                            if let Some(sr) = share_ref.as_ref() {
                                let _ = store.set_file_share_ref(&fid, sr);
                            }
                        }
                    }

                    let mid_str = mid.clone().unwrap_or_default();
                    let sid_str = sid.unwrap_or_default();
                    // For a DM, the FileHeaderReceived `channel_id` carries the
                    // conversation key the Dart side reloads — use the MASTER (same as
                    // ctx_id above), not the raw device id.
                    let cid_str = cid.unwrap_or_else(|| dm_convo.clone());

                    // LOOP BREAKER: if this file is ALREADY complete on disk, ignore the
                    // FileHeader entirely — do NOT register a pending stream or re-process
                    // early arrivals. A DM file fans out to several of the recipient's
                    // devices and the decrypt-fail safety re-request also re-sends a
                    // FileHeader, so the SAME completed file can keep producing headers.
                    // Each one used to re-register a pending stream (resetting retry_count
                    // since the prior entry was removed on success) → another crossed
                    // header/stream pair → an endless re-download of one already-saved file
                    // (22k log lines, wasted bandwidth re-fetching e.g. a 10KB banner
                    // thousands of times). Once it's on disk we're done — drop the header.
                    let already_complete = {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            match store.get_file_metadata(&fid) {
                                Ok(Some(meta)) => meta.completed_at.is_some()
                                    && meta.disk_path.as_ref()
                                        .map(|p| std::path::Path::new(p).exists())
                                        .unwrap_or(false),
                                _ => false,
                            }
                        } else {
                            false
                        }
                    };
                    if already_complete {
                        // Clear any stale pending stream / early-arrival bytes for it and
                        // stop — no re-request, no re-register. Still emit FileHeaderReceived
                        // below so the sender-side UI/late-joiner stays consistent.
                        pending_file_streams.remove(&fid);
                        if let Some((temp_path, _, _)) = early_file_streams.remove(&fid) {
                            let _ = std::fs::remove_file(&temp_path);
                        }
                        hollow_log!("[HOLLOW-FILE] FileHeader for {fid} ignored — already complete on disk");
                    }

                    // Inlined offline image (relay-buffered 0x08 DM): the AES ciphertext
                    // rides INSIDE the header — write it to disk NOW; no stream will ever
                    // arrive. The FCM fetch node always did this (fetch.rs); the FULL node
                    // ignored inline_bytes, registered a pending stream that never
                    // completed, and the buffered image rendered as nothing on desktop.
                    // AUTO-DOWNLOAD GATE key + verdict (issue #41) — computed
                    // here because it gates BOTH the inline-image write below
                    // and the pending-stream registration further down. An
                    // existing pending stream = a transfer we already chose to
                    // accept (the decrypt-fail retry re-requests WITHOUT a
                    // receipt — its fresh header must not be declined).
                    let auto_dl_key = if sid_str.is_empty() {
                        format!("dm:{dm_convo}")
                    } else {
                        format!("server:{sid_str}")
                    };
                    let auto_ok = explicitly_requested
                        || pending_file_streams.contains_key(&fid)
                        || file_handler::auto_download_allows(size, &name, &auto_dl_key, voice);

                    let mut inline_done = false;
                    if !already_complete && share_ref.is_none() {
                        if let (Some(b64), Some(ak), Some(an)) =
                            (inline_bytes.as_ref(), aes_key.as_ref(), aes_nonce.as_ref())
                        {
                            let decoded = base64::engine::general_purpose::STANDARD
                                .decode(b64)
                                .ok()
                                .and_then(|ct| {
                                    let key = hex::decode(ak).ok()?;
                                    let nonce = hex::decode(an).ok()?;
                                    if key.len() != 32 || nonce.len() != 12 {
                                        return None;
                                    }
                                    let mut k = [0u8; 32];
                                    let mut n = [0u8; 12];
                                    k.copy_from_slice(&key);
                                    n.copy_from_slice(&nonce);
                                    crate::vault::pipeline::aes_decrypt(&ct, &k, &n).ok()
                                });
                            if let Some(plaintext) = decoded {
                                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                    // Captionless offline image: the "[file:...]"
                                    // companion DM is never sent to offline peers, so
                                    // insert the message row here (dedup by mid — a
                                    // captioned image's real caption DM wins later via
                                    // promote_file_sentinel_to_caption). Mirrors fetch.rs.
                                    // Stored REGARDLESS of the auto-download gate —
                                    // only the file bytes are gated, never the message.
                                    //
                                    // SECURITY (backfill rule, 0.8.5): the header's sig is
                                    // the MESSAGE signature over the sentinel text — the
                                    // row is stored ONLY when it VERIFIES (a captioned
                                    // image's header legitimately fails here, since the
                                    // sender signed the CAPTION — its caption DM creates
                                    // the row instead; an unsigned header no longer
                                    // materialises a row at all). Sibling echoes skip the
                                    // check: the sender is us, and the header carries no
                                    // convo to reconstruct the signing context from.
                                    // `order_us` from the header — the v2 signature binds
                                    // the sender's Lamport stamp, so a local ts*1000
                                    // default would wedge this row's later sync re-serve.
                                    let from_sibling = super::resolver::same_identity(&peer_str, master_peer_str);
                                    let sentinel_text = format!("[file:{fid}]");
                                    let sentinel_sig_ok = from_sibling || {
                                        let extras = crypto_handler::SignedExtras {
                                            mid: mid.as_deref(),
                                            reply_to: None,
                                            file_id: Some(&fid),
                                            order_us,
                                            lp_digest: None,
                                        };
                                        check_backfill_signature(
                                            &dm_convo, "dm", master_peer_str, ts, None,
                                            &extras, &sentinel_text,
                                            sig.as_deref(), pk.as_deref(), &mut PkCache::new(),
                                        ).is_acceptable()
                                    };
                                    if ctx_type == "dm"
                                        && sentinel_sig_ok
                                        && !mid.as_deref()
                                            .map(|m| store.dm_message_exists(m))
                                            .unwrap_or(false)
                                    {
                                        let _ = store.insert(
                                            &dm_convo, &sentinel_text, false, ts,
                                            sig.as_deref(), pk.as_deref(),
                                            mid.as_deref(), None, Some(&fid), order_us,
                                        );
                                    }
                                }
                                if !auto_ok {
                                    // AUTO-DOWNLOAD GATE (issue #41): drop the inline
                                    // ciphertext — the card renders from the metadata
                                    // row with a manual Download button that re-pulls
                                    // the bytes from the sender.
                                    hollow_log!("[HOLLOW-FILE] Auto-download gate dropped inline image bytes for {fid} ({auto_dl_key}) — message kept, manual download available");
                                    inline_done = true;
                                } else {
                                    let files_dir = file_transfer::files_dir();
                                    let _ = std::fs::create_dir_all(&files_dir);
                                    let disk_path = files_dir.join(format!("{fid}.{ext}"));
                                    if std::fs::write(&disk_path, &plaintext).is_ok() {
                                        let disk_str = disk_path.to_string_lossy().to_string();
                                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                            let _ = store.mark_file_complete(&fid, &disk_str);
                                        }
                                        hollow_log!("[HOLLOW-FILE] Wrote inline image {fid} ({} bytes) from buffered header", plaintext.len());
                                        let _ = event_tx.send(NetworkEvent::FileCompleted {
                                            file_id: fid.clone(),
                                            disk_path: disk_str,
                                        }).await;
                                        inline_done = true;
                                    }
                                }
                            }
                        }
                    }

                    // AUTO-DOWNLOAD GATE (issue #41): a pushed stream in a
                    // conversation with auto-download off (or over the
                    // threshold) is declined — the metadata row above still
                    // renders the card with a manual Download button, but no
                    // pending stream registers and any bytes the sender already
                    // queued are deleted on arrival instead of parked.
                    if !already_complete && !inline_done && !auto_ok
                        && share_ref.is_none() && aes_key.is_some()
                    {
                        declined_file_ids.insert(fid.clone());
                        if let Some((temp_path, _, _)) = early_file_streams.remove(&fid) {
                            let _ = std::fs::remove_file(&temp_path);
                        }
                        hollow_log!("[HOLLOW-FILE] Auto-download gate declined pushed file {fid} ({size} bytes, {auto_dl_key}) — metadata kept, manual download available");
                        // Tell Dart NOW, at header time: the transfer provider
                        // flags the file declined so NO progress source (Rust
                        // WS poll, Dart WebRTC data-channel receive) can flip
                        // the bubble into a spinner while the unwanted push
                        // transits and is discarded.
                        let _ = event_tx.send(NetworkEvent::FileFailed {
                            file_id: fid.clone(),
                            error: "auto_download_off".to_string(),
                        }).await;
                    }

                    // If aes_key is present and no share_ref, this is a streamed transfer — register for stream receive.
                    // Share-backed files skip this — Share handles delivery, no P2P binary data.
                    if !already_complete && !inline_done && auto_ok && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
                        // Preserve the retry counter across a re-registration. A DM
                        // file is fanned out to several of the recipient's devices, so
                        // the SAME file can produce MULTIPLE FileHeaders here — and the
                        // decrypt-fail auto-retry also re-requests (which re-sends a
                        // FileHeader). Resetting retry_count to 0 on every header made
                        // the bounded "3 retries then give up" never fire → an infinite
                        // FileHeader/stream/decrypt-fail loop (4.5k log lines, "stuck
                        // loading forever"). Carry the existing count forward instead.
                        let carried_retry = pending_file_streams.get(&fid)
                            .map(|p| p.retry_count)
                            .unwrap_or(0);
                        pending_file_streams.insert(fid.clone(), PendingFileStream {
                            aes_key: ak,
                            aes_nonce: an,
                            file_name: name.clone(),
                            ext: ext.clone(),
                            sender: peer_str.to_string(),
                            server_id: sid_str.clone(),
                            channel_id: cid_str.clone(),
                            message_id: mid_str.clone(),
                            is_image: img,
                            width: w,
                            height: h,
                            retry_count: carried_retry,
                        });
                        hollow_log!("[HOLLOW-FILE] Registered pending stream for {fid} (streamed transfer)");

                        // Check if WebRTC bytes already arrived before this FileHeader (race condition).
                        if let Some((temp_path, file_size, sender)) = early_file_streams.remove(&fid) {
                            hollow_log!("[HOLLOW-FILE] Early arrival found for {fid} — processing now");
                            let request = super::ws_stream_transfer::StreamRequest {
                                kind: super::ws_stream_transfer::StreamKind::File,
                                id: fid.clone(),
                                size: file_size,
                                temp_path,
                            };
                            let mut empty_vault_dl = HashMap::new();
                            // Early-arrival path is File-only; link snapshots never route here.
                            let mut empty_link_snapshots = HashMap::new();
                            file_handler::handle_completed_stream(
                                request, &sender,
                                pending_file_streams, pending_shard_streams,
                                &mut empty_vault_dl, early_file_streams,
                                &mut empty_link_snapshots,
                                bundle_keypair, event_tx,
                                ws_cmd_tx, ws_room_peers,
                                db_path, db_passphrase,
                            ).await;
                        }
                    }

                    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                        file_id: fid,
                        file_name: name,
                        size_bytes: size,
                        is_image: img,
                        width: w,
                        height: h,
                        message_id: mid_str,
                        sender_id: peer_str.to_string(),
                        server_id: sid_str,
                        channel_id: cid_str,
                        video_thumb: vthumb,
                        share_ref,
                        thumb_b64: thumb,
                    }).await;
                }
                Ok(MessageEnvelope::FileChunk { fid, idx, data }) => {
                    use crate::node::file_transfer;
                    // Decode base64 chunk data.
                    let chunk_bytes = base64::engine::general_purpose::STANDARD.decode(&data);
                    if let Err(e) = &chunk_bytes {
                        hollow_log!("[HOLLOW-FILE] Failed to decode chunk {idx} for {fid}: {e}");
                    }
                    if let Ok(chunk_bytes) = chunk_bytes {

                    // Write chunk to disk.
                    if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
                        hollow_log!("[HOLLOW-FILE] {e}");
                    } else {

                    // Update DB.
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        if let Ok(received) = store.mark_chunk_received(&fid, idx) {
                            // Get total chunks from file metadata.
                            if let Ok(Some(file_meta)) = store.get_file_metadata(&fid) {
                                let _ = event_tx.send(NetworkEvent::FileProgress {
                                    file_id: fid.clone(),
                                    chunks_received: received,
                                    total_chunks: file_meta.chunk_count,
                                }).await;

                                // Check if all chunks received.
                                if received >= file_meta.chunk_count {
                                    let final_path = file_transfer::final_file_path(&fid, &file_meta.file_ext);
                                    match file_transfer::assemble_file(&fid, file_meta.chunk_count, &final_path) {
                                        Ok(()) => {
                                            let disk_path = final_path.to_string_lossy().to_string();
                                            let _ = store.mark_file_complete(&fid, &disk_path);
                                            hollow_log!("[HOLLOW-FILE] File {fid} complete: {disk_path}");
                                            let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                file_id: fid,
                                                disk_path,
                                            }).await;
                                        }
                                        Err(e) => {
                                            hollow_log!("[HOLLOW-FILE] Assembly failed for {fid}: {e}");
                                            let _ = event_tx.send(NetworkEvent::FileFailed {
                                                file_id: fid,
                                                error: e,
                                            }).await;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    } // else (write_chunk ok)
                    } // if let Ok(chunk_bytes)
                }

                // -- Vault shard receive handlers (Phase 4) --
                Ok(MessageEnvelope::ShardStore { inner }) => {
                    let ShardStorePayload { sid, cid, si, sk, k, m, total_size, tier, data, chunks, .. } = *inner;
                    hollow_log!("[HOLLOW-VAULT] ShardStore received: cid={cid} si={si} chunks={chunks} from {peer_str}");

                    // Verify sender is a member of the server
                    let is_member = server_states.get(&sid)
                        .map(|s| s.is_member(peer_str))
                        .unwrap_or(false);
                    if !is_member {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardStore from {peer_str} — not a member of {sid}");
                    } else if chunks == 0 && data.is_empty() {
                        // Streamed shard — data arrives via /hollow/stream/1.0.0.
                        let key = format!("{cid}:{si}");
                        pending_shard_streams.insert(key.clone(), PendingShardStream {
                            server_id: sid, content_id: cid, shard_index: si,
                            shard_key: sk, k, m, total_size, tier,
                        });
                        hollow_log!("[HOLLOW-VAULT] Registered pending shard stream: {key}");
                    } else if chunks == 0 {
                        // Inline shard (legacy) — decode and store immediately
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            // Check pledge capacity
                            let local_peer = local_peer_str.to_string();
                            let pledge = server_states.get(&sid)
                                .map(|s| s.get_storage_pledge(&local_peer))
                                .unwrap_or(0);
                            let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                            if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                                let used = content_store.total_storage_used(&sid).unwrap_or(0);
                                if pledge > 0 && used + shard_bytes.len() as u64 > pledge {
                                    hollow_log!("[HOLLOW-VAULT] Pledge exceeded for {sid} — rejecting shard");
                                    let ack = MessageEnvelope::ShardStoreAck {
                                        sid: sid.clone(), cid: cid.clone(), si, ok: false,
                                        err: Some("Pledge capacity exceeded".into()),
                                        target: None,
                                    };
                                    let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                        send_encrypted_message(
                                            olm, crypto_store,
                                            
                                            &peer_str, &ack_json, event_tx,
                                        ws_cmd_tx, ws_room_peers,
                                        ).await;
                                } else {
                                    // Store the shard
                                    let tier_enum = crate::vault::content_store::StorageTier::from_str(&tier);
                                    match content_store.store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes) {
                                        Ok(_) => {
                                            hollow_log!("[HOLLOW-VAULT] Shard stored: cid={cid} si={si}");
                                            let _ = event_tx.send(NetworkEvent::ShardStored {
                                                server_id: sid.clone(),
                                                content_id: cid.clone(),
                                                shard_index: si,
                                                from_peer: peer_str.to_string(),
                                            }).await;
                                            // Send ack
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: sid.clone(), cid: cid.clone(), si, ok: true, err: None,
                                                target: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                                send_encrypted_message(
                                                    olm, crypto_store,
                                                    
                                                    &peer_str, &ack_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                                ).await;
                                        }
                                        Err(e) => {
                                            hollow_log!("[HOLLOW-VAULT] Failed to store shard: {e}");
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: sid.clone(), cid: cid.clone(), si, ok: false,
                                                err: Some(e),
                                                target: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                                send_encrypted_message(
                                                    olm, crypto_store,
                                                    
                                                    &peer_str, &ack_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                                ).await;
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Chunked shard — create assembly entry
                        let key = format!("{cid}:{si}:{peer_str}");
                        pending_shard_assembly.insert(key, PendingShardAssembly {
                            server_id: sid,
                            content_id: cid,
                            shard_index: si,
                            shard_key: sk,
                            k,
                            m,
                            total_size,
                            tier,
                            expected_chunks: chunks,
                            received: std::collections::HashSet::new(),
                            chunk_data: Vec::new(),
                            sender_peer: peer_str.to_string(),
                            received_at: std::time::Instant::now(),
                        });
                    }
                }

                Ok(MessageEnvelope::ShardChunk { sid, cid, si, ci, data }) => {
                    let key = format!("{cid}:{si}:{peer_str}");
                    if let Some(assembly) = pending_shard_assembly.get_mut(&key) {
                        if let Ok(chunk_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            if !assembly.received.contains(&ci) {
                                assembly.received.insert(ci);
                                assembly.chunk_data.push((ci, chunk_bytes));
                            }

                            // Check if all chunks received
                            if assembly.received.len() as u32 >= assembly.expected_chunks {
                                // Reassemble in order
                                let mut asm = pending_shard_assembly.remove(&key).unwrap();
                                asm.chunk_data.sort_by_key(|(idx, _)| *idx);
                                let mut full_data = Vec::new();
                                for (_, chunk) in &asm.chunk_data {
                                    full_data.extend_from_slice(chunk);
                                }

                                // Store via ContentStore
                                let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                                if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                                    let tier_enum = crate::vault::content_store::StorageTier::from_str(&asm.tier);
                                    match content_store.store_shard(&asm.server_id, &asm.content_id, asm.shard_index, asm.k, asm.m, asm.total_size, tier_enum, &full_data) {
                                        Ok(_) => {
                                            hollow_log!("[HOLLOW-VAULT] Chunked shard assembled+stored: cid={} si={}", asm.content_id, asm.shard_index);
                                            let _ = event_tx.send(NetworkEvent::ShardStored {
                                                server_id: asm.server_id.clone(),
                                                content_id: asm.content_id.clone(),
                                                shard_index: asm.shard_index,
                                                from_peer: peer_str.to_string(),
                                            }).await;
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: asm.server_id, cid: asm.content_id, si: asm.shard_index, ok: true, err: None,
                                                target: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                                send_encrypted_message(
                                                    olm, crypto_store,
                                                    
                                                    &peer_str, &ack_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                                ).await;
                                        }
                                        Err(e) => {
                                            hollow_log!("[HOLLOW-VAULT] Failed to store assembled shard: {e}");
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: asm.server_id, cid: asm.content_id, si: asm.shard_index, ok: false, err: Some(e),
                                                target: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                                send_encrypted_message(
                                                    olm, crypto_store,
                                                    
                                                    &peer_str, &ack_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                                ).await;
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        hollow_log!("[HOLLOW-VAULT] ShardChunk for unknown assembly: cid={cid} si={si} ci={ci}");
                    }
                }

                Ok(MessageEnvelope::ShardStoreAck { sid, cid, si, ok, err, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardStoreAck: cid={cid} si={si} ok={ok} err={err:?}");
                    let _ = event_tx.send(NetworkEvent::ShardStoreAckReceived {
                        server_id: sid.clone(),
                        content_id: cid.clone(),
                        shard_index: si,
                        success: ok,
                        error: err.unwrap_or_default(),
                    }).await;

                    // Mark placement as confirmed in DB
                    if ok {
                        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                        if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                            let _ = content_store.confirm_placement(&cid, si);
                        }
                    }
                }

                Ok(MessageEnvelope::ShardDelete { sid, cid }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardDelete received: cid={cid} from {peer_str}");

                    // Verify sender is a member with MANAGE_SERVER permission
                    let allowed = server_states.get(&sid)
                        .map(|s| {
                            s.is_member(peer_str) &&
                            s.has_permission(&peer_str, crate::crdt::operations::Permission::MANAGE_SERVER)
                        })
                        .unwrap_or(false);

                    if !allowed {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardDelete from {peer_str} — not authorized for {sid}");
                    } else {
                        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                            let _ = cs.delete_content(&sid, &cid);
                            let _ = cs.delete_placements(&cid);
                        }
                        hollow_log!("[HOLLOW-VAULT] Shard content deleted: cid={cid}");
                        let _ = event_tx.send(NetworkEvent::ShardDeleted {
                            server_id: sid,
                            content_id: cid,
                        }).await;
                    }
                }

                // -- Vault shard retrieve handlers (Phase 4) --

                Ok(MessageEnvelope::ShardRequest { sid, cid, si, sk, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardRequest: cid={cid} si={si} from {peer_str}");
                    let is_member = server_states.get(&sid)
                        .map(|s| s.is_member(peer_str))
                        .unwrap_or(false);
                    if !is_member {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardRequest from {peer_str} — not a member of {sid}");
                    } else {
                        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                            match cs.read_shard_unchecked(&sid, &sk) {
                                Ok(shard_data) => {
                                    // Send metadata via Olm, stream shard bytes.
                                    let resp = MessageEnvelope::ShardResponse {
                                        sid: sid.clone(), cid: cid.clone(), si,
                                        data: String::new(), chunks: 0, found: true,
                                        target: None,
                                    };
                                    let json = serde_json::to_string(&resp).unwrap_or_default();
                                        send_encrypted_message(
                                            olm, crypto_store,
                                            
                                            &peer_str, &json, event_tx,
                                        ws_cmd_tx, ws_room_peers,
                                        ).await;

                                        // Stream shard bytes via stream_to_peer (WS or libp2p).
                                        let shard_temp_dir = crate::node::file_transfer::files_dir();
                                        let shard_safe_prefix = &cid[..16.min(cid.len())];
                                        let shard_temp_name = format!(".stream_shard_{}_{}.tmp", shard_safe_prefix, si);
                                        let shard_temp_path = shard_temp_dir.join(&shard_temp_name);
                                        if let Ok(()) = std::fs::write(&shard_temp_path, &shard_data) {
                                            let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index: si };
                                            file_handler::stream_to_peer(
                                                ws_cmd_tx, ws_room_peers,
                                                webrtc_peers, pending_webrtc_sends, event_tx,
                                                &peer_str, &shard_kind,
                                                &cid, &shard_temp_path, shard_data.len() as u64,
                                            ).await;
                                            hollow_log!("[HOLLOW-VAULT] Streaming shard response si={si} ({} bytes) to {peer_str}", shard_data.len());
                                        }
                                }
                                Err(_) => {
                                    let resp = MessageEnvelope::ShardResponse {
                                        sid, cid, si, data: String::new(), chunks: 0, found: false,
                                        target: None,
                                    };
                                    let json = serde_json::to_string(&resp).unwrap_or_default();
                                        send_encrypted_message(
                                            olm, crypto_store,
                                            
                                            &peer_str, &json, event_tx,
                                        ws_cmd_tx, ws_room_peers,
                                        ).await;
                                }
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::ShardResponse { sid, cid, si, data, chunks, found, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardResponse: cid={cid} si={si} found={found} chunks={chunks} from {peer_str}");
                    if !found {
                        let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                            server_id: sid, content_id: cid, shard_index: si,
                            error: "Shard not found on peer".into(),
                        }).await;
                    } else if data.is_empty() {
                        // Streamed shard response — data arrives via /hollow/stream/1.0.0.
                        // Register pending_shard_streams so the stream handler stores it.
                        let key = format!("{cid}:{si}");
                        pending_shard_streams.insert(key.clone(), PendingShardStream {
                            server_id: sid.clone(), content_id: cid.clone(), shard_index: si,
                            shard_key: String::new(), k: 0, m: 0, total_size: 0,
                            tier: "standard".to_string(),
                        });
                        hollow_log!("[HOLLOW-VAULT] Registered pending shard stream for response: {key}");
                    } else {
                        // Inline shard data (small shards) — decode and store immediately
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                            if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                                let tier = crate::vault::content_store::StorageTier::Standard;
                                let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                            }
                            let _ = event_tx.send(NetworkEvent::ShardReceived {
                                server_id: sid, content_id: cid, shard_index: si,
                                from_peer: peer_str.to_string(),
                            }).await;
                        }
                    }
                }

                Ok(MessageEnvelope::ShardResponseChunk { sid, cid, si, ci, data, .. }) => {
                    let key = format!("resp:{cid}:{si}:{peer_str}");
                    if let Some(assembly) = pending_shard_assembly.get_mut(&key) {
                        if let Ok(chunk_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            if !assembly.received.contains(&ci) {
                                assembly.received.insert(ci);
                                assembly.chunk_data.push((ci, chunk_bytes));
                            }
                            if assembly.received.len() as u32 >= assembly.expected_chunks {
                                let asm = pending_shard_assembly.remove(&key).unwrap();
                                let mut sorted = asm.chunk_data;
                                sorted.sort_by_key(|(idx, _)| *idx);
                                let _full_data: Vec<u8> = sorted.into_iter().flat_map(|(_, d)| d).collect();
                                let _ = event_tx.send(NetworkEvent::ShardReceived {
                                    server_id: sid, content_id: cid, shard_index: si,
                                    from_peer: peer_str.to_string(),
                                }).await;
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::ShardProbe { sid, cid, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardProbe: cid={cid} from {peer_str}");
                    let is_member = server_states.get(&sid)
                        .map(|s| s.is_member(peer_str))
                        .unwrap_or(false);
                    if is_member {
                        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                        let mut indices = Vec::new();
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                            if let Ok(records) = cs.list_content_shards(&sid, &cid) {
                                indices = records.iter().map(|r| r.shard_index).collect();
                            }
                        }
                        let resp = MessageEnvelope::ShardProbeResponse {
                            sid, cid, shards: indices,
                            target: None,
                        };
                        let json = serde_json::to_string(&resp).unwrap_or_default();
                            send_encrypted_message(
                                olm, crypto_store,
                                
                                &peer_str, &json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                            ).await;
                    }
                }

                Ok(MessageEnvelope::ShardProbeResponse { sid, cid, shards, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardProbeResponse: cid={cid} shards={shards:?} from {peer_str}");
                    // Logged for now — download pipeline will use this data when built
                }

                Ok(MessageEnvelope::VaultManifestBroadcast { sid, cid, chid, manifest }) => {
                    hollow_log!("[HOLLOW-VAULT] VaultManifest received: cid={cid} in {sid}/{chid} from {peer_str}");
                    if let Ok(manifest_obj) = serde_json::from_str::<crate::vault::pipeline::VaultManifest>(&manifest) {
                        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                            let _ = cs.save_manifest(&sid, &chid, &manifest_obj);
                        }
                        // Link vault content_id to the file record via message_id.
                        if !manifest_obj.message_id.is_empty() {
                            if let Ok(ms) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                let _ = ms.set_file_content_id(&manifest_obj.message_id, &manifest_obj.content_id);
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::ShardMigrate { sid, cid, si, sk, data, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardMigrate received: cid={cid} si={si} from {peer_str}");
                    // Same logic as ShardStore inline — verify membership, store shard
                    let is_member = server_states.get(&sid)
                        .map(|s| s.is_member(peer_str))
                        .unwrap_or(false);
                    if is_member {
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                            if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                                let tier = crate::vault::content_store::StorageTier::Standard;
                                let _ = content_store.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                                hollow_log!("[HOLLOW-VAULT] Migrated shard stored: cid={cid} si={si}");
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::SessionAck) => {
                    // Lightweight encrypted ping from peer after they created an inbound
                    // session. The act of decrypting this message upgrades our outbound
                    // session's ratchet so subsequent encrypts produce Normal (type 1).
                    // This is the CONFIRMATION point for an initiator: the peer proved it
                    // can decrypt us, so the session is now bidirectional. Emit
                    // SessionEstablished here (not optimistically at outbound creation) and
                    // clear the in-flight marker so the sweep stops retrying.
                    hollow_log!("[HOLLOW-CRYPTO] SessionAck received from {peer_str} — session confirmed bidirectional");
                    let was_unconfirmed = olm.has_unconfirmed_session(&peer_str);
                    olm.mark_session_bidirectional(&peer_str);
                    key_request_in_flight.remove(peer_str);
                    if was_unconfirmed {
                        let _ = event_tx.send(NetworkEvent::SessionEstablished {
                            peer_id: peer_str.to_string(),
                        }).await;
                    }
                }

                // Phase 6 MLS envelope variants — should not arrive via Olm, log and ignore.
                // CrdtOp via Olm fallback — apply it (may arrive when MLS is out of sync).
                Ok(MessageEnvelope::CrdtOp { sid, op_json, .. }) => {
                    if let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
                        if let Some(state) = server_states.get_mut(&sid) {
                            if let Ok(()) = state.apply_op(&op) {
                                state.op_log.push(op.clone());
                                if let Ok(json) = serde_json::to_string(&*state) {
                                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                        let _ = store.save_server_state(&sid, &json);
                                        let _ = store.insert_crdt_op(&op);
                                    }
                                }
                                let _ = event_tx.send(NetworkEvent::SyncCompleted {
                                    server_id: sid, ops_applied: 1,
                                }).await;
                            }
                        }
                    }
                }
                // SyncReq/SyncResp via Olm fallback — handle normally.
                Ok(MessageEnvelope::SyncReq { sid, state_vector_json, .. }) => {
                    if let Some(state) = server_states.get(&sid) {
                        if let Ok(their_vector) = serde_json::from_str::<crate::crdt::sync::StateVector>(&state_vector_json) {
                            let delta = crate::crdt::sync::compute_delta(&state.op_log, &their_vector);
                            if !delta.is_empty() {
                                let ops_json = serde_json::to_string(&delta).unwrap_or_default();
                                // Respond via plaintext since Olm is the active path.
                                send_message_to_peer(
                                    ws_cmd_tx, ws_room_peers,
                                    peer_str, HavenMessage::SyncResponse {
                                        server_id: sid,
                                        ops_json,
                                    },
                                );
                            }
                        }
                    }
                }
                Ok(MessageEnvelope::SyncResp { sid, ops_json, .. }) => {
                    if let Some(state) = server_states.get_mut(&sid) {
                        // Tolerant parse: a NEWER client's op variant skips
                        // just that op, never the whole batch.
                        let incoming_ops = crate::crdt::operations::parse_ops_tolerant(&ops_json);
                        if !incoming_ops.is_empty() {
                            // Persist synced ops (op_log is RAM-only — see the
                            // plaintext SyncResponse handler for rationale).
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                for op in &incoming_ops {
                                    if op.server_id == sid {
                                        let _ = store.insert_crdt_op(op);
                                    }
                                }
                            }
                            if let Ok(applied) = crate::crdt::sync::merge_ops(state, &incoming_ops) {
                                if applied > 0 {
                                    if let Ok(json) = serde_json::to_string(&*state) {
                                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                            let _ = store.save_server_state(&sid, &json);
                                        }
                                    }
                                    let _ = event_tx.send(NetworkEvent::SyncCompleted {
                                        server_id: sid, ops_applied: applied as u32,
                                    }).await;
                                }
                            }
                        }
                    }
                }
                // MLS-only envelopes that should never arrive via Olm (they use plaintext
                // HavenMessage variants instead for epoch resilience).
                Ok(MessageEnvelope::ServerDelete { .. })
                | Ok(MessageEnvelope::MemberKick { .. })
                | Ok(MessageEnvelope::Typing { .. })
                | Ok(MessageEnvelope::ProfileUpdate { .. })
                | Ok(MessageEnvelope::ChannelSyncReq { .. })
                | Ok(MessageEnvelope::ChannelProbe { .. })
                | Ok(MessageEnvelope::VoiceChannelJoin { .. })
                | Ok(MessageEnvelope::VoiceChannelLeave { .. })
                | Ok(MessageEnvelope::VoiceChannelAudioState { .. })
                | Ok(MessageEnvelope::VoiceChannelScreenState { .. })
                | Ok(MessageEnvelope::VoiceChannelCameraState { .. })
                | Ok(MessageEnvelope::VoiceChannelRecordingState { .. })
                | Ok(MessageEnvelope::BroadcastMeta { .. }) => {
                    hollow_log!("[HOLLOW-MLS] Received MLS-only envelope via Olm from {peer_str} — ignoring");
                }

                // Voice SDP/ICE + ChannelProbeResp — Olm fallback handlers.
                // These arrive via Olm when MLS encrypt failed on the sender side
                // (peer's epoch may be stale after reconnection).
                Ok(MessageEnvelope::ChannelProbeResp { sid, cid, their_latest, msg_count, .. }) => {
                    // Mirror the MLS ChannelProbeResp handler — compare timestamps,
                    // send plaintext ChannelSyncRequest if peer has newer messages.
                    let dedup_key = format!("{sid}:{cid}");
                    if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
                        return;
                    }
                    if !server_states.contains_key(&sid) { return; }
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let our_latest = store.get_latest_channel_timestamp(&sid, &cid)
                            .unwrap_or(None).unwrap_or(0);
                        if their_latest > our_latest || msg_count > store.count_channel_messages(&sid, &cid) {
                            channel_sync_sent.insert(dedup_key, std::time::Instant::now());
                            let per_sender = store.get_per_sender_timestamps(&sid, &cid)
                                .unwrap_or_default();
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, HavenMessage::ChannelSyncRequest {
                                    server_id: sid.clone(),
                                    channel_id: cid,
                                    since_timestamp: our_latest,
                                    sender_timestamps: per_sender,
                                },
                            );
                        }
                    }
                }

                Ok(MessageEnvelope::VoiceChannelSdpOffer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC SDP offer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC SDP offer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "sdp_offer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelSdpAnswer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC SDP answer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC SDP answer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "sdp_answer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelIce { sid, cid, candidate, sdp_mid, sdp_mline_index, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC ICE (Olm) from non-participant {peer_str} in {cid}");
                    } else {
                        let payload = serde_json::json!({
                            "candidate": candidate,
                            "sdpMid": sdp_mid,
                            "sdpMLineIndex": sdp_mline_index,
                        }).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "ice".to_string(), payload,
                        }).await;
                    }
                }
                // Screen offer/answer/ICE consolidate into the shared
                // voice_handler handlers (same participant + size guards the
                // inline arms had, plus the step-2 origin spoof guard) so the
                // origin contract lives in ONE place for both Olm + MLS paths.
                Ok(MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, origin, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_offer(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, sdp, origin, &local_peer_str,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, origin, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_answer(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, sdp, origin, &local_peer_str,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, origin, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_ice(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, candidate, sdp_mid, sdp_mline_index, role,
                        origin, &local_peer_str,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelScreenWatch { sid, cid, want, viewer_width, viewer_height, route, fwd_capable, relay_private, fwd_simulcast, fwd_feed, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_watch(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, want,
                        viewer_width, viewer_height, route, fwd_capable, relay_private, fwd_simulcast, fwd_feed,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelScreenAssign { sid, cid, origin, forwarder, feed_target, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_assign(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, origin, forwarder, feed_target, &local_peer_str,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelScreenFeedState { sid, cid, origin, forwarder, up, .. }) => {
                    voice_handler::handle_envelope_voice_channel_screen_feed_state(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid, origin, forwarder, up, &local_peer_str,
                    ).await;
                }
                Ok(MessageEnvelope::VoiceChannelRenegOffer { sid, cid, sdp, ice_restart, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg offer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg offer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp, "ice_restart": ice_restart}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "reneg_offer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelRenegAnswer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg answer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg answer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "reneg_answer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelLegRestart { sid, cid, .. }) => {
                    voice_handler::handle_envelope_voice_channel_leg_restart(
                        voice_channel_participants, event_tx,
                        peer_str.to_string(), sid, cid,
                    ).await;
                }

                // -- Media forwarder control plane (step 3) --
                // Client-bound signals from a forwarder. Rust enforces only the
                // SDP size cap; the trust decision ("from the discovered
                // forwarder AND for a watched+assigned origin") lives in Dart —
                // an arbitrary peer sending these reaches a provider that
                // ignores unknown senders.
                Ok(MessageEnvelope::FwdIngestAnswer { origin, sdp }) => {
                    if sdp.len() > MAX_SDP_SIZE {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED fwd_ingest_answer — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        // Feeder election: when WE are feeding this forwarder,
                        // its ingest answer belongs to OUR engine's feed leg
                        // (structurally an egress answer), not to Dart — we
                        // never offered an ingest of our own to it.
                        #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                        let consumed = {
                            let (embedded_fwd, _) = fwd_bridge;
                            embedded_fwd.handle_feed_answer(
                                peer_str,
                                MessageEnvelope::FwdIngestAnswer {
                                    origin: origin.clone(),
                                    sdp: sdp.clone(),
                                },
                            )
                        };
                        #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                        let consumed = false;
                        if consumed {
                            // The fed forwarder ADMITTED our ingest (an old
                            // binary that ignores the `feeder` field, or any
                            // refusal, answers with fwd_error instead). Tell
                            // Dart so it can report the feed up to the owner,
                            // which is what lets the owner stop supplying that
                            // forwarder itself — make-before-break.
                            let payload = serde_json::json!({
                                "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                            }).to_string();
                            let _ = event_tx.send(NetworkEvent::ForwarderSignal {
                                from_peer: peer_str.to_string(),
                                signal_type: "fwd_feed_up".to_string(), payload,
                            }).await;
                        } else {
                            let payload = serde_json::json!({
                                "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                                "sdp": sdp,
                            }).to_string();
                            let _ = event_tx.send(NetworkEvent::ForwarderSignal {
                                from_peer: peer_str.to_string(),
                                signal_type: "fwd_ingest_answer".to_string(), payload,
                            }).await;
                        }
                    }
                }
                Ok(MessageEnvelope::FwdEgressOffer { origin, sdp }) => {
                    if sdp.len() > MAX_SDP_SIZE {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED fwd_egress_offer — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({
                            "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                            "sdp": sdp,
                        }).to_string();
                        let _ = event_tx.send(NetworkEvent::ForwarderSignal {
                            from_peer: peer_str.to_string(),
                            signal_type: "fwd_egress_offer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::FwdError { origin, code, detail }) => {
                    let payload = serde_json::json!({
                        "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                        "code": code, "detail": detail,
                    }).to_string();
                    let _ = event_tx.send(NetworkEvent::ForwarderSignal {
                        from_peer: peer_str.to_string(),
                        signal_type: "fwd_error".to_string(), payload,
                    }).await;
                }
                // Forwarder-bound signals arriving at a client. Phase 2: an
                // ENABLED embedded peer forwarder consumes them (expectation
                // gate + engine admission + token bucket in
                // `embedded_forwarder`); otherwise — misdirected or malicious —
                // they keep hitting the pre-phase-2 ignore arm.
                Ok(env @ (MessageEnvelope::FwdStreamRegister { .. }
                | MessageEnvelope::FwdStreamAuth { .. }
                | MessageEnvelope::FwdStreamUnregister { .. }
                | MessageEnvelope::FwdIngestOffer { .. }
                | MessageEnvelope::FwdAttach { .. }
                | MessageEnvelope::FwdDetach { .. }
                | MessageEnvelope::FwdEgressAnswer { .. })) => {
                    #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
                    {
                        let (embedded_fwd, cmd_tx) = fwd_bridge;
                        if !embedded_fwd.handle_inbound(peer_str, env, cmd_tx) {
                            hollow_log!("[HOLLOW-SECURITY] Forwarder-bound fwd_* signal received by client from {peer_str} — ignoring");
                        }
                    }
                    #[cfg(not(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios")))))]
                    {
                        let _ = (env, &fwd_bridge);
                        hollow_log!("[HOLLOW-SECURITY] Forwarder-bound fwd_* signal received by client from {peer_str} — ignoring");
                    }
                }

                Err(e) => {
                    // A decrypted payload that LOOKS like JSON but failed the
                    // MessageEnvelope parse is version skew or corruption being
                    // silently MISROUTED into the legacy-DM fallback — say so
                    // with the sender tagged (the fwd-signal blackhole was only
                    // diagnosable from log absence on both ends).
                    if text.trim_start().starts_with('{') {
                        hollow_log!("[HOLLOW-SWARM] Decrypted envelope from {peer_str} failed MessageEnvelope parse ({} B) — falling through as legacy raw-text DM: {e}", text.len());
                    }
                    // Legacy raw-text DM (backward compatible). No signature
                    // available since these aren't wrapped in signed envelopes.
                    let legacy_ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let _ = event_tx
                        .send(NetworkEvent::MessageReceived {
                            from_peer: peer_str.to_string(),
                            text,
                            timestamp: legacy_ts,
                            message_id: String::new(),
                            reply_to_mid: String::new(),
                            link_preview: None,
                            signature: None,
                            public_key: None,
                            is_own: false,
                            duplicate: false,
                        })
                        .await;
                }
            }

            // Ack.
            
        }

        // -- CRDT sync message handlers --

        HavenMessage::SyncRequest { server_id, state_vector_json, mls_epoch } => {
            hollow_log!("[HOLLOW-CRDT] SyncRequest from {peer_str} for server {server_id}");


            if let Some(state) = server_states.get(&server_id) {
                // Compute what they're missing
                if let Ok(their_vector) = serde_json::from_str::<StateVector>(&state_vector_json) {
                    let delta = crdt_sync::compute_delta(&state.op_log, &their_vector);
                    if !delta.is_empty() {
                        if let Ok(ops_json) = serde_json::to_string(&delta) {
                            hollow_log!("[HOLLOW-CRDT] Sending {} delta ops to {peer_str}", delta.len());
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, HavenMessage::SyncResponse {
                                    server_id: server_id.clone(),
                                    ops_json,
                                },
                            );
                        }
                    }
                }

                // No bidirectional SyncRequest here — both peers trigger
                // sync in ConnectionEstablished, so both sides already initiate.
            }

            // Epoch hint (join-order SFrame race fix): the first-contact sync
            // doubles as the stale-group detector — serve a commit catch-up /
            // repair when the sender is behind, self-probe when it's ahead.
            if let (Some(their_epoch), Some(mls_mgr)) = (mls_epoch, mls.as_mut()) {
                crate::node::crypto_handler::handle_epoch_hint(
                    mls_mgr, ws_cmd_tx, ws_room_peers, server_states,
                    pending_mls_removals, mls_epoch_hint_cooldown,
                    &server_id, None, their_epoch, peer_str, local_peer_str,
                    false, // incidental hint on a sync — elect one responder
                );
            }
        }

        HavenMessage::ServerStateSnapshot { server_id, state_json } => {
            // SECURITY: only honored while a join WE initiated is pending —
            // an established member must never let another peer overwrite
            // its server state wholesale.
            if !pending_server_joins.contains_key(&server_id) {
                hollow_log!("[HOLLOW-CRDT] Ignoring ServerStateSnapshot for {server_id} (no pending join)");
                return;
            }
            match serde_json::from_str::<ServerState>(&state_json) {
                Ok(mut snap) => {
                    if snap.server_id != server_id {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ServerStateSnapshot from {peer_str} — server_id mismatch");
                        return;
                    }
                    snap.set_hlc(Hlc::new(local_peer_str.to_string()));
                    // Multi-device (Step 6): a snapshot from a not-yet-upgraded
                    // member may carry device-keyed joiners — fold to master.
                    snap.canonicalize_members(|id| super::resolver::resolve(id));
                    hollow_log!("[HOLLOW-CRDT] Adopted state snapshot for {server_id} from {peer_str} ({} channels, {} members, {} layout items)",
                        snap.channels.len(), snap.members.len(), snap.channel_layout.len());
                    // Persist now — the SyncResponse that follows re-persists
                    // after merging ops, but a crash between the two must not
                    // strand a half-joined server.
                    if let Ok(json) = serde_json::to_string(&snap) {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                        }
                    }
                    server_states.insert(server_id, snap);
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-CRDT] Invalid ServerStateSnapshot for {server_id}: {e}");
                }
            }
        }

        HavenMessage::SyncResponse { server_id, ops_json } => {
            hollow_log!("[HOLLOW-CRDT] SyncResponse from {peer_str} for server {server_id}");
            

            // Room gating: only accept sync for servers we already know about
            // or are actively trying to join.
            let is_known = server_states.contains_key(&server_id);
            let is_pending_join = pending_server_joins.contains_key(&server_id);
            if !is_known && !is_pending_join {
                hollow_log!("[HOLLOW-CRDT] Ignoring SyncResponse for unknown server {server_id} (not joined)");
                return;
            }

            // Tolerant parse: a NEWER client's op variant skips just that op,
            // never the whole batch.
            let incoming_ops = crate::crdt::operations::parse_ops_tolerant(&ops_json);
            if !incoming_ops.is_empty() {
                let state = server_states.entry(server_id.clone()).or_insert_with(|| {
                    // Skeleton for a pending join. The responder (peer_str) is
                    // just our sync source — when the owner is offline this is
                    // the MLS coordinator, a plain Member. Strip the creator
                    // seeding (member entry + Owner role) and zero the name
                    // register's HLC so the real name/owner always win the
                    // merge via the ServerCreated/ServerRenamed ops.
                    let mut s = ServerState::new(server_id.clone(), "".into(), peer_str.to_string());
                    s.members.remove(peer_str);
                    s.roles.remove(peer_str);
                    s.name = crate::crdt::admin_lww::AdminLwwReg::new(
                        String::new(),
                        crate::crdt::hlc::HlcTimestamp::zero(peer_str),
                        0,
                    );
                    s.set_hlc(Hlc::new(local_peer_str.to_string()));
                    s
                });

                // SECURITY (tombstone): a destructive `ServerDeleted` op delivered via
                // sync must be authenticated as Owner-authored, using OUR current role
                // map (ServerCreated, which we already hold, establishes the true Owner)
                // — never trust the relayer. Drop unauthorized tombstones BEFORE persist
                // + merge so they can't tombstone us via a forged sync.
                let incoming_ops: Vec<crate::crdt::operations::CrdtOp> = incoming_ops
                    .into_iter()
                    .filter(|op| {
                        if let crate::crdt::operations::CrdtPayload::ServerDeleted { .. } = op.payload {
                            let ok = state.get_role(&op.author) == crate::crdt::operations::MemberRole::Owner;
                            if !ok {
                                hollow_log!("[HOLLOW-SECURITY] Dropped synced ServerDeleted from non-owner {} for {server_id}", op.author);
                            }
                            ok
                        } else { true }
                    })
                    .collect();

                // Persist every synced op into the crdt_ops table (INSERT OR
                // IGNORE — idempotent). op_log is NOT serialized in the state
                // JSON, so without this a member that joined via sync holds
                // the server's history in RAM only and serves near-empty op
                // logs to future joiners after a restart (missing server
                // name/avatar/nicknames when the owner is offline).
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    for op in &incoming_ops {
                        if op.server_id == server_id {
                            let _ = store.insert_crdt_op(op);
                        }
                    }
                }

                // Capture membership BEFORE merge so we can detect a kick-while-offline
                // (we were a member, the synced ops remove us → self-evict on reconnect).
                let was_member_before = state.is_member(local_peer_str);

                match crdt_sync::merge_ops(state, &incoming_ops) {
                    // Run even when 0 ops applied if a join is pending — the
                    // joiner may have adopted a ServerStateSnapshot already
                    // (responder's op log can be empty/compacted), and the
                    // join must still complete.
                    Ok(applied) if applied > 0 || pending_server_joins.contains_key(&server_id) => {
                        hollow_log!("[HOLLOW-CRDT] Applied {applied} ops for server {server_id}");

                        // Multi-device (Step 6): fold any device-keyed members a
                        // not-yet-upgraded peer's ops introduced into their master.
                        state.canonicalize_members(|id| super::resolver::resolve(id));

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                            }
                        }

                        // Check if this completes a pending server join
                        if pending_server_joins.remove(&server_id).is_some() {
                            let server_name = state.name().to_string();
                            hollow_log!("[HOLLOW-CRDT] Server join completed: {server_id} ({server_name})");

                            // Drop stale MLS group from before ban/leave — forces fresh
                            // KeyPackage exchange so the rejoining peer gets a clean epoch.
                            if let Some(mls_mgr) = mls.as_mut() {
                                if mls_mgr.has_group(&server_id) {
                                    hollow_log!("[HOLLOW-MLS] Dropping stale MLS group for {server_id} on rejoin");
                                    mls_mgr.remove_group(&server_id);
                                    persist_mls_state(mls_mgr, crypto_store);
                                    mls_decrypt_failures.remove(&server_id);
                                }
                            }

                            // Join the WS relay room for this server so we receive MLS broadcasts.
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: server_id.clone(),
                            });

                            let _ = event_tx.send(NetworkEvent::ServerJoined {
                                server_id: server_id.clone(),
                                name: server_name,
                            }).await;

                            // Backfill profiles of OFFLINE members from the
                            // responder's cache (display name + avatar for
                            // chat rendering). Online members are covered by
                            // the normal per-peer ProfileRequest on sync, but
                            // during a pending join this server wasn't in
                            // server_states yet, so the proxy-profile pass in
                            // the RoomMembers handler skipped it entirely.
                            {
                                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                    let mut proxy_count = 0u32;
                                    for member_id in state.members.keys() {
                                        if proxy_count >= 10 { break; }
                                        if member_id == local_peer_str || member_id == peer_str { continue; }
                                        let is_online = ws_room_peers.values()
                                            .any(|peers| peers.contains(member_id.as_str()));
                                        if is_online { continue; }
                                        if let Ok(Some(_)) = store.load_profile_light(member_id) { continue; }
                                        hollow_log!("[HOLLOW-PROFILE] Post-join proxy profile request for {member_id} via {peer_str}");
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            peer_str, HavenMessage::ProfileRequestFor {
                                                target_peer_id: member_id.clone(),
                                            },
                                        );
                                        proxy_count += 1;
                                    }
                                }
                            }

                            // Auto-pledge min_pledge_mb for the newly joined server
                            {
                                let local_peer = local_peer_str.to_string();
                                if state.get_storage_pledge(&local_peer) == 0 {
                                    let min_pledge_bytes = state.min_pledge_mb() * 1024 * 1024;
                                    hollow_log!("[HOLLOW-VAULT] Auto-pledging {} MB for server {server_id}", min_pledge_bytes / (1024 * 1024));
                                    let pledge_op = state.create_op(CrdtPayload::StoragePledgeChanged {
                                        peer_id: local_peer.clone(),
                                        pledge_bytes: min_pledge_bytes,
                                    });
                                    let _ = state.apply_op(&pledge_op);

                                    if let Ok(json) = serde_json::to_string(&state) {
                                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                            let _ = store.save_server_state(&server_id, &json);
                                            let _ = store.insert_crdt_op(&pledge_op);
                                        }
                                    }

                                    // Broadcast pledge to connected members — MLS first, plaintext fallback.
                                    if let Ok(op_json) = serde_json::to_string(&pledge_op) {
                                        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                                        if mls_ok {
                                            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                                            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store) {
                                                hollow_log!("[HOLLOW-MLS] CrdtOp pledge broadcast failed: {e}");
                                            }
                                        } else {
                                            let pledge_data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
                                                server_id: server_id.clone(),
                                                op_json: op_json.clone(),
                                            }).unwrap_or_default();
                                            for member in state.members_list() {
                                                if member.peer_id == local_peer { continue; }
                                                send_raw_to_identity(ws_cmd_tx, ws_room_peers, &member.peer_id, pledge_data.clone());
                                            }
                                        }
                                    }
                                }
                            }

                            // Establish Olm session with all server members we're
                            // connected to but don't have sessions with yet.
                            // Members are master-keyed → bootstrap a session with each
                            // online DEVICE of every member (Olm is per-device).
                            for member in state.members_list() {
                                if super::resolver::same_identity(&member.peer_id, &local_peer_str) { continue; }
                                for dev in crate::node::crypto_handler::online_devices_for(ws_room_peers, &member.peer_id) {
                                    // Ensure the device shows as online in UI.
                                    let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                        peer: DiscoveredPeer { peer_id: dev.clone(), addresses: vec![] },
                                    }).await;
                                    if !olm.has_confirmed_session(&dev)
                                        && !key_request_is_fresh(key_request_in_flight, &dev)
                                    {
                                        hollow_log!("[HOLLOW-SWARM] No confirmed Olm session with server member device {dev}, sending KeyRequest");
                                        send_message_to_peer(ws_cmd_tx, ws_room_peers, &dev, signed_key_request(device_keypair, device_peer_id, &dev));
                                        key_request_in_flight.insert(dev.clone(), std::time::Instant::now());
                                    }
                                }
                            }

                            // MLS: if we don't have the MLS group after joining, send
                            // our KeyPackage to the JOIN RESPONDER (`peer_str`) — the
                            // device that just served us the SyncResponse. It is the
                            // online member we synced from (the owner, or the
                            // coordinator the owner delegated to), is provably in the
                            // room (it just messaged us), and reaching it directly
                            // avoids depending on a resolver link we may not have warmed
                            // yet for a freshly-joined server. The responder's
                            // MlsKeyPackage handler re-elects the real committer if it
                            // isn't the right one. This mirrors the RoomMembers /
                            // PeerJoined recovery paths, which send to the raw device id.
                            if let Some(mls_mgr) = mls.as_ref() {
                                if !mls_mgr.has_group(&server_id) {
                                    if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            peer_str, HavenMessage::MlsKeyPackage {
                                                server_id: server_id.clone(),
                                                key_package: kp_b64,
                                                channel_id: None,
                                            },
                                        );
                                        hollow_log!("[HOLLOW-MLS] Sent bootstrap KeyPackage to join responder {peer_str} for {server_id}");
                                    }
                                }
                            }
                        }

                        // Reconcile changes that happened while we were OFFLINE (the
                        // grow-only sync just delivered the ops): a server DELETION
                        // (tombstone), a BAN, or a plain KICK / our own LEAVE (fanned by
                        // a sibling) of us.
                        let deleted_now = state.is_deleted();
                        let kicked_now = was_member_before && !state.is_member(local_peer_str);
                        let banned_now = state.is_banned(&local_peer_str);
                        let evicted_sub_cids: Vec<String> = state.subgroup_channel_ids();
                        let pending = pending_server_joins.contains_key(&server_id);
                        if deleted_now {
                            // Owner tombstoned the server while we were offline. Leave the
                            // MLS group; keep the shell so we relay the tombstone onward.
                            if let Some(mls_mgr) = mls.as_mut() {
                                if mls_mgr.has_group(&server_id) {
                                    mls_mgr.remove_group(&server_id);
                                    persist_mls_state(mls_mgr, crypto_store);
                                }
                            }
                            let _ = event_tx.send(NetworkEvent::ServerDeleted {
                                server_id,
                            }).await;
                        } else if banned_now || (kicked_now && !pending) {
                            // Self-eviction reconciled from sync — tear down DURABLY, not
                            // just the UI event: without removing the state + DB row, the
                            // shell reloads on restart, re-lists the server, and the
                            // sibling re-announce path can even re-ADD us as a member of
                            // a server we left/were kicked from (authored by a non-member,
                            // so real members reject it → permanent fork). Mirrors the
                            // MemberKickBroadcast teardown, which only covers devices that
                            // were ONLINE at kick time.
                            hollow_log!("[HOLLOW-CRDT] Offline-reconciled self-eviction from {server_id} (banned={banned_now}) — durable teardown");
                            server_states.remove(&server_id);
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                let _ = store.delete_server_state(&server_id);
                            }
                            if let Some(mls_mgr) = mls.as_mut() {
                                if mls_mgr.has_group(&server_id) {
                                    mls_mgr.remove_group(&server_id);
                                }
                                for cid in &evicted_sub_cids {
                                    let gk = crate::crypto::subgroup_id(&server_id, cid);
                                    if mls_mgr.has_group(&gk) {
                                        mls_mgr.remove_group(&gk);
                                    }
                                }
                                persist_mls_state(mls_mgr, crypto_store);
                            }
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                room_code: server_id.clone(),
                            });
                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id,
                                peer_id: local_peer_str.to_string(),
                            }).await;
                        } else {
                            let _ = event_tx.send(NetworkEvent::SyncCompleted {
                                server_id,
                                ops_applied: applied as u32,
                            }).await;
                        }
                    }
                    _ => {}
                }
            }
        }

        HavenMessage::CrdtOpBroadcast { server_id, op_json } => {
            hollow_log!("[HOLLOW-CRDT] CrdtOpBroadcast from {peer_str} for server {server_id}");
            

            // Room gating: only accept ops for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                hollow_log!("[HOLLOW-CRDT] Ignoring CrdtOpBroadcast for unknown server {server_id}");
                return;
            }

            if let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
                // SECURITY: Log author mismatch but don't reject — the op may be
                // legitimately relayed by another peer during join/sync fan-out.
                // The per-payload permission check below validates the author's role.
                if op.author != peer_str {
                    hollow_log!("[HOLLOW-CRDT] Note: CrdtOpBroadcast author '{}' differs from sender '{peer_str}' (relay)", op.author);
                }

                // SECURITY: Verify the AUTHOR has permission for this operation type.
                // Shared ingest matrix (ServerState::op_allowed): uses op.author (the
                // original creator) for the role lookup, not the sender (who may be
                // relaying the op), and is override-aware — the same matrix the local
                // send handlers gate on.
                {
                    let state = server_states.get(&server_id).unwrap();
                    if !state.op_allowed(&op) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED CrdtOpBroadcast from {peer_str} — insufficient permission for {:?} (role: {:?})", op.payload, state.get_role(&op.author));
                        return;
                    }
                }

                let state = server_states.get_mut(&server_id).unwrap();

                let was_len = state.op_log.len();
                let _ = state.apply_op(&op);

                if state.op_log.len() > was_len {
                    // New op — persist and forward to other connected peers
                    if let Ok(json) = serde_json::to_string(&state) {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Forward the (validated, NEW) op onward. Tier 2 (large-server
                    // scaling): prefer the WebRTC mesh — the historical per-member
                    // SendDirect re-forward made EVERY receiving node pay
                    // O(members × devices) relay uploads per op (O(N²) network-wide).
                    // Op-newness gates this block, so each node re-floods a given op
                    // at most once and only after the permission checks above passed.
                    // Falls back to the relay fan-out when the mesh isn't up.
                    if super::gossip_relay::flood_crdt_op(
                        gossip_overlays, event_tx, &server_id, &op_json, Some(peer_str),
                    ) == 0 {
                        let crdt_msg = HavenMessage::CrdtOpBroadcast {
                            server_id: server_id.clone(),
                            op_json: op_json.clone(),
                        };
                        let crdt_data = serde_json::to_vec(&crdt_msg).unwrap_or_default();
                        for member_peer_str in state.members.keys() {
                            if super::resolver::same_identity(member_peer_str, &local_peer_str) { continue; }
                            for dev in crate::node::crypto_handler::online_devices_for(ws_room_peers, member_peer_str) {
                                if dev == peer_str { continue; } // don't echo back to the sender device
                                send_raw_to_peer(ws_cmd_tx, ws_room_peers, &dev, crdt_data.clone());
                            }
                        }
                    }

                    // Emit specific events based on op payload so Dart UI updates correctly.
                    // Set when a MemberRemoved op evicts OUR OWN identity — the durable
                    // teardown runs AFTER the match (the `state` borrow spans the match).
                    let mut self_evict_teardown = false;
                    match &op.payload {
                        CrdtPayload::ChannelAdded { channel_id, name, channel_type, .. } => {
                            let _ = event_tx.send(NetworkEvent::ChannelAdded {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                                channel_type: channel_type.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRemoved { channel_id } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRenamed { channel_id, new_name } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRenamed {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberAdded { peer_id, .. } => {
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberRemoved { peer_id } => {
                            // Self-eviction: OUR identity was removed (our own LEAVE
                            // fanned from a sibling device, or a plain kick of us) and
                            // the merge confirms we're no longer a member. Tear down
                            // DURABLY — the acting device deletes its state in
                            // handle_leave_server, but a sibling that only emitted
                            // MemberLeft kept the shell, which reloaded on restart and
                            // fed the sibling re-announce loop (a left server could
                            // resurrect on our own devices and even re-ADD us via the
                            // sibling join fast-path). Guarded on !pending so a rejoin
                            // replaying the old removal op can't nuke the fresh join.
                            let self_evicted = super::resolver::same_identity(peer_id, &local_peer_str)
                                && !pending_server_joins.contains_key(&server_id)
                                && !state.is_member(&local_peer_str);
                            if self_evicted {
                                self_evict_teardown = true; // teardown after the match
                                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                                    server_id: server_id.clone(),
                                }).await;
                            } else {
                                let _ = event_tx.send(NetworkEvent::MemberLeft {
                                    server_id: server_id.clone(),
                                    peer_id: peer_id.clone(),
                                }).await;
                            }
                        }
                        CrdtPayload::ServerDeleted { .. } => {
                            // Owner tombstoned the server. The state shell is RETAINED
                            // (so we keep serving the tombstone to our own offline peers),
                            // but we leave the MLS group + tell the UI to drop the server.
                            if let Some(mls_mgr) = mls {
                                mls_mgr.remove_group(&server_id);
                                persist_mls_state(mls_mgr, crypto_store);
                            }
                            let _ = event_tx.send(NetworkEvent::ServerDeleted {
                                server_id: server_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberBanned { peer_id } => {
                            let local_peer = local_peer_str.to_string();
                            if *peer_id == local_peer {
                                let _ = event_tx.send(NetworkEvent::MemberLeft {
                                    server_id: server_id.clone(),
                                    peer_id: peer_id.clone(),
                                }).await;
                            } else {
                                let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                    server_id: server_id.clone(),
                                }).await;
                            }
                        }
                        CrdtPayload::RoleChanged { peer_id, role, .. } => {
                            let _ = event_tx.send(NetworkEvent::RoleChanged {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                                new_role: role.as_str().to_string(),
                            }).await;
                        }
                        CrdtPayload::NicknameChanged { peer_id, .. } => {
                            // Re-use MemberJoined to trigger member list refresh in Dart
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::TwitchUsernameChanged { peer_id, .. } => {
                            // Re-use MemberJoined to trigger member list refresh in Dart
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MessagePinned { channel_id, message_id } => {
                            let _ = event_tx.send(NetworkEvent::MessagePinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MessageUnpinned { channel_id, message_id } => {
                            let _ = event_tx.send(NetworkEvent::MessageUnpinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelPublicChanged { channel_id, is_public } => {
                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;
                            // Broadcast to room (including guests) so public channel browsers see the change.
                            // Text only (#44) — a voice-channel announce put a ghost entry in
                            // browsers that the next list refresh dropped.
                            if let Some(ch) = state.channels.get(channel_id)
                                .filter(|c| c.channel_type == crate::crdt::server_state::ChannelType::Text)
                            {
                                let notify = HavenMessage::PublicChannelConfigChanged {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    is_public: *is_public,
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
                                    is_public: *is_public,
                                    channel_name: ch.name.clone(),
                                    category: ch.category.clone(),
                                }).await;
                            }
                        }
                        _ => {
                            // ServerRenamed, ServerSettingChanged, etc.
                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;
                        }
                    }

                    // Durable self-eviction teardown (flag set in the MemberRemoved arm;
                    // runs here because the `state` borrow spans the match). Removing the
                    // state FIRST also makes the subgroup reconcile below skip the server.
                    if self_evict_teardown {
                        hollow_log!("[HOLLOW-CRDT] Self MemberRemoved for {server_id} — durable teardown (sibling leave / kick)");
                        let sub_cids: Vec<String> = server_states.get(&server_id)
                            .map(|s| s.subgroup_channel_ids())
                            .unwrap_or_default();
                        server_states.remove(&server_id);
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            let _ = store.delete_server_state(&server_id);
                        }
                        if let Some(mls_mgr) = mls.as_mut() {
                            if mls_mgr.has_group(&server_id) {
                                mls_mgr.remove_group(&server_id);
                            }
                            for cid in &sub_cids {
                                let gk = crate::crypto::subgroup_id(&server_id, cid);
                                if mls_mgr.has_group(&gk) {
                                    mls_mgr.remove_group(&gk);
                                }
                            }
                            persist_mls_state(mls_mgr, crypto_store);
                        }
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                            room_code: server_id.clone(),
                        });
                    }

                    // Option B: a role/visibility op shifts who qualifies for restricted
                    // channels. Reconcile subgroups here too (coordinator-gated + idempotent)
                    // so the ACTUAL subgroup coordinator acts even when the op was authored
                    // by some other member. The `state` mutable borrow above has ended.
                    let affects_subgroups = matches!(
                        &op.payload,
                        CrdtPayload::RoleChanged { .. }
                            | CrdtPayload::ChannelVisibilityChanged { .. }
                            | CrdtPayload::MemberRemoved { .. }
                            | CrdtPayload::MemberBanned { .. }
                            | CrdtPayload::ChannelVisibilityLabelsChanged { .. }
                            | CrdtPayload::ChannelGrantSet { .. }
                            | CrdtPayload::ChannelGrantRevoked { .. }
                            | CrdtPayload::LabelAssigned { .. }
                            | CrdtPayload::LabelUnassigned { .. }
                            | CrdtPayload::LabelDeleted { .. }
                            | CrdtPayload::LabelUpdated { .. }
                    );
                    if affects_subgroups {
                        let only = match &op.payload {
                            CrdtPayload::ChannelVisibilityChanged { channel_id, .. }
                            | CrdtPayload::ChannelVisibilityLabelsChanged { channel_id, .. }
                            | CrdtPayload::ChannelGrantSet { channel_id, .. }
                            | CrdtPayload::ChannelGrantRevoked { channel_id, .. } => Some(channel_id.clone()),
                            _ => None,
                        };
                        if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&server_id)) {
                            crate::node::crypto_handler::reconcile_subgroups_for_server(
                                mls_mgr, ws_cmd_tx, ws_room_peers,
                                pending_mls_key_packages, pending_mls_removals,
                                state, &server_id, local_peer_str, only.as_deref(),
                            );
                        }
                        // If this op revoked OUR access to a voice channel we're in,
                        // drop the call (the subgroup removal above already rotates the
                        // SFrame key for the remaining participants).
                        voice_handler::auto_leave_invisible_voice_channels(
                            mls, ws_cmd_tx, ws_room_peers, server_states,
                            bundle_keypair, crypto_store,
                            voice_channel_participants, voice_channel_gossip_mode,
                            gossip_overlays, local_peer_str, device_peer_id, &server_id, event_tx,
                        ).await;
                    }
                }
            }
        }

        HavenMessage::ServerJoinRequest { server_id, twitch_proof_json, nsfw_confirmed } => {
            hollow_log!("[HOLLOW-CRDT] ServerJoinRequest from {peer_str} for server {server_id}");

            if let Some(state) = server_states.get_mut(&server_id) {
                // Multi-device: a SAME-IDENTITY requester is one of OUR OWN devices
                // (a sibling co-owning/co-membering this server, e.g. onboarding a
                // newly-created server). It skips the ban + Twitch + owner-verify gates
                // — those are for strangers; a sibling is already us. It still gets the
                // normal snapshot + MLS-leaf add below.
                let is_sibling = super::resolver::same_identity(peer_str, local_peer_str)
                    && peer_str != local_peer_str;

                // COORDINATOR GATE. This handler is the expensive half of a join:
                // a MemberAdded op, a full ServerStateSnapshot and the ENTIRE op
                // log, all aimed at one joiner. Nothing used to gate it, so every
                // online member ran the whole thing — N snapshots, N op logs and N
                // duplicate MemberAdded ops per join. Measured 2026-08-27 with the
                // relay meter: ~48 SendDirect commands per join at 5 members, ~170
                // at 9, ~342 at 13. Super-linear, while steady-state messaging sat
                // flat at 2 deliveries per other-member. The MLS half was already
                // election-gated to a single committer; this brings the CRDT half
                // onto the SAME election, so the two agree on who is serving.
                //
                // A repeat request inside the window means the joiner's 4s retry
                // fired: our elected coordinator did not answer (its socket died
                // between the relay's presence snapshot and now), so everyone
                // serves and the cost degrades to the old fan-out rather than to a
                // failed join. Siblings are never gated — a sibling IS us.
                let seen_key = format!("{server_id}|{peer_str}");
                let repeat_ask = join_request_seen
                    .get(&seen_key)
                    .is_some_and(|t: &std::time::Instant| t.elapsed() < JOIN_SERVE_RETRY_WINDOW);
                // Entries are only meaningful for one window; drop the expired ones
                // rather than letting a long-lived node accumulate one per join.
                if join_request_seen.len() > 256 {
                    join_request_seen.retain(|_, t| t.elapsed() < JOIN_SERVE_RETRY_WINDOW);
                }
                join_request_seen.insert(seen_key, std::time::Instant::now());
                if !is_sibling && !repeat_ask {
                    // Candidates are the CRDT members (every one of them holds the
                    // state a joiner needs), minus the joiner itself — a REJOINING
                    // member is already in `members` and electing them would leave
                    // nobody serving.
                    let candidates: Vec<String> = state.members.keys()
                        .filter(|m| !super::resolver::same_identity(peer_str, m))
                        .cloned()
                        .collect();
                    let coordinator = crate::node::crypto_handler::elect_server_coordinator(
                        state, &candidates, local_peer_str, &ws_room_peers,
                    );
                    if coordinator.as_deref()
                        .is_some_and(|c| !super::resolver::same_identity(c, local_peer_str))
                    {
                        hollow_log!("[HOLLOW-CRDT] Not the join coordinator for {server_id} (it is {coordinator:?}), leaving the join to them");
                        return;
                    }
                }

                // Ban check: reject banned peers before any other verification.
                if !is_sibling && state.is_banned(peer_str) {
                    hollow_log!("[HOLLOW-CRDT] Rejecting join from banned peer {peer_str} for server {server_id}");
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        peer_str, HavenMessage::ServerJoinRejected {
                            server_id,
                            reason: "banned".to_string(),
                        },
                    );
                    return;
                }

                // Twitch verification gate: check CRDT settings before accepting.
                if !is_sibling { if let Some(twitch_settings) = twitch::TwitchServerSettings::from_server_state(state) {
                    let reject_reason = match &twitch_proof_json {
                        None => Some("twitch_required".to_string()),
                        Some(proof_json) => {
                            match serde_json::from_str::<twitch::TwitchProof>(proof_json) {
                                Ok(proof) => twitch::validate_proof(&proof, &twitch_settings).err(),
                                Err(e) => Some(format!("Invalid Twitch proof: {e}")),
                            }
                        }
                    };
                    if let Some(reason) = reject_reason {
                        // Include full info so the joiner's client can display requirements and auto-retry.
                        // Format: "twitch_required:{channel_id}:{channel_name}:{server_name}:{min_follow_days}:{require_sub}"
                        let server_name = state.name().to_string();
                        let enriched_reason = if reason == "twitch_required" {
                            format!("twitch_required:{}:{}:{}:{}:{}",
                                twitch_settings.channel_id,
                                twitch_settings.channel_name,
                                server_name,
                                twitch_settings.min_follow_days,
                                twitch_settings.require_sub,
                            )
                        } else {
                            format!("twitch_failed:{}:{}:{}",
                                twitch_settings.channel_name,
                                server_name,
                                reason,
                            )
                        };
                        hollow_log!("[HOLLOW-CRDT] Rejecting join from {peer_str}: {reason}");
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::ServerJoinRejected {
                                server_id,
                                reason: enriched_reason,
                            },
                        );
                        return;
                    }
                } } // close Twitch gate + `if !is_sibling`

                // Owner-online verification: if enabled, only the owner accepts joins.
                if !is_sibling { if let Some(ref twitch_settings) = twitch::TwitchServerSettings::from_server_state(state) {
                    if twitch_settings.owner_verify {
                        let owner_id = state.roles.iter()
                            .find(|(_, reg)| *reg.read() == crate::crdt::operations::MemberRole::Owner)
                            .map(|(pid, _)| pid.clone());

                        if let Some(ref oid) = owner_id {
                            if oid != local_peer_str {
                                // We're not the owner — only the owner should accept.
                                // Check if the owner is online; if not, reject so the joiner isn't stuck waiting.
                                let owner_online = peer_is_reachable(ws_room_peers, oid);
                                if !owner_online {
                                    let server_name = state.name().to_string();
                                    send_message_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        peer_str, HavenMessage::ServerJoinRejected {
                                            server_id,
                                            reason: format!("twitch_owner_offline:{}", server_name),
                                        },
                                    );
                                }
                                // Either way, non-owner does not process the join.
                                return;
                            }
                            // We ARE the owner — proceed to accept below.
                        }
                    }
                } } // close owner-verify gate + `if !is_sibling`

                // Multi-device (Step 6): server membership is keyed by the MASTER
                // identity, never a device id. Resolve the joining device to its
                // master so one human = one member entry (the owner is already
                // master-keyed). Unknown device (guest / no device list yet) →
                // resolves to itself = byte-for-byte pre-multi-device.
                let member_master = super::resolver::resolve(peer_str);

                // Check if this identity is already a member (by master).
                let already_member = state.members_list().iter()
                    .any(|m| super::resolver::same_identity(&m.peer_id, &member_master));

                if !already_member {
                    // Private-server gate: an invite-only server rejects all new
                    // joiners (existing members re-joining are never blocked, since
                    // they short-circuit above). Mirrors the Twitch gate. A sibling
                    // (our own device) is exempt — it co-owns/co-members the server.
                    if !is_sibling && state.is_private() {
                        hollow_log!("[HOLLOW-CRDT] Rejecting join from {peer_str}: server {server_id} is private");
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::ServerJoinRejected {
                                server_id,
                                reason: format!("server_private:{}", state.name()),
                            },
                        );
                        return;
                    }

                    // NSFW consent gate: an NSFW-flagged server requires the joiner
                    // to accept a "proceed at your own risk" prompt first. Unlike
                    // private/full this is not a hard rejection — we reject ONCE with
                    // an `nsfw_confirm:` reason carrying the server name; the joiner's
                    // client shows the consent dialog and re-sends with
                    // `nsfw_confirmed=true`. Ordered after private/full so we never
                    // ask consent for a server they can't enter. Siblings exempt.
                    if !is_sibling && state.is_nsfw() && !nsfw_confirmed {
                        hollow_log!("[HOLLOW-CRDT] NSFW consent required for {peer_str} joining {server_id}");
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::ServerJoinRejected {
                                server_id,
                                reason: format!("nsfw_confirm:{}", state.name()),
                            },
                        );
                        return;
                    }

                    // Member-cap gate: reject if the server is at its configured
                    // max member count. None = unlimited.
                    if let Some(max) = state.max_members() {
                        if state.members_list().len() as u32 >= max {
                            hollow_log!("[HOLLOW-CRDT] Rejecting join from {peer_str}: server {server_id} is full ({max} max)");
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, HavenMessage::ServerJoinRejected {
                                    server_id,
                                    reason: format!("server_full:{}:{}", state.name(), max),
                                },
                            );
                            return;
                        }
                    }

                    // Add the new member via CRDT op, keyed by the MASTER identity.
                    // The short display label is derived from the master id.
                    let display_name = format!("{}...{}", &member_master[..4.min(member_master.len())], &member_master[member_master.len().saturating_sub(4)..]);
                    let op = state.create_op(CrdtPayload::MemberAdded {
                        peer_id: member_master.clone(),
                        display_name,
                    });
                    let _ = state.apply_op(&op);

                    // If Twitch proof contains a username, also create a TwitchUsernameChanged op
                    if let Some(ref proof_json) = twitch_proof_json {
                        if let Ok(proof) = serde_json::from_str::<crate::node::twitch::TwitchProof>(proof_json) {
                            if !proof.twitch_username.is_empty() {
                                let tw_op = state.create_op(CrdtPayload::TwitchUsernameChanged {
                                    peer_id: member_master.clone(),
                                    twitch_username: proof.twitch_username.clone(),
                                });
                                let _ = state.apply_op(&tw_op);
                            }
                        }
                    }

                    // Persist
                    if let Ok(json) = serde_json::to_string(&state) {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Broadcast MemberAdded to other peers — MLS first, plaintext fallback.
                    if let Ok(op_json) = serde_json::to_string(&op) {
                        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if mls_ok {
                            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store) {
                                hollow_log!("[HOLLOW-MLS] CrdtOp MemberAdded broadcast failed: {e}");
                            }
                        } else {
                            // Plaintext fallback: broadcast to all WS room peers.
                            if let Some(room_peers) = ws_room_peers.get(&server_id) {
                                let crdt_data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                }).unwrap_or_default();
                                for other_str in room_peers.iter() {
                                    if other_str == local_peer_str || other_str == peer_str { continue; }
                                    send_raw_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        other_str, crdt_data.clone(),
                                    );
                                }
                            }
                        }
                    }

                    let _ = event_tx.send(NetworkEvent::MemberJoined {
                        server_id: server_id.clone(),
                        peer_id: member_master.clone(),
                    }).await;

                    // Emit PeerDiscovered so the new member shows as online
                    // in the member panel (they may have connected via mDNS
                    // before being a server member, skipping the normal path).
                    if peer_is_reachable(ws_room_peers, &peer_str) {
                        let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                            peer: DiscoveredPeer {
                                peer_id: peer_str.to_string(),
                                addresses: vec![],
                            },
                        }).await;
                    }
                }

                // Send a full STATE snapshot first — op logs can be incomplete
                // (pre-persistence history loss, 1000-op compaction), so the
                // joiner must not depend on op replay alone to reconstruct
                // channels/layout/name. WS delivery is FIFO, so the snapshot
                // lands before the SyncResponse that completes the join.
                if let Ok(state_json) = serde_json::to_string(&state) {
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        peer_str, HavenMessage::ServerStateSnapshot {
                            server_id: server_id.clone(),
                            state_json,
                        },
                    );
                }

                // Send full server state to the joiner (all ops so they can reconstruct)
                let all_ops: Vec<&crate::crdt::operations::CrdtOp> = state.op_log.iter().collect();
                if let Ok(ops_json) = serde_json::to_string(&all_ops) {
                    hollow_log!("[HOLLOW-CRDT] Sending snapshot + {} ops to joiner {peer_str}", all_ops.len());
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        peer_str, HavenMessage::SyncResponse {
                            server_id,
                            ops_json,
                        },
                    );
                }

                // Proactively establish Olm session with the new member so
                // encrypted channel sync batches can be sent immediately.
                if !olm.has_confirmed_session(&peer_str) && !key_request_is_fresh(key_request_in_flight, peer_str) {
                    hollow_log!("[HOLLOW-SWARM] No confirmed Olm session with new member {peer_str}, sending KeyRequest");
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                    );
                    key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());
                }
            } else {
                hollow_log!("[HOLLOW-CRDT] ServerJoinRequest for unknown server {server_id}");
            }
        }

        HavenMessage::ServerJoinRejected { server_id, reason } => {
            hollow_log!("[HOLLOW-CRDT] Join rejected for {server_id}: {reason}");
            // A join request reaches every online member, so each one may send
            // its own rejection. Only surface the FIRST for an in-flight join —
            // remove() returns Some only if the join was still pending, which
            // dedups the rejection popup (otherwise the joiner sees N popups).
            let was_pending = pending_server_joins.remove(&server_id).is_some();
            if was_pending {
                let _ = event_tx.send(NetworkEvent::TwitchJoinRejected {
                    server_id,
                    reason,
                }).await;
            }
        }

        HavenMessage::ServerDeleteBroadcast { server_id } => {
            hollow_log!("[HOLLOW-CRDT] ServerDeleteBroadcast from {peer_str} for server {server_id}");
            

            // SECURITY: Verify sender is the server Owner before deleting.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                if sender_role != crate::crdt::operations::MemberRole::Owner {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED ServerDeleteBroadcast from non-owner {peer_str} (role: {:?}) for server {server_id}", sender_role);
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED ServerDeleteBroadcast for unknown server {server_id}");
                return;
            }

            // Legacy one-shot path (a pre-tombstone peer may still send this). Convert
            // it to a TOMBSTONE rather than hard-delete: synthesize the owner's
            // ServerDeleted op locally, apply + persist it, and keep the shell so we
            // relay it onward like the CRDT-op path. (New senders no longer emit this.)
            if let Some(state) = server_states.get_mut(&server_id) {
                if !state.is_deleted() {
                    let now_ms = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms });
                    let _ = state.apply_op(&op);
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.insert_crdt_op(&op);
                        if let Ok(json) = serde_json::to_string(&*state) {
                            let _ = store.save_server_state(&server_id, &json);
                        }
                    }
                    if let Some(mls_mgr) = mls {
                        mls_mgr.remove_group(&server_id);
                        persist_mls_state(mls_mgr, crypto_store);
                    }
                    let _ = event_tx.send(NetworkEvent::ServerDeleted {
                        server_id,
                    }).await;
                }
            }
        }

        HavenMessage::MemberKickBroadcast { server_id } => {
            hollow_log!("[HOLLOW-CRDT] MemberKickBroadcast from {peer_str} — kicked from server {server_id}");
            

            // SECURITY: Verify sender has KICK_MEMBERS permission and outranks us.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                // Override-aware — must match the kicker's own has_permission gate.
                let sender_perms = state.get_permissions(&peer_str);
                let local_peer = local_peer_str.to_string();
                let our_role = state.get_role(&local_peer);
                if (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) == 0 {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — no KICK_MEMBERS permission (role: {:?})", sender_role);
                    return;
                }
                if !sender_role.outranks(&our_role) {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — does not outrank us ({:?} vs {:?})", sender_role, our_role);
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast for unknown server {server_id}");
                return;
            }

            // Same cleanup as ServerDeleteBroadcast — remove ourselves from this server.
            if server_states.remove(&server_id).is_some() {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.delete_server_state(&server_id);
                }

                // Clean up MLS group.
                if let Some(mls_mgr) = mls {
                    mls_mgr.remove_group(&server_id);
                    persist_mls_state(mls_mgr, crypto_store);
                }

                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id,
                }).await;
            }
        }

        HavenMessage::ChannelSyncRequest { server_id, channel_id, since_timestamp, sender_timestamps } => {
            

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            // Dedup: if we already responded to this peer+channel within 2s, skip.
            // Prevents flood from multiple parallel sync triggers on the requester's side.
            let resp_dedup_key = format!("{server_id}:{channel_id}:resp:{peer_str}");
            if channel_sync_sent.get(&resp_dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
                return;
            }
            channel_sync_sent.insert(resp_dedup_key, std::time::Instant::now());

            hollow_log!("[HOLLOW-SYNC] ChannelSyncRequest from {peer_str} for {channel_id} in {server_id} since {since_timestamp} (per-sender: {} entries)", sender_timestamps.len());

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                // Per-sender sync when watermarks were sent, legacy single-timestamp
                // fallback otherwise — shared with the MLS/Olm responders.
                if let Ok((envelope, count)) = super::sync_handler::build_channel_sync_batch(
                    &store, &server_id, &channel_id, since_timestamp, &sender_timestamps,
                ) {
                    hollow_log!("[HOLLOW-SYNC] Sending {count} sync messages for {channel_id}");
                    // Send via MLS if peer is in the group, otherwise Olm fallback.
                    // Don't use MLS if peer hasn't joined yet (they sent plaintext request
                    // before receiving Welcome) — they can't decrypt the MLS response.
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    send_encrypted_message(
                        olm, crypto_store,
                        peer_str, &envelope_json, event_tx,
                        ws_cmd_tx, ws_room_peers,
                    ).await;
                }
            }
        }

        // -- Multi-peer fan-out sync probe handlers --

        HavenMessage::ChannelSyncProbe { server_id, channel_id, our_latest, msg_count: _probe_count } => {
            

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let their_latest = store
                    .get_latest_channel_timestamp(&server_id, &channel_id)
                    .unwrap_or(None)
                    .unwrap_or(0);
                let msg_count = store
                    .count_channel_messages(&server_id, &channel_id);

                hollow_log!(
                    "[HOLLOW-SYNC] Probe from {peer_str} for {channel_id}: ours={their_latest} theirs={our_latest} (count={msg_count})"
                );

                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    peer_str, HavenMessage::ChannelSyncProbeResponse {
                        server_id,
                        channel_id,
                        their_latest,
                        msg_count,
                    },
                );
            }
        }

        HavenMessage::ChannelSyncProbeResponse { server_id, channel_id, their_latest, msg_count } => {
            

            // Compare: if the peer has newer messages than us, fire a full sync request.
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let our_latest = store
                    .get_latest_channel_timestamp(&server_id, &channel_id)
                    .unwrap_or(None)
                    .unwrap_or(0);
                let our_msg_count = store.count_channel_messages(&server_id, &channel_id);

                // Sync if: peer has newer messages (timestamp check only).
                // Dedup: skip if already syncing this channel recently.
                let dedup_key = format!("{server_id}:{channel_id}");
                let recently_synced = channel_sync_sent.get(&dedup_key)
                    .is_some_and(|t| t.elapsed() < Duration::from_secs(5));
                if their_latest > our_latest && !recently_synced {
                    channel_sync_sent.insert(dedup_key, std::time::Instant::now());
                    let sender_ts = store
                        .get_per_sender_timestamps(&server_id, &channel_id)
                        .unwrap_or_default();
                    hollow_log!(
                        "[HOLLOW-SYNC] Probe response: {channel_id} needs sync (ts: ours={our_latest} peer={their_latest}, count: ours={our_msg_count} peer={msg_count}). Requesting from {peer_str}"
                    );
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        peer_str, HavenMessage::ChannelSyncRequest {
                            server_id: server_id.clone(),
                            channel_id: channel_id.clone(),
                            since_timestamp: our_latest,
                            sender_timestamps: sender_ts,
                        },
                    );
                } else {
                    hollow_log!(
                        "[HOLLOW-SYNC] Probe response: {channel_id} is up to date (ts: ours={our_latest} peer={their_latest}, count: {our_msg_count}). Skipping."
                    );
                    // Emit completion for this channel so UI knows sync is done.
                    let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                        server_id,
                        new_message_count: 0,
                    }).await;
                }
            }
        }

        HavenMessage::DmSyncRequest { since_timestamp, both_directions } => {
            hollow_log!("[HOLLOW-SYNC] DmSyncRequest from {peer_str} since {since_timestamp} (both_directions={both_directions})");

            // Multi-device: the requester sends its DEVICE id, but our DM rows for
            // that person are keyed by their MASTER id (the conversation key). A
            // multi-device requester (e.g. a friend's 2nd device) therefore matched
            // ZERO rows under the raw device id → we replied "Sending 0" and the
            // catch-up sync silently delivered nothing (text limped through on live
            // fan-out; a file whose live WebRTC stream failed was then lost entirely
            // — no placeholder, no metadata). Resolve to the master for the lookup;
            // the transport send still targets the raw device `peer_str`. No-op
            // single-device (resolve returns the id unchanged).
            let convo_peer = super::resolver::resolve(&peer_str);

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                // Multi-device peer-fallback: a multi-device requester sets
                // `both_directions` so we re-serve the requester's OWN messages
                // (sent from another of their devices, stored here as is_mine=0)
                // alongside our own — otherwise those are stranded when that
                // other device is offline. A single-device requester omits the
                // flag → the cheap is_mine=1-only path, byte-for-byte as before.
                let messages_result = if both_directions {
                    store.get_dm_messages_for_sibling(&convo_peer, since_timestamp, 200)
                } else {
                    store.get_dm_messages_since(&convo_peer, since_timestamp, 200)
                };
                if let Ok(messages) = messages_result {
                        hollow_log!("[HOLLOW-SYNC] Sending {} DM sync messages to {peer_str} (convo {convo_peer}, both_directions={both_directions})", messages.len());
                        let super::sync_handler::SyncPage { items, truncated } =
                            build_dm_sync_items(&store, &messages);

                        if !items.is_empty() {
                            // `truncated` = the preview budget ended the page
                            // early, so there is more to serve regardless of
                            // how short it came out.
                            let has_more = if truncated || items.len() >= 200 {
                                Some(true)
                            } else {
                                None
                            };
                            let envelope = MessageEnvelope::DmSyncBatch {
                                messages: items,
                                has_more,
                            };
                            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                            if olm.has_session(peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    peer_str, &envelope_json, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            } else {
                                // Asymmetric fresh-peer handshake: THEY built a session
                                // and sent us this catch-up request, but our half was
                                // never built (a dropped glare frame). Encrypting now
                                // would hit "No session" and surface a user-visible
                                // MessageSendFailed for a purely internal sync reply.
                                // Queue the batch + re-key instead — pending_messages is
                                // drained on the KeyBundle-success / PreKey-decrypt /
                                // co-presence heal paths, exactly like every deferred DM.
                                pending_messages
                                    .entry(peer_str.to_string())
                                    .or_default()
                                    .push(envelope_json);
                                if !key_request_is_fresh(key_request_in_flight, peer_str) {
                                    send_message_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                                    );
                                    key_request_in_flight
                                        .insert(peer_str.to_string(), std::time::Instant::now());
                                }
                            }
                        }
                    }
            }
        }

        HavenMessage::DmSiblingSyncRequest { per_convo_since } => {
            // Multi-device (Phase 6 / Step 5): a sibling device asks for our FULL
            // DM history across ALL conversations, both directions. Honor ONLY for
            // our own other device — a friend must never pull our whole DB.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-SYNC] Dropped DmSiblingSyncRequest from non-self peer {peer_str}"
                );
                return;
            }
            let since_map: std::collections::HashMap<String, i64> =
                per_convo_since.into_iter().collect();

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let convos = store.get_dm_peer_ids();
                hollow_log!(
                    "[HOLLOW-SYNC] DmSiblingSyncRequest from sibling {peer_str} — serving {} conversation(s)",
                    convos.len()
                );
                for convo in convos {
                    let since = since_map.get(&convo).copied().unwrap_or(0);
                    let messages = match store.get_dm_messages_for_sibling(&convo, since, 200) {
                        Ok(m) => m,
                        Err(e) => {
                            hollow_log!("[HOLLOW-SYNC] sibling sync read failed for {convo}: {e}");
                            continue;
                        }
                    };
                    if messages.is_empty() { continue; }
                    let super::sync_handler::SyncPage { items, truncated } =
                        build_dm_sync_items(&store, &messages);
                    // `truncated` = the preview budget cut the page short, so
                    // more remains even when the page is under the limit.
                    let has_more = if truncated || messages.len() >= 200 { Some(true) } else { None };
                    hollow_log!(
                        "[HOLLOW-SYNC] Sending {} sibling DM(s) for convo {convo} to {peer_str} (has_more={has_more:?})",
                        items.len()
                    );
                    let envelope = MessageEnvelope::DmSiblingSyncBatch {
                        convo: convo.clone(),
                        messages: items,
                        has_more,
                    };
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    if olm.has_session(peer_str) {
                        send_encrypted_message(
                            olm, crypto_store,
                            peer_str, &envelope_json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    } else {
                        // No session yet (asymmetric fresh handshake) — queue each
                        // batch + re-key rather than hard-fail with MessageSendFailed.
                        // See the DmSyncRequest responder above for the full rationale.
                        pending_messages
                            .entry(peer_str.to_string())
                            .or_default()
                            .push(envelope_json);
                        if !key_request_is_fresh(key_request_in_flight, peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
                            );
                            key_request_in_flight
                                .insert(peer_str.to_string(), std::time::Instant::now());
                        }
                    }
                }
            }
        }

        HavenMessage::PeerDisconnecting => {
            hollow_log!("[HOLLOW-SWARM] Peer {peer_str} is disconnecting gracefully");

            // Peer is gracefully disconnecting — emit PeerDisconnected.
            let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::SiblingProveRequest { nonce } => {
            // A peer in OUR inbox is challenging us to prove we are its sibling (we
            // share the master key). We sign `hollow-sibling:{our_master}:{our_device}:
            // {nonce}` with the MASTER key. A genuine challenger shares our master, so
            // it can reconstruct + verify this; a stranger that somehow received this
            // (it never should — strangers don't sit in our inbox to challenge) gains
            // nothing because the proof binds to OUR master, which only real siblings
            // hold. `master_peer_str` is our master peer_id; `device_peer_id` is ours.
            let (sig_b64, master_pubkey_b64) =
                super::crypto_handler::build_sibling_proof(master_keypair, device_peer_id, &nonce);
            hollow_log!("[HOLLOW-SIBLING] Answering sibling-proof challenge from {peer_str}");
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                peer_str, HavenMessage::SiblingProveResponse { nonce, sig_b64, master_pubkey_b64 },
            );
        }

        HavenMessage::SiblingProveResponse { nonce, sig_b64, master_pubkey_b64 } => {
            // The peer we challenged answered. Verify the proof binds to OUR master AND
            // to the device id WE challenged (peer_str — taken from the routing layer,
            // never self-reported) AND to the nonce we issued. Only on a valid proof do
            // we treat it as our sibling and run the convergence machinery.
            let Some((expected_nonce, issued_at)) = pending_sibling_challenges.get(peer_str) else {
                hollow_log!("[HOLLOW-SIBLING] Unsolicited/expired SiblingProveResponse from {peer_str} — ignored");
                return;
            };
            if *expected_nonce != nonce {
                hollow_log!("[HOLLOW-SIBLING] Nonce mismatch in SiblingProveResponse from {peer_str} — ignored");
                return;
            }
            if issued_at.elapsed() >= Duration::from_secs(60) {
                hollow_log!("[HOLLOW-SIBLING] Stale SiblingProveResponse from {peer_str} — ignored");
                pending_sibling_challenges.remove(peer_str);
                return;
            }
            if !super::crypto_handler::verify_sibling_proof(
                local_peer_str, peer_str, &nonce, &sig_b64, &master_pubkey_b64,
            ) {
                hollow_log!("[HOLLOW-SIBLING] INVALID sibling proof from {peer_str} — NOT a sibling, no merge");
                pending_sibling_challenges.remove(peer_str);
                return;
            }
            pending_sibling_challenges.remove(peer_str);
            hollow_log!("[HOLLOW-SIBLING] Verified sibling {peer_str} via master-signed proof — converging");
            on_verified_sibling(
                ws_cmd_tx, ws_room_peers, master_keypair,
                device_peer_id, local_peer_str, server_states,
                link_snapshot_requested, is_invisible,
                db_path, db_passphrase, peer_str,
            );
        }

        HavenMessage::SiblingServerAnnounce { server_id } => {
            // Multi-device: one of OUR OWN devices created a server and is telling us
            // (its sibling) to onboard. SECURITY: only act on a SAME-IDENTITY sender —
            // a stranger can't pull us into a server this way.
            if !super::resolver::same_identity(&peer_str, local_peer_str) {
                hollow_log!("[HOLLOW-SECURITY] Ignored SiblingServerAnnounce from non-sibling {peer_str}");
                return;
            }
            // Already joining → nothing to do (a SyncResponse will complete it and
            // emit ServerJoined).
            if pending_server_joins.contains_key(&server_id) {
                return;
            }
            // A tombstoned server we still hold the shell of → ignore (deletion
            // reconciles via the grow-only CRDT path, not a re-join).
            if let Some(state) = server_states.get(&server_id) {
                if state.is_deleted() { return; }
            }
            // ALWAYS run the inline join flow — even if we ALREADY hold the server.
            // This is the deliberate choice (vs. a weaker ServerUpdated nudge that
            // proved unreliable at refreshing the UI): the join flow ends in
            // `Server join completed` → NetworkEvent::ServerJoined → Dart
            // `onServerCreated`, which UNCONDITIONALLY inserts the server into
            // serverListProvider. That is the exact path a live (both-online) create
            // uses and the ONLY path observed to refresh the list reliably. For a
            // server we already have, the same-identity ServerJoinRequest fast-path
            // on the responder just re-serves the snapshot/ops (idempotent —
            // message/op dedup), and the SyncResponse handler completes the pending
            // join (it runs even with 0 new ops when a join is pending). MLS isn't
            // re-keyed: we keep our existing leaf; the bootstrap KeyPackage only
            // fires if we lack the group.
            hollow_log!("[HOLLOW-CRDT] Sibling {peer_str} announced server {server_id}; running join flow (have_it={})", server_states.contains_key(&server_id));
            // Lightweight inline join (mirrors handle_join_server): join the rooms +
            // send a ServerJoinRequest to the announcer, which same-identity fast-paths
            // us (serves the snapshot + adds our MLS leaf). No twitch proof for a co-owner.
            // Same-identity join: bypasses the gates anyway (the receiver's NSFW
            // gate is `!is_sibling`), so no twitch proof and nsfw pre-confirmed.
            pending_server_joins.insert(server_id.clone(), PendingJoin { twitch_proof_json: None, nsfw_confirmed: true });
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: server_id.clone() });
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                &peer_str, HavenMessage::ServerJoinRequest {
                    server_id: server_id.clone(),
                    twitch_proof_json: None,
                    nsfw_confirmed: true,
                },
            );
        }

        // -- MLS message handlers --

        HavenMessage::MlsChannelMessage { server_id, body, channel_id: msg_channel_id } => {
            // Restricted channels (Option B) are encrypted under a per-channel
            // subgroup keyed by `subgroup_id(server, channel)`. `group_key` is the
            // bare server_id for `None` (server-wide group, backward compatible).
            let group_key = match &msg_channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            hollow_log!("[HOLLOW-TOPIC] RECV MlsChannelMessage from {peer_str} for {group_key} ({} b64 bytes)", body.len());


            if let Some(mls_mgr) = mls {
                if !mls_mgr.has_group(&group_key) {
                    hollow_log!("[HOLLOW-MLS] Received MlsChannelMessage for unknown group {group_key}");

                    // If we're a member of this server but don't have the MLS group,
                    // the Welcome was lost. Send KeyPackage to the coordinator
                    // (lowest online peer) for MLS bootstrap.
                    // Only do this once per group to avoid spamming (expires after 60s).
                    if !mls_bootstrap_requested.get(&group_key).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                        if let Some(state) = server_states.get(&server_id) {
                            // Subgroup: only bootstrap if we actually qualify for the
                            // channel (a non-qualifying member never holds the key and
                            // must NOT request it). Server group: any member bootstraps.
                            let may_bootstrap = match &msg_channel_id {
                                Some(cid) => state.can_see_channel(&local_peer_str, cid),
                                None => true,
                            };
                            // Coordinator = lowest online MASTER (excluding us). For a
                            // subgroup the candidate set is the qualifying members; for
                            // the server group it's all members.
                            let coordinator = match &msg_channel_id {
                                Some(cid) => crate::node::crypto_handler::elect_subgroup_coordinator(
                                    state, cid, &local_peer_str, ws_room_peers,
                                ).filter(|c| c != &local_peer_str),
                                None => {
                                    // Server group: target the OWNER (always holds the
                                    // group) when online — single authoritative re-adder.
                                    // Fall back to lowest-master only if owner is offline.
                                    crate::node::crypto_handler::server_bootstrap_target(
                                        state, &local_peer_str, ws_room_peers,
                                    )
                                }
                            };
                            if may_bootstrap {
                                if let Some(coordinator) = coordinator {
                                    if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                        let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                            server_id: server_id.clone(),
                                            key_package: kp_b64,
                                            channel_id: msg_channel_id.clone(),
                                        }).unwrap_or_default();
                                        let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
                                        if sent > 0 {
                                            hollow_log!("[HOLLOW-MLS] Sent KeyPackage to coordinator {coordinator} ({sent} device(s)) for {group_key} bootstrap (triggered by message)");
                                            mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
                                        }
                                    }
                                }
                            }
                        }
                    }

                    return;
                }

                let ciphertext = match base64::engine::general_purpose::STANDARD.decode(&body) {
                    Ok(ct) => ct,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode failed: {e}"); return; }
                };

                match mls_mgr.decrypt(&group_key, &ciphertext) {
                    Ok((plaintext, sender_peer_id)) => {
                        *mls_dirty = true;
                        mls_decrypt_failures.remove(&group_key); // Reset failure counter on success.
                        hollow_log!("[HOLLOW-TOPIC] DECRYPT ok for {group_key}, sender(leaf)={sender_peer_id}");

                        // Parse the plaintext as a MessageEnvelope.
                        let envelope_str = String::from_utf8_lossy(&plaintext);
                        let envelope = match serde_json::from_str::<MessageEnvelope>(&envelope_str) {
                            Ok(env) => env,
                            Err(e) => {
                                hollow_log!("[HOLLOW-MLS] Decrypted envelope in {group_key} from leaf {sender_peer_id} failed MessageEnvelope parse ({} B) — dropped: {e}", envelope_str.len());
                                return;
                            }
                        };

                        // Target filtering: if this envelope has a target and it's not us, discard.
                        // The ratchet already advanced by decrypting — that's the point.
                        let local_peer = local_peer_str.to_string();
                        if let Some(target) = envelope.target() {
                            if target != local_peer {
                                return; // Not for us — discard silently.
                            }
                        }

                        // Multi-device (Step 6): the MLS leaf credential is the
                        // sender's DEVICE id, but channel messages/edits/reactions
                        // are signed by — and attributed to — the sender's MASTER.
                        // Resolve once: `sender_master` for attribution + signature
                        // verification, `sender_peer_id` (device) kept for Olm
                        // reply/transport sites (sync responders, file re-requests).
                        let sender_master = super::resolver::resolve(&sender_peer_id);

                        match envelope {
                            MessageEnvelope::ChannelMessage { inner } => {
                                let ChannelMessagePayload { sid, cid, text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us } = *inner;
                                let mod_state = server_states.get(&sid);
                                message_ops::handle_envelope_channel_message(
                                    event_tx, bundle_keypair, mod_state, &local_peer,
                                    sender_master.clone(), sid, cid, text, ts,
                                    sig, pk, mid, reply_to, file_id, link_preview, order_us,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid, cid } => {
                                let mod_state = sid.as_deref().and_then(|s| server_states.get(s));
                                message_ops::handle_envelope_edit_message(
                                    event_tx, bundle_keypair, mod_state, &sender_master,
                                    mid, new_text, ts, sig, pk, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::LinkPreviewSet { mid, lp, ts, sig, pk, sid, cid } => {
                                let mod_state = sid.as_deref().and_then(|s| server_states.get(s));
                                message_ops::handle_envelope_link_preview_set(
                                    event_tx, mod_state, &sender_master, &local_peer,
                                    mid, lp, ts, sig, pk, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid, cid } => {
                                message_ops::handle_envelope_delete_message(
                                    event_tx, bundle_keypair, &sender_master,
                                    mid, ts, sig, pk, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid, cid } => {
                                let mod_state = sid.as_deref().and_then(|s| server_states.get(s));
                                message_ops::handle_envelope_add_reaction(
                                    event_tx, bundle_keypair, mod_state, &sender_master,
                                    mid, emoji, ts, sig, pk, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::RemoveReaction { mid, emoji, ts, sig, pk, sid, cid } => {
                                message_ops::handle_envelope_remove_reaction(
                                    event_tx, bundle_keypair, &sender_master,
                                    mid, emoji, ts, sig, pk, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::FileHeader { inner } => {
                                let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref, thumb, voice, .. } = *inner;
                                file_handler::handle_envelope_file_header(
                                    server_states, pending_file_streams, pending_shard_streams,
                                    early_file_streams, bundle_keypair, event_tx,
                                    &server_id, sender_peer_id,
                                    fid, name, ext, mime, size, chunks, img, w, h,
                                    mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref,
                                    thumb, voice,
                                    requested_file_receipts, declined_file_ids,
                                    ws_cmd_tx, ws_room_peers,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::FileChunk { fid, idx, data } => {
                                file_handler::handle_envelope_file_chunk(
                                    bundle_keypair, event_tx, fid, idx, data,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            // -- Phase 6 new MLS dispatch branches --

                            MessageEnvelope::CrdtOp { sid, op_json } => {
                                // Detect a membership/visibility op BEFORE applying so we
                                // can reconcile subgroups + auto-leave invisible voice
                                // channels afterwards. This op may arrive via MLS *or*
                                // plaintext (we now send both); whichever wins the race
                                // applies it and the other no-ops — so BOTH paths must run
                                // the reconcile/auto-leave, else neither fires when MLS wins.
                                let sniffed_op = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json).ok();
                                let affects_subgroups = sniffed_op.as_ref()
                                    .map(|o| matches!(
                                        o.payload,
                                        crate::crdt::operations::CrdtPayload::RoleChanged { .. }
                                            | crate::crdt::operations::CrdtPayload::ChannelVisibilityChanged { .. }
                                            | crate::crdt::operations::CrdtPayload::MemberRemoved { .. }
                                            | crate::crdt::operations::CrdtPayload::MemberBanned { .. }
                                            | crate::crdt::operations::CrdtPayload::ChannelVisibilityLabelsChanged { .. }
                                            | crate::crdt::operations::CrdtPayload::ChannelGrantSet { .. }
                                            | crate::crdt::operations::CrdtPayload::ChannelGrantRevoked { .. }
                                            | crate::crdt::operations::CrdtPayload::LabelAssigned { .. }
                                            | crate::crdt::operations::CrdtPayload::LabelUnassigned { .. }
                                            | crate::crdt::operations::CrdtPayload::LabelDeleted { .. }
                                            | crate::crdt::operations::CrdtPayload::LabelUpdated { .. }
                                    ))
                                    .unwrap_or(false);
                                let only_cid = if affects_subgroups {
                                    sniffed_op.and_then(|o| match o.payload {
                                        crate::crdt::operations::CrdtPayload::ChannelVisibilityChanged { channel_id, .. }
                                        | crate::crdt::operations::CrdtPayload::ChannelVisibilityLabelsChanged { channel_id, .. }
                                        | crate::crdt::operations::CrdtPayload::ChannelGrantSet { channel_id, .. }
                                        | crate::crdt::operations::CrdtPayload::ChannelGrantRevoked { channel_id, .. } => Some(channel_id),
                                        _ => None,
                                    })
                                } else { None };

                                // Capture membership BEFORE apply: a MemberRemoved of OUR
                                // identity arriving via MLS must trigger the same durable
                                // self-eviction teardown as the plaintext CrdtOpBroadcast
                                // path. The op is sent BOTH ways and the op_log dedups —
                                // when MLS wins the race the plaintext copy no-ops, so
                                // this path must tear down too or the shell survives.
                                let was_member_before = server_states.get(&sid)
                                    .map(|s| s.is_member(&local_peer_str))
                                    .unwrap_or(false);

                                sync_handler::handle_envelope_crdt_op(
                                    server_states, bundle_keypair, event_tx,
                                    sid.clone(), op_json,
                                    crdt_store,
                                    ws_cmd_tx,
                                ).await;

                                let self_evicted = was_member_before
                                    && !pending_server_joins.contains_key(&sid)
                                    && server_states.get(&sid)
                                        .map(|s| !s.is_member(&local_peer_str) && !s.is_deleted())
                                        .unwrap_or(false);
                                if self_evicted {
                                    hollow_log!("[HOLLOW-CRDT] Self-eviction via MLS CrdtOp for {sid} — durable teardown");
                                    let sub_cids: Vec<String> = server_states.get(&sid)
                                        .map(|s| s.subgroup_channel_ids())
                                        .unwrap_or_default();
                                    server_states.remove(&sid);
                                    crdt_store.delete_server(sid.clone());
                                    if let Some(mls_mgr) = mls.as_mut() {
                                        if mls_mgr.has_group(&sid) {
                                            mls_mgr.remove_group(&sid);
                                        }
                                        for cid in &sub_cids {
                                            let gk = crate::crypto::subgroup_id(&sid, cid);
                                            if mls_mgr.has_group(&gk) {
                                                mls_mgr.remove_group(&gk);
                                            }
                                        }
                                        persist_mls_state(mls_mgr, crypto_store);
                                    }
                                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                        room_code: sid.clone(),
                                    });
                                    let _ = event_tx.send(NetworkEvent::ServerDeleted {
                                        server_id: sid.clone(),
                                    }).await;
                                }

                                if affects_subgroups {
                                    if let (Some(mls_mgr), Some(state)) = (mls.as_mut(), server_states.get(&sid)) {
                                        crate::node::crypto_handler::reconcile_subgroups_for_server(
                                            mls_mgr, ws_cmd_tx, ws_room_peers,
                                            pending_mls_key_packages, pending_mls_removals,
                                            state, &sid, local_peer_str, only_cid.as_deref(),
                                        );
                                    }
                                    voice_handler::auto_leave_invisible_voice_channels(
                                        mls, ws_cmd_tx, ws_room_peers, server_states,
                                        bundle_keypair, crypto_store,
                                        voice_channel_participants, voice_channel_gossip_mode,
                                        gossip_overlays, local_peer_str, device_peer_id, &sid, event_tx,
                                    ).await;
                                }
                            }

                            MessageEnvelope::ServerDelete { sid } => {
                                // Author permission check is by MASTER identity.
                                sync_handler::handle_envelope_server_delete(
                                    server_states, mls, bundle_keypair, event_tx,
                                    &sender_master, sid,
                                    crypto_store, crdt_store,
                                ).await;
                            }

                            MessageEnvelope::MemberKick { sid } => {
                                // Kick author permission check is by MASTER identity.
                                sync_handler::handle_envelope_member_kick(
                                    server_states, mls, bundle_keypair, event_tx,
                                    &local_peer, &sender_master, sid,
                                    crypto_store, crdt_store,
                                ).await;
                            }

                            MessageEnvelope::Typing { sid, cid } => {
                                // Typing indicator is keyed on the MASTER identity.
                                super::social::handle_envelope_typing(
                                    event_tx, sender_master.clone(), sid, cid,
                                ).await;
                            }

                            MessageEnvelope::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list, avatar_hash, banner_hash, showcase_board, showcase_assets_b64, showcase_assets_hash, avatar_frame, avatar_anim, banner_anim, profile_sig, profile_pk } => {
                                if peer_invisible {
                                    let _ = event_tx.send(NetworkEvent::PeerStatusChanged {
                                        peer_id: sender_peer_id.clone(),
                                        status: "invisible".to_string(),
                                    }).await;
                                }
                                let envelope_revoked = super::social::handle_envelope_profile_update(
                                    event_tx, server_states, master_peer_str,
                                    device_peer_id, master_keypair, ws_cmd_tx, ws_room_peers,
                                    sender_peer_id, display_name, status, about_me,
                                    updated_at, avatar_b64, banner_b64, twitch_username,
                                    device_list, avatar_hash, banner_hash, showcase_board,
                                    showcase_assets_b64, showcase_assets_hash, avatar_frame,
                                    avatar_anim, banner_anim,
                                    profile_sig, profile_pk,
                                    db_path, db_passphrase,
                                ).await;
                                // Step 7: enforce revocations learned via the MLS
                                // server-member profile path too (Olm drop + single
                                // leaf removal where we coordinate).
                                enforce_device_revocations(
                                    &envelope_revoked, olm, crypto_store, Some(&*mls_mgr),
                                    local_peer_str, ws_room_peers, pending_mls_removals,
                                );
                            }

                            MessageEnvelope::SyncReq { sid, state_vector_json, .. } => {
                                sync_handler::handle_envelope_sync_req(
                                    server_states, olm, crypto_store, mls_mgr,
                                    bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
                                    sender_peer_id, sid, state_vector_json,
                                    crdt_store,
                                ).await;
                            }

                            MessageEnvelope::SyncResp { sid, ops_json, .. } => {
                                sync_handler::handle_envelope_sync_resp(
                                    server_states, bundle_keypair, event_tx,
                                    sid, ops_json,
                                    crdt_store,
                                ).await;
                            }

                            MessageEnvelope::ChannelSyncReq { sid, cid, since_timestamp, sender_timestamps, .. } => {
                                sync_handler::handle_envelope_channel_sync_req(
                                    server_states, olm, bundle_keypair, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                    &sender_peer_id, sid, cid, since_timestamp, sender_timestamps,
                                    crypto_store, crdt_store,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ChannelProbe { sid, cid, our_latest: _their_latest, msg_count: _their_count, .. } => {
                                sync_handler::handle_envelope_channel_probe(
                                    server_states, olm, crypto_store,
                                    bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
                                    sender_peer_id, sid, cid,
                                    crdt_store,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ChannelProbeResp { sid, cid, their_latest, msg_count, .. } => {
                                sync_handler::handle_envelope_channel_probe_resp(
                                    bundle_keypair, ws_cmd_tx, ws_room_peers,
                                    channel_sync_sent, sender_peer_id,
                                    sid, cid, their_latest, msg_count,
                                    crdt_store,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, .. } => {
                                sync_handler::handle_envelope_channel_sync_batch(
                                    olm, bundle_keypair, event_tx, ws_cmd_tx,
                                    ws_room_peers, &local_peer, &sender_peer_id,
                                    sid, cid, messages, total, has_more,
                                    crypto_store, crdt_store,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            // -- Vault/shard envelopes via MLS (same logic as Olm handlers) --

                            MessageEnvelope::ShardStore { inner } => {
                                let ShardStorePayload { sid, cid, si, sk, k, m, total_size, tier, data, chunks, .. } = *inner;
                                vault_ops::handle_envelope_shard_store(
                                    server_states, pending_shard_streams, olm,
                                    bundle_keypair, crypto_store, event_tx, ws_cmd_tx,
                                    ws_room_peers, sender_peer_id,
                                    sid, cid, si, sk, k, m, total_size, tier, data, chunks,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ShardChunk { .. } => {
                                vault_ops::handle_envelope_shard_chunk(&sender_peer_id).await;
                            }

                            MessageEnvelope::ShardStoreAck { sid, cid, si, ok, err, .. } => {
                                vault_ops::handle_envelope_shard_store_ack(
                                    event_tx, sid, cid, si, ok, err,
                                ).await;
                            }

                            MessageEnvelope::ShardDelete { sid, cid } => {
                                vault_ops::handle_envelope_shard_delete(
                                    server_states, event_tx,
                                    &sender_peer_id, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ShardRequest { sid, cid, si, sk, .. } => {
                                vault_ops::handle_envelope_shard_request(
                                    server_states, olm, crypto_store,
                                    bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
                                    webrtc_peers, pending_webrtc_sends,
                                    &server_id, sender_peer_id, sid, cid, si, sk,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ShardResponse { sid, cid, si, data, chunks, found, .. } => {
                                vault_ops::handle_envelope_shard_response(
                                    pending_shard_streams, event_tx, sender_peer_id,
                                    sid, cid, si, data, chunks, found,
                                ).await;
                            }

                            MessageEnvelope::ShardResponseChunk { .. } => {
                                vault_ops::handle_envelope_shard_response_chunk().await;
                            }

                            MessageEnvelope::ShardProbe { sid, cid, .. } => {
                                vault_ops::handle_envelope_shard_probe(
                                    server_states, olm, crypto_store,
                                    bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
                                    sender_peer_id, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ShardProbeResponse { sid, cid, shards, .. } => {
                                vault_ops::handle_envelope_shard_probe_response(
                                    &sender_peer_id, sid, cid, shards,
                                ).await;
                            }

                            MessageEnvelope::VaultManifestBroadcast { sid, cid, chid, manifest } => {
                                vault_ops::handle_envelope_vault_manifest_broadcast(
                                    sid, cid, chid, manifest,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::ShardMigrate { sid, cid, si, sk, data, .. } => {
                                vault_ops::handle_envelope_shard_migrate(
                                    server_states, &sender_peer_id,
                                    sid, cid, si, sk, data,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            // -- Voice channel signaling (Phase 5C) --
                            // SECURITY (Phase 6.25): VC signal sub-rate-limiter (drop on rate-limit).
                            MessageEnvelope::VoiceChannelJoin { .. }
                            | MessageEnvelope::VoiceChannelLeave { .. }
                            | MessageEnvelope::VoiceChannelSdpOffer { .. }
                            | MessageEnvelope::VoiceChannelSdpAnswer { .. }
                            | MessageEnvelope::VoiceChannelIce { .. }
                            | MessageEnvelope::VoiceChannelAudioState { .. }
                            | MessageEnvelope::VoiceChannelScreenOffer { .. }
                            | MessageEnvelope::VoiceChannelScreenAnswer { .. }
                            | MessageEnvelope::VoiceChannelScreenIce { .. }
                            | MessageEnvelope::VoiceChannelScreenState { .. }
                            | MessageEnvelope::VoiceChannelScreenWatch { .. }
                            | MessageEnvelope::VoiceChannelScreenAssign { .. }
                            | MessageEnvelope::VoiceChannelScreenFeedState { .. }
                            | MessageEnvelope::VoiceChannelRenegOffer { .. }
                            | MessageEnvelope::VoiceChannelRenegAnswer { .. }
                            | MessageEnvelope::VoiceChannelLegRestart { .. }
                            | MessageEnvelope::VoiceChannelCameraState { .. }
                            | MessageEnvelope::VoiceChannelRecordingState { .. }
                            if !voice_handler::vc_rate_check(vc_signal_rate_tokens, peer_str) => {
                                // Rate limited — drop silently (already logged).
                            }

                            // VC participants/signaling are keyed by the ROUTABLE WS
                            // sender (`peer_str`), NOT the MLS leaf credential
                            // (`sender_peer_id`). For a multi-device sender these can
                            // differ — the leaf credential is not a live socket, so
                            // using it would (a) add a PHANTOM second participant that
                            // can never connect (the cause of "two ALs" in the VC list)
                            // and (b) make every SDP/ICE reply Olm-target an unreachable
                            // id. The plaintext VC path already uses the routable sender;
                            // matching it here lets the Set dedup the two arrivals.
                            MessageEnvelope::VoiceChannelJoin { sid, cid } => {
                                voice_handler::handle_envelope_voice_channel_join(
                                    server_states, voice_channel_participants,
                                    voice_channel_gossip_mode, gossip_overlays,
                                    ws_cmd_tx, event_tx, local_peer_str, device_peer_id,
                                    peer_str.to_string(), sid, cid,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelLeave { sid, cid } => {
                                voice_handler::handle_envelope_voice_channel_leave(
                                    voice_channel_participants, voice_channel_gossip_mode,
                                    gossip_overlays, event_tx, local_peer_str, device_peer_id,
                                    peer_str.to_string(), sid, cid,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelSdpOffer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_sdp_offer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelSdpAnswer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_sdp_answer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelIce { sid, cid, candidate, sdp_mid, sdp_mline_index, .. } => {
                                voice_handler::handle_envelope_voice_channel_ice(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, candidate, sdp_mid, sdp_mline_index,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelAudioState { sid, cid, muted, deafened, .. } => {
                                voice_handler::handle_envelope_voice_channel_audio_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, muted, deafened,
                                ).await;
                            }

                            // -- Voice channel screen sharing (Phase 5B) --
                            MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, origin, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_offer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp, origin, local_peer_str,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, origin, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_answer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp, origin, local_peer_str,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, origin, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_ice(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, candidate, sdp_mid, sdp_mline_index, role,
                                    origin, local_peer_str,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenState { sid, cid, enabled, quality, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, enabled, quality,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenWatch { sid, cid, want, viewer_width, viewer_height, route, fwd_capable, relay_private, fwd_simulcast, fwd_feed, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_watch(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, want,
                                    viewer_width, viewer_height, route, fwd_capable, relay_private, fwd_simulcast, fwd_feed,
                                ).await;
                            }

                            MessageEnvelope::VoiceChannelScreenAssign { sid, cid, origin, forwarder, feed_target, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_assign(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, origin, forwarder, feed_target,
                                    local_peer_str,
                                ).await;
                            }

                            MessageEnvelope::VoiceChannelScreenFeedState { sid, cid, origin, forwarder, up, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_feed_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, origin, forwarder, up,
                                    local_peer_str,
                                ).await;
                            }

                            // -- Voice channel camera (Phase 5B) --
                            MessageEnvelope::VoiceChannelRenegOffer { sid, cid, sdp, ice_restart, .. } => {
                                voice_handler::handle_envelope_voice_channel_reneg_offer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp, ice_restart,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelRenegAnswer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_reneg_answer(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelLegRestart { sid, cid, .. } => {
                                voice_handler::handle_envelope_voice_channel_leg_restart(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelCameraState { sid, cid, enabled, .. } => {
                                voice_handler::handle_envelope_voice_channel_camera_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, enabled,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelRecordingState { sid, cid, recording, .. } => {
                                voice_handler::handle_envelope_voice_channel_recording_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, recording,
                                ).await;
                            }

                            // -- Gossip relay tree (Phase 5D) --
                            MessageEnvelope::BroadcastMeta { broadcast_id, origin, sid, cid, file_id, ttl } => {
                                file_handler::handle_envelope_broadcast_meta(
                                    gossip_overlays, local_peer_str, &sender_peer_id,
                                    broadcast_id, origin, sid, cid, file_id, ttl,
                                ).await;
                            }

                            // DM-only envelopes should never arrive via MLS.
                            MessageEnvelope::DirectMessage { .. }
                            | MessageEnvelope::DmSyncBatch { .. }
                            | MessageEnvelope::DmSiblingSyncBatch { .. }
                            | MessageEnvelope::SessionAck => {
                                hollow_log!("[HOLLOW-MLS] Unexpected DM envelope via MLS from {sender_peer_id} — ignoring");
                            }

                            // Forwarder control plane is Olm-direct inside the
                            // fwd:{forwarder} room by contract — the forwarder
                            // holds no group keys, so fwd_* via MLS is always
                            // misdirected or spoofed.
                            MessageEnvelope::FwdStreamRegister { .. }
                            | MessageEnvelope::FwdStreamAuth { .. }
                            | MessageEnvelope::FwdStreamUnregister { .. }
                            | MessageEnvelope::FwdIngestOffer { .. }
                            | MessageEnvelope::FwdIngestAnswer { .. }
                            | MessageEnvelope::FwdAttach { .. }
                            | MessageEnvelope::FwdDetach { .. }
                            | MessageEnvelope::FwdEgressOffer { .. }
                            | MessageEnvelope::FwdEgressAnswer { .. }
                            | MessageEnvelope::FwdError { .. } => {
                                hollow_log!("[HOLLOW-MLS] Unexpected fwd_* envelope via MLS from {sender_peer_id} — ignoring");
                            }
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Decrypt failed for {group_key}: {e}");

                        // Immediately request sync from the sender. Server group:
                        // all subscribed channels (the dropped message came via topic
                        // routing for one of them). Subgroup: just that one channel.
                        // 5s dedup prevents flood.
                        {
                            let dedup_key = format!("mls_fail_sync:{group_key}:{peer_str}");
                            if !channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
                                channel_sync_sent.insert(dedup_key, std::time::Instant::now());
                                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                    let sync_cids: Vec<String> = match &msg_channel_id {
                                        Some(cid) => vec![cid.clone()],
                                        None => subscribed_channels
                                            .get(&server_id)
                                            .cloned()
                                            .unwrap_or_default(),
                                    };
                                    for cid in &sync_cids {
                                        let sender_ts = store.get_per_sender_timestamps(&server_id, cid)
                                            .unwrap_or_default();
                                        let our_latest = store.get_latest_channel_timestamp(&server_id, cid)
                                            .unwrap_or(None).unwrap_or(0);
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            peer_str, HavenMessage::ChannelSyncRequest {
                                                server_id: server_id.clone(),
                                                channel_id: cid.clone(),
                                                since_timestamp: our_latest,
                                                sender_timestamps: sender_ts,
                                            },
                                        );
                                    }
                                    hollow_log!("[HOLLOW-MLS] Requested immediate sync from {peer_str} for {} channel(s) in {group_key}", sync_cids.len());
                                }
                            }
                        }

                        // Server group: ALSO request a CRDT op-log sync — on a SHORTER
                        // dedup than the message sync above. A WrongEpoch failure usually
                        // means the sender is ahead (it advanced the epoch + may have
                        // broadcast new CRDT ops — a freshly created channel, a visibility
                        // change — that we can't decrypt and would otherwise never learn
                        // about, since per-channel message sync only covers channels we
                        // already know). Several such ops can arrive back-to-back (create
                        // then restrict), so a 1s dedup lets each trigger a fresh op-log
                        // delta rather than the 5s message-sync window swallowing the rest.
                        if msg_channel_id.is_none() {
                            let op_dedup = format!("mls_fail_opsync:{group_key}:{peer_str}");
                            if !channel_sync_sent.get(&op_dedup).is_some_and(|t| t.elapsed() < Duration::from_secs(1)) {
                                channel_sync_sent.insert(op_dedup, std::time::Instant::now());
                                if let Some(state) = server_states.get(&server_id) {
                                    let our_vector = StateVector::from_server_state(state);
                                    if let Ok(sv) = serde_json::to_string(&our_vector) {
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            peer_str, HavenMessage::SyncRequest {
                                                server_id: server_id.clone(),
                                                state_vector_json: sv,
                                                // A decrypt failure often IS epoch skew —
                                                // let the responder catch us up.
                                                mls_epoch: mls_mgr.epoch(&server_id).ok(),
                                            },
                                        );
                                    }
                                }
                            }
                        }

                        // Track consecutive failures — trigger recovery after 3 that
                        // are actually SUSTAINED. The count alone counted a burst: on
                        // rejoin the relay's availability cache replays every buffered
                        // channel frame at once, so a returning member saw three
                        // undecryptable frames in the same millisecond and nuked its
                        // group before the first `SyncRequest` (which carries the epoch
                        // hint) had even arrived. That is ONE event, not three, and the
                        // heal it pre-empted was the cheap one. Measured in the fleet
                        // 2026-08-27: probe sent, catch-up served, then "Ignoring
                        // MlsCommitCatchup for group we don't hold".
                        let entry = mls_decrypt_failures
                            .entry(group_key.clone())
                            .or_insert_with(|| (0, std::time::Instant::now()));
                        entry.0 += 1;
                        let sustained = entry.1.elapsed() >= MLS_DECRYPT_FAIL_WINDOW;
                        let count = &mut entry.0;

                        // An epoch probe already in flight is about to answer with a
                        // commit catch-up, which costs NO epoch churn. Dropping the
                        // group out from under it wastes that answer ("Ignoring
                        // MlsCommitCatchup for group we don't hold") and heals the
                        // heavy way instead: remove + re-add, two epochs, rekeying
                        // everyone. Seen in the fleet 2026-08-27 — a returning owner
                        // rejoins, the relay's availability cache replays three
                        // buffered channel frames instantly, and the ladder beat the
                        // probe's round trip every time. Hold the group for one grace
                        // window; if the answer does not come, the ladder still runs.
                        let probe_in_flight = mls_epoch_hint_cooldown
                            .get(&format!("{group_key}|probe"))
                            .is_some_and(|t| t.elapsed() < EPOCH_PROBE_GRACE);
                        if *count >= 3 && !sustained {
                            hollow_log!("[HOLLOW-MLS] {} decrypt failures for {group_key} in one burst — waiting for it to be sustained before dropping the group", count);
                        } else if *count >= 3 && probe_in_flight {
                            hollow_log!("[HOLLOW-MLS] {} decrypt failures for {group_key}, but an epoch probe is in flight — holding the group for the catch-up", count);
                        } else if *count >= 3 && !mls_bootstrap_requested.get(&group_key).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                            hollow_log!("[HOLLOW-MLS] {} consecutive decrypt failures — initiating MLS recovery for {group_key}", count);
                            *count = 0;

                            // Drop broken group and request re-bootstrap from coordinator.
                            mls_mgr.remove_group(&group_key);
                            persist_mls_state(mls_mgr, crypto_store);

                            if let Some(state) = server_states.get(&server_id) {
                                let local_peer = local_peer_str.to_string();
                                // Only attempt recovery if we're still a member (skip if banned/removed).
                                // Members are master-keyed; our master is the key. For a
                                // subgroup we must also still QUALIFY for the channel.
                                let still_eligible = state.members.contains_key(&local_peer)
                                    && match &msg_channel_id {
                                        Some(cid) => state.can_see_channel(&local_peer, cid),
                                        None => true,
                                    };
                                if !still_eligible {
                                    hollow_log!("[HOLLOW-MLS] Skipping recovery for {group_key} — no longer eligible");
                                } else {
                                    // Coordinator = lowest online MASTER (excluding us);
                                    // send to one of its online DEVICES. Subgroup uses the
                                    // qualifying-member candidate set.
                                    let coordinator = match &msg_channel_id {
                                        Some(cid) => crate::node::crypto_handler::elect_subgroup_coordinator(
                                            state, cid, &local_peer, ws_room_peers,
                                        ).filter(|c| c != &local_peer),
                                        None => {
                                            // Server group: recover from the OWNER (always
                                            // holds the group) when online; else lowest master.
                                            crate::node::crypto_handler::server_bootstrap_target(
                                                state, &local_peer, ws_room_peers,
                                            )
                                        }
                                    };
                                    if let Some(coordinator) = coordinator {
                                        if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                            let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                            let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                                server_id: server_id.clone(),
                                                key_package: kp_b64,
                                                channel_id: msg_channel_id.clone(),
                                            }).unwrap_or_default();
                                            let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
                                            mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
                                            hollow_log!("[HOLLOW-MLS] Sent recovery KeyPackage to coordinator {coordinator} ({sent} device(s)) for {group_key}");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackage { server_id, key_package, channel_id: kp_channel_id } => {
            // Restricted channel (Option B): the KeyPackage is for the per-channel
            // subgroup. `group_key` is the bare server_id for the server group.
            let group_key = match &kp_channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            hollow_log!("[HOLLOW-MLS] MlsKeyPackage from {peer_str} for {group_key}");

            // L6: Reject KeyPackage from non-members (prevents unauthorized MLS group joins).
            // Multi-device (Step 6): members are keyed by MASTER; the sender is a
            // DEVICE. Accept if the sending device's IDENTITY is a member — this is
            // what lets a SIBLING of an existing member get its own leaf added
            // without first being its own CRDT member. Unknown device → resolves to
            // itself → falls back to plain membership (single-device unchanged).
            // For a subgroup, the sender's identity must additionally QUALIFY for
            // the channel (role satisfies the visibility tier) — otherwise we'd add
            // a leaf that cryptographically defeats the channel restriction.
            if let Some(state) = server_states.get(&server_id) {
                let is_member = state.members.keys()
                    .any(|k| super::resolver::same_identity(peer_str, k));
                if !is_member {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackage from non-member {peer_str} for {group_key}");
                    return;
                }
                if let Some(cid) = &kp_channel_id {
                    let sender_master = super::resolver::resolve(peer_str);
                    if !state.can_see_channel(&sender_master, cid) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED subgroup MlsKeyPackage from {peer_str} — role doesn't satisfy channel {cid} tier");
                        return;
                    }
                }
            } else {
                hollow_log!("[HOLLOW-MLS] No server state for {server_id}, skipping KeyPackage");
                return;
            }

            // SIBLING-RE-ADDS-SIBLING fast path (keystone regen recovery): if WE hold
            // the group and the sender is OUR OWN identity (a sibling/keystone that
            // regenerated its leaf), WE process it directly — the coordinator election
            // below excludes the sender's identity (= ours), leaving an owned-server
            // keystone with no one to re-add it. We hold a valid device-credentialed
            // leaf, so the batch processor below removes any STALE leaf sharing the
            // sender's credential (the keystone's old master-credentialed leaf — same
            // id "M" — caught by the "sender already a leaf" branch) and adds the new
            // leaf to the SAME group: one epoch advance, no fork. The `!=` guard keeps
            // us from self-processing (we never send our own KP to ourselves).
            let sibling_readd = mls.as_ref().is_some_and(|m| {
                if !(m.has_group(&group_key)
                    && super::resolver::same_identity(peer_str, local_peer_str)
                    && peer_str != local_peer_str)
                {
                    return false;
                }
                // If several of OUR OWN device leaves currently hold the group, only the
                // lowest-id one re-adds (deterministic single re-adder → no glare). The
                // sender's (regenerating) leaf is excluded from this tiebreak set.
                let our_leaves: Vec<String> = m.group_members(&group_key)
                    .into_iter()
                    .filter(|p| super::resolver::same_identity(p, local_peer_str) && p != peer_str)
                    .collect();
                our_leaves.iter().map(|s| s.as_str()).min() == Some(&device_peer_id[..])
            });
            if sibling_readd {
                hollow_log!("[HOLLOW-MLS] Sibling re-add: adding our own sibling {peer_str}'s regenerated leaf to {group_key} (bypassing coordinator election)");
            }

            // Distributed committer: lowest online MLS member (by MASTER identity)
            // processes KeyPackages. The sender's IDENTITY is excluded from the
            // election — they sent the KeyPackage because they (or a sibling) lost
            // their group, so neither the sending device nor its siblings can be
            // the coordinator that processes it.
            if !sibling_readd { if let Some(mls_mgr) = mls.as_ref() {
                if mls_mgr.has_group(&group_key) {
                    let members: Vec<String> = mls_mgr.group_members(&group_key)
                        .into_iter()
                        .filter(|p| !super::resolver::same_identity(p, peer_str))
                        .collect();
                    // Server group: prefer the OWNER as the single authoritative
                    // committer (linear epochs; avoids the non-owner-committer
                    // fan-out-miss divergence with 3+ distinct members). Subgroup
                    // with a group: deterministic lowest-master election.
                    let coordinator = if kp_channel_id.is_none() {
                        server_states.get(&server_id).map_or_else(
                            || elect_coordinator(&members, local_peer_str, &ws_room_peers),
                            |s| crate::node::crypto_handler::elect_server_coordinator(
                                s, &members, local_peer_str, &ws_room_peers,
                            ),
                        )
                    } else {
                        elect_coordinator(&members, local_peer_str, &ws_room_peers)
                    };
                    if coordinator.as_deref() != Some(local_peer_str) {
                        hollow_log!("[HOLLOW-MLS] Not MLS coordinator for {group_key} (excluding sender identity), skipping KeyPackage");
                        return;
                    }
                } else if kp_channel_id.is_some() {
                    // Subgroup doesn't exist yet — the elected subgroup coordinator
                    // (lowest online qualifying member, excluding the sender) creates
                    // and populates it. Candidate set = members who can see the channel.
                    let cid = kp_channel_id.as_deref().unwrap();
                    let coordinator = server_states.get(&server_id).and_then(|s| {
                        let mut masters: Vec<String> = s.members.keys()
                            .filter(|m| s.can_see_channel(m, cid))
                            .filter(|m| !super::resolver::same_identity(peer_str, m))
                            .filter(|m| m.as_str() == local_peer_str || peer_is_reachable(&ws_room_peers, m))
                            .cloned()
                            .collect();
                        masters.sort();
                        masters.dedup();
                        masters.into_iter().next()
                    });
                    if coordinator.as_deref() != Some(local_peer_str) {
                        hollow_log!("[HOLLOW-MLS] Not subgroup coordinator for {group_key}, skipping KeyPackage");
                        return;
                    }
                } else {
                    // No server MLS group yet — only the owner can create it.
                    let local_peer = local_peer_str.to_string();
                    let is_owner = server_states.get(&server_id)
                        .map(|s| {
                            s.roles.get(&local_peer)
                                .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                .unwrap_or(false)
                        })
                        .unwrap_or(false);
                    if !is_owner {
                        hollow_log!("[HOLLOW-MLS] No MLS group for {server_id} and not owner, skipping KeyPackage");
                        return;
                    }
                }
            } } // close `if let Some(mls_mgr)` + `if !sibling_readd`

            if let Some(mls_mgr) = mls {
                // Create MLS group lazily if it doesn't exist (server group: migration
                // for pre-MLS servers; subgroup: first restricted-channel join).
                if !mls_mgr.has_group(&group_key) {
                    hollow_log!("[HOLLOW-MLS] Lazily creating MLS group {group_key}");
                    if let Err(e) = mls_mgr.create_group(&group_key) {
                        hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}");
                        return;
                    }
                }

                // Step 1: Queue stale MLS members for batch removal. A leaf is stale
                // iff NO CRDT member shares its identity (Step 6: leaves are device
                // ids, members are masters) — and, for a subgroup, additionally if the
                // member's identity no longer QUALIFIES for the channel (demoted).
                // Never sweep our own device's leaf.
                if let Some(state) = server_states.get(&server_id) {
                    let mls_members = mls_mgr.group_members(&group_key);
                    for stale_peer in &mls_members {
                        if super::resolver::same_identity(stale_peer, local_peer_str) { continue; }
                        let stale_master = super::resolver::resolve(stale_peer);
                        let has_member = state.members.keys()
                            .any(|k| super::resolver::same_identity(stale_peer, k));
                        let qualifies = match &kp_channel_id {
                            Some(cid) => state.can_see_channel(&stale_master, cid),
                            None => true,
                        };
                        if !has_member || !qualifies {
                            hollow_log!("[HOLLOW-MLS] Queuing stale/ineligible MLS member {stale_peer} for batch removal from {group_key}");
                            pending_mls_removals.entry(group_key.clone()).or_default().push(stale_peer.clone());
                        }
                    }
                }

                // Step 2: If the SENDING DEVICE already has a leaf, queue THAT exact
                // leaf for batch removal + re-add (recovery). Match the exact device
                // id — never a sibling's live leaf (siblings have distinct ids).
                if mls_mgr.group_members(&group_key).contains(&peer_str.to_string()) {
                    hollow_log!("[HOLLOW-MLS] Device {peer_str} already in MLS group {group_key} — queuing for batch removal + re-add");
                    pending_mls_removals.entry(group_key.clone()).or_default().push(peer_str.to_string());
                }

                let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(&key_package) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode KeyPackage failed: {e}"); return; }
                };

                // Queue KeyPackage for batch processing (single epoch advance per batch).
                pending_mls_key_packages
                    .entry(group_key.clone())
                    .or_default()
                    .push((peer_str.to_string(), kp_bytes));
                hollow_log!("[HOLLOW-MLS] Queued KeyPackage from {peer_str} for batch add to {group_key}");
            }
        }

        HavenMessage::MlsWelcome { server_id, welcome, channel_id: wl_channel_id } => {
            let group_key = match &wl_channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            hollow_log!("[HOLLOW-MLS] MlsWelcome from {peer_str} for {group_key}");


            if let Some(mls_mgr) = mls {
                let welcome_bytes = match base64::engine::general_purpose::STANDARD.decode(&welcome) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode Welcome failed: {e}"); return; }
                };

                // If group already exists locally (stale from failed recovery), remove it first.
                if mls_mgr.has_group(&group_key) {
                    hollow_log!("[HOLLOW-MLS] Removing stale local group for {group_key} before Welcome");
                    mls_mgr.remove_group(&group_key);
                }

                match mls_mgr.join_from_welcome(&group_key, &welcome_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, crypto_store);
                        mls_bootstrap_requested.remove(&group_key);
                        mls_decrypt_failures.remove(&group_key);
                        hollow_log!("[HOLLOW-MLS] Joined MLS group {group_key}");

                        // Conference Welcome = we were ADMITTED (waiting room
                        // opened). Dart leaves the lobby and joins the call.
                        if let Some(conf_id) = super::conference::conf_id_from_sid(&server_id) {
                            super::conference::clear_pending_knock(conf_id);
                            let _ = event_tx.send(NetworkEvent::ConferenceAdmitted {
                                conf_id: conf_id.to_string(),
                            }).await;
                        }

                        // Emit the SFrame key for this group — if we joined a
                        // restricted VOICE channel's subgroup (e.g. via VC-join
                        // bootstrap), this delivers the key to its voice cryptor.
                        // For the server group / text-only subgroups Dart just
                        // caches it (no active cryptor for that channel).
                        if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                            let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                server_id: server_id.clone(), epoch, sframe_key,
                                channel_id: wl_channel_id.clone(),
                            }).await;
                        }

                        // After SERVER-GROUP recovery, also catch up on CRDT OPS we
                        // missed while at a stale epoch (new channels, visibility, role
                        // changes). An op broadcast via MLS at an epoch we couldn't
                        // decrypt was dropped with no plaintext fallback — without this
                        // SyncRequest a channel created during our skew is lost forever
                        // (we never learn it exists, so per-channel sync can't recover
                        // it). The responder serves the op-log delta via SyncResponse.
                        if wl_channel_id.is_none() {
                            if let Some(state) = server_states.get(&server_id) {
                                let our_vector = StateVector::from_server_state(state);
                                if let Ok(sv) = serde_json::to_string(&our_vector) {
                                    send_message_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        &peer_str, HavenMessage::SyncRequest {
                                            server_id: server_id.clone(),
                                            state_vector_json: sv,
                                            // Freshly Welcomed — current by construction.
                                            mls_epoch: mls_mgr.epoch(&server_id).ok(),
                                        },
                                    );
                                }
                            }
                        }

                        // After MLS recovery, sync channels — server group: ALL channels
                        // (not just empty ones; the DB has gaps from the stale epoch).
                        // Subgroup: just the one restricted channel it serves.
                        if let Some(state) = server_states.get(&server_id) {
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                let sync_cids: Vec<String> = match &wl_channel_id {
                                    Some(cid) => vec![cid.clone()],
                                    None => state.channels.keys().cloned().collect(),
                                };
                                for cid in &sync_cids {
                                    let sender_ts = store.get_per_sender_timestamps(&server_id, cid)
                                        .unwrap_or_default();
                                    let our_latest = store.get_latest_channel_timestamp(&server_id, cid)
                                        .unwrap_or(None).unwrap_or(0);
                                    send_message_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        &peer_str, HavenMessage::ChannelSyncRequest {
                                            server_id: server_id.clone(),
                                            channel_id: cid.clone(),
                                            since_timestamp: our_latest,
                                            sender_timestamps: sender_ts,
                                        },
                                    );
                                }
                            }
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Failed to join from Welcome for {group_key}: {e}");
                        // Clear bootstrap flag so next MlsChannelMessage can trigger retry.
                        mls_bootstrap_requested.remove(&group_key);
                    }
                }
            }
        }

        HavenMessage::MlsCommit { server_id, commit, channel_id: cm_channel_id, epoch: cm_epoch } => {
            hollow_log!("[HOLLOW-MLS] MlsCommit from {peer_str} for {server_id} (cid={cm_channel_id:?})");
            if let Some(mls_mgr) = mls {
                let _ = crate::node::crypto_handler::handle_mls_commit_frame(
                    mls_mgr, crypto_store, server_states, ws_cmd_tx, ws_room_peers,
                    mls_bootstrap_requested, event_tx, local_peer_str,
                    &server_id, &commit, &cm_channel_id, cm_epoch,
                ).await;
            }
        }

        HavenMessage::MlsEpochProbe { server_id, channel_id: pr_channel_id, epoch } => {
            // A peer asks whether its group is behind (join-order SFrame race
            // fix). Membership gate + authority election + cooldowns live in
            // the handler; a spoofed hint can never drop a group.
            hollow_log!("[HOLLOW-MLS] MlsEpochProbe from {peer_str} for {server_id} (cid={pr_channel_id:?}, their epoch {epoch})");
            if let Some(mls_mgr) = mls {
                crate::node::crypto_handler::handle_epoch_hint(
                    mls_mgr, ws_cmd_tx, ws_room_peers, server_states,
                    pending_mls_removals, mls_epoch_hint_cooldown,
                    &server_id, pr_channel_id.as_deref(), epoch,
                    peer_str, local_peer_str,
                    true, // addressed to us — answer it, do not re-elect
                );
            }
        }

        HavenMessage::MlsCommitCatchup { server_id, channel_id: cu_channel_id, commits } => {
            // Replay of commit frames we missed (unbuffered 0x03 broadcast).
            // Every frame goes through the SAME validated apply path as a live
            // MlsCommit; additionally each must be exactly one epoch ahead of
            // us — we never attempt a gapped commit, so a bad catch-up can't
            // even reach the drop-group recovery (strictly safer than the
            // broadcast path it supplements).
            let is_member = server_states.get(&server_id).is_some_and(|s| {
                s.members.keys().any(|m| super::resolver::same_identity(m, peer_str))
            });
            if !is_member {
                hollow_log!("[HOLLOW-MLS] Ignoring MlsCommitCatchup from non-member {peer_str} for {server_id}");
                return;
            }
            let group_key = match &cu_channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            if let Some(mls_mgr) = mls {
                if !mls_mgr.has_group(&group_key) {
                    hollow_log!("[HOLLOW-MLS] Ignoring MlsCommitCatchup for group we don't hold: {group_key}");
                    return;
                }
                let mut entries = commits;
                entries.sort_by_key(|(e, _)| *e);
                entries.truncate(16); // flood guard
                hollow_log!("[HOLLOW-MLS] Commit catch-up from {peer_str} for {group_key}: {} frame(s)", entries.len());
                for (entry_epoch, commit_b64) in entries {
                    let Ok(own) = mls_mgr.epoch(&group_key) else { break };
                    if entry_epoch <= own {
                        continue; // already there
                    }
                    if entry_epoch != own + 1 {
                        hollow_log!("[HOLLOW-MLS] Catch-up gap for {group_key}: at {own}, next frame is {entry_epoch} — stopping");
                        break;
                    }
                    match crate::node::crypto_handler::handle_mls_commit_frame(
                        mls_mgr, crypto_store, server_states, ws_cmd_tx, ws_room_peers,
                        mls_bootstrap_requested, event_tx, local_peer_str,
                        &server_id, &commit_b64, &cu_channel_id, Some(entry_epoch),
                    ).await {
                        crate::node::crypto_handler::CommitApplyOutcome::Applied
                        | crate::node::crypto_handler::CommitApplyOutcome::Skipped => continue,
                        crate::node::crypto_handler::CommitApplyOutcome::NoGroup
                        | crate::node::crypto_handler::CommitApplyOutcome::Failed => break,
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackageRequest { server_id, channel_id: kpr_channel_id } => {
            let group_key = match &kpr_channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            hollow_log!("[HOLLOW-MLS] MlsKeyPackageRequest from {peer_str} for {group_key}");


            // Respond with our KeyPackage if we have an MLS identity.
            //
            // HOLDING the group is NOT a reason to refuse. The requester is the
            // authority on whether our leaf needs replacing and it only asks on a
            // real signal: the PeerJoined coordinator asks when we hold no leaf,
            // and `handle_epoch_hint`'s repair arm asks when our epoch is stale and
            // the commit cache cannot bridge it — it has already queued the removal
            // of our old leaf. Refusing there deadlocked the repair (we think the
            // group is fine, they have just evicted us) and left the peer waiting
            // for the decrypt-fail ladder. Re-adding an existing leaf is safe: the
            // batch processor's "sender already a leaf" branch drops the stale one
            // sharing our credential and adds the new one in the SAME commit, so
            // it is one epoch advance and no fork.
            if let Some(mls_mgr) = mls {
                if mls_mgr.has_group(&group_key) {
                    hollow_log!("[HOLLOW-MLS] KeyPackageRequest for {group_key} while we hold it — answering anyway (leaf repair)");
                }
                match mls_mgr.generate_key_package() {
                    Ok(kp_bytes) => {
                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::MlsKeyPackage {
                                server_id,
                                key_package: kp_b64,
                                channel_id: kpr_channel_id,
                            },
                        );
                    }
                    Err(e) => hollow_log!("[HOLLOW-MLS] Failed to generate KeyPackage: {e}"),
                }
            }
        }

        // -- Profile sync (Phase 3.5) --

        HavenMessage::FriendRequest { requested_at } => {

            // A friend request whose sender resolves to our own identity is one of
            // our own devices (multi-device: same master identity). Never render it
            // as a stranger's request ("your own friend friend-requested you").
            if super::resolver::same_identity(peer_str, master_peer_str) {
                hollow_log!("[HOLLOW-FRIENDS] Ignored self friend request (own device)");
                return;
            }

            // BLOCK GUARD: a blocked identity's friend request is dropped
            // outright — no pending row, no room join, no event/notification.
            // This is the anti-spam surface blocking exists for.
            if super::blocklist::is_blocked(peer_str) {
                return;
            }

            hollow_log!("[HOLLOW-FRIENDS] Friend request from {peer_str}");

            let req_master_early = super::resolver::resolve(&peer_str);

            // MUTUAL request → auto-converge to friends. If our OWN outgoing request
            // to this person is still live (a queued outbound request in
            // `pending_friend_requests`, or a persisted "pending outgoing" row),
            // both sides requested each other. Saving "pending incoming" here and
            // showing a Reject affordance is the reject/accept race: rejecting drops
            // our row but our queued outbound request later drains and re-friends us
            // anyway. Instead, treat the inbound request as an implicit accept and
            // converge deterministically. FriendAccept is idempotent, so both sides
            // running this branch still converge.
            let is_mutual = {
                let queued = pending_friend_requests.contains_key(&req_master_early)
                    || pending_friend_requests.contains_key(peer_str);
                let persisted = crate::storage::MessageStore::open(db_path, db_passphrase)
                    .ok()
                    .and_then(|s| {
                        s.get_friend_status_direction(&req_master_early)
                            .ok()
                            .flatten()
                    })
                    .map(|(status, dir)| status == "pending" && dir == "outgoing")
                    .unwrap_or(false);
                queued || persisted
            };

            if is_mutual {
                hollow_log!(
                    "[HOLLOW-FRIENDS] Mutual friend request with {peer_str} (master {req_master_early}) — auto-accepting"
                );
                // Disarm our queued outbound request/removal for this person; we are
                // converging to friends, so those queued ops must not re-fire.
                pending_friend_requests.remove(&req_master_early);
                pending_friend_requests.remove(peer_str);
                pending_friend_removals.remove(&req_master_early);
                pending_friend_removals.remove(peer_str);
                social::handle_accept_friend_request(
                    event_tx, ws_cmd_tx, ws_room_peers,
                    local_peer_str, master_keypair, device_peer_id, is_invisible,
                    peer_str.to_string(),
                    pending_friend_accepts,
                    pending_friend_removals,
                    db_path, db_passphrase,
                ).await;
                return;
            }

            // Save as pending incoming, keyed by the sender's MASTER (friendships key
            // on the master). Cold resolver → resolves to the device id itself, which
            // the device-list ingest re-key later migrates to the master. Also migrate
            // any row already stranded under the device id.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let master = super::resolver::resolve(&peer_str);
                    if master != peer_str {
                        let _ = store.migrate_friend_to_master(&peer_str, &master);
                    }
                    let _ = store.save_friend(&master, "pending", "incoming", requested_at);
                }
            }

            // Register DM room code so we can rediscover this peer, AND JOIN the DM
            // relay room now. The requester is already in this DM room (it joined at
            // send time) and — post anti-mis-link fix — LEAVES our inbox after
            // delivery, so the DM room is the shared rendezvous over which our eventual
            // FriendAccept routes back. Without joining here, the accept could find no
            // shared room (we used to rely on the requester lingering in our inbox).
            // `dm_room_code` is pure (f(masters)) — pass the requester's MASTER (not the
            // raw sender device) so we land in the SAME room the requester joined
            // (`dm_room_code(my_master, their_master)`). Using the device id put us in a
            // DIFFERENT room (`dm_room_code(my_master, their_device)`) where the requester
            // never was → our FriendAccept had no shared room and was lost (the exact bug
            // where the requester never learned we accepted).
            let local_peer = local_peer_str.to_string();
            let req_master = super::resolver::resolve(&peer_str);
            let room = dm_room_code(&local_peer, &req_master);
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                room_code: room,
            });

            // CRITICAL: push OUR profile + DEVICE LIST to the requester NOW, while it is
            // still reachable (it just sent us this request, so it shares a room with
            // us — the inbox and/or the DM room). This is the ONLY reliable moment to
            // teach the requester `our-device → our-master`: our normal device-list send
            // is gated behind the `is_new` PeerJoined path, which the requester defeats
            // by leaving our inbox right after delivery and then being pinned in
            // `synced_peers` via the shared DM room — so it never fires again. Without
            // this, the requester never ingests our device list, never collapses our
            // device→master, and our friendship stays split (their incoming row keyed by
            // our device id, never re-keyed). Send to the SENDER device directly.
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers,
                local_peer_str, master_keypair, device_peer_id, &peer_str,
                is_invisible,
                db_path, db_passphrase,
            );

            let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendAccept => {
            
            hollow_log!("[HOLLOW-FRIENDS] Friend accepted by {peer_str}");

            // Update our outgoing request to accepted, keyed by the friend's MASTER.
            // The accepter's `peer_str` may be a device id (multi-device / nickname);
            // resolve so the accepted row matches presence/DM/profile, and migrate any
            // pending row stranded under the device id.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let master = super::resolver::resolve(&peer_str);
                    if master != peer_str {
                        let _ = store.migrate_friend_to_master(&peer_str, &master);
                    }
                    let _ = store.save_friend(&master, "accepted", "", now);
                }
            }

            // Register DM room code with signaling. Use the MASTER so both sides compute
            // the SAME pure dm_room_code.
            let local_peer = local_peer_str.to_string();
            let friend_master = super::resolver::resolve(&peer_str);
            let room = dm_room_code(&local_peer, &friend_master);

            // Push our profile + device list to the accepter while it's reachable, so it
            // learns our device→master mapping over the durable DM room (same reason as
            // the FriendRequest handler — the is_new gate otherwise suppresses it).
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers,
                local_peer_str, master_keypair, device_peer_id, &peer_str,
                is_invisible,
                db_path, db_passphrase,
            );

            let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendReject => {
            // The sender is a DEVICE id but our outgoing request row is keyed by
            // their MASTER — delete the master row (a raw device-id delete would
            // silently no-op, leaving a ghost outgoing request). Delete both keys
            // to also clean any legacy device-stranded row.
            let master = super::resolver::resolve(&peer_str);
            hollow_log!("[HOLLOW-FRIENDS] Friend rejected by {peer_str} (master {master})");

            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.remove_friend(&master);
                    if master != peer_str {
                        let _ = store.remove_friend(&peer_str);
                    }
                }
            }

            let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
                peer_id: master,
            }).await;
        }

        HavenMessage::FriendRemove => {
            // The remover sends from a DEVICE id, but the friendship is keyed by
            // their MASTER on our side — resolve so the DELETE hits the right row
            // (a raw device-id delete misses a master-keyed friend → asymmetric
            // removal where they removed us but we still list them). Delete both
            // keys for any legacy device-stranded row.
            let master = super::resolver::resolve(&peer_str);
            hollow_log!("[HOLLOW-FRIENDS] Friend removed by {peer_str} (master {master})");

            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.remove_friend(&master);
                    if master != peer_str {
                        let _ = store.remove_friend(&peer_str);
                    }
                }
            }

            // CRITICAL — clear our OWN queued accept/request for this person. We may
            // hold a `pending_friend_accepts[master]` entry (we accepted them earlier,
            // AND it is re-seeded from accepted-friends at every startup). If it
            // survives this removal, then when they RE-ADD us and their device
            // reappears, the pending-accepts drain AUTO-SENDS a FriendAccept WITHOUT
            // ever surfacing their new request — they re-friend us off that stale
            // accept while WE show nothing and never consented (the asymmetric
            // re-add-auto-accept bug). The send-side `handle_remove_friend` already
            // does this; the RECEIVE side must too. Clear both master and device keys.
            pending_friend_accepts.remove(&master);
            pending_friend_requests.remove(&master);
            if master != peer_str {
                pending_friend_accepts.remove(peer_str);
                pending_friend_requests.remove(peer_str);
            }

            // NOTE: do NOT LeaveRoom here either — symmetric with the send side. The
            // lingering ex-friend presence is handled as a UI-count concern (the Network
            // column counts only peers resolving to an accepted friend), not by leaving
            // rooms (which raced removal delivery and dropped the message).

            let _ = event_tx.send(NetworkEvent::FriendRemoved {
                peer_id: master,
            }).await;
        }

        HavenMessage::FriendListSync { friends } => {
            // Multi-device (Phase 6): accept a friend-list backfill ONLY from our
            // own other device (verified-self). A non-self sender trying this is
            // an attempt to inject friends — drop it.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Dropped FriendListSync from non-self peer {peer_str}"
                );
                return;
            }
            hollow_log!(
                "[HOLLOW-MULTIDEV] Sibling device {peer_str} shared {} friends",
                friends.len()
            );

            let mut inserted: u32 = 0;
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                // Existing friends (any status) so we don't clobber a relationship
                // we already track or re-add a removed one within the same session.
                let existing: std::collections::HashSet<String> = store
                    .load_friends(None)
                    .map(|rows| rows.into_iter().map(|(pid, ..)| pid).collect())
                    .unwrap_or_default();

                for entry in &friends {
                    // Never add ourselves (any of our own devices) as a friend.
                    if super::resolver::same_identity(&entry.peer_id, local_peer_str) {
                        continue;
                    }
                    // Key the friend by their MASTER (the invariant). A sibling on a
                    // current build already sends masters, but resolve defensively so
                    // a device-keyed entry from an older sibling still lands canonical
                    // and dedups against our existing master row.
                    let fmaster = super::resolver::resolve(&entry.peer_id);
                    if existing.contains(&fmaster) || existing.contains(&entry.peer_id) {
                        continue;
                    }
                    // v1 shares only accepted friends; persist as accepted.
                    if store
                        .save_friend(&fmaster, "accepted", "", entry.requested_at)
                        .is_ok()
                    {
                        inserted += 1;
                    }
                    // Join the friend's DM room so presence flows both ways and
                    // future live messages arrive (history backfill is Step 4/5).
                    // Use the friend's MASTER so both sides compute the same pure
                    // dm_room_code (a device-keyed room would diverge per-side).
                    let room = dm_room_code(local_peer_str, &fmaster);
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                        room_code: room.clone(),
                    });
                    // CRITICAL (presence collapse): announce ourselves to this
                    // freshly-learned friend with our profile + MERGED device list.
                    // Without this, a substitute device (e.g. a VM that imported the
                    // mnemonic) joins the friend's DM room but the friend never
                    // receives a ProfileUpdate carrying our device id — so the
                    // friend's resolver never maps our-device → master and shows the
                    // identity OFFLINE when the original device quits.
                    //
                    // We just issued JoinRoom, so we are NOT in `ws_room_peers[room]`
                    // yet — `send_own_profile_to_peer`'s room-lookup would drop the
                    // send. Target the KNOWN DM room directly: on the same WS
                    // connection JoinRoom is processed before this SendDirect (ordered
                    // TCP), so by the time the relay routes it we are in the room.
                    //
                    // CRITICAL: a freshly-imported substitute device has NO local
                    // profile row yet (no display name set), so we must NOT gate the
                    // device-list send on `load_profile` being Some — that was the
                    // exact bug where AL never learned the VM→master mapping. Build
                    // the ProfileUpdate from whatever profile exists (or empty
                    // defaults) and ALWAYS attach the device list.
                    {
                        let profile = crate::storage::MessageStore::open(db_path, db_passphrase)
                            .ok()
                            .and_then(|s| s.load_profile(local_peer_str).ok().flatten());
                        // LIGHT announce (device list is the payload here) — blobs
                        // ride as hashes; a stale friend pulls via ProfileRequest.
                        // Our proof rides along - receivers REQUIRE it to store
                        // the profile, and forward it when relaying us onward.
                        // Signed fresh if the row predates 0.8.5.
                        let (profile_sig, profile_pk, signed_avatar_hash) =
                            social::own_profile_proof(master_keypair, local_peer_str, profile.as_ref());
                        let (display_name, status, about_me, updated_at, avatar_hash, banner_hash, twitch_username, showcase_board, showcase_assets_hash, avatar_frame, avatar_anim, banner_anim) =
                            match profile {
                                Some(p) => (
                                    p.display_name, p.status, p.about_me, p.updated_at,
                                    signed_avatar_hash,
                                    social::profile_blob_hash(p.banner_bytes.as_deref()),
                                    p.twitch_username, p.showcase_board,
                                    social::profile_blob_hash(p.showcase_assets.as_deref()),
                                    p.avatar_frame, p.avatar_anim, p.banner_anim,
                                ),
                                None => (String::new(), String::new(), String::new(), 0, String::new(), String::new(), String::new(), String::new(), String::new(), String::new(), String::new(), String::new()),
                            };
                        let device_list = super::crypto_handler::build_local_device_list(
                            master_keypair, device_peer_id, db_path, db_passphrase,
                        );
                        let dev_count = device_list.as_ref().map(|d| d.devices.len()).unwrap_or(0);
                        let msg = HavenMessage::ProfileUpdate {
                            display_name, status, about_me, updated_at,
                            avatar_b64: String::new(), banner_b64: String::new(),
                            is_invisible, twitch_username,
                            device_list,
                            avatar_hash, banner_hash,
                            showcase_board: Some(showcase_board),
                            showcase_assets_b64: String::new(),
                            showcase_assets_hash,
                            avatar_frame: Some(avatar_frame),
                            avatar_anim: Some(avatar_anim),
                            banner_anim: Some(banner_anim),
                            profile_sig, profile_pk,
                        };
                        let json = serde_json::to_string(&msg).unwrap_or_default();
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                            room_code: room,
                            target_peer: entry.peer_id.clone(),
                            data: json.into_bytes(),
                        });
                        hollow_log!(
                            "[HOLLOW-DEVICES] Announced self ({dev_count}-device list) to backfilled friend {}",
                            entry.peer_id
                        );
                    }
                }
            }

            if inserted > 0 {
                hollow_log!("[HOLLOW-MULTIDEV] Backfilled {inserted} friends from sibling device");
                let _ = event_tx.send(NetworkEvent::FriendsBackfilled { count: inserted }).await;
            }
        }

        HavenMessage::FriendListRequest => {
            // Multi-device (Phase 6): a sibling asked for our friend list. Reply
            // ONLY to our own other device (verified-self). Pull companion to the
            // push in ingest_sibling_device_list — fixes the join-timing race.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Dropped FriendListRequest from non-self peer {peer_str}"
                );
                return;
            }
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                if let Ok(friends) = store.load_friends(Some("accepted")) {
                    if !friends.is_empty() {
                        let entries: Vec<FriendListEntry> = friends
                            .into_iter()
                            .map(|(pid, status, direction, requested_at, _u)| FriendListEntry {
                                peer_id: pid, status, direction, requested_at,
                            })
                            .collect();
                        hollow_log!(
                            "[HOLLOW-MULTIDEV] Replying to FriendListRequest from {peer_str} with {} friends",
                            entries.len()
                        );
                        crate::node::crypto_handler::send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::FriendListSync { friends: entries },
                        );
                    }
                }
            }
        }

        HavenMessage::SiblingStateSyncRequest => {
            // Multi-device MANUAL state sync: our OWN other device (the user tapped
            // "Sync from this device" on it, choosing US as the source) wants our
            // full server + friend state. SECURITY: verified-self only.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-SYNC] Dropped SiblingStateSyncRequest from non-self peer {peer_str}"
                );
                return;
            }
            // 1) Announce every server we're STILL A MEMBER of to the requester. Each
            //    announce drives the requester's join flow → ServerJoined → its UI
            //    list refresh (the proven path). Idempotent on the requester.
            //    Membership filter mirrors on_verified_sibling: a shell retained
            //    after our own leave must never be re-announced (it would re-join /
            //    re-ADD us to a server we left).
            let mut announced = 0u32;
            for (sid, st) in server_states.iter() {
                if st.is_deleted() || !st.is_member(local_peer_str) { continue; }
                let announce = serde_json::to_vec(
                    &HavenMessage::SiblingServerAnnounce { server_id: sid.clone() },
                ).unwrap_or_default();
                if !announce.is_empty() {
                    super::crypto_handler::send_raw_to_peer(ws_cmd_tx, ws_room_peers, peer_str, announce);
                    announced += 1;
                }
            }
            // 2) Re-share our friend list so the requester converges friends too.
            let mut friends_sent = 0usize;
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                if let Ok(friends) = store.load_friends(Some("accepted")) {
                    if !friends.is_empty() {
                        let entries: Vec<FriendListEntry> = friends
                            .into_iter()
                            .map(|(pid, status, direction, requested_at, _u)| FriendListEntry {
                                peer_id: pid, status, direction, requested_at,
                            })
                            .collect();
                        friends_sent = entries.len();
                        super::crypto_handler::send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::FriendListSync { friends: entries },
                        );
                    }
                }
            }
            hollow_log!(
                "[HOLLOW-SYNC] Manual state-sync from {peer_str}: announced {announced} server(s) + {friends_sent} friend(s)"
            );
        }

        // -- Multi-device link snapshot (Step 4) --
        HavenMessage::LinkSnapshotRequest { include_vault: _, include_files: _, msg_count, friend_count, has_profile } => {
            // An empty device wants our full snapshot. We do NOT require same_identity
            // here: the code-path requester isn't a sibling yet (no shared master). The
            // authorization is the human Confirm on THIS (populated) device — surfaced
            // via SiblingLinkAvailable. The actual push happens on AcceptLinkPush.
            link_handler::handle_inbound_link_request(
                &event_tx, peer_str, msg_count, friend_count, has_profile,
            ).await;
        }

        HavenMessage::LinkSnapshotKey { link_id, aes_key: _, aes_nonce: _ } => {
            // The populated device announced the link_id. The `.hollow` blob that
            // follows is encrypted with the CODE WE typed (no key travels in the
            // message), so register the pending stash keyed by link_id + our code.
            link_handler::handle_inbound_link_key(
                pending_link_snapshots, &link_id, link_handler::my_link_code(),
            );
        }

        HavenMessage::LinkDeclined => {
            hollow_log!("[HOLLOW-LINK] Link request declined by {peer_str}");
            let _ = event_tx.send(NetworkEvent::LinkFailed {
                link_id: String::new(),
                error: "declined by other device".to_string(),
            }).await;
        }

        HavenMessage::LinkSnapshotAck { link_id } => {
            // (Sender side) The empty device confirmed it received + stashed the full
            // snapshot. Only NOW flip the sender UI to "Data sent" — the prior
            // queued-bytes-leaving-our-channel signal was premature.
            hollow_log!("[HOLLOW-LINK] LinkSnapshotAck for {link_id} from {peer_str} — receiver has everything");
            let _ = event_tx.send(NetworkEvent::LinkPushComplete { bytes: 0 }).await;
        }

        HavenMessage::PublicChannelMessage { server_id, channel_id, text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us, file_meta } => {
            if peer_str == local_peer_str { return; }
            // Multi-device: the relay frame author (`peer_str`) is the sender's
            // DEVICE id, but a public channel message is SIGNED by — and must be
            // attributed to — the sender's MASTER (the send side signs with the
            // master id; see message_ops public-channel send). Resolve first so the
            // signature verifies and the row is master-keyed, exactly like the MLS
            // path. Single-device senders resolve to themselves (no-op).
            //
            // `order_us` is the SENDER's Lamport stamp (0.8.3+) — persist it
            // faithfully: the v2 signature binds it, so a local ts*1000 default
            // would store a row whose signature fails when re-served via sync.
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_channel_message(
                &event_tx, &bundle_keypair, server_states.get(&server_id), &local_peer_str,
                sender_master.clone(),
                server_id.clone(), channel_id.clone(), text, ts, sig, pk,
                Some(mid.clone()), reply_to, file_id.clone(), link_preview, order_us,
                &db_path, &db_passphrase,
            ).await;
            // GUEST live file card: we can't decrypt the MLS FileHeader that
            // follows, so the plaintext message carries display metadata.
            // Members ignore it (server state present = MLS header is their
            // source); the v2 signature binds `file_id`, not this blob, so
            // require the blob to describe exactly the signed file_id.
            if server_states.get(&server_id).is_none() && guest_rooms.contains(&server_id) {
                if let Some(fm) = file_meta
                    .filter(|fm| file_id.as_deref() == Some(fm.fid.as_str()))
                {
                    let thumb_b64 =
                        file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime);
                    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                        file_id: fm.fid,
                        file_name: fm.name,
                        size_bytes: fm.size,
                        is_image: fm.img,
                        width: fm.w,
                        height: fm.h,
                        message_id: mid,
                        sender_id: sender_master,
                        server_id,
                        channel_id,
                        video_thumb: None,
                        share_ref: None,
                        thumb_b64,
                    }).await;
                }
            }
        }

        HavenMessage::PublicChannelEdit { server_id, channel_id, mid, text, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_edit_message(
                &event_tx, &bundle_keypair, server_states.get(&server_id), &sender_master,
                mid, text, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicLinkPreviewSet { server_id, channel_id, mid, lp, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_link_preview_set(
                &event_tx, server_states.get(&server_id), &sender_master, local_peer_str,
                mid, lp, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelDelete { server_id, channel_id, mid, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_delete_message(
                &event_tx, &bundle_keypair, &sender_master,
                mid, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelAddReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_add_reaction(
                &event_tx, &bundle_keypair, server_states.get(&server_id), &sender_master,
                mid, emoji, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelRemoveReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_remove_reaction(
                &event_tx, &bundle_keypair, &sender_master,
                mid, emoji, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        // -- Guest sync handlers (Public Channels Phase 3) --

        HavenMessage::PublicChannelListRequest { server_id } => {
            if peer_str == local_peer_str { return; }
            if let Some(state) = server_states.get(&server_id) {
                let channels: Vec<PublicChannelEntry> = state.channels.values()
                    .filter(|ch| ch.effective_public())
                    .map(|ch| PublicChannelEntry {
                        channel_id: ch.channel_id.clone(),
                        name: ch.name.clone(),
                        category: ch.category.clone(),
                    })
                    .collect();
                if !channels.is_empty() {
                    let avatar_b64 = state.settings.get("server_avatar")
                        .map(|reg| reg.read().clone())
                        .unwrap_or_default();
                    // THUMBNAIL only — this answers strangers pre-join, so the
                    // full banner blob never rides this path.
                    let banner_thumb_b64 = super::assets::public_banner_thumb(state, db_path, db_passphrase)
                        .map(|t| base64::engine::general_purpose::STANDARD.encode(t))
                        .unwrap_or_default();
                    let resp = HavenMessage::PublicChannelListResponse {
                        server_id: server_id.clone(),
                        server_name: state.name().to_string(),
                        channels,
                        server_avatar_b64: avatar_b64,
                        server_banner_thumb_b64: banner_thumb_b64,
                    };
                    // Send directly using server_id as room — guests may not be in ws_room_peers
                    if let Ok(data) = serde_json::to_vec(&resp) {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                            room_code: server_id.clone(),
                            target_peer: peer_str.to_string(),
                            data,
                        });
                    }
                }
            }
        }

        HavenMessage::PublicChannelSyncRequest { server_id, channel_id, before_timestamp } => {
            if peer_str == local_peer_str { return; }
            if let Some(state) = server_states.get(&server_id) {
                if !state.is_channel_public(&channel_id) { return; }

                let dedup_key = format!("pub_sync:{server_id}:{channel_id}:resp:{peer_str}");
                if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(2)) {
                    return;
                }
                channel_sync_sent.insert(dedup_key, std::time::Instant::now());

                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let limit = 50i32;
                    let messages_result = if let Some(before_ts) = before_timestamp {
                        store.get_channel_messages_before(&server_id, &channel_id, before_ts, limit)
                    } else {
                        // Initial request: get the latest messages (not oldest).
                        store.get_channel_messages_before(&server_id, &channel_id, i64::MAX, limit)
                    };
                    if let Ok(msgs) = messages_result {
                        let msg_ids: Vec<String> = msgs.iter().filter_map(|m| m.message_id.clone()).collect();
                        let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
                        let file_ids: Vec<&str> = msgs.iter().filter_map(|m| m.file_id.as_deref()).collect();
                        let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

                        let mut budget = super::sync_handler::PreviewBudget::new();
                        let mut items: Vec<SyncMessageItem> = Vec::with_capacity(msgs.len());
                        let mut truncated = false;

                        for m in msgs.iter() {
                            // Same rule as the member responders: cut the page
                            // rather than serve a message stripped of the card
                            // its signature covers. This page walks BACKWARDS
                            // (newest first, `before_timestamp`), so the tail we
                            // drop is the oldest — exactly what the requester
                            // asks for next.
                            if let Some(lp) = &m.link_preview {
                                if !budget.fits(lp, items.len()) {
                                    hollow_log!(
                                        "[HOLLOW-SYNC] Preview budget spent after {} guest item(s) — cutting the page short (has_more)",
                                        items.len()
                                    );
                                    truncated = true;
                                    break;
                                }
                            }
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
                                    sender: m.sender_id.clone(),
                                    vthumb: f.video_thumb.clone(),
                                    thumb: f.thumb_b64.clone(),
                                })
                            });
                            // Deletion proof rides with the hidden flag — guests
                            // verify it item-locally (REJECT-ABSENT, 0.8.4).
                            let (hidden_at, hidden_sig, hidden_pk) = message_ops::deletion_proof_fields(
                                &store, m.hidden_at, m.message_id.as_deref(),
                            );
                            items.push(SyncMessageItem {
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
                                lp_digest: m.link_preview.as_ref().map(crypto_handler::link_preview_digest),
                                lp: m.link_preview.clone().map(Box::new),
                                reactions,
                            });
                        }
                        let has_more = truncated || msgs.len() as i32 >= limit;

                        // Build sender profiles (one per unique sender)
                        // Priority: server nickname > profile display name > nothing
                        // Avatar: from local user_profiles DB (whatever we've cached from ProfileUpdated events)
                        let unique_senders: std::collections::HashSet<&str> = items.iter().map(|m| m.s.as_str()).collect();
                        let mut sender_profiles = std::collections::HashMap::new();
                        for sender in &unique_senders {
                            let mut profile = SyncSenderProfile { name: None, avatar_b64: None };
                            let nickname = state.get_nickname(sender);
                            if !nickname.is_empty() {
                                profile.name = Some(nickname);
                            } else if let Ok(Some(stored)) = store.load_profile_light(sender) {
                                if !stored.display_name.is_empty() {
                                    profile.name = Some(stored.display_name);
                                }
                            }
                            if let Ok(Some(avatar_bytes)) = store.load_avatar(sender) {
                                if let Ok(thumb) = crate::node::image_convert::process_sync_avatar(&avatar_bytes) {
                                    profile.avatar_b64 = Some(base64::engine::general_purpose::STANDARD.encode(&thumb));
                                }
                            }
                            sender_profiles.insert(sender.to_string(), profile);
                        }

                        let resp = HavenMessage::PublicChannelSyncResponse {
                            server_id: server_id.clone(),
                            channel_id: channel_id.clone(),
                            messages: items,
                            has_more,
                            sender_profiles,
                        };
                        // Send directly using server_id as room — guests may not be in ws_room_peers
                        if let Ok(data) = serde_json::to_vec(&resp) {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                                room_code: server_id.clone(),
                                target_peer: peer_str.to_string(),
                                data,
                            });
                        }
                    }
                }
            }
        }

        HavenMessage::PublicChannelListResponse { server_id, server_name, channels, server_avatar_b64, server_banner_thumb_b64 } => {
            if peer_str == local_peer_str { return; }
            if !guest_rooms.contains(&server_id) { return; }
            let entries: Vec<PublicChannelEntryFfi> = channels.into_iter()
                .map(|c| PublicChannelEntryFfi {
                    channel_id: c.channel_id,
                    name: c.name,
                    category: c.category,
                })
                .collect();
            let server_avatar = if server_avatar_b64.is_empty() {
                None
            } else {
                base64::engine::general_purpose::STANDARD.decode(&server_avatar_b64).ok()
            };
            // Cap what a stranger's response can hand us: a thumb is ≤40 KB
            // at authoring, so anything much bigger is hostile padding.
            let server_banner_thumb = if server_banner_thumb_b64.is_empty() || server_banner_thumb_b64.len() > 80_000 {
                None
            } else {
                base64::engine::general_purpose::STANDARD.decode(&server_banner_thumb_b64).ok()
            };
            let _ = event_tx.send(NetworkEvent::PublicChannelListReceived {
                server_id, server_name, channels: entries, server_avatar, server_banner_thumb,
            }).await;
        }

        HavenMessage::PublicChannelSyncResponse { server_id, channel_id, messages, has_more, sender_profiles } => {
            if peer_str == local_peer_str { return; }
            if !guest_rooms.contains(&server_id) { return; }
            // Guests hold no rows to check against, so EVERYTHING is verified
            // from the items' own fields — public-channel sync is plaintext, so
            // the relay (or any responder) can rewrite the whole batch:
            //   * content signature  -> drop the item        (0.8.5)
            //   * hidden flag proof  -> strip the flag       (0.8.4, REJECT-ABSENT)
            //   * reaction signature -> drop that reaction   (0.8.5)
            // This is the one surface strangers see, so it gets the same rule
            // the four member-side backfill sites use.
            let mut pk_cache = PkCache::new();
            let mut ffi_messages: Vec<GuestSyncMessageFfi> = Vec::with_capacity(messages.len());
            for m in messages {
                if !message_ops::guest_item_accepted(&m, &server_id, &channel_id, &mut pk_cache) {
                    continue;
                }
                let hidden_at = message_ops::verified_guest_hidden_at(
                    &m, &server_id, &channel_id, &mut pk_cache,
                );
                let reactions = match &m.mid {
                    Some(mid) => m.reactions.iter()
                        .filter(|r| message_ops::sync_reaction_accepted(mid, r))
                        .map(|r| GuestReactionFfi {
                            emoji: r.e.clone(), peer_id: r.p.clone(), added_at: r.ts,
                        })
                        .collect(),
                    // No mid = nothing a reaction signature could bind to.
                    None => Vec::new(),
                };
                // Attachment metadata → file card (metadata only, never bytes).
                // The item's v2 signature binds `file_id` but NOT the file_meta
                // blob, so require the blob to describe exactly the signed
                // file_id — a rewriting responder can then only change cosmetic
                // fields (name/size), never attach someone else's file id.
                let file_meta = m.file_meta
                    .filter(|fm| m.file_id.as_deref() == Some(fm.fid.as_str()))
                    .map(|fm| GuestFileMetaFfi {
                        file_id: fm.fid,
                        file_name: fm.name,
                        file_ext: fm.ext,
                        mime_type: fm.mime,
                        size_bytes: fm.size,
                        is_image: fm.img,
                        width: fm.w,
                        height: fm.h,
                        // Wire path: never a disk path (a responder's path is
                        // meaningless here; bytes ride the gated request).
                        disk_path: None,
                    });
                ffi_messages.push(GuestSyncMessageFfi {
                    sender_id: m.s,
                    text: m.t,
                    timestamp: m.ts,
                    message_id: m.mid,
                    signature: m.sig,
                    public_key: m.pk,
                    edited_at: m.edited_at,
                    reply_to: m.reply_to,
                    hidden_at,
                    reactions,
                    file_meta,
                    // Safe to render: `guest_item_accepted` above bound this
                    // exact card into the signature it checked.
                    link_preview: m.lp.map(|b| *b),
                });
            }
            let ffi_profiles: Vec<SyncSenderProfileFfi> = sender_profiles.into_iter().map(|(pid, p)| {
                let avatar = p.avatar_b64.and_then(|b64| base64::engine::general_purpose::STANDARD.decode(&b64).ok());
                SyncSenderProfileFfi { peer_id: pid, name: p.name, avatar }
            }).collect();
            let _ = event_tx.send(NetworkEvent::PublicChannelSyncReceived {
                server_id, channel_id, messages: ffi_messages, has_more, sender_profiles: ffi_profiles,
            }).await;
        }

        HavenMessage::PublicChannelConfigChanged { server_id, channel_id, is_public, channel_name, category } => {
            if peer_str == local_peer_str { return; }
            if !guest_rooms.contains(&server_id) { return; }
            let _ = event_tx.send(NetworkEvent::PublicChannelConfigChanged {
                server_id, channel_id, is_public, channel_name, category,
            }).await;
        }

        HavenMessage::PublicFileHeader {
            file_id, name, ext, mime, size, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce,
        } => {
            // SECURITY receipt cap (mirrors `requested_asset_kinds`): accept
            // ONLY a fresh header answering a request WE made, for the server
            // we made it in, and only while browsing that server as a guest.
            // An unsolicited plaintext header would register a decrypt key and
            // let a stranger stream arbitrary bytes onto our disk.
            let Some((req_sid, req_at)) = pending_public_file_requests.remove(&file_id) else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED unsolicited PublicFileHeader for {file_id} from {peer_str}");
                return;
            };
            if req_sid != sid
                || !guest_rooms.contains(&sid)
                || req_at.elapsed() > std::time::Duration::from_secs(120)
            {
                hollow_log!("[HOLLOW-SECURITY] REJECTED PublicFileHeader for {file_id} from {peer_str} — stale or server mismatch");
                return;
            }
            // Same ingest as an Olm FileHeader: 34 MB default size cap (no
            // server state as a guest), metadata row, pending-stream key
            // registration, FileHeaderReceived for the transfer UI. The
            // sender recorded here is the RESPONDER — that is who streams.
            file_handler::handle_envelope_file_header(
                server_states, pending_file_streams, pending_shard_streams,
                early_file_streams, bundle_keypair, event_tx,
                &sid, peer_str.to_string(),
                file_id, name, ext, mime, size, 0, img, w, h,
                mid, Some(sid.clone()), Some(cid), ts,
                Some(aes_key), Some(aes_nonce),
                None, None,
                None, false,
                requested_file_receipts, declined_file_ids,
                ws_cmd_tx, ws_room_peers,
                db_path, db_passphrase,
            ).await;
        }

        HavenMessage::ChannelNotificationHint { server_id, channel_id, message_id, has_everyone, mentioned_names, is_reply: _, reply_to_sender } => {
            // Reply-to-ME only — the wire's bare `is_reply` fired the
            // mentions-only level on every reply to anyone (#42). Hints from
            // pre-0.9.1 senders carry no author → false (never over-notify).
            let is_reply_to_own = reply_to_sender
                .as_deref()
                .is_some_and(|s| super::resolver::same_identity(s, local_peer_str));
            let _ = event_tx.send(NetworkEvent::ChannelNotificationHint {
                server_id, channel_id, from_peer: peer_str.to_string(),
                message_id, has_everyone, mentioned_names, is_reply_to_own,
            }).await;
        }

        HavenMessage::TypingIndicator { server_id, channel_id } => {
            // Phantom-chat guard (Step 7): ignore typing from a just-revoked-but-still-
            // alive device (same reason we drop its DMs — it would spawn/feed a phantom
            // conversation). Stops once the device self-nukes / disconnects.
            if super::resolver::is_revoked(peer_str) {
                return;
            }
            // Attribute typing to the sender's MASTER identity (server members and
            // DM threads are master-keyed). The raw `peer_str` is a device id, which
            // would never match the master-keyed member/thread → indicator never
            // shows for a multi-device (or keystone-rotated) sender.
            let typist_master = super::resolver::resolve(peer_str);
            hollow_log!(
                "[HOLLOW-TYPING] Received from {peer_str} (server={}, master {typist_master})",
                if server_id.is_empty() { "DM" } else { &server_id }
            );
            let _ = event_tx.send(NetworkEvent::TypingStarted {
                peer_id: typist_master,
                server_id,
                channel_id,
            }).await;
        }

        HavenMessage::StatusUpdate { status } => {
            hollow_log!("[HOLLOW-STATUS] Received status update from {peer_str}: {status}");
            let _ = event_tx.send(NetworkEvent::PeerStatusChanged {
                peer_id: peer_str.to_string(),
                status,
            }).await;
        }

        HavenMessage::AutoDownloadPref { mb } => {
            // Auto-download pre-negotiation (issue #41): remember this DEVICE's
            // advertised threshold so our DM file fan-out can skip streaming
            // bytes it would discard. Clamp to the settings slider's ceiling —
            // a larger value is malformed, not a real preference.
            let mb = mb.min(2048);
            hollow_log!("[HOLLOW-FILE] Peer {peer_str} advertised auto-download pref: {mb} MB");
            peer_auto_dl.insert(peer_str.to_string(), mb);
        }

        HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list, avatar_hash, banner_hash, showcase_board, showcase_assets_b64, showcase_assets_hash, avatar_frame, avatar_anim, banner_anim, profile_sig, profile_pk } => {
            // If the profile carries an invisible flag, emit PeerStatusChanged so the
            // UI treats this peer as offline from the very first event.
            if peer_invisible {
                let _ = event_tx.send(NetworkEvent::PeerStatusChanged {
                    peer_id: peer_str.to_string(),
                    status: "invisible".to_string(),
                }).await;
            }

            // Multi-device: ingest the sender's signed device list (verify +
            // monotonic + persist + resolver update + DeviceListUpdated). A list
            // for our OWN master is a sibling device → merged (union) + friend
            // list shared (see ingest_sibling_device_list).
            let ingest_outcome = super::crypto_handler::ingest_device_list(
                event_tx, master_peer_str, device_peer_id, master_keypair, peer_str,
                ws_cmd_tx, ws_room_peers, device_list, db_path, db_passphrase,
            ).await;
            let our_devices_grew = ingest_outcome.our_devices_grew;
            // Step 7: enforce any device revocations learned from this list — drop
            // Olm sessions + (coordinator) remove the revoked leaf from shared servers.
            enforce_device_revocations(
                &ingest_outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                local_peer_str, ws_room_peers, pending_mls_removals,
            );
            // If a sibling merge added one of OUR device ids, re-announce our
            // profile (now carrying the merged device list) to every peer we share
            // a room with — friends converge on the full device set immediately,
            // while we're still online. Without this, a friend only learns the
            // union when our substitute device joins their DM room (racy), and
            // shows us OFFLINE if our original device quits first.
            if our_devices_grew {
                let peers: Vec<String> = ws_room_peers.values()
                    .flat_map(|p| p.iter().cloned())
                    .collect();
                hollow_log!(
                    "[HOLLOW-DEVICES] Sibling merge grew our device set — re-announcing profile to {} room peer(s)",
                    peers.len()
                );
                for pid in peers {
                    if pid == local_peer_str || pid == device_peer_id { continue; }
                    // Skip our own other devices (siblings) — they already have it.
                    if super::resolver::same_identity(&pid, local_peer_str) { continue; }
                    social::send_own_profile_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        local_peer_str, master_keypair, device_peer_id, &pid,
                        is_invisible,
                        db_path, db_passphrase,
                    );
                }
            }

            // MAPPING-LEARNED friend-request drain. A queued outbound friend
            // request is keyed by the TARGET'S MASTER, but the presence-event
            // drains (PeerJoined/RoomMembers) only match a joining DEVICE to that
            // master via the resolver. A FRESH requester that has never ingested
            // the target's device list resolves the target's device to ITSELF
            // (cold resolver → identity), so those drains no-op — the request sits
            // queued and the target never receives it UNTIL it re-joins a shared
            // room (a restart) AFTER the mapping is finally learned. The moment we
            // learn device→master (this ingest) is exactly when we CAN attribute
            // the target's present device to the queued master — so drain here.
            // `peer_str` (the sender of this profile) is guaranteed co-present (it
            // just reached us), so friend_device_targets resolves a live device.
            {
                let sender_master = super::resolver::resolve(peer_str);
                let queued: Option<i64> = pending_friend_requests
                    .keys()
                    .find(|k| super::resolver::resolve(k) == sender_master || k.as_str() == peer_str)
                    .cloned()
                    .and_then(|k| pending_friend_requests.remove(&k));
                if let Some(requested_at) = queued {
                    hollow_log!(
                        "[HOLLOW-FRIENDS] Learned {peer_str}→master {sender_master} — draining queued friend request"
                    );
                    for t in &social::friend_device_targets(ws_room_peers, peer_str, &sender_master) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            t, HavenMessage::FriendRequest { requested_at },
                        );
                    }
                    // Leave the target's inbox now the request is delivered (the
                    // accept returns via the DM room, not the inbox) — mirrors the
                    // presence-event drains.
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                        room_code: format!("inbox:{sender_master}"),
                    });
                }
            }

            // SECURITY: Truncate profile fields to prevent oversized strings from malicious peers.
            // Slightly above UI limits (32/48/128) as a safety backstop.
            let display_name = if display_name.len() > 64 { display_name[..64].to_string() } else { display_name };
            let status = if status.len() > 96 { status[..96].to_string() } else { status };
            let about_me = if about_me.len() > 256 { about_me[..256].to_string() } else { about_me };
            let twitch_username = if twitch_username.len() > 64 { twitch_username[..64].to_string() } else { twitch_username };

            // Decode avatar/banner from base64.
            // Empty string = no change (None). "CLEAR" = clear (Some(empty)). Otherwise = base64 data.
            use base64::Engine;
            let avatar_bytes: Option<Vec<u8>> = if avatar_b64.is_empty() {
                None
            } else if avatar_b64 == "CLEAR" {
                Some(vec![]) // empty = clear signal for save_profile
            } else {
                match base64::engine::general_purpose::STANDARD.decode(&avatar_b64) {
                    Ok(bytes) if bytes.len() <= 1_000_000 => Some(bytes), // 1MB for GIF support
                    Ok(_) => { hollow_log!("[HOLLOW-SWARM] Rejecting avatar from {peer_str}: too large"); None }
                    Err(e) => { hollow_log!("[HOLLOW-SWARM] Invalid avatar base64 from {peer_str}: {e}"); None }
                }
            };
            let banner_bytes: Option<Vec<u8>> = if banner_b64.is_empty() {
                None
            } else if banner_b64 == "CLEAR" {
                Some(vec![]) // empty = clear signal for save_profile
            } else {
                match base64::engine::general_purpose::STANDARD.decode(&banner_b64) {
                    Ok(bytes) if bytes.len() <= 2_000_000 => Some(bytes), // 2MB for GIF support
                    Ok(_) => { hollow_log!("[HOLLOW-SWARM] Rejecting banner from {peer_str}: too large"); None }
                    Err(e) => { hollow_log!("[HOLLOW-SWARM] Invalid banner base64 from {peer_str}: {e}"); None }
                }
            };

            hollow_log!("[HOLLOW-SWARM] ProfileUpdate from {peer_str}: name={display_name}");

            // Multi-device: persist under the sender's MASTER identity (so any
            // device of one person updates the ONE identity profile), with the
            // empty-profile guard (a profile-less sibling must not blank a good
            // row). Single-device: master == sender, so this is a no-op rename.
            // Showcase asset bundle: same CLEAR/b64 semantics as the blobs.
            let showcase_assets_bytes: Option<Vec<u8>> = if showcase_assets_b64.is_empty() {
                None
            } else if showcase_assets_b64 == "CLEAR" {
                Some(vec![])
            } else {
                base64::engine::general_purpose::STANDARD.decode(&showcase_assets_b64).ok()
                    .filter(|b| b.len() <= 2_000_000)
            };

            // Owner proof (0.8.5) — stored only when it VERIFIES, so an
            // unverified signature can never be laundered into a ProfileRelay
            // by us. Absent is fine here: attribution is transport-attested on
            // this path, the profile just becomes non-relayable.
            let verified_proof = social::verified_profile_proof(
                peer_str, updated_at, &display_name, &status, &about_me,
                &twitch_username, &avatar_hash, profile_sig.as_deref(), profile_pk.as_deref(),
            );
            let proof = verified_proof.as_ref().map(|(sig, pk, ah)| {
                crate::storage::ProfileProof { sig, pk, avatar_hash: ah }
            });
            let (profile_master, saved) = social::save_incoming_profile(
                &peer_str, &display_name, &status, &about_me, updated_at,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
                social::sanitize_incoming_showcase(showcase_board.as_deref()),
                showcase_assets_bytes.as_deref(), proof,
                social::sanitize_incoming_frame(avatar_frame.as_deref()),
                social::sanitize_incoming_anim(avatar_anim.as_deref()),
                social::sanitize_incoming_anim(banner_anim.as_deref()),
                db_path, db_passphrase,
            );

            // Light announce advertising blobs we don't match → pull once.
            social::maybe_request_full_profile(
                ws_cmd_tx, ws_room_peers, peer_str, &profile_master,
                &avatar_b64, &banner_b64, &avatar_hash, &banner_hash,
                &showcase_assets_b64, &showcase_assets_hash,
                device_peer_id, db_path, db_passphrase,
            );

            // Update display_name in server member lists (local-only, not a CRDT
            // op). Members are master-keyed (multi-device); update under the master.
            // `saved` gates this too — see the MLS twin in social.rs.
            for (_, state) in server_states.iter_mut() {
                if saved && !display_name.is_empty() {
                    if let Some(member) = state.members.get_mut(&profile_master) {
                        member.display_name = display_name.clone();
                    }
                }
            }

            // Notify Dart to refresh UI — key on the MASTER so the collapsed
            // identity's avatar/name caches invalidate.
            let _ = event_tx.send(NetworkEvent::ProfileUpdated {
                peer_id: profile_master,
            }).await;
        }

        // File request — respond with file chunks via Olm.
        HavenMessage::FileRequest { file_id, chunks, offset } => {

            use crate::node::file_transfer;
            hollow_log!("[HOLLOW-FILE] FileRequest from {peer_str} for {file_id}");

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                if let Ok(Some(file_meta)) = store.get_file_metadata(&file_id) {
                        // SECURITY: serving used to be UNGATED — any peer that
                        // learned a file_id (guests see them in plaintext public
                        // messages) could pull ANY file we hold, DM attachments
                        // included. Serve only:
                        //   * DM files      -> the conversation counterparty or
                        //                      our own sibling devices
                        //   * channel files -> server members; PUBLIC (text)
                        //                      channels -> anyone (guest browser)
                        // `requester_is_member` also picks the header transport
                        // below: Olm for members/DM parties, plaintext public
                        // header for guests (who may hold no Olm session).
                        if crate::node::blocklist::is_blocked(peer_str) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED FileRequest from {peer_str} — blocked");
                            return;
                        }
                        let requester_master = super::resolver::resolve(peer_str);
                        let (requester_is_member, public_ok) = match file_meta.context_type.as_str() {
                            "dm" => (
                                super::resolver::same_identity(peer_str, local_peer_str)
                                    || super::resolver::same_identity(peer_str, &file_meta.context_id),
                                false,
                            ),
                            "channel" => {
                                let mut parts = file_meta.context_id.splitn(2, ':');
                                match (parts.next(), parts.next()) {
                                    (Some(sid), Some(cid)) => match server_states.get(sid) {
                                        Some(s) => (
                                            s.is_member(&requester_master),
                                            s.is_channel_public(cid),
                                        ),
                                        // We hold the file but no longer hold the
                                        // server state — fail closed.
                                        None => (false, false),
                                    },
                                    _ => (false, false),
                                }
                            }
                            _ => (false, false),
                        };
                        if !requester_is_member && !public_ok {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED FileRequest from {peer_str} for {file_id} — not entitled ({} file)", file_meta.context_type);
                            return;
                        }
                        if let Some(ref disk_path) = file_meta.disk_path {
                            if let Ok(file_data) = std::fs::read(disk_path) {
                                // AES-encrypt and stream the file.
                                if let Ok(enc) = crate::vault::pipeline::aes_encrypt(&file_data) {
                                    // UNIQUE temp file per encryption (suffix = this
                                    // request's random AES nonce). A fixed
                                    // `.stream_send_{file_id}.tmp` was CLOBBERED when the
                                    // receiver re-requested rapidly (the decrypt-fail
                                    // retry / thread-open retry): request B's
                                    // re-encryption (new key) overwrote the temp while
                                    // request A's stream was still reading it, so A
                                    // streamed B's ciphertext under A's header key →
                                    // AES-GCM decrypt failed every time, fixed only by an
                                    // app restart (which serializes a single clean
                                    // request). Per-nonce path lets concurrent requests
                                    // each stream their own matching ciphertext.
                                    let nonce_hex = hex::encode(enc.nonce);
                                    let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}_{nonce_hex}.tmp"));
                                    if let Ok(()) = std::fs::write(&temp_path, &enc.ciphertext) {
                                        // Extract server/channel IDs from context.
                                        let (resp_sid, resp_cid) = if file_meta.context_type == "channel" {
                                            let parts: Vec<&str> = file_meta.context_id.splitn(2, ':').collect();
                                            if parts.len() == 2 {
                                                (Some(parts[0].to_string()), Some(parts[1].to_string()))
                                            } else {
                                                (None, None)
                                            }
                                        } else {
                                            (None, None)
                                        };
                                        if requester_is_member {
                                            // Members / DM parties: Olm-wrapped header (existing path).
                                            let header = MessageEnvelope::FileHeader {
                                                inner: Box::new(FileHeaderPayload {
                                                    fid: file_id.clone(),
                                                    name: file_meta.file_name.clone(),
                                                    ext: file_meta.file_ext.clone(),
                                                    mime: file_meta.mime_type.clone(),
                                                    size: file_meta.size_bytes,
                                                    chunks: 0,
                                                    img: file_meta.is_image,
                                                    w: file_meta.width,
                                                    h: file_meta.height,
                                                    mid: file_meta.message_id.clone(),
                                                    sid: resp_sid,
                                                    cid: resp_cid,
                                                    ts: file_meta.created_at,
                                                    sig: None,
                                                    pk: None,
                                                    aes_key: Some(hex::encode(enc.key)),
                                                    aes_nonce: Some(hex::encode(enc.nonce)),
                                                    target: None,
                                                    vthumb: file_meta.video_thumb.clone(),
                                                    share_ref: None,
                                                    // Bytes re-serve for an EXISTING message row —
                                                    // no sentinel insert happens (no inline_bytes),
                                                    // so no ordering stamp to carry.
                                                    order_us: None,
                                                    inline_bytes: None,
                                                    thumb: file_meta.thumb_b64.clone(),
                                                    // Explicit-pull response — the receiver's
                                                    // receipt bypasses the gate; no voice flag
                                                    // is persisted to rehydrate from.
                                                    voice: false,
                                                }),
                                            };
                                            // Send FileHeader via Olm (targeted) + SendDirect.
                                            let header_json = serde_json::to_string(&header).unwrap_or_default();
                                            send_encrypted_message(
                                                olm, crypto_store,
                                                &peer_str, &header_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                            ).await;
                                        } else {
                                            // Non-member on a PUBLIC channel (guest browser):
                                            // plaintext header — the guest may hold no Olm
                                            // session, and the content is public anyway.
                                            super::crypto_handler::send_message_to_peer(
                                                ws_cmd_tx, ws_room_peers, peer_str,
                                                HavenMessage::PublicFileHeader {
                                                    file_id: file_id.clone(),
                                                    name: file_meta.file_name.clone(),
                                                    ext: file_meta.file_ext.clone(),
                                                    mime: file_meta.mime_type.clone(),
                                                    size: file_meta.size_bytes,
                                                    img: file_meta.is_image,
                                                    w: file_meta.width,
                                                    h: file_meta.height,
                                                    mid: file_meta.message_id.clone(),
                                                    sid: resp_sid.clone().unwrap_or_default(),
                                                    cid: resp_cid.clone().unwrap_or_default(),
                                                    ts: file_meta.created_at,
                                                    aes_key: hex::encode(enc.key),
                                                    aes_nonce: hex::encode(enc.nonce),
                                                },
                                            );
                                        }

                                            if offset > 0 {
                                                // Resumed transfer: skip FileHeader, stream from offset via WS.
                                                if let Some(room) = ws_room_for_peer(ws_room_peers, &peer_str) {
                                                    super::ws_stream_transfer::ws_stream_send(
                                                        ws_cmd_tx, &room, &peer_str,
                                                        &super::ws_stream_transfer::StreamKind::File,
                                                        &file_id, &temp_path, enc.ciphertext.len() as u64,
                                                        offset,
                                                    ).await;
                                                }
                                                hollow_log!("[HOLLOW-FILE] Resumed file {} to {peer_str} from offset {offset}", file_id);
                                            } else {
                                                // Fresh transfer: stream via WebRTC or WS relay.
                                                file_handler::stream_to_peer(
                                                    ws_cmd_tx, ws_room_peers,
                                                    webrtc_peers, pending_webrtc_sends, event_tx,
                                                    &peer_str, &super::ws_stream_transfer::StreamKind::File,
                                                    &file_id, &temp_path, enc.ciphertext.len() as u64,
                                                ).await;
                                                hollow_log!("[HOLLOW-FILE] Streamed file {} to {peer_str}", file_id);
                                            }
                                            // Clean up the re-served ciphertext temp once the WS-relay
                                            // stream is queued. A WebRTC send still in flight owns the
                                            // temp (removed on WebRtcTransferComplete), so only delete
                                            // when none is pending — otherwise this leaked a duplicate
                                            // encrypted copy on every file re-request.
                                            if !pending_webrtc_sends.contains_key(&file_id) {
                                                let _ = std::fs::remove_file(&temp_path);
                                            }
                                    }
                                }
                            }
                        }
                }
            }
        }

        // -- WebRTC signaling (Phase 5A) --
        HavenMessage::RtcOffer { sdp, conn_id } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED RtcOffer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            // BLOCK GUARD: a blocked identity can't open a data channel to us.
            // Guarding the OFFER kills the connection at initiation; the other
            // Rtc/Call signals are inert without one. Siblings exempt.
            if !super::resolver::same_identity(peer_str, master_peer_str)
                && super::blocklist::is_blocked(peer_str)
            {
                return;
            }
            hollow_log!("[HOLLOW-WEBRTC] RtcOffer from {peer_str} conn={conn_id}");
            // sdp is the raw SDP string (not JSON-wrapped).
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "offer".to_string(),
                payload: sdp,
                conn_id,
            }).await;
        }
        HavenMessage::RtcAnswer { sdp, conn_id } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED RtcAnswer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-WEBRTC] RtcAnswer from {peer_str} conn={conn_id}");
            // sdp is the raw SDP string (not JSON-wrapped).
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "answer".to_string(),
                payload: sdp,
                conn_id,
            }).await;
        }
        HavenMessage::RtcIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id } => {
            hollow_log!("[HOLLOW-WEBRTC] RtcIceCandidate from {peer_str} conn={conn_id}");
            let payload = serde_json::json!({
                "candidate": candidate,
                "sdpMid": sdp_mid,
                "sdpMLineIndex": sdp_mline_index,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "ice".to_string(),
                payload,
                conn_id,
            }).await;
        }

        // -- Hollow Share data channel (dedicated, STUN-only — §7A) --
        HavenMessage::RtcShareOffer { sdp, conn_id } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED RtcShareOffer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            // BLOCK GUARD: same as RtcOffer — a blocked identity can't open a
            // data channel to us, Share lane included. Siblings exempt.
            if !super::resolver::same_identity(peer_str, master_peer_str)
                && super::blocklist::is_blocked(peer_str)
            {
                return;
            }
            hollow_log!("[HOLLOW-WEBRTC] RtcShareOffer from {peer_str} conn={conn_id}");
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "share_offer".to_string(),
                payload: sdp,
                conn_id,
            }).await;
        }
        HavenMessage::RtcShareAnswer { sdp, conn_id } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED RtcShareAnswer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-WEBRTC] RtcShareAnswer from {peer_str} conn={conn_id}");
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "share_answer".to_string(),
                payload: sdp,
                conn_id,
            }).await;
        }
        HavenMessage::RtcShareIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id } => {
            hollow_log!("[HOLLOW-WEBRTC] RtcShareIceCandidate from {peer_str} conn={conn_id}");
            let payload = serde_json::json!({
                "candidate": candidate,
                "sdpMid": sdp_mid,
                "sdpMLineIndex": sdp_mline_index,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::WebRtcSignal {
                peer_id: peer_str.to_string(),
                signal_type: "share_ice".to_string(),
                payload,
                conn_id,
            }).await;
        }

        // -- Conferences (node/conference.rs; reports/CONFERENCES_PLAN.md) --
        HavenMessage::ConferenceJoinRequest { conf_id, display_name, avatar_hash, key_package, access_hash } => {
            // Blocklist + access-code gating live inside the handler (host-only).
            super::conference::handle_inbound_join_request(
                conference_host, mls, crypto_store, ws_cmd_tx, event_tx,
                peer_str, local_peer_str,
                conf_id, display_name, avatar_hash, key_package, access_hash,
            ).await;
        }
        HavenMessage::ConferenceJoinDenied { conf_id, reason } => {
            super::conference::clear_pending_knock(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceJoinDenied { conf_id, reason }).await;
        }
        HavenMessage::ConferenceLobbyInfo { conf_id, host_name, host_avatar_hash } => {
            let _ = event_tx.send(NetworkEvent::ConferenceLobbyInfo {
                conf_id, host_peer_id: peer_str.to_string(), host_name, host_avatar_hash,
            }).await;
        }
        HavenMessage::ConferenceChat { conf_id, body } => {
            super::conference::handle_inbound_chat(
                mls, crypto_store, event_tx, peer_str, conf_id, body,
            ).await;
        }
        HavenMessage::ConferenceEnded { conf_id } => {
            // Anyone in the room could send this; Dart validates by_peer_id
            // against the host it learned from LobbyInfo/meeting start.
            super::conference::clear_pending_knock(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceEnded {
                conf_id, by_peer_id: peer_str.to_string(),
            }).await;
        }
        HavenMessage::ConferenceKicked { conf_id } => {
            // The MLS remove already cut us off; this is the courtesy signal.
            // Dart validates by_peer_id against the known host before tearing
            // down (a random member can't fake-kick us out of the UI).
            super::conference::clear_pending_knock(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceKicked {
                conf_id, by_peer_id: peer_str.to_string(),
            }).await;
        }

        // -- Voice call signaling (Phase 5B) --
        HavenMessage::CallInvite { call_id, video, sframe_key } => {
            // BLOCK GUARD: a blocked identity can't ring us. Dropping the
            // invite kills the whole call flow (no ringing UI, no accept path).
            if !super::resolver::same_identity(peer_str, master_peer_str)
                && super::blocklist::is_blocked(peer_str)
            {
                return;
            }
            // SECURITY (Phase 6.25): Don't log sframe_key length/presence.
            hollow_log!("[HOLLOW-CALL] CallInvite from {peer_str} call={call_id} video={video} key_len={}", sframe_key.len());
            let payload = serde_json::json!({
                "call_id": call_id,
                "video": video,
                "sframe_key": sframe_key,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "invite".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallAccept { call_id, sframe_key } => {
            hollow_log!("[HOLLOW-CALL] CallAccept from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "sframe_key": sframe_key,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "accept".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallReject { call_id } => {
            hollow_log!("[HOLLOW-CALL] CallReject from {peer_str} call={call_id}");
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "reject".to_string(),
                payload: call_id,
            }).await;
        }
        HavenMessage::CallEnd { call_id } => {
            hollow_log!("[HOLLOW-CALL] CallEnd from {peer_str} call={call_id}");
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "end".to_string(),
                payload: call_id,
            }).await;
        }
        HavenMessage::CallBusy { call_id } => {
            hollow_log!("[HOLLOW-CALL] CallBusy from {peer_str} call={call_id}");
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "busy".to_string(),
                payload: call_id,
            }).await;
        }
        HavenMessage::CallMediaRestart { call_id } => {
            hollow_log!("[HOLLOW-CALL] CallMediaRestart from {peer_str} call={call_id}");
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "media_restart".to_string(),
                payload: call_id,
            }).await;
        }
        HavenMessage::CallSdpOffer { call_id, sdp } => {
            // SECURITY (Phase 6.25): SDP size limit.
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED CallSdpOffer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-CALL] CallSdpOffer from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "sdp": sdp,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "sdp_offer".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallSdpAnswer { call_id, sdp } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED CallSdpAnswer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-CALL] CallSdpAnswer from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "sdp": sdp,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "sdp_answer".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallIceCandidate { call_id, candidate, sdp_mid, sdp_mline_index } => {
            hollow_log!("[HOLLOW-CALL] CallIceCandidate from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "candidate": candidate,
                "sdpMid": sdp_mid,
                "sdpMLineIndex": sdp_mline_index,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "ice".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallVideoState { call_id, enabled } => {
            hollow_log!("[HOLLOW-CALL] CallVideoState from {peer_str} call={call_id} enabled={enabled}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "enabled": enabled,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "video_state".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallAudioState { call_id, muted, deafened } => {
            hollow_log!("[HOLLOW-CALL] CallAudioState from {peer_str} call={call_id} muted={muted} deafened={deafened}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "muted": muted,
                "deafened": deafened,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "audio_state".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallScreenState { call_id, enabled, quality } => {
            hollow_log!("[HOLLOW-CALL] CallScreenState from {peer_str} call={call_id} enabled={enabled} quality={quality:?}");
            let mut json = serde_json::json!({
                "call_id": call_id,
                "enabled": enabled,
            });
            if let Some(q) = &quality {
                json["quality"] = serde_json::Value::String(q.clone());
            }
            let payload = json.to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "screen_state".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallScreenOffer { call_id, sdp } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED CallScreenOffer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-CALL] CallScreenOffer from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "sdp": sdp,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "screen_offer".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallScreenAnswer { call_id, sdp } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED CallScreenAnswer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            hollow_log!("[HOLLOW-CALL] CallScreenAnswer from {peer_str} call={call_id}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "sdp": sdp,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "screen_answer".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallScreenIce { call_id, candidate, sdp_mid, sdp_mline_index, role } => {
            hollow_log!("[HOLLOW-CALL] CallScreenIce from {peer_str} call={call_id} role={role}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "candidate": candidate,
                "sdpMid": sdp_mid,
                "sdpMLineIndex": sdp_mline_index,
                "role": role,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "screen_ice".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallScreenWatch { call_id, want, viewer_width, viewer_height } => {
            hollow_log!("[HOLLOW-CALL] CallScreenWatch from {peer_str} call={call_id} want={want} viewer={viewer_width}x{viewer_height}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "want": want,
                "viewer_width": viewer_width,
                "viewer_height": viewer_height,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: "screen_watch".to_string(),
                payload,
            }).await;
        }
        HavenMessage::CallRecordingState { call_id, recording } => {
            hollow_log!("[HOLLOW-CALL] CallRecordingState from {peer_str} call={call_id} recording={recording}");
            let payload = serde_json::json!({
                "call_id": call_id,
                "recording": recording,
            }).to_string();
            let _ = event_tx.send(NetworkEvent::CallSignal {
                peer_id: peer_str.to_string(),
                signal_type: if recording { "recording_start" } else { "recording_stop" }.to_string(),
                payload,
            }).await;
        }

        // -- Gossip relay tree (Phase 5D) --
        HavenMessage::PeerExchange { server_id, peers } => {
            hollow_log!("[HOLLOW-GOSSIP] PeerExchange from {peer_str} for server {server_id}: {} peers", peers.len());
            // SECURITY (Phase 6.25): Only accept from gossip neighbors + cap list size.
            if peers.len() > MAX_PEER_EXCHANGE_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED PeerExchange — too many peers ({} > {MAX_PEER_EXCHANGE_SIZE}) from {peer_str}", peers.len());
                return;
            }
            if let Some(overlay) = gossip_overlays.get_mut(&server_id) {
                // Only trust PeerExchange from our current gossip neighbors.
                if !overlay.neighbors.contains(peer_str) {
                    hollow_log!("[HOLLOW-SECURITY] BLOCKED PeerExchange from non-neighbor {peer_str} for server {server_id}");
                    return;
                }
                for p in &peers {
                    if p != local_peer_str {
                        overlay.known_peers.insert(p.clone());
                        overlay.peer_scores
                            .entry(p.clone())
                            .or_insert_with(super::gossip::PeerScore::new);
                    }
                }
            }
        }

        // -- Profile request (Phase profile-sync) --
        HavenMessage::ProfileRequest => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRequest from {peer_str} — sending our profile");
            // FULL send — this is the pull half of the light-announce protocol.
            social::send_own_profile_full_to_peer(
                ws_cmd_tx, ws_room_peers,
                local_peer_str, master_keypair, device_peer_id, peer_str,
                is_invisible,
                db_path, db_passphrase,
            );
        }

        HavenMessage::EmoteRequest { hashes } => {
            emotes::handle_emote_request(
                ws_cmd_tx, ws_room_peers, peer_str, hashes,
                db_path, db_passphrase,
            );
        }

        HavenMessage::EmoteAssets { bundle_json } => {
            emotes::handle_emote_assets(
                event_tx, requested_asset_kinds, bundle_json,
                db_path, db_passphrase,
            ).await;
        }

        HavenMessage::ProfileRequestFor { target_peer_id } => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRequestFor {target_peer_id} from {peer_str}");
            social::handle_profile_request_for(
                ws_cmd_tx, ws_room_peers,
                peer_str, &target_peer_id,
                db_path, db_passphrase,
            );
        }

        HavenMessage::ProfileRelay { source_peer_id, display_name, status, about_me, updated_at, avatar_b64, twitch_username, avatar_hash, profile_sig, profile_pk } => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRelay for {source_peer_id} from {peer_str}");
            social::handle_profile_relay(
                event_tx, server_states,
                source_peer_id, display_name, status, about_me, updated_at,
                avatar_b64, twitch_username, avatar_hash, profile_sig, profile_pk,
                db_path, db_passphrase,
            ).await;
        }

        // -- Plaintext voice channel handlers (MLS epoch-resilient) --
        // These arrive as plaintext HavenMessage instead of MLS MessageEnvelope
        // to survive epoch staleness after reconnection.

        HavenMessage::VoiceChannelJoin { server_id, channel_id } => {
            // Self-echo guard: both id forms (sender echoes carry our DEVICE id).
            if peer_str == local_peer_str || peer_str == device_peer_id { return; }
            // Conferences have no CRDT membership — the equivalent check is
            // MLS group membership (leaf credentials ARE device ids), which
            // only an ADMITTED peer can hold. This is what lets the existing
            // PeerJoined re-broadcast + the conference reply-on-join sync
            // reach late joiners (their plaintext copies otherwise hit the
            // server guard below and a new member never sees who's already
            // in the call).
            let is_conf = super::conference::is_conference_sid(&server_id);
            let is_member = if is_conf {
                mls.as_ref().is_some_and(|m|
                    m.group_members(&server_id).iter().any(|c| c == peer_str))
            } else {
                server_states.get(&server_id)
                    .map(|s| s.is_member(peer_str))
                    .unwrap_or(false)
            };
            let is_voice_channel = if is_conf {
                channel_id == super::conference::CONF_CHANNEL
            } else {
                server_states.get(&server_id)
                    .and_then(|s| s.channels.get(&channel_id))
                    .map(|ch| ch.channel_type == crate::crdt::server_state::ChannelType::Voice)
                    .unwrap_or(false)
            };
            if !is_member {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VoiceChannelJoin from non-member {peer_str} in server {server_id}");
            } else if !is_voice_channel {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VoiceChannelJoin for non-voice channel {channel_id} in server {server_id}");
            } else {
                hollow_log!("[HOLLOW-VC] {peer_str} joined voice channel {channel_id} in {server_id} (plaintext)");
                let vc_key = format!("{server_id}:{channel_id}");
                voice_channel_participants.entry(vc_key.clone()).or_default()
                    .insert(peer_str.to_string());
                let _ = event_tx.send(NetworkEvent::VoiceChannelJoined {
                    server_id: server_id.clone(), channel_id: channel_id.clone(),
                    peer_id: peer_str.to_string(), is_self: false,
                }).await;
                voice_handler::check_voice_mode_transition(
                    &vc_key, &server_id, &channel_id,
                    &voice_channel_participants, voice_channel_gossip_mode,
                    &gossip_overlays, device_peer_id, &event_tx,
                ).await;
            }
        }

        HavenMessage::VoiceChannelLeave { server_id, channel_id } => {
            // Self-echo guard: both id forms (see the join twin).
            if peer_str == local_peer_str || peer_str == device_peer_id { return; }
            hollow_log!("[HOLLOW-VC] {peer_str} left voice channel {channel_id} in {server_id} (plaintext)");
            let vc_key = format!("{server_id}:{channel_id}");
            if let Some(participants) = voice_channel_participants.get_mut(&vc_key) {
                participants.remove(peer_str);
                if participants.is_empty() {
                    voice_channel_participants.remove(&vc_key);
                    voice_channel_gossip_mode.remove(&vc_key);
                }
            }
            let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
                server_id: server_id.clone(), channel_id: channel_id.clone(),
                peer_id: peer_str.to_string(), is_self: false,
            }).await;
            voice_handler::check_voice_mode_transition(
                &vc_key, &server_id, &channel_id,
                &voice_channel_participants, voice_channel_gossip_mode,
                &gossip_overlays, device_peer_id, &event_tx,
            ).await;
        }

        HavenMessage::VoiceChannelAudioState { server_id, channel_id, muted, deafened } => {
            let vc_key = format!("{server_id}:{channel_id}");
            let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
            if !is_participant {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VC audio state from non-participant {peer_str} in {channel_id}");
            } else {
                let payload = serde_json::json!({
                    "muted": muted,
                    "deafened": deafened,
                }).to_string();
                let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                    server_id, channel_id, peer_id: peer_str.to_string(),
                    signal_type: "audio_state".to_string(), payload,
                }).await;
            }
        }

        HavenMessage::VoiceChannelScreenState { server_id, channel_id, enabled, quality } => {
            let vc_key = format!("{server_id}:{channel_id}");
            let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
            if !is_participant {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VC screen state from non-participant {peer_str} in {channel_id}");
            } else {
                let mut json = serde_json::json!({"enabled": enabled});
                if let Some(q) = &quality {
                    json["quality"] = serde_json::Value::String(q.clone());
                }
                let payload = json.to_string();
                let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                    server_id, channel_id, peer_id: peer_str.to_string(),
                    signal_type: "screen_state".to_string(), payload,
                }).await;
            }
        }

        HavenMessage::VoiceChannelCameraState { server_id, channel_id, enabled } => {
            let vc_key = format!("{server_id}:{channel_id}");
            let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
            if !is_participant {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VC camera state from non-participant {peer_str} in {channel_id}");
            } else {
                let payload = serde_json::json!({"enabled": enabled}).to_string();
                let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                    server_id, channel_id, peer_id: peer_str.to_string(),
                    signal_type: "camera_state".to_string(), payload,
                }).await;
            }
        }

        HavenMessage::VoiceChannelRecordingState { server_id, channel_id, recording } => {
            let vc_key = format!("{server_id}:{channel_id}");
            let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
            if !is_participant {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VC recording state from non-participant {peer_str} in {channel_id}");
            } else {
                let payload = serde_json::json!({"recording": recording}).to_string();
                let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                    server_id, channel_id, peer_id: peer_str.to_string(),
                    signal_type: if recording { "recording_start" } else { "recording_stop" }.to_string(),
                    payload,
                }).await;
            }
        }

        _ => {}
    }
}

// flush_pending_sync_requests moved to sync_handler.rs

