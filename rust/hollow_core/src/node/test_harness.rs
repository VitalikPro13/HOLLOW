//! Headless multi-node integration test harness (Step 9B-i).
//!
//! Spins up several real `spawn_node` event loops IN ONE PROCESS, each with its
//! own in-memory keypairs and its own temp SQLCipher DBs, all wired through an
//! in-process [`MockRelay`] that mimics the production relay's load-bearing
//! behavior (room routing + offline buffering — the relay is a dumb pipe; all
//! crypto/sync/ordering logic lives in the nodes). No sockets, no TLS, no
//! network. This lets us drive a true multi-device scenario and assert on each
//! node's real DB / events — the automated version of the manual Pixel↔VM↔AL
//! live test.
//!
//! See `reports/MULTI_DEVICE_IMPLEMENTATION_TRACKER.md` §9B-i and the
//! `project_multinode_test_harness` memory for the design.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, OlmManager};
use crate::identity::native_identity::NativeKeypair;
use super::crdt_store::CrdtStore;
use super::types::{NetworkEvent, NodeCommand};
use super::ws_client::{WsCommand, WsEvent};

/// Process-wide guard: the resolver (and other `OnceLock`/global statics the
/// nodes touch) is process-global, so harness tests must run serially and start
/// from a clean resolver. Each test takes this guard via [`test_guard`].
static HARNESS_GUARD: Mutex<()> = Mutex::new(());

pub(crate) fn test_guard() -> std::sync::MutexGuard<'static, ()> {
    let g = HARNESS_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    super::resolver::clear_for_test();
    g
}

// ---------------------------------------------------------------------------
// MockRelay — in-process broker mimicking the production relay's routing.
// ---------------------------------------------------------------------------

/// What a node hands the broker so the broker can deliver events back to it.
struct Conn {
    event_tx: mpsc::UnboundedSender<WsEvent>,
    online: bool,
}

#[derive(Default)]
struct RelayInner {
    /// device_peer_id -> connection (event sink + online flag).
    conns: HashMap<String, Conn>,
    /// room_code -> set of device_peer_ids currently in the room.
    rooms: HashMap<String, HashSet<String>>,
    /// target device_peer_id -> buffered (room, frame-kind, from, data) for
    /// replay when the target next joins that room. Mirrors the relay's
    /// offline buffer (the load-bearing peer-fallback path).
    offline: HashMap<String, Vec<BufferedMsg>>,
}

struct BufferedMsg {
    room: String,
    from: String,
    data: Vec<u8>,
    /// true => deliver as DirectMessage on replay; false => Message (room bcast).
    direct: bool,
}

/// Shared handle to the in-process relay. Clone-able; all clones point at the
/// same inner state behind a mutex.
#[derive(Clone)]
pub(crate) struct MockRelay {
    inner: Arc<Mutex<RelayInner>>,
}

impl MockRelay {
    pub(crate) fn new() -> Self {
        Self { inner: Arc::new(Mutex::new(RelayInner::default())) }
    }

