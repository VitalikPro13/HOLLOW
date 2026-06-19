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
    /// Microsecond ordering key (Step 9C/C4) — `None` if it didn't survive the
    /// wire/backfill (a regression) or a legacy/pre-9C row.
    pub order_us: Option<i64>,
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

    /// Server ids this node is a member of (what the server strip shows). Mirrors
    /// `get_joined_servers`: tombstoned (deleted) servers are HIDDEN — the node keeps
    /// the shell to serve the deletion op, but the UI list excludes it.
    pub(crate) fn servers(&self) -> Vec<String> {
        self.store()
            .load_all_servers()
            .unwrap_or_default()
            .into_iter()
            .filter(|(_, json)| {
                serde_json::from_str::<ServerState>(json)
                    .map(|s| !s.is_deleted())
                    .unwrap_or(true)
            })
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

    /// A member's server nickname as the UI would read it (master-keyed, collapses
    /// device→master via `get_nickname`'s resolver). Empty string = no nickname.
    pub(crate) fn server_nickname(&self, server_id: &str, master: &str) -> String {
        self.server_state(server_id)
            .map(|s| s.get_nickname(master))
            .unwrap_or_default()
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
                order_us: m.order_us,
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

    // --- Live crypto state (queries the running event loop) ----------------

    /// Snapshot the node's LIVE in-memory MLS/Olm state (owned by the running
    /// event loop). Round-trips a `DebugSnapshot` command over the oneshot.
    /// Returns `None` if the loop didn't reply within the timeout.
    pub(crate) async fn debug_snapshot(&self) -> Option<super::types::DebugSnapshotReply> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.cmd_tx
            .send(NodeCommand::DebugSnapshot { reply: tx })
            .await
            .ok()?;
        tokio::time::timeout(std::time::Duration::from_secs(2), rx)
            .await
            .ok()?
            .ok()
    }

    /// The MLS group's leaf DEVICE ids for `server_id` (raw, device-keyed — the
    /// truth under the master-keyed member panel). Empty if no group / no reply.
    pub(crate) async fn mls_members(&self, server_id: &str) -> Vec<String> {
        let mut v = self
            .debug_snapshot()
            .await
            .and_then(|s| s.mls_members.get(server_id).cloned())
            .unwrap_or_default();
        v.sort();
        v
    }

    /// The current MLS epoch for `server_id` (None if no group / no reply).
    pub(crate) async fn mls_epoch(&self, server_id: &str) -> Option<u64> {
        self.debug_snapshot()
            .await
            .and_then(|s| s.mls_epoch.get(server_id).copied())
    }

    /// Olm session status with a peer DEVICE id: "none" | "unconfirmed" |
    /// "confirmed" | "absent" (no session object at all).
    pub(crate) async fn olm_status(&self, device_peer_id: &str) -> String {
        self.debug_snapshot()
            .await
            .and_then(|s| s.olm_sessions.get(device_peer_id).cloned())
            .unwrap_or_else(|| "absent".to_string())
    }

    // --- File-transfer control state (DB-backed) ---------------------------

    /// A received file's metadata row, as the receiver persisted it from the
    /// FileHeader (control plane). `completed_at` is `None` until the byte stream
    /// assembles — which a pure harness run never does (no WebRTC), so this reads
    /// the CONTROL state: a pending download the UI would show as "downloading".
    pub(crate) fn file_meta(&self, file_id: &str) -> Option<crate::storage::messages::StoredFile> {
        self.store().get_file_metadata(file_id).ok().flatten()
    }

    /// File ids referenced by messages that have no completed file row — i.e. the
    /// files the node still needs to RequestFile for (the "needs download" set).
    pub(crate) fn missing_file_ids(&self) -> Vec<String> {
        let mut v = self.store().get_missing_file_ids().unwrap_or_default();
        v.sort();
        v
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
    spawn_node_full(relay, master_tag, device_tag, friend_masters, None).await
}

/// Full spawn with an optional pre-seeded SIGNED self device list (Step 9C/C5):
/// persists a master-signed `{devices}` list into the node's DB BEFORE start, so
/// startup's resolver self-seed reads it — mimicking a freshly-LINKED sibling whose
/// imported DB holds the SOURCE device's list (and NOT yet its own new device id).
async fn spawn_node_full(
    relay: &MockRelay,
    master_tag: u8,
    device_tag: u8,
    friend_masters: &[&str],
    pre_seed_self_devices: Option<&[String]>,
) -> TestNode {
    let master = NativeKeypair::from_secret_bytes(&seed_bytes(master_tag));
    let device = NativeKeypair::from_secret_bytes(&seed_bytes(device_tag));
    let passphrase = passphrase_for(&master);

    let tmp = tempfile::tempdir().expect("tempdir");
    let db_path = tmp.path().join("messages.db").to_str().unwrap().to_string();

    // Mirror production `start_node`: run the one-time storage-hygiene migration in
    // the single-connection window BEFORE any store/actor opens. (In production
    // this runs in `api::network::start_node`; the harness uses `spawn_node_mock`
    // which bypasses that path, so do it here for parity + to exercise the code.)
    crate::storage::MessageStore::migrate_auto_vacuum_once(&db_path, &passphrase)
        .expect("auto_vacuum migration");

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
        // Pre-seed a signed self device list (C5: simulate the imported source list).
        if let Some(devices) = pre_seed_self_devices {
            let signed = super::crypto_handler::build_signed_device_list(
                &master, 1, devices.to_vec(), Vec::new(),
            );
            if let Ok(json) = serde_json::to_string(&signed) {
                store.save_device_list(
                    &signed.master_peer_id, &json, signed.version, &signed.devices, 0,
                ).expect("persist pre-seed device list");
            }
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

/// Drive `CreateServer` on `node` and return the new `server_id` (captured from
/// the `ServerCreated` event the owner emits). The default `#general` channel id
/// is `format!("{}-general", &server_id[..8])`.
async fn create_server_and_wait(node: &mut TestNode, name: &str) -> String {
    node.cmd_tx
        .send(NodeCommand::CreateServer { name: name.to_string() })
        .await
        .unwrap();
    let mut server_id = None;
    let ok = wait_event(node, std::time::Duration::from_secs(3), |ev| {
        if let NetworkEvent::ServerCreated { server_id: sid, .. } = ev {
            server_id = Some(sid.clone());
            true
        } else {
            false
        }
    })
    .await;
    assert!(ok, "owner should emit ServerCreated");
    server_id.expect("ServerCreated carried a server_id")
}

/// The default `#general` channel id for a server.
fn general_channel_of(server_id: &str) -> String {
    format!("{}-general", &server_id[..8.min(server_id.len())])
}

/// Persist a master-signed v1 `SignedDeviceList` (devices = `device_ids`) into the
/// DB at `db_path`, the way an inbox-proof / ProfileUpdate ingest would leave it.
/// This is the precondition `revoke_own_device` reads (it bumps + re-signs from the
/// stored version). `master_tag` is the shared sibling master seed tag.
fn seed_device_list_into_db(db_path: &str, passphrase: &str, master_tag: u8, device_ids: &[String]) {
    let master = NativeKeypair::from_secret_bytes(&seed_bytes(master_tag));
    let signed = super::crypto_handler::build_signed_device_list(&master, 1, device_ids.to_vec(), Vec::new());
    let json = serde_json::to_string(&signed).expect("serialize device list");
    let store = crate::storage::MessageStore::open(db_path, passphrase).expect("open store");
    store
        .save_device_list(&signed.master_peer_id, &json, signed.version, &signed.devices, 0)
        .expect("persist device list");
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

// ---------------------------------------------------------------------------
// Rung 2: a friend JOINS a server, the MLS group forms across both nodes, and
// an encrypted channel message DECRYPTS on the joiner's device. This is the
// Step-6 multi-device-MLS surface — the biggest untested area — driven and
// inspected end to end (CRDT member panel + raw MLS leaves + live MLS epoch +
// decrypted channel message), no live devices.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn server_join_forms_mls_and_channel_message_decrypts() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner (single device), J = joiner (single device). Both plain
    // single-device identities (device == master) — the common case.
    const O_MASTER: u8 = 30;
    const J_MASTER: u8 = 40;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    // Befriend O <-> J (so Olm key exchange + presence work as in production;
    // server join needs a live Olm session for the direct handshake messages).
    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    // Let Olm sessions confirm bidirectionally before the join handshake rides them.
    sleep_ms(4000).await;

    // Olm sanity (live-state inspector): O <-> J sessions are confirmed.
    assert_eq!(
        o.olm_status(&j.device_id).await,
        "confirmed",
        "owner must hold a confirmed Olm session with the joiner before join"
    );

    // --- Owner creates a server (+ implicit #general channel) ---
    let server_id = create_server_and_wait(&mut o, "Test Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;

    // Owner has an MLS group with itself as the sole leaf at epoch 0.
    assert_eq!(
        o.mls_members(&server_id).await,
        vec![o.device_id.clone()],
        "owner is the sole MLS leaf right after CreateServer"
    );
    drain_events(&mut o);
    drain_events(&mut j);

    // --- Joiner joins the server ---
    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();

    // Joiner should complete the CRDT join (ServerJoined) first…
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should emit ServerJoined");

    // …then the MLS handshake (KeyPackage → 2s batch timer → Welcome) forms the
    // group on the joiner. Give the 2s mls_batch_timer room to fire after the KP.
    sleep_ms(5000).await;

    // --- MLS group formed across BOTH nodes (raw device-keyed leaves) ---
    let owner_leaves = o.mls_members(&server_id).await;
    let joiner_leaves = j.mls_members(&server_id).await;
    let expected = {
        let mut v = vec![o.device_id.clone(), j.device_id.clone()];
        v.sort();
        v
    };
    assert_eq!(owner_leaves, expected, "owner's MLS group must contain both device leaves");
    assert_eq!(joiner_leaves, expected, "joiner's MLS group must contain both device leaves");
    // Both at the same (post-add) epoch.
    assert!(o.mls_epoch(&server_id).await.unwrap_or(0) >= 1, "owner epoch advanced past the add");
    assert_eq!(
        o.mls_epoch(&server_id).await,
        j.mls_epoch(&server_id).await,
        "owner and joiner must be at the same MLS epoch"
    );

    // --- Member panel (UI layer): both see two MASTER-keyed members, online ---
    let panel = j.member_panel(&server_id, &relay);
    let masters: Vec<String> = panel.iter().map(|r| r.master.clone()).collect();
    assert!(masters.contains(&o_master) && masters.contains(&j_master),
        "joiner's member panel shows both masters, got {masters:?}");
    assert!(panel.iter().all(|r| r.online), "both members online in the panel");
    // Raw layer: CRDT member keys are MASTERS, not device ids (canonicalize_members).
    assert_eq!(j.raw_crdt_member_keys(&server_id), {
        let mut v = vec![o_master.clone(), j_master.clone()]; v.sort(); v
    }, "CRDT members must be master-keyed");

    drain_events(&mut j);

    // --- Owner sends an MLS-encrypted channel message; joiner DECRYPTS it ---
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "hello channel".to_string(),
            message_id: "ch-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();

    let got = wait_event(&mut j, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "hello channel")
    })
    .await;
    assert!(got, "joiner must receive + decrypt the channel message");
    sleep_ms(200).await;

    // Channel-pane inspector: the decrypted message is stored, attributed to the
    // owner's MASTER, on the receive side (is_mine=false).
    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "hello channel").expect("message stored");
    assert_eq!(row.sender_master, o_master, "channel message attributed to owner master");
    assert!(!row.is_mine, "received message is not is_mine on the joiner");
}

// ---------------------------------------------------------------------------
// Rung 3: device REVOCATION. One sibling revokes another. Assert the full
// cutoff: the revoked device gets SelfRevoked, the revoker drops its Olm session
// to it, and the ghost fan-out guard holds — a subsequent DM from a friend never
// reaches the revoked-and-dropped device (collect_target_devices filters to
// devices currently in a room). This is the Steps 7/8 revocation surface.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn device_revocation_cuts_off_and_ghost_fanout_holds() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = friend (single device). M = our identity, two devices B + C.
    const A_MASTER: u8 = 50;
    const M_MASTER: u8 = 60;
    const B_DEV: u8 = 61;
    const C_DEV: u8 = 62;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    // Seed the resolver: M has devices B + C (so devices_for/same_identity work and
    // revoke_own_device's `belongs` check passes).
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    // A is friends with M; B and C are friends with A.
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    sleep_ms(1200).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;

    // Persist a v1 signed device list {B,C} into BOTH siblings' DBs (what an
    // inbox-proof / ProfileUpdate ingest would leave) so revoke bumps from v1→v2.
    seed_device_list_into_db(&b.db_path, &b.passphrase, M_MASTER, &[b_dev.clone(), c_dev.clone()]);
    seed_device_list_into_db(&c.db_path, &c.passphrase, M_MASTER, &[b_dev.clone(), c_dev.clone()]);

    // Let Olm sessions confirm all around (A↔B, A↔C, B↔C siblings).
    sleep_ms(5000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    // B holds a session with sibling C before revocation.
    assert_ne!(
        b.olm_status(&c.device_id).await,
        "absent",
        "B should hold an Olm session with sibling C before revoking it"
    );

    // --- B revokes device C ---
    b.cmd_tx
        .send(NodeCommand::RevokeDevice { device_peer_id: c.device_id.clone() })
        .await
        .unwrap();

    // The revoker B emits DeviceListUpdated.
    let b_updated = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::DeviceListUpdated { .. })
    })
    .await;
    assert!(b_updated, "revoker B should emit DeviceListUpdated");

    // The revoked device C receives the tombstone (ProfileUpdate to it FIRST) and
    // emits SelfRevoked — the trigger for the Dart-side data wipe.
    let c_nuked = wait_event(&mut c, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::SelfRevoked)
    })
    .await;
    assert!(c_nuked, "revoked device C should emit SelfRevoked");
    sleep_ms(300).await;

    // B's Olm session to C is torn down (enforce_device_revocations).
    assert_eq!(
        b.olm_status(&c.device_id).await,
        "absent",
        "B must drop its Olm session to the revoked device C"
    );

    // --- Ghost fan-out guard: C self-nukes → disconnect; a later DM must NOT
    // reach it. Simulate C's disconnect (the real device wipes + drops its socket). ---
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut c);

    // A sends a DM to our identity M. With C revoked + out of all rooms,
    // collect_target_devices targets only B (in the room) — never the ghost C.
    a.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: m_master.clone(),
            text: "after-revoke".to_string(),
            message_id: "post-revoke-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();

    // B (still live) receives it…
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "after-revoke")
    })
    .await;
    assert!(b_got, "live device B should still receive the friend's DM");

    // …and C (revoked + offline) must NOT — its thread stays empty of the post-revoke
    // message even after coming back online (it's dropped from the room, never
    // targeted, and the receive-side is_revoked guard drops any stray delivery).
    relay.set_online(&c.device_id, true);
    sleep_ms(800).await;
    let c_thread = c.dm_thread(&a.master_id);
    assert!(
        !c_thread.iter().any(|m| m.text == "after-revoke"),
        "revoked device C must NOT receive the post-revocation DM (ghost fan-out guard), got {:?}",
        c_thread.iter().map(|m| &m.text).collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: call signal routing. The harness can't run real
// audio/video/ICE, but it CAN verify the load-bearing CONTROL path that breaks
// silently: a call signal addressed to a friend's MASTER must be (a) mapped from
// its whitelisted signal_type to the right HavenMessage variant and (b) routed to
// the friend's concrete online DEVICE (the master authenticates as no socket).
// An unknown signal_type must be silently dropped, never delivered. This guards
// the "WHITELISTED, not passed through" + master-vs-device routing class.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn call_signal_routes_to_friend_device_and_drops_unknown() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = caller (single device). M = callee identity with one online device B.
    const A_MASTER: u8 = 70;
    const M_MASTER: u8 = 80;
    const B_DEV: u8 = 81;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();

    // M is multi-device-capable (device B != master) so the routing must resolve
    // master→device — addressing the bare master would be silently dropped.
    super::resolver::seed_self(&m_master, &[b_dev.clone()]);

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    sleep_ms(2500).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A sends a call INVITE addressed to M's MASTER. handle_call_send_signal must
    // map "invite" → CallInvite and route to B (M's online device).
    let invite_payload = serde_json::json!({
        "call_id": "call-1", "video": true, "sframe_key": "k",
    }).to_string();
    a.cmd_tx
        .send(NodeCommand::CallSendSignal {
            peer_id: m_master.clone(),
            signal_type: "invite".to_string(),
            payload: invite_payload,
        })
        .await
        .unwrap();

    // B (M's device) receives the CallSignal invite — the call "rings".
    let mut got_call_id = None;
    let rang = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::CallSignal { signal_type, payload, .. } = ev {
            if signal_type == "invite" {
                let v: serde_json::Value = serde_json::from_str(payload).unwrap_or_default();
                got_call_id = v["call_id"].as_str().map(|s| s.to_string());
                return true;
            }
        }
        false
    })
    .await;
    assert!(rang, "callee device B must receive the routed CallInvite (master→device routing)");
    assert_eq!(got_call_id.as_deref(), Some("call-1"), "the invite carried the right call_id");

    drain_events(&mut b);

    // An UNKNOWN signal type must be silently dropped (whitelist) — never delivered.
    a.cmd_tx
        .send(NodeCommand::CallSendSignal {
            peer_id: m_master.clone(),
            signal_type: "totally-made-up".to_string(),
            payload: "{}".to_string(),
        })
        .await
        .unwrap();
    let leaked = wait_event(&mut b, std::time::Duration::from_millis(800), |ev| {
        matches!(ev, NetworkEvent::CallSignal { .. })
    })
    .await;
    assert!(!leaked, "an unknown call signal type must be silently dropped, never delivered");
}

