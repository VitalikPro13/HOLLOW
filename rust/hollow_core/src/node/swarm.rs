use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

const MLS_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(60);

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

use crate::crdt::hlc::Hlc;
use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{self as crdt_sync, StateVector};
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::signaling::{self, SignalingCmd, SignalingEvent};

use super::types::*;

use super::crypto_handler::{
    message_signing_payload, sign_message, verify_message_signature, verify_message_signature_cached,
    persist_mls_state, persist_crypto_state, persist_olm_session,
    peer_is_reachable, is_mls_coordinator, is_vault_coordinator, elect_coordinator, ws_room_for_peer,
    send_mls_broadcast, send_encrypted_message,
    send_message_to_peer, send_raw_to_peer, send_raw_to_identity,
};
use super::file_handler;
use super::link_handler;
use super::message_ops;
use super::social;
use super::sync_handler;
use super::vault_ops;
use super::twitch;
use super::voice_handler;

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

    // Signaling register must be signed by the DEVICE key (it authenticates the
    // device's transport presence under the device peer_id).
    let sig_keypair = device_keypair.clone();

    // Spawn the signaling background task (device-keyed).
    let signaling_url = format!("https://{relay_domain}");
    let (sig_cmd_tx, sig_event_rx) =
        signaling::spawn_signaling_task(sig_keypair, device_peer_id.clone(), signaling_url);

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
        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store, sig_cmd_tx, sig_event_rx,
        bundle_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,
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

    // Dead signaling channels — the real task is never spawned. The event loop
    // holds `sig_cmd_tx` (its sends go nowhere) and selects on `sig_event_rx`
    // (which never yields, since its sender is dropped here). Signaling is a
    // non-fatal HTTP peer-discovery fallback; DM/room delivery never needs it.
    let (sig_cmd_tx, _sig_cmd_rx) = mpsc::channel::<SignalingCmd>(8);
    let (_sig_event_tx, sig_event_rx) = mpsc::channel::<SignalingEvent>(8);

    // Injected WS channels (the broker owns the other ends).
    let (ws_cmd_tx, ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
    let (ws_event_tx, ws_event_rx) = tokio::sync::mpsc::unbounded_channel();

    let handle = tokio::spawn(run_event_loop(
        event_tx, cmd_rx, cmd_tx, olm, crypto_store, crdt_store, sig_cmd_tx, sig_event_rx,
        bundle_keypair, ws_cmd_tx, ws_event_rx, master_peer_id.clone(), device_peer_id,
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
    sig_cmd_tx: mpsc::Sender<SignalingCmd>,
    mut sig_event_rx: mpsc::Receiver<SignalingEvent>,
    bundle_keypair: crate::identity::native_identity::NativeKeypair,
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

    // Peers we've already triggered sync for this session.
    let mut synced_peers: std::collections::HashSet<String> = std::collections::HashSet::new();

    let mut is_invisible = initial_invisible;
    if initial_invisible {
        hollow_log!("[HOLLOW-STATUS] Node starting in invisible mode (persisted preference)");
    }

    // -- WebRTC peer tracking (Phase 5A) --
    // Peers with active WebRTC data channels (Dart notifies us via NodeCommand).
    let mut webrtc_peers: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Pending WebRTC sends — stored so we can retry via WSS on failure.
    // Key: transfer_id, Value: (peer_id, kind, id, source_path, total_size)
    let mut pending_webrtc_sends: HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)> = HashMap::new();

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
            match store.load_device_list(&master_peer_str) {
                Ok(Some(list)) => super::resolver::seed_self(&master_peer_str, &list.devices),
                _ => super::resolver::seed_self(&master_peer_str, &[device_peer_id.clone()]),
            }
        }
    }
    // Multi-device (Step 6): install the device→master resolver into the `crdt`
    // module so ServerState's role/ban/permission/membership accessors collapse a
    // device id to its master internally (one chokepoint for dozens of call sites).
    crate::crdt::set_identity_resolver(super::resolver::resolve);

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
                    let server_ids: Vec<String> = server_states.keys().cloned().collect();
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
                            let foreign = cred_id != device_peer_id
                                && (cred_id != master_peer_str || has_sibling);
                            if foreign {
                                hollow_log!("[HOLLOW-MLS] MLS credential {cred_id} not ours (device={device_peer_id}, has_sibling={has_sibling}); discarding inherited identity + groups, will mint fresh");
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
    let mut pending_server_joins: HashMap<String, Option<String>> = HashMap::new();
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

    // Track failed sync requests per peer — retried after session re-establishment.
    // Maps peer_id_str → Vec<(server_id, channel_id, since_timestamp)>
    let mut pending_sync_requests: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();

    // Track server_ids for which we've already requested MLS bootstrap (KeyPackage sent to owner).
    // Prevents spamming the owner on every MlsChannelMessage for an unknown group.
    // Value = when the request was sent; entries expire after MLS_BOOTSTRAP_TIMEOUT to allow retry.
    let mut mls_bootstrap_requested: HashMap<String, std::time::Instant> = HashMap::new();

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
    let mut mls_decrypt_failures: HashMap<String, u32> = HashMap::new();

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

    loop {
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // If switching rooms, unregister from the old room and clear state.
                        if let Some(old_room) = active_room.as_ref().filter(|r| *r != &room_code) {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: old_room.clone(),
                            }).await;
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                        }
                        active_room = Some(room_code.clone());
                        // Join the WS relay room for DMs.
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                            room_code: room_code.clone(),
                        });
                        // Also register with signaling for peer discovery.
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: room_code.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code,
                        }).await;
                    }
                    NodeCommand::SendMessage { peer_id: peer_id_str, text, message_id, reply_to_mid, link_preview } => {
                        last_message_traffic = std::time::Instant::now();
                        message_ops::handle_send_message(
                            &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut pending_messages, &mut key_request_in_flight,
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_peer_id,
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
                            &bundle_keypair, &local_peer_str, name,
                            &crypto_store, &crdt_store,
                        ).await;
                    }

                    NodeCommand::CreateChannel { server_id, name, category, channel_type } => {
                        if sync_handler::handle_create_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, name, category, channel_type,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RemoveChannel { server_id, channel_id } => {
                        if sync_handler::handle_remove_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RenameServer { server_id, new_name } => {
                        if sync_handler::handle_rename_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, new_name,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::RenameChannel { server_id, channel_id, new_name } => {
                        if sync_handler::handle_rename_channel(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, new_name,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UpdateServerSetting { server_id, key, value } => {
                        sync_handler::handle_update_server_setting(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, key, value,
                            &crypto_store, &crdt_store,
                        ).await;
                    }

                    NodeCommand::DeleteServer { server_id } => {
                        if sync_handler::handle_delete_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &sig_cmd_tx, &bundle_keypair, &local_peer_str,
                            server_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::JoinServer { server_id, twitch_proof_json } => {
                        sync_handler::handle_join_server(
                            &mut pending_server_joins, &mls, &ws_cmd_tx,
                            &ws_room_peers, &sig_cmd_tx, &cmd_tx,
                            server_id, twitch_proof_json,
                            &crdt_store,
                        ).await;
                    }

                    NodeCommand::ChangeRole { server_id, peer_id, new_role } => {
                        if sync_handler::handle_change_role(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, peer_id, new_role,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::KickMember { server_id, peer_id } => {
                        if sync_handler::handle_kick_member(
                            &mut server_states, &mut mls, &mut olm, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
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

                    NodeCommand::LeaveServer { server_id } => {
                        if sync_handler::handle_leave_server(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &sig_cmd_tx, &bundle_keypair, &local_peer_str,
                            server_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::ChangeRolePermissions { server_id, role, permissions } => {
                        if sync_handler::handle_change_role_permissions(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, role, permissions,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::BanMember { server_id, peer_id } => {
                        if sync_handler::handle_ban_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnbanMember { server_id, peer_id } => {
                        if sync_handler::handle_unban_member(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, peer_id,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::CreateLabel { server_id, name, color } => {
                        let label_id = format!("lbl-{}", hex::encode(&{
                            let mut buf = [0u8; 4];
                            getrandom::fill(&mut buf).expect("RNG");
                            buf
                        }));
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelCreated { label_id, name, color },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::DeleteLabel { server_id, label_id } => {
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelDeleted { label_id },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UpdateLabel { server_id, label_id, name, color } => {
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelUpdated { label_id, name, color },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::AssignLabel { server_id, label_id, peer_id } => {
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelAssigned { label_id, peer_id },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnassignLabel { server_id, label_id, peer_id } => {
                        if sync_handler::handle_label_op(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, CrdtPayload::LabelUnassigned { label_id, peer_id },
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelVisibility { server_id, channel_id, visibility } => {
                        if sync_handler::handle_set_channel_visibility(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, visibility,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelPosting { server_id, channel_id, posting } => {
                        if sync_handler::handle_set_channel_posting(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, posting,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetChannelPublic { server_id, channel_id, is_public } => {
                        if sync_handler::handle_set_channel_public(
                            &mut server_states, &mut mls, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, is_public,
                            &crypto_store, &crdt_store,
                        ).await { continue; }
                    }

                    // -- Guest sync commands (Public Channels Phase 3) --
                    NodeCommand::RequestPublicChannels { server_id } => {
                        hollow_log!("[HOLLOW-GUEST] RequestPublicChannels for {server_id}, is_member={}", server_states.contains_key(&server_id));
                        if server_states.contains_key(&server_id) {
                            let state = &server_states[&server_id];
                            let channels: Vec<PublicChannelEntryFfi> = state.channels.values()
                                .filter(|ch| ch.is_public && ch.channel_type == crate::crdt::server_state::ChannelType::Text)
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
                            let _ = event_tx.send(NetworkEvent::PublicChannelListReceived {
                                server_id: server_id.clone(),
                                server_name: state.name().to_string(),
                                channels,
                                server_avatar: local_avatar,
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
                                    store.get_channel_messages_since(&server_id, &channel_id, 0, limit)
                                };
                                if let Ok(msgs) = messages_result {
                                    let has_more = msgs.len() as i32 >= limit;
                                    let msg_ids: Vec<String> = msgs.iter().filter_map(|m| m.message_id.clone()).collect();
                                    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
                                    let ffi_messages: Vec<GuestSyncMessageFfi> = msgs.iter().map(|m| {
                                        let reactions = m.message_id.as_ref()
                                            .and_then(|mid| reactions_map.get(mid))
                                            .map(|rs| rs.iter().map(|(e, p, ts, _sig, _pk)| GuestReactionFfi {
                                                emoji: e.clone(), peer_id: p.clone(), added_at: *ts,
                                            }).collect())
                                            .unwrap_or_default();
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
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, peer_id, nickname,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::SetTwitchUsername { server_id, peer_id, twitch_username } => {
                        if sync_handler::handle_set_twitch_username(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
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
                    NodeCommand::UpdateProfile { display_name, status, about_me, avatar_bytes, banner_bytes, twitch_username } => {
                        social::handle_update_profile(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &mut mls, &server_states,
                            &crypto_store, &local_peer_str, &master_keypair, &device_peer_id,
                            display_name, status, about_me,
                            avatar_bytes, banner_bytes, is_invisible, twitch_username,
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
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_peer_id,
                            peer_id_str, message_id, new_text,
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
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_peer_id,
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
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_peer_id,
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
                            &bundle_keypair, &pub_key_b64, &local_peer_str, &device_peer_id,
                            peer_id_str, message_id, emoji,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendFriendRequest { peer_id: peer_id_str } => {
                        social::handle_send_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &sig_cmd_tx,
                            &mut pending_friend_requests,
                            &local_peer_str, peer_id_str,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::SendFriendRequestByNickname { nickname } => {
                        pending_nickname_resolve = Some(nickname.clone());
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ResolveNickname { nickname });
                    }

                    NodeCommand::ClaimNickname { nickname } => {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ClaimNickname { nickname });
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

                    NodeCommand::AcceptFriendRequest { peer_id: peer_id_str } => {
                        social::handle_accept_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers, &sig_cmd_tx,
                            &local_peer_str, peer_id_str,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RejectFriendRequest { peer_id: peer_id_str } => {
                        social::handle_reject_friend_request(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            peer_id_str,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RemoveFriend { peer_id: peer_id_str } => {
                        social::handle_remove_friend(
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            peer_id_str,
                            &mut pending_friend_removals,
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
                            room_code: server_id,
                            topics: channel_ids,
                        });
                    }

                    NodeCommand::UpdateChannelLayout { server_id, layout_json } => {
                        if sync_handler::handle_update_channel_layout(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, layout_json,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::PinMessage { server_id, channel_id, message_id } => {
                        if sync_handler::handle_pin_message(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, message_id,
                            &crdt_store,
                        ).await { continue; }
                    }

                    NodeCommand::UnpinMessage { server_id, channel_id, message_id } => {
                        if sync_handler::handle_unpin_message(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
                            server_id, channel_id, message_id,
                            &crdt_store,
                        ).await { continue; }
                    }

                    // -- Storage pledge (Phase 4) --
                    NodeCommand::SetStoragePledge { server_id, pledge_bytes } => {
                        sync_handler::handle_set_storage_pledge(
                            &mut server_states, &event_tx, &ws_cmd_tx,
                            &ws_room_peers, &bundle_keypair, &local_peer_str,
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
                            &mut server_states, &mut olm, &crypto_store, &mut mls,
                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                            &webrtc_peers, &mut pending_webrtc_sends,
                            &bundle_keypair, &local_peer_str,
                            server_id, channel_id, file_name, mime_type, message_id,
                            ciphertext, aes_key, aes_nonce, original_size, content_id,
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
                        let SendFilePayload { peer_id, server_id, channel_id, file_path, message_id, message_text, vthumb, override_width, override_height, share_ref } = *box_payload;
                        file_handler::handle_send_file(
                            peer_id, server_id, channel_id, file_path, message_id, message_text,
                            vthumb, override_width, override_height, share_ref,
                            &event_tx, &server_states, &bundle_keypair, &pub_key_b64, &local_peer_str,
                            &device_peer_id,
                            &mut olm, &crypto_store, &mut mls,
                            &ws_cmd_tx, &ws_room_peers, &webrtc_peers, &mut pending_webrtc_sends,
                            &mut gossip_overlays,
                            &db_path, &db_passphrase,
                        ).await;
                    }

                    NodeCommand::RequestFile { file_id, peer_id: peer_id_str, chunks } => {
                        file_handler::handle_request_file(
                            file_id, peer_id_str, chunks,
                            &ws_cmd_tx, &ws_room_peers,
                            &pending_ws_transfers,
                        );
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
                            &gossip_overlays, &local_peer_str, &event_tx,
                        ).await;
                    }

                    NodeCommand::VoiceChannelLeave { server_id, channel_id } => {
                        voice_handler::handle_voice_channel_leave(
                            server_id, channel_id,
                            &mut mls, &ws_cmd_tx, &ws_room_peers,
                            &server_states, &bundle_keypair, &crypto_store,
                            &mut voice_channel_participants, &mut voice_channel_gossip_mode,
                            &gossip_overlays, &local_peer_str, &event_tx,
                        ).await;
                    }

                    NodeCommand::VoiceChannelSendSignal { server_id, channel_id, peer_id, signal_type, payload } => {
                        last_message_traffic = std::time::Instant::now();
                        voice_handler::handle_voice_channel_send_signal(
                            server_id, channel_id, peer_id, signal_type, payload,
                            &mut mls, &mut olm, &crypto_store,
                            &ws_cmd_tx, &ws_room_peers,
                            &server_states, &bundle_keypair,
                            &local_peer_str, &event_tx,
                        ).await;
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
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: room.clone(),
                            }).await;
                        }
                        for sid in server_states.keys() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: sid.clone(),
                            }).await;
                        }
                    }
                }
            }
            // Handle signaling service events (bootstrap peer discovery).
            Some(sig_event) = sig_event_rx.recv() => {
                match sig_event {
                    SignalingEvent::BootstrapPeers { peers } => {
                        // Discovery result — log quietly, never as a user-facing Error
                        // event (0 peers is normal when everyone's already connected via WS).
                        hollow_log!("[HOLLOW-SIGNALING] Bootstrap returned {} peers", peers.len());
                        for bp in peers {
                            // Skip ourselves (master AND device id — the relay/signaling
                            // can report us under either).
                            if bp.peer_id == local_peer_str || bp.peer_id == device_peer_id {
                                continue;
                            }
                            // Skip peers already visible via WS relay.
                            let already_ws = ws_room_peers.values().any(|ps| ps.contains(&bp.peer_id));
                            if already_ws {
                                continue;
                            }
                            // Emit PeerDiscovered for the UI.
                            let _ = event_tx
                                .send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: bp.peer_id.clone(),
                                        addresses: vec!["ws-relay".to_string()],
                                    },
                                })
                                .await;
                        }
                    }
                    SignalingEvent::Error { message } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error { message })
                            .await;
                    }
                }
            }

            // -- WebSocket relay events --
            Some(ws_event) = ws_event_rx.recv() => {
                use super::ws_client::WsEvent;
                match ws_event {
                    WsEvent::Connected => {
                        hollow_log!("[HOLLOW-WS] Relay connected — joining inbox + server + DM rooms");
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
                        // Verify local shard integrity on startup.
                    // Removes DB records for shards whose files are missing or corrupt.
                    {
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
                        key_request_in_flight.clear();
                        key_bundle_sent_to.clear();
                        mls_bootstrap_requested.clear();
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
                        let local_str = local_peer_str.to_string();
                        for participants in voice_channel_participants.values_mut() {
                            participants.retain(|p| *p == local_str);
                        }
                        voice_channel_participants.retain(|_, p| !p.is_empty());
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

                            if peer_id != local_peer_str && peer_id != device_peer_id {

                                // Only trigger sync if not already synced this session
                                // (prevents duplicate sync when both WS and libp2p fire).
                                let is_new = synced_peers.insert(peer_id.clone());

                                let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: peer_id.clone(),
                                        addresses: vec!["ws-relay".to_string()],
                                    },
                                }).await;

                                // Drain pending friend requests for this peer.
                                if let Some(requested_at) = pending_friend_requests.remove(&peer_id) {
                                    hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared, sending queued friend request");
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &peer_id, HavenMessage::FriendRequest { requested_at },
                                    );
                                }

                                // Drain pending friend removals for this peer.
                                if pending_friend_removals.remove(&peer_id) {
                                    hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id} appeared, sending queued friend removal");
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        &peer_id, HavenMessage::FriendRemove,
                                    );
                                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                        let _ = store.remove_friend(&peer_id);
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

                                    // Multi-device (Phase 6): a peer joining OUR OWN inbox room
                                    // (`inbox:{master}`) is BY DEFINITION our own other device —
                                    // only our devices ever join our master inbox. Use that as the
                                    // sibling proof DIRECTLY, instead of `same_identity` (which
                                    // depends on the device-list having already been exchanged — a
                                    // chicken-and-egg that lost the friend-share to join-timing
                                    // races). Seed the resolver from this fact, then push our friend
                                    // list AND pull theirs (covers either side being the empty one).
                                    let own_inbox = format!("inbox:{}", local_peer_str);
                                    if room == own_inbox && peer_id != device_peer_id {
                                        // The joining device belongs to our master identity.
                                        super::resolver::update(&peer_id, &local_peer_str);

                                        // CRITICAL (presence collapse): the inbox-proof tells us
                                        // `peer_id` is OUR sibling device. Merge it into our own
                                        // master-signed device list RIGHT HERE — do not wait for a
                                        // ProfileUpdate carrying a device_list (a freshly-imported
                                        // sibling has no profile, so it never sends one, and our list
                                        // would stay 1 device forever → a friend like AL only ever
                                        // learns ONE of our devices and shows us offline when that one
                                        // quits). Union + re-sign + persist, then re-announce our
                                        // profile (now carrying BOTH devices) to every friend we share
                                        // a room with so they converge immediately.
                                        let our_set_grew = super::crypto_handler::merge_sibling_device_id(
                                            &master_keypair, &device_peer_id, &peer_id,
                                            &db_path, &db_passphrase,
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
                                                if super::resolver::same_identity(&pid, &local_peer_str) { continue; }
                                                social::send_own_profile_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    &local_peer_str, &master_keypair, &device_peer_id, &pid,
                                                    is_invisible,
                                                    &db_path, &db_passphrase,
                                                );
                                            }
                                        }
                                        // Also hand the sibling our device list directly (via a
                                        // ProfileUpdate) so IT converges on the union too — covers the
                                        // case where the sibling is the one with a profile and we are
                                        // the fresh device.
                                        social::send_own_profile_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &local_peer_str, &master_keypair, &device_peer_id, &peer_id,
                                            is_invisible,
                                            &db_path, &db_passphrase,
                                        );

                                        // SIBLING PROFILE SYNC: a freshly-imported device holds the
                                        // master KEY but none of the master's profile CONTENT (name/
                                        // avatar). If our OWN identity profile is empty/absent, pull it
                                        // from the sibling — the incoming ProfileUpdate resolves to our
                                        // master (== local_peer_str), so save_incoming_profile adopts it
                                        // as our own. Without this the substitute device shows the
                                        // identity online but nameless.
                                        let need_profile = crate::storage::MessageStore::open(&db_path, &db_passphrase)
                                            .ok()
                                            .and_then(|s| s.load_profile(&local_peer_str).ok().flatten())
                                            .map(|p| p.display_name.trim().is_empty())
                                            .unwrap_or(true);
                                        if need_profile {
                                            hollow_log!(
                                                "[HOLLOW-MULTIDEV] Own profile empty — requesting it from sibling {peer_id}"
                                            );
                                            send_message_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                &peer_id, HavenMessage::ProfileRequest,
                                            );
                                        }

                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
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
                                                        "[HOLLOW-MULTIDEV] Sibling device {peer_id} joined our inbox — sharing {} friends",
                                                        entries.len()
                                                    );
                                                    send_message_to_peer(
                                                        &ws_cmd_tx, &ws_room_peers,
                                                        &peer_id, HavenMessage::FriendListSync { friends: entries },
                                                    );
                                                }
                                            }
                                        }
                                        // Pull theirs too (in case WE are the empty device).
                                        hollow_log!(
                                            "[HOLLOW-MULTIDEV] Sibling {peer_id} joined our inbox — requesting their friend list"
                                        );
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, HavenMessage::FriendListRequest,
                                        );

                                        // Multi-device backfill (Step 5): ask the sibling for the
                                        // FULL DM history across all conversations, both directions,
                                        // since our per-conversation high-water mark. Closes the
                                        // offline gap that live fan-out (Step 3) and the one-time
                                        // link snapshot (Step 4) can't. Throttled per-sibling
                                        // (Step 5.1) so this path + the device-list-ingest path +
                                        // reconnect re-fires collapse into one request; incremental
                                        // + idempotent (message_id dedup) so a skipped redundant
                                        // request loses nothing.
                                        super::crypto_handler::request_sibling_dm_backfill(
                                            &ws_cmd_tx, &ws_room_peers, &peer_id,
                                            &db_path, &db_passphrase,
                                        );

                                        // Multi-device link (Step 4): if WE are essentially empty
                                        // (a fresh mnemonic import) and a populated sibling is now
                                        // online, AUTO-REQUEST a full snapshot from it. The sibling
                                        // shows a Confirm before sending. We gate on a near-empty DB
                                        // so a populated device never re-pulls, and we only fire once
                                        // per sibling per session (link_snapshot_requested).
                                        let (my_msgs, my_friends, _my_servers, _hp) =
                                            crate::api::storage::snapshot_state_summary();
                                        if my_msgs == 0 && my_friends == 0
                                            && link_snapshot_requested.insert(peer_id.clone())
                                        {
                                            hollow_log!(
                                                "[HOLLOW-LINK] Empty device — auto-requesting snapshot from sibling {peer_id}"
                                            );
                                            // Mnemonic path has no typed code; both siblings share the
                                            // master id, so use it as the .hollow passphrase.
                                            link_handler::set_my_link_code(&local_peer_str);
                                            link_handler::handle_request_link_snapshot(
                                                &ws_cmd_tx, &ws_room_peers, &peer_id, false, false,
                                            );
                                        }
                                    }

                                    // Proactive key exchange if no CONFIRMED Olm session.
                                    // An outbound-only session is NOT proof the peer can decrypt
                                    // us — only a confirmed (bidirectional) session is. Reporting
                                    // SessionEstablished for an unconfirmed session is the bug where
                                    // "A writes and B doesn't see it" (B never built its half).
                                    if olm.has_confirmed_session(&peer_id) {
                                        let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_id.clone(),
                                        }).await;
                                        // Drain any pending messages queued while peer was offline.
                                        if let Some(queued) = pending_messages.remove(&peer_id) {
                                            hollow_log!("[HOLLOW-CRYPTO] PeerJoined: draining {} pending messages for {peer_id}", queued.len());
                                            for text in queued {
                                                send_encrypted_message(
                                                    &mut olm, &crypto_store, &peer_id, &text, &event_tx,
                                                    &ws_cmd_tx, &ws_room_peers,
                                                ).await;
                                            }
                                        }
                                        sync_handler::flush_pending_sync_requests(
                                            &mut pending_sync_requests, &peer_id,
                                            &mut olm, &crypto_store,
                                            &bundle_keypair, &event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                                            &crdt_store,
                                            &db_path, &db_passphrase,
                                        ).await;
                                    } else if !key_request_is_fresh(&key_request_in_flight, &peer_id) {
                                        // No session, or only an unconfirmed outbound session — send
                                        // (or resend, if the prior request went stale) a KeyRequest.
                                        // The reconciliation sweep will retry if this frame is dropped.
                                        hollow_log!("[HOLLOW-WS] Proactive key exchange for {peer_id}");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            &peer_id, HavenMessage::KeyRequest,
                                        );
                                        key_request_in_flight.insert(peer_id.clone(), std::time::Instant::now());
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
                                                            },
                                                        );
                                                        mls_bootstrap_requested.insert(sid.clone(), std::time::Instant::now());
                                                    }
                                                }
                                            }

                                            // Voice channel: re-broadcast our join to the reconnecting peer
                                            // so they know we're in a voice channel.
                                            for (vc_key, vc_peers) in voice_channel_participants.iter() {
                                                if vc_peers.contains(&local_peer_str.to_string()) {
                                                    // vc_key = "server_id:channel_id"
                                                    if let Some(colon) = vc_key.find(':') {
                                                        let vc_sid = &vc_key[..colon];
                                                        let vc_cid = &vc_key[colon+1..];
                                                        if vc_sid == sid {
                                                            hollow_log!("[HOLLOW-VC] Re-broadcasting VC join to reconnected peer {peer_id} for {vc_cid}");
                                                            // Plaintext — MLS epoch is likely stale on reconnecting peer.
                                                            send_message_to_peer(
                                                                &ws_cmd_tx, &ws_room_peers,
                                                                &peer_id, HavenMessage::VoiceChannelJoin {
                                                                    server_id: vc_sid.to_string(),
                                                                    channel_id: vc_cid.to_string(),
                                                                },
                                                            );
                                                        }
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
                                            let since = if multi_device {
                                                store.get_latest_dm_timestamp_any(&convo)
                                            } else {
                                                store.get_latest_dm_timestamp(&convo)
                                            }
                                            .unwrap_or(None)
                                            .unwrap_or(0);
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
                                            twitch_proof_json: pending_server_joins.get(&room).cloned().flatten(),
                                        },
                                    );
                                    hollow_log!("[HOLLOW-CRDT] Sent pending join request to {peer_id} for {room}");
                                }
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

                        // Hollow Share: drop the peer from peer_have + free
                        // any in-flight chunk requests so the scheduler retries.
                        if room.starts_with("share:") {
                            super::share_handler::forget_peer(&mut share_registry, &peer_id);
                        }

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
                        ws_room_peers.insert(room.clone(), room_set);
                        for gone in vanished {
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

                        // On first RoomMembers, broadcast our profile to all rooms.
                        // This ensures peers who were online while we were offline get our latest profile.
                        if !profile_broadcast_done {
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
                        let sv_cache: std::collections::HashMap<&str, String> = server_states.iter()
                            .filter_map(|(sid, state)| {
                                let sv = StateVector::from_server_state(state);
                                serde_json::to_string(&sv).ok().map(|json| (sid.as_str(), json))
                            })
                            .collect();

                        for pid_str in &peers {
                            if pid_str != &local_peer && pid_str.as_str() != device_peer_id {
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
                                                    },
                                                );
                                                mls_bootstrap_requested.insert(sid.clone(), std::time::Instant::now());
                                            }
                                        }
                                    }

                                    // Drain pending friend requests for this peer.
                                    if let Some(requested_at) = pending_friend_requests.remove(pid_str) {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers, sending queued friend request");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            pid_str, HavenMessage::FriendRequest { requested_at },
                                        );
                                    }

                                    // Drain pending friend removals for this peer.
                                    if pending_friend_removals.remove(pid_str) {
                                        hollow_log!("[HOLLOW-FRIENDS] Peer {pid_str} appeared in RoomMembers, sending queued friend removal");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            pid_str, HavenMessage::FriendRemove,
                                        );
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            let _ = store.remove_friend(pid_str);
                                        }
                                    }

                                    // Olm key exchange + pending_messages drain + DM sync.
                                    // RoomMembers fires on the JOINING peer (us) while PeerJoined
                                    // fires on the EXISTING peer (them). Without this, DM sync is
                                    // one-directional: they ask us, but we never ask them.
                                    if olm.has_confirmed_session(pid_str) {
                                        let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                            peer_id: pid_str.clone(),
                                        }).await;
                                        // Drain any pending messages queued while peer was offline.
                                        if let Some(queued) = pending_messages.remove(pid_str) {
                                            hollow_log!("[HOLLOW-CRYPTO] RoomMembers: draining {} pending messages for {pid_str}", queued.len());
                                            for text in queued {
                                                send_encrypted_message(
                                                    &mut olm, &crypto_store, pid_str, &text, &event_tx,
                                                    &ws_cmd_tx, &ws_room_peers,
                                                ).await;
                                            }
                                        }
                                        sync_handler::flush_pending_sync_requests(
                                            &mut pending_sync_requests, pid_str,
                                            &mut olm, &crypto_store,
                                            &bundle_keypair, &event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                                            &crdt_store,
                                            &db_path, &db_passphrase,
                                        ).await;
                                    } else if !key_request_is_fresh(&key_request_in_flight, pid_str) {
                                        hollow_log!("[HOLLOW-WS] RoomMembers: proactive key exchange for {pid_str}");
                                        send_message_to_peer(
                                            &ws_cmd_tx, &ws_room_peers,
                                            pid_str, HavenMessage::KeyRequest,
                                        );
                                        key_request_in_flight.insert(pid_str.clone(), std::time::Instant::now());
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
                                            let since = if multi_device {
                                                store.get_latest_dm_timestamp_any(&convo)
                                            } else {
                                                store.get_latest_dm_timestamp(&convo)
                                            }
                                            .unwrap_or(None)
                                            .unwrap_or(0);
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

                                // Send join request if this room matches a pending server join.
                                // Outside is_new guard — peer may already be in synced_peers
                                // from a DM room but we still need to send the join request.
                                if pending_server_joins.contains_key(&room) {
                                    send_message_to_peer(
                                        &ws_cmd_tx, &ws_room_peers,
                                        pid_str, HavenMessage::ServerJoinRequest {
                                            server_id: room.clone(),
                                            twitch_proof_json: pending_server_joins.get(&room).cloned().flatten(),
                                        },
                                    );
                                    hollow_log!("[HOLLOW-CRDT] Sent pending join request to {pid_str} for {room}");
                                }
                            }
                        }
                    }
                    WsEvent::BinaryDirect { room: _, from, data } => {
                        if let Some(completed) = super::ws_stream_transfer::ws_stream_receive(
                            &mut pending_ws_transfers, &data,
                        ) {
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
                            let dm_room = dm_room_code(&local_peer, peer_id);
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
                                send_message_to_peer(&ws_cmd_tx, &ws_room_peers, pid, HavenMessage::KeyRequest);
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
                    WsEvent::NicknameResolved { nickname, peer_id } => {
                        if pending_nickname_resolve.as_deref() == Some(&nickname) {
                            pending_nickname_resolve = None;
                            social::handle_send_friend_request(
                                &event_tx, &ws_cmd_tx, &ws_room_peers, &sig_cmd_tx,
                                &mut pending_friend_requests,
                                &local_peer_str, peer_id,
                                &db_path, &db_passphrase,
                            ).await;
                        }
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
                        if let Ok(text) = String::from_utf8(data) {
                            if let Ok(msg) = serde_json::from_str::<HavenMessage>(&text) {
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
                                                    &event_tx, &webrtc_peers, &from, root_hash, indices,
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

                                    handle_incoming_request(
                                        &mut olm, &crypto_store, &crdt_store, &event_tx,
                                        &mut pending_messages, &mut key_request_in_flight, &mut key_bundle_sent_to,
                                        &mut server_states, &bundle_keypair,
                                        &master_keypair, &master_peer_str, &device_peer_id,
                                        &mut pending_server_joins,
                                        &mut pending_sync_requests, &mut mls,
                                        &mut mls_bootstrap_requested,
                                        &sig_cmd_tx,
                                        &mut pending_shard_assembly, &mut pending_file_streams,
                                        &mut pending_shard_streams, &mut early_file_streams,
                                        &mut pending_link_snapshots,
                                        &mut decrypt_fail_cooldown,
                                        &mut pending_mls_key_packages, &mut pending_mls_removals,
                                        &mut mls_decrypt_failures,
                                        &ws_cmd_tx, &ws_room_peers,
                                        &webrtc_peers, &mut pending_webrtc_sends,
                                        &mut channel_sync_sent,
                                        &mut gossip_overlays,
                                        &mut voice_channel_participants,
                                        &mut voice_channel_gossip_mode,
                                        &mut vc_signal_rate_tokens,
                                        &mut mls_dirty,
                                        &guest_rooms,
                                        &subscribed_channels,
                                        &db_path, &db_passphrase,
                                        &local_peer_str, &from, is_invisible, msg,
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
                if let Some(ref mut mls_mgr) = mls {
                    // Phase 1: Batch removals (stale members + recovery re-adds) — single commit.
                    let removal_sids: Vec<String> = pending_mls_removals.keys().cloned().collect();
                    for server_id in removal_sids {
                        if let Some(peers_to_remove) = pending_mls_removals.remove(&server_id) {
                            if peers_to_remove.is_empty() { continue; }
                            let unique: Vec<String> = {
                                let mut set = std::collections::HashSet::new();
                                peers_to_remove.into_iter().filter(|p| set.insert(p.clone())).collect()
                            };
                            let refs: Vec<&str> = unique.iter().map(|s| s.as_str()).collect();
                            hollow_log!("[HOLLOW-MLS] Batch-removing {} members from {server_id}: {:?}", refs.len(), refs);
                            match mls_mgr.remove_members_batch(&server_id, &refs) {
                                Ok(commit_bytes) => {
                                    if let Err(e) = mls_mgr.merge_pending_commit(&server_id) {
                                        hollow_log!("[HOLLOW-MLS] Failed to merge batch removal commit: {e}");
                                        continue;
                                    }
                                    persist_mls_state(mls_mgr, &crypto_store);
                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                    if let Some(state) = server_states.get(&server_id) {
                                        let commit_msg = HavenMessage::MlsCommit { server_id: server_id.clone(), commit: commit_b64.clone() };
                                        let commit_data = serde_json::to_vec(&commit_msg).unwrap_or_default();
                                        // Per-device fan-out; skip self and the exact
                                        // removed device ids (members are master-keyed).
                                        let removed: std::collections::HashSet<&str> = unique.iter().map(|s| s.as_str()).collect();
                                        let mut sent_devices: std::collections::HashSet<String> = std::collections::HashSet::new();
                                        for member_peer in state.members.keys() {
                                            if super::resolver::same_identity(member_peer, &local_peer_str) { continue; }
                                            for dev in crate::node::crypto_handler::online_devices_for(&ws_room_peers, member_peer) {
                                                if removed.contains(dev.as_str()) { continue; }
                                                if !sent_devices.insert(dev.clone()) { continue; }
                                                send_raw_to_peer(&ws_cmd_tx, &ws_room_peers, &dev, commit_data.clone());
                                            }
                                        }
                                    }
                                }
                                Err(e) => hollow_log!("[HOLLOW-MLS] Batch removal failed for {server_id}: {e}"),
                            }
                        }
                    }

                    // Phase 2: Batch additions — single commit.
                    let server_ids: Vec<String> = pending_mls_key_packages.keys().cloned().collect();
                    for server_id in server_ids {
                        if let Some(queued) = pending_mls_key_packages.remove(&server_id) {
                            if queued.is_empty() { continue; }

                            // Deduplicate by peer_id — keep only the last KeyPackage per peer.
                            let mut deduped: HashMap<String, Vec<u8>> = HashMap::new();
                            for (peer_id, kp_bytes) in queued {
                                deduped.insert(peer_id, kp_bytes);
                            }
                            let queued: Vec<(String, Vec<u8>)> = deduped.into_iter().collect();
                            if queued.is_empty() { continue; }

                            hollow_log!("[HOLLOW-MLS] Processing batch of {} KeyPackages for {server_id}", queued.len());

                            match mls_mgr.add_members_batch(&server_id, &queued) {
                                Ok((commit_bytes, welcome_bytes, added_peers)) => {
                                    if let Err(e) = mls_mgr.merge_pending_commit(&server_id) {
                                        hollow_log!("[HOLLOW-MLS] Failed to merge batch commit: {e}");
                                        continue;
                                    }
                                    persist_mls_state(mls_mgr, &crypto_store);
                                    // Emit epoch change for SFrame key rotation.
                                    if let Ok(sframe_key) = mls_mgr.export_secret(&server_id, "sframe", b"", 32) {
                                        let epoch = mls_mgr.epoch(&server_id).unwrap_or(0);
                                        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                            server_id: server_id.clone(), epoch, sframe_key,
                                        }).await;
                                    }

                                    let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(&welcome_bytes);
                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);

                                    // Send Welcome to all new joiners.
                                    let welcome_data = serde_json::to_vec(&HavenMessage::MlsWelcome {
                                        server_id: server_id.clone(),
                                        welcome: welcome_b64,
                                    }).unwrap_or_default();
                                    for peer_id_str in &added_peers {
                                            if peer_is_reachable(&ws_room_peers, peer_id_str) {
                                                send_raw_to_peer(
                                                    &ws_cmd_tx, &ws_room_peers,
                                                    peer_id_str, welcome_data.clone(),
                                                );
                                            }
                                    }

                                    // Broadcast single Commit to all EXISTING leaves
                                    // (fanned out per-DEVICE — members are master-keyed
                                    // and the master has no socket). The skip is
                                    // per-DEVICE, not per-identity: a member may hold
                                    // several leaves where only ONE was just added
                                    // (the new sibling B); its already-joined sibling A
                                    // still needs this Commit for the new epoch. So we
                                    // send to every online device of every member EXCEPT
                                    // the exact just-added device ids (they get the
                                    // Welcome) and our own devices.
                                    if let Some(state) = server_states.get(&server_id) {
                                        let commit_data = serde_json::to_vec(&HavenMessage::MlsCommit {
                                            server_id: server_id.clone(),
                                            commit: commit_b64,
                                        }).unwrap_or_default();
                                        let mut sent_devices: std::collections::HashSet<String> = std::collections::HashSet::new();
                                        for member_peer_str in state.members.keys() {
                                            if super::resolver::same_identity(member_peer_str, &local_peer_str) { continue; }
                                            for dev in crate::node::crypto_handler::online_devices_for(&ws_room_peers, member_peer_str) {
                                                if added_peers.contains(&dev) { continue; }   // gets the Welcome instead
                                                if !sent_devices.insert(dev.clone()) { continue; } // already sent
                                                send_raw_to_peer(&ws_cmd_tx, &ws_room_peers, &dev, commit_data.clone());
                                            }
                                        }
                                    }

                                    hollow_log!("[HOLLOW-MLS] Batch-added {} members to server {server_id}: {:?}", added_peers.len(), added_peers);

                                    // Coordinator side: request channel sync FROM each
                                    // recovered peer.  During the stale epoch the
                                    // coordinator may have dropped messages that the
                                    // recovered peer sent (decrypt failed).  Syncing
                                    // from them fills the gap on this side.
                                    if let Some(state) = server_states.get(&server_id) {
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &db_passphrase) {
                                            for peer_id_str in &added_peers {
                                                if !peer_is_reachable(&ws_room_peers, peer_id_str) { continue; }
                                                for cid in state.channels.keys() {
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
                                Err(e) => hollow_log!("[HOLLOW-MLS] Batch add failed for {server_id}: {e}"),
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

                // Re-bootstrap signaling rooms (HTTP, non-fatal fallback).
                if let Some(room) = &active_room {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: room.clone(),
                    }).await;
                }
                for sid in server_states.keys() {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: sid.clone(),
                    }).await;
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
                    for peer in &online {
                        // Only reconcile peers we actually have a relationship with —
                        // a shared-server member, a peer with queued DMs, or one with a
                        // half-built (unconfirmed) session. Avoids spamming co-room
                        // strangers (e.g. public-channel guests we never DM).
                        let is_member = server_states.values()
                            .any(|s| s.is_member(peer));
                        let has_pending = pending_messages.contains_key(peer);
                        let half_session = olm.has_unconfirmed_session(peer);
                        if !(is_member || has_pending || half_session) {
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
                        send_message_to_peer(&ws_cmd_tx, &ws_room_peers, peer, HavenMessage::KeyRequest);
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
                // Snapshot progress under lock, then emit events outside lock.
                let snapshot: Vec<(String, u64, u64)> = {
                    let Ok(map) = super::ws_stream_transfer::stream_progress().lock() else { continue };
                    map.iter().map(|(id, p)| {
                        (id.clone(), p.bytes_received.load(std::sync::atomic::Ordering::Relaxed), p.total_bytes)
                    }).collect()
                };
                for (file_id, received, total) in snapshot {
                    if received == 0 { continue; }
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
                    let online_peers: std::collections::HashSet<String> = ws_room_peers.values()
                        .flat_map(|peers| peers.iter().cloned())
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
                                        send_encrypted_message(
                                            &mut olm, &crypto_store, source_peer, &env_json,
                                            &event_tx, &ws_cmd_tx, &ws_room_peers,
                                        ).await;
                                        total_requested += 1;
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
                if !rebalance_pending.is_empty() {
                    let servers_to_check: Vec<String> = rebalance_pending.drain().collect();
                    hollow_log!("[HOLLOW-VAULT] Event-driven rebalance for {} servers", servers_to_check.len());

                    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");

                    if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir) {
                        let online_peers: std::collections::HashSet<String> = ws_room_peers.values()
                            .flat_map(|peers| peers.iter().cloned())
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
                                                send_encrypted_message(
                                                    &mut olm, &crypto_store, source_peer, &env_json,
                                                    &event_tx, &ws_cmd_tx, &ws_room_peers,
                                                ).await;
                                                total_requested += 1;
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
                super::gossip_relay::handle_gossip_rotation(&mut gossip_overlays, &event_tx, webrtc_peers.len()).await;
            }

            // -- Gossip broadcast dedup eviction timer (60s) --
            _ = gossip_eviction_timer.tick() => {
                super::gossip_relay::handle_gossip_eviction(&mut gossip_overlays, &ws_cmd_tx, &ws_room_peers);
            }

            // -- Gossip peer exchange timer (2 minutes) --
            _ = gossip_exchange_timer.tick() => {
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
                let messaging_active = std::time::Instant::now()
                    .duration_since(last_message_traffic) < super::share_handler::COEXIST_PAUSE;
                super::share_handler::tick(&mut share_registry, &ws_cmd_tx, messaging_active, &webrtc_peers, &event_tx, &bundle_keypair).await;
            }

            // -- MLS state debounce (2s) --
            _ = mls_persist_timer.tick() => {
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

/// Pack a slice of stored DM messages into wire `DmSyncItem`s, joining in each
/// message's reactions and file metadata in two batch queries. Shared by the
/// friend `DmSyncRequest` responder and the multi-device sibling backfill
/// responder so the (reactions + file-meta) join logic lives in one place.
fn build_dm_sync_items(
    store: &crate::storage::MessageStore,
    messages: &[crate::storage::messages::StoredMessage],
) -> Vec<DmSyncItem> {
    let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
    let file_ids: Vec<&str> = messages.iter().filter_map(|m| m.file_id.as_deref()).collect();
    let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

    messages.iter().map(|m| {
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
            })
        });
        DmSyncItem {
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
            hidden_at: m.hidden_at,
            reactions,
        }
    }).collect()
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
    master_peer_str: &str,
    device_peer_id: &str,
    pending_server_joins: &mut HashMap<String, Option<String>>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    mls: &mut Option<MlsManager>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    pending_shard_assembly: &mut HashMap<String, PendingShardAssembly>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (std::path::PathBuf, u64, String)>,
    pending_link_snapshots: &mut HashMap<String, file_handler::LinkSnapshotState>,
    decrypt_fail_cooldown: &mut HashMap<String, std::time::Instant>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    mls_decrypt_failures: &mut HashMap<String, u32>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    channel_sync_sent: &mut HashMap<String, std::time::Instant>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    vc_signal_rate_tokens: &mut HashMap<String, (u32, std::time::Instant)>,
    mls_dirty: &mut bool,
    guest_rooms: &std::collections::HashSet<String>,
    subscribed_channels: &HashMap<String, Vec<String>>,
    db_path: &str,
    db_passphrase: &str,
    local_peer_str: &str,
    peer_str: &str,
    is_invisible: bool,
    request: HavenMessage,
) {

    match request {
        HavenMessage::KeyRequest => {
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
                send_message_to_peer(ws_cmd_tx, ws_room_peers, peer_str, HavenMessage::KeyBundle {
                    identity_key, one_time_key: otk,
                });
            }
        }

        HavenMessage::KeyBundle { identity_key, one_time_key } => {
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
                        Err(_) => {
                            // Existing session can't handle this PreKey — it's a
                            // genuinely new session from the peer (e.g. they re-keyed).
                            // Replace our session with the new inbound one.
                            olm.remove_session(&peer_str);
                            match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                                Ok(pt) => {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_str.to_string(),
                                        })
                                        .await;
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
                                    // Both paths failed. Apply cooldown to prevent flood.
                                    let now = std::time::Instant::now();
                                    let should_rekey = match decrypt_fail_cooldown.get(peer_str) {
                                        Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                                        None => true,
                                    };
                                    if should_rekey {
                                        hollow_log!("[HOLLOW-CRYPTO] PreKey session creation also failed for {peer_str}: {e2} — initiating re-key");
                                        decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                                        if !key_request_is_fresh(key_request_in_flight, peer_str) {
                                            key_request_in_flight.insert(peer_str.to_string(), now);
                                            send_message_to_peer(
                                                ws_cmd_tx, ws_room_peers,
                                                peer_str, HavenMessage::KeyRequest,
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
                        Err(e) => {
                            // Apply cooldown to prevent flood from stale PreKey messages.
                            let now = std::time::Instant::now();
                            let should_rekey = match decrypt_fail_cooldown.get(peer_str) {
                                Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                                None => true,
                            };
                            if should_rekey {
                                hollow_log!("[HOLLOW-CRYPTO] PreKey session creation failed for {peer_str}: {e} — initiating re-key");
                                decrypt_fail_cooldown.insert(peer_str.to_string(), now);
                                if !key_request_is_fresh(key_request_in_flight, peer_str) {
                                    key_request_in_flight.insert(peer_str.to_string(), now);
                                    send_message_to_peer(
                                        ws_cmd_tx, ws_room_peers,
                                        peer_str, HavenMessage::KeyRequest,
                                    );
                                }
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
                        }
                        pt
                    }
                    Err(e) => {
                        // Decrypt failure — check cooldown before killing session.
                        // This prevents rapid session thrashing when many in-flight
                        // chunks fail (e.g., large file transfer with 1000+ chunks).
                        let now = std::time::Instant::now();
                        let should_rekey = match decrypt_fail_cooldown.get(peer_str) {
                            Some(last_kill) => now.duration_since(*last_kill) >= Duration::from_secs(5),
                            None => true, // First failure — allow rekey
                        };

                        if should_rekey {
                            hollow_log!("[HOLLOW-SWARM] Decrypt failed for {peer_str}: {e} — removing stale session");
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

                            // Send a KeyRequest to re-establish the session.
                            if !key_request_is_fresh(key_request_in_flight, peer_str) {
                                key_request_in_flight.insert(peer_str.to_string(), now);
                                send_message_to_peer(
                                    ws_cmd_tx, ws_room_peers,
                                    peer_str, HavenMessage::KeyRequest,
                                );
                            }
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
                    let ChannelMessagePayload { sid, cid, text: msg_text, ts, sig, pk, mid, reply_to, file_id, link_preview } = *inner;
                    // SECURITY: Verify sender is a member of the claimed server.
                    if let Some(state) = server_states.get(&sid) {
                        if !state.is_member(peer_str) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — not a member of server {sid}");
                            return;
                        }
                    } else {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage for unknown server {sid}");
                        return;
                    }

                    // SECURITY: Reject messages with invalid signatures.
                    if sig.is_some() {
                        let payload = message_signing_payload(
                            "ch", &format!("{sid}:{cid}"), &peer_str, ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — signature verification FAILED");
                            return;
                        }
                    }

                    // SECURITY: Enforce 4,000 character limit on message text.
                    let msg_text = if msg_text.len() > 4000 { msg_text[..4000].to_string() } else { msg_text };

                    // Persist channel message using sender's timestamp.
                    // INSERT OR IGNORE deduplicates via UNIQUE(server_id, channel_id, sender_id, timestamp, text).
                    let mut is_new = true;
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        match store.insert_channel_message(
                            &sid, &cid, &peer_str, &msg_text, false, ts,
                            sig.as_deref(), pk.as_deref(), mid.as_deref(),
                            reply_to.as_deref(), file_id.as_deref(),
                        ) {
                            Ok(0) => { is_new = false; } // INSERT OR IGNORE skipped — duplicate
                            Ok(_) => {}
                            Err(_) => { is_new = false; }
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

                    // Only emit event if this is a genuinely new message.
                    if is_new {
                        let _ = event_tx
                            .send(NetworkEvent::ChannelMessageReceived {
                                server_id: sid,
                                channel_id: cid,
                                from_peer: peer_str.to_string(),
                                text: msg_text,
                                timestamp: ts,
                                message_id: mid.unwrap_or_default(),
                                reply_to_mid: reply_to.unwrap_or_default(),
                                link_preview,
                                signature: sig,
                                public_key: pk,
                            })
                            .await;
                    }
                }
                Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, .. }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} sync messages for {cid} in {sid} (total: {total}, has_more: {has_more:?})", messages.len());
                    let local_peer = local_peer_str.to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.begin_transaction();
                        let mut pk_cache: std::collections::HashMap<String, Vec<u8>> = std::collections::HashMap::new();
                        for msg in &messages {
                            // Verify signature on each synced message.
                            // Skip edited messages — the stored signature was created
                            // against the original text, not the edited text.
                            if msg.sig.is_some() && msg.edited_at.is_none() {
                                let payload = message_signing_payload(
                                    "ch", &format!("{sid}:{cid}"), &msg.s, msg.ts, &msg.t,
                                );
                                if !verify_message_signature_cached(&msg.s, msg.sig.as_deref(), msg.pk.as_deref(), &payload, &mut pk_cache) {
                                    hollow_log!("[HOLLOW-CRYPTO] Sig verify FAILED for synced msg from {} ts={} text_len={} has_pk={}", msg.s, msg.ts, msg.t.len(), msg.pk.is_some());
                                }
                            }

                            let is_mine = msg.s == local_peer;
                            let already_exists = msg.mid.as_ref()
                                .map(|mid| store.channel_message_exists(mid))
                                .unwrap_or(false);

                            if !already_exists {
                                match store.insert_channel_message(
                                    &sid, &cid, &msg.s, &msg.t, is_mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
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
                            }

                            // Apply deletion if the message was hidden on the syncing peer.
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                let _ = store.set_channel_message_hidden(mid, hidden_ts);
                            }

                            // Insert file metadata and emit FileHeaderReceived for late joiners.
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
                                }).await;
                            }

                            // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
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
                    let DirectMessagePayload { text: msg_text, ts, sig, pk, mid, reply_to, file_id, link_preview, convo } = *inner;
                    // SECURITY: Enforce 4,000 character limit on message text.
                    let msg_text = if msg_text.len() > 4000 { msg_text[..4000].to_string() } else { msg_text };

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
                    let convo_peer = match (is_own_device, convo.as_deref()) {
                        (true, Some(c)) => c.to_string(),
                        _ => super::resolver::resolve(&peer_str),
                    };

                    // Verify DM signature if present. The signed payload's context is
                    // the RECIPIENT master and the signer is the SENDER master:
                    //   - Normal incoming DM (from a friend): recipient = OUR master,
                    //     signer = the friend (`convo_peer`).
                    //   - Self fan-out echo (`is_own_device`, our OWN sibling mirroring
                    //     a message WE sent): WE were the signer and the FRIEND
                    //     (`convo_peer`) was the recipient — so context/signer are
                    //     SWAPPED. Verifying with the friend as signer (as for a normal
                    //     DM) made every self-echo log a (cosmetic) sig FAIL.
                    if sig.is_some() {
                        let (recipient_m, signer_m): (&str, &str) = if is_own_device {
                            (&convo_peer, master_peer_str)
                        } else {
                            (master_peer_str, &convo_peer)
                        };
                        let payload = message_signing_payload(
                            "dm", recipient_m, signer_m, ts, &msg_text,
                        );
                        if !verify_message_signature(signer_m, sig.as_deref(), pk.as_deref(), &payload) {
                            hollow_log!("[HOLLOW-CRYPTO] Signature verification FAILED for DM from {peer_str} (signer {signer_m})");
                        }
                    }

                    // Persist received DM using sender's timestamp (not Dart DateTime.now()).
                    // This ensures DM sync timestamps are consistent for deduplication.
                    // `is_own` flags a message echoed from our OWN other device as ours.
                    let mut is_new = true;
                    {
                        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                            match store.insert(
                                &convo_peer, &msg_text, is_own_device, ts,
                                sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                reply_to.as_deref(), file_id.as_deref(),
                            ) {
                                Ok(0) => { is_new = false; } // Duplicate
                                Ok(_) => {}
                                Err(_) => { is_new = false; }
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

                    // Only emit event if this is a genuinely new message.
                    if is_new {
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
                            })
                            .await;
                    }
                }
                Ok(MessageEnvelope::DmSyncBatch { messages, has_more }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} DM sync messages from {peer_str} (has_more: {has_more:?})", messages.len());
                    let local_peer = local_peer_str.to_string();
                    // Multi-device: the DM conversation key is the sender's MASTER id
                    // (transport target stays raw `peer_str`). No-op on single-device.
                    let convo_peer = super::resolver::resolve(&peer_str);
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
                        let mut pk_cache: std::collections::HashMap<String, Vec<u8>> = std::collections::HashMap::new();
                        for msg in &messages {
                            // Effective direction from OUR perspective (see the
                            // responder-relative note above): invert on the friend
                            // path, keep as-is from a sibling.
                            let is_mine = if from_sibling { msg.mine } else { !msg.mine };

                            // Verify signature if present.
                            // Skip edited messages — sig was against original text.
                            if msg.sig.is_some() && msg.edited_at.is_none() {
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
                                let payload = message_signing_payload(
                                    "dm", recipient_m, sender_m, msg.ts, &msg.t,
                                );
                                if !verify_message_signature_cached(sender_m, msg.sig.as_deref(), msg.pk.as_deref(), &payload, &mut pk_cache) {
                                    hollow_log!("[HOLLOW-CRYPTO] Sig verify FAILED for DM sync msg from {peer_str} (master {convo_peer}, is_mine={is_mine}) ts={} text_len={} has_pk={}", msg.ts, msg.t.len(), msg.pk.is_some());
                                }
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
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
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

                            // Apply deletion if the message was hidden on the syncing peer.
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                if store.set_dm_message_hidden(mid, hidden_ts).is_ok() {
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
                            if let Some(ref fm) = msg.file_meta {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    fm.mid.as_deref(), "dm", &convo_peer,
                                    &fm.sender, false, fm.ts,
                                    fm.vthumb.as_ref(),
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
                                }).await;
                            }

                            // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
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
                        let mut pk_cache: std::collections::HashMap<String, Vec<u8>> = std::collections::HashMap::new();
                        for msg in &messages {
                            // Verify signature if present (skip edited — sig was over original).
                            // The original sig context is the FRIEND conversation, not us:
                            //   mine=true  → sender = our master, recipient = convo
                            //   mine=false → sender = convo,      recipient = our master
                            // The claimed signer (whose pubkey is checked) is the SENDER master.
                            if msg.sig.is_some() && msg.edited_at.is_none() {
                                let (sender_m, recipient_m): (&str, &str) = if msg.mine {
                                    (&local_peer, &convo_peer)
                                } else {
                                    (&convo_peer, &local_peer)
                                };
                                let payload = message_signing_payload(
                                    "dm", recipient_m, sender_m, msg.ts, &msg.t,
                                );
                                if !verify_message_signature_cached(sender_m, msg.sig.as_deref(), msg.pk.as_deref(), &payload, &mut pk_cache) {
                                    hollow_log!("[HOLLOW-CRYPTO] Sig verify FAILED for sibling DM (convo {convo_peer}, mine={}) ts={}", msg.mine, msg.ts);
                                }
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
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
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

                            // Apply deletion if hidden on the sibling.
                            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                                if store.set_dm_message_hidden(mid, hidden_ts).is_ok() {
                                    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                                        peer_id: convo_peer.clone(),
                                        message_id: mid.clone(),
                                        deleted_at: hidden_ts,
                                    }).await;
                                }
                            }

                            // File metadata (so the card renders; bytes fetch on demand).
                            if let Some(ref fm) = msg.file_meta {
                                let _ = store.insert_file_metadata(
                                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                                    fm.size, 0, fm.img, fm.w, fm.h,
                                    fm.mid.as_deref(), "dm", &convo_peer,
                                    &fm.sender, false, fm.ts,
                                    fm.vthumb.as_ref(),
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
                                }).await;
                            }

                            // Reactions (INSERT OR IGNORE — idempotent).
                            if let Some(mid) = &msg.mid {
                                for r in &msg.reactions {
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

                    // Persist the edit to local DB (preserves old text).
                    let mut edit_applied = false;
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        if sid.is_some() {
                            // Channel edit — verify sender owns the message.
                            let sender = store.get_channel_message_sender(&mid);
                            if sender.as_deref() == Some(&peer_str) {
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
                    // SECURITY: Reject emoji strings longer than 10 characters.
                    if emoji.len() > 10 {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED AddReaction from {peer_str} — emoji too long ({} chars)", emoji.len());
                        return;
                    }
                    hollow_log!("[HOLLOW-REACTION] Received reaction {emoji} on {mid} from {peer_str}");

                    // DM (sid==None): the reactor is keyed by the sender's MASTER id so
                    // reactions from any of a friend's devices attribute to one person.
                    // Channel context keeps the raw device id (untouched).
                    let reactor_key = if sid.is_none() {
                        super::resolver::resolve(&peer_str)
                    } else {
                        peer_str.to_string()
                    };

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
                    let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref, .. } = *inner;
                    use crate::node::file_transfer;
                    hollow_log!("[HOLLOW-FILE] FileHeader received: {fid} ({name}, {size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());

                    // SECURITY: Validate file size against server limit (or default 34MB for DMs).
                    // Skip for share-backed files — Share handles delivery with no size limit.
                    if share_ref.is_none() {
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

                    let ctx_type = if sid.is_some() { "channel" } else { "dm" };
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

                    // Save file metadata to DB.
                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = store.insert_file_metadata(
                            &fid, &name, &ext, &mime,
                            size, chunks, img,
                            w, h,
                            mid.as_deref(), ctx_type, &ctx_id,
                            &peer_str, false, ts,
                            vthumb.as_ref(),
                        );
                    }

                    let mid_str = mid.unwrap_or_default();
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

                    // If aes_key is present and no share_ref, this is a streamed transfer — register for stream receive.
                    // Share-backed files skip this — Share handles delivery, no P2P binary data.
                    if !already_complete && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
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
                        if let Ok(incoming_ops) = serde_json::from_str::<Vec<crate::crdt::operations::CrdtOp>>(&ops_json) {
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
                Ok(MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen offer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen offer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "screen_offer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen answer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen answer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "screen_answer".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen ICE (Olm) from non-participant {peer_str} in {cid}");
                    } else {
                        let payload = serde_json::json!({
                            "candidate": candidate,
                            "sdpMid": sdp_mid,
                            "sdpMLineIndex": sdp_mline_index,
                            "role": role,
                        }).to_string();
                        let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
                            server_id: sid, channel_id: cid, peer_id: peer_str.to_string(),
                            signal_type: "screen_ice".to_string(), payload,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::VoiceChannelRenegOffer { sid, cid, sdp, .. }) => {
                    let vc_key = format!("{sid}:{cid}");
                    let is_participant = voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false);
                    if !is_participant {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg offer (Olm) from non-participant {peer_str} in {cid}");
                    } else if sdp.len() > 64 * 1024 {
                        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC reneg offer (Olm) — size {} exceeds limit from {peer_str}", sdp.len());
                    } else {
                        let payload = serde_json::json!({"sdp": sdp}).to_string();
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

                Err(_) => {
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
                        })
                        .await;
                }
            }

            // Ack.
            
        }

        // -- CRDT sync message handlers --

        HavenMessage::SyncRequest { server_id, state_vector_json } => {
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

            if let Ok(incoming_ops) = serde_json::from_str::<Vec<crate::crdt::operations::CrdtOp>>(&ops_json) {
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
                                        send_message_to_peer(ws_cmd_tx, ws_room_peers, &dev, HavenMessage::KeyRequest);
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
                                            },
                                        );
                                        hollow_log!("[HOLLOW-MLS] Sent bootstrap KeyPackage to join responder {peer_str} for {server_id}");
                                    }
                                }
                            }
                        }

                        if state.is_banned(&local_peer_str) {
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
                // Use op.author (the original creator) for role lookup, not the sender
                // (who may be relaying the op).
                {
                    let state = server_states.get(&server_id).unwrap();
                    let sender_role = state.get_role(&op.author);
                    let sender_perms = sender_role.default_permissions();
                    use crate::crdt::operations::{CrdtPayload, Permission, MemberRole};

                    let allowed = match &op.payload {
                        // Only admins+ can manage channels
                        CrdtPayload::ChannelAdded { .. }
                        | CrdtPayload::ChannelRemoved { .. }
                        | CrdtPayload::ChannelRenamed { .. }
                        | CrdtPayload::ChannelLayoutUpdated { .. } => {
                            (sender_perms & Permission::MANAGE_CHANNELS) != 0
                        }
                        // Only admins+ can change roles
                        CrdtPayload::RoleChanged { peer_id, role, .. } => {
                            state.can_change_role(&op.author, peer_id, role)
                        }
                        // Only admins+ can change server settings/rename
                        CrdtPayload::ServerRenamed { .. }
                        | CrdtPayload::ServerSettingChanged { .. } => {
                            sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        // Self-removal (voluntary leave) is always allowed;
                        // kicking someone ELSE needs moderator+ and outranking.
                        CrdtPayload::MemberRemoved { peer_id } => {
                            let target_role = state.get_role(peer_id);
                            peer_id == &op.author
                                || ((sender_perms & Permission::KICK_MEMBERS) != 0
                                    && sender_role.outranks(&target_role))
                        }
                        // Members can add other members (via invite), change own nickname,
                        // pin/unpin messages (if they have MANAGE_CHANNELS), create servers
                        CrdtPayload::MemberAdded { .. } => {
                            state.members.contains_key(&op.author)
                        }
                        CrdtPayload::NicknameChanged { peer_id, .. } => {
                            // Members can only change their own nickname
                            peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        CrdtPayload::MessagePinned { .. }
                        | CrdtPayload::MessageUnpinned { .. } => {
                            (sender_perms & Permission::MANAGE_CHANNELS) != 0
                        }
                        CrdtPayload::StoragePledgeChanged { peer_id, .. } => {
                            // Members can change own pledge, admins can change anyone's
                            peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        CrdtPayload::TwitchUsernameChanged { peer_id, .. } => {
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
                        | CrdtPayload::ChannelPostingChanged { .. }
                        | CrdtPayload::ChannelPublicChanged { .. } => {
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
                        hollow_log!("[HOLLOW-SECURITY] REJECTED CrdtOpBroadcast from {peer_str} — insufficient permission for {:?} (role: {:?})", op.payload, sender_role);
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

                    // Forward to other connected server members (simple gossip).
                    // Members are master-keyed → fan to each member's devices; skip
                    // our own identity and the exact device that sent this to us.
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

                    // Emit specific events based on op payload so Dart UI updates correctly.
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
                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
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
                            // Broadcast to room (including guests) so public channel browsers see the change
                            if let Some(ch) = state.channels.get(channel_id) {
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
                }
            }
        }

        HavenMessage::ServerJoinRequest { server_id, twitch_proof_json } => {
            hollow_log!("[HOLLOW-CRDT] ServerJoinRequest from {peer_str} for server {server_id}");

            if let Some(state) = server_states.get_mut(&server_id) {
                // Ban check: reject banned peers before any other verification.
                if state.is_banned(peer_str) {
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
                if let Some(twitch_settings) = twitch::TwitchServerSettings::from_server_state(state) {
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
                }

                // Owner-online verification: if enabled, only the owner accepts joins.
                if let Some(ref twitch_settings) = twitch::TwitchServerSettings::from_server_state(state) {
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
                }

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
                    // they short-circuit above). Mirrors the Twitch gate.
                    if state.is_private() {
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
                        peer_str, HavenMessage::KeyRequest,
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

            if server_states.remove(&server_id).is_some() {
                // Remove from DB.
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

        HavenMessage::MemberKickBroadcast { server_id } => {
            hollow_log!("[HOLLOW-CRDT] MemberKickBroadcast from {peer_str} — kicked from server {server_id}");
            

            // SECURITY: Verify sender has KICK_MEMBERS permission and outranks us.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                let sender_perms = sender_role.default_permissions();
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
                // Use per-sender sync if available, fall back to legacy single-timestamp.
                let messages_result = if !sender_timestamps.is_empty() {
                    store.get_channel_messages_since_per_sender(
                        &server_id, &channel_id, &sender_timestamps, 200,
                    )
                } else {
                    store.get_channel_messages_since(
                        &server_id, &channel_id, since_timestamp, 200,
                    )
                };
                    if let Ok(messages) = messages_result {
                        hollow_log!("[HOLLOW-SYNC] Sending {} sync messages for {channel_id}", messages.len());
                        // Load reactions for all messages in the batch.
                        let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
                        let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
                        let file_ids: Vec<&str> = messages.iter().filter_map(|m| m.file_id.as_deref()).collect();
                        let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

                        let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
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

                        let total = if !sender_timestamps.is_empty() {
                            store.count_channel_messages_since_per_sender(
                                &server_id, &channel_id, &sender_timestamps,
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
                        let items = build_dm_sync_items(&store, &messages);

                        if !items.is_empty() {
                            let has_more = if items.len() >= 200 {
                                Some(true)
                            } else {
                                None
                            };
                            let envelope = MessageEnvelope::DmSyncBatch {
                                messages: items,
                                has_more,
                            };
                            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                            send_encrypted_message(
                                olm, crypto_store,
                                peer_str, &envelope_json, event_tx,
                                ws_cmd_tx, ws_room_peers,
                            ).await;
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
                    let has_more = if messages.len() >= 200 { Some(true) } else { None };
                    let items = build_dm_sync_items(&store, &messages);
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
                    send_encrypted_message(
                        olm, crypto_store,
                        peer_str, &envelope_json, event_tx,
                        ws_cmd_tx, ws_room_peers,
                    ).await;
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

        // -- MLS message handlers --

        HavenMessage::MlsChannelMessage { server_id, body } => {
            hollow_log!("[HOLLOW-TOPIC] RECV MlsChannelMessage from {peer_str} for {server_id} ({} b64 bytes)", body.len());


            if let Some(mls_mgr) = mls {
                if !mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Received MlsChannelMessage for unknown group {server_id}");

                    // If we're a member of this server but don't have the MLS group,
                    // the Welcome was lost. Send KeyPackage to the coordinator
                    // (lowest online peer) for MLS bootstrap.
                    // Only do this once per server to avoid spamming (expires after 60s).
                    if !mls_bootstrap_requested.get(&server_id).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                        if let Some(state) = server_states.get(&server_id) {
                            // Coordinator = lowest online MASTER (excluding us). Send
                            // our KeyPackage to one of that master's online DEVICES
                            // (the master itself has no socket).
                            let members: Vec<String> = state.members.keys().cloned().collect();
                            let coordinator = elect_coordinator(&members, &local_peer_str, ws_room_peers)
                                .filter(|c| c != &local_peer_str);
                            if let Some(coordinator) = coordinator {
                                if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                    let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                        server_id: server_id.clone(),
                                        key_package: kp_b64,
                                    }).unwrap_or_default();
                                    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
                                    if sent > 0 {
                                        hollow_log!("[HOLLOW-MLS] Sent KeyPackage to coordinator {coordinator} ({sent} device(s)) for MLS bootstrap (triggered by message)");
                                        mls_bootstrap_requested.insert(server_id.clone(), std::time::Instant::now());
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

                match mls_mgr.decrypt(&server_id, &ciphertext) {
                    Ok((plaintext, sender_peer_id)) => {
                        *mls_dirty = true;
                        mls_decrypt_failures.remove(&server_id); // Reset failure counter on success.
                        hollow_log!("[HOLLOW-TOPIC] DECRYPT ok for {server_id}, sender(leaf)={sender_peer_id}");

                        // Parse the plaintext as a MessageEnvelope.
                        let envelope_str = String::from_utf8_lossy(&plaintext);
                        let envelope = match serde_json::from_str::<MessageEnvelope>(&envelope_str) {
                            Ok(env) => env,
                            Err(_) => {
                                hollow_log!("[HOLLOW-MLS] Failed to parse decrypted envelope");
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
                                let ChannelMessagePayload { sid, cid, text, ts, sig, pk, mid, reply_to, file_id, link_preview } = *inner;
                                message_ops::handle_envelope_channel_message(
                                    event_tx, bundle_keypair, &local_peer,
                                    sender_master.clone(), sid, cid, text, ts,
                                    sig, pk, mid, reply_to, file_id, link_preview,
                                    db_path, db_passphrase,
                                ).await;
                            }
                            MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid, cid } => {
                                message_ops::handle_envelope_edit_message(
                                    event_tx, bundle_keypair, &sender_master,
                                    mid, new_text, ts, sig, pk, sid, cid,
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
                                message_ops::handle_envelope_add_reaction(
                                    event_tx, bundle_keypair, &sender_master,
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
                                let FileHeaderPayload { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref, .. } = *inner;
                                file_handler::handle_envelope_file_header(
                                    server_states, pending_file_streams, pending_shard_streams,
                                    early_file_streams, bundle_keypair, event_tx,
                                    &server_id, sender_peer_id,
                                    fid, name, ext, mime, size, chunks, img, w, h,
                                    mid, sid, cid, ts, aes_key, aes_nonce, vthumb, share_ref,
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
                                sync_handler::handle_envelope_crdt_op(
                                    server_states, bundle_keypair, event_tx,
                                    sid, op_json,
                                    crdt_store,
                                    ws_cmd_tx,
                                ).await;
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

                            MessageEnvelope::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list } => {
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
                                    device_list, db_path, db_passphrase,
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
                            | MessageEnvelope::VoiceChannelRenegOffer { .. }
                            | MessageEnvelope::VoiceChannelRenegAnswer { .. }
                            | MessageEnvelope::VoiceChannelCameraState { .. }
                            if !voice_handler::vc_rate_check(vc_signal_rate_tokens, &sender_peer_id) => {
                                // Rate limited — drop silently (already logged).
                            }

                            MessageEnvelope::VoiceChannelJoin { sid, cid } => {
                                voice_handler::handle_envelope_voice_channel_join(
                                    server_states, voice_channel_participants,
                                    voice_channel_gossip_mode, gossip_overlays,
                                    event_tx, local_peer_str, sender_peer_id, sid, cid,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelLeave { sid, cid } => {
                                voice_handler::handle_envelope_voice_channel_leave(
                                    voice_channel_participants, voice_channel_gossip_mode,
                                    gossip_overlays, event_tx, local_peer_str,
                                    sender_peer_id, sid, cid,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelSdpOffer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_sdp_offer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelSdpAnswer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_sdp_answer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelIce { sid, cid, candidate, sdp_mid, sdp_mline_index, .. } => {
                                voice_handler::handle_envelope_voice_channel_ice(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, candidate, sdp_mid, sdp_mline_index,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelAudioState { sid, cid, muted, deafened, .. } => {
                                voice_handler::handle_envelope_voice_channel_audio_state(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, muted, deafened,
                                ).await;
                            }

                            // -- Voice channel screen sharing (Phase 5B) --
                            MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_offer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_answer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_ice(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, candidate, sdp_mid, sdp_mline_index, role,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelScreenState { sid, cid, enabled, quality, .. } => {
                                voice_handler::handle_envelope_voice_channel_screen_state(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, enabled, quality,
                                ).await;
                            }

                            // -- Voice channel camera (Phase 5B) --
                            MessageEnvelope::VoiceChannelRenegOffer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_reneg_offer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelRenegAnswer { sid, cid, sdp, .. } => {
                                voice_handler::handle_envelope_voice_channel_reneg_answer(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, sdp,
                                ).await;
                            }
                            MessageEnvelope::VoiceChannelCameraState { sid, cid, enabled, .. } => {
                                voice_handler::handle_envelope_voice_channel_camera_state(
                                    voice_channel_participants, event_tx,
                                    sender_peer_id, sid, cid, enabled,
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
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Decrypt failed for {server_id}: {e}");

                        // Immediately request sync from the sender for
                        // subscribed channels only.  The dropped message
                        // came via topic routing so it belongs to one of our
                        // subscribed channels.  Syncing just those (instead
                        // of all channels) avoids pulling history the user
                        // hasn't opened.  5s dedup prevents flood.
                        {
                            let dedup_key = format!("mls_fail_sync:{server_id}:{peer_str}");
                            if !channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
                                channel_sync_sent.insert(dedup_key, std::time::Instant::now());
                                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                    let subscribed: Vec<String> = subscribed_channels
                                        .get(&server_id)
                                        .cloned()
                                        .unwrap_or_default();
                                    for cid in &subscribed {
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
                                    hollow_log!("[HOLLOW-MLS] Requested immediate sync from {peer_str} for {} subscribed channels in {server_id}", subscribed.len());
                                }
                            }
                        }

                        // Track consecutive failures — trigger recovery after 3.
                        let count = mls_decrypt_failures.entry(server_id.clone()).or_insert(0);
                        *count += 1;

                        if *count >= 3 && !mls_bootstrap_requested.get(&server_id).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                            hollow_log!("[HOLLOW-MLS] {} consecutive decrypt failures — initiating MLS recovery for {server_id}", count);
                            *count = 0;

                            // Drop broken group and request re-bootstrap from coordinator.
                            mls_mgr.remove_group(&server_id);
                            persist_mls_state(mls_mgr, crypto_store);

                            if let Some(state) = server_states.get(&server_id) {
                                let local_peer = local_peer_str.to_string();
                                // Only attempt recovery if we're still a member (skip if banned/removed).
                                // Members are master-keyed; our master is the key.
                                if !state.members.contains_key(&local_peer) {
                                    hollow_log!("[HOLLOW-MLS] Skipping recovery for {server_id} — no longer a member");
                                } else {
                                    // Coordinator = lowest online MASTER (excluding us);
                                    // send to one of its online DEVICES.
                                    let members: Vec<String> = state.members.keys().cloned().collect();
                                    let coordinator = elect_coordinator(&members, &local_peer, ws_room_peers)
                                        .filter(|c| c != &local_peer);
                                    if let Some(coordinator) = coordinator {
                                        if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                            let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                            let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                                server_id: server_id.clone(),
                                                key_package: kp_b64,
                                            }).unwrap_or_default();
                                            let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
                                            mls_bootstrap_requested.insert(server_id.clone(), std::time::Instant::now());
                                            hollow_log!("[HOLLOW-MLS] Sent recovery KeyPackage to coordinator {coordinator} ({sent} device(s)) for {server_id}");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackage { server_id, key_package } => {
            hollow_log!("[HOLLOW-MLS] MlsKeyPackage from {peer_str} for server {server_id}");

            // L6: Reject KeyPackage from non-members (prevents unauthorized MLS group joins).
            // Multi-device (Step 6): members are keyed by MASTER; the sender is a
            // DEVICE. Accept if the sending device's IDENTITY is a member — this is
            // what lets a SIBLING of an existing member get its own leaf added
            // without first being its own CRDT member. Unknown device → resolves to
            // itself → falls back to plain membership (single-device unchanged).
            if let Some(state) = server_states.get(&server_id) {
                let is_member = state.members.keys()
                    .any(|k| super::resolver::same_identity(peer_str, k));
                if !is_member {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MlsKeyPackage from non-member {peer_str} for {server_id}");
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-MLS] No server state for {server_id}, skipping KeyPackage");
                return;
            }

            // Distributed committer: lowest online MLS member (by MASTER identity)
            // processes KeyPackages. The sender's IDENTITY is excluded from the
            // election — they sent the KeyPackage because they (or a sibling) lost
            // their group, so neither the sending device nor its siblings can be
            // the coordinator that processes it.
            if let Some(mls_mgr) = mls.as_ref() {
                if mls_mgr.has_group(&server_id) {
                    let members: Vec<String> = mls_mgr.group_members(&server_id)
                        .into_iter()
                        .filter(|p| !super::resolver::same_identity(p, peer_str))
                        .collect();
                    let coordinator = elect_coordinator(&members, local_peer_str, &ws_room_peers);
                    if coordinator.as_deref() != Some(local_peer_str) {
                        hollow_log!("[HOLLOW-MLS] Not MLS coordinator for {server_id} (excluding sender identity), skipping KeyPackage");
                        return;
                    }
                } else {
                    // No MLS group yet — only the owner can create it.
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
            }

            if let Some(mls_mgr) = mls {
                // Create MLS group lazily if it doesn't exist (migration for pre-MLS servers).
                if !mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Lazily creating MLS group for existing server {server_id}");
                    if let Err(e) = mls_mgr.create_group(&server_id) {
                        hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}");
                        return;
                    }
                }

                // Step 1: Queue stale MLS members (whose IDENTITY isn't in the CRDT)
                // for batch removal. Multi-device (Step 6): MLS leaves are device
                // ids, CRDT members are masters — a leaf is stale iff NO CRDT member
                // shares its identity. Never sweep our own device's leaf
                // (same_identity to our master).
                if let Some(state) = server_states.get(&server_id) {
                    let mls_members = mls_mgr.group_members(&server_id);
                    for stale_peer in &mls_members {
                        if super::resolver::same_identity(stale_peer, local_peer_str) { continue; }
                        let has_member = state.members.keys()
                            .any(|k| super::resolver::same_identity(stale_peer, k));
                        if !has_member {
                            hollow_log!("[HOLLOW-MLS] Queuing stale MLS member {stale_peer} for batch removal from {server_id}");
                            pending_mls_removals.entry(server_id.clone()).or_default().push(stale_peer.clone());
                        }
                    }
                }

                // Step 2: If the SENDING DEVICE already has a leaf, queue THAT exact
                // leaf for batch removal + re-add (recovery). Match the exact device
                // id — never a sibling's live leaf (siblings have distinct ids).
                if mls_mgr.group_members(&server_id).contains(&peer_str.to_string()) {
                    hollow_log!("[HOLLOW-MLS] Device {peer_str} already in MLS group for {server_id} — queuing for batch removal + re-add");
                    pending_mls_removals.entry(server_id.clone()).or_default().push(peer_str.to_string());
                }

                let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(&key_package) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode KeyPackage failed: {e}"); return; }
                };

                // Queue KeyPackage for batch processing (single epoch advance per batch).
                pending_mls_key_packages
                    .entry(server_id.clone())
                    .or_default()
                    .push((peer_str.to_string(), kp_bytes));
                hollow_log!("[HOLLOW-MLS] Queued KeyPackage from {peer_str} for batch add to {server_id}");
            }
        }

        HavenMessage::MlsWelcome { server_id, welcome } => {
            hollow_log!("[HOLLOW-MLS] MlsWelcome from {peer_str} for server {server_id}");
            

            if let Some(mls_mgr) = mls {
                let welcome_bytes = match base64::engine::general_purpose::STANDARD.decode(&welcome) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode Welcome failed: {e}"); return; }
                };

                // If group already exists locally (stale from failed recovery), remove it first.
                if mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Removing stale local group for {server_id} before Welcome");
                    mls_mgr.remove_group(&server_id);
                }

                match mls_mgr.join_from_welcome(&server_id, &welcome_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, crypto_store);
                        mls_bootstrap_requested.remove(&server_id);
                        mls_decrypt_failures.remove(&server_id);
                        hollow_log!("[HOLLOW-MLS] Joined MLS group for server {server_id}");

                        // After MLS recovery, sync ALL channels — not just empty ones.
                        // Messages that arrived during the stale epoch were silently
                        // dropped (decrypt failed), so the DB has gaps even when
                        // our_latest != 0.  Use per-sender timestamps so the
                        // responder only sends what we're actually missing.
                        if let Some(state) = server_states.get(&server_id) {
                            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                for cid in state.channels.keys() {
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
                        hollow_log!("[HOLLOW-MLS] Failed to join from Welcome for {server_id}: {e}");
                        // Clear bootstrap flag so next MlsChannelMessage can trigger retry.
                        mls_bootstrap_requested.remove(&server_id);
                    }
                }
            }
        }

        HavenMessage::MlsCommit { server_id, commit } => {
            hollow_log!("[HOLLOW-MLS] MlsCommit from {peer_str} for server {server_id}");
            

            if let Some(mls_mgr) = mls {
                let commit_bytes = match base64::engine::general_purpose::STANDARD.decode(&commit) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode Commit failed: {e}"); return; }
                };

                match mls_mgr.process_commit(&server_id, &commit_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, crypto_store);
                        hollow_log!("[HOLLOW-MLS] Processed commit for server {server_id}");
                        // Emit epoch change for SFrame key rotation.
                        if let Ok(sframe_key) = mls_mgr.export_secret(&server_id, "sframe", b"", 32) {
                            let epoch = mls_mgr.epoch(&server_id).unwrap_or(0);
                            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                server_id: server_id.clone(), epoch, sframe_key,
                            }).await;
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Failed to process commit for {server_id}: {e}");

                        // Commit processing failed — MLS group state is stale.
                        // Drop group and request re-bootstrap from owner.
                        if !mls_bootstrap_requested.get(&server_id).is_some_and(|t| t.elapsed() < MLS_BOOTSTRAP_TIMEOUT) {
                            hollow_log!("[HOLLOW-MLS] Dropping stale MLS group and requesting re-bootstrap for {server_id}");
                            mls_mgr.remove_group(&server_id);
                            persist_mls_state(mls_mgr, crypto_store);

                            if let Some(state) = server_states.get(&server_id) {
                                let local_peer = local_peer_str.to_string();
                                for member in state.members_list() {
                                    if member.peer_id == local_peer { continue; }
                                    let is_owner = state.roles.get(&member.peer_id)
                                        .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                        .unwrap_or(false);
                                    if is_owner {
                                            // member.peer_id is the owner's MASTER — fan
                                            // the KeyPackage to its online device(s).
                                            if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                                                    server_id: server_id.clone(),
                                                    key_package: kp_b64,
                                                }).unwrap_or_default();
                                                let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &member.peer_id, data);
                                                if sent > 0 {
                                                    mls_bootstrap_requested.insert(server_id.clone(), std::time::Instant::now());
                                                    hollow_log!("[HOLLOW-MLS] Sent re-bootstrap KeyPackage to owner {} ({sent} device(s)) for {server_id}", member.peer_id);
                                                }
                                            }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackageRequest { server_id } => {
            hollow_log!("[HOLLOW-MLS] MlsKeyPackageRequest from {peer_str} for server {server_id}");
            

            // Respond with our KeyPackage if we have an MLS identity.
            // Skip if we already have the MLS group (reconnecting peer, not a new joiner).
            if let Some(mls_mgr) = mls {
                if mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Already in MLS group for {server_id}, ignoring KeyPackageRequest");
                    return;
                }
                match mls_mgr.generate_key_package() {
                    Ok(kp_bytes) => {
                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            peer_str, HavenMessage::MlsKeyPackage {
                                server_id,
                                key_package: kp_b64,
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

            hollow_log!("[HOLLOW-FRIENDS] Friend request from {peer_str}");

            // Save as pending incoming.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.save_friend(&peer_str, "pending", "incoming", requested_at);
                }
            }

            // Register DM room code so we can rediscover this peer.
            let local_peer = local_peer_str.to_string();
            let room = dm_room_code(&local_peer, &peer_str);
            let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                room_code: room.clone(),
            }).await;
            let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                room_code: room,
            }).await;

            let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendAccept => {
            
            hollow_log!("[HOLLOW-FRIENDS] Friend accepted by {peer_str}");

            // Update our outgoing request to accepted.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let _ = store.save_friend(&peer_str, "accepted", "", now);
                }
            }

            // Register DM room code with signaling for internet discovery.
            let local_peer = local_peer_str.to_string();
            let room = dm_room_code(&local_peer, &peer_str);
            let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                room_code: room.clone(),
            }).await;
            let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                room_code: room,
            }).await;

            let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendReject => {
            
            hollow_log!("[HOLLOW-FRIENDS] Friend rejected by {peer_str}");

            // Remove our outgoing request.
            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.remove_friend(&peer_str);
                }
            }

            let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
                peer_id: peer_str.to_string(),
            }).await;
        }

        HavenMessage::FriendRemove => {
            
            hollow_log!("[HOLLOW-FRIENDS] Friend removed by {peer_str}");

            {
                if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                    let _ = store.remove_friend(&peer_str);
                }
            }

            let _ = event_tx.send(NetworkEvent::FriendRemoved {
                peer_id: peer_str.to_string(),
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
                    if existing.contains(&entry.peer_id) {
                        continue;
                    }
                    // v1 shares only accepted friends; persist as accepted.
                    if store
                        .save_friend(&entry.peer_id, "accepted", "", entry.requested_at)
                        .is_ok()
                    {
                        inserted += 1;
                    }
                    // Join the friend's DM room so presence flows both ways and
                    // future live messages arrive (history backfill is Step 4/5).
                    let room = dm_room_code(local_peer_str, &entry.peer_id);
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
                        let (display_name, status, about_me, updated_at, avatar_b64, banner_b64, twitch_username) =
                            match profile {
                                Some(p) => (
                                    p.display_name, p.status, p.about_me, p.updated_at,
                                    p.avatar_bytes.as_ref()
                                        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                                        .unwrap_or_default(),
                                    p.banner_bytes.as_ref()
                                        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                                        .unwrap_or_default(),
                                    p.twitch_username,
                                ),
                                None => (String::new(), String::new(), String::new(), 0, String::new(), String::new(), String::new()),
                            };
                        let device_list = super::crypto_handler::build_local_device_list(
                            master_keypair, device_peer_id, db_path, db_passphrase,
                        );
                        let dev_count = device_list.as_ref().map(|d| d.devices.len()).unwrap_or(0);
                        let msg = HavenMessage::ProfileUpdate {
                            display_name, status, about_me, updated_at,
                            avatar_b64, banner_b64, is_invisible, twitch_username,
                            device_list,
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

        HavenMessage::PublicChannelMessage { server_id, channel_id, text, ts, sig, pk, mid, reply_to, file_id, link_preview } => {
            if peer_str == local_peer_str { return; }
            message_ops::handle_envelope_channel_message(
                &event_tx, &bundle_keypair, &local_peer_str,
                peer_str.to_string(),
                server_id, channel_id, text, ts, sig, pk,
                Some(mid), reply_to, file_id, link_preview,
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelEdit { server_id, channel_id, mid, text, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            message_ops::handle_envelope_edit_message(
                &event_tx, &bundle_keypair, peer_str,
                mid, text, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelDelete { server_id, channel_id, mid, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            message_ops::handle_envelope_delete_message(
                &event_tx, &bundle_keypair, peer_str,
                mid, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelAddReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            message_ops::handle_envelope_add_reaction(
                &event_tx, &bundle_keypair, peer_str,
                mid, emoji, ts, sig, pk,
                Some(server_id), Some(channel_id),
                &db_path, &db_passphrase,
            ).await;
        }

        HavenMessage::PublicChannelRemoveReaction { server_id, channel_id, mid, emoji, ts, sig, pk } => {
            if peer_str == local_peer_str { return; }
            message_ops::handle_envelope_remove_reaction(
                &event_tx, &bundle_keypair, peer_str,
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
                    .filter(|ch| ch.is_public && ch.channel_type == crate::crdt::server_state::ChannelType::Text)
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
                    let resp = HavenMessage::PublicChannelListResponse {
                        server_id: server_id.clone(),
                        server_name: state.name().to_string(),
                        channels,
                        server_avatar_b64: avatar_b64,
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
                        let has_more = msgs.len() as i32 >= limit;
                        let msg_ids: Vec<String> = msgs.iter().filter_map(|m| m.message_id.clone()).collect();
                        let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
                        let file_ids: Vec<&str> = msgs.iter().filter_map(|m| m.file_id.as_deref()).collect();
                        let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

                        let items: Vec<SyncMessageItem> = msgs.iter().map(|m| {
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

        HavenMessage::PublicChannelListResponse { server_id, server_name, channels, server_avatar_b64 } => {
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
            let _ = event_tx.send(NetworkEvent::PublicChannelListReceived {
                server_id, server_name, channels: entries, server_avatar,
            }).await;
        }

        HavenMessage::PublicChannelSyncResponse { server_id, channel_id, messages, has_more, sender_profiles } => {
            if peer_str == local_peer_str { return; }
            if !guest_rooms.contains(&server_id) { return; }
            let ffi_messages: Vec<GuestSyncMessageFfi> = messages.into_iter()
                .map(|m| GuestSyncMessageFfi {
                    sender_id: m.s,
                    text: m.t,
                    timestamp: m.ts,
                    message_id: m.mid,
                    signature: m.sig,
                    public_key: m.pk,
                    edited_at: m.edited_at,
                    reply_to: m.reply_to,
                    hidden_at: m.hidden_at,
                    reactions: m.reactions.into_iter().map(|r| GuestReactionFfi {
                        emoji: r.e, peer_id: r.p, added_at: r.ts,
                    }).collect(),
                })
                .collect();
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

        HavenMessage::ChannelNotificationHint { server_id, channel_id, message_id, has_everyone, mentioned_names, is_reply } => {
            let _ = event_tx.send(NetworkEvent::ChannelNotificationHint {
                server_id, channel_id, from_peer: peer_str.to_string(),
                message_id, has_everyone, mentioned_names, is_reply,
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

        HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible: peer_invisible, twitch_username, device_list } => {
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
            let (profile_master, _saved) = social::save_incoming_profile(
                &peer_str, &display_name, &status, &about_me, updated_at,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
                db_path, db_passphrase,
            );

            // Update display_name in server member lists (local-only, not a CRDT
            // op). Members are master-keyed (multi-device); update under the master.
            for (_, state) in server_states.iter_mut() {
                if !display_name.is_empty() {
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
                                                inline_bytes: None,
                                            }),
                                        };
                                        // Send FileHeader via Olm (targeted) + SendDirect.
                                            let header_json = serde_json::to_string(&header).unwrap_or_default();
                                            send_encrypted_message(
                                                olm, crypto_store,
                                                &peer_str, &header_json, event_tx,
                                                ws_cmd_tx, ws_room_peers,
                                            ).await;

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

        // -- Voice call signaling (Phase 5B) --
        HavenMessage::CallInvite { call_id, video, sframe_key } => {
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
            social::send_own_profile_to_peer(
                ws_cmd_tx, ws_room_peers,
                local_peer_str, master_keypair, device_peer_id, peer_str,
                is_invisible,
                db_path, db_passphrase,
            );
        }

        HavenMessage::ProfileRequestFor { target_peer_id } => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRequestFor {target_peer_id} from {peer_str}");
            social::handle_profile_request_for(
                ws_cmd_tx, ws_room_peers,
                peer_str, &target_peer_id,
                db_path, db_passphrase,
            );
        }

        HavenMessage::ProfileRelay { source_peer_id, display_name, status, about_me, updated_at, avatar_b64, twitch_username } => {
            hollow_log!("[HOLLOW-PROFILE] ProfileRelay for {source_peer_id} from {peer_str}");
            social::handle_profile_relay(
                event_tx, server_states,
                source_peer_id, display_name, status, about_me, updated_at,
                avatar_b64, twitch_username,
                db_path, db_passphrase,
            ).await;
        }

        // -- Plaintext voice channel handlers (MLS epoch-resilient) --
        // These arrive as plaintext HavenMessage instead of MLS MessageEnvelope
        // to survive epoch staleness after reconnection.

        HavenMessage::VoiceChannelJoin { server_id, channel_id } => {
            if peer_str == local_peer_str { return; }
            let is_member = server_states.get(&server_id)
                .map(|s| s.is_member(peer_str))
                .unwrap_or(false);
            let is_voice_channel = server_states.get(&server_id)
                .and_then(|s| s.channels.get(&channel_id))
                .map(|ch| ch.channel_type == crate::crdt::server_state::ChannelType::Voice)
                .unwrap_or(false);
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
                    peer_id: peer_str.to_string(),
                }).await;
                voice_handler::check_voice_mode_transition(
                    &vc_key, &server_id, &channel_id,
                    &voice_channel_participants, voice_channel_gossip_mode,
                    &gossip_overlays, local_peer_str, &event_tx,
                ).await;
            }
        }

        HavenMessage::VoiceChannelLeave { server_id, channel_id } => {
            if peer_str == local_peer_str { return; }
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
                peer_id: peer_str.to_string(),
            }).await;
            voice_handler::check_voice_mode_transition(
                &vc_key, &server_id, &channel_id,
                &voice_channel_participants, voice_channel_gossip_mode,
                &gossip_overlays, local_peer_str, &event_tx,
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

        _ => {}
    }
}

// flush_pending_sync_requests moved to sync_handler.rs