    /// Register a freshly-spawned node: take ownership of its outbound command
    /// stream (drive it on a background task) and remember its inbound event
    /// sink. Emits `Connected` to the node so it runs its connect flow
    /// (join inbox + friend DM rooms).
    fn register(
        &self,
        peer_id: String,
        mut cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
        event_tx: mpsc::UnboundedSender<WsEvent>,
    ) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.conns.insert(peer_id.clone(), Conn { event_tx: event_tx.clone(), online: true });
        }
        // Drive this node's outbound commands.
        let relay = self.clone();
        let pid = peer_id.clone();
        tokio::spawn(async move {
            while let Some(cmd) = cmd_rx.recv().await {
                relay.handle_command(&pid, cmd);
            }
        });
        // Tell the node it's connected (mirrors WsEvent::Connected on real auth).
        let _ = event_tx.send(WsEvent::Connected);
    }

    /// The set of DEVICE peer_ids the relay currently considers online (a live
    /// socket). This is the relay's authoritative presence view — the same thing
    /// the real relay reports via `RoomMembers`, which the UI's online dots
    /// ultimately derive from. Inspectors read presence from HERE (the relay),
    /// not from a node's internal state, because the relay is the source of truth.
    pub(crate) fn online_devices(&self) -> std::collections::HashSet<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .conns
            .iter()
            .filter(|(_, c)| c.online)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// DEVICE peer_ids currently present in `room` (online + joined). Mirrors the
    /// relay's per-room membership set. Raw-layer presence for future scenarios
    /// (e.g. asserting which of a member's devices are in a server room).
    #[allow(dead_code)]
    pub(crate) fn room_devices(&self, room: &str) -> std::collections::HashSet<String> {
        let inner = self.inner.lock().unwrap();
        inner.rooms.get(room).cloned().unwrap_or_default()
    }

    /// Mark a node offline (simulate a disconnect): stop delivering to it, drop
    /// it from every room (broadcasting PeerLeft), so peers see it leave. Its
    /// event loop keeps running but receives nothing until it comes back.
    fn set_online(&self, peer_id: &str, online: bool) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(conn) = inner.conns.get_mut(peer_id) {
            conn.online = online;
        }
        if !online {
            // Remove from all rooms + broadcast peer_left to remaining members.
            let rooms: Vec<String> = inner.rooms.keys().cloned().collect();
            for room in rooms {
                let was_present = inner
                    .rooms
                    .get_mut(&room)
                    .map(|s| s.remove(peer_id))
                    .unwrap_or(false);
                if was_present {
                    inner.broadcast_except(&room, peer_id, WsEvent::PeerLeft {
                        room: room.clone(),
                        peer_id: peer_id.to_string(),
                    });
                }
            }
            // Tell the offline node its OWN socket died. The real WS client emits
            // `WsEvent::Disconnected` when the TCP/TLS socket drops; the event loop
            // relies on that to clear sync-gating state (`synced_peers`,
            // `key_request_in_flight`, `key_bundle_sent_to`, …). Without it the
            // node keeps every peer marked already-synced, so on reconnect the
            // `is_new` guard suppresses the proactive DmSyncRequest/key exchange
            // and the reconnect flow silently does nothing.
            if let Some(conn) = inner.conns.get(peer_id) {
                let _ = conn.event_tx.send(WsEvent::Disconnected);
            }
        } else {
            // Coming back online: re-emit Connected so the node re-runs its
            // join flow (inbox + friend DM rooms) from scratch.
            if let Some(conn) = inner.conns.get(peer_id) {
                let _ = conn.event_tx.send(WsEvent::Connected);
            }
        }
    }

    fn handle_command(&self, from: &str, cmd: WsCommand) {
        let mut inner = self.inner.lock().unwrap();
        // Drop everything from an offline node (mirrors a dead socket).
        if !inner.conns.get(from).map(|c| c.online).unwrap_or(false) {
            return;
        }
        match cmd {
            WsCommand::JoinRoom { room_code } => {
                // Existing members (snapshot) BEFORE adding the joiner.
                let existing: Vec<String> = inner
                    .rooms
                    .get(&room_code)
                    .map(|s| s.iter().cloned().collect())
                    .unwrap_or_default();
                inner.rooms.entry(room_code.clone()).or_default().insert(from.to_string());

                // members snapshot to the joiner (includes self, like the relay).
                let mut members = existing.clone();
                members.push(from.to_string());
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::RoomMembers {
                        room: room_code.clone(),
                        peers: members,
                    });
                }
                // peer_joined to existing members.
                for m in &existing {
                    if let Some(conn) = inner.conns.get(m) {
                        let _ = conn.event_tx.send(WsEvent::PeerJoined {
                            room: room_code.clone(),
                            peer_id: from.to_string(),
                        });
                    }
                }
                // Replay this peer's buffered offline messages for this room.
                inner.replay_offline(from, &room_code);
            }
            WsCommand::LeaveRoom { room_code } => {
                let was = inner
                    .rooms
                    .get_mut(&room_code)
                    .map(|s| s.remove(from))
                    .unwrap_or(false);
                if was {
                    inner.broadcast_except(&room_code, from, WsEvent::PeerLeft {
                        room: room_code.clone(),
                        peer_id: from.to_string(),
                    });
                }
            }
            WsCommand::SendToRoom { room_code, data } => {
                inner.broadcast_except(&room_code, from, WsEvent::Message {
                    room: room_code.clone(),
                    from: from.to_string(),
                    data,
                });
            }
            WsCommand::SendDirect { room_code, target_peer, data }
            | WsCommand::SendDirectImage { room_code, target_peer, data } => {
                inner.deliver_direct(&room_code, from, &target_peer, data, true);
            }
            WsCommand::SendBinaryDirect { room_code, target_peer, data } => {
                // Delivered as BinaryDirect when present; not buffered (matches
                // the file/shard streaming path — irrelevant to current tests).
                let in_room = inner.peer_in_room(&room_code, &target_peer);
                if let Some(conn) = inner.conns.get(&target_peer).filter(|c| c.online && in_room) {
                    let _ = conn.event_tx.send(WsEvent::BinaryDirect {
                        room: room_code,
                        from: from.to_string(),
                        data,
                    });
                }
            }
            WsCommand::SendToRoomTopic { room_code, data, .. } => {
                // Simplify topic routing to a plain room broadcast (no test
                // exercises topic filtering yet).
                inner.broadcast_except(&room_code, from, WsEvent::Message {
                    room: room_code.clone(),
                    from: from.to_string(),
                    data,
                });
            }
            WsCommand::DiscoverPeers { room_code } => {
                let peers: Vec<String> = inner
                    .rooms
                    .get(&room_code)
                    .map(|s| s.iter().filter(|p| *p != from).cloned().collect())
                    .unwrap_or_default();
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::DiscoveredPeers { room: room_code, peers });
                }
            }
            WsCommand::CheckPeers { peers, rooms } => {
                let online: Vec<String> = peers
                    .into_iter()
                    .filter(|p| inner.conns.get(p).map(|c| c.online).unwrap_or(false))
                    .collect();
                let active_rooms: Vec<String> = rooms
                    .into_iter()
                    .filter(|r| inner.rooms.get(r).map(|s| !s.is_empty()).unwrap_or(false))
                    .collect();
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::PeerStatus { online, active_rooms });
                }
            }
            // Channel-direct offline push, nickname/linkcode/push registries:
            // not needed for the current tests — no-op (add when a test does).
            _ => {}
        }
    }
}