// ---------------------------------------------------------------------------
// Ring-2 FILE TRANSFER: full DM file send end to end. The FileHeader rides Olm
// (SendDirect); the encrypted bytes fall back to WSS-relay binary streaming when
// there's no WebRTC data channel (`stream_to_peer` -> ws_stream_send ->
// SendBinaryDirect), which the MockRelay routes in-room. So MORE than the control
// plane is coverable here: the bytes actually transfer + decrypt in-process. We
// assert the receiver emits FileHeaderReceived, persists the files row, and
// completes the transfer with the correct decrypted contents on disk. (Only the
// WebRTC-data-channel byte path itself is out of scope — the relay fallback is
// the same assembly/decrypt logic.)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_file_transfer_completes_and_decrypts() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 90;
    const B_MASTER: u8 = 100;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    sleep_ms(4000).await; // let Olm sessions confirm (the FileHeader rides Olm)
    assert_eq!(
        a.olm_status(&b.device_id).await, "confirmed",
        "sender needs a confirmed Olm session for the FileHeader"
    );
    drain_events(&mut a);
    drain_events(&mut b);

    // Write a small real file for the sender to read + send.
    let src = global_tmp.path().join("hello.txt");
    let contents: &[u8] = b"hello file contents";
    std::fs::write(&src, contents).expect("write src file");

    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "file-msg-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
        })))
        .await
        .unwrap();

    // Receiver B emits FileHeaderReceived and persists a files row.
    let mut got_fid = None;
    let header = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("hello") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(header, "receiver must emit FileHeaderReceived for the sent file");
    let fid = got_fid.expect("file id from header");

    // The bytes stream over the relay fallback + decrypt; wait for completion.
    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "receiver must complete the file transfer (relay byte fallback)");
    sleep_ms(200).await;

    // Inspector: the files row is persisted, complete, and on disk with the
    // ORIGINAL decrypted contents — a true end-to-end file transfer.
    let meta = b.file_meta(&fid).expect("receiver persisted a files row");
    assert_eq!(meta.context_type, "dm", "file context is a DM");
    assert!(meta.file_name.starts_with("hello"), "header name persisted, got {:?}", meta.file_name);
    assert_eq!(meta.size_bytes, contents.len() as u64, "size matches the source file");
    assert!(meta.completed_at.is_some(), "transfer completed");
    let disk = meta.disk_path.expect("completed file has a disk path");
    let got = std::fs::read(&disk).expect("read the received file");
    assert_eq!(got, contents, "received file must decrypt to the original contents");
    // A completed file is no longer in the needs-download set.
    assert!(!b.missing_file_ids().contains(&fid), "completed file is not missing");
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: voice-channel join/leave + participant tracking + signal
// routing. Real audio/SFU is out of scope; the control path rides a plaintext
// fallback (no formed MLS group needed — only server membership + a Voice
// channel). Both nodes join a server, J joins the voice channel (O sees it in its
// participant set), a broadcast signal routes, and leave removes the participant.
// Also guards the VC signal whitelist (unknown type silently dropped).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn voice_channel_join_leave_and_signal_routing() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 110;
    const J_MASTER: u8 = 120;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    sleep_ms(4000).await; // Olm confirm (targeted VC signals would need it)

    // Owner creates a server; add a VOICE channel (the default #general is Text).
    let server_id = create_server_and_wait(&mut o, "VC Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            name: "Voice".to_string(),
            category: None,
            channel_type: "voice".to_string(),
        })
        .await
        .unwrap();
    let mut voice_cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(3), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, channel_type, .. } = ev {
            if channel_type == "voice" {
                voice_cid = Some(channel_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(made, "owner should create a voice channel");
    let voice_cid = voice_cid.expect("voice channel id");
    sleep_ms(300).await;

    // J joins the server (so both hold server_states with each other as members —
    // the precondition for the plaintext VC path; MLS-formed not required here).
    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await; // let the MemberAdded op propagate to both CRDTs
    drain_events(&mut o);
    drain_events(&mut j);

    // --- J joins the VOICE channel; O sees J in the participant set ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let o_saw_join = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(o_saw_join, "owner must see the joiner enter the voice channel");

    // --- A broadcast VC signal (audio_state) routes via the plaintext fallback ---
    drain_events(&mut o);
    let audio_payload = serde_json::json!({
        "call_id": voice_cid, "muted": true, "deafened": false,
    }).to_string();
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "audio_state".to_string(),
            payload: audio_payload,
        })
        .await
        .unwrap();
    let o_saw_signal = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelSignal { signal_type, .. } if signal_type == "audio_state")
    })
    .await;
    assert!(o_saw_signal, "owner must receive the routed audio_state VC signal");

    // Unknown VC signal type is silently dropped (whitelist).
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "made-up-vc-signal".to_string(),
            payload: "{}".to_string(),
        })
        .await
        .unwrap();
    let leaked = wait_event(&mut o, std::time::Duration::from_millis(800), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelSignal { .. })
    })
    .await;
    assert!(!leaked, "an unknown VC signal type must be silently dropped");

    // --- J leaves the voice channel; O sees the leave ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelLeave {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let o_saw_leave = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelLeft { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(o_saw_leave, "owner must see the joiner leave the voice channel");
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: recovery-pool formation. The cross-peer shard byte
// streaming + reconstruction math need a populated vault (heavier setup), but the
// pool's MEMBERSHIP control path is fully in-process: an initiator opens a pool
// (joins recovery:{server}:{token}), a second node joins + broadcasts a
// RecoveryHello, and the initiator registers it as a member. This guards the pool
// rendezvous + RecoveryHello/Welcome inventory-exchange handshake.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn recovery_pool_membership_forms() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 130; // initiator
    const J_MASTER: u8 = 140; // joiner
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1000).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    sleep_ms(1500).await;
    drain_events(&mut o);
    drain_events(&mut j);

    let server_id = "recovery-server-1".to_string();
    let token = "tok123".to_string();

    // Initiator opens the pool FIRST (so it's in the room when the joiner's
    // RecoveryHello room-broadcast arrives).
    o.cmd_tx
        .send(NodeCommand::InitiateRecoveryPool { server_id: server_id.clone(), token: token.clone() })
        .await
        .unwrap();
    let created = wait_event(&mut o, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::RecoveryPoolCreated { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(created, "initiator should emit RecoveryPoolCreated");
    sleep_ms(300).await;

    // Joiner joins the pool → sends RecoveryHello (room broadcast) + emits Joined.
    j.cmd_tx
        .send(NodeCommand::JoinRecoveryPool { server_id: server_id.clone(), token: token.clone() })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::RecoveryPoolJoined { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should emit RecoveryPoolJoined");

    // The initiator receives the RecoveryHello and registers the joiner as a member.
    let o_saw_member = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::RecoveryPoolMemberJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(o_saw_member, "initiator must register the joiner as a recovery-pool member");
}

// ---------------------------------------------------------------------------
// Step 9C / C3 (VERIFY-ONLY): sibling↔sibling SERVER-message backfill — the
// server analog of the DM peer-fallback. Claim under test (tracker §9C): the
// channel-sync rails already recover a device's OWN channel messages that were
// sent from a now-offline SIBLING, with NO new code — because the
// `ChannelSyncRequest` responder has no `is_mine` filter (serves all senders by
// sender_id+timestamp) and the reconnect trigger (`SyncCoordinator::collect_ready`,
// registered on PeerJoined/RoomMembers) fires a `ChannelSyncRequest` per channel
// unconditionally. Scenario: A owns a server; M's two devices B + C both join
// (both MLS leaves). C goes offline; B sends 3 channel messages (stored on A under
// master M). Then B goes offline and C reconnects — C must recover B's sends (its
// OWN identity's messages) from A, the only present member. If this is green, the
// `[~]` item is confirmed needing no code.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sibling_recovers_own_channel_messages_from_present_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = owner/friend (single device). M = our identity with two devices B + C.
    const A_MASTER: u8 = 150;
    const M_MASTER: u8 = 160;
    const B_DEV: u8 = 161;
    const C_DEV: u8 = 162;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    // M has devices B + C (resolver collapses both → master M; A routes M→devices).
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    // A is friends with M; B and C are friends with A (so Olm sessions form for the
    // server-join handshake, exactly as in the server-join test).
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;
    sleep_ms(5000).await; // let Olm confirm all around (A↔B, A↔C, B↔C)
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    // --- A creates a server; B (one device of M) joins and forms its MLS leaf ---
    // We test the backfill rail with ONE sibling member at a time, which isolates
    // the "own data stranded" recovery from the separate concurrent-two-sibling-MLS
    // formation timing (C joins FRESH later, while B is offline). C recovering B's
    // sends on join is the exact §9C claim ("the server rails already cover the same
    // 'own data stranded' class as the DM peer-fallback").
    let server_id = create_server_and_wait(&mut a, "Backfill Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;

    // C stays OFFLINE for the whole "B sends" phase (it joins fresh afterwards).
    relay.set_online(&c.device_id, false);
    sleep_ms(200).await;

    b.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let b_joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(b_joined, "device B should join the server");
    sleep_ms(4000).await; // let B's MLS leaf form (KeyPackage → batch-add → Welcome)
    drain_events(&mut a);
    drain_events(&mut b);

    // B and A are the two MLS leaves; B's channel message must decrypt on A.
    let a_leaves = a.mls_members(&server_id).await;
    assert!(
        a_leaves.contains(&b.device_id),
        "A's MLS group must contain B's device leaf, got {a_leaves:?}"
    );

    // --- B sends 3 channel messages; A (present) stores them under master M ---
    for (i, mid) in ["s1", "s2", "s3"].iter().enumerate() {
        b.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: format!("from-B-{}", i + 1),
                message_id: (*mid).to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(80).await; // keep timestamps strictly ordered
    }
    let a_got = wait_event(&mut a, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "from-B-3")
    })
    .await;
    assert!(a_got, "owner A must receive B's channel messages");
    sleep_ms(300).await;
    {
        // Sanity: A holds B's three sends, attributed to our master M.
        let on_a = a.channel_messages(&server_id, &general);
        for t in ["from-B-1", "from-B-2", "from-B-3"] {
            let row = on_a.iter().find(|m| m.text == t)
                .unwrap_or_else(|| panic!("A should hold {t}, got {:?}",
                    on_a.iter().map(|m| &m.text).collect::<Vec<_>>()));
            assert_eq!(row.sender_master, m_master, "B's send attributed to master M on A");
        }
    }

    // --- B goes offline; C comes online and JOINS the server fresh ---
    // C is M's OTHER device; B's sends are its OWN identity's history, now stranded
    // (the only device that sent them is offline). On join, C's channel-sync must
    // recover them from A — the present member.
    relay.set_online(&b.device_id, false);
    sleep_ms(200).await;
    drain_events(&mut c);
    relay.set_online(&c.device_id, true);
    sleep_ms(500).await; // let C re-run its connect flow

    c.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let c_joined = wait_event(&mut c, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(c_joined, "device C should join the server fresh");

    // On join, C registers with the SyncCoordinator and fires a ChannelSyncRequest
    // per channel; A serves B's messages (sender = master M = C's OWN identity — no
    // is_mine filter blocks them). The backfill path emits MessageSyncCompleted.
    let recovered = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::MessageSyncCompleted { server_id: sid, new_message_count }
            if *sid == server_id && *new_message_count > 0)
            || matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "from-B-3")
    })
    .await;
    assert!(recovered, "C should receive a channel-sync carrying B's messages from A on join");
    sleep_ms(700).await; // let any remaining inserts commit

    // --- THE ASSERTION: C recovered all 3 of its own identity's channel sends ---
    let on_c = c.channel_messages(&server_id, &general);
    for t in ["from-B-1", "from-B-2", "from-B-3"] {
        let row = on_c.iter().find(|m| m.text == t).unwrap_or_else(|| {
            panic!(
                "C must recover its own identity's channel message {t:?} from A on join \
                 (sibling server backfill). Got: {:?}",
                on_c.iter().map(|m| &m.text).collect::<Vec<_>>()
            )
        });
        // Attributed to our master M (C's own identity) — the messages it sent from B.
        assert_eq!(row.sender_master, m_master, "recovered message attributed to master M");
        // C4: the microsecond ordering key survived the send → A → backfill → C round
        // trip (not NULL), so cross-device ordering is stable.
        assert!(
            row.order_us.is_some(),
            "recovered message {t:?} must carry order_us through the wire+backfill (C4)"
        );
    }
    // C4: the three backfilled sends are in true send order on C (B-1 < B-2 < B-3 by
    // order_us), even though they may share a millisecond timestamp.
    let recovered_seq: Vec<(&str, i64)> = ["from-B-1", "from-B-2", "from-B-3"]
        .iter()
        .map(|t| (*t, on_c.iter().find(|m| m.text == *t).unwrap().order_us.unwrap()))
        .collect();
    assert!(
        recovered_seq[0].1 < recovered_seq[1].1 && recovered_seq[1].1 < recovered_seq[2].1,
        "backfilled sends must keep strictly increasing order_us (true send order): {recovered_seq:?}"
    );
}

