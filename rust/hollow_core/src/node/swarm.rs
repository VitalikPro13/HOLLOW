use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

pub(crate) const MLS_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(60);

/// At most one KeyPackage answered per group in this window: each answer mints and
/// persists private key material.
pub(crate) const KEY_PACKAGE_ANSWER_GAP: Duration = Duration::from_secs(10);

/// How long a served `ServerJoinRequest` is remembered, so a REPEAT ask is
/// recognised as the joiner's retry and bypasses the coordinator gate. Longer
/// than that retry, shorter than the join timeout: at most one escalation.
pub(crate) const JOIN_SERVE_RETRY_WINDOW: Duration = Duration::from_secs(12);

/// How long an in-flight Olm KeyRequest counts as live before the
/// session-reconciliation sweep may resend it. The relay never ACKs a direct
/// message, so a dropped KeyRequest would otherwise strand the flag forever.
const OLM_KEY_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// How long before a co-member device we still cannot place is introduced to again.
const CO_MEMBER_INTRO_RETRY: Duration = Duration::from_secs(300);

/// At most this many introductions per sweep, so a big server's reconnect spreads
/// them out.
const CO_MEMBER_INTRO_BATCH: usize = 8;

/// How often the batch tick looks for co-members to introduce ourselves to: every
/// leaf of every server group is walked.
const CO_MEMBER_SWEEP_EVERY: Duration = Duration::from_secs(10);

/// Every leaf our server groups certify for a co-member: bound to a master who is a
/// member of that server, and neither ours, revoked, disowned nor blocked. Paired
/// with the server it sits in.
fn certified_co_member_leaves(
    mls: &MlsManager,
    server_states: &HashMap<String, ServerState>,
    local_master: &str,
) -> Vec<(String, crate::crypto::LeafIdentity)> {
    let mut out = Vec::new();
    for server_id in mls.group_ids() {
        if server_id.contains('#') || super::conference::is_conference_sid(&server_id) {
            continue;
        }
        let Some(state) = server_states.get(&server_id) else { continue };
        for leaf in mls.group_leaves(&server_id) {
            let crate::crypto::LeafView::Bound(leaf) = leaf else { continue };
            if leaf.master != local_master
                && state.members.contains_key(&leaf.master)
                && !super::resolver::is_revoked(&leaf.device)
                && !super::resolver::disowns(&leaf.master, &leaf.device)
                && !super::blocklist::is_blocked(&leaf.master)
            {
                out.push((server_id.clone(), leaf));
            }
        }
    }
    out
}

/// True when a KeyRequest to `peer` is still within `OLM_KEY_REQUEST_TIMEOUT`;
/// a stale or absent entry returns false so the caller may resend.
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
/// A forwarder is not a social peer: it holds no group keys, is in no server,
/// shares no DMs and DISCARDS every discovery frame, so presence in one of these
/// rooms must not trigger the peer-discovery cascade.
pub(crate) fn is_forwarder_room(room: &str) -> bool {
    room.starts_with("fwd:")
}

/// True when EVERY room we share with `peer` is a forwarder control-plane room,
/// so this peer is a media forwarder to us and not a social peer. Structural,
/// which makes it hold for peer forwarders as well as the VPS one. False when we
/// share any ordinary room (a friend watching through our embedded engine still
/// shares their DM room) and false when we share none: "unknown" must never be
/// treated as "forwarder".
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

/// The one piece of the peer-discovery cascade the forwarder lane genuinely
/// needs: an Olm session, plus the drain of anything queued while we had none.
///
/// Returns true when a confirmed session already existed, so the caller can run
/// the discovery work that belongs after it (the full path also flushes pending
/// sync requests there; the fwd lane must not). Load-bearing for that lane:
/// `send_fwd_envelope_via_room` QUEUES into `pending_messages`, so this drain is
/// what delivers a share's first `fwd_stream_register`.
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
    // An outbound-only session is NOT proof the peer can decrypt us. Reporting
    // SessionEstablished for an unconfirmed session is the "A writes and B does not
    // see it" bug: B never built its half.
    if olm.has_confirmed_session(peer_id) {
        let _ = event_tx
            .send(NetworkEvent::SessionEstablished {
                peer_id: peer_id.to_string(),
            })
            .await;
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

/// Our session with `peer` was just built or switched to: report it once it is
/// confirmed, acknowledge it so the peer's outbound half confirms too, and send what
/// waited for a session.
#[allow(clippy::too_many_arguments)]
async fn on_session_ready(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    master_peer_str: &str,
    peer_str: &str,
    had_session: bool,
    ack: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    if olm.has_confirmed_session(peer_str) {
        let _ = event_tx
            .send(NetworkEvent::SessionEstablished { peer_id: peer_str.to_string() })
            .await;
        key_request_in_flight.remove(peer_str);
    }
    if ack {
        let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
        send_encrypted_message(
            olm, crypto_store, peer_str, &ack_json, event_tx, ws_cmd_tx, ws_room_peers,
        ).await;
    }
    if let Some(queued) = pending_messages.remove(peer_str) {
        hollow_log!("[HOLLOW-CRYPTO] Draining {} pending messages for {peer_str}", queued.len());
        for text in queued {
            send_encrypted_message(
                olm, crypto_store, peer_str, &text, event_tx, ws_cmd_tx, ws_room_peers,
            ).await;
        }
    }
    // With no session, the peer's DMs in that window may never have rendered here:
    // ask it to re-serve from our high-water mark.
    if !had_session {
        request_dm_resync_after_rekey(
            peer_str, master_peer_str, ws_cmd_tx, ws_room_peers, db_path, db_passphrase,
        );
    }
    sync_handler::flush_pending_sync_requests(
        pending_sync_requests, peer_str, olm, crypto_store, bundle_keypair, event_tx,
        ws_cmd_tx, ws_room_peers, crdt_store, db_path, db_passphrase,
    ).await;
}

/// Push our WHOLE personal emote set (tombstones included) to a verified sibling.
/// Rows only: a name the sibling cannot render pulls its bytes over the asset rail.
fn send_personal_emotes_to_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> usize {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return 0;
    };
    let Ok(rows) = store.list_personal_emote_entries() else {
        return 0;
    };
    if rows.is_empty() {
        return 0;
    }
    let emotes: Vec<PersonalEmoteEntry> = rows
        .into_iter()
        .map(|(name, hash, animated, source, added_at)| PersonalEmoteEntry {
            name, hash, animated, source, added_at,
        })
        .collect();
    let count = emotes.len();
    hollow_log!(
        "[HOLLOW-MULTIDEV] Sharing {count} personal emote row(s) with sibling {peer_id}"
    );
    super::olm_lane::carry(
        ws_cmd_tx, peer_id, None,
        &HavenMessage::PersonalEmoteSync { emotes },
        super::olm_lane::NoSession::Queue,
    );
    count
}

/// Run the sibling convergence for `peer_id`, one of our own devices: our roster names
/// it a member (design ID-1). Holding the master key is not enough, and neither is
/// bare `inbox:{our_master}` membership: a friend-request sender sits there too.
///
/// Pushes our profile and friends and pulls theirs, requests a DM backfill, and
/// re-announces our servers. Synchronous: none of these calls await.
#[allow(clippy::too_many_arguments)]
fn on_verified_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_states: &HashMap<String, ServerState>,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
    peer_id: &str,
    own_call: Option<&CallPresence>,
) {
    if !super::resolver::same_identity(peer_id, local_peer_str) || super::resolver::is_revoked(peer_id) {
        hollow_log!("[HOLLOW-ROSTER] {peer_id} is not one of this identity's devices: no sibling state");
        return;
    }
    let own_inbox = format!("inbox:{}", local_peer_str);

    // Hand the sibling our roster (in a ProfileUpdate), so it holds everything we do.
    social::send_own_profile_to_peer(
        ws_cmd_tx, ws_room_peers, server_states,
        local_peer_str, master_keypair, peer_id,
        is_invisible,
        db_path, db_passphrase,
    );

    // A freshly-imported device holds the master KEY but none of the master's
    // profile CONTENT, so pull the profile from the sibling when ours is empty.
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
        super::olm_lane::carry(ws_cmd_tx, peer_id, None, &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
    }

    // Both sides share on verification, so whichever device read more while the
    // other was away wins per conversation (#80).
    super::crypto_handler::share_state_with_sibling(ws_cmd_tx, peer_id, db_path, db_passphrase);
    send_personal_emotes_to_sibling(ws_cmd_tx, peer_id, db_path, db_passphrase);

    // Re-announce every server we still BELONG to (idempotent on the receiver).
    // The MEMBERSHIP filter matters as much as the tombstone: announcing a shell
    // retained after our own LEAVE makes the sibling re-ADD our identity to a
    // server we left, real members reject that op, and the actor's devices fork.
    for (sid, st) in server_states.iter() {
        if st.is_deleted() || !st.is_member(local_peer_str) { continue; }
        super::olm_lane::carry(
            ws_cmd_tx, peer_id, Some(&own_inbox),
            &HavenMessage::SiblingServerAnnounce { server_id: sid.clone(), owner: st.anchor_owner(), join_key: st.join_public_text() },
            super::olm_lane::NoSession::Queue,
        );
    }
    hollow_log!(
        "[HOLLOW-CRDT] Re-announced {} server(s) to verified sibling {peer_id}",
        server_states.values()
            .filter(|s| !s.is_deleted() && s.is_member(local_peer_str))
            .count()
    );

    // Both ways: ours goes with the ask, and the sibling answers with its own, so
    // a device back from an unclean drop hears of a call the other is in.
    let kind = super::call_book::own_device_kind().to_string();
    super::olm_lane::carry(ws_cmd_tx, peer_id, None, &HavenMessage::DeviceKind { kind }, super::olm_lane::NoSession::Queue);
    super::olm_lane::carry(
        ws_cmd_tx, peer_id, None,
        &HavenMessage::SiblingCallState { presence: own_call.cloned(), ask: true },
        super::olm_lane::NoSession::Queue,
    );
}

/// Room presence after the resolver moved (G1): a master id that turned bare leaves it,
/// and if one left out earlier is a device now, every room is asked for its members.
async fn settle_bare_presence(
    bare_presence: &mut super::roster_book::BarePresence,
    ws_room_peers: &mut HashMap<String, std::collections::HashSet<String>>,
    synced_peers: &mut std::collections::HashSet<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) {
    let (bare, admitted) = bare_presence.settle(ws_room_peers);
    for peer_id in bare {
        hollow_log!("[HOLLOW-SECURITY] {peer_id} is a master id its roster no longer counts: out of room presence");
        synced_peers.remove(&peer_id);
        let _ = event_tx.send(NetworkEvent::PeerDisconnected { peer_id }).await;
    }
    if admitted {
        for room_code in ws_room_peers.keys().cloned() {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code });
        }
    }
}

/// A sibling that went offline no longer holds the identity's one call.
async fn sibling_left_its_call(
    call_book: &mut super::call_book::CallBook,
    event_tx: &mpsc::Sender<NetworkEvent>,
    device: &str,
) {
    if call_book.sibling_gone(device) {
        emit_sibling_call(event_tx, device, None).await;
    }
}

async fn emit_sibling_call(event_tx: &mpsc::Sender<NetworkEvent>, device: &str, presence: Option<CallPresence>) {
    let p = presence.unwrap_or_default();
    let _ = event_tx.send(NetworkEvent::SiblingCallState {
        device: device.to_string(),
        active: !p.kind.is_empty(),
        kind: p.kind,
        with: p.with,
        channel: p.channel,
        started_ms: p.started_ms,
    }).await;
}

/// Converge with each sibling an ingest just admitted that sits in our inbox now.
#[allow(clippy::too_many_arguments)]
fn converge_new_siblings(
    added: &[String],
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    local_peer_str: &str,
    server_states: &HashMap<String, ServerState>,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
    own_call: Option<&CallPresence>,
) {
    let own_inbox = format!("inbox:{local_peer_str}");
    let Some(present) = ws_room_peers.get(&own_inbox) else { return };
    for device in added.iter().filter(|d| d.as_str() != device_peer_id && present.contains(*d)) {
        on_verified_sibling(
            ws_cmd_tx, ws_room_peers, master_keypair, local_peer_str,
            server_states, is_invisible, db_path, db_passphrase, device, own_call,
        );
    }
}

/// Hand our roster to a device in our own inbox that it does not name. The relay shows
/// an inbox only to devices that proved they hold its master key, so this tells it
/// nothing new; from the roster it learns whether it is one of ours, and we learn the
/// same from its answer.
fn offer_roster(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Some(roster) = super::roster_book::own_roster(local_peer_str, db_path, db_passphrase) {
        send_message_to_peer(ws_cmd_tx, ws_room_peers, peer_id, HavenMessage::RosterNotice { roster });
    }
}

use crate::crdt::hlc::Hlc;
use crate::crdt::operations::{CrdtPayload};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{self as crdt_sync, StateVector};
use crate::crypto::{CryptoStore, MlsManager, OlmManager};

use super::types::*;

use super::crypto_handler;
use super::crypto_handler::{
    key_bundle_signing_payload, key_request_signing_payload, signed_key_bundle, signed_key_request,
    verify_key_exchange, key_exchange_device_unauthorized,
    KeyExchangeAuth, REQUIRE_SIGNED_KEY_EXCHANGE,
    check_backfill_signature, BackfillSig, PkCache,
    persist_mls_state, persist_crypto_state, persist_olm_session,
    peer_is_reachable, is_mls_coordinator, is_vault_coordinator, elect_coordinator, ws_room_for_peer,
    send_mls_broadcast, send_encrypted_message,
    send_message_to_peer, send_message_to_peer_in_room, send_raw_to_peer, send_raw_to_identity,
};
use super::destroy;
use super::file_asks;
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

/// Embedded peer-forwarder handle threaded into `handle_incoming_request` so
/// forwarder-bound `fwd_*` envelopes reach the embedded engine. Desktop-only in
/// substance; a PhantomData elsewhere so the shared signature never changes.
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
/// Key routing: the DEVICE keypair drives WS relay auth and the signaling
/// register, so each physical device gets its own relay socket and never
/// clobbers a sibling. The MASTER keypair (`native_keypair`) drives everything
/// else: `local_peer_str`, MLS and server membership, message signing, the DB
/// passphrase. The rooms are master-derived, so the device authenticates as
/// itself yet sits in its identity's rooms. See `node::resolver`.
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
    super::dm_room::register(&native_keypair);

    // Peer discovery rides the live WS connection (`discover_peers` plus RoomMembers
    // on join); the relay keeps its HTTP endpoints only for older clients.

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

/// Test-only spawn variant for the headless multi-node harness. Identical to
/// `spawn_node` except that it opens no real WebSocket or HTTP signaling task
/// and instead takes an injected WS channel pair, so an in-process `MockRelay`
/// can route between several nodes with no network, TLS or auth.
///
/// Returns `(master_peer_id, event_loop_handle, ws_cmd_rx, ws_event_tx)`: the
/// broker drains `ws_cmd_rx` and pushes into `ws_event_tx`.
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
    super::dm_room::register(&native_keypair);

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
    // Production derives these from the global data dir and master keypair; the
    // harness injects per-node temp paths so several nodes share one process.
    db_path: String,
    db_passphrase: String,
) {
    let pub_key_proto = bundle_keypair.public_key_protobuf();
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(&pub_key_proto);

    // -- Multi-device identity --
    // `local_peer_str` and `bundle_keypair` are the MASTER (the event loop runs in
    // identity terms); `device_peer_id` is THIS device's transport id, the one we
    // authenticate to the relay with. Equal on a pre-multi-device install.
    let master_keypair = bundle_keypair.clone();
    let master_peer_str = local_peer_str.clone();
    crypto_handler::bind_olm_identity(&mut olm, &device_keypair);
    let (ws_cmd_tx, mut carry_rx) = super::frame_auth::spawn_sealer(device_keypair.clone(), ws_cmd_tx);
    #[cfg(test)]
    let mut carry_log: Vec<(String, String)> = Vec::new();
    let mut frame_replays = super::frame_auth::ReplayGuard::default();

    // Decrypt-failure cooldown per peer: prevents session thrashing when many
    // in-flight chunks fail decrypt at once (a 340 MB file is 1360 chunks).
    let mut decrypt_fail_cooldown: HashMap<String, std::time::Instant> = HashMap::new();
    const REKEY_COOLDOWN: Duration = Duration::from_secs(5);

    // Buffer messages while key exchange is in progress.
    let mut pending_messages: HashMap<String, Vec<String>> = HashMap::new();

    // peer_id -> when its KeyRequest was sent. Entries older than
    // OLM_KEY_REQUEST_TIMEOUT are stale so the reconciliation sweep can resend: the
    // relay never ACKs, so a dropped frame must self-heal by retry.
    let mut key_request_in_flight: HashMap<String, std::time::Instant> = HashMap::new();
    // Track peers we've sent a KeyBundle to (for glare detection at KeyBundle reception).
    let mut key_bundle_sent_to: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track the active room code so we can re-bootstrap after getting a relay circuit address.
    let mut active_room: Option<String> = None;

    // -- Vault shard assembly state --
    // Tracks chunked shard reassembly. Key = "content_id:shard_index:sender_peer".

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
    let mut bare_presence = super::roster_book::BarePresence::default();

    // Embedded peer forwarder: this desktop can serve as a blind packet
    // forwarder for screen shares it watches. Desktop-only and feature-gated.
    #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
    let mut embedded_fwd =
        super::embedded_forwarder::EmbeddedForwarder::new(device_peer_id.clone());

    // Peers we've already triggered sync for this session.
    let mut synced_peers: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Outstanding asset pulls, keyed by content hash. Each entry records the kind WE
    // asked for, which is what sizes the receipt cap (never anything the sender
    // says), plus where to ask and who has been asked. The table SURVIVES a
    // disconnect (only the per-connection `asked` sets clear), so a holder offline
    // when the token first rendered still gets asked when it appears.
    let mut pending_asset_asks: std::collections::HashMap<String, emotes::PendingAsk> =
        std::collections::HashMap::new();

    // Outstanding FILE pulls, keyed by file_id (node/file_asks.rs). Survives a
    // disconnect like the asset table, so a holder that was offline when the user
    // tapped Download still gets asked, and the card can say so meanwhile.
    let mut pending_file_asks: std::collections::HashMap<String, file_asks::PendingFileAsk> =
        std::collections::HashMap::new();

    // Guest public-file downloads: file_id -> (server_id, asked device, requested-at). The receipt
    // cap for plaintext `PublicFileHeader`s, mirroring `pending_asset_asks`: an
    // unsolicited header would register a decrypt key and let a stranger stream
    // bytes onto our disk.
    let mut pending_public_file_requests: std::collections::HashMap<String, (String, String, std::time::Instant)> =
        std::collections::HashMap::new();

    // Files WE explicitly asked for: file_id -> requested-at. A FileHeader answering
    // one of these bypasses BOTH the per-context size cap and the auto-download gate
    // (issue #41), because the user asked for exactly these bytes. Consumed on the
    // first matching header, expiring after 5 minutes.
    let mut requested_file_receipts: std::collections::HashMap<String, std::time::Instant> =
        std::collections::HashMap::new();

    // Pushed files declined by the auto-download gate this session. Stream bytes
    // that still arrive (the sender queued its push before any response could reach
    // it) are deleted instead of parked forever in `early_file_streams`.
    let mut declined_file_ids: std::collections::HashSet<String> =
        std::collections::HashSet::new();

    // Auto-download preferences ADVERTISED by peer devices (issue #41): device
    // peer_id -> threshold MB for pushes from us (0 = off). The DM file fan-out
    // consults it to skip bytes a gated receiver would only discard. Connection
    // state, cleared on Disconnected; peers re-advertise when they rejoin.
    let mut peer_auto_dl: std::collections::HashMap<String, u32> =
        std::collections::HashMap::new();

    // (server room, channel) pairs whose relay offline catch-up already ran THIS
    // connection. Cleared on Disconnected like every sync gate: a new socket needs
    // a fresh registration and replay.
    let mut relay_catchup_done: std::collections::HashSet<(String, String)> = std::collections::HashSet::new();

    let mut is_invisible = initial_invisible;
    if initial_invisible {
        hollow_log!("[HOLLOW-STATUS] Node starting in invisible mode (persisted preference)");
    }

    // -- WebRTC peer tracking --
    // Peers with active GENERAL 'hollow-data' channels (Dart notifies us via
    // NodeCommand). Carries DM/channel files, vault shards, screen audio, gossip.
    let mut webrtc_peers: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Peers with an active HOLLOW SHARE channel: a SECOND, STUN-only peer connection
    // (HOLLOW_PLAN section 7A). Separate on purpose, because the general channel
    // carries TURN and a Share on it would push multi-GB through the relay.
    let mut webrtc_share_peers: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Pending WebRTC sends — stored so we can retry via WSS on failure.
    // Key: transfer_id, Value: (peer_id, kind, id, source_path, total_size)
    let mut pending_webrtc_sends: HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)> = HashMap::new();

    // At-rest file protection (issue 78): the key ring has to be live before any
    // handler writes content, and the sweep converts what older versions left in
    // plaintext. Both run here so the multi-node harness exercises them too.
    {
        if let Err(e) = crate::node::at_rest::init(&db_path, &db_passphrase) {
            hollow_log!("[HOLLOW-ATREST] key ring unavailable: {e}");
        }
        crate::node::at_rest::wipe_temp_dir();
        // Directories the app fills with content, plus the one loose content file
        // at the data root. The root itself is NEVER swept: identity.key, the
        // database, the logs and profiles.json live there.
        let mut sweep_targets = vec![
            crate::node::file_transfer::files_dir(),
            crate::vault::pipeline::vault_cache_dir(),
            crate::node::share_handler::shares_dir().unwrap_or_default(),
        ];
        if let Ok(root) = crate::identity::data_dir() {
            sweep_targets.push(root.join("audio_cache"));
            sweep_targets.push(root.join("custom_background.img"));
        }
        tokio::task::spawn_blocking(move || {
            crate::node::at_rest::migrate_plaintext(&sweep_targets);
        });
    }

    // Startup sweep: delete orphaned stream temps left by a previous run. They are
    // always transient ciphertext of an in-flight send or receive, whose state lives
    // in RAM, so none can legitimately exist on a fresh boot.
    {
        let files_dir = crate::node::file_transfer::files_dir();
        let swept = tokio::task::spawn_blocking(move || {
            let Ok(entries) = std::fs::read_dir(&files_dir) else { return 0u32 };
            let mut swept = 0u32;
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(".stream_send_")
                    || name.starts_with(".stream_shard_")
                    || name.starts_with(".ws_recv_")
                {
                    if crate::node::at_rest::remove(&entry.path()).is_ok() {
                        swept += 1;
                    }
                }
            }
            swept
        })
        .await
        .unwrap_or(0);
        if swept > 0 {
            hollow_log!("[HOLLOW-FILE] Startup swept {swept} orphaned stream temp(s) from files/");
        }
    }

    // -- Profile sync state --
    let mut profile_broadcast_done = false;

    // -- Gossip relay tree state --
    let mut gossip_overlays: HashMap<String, super::gossip::GossipOverlay> = HashMap::new();

    // -- Voice channel participant tracking --
    // Key: "server_id:channel_id", Value: set of peer_ids in the voice channel.
    let mut voice_channel_participants: HashMap<String, std::collections::HashSet<String>> = HashMap::new();
    let mut call_book = super::call_book::CallBook::default();
    // Track the current voice mode per channel: true = gossip, false = mesh.
    let mut voice_channel_gossip_mode: HashMap<String, bool> = HashMap::new();

    // -- Conference host state (active meetings we host; node/conference.rs) --
    let mut conference_host: HashMap<String, super::conference::ConferenceHostState> = HashMap::new();

    // -- WS stream transfer reassembly state --
    let mut pending_ws_transfers: HashMap<String, super::ws_stream_transfer::WsTransferState> = HashMap::new();

    // -- Recovery pool state (Evidence Recovery) --
    let mut recovery_pool_state: Option<crate::node::recovery_pool::RecoveryPoolState> = None;

    // -- Hollow Share --
    // Registry of active share swarms, owned by this loop and passed as &mut
    // into every handler, like the other domain modules.
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


    // -- Multi-device resolver warm-up --
    // Persisted device links must reach the process-global resolver BEFORE the loop
    // handles any message, or an early message from a friend's other device is
    // misattributed. A no-op self-mapping on a pre-multi-device install.
    // Our own roster comes up to date here (design ID-1), and the resolver holds its
    // members only: holding the master key makes no device one of ours.
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            super::resolver::warm_from_store(&store);
            let (_roster, own_state) =
                super::roster_book::ensure_own(&store, &master_keypair, &device_keypair, &db_path);
            drop(store);
            super::roster_book::announce_own_state(
                &event_tx, &device_peer_id, &own_state, &db_path, &db_passphrase,
            ).await;
            // The UI read the gate before this start settled it (a new join ask).
            let _ = event_tx
                .send(NetworkEvent::DeviceListUpdated { master_peer_id: master_keypair.peer_id() })
                .await;
        }
    }
    // Install the device-to-master resolver into the `crdt` module so
    // ServerState's role, ban, permission and membership accessors collapse a
    // device id internally: one chokepoint for dozens of call sites.
    crate::crdt::set_identity_resolver(super::resolver::resolve);

    // -- Friend-table canonicalization sweep --
    // INVARIANT: every friend row is keyed by the friend's MASTER identity. A row
    // stranded under a friend's DEVICE id diverges from presence, DMs and profile,
    // which are all master-keyed. The resolver is warm by now, so fold any
    // device-keyed row into its master. Idempotent, and it heals an existing broken
    // DB on the next launch with no re-add.
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

    // -- CRDT state --
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
                                install_op_signer(&mut state, &bundle_keypair);
                                // Restore op_log from crdt_ops table (no longer serialized in state JSON).
                                // An anchored server is rebuilt from every op since its anchor.
                                let legacy = state.anchor() == crate::crdt::server_state::Anchor::Legacy;
                                if state.op_log.is_empty() {
                                    if let Ok(ops) = store.load_ops_for_server(&server_id, legacy.then_some(1000)) {
                                        state.restore_op_log(ops);
                                    }
                                }
                                // Fold any legacy device-keyed member entries into
                                // their master identity (the resolver was warmed just
                                // above). A no-op for single-device, and never on an
                                // anchored server, whose ops are master-keyed.
                                if legacy && state.canonicalize_members(|id| super::resolver::resolve(id)) {
                                    if let Ok(json) = serde_json::to_string(&state) {
                                        let _ = store.save_server_state(&server_id, &json);
                                    }
                                    hollow_log!("[HOLLOW-MULTIDEV] Canonicalized device-keyed members → master for server {server_id}");
                                }
                                server_states.insert(server_id.clone(), state);
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
                    // Every MLS group key to reload: each server's bare id (the server-wide group)
                    // plus each restricted channel's subgroup id.
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
                            // Detect an MLS credential that does not belong to THIS device and must be
                            // regenerated: a linked sibling imported the SOURCE device's whole DB including
                            // its MLS signer, and two devices sharing one signature key cannot both be
                            // leaves (`DuplicateSignatureKey` on add, `CannotDecryptOwnMessage` on receive).
                            // Two cases: the credential is some OTHER device's id, or it is our MASTER while
                            // we know sibling devices, which is the inherited keystone leaf. A legacy SOLE
                            // single-device install keeps its master-credentialed leaf, because re-keying it
                            // would orphan the servers it owns: no peer can re-add it.
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
                                // Groups formed before bound leaves keep working: the old key
                                // stays as the legacy signer until the batch tick rebinds.
                                let mut mgr = mgr;
                                mgr.adopt_device_identity(&device_keypair, &master_keypair);
                                hollow_log!("[HOLLOW-MLS] Restored MLS identity from DB (credential {cred_id}), {} group(s) still to rebind", mgr.unbound_own_groups().len());
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
    // Create MLS identity if none exists: this device's key signs, and the leaf
    // credential carries the master's certificate for the device.
    if mls.is_none() {
        match MlsManager::new(&device_keypair, &master_keypair) {
            Ok(mgr) => {
                hollow_log!("[HOLLOW-MLS] Created new MLS identity");
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
    // server_id -> (join key, owner pin) of the invite a join started from, for the
    // re-ask that answers a consent or Twitch question with no link in hand.
    let mut join_invites: HashMap<String, (String, Option<String>)> = HashMap::new();
    // Our side of every server's join lock (`lock_keeper`), and joins that just
    // completed, whose later answers still merge (`RecentJoin`).
    let mut lock_keeper = super::lock_keeper::LockKeeper::default();
    let mut recent_joins: HashMap<String, RecentJoin> = HashMap::new();
    // "{server_id}|{joiner_device}" -> when we last saw that join request, so the
    // coordinator gate can tell a first ask from the joiner's escalation retry.
    let mut join_request_seen: HashMap<String, std::time::Instant> = HashMap::new();
    // "{server_id}|{joiner_master}" -> the newest `requested_at` we know has been
    // ANSWERED, read from the `~join` ring or written by our own answer. It stops a
    // member returning days later from re-serving a join somebody else handled. NOT
    // sync-gating state, so it deliberately survives `WsEvent::Disconnected`.
    let mut join_resolutions: HashMap<String, i64> = HashMap::new();
    // Servers whose PARKED join completed but whose MLS leaf has not formed yet.
    // Between the two the UI says "waiting for a member to finish setup"; the
    // Welcome clears it.
    let mut awaiting_mls_after_parked_join: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    // Pending friend requests: peer_id → requested_at timestamp.
    // Queued when peer isn't reachable (no shared rooms), sent when they appear.
    let mut pending_friend_requests: HashMap<String, i64> = HashMap::new();
    // Masters whose DECLINE we have already re-sent on THIS connection. The relay's
    // copy of a reject expires before the requester next boots; the requester then
    // re-deposits the same request and we swallow it against the tombstone, so
    // without re-arming the answer it would never learn. Cleared on Disconnected
    // like every reconnect-scoped gate: the mailbox only replays on an inbox
    // rejoin, so one re-send per connection is exactly one per replay burst.
    let mut reject_resent: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut pending_nickname_resolve: Option<String> = None;
    let mut link = link_handler::LinkState::default();
    // Destruction freshness: the first start of a device stamps when it joined the
    // identity, so an order issued before it existed can never wipe it.
    super::destroy::stamp_device_link(&db_path, &db_passphrase, &device_peer_id);

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

    // PARKED JOINS: restore every join still waiting for an answer. A parked entry
    // gets NO timer, because waiting indefinitely for a member to return is the
    // point. The room join happens in the `WsEvent::Connected` handler with every
    // other room join. A refused row is restored too: a refusal never ends a join.
    {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
            let rows = store.load_pending_joins().unwrap_or_default();
            if !rows.is_empty() {
                // ONE build for all of them: this opens the DB.
                let device_list = super::roster_book::own_roster(&master_keypair.peer_id(), &db_path, &db_passphrase);
                let card = super::profile_card::own_card(&master_keypair, &db_path, &db_passphrase);
                let mut restored = 0usize;
                for row in rows {
                    // A row from before the join lane names no key to seal it to: it can
                    // never be answered, so it turns into a tile that says so.
                    if row.join_key.is_none() {
                        if row.state == "pending" {
                            let reason = sync_handler::INVITE_OUTDATED.to_string();
                            let _ = store.upsert_pending_join(&crate::storage::messages::PendingJoinRow {
                                state: "rejected".to_string(),
                                reason,
                                ..row
                            });
                        }
                        continue;
                    }
                    let refused = (row.state == "rejected").then(|| row.reason.clone());
                    pending_server_joins.insert(row.server_id.clone(), PendingJoin {
                        twitch_proof_json: row.twitch_proof_json,
                        nsfw_confirmed: row.nsfw_confirmed,
                        requested_at: row.requested_at,
                        parked: true,
                        last_deposited_at: row.last_deposited_at,
                        device_list: device_list.clone(),
                        // Rung 2: the same package the ring copy names. Its
                        // private half came back with the MLS store, so a
                        // re-deposit after a restart is the SAME leaf request.
                        key_package: row.key_package,
                        owner_pin: row.owner_pin,
                        join_key: row.join_key,
                        reply_secret: row.reply_secret.as_deref().and_then(super::join_lane::ReplySecret::from_stored),
                        refused,
                        card: card.clone(),
                        ..Default::default()
                    });
                    restored += 1;
                }
                if restored > 0 {
                    hollow_log!("[HOLLOW-CRDT] Restored {restored} parked server join(s) from DB");
                }
            }
        }
    }

    // Pending friend ACCEPTS: master -> timestamp. A FriendAccept we sent may not
    // have reached the requester (its device raced our accept, or it was offline),
    // which leaves the requester stuck "pending outgoing" forever. Seeded with EVERY
    // accepted friend, so first contact each session re-sends an idempotent accept;
    // drained on the peer's appearance, at most one extra message per friend.
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

    // server_ids we already requested MLS bootstrap for, so an MlsChannelMessage
    // for an unknown group cannot spam the owner. The value is when the request
    // was sent; entries expire after MLS_BOOTSTRAP_TIMEOUT to allow a retry.
    let mut mls_bootstrap_requested: HashMap<String, std::time::Instant> = HashMap::new();

    // Groups a commit just evicted us from while we are still a member, and when.
    // A remove + re-add is two commits from ONE batch tick with the removal first,
    // so the Welcome that puts us back is already in flight: asking for a leaf on
    // seeing the removal mints a KeyPackage the next tick turns into another
    // remove + re-add. Swept at the top of the tick, cleared by the Welcome.
    let mut mls_welcome_grace: HashMap<String, std::time::Instant> = HashMap::new();

    // Co-member devices we introduced ourselves to, so the batch tick asks each once
    // per window rather than every two seconds.
    let mut co_member_introductions: HashMap<String, std::time::Instant> = HashMap::new();
    let mut co_member_swept = std::time::Instant::now();

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

    // Multi-peer fan-out sync coordinator.
    // Collects connected peers for 500ms, then assigns channels evenly across peers.
    let mut sync_coordinator = SyncCoordinator::new();

    let mut sync_dispatch_timer = tokio::time::interval(Duration::from_millis(100));
    sync_dispatch_timer.tick().await; // consume immediate first tick

    // Channel sync dedup: tracks (server_id:channel_id) → last sync request time.
    // Prevents the same channel from being sync-requested multiple times in quick succession.
    let mut channel_sync_sent: HashMap<String, std::time::Instant> = HashMap::new();
    let mut slow_mode_clock = message_ops::SlowModeClock::default();

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

    // cfg(test) shortens the period so the harness can watch a query.
    let liveness_secs: u64 = if cfg!(test) { 3 } else { 60 };
    let mut peer_liveness_timer = tokio::time::interval(Duration::from_secs(liveness_secs));
    peer_liveness_timer.tick().await; // consume immediate first tick

    // Asset-rail retry sweep: rotate a pull that has gone quiet to its next holder.
    // Covers responders that answer a total miss with silence (any client older
    // than the `missing` field) and a first holder that simply never replied.
    // cfg(test) shortens the period so the harness can watch a rotation.
    let mut asset_retry_timer =
        tokio::time::interval(Duration::from_secs(emotes::ASSET_RETRY_SECS));
    asset_retry_timer.tick().await; // consume immediate first tick

    // Temporary channel-grant expiry sweep. The predicate is lazy (an expired grant
    // already reads as denied); this timer drives the CONSEQUENCES: MLS subgroup
    // leaf removal (coordinator-gated, idempotent), voice eviction, and a
    // ServerUpdated so the expired member's own UI refreshes.
    let grant_sweep_secs: u64 = if cfg!(test) { 2 } else { 30 };
    let mut grant_sweep_timer = tokio::time::interval(Duration::from_secs(grant_sweep_secs));
    grant_sweep_timer.tick().await; // consume immediate first tick
    // Last-tick watermark; 0 so the FIRST tick reconciles grants that expired
    // while this node was offline (one-time, idempotent).
    let mut grant_sweep_last_ms: u64 = 0;

    // TURN credentials last an hour; re-request at 50 minutes so a long session
    // never expires mid-call. A fresh set also arrives on every Connected, so this
    // only matters for continuously-connected sessions.
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
        if bare_presence.stale() {
            Box::pin(settle_bare_presence(&mut bare_presence, &mut ws_room_peers, &mut synced_peers, &event_tx, &ws_cmd_tx)).await;
        }
        tokio::select! {
            Some((carry, done)) = carry_rx.recv() => {
                if let super::ws_client::WsCommand::Carry { device, room, json, no_session } = carry {
                    #[cfg(test)]
                    carry_log.push((device.clone(), json.clone()));
                    let frames = super::olm_lane::OlmLane::new(
                        &mut olm, &crypto_store, &ws_room_peers,
                        &mut pending_messages, &mut key_request_in_flight, &device_keypair, &device_peer_id,
                    )
                    .deliver(&device, room.as_deref(), &json, no_session);
                    let _ = done.send(frames);
                }
            }

            Some(cmd) = cmd_rx.recv() => {
                arm_started = Some(("cmd", cmd.kind(), std::time::Instant::now()));
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // If switching rooms, unregister from the old room and clear state.
                        if let Some(old_room) = active_room.as_ref().filter(|r| *r != &room_code) {
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                        }
                        active_room = Some(room_code.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                            room_code: room_code.clone(),
                        });
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

                    // -- CRDT commands --

                    NodeCommand::CreateServer { name } => {
                        let before: std::collections::HashSet<String> = server_states.keys().cloned().collect();
                        sync_handler::handle_create_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id, name,
                            &crypto_store, &crdt_store,
                        ).await;
                        // Its first join lock, before any invite can be used.
                        for created in server_states.keys().filter(|id| !before.contains(*id)) {
                            lock_keeper.watch(created, &local_peer_str, &ws_cmd_tx);
                        }
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

                    NodeCommand::JoinServer { server_id, twitch_proof_json, nsfw_confirmed, owner_pin, join_key } => {
                        // The answer to a consent or Twitch question asks again with no link
                        // in hand: the invite that started the join is the one it means.
                        let remembered = join_invites.get(&server_id).cloned();
                        let owner_pin = owner_pin.or_else(|| remembered.as_ref().and_then(|(_, pin)| pin.clone()));
                        let join_key = join_key
                            .filter(|k| super::sealed_box::key_from_text(k).is_some())
                            .or_else(|| remembered.map(|(key, _)| key))
                            .or_else(|| pending_server_joins.get(&server_id).and_then(|p| p.join_key.clone()))
                            .or_else(|| server_states.get(&server_id).and_then(|s| s.join_public_text()));
                        let Some(join_key) = join_key else {
                            hollow_log!("[HOLLOW-CRDT] Join of {server_id} refused here: the invite carries no join key");
                            let _ = event_tx.send(NetworkEvent::TwitchJoinRejected {
                                server_id,
                                reason: sync_handler::INVITE_OUTDATED.to_string(),
                            }).await;
                            continue;
                        };
                        if join_invites.len() >= 256 {
                            join_invites.clear();
                        }
                        join_invites.insert(server_id.clone(), (join_key.clone(), owner_pin.clone()));
                        sync_handler::handle_join_server(
                            &mut pending_server_joins, &ws_cmd_tx,
                            &ws_room_peers, &cmd_tx,
                            server_id, twitch_proof_json, nsfw_confirmed, owner_pin, join_key,
                            &crdt_store, &master_keypair, &device_peer_id,
                            &mls, &crypto_store, None, None,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::ChangeRole { server_id, peer_id, new_role } => {
                        let sid = server_id.clone();
                        lock_keeper.nudge(&sid);
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
                        lock_keeper.nudge(&server_id);
                        if sync_handler::handle_kick_member(
                            &mut server_states, &mut mls, &mut olm, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RevokeDevice { device_peer_id: target } => {
                        if let Some(revoked) = Box::pin(sync_handler::handle_revoke_device(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &server_states, &master_keypair,
                            &device_keypair, &master_peer_str, &local_peer_str, &device_peer_id,
                            is_invisible, target, &db_path, &db_passphrase,
                        )).await {
                            // Drop our Olm session to the removed device + (coordinator)
                            // remove its MLS leaf from shared servers: the same enforcement
                            // a friend runs when it ingests the removal.
                            enforce_device_revocations(
                                &[revoked], &mut olm, &crypto_store, mls.as_ref(),
                                &local_peer_str, &ws_room_peers, &mut pending_mls_removals,
                            );
                        }
                    }

                    NodeCommand::PublishSelfRevocation { reply } => {
                        let ok = destroy::handle_publish_self_revocation(
                            &ws_cmd_tx, &ws_room_peers, &server_states, &master_keypair,
                            &device_keypair, &master_peer_str, &device_peer_id, is_invisible,
                            &db_path, &db_passphrase,
                        );
                        let _ = reply.send(ok);
                    }

                    NodeCommand::PublishDestroyIdentity { order, reply } => {
                        let reached = Box::pin(destroy::handle_publish_destroy_identity(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &master_peer_str, &device_peer_id, *order, &db_path, &db_passphrase,
                        )).await;
                        let _ = reply.send(reached);
                    }

                    NodeCommand::PublishDelegatedDestroy { delegation, notify_friends, reply } => {
                        let order = crypto_handler::build_delegated_destroy(
                            &master_keypair, &device_keypair, delegation,
                            destroy::now_ms(), notify_friends,
                        );
                        let reached = Box::pin(destroy::handle_publish_destroy_identity(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &master_peer_str, &device_peer_id, order, &db_path, &db_passphrase,
                        )).await;
                        let _ = reply.send(reached);
                    }

                    NodeCommand::ApproveDevice { device_peer_id: target } => {
                        Box::pin(sync_handler::handle_approve_device(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &server_states, &master_keypair,
                            &device_keypair, &local_peer_str, &device_peer_id, is_invisible,
                            target, &db_path, &db_passphrase,
                        )).await;
                    }

                    NodeCommand::RosterChanged { newly_revoked } => {
                        enforce_device_revocations(
                            &newly_revoked, &mut olm, &crypto_store, mls.as_ref(),
                            &local_peer_str, &ws_room_peers, &mut pending_mls_removals,
                        );
                        sync_handler::announce_roster_change(
                            &ws_cmd_tx, &ws_room_peers, &server_states, &master_keypair,
                            &local_peer_str, &device_peer_id, is_invisible, &newly_revoked,
                            &db_path, &db_passphrase,
                        );
                        super::roster_book::announce_phrase_change(
                            &ws_cmd_tx, &local_peer_str, server_states.keys(), &db_path, &db_passphrase,
                        );
                        if let Some((_, state)) = super::roster_book::own(&local_peer_str, &db_path, &db_passphrase) {
                            super::roster_book::announce_own_state(
                                &event_tx, &device_peer_id, &state, &db_path, &db_passphrase,
                            ).await;
                            if state.is_member(&device_peer_id) {
                                let _ = event_tx.send(NetworkEvent::DeviceRestored).await;
                            }
                        }
                        let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
                            master_peer_id: master_peer_str.clone(),
                        }).await;
                    }

                    NodeCommand::UnregisterPushToken => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::UnregisterPushToken);
                    }

                    NodeCommand::KillAck => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillAck { issued_at_ms: None });
                    }

                    NodeCommand::DepositKillSignal { targets, issued_at_ms, blob } => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillDeposit {
                            targets, issued_at_ms, blob,
                        });
                    }

                    NodeCommand::ResetDeviceLists => {
                        if let Some(revoked) = Box::pin(sync_handler::handle_reset_device_lists(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &server_states, &master_keypair,
                            &device_keypair, &master_peer_str, &local_peer_str, &device_peer_id,
                            is_invisible, &db_path, &db_passphrase,
                        )).await {
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
                        // Only our devices are in inbox:{master}; any shared room reaches it.
                        let own_inbox = format!("inbox:{local_peer_str}");
                        let room = ws_room_peers.get(&own_inbox)
                            .is_some_and(|p| p.contains(&source_device_id))
                            .then_some(own_inbox);
                        super::olm_lane::carry(
                            &ws_cmd_tx, &source_device_id, room.as_deref(),
                            &HavenMessage::SiblingStateSyncRequest,
                            super::olm_lane::NoSession::Queue,
                        );
                    }

                    NodeCommand::SyncPersonalEmotes { emotes } => {
                        let count = emotes.len();
                        let sent = super::olm_lane::carry_to_own_siblings(
                            &ws_cmd_tx, &ws_room_peers, &local_peer_str, &device_peer_id,
                            &HavenMessage::PersonalEmoteSync { emotes },
                            super::olm_lane::NoSession::Queue,
                        );
                        hollow_log!(
                            "[HOLLOW-MULTIDEV] Personal emote delta ({count} row(s)) fanned to {sent} sibling device(s)"
                        );
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
                        lock_keeper.nudge(&server_id);
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

                    // Delete/update/assign/unassign can each shift who qualifies for a label-gated
                    // channel, so reconcile every channel's subgroups after each: one label can
                    // gate many. Runs even on a permission-denied result; reconcile is idempotent.
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
                            &ws_cmd_tx, &ws_room_peers, &mut pending_asset_asks,
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
                                    store.get_visible_channel_messages_before(&server_id, &channel_id, before_ts, limit)
                                } else {
                                    // Initial request: LATEST messages, mirroring the remote responder.
                                    // `messages_since(0)` returns the OLDEST 50, which lands an owner cold-starting
                                    // into their own public channel at the START of history.
                                    store.get_visible_channel_messages_before(&server_id, &channel_id, i64::MAX, limit)
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
                    NodeCommand::UpdateProfile { display_name, status, about_me, avatar_bytes, banner_bytes, twitch_username, showcase_board, showcase_assets, avatar_frame, avatar_anim, banner_anim, support_creds } => {
                        social::handle_update_profile(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut mls, &server_states,
                            &crypto_store, &local_peer_str, &master_keypair, &device_peer_id,
                            display_name, status, about_me,
                            avatar_bytes, banner_bytes, is_invisible, twitch_username,
                            showcase_board, showcase_assets, avatar_frame,
                            avatar_anim, banner_anim, support_creds,
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
                            &mut olm, &crypto_store,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_friend_requests,
                            &mut pending_friend_removals,
                            &local_peer_str, &master_keypair, &device_keypair, &device_peer_id,
                            peer_id_str,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::ResolveNickname { nickname } => {
                        let nickname = nickname.to_lowercase();
                        pending_nickname_resolve = Some(nickname.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ResolveNickname { nickname });
                    }

                    NodeCommand::ClaimNickname { nickname } => {
                        // Our MASTER signs the claim for this device: the relay hands
                        // it back on resolve, so a stranger's request goes to
                        // `inbox:{master}` and only to a master that claimed it.
                        let nickname = nickname.to_lowercase();
                        let now_ms = super::types::now_ms();
                        let claim = super::nick_claim::sign(&master_keypair, &nickname, &device_peer_id, now_ms);
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ClaimNickname {
                            nickname,
                            master: local_peer_str.to_string(),
                            claim,
                        });
                    }

                    NodeCommand::ReleaseNickname => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ReleaseNickname);
                    }

                    // -- Multi-device linking --
                    NodeCommand::ClaimLinkCode { rendezvous, secret } => {
                        link_handler::claim(&mut link, &ws_cmd_tx, &rendezvous, &secret);
                    }
                    NodeCommand::ReleaseLinkCode => {
                        link_handler::release(&mut link, &ws_cmd_tx);
                    }
                    NodeCommand::ResolveLinkCode { code, kind } => {
                        if let Err(error) = link_handler::resolve(&mut link, &ws_cmd_tx, &code, &kind) {
                            let _ = event_tx.send(NetworkEvent::LinkFailed { link_id: String::new(), error }).await;
                        }
                    }
                    NodeCommand::AcceptLinkPush { target_peer, include_vault, include_files } => {
                        Box::pin(link_handler::accept(
                            &mut link, &ws_cmd_tx, &event_tx, &master_keypair, &device_keypair,
                            &target_peer, include_vault, include_files, &db_path, &db_passphrase,
                        )).await;
                    }
                    NodeCommand::DeclineLinkPush { target_peer } => {
                        link_handler::decline(&mut link, &ws_cmd_tx, &target_peer);
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
                            &mut olm, &crypto_store,
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &server_states,
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
                            &master_keypair,
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

                    NodeCommand::SetCallPresence { presence } => {
                        if call_book.set_own(presence) {
                            let presence = call_book.own().cloned();
                            hollow_log!("[HOLLOW-CALL] This device is now in {:?}", presence.as_ref().map(|p| p.kind.as_str()));
                            super::olm_lane::carry_to_own_siblings(
                                &ws_cmd_tx, &ws_room_peers, &local_peer_str, &device_peer_id,
                                &HavenMessage::SiblingCallState { presence, ask: false },
                                super::olm_lane::NoSession::Queue,
                            );
                        }
                    }

                    NodeCommand::SyncReadMarkers { markers } => {
                        super::olm_lane::carry_to_own_siblings(
                            &ws_cmd_tx, &ws_room_peers, &local_peer_str, &device_peer_id,
                            &HavenMessage::ReadMarkers { markers },
                            super::olm_lane::NoSession::Queue,
                        );
                    }

                    NodeCommand::SetInvisible { invisible } => {
                        social::handle_set_invisible(
                            &ws_cmd_tx, &ws_room_peers, &server_states, &local_peer_str,
                            invisible, &mut is_invisible, &db_path, &db_passphrase,
                        );
                    }

                    NodeCommand::SubscribeChannels { server_id, channel_ids } => {
                        hollow_log!("[HOLLOW-TOPIC] Subscribe room={server_id} topics={channel_ids:?}");
                        subscribed_channels.insert(server_id.clone(), channel_ids.clone());
                        let owner = server_states.get(&server_id).and_then(|s| s.anchor_owner());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::Subscribe {
                            room_code: server_id.clone(),
                            topics: channel_ids
                                .iter()
                                .map(|cid| super::ring_auth::ring_topic(&server_id, owner.as_deref(), cid))
                                .collect(),
                        });
                        // Relay offline catch-up on CHANNEL OPEN, the safety net for the connect-time
                        // sweep: refresh the ring registration (covering channels created since anyone
                        // last registered) and replay any ring this connection has not pulled.
                        // Dedup-by-message_id makes a re-pull harmless. The watermark lookup awaits the
                        // CrdtStore actor, so the channel list is gathered and the `server_states`
                        // borrow dropped before the await.
                        //
                        // ONLY once we are actually in the room. The relay silently drops both
                        // `set_topic_buffer` and `topic_catchup` from a non-member, while
                        // `relay_catchup_done` would record the pull as done, so the connect-time sweep
                        // skips that channel and nothing replays its ring for the rest of the
                        // connection. Dart subscribes the moment the shell picks a channel, which on a
                        // cold start is well before the socket has joined, so this was the normal path.
                        // `ws_room_peers` holds an entry from the moment the relay answers a join with
                        // its member list, so it says exactly "this socket is in that room".
                        let in_room = ws_room_peers.contains_key(&server_id);
                        let fresh_channels: Vec<String> = match server_states.get(&server_id) {
                            Some(state) if in_room && state.relay_catchup_secs() > 0 => {
                                sync_handler::register_relay_catchup(&ws_cmd_tx, state, &server_id, &master_keypair);
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
                                    channel_id: super::ring_auth::ring_topic(&server_id, owner.as_deref(), &cid),
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

                    // -- Storage pledge --
                    NodeCommand::SetStoragePledge { server_id, pledge_bytes } => {
                        sync_handler::handle_set_storage_pledge(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &mut gossip_overlays, &bundle_keypair, &local_peer_str, &device_peer_id,
                            server_id, pledge_bytes,
                            &crdt_store,
                        ).await;
                    }

                    // -- Vault shard distribution --
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

                    // -- File sharing --
                    NodeCommand::SendFile(box_payload) => {
                        let SendFilePayload { peer_id, server_id, channel_id, file_path, message_id, message_text, vthumb, override_width, override_height, share_ref, voice, poster, album } = *box_payload;
                        file_handler::handle_send_file(
                            peer_id, server_id, channel_id, file_path, message_id, message_text,
                            vthumb, override_width, override_height, share_ref, voice, poster, album,
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
                            final_data, final_ext, width, height, thumb, voice, album, order_us,
                        } = *box_payload;
                        file_handler::finish_send_file(
                            peer_id, server_id, channel_id, message_id, message_text,
                            vthumb, share_ref, original_name, is_image,
                            final_data, final_ext, width, height, thumb, voice, album, order_us,
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
                        // Explicit pull: the response header must pass the size cap and the
                        // auto-download gate (issue #41). The ask table re-stamps both on every retry,
                        // but the rowless path below never reaches the table, so stamp here.
                        requested_file_receipts.insert(file_id.clone(), std::time::Instant::now());
                        declined_file_ids.remove(&file_id);
                        file_handler::handle_request_file(
                            file_id, peer_id_str, chunks,
                            &ws_cmd_tx, &ws_room_peers,
                            &pending_ws_transfers,
                            &server_states, &event_tx,
                            &mut pending_file_asks,
                            &mut requested_file_receipts,
                            &mut declined_file_ids,
                            &local_peer_str, &device_peer_id,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::CancelFileRequest { file_id } => {
                        // Stop waiting: the queued ask and its explicit-pull receipt go together, so an
                        // answer already on its way faces the size cap and the auto-download gate as
                        // the unsolicited push it now is.
                        hollow_log!("[HOLLOW-FILE] Cancelling the pending ask for {file_id}");
                        file_asks::cancel(
                            &mut pending_file_asks,
                            &mut requested_file_receipts,
                            &file_id,
                        );
                    }

                    NodeCommand::RequestPublicFile { server_id, file_id, peer_hint } => {
                        // Guest download: pick ONE live room peer, the hint first (usually the message
                        // sender), else any other peer, which may be another guest that will not
                        // answer. Mirrors the emote-rail peer pick.
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
                                    (server_id.clone(), t.clone(), std::time::Instant::now()),
                                );
                                // The answering PublicFileHeader delegates into the
                                // shared header path — mark it explicitly requested
                                // so the auto-download gate lets it through.
                                requested_file_receipts.insert(file_id.clone(), std::time::Instant::now());
                                hollow_log!("[HOLLOW-GUEST] Requesting public file {file_id} in {server_id} from {t}");
                                super::olm_lane::carry(
                                    &ws_cmd_tx, &t, Some(&server_id),
                                    &HavenMessage::FileRequest { file_id, chunks: Vec::new(), offset: 0 },
                                    super::olm_lane::NoSession::Queue,
                                );
                            }
                            None => {
                                hollow_log!("[HOLLOW-GUEST] No room peer to serve public file {file_id} in {server_id}");
                            }
                        }
                    }

                    // -- WebRTC commands --
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
                            &server_states, &local_peer_str, &db_path, &db_passphrase,
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
                            let _ = tokio::fs::remove_file(&temp_path).await;
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

                    // -- Voice call signaling --
                    NodeCommand::CallSendSignal { peer_id, signal_type, payload } => {
                        last_message_traffic = std::time::Instant::now();
                        voice_handler::handle_call_send_signal(
                            peer_id, signal_type, payload, &mut call_book,
                            &mut olm, &crypto_store, &event_tx,
                            &ws_cmd_tx, &ws_room_peers,
                            &mut key_request_in_flight,
                            &device_keypair, &device_peer_id, &local_peer_str,
                        ).await;
                    }

                    // -- Voice channel commands --
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

                    // Deliberately NOT NodeCommand::JoinRoom: that arm mutates `active_room` and
                    // fires `RoomCleared`, which would wipe the open DM chat. The fwd room is a
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
                    NodeCommand::ConferenceStart { conf_id, nonce, link_key, waiting_room, code_key, host_display_name, host_avatar_hash } => {
                        super::conference::handle_conference_start(
                            &mut conference_host, &mut mls, &crypto_store, &ws_cmd_tx,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &local_peer_str, &device_peer_id, conf_id, nonce, link_key, waiting_room, code_key,
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

                    NodeCommand::ConferenceRequestJoin { conf_id, link_key, display_name, avatar_hash, code_key } => {
                        super::conference::handle_conference_request_join(
                            &mut mls, &crypto_store, &ws_cmd_tx, &device_peer_id,
                            conf_id, link_key, display_name, avatar_hash, code_key,
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
                            &pending_server_joins, &ws_cmd_tx, &ws_room_peers, &device_peer_id, server_id,
                        );
                    }

                    // -- Parked joins: user actions on the pending tile --
                    NodeCommand::DiscardPendingJoin { server_id } => {
                        sync_handler::handle_discard_pending_join(
                            &mut pending_server_joins, &event_tx, &ws_cmd_tx,
                            &mut mls, &crypto_store, server_id, &crdt_store,
                        ).await;
                    }
                    // "Request again": the same code path as the original ask,
                    // with the row's stored consent/proof and a FRESH nonce. The
                    // row is read on the CrdtStore actor rather than opened here.
                    NodeCommand::RequestPendingJoinAgain { server_id } => {
                        match crdt_store.load_pending_join(server_id.clone()).await {
                            Some(row) if row.join_key.is_none() => {
                                hollow_log!("[HOLLOW-CRDT] Request again for {server_id}: the row names no join key");
                                let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
                                    server_id,
                                    state: "rejected".to_string(),
                                    reason: sync_handler::INVITE_OUTDATED.to_string(),
                                }).await;
                            }
                            Some(row) => {
                                sync_handler::handle_join_server(
                                    &mut pending_server_joins, &ws_cmd_tx,
                                    &ws_room_peers, &cmd_tx,
                                    server_id, row.twitch_proof_json, row.nsfw_confirmed, row.owner_pin,
                                    row.join_key.unwrap_or_default(),
                                    &crdt_store, &master_keypair, &device_peer_id,
                                    &mls, &crypto_store, row.key_package, row.reply_secret,
                                    &db_path, &db_passphrase,
                                ).await;
                            }
                            None => {
                                hollow_log!("[HOLLOW-CRDT] Request again for {server_id}: no pending join row, ignoring");
                            }
                        }
                    }

                    // -- Server join timeout --
                    NodeCommand::CheckPendingJoinTimeout { server_id, only_if_empty } => {
                        sync_handler::handle_check_pending_join_timeout(
                            &mut pending_server_joins, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &local_peer_str, &device_peer_id,
                            server_id, only_if_empty,
                            &crdt_store,
                        ).await;
                    }

                    // -- Gossip relay tree commands --
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
                        // A CRDT op arrived over the WebRTC mesh instead of the relay. Dedup by
                        // broadcast_id, then ingest through the EXACT same validated path as a relay
                        // CrdtOpBroadcast, re-flooding the mesh only on op-newness.
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
                                                                &mut join_resolutions,
                                                                &mut awaiting_mls_after_parked_join,
                                                                &crdt_store,
                                &mut pending_sync_requests, &mut mls,
                                &mut mls_bootstrap_requested,
                                &mut mls_welcome_grace,
                                &mut relay_catchup_done,
                                &mut pending_file_streams,
                                &mut pending_shard_streams, &mut early_file_streams,
                                &mut pending_link_snapshots,
                                &mut link,
                                &mut decrypt_fail_cooldown,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                &mut mls_epoch_hint_cooldown,
                                &ws_cmd_tx, &ws_room_peers,
                                &webrtc_peers, &mut pending_webrtc_sends,
                                &mut channel_sync_sent,
                                &mut slow_mode_clock,
                                &mut gossip_overlays,
                                &mut voice_channel_participants,
                                &mut voice_channel_gossip_mode,
                                &mut call_book,
                                &mut conference_host,
                                &mut vc_signal_rate_tokens,
                                &mut mls_dirty,
                                &guest_rooms,
                                &subscribed_channels,
                                &db_path, &db_passphrase,
                                &local_peer_str, &sender_peer_id, is_invisible,
                                &mut pending_friend_accepts, &mut pending_friend_requests,
                                &mut pending_friend_removals,
                                &mut reject_resent,
                                &mut pending_asset_asks,
                                &mut pending_file_asks,
                                &pending_ws_transfers,
                                &mut pending_public_file_requests,
                                &mut requested_file_receipts,
                                &mut declined_file_ids,
                                &mut peer_auto_dl,
                                fwd_bridge,
                                HavenMessage::CrdtOpBroadcast { server_id, op_json },
                                super::frame_auth::now_ms(),
                                &mut None,
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
                            &local_peer_str, &device_peer_id,
                            server_id, token,
                            &db_path, &db_passphrase,
                        ).await;
                    }
                    NodeCommand::StopRecoveryPool { server_id } => {
                        vault_ops::handle_stop_recovery_pool(
                            &mut recovery_pool_state,
                            &event_tx, &ws_cmd_tx, &device_peer_id,
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

                    // TEST-ONLY: snapshot live in-memory MLS/Olm state for the multi-node harness.
                    // These managers are owned by this loop and unreadable from a TestNode; this
                    // reads the SAME live state the production paths use, with no snapshot lag.
                    #[cfg(test)]
                    NodeCommand::TestCarry { device, msg } => {
                        // Built by hand: a modified client puts any type in its envelope.
                        let envelope = MessageEnvelope::Carried { msg, at_ms: super::frame_auth::now_ms() };
                        if let Ok(json) = serde_json::to_string(&envelope) {
                            super::olm_lane::carry_json(&ws_cmd_tx, &device, None, json, super::olm_lane::NoSession::Queue);
                        }
                    }

                    #[cfg(test)]
                    NodeCommand::TestConferenceLine { conf_id, line } => {
                        if let Some(mls_mgr) = mls.as_mut() {
                            super::conference::send_group_line(mls_mgr, &crypto_store, &ws_cmd_tx, &conf_id, &line);
                        }
                    }

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
                            if let Some(id) = olm.session_id(&peer) {
                                snap.olm_session_ids.insert(peer.clone(), id);
                            }
                            snap.olm_sessions.insert(peer, status.to_string());
                        }
                        let mut peers: std::collections::HashSet<String> =
                            std::collections::HashSet::new();
                        for set in ws_room_peers.values() {
                            peers.extend(set.iter().cloned());
                        }
                        snap.room_peers = peers.into_iter().collect();
                        snap.carried = carry_log.clone();
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
                        // Join the personal inbox room showing our roster: a request for an offline
                        // stranger is addressed to their MASTER, which no socket authenticates as, so
                        // the relay buffers it under the master and replays it only to a device its
                        // fold of the master's rosters counts as a member. A waiting device shows it
                        // too, which starts the relay's seven days.
                        {
                            let inbox_room = format!("inbox:{}", local_peer_str);
                            match super::roster_book::own_roster(&local_peer_str, &db_path, &db_passphrase) {
                                Some(roster) => {
                                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinInbox {
                                        room_code: inbox_room,
                                        roster,
                                    });
                                }
                                None => {
                                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                        room_code: inbox_room,
                                    });
                                }
                            }
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: super::roster_book::own_room(&local_peer_str),
                            });
                            // A device our roster does not admit yet asks, on every
                            // connect: the mailbox and the rooms forget.
                            super::roster_book::announce_pending(
                                &ws_cmd_tx, &local_peer_str, &device_peer_id, server_states.keys(),
                                &db_path, &db_passphrase,
                            );
                        }
                        // ASYNC FRIENDING: re-deposit every still-pending outgoing request into the
                        // target's master-keyed mailbox. A target we hold no DEVICE for is unreachable
                        // by any targeted send, so the presence drains never fire for them and the
                        // mailbox is the only leg that reaches someone who is not here. Cheap and
                        // idempotent, and it survives a relay restart clearing the buffer.
                        {
                            let targets: Vec<(String, i64)> = pending_friend_requests
                                .iter()
                                .map(|(k, v)| (k.clone(), *v))
                                .collect();
                            for (target, requested_at) in targets {
                                let target_master = super::resolver::resolve(&target);
                                let msg = social::build_friend_request(
                                    &mut olm, &crypto_store, &master_keypair,
                                    &device_keypair, &device_peer_id,
                                    &target_master, requested_at,
                                    &db_path, &db_passphrase,
                                );
                                social::deposit_friend_request_to_inbox(
                                    &ws_cmd_tx, &target_master, &msg,
                                );
                            }
                        }

                        for server_id in server_states.keys() {
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: server_id.clone(),
                            });
                        }
                        // ...and for every server we are still WAITING to join. A parked join is not a
                        // membership, so the loop above misses it, and being in that room is what makes
                        // both legs of the answer reachable: the relay replays the admitter's buffered
                        // snapshot on the room join, and the `~join` catch-up is gated on membership.
                        // Each such join reads the lock afresh: this relay may hold another one.
                        for (server_id, pending) in pending_server_joins.iter_mut() {
                            pending.lock_asked_at = None;
                            pending.lock_asks.clear();
                            sync_handler::request_join_lock(&ws_cmd_tx, server_id, pending);
                            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                                room_code: server_id.clone(),
                            });
                        }
                        lock_keeper.on_connected(&server_states, &local_peer_str, &ws_cmd_tx);
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
                        // Verify local shard integrity on startup, removing DB records for shards whose
                        // files are missing or corrupt.
                        //
                        // Gated on having servers: opening a `ContentStore` (a SEPARATE SQLCipher
                        // connection running its own page-1 `PRAGMA key` check) while the other
                        // connections are concurrently live raced the codec and logged a harmless
                        // `hmac check failed for pgno=1` on every connect. A node in a server has real
                        // shard data, so the legitimate open does not race.
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
                        // A sibling's call is unknown until it re-announces on reconnect.
                        call_book.clear_siblings();
                        // Asset pulls OUTLIVE the socket — only the record of
                        // who was asked over the dead connection is dropped,
                        // because a new socket means a fresh set of holders.
                        emotes::reset_asked_on_disconnect(&mut pending_asset_asks);
                        // File pulls outlive the socket for the same reason:
                        // the queued Download waits for its holder, and only
                        // what the dead connection told us is dropped.
                        file_asks::reset_on_disconnect(&mut pending_file_asks);
                        pending_public_file_requests.clear();
                        // Explicit-pull receipts die with the socket, since the pending request cannot
                        // be answered on a new connection. `declined_file_ids` deliberately survives:
                        // it reflects the auto-download setting, not connection state.
                        requested_file_receipts.clear();
                        // Advertised auto-download prefs are connection state:
                        // peers re-advertise on rejoin (issue #41 pre-negotiation).
                        peer_auto_dl.clear();
                        relay_catchup_done.clear();
                        // A new socket means a fresh mailbox replay burst, so the
                        // decline re-send is re-armed with it (see `reject_resent`).
                        reject_resent.clear();
                        key_request_in_flight.clear();
                        key_bundle_sent_to.clear();
                        mls_bootstrap_requested.clear();
                        // The grace waits for a Welcome that was in flight on the socket that just
                        // died. Dropping it with the throttle keeps the pair consistent: the new socket
                        // re-bootstraps through the ordinary paths, not a sweep on a stale deadline.
                        mls_welcome_grace.clear();
                        mls_epoch_hint_cooldown.clear();
                        if !pending_messages.is_empty() {
                            hollow_log!("[HOLLOW-WS] Keeping {} pending message queues for delivery after reconnect", pending_messages.len());
                        }
                        // Clean up in-progress WS stream transfers. Resumption infrastructure exists
                        // (the FileRequest offset, seek support in ws_stream_send) but transfer state
                        // is in-memory only, so cross-restart resumption would need persistence.
                        if !pending_ws_transfers.is_empty() {
                            hollow_log!("[HOLLOW-WS] Cleaning up {} in-progress WS transfers", pending_ws_transfers.len());
                            for (id, state) in pending_ws_transfers.drain() {
                                let _ = tokio::fs::remove_file(&state.temp_path).await;
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
                        }
                    }
                    WsEvent::PeerJoined { room, peer_id } => {
                        hollow_log!("[HOLLOW-WS] Peer {peer_id} joined room {room}");
                        if !bare_presence.admits(&peer_id) {
                            hollow_log!("[HOLLOW-SECURITY] {peer_id} joined {room} as a master id its roster does not count: not a device");
                            continue;
                        }
                        ws_room_peers.entry(room.clone()).or_default().insert(peer_id.clone());

                        // A holder we could not reach earlier just turned up:
                        // ask it for anything still pending on the asset rail.
                        emotes::retry_asks_for_peer(
                            &ws_cmd_tx, &ws_room_peers, &mut pending_asset_asks,
                            &room, &peer_id, &local_peer_str,
                        );
                        // A holder for a queued file download may have just
                        // arrived: ask it, and let the card say so.
                        file_asks::retry_asks_for_peer(
                            &ws_cmd_tx, &ws_room_peers, &server_states, &event_tx,
                            &mut pending_file_asks,
                            &mut requested_file_receipts, &mut declined_file_ids,
                            &pending_ws_transfers,
                            &room, &peer_id, &local_peer_str, &device_peer_id,
                        ).await;

                        // Media-forwarder control-plane room: run the MINIMAL path (Olm session plus a
                        // queued fwd envelope drain) and skip the discovery cascade. A forwarder
                        // discards every profile, sync, friend, MLS and DM frame we could send it, so
                        // the cascade was ~45 junk frames per join.
                        //
                        // CRITICAL: this must NOT touch `synced_peers`. That set is GLOBAL, not
                        // per-room, so inserting here burns the `is_new` flag and a LATER join of a
                        // genuinely shared room skips profile and sync forever.
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
                            super::conference::reknock_if_pending(&mut mls, &crypto_store, &ws_cmd_tx, &room);
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
                                        if let Some(bytes) = pool.seal(&device_peer_id, &welcome) {
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

                        if server_states.contains_key(&room) {
                            rebalance_pending.insert(room.clone());
                        }

                        // Voice presence: tell a peer that just (re)appeared in this room which of its
                        // voice channels we are in.
                        //
                        // DELIBERATELY OUTSIDE the `is_new` guard below. `synced_peers` means "have we
                        // synced with this peer at all this session" and is NOT cleared when a peer's
                        // socket dies, because the relay only broadcasts PeerLeft for a CLEAN leave, so
                        // a peer that dropped and came back is `is_new == false` and skips the cascade.
                        // That is exactly the peer that needs this: `WsEvent::Disconnected` purges every
                        // REMOTE participant from `voice_channel_participants`, that set gates EVERY
                        // inbound VC signal, and nothing else refills it, so the reconnecting side
                        // blackholes the offers its own peer sends while its own requests still arrive.
                        //
                        // One small plaintext frame, idempotent at the receiver, and plaintext because
                        // a reconnecting peer's MLS epoch is very likely stale.
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
                                // Anyone with the server id can join its room; only someone
                                // who could see this voice channel learns we sit in it (J3).
                                if server_states.get(&room).is_some_and(|s| {
                                    !s.is_member(&peer_id) || !s.can_see_channel(&peer_id, vc_cid)
                                }) {
                                    continue;
                                }
                                hollow_log!("[HOLLOW-VC] Re-announcing our presence in {vc_cid} to {peer_id} (rejoined the room)");
                                // The room is KNOWN here, so send into it directly
                                // rather than through `ws_room_for_peer` (first-match
                                // is the silent one-way-loss trap).
                                super::olm_lane::carry(
                                    &ws_cmd_tx, &peer_id, Some(&room),
                                    &HavenMessage::VoiceChannelJoin {
                                        server_id: vc_sid.to_string(),
                                        channel_id: vc_cid.to_string(),
                                    },
                                    super::olm_lane::NoSession::Queue,
                                );
                            }
                        }

                            // Update the gossip overlay: add this peer and maybe connect. Multi-device: the
                            // relay reports US under our DEVICE id, which differs from local_peer_str (the
                            // master). Exclude both, or the node key-exchanges and WebRTCs with its OWN
                            // device presence, an endless MAC-mismatch re-key.
                            // Only a member of the server: anyone with its id can join the
                            // room, and a neighbour gets a data channel and the op flood (J2).
                            let is_member = server_states.get(&room).is_some_and(|s| s.is_member(&peer_id));
                            if peer_id != local_peer_str && peer_id != device_peer_id && is_member
                                && let Some(overlay) = gossip_overlays.get_mut(&room)
                                && let Some(new_neighbor) = overlay.add_known_peer(&peer_id)
                            {
                                hollow_log!("[HOLLOW-GOSSIP] New neighbor {new_neighbor} joined server {room}");
                                let _ = event_tx.send(NetworkEvent::GossipConnect { peer_id: new_neighbor }).await;
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

                                // Drain pending friend requests for this peer. The request is keyed by the
                                // TARGET'S MASTER id but the relay reports DEVICE ids, so match the joining
                                // device by resolving device to master (a fresh target we never linked resolves
                                // to itself). Deliver to the concrete device.
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
                                        // The same bundled message the mailbox holds: `build_friend_request` reuses
                                        // the cached bundle, so a live drain and a deposit are the same request and
                                        // the target dedups.
                                        let req_msg = social::build_friend_request(
                                            &mut olm, &crypto_store, &master_keypair,
                                            &device_keypair, &device_peer_id,
                                            &super::resolver::resolve(&target_key), requested_at,
                                            &db_path, &db_passphrase,
                                        );
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, req_msg,
                                        );
                                        // Defense in depth: leave the target's inbox now that the
                                        // request is delivered (ordered after the send). Accept comes
                                        // back via the DM room, not the inbox.
                                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                                            room_code: format!("inbox:{}", target_key),
                                        });
                                    }
                                }

                                // Drain pending friend removals for this peer. The tombstone is keyed by the
                                // friend's MASTER but the relay reports DEVICE ids, so resolve the joining
                                // device to its master to match (a single-device peer resolves to itself).
                                // Deliver the FriendRemove to the concrete device that appeared.
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

                                // (Re)deliver a queued FriendAccept to the requester. The accept can race the
                                // requester's DM-room join, or the requester may have been offline. Idempotent
                                // (the receiver re-saves "accepted"), and the entry is removed on delivery so
                                // it fires at most once per friend per session.
                                {
                                    let joined_master = super::resolver::resolve(&peer_id);
                                    let queued = pending_friend_accepts
                                        .remove(&joined_master)
                                        .or_else(|| pending_friend_accepts.remove(&peer_id));
                                    if let Some(stamp) = queued
                                        && !super::blocklist::is_blocked(&peer_id)
                                        && social::holds_accepted_friend(&db_path, &db_passphrase, &joined_master)
                                    {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared (master {joined_master}), (re)sending FriendAccept");
                                        social::send_friend_accept(
                                            &ws_cmd_tx, &local_peer_str, &master_keypair,
                                            &joined_master, &peer_id, stamp, &db_path, &db_passphrase,
                                        );
                                    }
                                }

                                if is_new {
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers, &server_states,
                                        &local_peer_str, &master_keypair, &peer_id,
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
                                            &ws_cmd_tx, &local_peer_str, &peer_id,
                                        );
                                    }

                                    // A peer in OUR OWN inbox room is our device only when our roster
                                    // says so: a friend-request sender joins our inbox to deliver, and a
                                    // device holding just the master key is nobody's member.
                                    let own_inbox = format!("inbox:{}", local_peer_str);
                                    if room == own_inbox && peer_id != device_peer_id {
                                        if super::resolver::same_identity(&peer_id, &local_peer_str) {
                                            on_verified_sibling(
                                                &ws_cmd_tx, &ws_room_peers, &master_keypair, &local_peer_str, &server_states,
                                                is_invisible, &db_path, &db_passphrase, &peer_id, call_book.own(),
                                            );
                                        } else {
                                            offer_roster(&ws_cmd_tx, &ws_room_peers, &local_peer_str, &peer_id, &db_path, &db_passphrase);
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

                                    // CRDT sync and message sync for shared servers. Members are master-keyed and
                                    // `peer_id` is a DEVICE, so match by identity: a multi-device member's device
                                    // still triggers sync and MLS bootstrap.
                                    for (sid, state) in server_states.iter() {
                                        if state.members.keys().any(|k| super::resolver::same_identity(&peer_id, k)) {
                                            let our_vector = StateVector::from_server_state(state);
                                            if let Ok(sv_json) = serde_json::to_string(&our_vector) {
                                                // Olm, never MLS, for the post-reconnection SyncReq:
                                                // the peer's MLS epoch may be stale, causing silent decrypt failure.
                                                super::olm_lane::carry(
                                                    &ws_cmd_tx, &peer_id, None,
                                                    &HavenMessage::SyncRequest {
                                                        server_id: sid.clone(),
                                                        state_vector_json: sv_json,
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                    },
                                                    super::olm_lane::NoSession::Queue,
                                                );
                                            }

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
                                                    if let Ok(kp_bytes) = crate::node::crypto_handler::mint_key_package(mls_mgr, &crypto_store) {
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

                                    // DM sync. High-water keyed by the friend's MASTER (the conversation key),
                                    // not the raw device id the relay reported, or a multi-device friend's
                                    // timestamp lookup misses and we mis-page the sync.
                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let convo = super::resolver::resolve(&peer_id);
                                            // Multi-device peer-fallback: if WE have a sibling, ask for BOTH
                                            // directions, so a friend re-serves the messages we sent from another,
                                            // possibly offline, device.
                                            let multi_device =
                                                !super::resolver::devices_for(&master_peer_str).is_empty();
                                            let (since, gap) = store.dm_sync_anchor(&convo, multi_device);
                                            // Without a session yet, the one it will form asks on its own
                                            // (`request_dm_resync_after_rekey`).
                                            super::olm_lane::carry(
                                                &ws_cmd_tx, &peer_id, None,
                                                &HavenMessage::DmSyncRequest {
                                                    since_timestamp: since,
                                                    both_directions: multi_device,
                                                    gap,
                                                },
                                                super::olm_lane::NoSession::Drop,
                                            );
                                        }
                                    }

                                }

                                // Send join request if this room matches a pending server join.
                                // Outside is_new guard — peer may already be synced from another room.
                                if let Some(pending) = pending_server_joins.get_mut(&room) {
                                    sync_handler::send_pending_request(&ws_cmd_tx, &room, &device_peer_id, pending, &peer_id);
                                }

                                // DM-room co-presence re-key, outside `is_new` because the peer was already
                                // met in the inbox. A friend-request requester joins the DM room, joins the
                                // target inbox to deliver, then LEAVES the inbox, and its DM-room join may not
                                // have reached the accepter's `ws_room_peers` when the accepter sends its
                                // KeyBundle; that bundle then targets a peer in no shared room and is SILENTLY
                                // DROPPED, so the lower-id side never builds an outbound session. When the
                                // DURABLE DM room becomes mutually populated, re-issue a KeyRequest, bypassing
                                // the in-flight freshness gate: a room transition is exactly the dropped-frame
                                // event the 30s sweep was meant to catch, at sub-second latency. KeyRequest is
                                // idempotent and the glare tiebreaker still arbitrates who creates the session.
                                // `local_peer_str` is the master, so this is the pure f(masters) DM room, which
                                // siblings, server members and guests never share: no key spam.
                                // Gate on `!has_session` (NO session object), never `!has_confirmed_session`:
                                // the wedged side holds no session at all, while a side with an unconfirmed
                                // OUTBOUND session has a handshake in flight that re-keying would tear down.
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
                        // WE left this room: purge its frozen member snapshot from the routing table.
                        // A self-left room receives no further PeerLeft or RoomMembers, so a stale
                        // entry lives forever and the flexible `ws_room_for_peer` first-match can
                        // route targeted sends into it; the relay then drops them because the sender
                        // is not in the room, a silent one-way blackhole that persists until restart.
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

                        if room.starts_with("recovery:") {
                            if let Some(pool) = recovery_pool_state.as_mut() {
                                if room == pool.room_code() && peer_id != local_peer_str {
                                    hollow_log!("[RECOVERY-POOL] Peer {peer_id} left pool");
                                    pool.remove_member(&peer_id);
                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolMemberLeft {
                                        server_id: pool.server_id.clone(),
                                        peer_id: peer_id.clone(),
                                    }).await;
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
                            sibling_left_its_call(&mut call_book, &event_tx, &peer_id).await;
                            let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                                peer_id: peer_id.clone(),
                            }).await;
                        } else {
                            // The peer may genuinely be in those rooms, or they may be STALE entries
                            // from a previous connection of theirs: the relay never sends PeerLeft for
                            // rooms a dead connection abandoned. Re-join them, so the relay answers with
                            // a fresh RoomMembers and that handler purges a peer who is truly gone.
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
                        let peers: Vec<String> = peers.into_iter().filter(|p| bare_presence.admits(p)).collect();
                        let local_peer = local_peer_str.to_string();
                        // Exclude BOTH our master (local_peer) and our DEVICE id: the relay lists us
                        // by our device id, so without this a node keeps its own presence in
                        // ws_room_peers and key-exchanges with ITSELF.
                        let room_set: std::collections::HashSet<String> = peers.iter()
                            .filter(|p| *p != &local_peer && p.as_str() != device_peer_id)
                            .cloned()
                            .collect();
                        // RoomMembers is the relay's AUTHORITATIVE snapshot for this room, so peers
                        // in our old set but missing from it are stale entries from a previous
                        // connection: the relay only broadcasts PeerLeft for rooms a connection is
                        // CURRENTLY in, so they survive a reconnect cycle and pin a peer "online".
                        let vanished: Vec<String> = ws_room_peers.get(&room)
                            .map(|old| old.difference(&room_set).cloned().collect())
                            .unwrap_or_default();

                        // Media-forwarder control-plane room: presence bookkeeping still runs,
                        // because the embedded engine's tolerance depends on it, but the discovery
                        // cascade is skipped. See the PeerJoined arm for the rationale and the two
                        // one-shot flags this must not burn (`synced_peers`, `profile_broadcast_done`).
                        let is_fwd_room = is_forwarder_room(&room);

                        if !is_fwd_room {
                            // Conference waiting room: sweep pending knockers
                            // against the authoritative snapshot (missed PeerLeft).
                            super::conference::retain_pending_in_room(&mut conference_host, &room, &room_set);
                            // Joiner side: peers already present when we (re)join a
                            // conf room we're knocking on — covers reconnects and
                            // "host already there" without waiting for a PeerJoined.
                            if !room_set.is_empty() {
                                super::conference::reknock_if_pending(&mut mls, &crypto_store, &ws_cmd_tx, &room);
                            }
                        }
                        ws_room_peers.insert(room.clone(), room_set);

                        // The authoritative roster is the FIRST moment after a boot at which
                        // anyone is known to be reachable, and the relay's offline ring replays
                        // messages before it arrives, so an ask made then finally gets someone.
                        emotes::retry_asks_in_room(
                            &ws_cmd_tx, &ws_room_peers, &mut pending_asset_asks,
                            &room, &local_peer_str,
                        );
                        // Same for file pulls: after a reconnect the ask table is full of holders
                        // that were unreachable on the old socket, and this roster is the first
                        // moment anybody is known to be reachable again.
                        file_asks::retry_asks_in_room(
                            &ws_cmd_tx, &ws_room_peers, &server_states, &event_tx,
                            &mut pending_file_asks,
                            &mut requested_file_receipts, &mut declined_file_ids,
                            &pending_ws_transfers,
                            &room, &local_peer_str, &device_peer_id,
                        ).await;

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
                                sibling_left_its_call(&mut call_book, &event_tx, &gone).await;
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
                                for pid in &peers {
                                    if pid != &local_peer && pid.as_str() != device_peer_id && state.is_member(pid) {
                                        overlay.add_known_peer(pid);
                                    }
                                }
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
                        // Once per connection per server room: refresh the relay's per-channel ring
                        // registration, then replay whatever buffered while nobody was online.
                        // Replayed frames arrive as ordinary topic messages, so verification,
                        // dedup-by-message_id and CRDT merge make this idempotent with peer sync.
                        // Runs even for a room with zero peers: that is exactly the gap it closes.
                        sync_handler::request_channel_catchups(
                            &ws_cmd_tx, &crdt_store, server_states.get(&room), &room,
                            &local_peer, &master_keypair, &mut relay_catchup_done, "connect",
                        ).await;

                        // -- The JOIN ring (pending joins, rung 1) --
                        // Read once per connection by BOTH roles: a member collects parked
                        // requests and other members' resolutions, a joiner collects the
                        // resolution addressed to it. A joiner is not in `server_states` at all,
                        // which is why this cannot ride the block above. No `max_age`: a join has
                        // no watermark and an old request is exactly the one we want.
                        {
                            let ring_wanted = server_states
                                .get(&room)
                                .is_some_and(|s| s.relay_catchup_secs() > 0)
                                || pending_server_joins.contains_key(&room);
                            if ring_wanted
                                && relay_catchup_done
                                    .insert((room.clone(), super::types::JOIN_TOPIC.to_string()))
                            {
                                hollow_log!("[HOLLOW-TOPIC] Join-ring catch-up request (connect) for {room}");
                                let owner = server_states
                                    .get(&room)
                                    .and_then(|s| s.anchor_owner())
                                    .or_else(|| pending_server_joins.get(&room).and_then(|p| p.owner_pin.clone()));
                                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::TopicCatchup {
                                    room_code: room.clone(),
                                    channel_id: super::ring_auth::ring_topic(&room, owner.as_deref(), super::types::JOIN_TOPIC),
                                    max_age_secs: 0,
                                });
                            }
                        }

                        // A still-parked join of OUR OWN re-deposits its copy, but only on a
                        // 12h interval: the ring is 200 frames shared by everyone joining this
                        // server, so a joiner that flaps every minute would own it within hours.
                        // The live re-send to present peers is free and happens per peer below.
                        if let Some(p) = pending_server_joins.get_mut(&room) {
                            let now = super::types::now_ms();
                            if p.parked && now - p.last_deposited_at >= super::types::REDEPOSIT_INTERVAL_MS {
                                p.last_deposited_at = now;
                                sync_handler::deposit_parked_join(&ws_cmd_tx, &room, &device_peer_id, p);
                                crdt_store.upsert_pending_join(
                                    sync_handler::pending_join_row(&room, p, "pending", ""),
                                );
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

                        // On first RoomMembers, broadcast our profile to all rooms, so peers who were
                        // online while we were offline get the latest. NOT on a fwd room: that would
                        // BURN the one-shot flag on a forwarder that discards profiles.
                        if !is_fwd_room && !profile_broadcast_done {
                            profile_broadcast_done = true;
                            hollow_log!("[HOLLOW-PROFILE] First RoomMembers — broadcasting our profile");
                            // Send our profile to every peer in the room, excluding both our own ids.
                            for pid in &peers {
                                if pid != &local_peer && pid.as_str() != device_peer_id {
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers, &server_states,
                                        &local_peer_str, &master_keypair, pid,
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
                                    social::send_own_profile_to_peer(
                                        &ws_cmd_tx, &ws_room_peers, &server_states,
                                        &local_peer_str, &master_keypair, pid_str,
                                        is_invisible,
                                        &db_path, &db_passphrase,
                                    );

                                    // Auto-download pre-negotiation (issue #41) — the
                                    // RoomMembers twin of the PeerJoined advertise.
                                    if super::resolver::same_identity(pid_str, &local_peer_str)
                                        || room == dm_room_code(&local_peer_str, &super::resolver::resolve(pid_str))
                                    {
                                        file_handler::advertise_auto_dl_pref_to_peer(
                                            &ws_cmd_tx, &local_peer_str, pid_str,
                                        );
                                    }

                                    {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            if let Ok(None) = store.load_profile(pid_str)
                                                && social::profile_audience(&server_states, &local_peer_str, pid_str, &db_path, &db_passphrase) != social::Audience::None
                                            {
                                                hollow_log!("[HOLLOW-PROFILE] No profile for {pid_str} — sending ProfileRequest");
                                                super::olm_lane::carry(&ws_cmd_tx, pid_str, None, &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
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
                                                    if let Ok(Some(_)) = store.load_profile_light(member_id) {
                                                        continue;
                                                    }
                                                    hollow_log!("[HOLLOW-PROFILE] Requesting proxy profile for {member_id} from {pid_str}");
                                                    super::olm_lane::carry(
                                                        &ws_cmd_tx, pid_str, None,
                                                        &HavenMessage::ProfileRequestFor { target_peer_id: member_id.clone() },
                                                        super::olm_lane::NoSession::Queue,
                                                    );
                                                    proxy_count += 1;
                                                }
                                                if proxy_count >= 10 { break; }
                                            }
                                        }
                                    }

                                    for (sid, state) in server_states.iter() {
                                        if state.is_member(pid_str) {
                                            if let Some(sv_json) = sv_cache.get(sid.as_str()) {
                                                super::olm_lane::carry(
                                                    &ws_cmd_tx, pid_str, None,
                                                    &HavenMessage::SyncRequest {
                                                        server_id: sid.clone(),
                                                        state_vector_json: sv_json.clone(),
                                                        // Epoch hint: lets the responder detect
                                                        // us (or itself) stale on first contact.
                                                        mls_epoch: mls.as_ref().and_then(|m| m.epoch(sid).ok()),
                                                    },
                                                    super::olm_lane::NoSession::Queue,
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

                                    // MLS: if we lost our group for any shared server, send a KeyPackage to
                                    // this peer for re-bootstrap. Members are master-keyed and `pid_str` is a
                                    // device, so match by identity.
                                    if let Some(ref mls_mgr) = mls {
                                        for (sid, srv_state) in server_states.iter() {
                                            if !srv_state.members.keys().any(|k| super::resolver::same_identity(pid_str, k)) { continue; }
                                            if mls_mgr.has_group(sid) { continue; }
                                            if mls_bootstrap_requested.get(sid.as_str()).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) { continue; }
                                            hollow_log!("[HOLLOW-MLS] No group for {sid}, sending KeyPackage to {pid_str} for bootstrap (RoomMembers)");
                                            if let Ok(kp_bytes) = crate::node::crypto_handler::mint_key_package(mls_mgr, &crypto_store) {
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

                                    // The friend request / removal / accept drains run OUTSIDE this guard; see below.

                                    // Multi-device sibling convergence on the RECONNECTING side. RoomMembers
                                    // fires on US and lists peers already there, so PeerJoined never fires for
                                    // that sibling on our side. This is the directional half a fresh mnemonic
                                    // link needs: the new EMPTY device joins last, learns of the populated
                                    // sibling here, and is the side that must PULL the snapshot. Membership in
                                    // `inbox:{master}` is not proof: only a member of our roster converges.
                                    {
                                        let own_inbox = format!("inbox:{}", local_peer_str);
                                        if room == own_inbox && pid_str.as_str() != device_peer_id {
                                            if super::resolver::same_identity(pid_str, &local_peer_str) {
                                                on_verified_sibling(
                                                    &ws_cmd_tx, &ws_room_peers, &master_keypair, &local_peer_str, &server_states,
                                                    is_invisible, &db_path, &db_passphrase, pid_str, call_book.own(),
                                                );
                                            } else {
                                                offer_roster(&ws_cmd_tx, &ws_room_peers, &local_peer_str, pid_str, &db_path, &db_passphrase);
                                            }
                                        }
                                    }

                                    // Olm key exchange, pending_messages drain and DM sync. RoomMembers fires
                                    // on the JOINING peer (us) while PeerJoined fires on the EXISTING peer
                                    // (them); without this, DM sync is one-directional.
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
                                            let (since, gap) = store.dm_sync_anchor(&convo, multi_device);
                                            // Without a session yet, the one it will form asks on its own
                                            // (`request_dm_resync_after_rekey`).
                                            super::olm_lane::carry(
                                                &ws_cmd_tx, pid_str, None,
                                                &HavenMessage::DmSyncRequest {
                                                    since_timestamp: since,
                                                    both_directions: multi_device,
                                                    gap,
                                                },
                                                super::olm_lane::NoSession::Drop,
                                            );
                                        }
                                    }

                                }

                                // Friend request / removal / accept drains, OUTSIDE the is_new guard.
                                // CRITICAL for a RE-ADD while the peer stays ONLINE: its device is already
                                // in `synced_peers` from the prior friendship, so `is_new` is false and the
                                // queued re-add FriendRequest would never drain, leaving the peer nothing to
                                // see. The drains are one-shot (`.remove()`), so running them on every
                                // RoomMembers for an already-synced peer is idempotent.
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
                                            let req_msg = social::build_friend_request(
                                                &mut olm, &crypto_store, &master_keypair,
                                                &device_keypair, &device_peer_id,
                                                &super::resolver::resolve(&target_key), requested_at,
                                                &db_path, &db_passphrase,
                                            );
                                            send_message_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                pid_str, req_msg,
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
                                    let queued = pending_friend_accepts
                                        .remove(&joined_master)
                                        .or_else(|| pending_friend_accepts.remove(&pid_str.to_string()));
                                    if let Some(stamp) = queued
                                        && !super::blocklist::is_blocked(pid_str)
                                        && social::holds_accepted_friend(&db_path, &db_passphrase, &joined_master)
                                    {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers (master {joined_master}), (re)sending FriendAccept");
                                        social::send_friend_accept(
                                            &ws_cmd_tx, &local_peer_str, &master_keypair,
                                            &joined_master, pid_str, stamp, &db_path, &db_passphrase,
                                        );
                                    }
                                }

                                // Send join request if this room matches a pending server join.
                                // Outside is_new guard — peer may already be in synced_peers
                                // from a DM room but we still need to send the join request.
                                if let Some(pending) = pending_server_joins.get_mut(&room) {
                                    sync_handler::send_pending_request(&ws_cmd_tx, &room, &device_peer_id, pending, pid_str);
                                }

                                // DM-room co-presence re-key, the RoomMembers twin of the PeerJoined heal
                                // above: depending on join order the wedged side learns of the peer's
                                // DM-room entry here rather than there. See that arm for the full rationale,
                                // including why this gates on `!has_session`, so only the truly wedged side
                                // kicks and not one with an unconfirmed handshake already in flight.
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
                    WsEvent::BinaryDirect { room, from, data } => {
                        // Stream chunks are live and sealed like every frame; a repeated
                        // chunk only fails the file's own integrity check, so they skip
                        // the replay guard a fast transfer would outgrow.
                        let now_ms = super::frame_auth::now_ms();
                        let delivery = super::frame_auth::Delivery::Direct { device: &device_peer_id, master: &local_peer_str };
                        let data = match super::frame_auth::open(&data, &from, &room, delivery, now_ms) {
                            Ok(_) if super::resolver::is_bare_master(&from) => {
                                hollow_log!("[HOLLOW-SECURITY] Dropped a stream chunk from {from}: a master id its roster does not count is no device");
                                continue;
                            }
                            Ok(opened) if from != device_peer_id && !super::frame_auth::is_stale(opened.ts_ms, now_ms) => {
                                opened.body.to_vec()
                            }
                            Ok(_) => {
                                hollow_log!("[HOLLOW-SECURITY] Dropped a stale or self-stamped stream chunk from {from} in {room}");
                                continue;
                            }
                            Err(refusal) => {
                                hollow_log!("[HOLLOW-SECURITY] Dropped a stream chunk from {from} in {room}: {refusal:?}");
                                continue;
                            }
                        };
                        if let Some(completed) = super::ws_stream_transfer::ws_stream_receive(
                            &mut pending_ws_transfers, &from, &data,
                        ) {
                            // Auto-download gate (issue #41): the sender queues its push before our
                            // decline could reach it, so bytes for a declined file are deleted here
                            // instead of being parked forever in early_file_streams.
                            if declined_file_ids.contains(&completed.id) {
                                hollow_log!("[HOLLOW-FILE] Discarding declined pushed stream {} ({} bytes)", completed.id, completed.size);
                                let _ = tokio::fs::remove_file(&completed.temp_path).await;
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
                    WsEvent::KillSignal { blob, issued_at_ms } => {
                        hollow_log!("[HOLLOW-DESTROY] Relay parked order issued_at={issued_at_ms}");
                        destroy::handle_kill_signal(
                            &event_tx, &ws_cmd_tx, &blob, issued_at_ms,
                            &master_peer_str, &device_peer_id, &db_path, &db_passphrase,
                        ).await;
                    }
                    WsEvent::LockChain { server, links, put } => {
                        // A server we are in: keep the relay's chain where ours is.
                        if let Some(state) = server_states.get(&server).filter(|s| s.is_member(&local_peer_str)) {
                            if let Some(payload) = lock_keeper.on_chain(&server, links.clone(), put, state) {
                                sync_handler::author_join_lock_op(
                                    &mut server_states, &mut mls, &ws_cmd_tx, &ws_room_peers, &mut gossip_overlays,
                                    &event_tx, &local_peer_str, &device_peer_id, &crypto_store, &crdt_store, &server, payload,
                                );
                                // Ring control answers to the newest lock: a server's first
                                // lock is what lets its rings be made at all.
                                if let Some(state) = server_states.get(&server).filter(|s| s.relay_catchup_secs() > 0) {
                                    sync_handler::register_relay_catchup(&ws_cmd_tx, state, &server, &master_keypair);
                                }
                            }
                            let next = server_states
                                .get(&server)
                                .and_then(|state| lock_keeper.tick_one(&server, state, &master_keypair, &ws_room_peers, &ws_cmd_tx));
                            if let Some(payload) = next {
                                sync_handler::author_join_lock_op(
                                    &mut server_states, &mut mls, &ws_cmd_tx, &ws_room_peers, &mut gossip_overlays,
                                    &event_tx, &local_peer_str, &device_peer_id, &crypto_store, &crdt_store, &server, payload,
                                );
                            }
                        }
                        // A server we are joining: seal to it, and judge what waited for it.
                        let held = sync_handler::handle_join_lock_chain(
                            &mut pending_server_joins, &ws_cmd_tx, &ws_room_peers, &crdt_store, &device_peer_id, &server, links,
                        );
                        for answer in held {
                            let (from, frame_ts, frame_nonce) = (answer.from.clone(), answer.frame_ts, answer.frame_nonce);
                            let Some(pending) = pending_server_joins.get_mut(&server) else { break };
                            let joining = sync_handler::recent_join_of(pending);
                            let msg = match sync_handler::judge_join_answer(pending, &server, &device_peer_id, &answer) {
                                sync_handler::JoinAnswer::Open(msg) => msg,
                                sync_handler::JoinAnswer::Stale => {
                                    sync_handler::reask_join(&ws_cmd_tx, &ws_room_peers, &crdt_store, &server, &device_peer_id, pending);
                                    continue;
                                }
                                sync_handler::JoinAnswer::Dropped => {
                                    hollow_log!("[HOLLOW-SECURITY] Dropped a held answer to our join of {server} from {from}");
                                    continue;
                                }
                            };
                            let now_ms = super::frame_auth::now_ms();
                            if msg.live_only()
                                && (super::frame_auth::is_stale(frame_ts, now_ms)
                                    || !frame_replays.first_sight(&from, frame_nonce, frame_ts, now_ms))
                            {
                                hollow_log!("[HOLLOW-SECURITY] Dropped a stale or repeated held join answer from {from} in {server}");
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
                                &mut join_resolutions,
                                &mut awaiting_mls_after_parked_join,
                                &crdt_store,
                                &mut pending_sync_requests, &mut mls,
                                &mut mls_bootstrap_requested,
                                &mut mls_welcome_grace,
                                &mut relay_catchup_done,
                                &mut pending_file_streams,
                                &mut pending_shard_streams, &mut early_file_streams,
                                &mut pending_link_snapshots,
                                &mut link,
                                &mut decrypt_fail_cooldown,
                                &mut pending_mls_key_packages, &mut pending_mls_removals,
                                &mut mls_epoch_hint_cooldown,
                                &ws_cmd_tx, &ws_room_peers,
                                &webrtc_peers, &mut pending_webrtc_sends,
                                &mut channel_sync_sent,
                                &mut slow_mode_clock,
                                &mut gossip_overlays,
                                &mut voice_channel_participants,
                                &mut voice_channel_gossip_mode,
                                &mut call_book,
                                &mut conference_host,
                                &mut vc_signal_rate_tokens,
                                &mut mls_dirty,
                                &guest_rooms,
                                &subscribed_channels,
                                &db_path, &db_passphrase,
                                &local_peer_str, &from, is_invisible,
                                &mut pending_friend_accepts, &mut pending_friend_requests,
                                &mut pending_friend_removals,
                                &mut reject_resent,
                                &mut pending_asset_asks,
                                &mut pending_file_asks,
                                &pending_ws_transfers,
                                &mut pending_public_file_requests,
                                &mut requested_file_receipts,
                                &mut declined_file_ids,
                                &mut peer_auto_dl,
                                fwd_bridge,
                                *msg,
                                frame_ts,
                                &mut None,
                            ).await;
                            sync_handler::note_completed_join(&mut recent_joins, &pending_server_joins, &server_states, &local_peer_str, &server, joining);
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
                        // Peer discovery over the live WS connection. Populate ws_room_peers and
                        // proactively key-exchange with any peer we lack a confirmed session for,
                        // reusing the reconciliation sweep's freshness guard so a dropped frame heals.
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
                    WsEvent::NicknameResolved { nickname, peer_id, master_id, claim } => {
                        if pending_nickname_resolve.as_deref() == Some(&nickname) {
                            pending_nickname_resolve = None;
                            // Only a master that signed the claim for the device holding the
                            // nickname counts, and even then the person confirms before any
                            // request goes out. Never fed to `resolver`: that takes only
                            // master-signed device lists.
                            let ev = match super::nick_claim::verified_master(&nickname, &peer_id, &master_id, &claim, super::types::now_ms()) {
                                Some(master_id) => NetworkEvent::NicknameResolved { nickname, master_id },
                                None => {
                                    hollow_log!("[HOLLOW-SECURITY] Nickname {nickname} resolved to a claim its master did not sign");
                                    NetworkEvent::NicknameResolveFailed { nickname, error: "unverified".to_string() }
                                }
                            };
                            let _ = event_tx.send(ev).await;
                        }
                    }
                    // TURN credentials from the authed relay socket feed Dart's
                    // iceConfigProvider.
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
                        // The operator's forwarder is nobody we know: a relay naming a
                        // person's device would send privacy-bound viewers' media legs,
                        // and their addresses, to that person. Dart pins the rest per relay.
                        let known_person = super::resolver::resolve(&peer_id) != peer_id
                            || super::resolver::is_known_master(&peer_id)
                            || peer_id == local_peer_str
                            || peer_id == device_peer_id;
                        if known_person {
                            hollow_log!("[HOLLOW-FWD] Relay advertised a known identity as its forwarder, ignored");
                        } else {
                            let _ = event_tx.send(NetworkEvent::MediaForwarderInfo {
                                peer_id, online,
                            }).await;
                        }
                    }
                    // -- Multi-device link codes --
                    WsEvent::LinkCodeClaimed { code } => {
                        let _ = event_tx.send(NetworkEvent::LinkCodeClaimed { code }).await;
                    }
                    WsEvent::LinkCodeReleased => {}
                    WsEvent::LinkCodeError { error, code } => {
                        link_handler::on_code_error(&mut link, &code);
                        let _ = event_tx.send(NetworkEvent::LinkCodeError { error, code }).await;
                    }
                    WsEvent::LinkCodeResolved { code, peer_id } => {
                        link_handler::on_resolved(&mut link, &ws_cmd_tx, &code, &peer_id);
                    }
                    ws_frame @ (WsEvent::Message { .. } | WsEvent::DirectMessage { .. }) => {
                        let direct = matches!(ws_frame, WsEvent::DirectMessage { .. });
                        let (WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data }) = ws_frame else {
                            continue;
                        };
                        // The relay never hands a device its own frames; one that does is
                        // echoing a genuine seal back to us.
                        if from == device_peer_id {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a frame stamped with our own device in {room}");
                            continue;
                        }
                        let now_ms = super::frame_auth::now_ms();
                        let delivery = if direct {
                            super::frame_auth::Delivery::Direct { device: &device_peer_id, master: &local_peer_str }
                        } else {
                            super::frame_auth::Delivery::Room
                        };
                        let (frame_ts, frame_nonce, data) = match super::frame_auth::open(&data, &from, &room, delivery, now_ms) {
                            Ok(opened) => (opened.ts_ms, opened.nonce, opened.body.to_vec()),
                            Err(refusal) => {
                                hollow_log!("[HOLLOW-SECURITY] Dropped a frame from {from} in {room}: {refusal:?}");
                                continue;
                            }
                        };
                        // A frame that dies here must SAY so with the sender tagged: these
                        // payloads are always HavenMessage JSON (binary chunks ride 0x02).
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
                                    if !super::roster_book::heard_from(&from, &msg) {
                                        hollow_log!("[HOLLOW-SECURITY] Dropped a {} from {from}: a master id its roster does not count is no device", msg.wire_kind());
                                        continue;
                                    }
                                    // Rate limiting (same as libp2p path). Not for our own
                                    // devices: a new sibling's first sync is a legitimate
                                    // burst far past the bucket, and every frame lost there
                                    // is state the new device never gets.
                                    let rate_ok = super::resolver::same_identity(&from, &local_peer_str) || {
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
                                    if msg.live_only()
                                        && (super::frame_auth::is_stale(frame_ts, now_ms)
                                            || !frame_replays.first_sight(&from, frame_nonce, frame_ts, now_ms))
                                    {
                                        hollow_log!("[HOLLOW-SECURITY] Dropped a stale or repeated live frame from {from} in {room}");
                                        continue;
                                    }

                                    // The recovery pool rides sealed under its invite token; a
                                    // plaintext copy falls to the lane check below.
                                    if let HavenMessage::RecoverySealed { nonce, ct } = &msg {
                                        let opened = recovery_pool_state.as_ref().and_then(|p| p.open_control(&room, &from, nonce, ct));
                                        if opened.is_none() {
                                            hollow_log!("[HOLLOW-SECURITY] Dropped a sealed recovery frame from {from} in {room}: not our pool's room, or its token does not open it");
                                        }
                                        if let (Some(inner), Some(pool)) = (opened, recovery_pool_state.as_mut()) {
                                            match inner {
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

                                                        if let Some(our_inv) = pool.members.get(&local_peer_str) {
                                                            let welcome = HavenMessage::RecoveryWelcome {
                                                                manifest_ids: our_inv.manifest_ids.clone(),
                                                                shard_inventory_json: serde_json::to_string(&our_inv.shards).unwrap_or_default(),
                                                            };
                                                            if let Some(bytes) = pool.seal(&device_peer_id, &welcome) {
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
                                                                if let Some(bytes) = pool.seal(&device_peer_id, &msg) {
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

                                                    let status = pool.compute_status();
                                                    let _ = event_tx.send(NetworkEvent::RecoveryPoolStatus {
                                                        server_id: pool.server_id.clone(),
                                                        total_files: status.total_files,
                                                        reconstructable: status.reconstructable,
                                                        partial: status.partial,
                                                        no_shards: status.no_shards,
                                                        progress_pct: status.progress_pct,
                                                    }).await;

                                                    if pool.is_coordinator() && pool.members.len() >= 2 {
                                                        let plan = pool.compute_transfer_plan();
                                                        if !plan.is_empty() {
                                                            hollow_log!("[RECOVERY-POOL] Coordinator: broadcasting transfer plan with {} assignments", plan.len());
                                                            let plan_json = serde_json::to_string(&plan).unwrap_or_default();
                                                            let msg = HavenMessage::RecoveryTransferPlan { plan_json };
                                                            if let Some(bytes) = pool.seal(&device_peer_id, &msg) {
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
                                                HavenMessage::RecoveryTransferPlan { plan_json } => {
                                                    hollow_log!("[RECOVERY-POOL] TransferPlan from {from}");
                                                    // Only the elected coordinator plans, and only for pool members.
                                                    let from_coordinator = pool.members.keys().min() == Some(&from);
                                                    if !from_coordinator {
                                                        hollow_log!("[HOLLOW-SECURITY] Dropped a transfer plan from {from}: not the pool's coordinator");
                                                    }
                                                    if let Some(plan) = serde_json::from_str::<Vec<crate::node::recovery_pool::TransferAssignment>>(&plan_json)
                                                        .ok()
                                                        .filter(|_| from_coordinator)
                                                    {
                                                        hollow_log!("[RECOVERY-POOL] Processing {} transfer assignments", plan.len());

                                                        let vault_dir_r = crate::identity::data_dir().unwrap_or_default().join("vault");

                                                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir_r) {
                                                            for assignment in &plan {
                                                                if assignment.dest_peer == local_peer_str {
                                                                    if let Some(meta) = pool.manifest_meta.get(&assignment.content_id) {
                                                                        let key = format!("{}:{}", assignment.content_id, assignment.shard_index);
                                                                        let sk = crate::vault::content_store::shard_key(&assignment.content_id, assignment.shard_index);
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

                                                                if assignment.source_peer == local_peer_str
                                                                    && pool.members.contains_key(&assignment.dest_peer)
                                                                {
                                                                    let sk = crate::vault::content_store::shard_key(&assignment.content_id, assignment.shard_index);
                                                                    if let Ok(shard_bytes) = cs.read_shard_unchecked(&pool.server_id, &sk) {
                                                                        let temp_dir = std::env::temp_dir().join("hollow_recovery");
                                                                        let _ = tokio::fs::create_dir_all(&temp_dir).await;
                                                                        let temp_path = temp_dir.join(format!("{}_{}.shard",
                                                                            crypto_handler::clip_bytes(&assignment.content_id, 8),
                                                                            assignment.shard_index));
                                                                        if tokio::fs::write(&temp_path, &shard_bytes).await.is_ok() {
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
                                                                            let _ = tokio::fs::remove_file(&temp_path).await;

                                                                            let received_msg = HavenMessage::RecoveryShardReceived {
                                                                                content_id: assignment.content_id.clone(),
                                                                                shard_index: assignment.shard_index,
                                                                            };
                                                                            if let Some(bytes) = pool.seal(&device_peer_id, &received_msg) {
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

                                    // Share control rides sealed under its link key; a plaintext copy
                                    // falls to the lane check below.
                                    if let HavenMessage::ShareSealed { root_hash, nonce, ct } = &msg {
                                        match super::share_handler::open_control(&share_registry, &room, root_hash, nonce, ct) {
                                            Some(HavenMessage::ShareManifestRequest { root_hash }) => {
                                                super::share_handler::handle_envelope_share_manifest_request(
                                                    &mut share_registry, &ws_cmd_tx, &from, root_hash,
                                                ).await;
                                            }
                                            Some(HavenMessage::ShareManifestResponse { root_hash, manifest_b64 }) => {
                                                super::share_handler::handle_envelope_share_manifest_response(
                                                    &mut share_registry, &bundle_keypair, &event_tx, root_hash, manifest_b64,
                                                ).await;
                                            }
                                            Some(HavenMessage::ShareHave { root_hash, bitmap_b64, chunk_count }) => {
                                                super::share_handler::handle_envelope_share_have(
                                                    &mut share_registry, &from, root_hash, bitmap_b64, chunk_count,
                                                ).await;
                                            }
                                            Some(HavenMessage::ShareChunkRequest { root_hash, indices }) => {
                                                super::share_handler::handle_envelope_share_chunk_request(
                                                    &mut share_registry, &mut seed_budget, &bundle_keypair, &ws_cmd_tx,
                                                    &event_tx, &webrtc_share_peers, &from, root_hash, indices,
                                                ).await;
                                            }
                                            Some(HavenMessage::ShareChunkResponse { root_hash, index, data_b64 }) => {
                                                super::share_handler::handle_envelope_share_chunk_response(
                                                    &mut share_registry, &bundle_keypair, &event_tx, root_hash, index, data_b64,
                                                ).await;
                                            }
                                            _ => hollow_log!("[HOLLOW-SECURITY] Dropped a sealed share frame from {from} in {room}: not a share we hold, or the link key does not open it"),
                                        }
                                        continue;
                                    }

                                    // The join lane: sealed to the server's door and invite key, or to our
                                    // reply key from its door, in that server's room. What it holds is judged
                                    // as a frame of its own.
                                    let mut joining: Option<RecentJoin> = None;
                                    let msg = if let HavenMessage::JoinSealed { eph, ct, n, door } = &msg {
                                        let as_member = server_states.get(&room).and_then(|s| {
                                            let invite = s.join_secret()?;
                                            super::join_lane::open_for_members(&invite, &s.join_lock.door_secrets(*n), &room, &from, *n, eph, ct)
                                        });
                                        let held = HeldAnswer {
                                            arrived_at: std::time::Instant::now(),
                                            from: from.clone(), eph: eph.clone(), ct: ct.clone(), n: *n, door: door.clone(), frame_ts, frame_nonce,
                                        };
                                        let opened = match (as_member, pending_server_joins.get_mut(&room)) {
                                            (Some(inner), _) => Some(inner),
                                            (None, Some(pending)) => {
                                                if sync_handler::hold_join_answer(&ws_cmd_tx, &room, pending, held) {
                                                    hollow_log!("[HOLLOW-CRDT] Holding an answer to our join of {room} from {from} until the relay shows its lock");
                                                    continue;
                                                }
                                                None
                                            }
                                            (None, None) => sync_handler::recent_join_answer(&mut recent_joins, &room, &device_peer_id, &held),
                                        };
                                        let Some(inner) = opened else {
                                            hollow_log!("[HOLLOW-SECURITY] Dropped a sealed join frame from {from} in {room}: no key of ours opens it, or it holds what that box may not carry");
                                            continue;
                                        };
                                        if inner.live_only()
                                            && (super::frame_auth::is_stale(frame_ts, now_ms)
                                                || !frame_replays.first_sight(&from, frame_nonce, frame_ts, now_ms))
                                        {
                                            hollow_log!("[HOLLOW-SECURITY] Dropped a stale or repeated live join frame from {from} in {room}");
                                            continue;
                                        }
                                        inner
                                    } else if let HavenMessage::MeetingSealed { nonce, ct } = &msg {
                                        // The meeting lane: sealed under the meeting link's key, in that
                                        // meeting's room, for the device that sealed it.
                                        let opened = super::conference::meeting_key_for_room(&conference_host, &room)
                                            .and_then(|key| super::conference::open_meeting(&key, &room, &from, nonce, ct));
                                        let Some(inner) = opened else {
                                            hollow_log!("[HOLLOW-SECURITY] Dropped a sealed meeting frame from {from} in {room}: no link key of ours opens it");
                                            continue;
                                        };
                                        inner
                                    } else if msg.lane() != Lane::Relay {
                                        // Claim C-24: what the relay must not read never counts in the clear.
                                        hollow_log!("[HOLLOW-SECURITY] Dropped a plaintext {} from {from}: it rides Olm only", msg.wire_kind());
                                        continue;
                                    } else {
                                        msg
                                    };
                                    let mut next = Some((Box::new(msg), frame_ts));
                                    while let Some((msg, frame_ts)) = next.take() {
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
                                                                                    &mut join_resolutions,
                                                                                    &mut awaiting_mls_after_parked_join,
                                                                                    &crdt_store,
                                            &mut pending_sync_requests, &mut mls,
                                            &mut mls_bootstrap_requested,
                                            &mut mls_welcome_grace,
                                            &mut relay_catchup_done,
                                            &mut pending_file_streams,
                                            &mut pending_shard_streams, &mut early_file_streams,
                                            &mut pending_link_snapshots,
                                            &mut link,
                                            &mut decrypt_fail_cooldown,
                                            &mut pending_mls_key_packages, &mut pending_mls_removals,
                                            &mut mls_epoch_hint_cooldown,
                                            &ws_cmd_tx, &ws_room_peers,
                                            &webrtc_peers, &mut pending_webrtc_sends,
                                            &mut channel_sync_sent,
                                            &mut slow_mode_clock,
                                            &mut gossip_overlays,
                                            &mut voice_channel_participants,
                                            &mut voice_channel_gossip_mode,
                                            &mut call_book,
                                            &mut conference_host,
                                            &mut vc_signal_rate_tokens,
                                            &mut mls_dirty,
                                            &guest_rooms,
                                            &subscribed_channels,
                                            &db_path, &db_passphrase,
                                            &local_peer_str, &from, is_invisible,
                                            &mut pending_friend_accepts, &mut pending_friend_requests,
                                            &mut pending_friend_removals,
                                            &mut reject_resent,
                                            &mut pending_asset_asks,
                                            &mut pending_file_asks,
                                            &pending_ws_transfers,
                                            &mut pending_public_file_requests,
                                            &mut requested_file_receipts,
                                            &mut declined_file_ids,
                                            &mut peer_auto_dl,
                                            fwd_bridge,
                                            *msg,
                                            frame_ts,
                                        &mut next,
                                        ).await;
                                    }
                                    sync_handler::note_completed_join(&mut recent_joins, &pending_server_joins, &server_states, &local_peer_str, &room, joining);
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
                // Owner checkpoints (design E): one comparison per server when none is due.
                sync_handler::author_due_checkpoints(
                    &mut server_states, &mut mls, &ws_cmd_tx, &ws_room_peers,
                    &mut gossip_overlays, &event_tx, &local_peer_str, &crypto_store, &crdt_store,
                ).await;
                sync_handler::author_missing_join_keys(
                    &mut server_states, &mut mls, &ws_cmd_tx, &ws_room_peers,
                    &mut gossip_overlays, &event_tx, &local_peer_str, &crypto_store, &crdt_store,
                );
                // The join lock: made, moved, put back, compacted and granted where due.
                for (server_id, payload) in lock_keeper.tick(&server_states, &master_keypair, &ws_room_peers, &ws_cmd_tx) {
                    sync_handler::author_join_lock_op(
                        &mut server_states, &mut mls, &ws_cmd_tx, &ws_room_peers, &mut gossip_overlays,
                        &event_tx, &local_peer_str, &device_peer_id, &crypto_store, &crdt_store, &server_id, payload,
                    );
                }
                sync_handler::reask_join_locks(&mut pending_server_joins, &ws_cmd_tx);
                if let Some(ref mut mls_mgr) = mls {
                    // Phase 0: the Welcome grace. A commit that evicted our own leaf while we
                    // are still a member is half of a remove + re-add, and the Welcome half is
                    // normally a few hundred ms behind, so asking for a leaf on the removal
                    // alone turns one heal into an epoch treadmill. The eviction only ARMS this;
                    // we ask here, once, if the Welcome never came. Before phase 1, so a
                    // KeyPackage it sends is processed by the committer's NEXT tick.
                    if !mls_welcome_grace.is_empty() {
                        let elapsed: Vec<String> = mls_welcome_grace
                            .iter()
                            .filter(|(_, t)| t.elapsed() >= crate::node::crypto_handler::MLS_WELCOME_GRACE)
                            .map(|(k, _)| k.clone())
                            .collect();
                        for group_key in elapsed {
                            mls_welcome_grace.remove(&group_key);
                            if mls_mgr.has_group(&group_key) {
                                continue; // the Welcome landed after all
                            }
                            let (sid, cid) = crate::crypto::split_group_key(&group_key);
                            let Some(state) = server_states.get(&sid) else { continue };
                            let still_eligible = state.members.keys()
                                .any(|m| super::resolver::same_identity(m, &local_peer_str))
                                && match &cid {
                                    Some(c) => state.can_see_channel(&local_peer_str, c),
                                    None => true,
                                };
                            if !still_eligible { continue; }
                            hollow_log!("[HOLLOW-MLS] Welcome grace elapsed for {group_key}, requesting bootstrap");
                            let requested = match &cid {
                                Some(c) => {
                                    crate::node::crypto_handler::request_subgroup_bootstrap(
                                        mls_mgr, &crypto_store, &ws_cmd_tx, &ws_room_peers,
                                        state, &sid, c, &local_peer_str,
                                    );
                                    true
                                }
                                None => crate::node::crypto_handler::request_server_group_bootstrap(
                                    mls_mgr, &crypto_store, &ws_cmd_tx, &ws_room_peers,
                                    state, &sid, &local_peer_str,
                                ),
                            };
                            if requested {
                                mls_bootstrap_requested.insert(group_key, std::time::Instant::now());
                            }
                        }
                    }

                    // Phase 0b: a member with no copy of its server group asks again once
                    // the throttle lapses. A first ask can be lost (it outruns the roster
                    // that lets its receiver place us), and with no channel traffic nothing
                    // else would ever ask, leaving a new device unable to read the server.
                    let leafless: Vec<String> = server_states.iter()
                        .filter(|(sid, state)| {
                            !state.is_deleted()
                                && !super::conference::is_conference_sid(sid)
                                && state.members.contains_key(&local_peer_str)
                                && !mls_mgr.has_group(sid)
                                && !pending_server_joins.contains_key(*sid)
                                && !mls_welcome_grace.contains_key(*sid)
                                && mls_bootstrap_requested.get(*sid).is_none_or(|t| t.elapsed() >= MLS_BOOTSTRAP_TIMEOUT)
                        })
                        .map(|(sid, _)| sid.clone())
                        .collect();
                    for sid in leafless {
                        let Some(state) = server_states.get(&sid) else { continue };
                        if crate::node::crypto_handler::request_server_leaf(
                            mls_mgr, &crypto_store, &ws_cmd_tx, &ws_room_peers, state, &sid,
                            &local_peer_str, &device_peer_id,
                        ) {
                            mls_bootstrap_requested.insert(sid, std::time::Instant::now());
                        }
                    }

                    // Phase 1: our own leaves that predate binding. Before any commit of
                    // ours, since receivers refuse commits from an unbound leaf.
                    crate::node::crypto_handler::rebind_unbound_leaves(
                        mls_mgr, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                        &server_states, &mut mls_bootstrap_requested, &local_peer_str,
                    ).await;

                    // Phase 2: ONE commit per group for every queued removal and add. A
                    // current member's leaf leaves only alongside a re-add of its device,
                    // exactly what receivers accept; the rest waits for its KeyPackage.
                    let mut group_keys: Vec<String> = pending_mls_removals.keys()
                        .chain(pending_mls_key_packages.keys())
                        .cloned()
                        .collect();
                    group_keys.sort();
                    group_keys.dedup();
                    let ourselves = crate::crypto::LeafIdentity {
                        device: device_peer_id.clone(),
                        master: local_peer_str.clone(),
                    };
                    for group_key in group_keys {
                        let queued_removals = pending_mls_removals.remove(&group_key).unwrap_or_default();
                        // The newest KeyPackage per device wins.
                        let mut queued_adds: Vec<(String, Vec<u8>)> = Vec::new();
                        for (peer_id, kp_bytes) in pending_mls_key_packages.remove(&group_key).unwrap_or_default() {
                            queued_adds.retain(|(p, _)| p != &peer_id);
                            queued_adds.push((peer_id, kp_bytes));
                        }
                        let (server_id, channel_id) = crate::crypto::split_group_key(&group_key);
                        let Some(state) = server_states.get(&server_id) else { continue };
                        let rules = super::mls_authority::GroupRules::Server {
                            state, channel: channel_id.as_deref(),
                        };
                        let (removals, adds) = super::mls_authority::plan_membership(
                            &mls_mgr.group_leaves(&group_key), &queued_removals, queued_adds,
                            &ourselves, &rules,
                        );
                        if removals.is_empty() && adds.is_empty() {
                            continue;
                        }
                        hollow_log!("[HOLLOW-MLS] Committing for {group_key}: remove {removals:?}, add {} KeyPackage(s)", adds.len());
                        let done = match mls_mgr.commit_membership(&group_key, &removals, &adds) {
                            Ok(done) => done,
                            Err(e) => {
                                hollow_log!("[HOLLOW-MLS] Membership commit failed for {group_key}: {e}");
                                continue;
                            }
                        };
                        if let Err(e) = mls_mgr.merge_pending_commit(&group_key) {
                            hollow_log!("[HOLLOW-MLS] Failed to merge membership commit: {e}");
                            continue;
                        }
                        persist_mls_state(mls_mgr, &crypto_store);
                        // Rotate SFrame for the remaining participants. A restricted voice
                        // channel keys off its SUBGROUP, so a removal there must re-key the
                        // channel's voice cryptor or the removed member keeps decoding audio.
                        if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                            let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                server_id: server_id.clone(), epoch, sframe_key,
                                channel_id: channel_id.clone(),
                            }).await;
                        }

                        if let Some(welcome_bytes) = &done.welcome {
                            let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(welcome_bytes);
                            let welcome_data = serde_json::to_vec(&HavenMessage::MlsWelcome {
                                server_id: server_id.clone(),
                                welcome: welcome_b64.clone(),
                                channel_id: channel_id.clone(),
                                conf_nonce: None,
                            }).unwrap_or_default();
                            for peer_id_str in &done.added {
                                if peer_is_reachable(&ws_room_peers, peer_id_str) {
                                    send_raw_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        peer_id_str, welcome_data.clone(),
                                    );
                                } else {
                                    // The device is not here. Rung 2 admits a PARKED joiner and
                                    // seats its leaf in the same batch, so the common case is a
                                    // Welcome for somebody offline for days. Addressed into the
                                    // server room by NAME, which the relay buffers under the target
                                    // device and replays on its next join of that room: the same
                                    // device-keyed FIFO queue the snapshot and the SyncResponse
                                    // ride, so the Welcome lands AFTER the SyncResponse.
                                    send_message_to_peer_in_room(
                                        &ws_cmd_tx, &server_id,
                                        peer_id_str, HavenMessage::MlsWelcome {
                                            server_id: server_id.clone(),
                                            welcome: welcome_b64.clone(),
                                            channel_id: channel_id.clone(),
                                            conf_nonce: None,
                                        },
                                    );
                                    hollow_log!("[HOLLOW-MLS] Buffered the Welcome for absent device {peer_id_str} in room {server_id} ({group_key})");
                                }
                            }
                        }

                        // Tier 1 (large-server scaling): ONE room broadcast for the commit,
                        // whose bytes are identical for every recipient. The devices it adds
                        // skip it via the epoch guard; the ones it removes find themselves
                        // evicted.
                        let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&done.commit);
                        let commit_epoch = mls_mgr.epoch(&group_key).ok();
                        crate::node::crypto_handler::broadcast_mls_commit(
                            mls_mgr, &ws_cmd_tx, &server_id, channel_id.clone(),
                            commit_b64, commit_epoch,
                        );
                        hollow_log!("[HOLLOW-MLS] Membership commit for {group_key}: removed {:?}, added {:?}", done.removed, done.added);

                        // Coordinator side: request channel sync FROM each recovered peer.
                        // During the stale epoch the coordinator may have dropped messages
                        // that peer sent, so syncing from them fills the gap on this side.
                        if !done.added.is_empty()
                            && let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase)
                        {
                            let sync_cids: Vec<String> = match &channel_id {
                                Some(cid) => vec![cid.clone()],
                                None => state.channels.keys().cloned().collect(),
                            };
                            for peer_id_str in &done.added {
                                if !peer_is_reachable(&ws_room_peers, peer_id_str) { continue; }
                                for cid in &sync_cids {
                                    super::olm_lane::carry(
                                        &ws_cmd_tx, peer_id_str, None,
                                        &sync_handler::channel_sync_request(&store, &server_id, cid, true),
                                        super::olm_lane::NoSession::Queue,
                                    );
                                }
                            }
                        }
                    }

                    // Phase 3: commits and Welcomes held because our view was behind get
                    // judged again, now that the ops they waited for may have landed.
                    for group_key in mls_mgr.held_group_keys() {
                        let (server_id, channel_id) = crate::crypto::split_group_key(&group_key);
                        let host = mls_mgr.pinned_committer(&group_key).map(str::to_string);
                        let retried = mls_mgr.retry_held_commit(&group_key, |facts| {
                            super::mls_authority::judge_commit(
                                &server_states, &server_id, channel_id.as_deref(), host.as_deref(), facts,
                            )
                        });
                        match retried {
                            Some(Ok(crate::crypto::Verdict::Accept)) => {
                                hollow_log!("[HOLLOW-MLS] Held commit for {group_key} now passes, merged");
                                let outcome = crate::node::crypto_handler::after_commit_merged(
                                    mls_mgr, &crypto_store, &server_states, &mut mls_bootstrap_requested,
                                    &event_tx, &local_peer_str, &server_id, &group_key, &channel_id,
                                ).await;
                                if matches!(outcome, crate::node::crypto_handler::CommitApplyOutcome::Evicted) {
                                    mls_welcome_grace.insert(group_key.clone(), std::time::Instant::now());
                                }
                            }
                            Some(Ok(crate::crypto::Verdict::Refuse(reason))) => {
                                hollow_log!("[HOLLOW-MLS] Held commit for {group_key} dropped: {reason}");
                            }
                            Some(Err(e)) => hollow_log!("[HOLLOW-MLS] Held commit for {group_key} failed to merge: {e}"),
                            Some(Ok(crate::crypto::Verdict::Hold(_))) | None => {}
                        }

                        let requests = super::mls_authority::LeafRequests {
                            bootstrap_requested: &mls_bootstrap_requested,
                            welcome_grace: &mls_welcome_grace,
                            awaiting_parked_join: &awaiting_mls_after_parked_join,
                            join_pending: pending_server_joins.contains_key(&server_id),
                            answered: mls_mgr.key_request_answered(&group_key),
                        };
                        let mut sender: Option<crate::crypto::LeafIdentity> = None;
                        let retried = mls_mgr.retry_held_welcome(&group_key, |facts| {
                            sender = facts.sender.bound().cloned();
                            let asked = super::mls_authority::asked_for_leaf(
                                &group_key, &server_id, sender.as_ref().map(|s| s.master.as_str()), &requests,
                            );
                            super::mls_authority::judge_welcome(
                                &server_states, &server_id, channel_id.as_deref(), None, asked, facts,
                            )
                        });
                        match retried {
                            Some(Ok(crate::crypto::Verdict::Accept)) => {
                                hollow_log!("[HOLLOW-MLS] Held Welcome for {group_key} now passes, joined");
                                let sync_peer = sender.as_ref().map(|s| s.device.clone()).unwrap_or_default();
                                after_welcome_joined(
                                    mls_mgr, &master_keypair, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                                    &crdt_store, &server_states, &mut mls_bootstrap_requested,
                                    &mut mls_welcome_grace, &mut awaiting_mls_after_parked_join,
                                    &mut relay_catchup_done, &db_path, &db_passphrase, &local_peer_str,
                                    &sync_peer, &server_id, &channel_id, &group_key,
                                    sender.as_ref().map(|s| s.master.as_str()),
                                ).await;
                            }
                            Some(Ok(crate::crypto::Verdict::Refuse(reason))) => {
                                hollow_log!("[HOLLOW-SECURITY] Held Welcome for {group_key} dropped: {reason}");
                                persist_mls_state(mls_mgr, &crypto_store);
                            }
                            Some(Err(e)) => hollow_log!("[HOLLOW-MLS] Held Welcome for {group_key} failed to install: {e}"),
                            Some(Ok(crate::crypto::Verdict::Hold(_))) | None => {}
                        }
                    }

                    // Phase 4: co-members who never met (a join one of us slept through)
                    // place each other here. Our group certifies the device, the CRDT
                    // the master; the leaf, the ops and the presence land in any order.
                    let mut candidates: Vec<(String, String)> = Vec::new();
                    let sweep_due = co_member_swept.elapsed() >= CO_MEMBER_SWEEP_EVERY;
                    if sweep_due {
                        co_member_swept = std::time::Instant::now();
                        co_member_introductions.retain(|_, t| t.elapsed() < CO_MEMBER_INTRO_RETRY);
                    }
                    let leaves = if sweep_due {
                        certified_co_member_leaves(mls_mgr, &server_states, &local_peer_str)
                    } else {
                        Vec::new()
                    };
                    for (server_id, leaf) in leaves {
                        if candidates.len() >= CO_MEMBER_INTRO_BATCH {
                            break;
                        }
                        let here = ws_room_peers.get(&server_id).is_some_and(|room| room.contains(&leaf.device));
                        let recent = co_member_introductions
                            .get(&leaf.device)
                            .is_some_and(|t| t.elapsed() < CO_MEMBER_INTRO_RETRY);
                        if !here || recent {
                            continue;
                        }
                        co_member_introductions.insert(leaf.device.clone(), std::time::Instant::now());
                        candidates.push((leaf.device, leaf.master));
                    }
                    if !candidates.is_empty() {
                        let (tx, kp, me) = (ws_cmd_tx.clone(), master_keypair.clone(), local_peer_str.clone());
                        let (path, pass, invisible) = (db_path.clone(), db_passphrase.clone(), is_invisible);
                        tokio::task::spawn_blocking(move || {
                            for device in social::co_members_to_introduce(candidates, &path, &pass) {
                                social::introduce_to_co_member(&tx, &kp, &me, &device, invisible, &path, &pass);
                            }
                        });
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

            _ = rebootstrap_timer.tick() => {
                arm_started = Some(("timer", "rebootstrap", std::time::Instant::now()));
                frame_replays.prune(super::frame_auth::now_ms());
                // Primary peer discovery rides the LIVE WS connection, with no fresh TLS
                // handshake. The HTTP bootstrap below is a non-fatal legacy fallback; its
                // failures are logged quietly and never surfaced.
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

                // -- Olm session reconciliation sweep (self-heal) --
                // The relay never ACKs a direct message, so a dropped KeyRequest, KeyBundle,
                // SessionAck or PreKey would strand the handshake until BOTH peers restart.
                // For every online peer we have a relationship with but NO confirmed Olm
                // session, resend a KeyRequest once the prior request goes stale.
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
                    // Accepted-friend masters, built once per sweep. BACKSTOP for the
                    // friend-handshake Olm wedge: the side that DEFERRED on glare holds NO
                    // session object at all, and a freshly-friended peer is not a server member,
                    // so a wedged friend with no queued DM would otherwise never be swept.
                    // Master-keyed, so a sibling resolves to our own master and is excluded.
                    let accepted_friends: std::collections::HashSet<String> =
                        crate::storage::MessageStore::open(&db_path, &db_passphrase)
                            .ok()
                            .and_then(|s| s.load_friends(Some("accepted")).ok())
                            .map(|v| v.into_iter().map(|(pid, ..)| pid).collect())
                            .unwrap_or_default();
                    for peer in &online {
                        // Only reconcile peers we actually have a relationship with: a shared-server
                        // member, an accepted friend, a peer with queued DMs, or one with a
                        // half-built session. Avoids spamming co-room strangers such as guests.
                        let is_member = server_states.values()
                            .any(|s| s.is_member(peer));
                        let is_friend = accepted_friends.contains(&super::resolver::resolve(peer));
                        let has_pending = pending_messages.contains_key(peer);
                        let half_session = olm.has_unconfirmed_session(peer);
                        if !(is_member || is_friend || has_pending || half_session) {
                            continue;
                        }
                        if olm.has_confirmed_session(peer) {
                            continue;
                        }
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
                    // Clean up orphaned early-arrival file streams (5 min TTL).
                    let mut stale_early: Vec<String> = Vec::new();
                    for (id, (tp, _, _)) in early_file_streams.iter() {
                        let stale = match tokio::fs::metadata(tp).await.and_then(|m| m.modified()) {
                            Ok(t) => t.elapsed().unwrap_or_default() >= Duration::from_secs(300),
                            Err(_) => true,
                        };
                        if stale {
                            stale_early.push(id.clone());
                        }
                    }
                    for id in &stale_early {
                        if let Some((tp, _, _)) = early_file_streams.remove(id) {
                            let _ = tokio::fs::remove_file(&tp).await;
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

                            // A ChannelSyncRequest over Olm rather than an MLS ChannelProbe: an MLS
                            // probe silently fails at a stale epoch after reconnection, so sync never
                            // completes. The response handler uses MLS if available, Olm otherwise.
                            let request = match sync_store.as_ref() {
                                Some(store) => sync_handler::channel_sync_request(store, server_id, channel_id, true),
                                None => HavenMessage::ChannelSyncRequest {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    since_timestamp: *our_latest,
                                    sender_timestamps: HashMap::new(),
                                    gap: None,
                                },
                            };
                            super::olm_lane::carry(&ws_cmd_tx, &peer_str, None, &request, super::olm_lane::NoSession::Queue);
                        }
                    }

                    let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
                        server_id: server_id.clone(),
                        peer_id: "fan-out".to_string(),
                    }).await;
                }

                sync_coordinator.cleanup_stale();
            }

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
                crdt_store.prune_legacy_ops(
                    server_states.iter()
                        .filter(|(_, s)| s.anchor() == crate::crdt::server_state::Anchor::Legacy)
                        .map(|(id, _)| id.clone())
                        .collect(),
                    1000,
                );
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
                                    let _ = cs.delete_placements(server_id, &manifest.content_id);
                                    let _ = cs.delete_manifest(&manifest.content_id);
                                }
                            }

                            // 2b. Retention for channel files not tracked by vault manifests
                            // (full-replication servers under 6 members, or any channel file in files/).
                            // Rows we never FETCHED come back here too: only the ones that reached disk
                            // have a path to delete, but EVERY row past the window is marked, so a card
                            // the user never downloaded reads as removed by retention instead of asking
                            // holders that deleted it for the same reason.
                            let prefix = format!("{}:", server_id);
                            if let Ok(files) = cs.find_expirable_channel_files(&prefix, cutoff) {
                                for (file_id, disk_path) in &files {
                                    hollow_log!("[HOLLOW-VAULT] Retention: expiring channel file {}", file_id);
                                    if let Some(path) = disk_path {
                                        let _ = crate::node::at_rest::remove(std::path::Path::new(path));
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
                                // Absent = PERMANENT. A year of a busy server's text is a few
                                // megabytes, and a community losing its first year one morning is
                                // the "where did it go" feeling Hollow exists to remove.
                                .unwrap_or_else(|| "permanent".to_string());
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
                    // Rooms hold DEVICE ids while placements and members are MASTER-keyed, so
                    // include each room peer's resolved master; dedup via the set.
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
                super::gossip_relay::handle_gossip_eviction(&mut gossip_overlays);
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
            // Drives chunk requests, Have rebroadcast and in-flight retry; chunk requests
            // pause when messaging or voice traffic is recent so a share never starves it.
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
            // RECEIVE-path only: a regressed receive ratchet can ratchet forward again
            // after a crash, so deferring its persistence is safe. Send-path encrypts
            // persist IMMEDIATELY, since a regressed send ratchet re-uses generations
            // and wedges the group for every receiver.
            _ = mls_persist_timer.tick() => {
                arm_started = Some(("timer", "mls_persist", std::time::Instant::now()));
                if mls_dirty {
                    if let Some(ref mls_mgr) = mls {
                        persist_mls_state(mls_mgr, &crypto_store);
                    }
                    mls_dirty = false;
                }
            }

            // Asset-rail retry sweep. Cheap by construction: an empty pending
            // table returns before it touches SQLCipher, and a non-empty one
            // opens the store at most once for the whole tick.
            _ = asset_retry_timer.tick() => {
                arm_started = Some(("timer", "asset_retry", std::time::Instant::now()));
                emotes::retry_stale_asks(
                    &ws_cmd_tx, &ws_room_peers, &mut pending_asset_asks,
                    &local_peer_str, &db_path, &db_passphrase,
                );
                // The file-ask twin: a holder that never answered (an old
                // client, a dropped frame) is a silent miss, so rotate it and,
                // when nobody is left, say which dead end it is.
                file_asks::retry_stale_asks(
                    &ws_cmd_tx, &ws_room_peers, &server_states, &event_tx,
                    &mut pending_file_asks,
                    &mut requested_file_receipts, &mut declined_file_ids,
                    &pending_ws_transfers,
                    &local_peer_str, &device_peer_id,
                    &db_path, &db_passphrase,
                ).await;
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
                            // Friends are MASTER-keyed; rooms and the relay hold DEVICE ids.
                            // A master-keyed check reads every fresh install as offline and
                            // asks the relay about an id no socket authenticates as.
                            if crypto_handler::peer_is_reachable(&ws_room_peers, friend_pid) {
                                continue;
                            }
                            let devices = super::resolver::devices_for(friend_pid);
                            if devices.is_empty() {
                                check_peers.push(friend_pid.clone());
                            } else {
                                check_peers.extend(devices);
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

            // Temporary channel-grant expiry sweep: the predicate already denies an
            // expired grant lazily, so this enacts the crypto and UI consequences. Only
            // (server, channel)s with an expiry inside the (last_tick, now] window fire,
            // so each expiry triggers exactly one reconcile and old rows never re-fire.
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



/// Resolve the DM conversation a received edit/delete/reaction event belongs to.
/// For a normal DM the sender IS the conversation peer; for a copy echoed from
/// our OWN sibling the sender is US, so the event must be keyed to the OTHER
/// party, looked up from the stored row by `mid` (these envelopes carry no
/// convo field). Falls back to `resolve(sender)` when the row is not found.
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
/// our DM history from our high-water mark. During an Olm desync the peer kept
/// encrypting on a ratchet we could not decrypt, so its messages never rendered;
/// this recovers them without the restart that used to be the only cure. The
/// receiver dedups by message_id, so a redundant re-serve is harmless.
fn request_dm_resync_after_rekey(
    peer_str: &str,
    master_peer_str: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    // A media forwarder is not a social peer: it has no DM history with us and
    // DISCARDS the request. Detected structurally (the only room we share with it
    // is a `fwd:` room), so it covers peer forwarders as well as the VPS one.
    if peer_is_forwarder_only(ws_room_peers, peer_str) {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let convo = super::resolver::resolve(peer_str);
        // Multi-device: if WE have a sibling, request both directions from our
        // cross-direction high-water mark (mirrors the PeerJoined DM-sync) so a
        // friend also re-serves messages we sent from another device.
        let multi_device = !super::resolver::devices_for(master_peer_str).is_empty();
        let (since, gap) = store.dm_sync_anchor(&convo, multi_device);
        hollow_log!("[HOLLOW-SYNC] Post-rekey DM resync from {peer_str} since {since} (both={multi_device})");
        super::olm_lane::carry(
            ws_cmd_tx, peer_str, None,
            &HavenMessage::DmSyncRequest {
                since_timestamp: since,
                both_directions: multi_device,
                gap,
            },
            super::olm_lane::NoSession::Queue,
        );
    }
}

/// Deliver one DM sync reply, or queue it and re-key when we hold no session:
/// the requester built its half before asking, ours may never have been built,
/// and a user-visible MessageSendFailed for an internal reply would be wrong.
#[allow(clippy::too_many_arguments)]
async fn send_dm_sync_reply(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_str: &str,
    envelope: &MessageEnvelope,
) {
    let envelope_json = serde_json::to_string(envelope).unwrap_or_default();
    if olm.has_session(peer_str) {
        send_encrypted_message(
            olm, crypto_store,
            peer_str, &envelope_json, event_tx,
            ws_cmd_tx, ws_room_peers,
        ).await;
        return;
    }
    pending_messages
        .entry(peer_str.to_string())
        .or_default()
        .push(envelope_json);
    if !key_request_is_fresh(key_request_in_flight, peer_str) {
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            peer_str, signed_key_request(device_keypair, device_peer_id, peer_str),
        );
        key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());
    }
}

/// Pack stored DM messages into wire `DmSyncItem`s, joining each message's
/// reactions and file metadata in two batch queries. Shared by the friend
/// `DmSyncRequest` responder and the multi-device sibling backfill responder.
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
            file_meta_map.get(fid.as_str()).map(|f| SyncFileMetaItem::from_stored(f, f.sender_id.clone()))
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
            album: m.album_id.clone(),
            lp: m.link_preview.clone().map(Box::new),
            reactions,
        });
    }
    super::sync_handler::SyncPage { items, truncated }
}

/// Enforce device revocations just learned from an ingested device list. For
/// each freshly-revoked device id:
/// - **Olm (every node):** drop the in-RAM session AND delete the persisted
///   pickle, so no friend encrypts a DM to it and a restart cannot resurrect it.
/// - **MLS (coordinator only):** where we are the elected coordinator and the
///   revoked id still holds a leaf, enqueue that ONE leaf into
///   `pending_mls_removals`. Only that leaf: the device's MASTER stays a member.
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

/// Install our MASTER signing key on a server state that will author ops.
///
/// Goes hand in hand with `set_hlc` at EVERY site: a state that can create an
/// op must be able to sign it, and `create_op` panics rather than emit an
/// unsigned op that every peer would reject. The MASTER key, not the device
/// key — `CrdtOp::author` and the `members`/`roles` maps are master-keyed.
pub(crate) fn install_op_signer(
    state: &mut ServerState,
    master: &crate::identity::native_identity::NativeKeypair,
) {
    let pk_b64 = base64::engine::general_purpose::STANDARD.encode(master.public_key_protobuf());
    state.set_signer(master.clone(), pk_b64);
}

/// Apply ONE remotely-authored CRDT op: the single ingest path for a
/// `CrdtOpBroadcast` and for the `MemberAdded` op a `ServerJoinResolved` carries.
/// Author-validated by `op_allowed`, never sender-validated (the sender may
/// legitimately be relaying), persisted through `insert_crdt_op`, re-flooded
/// once, and turned into the per-payload UI events. ONE path, so a join
/// resolution can never become a SECOND ingest with its own weaker gates.
#[allow(clippy::too_many_arguments)]
async fn apply_remote_crdt_op(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    pending_server_joins: &HashMap<String, PendingJoin>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    peer_str: &str,
    server_id: String,
    op_json: String,
) {
    

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

        // SECURITY: the ONE ingest (`ServerState::ingest_remote`): the author's
        // signature, the clock bound, then the fold, which judges the op by the shared
        // permission matrix at its own point in HLC order. It validates op.author, never
        // the sender, who may legitimately be relaying.
        let state = server_states.get_mut(&server_id).unwrap();
        let ingested = state.ingest_remote(std::slice::from_ref(&op));
        if !ingested.admitted.is_empty() || ingested.rebuilt {
            if let Ok(json) = serde_json::to_string(&state) {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.save_server_state(&server_id, &json);
                    store.persist_admitted_ops(&ingested.admitted, state.checkpoint_hlc.as_ref());
                }
            }
        }
        if ingested.rebuilt {
            // A rebuild can change anything: the UI reloads the whole server.
            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                server_id: server_id.clone(),
            }).await;
        }

        if ingested.admitted.iter().any(|o| o.author == op.author && o.hlc == op.hlc) {

            // Forward the validated, NEW op onward, preferring the WebRTC mesh: the old
            // per-member SendDirect re-forward made every receiving node pay
            // O(members x devices) relay uploads per op. Op-newness gates this block, so a
            // node re-floods a given op at most once. Falls back to the relay fan-out.
            if super::gossip_relay::flood_crdt_op(
                gossip_overlays, event_tx, &server_id, &op_json, Some(peer_str),
            ) == 0 {
                let crdt_msg = HavenMessage::CrdtOpBroadcast {
                    server_id: server_id.clone(),
                    op_json: op_json.clone(),
                };
                if let Some(json) = super::olm_lane::carried_json(&crdt_msg) {
                    for member_peer_str in state.members.keys() {
                        if super::resolver::same_identity(member_peer_str, &local_peer_str) { continue; }
                        for dev in crate::node::crypto_handler::online_devices_for(ws_room_peers, member_peer_str) {
                            if dev == peer_str { continue; } // don't echo back to the sender device
                            super::olm_lane::carry_json(ws_cmd_tx, &dev, None, json.clone(), super::olm_lane::NoSession::Queue);
                        }
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
                    // Self-eviction: OUR identity was removed (our own LEAVE fanned from a
                    // sibling, or a plain kick) and the merge confirms we are no longer a
                    // member. Tear down DURABLY: the acting device deletes its state in
                    // handle_leave_server, but a sibling that only emitted MemberLeft kept the
                    // shell, which reloaded on restart and fed the sibling re-announce loop.
                    // Guarded on !pending so a rejoin replaying the old removal op cannot nuke it.
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
                    // Text only (#44): a voice-channel announce put a ghost entry in
                    // browsers that the next list refresh dropped. The op's author tells
                    // the room's guests; members only update their own browser.
                    if let Some(ch) = state.channels.get(channel_id)
                        .filter(|c| c.channel_type == crate::crdt::server_state::ChannelType::Text)
                    {
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

            // A role or visibility op shifts who qualifies for restricted channels, so
            // reconcile subgroups here too (coordinator-gated and idempotent), letting the
            // ACTUAL coordinator act even when another member authored the op.
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

/// Everything owed once a Welcome is installed, live or after being held: clear the
/// requests it answers, finish a parked join or a meeting admission, emit the new
/// SFrame key, and pull the ops and messages missed while the group was stale.
#[allow(clippy::too_many_arguments)]
async fn after_welcome_joined(
    mls_mgr: &mut MlsManager,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    crdt_store_actor: &super::crdt_store::CrdtStore,
    server_states: &HashMap<String, ServerState>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    mls_welcome_grace: &mut HashMap<String, std::time::Instant>,
    awaiting_mls_after_parked_join: &mut std::collections::HashSet<String>,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    db_path: &str,
    db_passphrase: &str,
    local_peer_str: &str,
    sync_peer: &str,
    server_id: &str,
    channel_id: &Option<String>,
    group_key: &str,
    welcome_sender: Option<&str>,
) {
    if super::conference::is_conference_sid(server_id) {
        if let Some(host) = welcome_sender {
            mls_mgr.pin_committer(group_key, host);
        }
    }
    mls_mgr.drop_unused_legacy();
    persist_mls_state(mls_mgr, crypto_store);
    mls_bootstrap_requested.remove(group_key);
    // The Welcome the eviction grace was holding for. The wait
    // is over whether or not this is the re-add that caused it.
    mls_welcome_grace.remove(group_key);
    hollow_log!("[HOLLOW-MLS] Joined MLS group {group_key}");

    // Co-members met as strangers while this join was pending, so each side's
    // first-contact profile exchange carried no roster. Everyone online has admitted
    // us by the time a Welcome lands: ask each device we cannot place for its profile.
    if channel_id.is_none() && !super::conference::is_conference_sid(server_id) {
        let devices: Vec<String> = ws_room_peers.get(server_id)
            .map(|p| p.iter().cloned().collect())
            .unwrap_or_default();
        let (tx, me) = (ws_cmd_tx.clone(), local_peer_str.to_string());
        let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
        tokio::task::spawn_blocking(move || {
            let placed: std::collections::HashSet<String> = crate::storage::MessageStore::open(&path, &pass)
                .and_then(|s| s.get_all_device_links())
                .map(|links| links.into_iter().map(|(device, _)| device).collect())
                .unwrap_or_default();
            for device in devices.iter().filter(|d| !placed.contains(*d) && !super::resolver::same_identity(d, &me)) {
                super::olm_lane::carry(&tx, device, None, &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
            }
        });
    }

    // A parked join is only truly finished HERE: it has held the
    // server since the buffered snapshot landed, but could not
    // read a word of it until this leaf formed.
    if awaiting_mls_after_parked_join.remove(server_id) {
        let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
            server_id: server_id.to_string(),
            state: "ready".to_string(),
            reason: String::new(),
        }).await;

        // And ask the relay for the channel rings again. On the way
        // back in, `RoomMembers` for this room can be processed
        // BEFORE the buffered SyncResponse lands, and at that instant
        // the server is not in `server_states`, so the connect-time
        // sweep requested nothing. Clear this room's "already pulled"
        // marks first, or the request filters itself away.
        if channel_id.is_none() {
            relay_catchup_done.retain(|(r, _)| r != server_id);
            sync_handler::request_channel_catchups(
                ws_cmd_tx, crdt_store_actor, server_states.get(server_id),
                server_id, local_peer_str, master_keypair, relay_catchup_done,
                "parked join welcome",
            ).await;
        }
    }

    // Conference Welcome = we were ADMITTED (waiting room
    // opened). Dart leaves the lobby and joins the call.
    if let Some(conf_id) = super::conference::conf_id_from_sid(server_id) {
        super::conference::clear_pending_knock(conf_id);
        let _ = event_tx.send(NetworkEvent::ConferenceAdmitted {
            conf_id: conf_id.to_string(),
        }).await;
        super::conference::broadcast_card(mls_mgr, crypto_store, ws_cmd_tx, master_keypair, conf_id, db_path, db_passphrase);
    }

    // Emit the SFrame key for this group. If we joined a
    // restricted VOICE channel's subgroup this delivers the key to
    // its voice cryptor; elsewhere Dart just caches it.
    if let Ok(sframe_key) = mls_mgr.export_secret(group_key, "sframe", b"", 32) {
        let epoch = mls_mgr.epoch(group_key).unwrap_or(0);
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: server_id.to_string(), epoch, sframe_key,
            channel_id: channel_id.clone(),
        }).await;
    }

    // After SERVER-GROUP recovery, also catch up on CRDT OPS missed at a
    // stale epoch. An op broadcast via MLS at an epoch we could not decrypt
    // was dropped with no plaintext fallback, so a channel created during
    // the skew is otherwise lost forever: per-channel sync cannot find it.
    if channel_id.is_none() {
        if let Some(state) = server_states.get(server_id) {
            let our_vector = StateVector::from_server_state(state);
            if let Ok(sv) = serde_json::to_string(&our_vector) {
                super::olm_lane::carry(
                    ws_cmd_tx, sync_peer, None,
                    &HavenMessage::SyncRequest {
                        server_id: server_id.to_string(),
                        state_vector_json: sv,
                        // Freshly Welcomed — current by construction.
                        mls_epoch: mls_mgr.epoch(server_id).ok(),
                    },
                    super::olm_lane::NoSession::Queue,
                );
            }
        }
    }

    // After MLS recovery, sync channels — server group: ALL channels
    // (not just empty ones; the DB has gaps from the stale epoch).
    // Subgroup: just the one restricted channel it serves.
    if let Some(state) = server_states.get(server_id) {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let sync_cids: Vec<String> = match channel_id {
                Some(cid) => vec![cid.clone()],
                None => state.channels.keys().cloned().collect(),
            };
            for cid in &sync_cids {
                super::olm_lane::carry(
                    ws_cmd_tx, sync_peer, None,
                    &super::sync_handler::channel_sync_request(&store, server_id, cid, true),
                    super::olm_lane::NoSession::Queue,
                );
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
    join_resolutions: &mut HashMap<String, i64>,
    awaiting_mls_after_parked_join: &mut std::collections::HashSet<String>,
    crdt_store_actor: &super::crdt_store::CrdtStore,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    mls: &mut Option<MlsManager>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    mls_welcome_grace: &mut HashMap<String, std::time::Instant>,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (std::path::PathBuf, u64, String)>,
    pending_link_snapshots: &mut HashMap<String, file_handler::LinkSnapshotState>,
    link: &mut link_handler::LinkState,
    decrypt_fail_cooldown: &mut HashMap<String, std::time::Instant>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    mls_epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    channel_sync_sent: &mut HashMap<String, std::time::Instant>,
    slow_mode_clock: &mut message_ops::SlowModeClock,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    call_book: &mut super::call_book::CallBook,
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
    pending_friend_accepts: &mut HashMap<String, i64>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    reject_resent: &mut std::collections::HashSet<String>,
    pending_asset_asks: &mut HashMap<String, emotes::PendingAsk>,
    pending_file_asks: &mut HashMap<String, file_asks::PendingFileAsk>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    pending_public_file_requests: &mut HashMap<String, (String, String, std::time::Instant)>,
    requested_file_receipts: &mut HashMap<String, std::time::Instant>,
    declined_file_ids: &mut std::collections::HashSet<String>,
    peer_auto_dl: &mut HashMap<String, u32>,
    fwd_bridge: FwdBridge<'_>,
    request: HavenMessage,
    // When the sender sealed the frame: what carried signals are judged fresh by.
    frame_ts_ms: i64,
    // A `MessageEnvelope::Carried` decrypted here and when it was written, for the
    // caller to dispatch next.
    carried_out: &mut Option<(Box<HavenMessage>, i64)>,
) {

    match request {
        HavenMessage::KeyRequest { to, ts, sig, pk } => {
            // SECURITY: this handler TEARS DOWN a working Olm session, so an
            // unauthenticated KeyRequest is a remote session-reset primitive against any
            // peer. A device that is not in its master's SIGNED device list is refused
            // outright: a signature alone only proves that SOME device sent this, not
            // that it speaks for the identity we think we are talking to.
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

            // A peer asking for a key bundle means THEIR side has no usable session. If
            // we hold a CONFIRMED one, our half is stale relative to theirs and silently
            // ignoring it strands both sides until a mutual restart; an UNCONFIRMED
            // outbound session means they never got our PreKey. Either way tear down and
            // re-handshake, under a cooldown so a KeyRequest flood cannot thrash it.
            let now = std::time::Instant::now();
            let cooldown_ok = match decrypt_fail_cooldown.get(peer_str) {
                Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                None => true,
            };
            if olm.has_confirmed_session(peer_str) && !cooldown_ok {
                hollow_log!("[HOLLOW-CRYPTO] KeyRequest from {peer_str} but confirmed session + cooldown active, ignoring");
            } else if olm.claim_prekey_resend(peer_str, OLM_KEY_REQUEST_TIMEOUT) {
                // Our PreKey and their request crossed, or ours was lost. Answering with a
                // bundle would start a second session to collide with the first; every
                // message on an unanswered session carries the whole handshake instead.
                hollow_log!("[HOLLOW-CRYPTO] KeyRequest from {peer_str} while our PreKey is in flight — re-sending on the same session");
                let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
                send_encrypted_message(
                    olm, crypto_store, peer_str, &ack_json, event_tx, ws_cmd_tx, ws_room_peers,
                ).await;
            } else {
                if olm.has_session(peer_str) {
                    // Stop encrypting on our half so the session the peer builds from the
                    // new bundle is the one used; what it already sent still reads.
                    hollow_log!("[HOLLOW-CRYPTO] KeyRequest from {peer_str} while we hold a session — peer lost theirs, re-keying");
                    olm.retire_session(peer_str);
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
            // SECURITY: these Curve25519 keys arrive over the relay and become the Olm
            // ratchet for this peer. Unauthenticated, a hostile relay could substitute
            // its own keys and sit in the middle of every DM with no visible sign.
            //
            // The signature binds them to the sender's Ed25519 DEVICE key and
            // `verify_message_signature` re-derives the peer_id from `pk`, while the
            // device-list check ties that device to a master the user trusts, completing
            // master -> signed device list -> device key -> signed bundle -> Olm keys.
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

            // SECURITY: the bundle is authenticated by now, so pin the Olm identity key
            // and surface a LATER change (a reinstall) instead of letting it pass
            // silently. Done before the glare branching, so the fact is recorded even
            // when this bundle loses the tiebreaker and builds no session.
            super::security_alerts::note_olm_identity_key(
                event_tx, db_path, db_passphrase, master_peer_str,
                &super::resolver::resolve(peer_str), peer_str, &identity_key,
            ).await;

            // An unanswered outbound session past the request window never reached the
            // peer, and this bundle says the peer is waiting for one: it is replaced.
            if olm.has_confirmed_session(peer_str) || olm.has_fresh_outbound(peer_str, OLM_KEY_REQUEST_TIMEOUT) {
                hollow_log!("[HOLLOW-CRYPTO] Already have session with {peer_str}, ignoring KeyBundle");
                key_bundle_sent_to.remove(peer_str);
            } else if key_bundle_sent_to.remove(peer_str) && device_peer_id > peer_str {
                // Glare: we sent THEM a KeyBundle and they sent US one, so both sides would
                // create outbound sessions and MAC-mismatch. The lower peer id creates the
                // outbound session; we are higher, so we wait for their PreKey and create an
                // inbound one instead.
                //
                // CRITICAL: compare DEVICE ids, not master. `peer_str` is the SENDER'S DEVICE
                // id and the outbound Olm session lives on the SOCKET, so the tiebreaker must
                // be device against device to stay antisymmetric. Comparing our MASTER with
                // the peer's device is two unrelated strings, so BOTH peers can satisfy
                // `local > peer` at once, both defer, and the pair deadlocks until the sweep.
                //
                // Do NOT clear key_request_in_flight here: if the low peer's PreKey is
                // dropped, clearing it strands us sessionless with no retry. REFRESH the
                // timestamp so the reconciliation sweep re-requests after the deferral window.
                hollow_log!("[HOLLOW-CRYPTO] KeyBundle glare with {peer_str} — we're higher, deferring to their PreKey (sweep will retry if dropped)");
                key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());
            } else {
                key_bundle_sent_to.remove(peer_str);
                match olm.create_outbound_session(peer_str, &identity_key, &one_time_key) {
                    Ok(()) => {
                        hollow_log!("[HOLLOW-CRYPTO] Created outbound (unconfirmed) session with {peer_str} via KeyBundle");
                        persist_crypto_state(olm, crypto_store, peer_str);
                        // Keep key_request_in_flight set (refreshed): the session is outbound-only
                        // until the peer replies, and if our PreKey is dropped the sweep resends. Do
                        // NOT emit SessionEstablished yet, which would be the optimistic "A sends, B
                        // never sees it" bug; confirmation happens on SessionAck.
                        key_request_in_flight.insert(peer_str.to_string(), std::time::Instant::now());

                        // Send encrypted SessionAck to upgrade the ratchet.
                        let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck)
                            .unwrap_or_default();
                        send_encrypted_message(
                            olm, crypto_store, peer_str, &ack_json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;

                        if let Some(queued) = pending_messages.remove(peer_str) {
                            hollow_log!("[HOLLOW-CRYPTO] Draining {} pending messages for {peer_str}", queued.len());
                            for text in queued {
                                send_encrypted_message(
                                    olm, crypto_store, peer_str, &text, event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                        }

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

        HavenMessage::Encrypted { message_type, body, identity_key, identity_sig, identity_pk } => {
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
            if olm.already_decrypted(peer_str, &ciphertext) {
                hollow_log!("[HOLLOW-SECURITY] Dropped a repeated Olm frame from {peer_str}");
                return;
            }

            let plaintext = if message_type == 0 {
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
                // Before any session is built OR torn down: an unproven key must
                // not even cost us the session we already hold.
                if !crypto_handler::verify_olm_identity(
                    peer_str, their_identity, identity_sig.as_deref(), identity_pk.as_deref(),
                ) {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED PreKey from {peer_str}: identity key not signed by that device");
                    return;
                }

                let had_session = olm.has_session(peer_str);
                match olm.open_prekey(peer_str, their_identity, &ciphertext, device_peer_id) {
                    Ok(opened) => {
                        if opened.created {
                            if !opened.switched {
                                hollow_log!("[HOLLOW-CRYPTO] Glare with {peer_str}: keeping our session (lower device id), read theirs on its own");
                            } else if had_session {
                                hollow_log!("[HOLLOW-CRYPTO] PreKey from {peer_str} started a new session — encrypting on it");
                            }
                            persist_crypto_state(olm, crypto_store, peer_str);
                            // SECURITY: pin only AFTER the session was built. vodozemac has
                            // now proven this identity key belongs to the sender, so a
                            // forged key cannot fabricate a "they re-keyed" notice.
                            super::security_alerts::note_olm_identity_key(
                                event_tx, db_path, db_passphrase, master_peer_str,
                                &super::resolver::resolve(peer_str), peer_str,
                                their_identity,
                            ).await;
                        }
                        if opened.created || opened.switched {
                            on_session_ready(
                                olm, crypto_store, crdt_store, bundle_keypair, event_tx,
                                ws_cmd_tx, ws_room_peers, pending_messages, pending_sync_requests,
                                key_request_in_flight, master_peer_str, peer_str, had_session,
                                true, db_path, db_passphrase,
                            ).await;
                        }
                        opened.plaintext
                    }
                    Err(e) => {
                        // ALWAYS log the drop (the re-key below is throttled): a burst of
                        // failures must never go dark on the receive side.
                        hollow_log!("[HOLLOW-CRYPTO] Inbound PreKey from {peer_str} undecryptable: {e} — dropped");
                        let now = std::time::Instant::now();
                        if decrypt_fail_cooldown.get(peer_str)
                            .is_none_or(|last| now.duration_since(*last) >= Duration::from_secs(5))
                        {
                            decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                        }
                        // Nudge the peer to re-key on a 2 s throttle, shorter than the
                        // teardown cooldown, so it resolves live instead of at a restart.
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
                        persist_crypto_state(olm, crypto_store, peer_str);
                        return;
                    }
                }
            } else {
                let was_confirmed = olm.has_confirmed_session(peer_str);
                let had_session = olm.has_session(peer_str);
                match olm.decrypt(peer_str, message_type, &ciphertext) {
                    Ok(opened) => {
                        if opened.switched {
                            hollow_log!("[HOLLOW-CRYPTO] {peer_str} writes on a session we had retired — encrypting on it again");
                        }
                        if !had_session {
                            on_session_ready(
                                olm, crypto_store, crdt_store, bundle_keypair, event_tx,
                                ws_cmd_tx, ws_room_peers, pending_messages, pending_sync_requests,
                                key_request_in_flight, master_peer_str, peer_str, had_session,
                                false, db_path, db_passphrase,
                            ).await;
                        } else if !was_confirmed {
                            // A decrypted reply proves the peer holds the other half.
                            hollow_log!("[HOLLOW-CRYPTO] Session with {peer_str} confirmed via decrypted reply");
                            key_request_in_flight.remove(peer_str);
                            let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                peer_id: peer_str.to_string(),
                            }).await;
                            // Re-pull anything missed while this session was unconfirmed
                            // / desynced (live equivalent of the restart re-sync).
                            request_dm_resync_after_rekey(
                                peer_str, master_peer_str,
                                ws_cmd_tx, ws_room_peers, db_path, db_passphrase,
                            );
                        }
                        opened.plaintext
                    }
                    Err(e) => {
                        let now = std::time::Instant::now();
                        // ALWAYS log a decrypt failure. Gating this behind the 5s teardown
                        // cooldown left a burst of undecryptable frames after a glare-desynced
                        // session completely unlogged, which made the bug invisible.
                        hollow_log!("[HOLLOW-SWARM] Decrypt FAILED for {peer_str}: {e}");

                        // No session we hold reads it, so ours is dead to the peer: retire it
                        // at most once per 5s, which keeps a 1000-chunk transfer failing at
                        // once from thrashing the session.
                        let teardown_ok = match decrypt_fail_cooldown.get(peer_str) {
                            Some(last_kill) => now.duration_since(*last_kill) >= Duration::from_secs(5),
                            None => true,
                        };
                        if teardown_ok {
                            olm.retire_session(peer_str);
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

                        // Send a KeyRequest to re-establish the session, independent of the
                        // teardown throttle and lightly throttled on its own (2s). The sender keeps
                        // blasting on its live-but-dead ratchet and the relay never ACKs, so our
                        // repeated KeyRequest is the only signal that drives the peer to drop its
                        // half. Gating it behind the 5s cooldown went silent and never resolved live.
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

            olm.note_decrypted(peer_str, &ciphertext);
            // Persist only session ratchet after decrypt (account unchanged).
            persist_olm_session(olm, crypto_store, &peer_str);

            let text = String::from_utf8_lossy(&plaintext).to_string();

            // ASYNC FRIENDING: the accepter's ONE pre-key establisher. Its whole job was
            // done by the decrypt above, which created our inbound session, so it stops
            // here, before the envelope parse: it is deliberately not JSON.
            if text == social::FRIEND_HANDSHAKE_SENTINEL {
                hollow_log!("[HOLLOW-FRIENDS] Friend-handshake establisher from {peer_str} — Olm session live, no DM row");
                return;
            }

            let envelope = serde_json::from_str::<MessageEnvelope>(&text);
            // A carried message may have waited in the sender's queue for a session, so
            // it counts as sent when written, never later than its frame.
            let frame_ts_ms = match &envelope {
                Ok(MessageEnvelope::Carried { at_ms, .. }) => (*at_ms).min(frame_ts_ms),
                _ => frame_ts_ms,
            };
            if let Ok(env) = &envelope
                && env.live_only()
                && super::frame_auth::is_stale(frame_ts_ms, super::frame_auth::now_ms())
            {
                hollow_log!("[HOLLOW-SECURITY] Dropped a live signal from {peer_str} that arrived too late");
                return;
            }
            match envelope {
                Ok(MessageEnvelope::ChannelMessage { inner }) => {
                    let ChannelMessagePayload { sid, cid, text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us, album } = *inner;
                    // The Olm fallback (no MLS group yet, offline replay) takes the same ingest
                    // as MLS, with the sender's DEVICE resolved to the MASTER that signs it.
                    let Some(state) = server_states.get(&sid) else {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage for unknown server {sid}");
                        return;
                    };
                    message_ops::handle_envelope_channel_message(
                        event_tx, bundle_keypair, Some(state), slow_mode_clock, local_peer_str,
                        super::resolver::resolve(peer_str), sid, cid, text, ts,
                        sig, pk, mid, reply_to, file_id, link_preview, order_us, album,
                        db_path, db_passphrase,
                    ).await;
                }
                Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, mut messages, total, has_more, .. }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} sync messages for {cid} in {sid} (total: {total}, has_more: {has_more:?})", messages.len());
                    if !crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), peer_str, &cid) {
                        return;
                    }
                    messages.retain(|m| crypto_handler::backfill_author_allowed(server_states.get(&sid), &m.s, m.ts));
                    let local_peer = local_peer_str.to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.begin_transaction();
                        let mut pk_cache = PkCache::new();
                        for msg in &messages {
                            let (inserted, events) = super::sync_handler::ingest_synced_channel_item(
                                &store, &sid, &cid, msg, &local_peer, &mut pk_cache,
                            );
                            new_count += inserted;
                            for ev in events {
                                let _ = event_tx.send(ev).await;
                            }
                        }
                        let _ = store.commit_transaction();

                        // Pagination: if has_more, send a follow-up ChannelSyncRequest
                        // with updated per-sender timestamps from our DB.
                        if has_more == Some(true) {
                            hollow_log!("[HOLLOW-SYNC] Requesting next page for {cid} in {sid}");
                            super::olm_lane::carry(
                                ws_cmd_tx, peer_str, None,
                                &super::sync_handler::channel_sync_request(&store, &sid, &cid, false),
                                super::olm_lane::NoSession::Queue,
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
                    let DirectMessagePayload { text: msg_text, ts, sig, pk, mid, reply_to, file_id, link_preview, convo, order_us, album } = *inner;

                    // Multi-device: attribute the DM to the sender's MASTER, so messages from any
                    // of a friend's devices land in the single DM thread and our own other-device
                    // sends attribute to us. Pre-multi-device this resolves to peer_str unchanged.
                    let is_own_device = super::resolver::same_identity(&peer_str, master_peer_str);
                    // Self fan-out: a copy echoed from our OWN sibling carries `convo` = the OTHER
                    // party's master, so it files under the real conversation rather than
                    // resolving to ourselves. For a normal DM `convo` is None.
                    // PHANTOM-CHAT GUARD: drop a DM from a device we just revoked but that is
                    // still alive and talking. We `forget`-ed its device-to-master link, so
                    // `resolve` returns its own id and it would spawn an "unknown peer" chat.
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
                    // This signature is the ONLY thing binding DM content to the sender's
                    // Ed25519 identity. The Olm session it arrived on proves only that someone
                    // holds the ratchet, so verifying-then-storing-anyway would let a hostile
                    // relay FORGE DM content, not merely read it.
                    //
                    // A MISSING signature is rejected too: the old `if sig.is_some()` gate was
                    // itself the bypass, since stripping `sig`/`pk` skipped verification entirely.
                    // So is a body over the message size limit, dropped whole, never clipped.
                    //
                    // Signer and context are SWAPPED for a self fan-out echo (`is_own_device`):
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
                            album: album.as_deref(),
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

                    // Persist with the SENDER timestamp, never a local now(), so DM sync
                    // dedups consistently. `is_own` flags an echo from our OWN device.
                    let mut is_new = true;
                    {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            // Dedup by message_id (reconnect resend, pending drain,
                            // relay buffer). The content UNIQUE index is legacy-only
                            // now: it used to swallow distinct identical-text messages.
                            let already = mid.as_deref()
                                .map(|m| store.dm_message_exists(m))
                                .unwrap_or(false);
                            if already {
                                is_new = false;
                            } else {
                                match store.insert(
                                    &convo_peer, &msg_text, is_own_device, ts,
                                    sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                    reply_to.as_deref(), file_id.as_deref(), order_us, album.as_deref(),
                                ) {
                                    Ok(0) => { is_new = false; } // Duplicate (legacy no-mid row)
                                    Ok(_) => {}
                                    Err(_) => { is_new = false; }
                                }
                            }
                            if is_new {
                                if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid.as_ref()) {
                                    if let Ok(lp_json) = serde_json::to_string(lp) {
                                        let _ = store.update_link_preview(message_id, &lp_json);
                                    }
                                }
                            }
                        }
                    }

                    // ALWAYS emit, even when the row already existed. A sync
                    // batch racing this live delivery inserts the row first
                    // WITHOUT per-message events, and suppressing the live event
                    // too left an OPEN chat stale until re-entry.
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
                            album_id: album.map(Box::new),
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
                    // CRITICAL: `DmSyncItem.mine` is RESPONDER-relative, `is_mine` as stored in
                    // the SENDER's DB, and a FRIEND's perspective is the OPPOSITE of ours: what
                    // the friend SENT we RECEIVED, and what they received from us we sent. So on
                    // the friend path we INVERT. From our own SIBLING, `is_mine` already means
                    // the same on both devices, so it is kept as-is.
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

                            // CRITICAL (multi-device): the signer is always a MASTER
                            // id, never the raw device id the relay reported. The
                            // signing context is the FRIEND conversation, direction-
                            // dependent on OUR effective `is_mine`:
                            //   is_mine=true  -> sender = our master, recipient = convo
                            //   is_mine=false -> sender = convo,      recipient = our master
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
                                album: msg.album.as_deref(),
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
                            let scope = message_ops::RowScope::Dm { convo: &convo_peer, is_mine };
                            if !message_ops::change_may_touch_row(&store, &scope, msg.mid.as_deref()) {
                                continue;
                            }

                            let already_exists = msg.mid.as_ref()
                                .map(|mid| store.dm_message_exists(mid))
                                .unwrap_or(false);
                            hollow_log!(
                                "[HOLLOW-SYNC] dm item mid={:?} ts={} wire_mine={} is_mine={is_mine} edited_at={:?} exists={} text_len={}",
                                msg.mid, msg.ts, msg.mine, msg.edited_at, already_exists, msg.t.len()
                            );

                            // Reconcile against a row delivered via another path (an
                            // offline fetch) that has a NULL or different mid. Without
                            // this, an edited message inserts as a duplicate row.
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
                                    msg.album.as_deref(),
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

                            // The card the item's signature covers. Runs on every
                            // branch above, so a friend catching up after being
                            // offline gets the preview with the message.
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

                            // Insert file metadata and emit FileHeaderReceived for late joiners. A DM
                            // file's context is the conversation MASTER (`convo_peer`), not the raw
                            // device id, so it matches where the message row is stored and
                            // `_reloadChatForFile` reloads the right thread.
                            if let Some(fm) = file_handler::synced_file_meta(
                                &store, msg.file_meta.as_ref(), msg.file_id.as_deref(), msg.mid.as_deref(), sender_m,
                            ) {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    msg.mid.as_deref(), "dm", &convo_peer,
                                    sender_m, false, fm.ts,
                                    fm.vthumb.as_ref(),
                                    file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime).as_deref(),
                                    fm.sha256.as_deref(),
                                );
                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fm.fid.clone(),
                                    file_name: fm.name.clone(),
                                    size_bytes: fm.size,
                                    is_image: fm.img,
                                    width: fm.w,
                                    height: fm.h,
                                    message_id: msg.mid.clone().unwrap_or_default(),
                                    sender_id: sender_m.to_string(),
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

                        // Pagination. Carry the multi-device both-direction mode forward, or the
                        // next page reverts to is_mine=0-only and re-strands our own sends.
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
                            super::olm_lane::carry(
                                ws_cmd_tx, peer_str, None,
                                &HavenMessage::DmSyncRequest {
                                    since_timestamp: since,
                                    both_directions: multi_device,
                                    gap: None,
                                },
                                super::olm_lane::NoSession::Queue,
                            );
                        }
                    }

                    hollow_log!("[HOLLOW-SYNC] DM sync: {new_count} new messages from {peer_str}");
                    // Always emit DmSyncCompleted, even with 0 new messages: Dart may have
                    // cleared its in-memory cache on disconnect and this tells it to reload
                    // from the DB. Only on the last page.
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
                    // File these under the REAL conversation (the friend's master), not
                    // resolve(peer_str), which would be our own master since the sender is our
                    // sibling. Each item carries its own `mine`, so both directions land right.
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
                            // Backfill signature rule: Valid or nothing. A sibling is
                            // still only as trustworthy as the batch it forwards,
                            // including the cards in it, hence the shipped-preview digest.
                            let lp_digest = crypto_handler::backfill_lp_digest(
                                msg.lp.as_deref(), msg.lp_digest.as_deref(),
                            );
                            let extras = crypto_handler::SignedExtras {
                                mid: msg.mid.as_deref(),
                                reply_to: msg.reply_to.as_deref(),
                                file_id: msg.file_id.as_deref(),
                                order_us: msg.order_us,
                                lp_digest: lp_digest.as_deref(),
                                album: msg.album.as_deref(),
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
                            let scope = message_ops::RowScope::Dm { convo: &convo_peer, is_mine: msg.mine };
                            if !message_ops::change_may_touch_row(&store, &scope, msg.mid.as_deref()) {
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
                                    msg.album.as_deref(),
                                ) {
                                    Ok(id) if id > 0 => {
                                        new_count += 1;
                                        if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                                            let _ = store.set_dm_message_edited_at(mid, edit_ts);
                                        }
                                        // Deliberately NO per-message MessageReceived here:
                                        // that event INCREMENTS the unread counter, so
                                        // replaying a conversation as live events inflated
                                        // the unread pill with already-seen messages. The
                                        // terminal `DmSyncCompleted` drives `loadHistory` plus
                                        // `recomputeDmUnread`, which counts from the DB.
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
                            if let Some(fm) = file_handler::synced_file_meta(
                                &store, msg.file_meta.as_ref(), msg.file_id.as_deref(), msg.mid.as_deref(), sender_m,
                            ) {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    msg.mid.as_deref(), "dm", &convo_peer,
                                    sender_m, false, fm.ts,
                                    fm.vthumb.as_ref(),
                                    file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime).as_deref(),
                                    fm.sha256.as_deref(),
                                );
                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fm.fid.clone(),
                                    file_name: fm.name.clone(),
                                    size_bytes: fm.size,
                                    is_image: fm.img,
                                    width: fm.w,
                                    height: fm.h,
                                    message_id: msg.mid.clone().unwrap_or_default(),
                                    sender_id: sender_m.to_string(),
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
                            super::olm_lane::carry(
                                ws_cmd_tx, peer_str, None,
                                &HavenMessage::DmSiblingSyncRequest {
                                    per_convo_since: vec![(convo_peer.clone(), since)],
                                    gaps: HashMap::new(),
                                },
                                super::olm_lane::NoSession::Queue,
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
                    if sid.is_some() {
                        message_ops::handle_envelope_edit_message(
                            event_tx, bundle_keypair,
                            sid.as_deref().and_then(|s| server_states.get(s)),
                            &super::resolver::resolve(peer_str),
                            mid, new_text, ts, sig, pk, sid, cid,
                            db_path, db_passphrase,
                        ).await;
                    } else {
                        message_ops::handle_envelope_dm_edit(
                            event_tx, peer_str, master_peer_str,
                            mid, new_text, ts, sig, pk,
                            db_path, db_passphrase,
                        ).await;
                    }
                }
                Ok(MessageEnvelope::LinkPreviewSet { mid, lp, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-LP] Received link preview for message {mid} from {peer_str}");
                    message_ops::handle_envelope_link_preview_set(
                        event_tx,
                        sid.as_deref().and_then(|s| server_states.get(s)),
                        peer_str, master_peer_str,
                        mid, lp, ts, sig, pk, sid, cid, frame_ts_ms,
                        db_path, db_passphrase,
                    ).await;
                }
                Ok(MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-DELETE] Received delete for message {mid} from {peer_str}");
                    if sid.is_some() {
                        message_ops::handle_envelope_delete_message(
                            event_tx, bundle_keypair, &super::resolver::resolve(peer_str),
                            mid, ts, sig, pk, sid, cid,
                            db_path, db_passphrase,
                        ).await;
                    } else {
                        message_ops::handle_envelope_dm_delete(
                            event_tx, peer_str, master_peer_str,
                            mid, ts, sig, pk,
                            db_path, db_passphrase,
                        ).await;
                    }
                }
                Ok(MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-REACTION] Received reaction on {mid} from {peer_str}");
                    // Reactions are signed by and attributed to the reactor's MASTER, so a
                    // friend's reactions from any of its devices count as one person's.
                    let reactor = super::resolver::resolve(peer_str);
                    if sid.is_some() {
                        message_ops::handle_envelope_add_reaction(
                            event_tx, bundle_keypair,
                            sid.as_deref().and_then(|s| server_states.get(s)),
                            &reactor, mid, emoji, ts, sig, pk, sid, cid,
                            db_path, db_passphrase,
                        ).await;
                    } else if !emotes::valid_reaction_emoji(&emoji) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED AddReaction from {peer_str} — invalid emoji string ({} bytes)", emoji.len());
                    } else if !message_ops::reaction_sig_rejected(
                        &reactor, "reaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref(),
                    ) {
                        let stored = crate::storage::MessageStore::open(db_path, db_passphrase)
                            .is_ok_and(|store| {
                                message_ops::dm_reaction_target_ok(&store, &mid, peer_str, master_peer_str)
                                    && store.add_reaction(
                                        &mid, &emoji, &reactor, ts, sig.as_deref(), pk.as_deref(),
                                    ).is_ok()
                            });
                        if stored {
                            // The DM thread is the OTHER party: the reactor for a friend's
                            // reaction, the row's conversation for our own sibling's echo.
                            let _ = event_tx.send(NetworkEvent::DmReactionAdded {
                                peer_id: dm_event_convo(peer_str, master_peer_str, &mid, db_path, db_passphrase),
                                message_id: mid,
                                emoji,
                                reactor,
                                added_at: ts,
                            }).await;
                        }
                    }
                }
                Ok(MessageEnvelope::RemoveReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-REACTION] Received remove reaction {emoji} on {mid} from {peer_str}");
                    let reactor = super::resolver::resolve(peer_str);
                    if sid.is_some() {
                        message_ops::handle_envelope_remove_reaction(
                            event_tx, bundle_keypair, &reactor,
                            mid, emoji, ts, sig, pk, sid, cid,
                            db_path, db_passphrase,
                        ).await;
                    } else if !message_ops::reaction_sig_rejected(
                        &reactor, "unreaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref(),
                    ) {
                        // Only the reactor's own reaction goes, so no row check is needed.
                        let removed = crate::storage::MessageStore::open(db_path, db_passphrase)
                            .is_ok_and(|store| store.remove_reaction(&mid, &emoji, &reactor, ts, sig.as_deref(), pk.as_deref()) == Ok(true));
                        if removed {
                            let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
                                peer_id: dm_event_convo(peer_str, master_peer_str, &mid, db_path, db_passphrase),
                                message_id: mid,
                                emoji,
                                reactor,
                                removed_at: ts,
                            }).await;
                        }
                    }
                }
                // -- File transfer receive handlers --
                Ok(MessageEnvelope::FileHeader { inner }) => {
                    let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, sig, pk, aes_key, aes_nonce, vthumb, share_ref, order_us, album, inline_bytes, thumb, voice, author, sha256, .. } = *inner;
                    // Envelope-borne thumb: image blur placeholder or video
                    // poster, size-capped — see accept_header_thumb.
                    let thumb = file_handler::accept_header_thumb(thumb, img, &mime);
                    use crate::node::file_transfer;
                    hollow_log!("[HOLLOW-FILE] FileHeader received: {fid} ({name}, {size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());

                    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
                    // A holder answering for someone else's file: the device an explicit
                    // pull asked on this connection, or the decrypt-fail retry's target.
                    let asked = pending_file_asks.get(&fid).is_some_and(|a| a.asked.contains(peer_str))
                        || pending_file_streams.get(&fid).is_some_and(|p| p.sender == peer_str);
                    if let Some(reason) = file_handler::file_header_refused(
                        &store, server_states, &fid, sid.as_deref(), cid.as_deref(), peer_str, asked,
                    ).or_else(|| super::file_commit::header_claim_refused(
                        &fid, author.as_deref(), mid.as_deref(), size, sha256.as_deref(), &name, &ext,
                        vthumb.as_ref(), peer_str, asked,
                    )) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED FileHeader for {fid} from {peer_str}: {reason}");
                        return;
                    }
                    let already_complete = file_handler::file_bytes_on_disk(&store, &fid);
                    drop(store);
                    // A committed card belongs to the author its id names, whoever delivered it.
                    let card_owner = match author.as_deref() {
                        Some(a) if super::file_commit::is_committed_id(&fid) => a.to_string(),
                        _ => peer_str.to_string(),
                    };

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
                    // The answer to a queued pull arrived: the ask is over.
                    file_asks::retire(pending_file_asks, &fid);

                    // SECURITY: validate file size against the server limit (34MB default for
                    // DMs). Skipped for share-backed files, which Share delivers with no size
                    // limit, and for explicit pulls, whose fallback re-serve carries no share_ref.
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
                    // Multi-device: a DM file's conversation key MUST be the sender's MASTER id,
                    // where the DM message row itself is stored, not the raw sender DEVICE id.
                    // Otherwise the metadata is filed under the device while the message is
                    // under the master, and Dart reloads the wrong conversation.
                    let dm_convo = super::resolver::resolve(&peer_str);
                    let ctx_id = match (&sid, &cid) {
                        (Some(s), Some(c)) => format!("{s}:{c}"),
                        _ => dm_convo.clone(),
                    };

                    // Save file metadata to DB. Owner guard (0.8.5): the header
                    // is Olm-authenticated, but that only proves WHO sent it —
                    // not that the `file_id` inside is theirs to relabel.
                    let mut meta_written = false;
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        meta_written = file_handler::file_meta_write_allowed(&store, &fid, &peer_str);
                        if meta_written {
                            let _ = store.insert_file_metadata(
                                &fid, &name, &ext, &mime,
                                size, chunks, img,
                                w, h,
                                mid.as_deref(), ctx_type, &ctx_id,
                                &card_owner, false, ts,
                                vthumb.as_ref(), thumb.as_deref(), sha256.as_deref(),
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
                    // FileHeader entirely and register no pending stream. A DM file fans out to
                    // several of the recipient's devices and the decrypt-fail re-request also
                    // re-sends a header, so each re-registration reset retry_count and made an
                    // endless re-download of one already-saved file.
                    if already_complete {
                        // Clear any stale pending stream / early-arrival bytes for it and
                        // stop — no re-request, no re-register. Still emit FileHeaderReceived
                        // below so the sender-side UI/late-joiner stays consistent.
                        pending_file_streams.remove(&fid);
                        if let Some((temp_path, _, _)) = early_file_streams.remove(&fid) {
                            let _ = tokio::fs::remove_file(&temp_path).await;
                        }
                        hollow_log!("[HOLLOW-FILE] FileHeader for {fid} ignored — already complete on disk");
                    }

                    // Inlined offline image (relay-buffered 0x08 DM): the AES ciphertext rides
                    // INSIDE the header, so write it to disk now, because no stream will ever
                    // arrive.
                    // The AUTO-DOWNLOAD GATE key and verdict (issue #41) are computed here
                    // because they gate BOTH the inline write below and the pending-stream
                    // registration further down. An existing pending stream is a transfer we
                    // already accepted, and the decrypt-fail retry re-requests WITHOUT a
                    // receipt, so its fresh header must not be declined.
                    let auto_dl_key = if sid_str.is_empty() {
                        format!("dm:{dm_convo}")
                    } else {
                        format!("server:{sid_str}")
                    };
                    let auto_ok = explicitly_requested
                        || pending_file_streams.contains_key(&fid)
                        || file_handler::auto_download_allows(size, &name, &ext, &auto_dl_key, voice);

                    // Only a DM header inlines bytes (an offline image).
                    let mut inline_done = false;
                    if !already_complete && share_ref.is_none() && ctx_type == "dm" {
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
                                    // Captionless offline image: the "[file:...]" companion
                                    // DM is never sent to offline peers, so the message row
                                    // is inserted here (deduped by mid; a captioned image's
                                    // real caption DM wins later). Stored REGARDLESS of the
                                    // auto-download gate, which gates only the bytes.
                                    //
                                    // SECURITY (backfill rule): the header's sig is the
                                    // MESSAGE signature over the sentinel text, so the row is
                                    // stored ONLY when it VERIFIES; a captioned image's
                                    // header legitimately fails, because the sender signed the
                                    // CAPTION. `order_us` comes from the header, since the v2
                                    // signature binds the sender's Lamport stamp.
                                    let from_sibling = super::resolver::same_identity(&peer_str, master_peer_str);
                                    let sentinel_text = format!("[file:{fid}]");
                                    let sentinel_sig_ok = from_sibling || {
                                        let extras = crypto_handler::SignedExtras {
                                            mid: mid.as_deref(),
                                            reply_to: None,
                                            file_id: Some(&fid),
                                            order_us,
                                            lp_digest: None,
                                            album: album.as_deref(),
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
                                            album.as_deref(),
                                        );
                                    }
                                }
                                if !auto_ok {
                                    // AUTO-DOWNLOAD GATE (issue #41): drop the inline
                                    // ciphertext. The card renders from the metadata row with
                                    // a manual Download button that re-pulls the bytes.
                                    hollow_log!("[HOLLOW-FILE] Auto-download gate dropped inline image bytes for {fid} ({auto_dl_key}) — message kept, manual download available");
                                    inline_done = true;
                                } else if !file_transfer::is_wire_file_id(&fid)
                                    || !file_transfer::is_wire_ext(&ext)
                                {
                                    // SECURITY (FILE-1): this write names a file
                                    // from two raw wire strings, and an absolute
                                    // `fid` makes `Path::join` discard the base
                                    // directory, so a peer that chooses the name
                                    // chooses the directory.
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED inline FileHeader from {peer_str}: bad file id or extension");
                                } else if let Some(reason) = match crate::storage::MessageStore::open(db_path, db_passphrase) {
                                    Ok(store) => super::file_commit::completion_refused(&store, &fid, &plaintext),
                                    Err(_) => Some("the store could not be opened"),
                                } {
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED inline bytes for {fid} from {peer_str}: {reason}");
                                } else {
                                    let files_dir = file_transfer::files_dir();
                                    let _ = tokio::fs::create_dir_all(&files_dir).await;
                                    let disk_path = file_transfer::final_file_path(&fid, &ext);
                                    if crate::node::at_rest::write_all(&disk_path, &plaintext).is_ok() {
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
                    // conversation with auto-download off, or over the threshold, is
                    // declined. The metadata row still renders the card with a manual
                    // Download button, and queued bytes are deleted on arrival.
                    if !already_complete && !inline_done && !auto_ok
                        && share_ref.is_none() && aes_key.is_some()
                    {
                        declined_file_ids.insert(fid.clone());
                        if let Some((temp_path, _, _)) = early_file_streams.remove(&fid) {
                            let _ = tokio::fs::remove_file(&temp_path).await;
                        }
                        hollow_log!("[HOLLOW-FILE] Auto-download gate declined pushed file {fid} ({size} bytes, {auto_dl_key}) — metadata kept, manual download available");
                        // Tell Dart NOW, at header time: the transfer provider flags
                        // the file declined so no progress source can flip the bubble
                        // into a spinner while the unwanted push transits.
                        let _ = event_tx.send(NetworkEvent::FileFailed {
                            file_id: fid.clone(),
                            error: "auto_download_off".to_string(),
                        }).await;
                    }

                    // If aes_key is present and no share_ref, this is a streamed transfer — register for stream receive.
                    // Share-backed files skip this — Share handles delivery, no P2P binary data.
                    if !already_complete && !inline_done && auto_ok && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
                        // Preserve the retry counter across a re-registration. A DM file fans out
                        // to several of the recipient's devices, and the decrypt-fail auto-retry
                        // also re-sends a FileHeader. Resetting retry_count on every header made
                        // the bounded "3 retries then give up" never fire, giving an infinite
                        // header/stream/decrypt-fail loop.
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
                        // Dart starts a share download from this, so only the card's owner names one.
                        share_ref: share_ref.filter(|_| meta_written),
                        thumb_b64: thumb,
                    }).await;
                }

                // -- Vault shard receive handlers --
                Ok(MessageEnvelope::ShardStore { inner }) => {
                    let ShardStorePayload { sid, cid, si, sk, k, m, total_size, tier, data, chunks, .. } = *inner;
                    hollow_log!("[HOLLOW-VAULT] ShardStore received: cid={cid} si={si} chunks={chunks} from {peer_str}");
                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                    let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else { return };
                    // Streamed (no data) or inline; a chunked store has no sender.
                    let inline = if chunks > 0 {
                        None
                    } else if data.is_empty() {
                        Some(Vec::new())
                    } else {
                        base64::engine::general_purpose::STANDARD.decode(&data).ok()
                    };
                    let Some(shard_bytes) = inline else {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardStore for {cid} from {peer_str}: unreadable shard");
                        return;
                    };
                    let incoming = (shard_bytes.len() as u64).max(1);
                    let refusal = vault_ops::shard_write_refused(
                        server_states, &content_store, peer_str, &sid, &cid, si, local_peer_str, incoming,
                    );
                    let result = match refusal {
                        Some("that shard is already held") => Ok(()),
                        Some(reason) => Err(reason.to_string()),
                        None if shard_bytes.is_empty() => {
                            // Streamed shard: the bytes follow on the stream lane.
                            let key = format!("{cid}:{si}");
                            pending_shard_streams.entry(key.clone()).or_insert(PendingShardStream {
                                server_id: sid.clone(), content_id: cid.clone(), shard_index: si,
                                shard_key: sk, k, m, total_size, tier,
                            });
                            hollow_log!("[HOLLOW-VAULT] Registered pending shard stream: {key}");
                            return;
                        }
                        None => {
                            let tier_enum = crate::vault::content_store::StorageTier::from_str(&tier);
                            content_store
                                .store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes)
                                .map(|_| ())
                        }
                    };
                    if let Err(e) = &result {
                        hollow_log!("[HOLLOW-VAULT] Shard {si} of {cid} from {peer_str} not stored: {e}");
                    } else {
                        let _ = event_tx.send(NetworkEvent::ShardStored {
                            server_id: sid.clone(),
                            content_id: cid.clone(),
                            shard_index: si,
                            from_peer: peer_str.to_string(),
                        }).await;
                    }
                    if !shard_bytes.is_empty() {
                        let ack = MessageEnvelope::ShardStoreAck {
                            sid, cid, si, ok: result.is_ok(), err: result.err(), target: None,
                        };
                        let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                        send_encrypted_message(
                            olm, crypto_store, &peer_str, &ack_json, event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
                }

                Ok(MessageEnvelope::ShardStoreAck { sid, cid, si, ok, err, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardStoreAck: cid={cid} si={si} ok={ok} err={err:?}");
                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                    let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else { return };
                    // Only the peer we placed the shard on speaks for it.
                    let placed_on_sender = content_store
                        .placement_target(&cid, si)
                        .ok()
                        .flatten()
                        .is_some_and(|target| super::resolver::same_identity(peer_str, &target));
                    if !placed_on_sender {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardStoreAck for {cid}/{si} from {peer_str}: not where it was placed");
                        return;
                    }
                    if ok {
                        let _ = content_store.confirm_placement(&cid, si);
                    }
                    let _ = event_tx.send(NetworkEvent::ShardStoreAckReceived {
                        server_id: sid,
                        content_id: cid,
                        shard_index: si,
                        success: ok,
                        error: err.unwrap_or_default(),
                    }).await;
                }

                Ok(MessageEnvelope::ShardDelete { sid, cid }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardDelete received: cid={cid} from {peer_str}");
                    vault_ops::handle_shard_delete(
                        server_states, event_tx, peer_str, sid, cid, db_path, db_passphrase,
                    ).await;
                }

                // -- Vault shard retrieve handlers --

                Ok(MessageEnvelope::ShardRequest { sid, cid, si, sk, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardRequest: cid={cid} si={si} from {peer_str}");
                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                    let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else { return };
                    if let Some(reason) = vault_ops::shard_serve_refused(server_states, &cs, peer_str, &sid, &cid) {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardRequest for {cid} from {peer_str}: {reason}");
                        return;
                    }
                    // The key names the file we read, so it must be this shard's own.
                    let shard = if sk == crate::vault::content_store::shard_key(&cid, si) {
                        cs.read_shard_unchecked(&sid, &sk).ok()
                    } else {
                        None
                    };
                    let resp = MessageEnvelope::ShardResponse {
                        sid: sid.clone(), cid: cid.clone(), si,
                        data: String::new(), chunks: 0, found: shard.is_some(),
                        target: None,
                    };
                    let json = serde_json::to_string(&resp).unwrap_or_default();
                    send_encrypted_message(
                        olm, crypto_store, &peer_str, &json, event_tx,
                        ws_cmd_tx, ws_room_peers,
                    ).await;
                    if let Some(shard_data) = shard {
                        let shard_temp_dir = crate::node::file_transfer::files_dir();
                        // The cid is whatever a member stored the shard under: it names a
                        // file here, so only alphanumerics survive (a `\..\` walks out on Windows).
                        let shard_safe_prefix: String =
                            cid.chars().filter(|c| c.is_ascii_alphanumeric()).take(16).collect();
                        let shard_temp_name = format!(".stream_shard_{}_{}.tmp", shard_safe_prefix, si);
                        let shard_temp_path = shard_temp_dir.join(&shard_temp_name);
                        if let Ok(()) = tokio::fs::write(&shard_temp_path, &shard_data).await {
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
                }

                Ok(MessageEnvelope::ShardResponse { sid, cid, si, data, chunks, found, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardResponse: cid={cid} si={si} found={found} chunks={chunks} from {peer_str}");
                    if !found {
                        let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                            server_id: sid, content_id: cid, shard_index: si,
                            error: "Shard not found on peer".into(),
                        }).await;
                        return;
                    }
                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                    let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else { return };
                    let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) else { return };
                    let incoming = (shard_bytes.len() as u64).max(1);
                    if let Some(reason) = vault_ops::shard_write_refused(
                        server_states, &cs, peer_str, &sid, &cid, si, local_peer_str, incoming,
                    ) {
                        hollow_log!("[HOLLOW-VAULT] Shard response {si} of {cid} from {peer_str} not taken: {reason}");
                        return;
                    }
                    if shard_bytes.is_empty() {
                        // Streamed shard response: the bytes follow on the stream lane.
                        let key = format!("{cid}:{si}");
                        pending_shard_streams.entry(key.clone()).or_insert(PendingShardStream {
                            server_id: sid.clone(), content_id: cid.clone(), shard_index: si,
                            shard_key: String::new(), k: 0, m: 0, total_size: 0,
                            tier: "standard".to_string(),
                        });
                        hollow_log!("[HOLLOW-VAULT] Registered pending shard stream for response: {key}");
                    } else {
                        let tier = crate::vault::content_store::StorageTier::Standard;
                        let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                        let _ = event_tx.send(NetworkEvent::ShardReceived {
                            server_id: sid, content_id: cid, shard_index: si,
                            from_peer: peer_str.to_string(),
                        }).await;
                    }
                }

                Ok(MessageEnvelope::VaultManifestBroadcast { sid, cid, chid, manifest }) => {
                    hollow_log!("[HOLLOW-VAULT] VaultManifest received: cid={cid} in {sid}/{chid} from {peer_str}");
                    vault_ops::ingest_vault_manifest(
                        server_states, peer_str, &sid, &chid, &manifest, db_path, db_passphrase,
                    );
                }

                Ok(MessageEnvelope::ShardMigrate { sid, cid, si, data, .. }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardMigrate received: cid={cid} si={si} from {peer_str}");
                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
                    let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else { return };
                    let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) else { return };
                    match vault_ops::shard_write_refused(
                        server_states, &cs, peer_str, &sid, &cid, si, local_peer_str, shard_bytes.len() as u64,
                    ) {
                        Some(reason) => hollow_log!("[HOLLOW-VAULT] Migrated shard {si} of {cid} from {peer_str} not taken: {reason}"),
                        None => {
                            let tier = crate::vault::content_store::StorageTier::Standard;
                            let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                            hollow_log!("[HOLLOW-VAULT] Migrated shard stored: cid={cid} si={si}");
                        }
                    }
                }

                Ok(MessageEnvelope::DestroyIdentityOrder { destroy: order }) => {
                    destroy::handle_envelope_destroy_identity(
                        event_tx, &order, local_peer_str, device_peer_id, db_path, db_passphrase,
                    ).await;
                }
                Ok(MessageEnvelope::SessionAck) => {
                    // Lightweight encrypted ping the peer sends after building or switching
                    // to a session. The decrypt that read it already confirmed ours and
                    // reported SessionEstablished.
                    hollow_log!("[HOLLOW-CRYPTO] SessionAck received from {peer_str}");
                    key_request_in_flight.remove(peer_str);
                }

                // 1:1 call signaling, the ONLY accepted path for a Call* message.
                // `peer_str` is the device whose Olm ratchet just decrypted this, so the
                // sender is authenticated; the plaintext Call* arms below reject instead.
                Ok(MessageEnvelope::CallSignal { signal }) => {
                    voice_handler::handle_call_signal_message(
                        peer_str, master_peer_str, *signal, call_book, ws_cmd_tx, ws_room_peers,
                        event_tx, db_path, db_passphrase,
                    ).await;
                }

                // Handed back to the caller, which dispatches it as if it had arrived on
                // its own from `peer_str`, the device whose ratchet decrypted it.
                Ok(MessageEnvelope::Carried { msg, .. }) => {
                    // The answer to a join of ours comes only from our reply key: over Olm,
                    // anyone we share a session with could hand us a server state.
                    let answers_our_join = matches!(&*msg, HavenMessage::SyncResponse { server_id, .. }
                        if pending_server_joins.contains_key(server_id));
                    if answers_our_join {
                        hollow_log!("[HOLLOW-SECURITY] Dropped a sync answer over Olm from {peer_str} for a server we are still joining");
                    } else if msg.lane() == Lane::Carried {
                        *carried_out = Some((msg, frame_ts_ms));
                    } else {
                        hollow_log!("[HOLLOW-SECURITY] Dropped a carried message from {peer_str} that belongs to another lane");
                    }
                }

                // Group envelopes never ride Olm: their Olm path is the carried
                // HavenMessage, which the caller dispatches.
                Ok(MessageEnvelope::CrdtOp { .. })
                | Ok(MessageEnvelope::ChannelHint { .. })
                | Ok(MessageEnvelope::Typing { .. })
                | Ok(MessageEnvelope::ProfileUpdate { .. })
                | Ok(MessageEnvelope::VoiceChannelJoin { .. })
                | Ok(MessageEnvelope::VoiceChannelLeave { .. })
                | Ok(MessageEnvelope::VoiceChannelAudioState { .. })
                | Ok(MessageEnvelope::VoiceChannelScreenState { .. })
                | Ok(MessageEnvelope::VoiceChannelCameraState { .. })
                | Ok(MessageEnvelope::VoiceChannelRecordingState { .. }) => {
                    hollow_log!("[HOLLOW-MLS] Received MLS-only envelope via Olm from {peer_str} — ignoring");
                }

                // Voice SDP/ICE Olm fallback handlers: these arrive via Olm when MLS
                // encrypt failed on the sender side (its epoch may be stale after a
                // reconnect).
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
                // Screen offer/answer/ICE consolidate into the shared voice_handler
                // handlers (the same participant and size guards, plus the origin spoof
                // guard), so the origin contract lives in ONE place for Olm and MLS.
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
                        peer_str.to_string(), sid, cid, origin, forwarder, feed_target,
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
                // Client-bound signals from a forwarder. Rust enforces only the SDP size
                // cap; the trust decision ("from the discovered forwarder AND for a
                // watched and assigned origin") lives in Dart, and an arbitrary peer
                // sending these reaches a provider that ignores unknown senders.
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
                            // The fed forwarder ADMITTED our ingest; any refusal,
                            // including an old binary that ignores the `feeder`
                            // field, answers with fwd_error. Tell Dart so it can
                            // report the feed up to the owner: make-before-break.
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
                // Forwarder-bound signals arriving at a client. An ENABLED embedded
                // peer forwarder consumes them behind its expectation gate, engine
                // admission and token bucket; otherwise they hit the ignore arm.
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
                    // Every sender wraps its payload in a signed envelope, so one that
                    // does not parse is version skew or tampering, never a message.
                    hollow_log!("[HOLLOW-SWARM] Dropped a decrypted payload from {peer_str} that is not an envelope ({} B): {e}", text.len());
                }
            }

            
        }

        // -- CRDT sync message handlers --

        HavenMessage::SyncRequest { server_id, state_vector_json, mls_epoch } => {
            hollow_log!("[HOLLOW-CRDT] SyncRequest from {peer_str} for server {server_id}");

            // The op log is the whole server (names, roles, bans, restricted channels), so
            // only a member gets it. A tombstone has no members left: anyone asking gets
            // just the owner's deletion op, all a reconnecting former member needs.
            if let Some(state) = server_states.get(&server_id).filter(|s| s.is_member(peer_str) || s.is_deleted()) {
                if let Ok(their_vector) = serde_json::from_str::<StateVector>(&state_vector_json) {
                    let mut delta = crdt_sync::compute_delta(&state.op_log, &their_vector);
                    if !state.is_member(peer_str) {
                        delta.retain(|op| matches!(op.payload, CrdtPayload::ServerDeleted { .. }));
                    }
                    if !delta.is_empty() {
                        if let Ok(ops_json) = serde_json::to_string(&delta) {
                            hollow_log!("[HOLLOW-CRDT] Sending {} delta ops to {peer_str}", delta.len());
                            super::olm_lane::carry(
                                ws_cmd_tx, peer_str, None,
                                &HavenMessage::SyncResponse { server_id: server_id.clone(), ops_json },
                                super::olm_lane::NoSession::Queue,
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
                    mls_epoch_hint_cooldown,
                    &server_id, None, their_epoch, None, peer_str, local_peer_str,
                    false, // incidental hint on a sync — elect one responder
                );
            }
        }

        HavenMessage::ServerStateSnapshot { server_id, state_json } => {
            // SECURITY: only honored while a join WE initiated is pending —
            // an established member must never let another peer overwrite
            // its server state wholesale.
            let Some(owner_pin) = pending_server_joins.get(&server_id).map(|p| p.owner_pin.clone()) else {
                hollow_log!("[HOLLOW-CRDT] Ignoring ServerStateSnapshot for {server_id} (no pending join)");
                return;
            };
            // Never replaces a state already rebased on the owner's checkpoint.
            if server_states.get(&server_id).is_some_and(|s| s.anchor() != crate::crdt::server_state::Anchor::Legacy) {
                hollow_log!("[HOLLOW-CRDT] Ignoring ServerStateSnapshot for {server_id}: already anchored");
                return;
            }
            // SECURITY (E1): the anchor rules (`accept_join_snapshot`): no snapshot for
            // a self-certifying id, and with an invite pin only one owned by the pin.
            let parsed = serde_json::from_str::<ServerState>(&state_json).map_err(|e| e.to_string())
                .and_then(|snap| ServerState::accept_join_snapshot(snap, &server_id, owner_pin.as_deref())
                    .map_err(str::to_string));
            match parsed {
                Ok(mut snap) => {
                    snap.set_hlc(Hlc::new(local_peer_str.to_string()));
                    install_op_signer(&mut snap, bundle_keypair);
                    // SECURITY (CRDT-2): a snapshot is adopted wholesale from ONE
                    // responder, so its registers are only as honest as that peer.
                    // Pull any stamped past the drift bound back to it, or one hostile
                    // responder hands us a state no later honest write can overtake.
                    let clamped = snap.clamp_future_hlcs(crate::crdt::hlc::wall_clock_ms());
                    if clamped > 0 {
                        hollow_log!("[HOLLOW-SECURITY] Clamped {clamped} future-dated register(s) in the {server_id} snapshot from {peer_str}");
                    }
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
                    hollow_log!("[HOLLOW-SECURITY] REJECTED ServerStateSnapshot for {server_id} from {peer_str}: {e}");
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
                    // Skeleton for a pending join: ownerless, so only the anchor can
                    // found it (the op a self-certifying id proves, or the invite's
                    // pinned owner). The responder is just our sync source.
                    let mut s = ServerState::skeleton(server_id.clone());
                    s.owner_pin = pending_server_joins.get(&server_id).and_then(|p| p.owner_pin.clone());
                    s.set_hlc(Hlc::new(local_peer_str.to_string()));
                    install_op_signer(&mut s, bundle_keypair);
                    s
                });

                // SECURITY: every op in the batch passes `admit_remote_op`
                // inside `merge_ops`: the author's signature, the clock bound,
                // then the permission matrix using OUR role map and never the
                // relayer's word. That covers the destructive `ServerDeleted`
                // tombstone along with every other payload.
                //
                // Persist every ADMITTED op into the crdt_ops table. op_log is
                // NOT serialized in the state JSON, so without this a member
                // that joined via sync serves near-empty op logs after a restart.

                // Capture membership BEFORE merge so we can detect a kick-while-offline
                // (we were a member, the synced ops remove us → self-evict on reconnect).
                let was_member_before = state.is_member(local_peer_str);

                let op_store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();
                let merged = crdt_sync::merge_ops_with(state, &incoming_ops, |op| {
                    if let Some(store) = op_store.as_ref() {
                        if op.server_id == server_id {
                            let _ = store.insert_crdt_op(op);
                        }
                    }
                });
                if let Ok(report) = &merged {
                    if report.rejected > 0 {
                        hollow_log!("[HOLLOW-SECURITY] Dropped {} unadmitted op(s) from a SyncResponse for {server_id} from {peer_str}", report.rejected);
                    }
                }
                match merged {
                    // Run even when 0 ops applied if a join is pending: the joiner
                    // may have adopted a ServerStateSnapshot already (the
                    // responder's op log can be compacted), and the join must complete.
                    // An anchored joiner completes only once the fold admitted us: a
                    // batch that founds nothing or admits someone else is no join.
                    Ok(report) if (report.applied > 0 || pending_server_joins.contains_key(&server_id))
                        && (!pending_server_joins.contains_key(&server_id)
                            || state.anchor() == crate::crdt::server_state::Anchor::Legacy
                            || state.is_member(local_peer_str)) => {
                        let applied = report.applied;
                        hollow_log!("[HOLLOW-CRDT] Applied {applied} ops for server {server_id}");

                        // Multi-device (Step 6): fold any device-keyed members a
                        // not-yet-upgraded peer's ops introduced into their master.
                        // Anchored servers are master-keyed from their first op.
                        if state.anchor() == crate::crdt::server_state::Anchor::Legacy {
                            state.canonicalize_members(|id| super::resolver::resolve(id));
                        }

                        if let Ok(json) = serde_json::to_string(&state) {
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                            }
                        }

                        if let Some(completed) = pending_server_joins.remove(&server_id) {
                            let server_name = state.name().to_string();
                            hollow_log!("[HOLLOW-CRDT] Server join completed: {server_id} ({server_name})");

                            // The persisted tile is done with. A PARKED join owes
                            // the UI two more beats: admitted (said BEFORE
                            // ServerJoined so the tile turns into a server rather
                            // than blinking out), then READY once the MLS leaf that
                            // lets it read the channel actually forms.
                            crdt_store.delete_pending_join(server_id.clone());
                            if completed.parked || completed.refused.is_some() {
                                let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
                                    server_id: server_id.clone(),
                                    state: "admitted".to_string(),
                                    reason: String::new(),
                                }).await;
                                awaiting_mls_after_parked_join.insert(server_id.clone());
                            }

                            // Drop stale MLS group from before ban/leave — forces fresh
                            // KeyPackage exchange so the rejoining peer gets a clean epoch.
                            if let Some(mls_mgr) = mls.as_mut() {
                                if mls_mgr.has_group(&server_id) {
                                    hollow_log!("[HOLLOW-MLS] Dropping stale MLS group for {server_id} on rejoin");
                                    mls_mgr.remove_group(&server_id);
                                    persist_mls_state(mls_mgr, crypto_store);
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
                            // responder's cache. Online members are covered by the
                            // per-peer ProfileRequest on sync, but during a pending
                            // join this server was not in server_states yet.
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
                                        super::olm_lane::carry(
                                            ws_cmd_tx, peer_str, None,
                                            &HavenMessage::ProfileRequestFor { target_peer_id: member_id.clone() },
                                            super::olm_lane::NoSession::Queue,
                                        );
                                        proxy_count += 1;
                                    }
                                }
                            }

                            {
                                let local_peer = local_peer_str.to_string();
                                let pledge_op = (state.get_storage_pledge(&local_peer) == 0)
                                    .then(|| {
                                        let min_pledge_bytes = state.min_pledge_mb().saturating_mul(1024 * 1024);
                                        hollow_log!("[HOLLOW-VAULT] Auto-pledging {} MB for server {server_id}", min_pledge_bytes / (1024 * 1024));
                                        state.author_checked(CrdtPayload::StoragePledgeChanged {
                                            peer_id: local_peer.clone(),
                                            pledge_bytes: min_pledge_bytes,
                                        })
                                    })
                                    .flatten();
                                if let Some(pledge_op) = pledge_op {

                                    if let Ok(json) = serde_json::to_string(&state) {
                                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                            let _ = store.save_server_state(&server_id, &json);
                                            let _ = store.insert_crdt_op(&pledge_op);
                                        }
                                    }

                                    // Broadcast the pledge op to connected members: MLS when we hold
                                    // the group, PLUS the plaintext `CrdtOpBroadcast` twin
                                    // UNCONDITIONALLY. A CRDT op is author-signed and idempotent, so a
                                    // member with a working leaf just applies it twice, while a member
                                    // with NO leaf or at a skewed epoch is otherwise invisible here.
                                    //
                                    // `StoragePledgeChanged` does not touch `members`, so reading the
                                    // target list after `apply_op` is safe, unlike `ServerDeleted`.
                                    if let Ok(op_json) = serde_json::to_string(&pledge_op) {
                                        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                                        if mls_ok {
                                            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                                            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store) {
                                                hollow_log!("[HOLLOW-MLS] CrdtOp pledge broadcast failed: {e}");
                                            }
                                        }
                                        let pledge = HavenMessage::CrdtOpBroadcast {
                                            server_id: server_id.clone(),
                                            op_json: op_json.clone(),
                                        };
                                        if let Some(json) = super::olm_lane::carried_json(&pledge) {
                                            super::olm_lane::carry_to_identities(
                                                ws_cmd_tx, ws_room_peers, state.members.keys(), &local_peer, &json,
                                                super::olm_lane::NoSession::Queue,
                                            );
                                        }
                                    }
                                }
                            }

                            // Establish an Olm session with every server member we are
                            // connected to but lack one for. Members are master-keyed, so
                            // bootstrap with each online DEVICE of every member.
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

                            // MLS: we hold the server but not a leaf in its group, so
                            // ask for one.
                            //
                            // Exactly ONE KeyPackage may leave here. A second from the
                            // same device straddling a batch tick is a remove + re-add:
                            // two commits, the removal evicting the leaf the first
                            // Welcome just gave us, and the eviction path then asks for
                            // a third.
                            //
                            // The target is the one every other bootstrap path uses
                            // (`server_bootstrap_target`), because the receiving handler
                            // only ACTS as the owner or as a group holder. When that send
                            // lands we STAMP the throttle, which stops the
                            // message-triggered rescue firing a duplicate.
                            let want_leaf = mls.as_ref().is_some_and(|m| !m.has_group(&server_id));
                            if want_leaf && completed.parked && completed.key_package.is_some() {
                                // Rung 2: the ring copy of this request CARRIED a
                                // KeyPackage, so the member that admitted us has already
                                // seated our leaf and the Welcome waits in our own relay
                                // buffer, behind the SyncResponse we are handling. Asking
                                // again would mint a second package and turn that Welcome
                                // into a remove + re-add. Expecting a Welcome is what the
                                // eviction grace already means, so if none arrives inside
                                // it the batch tick asks once through the ordinary path.
                                mls_bootstrap_requested.insert(server_id.clone(), std::time::Instant::now());
                                mls_welcome_grace.insert(server_id.clone(), std::time::Instant::now());
                                hollow_log!("[HOLLOW-MLS] Parked join for {server_id} carried a KeyPackage; expecting a buffered Welcome");
                            } else if want_leaf
                                && let Some(mls_mgr) = mls.as_ref()
                                && let Ok(kp_bytes) = crate::node::crypto_handler::mint_key_package(mls_mgr, crypto_store)
                            {
                                // ONE package per attempt, minted before we know which
                                // of the two addresses it will go to. Every mint writes
                                // private init and leaf-encryption keys into persisted
                                // MLS storage that only a Welcome consumes, and the
                                // frame is byte-identical either way.
                                let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                    server_id: server_id.clone(),
                                    key_package: kp_b64,
                                    channel_id: None,
                                }).unwrap_or_default();
                                let target = crate::node::crypto_handler::server_bootstrap_target(
                                    state, local_peer_str, ws_room_peers,
                                )
                                .filter(|t| !super::resolver::same_identity(t, local_peer_str));
                                let sent = match &target {
                                    Some(t) => send_raw_to_identity(ws_cmd_tx, ws_room_peers, t, data.clone()),
                                    None => 0,
                                };
                                if sent > 0 {
                                    mls_bootstrap_requested.insert(server_id.clone(), std::time::Instant::now());
                                    hollow_log!(
                                        "[HOLLOW-MLS] Sent bootstrap KeyPackage to {} ({sent} device(s)) for {server_id}",
                                        target.as_deref().unwrap_or_default(),
                                    );
                                } else {
                                    send_raw_to_peer(ws_cmd_tx, ws_room_peers, peer_str, data);
                                    hollow_log!("[HOLLOW-MLS] Sent bootstrap KeyPackage to join responder {peer_str} for {server_id} (no bootstrap target yet)");
                                }
                            }
                        }

                        // Reconcile changes that happened while we were OFFLINE, now that
                        // the grow-only sync delivered the ops: a DELETION tombstone, a
                        // BAN, or a plain KICK or our own LEAVE fanned by a sibling.
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
                            // Self-eviction reconciled from sync: tear down DURABLY, not just
                            // the UI event. Without removing the state and DB row the shell
                            // reloads on restart, re-lists the server, and the sibling
                            // re-announce path can even re-ADD us to a server we left,
                            // authored by a non-member, so real members reject it and we fork.
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
            apply_remote_crdt_op(
                server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays,
                mls, crypto_store, pending_mls_key_packages, pending_mls_removals,
                voice_channel_participants, voice_channel_gossip_mode,
                pending_server_joins, bundle_keypair,
                db_path, db_passphrase, local_peer_str, device_peer_id, peer_str,
                server_id, op_json,
            ).await;
        }
        HavenMessage::ServerJoinRequest {
            server_id, twitch_proof_json, nsfw_confirmed,
            requested_at, device_list, parked, key_package, reply_key, card, avatar_b64,
        } => {
            hollow_log!("[HOLLOW-CRDT] ServerJoinRequest from {peer_str} for server {server_id} (nonce {requested_at}, parked {parked})");

            if !server_states.contains_key(&server_id) {
                hollow_log!("[HOLLOW-CRDT] ServerJoinRequest for unknown server {server_id}");
                return;
            }

            // ATTRIBUTION FIRST, before anything reads the joiner's identity.
            //
            // A PARKED request is read out of a TTL ring by a member that has
            // never been online with the joiner, so it holds no device-to-master
            // link: `resolve()` hands the device straight back and the
            // MASTER-keyed CRDT member entry would be created under a device id.
            // Every gate below reads this value too, so a wrong answer here is a
            // wrong ban check, not just a wrong label.
            //
            // So the request CARRIES the joiner's roster and attribution becomes
            // cryptographic: the sender device must be a member of it (design ID-1).
            // `if list.is_some()` must not be the bypass.
            let member_master = match device_list.as_ref() {
                Some(list) => {
                    // Ingest through the SAME path every other carried roster uses,
                    // so the resolver, the device store and every later send agree.
                    let outcome = super::roster_book::ingest(
                        event_tx, ws_cmd_tx, master_peer_str, device_peer_id,
                        peer_str, device_list.clone(), db_path, db_passphrase,
                    ).await;
                    enforce_device_revocations(
                        &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                        local_peer_str, ws_room_peers, pending_mls_removals,
                    );
                    let Some(master) = super::roster_book::carried_master(list, peer_str) else {
                        hollow_log!("[HOLLOW-CRDT] Dropping ServerJoinRequest from {peer_str} for {server_id}: its roster does not make the sender one of its devices");
                        return;
                    };
                    master
                }
                // A pre-parked-joins client: all we have is the resolver, which
                // works whenever the two have actually met. Byte-for-byte the
                // old behaviour.
                None => super::resolver::resolve(&peer_str),
            };
            let resolution_key = format!("{server_id}|{member_master}");
            // A request sealed before the joiner last left was answered in an earlier
            // membership; a ring or relay handing it back must not re-admit them. No clock
            // slack: a voluntary leave is stamped by the joiner's own clock.
            if server_states.get(&server_id).and_then(|s| s.left_at(&member_master))
                .is_some_and(|left| frame_ts_ms.max(0) as u64 <= left)
            {
                hollow_log!("[HOLLOW-SECURITY] Ignored a join request from {peer_str} for {server_id} sealed before the joiner left");
                return;
            }

            // Who is asking: the card the request carries, when it is the joiner's own.
            if let Some(card) = card.filter(|c| c.master == member_master && super::profile_card::card_holds(c)) {
                use base64::Engine;
                let avatar = (!avatar_b64.is_empty())
                    .then(|| base64::engine::general_purpose::STANDARD.decode(&avatar_b64).ok())
                    .flatten()
                    .filter(|b| b.len() <= super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES);
                if super::profile_card::store_card(&card, avatar.as_deref(), db_path, db_passphrase) {
                    let _ = event_tx.send(NetworkEvent::ProfileUpdated { peer_id: card.master.clone() }).await;
                }
            }

            if let Some(state) = server_states.get_mut(&server_id) {
                // Every answer is sealed to the reply key the request carried, from our
                // newest door, and the other members' copy to that door and the invite key.
                let answer = super::join_lane::Answer {
                    server_id: &server_id,
                    our_device: device_peer_id,
                    door: state.join_lock.newest_door(),
                    invite: state.join_secret().map(|s| super::sealed_box::public_of(&s)),
                    joiner_device: peer_str,
                    joiner_master: &member_master,
                    reply_key: &reply_key,
                    requested_at,
                    join_ring: super::ring_auth::topic(state, super::types::JOIN_TOPIC),
                };

                // Multi-device: a SAME-IDENTITY requester is one of OUR OWN devices,
                // a sibling co-owning this server. It skips the ban, Twitch and
                // owner-verify gates, which are for strangers, and is still added.
                let is_sibling = super::resolver::same_identity(peer_str, local_peer_str)
                    && peer_str != local_peer_str;

                let already_member = state.members_list().iter()
                    .any(|m| super::resolver::same_identity(&m.peer_id, &member_master));

                let catchup_secs = state.relay_catchup_secs();

                if parked {
                    // A PARKED copy is held to stricter rules than a live one. It
                    // was written into a shared ring, possibly days ago, and is read
                    // by whoever comes back, so it must never bypass a gate.

                    // Already a member: a copy from before its admission is history we
                    // are reading back. One sealed since is a member asking again because
                    // our answer came from a door that moved before it arrived: it gets
                    // its state again, and no second admission.
                    if already_member
                        && state.member_since(&member_master).is_none_or(|since| requested_at <= since as i64)
                    {
                        return;
                    }

                    // Somebody already answered this exact ask (or a newer one).
                    // The resolution rides the same ring, so every member that
                    // catches up learns this before it reaches the request.
                    if join_resolutions.get(&resolution_key).is_some_and(|t| *t >= requested_at) {
                        hollow_log!("[HOLLOW-CRDT] Parked join for {member_master} on {server_id} is already resolved, skipping");
                        return;
                    }

                    // TWITCH-GATED SERVERS used to wait here for co-presence,
                    // because the parked copy carried no proof: the old JSON named
                    // a Twitch account and a ring frame is readable by anyone with
                    // the invite. A follow CREDENTIAL names a channel, an age
                    // bucket and a tier, so it can ride the ring like the rest.
                } else {
                    // COORDINATOR GATE. This handler is the expensive half of a join: a
                    // MemberAdded op, a full ServerStateSnapshot and the ENTIRE op log,
                    // all aimed at one joiner. Ungated, every online member ran the
                    // whole thing, which measured super-linear (~48 SendDirect per join
                    // at 5 members, ~342 at 13). The MLS half was already election-gated
                    // to one committer; this puts the CRDT half on the SAME election.
                    //
                    // A repeat request inside the window means the joiner's retry fired,
                    // so everyone serves and the cost degrades to the old fan-out rather
                    // than a failed join. Siblings are never gated. A PARKED copy never
                    // touches this map: writing here would hand the next live ask a bypass.
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
                        // Candidates are the CRDT members, minus the joiner itself: a
                        // REJOINING member is already in `members`, and electing them
                        // would leave nobody serving.
                        let candidates: Vec<String> = state.members.keys()
                            .filter(|m| !super::resolver::same_identity(&member_master, m))
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
                }

                // Ban check, before any other verification. Keyed by the joiner's
                // MASTER, which is what the ban list holds: a parked request's raw
                // device id resolves to itself and would sail straight past it.
                if !is_sibling && state.is_banned(&member_master) {
                    hollow_log!("[HOLLOW-CRDT] Rejecting join from banned peer {peer_str} (master {member_master}) for server {server_id}");
                    if requested_at != 0 {
                        join_resolutions.insert(resolution_key, requested_at);
                    }
                    sync_handler::send_join_rejection(ws_cmd_tx, &answer, "banned", catchup_secs);
                    return;
                }

                // Twitch verification gate, offline against the root pinned in
                // `support_creds.rs`. The joiner ships a blind-signed follow
                // credential bound to its own MASTER; we contact nobody and learn
                // nothing beyond the channel, bucket and tier this server gates on.
                if !is_sibling { if let Some(twitch_settings) = twitch::TwitchServerSettings::from_server_state(state) {
                    let reject_reason = match &twitch_proof_json {
                        None => Some("twitch_required".to_string()),
                        Some(entry_json) => twitch::validate_follow_credential(
                            entry_json, &member_master, &twitch_settings,
                        )
                        .err(),
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
                        if requested_at != 0 && !enriched_reason.starts_with("twitch_required:") {
                            join_resolutions.insert(resolution_key, requested_at);
                        }
                        sync_handler::send_join_rejection(ws_cmd_tx, &answer, &enriched_reason, catchup_secs);
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
                                    let reason = format!("twitch_owner_offline:{server_name}");
                                    if requested_at != 0 {
                                        join_resolutions.insert(resolution_key, requested_at);
                                    }
                                    sync_handler::send_join_rejection(ws_cmd_tx, &answer, &reason, catchup_secs);
                                }
                                // Either way, non-owner does not process the join.
                                return;
                            }
                            // We ARE the owner — proceed to accept below.
                        }
                    }
                } } // close owner-verify gate + `if !is_sibling`

                // The MemberAdded op we authored, for the ring resolution: it is
                // the SAME op the broadcast below carries, so a member reading
                // the ring applies exactly what a member who was online received.
                let mut admitted_op_json: Option<String> = None;

                if !already_member {
                    // Private-server gate: an invite-only server rejects new joiners,
                    // while existing members re-joining short-circuit above. A sibling
                    // (our own device) is exempt, since it co-owns the server.
                    if !is_sibling && state.is_private() {
                        hollow_log!("[HOLLOW-CRDT] Rejecting join from {peer_str}: server {server_id} is private");
                        let reason = format!("server_private:{}", state.name());
                        if requested_at != 0 {
                            join_resolutions.insert(resolution_key, requested_at);
                        }
                        sync_handler::send_join_rejection(ws_cmd_tx, &answer, &reason, catchup_secs);
                        return;
                    }

                    // NSFW consent gate. Unlike private or full this is not a hard
                    // rejection: we reject ONCE with an `nsfw_confirm:` reason carrying
                    // the server name, the joiner's client shows the consent dialog, and
                    // it re-sends with `nsfw_confirmed=true`. Ordered after private and
                    // full so we never ask consent for a server they cannot enter.
                    if !is_sibling && state.is_nsfw() && !nsfw_confirmed {
                        hollow_log!("[HOLLOW-CRDT] NSFW consent required for {peer_str} joining {server_id}");
                        let reason = format!("nsfw_confirm:{}", state.name());
                        sync_handler::send_join_rejection(ws_cmd_tx, &answer, &reason, catchup_secs);
                        return;
                    }

                    // Member-cap gate: reject if the server is at its configured
                    // max member count. None = unlimited.
                    if let Some(max) = state.max_members() {
                        if state.members_list().len() as u32 >= max {
                            hollow_log!("[HOLLOW-CRDT] Rejecting join from {peer_str}: server {server_id} is full ({max} max)");
                            let reason = format!("server_full:{}:{}", state.name(), max);
                            if requested_at != 0 {
                                join_resolutions.insert(resolution_key.clone(), requested_at);
                            }
                            sync_handler::send_join_rejection(ws_cmd_tx, &answer, &reason, catchup_secs);
                            return;
                        }
                    }

                    // Add the new member via CRDT op, keyed by the MASTER identity.
                    // The short display label is derived from the master id.
                    let display_name = format!("{}...{}", &member_master[..4.min(member_master.len())], &member_master[member_master.len().saturating_sub(4)..]);
                    // Authored through the SAME rules every member re-checks (E7), so
                    // the Twitch credential rides along for them to verify.
                    let follow = twitch::TwitchServerSettings::from_server_state(state)
                        .and(twitch_proof_json.clone());
                    let Some(op) = state.author_checked(CrdtPayload::MemberAdded {
                        peer_id: member_master.clone(),
                        display_name,
                        follow,
                    }) else {
                        hollow_log!("[HOLLOW-CRDT] Not admitting {member_master} to {server_id}: the admission rules refuse it here");
                        return;
                    };

                    // A follow credential names no Twitch account at all, by
                    // design, so there is nothing to mint here and nothing to
                    // display: the purple chip draws from the joiner's OWN
                    // verified account credential on their profile.

                    if let Ok(json) = serde_json::to_string(&state) {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Broadcast MemberAdded to other peers: MLS when we hold the group,
                    // PLUS the plaintext `CrdtOpBroadcast` twin UNCONDITIONALLY. Our own
                    // encrypt succeeding says nothing about whether an existing member
                    // can DECRYPT: one with no leaf or at a skewed epoch never saw the
                    // new member appear. The op is author-signed and idempotent.
                    //
                    // `MemberAdded` drains nobody, so reading the members after it
                    // applied is safe (unlike `ServerDeleted`); the joiner gets its
                    // copy in the sync answer below.
                    if let Ok(op_json) = serde_json::to_string(&op) {
                        admitted_op_json = Some(op_json.clone());
                        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if mls_ok {
                            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store) {
                                hollow_log!("[HOLLOW-MLS] CrdtOp MemberAdded broadcast failed: {e}");
                            }
                        }
                        let added = HavenMessage::CrdtOpBroadcast {
                            server_id: server_id.clone(),
                            op_json: op_json.clone(),
                        };
                        if let Some(json) = super::olm_lane::carried_json(&added) {
                            let others = state.members.keys().filter(|m| **m != member_master);
                            super::olm_lane::carry_to_identities(
                                ws_cmd_tx, ws_room_peers, others, local_peer_str, &json,
                                super::olm_lane::NoSession::Queue,
                            );
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

                // RUNG 2: a PARKED request carries the joiner's KeyPackage, so the
                // leaf goes in the same batch as the membership and the joiner comes
                // back to a server it can READ rather than one it can only see.
                //
                // This sits here and nowhere earlier because everything above it is
                // a gate on this exact request: the attribution behind
                // `member_master`, the ban list, the Twitch credential,
                // owner-verify, private, NSFW consent and the member cap. A leaf is
                // the strongest thing a member can hand out.
                //
                // And only when the package's leaf is bound to the device attribution
                // named and to the joiner's master: that device's key signs it, so
                // not even the relay can hand us a leaf in someone else's name.
                if parked && let Some(kp_b64) = key_package.as_ref() {
                    match base64::engine::general_purpose::STANDARD.decode(kp_b64) {
                        Err(e) => hollow_log!("[HOLLOW-MLS] Carried KeyPackage from {peer_str} for {server_id} is not valid base64: {e}"),
                        Ok(kp_bytes) => match crate::crypto::MlsManager::key_package_identity(&kp_bytes) {
                            Err(e) => hollow_log!("[HOLLOW-MLS] Carried KeyPackage from {peer_str} for {server_id} does not parse: {e}"),
                            Ok(leaf) if leaf.bound().is_none_or(|id| id.device != peer_str || id.master != member_master) => hollow_log!(
                                "[HOLLOW-SECURITY] Dropping carried KeyPackage from {peer_str}: its leaf {leaf:?} is not this device of {member_master}"
                            ),
                            Ok(_) => {
                                let is_owner = state.roles.get(local_peer_str)
                                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                    .unwrap_or(false);
                                let mut queued = false;
                                if let Some(mls_mgr) = mls.as_mut() {
                                    // Lazily create the server group exactly as
                                    // the MlsKeyPackage handler does: only the
                                    // owner may, and only when nobody holds one.
                                    if !mls_mgr.has_group(&server_id) && is_owner {
                                        hollow_log!("[HOLLOW-MLS] Lazily creating MLS group {server_id} for a parked admission");
                                        if let Err(e) = mls_mgr.create_group(&server_id) {
                                            hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}");
                                        } else {
                                            persist_mls_state(mls_mgr, crypto_store);
                                        }
                                    }
                                    if mls_mgr.has_group(&server_id) {
                                        let already_leaf = mls_mgr.group_members(&server_id)
                                            .iter().any(|m| m == peer_str);
                                        let already_queued = pending_mls_key_packages
                                            .get(&server_id)
                                            .is_some_and(|q| q.iter().any(|(p, _)| p == peer_str));
                                        if !already_leaf && !already_queued {
                                            pending_mls_key_packages
                                                .entry(server_id.clone())
                                                .or_default()
                                                .push((peer_str.to_string(), kp_bytes));
                                            hollow_log!("[HOLLOW-MLS] Queued the carried KeyPackage of parked joiner {peer_str} for {server_id}");
                                        }
                                        queued = true;
                                    }
                                }
                                if !queued {
                                    // Rung 1 behaviour, and an accepted residual:
                                    // we can admit a member without holding the
                                    // group, and only a holder can seat a leaf.
                                    hollow_log!("[HOLLOW-MLS] Parked joiner {peer_str} admitted without a leaf on {server_id}: no group held here, its leaf waits for co-presence");
                                }
                            }
                        },
                    }
                }

                // A LEGACY server's log is capped and predates signing, so the
                // joiner needs a STATE snapshot first; an anchored one is rebuilt from
                // its founding op or checkpoint, and gets none. WS delivery is FIFO,
                // so it lands before the SyncResponse.
                //
                // Both go to the DETERMINISTIC server room, not through a presence
                // lookup: the joiner of a PARKED request is not here, and a targeted
                // frame into a room the target is not in is what the relay buffers
                // and replays. That buffered pair IS how a parked join completes.
                let legacy = state.anchor() == crate::crdt::server_state::Anchor::Legacy;
                if let Some(state_json) = legacy.then(|| serde_json::to_string(&state).ok()).flatten() {
                    answer.reply(ws_cmd_tx, &HavenMessage::ServerStateSnapshot {
                        server_id: server_id.clone(),
                        state_json,
                    });
                }

                // Send full server state to the joiner (all ops so they can reconstruct)
                let all_ops: Vec<&crate::crdt::operations::CrdtOp> = state.op_log.iter().collect();
                if let Ok(ops_json) = serde_json::to_string(&all_ops) {
                    hollow_log!("[HOLLOW-CRDT] Sending snapshot + {} ops to joiner {peer_str}", all_ops.len());
                    answer.reply(ws_cmd_tx, &HavenMessage::SyncResponse {
                        server_id: server_id.clone(),
                        ops_json,
                    });
                }

                // Tell the ring (and so every member that is not here) that this
                // ask is answered. Without it, the next member to return reads
                // the same request and serves the whole join again.
                if requested_at != 0 {
                    join_resolutions.insert(resolution_key, requested_at);
                    if catchup_secs > 0 {
                        sync_handler::publish_join_resolution(ws_cmd_tx, &answer, true, "", admitted_op_json);
                    }
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
            }
        }

        // A member's answer to a join, read out of the room's `~join` ring.
        // Two jobs: it stops US re-serving a join somebody else answered, and
        // it carries the `MemberAdded` op so an absent member still converges.
        HavenMessage::ServerJoinResolved {
            server_id, joiner_master, requested_at, admitted, reason, op_json,
        } => {
            hollow_log!("[HOLLOW-CRDT] ServerJoinResolved from {peer_str} for {joiner_master} on {server_id} (admitted {admitted}, reason '{reason}')");

            // JOINER SIDE FIRST: this may be the answer to OUR OWN parked ask.
            // It only ever acts on the exact ask it names, so a copy replayed
            // out of a three-day ring cannot resolve a later request.
            if let Some(pending) = pending_server_joins.get(&server_id) {
                if joiner_master == local_peer_str && requested_at == pending.requested_at {
                    if admitted {
                        // Nothing to do: the admitting member's buffered snapshot
                        // and SyncResponse are what complete us, and if the relay
                        // dropped them our live re-request does it on next co-presence.
                        hollow_log!("[HOLLOW-CRDT] Our parked join for {server_id} was admitted; waiting for the buffered snapshot");
                        return;
                    }
                    // The same landing pad as the targeted refusal, so the two
                    // legs of one answer can never diverge. An INTERACTIVE reason
                    // should be unreachable by construction, but a hostile member
                    // could write one, which is why this routes through the shared
                    // handler: the worst case is a dialog, not a poisoned tile.
                    sync_handler::handle_join_refused(
                        pending_server_joins, event_tx, crdt_store_actor, server_id, reason,
                    ).await;
                    return;
                }
            }

            // A resolution is only meaningful for a server we hold, and only
            // from somebody entitled to have made it. Anyone in the room can
            // publish on the topic, so CRDT membership of the SENDER is the gate.
            if !server_states.contains_key(&server_id) {
                return;
            }
            let sender_master = super::resolver::resolve(&peer_str);
            let sender_is_member = server_states
                .get(&server_id)
                .is_some_and(|s| s.members_list().iter()
                    .any(|m| super::resolver::same_identity(&m.peer_id, &sender_master)));
            if !sender_is_member {
                hollow_log!("[HOLLOW-SECURITY] Ignoring ServerJoinResolved from non-member {peer_str} for {server_id}");
                return;
            }

            // A resolution cannot answer an ask made after it was sealed: a far-future
            // stamp would freeze every later ask of that joiner.
            if requested_at > frame_ts_ms.saturating_add(super::frame_auth::LIVE_SKEW_MS) {
                hollow_log!("[HOLLOW-SECURITY] Ignoring ServerJoinResolved from {peer_str} naming an ask after its own seal");
                return;
            }
            // Max-wins: an older copy replayed out of the ring must never undo a
            // newer answer.
            let key = format!("{server_id}|{joiner_master}");
            let newest = join_resolutions.get(&key).copied().unwrap_or(0);
            if requested_at > newest {
                join_resolutions.insert(key, requested_at);
            }

            // The carried op goes through the ONE ingest path, gates included
            // (`op_allowed` on the op's AUTHOR, `insert_crdt_op`, the payload's
            // own event). Never a second, weaker apply.
            if let Some(op_json) = op_json {
                apply_remote_crdt_op(
                    server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays,
                    mls, crypto_store, pending_mls_key_packages, pending_mls_removals,
                    voice_channel_participants, voice_channel_gossip_mode,
                    pending_server_joins, bundle_keypair,
                    db_path, db_passphrase, local_peer_str, device_peer_id, peer_str,
                    server_id, op_json,
                ).await;
            }
        }

        HavenMessage::ServerJoinRejected { server_id, reason, requested_at } => {
            hollow_log!("[HOLLOW-CRDT] Join rejected for {server_id}: {reason} (nonce {requested_at})");
            // A join request reaches every online member, so each one may send
            // its own refusal. Only the FIRST for an in-flight join is acted on,
            // which dedups the popup (otherwise the joiner sees N).
            let Some(pending) = pending_server_joins.get(&server_id) else { return };
            // NONCE GUARD. This frame rides the deterministic server room, so the
            // relay buffers it for an absent joiner and replays it on that
            // device's next join, which is normally the user asking AGAIN. A copy
            // naming an older ask must not touch the newer one.
            if requested_at != pending.requested_at {
                hollow_log!("[HOLLOW-CRDT] Ignoring a rejection for {server_id} that names ask {requested_at}, ours is {}", pending.requested_at);
                return;
            }
            sync_handler::handle_join_refused(
                pending_server_joins, event_tx, crdt_store_actor, server_id, reason,
            ).await;
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
                if super::sync_handler::kick_predates_membership(state, &local_peer, frame_ts_ms) {
                    hollow_log!("[HOLLOW-SECURITY] Ignored a kick from {peer_str} sealed before we joined {server_id}");
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast for unknown server {server_id}");
                return;
            }

            if server_states.remove(&server_id).is_some() {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.delete_server_state(&server_id);
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

        HavenMessage::ChannelSyncRequest { server_id, channel_id, since_timestamp, sender_timestamps, gap } => {
            

            // Room gating: only respond for servers we are a member of, and only
            // for a channel this requester may SEE. The per-channel MLS subgroup
            // keeps a non-qualifier out of live traffic, and backfill was the way
            // straight around it, because this responder used to serve any
            // channel's stored rows, file headers and AES keys included.
            let visible = match server_states.get(&server_id) {
                Some(state) => super::crypto_handler::channel_readable_by(state, peer_str, &channel_id),
                None => return,
            };
            if !visible {
                hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelSyncRequest from {peer_str} for {channel_id}: not visible to that member");
                return;
            }

            // Dedup: if we already responded to this peer+channel within 2s, skip.
            // Prevents flood from multiple parallel sync triggers on the requester's side.
            let resp_dedup_key = format!("{server_id}:{channel_id}:resp:{peer_str}");
            if channel_sync_sent.get(&resp_dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
                return;
            }
            channel_sync_sent.insert(resp_dedup_key, std::time::Instant::now());

            hollow_log!("[HOLLOW-SYNC] ChannelSyncRequest from {peer_str} for {channel_id} in {server_id} since {since_timestamp} (per-sender: {} entries, gap={})", sender_timestamps.len(), gap.is_some());

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                // Per-sender sync when watermarks were sent, legacy single-timestamp
                // fallback otherwise — shared with the MLS/Olm responders.
                if let Ok((envelope, count)) = super::sync_handler::build_channel_sync_batch(
                    &store, &server_id, &channel_id, since_timestamp, &sender_timestamps, gap.as_ref(),
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

        HavenMessage::DmSyncRequest { since_timestamp, both_directions, gap } => {
            hollow_log!("[HOLLOW-SYNC] DmSyncRequest from {peer_str} since {since_timestamp} (both_directions={both_directions}, gap={})", gap.is_some());
            if super::blocklist::is_blocked(peer_str) {
                hollow_log!("[HOLLOW-SECURITY] Dropped a DmSyncRequest from blocked {peer_str}");
                return;
            }

            // Multi-device: the requester sends its DEVICE id, but our DM rows for
            // that person are keyed by their MASTER id. A multi-device requester
            // therefore matched ZERO rows under the raw device id and the catch-up
            // sync silently delivered nothing. Resolve to the master for the
            // lookup; the transport send still targets the raw device.
            let convo_peer = super::resolver::resolve(peer_str);

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                // Multi-device peer-fallback: a multi-device requester sets
                // `both_directions` so we re-serve the requester's OWN messages
                // (stored here as is_mine=0) alongside ours, which are otherwise
                // stranded when that device is offline.
                let gap_rows = gap
                    .map(|g| {
                        store
                            .get_dm_gap_messages(&convo_peer, &g, !both_directions, 200)
                            .unwrap_or_default()
                    })
                    .unwrap_or_default();
                if !gap_rows.is_empty() {
                    let super::sync_handler::SyncPage { items, .. } =
                        build_dm_sync_items(&store, &gap_rows);
                    hollow_log!("[HOLLOW-SYNC] Re-serving {} DM(s) behind {since_timestamp} to {peer_str} (convo {convo_peer})", items.len());
                    // Never paginated: whatever did not fit is still missing at the
                    // next sync and is served then.
                    send_dm_sync_reply(
                        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                        pending_messages, key_request_in_flight,
                        device_keypair, device_peer_id, peer_str,
                        &MessageEnvelope::DmSyncBatch { messages: items, has_more: None },
                    ).await;
                }

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
                        send_dm_sync_reply(
                            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                            pending_messages, key_request_in_flight,
                            device_keypair, device_peer_id, peer_str,
                            &MessageEnvelope::DmSyncBatch { messages: items, has_more },
                        ).await;
                    }
                }
            }
        }

        HavenMessage::DmSiblingSyncRequest { per_convo_since, mut gaps } => {
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
                    // The gap batch goes first and is never paginated; see the
                    // friend responder above.
                    let gap_rows = gaps
                        .remove(&convo)
                        .map(|g| store.get_dm_gap_messages(&convo, &g, false, 200).unwrap_or_default())
                        .unwrap_or_default();
                    let mut batches: Vec<(Vec<crate::storage::messages::StoredMessage>, bool)> =
                        Vec::with_capacity(2);
                    if !gap_rows.is_empty() {
                        batches.push((gap_rows, false));
                    }
                    match store.get_dm_messages_for_sibling(&convo, since, 200) {
                        Ok(m) if !m.is_empty() => batches.push((m, true)),
                        Ok(_) => {}
                        Err(e) => hollow_log!("[HOLLOW-SYNC] sibling sync read failed for {convo}: {e}"),
                    }
                    for (messages, paged) in batches {
                        let super::sync_handler::SyncPage { items, truncated } =
                            build_dm_sync_items(&store, &messages);
                        // `truncated` = the preview budget cut the page short, so
                        // more remains even when the page is under the limit.
                        let has_more = (paged && (truncated || messages.len() >= 200)).then_some(true);
                        hollow_log!(
                            "[HOLLOW-SYNC] Sending {} sibling DM(s) for convo {convo} to {peer_str} (gap={}, has_more={has_more:?})",
                            items.len(),
                            !paged
                        );
                        send_dm_sync_reply(
                            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                            pending_messages, key_request_in_flight,
                            device_keypair, device_peer_id, peer_str,
                            &MessageEnvelope::DmSiblingSyncBatch {
                                convo: convo.clone(),
                                messages: items,
                                has_more,
                            },
                        ).await;
                    }
                }
            }
        }
        HavenMessage::SiblingServerAnnounce { server_id, owner, join_key } => {
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
            // A server we hold only needs the list refresh `ServerJoined` drives in Dart
            // (a ServerUpdated nudge proved unreliable); presence sync converges its ops.
            // A pending join here would let any member's snapshot replace our state. A
            // tombstoned shell reconciles through the CRDT path, never a re-join.
            if let Some(state) = server_states.get(&server_id) {
                if !state.is_deleted() {
                    let _ = event_tx.send(NetworkEvent::ServerJoined {
                        server_id: server_id.clone(),
                        name: state.name().to_string(),
                    }).await;
                }
                return;
            }
            // Sealed to the join key like anyone's request, so it needs one: a server
            // whose owner has not set it yet is announced again on the next reconnect.
            if join_key.is_none() {
                hollow_log!("[HOLLOW-CRDT] Sibling {peer_str} announced {server_id} with no join key yet; waiting for the next announce");
                return;
            }
            hollow_log!("[HOLLOW-CRDT] Sibling {peer_str} announced server {server_id}; running join flow");
            // Lightweight inline join (mirrors handle_join_server): join the rooms, read
            // the lock, and ask whoever is in the room, the announcer included, which
            // same-identity fast-paths us. The receiver's gates are `!is_sibling`, so no
            // proof and NSFW pre-confirmed. Our signed device list attributes us to our
            // master with any member.
            let mut pending = PendingJoin {
                twitch_proof_json: None,
                nsfw_confirmed: true,
                owner_pin: owner,
                device_list: super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase),
                join_key,
                reply_secret: super::join_lane::ReplySecret::new(),
                ..Default::default()
            };
            sync_handler::request_join_lock(ws_cmd_tx, &server_id, &mut pending);
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: server_id.clone() });
            pending_server_joins.insert(server_id, pending);
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

                    // A member of this server without its MLS group lost the Welcome, so
                    // send a KeyPackage to the coordinator for bootstrap. Once per group
                    // (expires after 60s) so this cannot spam.
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
                                    if let Ok(kp_bytes) = crate::node::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
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

                match mls_mgr.decrypt_fresh(&group_key, &ciphertext) {
                    Ok(crate::crypto::Decrypted::Replay) => return,
                    Ok(crate::crypto::Decrypted::UnboundSender(raw)) => {
                        *mls_dirty = true;
                        hollow_log!("[HOLLOW-MLS] Ignoring a message in {group_key} from unbound leaf {raw}");
                        return;
                    }
                    Ok(crate::crypto::Decrypted::Fresh { plaintext, sender }) => {
                        *mls_dirty = true;
                        let sender_peer_id = sender.device.clone();
                        hollow_log!("[HOLLOW-TOPIC] DECRYPT ok for {group_key}, sender(leaf)={sender_peer_id}");

                        let envelope_str = String::from_utf8_lossy(&plaintext);
                        let envelope = match serde_json::from_str::<MessageEnvelope>(&envelope_str) {
                            Ok(env) => env,
                            Err(e) => {
                                hollow_log!("[HOLLOW-MLS] Decrypted envelope in {group_key} from leaf {sender_peer_id} failed MessageEnvelope parse ({} B) — dropped: {e}", envelope_str.len());
                                return;
                            }
                        };

                        if envelope.live_only() && super::frame_auth::is_stale(frame_ts_ms, super::frame_auth::now_ms()) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped a live signal in {group_key} from leaf {sender_peer_id} that arrived too late");
                            return;
                        }

                        // Target filtering: if this envelope has a target and it's not us, discard.
                        // The ratchet already advanced by decrypting — that's the point.
                        let local_peer = local_peer_str.to_string();
                        if let Some(target) = envelope.target() {
                            if target != local_peer {
                                return; // Not for us — discard silently.
                            }
                        }
                        let restricted = |cid: &str| {
                            server_states.get(&server_id).is_some_and(|s| s.channel_uses_subgroup(cid))
                        };
                        if !crate::node::crypto_handler::mls_envelope_fits_group(
                            &envelope, &server_id, msg_channel_id.as_deref(), restricted,
                        ) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED envelope decrypted in {group_key} from leaf {sender_peer_id}: it names another server, channel or a DM");
                            return;
                        }

                        // The leaf proves both the sending DEVICE and its MASTER:
                        // `sender_master` for attribution (channel messages, edits and
                        // reactions are signed by the master), `sender_peer_id` for
                        // replies and transport. A device the master's roster does not
                        // admit speaks for nobody, whatever the master key signed for it.
                        if super::resolver::disowns(&sender.master, &sender.device) {
                            hollow_log!("[HOLLOW-SECURITY] Dropped an envelope in {group_key} from leaf {sender_peer_id}: its master's roster does not admit it");
                            return;
                        }
                        let sender_master = sender.master.clone();

                        match envelope {
                            MessageEnvelope::ChannelMessage { inner } => {
                                let ChannelMessagePayload { sid, cid, text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us, album } = *inner;
                                let mod_state = server_states.get(&sid);
                                message_ops::handle_envelope_channel_message(
                                    event_tx, bundle_keypair, mod_state, slow_mode_clock, &local_peer,
                                    sender_master.clone(), sid, cid, text, ts,
                                    sig, pk, mid, reply_to, file_id, link_preview, order_us, album,
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
                                if sid.is_none() {
                                    return; // DM cards ride Olm only.
                                }
                                let mod_state = sid.as_deref().and_then(|s| server_states.get(s));
                                message_ops::handle_envelope_link_preview_set(
                                    event_tx, mod_state, &sender_master, &local_peer,
                                    mid, lp, ts, sig, pk, sid, cid, frame_ts_ms,
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
                                let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref, thumb, voice, author, sha256, .. } = *inner;
                                file_handler::handle_envelope_file_header(
                                    server_states, pending_file_streams, pending_shard_streams,
                                    early_file_streams, bundle_keypair, event_tx,
                                    &server_id, sender_peer_id,
                                    fid, name, ext, mime, size, chunks, img, w, h,
                                    mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref,
                                    thumb, voice, author, sha256, false,
                                    requested_file_receipts, declined_file_ids,
                                    ws_cmd_tx, ws_room_peers,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            // -- Phase 6 new MLS dispatch branches --

                            MessageEnvelope::CrdtOp { sid, op_json } => {
                                // Detect a membership or visibility op BEFORE applying, so
                                // subgroups can be reconciled and invisible voice channels left
                                // afterwards. The op arrives via MLS and plaintext, whichever wins
                                // applies it, so BOTH paths must run the reconcile.
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
                                // self-eviction teardown as the plaintext path, or when MLS wins
                                // the race the plaintext copy no-ops and the shell survives.
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

                            MessageEnvelope::ChannelHint { sid, cid, mid, has_everyone, mentioned_names, reply_to_sender } => {
                                message_ops::deliver_channel_hint(
                                    event_tx, server_states, local_peer_str, &sender_peer_id,
                                    sid, cid, mid, has_everyone, mentioned_names, reply_to_sender,
                                ).await;
                            }

                            MessageEnvelope::Typing { sid, cid } => {
                                // A meeting holds no server state: admission to its
                                // group is the membership proof.
                                let typing_ok = super::conference::is_conference_sid(&sid)
                                    || server_states.get(&sid).is_some_and(|state| {
                                        message_ops::channel_signal_accepted(
                                            state, &sender_master, master_peer_str, &cid,
                                            crate::crdt::hlc::wall_clock_ms(),
                                        )
                                    });
                                if typing_ok {
                                    super::social::handle_envelope_typing(
                                        event_tx, sender_master.clone(), sid, cid,
                                    ).await;
                                }
                            }

                            MessageEnvelope::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list, avatar_hash, banner_hash, showcase_board, showcase_assets_b64, showcase_assets_hash, avatar_frame, avatar_anim, banner_anim, support_creds, support_creds_sig, profile_sig, profile_pk } => {
                                if peer_invisible {
                                    let _ = event_tx.send(NetworkEvent::PeerStatusChanged {
                                        peer_id: sender_peer_id.clone(),
                                        status: "invisible".to_string(),
                                    }).await;
                                }
                                let envelope_revoked = super::social::handle_envelope_profile_update(
                                    event_tx, server_states, master_peer_str,
                                    device_peer_id, ws_cmd_tx, ws_room_peers,
                                    sender_peer_id, display_name, status, about_me,
                                    updated_at, avatar_b64, banner_b64, twitch_username,
                                    device_list, avatar_hash, banner_hash, showcase_board,
                                    showcase_assets_b64, showcase_assets_hash, avatar_frame,
                                    avatar_anim, banner_anim, support_creds,
                                    support_creds_sig, profile_sig, profile_pk,
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

                            MessageEnvelope::ChannelSyncBatch { sid, cid, mut messages, total, has_more, .. } => {
                                if crypto_handler::channel_backfill_allowed_from(server_states.get(&sid), &sender_master, &cid) {
                                    messages.retain(|m| crypto_handler::backfill_author_allowed(server_states.get(&sid), &m.s, m.ts));
                                    sync_handler::handle_envelope_channel_sync_batch(
                                        olm, bundle_keypair, event_tx, ws_cmd_tx,
                                        ws_room_peers, &local_peer, &sender_peer_id,
                                        sid, cid, messages, total, has_more,
                                        crypto_store, crdt_store,
                                        db_path, db_passphrase,
                                    ).await;
                                }
                            }

                            // -- Vault envelopes via MLS --
                            // Deletions and manifests go to the whole server; every other
                            // vault envelope is one peer to another and rides Olm only.
                            MessageEnvelope::ShardDelete { sid, cid } => {
                                vault_ops::handle_shard_delete(
                                    server_states, event_tx,
                                    &sender_peer_id, sid, cid,
                                    db_path, db_passphrase,
                                ).await;
                            }

                            MessageEnvelope::VaultManifestBroadcast { sid, chid, manifest, .. } => {
                                vault_ops::ingest_vault_manifest(
                                    server_states, &sender_peer_id, &sid, &chid, &manifest,
                                    db_path, db_passphrase,
                                );
                            }

                            MessageEnvelope::ShardStore { .. }
                            | MessageEnvelope::ShardStoreAck { .. }
                            | MessageEnvelope::ShardRequest { .. }
                            | MessageEnvelope::ShardResponse { .. }
                            | MessageEnvelope::ShardMigrate { .. } => {
                                hollow_log!("[HOLLOW-MLS-VAULT] Olm-only vault envelope via MLS from {sender_peer_id}, ignoring");
                            }

                            // -- Voice channel signaling --
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

                            // VC participants and signaling are keyed by the ROUTABLE WS
                            // sender (`peer_str`), which is only believed when the leaf that
                            // encrypted the frame is that very device: the relay could
                            // otherwise hand one member's signaling to another's slot.
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
                            if sender_peer_id != peer_str => {
                                hollow_log!("[HOLLOW-SECURITY] Dropping voice signal in {group_key}: encrypted by leaf {sender_peer_id}, relayed as {peer_str}");
                            }
                            MessageEnvelope::VoiceChannelJoin { sid, cid } => {
                                voice_handler::handle_envelope_voice_channel_join(
                                    mls_mgr, crypto_store, server_states, voice_channel_participants,
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

                            // -- Voice channel screen sharing --
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
                                ).await;
                            }

                            MessageEnvelope::VoiceChannelScreenFeedState { sid, cid, origin, forwarder, up, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_feed_state(
                                    voice_channel_participants, event_tx,
                                    peer_str.to_string(), sid, cid, origin, forwarder, up,
                                    local_peer_str,
                                ).await;
                            }

                            // -- Voice channel camera --
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

                            // DM-only envelopes should never arrive via MLS.
                            MessageEnvelope::DirectMessage { .. }
                            | MessageEnvelope::DmSyncBatch { .. }
                            | MessageEnvelope::DmSiblingSyncBatch { .. }
                            | MessageEnvelope::SessionAck => {
                                hollow_log!("[HOLLOW-MLS] Unexpected DM envelope via MLS from {sender_peer_id} — ignoring");
                            }

                            // A destruction order is a SIBLING lane message. Over MLS
                            // it would reach every member of a server instead, and no
                            // member of one can produce a valid order for our master.
                            MessageEnvelope::DestroyIdentityOrder { .. } => {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED destruction order envelope via MLS from {sender_peer_id}");
                            }

                            // A 1:1 call signal is Olm-direct by contract. Over MLS
                            // it would be readable by, and forgeable by, every other
                            // member of the group, SFrame key and all.
                            MessageEnvelope::CallSignal { .. } => {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED call signal envelope via MLS from {sender_peer_id}");
                            }

                            // Carried messages are Olm-direct by contract: a group
                            // would show them to every member.
                            MessageEnvelope::Carried { .. } => {
                                hollow_log!("[HOLLOW-SECURITY] REJECTED carried envelope via MLS from {sender_peer_id}");
                            }

                            // The forwarder control plane is Olm-direct inside the
                            // fwd:{forwarder} room by contract, and the forwarder holds
                            // no group keys, so fwd_* over MLS is always misdirected.
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
                    Err(crate::crypto::DecryptFail::Garbage(e)) => {
                        hollow_log!("[HOLLOW-MLS] Ignoring an undecryptable frame for {group_key} from {peer_str}: {e}");
                    }
                    Err(crate::crypto::DecryptFail::Stale(e)) => {
                        hollow_log!("[HOLLOW-MLS] Decrypt failed for {group_key}: {e}");

                        // Immediately request sync from the sender. Server group: all
                        // subscribed channels, since the dropped message came via topic
                        // routing for one. Subgroup: just that one. A 5s dedup prevents a flood.
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
                                    let state = server_states.get(&server_id);
                                    for cid in sync_cids.iter().filter(|c| crate::node::crypto_handler::sync_partner(state, peer_str, Some(c))) {
                                        super::olm_lane::carry(
                                            ws_cmd_tx, peer_str, None,
                                            &super::sync_handler::channel_sync_request(&store, &server_id, cid, true),
                                            super::olm_lane::NoSession::Queue,
                                        );
                                    }
                                    hollow_log!("[HOLLOW-MLS] Requested immediate sync from {peer_str} for {} channel(s) in {group_key}", sync_cids.len());
                                }
                            }
                        }

                        // Server group: ALSO request a CRDT op-log sync, on a SHORTER dedup
                        // than the message sync. A WrongEpoch failure usually means the sender
                        // is ahead and may have broadcast ops we cannot decrypt (a fresh
                        // channel, a visibility change) that per-channel sync can never
                        // recover. A 1s dedup lets back-to-back ops each trigger a delta.
                        if msg_channel_id.is_none()
                            && crate::node::crypto_handler::sync_partner(server_states.get(&server_id), peer_str, None)
                        {
                            let op_dedup = format!("mls_fail_opsync:{group_key}:{peer_str}");
                            if !channel_sync_sent.get(&op_dedup).is_some_and(|t| t.elapsed() < Duration::from_secs(1)) {
                                channel_sync_sent.insert(op_dedup, std::time::Instant::now());
                                if let Some(state) = server_states.get(&server_id) {
                                    let our_vector = StateVector::from_server_state(state);
                                    if let Ok(sv) = serde_json::to_string(&our_vector) {
                                        super::olm_lane::carry(
                                            ws_cmd_tx, peer_str, None,
                                            &HavenMessage::SyncRequest {
                                                server_id: server_id.clone(),
                                                state_vector_json: sv,
                                                // A decrypt failure often IS epoch skew —
                                                // let the responder catch us up.
                                                mls_epoch: mls_mgr.epoch(&server_id).ok(),
                                            },
                                            super::olm_lane::NoSession::Queue,
                                        );
                                    }
                                }
                            }
                        }

                        // Never drop the group over frames that fail: anyone in the room can
                        // send one. Ask the authority whether we are behind or forked; its
                        // catch-up or its repair's Welcome is what moves us.
                        if let Some(state) = server_states.get(&server_id) {
                            crate::node::crypto_handler::send_epoch_probe(
                                mls_mgr, ws_cmd_tx, ws_room_peers, state, &server_id,
                                msg_channel_id.as_deref(), local_peer_str, mls_epoch_hint_cooldown,
                            );
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

            // The package's leaf must be bound to the device that sent it (its key
            // signs for it, so not even the relay can speak for another device), and
            // its certified master must be a member who is not banned; for a subgroup
            // the master must also see the channel, or the leaf would defeat it.
            let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(&key_package) {
                Ok(b) => b,
                Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode KeyPackage failed: {e}"); return; }
            };
            let sender_leaf = match crate::crypto::MlsManager::key_package_identity(&kp_bytes) {
                Ok(leaf) => match leaf.bound() {
                    Some(id) if id.device == peer_str => id.clone(),
                    _ => {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackage from {peer_str} for {group_key}: its leaf {leaf:?} is not bound to the sending device");
                        return;
                    }
                },
                Err(e) => {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackage from {peer_str} for {group_key}: {e}");
                    return;
                }
            };
            let Some(state) = server_states.get(&server_id) else {
                hollow_log!("[HOLLOW-MLS] No server state for {server_id}, skipping KeyPackage");
                return;
            };
            let rules = super::mls_authority::GroupRules::Server { state, channel: kp_channel_id.as_deref() };
            if !state.members.contains_key(&sender_leaf.master) || state.is_banned(&sender_leaf.master) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackage from {peer_str} for {group_key}: {} is not a member", sender_leaf.master);
                return;
            }
            if let Some(cid) = &kp_channel_id {
                if !state.can_see_channel(&sender_leaf.master, cid) {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED subgroup MlsKeyPackage from {peer_str}: {} cannot see channel {cid}", sender_leaf.master);
                    return;
                }
            }

            // SIBLING-RE-ADDS-SIBLING fast path (keystone regen recovery): when WE
            // hold the group and the sender is OUR OWN identity, we process it
            // directly, because the coordinator election below excludes the sender's
            // identity and would leave an owned-server keystone with nobody to re-add
            // it. The batch processor removes any STALE leaf sharing the sender's
            // credential and adds the new one to the SAME group: one epoch, no fork.
            let sibling_readd = sender_leaf.master == local_peer_str
                && super::resolver::same_identity(peer_str, local_peer_str)
                && peer_str != device_peer_id
                && mls.as_ref().is_some_and(|m| {
                    if !m.has_group(&group_key) {
                        return false;
                    }
                    // If several of OUR OWN device leaves currently hold the group, only the
                    // lowest-id one re-adds (deterministic single re-adder → no glare). The
                    // sender's (regenerating) leaf is excluded from this tiebreak set.
                    let our_leaves: Vec<String> = m.group_leaves(&group_key)
                        .into_iter()
                        .filter(|l| l.bound().is_some_and(|b| b.master == local_peer_str) && l.id() != peer_str)
                        .map(|l| l.id().to_string())
                        .collect();
                    our_leaves.iter().map(|s| s.as_str()).min() == Some(&device_peer_id[..])
                });
            if sibling_readd {
                hollow_log!("[HOLLOW-MLS] Sibling re-add: adding our own sibling {peer_str}'s regenerated leaf to {group_key} (bypassing coordinator election)");
            }

            // Distributed committer: the lowest online MLS member by MASTER identity
            // processes KeyPackages. The sender's IDENTITY is excluded from the
            // election, because they sent the KeyPackage precisely because they or a
            // sibling lost their group. By its certified master as well: a new device's
            // KeyPackage can arrive before the roster that would let us resolve it.
            if !sibling_readd { if let Some(mls_mgr) = mls.as_ref() {
                if mls_mgr.has_group(&group_key) {
                    let members: Vec<String> = mls_mgr.group_members(&group_key)
                        .into_iter()
                        .filter(|p| {
                            !super::resolver::same_identity(p, peer_str)
                                && !super::resolver::same_identity(p, &sender_leaf.master)
                        })
                        .collect();
                    // Server group: prefer the OWNER as the single authoritative
                    // committer, which keeps epochs linear and avoids the
                    // non-owner-committer divergence. A subgroup elects the lowest master.
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
                            .filter(|m| !super::resolver::same_identity(peer_str, m) && **m != sender_leaf.master)
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

                // Step 1: queue stale leaves for removal in the same commit as the add,
                // so the Welcome carries a clean tree (every leaf bound and a member).
                for stale_peer in super::mls_authority::stale_leaves(
                    &mls_mgr.group_leaves(&group_key), &device_peer_id, &rules,
                ) {
                    hollow_log!("[HOLLOW-MLS] Queuing stale/ineligible MLS leaf {stale_peer} for batch removal from {group_key}");
                    pending_mls_removals.entry(group_key.clone()).or_default().push(stale_peer);
                }

                // Step 2: If the SENDING DEVICE already has a leaf, queue THAT exact
                // leaf for batch removal + re-add (recovery). Match the exact device
                // id — never a sibling's live leaf (siblings have distinct ids).
                if mls_mgr.group_members(&group_key).contains(&peer_str.to_string()) {
                    hollow_log!("[HOLLOW-MLS] Device {peer_str} already in MLS group {group_key} — queuing for batch removal + re-add");
                    pending_mls_removals.entry(group_key.clone()).or_default().push(peer_str.to_string());
                }

                // Queue KeyPackage for batch processing (single epoch advance per batch).
                pending_mls_key_packages
                    .entry(group_key.clone())
                    .or_default()
                    .push((peer_str.to_string(), kp_bytes));
                hollow_log!("[HOLLOW-MLS] Queued KeyPackage from {peer_str} for batch add to {group_key}");
            }
        }

        HavenMessage::MlsWelcome { server_id, welcome, channel_id: wl_channel_id, conf_nonce } => {
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

                // Staged and judged before it can replace anything: every leaf bound,
                // the sender a member, and a group we hold replaced only if we asked.
                let requests = super::mls_authority::LeafRequests {
                    bootstrap_requested: mls_bootstrap_requested,
                    welcome_grace: mls_welcome_grace,
                    awaiting_parked_join: awaiting_mls_after_parked_join,
                    join_pending: pending_server_joins.contains_key(&server_id),
                    answered: mls_mgr.key_request_answered(&group_key),
                };
                let mut welcome_sender: Option<String> = None;
                let judged = mls_mgr.join_from_welcome_judged(&group_key, &welcome_bytes, |facts| {
                    welcome_sender = facts.sender.bound().map(|s| s.master.clone());
                    let asked = super::mls_authority::asked_for_leaf(
                        &group_key, &server_id, welcome_sender.as_deref(), &requests,
                    );
                    super::mls_authority::judge_welcome(
                        server_states, &server_id, wl_channel_id.as_deref(), conf_nonce.as_deref(), asked, facts,
                    )
                });
                let judged = match judged {
                    Ok(crate::crypto::Verdict::Accept) => Ok(()),
                    Ok(crate::crypto::Verdict::Hold(reason)) => {
                        // Staging consumed our KeyPackage, so the staged Welcome is kept.
                        persist_mls_state(mls_mgr, crypto_store);
                        hollow_log!("[HOLLOW-MLS] Holding Welcome for {group_key} from {peer_str}: {reason}");
                        return;
                    }
                    Ok(crate::crypto::Verdict::Refuse(reason)) => {
                        persist_mls_state(mls_mgr, crypto_store);
                        hollow_log!("[HOLLOW-SECURITY] REFUSED Welcome for {group_key} from {peer_str}: {reason}");
                        super::conference::reknock_after_bad_welcome(mls_mgr, crypto_store, ws_cmd_tx, &server_id);
                        return;
                    }
                    Err(e) => Err(e),
                };

                match judged {
                    Ok(()) => {
                        after_welcome_joined(
                            mls_mgr, master_keypair, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                            crdt_store_actor, server_states, mls_bootstrap_requested,
                            mls_welcome_grace, awaiting_mls_after_parked_join, relay_catchup_done,
                            db_path, db_passphrase, local_peer_str, peer_str,
                            &server_id, &wl_channel_id, &group_key, welcome_sender.as_deref(),
                        ).await;
                    }
                    Err(e) => {
                        // Anyone can send a Welcome that does not process, so it clears
                        // nothing: our request stays open for the real one.
                        hollow_log!("[HOLLOW-MLS] Failed to join from Welcome for {group_key}: {e}");
                        super::conference::reknock_after_bad_welcome(mls_mgr, crypto_store, ws_cmd_tx, &server_id);
                    }
                }
            }
        }

        HavenMessage::MlsCommit { server_id, commit, channel_id: cm_channel_id, epoch: cm_epoch } => {
            hollow_log!("[HOLLOW-MLS] MlsCommit from {peer_str} for {server_id} (cid={cm_channel_id:?})");
            if let Some(mls_mgr) = mls {
                let outcome = crate::node::crypto_handler::handle_mls_commit_frame(
                    mls_mgr, crypto_store, server_states, ws_cmd_tx, ws_room_peers,
                    mls_bootstrap_requested, mls_epoch_hint_cooldown, event_tx, local_peer_str,
                    peer_str, &server_id, &commit, &cm_channel_id, cm_epoch,
                ).await;
                if matches!(outcome, crate::node::crypto_handler::CommitApplyOutcome::Evicted) {
                    let group_key = match &cm_channel_id {
                        Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                        None => server_id.clone(),
                    };
                    mls_welcome_grace.insert(group_key, std::time::Instant::now());
                }
            }
        }

        HavenMessage::MlsEpochProbe { server_id, channel_id: pr_channel_id, epoch, epoch_auth } => {
            // A peer asks whether its group is behind or forked. Membership gate,
            // authority election and cooldowns live in the handler; a spoofed hint
            // can never drop a group.
            hollow_log!("[HOLLOW-MLS] MlsEpochProbe from {peer_str} for {server_id} (cid={pr_channel_id:?}, their epoch {epoch})");
            if let Some(mls_mgr) = mls {
                crate::node::crypto_handler::handle_epoch_hint(
                    mls_mgr, ws_cmd_tx, ws_room_peers, server_states,
                    mls_epoch_hint_cooldown,
                    &server_id, pr_channel_id.as_deref(), epoch, epoch_auth.as_deref(),
                    peer_str, local_peer_str,
                    true, // addressed to us — answer it, do not re-elect
                );
            }
        }

        HavenMessage::MlsCommitCatchup { server_id, channel_id: cu_channel_id, commits } => {
            // Replay of commit frames we missed on the unbuffered 0x03 broadcast.
            // Every frame goes through the SAME judged apply path as a live
            // MlsCommit, and each must be exactly one epoch ahead of us.
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
                        mls_bootstrap_requested, mls_epoch_hint_cooldown, event_tx, local_peer_str,
                        peer_str, &server_id, &commit_b64, &cu_channel_id, Some(entry_epoch),
                    ).await {
                        crate::node::crypto_handler::CommitApplyOutcome::Applied
                        | crate::node::crypto_handler::CommitApplyOutcome::Skipped => continue,
                        // Evicted mid-replay: the group is gone, so nothing after
                        // this frame can apply. Arm the Welcome grace and stop —
                        // the re-add's Welcome is the only thing that can help.
                        crate::node::crypto_handler::CommitApplyOutcome::Evicted => {
                            mls_welcome_grace.insert(group_key.clone(), std::time::Instant::now());
                            break;
                        }
                        crate::node::crypto_handler::CommitApplyOutcome::NoGroup
                        | crate::node::crypto_handler::CommitApplyOutcome::Held
                        | crate::node::crypto_handler::CommitApplyOutcome::Refused
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

            // Every answer mints and persists a KeyPackage, and a KeyPackage is what
            // a Welcome into a substitute group needs. So only for a server we are a
            // member of (never a meeting, never while our own join is pending), only
            // to a current member, for a subgroup only if we qualify, at most once
            // per group per KEY_PACKAGE_ANSWER_GAP. While we hold a leaf, only to
            // someone entitled to repair it.
            let Some(state) = server_states.get(&server_id) else { return };
            if super::conference::is_conference_sid(&server_id)
                || pending_server_joins.contains_key(&server_id)
                || !state.members.contains_key(local_peer_str)
            {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackageRequest from {peer_str} for {group_key}: not a server of ours");
                return;
            }
            let requester_master = mls.as_ref()
                .and_then(|m| m.group_leaves(&group_key).into_iter().find(|l| l.id() == peer_str))
                .and_then(|l| l.bound().map(|b| b.master.clone()))
                .unwrap_or_else(|| super::resolver::resolve(peer_str));
            if !state.members.contains_key(&requester_master) || state.is_banned(&requester_master) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackageRequest from {peer_str} for {group_key}: {requester_master} is not a member");
                return;
            }
            if kpr_channel_id.as_deref().is_some_and(|cid| !state.can_see_channel(local_peer_str, cid)) {
                hollow_log!("[HOLLOW-MLS] Ignoring MlsKeyPackageRequest for {group_key}: we cannot see that channel");
                return;
            }
            let holds_leaf = mls.as_ref().is_some_and(|m| m.has_group(&group_key));
            if holds_leaf && !crate::node::crypto_handler::may_repair_our_leaf(
                state, kpr_channel_id.as_deref(), local_peer_str, ws_room_peers, &requester_master,
            ) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackageRequest from {peer_str} for {group_key}: {requester_master} may not repair our leaf");
                return;
            }
            if let Some(mls_mgr) = mls {
                if mls_mgr.key_request_answered(&group_key).is_some_and(|(_, t)| t.elapsed() < KEY_PACKAGE_ANSWER_GAP) {
                    hollow_log!("[HOLLOW-MLS] A KeyPackage for {group_key} went out moments ago, not minting another for {peer_str}");
                    return;
                }
                if holds_leaf {
                    hollow_log!("[HOLLOW-MLS] KeyPackageRequest for {group_key} while we hold it — answering (leaf repair)");
                }
                match crate::node::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
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
                        // The repair's Welcome from this requester may replace our group.
                        mls_mgr.note_key_request_answered(&group_key, &requester_master);
                    }
                    Err(e) => hollow_log!("[HOLLOW-MLS] Failed to generate KeyPackage: {e}"),
                }
            }
        }

        // -- Profile sync --

        HavenMessage::FriendRequest { requested_at, carried_bundle, device_list, sealed_card } => {

            // A friend request whose sender resolves to our own identity is one of
            // our own devices (multi-device: same master identity). Never render it
            // as a stranger's request ("your own friend friend-requested you").
            if super::resolver::same_identity(peer_str, master_peer_str) {
                hollow_log!("[HOLLOW-FRIENDS] Ignored self friend request (own device)");
                return;
            }

            // BLOCK GUARD: a blocked identity's friend request is dropped outright,
            // with no pending row, room join, event or notification. It runs BEFORE
            // any device-list ingest or bundle work, so a request replayed out of the
            // relay mailbox is dropped on exactly the same terms as a live one.
            if super::blocklist::is_blocked(peer_str) {
                return;
            }

            hollow_log!("[HOLLOW-FRIENDS] Friend request from {peer_str}");

            // ASYNC FRIENDING: the request may carry the sender's roster. Ingest it
            // FIRST. A stranger reaching us out of the mailbox has never sent us a
            // ProfileUpdate, so our resolver is cold for them: the friends row would key
            // under their DEVICE id and `dm_room_code` would compute a room they are not
            // in, addressing our accept nowhere. The roster ingest is the same one a
            // profile's goes through, so this adds a transport, not a trust level.
            //
            // This inbox is stranger-reachable, so a roster that does not make its
            // deliverer a member is a DROPPED request: `list.is_some()` is not a bypass.
            if let Some(list) = device_list.as_ref() {
                let outcome = super::roster_book::ingest(
                    event_tx, ws_cmd_tx, master_peer_str, device_peer_id,
                    peer_str, device_list.clone(), db_path, db_passphrase,
                ).await;
                enforce_device_revocations(
                    &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                    local_peer_str, ws_room_peers, pending_mls_removals,
                );
                // The carried bundle and profile below are keyed by the roster's master.
                if super::roster_book::carried_master(list, peer_str).is_none() {
                    hollow_log!("[HOLLOW-FRIENDS] Dropping FriendRequest from {peer_str}: its roster does not make the sender one of its devices");
                    return;
                }
                // A blocked identity's never-seen device resolves to itself above and
                // is bound to its master only now.
                if super::blocklist::is_blocked(peer_str) {
                    return;
                }
            }

            let req_master_early = super::resolver::resolve(&peer_str);

            // Verify and persist the carried prekey bundle, so ACCEPT (which may be a
            // reboot away) can build the Olm session with the requester long gone.
            // REJECT on any failure: an unverifiable bundle is simply not stored.
            if let (Some(bundle), Some(list)) = (carried_bundle.as_ref(), device_list.as_ref()) {
                if crypto_handler::verify_carried_bundle(master_peer_str, list, bundle, db_path, db_passphrase) {
                    let record = social::CarriedRequestRecord {
                        bundle: bundle.clone(),
                        device_list: list.clone(),
                        // Was the requester actually HERE when this landed? A live frame
                        // only reaches us because its sender shares a room with us, so
                        // room membership at receipt is the honest test.
                        live_at_receipt: crypto_handler::ws_room_for_peer(
                            ws_room_peers, peer_str,
                        ).is_some(),
                    };
                    // Key by the roster's master, not the resolver: the roster is the
                    // authenticated statement of who this device speaks for.
                    let key = social::in_bundle_key(&list.master);
                    if let (Ok(store), Ok(json)) = (
                        crate::storage::MessageStore::open(db_path, db_passphrase),
                        serde_json::to_string(&record),
                    ) {
                        let _ = store.save_setting(&key, &json);
                    }
                    hollow_log!("[HOLLOW-FRIENDS] Stored verified carried bundle from {peer_str} (master {})", list.master);
                } else {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED carried bundle in friend request from {peer_str} — verification FAILED");
                }
            }

            // ANTI-DOWNGRADE / DEDUP guard. The relay inbox mailbox is TTL-only and
            // re-delivers the ORIGINAL buffered request on EVERY `inbox:` join, by
            // design, so every sibling device collects it. Without this guard a
            // re-delivery UNDOES settled state: an accepter who already accepted and
            // then reboots would have the save below DOWNGRADE the "accepted" row
            // back to "pending incoming" and re-emit `FriendRequestReceived`. Placed
            // AFTER the carried-bundle store, since a half-formed friendship may want
            // its bundle refreshed, and BEFORE `is_mutual`, which must still fire.
            {
                let existing = crate::storage::MessageStore::open(db_path, db_passphrase)
                    .ok()
                    .and_then(|s| s.get_friend_row(&req_master_early).ok().flatten());
                match existing.as_ref().map(|(s, d, r)| (s.as_str(), d.as_str(), *r)) {
                    // Already friends — a re-delivered replay of a friendship we
                    // already hold. Do NOT save (no downgrade), do NOT emit, do NOT
                    // re-join/re-push. The friendship is settled.
                    Some(("accepted", _, _)) => {
                        hollow_log!("[HOLLOW-FRIENDS] Re-delivered request from {peer_str} — already accepted, ignoring");
                        return;
                    }
                    // The user already refused this person and the TTL-only mailbox is
                    // merely replaying the SAME or an older request, so do not resurrect
                    // it. A strictly NEWER requested_at is a genuine re-add and falls through.
                    Some(("declined", _, stored_req)) if requested_at <= stored_req => {
                        hollow_log!("[HOLLOW-FRIENDS] Re-delivered request from {peer_str} (requested_at {requested_at} <= stored {stored_req}) — already declined, ignoring");
                        // RE-ARM THE ANSWER. Swallowing silently is exactly how a decline
                        // failed to converge: our reject sits in the requester's TTL-only
                        // mailbox, and when that copy expires before the requester next boots
                        // it re-deposits this very request and nobody answers again. So every
                        // swallow re-sends the decline, ONCE per requester per process.
                        if reject_resent.insert(req_master_early.clone()) {
                            social::send_friend_reject(
                                ws_cmd_tx, ws_room_peers, peer_str,
                                &req_master_early, stored_req,
                                super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase),
                            );
                        }
                        return;
                    }
                    // A duplicate delivery of a request we already SHOW; re-emitting would
                    // spam the notification for a row already on screen. Only a strictly
                    // NEWER `requested_at` is a genuine re-request and refreshes it.
                    Some(("pending", "incoming", stored_req)) if requested_at <= stored_req => {
                        hollow_log!("[HOLLOW-FRIENDS] Duplicate incoming request from {peer_str} (requested_at {requested_at} <= stored {stored_req}) — already shown, ignoring");
                        return;
                    }
                    // pending/outgoing goes to the `is_mutual` auto-accept below.
                    // pending/incoming or declined with a strictly NEWER requested_at,
                    // "removed", or no row at all falls through to the new-request path.
                    _ => {}
                }
            }

            // A stranger's request holds no profile in our DB and the sender is often
            // gone before it can push one, so its card rides sealed in the request. It
            // opens only as the requester's own card; anything else drops JUST the card,
            // before the event, never the request.
            if let Some(card) = sealed_card.as_ref().and_then(|sealed| {
                super::profile_card::open_from(sealed, master_peer_str, &req_master_early, requested_at)
            }) {
                if super::profile_card::store_card(&card, None, db_path, db_passphrase) {
                    let _ = event_tx.send(NetworkEvent::ProfileUpdated { peer_id: card.master }).await;
                }
            }

            // MUTUAL request: auto-converge to friends. If our OWN outgoing request is
            // still live, both sides requested each other, and saving "pending
            // incoming" with a Reject affordance is the reject/accept race, because
            // our queued outbound request later drains and re-friends us anyway.
            // FriendAccept is idempotent, so both sides running this still converge.
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
                // STAMP THE CONVERGED REQUEST, before the accept freezes the row. Each
                // side holds its OWN outgoing request's timestamp and the two crossed a
                // millisecond apart, so the accepted rows would record DIFFERENT stamps
                // for one friendship, and a later decline measured against the other
                // side's reads as a stale replay half the time. save_friend advances a
                // PENDING row by MAX, and MAX is symmetric, so both sides freeze together.
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.save_friend(
                        &req_master_early, "pending", "outgoing", requested_at,
                    );
                }
                social::handle_accept_friend_request(
                    olm, crypto_store,
                    event_tx, ws_cmd_tx, ws_room_peers, server_states,
                    local_peer_str, master_keypair, device_peer_id, is_invisible,
                    peer_str.to_string(),
                    pending_friend_accepts,
                    pending_friend_removals,
                    db_path, db_passphrase,
                ).await;
                return;
            }

            // Save as pending incoming, keyed by the sender's MASTER, since
            // friendships key on the master. A cold resolver returns the device id
            // itself, which the device-list ingest re-key later migrates.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let master = super::resolver::resolve(&peer_str);
                    if master != peer_str {
                        let _ = store.migrate_friend_to_master(&peer_str, &master);
                    }
                    let _ = store.save_friend(&master, "pending", "incoming", requested_at);
                }
            }

            // Register the DM room code and JOIN the DM relay room now. The requester
            // joined it at send time and LEAVES our inbox after delivery, so the DM
            // room is the shared rendezvous our FriendAccept routes over.
            // `dm_room_code` is pure f(masters), so pass the requester's MASTER, not
            // the raw sender device: the device id lands us in a DIFFERENT room the
            // requester was never in, and the accept is lost.
            let local_peer = local_peer_str.to_string();
            let req_master = super::resolver::resolve(&peer_str);
            let room = dm_room_code(&local_peer, &req_master);
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                room_code: room,
            });

            // CRITICAL: push OUR profile and DEVICE LIST to the requester NOW, while
            // it is still reachable. This is the ONLY reliable moment to teach it
            // our-device -> our-master: the normal device-list send is gated behind
            // the `is_new` PeerJoined path, which the requester defeats by leaving our
            // inbox right after delivery and then being pinned in `synced_peers` via
            // the shared DM room, so it never fires again. Send to the SENDER device.
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers, server_states,
                local_peer_str, master_keypair, peer_str,
                is_invisible,
                db_path, db_passphrase,
            );

            let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendAccept { requested_at, device_list } => {
            // ATTRIBUTION, as on FriendReject: a carried list makes it cryptographic,
            // so a cold resolver cannot file the accept under a bare device id.
            let master = match device_list.as_ref() {
                Some(list) => {
                    let outcome = super::roster_book::ingest(
                        event_tx, ws_cmd_tx, master_peer_str, device_peer_id,
                        peer_str, device_list.clone(), db_path, db_passphrase,
                    ).await;
                    enforce_device_revocations(
                        &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                        local_peer_str, ws_room_peers, pending_mls_removals,
                    );
                    let Some(master) = super::roster_book::carried_master(list, peer_str) else {
                        hollow_log!("[HOLLOW-FRIENDS] Dropping FriendAccept from {peer_str}: its roster does not make the sender one of its devices");
                        return;
                    };
                    master
                }
                None => super::resolver::resolve(peer_str),
            };
            if super::blocklist::is_blocked(peer_str) {
                return;
            }
            let was_pending;
            {
                let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
                    return;
                };
                if master != peer_str {
                    let _ = store.migrate_friend_to_master(peer_str, &master);
                }
                // An accept answers a request WE sent, so it lands only on our own
                // pending outgoing row, or re-confirms an accepted one. With no row a
                // stranger befriended us by sending one, and on an incoming request it
                // accepted in our name (L1). A decline, a removal and a tombstone stay
                // as they are. Our siblings learn an accept through the sibling share
                // below, never from a row-less accept. A stamp older than the row is a
                // relay-parked or replayed copy; a bare one is a pre-0.11.1 sender.
                match store.get_friend_row(&master).ok().flatten() {
                    Some((status, direction, stored))
                        if (status == "pending" && direction == "outgoing") || status == "accepted" =>
                    {
                        if let Some(stamp) = requested_at && stamp < stored {
                            hollow_log!("[HOLLOW-FRIENDS] Ignoring stale FriendAccept from {peer_str}: answers request {stamp}, current is {stored}");
                            return;
                        }
                        // Sealed before our current request existed, whatever it names.
                        if status == "pending" && frame_ts_ms.saturating_add(super::frame_auth::LIVE_SKEW_MS) < stored {
                            hollow_log!("[HOLLOW-SECURITY] Ignoring a FriendAccept from {peer_str} sealed before our request");
                            return;
                        }
                        was_pending = status == "pending";
                    }
                    row => {
                        hollow_log!("[HOLLOW-FRIENDS] Ignoring FriendAccept from {peer_str}: no request of ours for {master} (row {row:?})");
                        return;
                    }
                }
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as i64;
                // A mutual request converged on the later of the two stamps on the side
                // that accepted it. The accepted row freezes its stamp, so ours takes that
                // one first, or a later decline from us names a request it never saw.
                if was_pending
                    && let Some(stamp) = requested_at
                    && stamp <= frame_ts_ms.saturating_add(super::frame_auth::LIVE_SKEW_MS)
                {
                    let _ = store.save_friend(&master, "pending", "outgoing", stamp);
                }
                let _ = store.save_friend(&master, "accepted", "", now);
            }
            if was_pending {
                social::share_friend_with_siblings(
                    ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &master, db_path, db_passphrase,
                );
            }

            hollow_log!("[HOLLOW-FRIENDS] Friend accepted by {peer_str}");

            // Register DM room code with signaling. Use the MASTER so both sides compute
            // the SAME pure dm_room_code.
            let local_peer = local_peer_str.to_string();
            let friend_master = master;
            let room = dm_room_code(&local_peer, &friend_master);

            // Push our profile + device list to the accepter while it's reachable, so it
            // learns our device→master mapping over the durable DM room (same reason as
            // the FriendRequest handler — the is_new gate otherwise suppresses it).
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers, server_states,
                local_peer_str, master_keypair, peer_str,
                is_invisible,
                db_path, db_passphrase,
            );

            let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendReject { requested_at, device_list } => {
            // ATTRIBUTION FIRST. The sender is a DEVICE id and our outgoing request row
            // is keyed by their MASTER, so a raw device-id lookup silently misses it.
            // `resolve()` alone cannot bridge that here: a decline of an ASYNC request
            // answers somebody we have never been online with, so we have ingested no
            // device list for them and `resolve(device)` hands the device back.
            //
            // So the reject CARRIES the decliner's roster, exactly like a friend request,
            // and attribution becomes cryptographic: the relay-authenticated sender device
            // must be a member of it. A roster that does not make it one is a REJECTED
            // message, never a downgrade: `list.is_some()` is not a bypass.
            let master = match device_list.as_ref() {
                Some(list) => {
                    // Ingest through the SAME path the FriendRequest arm uses, so the
                    // resolver, the device store and the DM room key all agree afterwards:
                    // an accept or DM that follows must not compute a different room.
                    let outcome = super::roster_book::ingest(
                        event_tx, ws_cmd_tx, master_peer_str, device_peer_id,
                        peer_str, device_list.clone(), db_path, db_passphrase,
                    ).await;
                    enforce_device_revocations(
                        &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                        local_peer_str, ws_room_peers, pending_mls_removals,
                    );
                    let Some(master) = super::roster_book::carried_master(list, peer_str) else {
                        hollow_log!("[HOLLOW-FRIENDS] Dropping FriendReject from {peer_str}: its roster does not make the sender one of its devices");
                        return;
                    };
                    master
                }
                // A pre-carried-list client: all we have is the resolver, which
                // works whenever the two have actually met.
                None => super::resolver::resolve(&peer_str),
            };

            let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
                hollow_log!("[HOLLOW-FRIENDS] FriendReject from {peer_str}: store unavailable, ignoring");
                return;
            };
            let row = store.get_friend_row(&master).ok().flatten();

            // A reject rides the TTL-only mailbox, so it can arrive LATE, out of order,
            // or replayed for three days. Unconditionally deleting on it would make an
            // old copy a remote un-friend primitive, wiping a friendship or a request
            // minted AFTER the decline. So a reject only ever acts on what it NAMES.
            //
            //   * pending/outgoing: the ordinary case. `requested_at == 0` is a pre-nonce
            //     client saying "decline whatever is pending", confined to this arm
            //     because with no timestamp only a still-pending request is safe to drop.
            //   * accepted: the MUTUAL RACE. Both sides requested each other, both
            //     converged, and the user then hit Reject on that same request, so
            //     honouring it keeps both sides symmetric. An accepted row FREEZES
            //     `requested_at`, so a reject replayed after a re-add is still refused.
            let acts_on = match row.as_ref().map(|(s, d, r)| (s.as_str(), d.as_str(), *r)) {
                Some(("pending", "outgoing", stored)) => requested_at == 0 || requested_at >= stored,
                Some(("accepted", _, stored)) => requested_at != 0 && requested_at >= stored,
                _ => false,
            };
            if !acts_on {
                hollow_log!("[HOLLOW-FRIENDS] FriendReject from {peer_str} answers no live request for {master} (row {row:?}, requested_at {requested_at}); nothing to do");
                return;
            }

            hollow_log!("[HOLLOW-FRIENDS] Friend rejected by {peer_str} (master {master})");
            let _ = store.remove_friend(&master);
            if master != peer_str {
                let _ = store.remove_friend(peer_str);
            }

            // Stop RE-DEPOSITING this request. Our outgoing request may still sit in
            // `pending_friend_requests`, which the reconnect handler re-deposits into the
            // target's TTL-only mailbox on every connect, perpetually refreshing a
            // request they just declined. Clear the in-memory queue under both keys.
            pending_friend_requests.remove(&master);
            pending_friend_accepts.remove(&master);
            if master != peer_str {
                pending_friend_requests.remove(peer_str);
                pending_friend_accepts.remove(peer_str);
            }

            // The request deposit STAYS in the target's inbox until the request is
            // resolved (that is what lets a sibling still collect it). A decline
            // resolves it, so leave now — mirroring what the delivery drains do.
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                room_code: format!("inbox:{master}"),
            });

            let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
                peer_id: master,
            }).await;
        }

        HavenMessage::FriendRemove => {
            // The remover sends from a DEVICE id while the friendship is keyed by their
            // MASTER on our side, so resolve or the DELETE misses and the removal is
            // asymmetric. Delete both keys for any legacy device-stranded row.
            let master = super::resolver::resolve(&peer_str);
            let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
            // A removal sealed before this friendship began belongs to an earlier one,
            // held back or replayed by the relay.
            if let Ok(Some((_, _, since))) = store.get_friend_row(&master)
                && frame_ts_ms + super::frame_auth::LIVE_SKEW_MS < since
            {
                hollow_log!("[HOLLOW-SECURITY] Ignored a removal from {peer_str} older than the friendship");
                return;
            }
            hollow_log!("[HOLLOW-FRIENDS] Friend removed by {peer_str} (master {master})");
            let _ = store.save_setting(&social::removed_key(&master), "1");
            let _ = store.remove_friend(&master);
            if master != peer_str {
                let _ = store.remove_friend(&peer_str);
            }

            // CRITICAL: clear our OWN queued accept and request for this person. A
            // `pending_friend_accepts` entry is re-seeded from accepted friends at every
            // startup, and if it survives this removal then when they RE-ADD us the drain
            // AUTO-SENDS a FriendAccept without ever surfacing their new request: they
            // re-friend us while WE show nothing and never consented.
            pending_friend_accepts.remove(&master);
            pending_friend_requests.remove(&master);
            if master != peer_str {
                pending_friend_accepts.remove(peer_str);
                pending_friend_requests.remove(peer_str);
            }

            // Do NOT LeaveRoom here either, symmetric with the send side. Lingering
            // ex-friend presence is a UI-count concern (the Network column counts only
            // peers resolving to an accepted friend); leaving raced removal delivery.

            let _ = event_tx.send(NetworkEvent::FriendRemoved {
                peer_id: master,
            }).await;
        }

        HavenMessage::IdentityDestroyed { destroy: order } => {
            // Self-authenticating, so the sender's identity buys it nothing: the
            // handler branches on whose MASTER signed it, not on who delivered it.
            destroy::handle_identity_destroyed(
                event_tx, &order, local_peer_str, device_peer_id, db_path, db_passphrase,
            ).await;
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
                let existing: HashMap<String, String> = store
                    .load_friends(None)
                    .map(|rows| rows.into_iter().map(|(pid, status, ..)| (pid, status)).collect())
                    .unwrap_or_default();

                for entry in &friends {
                    // Never add ourselves (any of our own devices) as a friend.
                    if super::resolver::same_identity(&entry.peer_id, local_peer_str) {
                        continue;
                    }
                    // Key the friend by their MASTER (the invariant). A current sibling
                    // already sends masters, but resolve defensively so a device-keyed entry
                    // from an older one still lands canonical and dedups against our row.
                    let fmaster = super::resolver::resolve(&entry.peer_id);
                    // Our sibling's accept is our own consent, so it settles a pending
                    // request here; any other row we hold stays ours.
                    let held = existing.get(&fmaster).or_else(|| existing.get(&entry.peer_id));
                    if held.is_some_and(|s| s != "pending" || entry.status != "accepted") {
                        continue;
                    }
                    // v1 shares only accepted friends; persist as accepted. The stamp says
                    // which of the friend's removals are older than the friendship, so it
                    // never runs ahead of the frame (the friendship itself is real).
                    let since = entry.requested_at.min(super::frame_auth::stamp_ceiling(frame_ts_ms));
                    if store
                        .save_friend(&fmaster, "accepted", "", since)
                        .is_ok()
                    {
                        inserted += 1;
                    }
                    // Join the friend's DM room so presence flows both ways and future
                    // live messages arrive. Use the friend's MASTER so both sides compute
                    // the same pure dm_room_code; a device-keyed room would diverge.
                    let room = dm_room_code(local_peer_str, &fmaster);
                    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                        room_code: room.clone(),
                    });
                    // CRITICAL (presence collapse): announce ourselves to this
                    // freshly-learned friend with our profile and MERGED device list.
                    // Without it a substitute device joins the friend's DM room but the
                    // friend never receives a ProfileUpdate carrying our device id, so
                    // their resolver never maps our-device to master and shows the
                    // identity OFFLINE when the original device quits.
                    //
                    // We just issued JoinRoom, so we are NOT in `ws_room_peers[room]` yet
                    // and `send_own_profile_to_peer`'s room lookup would drop the send.
                    // Target the KNOWN DM room directly: JoinRoom is processed before this
                    // SendDirect on the same ordered connection.
                    //
                    // A freshly-imported device has no profile row: never gate on load_profile.
                    if let Some(msg) = social::own_profile_update(
                        master_keypair, local_peer_str, is_invisible, false, None,
                        db_path, db_passphrase,
                    ) {
                        super::olm_lane::carry(ws_cmd_tx, &entry.peer_id, Some(&room), &msg, super::olm_lane::NoSession::Queue);
                        hollow_log!("[HOLLOW-DEVICES] Announced self to backfilled friend {}", entry.peer_id);
                    }
                }
            }

            if inserted > 0 {
                hollow_log!("[HOLLOW-MULTIDEV] Backfilled {inserted} friends from sibling device");
                let _ = event_tx.send(NetworkEvent::FriendsBackfilled { count: inserted }).await;
            }
        }

        HavenMessage::PersonalEmoteSync { emotes: incoming } => {
            // Multi-device: the personal emote set converges only between our OWN
            // devices. A non-self sender is trying to plant emotes on us.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Dropped PersonalEmoteSync from non-self peer {peer_str}"
                );
                return;
            }
            let rows: Vec<PersonalEmoteEntry> = incoming.into_iter().take(512).collect();
            let mut applied = 0usize;
            let mut missing: Vec<String> = Vec::new();
            // A row is its own LWW version: one stamped past the frame would win every
            // later write, and a clamped one would order differently on each device.
            let ceiling = super::frame_auth::stamp_ceiling(frame_ts_ms);
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                for e in &rows {
                    if !crate::crdt::valid_emote_name(&e.name)
                        || !(e.hash.is_empty() || crate::crdt::valid_emote_hash(&e.hash))
                        || e.source.len() > 64
                        || e.added_at < 0
                        || e.added_at > ceiling
                    {
                        continue;
                    }
                    let changed = store
                        .merge_personal_emote_entry(
                            &e.name, &e.hash, e.animated, &e.source, e.added_at,
                        )
                        .unwrap_or(false);
                    if !changed {
                        continue;
                    }
                    applied += 1;
                    if !e.hash.is_empty() && !store.has_emote_blob(&e.hash).unwrap_or(false) {
                        missing.push(e.hash.clone());
                    }
                }
            }
            let pulled = missing.len();
            if pulled > 0 {
                // Hint OUR OWN master: the rail turns it into our online sibling
                // devices, and its retry re-asks when the next one reconnects.
                emotes::handle_request_emotes(
                    ws_cmd_tx, ws_room_peers, pending_asset_asks,
                    missing, super::assets::AssetKind::Emote,
                    None, Some(local_peer_str.to_string()),
                    local_peer_str, db_path, db_passphrase,
                );
            }
            if applied > 0 {
                let _ = event_tx.send(NetworkEvent::PersonalEmotesUpdated).await;
            }
            hollow_log!(
                "[HOLLOW-MULTIDEV] Sibling {peer_str} shared {} personal emote row(s): {applied} applied, {pulled} blob(s) pulled",
                rows.len()
            );
        }

        HavenMessage::FriendListRequest => {
            // Multi-device (Phase 6): a sibling asked for our friend list. Reply
            // ONLY to our own other device (a roster member). Pull companion to
            // the push a sibling gets when it joins: fixes the join-timing race.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Dropped FriendListRequest from non-self peer {peer_str}"
                );
                return;
            }
            let friends = crypto_handler::accepted_friend_entries(db_path, db_passphrase);
            if !friends.is_empty() {
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Replying to FriendListRequest from {peer_str} with {} friends",
                    friends.len()
                );
                super::olm_lane::carry(
                    ws_cmd_tx, peer_str, None,
                    &HavenMessage::FriendListSync { friends },
                    super::olm_lane::NoSession::Queue,
                );
            }
        }

        HavenMessage::ReadMarkers { mut markers } => {
            // SECURITY: read state is per identity; a friend must not move our
            // pointers. The store apply and the never-regress rule live behind the
            // FFI (Dart owns the unread state), so this only gates and forwards.
            if !super::resolver::same_identity(peer_str, local_peer_str) {
                hollow_log!("[HOLLOW-UNREAD] Dropped ReadMarkers from non-self peer {peer_str}");
                return;
            }
            if markers.is_empty() { return; }
            // A pointer never regresses, so one past the frame would mark every later
            // message read. Held to the frame rather than refused: its stamp is the
            // time of a message someone else wrote, and "read up to now" still holds.
            let ceiling = super::frame_auth::stamp_ceiling(frame_ts_ms);
            for marker in &mut markers {
                marker.ts = marker.ts.min(ceiling);
            }
            hollow_log!("[HOLLOW-UNREAD] Received {} read marker(s) from sibling {peer_str}", markers.len());
            let _ = event_tx.send(NetworkEvent::ReadMarkersReceived { markers }).await;
        }

        HavenMessage::SiblingCallState { presence, ask } => {
            if !super::resolver::same_identity(peer_str, local_peer_str)
                || peer_str == device_peer_id
                || super::resolver::is_revoked(peer_str)
            {
                hollow_log!("[HOLLOW-CALL] Dropped SiblingCallState from non-sibling {peer_str}");
                return;
            }
            if let Some(changed) = call_book.set_sibling(peer_str, presence) {
                hollow_log!("[HOLLOW-CALL] Sibling {peer_str} is now in {:?}", changed.as_ref().map(|p| p.kind.as_str()));
                emit_sibling_call(event_tx, peer_str, changed).await;
            }
            if ask {
                super::olm_lane::carry(
                    ws_cmd_tx, peer_str, None,
                    &HavenMessage::SiblingCallState { presence: call_book.own().cloned(), ask: false },
                    super::olm_lane::NoSession::Queue,
                );
            }
        }

        HavenMessage::DeviceKind { kind } => {
            if !super::resolver::same_identity(peer_str, local_peer_str) || peer_str == device_peer_id {
                hollow_log!("[HOLLOW-ROSTER] Dropped DeviceKind from non-sibling {peer_str}");
                return;
            }
            let kind = super::call_book::device_kind(&kind);
            if kind.is_empty() { return; }
            let (db, pass, device, tx) = (db_path.to_string(), db_passphrase.to_string(), peer_str.to_string(), event_tx.clone());
            tokio::task::spawn_blocking(move || {
                let stored = crate::storage::MessageStore::open(&db, &pass).and_then(|s| s.set_device_kind(&device, kind));
                if let Ok(true) = stored {
                    let _ = tx.blocking_send(NetworkEvent::DeviceKindsChanged);
                }
            });
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
            // 1) Announce every server we are STILL A MEMBER of. Each announce drives
            //    the requester's join flow through to ServerJoined and its UI refresh,
            //    and is idempotent. The membership filter mirrors on_verified_sibling:
            //    a shell kept after our own leave would re-ADD us to a server we left.
            let mut announced = 0u32;
            for (sid, st) in server_states.iter() {
                if st.is_deleted() || !st.is_member(local_peer_str) { continue; }
                super::olm_lane::carry(
                    ws_cmd_tx, peer_str, None,
                    &HavenMessage::SiblingServerAnnounce { server_id: sid.clone(), owner: st.anchor_owner(), join_key: st.join_public_text() },
                    super::olm_lane::NoSession::Queue,
                );
                announced += 1;
            }
            // 2) Re-share our friend list so the requester converges friends too.
            let friends = crypto_handler::accepted_friend_entries(db_path, db_passphrase);
            let friends_sent = friends.len();
            if !friends.is_empty() {
                super::olm_lane::carry(
                    ws_cmd_tx, peer_str, None,
                    &HavenMessage::FriendListSync { friends },
                    super::olm_lane::NoSession::Queue,
                );
            }
            // 3) And the personal emote set, which converges the same way.
            let emotes_sent = send_personal_emotes_to_sibling(ws_cmd_tx, peer_str, db_path, db_passphrase);
            // 4) Where our reading stands, so the requester drops badges we cleared.
            let markers_sent = super::crypto_handler::send_read_markers_to_sibling(
                ws_cmd_tx, peer_str, db_path, db_passphrase,
            );
            hollow_log!(
                "[HOLLOW-SYNC] Manual state-sync from {peer_str}: announced {announced} server(s) + {friends_sent} friend(s) + {emotes_sent} personal emote row(s) + {markers_sent} read marker(s)"
            );
        }

        // -- Multi-device link (`link_handler`, `link_pake`) --
        HavenMessage::LinkPake { msg } => {
            link_handler::on_pake(link, ws_cmd_tx, event_tx, ws_room_peers, peer_str, &msg).await;
        }

        HavenMessage::LinkPakeReply { msg, confirm } => {
            link_handler::on_pake_reply(link, ws_cmd_tx, event_tx, peer_str, &msg, &confirm).await;
        }

        HavenMessage::LinkSealed { ct } => {
            link_handler::on_sealed(link, ws_cmd_tx, event_tx, pending_link_snapshots, peer_str, &ct).await;
        }

        HavenMessage::LinkDeclined => {
            if link_handler::on_declined(link, ws_cmd_tx, peer_str) {
                hollow_log!("[HOLLOW-LINK] Link request declined by {peer_str}");
                let _ = event_tx.send(NetworkEvent::LinkFailed {
                    link_id: String::new(),
                    error: "Your other device declined the link.".to_string(),
                }).await;
            }
        }

        HavenMessage::LinkSnapshotAck { link_id } => {
            // The joiner stashed the whole snapshot: only now does the sender show
            // "Data sent", since bytes leaving our channel prove nothing.
            if link_handler::on_ack(link, ws_cmd_tx, peer_str) {
                hollow_log!("[HOLLOW-LINK] LinkSnapshotAck for {link_id} from {peer_str}");
                let _ = event_tx.send(NetworkEvent::LinkPushComplete { bytes: 0 }).await;
            }
        }

        HavenMessage::PublicChannelMessage { server_id, channel_id, text, ts, sig, pk, mid, reply_to, file_id, link_preview, order_us, album, file_meta } => {
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
            // Multi-device: the relay frame author (`peer_str`) is the sender's DEVICE
            // id, but a public channel message is SIGNED by and must be attributed to
            // their MASTER, so resolve first or the signature cannot verify and the row
            // is not master-keyed.
            //
            // `order_us` is the SENDER's Lamport stamp and the v2 signature binds it, so
            // a local ts*1000 default would store a row whose signature fails on re-serve.
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_channel_message(
                &event_tx, &bundle_keypair, server_states.get(&server_id), slow_mode_clock, &local_peer_str,
                sender_master.clone(),
                server_id.clone(), channel_id.clone(), text, ts, sig, pk,
                Some(mid.clone()), reply_to, file_id.clone(), link_preview, order_us, album.map(|a| *a),
                &db_path, &db_passphrase,
            ).await;
            // GUEST live file card: we cannot decrypt the MLS FileHeader that
            // follows, so the plaintext message carries display metadata. Members
            // ignore it, and the v2 signature binds `file_id` and not this blob, so
            // require the blob to describe exactly the signed file_id.
            if server_states.get(&server_id).is_none() && guest_rooms.contains(&server_id) {
                if let Some(fm) = file_meta
                    .filter(|fm| file_id.as_deref() == Some(fm.fid.as_str()))
                    .filter(|fm| file_handler::synced_card_claim_refused(fm, Some(&mid), &sender_master).is_none())
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
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_edit_message(
                &event_tx, &bundle_keypair, server_states.get(&server_id), &sender_master,
                mid, text, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicLinkPreviewSet { server_id, channel_id, mid, lp, ts, sig, pk } => {
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_link_preview_set(
                &event_tx, server_states.get(&server_id), &sender_master, local_peer_str,
                mid, lp, ts, sig, pk,
                Some(server_id), Some(channel_id), frame_ts_ms,
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelDelete { server_id, channel_id, mid, ts, sig, pk } => {
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_delete_message(
                &event_tx, &bundle_keypair, &sender_master,
                mid, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelAddReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
            let sender_master = super::resolver::resolve(peer_str);
            message_ops::handle_envelope_add_reaction(
                &event_tx, &bundle_keypair, server_states.get(&server_id), &sender_master,
                mid, emoji, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelRemoveReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str
                || !message_ops::public_frame_accepted(
                    server_states.get(&server_id), guest_rooms.contains(&server_id),
                    &server_id, &channel_id,
                )
            {
                return;
            }
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
                        store.get_visible_channel_messages_before(&server_id, &channel_id, before_ts, limit)
                    } else {
                        // Initial request: get the latest messages (not oldest).
                        store.get_visible_channel_messages_before(&server_id, &channel_id, i64::MAX, limit)
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
                            // Same rule as the member responders: cut the page rather
                            // than serve a message stripped of the card its signature
                            // covers. This page walks BACKWARDS, so the tail is the oldest.
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
                                file_meta_map.get(fid.as_str()).map(|f| SyncFileMetaItem::from_stored(f, m.sender_id.clone()))
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
                                album: m.album_id.clone(),
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
            // Guests hold no rows to check against, so EVERYTHING is verified from
            // the items' own fields: public-channel sync is plaintext, so the relay
            // or any responder can rewrite the whole batch.
            //   * content signature  -> drop the item
            //   * hidden flag proof  -> strip the flag (REJECT-ABSENT)
            //   * reaction signature -> drop that reaction
            // This is the one surface strangers see, so it gets the member-side rule.
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
                // Attachment metadata to a file card (metadata only, never bytes). The
                // item's v2 signature binds `file_id` but NOT this blob, so require the
                // blob to describe exactly the signed file_id: a rewriting responder can
                // then only change cosmetic fields, never attach someone else's file id.
                let author = super::resolver::resolve(&m.s);
                let file_meta = m.file_meta
                    .filter(|fm| m.file_id.as_deref() == Some(fm.fid.as_str()))
                    .filter(|fm| file_handler::synced_card_claim_refused(fm, m.mid.as_deref(), &author).is_none())
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
            file_id, name, ext, mime, size, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, author, sha256,
        } => {
            // SECURITY receipt cap (mirrors `pending_asset_asks`): accept ONLY a
            // fresh header answering a request WE made, for the server we made it
            // in, and only while browsing that server as a guest. An unsolicited
            // plaintext header would register a decrypt key and stream bytes to disk.
            let Some((req_sid, asked, req_at)) = pending_public_file_requests.get(&file_id) else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED unsolicited PublicFileHeader for {file_id} from {peer_str}");
                return;
            };
            // Only the peer we asked answers, or anyone in the room could hand the
            // guest a file of its own under this id.
            if asked != peer_str {
                hollow_log!("[HOLLOW-SECURITY] REJECTED PublicFileHeader for {file_id} from {peer_str}: we asked {asked}");
                return;
            }
            let fresh = *req_sid == sid && req_at.elapsed() <= std::time::Duration::from_secs(120);
            pending_public_file_requests.remove(&file_id);
            if !fresh || !guest_rooms.contains(&sid) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED PublicFileHeader for {file_id} from {peer_str} — stale or server mismatch");
                return;
            }
            // The same ingest as an Olm FileHeader: 34 MB default size cap (no
            // server state as a guest), metadata row, pending-stream key
            // registration, FileHeaderReceived. The sender recorded is the RESPONDER.
            file_handler::handle_envelope_file_header(
                server_states, pending_file_streams, pending_shard_streams,
                early_file_streams, bundle_keypair, event_tx,
                &sid, peer_str.to_string(),
                file_id, name, ext, mime, size, 0, img, w, h,
                mid, Some(sid.clone()), Some(cid), ts,
                Some(aes_key), Some(aes_nonce),
                None, None,
                None, false, author, sha256, true,
                requested_file_receipts, declined_file_ids,
                ws_cmd_tx, ws_room_peers,
                db_path, db_passphrase,
            ).await;
        }

        HavenMessage::ChannelNotificationHint { server_id, channel_id, message_id, has_everyone, mentioned_names, is_reply: _, reply_to_sender } => {
            message_ops::deliver_channel_hint(
                event_tx, server_states, local_peer_str, peer_str,
                server_id, channel_id, message_id, has_everyone, mentioned_names, reply_to_sender,
            ).await;
        }

        HavenMessage::TypingIndicator { server_id, channel_id } => {
            // Phantom-chat guard (Step 7): ignore typing from a just-revoked-but-still-
            // alive device (same reason we drop its DMs — it would spawn/feed a phantom
            // conversation). Stops once the device self-nukes / disconnects.
            if super::resolver::is_revoked(peer_str) || super::blocklist::is_blocked(peer_str) {
                return;
            }
            // Attribute typing to the sender's MASTER identity, since server members and
            // DM threads are master-keyed. The raw `peer_str` is a device id and would
            // never match, so the indicator never shows for a multi-device sender.
            let typist_master = super::resolver::resolve(peer_str);
            // A DM dot only from a friend: a stranger in a shared room must not
            // conjure a thread.
            if server_id.is_empty() && !social::holds_accepted_friend(db_path, db_passphrase, &typist_master) {
                return;
            }
            if !server_id.is_empty()
                && !server_states.get(&server_id).is_some_and(|state| {
                    message_ops::channel_signal_accepted(
                        state, &typist_master, master_peer_str, &channel_id,
                        crate::crdt::hlc::wall_clock_ms(),
                    )
                })
            {
                return;
            }
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
            // advertised threshold so our DM file fan-out can skip bytes it would
            // discard. Clamp to the slider's ceiling: a larger value is malformed.
            let mb = mb.min(2048);
            hollow_log!("[HOLLOW-FILE] Peer {peer_str} advertised auto-download pref: {mb} MB");
            peer_auto_dl.insert(peer_str.to_string(), mb);
        }

        HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list, avatar_hash, banner_hash, showcase_board, showcase_assets_b64, showcase_assets_hash, avatar_frame, avatar_anim, banner_anim, support_creds, support_creds_sig, profile_sig, profile_pk } => {
            // If the profile carries an invisible flag, emit PeerStatusChanged so the
            // UI treats this peer as offline from the very first event.
            if peer_invisible {
                let _ = event_tx.send(NetworkEvent::PeerStatusChanged {
                    peer_id: peer_str.to_string(),
                    status: "invisible".to_string(),
                }).await;
            }

            // Multi-device: fold the sender's roster into ours for its master (verify,
            // merge, persist, resolver update, DeviceListUpdated).
            //
            // ORDER, and why it is this way round (CRYPTO-1): the roster is ingested
            // BEFORE the profile signature is checked, deliberately. Every statement in
            // it verifies on its own, so it needs nothing from the profile. The profile
            // signature needs it: it verifies against `resolve(sender)`, and this ingest
            // is what teaches the resolver device-to-master. The profile FIELDS are
            // still refused without a valid signature, downstream.
            let ingest_outcome = super::roster_book::ingest(
                event_tx, ws_cmd_tx, master_peer_str, device_peer_id, peer_str,
                device_list, db_path, db_passphrase,
            ).await;
            let our_devices_grew = ingest_outcome.our_devices_grew;
            if ingest_outcome.asks_again {
                super::roster_book::ask_again(
                    event_tx, ws_cmd_tx, master_keypair, device_keypair, server_states.keys(), db_path, db_passphrase,
                ).await;
            }
            converge_new_siblings(
                &ingest_outcome.added, ws_cmd_tx, ws_room_peers, master_keypair, device_peer_id,
                local_peer_str, server_states, is_invisible, db_path, db_passphrase, call_book.own(),
            );
            // Step 7: enforce any device revocations learned from this list — drop
            // Olm sessions + (coordinator) remove the revoked leaf from shared servers.
            enforce_device_revocations(
                &ingest_outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                local_peer_str, ws_room_peers, pending_mls_removals,
            );
            // Our own roster changed: re-announce it to every peer we share a room
            // with, our other devices included, so everyone converges now rather than
            // when each next meets the device that changed it.
            if our_devices_grew {
                super::roster_book::show_relay(ws_cmd_tx, local_peer_str, db_path, db_passphrase);
                let peers: Vec<String> = ws_room_peers.values()
                    .flat_map(|p| p.iter().cloned())
                    .collect();
                hollow_log!(
                    "[HOLLOW-ROSTER] Our roster changed: re-announcing profile to {} room peer(s)",
                    peers.len()
                );
                for pid in peers {
                    if pid == local_peer_str || pid == device_peer_id || pid == peer_str { continue; }
                    social::send_own_profile_to_peer(
                        ws_cmd_tx, ws_room_peers, server_states,
                        local_peer_str, master_keypair, &pid,
                        is_invisible,
                        db_path, db_passphrase,
                    );
                }
            }

            // MAPPING-LEARNED friend-request drain. A queued outbound request is keyed
            // by the TARGET'S MASTER, but the presence drains only match a joining
            // DEVICE to that master via the resolver, and a FRESH requester resolves
            // the target's device to ITSELF, so those drains no-op and the request sits
            // queued. The moment we learn device-to-master, here, is exactly when we
            // CAN attribute the target's present device to the queued master.
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
                    let req_msg = social::build_friend_request(
                        olm, crypto_store, master_keypair, device_keypair, device_peer_id,
                        &sender_master, requested_at, db_path, db_passphrase,
                    );
                    for t in &social::friend_device_targets(ws_room_peers, peer_str, &sender_master) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            t, req_msg.clone(),
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

            if social::profile_text_oversized(&display_name, &status, &about_me, &twitch_username) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED profile from {peer_str}: a field exceeds its limit");
                return;
            }
            // A full profile comes from someone we are close to, or from one we are
            // about to be (their accept can outrun ours); a stranger's is not stored.
            if social::profile_audience(server_states, master_peer_str, peer_str, db_path, db_passphrase) == social::Audience::None {
                hollow_log!("[HOLLOW-SECURITY] Ignored the profile fields of {peer_str}: no relationship (device list, if any, still ingested)");
                return;
            }

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

            // Multi-device: persist under the sender's MASTER identity, so any device of
            // one person updates the ONE identity profile, with the empty-profile guard:
            // a profile-less sibling must not blank a good row. The showcase asset
            // bundle uses the same CLEAR/b64 semantics as the blobs.
            let showcase_assets_bytes: Option<Vec<u8>> = if showcase_assets_b64.is_empty() {
                None
            } else if showcase_assets_b64 == "CLEAR" {
                Some(vec![])
            } else {
                base64::engine::general_purpose::STANDARD.decode(&showcase_assets_b64).ok()
                    .filter(|b| b.len() <= 2_000_000)
            };

            // Owner proof over every field, REQUIRED: nothing is stored without it, so
            // an unverified signature can never be laundered into a ProfileRelay by us.
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
            let verified_proof = social::verified_profile_proof(
                peer_str, updated_at, &fields, profile_sig.as_deref(), profile_pk.as_deref(),
            );
            let proof = verified_proof.as_ref().map(|(sig, pk)| crate::storage::ProfileProof {
                sig, pk,
                avatar_hash: &avatar_hash,
                banner_hash: &banner_hash,
                assets_hash: &showcase_assets_hash,
            });
            let (profile_master, saved) = social::save_incoming_profile(
                &peer_str, &display_name, &status, &about_me, updated_at,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
                social::sanitize_incoming_showcase(showcase_board.as_deref()),
                showcase_assets_bytes.as_deref(), proof,
                social::sanitize_incoming_frame(avatar_frame.as_deref()),
                social::sanitize_incoming_anim(avatar_anim.as_deref()),
                social::sanitize_incoming_anim(banner_anim.as_deref()),
                support_creds.as_deref(),
                support_creds_sig.as_deref(),
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

        HavenMessage::FileRequest { file_id, chunks, offset } => {

            use crate::node::file_transfer;
            hollow_log!("[HOLLOW-FILE] FileRequest from {peer_str} for {file_id}");

            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                if let Ok(Some(file_meta)) = store.get_file_metadata(&file_id) {
                        // SECURITY: serving used to be UNGATED, so any peer that
                        // learned a file_id (guests see them in plaintext public
                        // messages) could pull ANY file we hold, DM attachments
                        // included. Serve only:
                        //   * DM files      -> the counterparty or our own siblings
                        //   * channel files -> members; PUBLIC channels -> anyone
                        // `requester_is_member` also picks the header transport below.
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
                                            // Membership is not enough for a RESTRICTED
                                            // channel: the header we would send back
                                            // carries the file's AES key, so serving it to
                                            // a member who cannot see the channel hands over
                                            // exactly what the subgroup exists to withhold.
                                            s.is_member(&requester_master)
                                                && crate::node::crypto_handler::channel_readable_by(
                                                    s, &requester_master, cid,
                                                ),
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
                        // HONEST NEGATIVE ANSWER. The gate above has passed, so
                        // this requester is entitled to these bytes and we simply
                        // do not have them; saying nothing leaves the asker unable
                        // to tell "they are offline" from "they deleted it". Note
                        // what is NOT answered: a blocked requester, an unknown
                        // file_id and a non-entitled requester still get silence,
                        // because an answer would leak whether we hold a row.
                        let served_bytes = if file_meta.expired_at.is_some() {
                            Err("expired")
                        } else {
                            match file_meta.disk_path.as_ref() {
                                Some(p) => crate::node::at_rest::read_all(std::path::Path::new(p))
                                    .map_err(|_| "gone"),
                                None => Err("gone"),
                            }
                        };
                        let file_data = match served_bytes {
                            Ok(bytes) => bytes,
                            Err(reason) => {
                                hollow_log!("[HOLLOW-FILE] Cannot serve {file_id} to {peer_str} ({reason}) — answering file_unavail");
                                super::olm_lane::carry(
                                    ws_cmd_tx, peer_str, None,
                                    &HavenMessage::FileUnavailable {
                                        file_id: file_id.clone(),
                                        reason: reason.to_string(),
                                    },
                                    super::olm_lane::NoSession::Queue,
                                );
                                return;
                            }
                        };
                        if let Ok(enc) = crate::vault::pipeline::aes_encrypt(&file_data) {
                            // UNIQUE temp file per encryption (the suffix is this
                            // request's random AES nonce). A fixed
                            // `.stream_send_{file_id}.tmp` was CLOBBERED when the
                            // receiver re-requested rapidly: request B's re-encryption
                            // overwrote the temp while A's stream was still reading it,
                            // so A streamed B's ciphertext under A's header key.
                            let nonce_hex = hex::encode(enc.nonce);
                            let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}_{nonce_hex}.tmp"));
                            if let Ok(()) = tokio::fs::write(&temp_path, &enc.ciphertext).await {
                                // The card's author, as the committed id names it.
                                let served_author = Some(super::resolver::resolve(&file_meta.sender_id));
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
                                            album: None,
                                            inline_bytes: None,
                                            thumb: file_meta.thumb_b64.clone(),
                                            // Explicit-pull response — the receiver's
                                            // receipt bypasses the gate; no voice flag
                                            // is persisted to rehydrate from.
                                            voice: false,
                                            author: served_author.clone(),
                                            sha256: file_meta.sha256.clone(),
                                        }),
                                    };
                                    let header_json = serde_json::to_string(&header).unwrap_or_default();
                                    send_encrypted_message(
                                        olm, crypto_store,
                                        &peer_str, &header_json, event_tx,
                                        ws_cmd_tx, ws_room_peers,
                                    ).await;
                                } else {
                                    // Non-member on a PUBLIC channel (guest browser).
                                    super::olm_lane::carry(
                                        ws_cmd_tx, peer_str, None,
                                        &HavenMessage::PublicFileHeader {
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
                                            author: served_author.clone(),
                                            sha256: file_meta.sha256.clone(),
                                        },
                                        super::olm_lane::NoSession::Queue,
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
                                    // temp, so only delete when none is pending, or every file
                                    // re-request leaks a duplicate encrypted copy.
                                    if !pending_webrtc_sends.contains_key(&file_id) {
                                        let _ = tokio::fs::remove_file(&temp_path).await;
                                    }
                            }
                        }
                }
            }
        }

        // Negative answer to a FileRequest we sent. The owner of the pending
        // ask table decides what it means (asked-set rule, rotation, and the
        // local retention check that gates the one store write this can cause).
        HavenMessage::FileUnavailable { file_id, reason } => {
            file_asks::handle_file_unavailable(
                ws_cmd_tx, ws_room_peers, server_states, event_tx,
                pending_file_asks, requested_file_receipts, declined_file_ids,
                pending_ws_transfers,
                &peer_str, file_id, reason,
                local_peer_str, device_peer_id,
                db_path, db_passphrase,
            ).await;
        }

        // -- WebRTC signaling --
        HavenMessage::RtcOffer { sdp, conn_id } => {
            if sdp.len() > MAX_SDP_SIZE {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED RtcOffer — size {} exceeds limit from {peer_str}", sdp.len());
                return;
            }
            // Guarding the OFFER kills the connection at initiation; the other Rtc
            // signals are inert without one. Blocked and unknown peers get none.
            if !voice_handler::data_channel_peer_allowed(
                server_states, master_peer_str, peer_str, db_path, db_passphrase,
            ) {
                hollow_log!("[HOLLOW-SECURITY] Dropped RtcOffer from {peer_str}: no friendship or shared server");
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

        // -- Conferences (node/conference.rs; reports/shipped/voice-and-media/CONFERENCES_PLAN.md) --
        HavenMessage::ConferenceJoinRequest { conf_id, display_name, avatar_hash, key_package, code_proof } => {
            // Blocklist + access-code gating live inside the handler (host-only).
            super::conference::handle_inbound_join_request(
                conference_host, mls, crypto_store, ws_cmd_tx, event_tx,
                peer_str, local_peer_str,
                conf_id, display_name, avatar_hash, key_package, code_proof,
            ).await;
        }
        // Host frames count only from the host the meeting id names; Dart is handed
        // that host, never the frame's sender.
        HavenMessage::ConferenceJoinDenied { conf_id, reason, host } => {
            if super::conference::verified_host(&conf_id, peer_str, &host).is_none() {
                hollow_log!("[HOLLOW-SECURITY] Dropped a meeting denial for {conf_id} from {peer_str}: not its host");
                return;
            }
            super::conference::clear_pending_knock(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceJoinDenied { conf_id, reason }).await;
        }
        HavenMessage::ConferenceLobbyInfo { conf_id, host_name, host_avatar_hash, host } => {
            let Some(host_master) = super::conference::verified_host(&conf_id, peer_str, &host) else {
                hollow_log!("[HOLLOW-SECURITY] Dropped meeting lobby info for {conf_id} from {peer_str}: not its host");
                return;
            };
            let _ = event_tx.send(NetworkEvent::ConferenceLobbyInfo {
                conf_id, host_peer_id: host_master, host_name, host_avatar_hash,
            }).await;
        }
        HavenMessage::ConferenceChat { conf_id, body } => {
            super::conference::handle_inbound_chat(
                mls, crypto_store, event_tx, ws_cmd_tx, master_keypair, conf_id, body, db_path, db_passphrase,
            ).await;
        }
        HavenMessage::ConferenceEnded { conf_id, host } => {
            let Some(host_master) = super::conference::verified_host(&conf_id, peer_str, &host) else {
                hollow_log!("[HOLLOW-SECURITY] Dropped a meeting end for {conf_id} from {peer_str}: not its host");
                return;
            };
            super::conference::clear_pending_knock(&conf_id);
            super::conference::forget_meeting_key(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceEnded {
                conf_id, by_peer_id: host_master,
            }).await;
        }
        HavenMessage::ConferenceKicked { conf_id, host } => {
            // The MLS remove already cut us off; this is the courtesy signal.
            let Some(host_master) = super::conference::verified_host(&conf_id, peer_str, &host) else {
                hollow_log!("[HOLLOW-SECURITY] Dropped a meeting kick for {conf_id} from {peer_str}: not its host");
                return;
            };
            super::conference::clear_pending_knock(&conf_id);
            super::conference::forget_meeting_key(&conf_id);
            let _ = event_tx.send(NetworkEvent::ConferenceKicked {
                conf_id, by_peer_id: host_master,
            }).await;
        }

        // -- Voice call signaling --
        //
        // SECURITY (TRANSPORT-1): 1:1 call signaling is Olm-encrypted and arrives as
        // `MessageEnvelope::CallSignal` after decryption. A Call* frame reaching us
        // in the CLEAR came from the relay or an on-path attacker, not from the peer,
        // and honouring it would let the relay hand us an SFrame media key of its own
        // choosing in a forged CallAccept. Reject, never log-and-pass.
        HavenMessage::CallInvite { .. }
        | HavenMessage::CallAccept { .. }
        | HavenMessage::CallReject { .. }
        | HavenMessage::CallEnd { .. }
        | HavenMessage::CallBusy { .. }
        | HavenMessage::CallMediaRestart { .. }
        | HavenMessage::CallAnsweredElsewhere { .. }
        | HavenMessage::CallSdpOffer { .. }
        | HavenMessage::CallSdpAnswer { .. }
        | HavenMessage::CallIceCandidate { .. }
        | HavenMessage::CallVideoState { .. }
        | HavenMessage::CallAudioState { .. }
        | HavenMessage::CallScreenState { .. }
        | HavenMessage::CallScreenOffer { .. }
        | HavenMessage::CallScreenAnswer { .. }
        | HavenMessage::CallScreenIce { .. }
        | HavenMessage::CallScreenWatch { .. }
        | HavenMessage::CallRecordingState { .. } => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED plaintext call signal from {peer_str}");
        }

        // -- Gossip relay tree --
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
                // A neighbour's list names only members of this server (J6).
                let state = server_states.get(&server_id);
                for p in &peers {
                    if p != local_peer_str && state.is_some_and(|s| s.is_member(p)) {
                        overlay.known_peers.insert(p.clone());
                        overlay.peer_scores
                            .entry(p.clone())
                            .or_insert_with(super::gossip::PeerScore::new);
                    }
                }
            }
        }

        // -- Profile request --
        HavenMessage::ProfileRequest => {
            if social::profile_audience(server_states, master_peer_str, peer_str, db_path, db_passphrase) == social::Audience::None {
                // A co-member's device our resolver cannot place yet still gets the
                // pull half, on the strength of its leaf in our server group.
                let certified = mls.as_ref().is_some_and(|m| {
                    certified_co_member_leaves(m, server_states, master_peer_str).iter().any(|(_, l)| l.device == peer_str)
                });
                if certified {
                    hollow_log!("[HOLLOW-PROFILE] ProfileRequest from co-member device {peer_str} — sending our profile");
                    social::send_own_profile_to_co_member(
                        ws_cmd_tx, master_keypair, local_peer_str, peer_str, is_invisible, true, db_path, db_passphrase,
                    );
                } else {
                    hollow_log!("[HOLLOW-SECURITY] Ignored a ProfileRequest from {peer_str}: no relationship");
                }
                return;
            }
            hollow_log!("[HOLLOW-PROFILE] ProfileRequest from {peer_str} — sending our profile");
            // The pull half of the light-announce protocol: the blobs, or the card
            // with its avatar for someone we are not close to.
            social::send_own_profile_full_to_peer(
                ws_cmd_tx, ws_room_peers, server_states,
                local_peer_str, master_keypair, peer_str,
                is_invisible,
                db_path, db_passphrase,
            );
        }

        HavenMessage::ProfileCard { card, avatar_b64, device_list } => {
            // The roster first: it is what binds the sending device to the card's master.
            let outcome = super::roster_book::ingest(
                event_tx, ws_cmd_tx, master_peer_str, device_peer_id, peer_str,
                device_list, db_path, db_passphrase,
            ).await;
            enforce_device_revocations(
                &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                local_peer_str, ws_room_peers, pending_mls_removals,
            );
            // A card speaks only for its sender's own identity.
            if card.master != super::resolver::resolve(peer_str) || !super::profile_card::card_holds(&card) {
                hollow_log!("[HOLLOW-SECURITY] Dropped a profile card from {peer_str}: not its own, or not signed by it");
                return;
            }
            use base64::Engine;
            let avatar = (!avatar_b64.is_empty())
                .then(|| base64::engine::general_purpose::STANDARD.decode(&avatar_b64).ok())
                .flatten()
                .filter(|b| b.len() <= super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES);
            if super::profile_card::store_card(&card, avatar.as_deref(), db_path, db_passphrase) {
                let _ = event_tx.send(NetworkEvent::ProfileUpdated { peer_id: card.master.clone() }).await;
            }
            // A new avatar we hold no bytes for: pull them once.
            social::maybe_request_full_profile(
                ws_cmd_tx, ws_room_peers, peer_str, &card.master,
                &avatar_b64, "", &card.avatar_hash, "", "", "",
                device_peer_id, db_path, db_passphrase,
            );
        }

        HavenMessage::RosterNotice { roster } => {
            let outcome = super::roster_book::ingest(
                event_tx, ws_cmd_tx, master_peer_str, device_peer_id, peer_str,
                Some(roster), db_path, db_passphrase,
            ).await;
            if outcome.asks_again {
                super::roster_book::ask_again(
                    event_tx, ws_cmd_tx, master_keypair, device_keypair, server_states.keys(), db_path, db_passphrase,
                ).await;
            }
            if outcome.our_devices_grew {
                super::roster_book::show_relay(ws_cmd_tx, local_peer_str, db_path, db_passphrase);
            }
            converge_new_siblings(
                &outcome.added, ws_cmd_tx, ws_room_peers, master_keypair, device_peer_id,
                local_peer_str, server_states, is_invisible, db_path, db_passphrase, call_book.own(),
            );
            enforce_device_revocations(
                &outcome.newly_revoked, olm, crypto_store, mls.as_ref(),
                local_peer_str, ws_room_peers, pending_mls_removals,
            );
        }

        HavenMessage::EmoteRequest { hashes } => {
            emotes::handle_emote_request(ws_cmd_tx, peer_str, hashes, db_path, db_passphrase);
        }

        HavenMessage::EmoteAssets { bundle_json, missing } => {
            emotes::handle_emote_assets(
                ws_cmd_tx, ws_room_peers, event_tx, pending_asset_asks,
                peer_str, bundle_json, missing, local_peer_str,
                db_path, db_passphrase,
            ).await;
        }

        HavenMessage::ProfileRequestFor { target_peer_id } => {
            // Only about someone the asker shares a server with, and only from a member.
            let shared = server_states.values().any(|s| {
                !s.is_deleted() && s.is_member(peer_str) && s.is_member(master_peer_str) && s.is_member(&target_peer_id)
            });
            if !shared || super::blocklist::is_blocked(peer_str) {
                hollow_log!("[HOLLOW-SECURITY] Ignored a ProfileRequestFor from {peer_str}: no server shared with its target");
                return;
            }
            hollow_log!("[HOLLOW-PROFILE] ProfileRequestFor {target_peer_id} from {peer_str}");
            social::handle_profile_request_for(
                ws_cmd_tx,
                peer_str, &target_peer_id,
                db_path, db_passphrase,
            );
        }

        HavenMessage::ProfileRelay {
            source_peer_id, display_name, status, about_me, updated_at, avatar_b64, twitch_username,
            avatar_hash, banner_hash, showcase_board, showcase_assets_hash, avatar_frame, avatar_anim,
            banner_anim, profile_sig, profile_pk,
        } => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRelay for {source_peer_id} from {peer_str}");
            social::handle_profile_relay(
                event_tx, server_states,
                social::RelayedProfile {
                    source_peer_id, display_name, status, about_me, updated_at, avatar_b64, twitch_username,
                    avatar_hash, banner_hash, showcase_board, showcase_assets_hash, avatar_frame, avatar_anim,
                    banner_anim, profile_sig, profile_pk,
                },
                db_path, db_passphrase,
            ).await;
        }

        // -- Plaintext voice channel handlers (MLS epoch-resilient) --
        // These arrive as plaintext HavenMessage instead of MLS MessageEnvelope
        // to survive epoch staleness after reconnection.

        HavenMessage::VoiceChannelJoin { server_id, channel_id } => {
            // Self-echo guard: both id forms (sender echoes carry our DEVICE id).
            if peer_str == local_peer_str || peer_str == device_peer_id { return; }
            // Conferences have no CRDT membership, so the equivalent check is MLS
            // group membership (leaf credentials ARE device ids), which only an
            // ADMITTED peer can hold. That is what lets the PeerJoined re-broadcast
            // and the conference reply-on-join sync reach late joiners.
            let refusal = if super::conference::is_conference_sid(&server_id) {
                if !mls.as_ref().is_some_and(|m| m.group_members(&server_id).iter().any(|c| c == peer_str)) {
                    Some("not in the meeting group")
                } else {
                    (channel_id != super::conference::CONF_CHANNEL).then_some("not the meeting channel")
                }
            } else {
                voice_handler::voice_join_refusal(server_states.get(&server_id), peer_str, &channel_id)
            };
            if let Some(reason) = refusal {
                hollow_log!("[HOLLOW-SECURITY] BLOCKED plaintext VoiceChannelJoin from {peer_str} for {server_id}/{channel_id}: {reason}");
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



#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    /// HOL-SEC-032 and design ID-1. A device holding our master key is ours only when
    /// our roster makes it a member: a removed device, or one that restored a backup and
    /// was never admitted, is neither bound to our master nor sent our friends, servers
    /// or DM history, whatever key it holds.
    #[test]
    fn authz_only_a_roster_member_gets_sibling_state() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();

        let master = NativeKeypair::from_secret_bytes(&[0x01; 32]);
        let master_id = master.peer_id();
        let local_device = NativeKeypair::from_secret_bytes(&[0x02; 32]).peer_id();
        let removed = NativeKeypair::from_secret_bytes(&[0x03; 32]).peer_id();
        let never_admitted = NativeKeypair::from_secret_bytes(&[0x04; 32]).peer_id();
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("sibling.db").to_str().unwrap().to_string();
        let pass = "cd".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        crate::storage::MessageStore::open(&db, &pass)
            .unwrap()
            .save_friend("friend", "accepted", "outgoing", 1)
            .unwrap();
        super::super::resolver::seed_self(&master_id, std::slice::from_ref(&local_device));
        super::super::resolver::mark_revoked(std::slice::from_ref(&removed));
        let (ws_cmd_tx, mut ws_cmd_rx) =
            tokio::sync::mpsc::unbounded_channel::<super::super::ws_client::WsCommand>();
        let rooms: HashMap<String, std::collections::HashSet<String>> = HashMap::from([(
            format!("inbox:{master_id}"),
            std::collections::HashSet::from([local_device.clone(), removed.clone(), never_admitted.clone()]),
        )]);

        for outsider in [&removed, &never_admitted] {
            on_verified_sibling(
                &ws_cmd_tx, &rooms, &master, &master_id, &HashMap::new(),
                false, &db, &pass, outsider, None,
            );
            assert_ne!(
                super::super::resolver::resolve(outsider),
                master_id,
                "a device outside our roster was bound to our master",
            );
            assert!(
                ws_cmd_rx.try_recv().is_err(),
                "a device outside our roster was sent our state",
            );
        }
        super::super::resolver::clear_all();
    }
}