impl RelayInner {
    fn peer_in_room(&self, room: &str, peer: &str) -> bool {
        self.rooms.get(room).map(|s| s.contains(peer)).unwrap_or(false)
    }

    fn broadcast_except(&self, room: &str, from: &str, event: WsEvent) {
        let members: Vec<String> = self
            .rooms
            .get(room)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default();
        for m in members {
            if m == from {
                continue; // no self-echo (matches relay)
            }
            if let Some(conn) = self.conns.get(&m).filter(|c| c.online) {
                let _ = conn.event_tx.send(event.clone());
            }
        }
    }

    fn deliver_direct(&mut self, room: &str, from: &str, target: &str, data: Vec<u8>, direct: bool) {
        let online = self.conns.get(target).map(|c| c.online).unwrap_or(false);
        if online && self.peer_in_room(room, target) {
            if let Some(conn) = self.conns.get(target) {
                let _ = conn.event_tx.send(WsEvent::DirectMessage {
                    room: room.to_string(),
                    from: from.to_string(),
                    data,
                });
            }
        } else {
            // Target offline (or connected but not in the room): buffer for
            // replay on the target's next join of this room. This is the
            // load-bearing peer-fallback path.
            self.offline.entry(target.to_string()).or_default().push(BufferedMsg {
                room: room.to_string(),
                from: from.to_string(),
                data,
                direct,
            });
        }
    }