// ---------------------------------------------------------------------------
// Step 9C / C2: server MODERATION actions reach the actor's OWN sibling devices.
// The bug: kick/ban/role-change/leave broadcast their CRDT op only to the
// REMAINING members (master-keyed, actor's identity excluded), so a moderation
// action on device B never reaches sibling C of the same person — C only
// converged on restart. Fix: each handler also fans the op (and, for kick/ban,
// the MLS leaf-removal commit) to our own online siblings, excluding the acting
// device. Scenario: M owns a server (devices B + C); V is a victim member. B
// performs role-change then kick of V; C (sibling, never restarted) must reflect
// both WITHOUT restart. (Owner M creates the server so role-change/kick perms
// hold for either of M's devices.)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn moderation_action_converges_on_actor_sibling_without_restart() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = owner identity, devices B + C. V = victim (single device, a friend so
    // the join handshake's Olm session forms).
    const M_MASTER: u8 = 170;
    const B_DEV: u8 = 171;
    const C_DEV: u8 = 172;
    const V_MASTER: u8 = 180;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let v_master = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    // B + C (siblings) are friends with V; V is friends with M.
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&v_master]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&v_master]).await;
    sleep_ms(1500).await;
    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_MASTER, &[&m_master]).await;
    sleep_ms(5000).await; // let Olm confirm all around
    drain_events(&mut b);
    drain_events(&mut c);
    drain_events(&mut v);

    // --- B (device of owner M) creates the server; C is a sibling, V joins ---
    let server_id = create_server_and_wait(&mut b, "Mod Server").await;
    sleep_ms(500).await;

    // V joins the server.
    v.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let v_joined = wait_event(&mut v, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(v_joined, "victim V should join the server");
    sleep_ms(2500).await;

    // C (B's sibling) joins so it holds the server CRDT state as a member of M.
    c.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let c_joined = wait_event(&mut c, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(c_joined, "sibling C should join the server");
    sleep_ms(3000).await; // CRDT membership converges across B, C, V
    drain_events(&mut b);
    drain_events(&mut c);
    drain_events(&mut v);

    // Pre-state: C's member panel shows M (owner) + V (member), V as a plain Member.
    {
        let panel = c.member_panel(&server_id, &relay);
        let v_row = panel.iter().find(|r| r.master == v_master)
            .unwrap_or_else(|| panic!("C should see V as a member pre-action, got {:?}",
                panel.iter().map(|r| &r.master).collect::<Vec<_>>()));
        assert_eq!(v_row.role, crate::crdt::operations::MemberRole::Member,
            "V starts as a plain Member on C");
    }

    // --- B changes V's role to Moderator; C (sibling) must reflect it ---
    b.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
            new_role: "moderator".to_string(), // MemberRole::from_str is lowercase
        })
        .await
        .unwrap();
    sleep_ms(1500).await; // op fans to C (the fix) — no restart

    {
        let v_row = c.member_panel(&server_id, &relay)
            .into_iter()
            .find(|r| r.master == v_master)
            .expect("C still sees V after role change");
        assert_eq!(
            v_row.role, crate::crdt::operations::MemberRole::Moderator,
            "sibling C must reflect V's role change to Moderator WITHOUT restart (C2 fix)"
        );
    }

    // --- GAP-A (Fix 4): B sets its OWN server nickname; sibling C must reflect it
    // WITHOUT restart. (Here V is online and re-gossips B's op to C too, so this
    // also passes via the relay path; the DIRECT sibling-fan is isolated in the
    // dedicated no-relayer test `sibling_nickname_fans_directly_with_no_relayer`.) ---
    b.cmd_tx
        .send(NodeCommand::SetNickname {
            server_id: server_id.clone(),
            peer_id: m_master.clone(),
            nickname: "PixelNick".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(1500).await; // op fans to C (the Fix-4 sibling fan) — no restart
    {
        let nick = c.server_nickname(&server_id, &m_master);
        assert_eq!(
            nick, "PixelNick",
            "sibling C must reflect our own nickname change WITHOUT restart (Fix 4 GAP-A)"
        );
    }

    // --- B kicks V; C (sibling) must drop V from its member panel ---
    b.cmd_tx
        .send(NodeCommand::KickMember {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
        })
        .await
        .unwrap();
    // B emits MemberLeft for V locally.
    let b_kicked = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::MemberLeft { peer_id, .. } if *peer_id == v_master)
    })
    .await;
    assert!(b_kicked, "actor B should emit MemberLeft for the kicked victim");
    sleep_ms(1500).await; // removal op fans to C (the fix) — no restart

    // THE C2 ASSERTION: C dropped V without ever restarting.
    {
        let panel = c.member_panel(&server_id, &relay);
        assert!(
            !panel.iter().any(|r| r.master == v_master),
            "sibling C must drop the kicked V from its member panel WITHOUT restart (C2 fix), got {:?}",
            panel.iter().map(|r| &r.master).collect::<Vec<_>>()
        );
        // C still sees the owner identity M — only V was removed.
        assert!(
            panel.iter().any(|r| r.master == m_master),
            "C still shows the owner identity M after the kick"
        );
    }
}

// ---------------------------------------------------------------------------
// Step 9C / C5: a freshly-LINKED sibling's "Your devices" list shows BOTH devices
// immediately (not just itself). Bug: the imported .hollow backup carries the
// SOURCE device's signed device list, which does NOT contain the new sibling's
// brand-new device id. At startup the resolver self-seed used ONLY that list, so
// the running device resolved to ITSELF (not the master) → `myMaster` wrong →
// `myDevicesProvider` (which inverts the resolver) showed one device until the
// source came online and the inbox-proof merge fired. Fix: startup seeds
// `list.devices ∪ {this_device}`. This asserts the Rust state the panel reads
// (the resolver links), which is the harness-coverable half; the actual panel
// render is Vitalik's visual check.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn linked_sibling_resolves_both_devices_at_startup() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity. SOURCE device already existed; SIB is the freshly-linked
    // device we're booting. The imported list contains ONLY the source device id.
    const M_MASTER: u8 = 190;
    const SOURCE_DEV: u8 = 191;
    const SIB_DEV: u8 = 192;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let source_dev = NativeKeypair::from_secret_bytes(&seed_bytes(SOURCE_DEV)).peer_id();
    let sib_dev = NativeKeypair::from_secret_bytes(&seed_bytes(SIB_DEV)).peer_id();

    // CRUCIAL: do NOT pre-seed the resolver here (no `seed_self`). The whole point
    // is that STARTUP must seed our own running device from the persisted list +
    // its own id. The test_guard already cleared the resolver.

    // Spawn the sibling with a pre-seeded SOURCE-ONLY device list (mimics import).
    let sib = spawn_node_full(&relay, M_MASTER, SIB_DEV, &[], Some(&[source_dev.clone()])).await;
    sleep_ms(800).await; // let startup run its resolver self-seed

    // --- THE C5 ASSERTION: the resolver knows BOTH devices → master ---
    // The running sibling device must resolve to the master (NOT itself) — this is
    // what makes `myMaster`/`myDevicesProvider` correct in the panel.
    assert_eq!(
        super::resolver::resolve(&sib_dev), m_master,
        "the freshly-linked running device must resolve to the master at startup (C5)"
    );
    // The source device (from the imported list) also resolves to the master.
    assert_eq!(
        super::resolver::resolve(&source_dev), m_master,
        "the imported source device must resolve to the master"
    );
    // `devices_for(master)` (what `myDevicesProvider` inverts) contains BOTH — so the
    // panel shows two devices, not one.
    let mut devs = super::resolver::devices_for(&m_master);
    devs.sort();
    let mut expected = vec![source_dev.clone(), sib_dev.clone()];
    expected.sort();
    assert_eq!(
        devs, expected,
        "resolver must list BOTH the source and the freshly-linked device for the master (C5)"
    );

    // Keep `sib` alive to the end (its event loop owns the seeded resolver state).
    drop(sib);
}