    fn replay_offline(&mut self, peer: &str, room: &str) {
        let Some(buf) = self.offline.get_mut(peer) else { return };
        let (replay, keep): (Vec<_>, Vec<_>) = std::mem::take(buf).into_iter().partition(|m| m.room == room);
        *buf = keep;
        let Some(conn) = self.conns.get(peer) else { return };
        if !conn.online {
            return;
        }
        for m in replay {
            let ev = if m.direct {
                WsEvent::DirectMessage { room: m.room, from: m.from, data: m.data }
            } else {
                WsEvent::Message { room: m.room, from: m.from, data: m.data }
            };
            let _ = conn.event_tx.send(ev);
        }
    }
}

// ---------------------------------------------------------------------------
// TestNode — one running node + handles to drive/observe it.
// ---------------------------------------------------------------------------

pub(crate) struct TestNode {
    /// MASTER identity peer_id (friendships, DM convo key, display).
    pub master_id: String,
    /// DEVICE transport peer_id (relay routing).
    pub device_id: String,
    pub cmd_tx: mpsc::Sender<NodeCommand>,
    pub event_rx: mpsc::Receiver<NetworkEvent>,
    pub db_path: String,
    pub passphrase: String,
    _join: tokio::task::JoinHandle<()>,
    // Keep the tempdir alive for the node's lifetime.
    _tmp: tempfile::TempDir,
}

impl TestNode {
    fn store(&self) -> crate::storage::MessageStore {
        crate::storage::MessageStore::open(&self.db_path, &self.passphrase)
            .expect("open node store")
    }
}

// ---------------------------------------------------------------------------
// Inspectors — read a node's REAL state the way the UI does.
//
// Two layers, on purpose (the gap between them is where multi-device bugs hide):
//   * UI layer  — master-collapsed, the projection a person sees (member panel,
//                 online identities, a DM thread). Reads through the SAME
//                 resolver/CRDT accessors the Dart providers use, so a green
//                 inspector == a green UI for that state.
//   * Raw layer — device-keyed underlying truth (room device sets, raw CRDT
//                 member keys). Lets a test assert the invariant beneath the UI
//                 (e.g. CRDT members are master-keyed while transport is
//                 device-keyed) and catch a divergence the UI would hide.
//
// DB-backed state (DMs, channels, friends, servers, CRDT members/roles) is read
// from the node's own SQLCipher store. Presence is read from the MockRelay (the
// authoritative source, exactly as the real relay's RoomMembers drives the UI's
// online dots). Live MLS/Olm in-memory state is owned by the running event loop
// and is added as a debug-snapshot query when the server/channel scenarios land.
// ---------------------------------------------------------------------------

/// One DM bubble as the chat UI would render it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DmBubble {
    pub text: String,
    /// Right-aligned (our send) vs left (received) — the `is_mine` the UI uses.
    pub is_mine: bool,
    pub timestamp: i64,
    /// Whether a signature was present (None => unsigned, shows the "Unsigned" tag).
    pub has_sig: bool,
}

/// One member-panel row as the UI would render it (master-keyed).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct MemberRow {
    pub master: String,
    pub role: crate::crdt::operations::MemberRole,
    pub online: bool,
}

/// One channel message as the UI would render it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ChannelMsg {
    pub text: String,
    /// The SENDER collapsed to their master identity (the name the UI shows).
    pub sender_master: String,
    pub is_mine: bool,
    pub timestamp: i64,
}

#[allow(dead_code)] // Inspector API — methods are used as scenarios are added.
impl TestNode {
    // --- DM thread (UI layer) ----------------------------------------------

    /// The DM thread with `friend_master`, ordered oldest-first, exactly as the
    /// chat pane would show it (bubbles with side + signed flag). Resolves the
    /// friend to their master so a multi-device friend's thread still keys
    /// correctly (the conversation is master-keyed).
    pub(crate) fn dm_thread(&self, friend_master: &str) -> Vec<DmBubble> {
        let convo = super::resolver::resolve(friend_master);
        self.store()
            .get_dm_messages_for_sibling(&convo, 0, 1000)
            .unwrap_or_default()
            .into_iter()
            .map(|m| DmBubble {
                text: m.text,
                is_mine: m.is_mine,
                timestamp: m.timestamp,
                has_sig: m.signature.is_some(),
            })
            .collect()
    }

    /// Unread-count pill for a DM conversation, as the nav would show it.
    pub(crate) fn dm_unread(&self, friend_master: &str, last_seen_message_id: &str) -> u32 {
        let convo = super::resolver::resolve(friend_master);
        self.store().count_unread_dm(&convo, last_seen_message_id)
    }

    // --- Servers / channels / members (UI layer) ---------------------------

    /// Server ids this node is a member of (what the server strip shows).
    pub(crate) fn servers(&self) -> Vec<String> {
        self.store()
            .load_all_servers()
            .unwrap_or_default()
            .into_iter()
            .map(|(sid, _)| sid)
            .collect()
    }

    /// Load one server's CRDT state (None if not joined).
    fn server_state(&self, server_id: &str) -> Option<ServerState> {
        let json = self.store().load_server_state(server_id).ok().flatten()?;
        serde_json::from_str::<ServerState>(&json).ok()
    }

    /// The member panel for `server_id`, master-keyed with role + online flag —
    /// exactly the rows the member panel renders. `relay` supplies authoritative
    /// presence. Roles/membership go through `ServerState::get_role` (which
    /// collapses device→master internally, the resolver-hook chokepoint).
    pub(crate) fn member_panel(&self, server_id: &str, relay: &MockRelay) -> Vec<MemberRow> {
        let Some(state) = self.server_state(server_id) else { return Vec::new() };
        let online_masters = online_identities_from(relay);
        let mut rows: Vec<MemberRow> = state
            .members
            .keys()
            .map(|master| MemberRow {
                master: master.clone(),
                role: state.get_role(master),
                online: online_masters.contains(master),
            })
            .collect();
        rows.sort_by(|a, b| a.master.cmp(&b.master));
        rows
    }

    /// A channel's messages, oldest-first, as the channel pane shows them
    /// (sender collapsed to master).
    pub(crate) fn channel_messages(&self, server_id: &str, channel_id: &str) -> Vec<ChannelMsg> {
        self.store()
            .load_channel_messages(server_id, channel_id, 1000)
            .unwrap_or_default()
            .into_iter()
            .map(|m| ChannelMsg {
                sender_master: super::resolver::resolve(&m.sender_id),
                text: m.text,
                is_mine: m.is_mine,
                timestamp: m.timestamp,
            })
            .collect()
    }

    // --- Raw layer (device-keyed underlying truth) -------------------------

    /// The RAW CRDT member keys for a server (as stored). In a correct
    /// multi-device world these are MASTER ids; if a device id leaks in here,
    /// `canonicalize_members` failed — a bug invisible in the master-collapsed
    /// member panel but visible here.
    pub(crate) fn raw_crdt_member_keys(&self, server_id: &str) -> Vec<String> {
        let Some(state) = self.server_state(server_id) else { return Vec::new() };
        let mut keys: Vec<String> = state.members.keys().cloned().collect();
        keys.sort();
        keys
    }

    // --- Presence (UI layer, read from the authoritative relay) ------------

    /// The set of master identities this node would show as ONLINE (online dots /
    /// Home column). Collapses the relay's online device set through the resolver,
    /// mirroring `onlineIdentitiesProvider`.
    pub(crate) fn online_identities(&self, relay: &MockRelay) -> std::collections::HashSet<String> {
        online_identities_from(relay)
    }

    /// Whether `master` is online (the green dot), the way `identityIsOnline` does
    /// it — true if ANY of that identity's devices has a live socket.
    pub(crate) fn is_online(&self, master: &str, relay: &MockRelay) -> bool {
        online_identities_from(relay).contains(&super::resolver::resolve(master))
    }
}