// ---------------------------------------------------------------------------
// Fix 4 (GAP-A, no-relayer isolation): a plaintext-only lifecycle op fans to the
// actor's OWN sibling DIRECTLY when no other member is online to re-gossip it.
// M has two devices B + C, ALONE in a server (no friend member). B sets a server
// nickname; C must reflect it WITHOUT restart — only possible via the direct
// `fan_to_own_siblings` (the CrdtOpBroadcast re-gossip path has no other member to
// relay through). Guards the 6 plaintext handlers' sibling fan.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sibling_nickname_fans_directly_with_no_relayer() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity, devices B + C. No friend / other member exists.
    const M_MASTER: u8 = 200;
    const B_DEV: u8 = 201;
    const C_DEV: u8 = 202;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    sleep_ms(3000).await;
    drain_events(&mut b);
    drain_events(&mut c);

    // B creates a server; C joins it (sequential — C becomes a CRDT member).
    let server_id = create_server_and_wait(&mut b, "Solo Server").await;
    sleep_ms(500).await;
    c.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let joined = wait_event(&mut c, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "sibling C should join its own identity's server");
    sleep_ms(2000).await;
    drain_events(&mut b);
    drain_events(&mut c);

    // B sets a server nickname for our identity. The ONLY member besides B is C
    // (same identity), so the master-keyed remaining-member broadcast targets
    // nobody — only the direct sibling fan can deliver it to C.
    b.cmd_tx
        .send(NodeCommand::SetNickname {
            server_id: server_id.clone(),
            peer_id: m_master.clone(),
            nickname: "SoloNick".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(1500).await;

    assert_eq!(
        c.server_nickname(&server_id, &m_master), "SoloNick",
        "sibling C must receive the nickname via the DIRECT sibling fan (no relayer present)"
    );
}

// ---------------------------------------------------------------------------
// Fix 2 (tombstone + reconnect reconciliation): a member who was OFFLINE when the
// owner deleted a server must learn it's gone on RECONNECT — via the grow-only
// SyncRequest/SyncResponse path carrying the ServerDeleted tombstone op. Before
// the fix, deletion was a missable one-shot and the offline member kept the server
// forever. The MockRelay does NOT durably queue the (now-removed) one-shot, so this
// test PROVES the tombstone+reconnect path specifically.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn offline_member_reconciles_server_deletion_on_reconnect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner (single device), M = member (single device).
    const O_MASTER: u8 = 210;
    const M_MASTER: u8 = 220;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    sleep_ms(4000).await; // Olm confirm (server join handshake rides it)
    drain_events(&mut o);
    drain_events(&mut m);

    // O creates a server; M joins.
    let server_id = create_server_and_wait(&mut o, "Doomed Server").await;
    sleep_ms(300).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None })
        .await
        .unwrap();
    let joined = wait_event(&mut m, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "member M should join the server");
    sleep_ms(2500).await;
    assert!(m.servers().contains(&server_id), "M holds the server before deletion");

    // --- M goes OFFLINE; O deletes the server ---
    relay.set_online(&m.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);
    o.cmd_tx
        .send(NodeCommand::DeleteServer { server_id: server_id.clone() })
        .await
        .unwrap();
    let o_deleted = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::ServerDeleted { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(o_deleted, "owner O emits ServerDeleted");
    sleep_ms(300).await;
    // O's UI no longer lists it (tombstone hidden) but O RETAINS the shell to serve.
    assert!(!o.servers().contains(&server_id), "O's UI drops the deleted server");

    // --- M comes back ONLINE → reconnect SyncRequest → O serves the tombstone op ---
    drain_events(&mut m);
    relay.set_online(&m.device_id, true);
    let m_saw_delete = wait_event(&mut m, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerDeleted { server_id: sid } if *sid == server_id)
            || matches!(ev, NetworkEvent::MemberLeft { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(m_saw_delete, "M must learn the server was deleted on reconnect (tombstone sync)");
    sleep_ms(500).await;

    // --- THE CORE ASSERTION: M no longer lists the deleted server ---
    assert!(
        !m.servers().contains(&server_id),
        "offline member M must reconcile the deletion on reconnect (server gone), got {:?}",
        m.servers()
    );
}

// ---------------------------------------------------------------------------
// Fix 3 (server CREATE auto-onboards siblings): when one of M's devices creates a
// server, M's OTHER online device must auto-onboard — see the server AND get its own
// MLS leaf (so it can decrypt channel messages). The creator announces the new
// server to siblings (SiblingServerAnnounce), the sibling runs the same-identity
// join fast-path, and the sibling-re-adds / bootstrap path gives it an MLS leaf.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn server_create_auto_onboards_online_sibling() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity, devices B (creator) + C (sibling). No friend needed.
    const M_MASTER: u8 = 230;
    const B_DEV: u8 = 231;
    const C_DEV: u8 = 232;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    sleep_ms(3000).await; // let B↔C meet in the inbox room + Olm settle
    drain_events(&mut b);
    drain_events(&mut c);

    // B creates a server. C is online → should be auto-announced + onboard.
    let server_id = create_server_and_wait(&mut b, "Shared Server").await;
    let general = general_channel_of(&server_id);

    // C learns about the server (ServerJoined) WITHOUT ever calling JoinServer itself.
    let c_onboarded = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(c_onboarded, "sibling C must auto-onboard the newly-created server (ServerJoined)");
    sleep_ms(4000).await; // let C's MLS leaf form (KeyPackage → sibling-re-add → Welcome)

    // C's UI lists the server.
    assert!(
        c.servers().contains(&server_id),
        "sibling C's server list must include the auto-onboarded server, got {:?}",
        c.servers()
    );

    // B's MLS group must contain C's device leaf (so C can decrypt channel messages).
    let b_leaves = b.mls_members(&server_id).await;
    assert!(
        b_leaves.contains(&c.device_id),
        "creator B's MLS group must contain sibling C's leaf, got {b_leaves:?}"
    );

    // --- THE PAYOFF: B sends a channel message; C (auto-onboarded sibling) decrypts it ---
    drain_events(&mut c);
    b.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "hello sibling".to_string(),
            message_id: "sib-ch-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let c_got = wait_event(&mut c, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "hello sibling")
    })
    .await;
    assert!(c_got, "sibling C must decrypt a channel message in the auto-onboarded server");
}