/// Collapse the relay's online DEVICE set to the set of online MASTER identities
/// (the resolver-collapse the UI's presence layer performs).
fn online_identities_from(relay: &MockRelay) -> std::collections::HashSet<String> {
    relay
        .online_devices()
        .iter()
        .map(|dev| super::resolver::resolve(dev))
        .collect()
}

/// Derive the SQLCipher passphrase the same way `start_node` does
/// (`hex(proto[..32])` of the master keypair).
fn passphrase_for(master: &NativeKeypair) -> String {
    let proto = master.to_protobuf_encoding().expect("encode keypair");
    hex::encode(&proto[..32.min(proto.len())])
}

/// Make a deterministic 32-byte secret from a small seed (test reproducibility;
/// `Math.random`/time are unavailable and we want stable peer_ids per run).
fn seed_bytes(tag: u8) -> [u8; 32] {
    let mut b = [0u8; 32];
    b[0] = tag;
    // Spread the tag a little so distinct tags yield well-separated keys.
    for (i, slot) in b.iter_mut().enumerate() {
        *slot = tag.wrapping_add(i as u8).wrapping_mul(31).wrapping_add(7);
    }
    b
}

/// Spawn one node with the given master + device secret tags, wired into the
/// relay. `master_tag` shared across nodes => same identity (siblings); distinct
/// `device_tag` per node => distinct transport id.
///
/// Convenience for friendless single-node scenarios (future tests); the current
/// test uses [`spawn_node_with_friends`].
#[allow(dead_code)]
async fn spawn_node_on(relay: &MockRelay, master_tag: u8, device_tag: u8) -> TestNode {
    spawn_node_with_friends(relay, master_tag, device_tag, &[]).await
}

/// Like `spawn_node_on` but pre-seeds ACCEPTED friendships into the node's DB
/// BEFORE it registers with the relay, so the node's very first `Connected`
/// auto-joins the shared DM rooms (no offline/online thrash needed). Pass each
/// friend's MASTER id.
async fn spawn_node_with_friends(
    relay: &MockRelay,
    master_tag: u8,
    device_tag: u8,
    friend_masters: &[&str],
) -> TestNode {
    let master = NativeKeypair::from_secret_bytes(&seed_bytes(master_tag));
    let device = NativeKeypair::from_secret_bytes(&seed_bytes(device_tag));
    let passphrase = passphrase_for(&master);

    let tmp = tempfile::tempdir().expect("tempdir");
    let db_path = tmp.path().join("messages.db").to_str().unwrap().to_string();

    // Fresh Olm account + seeded friendships persisted to this node's DB BEFORE
    // the node connects (mirrors start_node loading an existing DB).
    let olm = {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase).expect("open store");
        let mgr = OlmManager::new();
        let pickle = mgr.account_pickle_json().expect("pickle");
        store.save_olm_account(&pickle).expect("save olm");
        for fm in friend_masters {
            store.save_friend(fm, "accepted", "outgoing", 0).expect("seed friend");
        }
        mgr
    };
    let crypto_store = CryptoStore::open(db_path.clone(), passphrase.clone()).expect("crypto store");
    let crdt_store = CrdtStore::open(db_path.clone(), passphrase.clone()).expect("crdt store");

    let (event_tx, event_rx) = mpsc::channel::<NetworkEvent>(256);
    let (cmd_tx, cmd_rx) = mpsc::channel::<NodeCommand>(256);
    let cmd_tx_clone = cmd_tx.clone();

    let (master_id, join, ws_cmd_rx, ws_event_tx) = super::swarm::spawn_node_mock(
        master.clone(),
        device.clone(),
        event_tx,
        cmd_rx,
        cmd_tx_clone,
        olm,
        crypto_store,
        crdt_store,
        false,
        db_path.clone(),
        passphrase.clone(),
    )
    .await
    .expect("spawn_node_mock");

    let device_id = device.peer_id();
    relay.register(device_id.clone(), ws_cmd_rx, ws_event_tx);

    TestNode {
        master_id,
        device_id,
        cmd_tx,
        event_rx,
        db_path,
        passphrase,
        _join: join,
        _tmp: tmp,
    }
}

/// Drain a node's events until `pred` returns true or the timeout elapses.
/// Returns true if matched.
async fn wait_event(
    node: &mut TestNode,
    timeout: std::time::Duration,
    mut pred: impl FnMut(&NetworkEvent) -> bool,
) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return false;
        }
        match tokio::time::timeout(remaining, node.event_rx.recv()).await {
            Ok(Some(ev)) => {
                if pred(&ev) {
                    return true;
                }
            }
            _ => return false,
        }
    }
}

/// Drain any currently-queued events without blocking (clears the channel).
fn drain_events(node: &mut TestNode) {
    while node.event_rx.try_recv().is_ok() {}
}

async fn sleep_ms(ms: u64) {
    tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
}

// ---------------------------------------------------------------------------
// The proof-of-concept test: peer-fallback recovers your OWN stranded sends
// on the CORRECT side (the inversion regression from the 2026-06-18 session).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
// The harness guard is a `std::sync::MutexGuard` deliberately held across the
// whole async test: it serializes harness tests against the process-global
// resolver. An async-aware mutex would let two harness tests interleave and
// corrupt each other's resolver state — exactly what the guard prevents.
#[allow(clippy::await_holding_lock)]
async fn peer_fallback_recovers_own_sends_correct_direction() {
    let _g = test_guard();
    // Point the process-global `data_dir()` at a throwaway temp dir so any stray
    // global-data-dir code path (vault/files/etc.) can't touch the developer's
    // REAL ~/.hollow DB (wrong passphrase → SQLCipher hmac failures). Each node
    // still uses its own injected per-node db_path for messages.
    let global_tmp = tempfile::tempdir().expect("global tmp");
    // SAFETY: set at the very start of this serialized test (HARNESS_GUARD); no
    // other thread reads the env concurrently here.
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = friend (outsider, single device). M = our identity, with TWO devices:
    // B (device tag 20) and C (device tag 21). C does the sends while B is
    // offline; B must later recover them from A on the CORRECT side.
    // A is a single-device outsider: device == master (the keystone case a
    // normal friend is in). M is our identity with two devices B + C.
    const A_MASTER: u8 = 10;
    const M_MASTER: u8 = 20;
    const B_DEV: u8 = 21;
    const C_DEV: u8 = 22;

    // Compute the master ids up front (deterministic from the seed tags) so each
    // node can be spawned with its friendship ALREADY seeded — its first
    // Connected then auto-joins the shared DM room (no offline/online thrash).
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    // Seed the (process-global) resolver BEFORE spawning so every node collapses
    // both M device ids to the master, A routes M→devices, and B knows it is
    // multi-device (`devices_for(M)` non-empty => sets both_directions).
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    // Stagger spawns so each node's pairwise Olm key exchange settles before the
    // next joins — avoids the symmetric KeyBundle glare (all-online-at-once makes
    // every pair defer waiting for the other, which only the 30s sweep breaks).
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;
    sleep_ms(1500).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;

    // Let rooms join + Olm key exchange (KeyRequest/KeyBundle/SessionAck over
    // SendDirect) FULLY CONFIRM between A and the live devices. Glare resolution
    // (lower peer sends PreKey/SessionAck, higher creates inbound) needs a couple
    // of round-trips; give it generous time so sessions are bidirectional before
    // any DM is sent (else the DM rides an unconfirmed ratchet and fails decrypt).
    sleep_ms(6000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    // --- B goes offline; C and A exchange 6 DMs (C wrote FIRST) ---
    relay.set_online(&b.device_id, false);
    sleep_ms(300).await;

    // C -> A : three messages (these are OUR sends, made on device C).
    for (i, mid) in ["c1", "c2", "c3"].iter().enumerate() {
        c.cmd_tx
            .send(NodeCommand::SendMessage {
                peer_id: a.master_id.clone(),
                text: format!("from-C-{}", i + 1),
                message_id: (*mid).to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(60).await; // keep timestamps strictly ordered + ratchet settling
    }
    // A -> M : three replies (A receives C's, then answers).
    for (i, mid) in ["a1", "a2", "a3"].iter().enumerate() {
        a.cmd_tx
            .send(NodeCommand::SendMessage {
                peer_id: b.master_id.clone(),
                text: format!("from-A-{}", i + 1),
                message_id: (*mid).to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(60).await;
    }

    // Let A persist everything (A is the holder of the full conversation).
    // Generous: the first sends had no Olm session, so they queue in
    // pending_messages and re-deliver after KeyRequest→KeyBundle settles.
    sleep_ms(2500).await;

    // Sanity (via the DM-thread inspector — reads the thread as A's chat pane
    // would): A holds all 6, both directions, i.e. the cross-node Olm sessions
    // formed and DMs decrypted before we even test the backfill.
    {
        let thread = a.dm_thread(&b.master_id);
        assert_eq!(thread.len(), 6, "A should hold all 6 messages, got {}", thread.len());
    }

    // Presence inspector: with all three online, A sees our identity (M) online,
    // and we see A online — the green dot the member/Home UI shows.
    assert!(
        a.is_online(&m_master, &relay),
        "A should see our identity M online while a device is connected"
    );
    assert!(
        b.online_identities(&relay).contains(&a.master_id),
        "B should see friend A among online identities"
    );

    // --- C goes offline; B comes online and must recover from A ---
    relay.set_online(&c.device_id, false);
    sleep_ms(100).await;
    drain_events(&mut b);
    relay.set_online(&b.device_id, true);

    // B's reconnect flow fires DmSyncRequest{both_directions} to A; A serves both
    // directions; B inserts with the friend-path inversion. Wait for completion.
    let synced = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::DmSyncCompleted { .. })
    })
    .await;
    assert!(synced, "B should receive DmSyncCompleted from A");
    sleep_ms(200).await; // let the final inserts commit

    // --- THE ASSERTIONS: B recovered all 6 on the CORRECT side ---
    // Read the thread exactly as B's chat pane would render it (the inspector).
    let thread = b.dm_thread(&a.master_id);
    let by_text: HashMap<String, bool> =
        thread.iter().map(|m| (m.text.clone(), m.is_mine)).collect();

    // Our own sends (made on sibling C) MUST be is_mine=true on B — the
    // inversion: A stored them is_mine=0, B re-orients to is_mine=true.
    for t in ["from-C-1", "from-C-2", "from-C-3"] {
        assert_eq!(
            by_text.get(t),
            Some(&true),
            "our own send {t:?} must land as is_mine=true on B (inversion). Got map: {by_text:?}"
        );
    }
    // A's sends are RECEIVED on B => is_mine=false.
    for t in ["from-A-1", "from-A-2", "from-A-3"] {
        assert_eq!(
            by_text.get(t),
            Some(&false),
            "friend send {t:?} must land as is_mine=false on B. Got map: {by_text:?}"
        );
    }
    assert_eq!(thread.len(), 6, "B must have all 6 messages, got {}", thread.len());

    // Every recovered message must carry a signature (the "Unsigned" tag must not
    // appear) — a backfill that mis-oriented direction also breaks sig context.
    assert!(
        thread.iter().all(|m| m.has_sig),
        "every backfilled DM must be signed (no Unsigned bubbles)"
    );

    // Ordering: C wrote first, so the earliest bubble is our own send.
    let earliest = thread
        .iter()
        .min_by_key(|m| m.timestamp)
        .expect("at least one message");
    assert!(
        earliest.is_mine && earliest.text.starts_with("from-C"),
        "earliest message must be our own C-send (correct order), got {:?}",
        earliest.text
    );
}
