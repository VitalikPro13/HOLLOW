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
/// from a clean resolver. Each test takes this guard via [`test_guard`]. The
/// guard IS the shared `resolver::test_lock()` — the same lock the resolver /
/// crypto_handler / server_state unit tests take — so no unit test's links can
/// be wiped mid-assert by a harness test's `clear_for_test` (or vice versa).
pub(crate) fn test_guard() -> std::sync::MutexGuard<'static, ()> {
    let g = super::resolver::test_lock();
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
    /// (room_code, channel/topic) -> ring of (sender_device, frame data).
    /// Mirrors the real relay's per-channel topic buffers (relay offline
    /// catch-up): key presence = registered via SetTopicBuffer, inbound
    /// SendToRoomTopic frames tee in, TopicCatchup replays them to the
    /// requester (skipping the requester's own frames). Caps/TTL not modeled.
    topic_buffers: HashMap<(String, String), Vec<(String, Vec<u8>)>>,
    /// nickname -> (claimer device_peer_id, claimer's self-reported master).
    /// Mirrors the relay's temporary-nickname registry. TTL not modeled;
    /// an offline holder resolves as not_found like the real staleness check.
    nicknames: HashMap<String, (String, String)>,
    /// Devices that silently DON'T receive 0x03 room broadcasts (SendToRoom)
    /// while still present in the room. Models the real relay's backpressure
    /// drop on a long-lived socket (uWS returns DROPPED past maxBackpressure
    /// with no error to the sender) — the exact loss mode behind the
    /// join-order MLS epoch race. Presence events and direct frames still
    /// flow, so the victim looks perfectly healthy to everyone.
    broadcast_deaf: HashSet<String>,
    /// Optional load meter (scaling benchmark). When `Some`, every command the
    /// relay handles and every frame the relay DELIVERS to a socket is tallied
    /// here — the ground truth for "what does one server operation cost the
    /// relay + the coordinator". `None` in normal tests (zero overhead).
    meter: Option<RelayMeter>,
}

/// Frame accounting for the scaling benchmark. Counts are cumulative from the
/// last [`MockRelay::reset_meter`]. The distinction that matters:
///   * `*_cmds`  = inbound commands a NODE issued (coordinator/sender-side work).
///   * `deliveries` = outbound frames the RELAY copied to a socket (relay egress
///                    — the O(N) fan-out and the true bandwidth bottleneck).
#[derive(Default, Clone, Debug)]
pub(crate) struct RelayMeter {
    /// SendDirect / SendDirectImage commands issued (the per-device targeted
    /// fan-out — MLS commits/welcomes ride this; O(N) on the coordinator).
    pub send_direct_cmds: u64,
    /// SendToRoom commands issued (single-frame broadcast; O(1) sender work).
    pub send_to_room_cmds: u64,
    /// SendToRoomTopic commands issued (single-frame topic broadcast).
    pub send_topic_cmds: u64,
    /// Total outbound frames the relay actually delivered to a socket, across
    /// ALL command types. This IS relay egress — the bottleneck the relay's
    /// 1 Gbps pipe caps. `bytes_out` weights it by payload size.
    pub deliveries: u64,
    pub bytes_out: u64,
    /// Deliveries attributable to broadcast fan-out (SendToRoom + topic), so we
    /// can separate "one post → N copies" egress from targeted-send egress.
    pub broadcast_deliveries: u64,
    /// Deliveries attributable to targeted SendDirect fan-out (commit/welcome).
    pub direct_deliveries: u64,
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

    /// Enable the load meter (scaling benchmark). Resets counts to zero. After
    /// this, every command + delivery is tallied until [`Self::take_meter`].
    pub(crate) fn reset_meter(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.meter = Some(RelayMeter::default());
    }

    /// Snapshot the current meter (leaves it running). `None` if never enabled.
    pub(crate) fn meter(&self) -> Option<RelayMeter> {
        self.inner.lock().unwrap().meter.clone()
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

    /// Number of frames currently buffered for `peer` in the offline queue. The
    /// relay buffers a direct frame under the TARGET device id when that device
    /// isn't in the room — and (on the real relay) fires a push to that device's
    /// token. So `buffered_count(device) > 0` is the proxy for "this device would
    /// have been woken by a push" (Step 9A: a quit phone must be a buffer target).
    #[allow(dead_code)]
    pub(crate) fn buffered_count(&self, peer: &str) -> usize {
        let inner = self.inner.lock().unwrap();
        inner.offline.get(peer).map(|v| v.len()).unwrap_or(0)
    }

    /// Test-only: deliver a raw frame to `target` as if `from` had sent it in
    /// `room`, bypassing the sender's own node logic — simulates a hostile or
    /// buggy peer pushing an UNSOLICITED protocol message (the real relay
    /// forwards any authed frame; sender honesty is not a transport guarantee).
    #[allow(dead_code)]
    pub(crate) fn inject_direct(&self, room: &str, from: &str, target: &str, data: Vec<u8>) {
        let inner = self.inner.lock().unwrap();
        if let Some(conn) = inner.conns.get(target) {
            let _ = conn.event_tx.send(WsEvent::DirectMessage {
                room: room.to_string(),
                from: from.to_string(),
                data,
            });
        }
    }

    /// Mark a node offline (simulate a disconnect): stop delivering to it, drop
    /// it from every room (broadcasting PeerLeft), so peers see it leave. Its
    /// event loop keeps running but receives nothing until it comes back.
    fn set_online(&self, peer_id: &str, online: bool) {
        self.set_online_inner(peer_id, online, true)
    }

    /// A socket that dies WITHOUT the other members being told.
    ///
    /// The real relay only broadcasts `PeerLeft` for a clean leave. A pulled
    /// adapter or a DNS failure closes the socket with nobody informed, and
    /// the peers keep the dead node in `synced_peers` — so when it comes back
    /// their `is_new` guard reads false and the whole reconnect cascade is
    /// skipped. `set_online(false)` is the POLITE version and cannot reproduce
    /// that. Verified against `hollow_debug.log` 2026-08-27: ZERO `PeerLeft`
    /// lines for a peer that was gone for 26 seconds.
    fn drop_socket_silently(&self, peer_id: &str) {
        self.set_online_inner(peer_id, false, false)
    }

    fn set_online_inner(&self, peer_id: &str, online: bool, announce_leave: bool) {
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
                if was_present && announce_leave {
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

    /// Test inspector: the stored self-reported master for a claimed nickname
    /// (None = nickname unknown).
    pub(crate) fn nickname_master(&self, nickname: &str) -> Option<String> {
        let inner = self.inner.lock().unwrap();
        inner.nicknames.get(nickname).map(|v| v.1.clone())
    }

    /// Make a device deaf to 0x03 room broadcasts (or restore it) — the
    /// silent-loss lever for the join-order MLS epoch race tests. The device
    /// stays in its rooms and keeps receiving presence + direct frames.
    #[allow(dead_code)]
    pub(crate) fn set_broadcast_deaf(&self, peer_id: &str, deaf: bool) {
        let mut inner = self.inner.lock().unwrap();
        if deaf {
            inner.broadcast_deaf.insert(peer_id.to_string());
        } else {
            inner.broadcast_deaf.remove(peer_id);
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
                // Mirror the real ws_client's local leave confirmation (mock
                // nodes bypass ws_client entirely) — the swarm purges the
                // room's peer snapshot on this, closing the stale-room
                // targeted-send blackhole.
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::LeftRoom {
                        room: room_code.clone(),
                    });
                }
            }
            WsCommand::SendToRoom { room_code, data } => {
                if let Some(m) = inner.meter.as_mut() { m.send_to_room_cmds += 1; }
                let n = data.len() as u64;
                let delivered = inner.broadcast_data_except(&room_code, from, WsEvent::Message {
                    room: room_code.clone(),
                    from: from.to_string(),
                    data,
                });
                if let Some(m) = inner.meter.as_mut() {
                    m.deliveries += delivered;
                    m.broadcast_deliveries += delivered;
                    m.bytes_out += delivered * n;
                }
            }
            WsCommand::SendDirect { room_code, target_peer, data }
            | WsCommand::SendDirectImage { room_code, target_peer, data } => {
                if let Some(m) = inner.meter.as_mut() { m.send_direct_cmds += 1; }
                let n = data.len() as u64;
                let delivered = inner.deliver_direct(&room_code, from, &target_peer, data, true);
                if let Some(m) = inner.meter.as_mut() {
                    m.deliveries += delivered;
                    m.direct_deliveries += delivered;
                    m.bytes_out += delivered * n;
                }
            }
            WsCommand::SendBinaryDirect { room_code, target_peer, data } => {
                // Delivered as BinaryDirect when present; not buffered (matches
                // the file/shard streaming path — irrelevant to current tests).
                // Both ends must be in the room: the relay drops a 0x02 whose
                // SENDER never joined, so senders that skip the join must fail
                // here too rather than passing only under the mock.
                let sender_in_room = inner.peer_in_room(&room_code, from);
                let in_room = inner.peer_in_room(&room_code, &target_peer);
                if !sender_in_room { return; }
                if let Some(conn) = inner.conns.get(&target_peer).filter(|c| c.online && in_room) {
                    let _ = conn.event_tx.send(WsEvent::BinaryDirect {
                        room: room_code,
                        from: from.to_string(),
                        data,
                    });
                }
            }
            WsCommand::SendToRoomTopic { room_code, topic, data } => {
                // Tee into the channel's ring buffer when registered (relay
                // offline catch-up), mirroring the real relay.
                let key = (room_code.clone(), topic.clone());
                if let Some(buf) = inner.topic_buffers.get_mut(&key) {
                    buf.push((from.to_string(), data.clone()));
                }
                if let Some(m) = inner.meter.as_mut() { m.send_topic_cmds += 1; }
                let n = data.len() as u64;
                // Simplify topic routing to a plain room broadcast (no test
                // exercises topic filtering yet).
                let delivered = inner.broadcast_except(&room_code, from, WsEvent::Message {
                    room: room_code.clone(),
                    from: from.to_string(),
                    data,
                });
                if let Some(m) = inner.meter.as_mut() {
                    m.deliveries += delivered;
                    m.broadcast_deliveries += delivered;
                    m.bytes_out += delivered * n;
                }
            }
            WsCommand::SetTopicBuffer { room_code, channels, clear, .. } => {
                if clear {
                    inner.topic_buffers.retain(|(r, _), _| r != &room_code);
                } else {
                    for c in channels {
                        inner.topic_buffers.entry((room_code.clone(), c)).or_default();
                    }
                }
            }
            WsCommand::TopicCatchup { room_code, channel_id, .. } => {
                // max_age_secs ignored — the mock doesn't model frame age.
                let frames: Vec<(String, Vec<u8>)> = inner
                    .topic_buffers
                    .get(&(room_code.clone(), channel_id))
                    .map(|v| v.iter().filter(|(s, _)| s != from).cloned().collect())
                    .unwrap_or_default();
                if let Some(conn) = inner.conns.get(from).filter(|c| c.online) {
                    for (sender, data) in frames {
                        let _ = conn.event_tx.send(WsEvent::Message {
                            room: room_code.clone(),
                            from: sender,
                            data,
                        });
                    }
                }
            }
            WsCommand::DiscoverPeers { room_code } => {
                // Members only, like the relay — discovery is not a roster dump
                // for any room code you happen to know.
                let peers: Vec<String> = inner
                    .rooms
                    .get(&room_code)
                    .filter(|s| s.contains(from))
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
                // The relay no longer answers the room-activity probe (it let
                // anyone holding two peer_ids test whether their deterministic
                // DM room was live), so nothing may depend on a reply here.
                let _ = rooms;
                let active_rooms: Vec<String> = Vec::new();
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::PeerStatus { online, active_rooms });
                }
            }
            WsCommand::ClaimNickname { nickname, master } => {
                // Auto-release any old binding of this claimer (like the relay).
                inner.nicknames.retain(|_, v| v.0 != from);
                inner.nicknames.insert(nickname.clone(), (from.to_string(), master));
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::NicknameClaimed { nickname });
                }
            }
            WsCommand::ReleaseNickname => {
                inner.nicknames.retain(|_, v| v.0 != from);
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::NicknameReleased);
                }
            }
            WsCommand::ResolveNickname { nickname } => {
                // An offline holder resolves as not_found (the real relay's
                // dead-holder staleness check).
                let hit = inner.nicknames.get(&nickname).and_then(|(dev, master)| {
                    let online =
                        inner.conns.get(dev).map(|c| c.online).unwrap_or(false);
                    online.then(|| (dev.clone(), master.clone()))
                });
                let ev = match hit {
                    Some((dev, master)) => WsEvent::NicknameResolved {
                        nickname,
                        peer_id: dev,
                        master_id: master,
                    },
                    None => WsEvent::NicknameError {
                        error: "not_found".to_string(),
                        nickname,
                    },
                };
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(ev);
                }
            }
            // Channel-direct offline push, linkcode/push registries: not
            // needed for the current tests — no-op (add when a test does).
            _ => {}
        }
    }
}

impl RelayInner {
    fn peer_in_room(&self, room: &str, peer: &str) -> bool {
        self.rooms.get(room).map(|s| s.contains(peer)).unwrap_or(false)
    }

    /// [`Self::broadcast_except`] for 0x03 DATA frames: additionally skips
    /// `broadcast_deaf` devices (the backpressure-drop lever). Presence events
    /// keep using `broadcast_except` directly — the real relay's drop hits
    /// data frames on a wedged socket, not the membership protocol.
    fn broadcast_data_except(&self, room: &str, from: &str, event: WsEvent) -> u64 {
        let members: Vec<String> = self
            .rooms
            .get(room)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default();
        let mut delivered = 0u64;
        for m in members {
            if m == from || self.broadcast_deaf.contains(&m) {
                continue;
            }
            if let Some(conn) = self.conns.get(&m).filter(|c| c.online) {
                let _ = conn.event_tx.send(event.clone());
                delivered += 1;
            }
        }
        delivered
    }

    /// Broadcast to every online room member except the sender. Returns the
    /// number of frames actually delivered to a socket (the relay egress for
    /// this one command — this is the O(N) fan-out the benchmark measures).
    fn broadcast_except(&self, room: &str, from: &str, event: WsEvent) -> u64 {
        let members: Vec<String> = self
            .rooms
            .get(room)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default();
        let mut delivered = 0u64;
        for m in members {
            if m == from {
                continue; // no self-echo (matches relay)
            }
            if let Some(conn) = self.conns.get(&m).filter(|c| c.online) {
                let _ = conn.event_tx.send(event.clone());
                delivered += 1;
            }
        }
        delivered
    }

    /// Deliver (or buffer) a direct frame. Returns 1 if it was delivered to a
    /// live socket, 0 if buffered offline (no egress now).
    fn deliver_direct(&mut self, room: &str, from: &str, target: &str, data: Vec<u8>, direct: bool) -> u64 {
        let online = self.conns.get(target).map(|c| c.online).unwrap_or(false);
        if online && self.peer_in_room(room, target) {
            if let Some(conn) = self.conns.get(target) {
                let _ = conn.event_tx.send(WsEvent::DirectMessage {
                    room: room.to_string(),
                    from: from.to_string(),
                    data,
                });
            }
            return 1;
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
            0
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
    /// the shell to serve the deletion op, but the UI list excludes it — and so is a
    /// non-empty-membership shell we're no longer a member of (left/kicked; a legacy
    /// pre-teardown DB may still hold one).
    pub(crate) fn servers(&self) -> Vec<String> {
        self.store()
            .load_all_servers()
            .unwrap_or_default()
            .into_iter()
            .filter(|(_, json)| {
                serde_json::from_str::<ServerState>(json)
                    .map(|s| {
                        !s.is_deleted()
                            && (s.members.is_empty() || s.is_member(&self.master_id))
                    })
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

    /// A server setting as the UI reads it via `get_server_setting`
    /// (None = never set).
    pub(crate) fn server_setting(&self, server_id: &str, key: &str) -> Option<String> {
        self.server_state(server_id)?
            .settings
            .get(key)
            .map(|r| r.read().clone())
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

    /// A channel's visibility tier as the UI reads it via `get_server_channels`
    /// ("everyone" | "moderator" | "admin"). This is the exact value
    /// `visibleChannelsProvider` filters on — green here == the UI would hide/show
    /// correctly. None if the channel/server is unknown.
    pub(crate) fn channel_visibility(&self, server_id: &str, channel_id: &str) -> Option<String> {
        let state = self.server_state(server_id)?;
        let ch = state.channels.get(channel_id)?;
        Some(match ch.visibility {
            crate::crdt::server_state::ChannelVisibility::Everyone => "everyone",
            crate::crdt::server_state::ChannelVisibility::ModeratorPlus => "moderator",
            crate::crdt::server_state::ChannelVisibility::AdminPlus => "admin",
        }.to_string())
    }

    /// A channel's posting tier as the UI reads it ("everyone"|"moderator"|"admin").
    /// Mirrors `canPostInChannelProvider`'s channel-mode input. None if unknown.
    pub(crate) fn channel_posting(&self, server_id: &str, channel_id: &str) -> Option<String> {
        let state = self.server_state(server_id)?;
        let ch = state.channels.get(channel_id)?;
        Some(match ch.posting {
            crate::crdt::server_state::ChannelPosting::Everyone => "everyone",
            crate::crdt::server_state::ChannelPosting::ModeratorPlus => "moderator",
            crate::crdt::server_state::ChannelPosting::AdminPlus => "admin",
        }.to_string())
    }

    /// A channel's slow-mode interval (seconds, 0 = off) as the UI reads it.
    pub(crate) fn channel_slow_mode(&self, server_id: &str, channel_id: &str) -> Option<u32> {
        let state = self.server_state(server_id)?;
        Some(state.channels.get(channel_id)?.slow_mode)
    }

    /// A channel's visibility label gate (label ids; empty = no gate). None
    /// if the channel/server is unknown.
    pub(crate) fn channel_visibility_labels(&self, server_id: &str, channel_id: &str) -> Option<Vec<String>> {
        let state = self.server_state(server_id)?;
        Some(state.channels.get(channel_id)?.visibility_labels.clone())
    }

    /// A channel's posting label gate (label ids; empty = no gate).
    pub(crate) fn channel_posting_labels(&self, server_id: &str, channel_id: &str) -> Option<Vec<String>> {
        let state = self.server_state(server_id)?;
        Some(state.channels.get(channel_id)?.posting_labels.clone())
    }

    /// The label ids assigned to a member (raw master-keyed lookup, sorted).
    pub(crate) fn member_label_ids(&self, server_id: &str, master: &str) -> Vec<String> {
        let mut ids = self
            .server_state(server_id)
            .and_then(|s| s.label_assignments.get(master).cloned())
            .unwrap_or_default();
        ids.sort();
        ids
    }

    /// A label's access flag (None = label unknown).
    pub(crate) fn label_access(&self, server_id: &str, label_id: &str) -> Option<bool> {
        self.server_state(server_id)?
            .labels
            .get(label_id)
            .map(|l| l.access)
    }

    /// Whether `peer` holds an unexpired temporary grant for the channel
    /// RIGHT NOW — the moving part `can_see_channel`/`can_post_in_channel`
    /// evaluate (mirrors `is_muted_now`).
    pub(crate) fn has_grant_now(&self, server_id: &str, channel_id: &str, peer: &str) -> bool {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        self.server_state(server_id)
            .map(|s| s.has_channel_grant(peer, channel_id, now))
            .unwrap_or(false)
    }

    /// A channel's media-only flag as the UI reads it.
    pub(crate) fn channel_media_only(&self, server_id: &str, channel_id: &str) -> Option<bool> {
        let state = self.server_state(server_id)?;
        Some(state.channels.get(channel_id)?.media_only)
    }

    /// Whether `peer` is muted RIGHT NOW per this node's CRDT state — exactly
    /// the predicate the send/ingest moderation gates evaluate.
    pub(crate) fn is_muted_now(&self, server_id: &str, peer: &str) -> bool {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        self.server_state(server_id)
            .map(|s| s.is_muted(peer, now))
            .unwrap_or(false)
    }

    /// Whether this node's local user can SEE a channel — exactly what
    /// `visibleChannelsProvider` computes (role tier vs channel visibility). The
    /// UI hides the channel + evicts the user when this flips to false.
    pub(crate) fn can_see_channel(&self, server_id: &str, channel_id: &str, me: &str) -> bool {
        self.server_state(server_id)
            .map(|s| s.can_see_channel(me, channel_id))
            .unwrap_or(false)
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

    /// The RAW `sender_id` a channel message row is stored under (NOT collapsed
    /// device→master like `channel_messages`). In a correct multi-device world a
    /// channel message's stored sender is the sender's MASTER (the bubble keys on
    /// it); if a sender DEVICE id leaks in here, the receive path stored it
    /// unresolved — a bug the master-collapsed `channel_messages` inspector hides
    /// (it resolves on read). None if no such message id is stored.
    pub(crate) fn raw_channel_message_sender(&self, message_id: &str) -> Option<String> {
        self.store().get_channel_message_sender(message_id)
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
        // 5s, not 2: under a full parallel run the event loop is busy and a
        // 2s round trip timed out, which `olm_status` then reports as "absent"
        // and `mls_members` as an empty group. Both read as real state.
        tokio::time::timeout(std::time::Duration::from_secs(5), rx)
            .await
            .ok()?
            .ok()
    }

    /// The MLS group's leaf DEVICE ids for `server_id` (raw, device-keyed — the
    /// truth under the master-keyed member panel). Empty if no group / no reply.
    /// `mls_members`, but telling "the loop did not reply" (None) apart from
    /// "the group holds no such leaf" (Some). An EVICTION wait must use this: a
    /// timed-out snapshot yields an empty list, which reads exactly like a
    /// successful removal and would pass the test without the eviction ever
    /// having happened.
    pub(crate) async fn mls_members_checked(&self, group_id: &str) -> Option<Vec<String>> {
        let mut v = self.debug_snapshot().await?.mls_members.get(group_id).cloned().unwrap_or_default();
        v.sort();
        Some(v)
    }

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

    /// Revocation tombstones this node has PERSISTED for `master` (Step 7).
    /// Empty when no signed device list is stored yet. This is the settle
    /// signal that a peer durably ingested a revocation — both the sender-side
    /// device targeting and the receive-side is_revoked guard read this list.
    pub(crate) fn revoked_devices(&self, master: &str) -> Vec<String> {
        self.store()
            .load_device_list(master)
            .ok()
            .flatten()
            .map(|l| l.revoked)
            .unwrap_or_default()
    }

    /// Active device ids this node has PERSISTED for `master`. Empty until a
    /// signed device list for that identity has been ingested.
    pub(crate) fn known_devices(&self, master: &str) -> Vec<String> {
        self.store()
            .load_device_list(master)
            .ok()
            .flatten()
            .map(|l| l.devices)
            .unwrap_or_default()
    }

    /// Security alerts this node has recorded (Issue 1-C). The DB is the dedup
    /// authority, so this is the assertion surface for "warned exactly once".
    pub(crate) fn security_alerts(&self) -> Vec<crate::storage::messages::SecurityAlertRow> {
        self.store().get_security_alerts().unwrap_or_default()
    }

    /// Friend-table status for a person (master-keyed): "accepted", "pending",
    /// or None if no row exists. Used by the reject/mutual-request tests.
    pub(crate) fn friend_status(&self, master: &str) -> Option<String> {
        self.store().get_friend_status(master).ok().flatten()
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

/// Spawn a node on a db_path the CALLER already created and pre-seeded (and owns
/// the backing `tmp`). Unlike `spawn_node_full`, this does NOT create or seed the
/// DB — it boots `spawn_node_mock` directly on the given path, so the test can
/// stage arbitrary on-disk state (e.g. a device-keyed friend row + a friend's
/// device list) and exercise the real startup code against it. The caller must
/// have already run `migrate_auto_vacuum_once` and saved an Olm account.
async fn spawn_node_on_db(
    relay: &MockRelay,
    master_tag: u8,
    device_tag: u8,
    db_path: &str,
    tmp: tempfile::TempDir,
) -> TestNode {
    let master = NativeKeypair::from_secret_bytes(&seed_bytes(master_tag));
    let device = NativeKeypair::from_secret_bytes(&seed_bytes(device_tag));
    let passphrase = passphrase_for(&master);
    let db_path = db_path.to_string();

    // Ensure an Olm account exists (spawn_node_mock expects one), without touching
    // any friend/device-list rows the caller staged.
    let olm = {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase).expect("open store");
        let mgr = OlmManager::new();
        if store.load_olm_account().ok().flatten().is_none() {
            let pickle = mgr.account_pickle_json().expect("pickle");
            store.save_olm_account(&pickle).expect("save olm");
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

/// Poll `cond` until it holds, or `secs` elapse. Returns whether it held.
///
/// **This is the default settle primitive, not `sleep_ms`.** A fixed sleep has
/// to be long enough for the slowest machine that will ever run it, so it is
/// dead time on every other machine AND a silent flake on the one where it
/// turned out not to be long enough: the assert that follows just fails, with
/// no hint that time was the problem. Polling finishes the moment the thing has
/// actually happened, usually two orders of magnitude sooner, and when it does
/// not happen it says so.
///
/// Reach for `sleep_ms` ONLY to prove an ABSENCE ("wait a window, then assert
/// nothing arrived"). There is no state to poll for something that must never
/// happen, so that window has to be real time. Everything else has a condition,
/// and `TestNode` exposes it.
///
/// POLL LIVE STATE, NEVER A RUNNING NODE'S DB. `olm_status`, `mls_members` and
/// `mls_epoch` round-trip a `DebugSnapshot` over the node's own channel and are
/// free to ask repeatedly. Everything else here (`servers`, `server_state` and
/// so everything built on it: `channel_visibility`, `can_see_channel`,
/// `has_grant_now`, `known_devices`) calls `store()`, which opens a NEW
/// SQLCipher connection each time. Asking on a loop starves the node's own
/// writer, which waits `busy_timeout = 4000`ms for locks the test keeps taking:
/// a 250ms poll for a channel-row heal stopped it landing inside 15s where a
/// plain sleep saw it in under 4. If the only settle signal is on disk, use a
/// sleep and say why.
async fn wait_until(secs: u64, mut cond: impl AsyncFnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(secs);
    // Backs off 25ms -> 250ms. Some predicates here open SQLCipher, whose key
    // derivation is deliberately expensive, so a flat 25ms poll would spend more
    // CPU on the KDF than the thing being waited for.
    let mut interval = 25;
    loop {
        if cond().await {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        sleep_ms(interval).await;
        interval = (interval * 2).min(250);
    }
}

/// Sleep until a wall-clock DEADLINE (plus `grace_ms`), not for a duration.
///
/// Use this wherever a test has to outlast a real timestamp: a grant expiry, a
/// TTL, a sweep window. The duration form silently depends on how long the steps
/// ABOVE happened to take, which is fine right up until those steps stop
/// sleeping a fixed amount and start finishing as soon as their condition holds.
/// `channel_grant_expiry_sweep` failed exactly that way: its "now ~= 11s after
/// the grant" sleep was sized against 6s of fixed sleeps that had just become
/// 1.5s of polling, so it woke up BEFORE the grant it was waiting to expire.
async fn sleep_until_ms(deadline_ms: u64, grace_ms: u64) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    sleep_ms(deadline_ms.saturating_sub(now) + grace_ms).await;
}

/// Wait until `a` and `b` hold a CONFIRMED Olm session with each other, and
/// panic with both directions' status if they do not.
///
/// Replaces the `sleep_ms(4000)` that stood at the top of every test whose
/// payloads ride Olm. Bidirectional on purpose: an outbound-only session is not
/// usable yet and deliberately does not count (see the comment at swarm.rs:92),
/// which is exactly the half-built state a too-short fixed sleep left behind.
async fn expect_olm_confirmed(a: &TestNode, b: &TestNode, secs: u64) {
    let ok = wait_until(secs, async || {
        a.olm_status(&b.device_id).await == "confirmed"
            && b.olm_status(&a.device_id).await == "confirmed"
    })
    .await;
    assert!(
        ok,
        "Olm never confirmed both ways within {}s: {} -> {} is {:?}, {} -> {} is {:?}",
        secs,
        a.device_id,
        b.device_id,
        a.olm_status(&b.device_id).await,
        b.device_id,
        a.device_id,
        b.olm_status(&a.device_id).await,
    );
}

/// Wait until a freshly spawned friend PAIR is actually usable: confirmed Olm
/// both ways, AND both devices present in the DM room their traffic rides.
///
/// This is what the `sleep_ms(4000)` after a friend-pair spawn was really
/// covering, and waiting only for the Olm session is not enough. The session
/// confirms well before both nodes have finished joining their rooms, so tests
/// converted to Olm-only started sending into a room the recipient had not
/// joined yet: `dm_file_transfer_completes_and_decrypts` and
/// `dm_relay_buffer_delivers_after_sender_goes_offline_and_clears` both went
/// intermittent, once hard-failing twice in a row. A sleep that "waits for Olm"
/// is rarely waiting only for Olm, which is the whole hazard in replacing one
/// with a narrower condition.
async fn expect_dm_pair_ready(relay: &MockRelay, a: &TestNode, b: &TestNode, secs: u64) {
    expect_olm_confirmed(a, b, secs).await;
    let room = super::types::dm_room_code(&a.master_id, &b.master_id);
    let ok = wait_until(secs, async || {
        let members = relay.room_devices(&room);
        members.contains(&a.device_id) && members.contains(&b.device_id)
    })
    .await;
    assert!(
        ok,
        "{} and {} never both joined DM room {} within {}s, got {:?}",
        a.device_id,
        b.device_id,
        room,
        secs,
        relay.room_devices(&room),
    );
}

/// Wait until `holder`'s MLS group for `group_id` carries `leaf`'s device, and
/// panic with the leaf list if it never does. `group_id` is a `server_id` for
/// the server-wide group, or `subgroup_id(server, channel)` for a per-channel
/// one. Replaces "let the MLS leaf form" sleeps: KeyPackage -> add -> Welcome is
/// a round trip whose duration is a property of the machine, not of the code.
async fn expect_mls_leaf(holder: &TestNode, group_id: &str, leaf: &str, secs: u64) {
    let ok = wait_until(secs, async || {
        holder.mls_members(group_id).await.iter().any(|m| m == leaf)
    })
    .await;
    assert!(
        ok,
        "MLS group {} on {} never gained leaf {} within {}s, got {:?}",
        group_id,
        holder.device_id,
        leaf,
        secs,
        holder.mls_members(group_id).await,
    );
}

/// Wait until EVERY node in `nodes` sees EVERY node's leaf in `group_id`, which
/// is what "the server-wide group has formed" actually means: one member's view
/// converging says nothing about the others'.
/// Wait until `holder`'s MLS group for `group_id` no longer carries `leaf`.
/// An eviction is a convergence like any other, not an absence: the leaf is gone
/// once the commit that removed it has been applied, and that is observable, so
/// it gets polled rather than slept on.
async fn expect_no_mls_leaf(holder: &TestNode, group_id: &str, leaf: &str, secs: u64) {
    let ok = wait_until(secs, async || {
        // Some(..) required: a snapshot that never came back is not an eviction.
        matches!(holder.mls_members_checked(group_id).await, Some(v) if !v.iter().any(|m| m == leaf))
    })
    .await;
    assert!(
        ok,
        "MLS group {} on {} never dropped leaf {} within {}s, got {:?}",
        group_id,
        holder.device_id,
        leaf,
        secs,
        holder.mls_members(group_id).await,
    );
}

async fn expect_mls_group(nodes: &[&TestNode], group_id: &str, secs: u64) {
    for holder in nodes {
        for leaf in nodes {
            expect_mls_leaf(holder, group_id, &leaf.device_id, secs).await;
        }
    }
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

    // Olm key exchange (KeyRequest/KeyBundle/SessionAck over SendDirect) must
    // FULLY CONFIRM between A and the live devices before any DM is sent, or the
    // DM rides an unconfirmed ratchet and fails to decrypt. Glare resolution
    // takes a couple of round trips, so this waits for the sessions themselves
    // rather than guessing how long the round trips take.
    expect_dm_pair_ready(&relay, &a, &b, 20).await;
    expect_dm_pair_ready(&relay, &a, &c, 20).await;
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
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
// PUBLIC-channel multi-device attribution (UI device→master collapse, 2026-06-24).
// A PUBLIC channel broadcasts signed PLAINTEXT (no MLS), and the relay frame's
// `from` is the sender's DEVICE id. Before the fix, the PublicChannelMessage
// handler passed that raw device id straight to handle_envelope_channel_message,
// so the message was attributed to + stored under the DEVICE — the bubble showed
// "12D3KooW…" instead of the sender's name (while the MLS path already resolved
// to master). It also broke signature verification (the sender SIGNS with its
// master id). This asserts the fix: the receiver attributes a public-channel
// message from a device!=master sender to that sender's MASTER, in BOTH the live
// event (`from_peer`) AND the raw stored row (NOT just the master-collapsed
// inspector, which would hide a device-keyed row by resolving on read).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn public_channel_message_from_multidevice_sender_attributes_to_master() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner/sender, J = joiner. BOTH are real fresh installs (device != master,
    // the shape every fresh friend has since ad7b49e). Resolver NOT pre-seeded —
    // J must learn O's device→master purely from the organic friend handshake, so
    // resolving the relay frame's device `from` to O's master is a real lookup.
    const O_MASTER: u8 = 50;
    const O_DEV: u8 = 51;
    const J_MASTER: u8 = 52;
    const J_DEV: u8 = 53;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let o_dev = NativeKeypair::from_secret_bytes(&seed_bytes(O_DEV)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();
    let j_dev = NativeKeypair::from_secret_bytes(&seed_bytes(J_DEV)).peer_id();
    // Precondition: meaningless unless the sender's device != master.
    assert_ne!(o_dev, o_master, "O must be a real fresh install (device != master)");
    assert_ne!(j_dev, j_master, "J must be a real fresh install (device != master)");

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_DEV, &[]).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // Organic friend handshake O <-> J (drives the device-list/profile pushes both
    // directions, warming J's resolver with O_DEV → O_MASTER and vice versa).
    o.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: j_master.clone() })
        .await
        .unwrap();
    let j_got_req = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(j_got_req, "J must receive O's friend request");
    j.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: o_master.clone() })
        .await
        .unwrap();
    // Let accept + device-list/profile pushes + Olm key exchange settle.
    expect_dm_pair_ready(&relay, &o, &j, 15).await;
    // ...and J's resolver has learned O's device -> master mapping, which is
    // the precondition the assertion below states.
    wait_until(15, async || super::resolver::resolve(&o_dev) == o_master).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // Precondition: J's resolver maps O's device → O's master. Without this, the
    // resolve in the PublicChannelMessage handler is a no-op and the test can't
    // distinguish the fix.
    assert_eq!(
        super::resolver::resolve(&o_dev), o_master,
        "J's resolver must map O's device → O's master after the friend handshake"
    );

    // O creates a server (+ implicit #general); J joins (forms the shared room so a
    // SendToRoom public broadcast reaches J).
    let server_id = create_server_and_wait(&mut o, "Public Test Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await; // let membership + the shared server room settle

    // O makes #general PUBLIC (plaintext broadcast path, no MLS).
    o.cmd_tx
        .send(NodeCommand::SetChannelPublic {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            is_public: true,
        })
        .await
        .unwrap();
    sleep_ms(2000).await; // let the ChannelPublicChanged CRDT op converge to J
    drain_events(&mut j);

    // --- THE PAYOFF: O sends a PUBLIC channel message from its DEVICE; J must
    // attribute it to O's MASTER (not O_DEV) ---
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "public from a device".to_string(),
            message_id: "pub-md-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();

    // Live event: from_peer is the raw value handle_envelope_channel_message was
    // called with — O's MASTER with the fix, O_DEV without it.
    let attributed_to_master = wait_event(&mut j, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, from_peer, .. }
            if text == "public from a device" && *from_peer == o_master)
    })
    .await;
    assert!(
        attributed_to_master,
        "J must receive the public channel message attributed to O's MASTER ({o_master}), not O's device ({o_dev})"
    );
    sleep_ms(200).await;

    // Raw layer (device-keyed truth): the stored row's sender is O's MASTER. This
    // is the assertion the master-collapsed `channel_messages` inspector can't make
    // — it resolves device→master on read and would pass even on a device-keyed row.
    assert_eq!(
        j.raw_channel_message_sender("pub-md-1").as_deref(),
        Some(o_master.as_str()),
        "the stored public-channel row must be MASTER-keyed (raw), not device-keyed"
    );
    // And the channel-pane inspector agrees (is_mine=false on the receiver).
    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "public from a device").expect("public message stored");
    assert_eq!(row.sender_master, o_master, "public channel message attributed to O's master");
    assert!(!row.is_mine, "received public message is not is_mine on J");
}

// ---------------------------------------------------------------------------
// Relay connection status (Item 1939): a node emits a real RelayConnected event
// once its WS connection is up — the signal the UI uses to show a truthful
// "Connected" instead of the stale "node started" status.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn node_emits_relay_connected_on_ws_connect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    let mut n = spawn_node_with_friends(&relay, 110, 110, &[]).await;

    let connected = wait_event(&mut n, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::RelayConnected)
    })
    .await;
    assert!(connected, "node must emit RelayConnected once its WS link is up");
}

// ---------------------------------------------------------------------------
// NSFW join-consent gate: an NSFW-flagged server rejects a first join attempt
// with an `nsfw_confirm:` reason (carried on TwitchJoinRejected, the shared
// join-reject event), then accepts the retry that carries nsfw_confirmed=true.
// This guards Item 1941 — the server-side reject-then-retry consent flow that
// every join entry point rides for free.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn nsfw_server_gates_join_until_confirmed() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 90;
    const J_MASTER: u8 = 100;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    // Owner creates a server and flags it NSFW via the settings CRDT.
    let server_id = create_server_and_wait(&mut o, "Adult Server").await;
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "is_nsfw".to_string(),
            value: "true".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(500).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // First join attempt (no consent) → rejected with the nsfw_confirm reason.
    j.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let rejected = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::TwitchJoinRejected { server_id: sid, reason }
            if *sid == server_id && reason.starts_with("nsfw_confirm:"))
    })
    .await;
    assert!(rejected, "first NSFW join must be rejected with nsfw_confirm:");

    // The joiner did NOT become a member.
    assert!(
        !j.raw_crdt_member_keys(&server_id).contains(&j_master),
        "joiner must not be a member before confirming NSFW consent"
    );
    drain_events(&mut j);

    // Retry WITH consent → join completes.
    j.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: true,
        })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join after confirming NSFW consent");
    sleep_ms(500).await;
    assert!(
        j.raw_crdt_member_keys(&server_id).contains(&j_master),
        "joiner is a member after confirming NSFW consent"
    );
}

// ---------------------------------------------------------------------------
// Channel typing indicator round-trips over the MLS server group and is
// attributed to the sender's MASTER identity on the receiver. Guards the path
// behind the mobile fix where a phone never SENT channel typing (Dart only
// called sendTypingIndicator for DMs) — here we drive the Rust send/receive
// directly to prove the channel-typing wire path is correct end to end, and
// that TypingStarted carries the master (not the device id), which is what the
// UI keys its "X is typing…" on.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_typing_roundtrips_master_attributed() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner (single device), J = joiner (single device).
    const O_MASTER: u8 = 70;
    const J_MASTER: u8 = 80;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    // Owner creates a server, joiner joins, MLS group forms across both.
    let server_id = create_server_and_wait(&mut o, "Typing Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should emit ServerJoined");
    // Give the MLS KeyPackage → batch timer → Welcome handshake time to form the group.
    sleep_ms(5000).await;
    assert_eq!(
        o.mls_epoch(&server_id).await,
        j.mls_epoch(&server_id).await,
        "owner and joiner must be at the same MLS epoch before typing"
    );
    drain_events(&mut j);

    // --- Owner types in #general; joiner receives TypingStarted for the MASTER ---
    o.cmd_tx
        .send(NodeCommand::SendTypingIndicator {
            server_id: server_id.clone(),
            channel_id: general.clone(),
        })
        .await
        .unwrap();

    let o_master_for_pred = o_master.clone();
    let general_for_pred = general.clone();
    let server_for_pred = server_id.clone();
    let got = wait_event(&mut j, std::time::Duration::from_secs(5), move |ev| {
        matches!(
            ev,
            NetworkEvent::TypingStarted { peer_id, server_id: sid, channel_id: cid }
                if *peer_id == o_master_for_pred
                    && *sid == server_for_pred
                    && *cid == general_for_pred
        )
    })
    .await;
    assert!(
        got,
        "joiner must receive a channel TypingStarted attributed to the owner's master \
         ({o_master}) for {server_id}/{general}"
    );
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

    // Let Olm sessions confirm all around (A↔B, A↔C, B↔C siblings). Poll until
    // every direction is CONFIRMED instead of a fixed sleep — under llvm-cov
    // instrumentation / full-suite parallel load the handshakes take far longer
    // than 5s, and revocation traffic sent over a half-established (glare)
    // session decrypts to "invalid MAC", so the tombstone silently never lands.
    // Early-exits as soon as everything is confirmed (~2-5s uncontended).
    let mut olm_ok = false;
    for _ in 0..60 {
        sleep_ms(500).await;
        if a.olm_status(&b.device_id).await == "confirmed"
            && a.olm_status(&c.device_id).await == "confirmed"
            && b.olm_status(&a.device_id).await == "confirmed"
            && b.olm_status(&c.device_id).await == "confirmed"
            && c.olm_status(&a.device_id).await == "confirmed"
            && c.olm_status(&b.device_id).await == "confirmed"
        {
            olm_ok = true;
            break;
        }
    }
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);
    assert!(
        olm_ok,
        "all Olm sessions (A↔B, A↔C, B↔C) must confirm before the revocation \
         (a↔b {}/{}, a↔c {}/{}, b↔c {}/{})",
        a.olm_status(&b.device_id).await,
        b.olm_status(&a.device_id).await,
        a.olm_status(&c.device_id).await,
        c.olm_status(&a.device_id).await,
        b.olm_status(&c.device_id).await,
        c.olm_status(&b.device_id).await,
    );

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

    // The revoker B emits DeviceListUpdated. Generous window (early-exit on
    // success) — instrumented CI stretches the revoke round-trip.
    let b_updated = wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
        matches!(ev, NetworkEvent::DeviceListUpdated { .. })
    })
    .await;
    assert!(b_updated, "revoker B should emit DeviceListUpdated");

    // The revoked device C receives the tombstone (ProfileUpdate to it FIRST) and
    // emits SelfRevoked — the trigger for the Dart-side data wipe.
    let c_nuked = wait_event(&mut c, std::time::Duration::from_secs(20), |ev| {
        matches!(ev, NetworkEvent::SelfRevoked)
    })
    .await;
    assert!(c_nuked, "revoked device C should emit SelfRevoked");

    // B's Olm session to C is torn down (enforce_device_revocations). The drop
    // runs async after the revoke command — poll instead of a fixed sleep.
    let mut b_dropped = false;
    for _ in 0..40 {
        sleep_ms(500).await;
        if b.olm_status(&c.device_id).await == "absent" {
            b_dropped = true;
            break;
        }
    }
    assert!(
        b_dropped,
        "B must drop its Olm session to the revoked device C (still {:?})",
        b.olm_status(&c.device_id).await
    );

    // Friend A must durably ingest the revocation (B re-broadcasts the signed
    // list to friends so they stop encrypting to the revoked device) BEFORE the
    // post-revoke DM is sent — under load the tombstone propagation lags, and
    // sending early races A's collect_target_devices against the ingest. Poll
    // A's PERSISTED list for the tombstone (the exact state the sender-side
    // device targeting reads).
    let mut a_ingested = false;
    for _ in 0..60 {
        sleep_ms(500).await;
        if a.revoked_devices(&m_master).iter().any(|d| *d == c.device_id) {
            a_ingested = true;
            break;
        }
    }
    assert!(
        a_ingested,
        "friend A must ingest + persist the revocation tombstone for C before \
         the post-revoke DM (got revoked={:?})",
        a.revoked_devices(&m_master)
    );

    // --- Ghost fan-out guard: C self-nukes → disconnect; a later DM must NOT
    // reach it. Simulate C's disconnect (the real device wipes + drops its socket). ---
    relay.set_online(&c.device_id, false);
    // Let A/B process the peer_left broadcast (the load-bearing settle — A's
    // tombstone ingest — was already confirmed above).
    sleep_ms(1000).await;
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
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "after-revoke")
    })
    .await;
    assert!(b_got, "live device B should still receive the friend's DM");

    // …and C (revoked + offline) must NOT — its thread stays empty of the post-revoke
    // message even after coming back online (it's dropped from the room, never
    // targeted, and the receive-side is_revoked guard drops any stray delivery).
    // Generous dwell: a NEGATIVE assert only gets stronger the longer we wait,
    // and under load a stray buffered delivery would land late.
    relay.set_online(&c.device_id, true);
    sleep_ms(2500).await;
    let c_thread = c.dm_thread(&a.master_id);
    assert!(
        !c_thread.iter().any(|m| m.text == "after-revoke"),
        "revoked device C must NOT receive the post-revocation DM (ghost fan-out guard), got {:?}",
        c_thread.iter().map(|m| &m.text).collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------
// Issue 1-C: "a NEW DEVICE appeared for this contact" must reach the friend as a
// visible alert — that is the real-world attack shape (a device linked to a
// compromised account), and it is detectable only because the device list is
// master-signed and already ingested + verified.
//
// The distributed part is what makes this worth a harness test rather than a
// unit test: the alert has to be driven by a device list that genuinely
// propagated over the wire, and it must NOT fire on the FIRST list a friend ever
// sees (that is a baseline, not a change — an alert there would fire for every
// new friend and train users to dismiss without reading).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn friend_is_warned_when_a_new_device_joins_their_contact() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = the friend who should be warned. M = the contact, devices B then C.
    const A_MASTER: u8 = 110;
    const M_MASTER: u8 = 120;
    const B_DEV: u8 = 121;
    const C_DEV: u8 = 122;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    // A and M's first device B come up and become friends.
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;

    // B publishes a device list of {B}. A ingests it as its BASELINE for M.
    seed_device_list_into_db(&b.db_path, &b.passphrase, M_MASTER, &[b_dev.clone()]);

    let mut a_saw_b = false;
    for _ in 0..40 {
        sleep_ms(500).await;
        if a.known_devices(&m_master).iter().any(|d| *d == b_dev) {
            a_saw_b = true;
            break;
        }
    }
    assert!(
        a_saw_b,
        "A should ingest M's first device list (got {:?})",
        a.known_devices(&m_master)
    );

    // FIRST contact must be silent. Assert against the DB, not the event
    // channel: the store write is the dedup authority, so an empty table is the
    // real proof that nothing was raised.
    assert!(
        a.security_alerts().is_empty(),
        "the first device list for a contact is a baseline, not a warning (got {:?})",
        a.security_alerts().iter().map(|r| r.kind.clone()).collect::<Vec<_>>()
    );
    drain_events(&mut a);

    // --- M links a SECOND device, C. ---
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;

    // A must now be warned — once, naming the device that appeared.
    let warned = wait_event(&mut a, std::time::Duration::from_secs(30), |ev| {
        matches!(
            ev,
            NetworkEvent::SecurityAlert { peer_id, kind, detail, .. }
                if peer_id == &m_master
                    && kind == super::security_alerts::KIND_NEW_DEVICE
                    && detail == &c_dev
        )
    })
    .await;
    assert!(
        warned,
        "A must be warned that a new device joined M (alerts: {:?})",
        a.security_alerts().iter().map(|r| (r.kind.clone(), r.detail.clone())).collect::<Vec<_>>()
    );

    // The list is re-published on every reconnect; the warning must not pile up.
    // Bounce C so A re-ingests the same {B,C} list at least once more.
    relay.set_online(&c.device_id, false);
    sleep_ms(1000).await;
    relay.set_online(&c.device_id, true);
    sleep_ms(3000).await;

    let new_device_alerts: Vec<_> = a
        .security_alerts()
        .into_iter()
        .filter(|r| r.kind == super::security_alerts::KIND_NEW_DEVICE)
        .collect();
    assert_eq!(
        new_device_alerts.len(),
        1,
        "a re-ingested device list must not re-raise the warning (got {:?})",
        new_device_alerts.iter().map(|r| r.detail.clone()).collect::<Vec<_>>()
    );
    assert_eq!(new_device_alerts[0].detail, c_dev, "the alert names the NEW device");
    assert!(
        new_device_alerts[0].acknowledged_at.is_none(),
        "a fresh warning starts unread"
    );

    // M's own devices never warn ABOUT THEMSELVES — the user linked them, and
    // they surface in linked-devices instead.
    assert!(
        b.security_alerts().is_empty(),
        "a device must not warn about its own identity's siblings (got {:?})",
        b.security_alerts().iter().map(|r| r.kind.clone()).collect::<Vec<_>>()
    );
    drain_events(&mut c);
}

// ---------------------------------------------------------------------------
// Step 9A push targeting: a DM to a multi-device identity must reach a fully-quit
// (offline-but-real) sibling device via the relay's offline buffer, so the real
// relay would fire a push to THAT device's token. Guards the Step 9A break where
// `collect_target_devices` dropped every non-in-room device (the Step 7 ghost
// filter) and so never targeted a quit phone at all. The complement assertion —
// a never-contacted GHOST id is NOT buffered — is covered by the revocation test.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_buffers_for_offline_real_sibling_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = friend (single device). M = our identity, two devices B + C.
    const A_MASTER: u8 = 90;
    const M_MASTER: u8 = 100;
    const B_DEV: u8 = 101;
    const C_DEV: u8 = 102;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    // A's resolver must know M's devices (it's the SENDER that fans master→devices).
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);
    super::resolver::update_many(&m_master, [b_dev.as_str(), c_dev.as_str()]);

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    sleep_ms(1200).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;

    // Let Olm sessions confirm all around (A↔B, A↔C). A must hold a session with C
    // for C to qualify as an offline-REAL target (the has_session ghost filter).
    sleep_ms(5000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);
    assert_ne!(
        a.olm_status(&c_dev).await, "absent",
        "A must hold an Olm session with C before C goes offline (else C is a ghost, not a real target)"
    );

    // C goes fully offline (the quit phone). B stays online.
    relay.set_online(&c_dev, false);
    sleep_ms(500).await;
    drain_events(&mut c);

    let before = relay.buffered_count(&c_dev);

    // A DMs our identity M. B (online) gets it live; C (offline-but-real) must be
    // buffered under its DEVICE id so the relay would push its token.
    a.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: m_master.clone(),
            text: "wake-the-phone".to_string(),
            message_id: "push-target-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();

    // B (live) receives it.
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "wake-the-phone")
    })
    .await;
    assert!(b_got, "online device B should receive the DM live");

    // C's offline buffer GREW — the relay would push C's token (the Step 9A fix).
    sleep_ms(400).await;
    let after = relay.buffered_count(&c_dev);
    assert!(
        after > before,
        "offline-but-real sibling C must be a buffer/push target (before={before} after={after})"
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

    // Recording indicator (issue #53): recording_start must round-trip, with
    // the Dart-facing signal-type string reconstructed from the recording flag.
    a.cmd_tx
        .send(NodeCommand::CallSendSignal {
            peer_id: m_master.clone(),
            signal_type: "recording_start".to_string(),
            payload: serde_json::json!({"recording": true, "timestamp": 1}).to_string(),
        })
        .await
        .unwrap();
    let saw_rec = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::CallSignal { signal_type, .. } if signal_type == "recording_start")
    })
    .await;
    assert!(saw_rec, "callee must receive the routed recording_start call signal");

    drain_events(&mut b);

    // DM screen_watch (issue #38 + media forwarding step 1): the viewer's
    // display resolution and source-quality request must round-trip.
    a.cmd_tx
        .send(NodeCommand::CallSendSignal {
            peer_id: m_master.clone(),
            signal_type: "screen_watch".to_string(),
            payload: serde_json::json!({
                "call_id": "call-1",
                "want": true,
                "viewer_width": 1920,
                "viewer_height": 1080,
                "source_quality": false,
            })
            .to_string(),
        })
        .await
        .unwrap();
    let mut dm_watch_payload = None;
    let saw_watch = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::CallSignal { signal_type, payload, .. } = ev {
            if signal_type == "screen_watch" {
                dm_watch_payload = Some(payload.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(saw_watch, "callee must receive the routed screen_watch call signal");
    let dm_watch: serde_json::Value =
        serde_json::from_str(&dm_watch_payload.expect("screen_watch payload")).expect("valid json");
    assert_eq!(dm_watch["want"], serde_json::Value::Bool(true), "want must round-trip");
    assert_eq!(dm_watch["viewer_width"], serde_json::json!(1920), "viewer_width must round-trip");
    assert_eq!(dm_watch["viewer_height"], serde_json::json!(1080), "viewer_height must round-trip");
    // "Source quality" was REMOVED 2026-08-15 (the clamp is keyed to the
    // viewer's MONITOR, so it already delivers everything they can display).
    // An older client's key must be DROPPED, not forwarded.
    assert!(
        dm_watch.get("source_quality").is_none(),
        "source_quality must no longer round-trip: {dm_watch}"
    );

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
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
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
            voice: false,
            poster: None,
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

/// Issue #41 — auto-download gate. With auto-download OFF for the conversation
/// the receiver keeps the pushed file's METADATA (the card renders with a
/// manual Download button) but registers no stream: the pushed bytes are
/// discarded and the row never completes. An explicit RequestFile (the manual
/// button) then bypasses the gate and the transfer completes normally.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_auto_download_off_declines_push_then_manual_request_completes() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 101;
    const B_MASTER: u8 = 102;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // Turn auto-download OFF for exactly this DM (global stays at the
    // permissive default so the conf leaks nothing into other tests even if
    // an assert below fires before the restore).
    let gate_key = format!("dm:{a_master}");
    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(gate_key.clone(), false)]),
    );

    let src = global_tmp.path().join("gated.bin");
    let contents: &[u8] = b"gated file contents that must not auto-persist";
    std::fs::write(&src, contents).expect("write src file");

    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "gated-file-msg-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();

    // The header still lands (card metadata)...
    let mut got_fid = None;
    let header = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("gated") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(header, "gated push must still deliver FileHeaderReceived (the card)");
    let fid = got_fid.expect("file id from header");

    // ...but the pushed bytes are declined: no FileCompleted, row incomplete.
    let completed_anyway = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(!completed_anyway, "auto-download off must not complete a pushed file");
    let meta = b.file_meta(&fid).expect("metadata row persisted despite the gate");
    assert!(meta.completed_at.is_none(), "gated file must stay incomplete");

    // Manual download (the placeholder / hover button): explicit RequestFile
    // bypasses the gate via the request receipt and completes normally.
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a.master_id.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "explicit RequestFile must bypass the auto-download gate");
    sleep_ms(200).await;

    let meta = b.file_meta(&fid).expect("files row after manual download");
    assert!(meta.completed_at.is_some(), "manual download completed");
    let disk = meta.disk_path.expect("completed file has a disk path");
    let got = std::fs::read(&disk).expect("read the received file");
    assert_eq!(got, contents, "manually pulled file decrypts to the original contents");

    // Restore the permissive default for the rest of the suite.
    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
}

/// Issue #41 carry-over — sender-side pre-negotiation. When the RECEIVER's
/// gating preference is advertised BEFORE the send (here: conf seeded before
/// the nodes connect, so the on-join `auto_dl_pref` advert carries 0), the
/// sender never streams the bytes at all: the receiver gets a METADATA-ONLY
/// header (no AES material → no pending stream, no decline sentinel — the
/// old path discarded fully-transmitted bytes instead). The manual
/// RequestFile pull then completes normally.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_receiver_pref_prenegotiation_skips_push_bytes() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 103;
    const B_MASTER: u8 = 104;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // Gate B's side of the conversation BEFORE anything connects, so B's
    // on-join advert to A already says 0 (the conf is process-global; the
    // override key only matches B's view of the conversation, so A's own
    // receive gate is unaffected).
    let gate_key = format!("dm:{a_master}");
    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(gate_key.clone(), false)]),
    );

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let src = global_tmp.path().join("preneg.bin");
    let contents: &[u8] = b"pre-negotiated file contents that must not ride the wire";
    std::fs::write(&src, contents).expect("write src file");

    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "preneg-file-msg-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();

    // The metadata-only header still lands (card renders)...
    let mut got_fid = None;
    let header = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("preneg") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(header, "pre-negotiated send must still deliver the metadata card");
    let fid = got_fid.expect("file id from header");

    // ...but NEITHER bytes NOR the decline sentinel follow: the sender never
    // streamed, so there is nothing for the receive gate to discard. (The old
    // receive-side-only path emits FileFailed{auto_download_off} here.)
    let byte_activity = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
            || matches!(
                ev,
                NetworkEvent::FileFailed { file_id, error }
                    if *file_id == fid && error == "auto_download_off"
            )
    })
    .await;
    assert!(
        !byte_activity,
        "pre-negotiation must keep the bytes (and the decline sentinel) off the wire"
    );
    let meta = b.file_meta(&fid).expect("metadata row persisted from the meta-only header");
    assert!(meta.completed_at.is_none(), "no bytes may land without a manual pull");

    // Manual pull still works: the explicit-request receipt bypasses the gate.
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a.master_id.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "manual RequestFile must complete after a pre-negotiated skip");
    sleep_ms(200).await;
    let meta = b.file_meta(&fid).expect("files row after manual download");
    let disk = meta.disk_path.expect("completed file has a disk path");
    assert_eq!(
        std::fs::read(&disk).expect("read the received file"),
        contents,
        "manually pulled file decrypts to the original contents"
    );

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
}

/// Issue #41 carry-over — voice messages are exempt from the auto-download
/// gate END TO END: with the conversation gated on the receiver (and that
/// preference advertised to the sender), a voice-flagged send still streams
/// and auto-completes. Also covers the legacy filename pattern — the wire
/// name is the recorder's temp basename (`voice_{stamp}_{rand}.ogg`), which
/// the old literal "Voice message.ogg" check never matched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_voice_message_bypasses_auto_download_gate() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 105;
    const B_MASTER: u8 = 106;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // Gate the conversation before connect — the advert says 0, and B's own
    // receive gate is off for this DM. Voice must sail through both.
    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // The recorder's real temp basename shape rides the wire.
    let src = global_tmp.path().join("voice_1730000000000_12345.ogg");
    let contents: &[u8] = b"opus-ish voice note bytes";
    std::fs::write(&src, contents).expect("write src file");

    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "voice-file-msg-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: true,
            poster: None,
        })))
        .await
        .unwrap();

    // Voice auto-completes despite the gated conversation.
    let mut got_fid = None;
    let header = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("voice_") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(header, "voice note header must arrive");
    let fid = got_fid.expect("file id from header");
    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "voice notes are exempt from the auto-download gate");
    sleep_ms(200).await;
    let meta = b.file_meta(&fid).expect("voice files row");
    let disk = meta.disk_path.expect("completed voice note has a disk path");
    assert_eq!(
        std::fs::read(&disk).expect("read the received voice note"),
        contents,
        "voice note decrypts to the original contents"
    );

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
}

/// Video poster pipeline: a DM video send with Dart-supplied poster bytes
/// (the ffmpeg-extracted frame) delivers a FileHeader whose `thumb_b64`
/// carries the re-encoded lossy poster AND whose width/height fall back to
/// the poster's own dimensions when the ffmpeg probe supplied none — so the
/// receiver's bubble renders a real preview at the correct aspect before a
/// single video byte is local.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_video_send_carries_poster_thumb_and_dims() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 107;
    const B_MASTER: u8 = 108;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // Fake "video" bytes + a real 64x36 (16:9) PNG poster frame.
    let src = global_tmp.path().join("clip.mp4");
    let contents: &[u8] = b"not really h264 but streams all the same";
    std::fs::write(&src, contents).expect("write src file");
    let poster_png = {
        let img = image::RgbaImage::from_pixel(64, 36, image::Rgba([40, 90, 160, 255]));
        let mut buf = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .expect("encode poster png");
        buf
    };

    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "video-file-msg-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            // No probe dims — the header must fall back to the poster's own.
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: Some(poster_png),
        })))
        .await
        .unwrap();

    let mut got = None;
    let header = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, width, height, thumb_b64, .. } = ev {
            if file_name.starts_with("clip") {
                got = Some((file_id.clone(), *width, *height, thumb_b64.clone()));
                return true;
            }
        }
        false
    })
    .await;
    assert!(header, "video header must arrive");
    let (fid, w, h, thumb) = got.expect("header fields");
    let thumb = thumb.expect("header must carry the re-encoded poster thumb");
    assert!(thumb.len() <= super::file_handler::FILE_THUMB_MAX_B64_LEN);
    // Poster-derived dimension fallback: 64x36 source poster, no upscale.
    assert_eq!((w, h), (Some(64), Some(36)), "header w/h fall back to poster dims");
    // The poster also persists on the receiver's files row for later reloads.
    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "video transfer completes");
    sleep_ms(200).await;
    let meta = b.file_meta(&fid).expect("receiver files row");
    assert_eq!(meta.thumb_b64.as_deref(), Some(thumb.as_str()), "poster persisted in thumb_b64");
    assert_eq!((meta.width, meta.height), (Some(64), Some(36)));
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
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    // Owner creates a server; add a VOICE channel (the default #general is Text).
    let server_id = create_server_and_wait(&mut o, "VC Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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

    // --- A broadcast recording indicator (issue #53) routes the same way ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            // Broadcast-class: peer_id is ignored by the Rust send path.
            peer_id: String::new(),
            signal_type: "recording_start".to_string(),
            payload: serde_json::json!({"recording": true, "timestamp": 1}).to_string(),
        })
        .await
        .unwrap();
    let o_saw_rec = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelSignal { signal_type, .. } if signal_type == "recording_start")
    })
    .await;
    assert!(o_saw_rec, "owner must receive the routed recording_start VC signal");

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

    // --- A targeted screen_watch signal (opt-in watching, issue #38) routes J → O ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "screen_watch".to_string(),
            payload: serde_json::json!({
                "want": true,
                "viewer_width": 2560,
                "viewer_height": 1440,
                "source_quality": true,
            })
            .to_string(),
        })
        .await
        .unwrap();
    let mut watch_payload = None;
    let o_saw_watch = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::VoiceChannelSignal { signal_type, payload, .. } = ev {
            if signal_type == "screen_watch" {
                watch_payload = Some(payload.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(o_saw_watch, "sharer must receive the routed screen_watch VC signal");
    let watch_json: serde_json::Value =
        serde_json::from_str(&watch_payload.expect("screen_watch payload")).expect("valid json");
    assert_eq!(watch_json["want"], serde_json::Value::Bool(true), "want flag must round-trip");
    // Media forwarding step 1: the viewer's display resolution must survive the
    // typed Rust round-trip (receiver-driven caps).
    assert_eq!(watch_json["viewer_width"], serde_json::json!(2560), "viewer_width must round-trip");
    assert_eq!(watch_json["viewer_height"], serde_json::json!(1440), "viewer_height must round-trip");
    // "Source quality" was REMOVED 2026-08-15 — an older client's key is
    // parsed away rather than forwarded to the sharer.
    assert!(
        watch_json.get("source_quality").is_none(),
        "source_quality must no longer round-trip: {watch_json}"
    );

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
// Ring-2 CONTROL PLANE: the self-ghost regression (2026-08). The VC participant
// set is keyed by ROUTABLE DEVICE ids — including OUR OWN entry. The bug: the
// own-join path inserted/emitted the MASTER id while Dart's self-skip compared
// the DEVICE id, so both ends dialed their own master as a remote participant
// ("Creating offer for peer <own master>" + endless "No session" storms). This
// test runs nodes whose device id genuinely differs from the master (the other
// VC tests use master==device seeds and can never catch the mixup) and pins:
// own join/leave events carry the DEVICE id + is_self=true, the remote view is
// device-keyed with is_self=false, and a self-targeted VC signal is dropped
// BEFORE Olm (no MessageSendFailed storm).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn vc_self_participant_is_device_keyed_no_self_dial() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 112;
    const O_DEVICE: u8 = 113;
    const J_MASTER: u8 = 122;
    const J_DEVICE: u8 = 123;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_DEVICE, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_DEVICE, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;
    assert_ne!(j.device_id, j.master_id, "test precondition: device != master");

    let server_id = create_server_and_wait(&mut o, "Ghost Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // --- J joins: its OWN event must carry the DEVICE id and is_self=true. ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let mut own_peer = None;
    let mut own_is_self = None;
    let j_own = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::VoiceChannelJoined { channel_id, peer_id, is_self, .. } = ev {
            if *channel_id == voice_cid {
                own_peer = Some(peer_id.clone());
                own_is_self = Some(*is_self);
                return true;
            }
        }
        false
    })
    .await;
    assert!(j_own, "joiner must see its own VoiceChannelJoined");
    assert_eq!(own_peer.as_deref(), Some(j.device_id.as_str()),
        "own join must carry the ROUTABLE DEVICE id, never the master (self-ghost)");
    assert_eq!(own_is_self, Some(true), "own join must be flagged is_self");

    // --- O's view of J's join is device-keyed and NOT flagged self. ---
    let mut remote_peer = None;
    let mut remote_is_self = None;
    let o_saw = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::VoiceChannelJoined { channel_id, peer_id, is_self, .. } = ev {
            if *channel_id == voice_cid {
                remote_peer = Some(peer_id.clone());
                remote_is_self = Some(*is_self);
                return true;
            }
        }
        false
    })
    .await;
    assert!(o_saw, "owner must see the joiner enter the voice channel");
    assert_eq!(remote_peer.as_deref(), Some(j.device_id.as_str()),
        "remote join must be keyed by the sender's DEVICE id");
    assert_eq!(remote_is_self, Some(false), "remote join must not be flagged self");

    // --- Self-targeted VC signal belt: dropped BEFORE Olm, no failure storm. ---
    drain_events(&mut j);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(), // our OWN master — the ghost's exact shape
            signal_type: "screen_watch".to_string(),
            payload: serde_json::json!({"want": true}).to_string(),
        })
        .await
        .unwrap();
    let storm = wait_event(&mut j, std::time::Duration::from_millis(1000), |ev| {
        matches!(ev, NetworkEvent::MessageSendFailed { .. })
    })
    .await;
    assert!(!storm, "a self-targeted VC signal must be dropped before Olm (no MessageSendFailed)");

    // --- J leaves: own event device-keyed + is_self; O sees the device id. ---
    drain_events(&mut o);
    drain_events(&mut j);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelLeave {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let mut left_peer = None;
    let mut left_is_self = None;
    let j_left = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        if let NetworkEvent::VoiceChannelLeft { channel_id, peer_id, is_self, .. } = ev {
            if *channel_id == voice_cid {
                left_peer = Some(peer_id.clone());
                left_is_self = Some(*is_self);
                return true;
            }
        }
        false
    })
    .await;
    assert!(j_left, "joiner must see its own VoiceChannelLeft");
    assert_eq!(left_peer.as_deref(), Some(j.device_id.as_str()),
        "own leave must carry the DEVICE id");
    assert_eq!(left_is_self, Some(true), "own leave must be flagged is_self");
    let o_saw_leave = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelLeft { channel_id, peer_id, .. }
            if *channel_id == voice_cid && *peer_id == j.device_id)
    })
    .await;
    assert!(o_saw_leave, "owner must see the joiner leave, keyed by its device id");
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: media forwarding step 2 — originator attribution on the
// VC screen lane. vc_screen_offer/answer/ice carry an optional StreamOrigin
// (who the stream is FROM vs who DELIVERED it); receivers get it verbatim in
// the VoiceChannelSignal payload. Guards: absent origin = old wire (delivered
// untouched), and a spoofed origin (neither the sender nor the recipient) is
// DROPPED — the SFrame group key is shared, so spoofed attribution would
// render the spoofer's pixels under the victim's name.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn vc_screen_origin_attribution_round_trip() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 111;
    const J_MASTER: u8 = 121;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Origin Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await;

    // BOTH nodes join the voice channel: the receive guard checks the SENDER
    // is a participant, and signals flow in both directions below.
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
    o.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let j_saw_join = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(j_saw_join, "joiner must see the owner enter the voice channel");
    drain_events(&mut o);
    drain_events(&mut j);

    // Helper: pull the next VoiceChannelSignal of a given type + its payload.
    async fn next_signal(
        node: &mut TestNode,
        wanted: &str,
        secs: u64,
    ) -> Option<serde_json::Value> {
        let mut got = None;
        let ok = wait_event(node, std::time::Duration::from_secs(secs), |ev| {
            if let NetworkEvent::VoiceChannelSignal { signal_type, payload, .. } = ev {
                if signal_type == wanted {
                    got = Some(payload.clone());
                    return true;
                }
            }
            false
        })
        .await;
        if !ok { return None; }
        Some(serde_json::from_str(&got.expect("payload")).expect("valid json"))
    }

    // --- 1. Sharer (J) -> viewer (O): screen_offer WITH origin round-trips ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "screen_offer".to_string(),
            payload: serde_json::json!({
                "sdp": "v=0 offer",
                "origin": {"peer": j_master, "kind": "screen", "stream": "cafe0123"},
            })
            .to_string(),
        })
        .await
        .unwrap();
    let offer = next_signal(&mut o, "screen_offer", 4).await
        .expect("viewer must receive the screen_offer");
    assert_eq!(offer["sdp"], serde_json::json!("v=0 offer"));
    assert_eq!(offer["origin"]["peer"], serde_json::json!(j_master),
        "origin.peer must round-trip");
    assert_eq!(offer["origin"]["kind"], serde_json::json!("screen"));
    assert_eq!(offer["origin"]["stream"], serde_json::json!("cafe0123"),
        "origin.stream must round-trip");

    // --- 2. Viewer (O) -> sharer (J): answer ECHOES the sharer's origin ---
    // origin.peer == the RECIPIENT here; the guard accepts it as an echo.
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_answer".to_string(),
            payload: serde_json::json!({
                "sdp": "v=0 answer",
                "origin": {"peer": j_master, "kind": "screen", "stream": "cafe0123"},
            })
            .to_string(),
        })
        .await
        .unwrap();
    let answer = next_signal(&mut j, "screen_answer", 4).await
        .expect("sharer must receive the echoed screen_answer");
    assert_eq!(answer["origin"]["peer"], serde_json::json!(j_master),
        "echoed origin must survive the answer direction");

    // --- 3. Viewer (O) -> sharer (J): incoming-role ICE with origin echo ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_ice".to_string(),
            payload: serde_json::json!({
                "candidate": "candidate:1 1 udp 1 10.0.0.1 1 typ host",
                "sdpMid": "0",
                "sdpMLineIndex": 0,
                "role": "incoming",
                "origin": {"peer": j_master, "kind": "screen", "stream": "cafe0123"},
            })
            .to_string(),
        })
        .await
        .unwrap();
    let ice = next_signal(&mut j, "screen_ice", 4).await
        .expect("sharer must receive the echoed screen_ice");
    assert_eq!(ice["role"], serde_json::json!("incoming"));
    assert_eq!(ice["origin"]["stream"], serde_json::json!("cafe0123"));

    // --- 4. Old-wire compat: an offer WITHOUT origin is delivered untouched ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "screen_offer".to_string(),
            payload: serde_json::json!({"sdp": "v=0 legacy"}).to_string(),
        })
        .await
        .unwrap();
    let legacy = next_signal(&mut o, "screen_offer", 4).await
        .expect("originless offer must still be delivered (old clients)");
    assert_eq!(legacy["sdp"], serde_json::json!("v=0 legacy"));
    assert!(legacy.get("origin").is_none(),
        "absent origin must stay absent — no synthesized attribution");

    // --- 5. Spoof rejection: origin naming a THIRD identity is dropped ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_answer".to_string(),
            payload: serde_json::json!({
                "sdp": "v=0 spoof",
                "origin": {"peer": "12D3KooWFakeVictimPeerId", "kind": "screen", "stream": "ff00ff00"},
            })
            .to_string(),
        })
        .await
        .unwrap();
    let spoofed = next_signal(&mut j, "screen_answer", 2).await;
    assert!(spoofed.is_none(),
        "a spoofed origin (neither sender nor recipient) must be DROPPED");

    // The drop is per-signal, not per-peer: a valid follow-up still flows.
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_answer".to_string(),
            payload: serde_json::json!({"sdp": "v=0 healthy"}).to_string(),
        })
        .await
        .unwrap();
    let healthy = next_signal(&mut j, "screen_answer", 4).await
        .expect("the node must stay healthy after dropping a spoofed signal");
    assert_eq!(healthy["sdp"], serde_json::json!("v=0 healthy"));
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: a voice peer that reconnects must be able to RECEIVE
// again, not just send.
//
// `WsEvent::Disconnected` purges every remote peer from
// `voice_channel_participants`, and that set gates EVERY inbound VC signal.
// Nothing refilled it: the peer on the other side never left its own channel,
// so it had no reason to announce anything, and the one path that did
// re-announce sat behind the `is_new`/`synced_peers` guard — which is false
// for exactly the peer that just came back.
//
// Field-caught 2026-08-27: the reconnecting node asked for a leg rebuild four
// times, its peer dialed four times, and it dropped all four offers as
// `BLOCKED VC SDP offer from non-participant` while its own requests still
// arrived. One-way signalling, permanently silent voice channel.
//
// The socket is dropped SILENTLY here on purpose: the real relay broadcast no
// `PeerLeft`, which is what left `is_new` false and skipped the cascade.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn vc_reconnecting_peer_can_receive_signals_again() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 115;
    const J_MASTER: u8 = 125;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Reconnect Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await;

    // Both in the voice channel.
    for (node, label) in [(&mut o, "owner"), (&mut j, "joiner")] {
        node.cmd_tx
            .send(NodeCommand::VoiceChannelJoin {
                server_id: server_id.clone(),
                channel_id: voice_cid.clone(),
            })
            .await
            .unwrap();
        let _ = label;
    }
    sleep_ms(2000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // Sanity: signalling works BEFORE the outage, so a failure after it is the
    // reconnect and not the fixture.
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "sdp_offer".to_string(),
            payload: serde_json::json!({"sdp": "v=0 before"}).to_string(),
        })
        .await
        .unwrap();
    let before = wait_event(&mut j, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelSignal { signal_type, .. } if signal_type == "sdp_offer")
    })
    .await;
    assert!(before, "the joiner must receive VC offers before the outage");

    // --- the outage: J's socket dies with nobody told, then comes back ---
    relay.drop_socket_silently(&j.device_id);
    sleep_ms(1500).await;
    relay.set_online(&j.device_id, true);
    // STAYS A SLEEP. The reconnect itself is observable, but the owner's
    // presence re-announce is the thing under test: polling for it would be
    // asserting the fix in the setup and the test could no longer fail.
    sleep_ms(4000).await; // reconnect + the owner's presence re-announce
    drain_events(&mut j);

    // The owner never left the channel and has no reason of its own to
    // announce anything: if nothing repopulated J's participant set, this
    // offer is dropped as "non-participant" and J hears nothing, forever.
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "sdp_offer".to_string(),
            payload: serde_json::json!({"sdp": "v=0 after"}).to_string(),
        })
        .await
        .unwrap();
    let after = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelSignal { signal_type, payload, .. }
            if signal_type == "sdp_offer" && payload.contains("v=0 after"))
    })
    .await;
    assert!(
        after,
        "a reconnected peer must receive VC offers again — its participant set          was purged on disconnect and only the peer's presence re-announce can          refill it, so a silent drop here is the one-way signalling bug"
    );
}

// ---------------------------------------------------------------------------
// Ring-2 CONTROL PLANE: the voice mesh's `leg_restart` request.
//
// The mesh gives the SDP offer to the lexicographically lower peer id, so the
// higher side has no way to rebuild a leg it alone can see is broken: before
// this signal it closed its connection and waited for an offer nobody was
// going to send (field-caught 2026-08-27, no audio for the rest of the call).
// A VC signal type is WHITELISTED in Rust across three separate touches, and
// missing one drops it SILENTLY, so this guards the whole path: it must reach
// the peer, in both directions, carrying the sender's id.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn vc_leg_restart_signal_round_trips() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 113;
    const J_MASTER: u8 = 123;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Leg Restart Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await;

    // BOTH sides join: the receive guard checks the SENDER is a participant,
    // and the request travels in whichever direction the id compare dictates.
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
    o.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let j_saw_join = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(j_saw_join, "joiner must see the owner enter the voice channel");
    drain_events(&mut o);
    drain_events(&mut j);

    // Helper: wait for a leg_restart naming a given sender.
    async fn saw_leg_restart(node: &mut TestNode, from: &str, cid: &str, secs: u64) -> bool {
        wait_event(node, std::time::Duration::from_secs(secs), |ev| {
            matches!(
                ev,
                NetworkEvent::VoiceChannelSignal { signal_type, peer_id, channel_id, .. }
                    if signal_type == "leg_restart" && peer_id == from && channel_id == cid
            )
        })
        .await
    }

    // --- J asks O to re-offer the leg ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "leg_restart".to_string(),
            payload: "{}".to_string(),
        })
        .await
        .unwrap();
    assert!(
        saw_leg_restart(&mut o, &j_master, &voice_cid, 5).await,
        "the dialing side must receive leg_restart — a missing whitelist touch          drops it silently and the leg is never rebuilt"
    );

    // --- and the other direction, since either id can end up the higher one ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "leg_restart".to_string(),
            payload: "{}".to_string(),
        })
        .await
        .unwrap();
    assert!(
        saw_leg_restart(&mut j, &o_master, &voice_cid, 5).await,
        "leg_restart must travel in both directions"
    );
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let b_joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(b_joined, "device B should join the server");
    expect_mls_leaf(&a, &server_id, &b.device_id, 15).await;
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
// Multi-device self-heal of a PRE-FIX channel row (2026-06-24). A row stored
// before the device→master resolve fix can be keyed under a sender DEVICE id with
// signature material that no longer verifies against the master-id payload — the
// "12D3KooW… + unverified signature" bubble Vitalik hit on VM. INSERT OR IGNORE +
// the already-exists skip means a later channel sync that carries the CORRECT
// (verified, master-keyed) copy can't overwrite it. The self-heal: when a synced
// item's signature VERIFIES and our stored row is attributed to a different
// sender, repair the row to the verified one. Here we simulate the corruption
// directly (poison the stored sender to a bogus device id), then re-sync from the
// member that holds the good copy and assert the row converges back to the master.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn corrupt_device_keyed_channel_row_self_heals_from_verified_sync() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = owner/sender (single keystone device), J = member. Both befriended so the
    // server-join Olm handshake works, exactly like the recovery test above.
    const A_MASTER: u8 = 170;
    const J_MASTER: u8 = 180;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();
    // A bogus DEVICE id to poison J's stored row with (stands in for the pre-fix
    // sibling-device id that AnonListen saw). It is NOT A's master and NOT in the
    // resolver, so it can never verify — mirroring the wedged VM row.
    let ghost_dev = NativeKeypair::from_secret_bytes(&seed_bytes(199)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &j, 15).await;
    drain_events(&mut a);
    drain_events(&mut j);

    // A creates a server; J joins and forms its MLS leaf.
    let server_id = create_server_and_wait(&mut a, "Heal Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    // STAYS A SLEEP. Narrowing this to "A sees J's leaf" returns much sooner and
    // breaks the test: the heal at the end of it stopped happening at all. The
    // leaf appearing is not the same event as J having finished joining, and the
    // corrupt-row/rejoin/sync sequence below depends on the latter.
    sleep_ms(4000).await; // MLS leaf forms

    // A sends a channel message; J receives + stores it CORRECTLY (verified, keyed to
    // A's master). This is the "good" copy A will later re-serve.
    drain_events(&mut j);
    const MID: &str = "heal-1";
    a.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "heal me".to_string(),
            message_id: MID.to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let j_got = wait_event(&mut j, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "heal me")
    })
    .await;
    assert!(j_got, "J must receive A's channel message");
    sleep_ms(300).await;
    assert_eq!(
        j.raw_channel_message_sender(MID).as_deref(), Some(a_master.as_str()),
        "precondition: J first stores the message correctly under A's master"
    );

    // --- Simulate the PRE-FIX corruption: poison J's stored row to the ghost device
    // id (sender no longer matches the signature → 'unverified' bubble). This is the
    // exact wedged state VM was in (stored under a sibling device, sig won't verify).
    let changed = j.store().repair_channel_message_sender(
        MID, &ghost_dev, false, None, None,
    ).expect("poison row");
    assert!(changed, "the poison write must mutate the row");
    assert_eq!(
        j.raw_channel_message_sender(MID).as_deref(), Some(ghost_dev.as_str()),
        "row is now corrupt (device-keyed) on J, mirroring the pre-fix VM state"
    );

    // --- Re-trigger channel sync: J reconnects, fires a ChannelSyncRequest per
    // channel; A serves the message (sender = A's master, valid signature). Because
    // J's stored sender is now the ghost device, J's per-sender cursor for A's master
    // is 0 → A re-serves it, and the self-heal fires (verified sig + sender mismatch
    // → repair). ---
    relay.set_online(&j.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut j);
    relay.set_online(&j.device_id, true);
    sleep_ms(700).await; // let J re-run connect + re-register the sync coordinator
    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    // STAYS A SLEEP, and this one was measured. Polling
    // `raw_channel_message_sender` (which opens a NEW SQLCipher connection every
    // call) at 250ms stopped the heal from landing inside 15s, when a plain sleep
    // saw it in under 4. Reading a node's DB from the test is not free and not
    // passive: the connection teardown takes locks the node's own writer then
    // waits on (busy_timeout = 4000). Poll LIVE state, never a running node's DB.
    sleep_ms(4000).await; // let the ChannelSyncRequest round-trip + heal commit

    // --- THE ASSERTION: J's row is repaired back to A's master (raw, device-keyed
    // truth), and its signature verifies again via the channel-pane inspector. ---
    assert_eq!(
        j.raw_channel_message_sender(MID).as_deref(), Some(a_master.as_str()),
        "the corrupt device-keyed row must self-heal back to A's master after a verified sync"
    );
    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "heal me").expect("healed message present");
    assert_eq!(row.sender_master, a_master, "healed message attributed to A's master");
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
// "Latest authorized write wins" (2026-07-16): an Admin holding MANAGE_SERVER
// flips a server setting the OWNER wrote earlier. Under the old priority-first
// AdminLwwReg merge the admin's op silently lost on every replica (including
// the admin's own) — the Twitch toggle "reverted". Pure HLC LWW + the
// permission-gated ingest must land it everywhere: on the owner, on the admin,
// and on a member that was OFFLINE during the flip and converges via sync.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn admin_flips_owner_setting_and_all_nodes_converge() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 190;
    const A_MASTER: u8 = 191;
    const M_MASTER: u8 = 192;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o =
        spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master, &m_master]).await;
    sleep_ms(1200).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    sleep_ms(1200).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &m, 15).await;
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    let server_id = create_server_and_wait(&mut o, "Settings Server").await;
    sleep_ms(500).await;

    // A and M join.
    a.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let a_joined = wait_event(&mut a, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(a_joined, "admin-to-be A should join the server");
    sleep_ms(1500).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let m_joined = wait_event(&mut m, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(m_joined, "member M should join the server");
    sleep_ms(2500).await; // CRDT membership converges across O, A, M
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    // O promotes A to Admin. A's LOCAL state must hold the role before A
    // authors the setting op (the author-side MANAGE_SERVER gate reads it).
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: a_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(1500).await;
    {
        let a_row = a
            .member_panel(&server_id, &relay)
            .into_iter()
            .find(|r| r.master == a_master)
            .expect("A sees itself in the member panel");
        assert_eq!(
            a_row.role,
            crate::crdt::operations::MemberRole::Admin,
            "A must know it is Admin before flipping the setting"
        );
    }

    // O writes the setting FIRST — the owner-written value that the old
    // priority-first merge made permanently sticky.
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "twitch_verification_enabled".to_string(),
            value: "true".to_string(),
        })
        .await
        .unwrap();
    let a_saw = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(a_saw, "A must apply the owner's setting op");
    let m_saw = wait_event(&mut m, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(m_saw, "M must apply the owner's setting op");
    sleep_ms(800).await; // fire-and-forget CrdtStore persist
    for (label, node) in [("O", &o), ("A", &a), ("M", &m)] {
        assert_eq!(
            node.server_setting(&server_id, "twitch_verification_enabled").as_deref(),
            Some("true"),
            "{label} reads the owner's initial value"
        );
    }

    // M goes offline — it must converge later via sync catch-up, not live fan.
    relay.set_online(&m.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut m);

    // ADMIN A flips the owner-written setting OFF.
    a.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "twitch_verification_enabled".to_string(),
            value: "false".to_string(),
        })
        .await
        .unwrap();
    let o_saw = wait_event(&mut o, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(o_saw, "owner must ingest the admin's setting op");
    sleep_ms(800).await;
    assert_eq!(
        a.server_setting(&server_id, "twitch_verification_enabled").as_deref(),
        Some("false"),
        "the admin's own replica reflects the flip (was: silently reverted)"
    );
    assert_eq!(
        o.server_setting(&server_id, "twitch_verification_enabled").as_deref(),
        Some("false"),
        "the owner's replica accepts the admin's later write (was: priority-first merge kept the owner value)"
    );

    // M returns; reconnect sync must deliver the admin's op. Poll the persisted
    // state rather than a specific event — the sync path's emission differs
    // from the live-broadcast path.
    relay.set_online(&m.device_id, true);
    let mut m_value = None;
    for _ in 0..24 {
        sleep_ms(500).await;
        m_value = m.server_setting(&server_id, "twitch_verification_enabled");
        if m_value.as_deref() == Some("false") {
            break;
        }
    }
    assert_eq!(
        m_value.as_deref(),
        Some("false"),
        "offline member M converges to the admin's write after reconnect sync"
    );

    drop(o);
    drop(a);
    drop(m);
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
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
    expect_dm_pair_ready(&relay, &o, &m, 15).await;
    drain_events(&mut o);
    drain_events(&mut m);

    // O creates a server; M joins.
    let server_id = create_server_and_wait(&mut o, "Doomed Server").await;
    sleep_ms(300).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
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
    expect_mls_leaf(&b, &server_id, &c.device_id, 15).await;

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

// ---------------------------------------------------------------------------
// Step 9D follow-up (server CREATE/JOIN re-announces to OFFLINE siblings on
// reconnect): the live SiblingServerAnnounce only reaches siblings online AT
// create/join time. A sibling that was OFFLINE then never learned the server
// exists — the asymmetry Vitalik hit (deletion reconciled via the grow-only
// CRDT tombstone, but creation/join did NOT). Here C is OFFLINE when B creates
// the server; C comes back online and must auto-onboard via the reconnect
// re-announce (PeerJoined on B's side + RoomMembers on C's side), get its MLS
// leaf, and decrypt a channel message — WITHOUT C ever calling JoinServer.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn server_create_reannounces_to_offline_sibling_on_reconnect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity, devices B (creator) + C (the offline sibling).
    const M_MASTER: u8 = 240;
    const B_DEV: u8 = 241;
    const C_DEV: u8 = 242;
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

    // --- C goes OFFLINE, then B creates a server (C must NOT learn it live) ---
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;

    let server_id = create_server_and_wait(&mut b, "Offline-Sibling Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(1500).await;

    // C is offline → it has not onboarded.
    assert!(
        !c.servers().contains(&server_id),
        "offline sibling C must NOT have the server yet (live announce can't reach it)"
    );

    // --- C comes back online: the reconnect re-announce must onboard it ---
    drain_events(&mut c);
    relay.set_online(&c.device_id, true);

    let c_onboarded = wait_event(&mut c, std::time::Duration::from_secs(12), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(
        c_onboarded,
        "reconnected sibling C must auto-onboard the server it missed while offline (ServerJoined)"
    );
    expect_mls_leaf(&b, &server_id, &c.device_id, 15).await;

    assert!(
        c.servers().contains(&server_id),
        "sibling C's server list must include the re-announced server, got {:?}",
        c.servers()
    );

    // B's MLS group must contain C's device leaf so C can decrypt channel messages.
    let b_leaves = b.mls_members(&server_id).await;
    assert!(
        b_leaves.contains(&c.device_id),
        "creator B's MLS group must contain reconnected sibling C's leaf, got {b_leaves:?}"
    );

    // --- THE PAYOFF: B sends a channel message; C (re-announced sibling) decrypts it ---
    drain_events(&mut c);
    b.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "welcome back".to_string(),
            message_id: "reannounce-ch-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let c_got = wait_event(&mut c, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "welcome back")
    })
    .await;
    assert!(
        c_got,
        "reconnected sibling C must decrypt a channel message in the re-announced server"
    );

    // --- THE UI-REFRESH GUARD (the actual symptom): C ALREADY HOLDS the server
    // now. A second reconnect re-announces it; the handler must RUN THE FULL JOIN
    // FLOW again (not a weak ServerUpdated nudge that proved unreliable), which
    // ends in NetworkEvent::ServerJoined → Dart `onServerCreated` → the server is
    // UNCONDITIONALLY (re)inserted into the list. This is the "MLS joined but UI
    // shows 3 not 4" bug: the crypto/DB onboard had succeeded; the list just never
    // refreshed. ServerJoined is the only event observed to refresh it reliably
    // (it's the same event a live both-online create fires), so an already-held
    // re-announce must produce it too.
    drain_events(&mut c);
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut c);
    relay.set_online(&c.device_id, true);

    let c_rejoined = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(
            ev,
            NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        )
    })
    .await;
    assert!(
        c_rejoined,
        "an already-held server re-announced on reconnect must re-run the join flow \
         and emit ServerJoined (→ onServerCreated → list refresh) — NOT silently no-op, \
         else the UI shows a stale count"
    );
}

// ---------------------------------------------------------------------------
// MANUAL state sync (Security → Your Devices "Sync from this device"): the
// deterministic escape hatch. The DESTINATION device asks a chosen SOURCE
// sibling to push its servers + friends. The source announces every server it
// holds; the destination runs its join flow and the server appears (ServerJoined).
// This is the user-triggered, on-demand equivalent of the reconnect re-announce —
// guaranteed to work regardless of whether the automatic sync converged.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn manual_state_sync_pulls_servers_from_source_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity, devices B (SOURCE, owns a server) + C (DESTINATION, missing it).
    const M_MASTER: u8 = 250;
    const B_DEV: u8 = 251;
    const C_DEV: u8 = 252;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    sleep_ms(3000).await;

    // B creates a server while C is OFFLINE, so C never learns it automatically.
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;
    let server_id = create_server_and_wait(&mut b, "Manual-Sync Server").await;
    sleep_ms(1000).await;

    // C comes back, but we DON'T rely on the auto re-announce here — we drain it and
    // then explicitly drive the MANUAL sync to prove the button's path on its own.
    relay.set_online(&c.device_id, true);
    sleep_ms(3000).await; // let C↔B re-meet so the request can target B
    drain_events(&mut c);

    // C (destination) taps "Sync from this device" choosing B (source).
    c.cmd_tx
        .send(NodeCommand::RequestStateSync { source_device_id: b.device_id.clone() })
        .await
        .unwrap();

    // C must onboard the server B pushed (ServerJoined → onServerCreated → UI list).
    let c_synced = wait_event(&mut c, std::time::Duration::from_secs(12), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(
        c_synced,
        "manual state sync must make C onboard the server held by source device B (ServerJoined)"
    );
    sleep_ms(1000).await;
    assert!(
        c.servers().contains(&server_id),
        "C's server list must include the manually-synced server, got {:?}",
        c.servers()
    );
}

// ---------------------------------------------------------------------------
// Per-channel MLS subgroups (Option B): a restricted (Admin+) channel encrypts
// under its OWN MLS subgroup, so a plain Member is NOT a leaf and cannot decrypt
// it — channel visibility is cryptographically enforced, not just UI-filtered.
// Promotion adds the member to the subgroup (decrypts forward); demotion removes
// it. Driven + inspected end to end via the raw subgroup leaf set + decrypted
// channel message — no live devices.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn restricted_channel_subgroup_enforces_visibility() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner, A = will be promoted to Admin, M = stays a plain Member.
    const O_MASTER: u8 = 60;
    const A_MASTER: u8 = 61;
    const M_MASTER: u8 = 62;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    // Mutual friends so the join handshakes' Olm sessions form.
    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master, &a_master]).await;
    // Mutual friends, so all three pairs confirm; waiting on the sessions
    // themselves is both faster and louder than a fixed 5s.
    expect_dm_pair_ready(&relay, &o, &a, 20).await;
    expect_dm_pair_ready(&relay, &o, &m, 20).await;
    expect_dm_pair_ready(&relay, &a, &m, 20).await;
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    // --- Owner creates a server; A and M join. ---
    let server_id = create_server_and_wait(&mut o, "Subgroup Server").await;
    sleep_ms(500).await;

    for (node, who) in [(&mut a, "A"), (&mut m, "M")] {
        node.cmd_tx
            .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{who} should join the server");
    }
    expect_mls_group(&[&o, &a, &m], &server_id, 20).await;
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    // --- Owner creates a channel and makes it Admin+ restricted. ---
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "secret".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut restricted_cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "secret" { restricted_cid = Some(channel_id.clone()); return true; }
        }
        false
    })
    .await;
    assert!(made, "owner should create the channel");
    let restricted_cid = restricted_cid.expect("channel id");
    sleep_ms(2000).await; // ChannelAdded fans to A + M

    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            visibility: "admin".to_string(), // ChannelVisibility::AdminPlus
        })
        .await
        .unwrap();
    // Visibility op fans out; the owner (subgroup coordinator) creates the subgroup
    // and pulls qualifying members' KeyPackages; the 2s batch timer commits them.
    let subgroup = crate::crypto::subgroup_id(&server_id, &restricted_cid);
    // The subgroup exists once its coordinator (the owner) holds its own leaf.
    expect_mls_leaf(&o, &subgroup, &o.device_id, 20).await;
    // Residual window: what follows asserts who is NOT in it yet, and an
    // absence only means something once real time has passed.
    sleep_ms(800).await;

    // --- Pre-promotion: only the OWNER qualifies (owner short-circuits can_see).
    // A and M are plain Members → NOT leaves of the subgroup. ---
    let owner_sub_leaves = o.mls_members(&subgroup).await;
    assert!(
        owner_sub_leaves.contains(&o.device_id),
        "owner holds the subgroup leaf, got {owner_sub_leaves:?}"
    );
    assert!(
        !owner_sub_leaves.contains(&a.device_id),
        "plain Member A must NOT be a subgroup leaf pre-promotion, got {owner_sub_leaves:?}"
    );
    assert!(
        !owner_sub_leaves.contains(&m.device_id),
        "plain Member M must NOT be a subgroup leaf, got {owner_sub_leaves:?}"
    );
    // A doesn't hold the subgroup at all (never welcomed).
    assert!(
        !a.mls_members(&subgroup).await.contains(&a.device_id),
        "A must not hold the restricted subgroup before promotion"
    );

    // --- Owner posts to the restricted channel. A (Member) must NOT decrypt it. ---
    drain_events(&mut a);
    drain_events(&mut m);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            text: "admins only #1".to_string(),
            message_id: "sub-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let a_got_secret = wait_event(&mut a, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "admins only #1")
    })
    .await;
    assert!(!a_got_secret, "plain Member A must NOT receive/decrypt a restricted-channel message");
    assert!(
        a.channel_messages(&server_id, &restricted_cid)
            .iter().all(|r| r.text != "admins only #1"),
        "A's DB must not contain the restricted message it can't decrypt"
    );

    // --- Promote A to Admin → reconciler pulls A's KeyPackage → A joins subgroup. ---
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: a_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &subgroup, &a.device_id, 20).await;
    expect_mls_leaf(&a, &subgroup, &a.device_id, 20).await;

    let owner_sub_leaves2 = o.mls_members(&subgroup).await;
    assert!(
        owner_sub_leaves2.contains(&a.device_id),
        "after promotion A must be a subgroup leaf on the owner, got {owner_sub_leaves2:?}"
    );
    assert!(
        a.mls_members(&subgroup).await.contains(&a.device_id),
        "after promotion A must hold the subgroup itself"
    );
    // M is still a plain Member → still excluded.
    assert!(
        !owner_sub_leaves2.contains(&m.device_id),
        "M (still Member) must remain excluded from the subgroup, got {owner_sub_leaves2:?}"
    );

    // --- Owner posts again; now A (Admin) DECRYPTS it; M still cannot. ---
    drain_events(&mut a);
    drain_events(&mut m);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            text: "admins only #2".to_string(),
            message_id: "sub-msg-2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let a_got2 = wait_event(&mut a, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "admins only #2")
    })
    .await;
    assert!(a_got2, "promoted Admin A must now receive + decrypt the restricted message");
    let m_got2 = wait_event(&mut m, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "admins only #2")
    })
    .await;
    assert!(!m_got2, "plain Member M must STILL not decrypt the restricted message");

    // --- Demote A back to Member → reconciler removes A's leaf from the subgroup. ---
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: a_master.clone(),
            new_role: "member".to_string(),
        })
        .await
        .unwrap();
    expect_no_mls_leaf(&o, &subgroup, &a.device_id, 20).await;

    let owner_sub_leaves3 = o.mls_members(&subgroup).await;
    assert!(
        !owner_sub_leaves3.contains(&a.device_id),
        "after demotion A's leaf must be removed from the subgroup, got {owner_sub_leaves3:?}"
    );
}

// ---------------------------------------------------------------------------
// Label-gated channel access (issue #32). A channel gated on an ACCESS label is
// encrypted under its own MLS subgroup; only label holders (plus Admin+/Owner)
// are leaves. The gate op is paired with a legacy `visibility: admin` stamp
// (old-client fail-closed fallback) — both must replicate. Assigning the label
// admits the member (KeyPackage pull → Welcome); unassigning evicts the leaf;
// picking a plain tier clears the gate everywhere and tears the subgroup down.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn label_gated_channel_subgroup_and_fallback() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner, V = plain member who will receive the VIP label, M = stays out.
    const O_MASTER: u8 = 103;
    const V_MASTER: u8 = 104;
    const M_MASTER: u8 = 105;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let v_master = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&v_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_MASTER, &[&o_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master, &v_master]).await;
    // Mutual friends, so all three pairs confirm; waiting on the sessions
    // themselves is both faster and louder than a fixed 5s.
    expect_dm_pair_ready(&relay, &o, &v, 20).await;
    expect_dm_pair_ready(&relay, &o, &m, 20).await;
    expect_dm_pair_ready(&relay, &v, &m, 20).await;
    drain_events(&mut o);
    drain_events(&mut v);
    drain_events(&mut m);

    let server_id = create_server_and_wait(&mut o, "Label Gate Server").await;
    sleep_ms(500).await;
    for (node, who) in [(&mut v, "V"), (&mut m, "M")] {
        node.cmd_tx
            .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{who} should join the server");
    }
    expect_mls_group(&[&o, &v, &m], &server_id, 20).await;
    drain_events(&mut o);
    drain_events(&mut v);
    drain_events(&mut m);

    // --- Channel + access label. ---
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "vip-lounge".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut vip_cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "vip-lounge" { vip_cid = Some(channel_id.clone()); return true; }
        }
        false
    })
    .await;
    assert!(made, "owner should create the channel");
    let vip_cid = vip_cid.expect("channel id");
    sleep_ms(2000).await;

    o.cmd_tx
        .send(NodeCommand::CreateLabel {
            server_id: server_id.clone(),
            name: "VIP".to_string(),
            color: "#f0f".to_string(),
            access: true,
        })
        .await
        .unwrap();
    // The label id is minted in the swarm — read it back from the CRDT.
    let mut vip_label = None;
    for _ in 0..20 {
        sleep_ms(250).await;
        if let Some(state) = o.server_state(&server_id) {
            if let Some(l) = state.labels.values().find(|l| l.name == "VIP") {
                vip_label = Some(l.label_id.clone());
                break;
            }
        }
    }
    let vip_label = vip_label.expect("VIP label should exist on the owner");
    assert_eq!(o.label_access(&server_id, &vip_label), Some(true));

    // --- Gate the channel on the label. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibilityLabels {
            server_id: server_id.clone(),
            channel_id: vip_cid.clone(),
            labels: vec![vip_label.clone()],
        })
        .await
        .unwrap();
    let subgroup = crate::crypto::subgroup_id(&server_id, &vip_cid);
    // The owner founding the subgroup is live state and gets polled.
    expect_mls_leaf(&o, &subgroup, &o.device_id, 20).await;
    // The other half of this step is the stamp + gate op reaching V and M, which
    // is only visible in THEIR DBs. Nothing to poll without hammering them, and
    // the owner's own progress does not prove they got it, so this stays a real
    // window.
    sleep_ms(2000).await;

    // Gate + legacy admin stamp replicated to ALL nodes (the stamp is what an
    // old client would honor).
    for (node, who) in [(&o, "O"), (&v, "V"), (&m, "M")] {
        assert_eq!(
            node.channel_visibility(&server_id, &vip_cid).as_deref(),
            Some("admin"),
            "{who}: legacy tier must be stamped to admin"
        );
        assert_eq!(
            node.channel_visibility_labels(&server_id, &vip_cid).as_deref(),
            Some(&[vip_label.clone()][..]),
            "{who}: visibility label gate must replicate"
        );
    }
    assert!(!v.can_see_channel(&server_id, &vip_cid, &v_master), "V has no label yet");
    assert!(!m.can_see_channel(&server_id, &vip_cid, &m_master));

    let owner_leaves = o.mls_members(&subgroup).await;
    assert!(owner_leaves.contains(&o.device_id), "owner holds the subgroup leaf");
    assert!(!owner_leaves.contains(&v.device_id), "V must not be a leaf pre-label");
    assert!(!owner_leaves.contains(&m.device_id), "M must not be a leaf");

    // Not decryptable by V pre-label.
    drain_events(&mut v);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: vip_cid.clone(),
            text: "vip only #1".to_string(),
            message_id: "vip-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let v_got = wait_event(&mut v, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "vip only #1")
    })
    .await;
    assert!(!v_got, "V must NOT decrypt the gated message before holding the label");

    // --- Assign the label → V is admitted to the subgroup and decrypts. ---
    o.cmd_tx
        .send(NodeCommand::AssignLabel {
            server_id: server_id.clone(),
            label_id: vip_label.clone(),
            peer_id: v_master.clone(),
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &subgroup, &v.device_id, 20).await;
    expect_mls_leaf(&v, &subgroup, &v.device_id, 20).await;
    // Residual window for the CRDT/grant half of this step, which is only
    // readable from the node DB and so is not polled (see wait_until).
    sleep_ms(500).await;

    assert!(v.can_see_channel(&server_id, &vip_cid, &v_master), "label holder sees the channel");
    let owner_leaves2 = o.mls_members(&subgroup).await;
    assert!(
        owner_leaves2.contains(&v.device_id),
        "labeled V must be a subgroup leaf, got {owner_leaves2:?}"
    );
    assert!(
        v.mls_members(&subgroup).await.contains(&v.device_id),
        "V must hold the subgroup itself"
    );

    drain_events(&mut v);
    drain_events(&mut m);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: vip_cid.clone(),
            text: "vip only #2".to_string(),
            message_id: "vip-msg-2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let v_got2 = wait_event(&mut v, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "vip only #2")
    })
    .await;
    assert!(v_got2, "labeled V must decrypt the gated message");
    let m_got2 = wait_event(&mut m, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "vip only #2")
    })
    .await;
    assert!(!m_got2, "unlabeled M must still not decrypt");

    // --- Unassign → V's leaf is evicted. ---
    o.cmd_tx
        .send(NodeCommand::UnassignLabel {
            server_id: server_id.clone(),
            label_id: vip_label.clone(),
            peer_id: v_master.clone(),
        })
        .await
        .unwrap();
    expect_no_mls_leaf(&o, &subgroup, &v.device_id, 20).await;
    // Residual window for the CRDT/grant half of this step, which is only
    // readable from the node DB and so is not polled (see wait_until).
    sleep_ms(500).await;
    let owner_leaves3 = o.mls_members(&subgroup).await;
    assert!(
        !owner_leaves3.contains(&v.device_id),
        "unassigned V's leaf must be removed, got {owner_leaves3:?}"
    );
    assert!(!v.can_see_channel(&server_id, &vip_cid, &v_master));

    // --- Picking a plain tier clears the gate everywhere + tears down. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: vip_cid.clone(),
            visibility: "everyone".to_string(),
        })
        .await
        .unwrap();
    let mut cleared_everywhere = false;
    for _ in 0..20 {
        sleep_ms(500).await;
        let all_clear = [&o, &v, &m].iter().all(|n| {
            n.channel_visibility(&server_id, &vip_cid).as_deref() == Some("everyone")
                && n.channel_visibility_labels(&server_id, &vip_cid)
                    .is_some_and(|l| l.is_empty())
        });
        if all_clear { cleared_everywhere = true; break; }
    }
    assert!(cleared_everywhere, "tier pick must clear the label gate on every node");
    assert!(m.can_see_channel(&server_id, &vip_cid, &m_master), "everyone sees again");
    assert!(
        o.mls_members(&subgroup).await.is_empty(),
        "subgroup must be torn down once the channel is unrestricted"
    );
}

// ---------------------------------------------------------------------------
// Access labels are NOT self-assignable (that would be privilege escalation —
// the label gates channels). The authoring gate refuses locally and the
// `op_allowed` ingest gate refuses remotely; cosmetic labels keep self-service.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn access_label_self_assign_locked() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 106;
    const M_MASTER: u8 = 107;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &m, 15).await;
    drain_events(&mut o);
    drain_events(&mut m);

    let server_id = create_server_and_wait(&mut o, "Lockdown Server").await;
    sleep_ms(500).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut m, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "M should join");
    sleep_ms(3000).await;

    // Owner creates one access label and one cosmetic label.
    for (name, access) in [("Staff", true), ("Fun", false)] {
        o.cmd_tx
            .send(NodeCommand::CreateLabel {
                server_id: server_id.clone(),
                name: name.to_string(),
                color: "#fff".to_string(),
                access,
            })
            .await
            .unwrap();
    }
    let mut staff_label = None;
    let mut fun_label = None;
    for _ in 0..20 {
        sleep_ms(250).await;
        if let Some(state) = m.server_state(&server_id) {
            staff_label = state.labels.values().find(|l| l.name == "Staff").map(|l| l.label_id.clone());
            fun_label = state.labels.values().find(|l| l.name == "Fun").map(|l| l.label_id.clone());
            if staff_label.is_some() && fun_label.is_some() { break; }
        }
    }
    let staff_label = staff_label.expect("Staff label replicated to M");
    let fun_label = fun_label.expect("Fun label replicated to M");
    assert_eq!(m.label_access(&server_id, &staff_label), Some(true));
    drain_events(&mut m);

    // M tries to self-assign the ACCESS label → refused at authoring.
    m.cmd_tx
        .send(NodeCommand::AssignLabel {
            server_id: server_id.clone(),
            label_id: staff_label.clone(),
            peer_id: m_master.clone(),
        })
        .await
        .unwrap();
    let denied = wait_event(&mut m, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("cannot manage labels"))
    })
    .await;
    assert!(denied, "self-assigning an access label must be refused with an Error event");
    sleep_ms(2000).await;
    assert!(
        o.member_label_ids(&server_id, &m_master).is_empty(),
        "the refused access-label assignment must not land on the owner"
    );
    assert!(
        m.member_label_ids(&server_id, &m_master).is_empty(),
        "the refused assignment must not land locally either"
    );

    // Cosmetic self-assign still works and replicates.
    m.cmd_tx
        .send(NodeCommand::AssignLabel {
            server_id: server_id.clone(),
            label_id: fun_label.clone(),
            peer_id: m_master.clone(),
        })
        .await
        .unwrap();
    let mut fun_on_owner = false;
    for _ in 0..20 {
        sleep_ms(500).await;
        if o.member_label_ids(&server_id, &m_master).contains(&fun_label) {
            fun_on_owner = true;
            break;
        }
    }
    assert!(fun_on_owner, "cosmetic self-assign must replicate to the owner");

    // A MANAGE_ROLES holder (owner) CAN assign the access label to M.
    o.cmd_tx
        .send(NodeCommand::AssignLabel {
            server_id: server_id.clone(),
            label_id: staff_label.clone(),
            peer_id: m_master.clone(),
        })
        .await
        .unwrap();
    let mut staff_on_m = false;
    for _ in 0..20 {
        sleep_ms(500).await;
        if m.member_label_ids(&server_id, &m_master).contains(&staff_label) {
            staff_on_m = true;
            break;
        }
    }
    assert!(staff_on_m, "owner-assigned access label must replicate to M");
}

// ---------------------------------------------------------------------------
// Temporary channel access grants — MLS lifecycle. A grant admits a plain
// Member to a restricted channel's subgroup (decryptable); revoking evicts the
// leaf and hides the channel again.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_grant_lifecycle_mls() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 108;
    const M_MASTER: u8 = 109;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &m, 15).await;
    drain_events(&mut o);
    drain_events(&mut m);

    let server_id = create_server_and_wait(&mut o, "Grant Server").await;
    sleep_ms(500).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut m, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "M should join");
    sleep_ms(3000).await;

    // Restricted channel M cannot see.
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "war-room".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "war-room" { cid = Some(channel_id.clone()); return true; }
        }
        false
    })
    .await;
    assert!(made);
    let cid = cid.expect("channel id");
    sleep_ms(2000).await;
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(6000).await;
    assert!(!m.can_see_channel(&server_id, &cid, &m_master));
    let subgroup = crate::crypto::subgroup_id(&server_id, &cid);
    assert!(!o.mls_members(&subgroup).await.contains(&m.device_id));

    // Grant M open-ended access → admitted to the subgroup, decrypts.
    o.cmd_tx
        .send(NodeCommand::GrantChannelAccess {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            peer_id: m_master.clone(),
            expires_at: u64::MAX,
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &subgroup, &m.device_id, 20).await;
    // Residual window for the CRDT/grant half of this step, which is only
    // readable from the node DB and so is not polled (see wait_until).
    sleep_ms(500).await;
    assert!(m.has_grant_now(&server_id, &cid, &m_master), "grant must replicate to M");
    assert!(m.can_see_channel(&server_id, &cid, &m_master), "granted M sees the channel");
    let leaves = o.mls_members(&subgroup).await;
    assert!(leaves.contains(&m.device_id), "granted M must be a subgroup leaf, got {leaves:?}");

    drain_events(&mut m);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            text: "guest pass".to_string(),
            message_id: "grant-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let m_got = wait_event(&mut m, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "guest pass")
    })
    .await;
    assert!(m_got, "granted M must decrypt the restricted message");

    // Revoke → leaf evicted, channel hidden again.
    o.cmd_tx
        .send(NodeCommand::RevokeChannelAccess {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            peer_id: m_master.clone(),
        })
        .await
        .unwrap();
    expect_no_mls_leaf(&o, &subgroup, &m.device_id, 20).await;
    // Residual window for the CRDT/grant half of this step, which is only
    // readable from the node DB and so is not polled (see wait_until).
    sleep_ms(500).await;
    assert!(!m.has_grant_now(&server_id, &cid, &m_master), "revoke must replicate");
    assert!(!m.can_see_channel(&server_id, &cid, &m_master));
    let leaves2 = o.mls_members(&subgroup).await;
    assert!(!leaves2.contains(&m.device_id), "revoked M's leaf must be evicted, got {leaves2:?}");
}

// ---------------------------------------------------------------------------
// Temporary grant EXPIRY. The predicate denies lazily the instant the clock
// passes `expires_at` (NO revoke op — mute precedent); the cfg(test) 2s sweep
// then drives the MLS leaf removal so the member also loses the key material.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_grant_expiry_sweep() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 111;
    const M_MASTER: u8 = 112;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &m, 15).await;
    drain_events(&mut o);
    drain_events(&mut m);

    let server_id = create_server_and_wait(&mut o, "Expiry Server").await;
    sleep_ms(500).await;
    m.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut m, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "M should join");
    sleep_ms(3000).await;

    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "airlock".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "airlock" { cid = Some(channel_id.clone()); return true; }
        }
        false
    })
    .await;
    assert!(made);
    let cid = cid.expect("channel id");
    sleep_ms(2000).await;
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    let subgroup = crate::crypto::subgroup_id(&server_id, &cid);
    // The subgroup exists once its coordinator (the owner) holds its own leaf.
    expect_mls_leaf(&o, &subgroup, &o.device_id, 20).await;
    // Residual window: what follows asserts who is NOT in it yet, and an
    // absence only means something once real time has passed.
    sleep_ms(800).await;

    // 10-second grant: long enough for the subgroup admission to complete,
    // short enough to observe the expiry inside the test.
    let expires_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
        + 10_000;
    o.cmd_tx
        .send(NodeCommand::GrantChannelAccess {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            peer_id: m_master.clone(),
            expires_at,
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &subgroup, &m.device_id, 20).await;
    // Residual window for the CRDT/grant half of this step, which is only
    // readable from the node DB and so is not polled (see wait_until).
    sleep_ms(500).await;
    assert!(m.has_grant_now(&server_id, &cid, &m_master), "grant active mid-window");
    assert!(m.can_see_channel(&server_id, &cid, &m_master));
    assert!(
        o.mls_members(&subgroup).await.contains(&m.device_id),
        "granted M must be admitted to the subgroup before expiry"
    );

    // Wait past expiry: the predicate flips immediately with NO revoke op.
    // Against the DEADLINE, not for a duration, because the steps above no
    // longer take a fixed amount of time.
    sleep_until_ms(expires_at, 1_000).await;
    assert!(!m.has_grant_now(&server_id, &cid, &m_master), "expired grant reads as denied (lazy)");
    assert!(!m.can_see_channel(&server_id, &cid, &m_master));

    // The 2s cfg(test) sweep + 2s MLS batch then evict M's leaf.
    let mut evicted = false;
    for _ in 0..12 {
        sleep_ms(1000).await;
        if !o.mls_members(&subgroup).await.contains(&m.device_id) {
            evicted = true;
            break;
        }
    }
    assert!(evicted, "the expiry sweep must remove M's subgroup leaf");

    // A fresh message is not decryptable by the expired guest.
    drain_events(&mut m);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            text: "after hours".to_string(),
            message_id: "expiry-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let m_got = wait_event(&mut m, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "after hours")
    })
    .await;
    assert!(!m_got, "expired guest must not decrypt fresh messages");
}

// ---------------------------------------------------------------------------
// Per-channel MLS subgroups — PHASE 2 (VOICE). A RESTRICTED voice channel derives
// its SFrame media key from the channel's own MLS SUBGROUP, not the server-wide
// group. The harness can't drive the WebRTC media plane, so it verifies the
// KEY LAYER: only members whose role satisfies the channel's visibility tier are
// leaves of the voice subgroup (== the only nodes that can `export_secret` the
// SFrame key). A non-qualifying Member is excluded → can't derive the key → would
// decode nothing; the Rust VC-join guard additionally REJECTS its join outright.
// Promotion adds it to the subgroup; demotion removes it (mid-call re-key / fwd
// secrecy). Mirrors the text test but on a `voice` channel.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn restricted_voice_channel_subgroup_enforces_sframe_membership() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner, A = promoted to Admin, M = stays a plain Member.
    const O_MASTER: u8 = 80;
    const A_MASTER: u8 = 81;
    const M_MASTER: u8 = 82;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master, &m_master]).await;
    sleep_ms(1500).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master, &a_master]).await;
    // Mutual friends, so all three pairs confirm; waiting on the sessions
    // themselves is both faster and louder than a fixed 5s.
    expect_dm_pair_ready(&relay, &o, &a, 20).await;
    expect_dm_pair_ready(&relay, &o, &m, 20).await;
    expect_dm_pair_ready(&relay, &a, &m, 20).await;
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    // --- Owner creates a server; A and M join. ---
    let server_id = create_server_and_wait(&mut o, "Voice Subgroup Server").await;
    sleep_ms(500).await;

    for (node, who) in [(&mut a, "A"), (&mut m, "M")] {
        node.cmd_tx
            .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{who} should join the server");
    }
    // Wait until ALL THREE distinct identities are leaves of the server-wide MLS
    // group — the precondition for an MLS-broadcast ChannelAdded op to reach them.
    // (Batch-add commits happen on a 2s timer; give it room.)
    //
    // The budget is 60s, not the 24s this used to allow. On a coverage-
    // instrumented CI runner this test takes ~94s against ~40s locally, and
    // under that squeeze the three sequential batch-add commits overran 24s:
    // the test flaked at THIS setup assert while the SFrame behaviour it
    // actually covers was never reached — green in the Rust Coverage job and
    // red in the Sonar job on the very SAME commit (2026-08-15). The loop exits
    // as soon as the leaves converge, so a healthy run costs what it did before.
    // 24s was also the shortest budget of any comparable multi-identity wait in
    // this file (siblings use 15-25 iterations); this brings it in line.
    let mut srv_ok = false;
    let mut last_leaves: Vec<String> = Vec::new();
    for _ in 0..30 {
        expect_mls_group(&[&o, &a, &m], &server_id, 20).await;
        let leaves = o.mls_members(&server_id).await;
        if leaves.contains(&o.device_id)
            && leaves.contains(&a.device_id)
            && leaves.contains(&m.device_id)
        {
            srv_ok = true;
            break;
        }
        last_leaves = leaves;
    }
    // Name the missing leaf: "must join the MLS group" alone cannot tell a real
    // convergence bug from a slow runner.
    assert!(
        srv_ok,
        "all three members must join the server-wide MLS group — \
         last leaves {last_leaves:?}, missing O={} A={} M={}",
        !last_leaves.contains(&o.device_id),
        !last_leaves.contains(&a.device_id),
        !last_leaves.contains(&m.device_id),
    );
    drain_events(&mut o);
    drain_events(&mut a);
    drain_events(&mut m);

    // --- Owner creates a VOICE channel, makes it Admin+ restricted. ---
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "war-room".to_string(),
            category: None,
            channel_type: "voice".to_string(),
        })
        .await
        .unwrap();
    let mut voice_cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, channel_type, name, .. } = ev {
            if channel_type == "voice" && name == "war-room" {
                voice_cid = Some(channel_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(made, "owner should create the voice channel");
    let voice_cid = voice_cid.expect("voice channel id");

    // Ensure the ChannelAdded op actually reaches A and M's STATE before we
    // restrict it (poll the store — the event may already be consumed/buffered).
    let mut chan_ok = false;
    for _ in 0..10 {
        sleep_ms(1000).await;
        if a.channel_visibility(&server_id, &voice_cid).is_some()
            && m.channel_visibility(&server_id, &voice_cid).is_some()
        {
            chan_ok = true;
            break;
        }
    }
    assert!(chan_ok, "A and M must receive the new voice channel");

    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            visibility: "admin".to_string(), // AdminPlus
        })
        .await
        .unwrap();
    let subgroup = crate::crypto::subgroup_id(&server_id, &voice_cid);
    // The subgroup exists once its coordinator (the owner) holds its own leaf.
    expect_mls_leaf(&o, &subgroup, &o.device_id, 20).await;
    // Residual window: what follows asserts who is NOT in it yet, and an
    // absence only means something once real time has passed.
    sleep_ms(800).await;

    // --- Pre-promotion: only the OWNER is a subgroup leaf (== SFrame holder). ---
    let leaves0 = o.mls_members(&subgroup).await;
    assert!(
        leaves0.contains(&o.device_id),
        "owner must hold the voice subgroup leaf, got {leaves0:?}"
    );
    assert!(
        !leaves0.contains(&a.device_id) && !leaves0.contains(&m.device_id),
        "plain Members A/M must NOT be voice-subgroup leaves pre-promotion, got {leaves0:?}"
    );
    // M must actually HAVE the channel (propagated) and see it as restricted —
    // otherwise `can_see_channel` would be false simply because the channel is
    // unknown, which is NOT the property we're testing.
    assert_eq!(
        m.channel_visibility(&server_id, &voice_cid).as_deref(),
        Some("admin"),
        "M must have the voice channel with admin visibility before the rejection test"
    );
    assert!(
        !m.can_see_channel(&server_id, &voice_cid, &m.device_id),
        "plain Member M must not be permitted to see the restricted voice channel"
    );

    // --- M (Member) tries to JOIN the restricted voice channel → REJECTED. ---
    // The Rust VC-join guard returns early; M emits no local VoiceChannelJoined and
    // the owner never sees M enter. (M also never holds the subgroup, so even a
    // modified client that bypassed the guard could not derive the SFrame key.)
    drain_events(&mut m);
    drain_events(&mut o);
    m.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let m_self_joined = wait_event(&mut m, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(!m_self_joined, "non-qualifying Member M's join to a restricted voice channel must be rejected");
    let o_saw_m = wait_event(&mut o, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(!o_saw_m, "owner must not see a rejected member enter the restricted voice channel");

    // --- Promote A to Admin → reconciler adds A to the voice subgroup. ---
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: a_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &subgroup, &a.device_id, 20).await;
    expect_mls_leaf(&a, &subgroup, &a.device_id, 20).await;

    let leaves1 = o.mls_members(&subgroup).await;
    assert!(
        leaves1.contains(&a.device_id),
        "after promotion A must be a voice-subgroup leaf (SFrame holder), got {leaves1:?}"
    );
    assert!(
        a.mls_members(&subgroup).await.contains(&a.device_id),
        "after promotion A must hold the voice subgroup itself (can export SFrame)"
    );
    assert!(
        !leaves1.contains(&m.device_id),
        "M (still Member) must remain excluded from the voice subgroup, got {leaves1:?}"
    );

    // A must see the channel as restricted (admin) so its VC-join derives the
    // SFrame key from the SUBGROUP, not the server group.
    assert_eq!(
        a.channel_visibility(&server_id, &voice_cid).as_deref(),
        Some("admin"),
        "A must see the voice channel as admin-restricted before joining"
    );

    // --- A (Admin) now joins the voice channel — allowed; participates. ---
    drain_events(&mut o);
    a.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let a_joined = wait_event(&mut a, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(a_joined, "promoted Admin A must be allowed to join the restricted voice channel");

    // --- Demote A back to Member → reconciler removes A's leaf (mid-call re-key). ---
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: a_master.clone(),
            new_role: "member".to_string(),
        })
        .await
        .unwrap();
    expect_no_mls_leaf(&o, &subgroup, &a.device_id, 20).await;

    let leaves2 = o.mls_members(&subgroup).await;
    assert!(
        !leaves2.contains(&a.device_id),
        "after demotion A's voice-subgroup leaf must be removed (loses SFrame key), got {leaves2:?}"
    );
}

// ---------------------------------------------------------------------------
// Real-time channel visibility/posting propagation to a REMOTE member. The UI
// reads channel visibility/posting + role from the local DB (get_server_channels
// / getMyRole) and recomputes visibleChannelsProvider / canPostInChannelProvider.
// This test proves the DATA LAYER those providers read reflects a LIVE change on
// the receiving member (the contract the Dart reactivity fix depends on), and
// that an offline member catches up on reconnect. No live devices / UI.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_visibility_posting_propagate_to_remote_member_realtime() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner (admin tier), V = a plain Member viewer.
    const O_MASTER: u8 = 70;
    const V_MASTER: u8 = 71;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let v_master = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&v_master]).await;
    sleep_ms(1500).await;
    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &v, 15).await;

    let server_id = create_server_and_wait(&mut o, "Vis Server").await;
    sleep_ms(500).await;
    v.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut v, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "V should join");
    sleep_ms(3000).await;

    // Owner creates a channel. Both start seeing it as "everyone".
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "topic".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut cid = None;
    wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "topic" { cid = Some(channel_id.clone()); return true; }
        }
        false
    })
    .await;
    let cid = cid.expect("channel id");
    sleep_ms(2500).await; // ChannelAdded fans to V

    // Baseline: V (plain Member) sees the channel as "everyone" and CAN see it.
    assert_eq!(v.channel_visibility(&server_id, &cid).as_deref(), Some("everyone"),
        "V's DB shows the new channel as everyone-visible");
    assert!(v.can_see_channel(&server_id, &cid, &v_master),
        "V (Member) can see an everyone channel");
    assert_eq!(v.channel_posting(&server_id, &cid).as_deref(), Some("everyone"),
        "V's DB shows everyone-posting baseline");

    // --- LIVE visibility change: owner restricts the channel to Admin+. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    // Poll V's DB-backed view (what the UI reads) until it reflects the change.
    let mut vis_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        if v.channel_visibility(&server_id, &cid).as_deref() == Some("admin") {
            vis_ok = true;
            break;
        }
    }
    assert!(vis_ok, "V's DB must reflect the LIVE visibility change to admin (got {:?})",
        v.channel_visibility(&server_id, &cid));
    // The exact predicate visibleChannelsProvider uses now hides it for V.
    assert!(!v.can_see_channel(&server_id, &cid, &v_master),
        "V (Member) must NOT be able to see an Admin+ channel after the live change → UI hides + evicts");

    // --- LIVE posting change: set a (now-admin) channel back to everyone-visible
    // but moderator-only posting, and confirm V's DB reflects posting too. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            visibility: "everyone".to_string(),
        })
        .await
        .unwrap();
    o.cmd_tx
        .send(NodeCommand::SetChannelPosting {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            posting: "moderator".to_string(),
        })
        .await
        .unwrap();
    let mut post_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        let vis = v.channel_visibility(&server_id, &cid);
        let post = v.channel_posting(&server_id, &cid);
        if vis.as_deref() == Some("everyone") && post.as_deref() == Some("moderator") {
            post_ok = true;
            break;
        }
    }
    assert!(post_ok, "V's DB must reflect the LIVE posting change to moderator + visibility back to everyone (got vis={:?} post={:?})",
        v.channel_visibility(&server_id, &cid), v.channel_posting(&server_id, &cid));
    // V can SEE it again (everyone) but the input bar locks (Member can't post in moderator+).
    assert!(v.can_see_channel(&server_id, &cid, &v_master), "V sees the everyone channel again");

    // --- ABSENT-DURING-CHANGE catch-up: a member that was NOT present when the
    // visibility was changed must converge to the restricted state when it (re)joins
    // — the "join pulls the latest CRDT" path the user observed already works, and
    // this locks it in. (The harness spawns a fresh DB per node, so the rejoiner is
    // a clean member pulling current state — the same convergence guarantee.) ---
    drop(v); // V leaves the relay (drops its WS room presence)
    sleep_ms(1500).await;
    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(1500).await;

    let mut v2 = spawn_node_with_friends(&relay, V_MASTER, V_MASTER, &[&o_master]).await;
    v2.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let mut caught_up = false;
    for _ in 0..25 {
        sleep_ms(400).await;
        if v2.channel_visibility(&server_id, &cid).as_deref() == Some("admin") {
            caught_up = true;
            break;
        }
    }
    assert!(caught_up, "a member joining after the change must converge to the restricted visibility (got {:?})",
        v2.channel_visibility(&server_id, &cid));
    assert!(!v2.can_see_channel(&server_id, &cid, &v_master),
        "after catch-up, V can't see the now-Admin+ channel");
}

// ---------------------------------------------------------------------------
// MODERATION TRIO: mute (timed + permanent), per-channel slow mode, and
// media-only channels. Covers: CRDT convergence of all three settings to a
// remote member, send-side rejection (the Error events the input bar toasts),
// unmute/expiry restoring posting, and the Moderator+ slow-mode exemption.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn moderation_trio_mute_slowmode_mediaonly() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 72; // owner
    const V_MASTER: u8 = 73; // plain member
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let v_master = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&v_master]).await;
    sleep_ms(1500).await;
    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &v, 15).await;

    let server_id = create_server_and_wait(&mut o, "Mod Server").await;
    sleep_ms(500).await;
    v.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut v, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "V should join");
    sleep_ms(3000).await;
    let general = general_channel_of(&server_id);

    // --- Baseline: V can post. ---
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "baseline".to_string(),
            message_id: "mod-m0".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let got = wait_event(&mut o, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "baseline")
    })
    .await;
    assert!(got, "owner receives V's baseline message");

    // --- PERMANENT MUTE: converges to V, V's send is rejected. ---
    o.cmd_tx
        .send(NodeCommand::MuteMember {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
            expires_at: u64::MAX,
        })
        .await
        .unwrap();
    let mut muted_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        if v.is_muted_now(&server_id, &v_master) { muted_ok = true; break; }
    }
    assert!(muted_ok, "V's own CRDT must show V as muted (permanent)");

    drain_events(&mut v);
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "while-muted".to_string(),
            message_id: "mod-m1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let rejected = wait_event(&mut v, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("muted"))
    })
    .await;
    assert!(rejected, "muted V's send must be rejected with the muted error");
    sleep_ms(1000).await;
    assert!(
        !o.channel_messages(&server_id, &general).iter().any(|m| m.text == "while-muted"),
        "owner must never store a message a muted member tried to send"
    );

    // --- UNMUTE restores posting. ---
    o.cmd_tx
        .send(NodeCommand::UnmuteMember {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
        })
        .await
        .unwrap();
    let mut unmuted_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        if !v.is_muted_now(&server_id, &v_master) { unmuted_ok = true; break; }
    }
    assert!(unmuted_ok, "unmute must converge to V");
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "unmuted-again".to_string(),
            message_id: "mod-m2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let got = wait_event(&mut o, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "unmuted-again")
    })
    .await;
    assert!(got, "after unmute V can post again");

    // --- TIMED MUTE expires on its own (no unmute op). ---
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    o.cmd_tx
        .send(NodeCommand::MuteMember {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
            expires_at: now_ms + 4000,
        })
        .await
        .unwrap();
    let mut timed_ok = false;
    for _ in 0..10 {
        sleep_ms(250).await;
        if v.is_muted_now(&server_id, &v_master) { timed_ok = true; break; }
    }
    assert!(timed_ok, "timed mute must converge while active");
    sleep_ms(4500).await; // let it lapse
    assert!(!v.is_muted_now(&server_id, &v_master),
        "an expired timed mute must read as unmuted with NO unmute op");
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "after-expiry".to_string(),
            message_id: "mod-m3".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let got = wait_event(&mut o, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "after-expiry")
    })
    .await;
    assert!(got, "V can post after the timed mute lapses");

    // --- SLOW MODE: 5s window; Member throttled, Owner exempt. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelSlowMode {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            seconds: 5,
        })
        .await
        .unwrap();
    let mut slow_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        if v.channel_slow_mode(&server_id, &general) == Some(5) { slow_ok = true; break; }
    }
    assert!(slow_ok, "slow_mode=5 must converge to V");

    // Ensure V's previous message is outside the 5s window, then send two fast.
    sleep_ms(5200).await;
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "slow-1".to_string(),
            message_id: "mod-m4".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    sleep_ms(400).await; // local persist lands; still deep inside the window
    drain_events(&mut v);
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "slow-2".to_string(),
            message_id: "mod-m5".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let throttled = wait_event(&mut v, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("Slow mode"))
    })
    .await;
    assert!(throttled, "V's second rapid send must hit the slow-mode gate");
    sleep_ms(1000).await;
    let o_msgs = o.channel_messages(&server_id, &general);
    assert!(o_msgs.iter().any(|m| m.text == "slow-1"), "slow-1 arrives at owner");
    assert!(!o_msgs.iter().any(|m| m.text == "slow-2"),
        "slow-2 must never reach the owner (throttled at V's send)");

    // Owner is Moderator+ → exempt: two back-to-back sends both land at V.
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "owner-fast-1".to_string(),
            message_id: "mod-m6".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "owner-fast-2".to_string(),
            message_id: "mod-m7".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let got = wait_event(&mut v, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "owner-fast-2")
    })
    .await;
    assert!(got, "owner (Moderator+ exempt) posts through slow mode unthrottled");
    let v_msgs = v.channel_messages(&server_id, &general);
    assert!(v_msgs.iter().any(|m| m.text == "owner-fast-1"),
        "V stored the owner's first rapid message too (exempt sender not dropped at ingest)");

    // --- MEDIA-ONLY: text-only sends are rejected. ---
    o.cmd_tx
        .send(NodeCommand::SetChannelMediaOnly {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            media_only: true,
        })
        .await
        .unwrap();
    let mut media_ok = false;
    for _ in 0..20 {
        sleep_ms(300).await;
        if v.channel_media_only(&server_id, &general) == Some(true) { media_ok = true; break; }
    }
    assert!(media_ok, "media_only=true must converge to V");

    sleep_ms(5200).await; // clear V's slow-mode window so only media-only can reject
    drain_events(&mut v);
    v.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "text-in-media-only".to_string(),
            message_id: "mod-m8".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let rejected = wait_event(&mut v, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("media-only"))
    })
    .await;
    assert!(rejected, "text-only send into a media-only channel must be rejected");
    sleep_ms(1000).await;
    assert!(
        !o.channel_messages(&server_id, &general).iter().any(|m| m.text == "text-in-media-only"),
        "owner must never store the rejected text-only message"
    );
}

// ---------------------------------------------------------------------------
// ANTI-MIS-LINK (the security fix): a friend request between two DISTINCT
// identities must NEVER fuse them. Sending a friend request makes the requester
// join the TARGET's `inbox:{target}` room to deliver — which used to trip the
// inbox-proof, mis-merging the stranger as the target's own sibling device
// (resolver poison + device-list merge + friend-list leak + auto snapshot/link),
// and swallowing the real request as a "self friend request". With the
// cryptographic sibling-proof handshake, the stranger (holding only ITS OWN
// master key) cannot answer the target's nonce challenge, so NO merge happens and
// the request flows normally.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn friend_request_between_strangers_does_not_merge() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A and B are TWO DISTINCT identities (different master tags → different master
    // keys), each a single device. They are NOT siblings and NOT yet friends. The
    // resolver is NOT pre-seeded for either (test_guard cleared it) — so a buggy
    // inbox-proof would be the ONLY thing that could link them.
    const A_MASTER: u8 = 1;
    const A_DEV: u8 = 2;
    const B_MASTER: u8 = 3;
    const B_DEV: u8 = 4;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let a_dev = NativeKeypair::from_secret_bytes(&seed_bytes(A_DEV)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await; // let both join their own inbox rooms + settle
    drain_events(&mut a);
    drain_events(&mut b);

    // A sends B a friend request → A joins inbox:{b_master} to deliver. B's inbox
    // handler sees A's device and (post-fix) challenges it; A can't answer.
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();

    // B must receive a NORMAL pending INCOMING friend request — NOT have it swallowed
    // as a "self friend request (own device)". A is single-device and hasn't shared a
    // device list, so from B's side A's identity IS A's sending DEVICE id (B has no
    // device→master link for A — and crucially must NOT fabricate one).
    let b_got_request = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id } if *peer_id == a_dev)
    })
    .await;
    assert!(
        b_got_request,
        "B must receive a normal incoming friend request from A (not swallowed as self)"
    );
    sleep_ms(2000).await; // give any (buggy) merge / handshake the time to (not) happen

    // --- THE SECURITY ASSERTIONS: A and B remain DISTINCT identities ---
    assert!(
        !super::resolver::same_identity(&a_master, &b_master),
        "A and B must remain distinct identities after a friend request"
    );
    assert!(
        !super::resolver::same_identity(&a_dev, &b_master),
        "A's device must NOT resolve to B's master (no resolver poisoning)"
    );
    assert!(
        !super::resolver::same_identity(&b_dev, &a_master),
        "B's device must NOT resolve to A's master (symmetric — no poisoning either way)"
    );

    // B must NOT have merged A's device into B's own master-signed device list.
    let b_devices = super::resolver::devices_for(&b_master);
    assert!(
        !b_devices.contains(&a_dev),
        "B's device set must NOT contain A's device (no inbox-proof mis-merge), got {b_devices:?}"
    );
    if let Ok(Some(list)) = b.store().load_device_list(&b_master) {
        assert!(
            !list.devices.contains(&a_dev),
            "B's PERSISTED device list must not contain A's device, got {:?}",
            list.devices
        );
    }
    // Symmetric: A must not have merged B's device.
    let a_devices = super::resolver::devices_for(&a_master);
    assert!(
        !a_devices.contains(&b_dev),
        "A's device set must NOT contain B's device, got {a_devices:?}"
    );

    // B's incoming-friend row is genuinely pending/incoming (the normal flow ran).
    // It is keyed by A's MASTER (friend save sites resolve device→master; B learned
    // A's device→master from A's published device list). If B hadn't learned the
    // mapping yet it would key under the device id — accept either, but it must be
    // one of A's ids and NOT collapsed into B's own identity.
    let b_friends = b.store().load_friends(None).unwrap_or_default();
    assert!(
        b_friends.iter().any(|(pid, status, dir, _, _)| {
            (*pid == a_master || *pid == a_dev) && status == "pending" && dir == "incoming"
        }),
        "B must hold a pending INCOMING friend row for A (master or device), got {b_friends:?}"
    );
    // And that row must key on A, never on B's own identity.
    assert!(
        b_friends.iter().all(|(pid, _, _, _, _)| !super::resolver::same_identity(pid, &b_master)),
        "no friend row may be keyed under B's own identity, got {b_friends:?}"
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Friend convergence across DEVICE≠MASTER (the VM/AL bug): when A friend-requests
// B (whose device id ≠ master id) and B accepts, A must LEARN B's device→master
// mapping and end with a SINGLE accepted friend keyed by B's MASTER — not a split
// (incoming under B's device id + outgoing under B's master). The fix: the friend
// handlers push our profile+device-list to the peer over the durable room (the
// `is_new` gate otherwise suppressed it after the transient inbox window).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn friend_converges_to_master_across_distinct_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A and B are distinct identities, EACH with device != master (the VM/AL shape).
    const A_MASTER: u8 = 8;
    const A_DEV: u8 = 9;
    const B_MASTER: u8 = 11;
    const B_DEV: u8 = 12;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A requests B (by master). B accepts.
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(b_got, "B must receive A's friend request");
    sleep_ms(2000).await; // let the profile/device-list pushes propagate both ways
    drain_events(&mut a);
    drain_events(&mut b);

    // --- THE CORE FIX: A learned B's device→master mapping (the pushed device list).
    // This is what was BROKEN: A's only chance to ingest B's device list was the
    // transient inbox window, then the is_new gate suppressed it forever, so A never
    // collapsed B's device→master. The friend handlers now push the device list over
    // the durable room. ---
    assert_eq!(
        super::resolver::resolve(&b_dev), b_master,
        "A must resolve B's device → B's master after the device-list push (the fix)"
    );

    // --- A's friend row for B is keyed by B's MASTER and is SINGULAR (no split into a
    // device-keyed + a master-keyed row). Status may be pending or accepted depending
    // on accept-delivery timing — the keying is what this test pins. ---
    let a_friends = a.store().load_friends(None).unwrap_or_default();
    let b_rows: Vec<_> = a_friends.iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &b_master))
        .collect();
    assert_eq!(
        b_rows.len(), 1,
        "A must have exactly ONE friend row for B (no device/master split), got {a_friends:?}"
    );
    assert_eq!(b_rows[0].0, b_master, "A's friend row for B must be keyed by B's MASTER");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Showcase board replication (profile field, 2026-07): A's board JSON rides
// ProfileUpdate to B and lands keyed by A's MASTER (A uses device != master);
// a later update that doesn't touch the board (input None → the handler
// rebroadcasts the STORED value) must not lose it; Some("") clears it.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn showcase_board_replicates_preserves_and_clears() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 61;
    const A_DEV: u8 = 62;
    const B_MASTER: u8 = 63;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let send_update = |status: &str, board: Option<String>, assets: Option<Vec<u8>>| NodeCommand::UpdateProfile {
        display_name: "Anon A".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: board,
        showcase_assets: assets,
        avatar_frame: None,
        avatar_anim: None,
        banner_anim: None,
    };

    // --- 1. A composes an ENRICHED game-block board (+ a two-asset bundle:
    // cover + company logo) → B stores both under A's MASTER. The baked game
    // card (Steam/IGDB details, dev credit with a logo asset) replicates
    // exactly like any board: JSON is opaque, images ride the bundle. This
    // exercises the multi-asset (cover + logo) replication path. ---
    use sha2::{Digest, Sha256};
    let cover_bytes = vec![7u8; 512];
    let cover_hash = hex::encode(Sha256::digest(&cover_bytes));
    let logo_bytes = vec![9u8; 256];
    let logo_hash = hex::encode(Sha256::digest(&logo_bytes));
    // A favorite-game block carrying baked details: the cover hash, and a
    // company whose logo references the logo asset hash (URL already rewritten
    // to a hash at authoring, per the composer).
    let board = format!(
        r#"{{"v":1,"right":[{{"t":"favorite_game","d":{{"name":"Hollow Knight","cover":"{cover}","year":2017,"blurb":"peak","details":{{"description":"A hand-drawn Metroidvania.","platforms":["pc","mac","linux","nintendo"],"metacritic":90,"achievements":63,"req_min":"OS: Win10\nRAM: 4 GB","companies":[{{"name":"Team Cherry","role":"dev","logo":"{logo}","links":[{{"kind":"twitter","url":"https://x.com/teamcherry"}}]}}]}}}}}}]}}"#,
        cover = cover_hash,
        logo = logo_hash,
    );
    let bundle = crate::api::showcase::encode_asset_bundle(&[
        (cover_hash.clone(), cover_bytes.clone()),
        (logo_hash.clone(), logo_bytes.clone()),
    ]);
    a.cmd_tx.send(send_update("hi", Some(board.clone()), Some(bundle.clone()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's profile update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap()
        .expect("B must hold A's profile keyed by A's MASTER (device != master)");
    assert_eq!(p.showcase_board, board, "enriched board JSON must replicate to B");
    assert_eq!(
        p.showcase_assets.as_deref(), Some(bundle.as_slice()),
        "two-asset bundle (cover + company logo) must replicate to B byte-exact"
    );
    let mut decoded = crate::api::showcase::decode_asset_bundle(p.showcase_assets.as_deref().unwrap());
    decoded.sort();
    let mut expected = vec![
        (cover_hash.clone(), cover_bytes.clone()),
        (logo_hash.clone(), logo_bytes.clone()),
    ];
    expected.sort();
    assert_eq!(decoded, expected,
        "replicated bundle must decode both cover + logo with hashes verifying");
    let board = board.as_str();

    // --- 2. A board-untouched update (input None): the handler rebroadcasts the
    // STORED board, and B's COALESCE save preserves it either way. ---
    drain_events(&mut b);
    a.cmd_tx.send(send_update("status changed", None, None)).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's second profile update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.status, "status changed", "the non-board field must update");
    assert_eq!(p.showcase_board, board, "an update that didn't touch the board must NOT lose it");
    assert_eq!(p.showcase_assets.as_deref(), Some(bundle.as_slice()),
        "an update that didn't touch the assets must NOT lose them");

    // --- 3. Explicit clear (Some("") / empty bundle) propagates. ---
    drain_events(&mut b);
    a.cmd_tx.send(send_update("cleared", Some(String::new()), Some(Vec::new()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's clear update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.showcase_board, "", "an explicit empty board must clear on B");
    assert_eq!(p.showcase_assets, None, "an explicit empty bundle must clear on B");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// POSITIVE (no regression): the sibling-proof handshake itself links two genuine
// siblings that meet LIVE in the inbox with NO pre-seeded resolver. Unlike
// `linked_sibling_resolves_both_devices_at_startup` (which pre-seeds the resolver
// from an imported device list), here neither device knows the other at boot —
// the ONLY way they converge is the challenge→master-signed-response→merge path.
// Proves the handshake replaces the old bare-inbox shortcut without breaking
// genuine multi-device convergence.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn genuine_siblings_converge_via_proof_handshake() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // ONE identity M, two devices B and C (same master tag → SHARED master key).
    // CRUCIAL: do NOT seed_self — the resolver starts empty for both, so each
    // device's startup seeds only ITSELF. They can only learn of each other by
    // answering each other's inbox sibling-proof challenge.
    const M_MASTER: u8 = 5;
    const B_DEV: u8 = 6;
    const C_DEV: u8 = 7;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[]).await;
    sleep_ms(1000).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    // Allow the handshake round-trip (challenge → response → verify → merge) and the
    // device-list re-sign that follows.
    sleep_ms(3000).await;
    drain_events(&mut b);
    drain_events(&mut c);

    // After the handshake, BOTH devices resolve to the shared master, and the
    // resolver lists both — i.e. the merge ran via the verified-proof path.
    assert!(
        super::resolver::same_identity(&b_dev, &c_dev),
        "the two genuine sibling devices must resolve to the same identity after the handshake"
    );
    assert_eq!(
        super::resolver::resolve(&c_dev), m_master,
        "sibling C's device must resolve to the shared master after a verified proof"
    );
    assert_eq!(
        super::resolver::resolve(&b_dev), m_master,
        "sibling B's device must resolve to the shared master after a verified proof"
    );
    let mut devs = super::resolver::devices_for(&m_master);
    devs.sort();
    let mut expected = vec![b_dev.clone(), c_dev.clone()];
    expected.sort();
    assert_eq!(
        devs, expected,
        "the resolver must list BOTH sibling devices for the master after the proof handshake"
    );

    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// Friend REMOVAL must be symmetric across a device != master shape. The bug:
// every remove_friend call (send side + the FriendRemove receive arm) passed a
// RAW id with no device→master resolution. Once the UI collapses to master, A
// removing B addressed the bare master (no socket → the online branch was
// skipped → a stuck offline tombstone) while B, receiving FriendRemove from A's
// DEVICE id, DELETEd `WHERE peer_id = <A device>` and MISSED its master-keyed
// row — so B still listed A. This test drives the real request/accept/remove
// flow and asserts BOTH sides end with NO row for the other.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_removal_is_symmetric_across_distinct_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A and B distinct identities, EACH device != master (the VM/AL shape).
    const A_MASTER: u8 = 8;
    const A_DEV: u8 = 9;
    const B_MASTER: u8 = 11;
    const B_DEV: u8 = 12;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A requests B (by master). B accepts using the id B actually RECEIVED the
    // request under — exactly as the UI does (`acceptRequest(req.peerId)`), which
    // is A's DEVICE id while B's resolver is still cold for A. This is the real
    // path; accepting `a_master` directly would skip the device→master plumbing.
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    let mut a_id_as_b_saw = None;
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
            a_id_as_b_saw = Some(peer_id.clone());
            true
        } else {
            false
        }
    })
    .await;
    assert!(b_got, "B must receive A's friend request");
    let a_id_for_accept = a_id_as_b_saw.expect("captured the requester id");
    sleep_ms(1500).await; // let A's device list propagate so B can resolve A→master

    // Accept and wait for BOTH sides to record the accepted friendship. Acceptance
    // delivery depends on the device lists having propagated so both sides agree on
    // the DM room — in the harness that can take a couple of round-trips, so re-send
    // the (idempotent) accept and re-check up to a few times rather than racing a
    // single fixed sleep. This mirrors real use, where convergence is within
    // seconds and the human clicks Accept well after the request lands.
    let mut converged = false;
    for _ in 0..6 {
        b.cmd_tx
            .send(NodeCommand::AcceptFriendRequest { peer_id: a_id_for_accept.clone() })
            .await
            .unwrap();
        sleep_ms(1500).await;
        drain_events(&mut a);
        drain_events(&mut b);
        let a_has_b = a.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &b_master && st == "accepted");
        let b_has_a = b.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &a_master && st == "accepted");
        if a_has_b && b_has_a {
            converged = true;
            break;
        }
    }
    assert!(
        converged,
        "precondition: both A and B must list each other as accepted (master-keyed) before removal"
    );

    // --- THE ACT: A removes B (by MASTER, exactly as the collapsed UI does). ---
    a.cmd_tx
        .send(NodeCommand::RemoveFriend { peer_id: b_master.clone() })
        .await
        .unwrap();
    // B should receive the FriendRemove (fanned to B's online device, not the
    // bare master) and DELETE its master-keyed row for A.
    let b_removed = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRemoved { .. })
    })
    .await;
    assert!(b_removed, "B must receive the FriendRemove and emit FriendRemoved");
    sleep_ms(500).await;

    // --- ASSERT: NEITHER side has ANY row for the other (no ghost, no asymmetry). ---
    let a_rows_for_b: Vec<_> = a.store().load_friends(None).unwrap_or_default()
        .into_iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &b_master))
        .collect();
    assert!(
        a_rows_for_b.is_empty(),
        "A must have NO friend row for B after removal, got {a_rows_for_b:?}"
    );
    let b_rows_for_a: Vec<_> = b.store().load_friends(None).unwrap_or_default()
        .into_iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &a_master))
        .collect();
    assert!(
        b_rows_for_a.is_empty(),
        "B must have NO friend row for A after removal (symmetric remove), got {b_rows_for_a:?}"
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// The REQUESTER must end up with an ACCEPTED friend row after the other side
// accepts — even though it was the requester (it never clicked Accept). The bug:
// the accepter's FriendAccept could be lost (the requester's device raced the
// accept and wasn't yet in the accepter's DM room, OR the FriendRequest-receive
// handler joined a DEVICE-keyed DM room that the requester never shared), so the
// requester stayed stuck "pending outgoing" forever. The pending-accepts queue +
// master-keyed DM-room join fix this: the accept is (re)delivered when the
// requester's device appears. This test pins the REQUESTER's side specifically.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn requester_gets_accepted_row_after_acceptance() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // REQUESTER R and ACCEPTER C, each device != master.
    const R_MASTER: u8 = 30;
    const R_DEV: u8 = 31;
    const C_MASTER: u8 = 32;
    const C_DEV: u8 = 33;
    let r_master = NativeKeypair::from_secret_bytes(&seed_bytes(R_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut r = spawn_node_with_friends(&relay, R_MASTER, R_DEV, &[]).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut r);
    drain_events(&mut c);

    // R requests C (by master).
    r.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: c_master.clone() })
        .await
        .unwrap();
    let mut r_id_as_c_saw = None;
    let c_got = wait_event(&mut c, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
            r_id_as_c_saw = Some(peer_id.clone());
            true
        } else {
            false
        }
    })
    .await;
    assert!(c_got, "C must receive R's friend request");
    let r_id_for_accept = r_id_as_c_saw.expect("captured requester id");
    sleep_ms(1000).await;

    // C accepts. THE FOCUS: R (the requester) must converge to an accepted row even
    // though it never accepted — i.e. C's FriendAccept reaches R. Poll R's own DB,
    // re-issuing the (idempotent) accept a few times to absorb harness delivery jitter.
    let mut r_has_c_accepted = false;
    for _ in 0..6 {
        c.cmd_tx
            .send(NodeCommand::AcceptFriendRequest { peer_id: r_id_for_accept.clone() })
            .await
            .unwrap();
        sleep_ms(1500).await;
        drain_events(&mut r);
        drain_events(&mut c);
        r_has_c_accepted = r.store().load_friends(None).unwrap_or_default()
            .iter()
            .any(|(pid, st, _, _, _)| pid == &c_master && st == "accepted");
        if r_has_c_accepted {
            break;
        }
    }
    assert!(
        r_has_c_accepted,
        "REQUESTER R must hold an accepted row keyed by C's master after C accepts \
         (the FriendAccept must reach the requester), rows={:?}",
        r.store().load_friends(None).unwrap_or_default()
    );

    drop(r);
    drop(c);
}

// ---------------------------------------------------------------------------
// Temporary nicknames (2026-07-16): a nickname is claimed under the claimer's
// WS-auth DEVICE id, but friend requests must target the MASTER — the claim now
// carries the master through the relay and resolve hands it back (`master_id`),
// so a stranger's request lands in `inbox:{master}` (the room the claimer
// actually listens on) instead of queuing forever under a device id.
//
// Harness caveat: the resolver is process-global, so B's node incidentally
// knows A's device→master mapping here (in production a stranger's resolver is
// COLD). The relay-reported master_id path this test drives bypasses the
// resolver entirely; the `nickname_master` inspector pins the new plumbing.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn nickname_friend_request_reaches_multi_device_claimer() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = claimer with master ≠ device (the failing shape in production).
    // B = stranger requester (single device).
    const A_MASTER: u8 = 200;
    const A_DEV: u8 = 201;
    const B_MASTER: u8 = 210;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let a_dev = NativeKeypair::from_secret_bytes(&seed_bytes(A_DEV)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_on(&relay, A_MASTER, A_DEV).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_on(&relay, B_MASTER, B_MASTER).await;
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A claims a nickname; the claim must carry A's MASTER to the relay.
    a.cmd_tx
        .send(NodeCommand::ClaimNickname { nickname: "testnick".to_string() })
        .await
        .unwrap();
    let claimed = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::NicknameClaimed { nickname } if nickname == "testnick")
    })
    .await;
    assert!(claimed, "A should claim the nickname");
    assert_eq!(
        relay.nickname_master("testnick").as_deref(),
        Some(a_master.as_str()),
        "the claim must bind the claimer's MASTER at the relay (new plumbing)"
    );

    // Stranger B friend-requests by nickname. Resolve returns (device,
    // master_id); the request must key + deliver on the MASTER.
    b.cmd_tx
        .send(NodeCommand::SendFriendRequestByNickname { nickname: "testnick".to_string() })
        .await
        .unwrap();

    let a_got = wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id } if *peer_id == b_master)
    })
    .await;
    assert!(a_got, "claimer A must receive the stranger's friend request");
    sleep_ms(800).await;

    // B's outgoing row is keyed by A's MASTER — never the device id.
    let b_rows = b.store().load_friends(None).unwrap_or_default();
    assert!(
        b_rows.iter().any(|r| r.0 == a_master && r.1 == "pending" && r.2 == "outgoing"),
        "B's pending outgoing row must be keyed by A's master, got {b_rows:?}"
    );
    assert!(
        !b_rows.iter().any(|r| r.0 == a_dev),
        "no friend row may be stranded under A's DEVICE id, got {b_rows:?}"
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// REMOVE → RE-ADD must NOT ping-pong. The bug: removing a friend while they were
// offline queued a FriendRemove; re-adding then queued a FriendRequest — and on
// the peer's reconnect BOTH drained, sending a contradictory FriendRequest +
// FriendRemove. The peer removed us back and the friendship flapped. The fix:
// sending a request (or accepting) CANCELS any pending removal for that person,
// and removing CANCELS any pending request/accept. This test removes B while B is
// offline, re-adds, then brings B's contact back and asserts the friendship forms
// cleanly (no stray removal tears it down).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn remove_then_readd_does_not_pingpong() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 40;
    const A_DEV: u8 = 41;
    const B_MASTER: u8 = 42;
    const B_DEV: u8 = 43;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // A starts with B already an accepted friend (seeded). B is OFFLINE.
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    sleep_ms(1000).await;
    drain_events(&mut a);

    // A removes B (B offline → removal is QUEUED, not delivered).
    a.cmd_tx
        .send(NodeCommand::RemoveFriend { peer_id: b_master.clone() })
        .await
        .unwrap();
    sleep_ms(500).await;
    // A re-adds B (sends a fresh request). This MUST cancel the queued removal.
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    sleep_ms(500).await;
    drain_events(&mut a);

    // NOW B comes online. B accepts A's request. The drain on B's appearance must
    // send ONLY the friend request (the removal was cancelled) — so the friendship
    // forms and STAYS.
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    // B should receive A's request; accept it using the id B saw.
    let mut a_id_as_b_saw = None;
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
            a_id_as_b_saw = Some(peer_id.clone());
            true
        } else {
            false
        }
    })
    .await;
    assert!(b_got, "B must receive A's re-add friend request");
    let a_id_for_accept = a_id_as_b_saw.expect("captured A's id");

    let mut converged = false;
    for _ in 0..6 {
        b.cmd_tx
            .send(NodeCommand::AcceptFriendRequest { peer_id: a_id_for_accept.clone() })
            .await
            .unwrap();
        sleep_ms(1500).await;
        drain_events(&mut a);
        drain_events(&mut b);
        let a_has_b = a.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &b_master && st == "accepted");
        let b_has_a = b.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &a_master && st == "accepted");
        if a_has_b && b_has_a {
            converged = true;
            break;
        }
    }
    assert!(converged, "re-added friendship must form on both sides");

    // Settle, then assert it STAYS accepted (a stray FriendRemove would have torn it
    // down — the ping-pong symptom).
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    let a_has_b = a.store().load_friends(None).unwrap_or_default()
        .iter().any(|(pid, st, _, _, _)| pid == &b_master && st == "accepted");
    let b_has_a = b.store().load_friends(None).unwrap_or_default()
        .iter().any(|(pid, st, _, _, _)| pid == &a_master && st == "accepted");
    assert!(a_has_b, "A must STILL list B as accepted (no stray removal ping-pong)");
    assert!(b_has_a, "B must STILL list A as accepted (no stray removal ping-pong)");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// REMOVE → RE-ADD while BOTH stay ONLINE must require fresh CONSENT (2026-06-23).
// THE LIVE BUG (Vitalik): A and B become friends (B clicked Accept, so B holds a
// `pending_friend_accepts[A]` entry, ALSO re-seeded from accepted-friends at every
// startup). A removes B; B receives the FriendRemove and DELETES its row — but the
// stale `pending_friend_accepts[A]` SURVIVES (the FriendRemove receive handler
// never cleared it). When A re-adds (fresh FriendRequest) and A's device reappears
// in B's rooms, B's pending-accepts drain AUTO-SENDS a FriendAccept — WITHOUT ever
// showing A's request in B's Incoming tab. A re-adds B as a friend off that stale
// accept; B has NO row and never consented. Result: asymmetric (A has B, B has
// nothing). This test drives the exact flow (both online throughout) and asserts B
// gets a genuine INCOMING pending request on re-add and does NOT silently re-friend.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn readd_while_online_requires_fresh_consent() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A (requester) and B (accepter), each device != master (the real shape).
    const A_MASTER: u8 = 51;
    const A_DEV: u8 = 52;
    const B_MASTER: u8 = 53;
    const B_DEV: u8 = 54;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // --- Phase 1: become friends ORGANICALLY (B must click Accept so B holds a
    // pending_friend_accepts[A] — the stale entry that later mis-fires). ---
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    let mut a_id_as_b_saw = None;
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
            a_id_as_b_saw = Some(peer_id.clone());
            true
        } else {
            false
        }
    })
    .await;
    assert!(b_got, "B must receive A's initial friend request");
    let a_id_for_accept = a_id_as_b_saw.expect("captured A's id");
    let mut converged = false;
    for _ in 0..6 {
        b.cmd_tx
            .send(NodeCommand::AcceptFriendRequest { peer_id: a_id_for_accept.clone() })
            .await
            .unwrap();
        sleep_ms(1200).await;
        drain_events(&mut a);
        drain_events(&mut b);
        let a_has_b = a.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &b_master && st == "accepted");
        let b_has_a = b.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &a_master && st == "accepted");
        if a_has_b && b_has_a { converged = true; break; }
    }
    assert!(converged, "precondition: both must be accepted friends before removal");

    // --- Phase 2: A removes B (both still ONLINE). B deletes its row. ---
    a.cmd_tx
        .send(NodeCommand::RemoveFriend { peer_id: b_master.clone() })
        .await
        .unwrap();
    let b_removed = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRemoved { .. })
    })
    .await;
    assert!(b_removed, "B must receive the FriendRemove");
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    // Sanity: B has no row for A right now.
    assert!(
        !b.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &a_master)),
        "B must have no friend row for A after the removal"
    );

    // --- Phase 3: A RE-ADDS B (fresh FriendRequest). B must see a genuine INCOMING
    // pending request — NOT silently auto-accept off the stale pending_friend_accepts. ---
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    let b_got_readd = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(
        b_got_readd,
        "B must receive a NEW incoming friend request on re-add (the bug: B auto-accepted \
         off a stale pending_friend_accepts and never surfaced the request)"
    );

    // Give any (buggy) auto-accept time to propagate, then assert the friendship did
    // NOT silently re-form: B's row for A must be PENDING/INCOMING (awaiting consent),
    // and A must NOT yet list B as accepted (no stale-accept round-trip).
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut b);
    let b_rows_for_a: Vec<_> = b.store().load_friends(None).unwrap_or_default()
        .into_iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &a_master))
        .collect();
    assert!(
        b_rows_for_a.iter().all(|(_, st, _, _, _)| st != "accepted"),
        "B must NOT have auto-accepted A on re-add (must await consent), got {b_rows_for_a:?}"
    );
    assert!(
        b_rows_for_a.iter().any(|(_, st, dir, _, _)| st == "pending" && dir == "incoming"),
        "B must hold a PENDING INCOMING request for A on re-add, got {b_rows_for_a:?}"
    );
    let a_has_b_accepted = a.store().load_friends(None).unwrap_or_default()
        .iter().any(|(pid, st, _, _, _)| super::resolver::same_identity(pid, &b_master) && st == "accepted");
    assert!(
        !a_has_b_accepted,
        "A must NOT list B as accepted off a stale auto-accept (B never consented)"
    );

    // --- Phase 4: B genuinely accepts → NOW it converges cleanly both ways. ---
    let mut reconverged = false;
    for _ in 0..6 {
        b.cmd_tx
            .send(NodeCommand::AcceptFriendRequest { peer_id: a_master.clone() })
            .await
            .unwrap();
        sleep_ms(1200).await;
        drain_events(&mut a);
        drain_events(&mut b);
        let a_has_b = a.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &b_master && st == "accepted");
        let b_has_a = b.store().load_friends(None).unwrap_or_default()
            .iter().any(|(pid, st, _, _, _)| pid == &a_master && st == "accepted");
        if a_has_b && b_has_a { reconverged = true; break; }
    }
    assert!(reconverged, "after B's genuine re-accept, both must list each other accepted");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// The startup CANONICALIZATION sweep heals a friend row stranded under a DEVICE
// id (the legacy temp-nickname-add shape). We pre-seed: (1) a friend row keyed
// by the friend's DEVICE id, and (2) a persisted device list mapping that device
// → its master. On start, the resolver warms from the device list and the sweep
// folds the row to the master — no re-add, no network. This is what repairs an
// existing broken DB on the next launch.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn startup_canonicalizes_device_keyed_friend_row() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // The local node.
    const LOCAL_MASTER: u8 = 20;
    const LOCAL_DEV: u8 = 21;
    // The FRIEND: distinct identity with device != master.
    const FRIEND_MASTER: u8 = 22;
    const FRIEND_DEV: u8 = 23;
    let friend_master = NativeKeypair::from_secret_bytes(&seed_bytes(FRIEND_MASTER)).peer_id();
    let friend_dev = NativeKeypair::from_secret_bytes(&seed_bytes(FRIEND_DEV)).peer_id();

    // Build the local node's DB path the same way spawn_node does, so we can
    // pre-seed it before start. (spawn_node uses its own tempdir, so instead we
    // pre-seed via a throwaway dir and point the node at it.)
    let tmp = tempfile::tempdir().expect("tmp");
    let db_path = tmp.path().join("messages.db").to_str().unwrap().to_string();
    let local_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(LOCAL_MASTER));
    let passphrase = passphrase_for(&local_master_kp);
    crate::storage::MessageStore::migrate_auto_vacuum_once(&db_path, &passphrase)
        .expect("auto_vacuum migration");
    {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase).expect("open store");
        // (1) Friend row stranded under the friend's DEVICE id.
        store.save_friend(&friend_dev, "accepted", "", 100).expect("seed device-keyed friend");
        // (2) Persisted device list: friend_dev → friend_master (so the resolver
        //     can collapse it at startup).
        let friend_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(FRIEND_MASTER));
        let signed = super::crypto_handler::build_signed_device_list(
            &friend_master_kp, 1, vec![friend_dev.clone()], Vec::new(),
        );
        let json = serde_json::to_string(&signed).expect("serialize");
        store
            .save_device_list(&signed.master_peer_id, &json, signed.version, &signed.devices, 0)
            .expect("persist friend device list");
    }

    // Boot the node ON THAT pre-seeded DB. The startup sweep should fold the row.
    let mut local = spawn_node_on_db(&relay, LOCAL_MASTER, LOCAL_DEV, &db_path, tmp).await;
    sleep_ms(1500).await;
    drain_events(&mut local);

    // The device-keyed row is GONE; a single row keyed by the friend's MASTER
    // remains, status preserved (accepted).
    let rows = local.store().load_friends(None).unwrap_or_default();
    let for_friend: Vec<_> = rows
        .iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &friend_master))
        .collect();
    assert_eq!(
        for_friend.len(), 1,
        "exactly one friend row for the friend after canonicalization, got {rows:?}"
    );
    assert_eq!(
        for_friend[0].0, friend_master,
        "the surviving row must be keyed by the friend's MASTER"
    );
    assert_eq!(for_friend[0].1, "accepted", "status must be preserved by the fold");
    assert!(
        !rows.iter().any(|(pid, _, _, _, _)| pid == &friend_dev),
        "the device-keyed row must be deleted"
    );

    drop(local);
}

// ---------------------------------------------------------------------------
// THE LIVE BUG REPRODUCTION (2026-06-23): two FRESH single-device people (AL/VM),
// each device != master, become friends ORGANICALLY (no pre-seeded resolver, real
// FriendRequest→Accept handshake), then DM each other BOTH ways. Every fresh
// install since ad7b49e mints a random device key, so device != master even with
// NO sibling — the "byte-for-byte pre-multi-device" claim only ever held on
// MIGRATED keystone installs. This is the exact shape Vitalik reports: AL→VM DMs
// never render on VM while VM→AL works.
//
// What this pins (the WHOLE chain, end to end, on REAL state):
//   1. After the handshake, EACH side's resolver maps the OTHER's device→master
//      (the device-list push over the durable room must land BOTH directions).
//   2. Olm sessions confirm BOTH ways (no glare deadlock / incompatible halves).
//   3. A DM sent each way RENDERS in the receiver's master-keyed UI thread
//      (`dm_thread(sender_master)`) — this is the assertion the convergence test
//      was MISSING. If the receiver filed the DM under the sender's DEVICE id
//      (cold resolver), `dm_thread` (which keys on master) is EMPTY → caught here.
//   4. The rendered bubble is INCOMING (is_mine == false) and SIGNED.
// This is the headless equivalent of the live two-laptop test.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn fresh_single_device_friends_dm_both_ways() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // AL and VM: distinct identities, EACH device != master (the real fresh-install
    // shape). Resolver NOT pre-seeded (test_guard cleared it) — they must learn each
    // other's device→master purely from the organic handshake's device-list push.
    const AL_MASTER: u8 = 41;
    const AL_DEV: u8 = 42;
    const VM_MASTER: u8 = 43;
    const VM_DEV: u8 = 44;
    let al_master = NativeKeypair::from_secret_bytes(&seed_bytes(AL_MASTER)).peer_id();
    let al_dev = NativeKeypair::from_secret_bytes(&seed_bytes(AL_DEV)).peer_id();
    let vm_master = NativeKeypair::from_secret_bytes(&seed_bytes(VM_MASTER)).peer_id();
    let vm_dev = NativeKeypair::from_secret_bytes(&seed_bytes(VM_DEV)).peer_id();
    // Precondition: this scenario is meaningless unless device != master.
    assert_ne!(al_dev, al_master, "AL must be a real fresh install (device != master)");
    assert_ne!(vm_dev, vm_master, "VM must be a real fresh install (device != master)");

    let mut al = spawn_node_with_friends(&relay, AL_MASTER, AL_DEV, &[]).await;
    let mut vm = spawn_node_with_friends(&relay, VM_MASTER, VM_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // AL friend-requests VM (by master). VM accepts. This drives the REAL handshake
    // incl. the device-list/profile pushes both directions.
    al.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();
    let vm_got = wait_event(&mut vm, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(vm_got, "VM must receive AL's friend request");
    vm.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: al_master.clone() })
        .await
        .unwrap();
    // Let accept + the profile/device-list pushes + Olm key exchange settle.
    // PROMPTNESS GUARD: a SHORT settle. Before the fix, the inbox-leave race dropped
    // one side's KeyBundle and the handshake only healed via the 30s reconciliation
    // sweep — so this 2s window left BOTH sides session-less and the DM assertions
    // failed. The co-presence re-key (PeerJoined/RoomMembers on the durable DM room)
    // must establish the session within a couple of seconds, not 30.
    sleep_ms(2000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // (1) Resolver converged BOTH ways — the load-bearing precondition for DM
    // attribution. If EITHER side is cold, that side files the friend's DMs under a
    // device id its master-keyed UI never reads.
    assert_eq!(
        super::resolver::resolve(&vm_dev), vm_master,
        "AL→VM direction: AL's resolver must map VM's device → VM's master"
    );
    assert_eq!(
        super::resolver::resolve(&al_dev), al_master,
        "VM→AL direction: VM's resolver must map AL's device → AL's master"
    );

    // (2) Olm sessions confirmed BOTH ways (no glare deadlock / incompatible halves).
    // The session lives keyed by the peer's DEVICE id on each side.
    let al_sees_vm = al.olm_status(&vm_dev).await;
    let vm_sees_al = vm.olm_status(&al_dev).await;
    assert!(
        al_sees_vm == "confirmed" || al_sees_vm == "unconfirmed",
        "AL must hold an Olm session with VM's device (got {al_sees_vm})"
    );
    assert!(
        vm_sees_al == "confirmed" || vm_sees_al == "unconfirmed",
        "VM must hold an Olm session with AL's device (got {vm_sees_al})"
    );

    // (3) THE ACTUAL BUG: AL → VM. AL sends; VM must RENDER it in the master-keyed
    // thread (not strand it under al_dev).
    al.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: vm_master.clone(),
            text: "AL-to-VM-hello".to_string(),
            message_id: "al-vm-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let vm_rx = wait_event(&mut vm, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, from_peer, is_own, .. }
            if text == "AL-to-VM-hello" && *from_peer == al_master && !*is_own)
    })
    .await;
    assert!(
        vm_rx,
        "VM must emit MessageReceived for AL's DM attributed to AL's MASTER (the live bug: \
         it never rendered / was attributed to AL's device)"
    );

    // VM → AL (the working direction — guards against a fix that breaks it).
    vm.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: al_master.clone(),
            text: "VM-to-AL-hello".to_string(),
            message_id: "vm-al-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let al_rx = wait_event(&mut al, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, from_peer, is_own, .. }
            if text == "VM-to-AL-hello" && *from_peer == vm_master && !*is_own)
    })
    .await;
    assert!(al_rx, "AL must receive VM's DM attributed to VM's MASTER");

    // (4) The UI-layer thread (master-keyed, read exactly as the chat pane does)
    // shows BOTH sides' messages on BOTH nodes. This is the green-inspector ==
    // green-UI guarantee: if VM stranded AL's DM under al_dev, this is EMPTY.
    sleep_ms(500).await;
    let vm_thread = vm.dm_thread(&al_master);
    assert!(
        vm_thread.iter().any(|b| b.text == "AL-to-VM-hello" && !b.is_mine && b.has_sig),
        "VM's DM thread with AL must show AL's incoming signed message, got {vm_thread:?}"
    );
    assert!(
        vm_thread.iter().any(|b| b.text == "VM-to-AL-hello" && b.is_mine),
        "VM's DM thread must also show VM's own outgoing message, got {vm_thread:?}"
    );
    let al_thread = al.dm_thread(&vm_master);
    assert!(
        al_thread.iter().any(|b| b.text == "VM-to-AL-hello" && !b.is_mine && b.has_sig),
        "AL's DM thread with VM must show VM's incoming signed message, got {al_thread:?}"
    );
    assert!(
        al_thread.iter().any(|b| b.text == "AL-to-VM-hello" && b.is_mine),
        "AL's DM thread must also show AL's own outgoing message, got {al_thread:?}"
    );

    drop(al);
    drop(vm);
}

// ---------------------------------------------------------------------------
// Reject must NOT silently re-friend: rejecting an incoming request while our
// OWN outbound request to the same person is still queued used to leave the
// outbound request armed; it drained on the peer's next appearance, the peer
// accepted, and the pair became friends behind the user's back. The fix clears
// pending_friend_requests on reject. Regression guard for the reject/accept race.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn reject_cancels_own_queued_request_no_refriend() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();

    const AL_MASTER: u8 = 61;
    const AL_DEV: u8 = 62;
    const VM_MASTER: u8 = 63;
    const VM_DEV: u8 = 64;
    let al_master = NativeKeypair::from_secret_bytes(&seed_bytes(AL_MASTER)).peer_id();
    let vm_master = NativeKeypair::from_secret_bytes(&seed_bytes(VM_MASTER)).peer_id();

    let mut al = spawn_node_with_friends(&relay, AL_MASTER, AL_DEV, &[]).await;
    let mut vm = spawn_node_with_friends(&relay, VM_MASTER, VM_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // BOTH sides request each other (mutual). AL's request + VM's request cross.
    al.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();
    vm.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: al_master.clone() })
        .await
        .unwrap();
    sleep_ms(1500).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // AL REJECTS VM. With the fix, AL's own queued outbound request to VM is
    // cancelled, so it can never drain and re-friend them.
    al.cmd_tx
        .send(NodeCommand::RejectFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();

    // Give the reject + any (buggy) queued-request drain + a possible VM accept a
    // generous window to fire. Before the fix, AL ends up "accepted" here.
    sleep_ms(3000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    let al_status = al.friend_status(&vm_master);
    assert_ne!(
        al_status.as_deref(),
        Some("accepted"),
        "AL rejected VM — must NOT silently become friends via its own queued request \
         (got status {al_status:?})"
    );

    drop(al);
    drop(vm);
}

// ---------------------------------------------------------------------------
// Mutual friend requests converge to friends WITHOUT a reject prompt. When both
// sides request each other, the inbound request arriving while our own outbound
// request is live is treated as an implicit accept → both become friends. Guards
// the mutual auto-converge path.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn mutual_friend_requests_auto_converge() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();

    const AL_MASTER: u8 = 71;
    const AL_DEV: u8 = 72;
    const VM_MASTER: u8 = 73;
    const VM_DEV: u8 = 74;
    let al_master = NativeKeypair::from_secret_bytes(&seed_bytes(AL_MASTER)).peer_id();
    let vm_master = NativeKeypair::from_secret_bytes(&seed_bytes(VM_MASTER)).peer_id();

    let mut al = spawn_node_with_friends(&relay, AL_MASTER, AL_DEV, &[]).await;
    let mut vm = spawn_node_with_friends(&relay, VM_MASTER, VM_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // Both request each other with no explicit accept from either side.
    al.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();
    vm.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: al_master.clone() })
        .await
        .unwrap();
    sleep_ms(3000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // Both sides converge to "accepted" purely from the mutual requests.
    assert_eq!(
        al.friend_status(&vm_master).as_deref(),
        Some("accepted"),
        "AL must auto-converge to friends with VM on a mutual request"
    );
    assert_eq!(
        vm.friend_status(&al_master).as_deref(),
        Some("accepted"),
        "VM must auto-converge to friends with AL on a mutual request"
    );

    drop(al);
    drop(vm);
}

// ---------------------------------------------------------------------------
// One-way DM delivery guard: a DM must arrive when the sender is in several relay
// rooms alongside the DM room. The online send path used to route via
// `ws_room_for_peer` (first-match over a HashMap); if the sender's map ever lists
// the recipient's device under a room the recipient has since left (handshake
// room churn / a stale ghost entry), the first-match can pick it, the relay
// buffers the frame against a room the recipient never rejoins, and it's silently
// lost (sends "succeeded", never arrived — the one-way DM bug). The fix routes
// online DMs into the deterministic `dm_room_code`, which every recipient device
// is always a member of. NOTE: the harness can't force a stale relay-room desync
// (no node-level LeaveRoom command), so this asserts delivery under multiple
// shared rooms rather than reproducing the exact staleness; the fix's correctness
// is that it never consults the racy lookup for a DM.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn dm_delivers_with_multiple_shared_rooms() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();

    const AL_MASTER: u8 = 81;
    const AL_DEV: u8 = 82;
    const VM_MASTER: u8 = 83;
    const VM_DEV: u8 = 84;
    let al_master = NativeKeypair::from_secret_bytes(&seed_bytes(AL_MASTER)).peer_id();
    let vm_master = NativeKeypair::from_secret_bytes(&seed_bytes(VM_MASTER)).peer_id();

    let mut al = spawn_node_with_friends(&relay, AL_MASTER, AL_DEV, &[]).await;
    let mut vm = spawn_node_with_friends(&relay, VM_MASTER, VM_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // Establish the friendship (drives the real handshake + confirmed Olm session).
    al.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();
    let vm_got = wait_event(&mut vm, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(vm_got, "VM must receive AL's friend request");
    vm.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: al_master.clone() })
        .await
        .unwrap();
    sleep_ms(2000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // Multi-shared-room condition: AL joins an EXTRA room that VM never joins, but
    // whose membership churn (plus the inbox/DM rooms) means AL's ws_room_peers can
    // list VM's device under more than one room key across the handshake. The DM
    // send must deterministically target the DM room, not a first-match room VM is
    // absent from. Driving several extra rooms widens the window that the racy
    // first-match would land on the wrong one; the fix makes delivery reliable.
    for i in 0..6 {
        al.cmd_tx
            .send(NodeCommand::JoinRoom { room_code: format!("extra_room_{i}") })
            .await
            .unwrap();
    }
    sleep_ms(1000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    // AL → VM DM. Must arrive despite the multiple shared rooms.
    al.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: vm_master.clone(),
            text: "multi-room-dm".to_string(),
            message_id: "mr-dm-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let vm_rx = wait_event(&mut vm, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, from_peer, is_own, .. }
            if text == "multi-room-dm" && *from_peer == al_master && !*is_own)
    })
    .await;
    assert!(
        vm_rx,
        "VM must receive AL's DM even with multiple shared rooms (the one-way bug: \
         the send picked a non-DM room and the relay silently buffered it)"
    );

    drop(al);
    drop(vm);
}

// ---------------------------------------------------------------------------
// Friend-request-needs-restart race: a request sent to a target whose device→
// master mapping the requester hasn't learned yet queues (keyed by target MASTER)
// and the presence-event drains no-op (they can't attribute the target's present
// DEVICE to the queued master while the resolver is cold). The target then never
// receives it until it re-joins a shared room (a restart). The fix drains the
// queue the moment the mapping is learned (device-list ingest). This test drives
// a fresh cold requester and asserts the target receives the request WITHOUT
// restarting. NOTE: the in-process MockRelay collapses the exact micro-timing
// window of the field race, so this is a delivery guarantee for the cold-requester
// path rather than a deterministic repro of the presence-event miss; the fix's
// correctness is that learning the mapping now always re-drives the queued drain.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn friend_request_delivers_without_recipient_restart() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();

    // Fresh distinct identities, each device != master (real fresh-install shape),
    // resolver NOT pre-seeded → the requester starts COLD (can't map the target's
    // device to its master until it ingests the target's device list).
    const AL_MASTER: u8 = 91;
    const AL_DEV: u8 = 92;
    const VM_MASTER: u8 = 93;
    const VM_DEV: u8 = 94;
    let al_master = NativeKeypair::from_secret_bytes(&seed_bytes(AL_MASTER)).peer_id();
    let al_dev = NativeKeypair::from_secret_bytes(&seed_bytes(AL_DEV)).peer_id();
    let vm_master = NativeKeypair::from_secret_bytes(&seed_bytes(VM_MASTER)).peer_id();
    let vm_dev = NativeKeypair::from_secret_bytes(&seed_bytes(VM_DEV)).peer_id();
    assert_ne!(al_dev, al_master);
    assert_ne!(vm_dev, vm_master);

    let mut al = spawn_node_with_friends(&relay, AL_MASTER, AL_DEV, &[]).await;
    let mut vm = spawn_node_with_friends(&relay, VM_MASTER, VM_DEV, &[]).await;
    // Minimal settle: send the request BEFORE the device-list/profile exchange has
    // taught AL that VM's device resolves to VM's master — so AL queues it and the
    // presence drains can't attribute VM's device to the queued master.
    sleep_ms(200).await;
    drain_events(&mut al);
    drain_events(&mut vm);

    al.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: vm_master.clone() })
        .await
        .unwrap();

    // VM must receive the request WITHOUT restarting — the mapping-learned drain
    // (device-list ingest on AL) must re-fire the queued request once AL learns
    // VM's device→master. Before the fix, VM never sees it (it sat queued on AL).
    let vm_got = wait_event(&mut vm, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(
        vm_got,
        "VM must receive AL's friend request WITHOUT a restart (the needs-restart \
         race: AL queued it while cold and no drain re-fired on learning the mapping)"
    );

    drop(al);
    drop(vm);
}

// ---------------------------------------------------------------------------
// LEAVE converges DURABLY on the leaver's sibling devices (2026-07-02).
// THE AUDIT FINDING: the acting device tears down fully in handle_leave_server,
// but a SIBLING applying the fanned self-MemberRemoved only emitted MemberLeft —
// no state/DB teardown. The shell reloaded on restart, re-listed the server, and
// the sibling re-announce loop (which filtered only on is_deleted, never on
// membership) could re-ADD the identity to a server it left — authored by a
// non-member, rejected by real members → permanent fork. This drives: owner O;
// member identity M with devices B + C; B joins, C onboards via the reconnect
// re-announce; B LEAVES → C must tear down durably (state deleted, UI list
// empty), O prunes M from members, and a later C reconnect must NOT resurrect
// the server via re-announce.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn leave_tears_down_durably_on_sibling_and_owner_prunes_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner (single device). M = member identity, devices B (actor) + C (sibling).
    const O_MASTER: u8 = 250;
    const O_DEV: u8 = 251;
    const M_MASTER: u8 = 252;
    const B_DEV: u8 = 253;
    const C_DEV: u8 = 254;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_DEV, &[&m_master]).await;
    sleep_ms(1000).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&o_master]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    sleep_ms(3000).await; // O<->B rooms + B<->C sibling proof + Olm settle
    drain_events(&mut o);
    drain_events(&mut b);
    drain_events(&mut c);

    // --- O creates a server; B (non-owner member) joins it ---
    let server_id = create_server_and_wait(&mut o, "Leave-Teardown Server").await;
    sleep_ms(500).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let b_joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(b_joined, "member device B must join the owner's server");
    sleep_ms(2000).await;

    // --- Sibling C onboards via the reconnect re-announce (bounce C) ---
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut c);
    relay.set_online(&c.device_id, true);
    let c_onboarded = wait_event(&mut c, std::time::Duration::from_secs(12), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(c_onboarded, "sibling C must onboard the joined server via re-announce");
    sleep_ms(3000).await;
    assert!(
        c.servers().contains(&server_id),
        "sibling C's server list must include the server before the leave, got {:?}",
        c.servers()
    );
    drain_events(&mut o);
    drain_events(&mut b);
    drain_events(&mut c);

    // --- B LEAVES the server ---
    b.cmd_tx
        .send(NodeCommand::LeaveServer { server_id: server_id.clone() })
        .await
        .unwrap();
    let b_gone = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::ServerDeleted { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(b_gone, "acting device B must emit ServerDeleted on leave");

    // THE FIX UNDER TEST: sibling C applies the fanned self-MemberRemoved and
    // tears down DURABLY (ServerDeleted event + state gone), not just MemberLeft.
    let c_gone = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerDeleted { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(c_gone, "sibling C must emit ServerDeleted for the left server (durable teardown)");
    sleep_ms(1500).await;

    assert!(
        !b.servers().contains(&server_id),
        "leaver B's list must not contain the left server, got {:?}",
        b.servers()
    );
    assert!(
        !c.servers().contains(&server_id),
        "sibling C's list must not contain the left server, got {:?}",
        c.servers()
    );
    assert!(
        c.server_state(&server_id).is_none(),
        "sibling C's DB must no longer hold the left server's state (restart-durable)"
    );
    assert!(
        b.server_state(&server_id).is_none(),
        "leaver B's DB must no longer hold the left server's state"
    );

    // Owner keeps the server but prunes M from the members.
    assert!(
        o.servers().contains(&server_id),
        "owner O must still list the server, got {:?}",
        o.servers()
    );
    let o_members = o.raw_crdt_member_keys(&server_id);
    assert!(
        !o_members.contains(&m_master),
        "owner O's member list must no longer contain the leaver's master, got {o_members:?}"
    );

    // --- A later sibling reconnect must NOT resurrect the left server ---
    relay.set_online(&c.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut c);
    relay.set_online(&c.device_id, true);
    let resurrected = wait_event(&mut c, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(
        !resurrected,
        "a reconnecting sibling must NOT re-onboard a server the identity LEFT"
    );
    assert!(
        !c.servers().contains(&server_id),
        "sibling C's list must stay empty of the left server after reconnect, got {:?}",
        c.servers()
    );

    drop(o);
    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// Relay message-availability cache (opt-in offline buffer) — DM leg.
// The classic gap: Alice DMs Bob while Bob is offline, then ALICE goes offline
// before Bob returns. No peer holds the message online — only the relay's
// offline buffer can deliver it. The buffer must replay on Bob's DM-room join
// and be CLEARED afterwards (delete-on-delivery frees relay RAM). Availability,
// not authority: the replayed frame rides the normal Olm-decrypt + dedup path.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn dm_relay_buffer_delivers_after_sender_goes_offline_and_clears() {
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
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file/voice/video send PRE-NEGOTIATES
    // the recipient's auto-download preference, and that advert exchange has no
    // live probe (DebugSnapshotReply carries MLS + Olm only). Every test that
    // went intermittent while this file was being de-slept was in this family,
    // and none outside it. Delete this when the pref becomes observable, not
    // before.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // Bob goes fully offline.
    relay.set_online(&b.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut b);

    // Alice sends while Bob is gone — the relay buffers under Bob's device id.
    a.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: b_master.clone(),
            text: "missed-you".to_string(),
            message_id: "relay-buffer-dm-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    sleep_ms(800).await;
    assert!(
        relay.buffered_count(&b.device_id) > 0,
        "relay must buffer the DM for offline Bob"
    );

    // Alice goes offline TOO — nobody is left online to serve the message.
    relay.set_online(&a.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut a);

    // Bob returns: the relay replay (on DM-room join) is the ONLY delivery path.
    relay.set_online(&b.device_id, true);
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "missed-you")
    })
    .await;
    assert!(got, "Bob must receive the buffered DM from the relay with Alice offline");
    sleep_ms(300).await;

    // Delivered entries are deleted relay-side (freeing RAM).
    assert_eq!(
        relay.buffered_count(&b.device_id), 0,
        "the relay buffer for Bob must be cleared after replay"
    );

    // The message persisted through the normal verify/dedup path.
    let dm_texts: Vec<String> = b.dm_thread(&a_master).iter().map(|m| m.text.clone()).collect();
    assert!(
        dm_texts.contains(&"missed-you".to_string()),
        "buffered DM must be persisted on Bob, got {dm_texts:?}"
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Relay message-availability cache — CHANNEL leg (server-owner opt-in).
// Owner enables `relay_catchup_secs` (a normal Owner/Admin ServerSettingChanged
// key). From then on channel topic frames tee into a per-channel relay ring.
// Alice (owner) posts while Bob is offline, then Alice goes offline; Bob's
// reconnect must deliver the message via TopicCatchup replay — one stored copy
// serves any late joiner; nothing depends on a member staying online.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_relay_catchup_delivers_when_all_other_members_offline() {
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
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Catchup Server").await;
    let general = general_channel_of(&server_id);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(2500).await; // let MemberAdded + MLS welcome settle
    drain_events(&mut o);
    drain_events(&mut j);

    // Owner enables relay catch-up (3 days). The toggle site registers the
    // topic buffers with the relay immediately.
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "relay_catchup_secs".to_string(),
            value: "259200".to_string(),
        })
        .await
        .unwrap();
    // The setting must reach the JOINER's CRDT before it goes offline (its own
    // reconnect hook reads the LOCAL state).
    let j_updated = wait_event(&mut j, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(j_updated, "joiner must apply the relay_catchup_secs setting op");
    sleep_ms(500).await;

    // Bob (joiner) goes offline.
    relay.set_online(&j.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut j);

    // Alice (owner) posts to #general while Bob is gone — the frame tees into
    // the relay's per-channel ring — then goes offline herself.
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "catch-me-later".to_string(),
            message_id: "relay-catchup-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    sleep_ms(1000).await;
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    // Bob returns to an EMPTY room. TopicCatchup replay is the only path.
    relay.set_online(&j.device_id, true);
    let got = wait_event(&mut j, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "catch-me-later")
    })
    .await;
    assert!(
        got,
        "joiner must receive the channel message via relay catch-up with every other member offline"
    );
    sleep_ms(300).await;

    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "catch-me-later").expect("catch-up message stored");
    assert_eq!(row.sender_master, o_master, "catch-up message attributed to the owner's master");

    // Dedup guard: a second catch-up replay (reconnect again) must not
    // duplicate the row — replay is idempotent with peer sync.
    relay.set_online(&j.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut j);
    relay.set_online(&j.device_id, true);
    sleep_ms(2500).await;
    drain_events(&mut j);
    let count = j
        .channel_messages(&server_id, &general)
        .iter()
        .filter(|m| m.text == "catch-me-later")
        .count();
    assert_eq!(count, 1, "re-replayed catch-up frames must dedup by message_id");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Relay catch-up must cover EVERY text channel, not just the first/selected
// one (field report 2026-07-04: #general caught up on launch but a second
// channel stayed empty). Owner posts to TWO channels while the joiner is
// offline, then goes offline; the returning joiner must get BOTH.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_relay_catchup_covers_all_channels() {
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
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Two Chan Server").await;
    let general = general_channel_of(&server_id);

    // Owner creates a SECOND text channel.
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "second".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut second_cid = None;
    let made = wait_event(&mut o, std::time::Duration::from_secs(3), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
            if name == "second" {
                second_cid = Some(channel_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(made, "owner should create the second channel");
    let second_cid = second_cid.expect("second channel id");

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(2500).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // Owner enables relay catch-up; wait for the joiner to apply the op.
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "relay_catchup_secs".to_string(),
            value: "259200".to_string(),
        })
        .await
        .unwrap();
    let j_updated = wait_event(&mut j, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(j_updated, "joiner must apply the relay_catchup_secs setting op");
    sleep_ms(500).await;

    // Joiner offline; owner posts to BOTH channels, then goes offline.
    relay.set_online(&j.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut j);

    for (cid, text, mid) in [
        (&general, "in-general", "two-chan-1"),
        (&second_cid, "in-second", "two-chan-2"),
    ] {
        o.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: cid.to_string(),
                text: text.to_string(),
                message_id: mid.to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(600).await;
    }
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    // Joiner returns to an empty room — catch-up must deliver BOTH channels.
    relay.set_online(&j.device_id, true);
    let mut got_general = false;
    let mut got_second = false;
    wait_event(&mut j, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::ChannelMessageReceived { text, .. } = ev {
            if text == "in-general" { got_general = true; }
            if text == "in-second" { got_second = true; }
        }
        got_general && got_second
    })
    .await;
    sleep_ms(300).await;

    assert!(
        j.channel_messages(&server_id, &general).iter().any(|m| m.text == "in-general"),
        "catch-up must deliver the #general message"
    );
    assert!(
        j.channel_messages(&server_id, &second_cid).iter().any(|m| m.text == "in-second"),
        "catch-up must deliver the SECOND channel's message too"
    );

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Relay catch-up must deliver CHANNEL FILE messages (field report 2026-07-04
// round 2: captions/cards never appeared). The companion text message used to
// fan targeted per-member sends — offline members got nothing and nothing
// entered the ring; the FileHeader alone replayed with no message row to hang
// on. Both now ride the topic broadcast: the returning member must get the
// caption row + the file metadata (bytes come later via request-on-open).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_relay_catchup_delivers_file_message_and_header() {
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
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "File Catchup Server").await;
    let general = general_channel_of(&server_id);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(2500).await; // MemberAdded + MLS welcome settle
    drain_events(&mut o);
    drain_events(&mut j);

    // Joiner offline (catch-up is DEFAULT ON — no server setting needed).
    relay.set_online(&j.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut j);

    // Owner sends a channel FILE with a caption while the joiner is gone,
    // then goes offline herself.
    let src = global_tmp.path().join("notes.txt");
    std::fs::write(&src, b"channel file catch-up contents").expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "chan-file-catchup-1".to_string(),
            message_text: "file-caption-test".to_string(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();
    sleep_ms(1500).await;
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    // Joiner returns to an empty room — the caption row AND the FileHeader
    // must both arrive via ring replay.
    relay.set_online(&j.device_id, true);
    let mut got_msg = false;
    let mut got_fid: Option<String> = None;
    wait_event(&mut j, std::time::Duration::from_secs(10), |ev| {
        match ev {
            NetworkEvent::ChannelMessageReceived { text, .. } if text == "file-caption-test" => {
                got_msg = true;
            }
            NetworkEvent::FileHeaderReceived { file_id, file_name, .. }
                if file_name.starts_with("notes") =>
            {
                got_fid = Some(file_id.clone());
            }
            _ => {}
        }
        got_msg && got_fid.is_some()
    })
    .await;
    assert!(got_msg, "the file's caption message must arrive via relay catch-up");
    let fid = got_fid.expect("the channel FileHeader must arrive via relay catch-up");
    sleep_ms(500).await;

    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "file-caption-test").expect("caption row stored");
    assert_eq!(row.sender_master, o_master, "caption attributed to the owner's master");

    // Header landed as metadata (card renders); bytes come later via the
    // request-on-open sweep once a holder is back online.
    let meta = j.file_meta(&fid).expect("file metadata row persisted from the replayed header");
    assert_eq!(meta.file_name, "notes.txt", "header name persisted");
    assert!(meta.completed_at.is_none(), "no bytes yet — the relay never carries file bytes");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Channel file fallback (HOLLOW_PLAN line 2016, fixed 2026-07-16): O sends an
// image/file to a full-replication channel, B (online) receives the bytes, O
// goes OFFLINE, then C comes online and requests the file — targeting O, the
// only holder the UI knows. `handle_request_file` used to drop the request on
// the floor ("no online device"); now it reroutes to ONE online device of
// another server member (B), who serves any file it has on disk. O being
// offline proves the bytes can only have come from B.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_file_request_reroutes_to_online_holder_when_sender_offline() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 220;
    const B_MASTER: u8 = 221;
    const C_MASTER: u8 = 222;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut o =
        spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&b_master, &c_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&o_master]).await;
    sleep_ms(1200).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &c, 15).await;

    let server_id = create_server_and_wait(&mut o, "Reroute Server").await;
    let general = general_channel_of(&server_id);

    for (label, node) in [("B", &mut b), ("C", &mut c)] {
        node.cmd_tx
            .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{label} should join the server");
        sleep_ms(1500).await;
    }
    sleep_ms(2500).await; // membership + MLS settle (3 members < 6 → full replication)
    drain_events(&mut o);
    drain_events(&mut b);
    drain_events(&mut c);

    // C goes offline BEFORE the file is sent — it never gets the bytes stream.
    // Generous settle: C's PeerLeft triggers a room-membership refresh on O,
    // and SendFile must run against the SETTLED view (else O's transient
    // ws_room_peers misses B and the byte stream is silently skipped).
    relay.set_online(&c.device_id, false);
    sleep_ms(2000).await;
    drain_events(&mut o);
    drain_events(&mut c);

    // O sends a channel file; online member B receives the full bytes.
    let contents: &[u8] = b"reroute me to an online holder";
    let src = global_tmp.path().join("reroute.txt");
    std::fs::write(&src, contents).expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "chan-file-reroute-1".to_string(),
            message_text: "reroute-caption".to_string(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();

    let mut got_fid: Option<String> = None;
    wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("reroute") {
                got_fid = Some(file_id.clone());
            }
        }
        got_fid.is_some()
    })
    .await;
    let fid = got_fid.expect("B must receive the channel FileHeader");
    let b_done = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(b_done, "online member B must receive the full file bytes");
    sleep_ms(500).await;
    {
        let meta = b.file_meta(&fid).expect("B persisted the files row");
        let disk = meta.disk_path.expect("B's completed file has a disk path");
        assert_eq!(std::fs::read(&disk).unwrap(), contents, "B holds the original bytes");
    }

    // The SENDER goes offline — B is now the only online holder.
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    // C returns; relay catch-up (default ON) replays the caption + FileHeader,
    // so C learns the file exists — but has no bytes.
    relay.set_online(&c.device_id, true);
    let mut c_has_header = false;
    wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        if matches!(ev, NetworkEvent::FileHeaderReceived { file_id, .. } if *file_id == fid) {
            c_has_header = true;
        }
        c_has_header
    })
    .await;
    assert!(c_has_header, "C must learn the file via relay catch-up");
    sleep_ms(500).await;
    assert!(
        c.file_meta(&fid).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "C must not have the bytes yet"
    );

    // C requests the file the way the UI does — targeting the SENDER's master,
    // who is offline. The fallback must reroute to B.
    c.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: o_master.clone(),
            chunks: vec![],
        })
        .await
        .unwrap();
    let c_done = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(c_done, "C must complete the transfer via the rerouted holder (B)");
    sleep_ms(300).await;
    let meta = c.file_meta(&fid).expect("C persisted the files row");
    assert!(meta.completed_at.is_some(), "C's transfer completed");
    let disk = meta.disk_path.expect("C's completed file has a disk path");
    assert_eq!(
        std::fs::read(&disk).unwrap(),
        contents,
        "C's bytes must match the original — only B could have served them"
    );

    drop(o);
    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// FileRequest gate + guest public downloads (0.9.1). Serving used to be
// UNGATED — any peer that learned a file_id could pull ANY file. Now:
//   1. a NON-member requesting a file from a PRIVATE channel is refused
//      (no header, no bytes, no row);
//   2. once the channel is PUBLIC, guest sync carries the file's metadata
//      (SyncFileMetaItem → GuestSyncMessageFfi — it used to be dropped);
//   3. RequestPublicFile serves the guest the actual bytes via the plaintext
//      PublicFileHeader + WS stream (receipt-cap armed);
//   4. a file posted live into a public channel reaches the guest as a
//      plaintext PublicChannelMessage + metadata FileHeaderReceived.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn file_request_gate_refuses_stranger_and_serves_guest_public() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 230;
    const G_MASTER: u8 = 231; // stranger/guest — no friendship, never a member
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    sleep_ms(1200).await;
    let mut g = spawn_node_with_friends(&relay, G_MASTER, G_MASTER, &[]).await;
    sleep_ms(1200).await;

    let server_id = create_server_and_wait(&mut o, "Gate Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(500).await;

    // O posts a file while #general is PRIVATE.
    let contents: &[u8] = b"gated bytes - guests only once public";
    let src = global_tmp.path().join("gated.txt");
    std::fs::write(&src, contents).expect("write src file");
    drain_events(&mut o);
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "gate-file-1".to_string(),
            message_text: String::new(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();
    let mut got_fid: Option<String> = None;
    wait_event(&mut o, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileCompleted { file_id, .. } = ev {
            got_fid = Some(file_id.clone());
        }
        got_fid.is_some()
    })
    .await;
    let fid = got_fid.expect("sender-side FileCompleted carries the file id");

    // G joins the WS room as a GUEST (not-a-member branch of
    // RequestPublicChannels) so direct sends to O can route.
    g.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    sleep_ms(2500).await; // room join + presence settle
    drain_events(&mut g);

    // 1. PRIVATE channel: the stranger's request must be REFUSED.
    g.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: o_master.clone(),
            chunks: vec![],
        })
        .await
        .unwrap();
    let leaked = wait_event(&mut g, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
            || matches!(ev, NetworkEvent::FileHeaderReceived { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(!leaked, "a non-member must NOT be served a private-channel file");
    assert!(
        g.file_meta(&fid).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "no bytes may have landed on the stranger's disk"
    );

    // O publishes #general.
    o.cmd_tx
        .send(NodeCommand::SetChannelPublic {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            is_public: true,
        })
        .await
        .unwrap();
    sleep_ms(2000).await;
    drain_events(&mut g);

    // 2. Guest sync now carries the attachment's metadata.
    g.cmd_tx
        .send(NodeCommand::RequestPublicChannelSync {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            before_timestamp: None,
        })
        .await
        .unwrap();
    let mut synced_meta = false;
    wait_event(&mut g, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::PublicChannelSyncReceived { messages, .. } = ev {
            synced_meta = messages.iter().any(|m| {
                m.file_meta.as_ref().is_some_and(|fm| {
                    fm.file_id == fid && fm.file_name == "gated.txt" && !fm.is_image
                })
            });
        }
        synced_meta
    })
    .await;
    assert!(synced_meta, "guest sync must carry file metadata for the card");

    // 3. The gated public download serves the bytes.
    drain_events(&mut g);
    g.cmd_tx
        .send(NodeCommand::RequestPublicFile {
            server_id: server_id.clone(),
            file_id: fid.clone(),
            peer_hint: None,
        })
        .await
        .unwrap();
    let g_done = wait_event(&mut g, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(g_done, "guest must receive the public-channel file bytes");
    sleep_ms(300).await;
    let meta = g.file_meta(&fid).expect("guest persisted the files row");
    let disk = meta.disk_path.expect("guest's completed file has a disk path");
    assert_eq!(std::fs::read(&disk).unwrap(), contents, "guest holds the original bytes");

    // 4. A file posted LIVE into the now-public channel reaches the guest as
    // a plaintext message + metadata header (no MLS involved).
    let live_src = global_tmp.path().join("live.txt");
    std::fs::write(&live_src, b"live public file").expect("write live src");
    drain_events(&mut g);
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: live_src.to_str().unwrap().to_string(),
            message_id: "gate-file-live".to_string(),
            message_text: "live caption".to_string(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();
    let mut live_row = false;
    let mut live_meta = false;
    wait_event(&mut g, std::time::Duration::from_secs(8), |ev| {
        if matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "live caption") {
            live_row = true;
        }
        if matches!(ev, NetworkEvent::FileHeaderReceived { file_name, .. } if file_name == "live.txt") {
            live_meta = true;
        }
        live_row && live_meta
    })
    .await;
    assert!(live_row, "guest must receive the live public file message");
    assert!(live_meta, "guest must receive the live file's metadata header");

    // 5. Owner-preview window: the LOCAL sync branch (member browsing their
    // own public channel) must return the LATEST page, mirroring the remote
    // responder — `messages_since(0)` returned the OLDEST 50, landing a
    // cold-started owner at the top of history. Push the channel past one
    // page and check the local sync window.
    for i in 0..55 {
        o.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: format!("filler-{i}"),
                message_id: format!("gate-filler-{i}"),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        // Distinct ms timestamps — the page query orders by `timestamp`, and
        // 55 same-ms rows would make the window cut arbitrary (flaky).
        sleep_ms(10).await;
    }
    sleep_ms(3000).await; // let the sends persist
    drain_events(&mut o);
    o.cmd_tx
        .send(NodeCommand::RequestPublicChannelSync {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            before_timestamp: None,
        })
        .await
        .unwrap();
    let mut window_ok = false;
    wait_event(&mut o, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::PublicChannelSyncReceived { messages, .. } = ev {
            let has_newest = messages.iter().any(|m| m.text == "filler-54");
            let has_oldest = messages.iter().any(|m| m.text == "filler-0");
            window_ok = has_newest && !has_oldest;
            return true;
        }
        false
    })
    .await;
    assert!(window_ok, "owner preview must load the LATEST page, not the oldest");

    drop(o);
    drop(g);
}

// ---------------------------------------------------------------------------
// SELF-DM ("Saved messages", 2026-07): a DM whose recipient is our OWN master
// is a notes-to-self thread. The send path stores it locally (keyed on our own
// master) exactly like any DM, but `fan_out_dm_envelope` must SKIP the
// recipient-device expansion (`same_identity(local, recipient)`) — there is no
// other party, and the bare-master fallback would otherwise queue a dead
// envelope (KeyRequest to a peer nobody authenticates as) forever. Our own
// SIBLINGS still get the echo (convo-tagged with our own master), so the saved
// note appears on every device. This drives both halves:
//   1. solo device: the note lands in the own-master thread (is_mine, signed)
//      and NOTHING is queued at the relay under the bare master id;
//   2. a live sibling receives the echo and files it under the own-master
//      conversation (is_own=true), same thread key as the sender.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn self_dm_saved_messages_stores_locally_and_replicates_to_sibling() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = our identity with two devices B + C (the multi-device shape). C spawns
    // only in phase 2 — phase 1 is the plain single-device saved-messages case.
    const M_MASTER: u8 = 64;
    const B_DEV: u8 = 65;
    const C_DEV: u8 = 66;
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    // Seed our own device→master links (as startup's self-seed would). C's id is
    // seeded before C exists — the sibling fan-out is live-room-filtered, so a
    // known-but-offline sibling is simply skipped, never a dead target.
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);

    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut b);

    // --- Phase 1: SOLO self-DM (single device, nobody else online) ---
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: m_master.clone(),
            text: "saved-note-solo".to_string(),
            message_id: "self-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    // The send path completes (local insert → fan-out no-op → MessageSent hydrate).
    let sent = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::MessageSent { message_id, .. } if message_id == "self-1")
    })
    .await;
    assert!(sent, "self-DM send must complete and emit MessageSent");
    sleep_ms(300).await;

    // UI-layer inspector: the note renders in the own-master ("Saved messages")
    // thread, outgoing side, signed.
    let thread = b.dm_thread(&m_master);
    assert!(
        thread.iter().any(|m| m.text == "saved-note-solo" && m.is_mine && m.has_sig),
        "the solo self-DM must land in the own-master thread as an outgoing signed bubble, got {thread:?}"
    );

    // THE SHORT-CIRCUIT: no dead network send was queued for the bare master id
    // (nobody authenticates as the master — a frame buffered under it would sit
    // at the relay forever; pre-fix the recipient-branch fallback produced one).
    assert_eq!(
        relay.buffered_count(&m_master),
        0,
        "a self-DM must not queue any relay frame under the bare master id"
    );

    // --- Phase 2: a live SIBLING receives the echo under the same thread ---
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[]).await;
    // Siblings meet in inbox:{master}; let PeerJoined-driven Olm key exchange settle.
    sleep_ms(5000).await;
    drain_events(&mut b);
    drain_events(&mut c);
    assert_ne!(
        b.olm_status(&c_dev).await,
        "absent",
        "B must hold an Olm session with sibling C before the echoed self-DM rides it"
    );

    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: m_master.clone(),
            text: "saved-note-echo".to_string(),
            message_id: "self-2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();

    // Sibling C receives the echo as an OWN message filed under the own-master
    // conversation (the convo-tagged sibling envelope).
    let c_got = wait_event(&mut c, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, from_peer, is_own, .. }
            if text == "saved-note-echo" && *from_peer == m_master && *is_own)
    })
    .await;
    assert!(
        c_got,
        "sibling C must receive the self-DM echo attributed to our OWN master with is_own=true"
    );
    sleep_ms(300).await;

    // UI layer on BOTH devices: same thread key (own master), outgoing side.
    let c_thread = c.dm_thread(&m_master);
    assert!(
        c_thread.iter().any(|m| m.text == "saved-note-echo" && m.is_mine),
        "sibling C must file the echo under the own-master thread as OUTGOING, got {c_thread:?}"
    );
    let b_thread = b.dm_thread(&m_master);
    assert!(
        b_thread.iter().any(|m| m.text == "saved-note-solo" && m.is_mine)
            && b_thread.iter().any(|m| m.text == "saved-note-echo" && m.is_mine),
        "sender B keeps both saved notes in the own-master thread, got {b_thread:?}"
    );

    // Still nothing queued under the bare master after the sibling fan-out.
    assert_eq!(
        relay.buffered_count(&m_master),
        0,
        "the sibling echo must target the DEVICE, never buffer under the bare master"
    );

    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// BLOCK ENFORCEMENT AT INGEST (node/blocklist.rs, 2026-07): blocking is
// receiver-side self-protection — the blocked identity's traffic still arrives
// at the socket, but the swarm guards drop it BEFORE store + emit. This drives
// the two hot surfaces: a live DM from a blocked FRIEND (guard in the
// DirectMessage arm, collapsing sender device→master through the resolver) and
// a friend request from a blocked STRANGER (guard in the FriendRequest arm —
// the anti-spam surface blocking exists for).
//
// CAUTION — the blocklist is PROCESS-GLOBAL (like the resolver), so a block "by
// A" is visible to every node's guards in the harness process. Assertions are
// structured so that can't false-positive: the only guarded deliveries the test
// asserts on are TO A, the control sender (stranger D) is never blocked, and
// the set is cleared at start + on scope exit (panic-safe drop guard) so later
// tests aren't poisoned.
// ---------------------------------------------------------------------------

/// RAII guard: clears the process-global blocklist on scope exit — INCLUDING a
/// panicking assert — so a failed block test can't leave ids blocked for the
/// other harness/unit tests in this process (seed tags are reused across tests).
struct BlocklistClearGuard;
impl Drop for BlocklistClearGuard {
    fn drop(&mut self) {
        super::blocklist::clear_for_test();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn blocked_peer_dm_and_friend_request_dropped() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let _block_guard = BlocklistClearGuard;
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = the blocker (keystone: device == master). B = an accepted FRIEND with
    // device != master — the block is stored MASTER-keyed but B's traffic arrives
    // from its DEVICE id, so the guard must collapse device→master to catch it.
    // C = a blocked stranger, D = a NOT-blocked control stranger (both keystone).
    const A_MASTER: u8 = 45;
    const B_MASTER: u8 = 46;
    const B_DEV: u8 = 47;
    const C_MASTER: u8 = 48;
    const D_MASTER: u8 = 49;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();
    let d_master = NativeKeypair::from_secret_bytes(&seed_bytes(D_MASTER)).peer_id();
    assert_ne!(b_dev, b_master, "B must have device != master (the collapse under test)");

    // Seed B's device→master link (as B's ingested device list would) so A's
    // guard can collapse b_dev → b_master. Pre-seeded accepted friendship A<->B
    // (the harness's standard friend setup) auto-joins the shared DM room.
    super::resolver::seed_self(&b_master, &[b_dev.clone()]);
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1500).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[&a_master]).await;
    // Let the A<->B Olm key exchange fully confirm before any DM rides it.
    sleep_ms(5000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // --- Control (pre-block): B's DM reaches A — proves session + route work,
    // so the later non-delivery can only be the guard. ---
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "before-block".to_string(),
            message_id: "blk-0".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let control = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, from_peer, .. }
            if text == "before-block" && *from_peer == b_master)
    })
    .await;
    assert!(control, "pre-block control DM must arrive (else the block assertion is meaningless)");
    drain_events(&mut a);
    drain_events(&mut b);

    // --- A blocks B (by MASTER — the FFI wrapper persists then calls this). ---
    super::blocklist::block(&b_master);

    // B sends again. A's DirectMessage-arm guard must drop it before store+emit.
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "after-block".to_string(),
            message_id: "blk-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let leaked = wait_event(&mut a, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { message_id, .. } if message_id == "blk-1")
    })
    .await;
    assert!(
        !leaked,
        "A must emit NO MessageReceived for the blocked friend's DM"
    );

    // A's store: the pre-block row is there, the blocked one is NOT.
    let a_thread = a.dm_thread(&b_master);
    assert!(
        a_thread.iter().any(|m| m.text == "before-block"),
        "A keeps the pre-block message, got {a_thread:?}"
    );
    assert!(
        !a_thread.iter().any(|m| m.text == "after-block"),
        "the blocked DM must never reach A's store, got {a_thread:?}"
    );
    // Sender-side: blocking is receiver-side only — B keeps its own sent row.
    let b_thread = b.dm_thread(&a_master);
    assert!(
        b_thread.iter().any(|m| m.text == "after-block" && m.is_mine),
        "B (the blocked sender) still holds its own sent row, got {b_thread:?}"
    );

    // --- Friend requests: blocked stranger C is dropped, control stranger D
    // lands — same window, same receiver, so the drop is provably the guard. ---
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[]).await;
    let mut d = spawn_node_with_friends(&relay, D_MASTER, D_MASTER, &[]).await;
    sleep_ms(1500).await;
    drain_events(&mut a);
    drain_events(&mut c);
    drain_events(&mut d);

    super::blocklist::block(&c_master);

    c.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: a_master.clone() })
        .await
        .unwrap();
    d.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: a_master.clone() })
        .await
        .unwrap();

    // Wait for D's request (the positive control), noting if C's ever leaks.
    let mut saw_c = false;
    let d_got = wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
            if *peer_id == c_master {
                saw_c = true;
            }
            *peer_id == d_master
        } else {
            false
        }
    })
    .await;
    assert!(d_got, "control stranger D's friend request must reach A");
    // Extra window in case C's (dropped) request would have trailed D's.
    let c_late = wait_event(&mut a, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id } if *peer_id == c_master)
    })
    .await;
    assert!(
        !saw_c && !c_late,
        "A must emit NO FriendRequestReceived for blocked stranger C"
    );

    // A's friend rows: D has a pending incoming row; C has NO row at all.
    let a_friends = a.store().load_friends(None).unwrap_or_default();
    assert!(
        a_friends.iter().any(|(pid, status, dir, _, _)| {
            *pid == d_master && status == "pending" && dir == "incoming"
        }),
        "A must hold a pending INCOMING friend row for control stranger D, got {a_friends:?}"
    );
    assert!(
        a_friends
            .iter()
            .all(|(pid, _, _, _, _)| !super::resolver::same_identity(pid, &c_master)),
        "A must hold NO friend row for blocked stranger C, got {a_friends:?}"
    );

    // Leave the process clean for later tests (the drop guard also covers panics).
    super::blocklist::clear_for_test();

    drop(a);
    drop(b);
    drop(c);
    drop(d);
}

// ---------------------------------------------------------------------------
// SCALING BENCHMARK (large-server MLS viability, 2026-07-06).
//
// Question: can MLS server groups scale to thousands / tens-of-thousands of
// members without a plaintext downgrade? The investigation identified TWO
// O(N) fan-out points; this benchmark MEASURES them on the real join/commit/
// message code so the slope is fact, not estimate, then extrapolates.
//
// Metric source of truth: the MockRelay load meter (RelayMeter) â€” it counts
// exactly what the production relay would copy to sockets, plus the targeted
// SendDirect commit/welcome fan-out the coordinator issues. We drive the REAL
// spawn_node event loops, the REAL JoinServer -> KeyPackage -> 2s-batch ->
// Welcome MLS handshake, and the REAL MLS-encrypted channel send.
//
// We measure at increasing member counts, isolate the PER-MEMBER incremental
// cost of (a) a join/commit and (b) one channel message, confirm both are
// linear, and print the extrapolation to 1k / 50k. Run with:
//   cargo test --lib scaling_benchmark_mls_fanout -- --nocapture --ignored
// Marked ignore so it never runs in the normal fast suite (it spawns many real
// nodes and sleeps for MLS batch timers).
// ---------------------------------------------------------------------------

/// One measured data point: the relay/coordinator load for a server that grew
/// to `members` total members.
#[derive(Debug, Clone)]
struct ScalePoint {
    members: usize,
    /// SendDirect commands issued for the joins in THIS round (commit + welcome
    /// + sync targeted fan-out â€” the O(N) coordinator path).
    join_direct_cmds: u64,
    /// Total relay deliveries for the joins in this round.
    join_deliveries: u64,
    /// Relay deliveries for ONE channel message broadcast at this size (the
    /// steady-state O(N) egress per post).
    per_msg_deliveries: u64,
    /// SendToRoom/topic broadcast commands the sender issued for that one
    /// message (should stay O(1) regardless of size â€” the good path).
    per_msg_broadcast_cmds: u64,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "scaling benchmark: spawns many real nodes, sleeps for MLS batch timers. Run with --ignored --nocapture."]
#[allow(clippy::await_holding_lock)]
async fn scaling_benchmark_mls_fanout() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 100;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();

    // Checkpoints where we snapshot the meter. Kept modest â€” each real node runs
    // a full event loop + Olm handshake + MLS batch commit. Three checkpoints
    // confirm linearity and give the slope.
    let checkpoints = [4usize, 8, 12];
    let max_joiners = *checkpoints.iter().max().unwrap();

    let joiner_masters: Vec<String> = (0..max_joiners)
        .map(|i| NativeKeypair::from_secret_bytes(&seed_bytes(101 + i as u8)).peer_id())
        .collect();
    let joiner_master_refs: Vec<&str> = joiner_masters.iter().map(|s| s.as_str()).collect();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &joiner_master_refs).await;
    sleep_ms(1500).await;

    let server_id = create_server_and_wait(&mut o, "Scale Server").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    println!("\n=== MLS SCALING BENCHMARK ===");
    println!("server={} channel={}", &server_id[..8], &general);

    let mut points: Vec<ScalePoint> = Vec::new();
    let mut joiners: Vec<TestNode> = Vec::new();

    for target in checkpoints {
        let round_start = joiners.len();
        while joiners.len() < target {
            let i = joiners.len();
            let tag = 101 + i as u8;
            let mut j = spawn_node_with_friends(&relay, tag, tag, &[o_master.as_str()]).await;
            sleep_ms(1200).await;
            drain_events(&mut j);
            joiners.push(j);
        }

        // Meter the commit/welcome fan-out for the joiners added THIS round.
        relay.reset_meter();
        for j in joiners.iter_mut().skip(round_start) {
            j.cmd_tx
                .send(NodeCommand::JoinServer {
                    server_id: server_id.clone(),
                    twitch_proof_json: None,
                    nsfw_confirmed: false,
                })
                .await
                .unwrap();
            sleep_ms(400).await;
        }
        sleep_ms(7000).await;
        let join_meter = relay.meter().expect("meter enabled");
        let members = target + 1; // + owner

        // Measure ONE channel message broadcast at this size.
        for j in joiners.iter_mut() { drain_events(j); }
        drain_events(&mut o);
        relay.reset_meter();
        o.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: format!("scale-msg-at-{}", members),
                message_id: format!("scale-{}", members),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(2500).await;
        let msg_meter = relay.meter().expect("meter enabled");

        let point = ScalePoint {
            members,
            join_direct_cmds: join_meter.send_direct_cmds,
            join_deliveries: join_meter.deliveries,
            per_msg_deliveries: msg_meter.deliveries,
            per_msg_broadcast_cmds: msg_meter.send_to_room_cmds + msg_meter.send_topic_cmds,
        };
        println!(
            "[checkpoint] members={:>3} | this-round joins: SendDirect_cmds={:>5} deliveries={:>5} | \
             1 msg: deliveries={:>4} broadcast_cmds={:>3}",
            point.members, point.join_direct_cmds, point.join_deliveries,
            point.per_msg_deliveries, point.per_msg_broadcast_cmds,
        );
        points.push(point);
    }

    println!("\n--- PER-MESSAGE EGRESS (the steady-state bottleneck) ---");
    for p in &points {
        let per_member = p.per_msg_deliveries as f64 / (p.members.saturating_sub(1)).max(1) as f64;
        println!(
            "  members={:>3}: {:>4} relay deliveries/msg  ({:.2} per other-member)  broadcast_cmds={}",
            p.members, p.per_msg_deliveries, per_member, p.per_msg_broadcast_cmds,
        );
    }

    if let Some(last) = points.last() {
        assert!(
            last.per_msg_broadcast_cmds <= 2,
            "sender should issue ~1 broadcast command per message regardless of size (got {})",
            last.per_msg_broadcast_cmds,
        );
        let others = (last.members - 1) as u64;
        assert!(
            last.per_msg_deliveries >= others / 2,
            "relay egress should scale O(N) with members (got {} deliveries for {} others)",
            last.per_msg_deliveries, others,
        );
    }

    let slope = points
        .last()
        .map(|p| p.per_msg_deliveries as f64 / (p.members.saturating_sub(1)).max(1) as f64)
        .unwrap_or(1.0);
    println!("\n--- EXTRAPOLATION (measured slope = {:.3} relay deliveries per other-member) ---", slope);
    for &n in &[1_000usize, 10_000, 50_000] {
        let deliveries = slope * (n as f64 - 1.0);
        let mb_per_msg = deliveries * 2_048.0 / 1_048_576.0;
        // Relay uplink line rate. OVH lifted the production box from 400 Mbps
        // (50 MB/s) to 1 Gbps on 2026-08-04; measured ~854 Mbps, so this is an
        // optimistic ceiling by ~15%. Bump alongside `bandwidth_cap_mbps` in
        // relay-uws/src/http_handlers.cpp if the port changes again.
        const RELAY_UPLINK_MB_S: f64 = 125.0;
        let secs_per_msg = mb_per_msg / RELAY_UPLINK_MB_S;
        let max_msgs_per_sec = if secs_per_msg > 0.0 { 1.0 / secs_per_msg } else { f64::INFINITY };
        println!(
            "  {:>6} members: {:>8.0} deliveries/msg = {:>7.1} MB egress/msg  |  \
             1 hot channel saturates 1Gbps at ~{:.2} msg/s",
            n, deliveries, mb_per_msg, max_msgs_per_sec,
        );
    }
    println!("=== END BENCHMARK ===\n");

    drop(o);
    for j in joiners { drop(j); }
}


// ---------------------------------------------------------------------------
// Custom emotes: EmojiAdded replicates the (name, hash) metadata via the CRDT
// to a joined member; the member pulls the content-addressed BYTES on demand
// (EmoteRequest → EmoteAssets) and verifies them before caching; a member
// without MANAGE_EMOTES is rejected at ingest; EmojiRemoved converges.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn server_emote_replicates_and_bytes_pull_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner, J = joiner — both plain single-device identities.
    const O_MASTER: u8 = 73;
    const J_MASTER: u8 = 74;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Emote Server").await;
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // --- 1. Owner processes + registers a custom emote; metadata replicates. ---
    use sha2::{Digest, Sha256};
    // A tiny valid WebP the way authoring produces it (still, ≤64px).
    let (emote_bytes, animated) = {
        let img = image::RgbaImage::from_pixel(32, 32, image::Rgba([200, 40, 40, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .expect("encode test png");
        super::image_convert::process_emote_image(&png).expect("process emote")
    };
    assert!(!animated, "still emote");
    let hash = hex::encode(Sha256::digest(&emote_bytes));
    o.store()
        .save_emote_blob(&hash, &emote_bytes, false)
        .expect("owner caches its own emote blob");

    o.cmd_tx
        .send(NodeCommand::AddServerEmote {
            server_id: server_id.clone(),
            name: "pogfish".to_string(),
            hash: hash.clone(),
            animated: false,
        })
        .await
        .unwrap();
    let updated = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(updated, "J must receive ServerUpdated for the emote add");
    sleep_ms(500).await;

    let j_state = j.server_state(&server_id).expect("J holds the server state");
    let emote = j_state.emotes.get("pogfish").expect("emote metadata replicated to J");
    assert_eq!(emote.hash, hash, "replicated hash matches");
    assert!(!emote.animated);

    // --- 2. J pulls the bytes on demand (EmoteRequest → EmoteAssets). ---
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "J must NOT have the bytes yet — they never ride the CRDT"
    );
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Emote,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();
    let got_assets = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_assets, "J must receive the emote bytes from the owner");
    sleep_ms(300).await;
    assert_eq!(
        j.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(emote_bytes.as_slice()),
        "pulled bytes must match the owner's blob byte-exact (hash-verified)"
    );

    // --- 3. A plain Member's EmojiAdded is REJECTED at ingest (no MANAGE_EMOTES). ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::AddServerEmote {
            server_id: server_id.clone(),
            name: "sneaky".to_string(),
            hash: hash.clone(),
            animated: false,
        })
        .await
        .unwrap();
    // J's own authoring handler refuses (permission denied error event).
    let denied = wait_event(&mut j, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("cannot manage emotes"))
    })
    .await;
    assert!(denied, "member without MANAGE_EMOTES must be refused at authoring");
    sleep_ms(500).await;
    let o_state = o.server_state(&server_id).expect("owner state");
    assert!(
        !o_state.emotes.contains_key("sneaky"),
        "a member-authored emote op must never reach the owner's state"
    );

    // --- 4. EmojiRemoved converges. ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::RemoveServerEmote {
            server_id: server_id.clone(),
            name: "pogfish".to_string(),
        })
        .await
        .unwrap();
    let removed = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(removed, "J must receive ServerUpdated for the emote removal");
    sleep_ms(500).await;
    let j_state = j.server_state(&server_id).expect("J state after removal");
    assert!(j_state.emotes.is_empty(), "EmojiRemoved must converge on J");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Server sticker packs (asset-rail Phase 5): StickerAdded replicates the
// hash-keyed metadata to a joined member, who pulls the BYTES on demand at
// AssetKind::Sticker; a member without MANAGE_EMOTES is refused; a sticker
// whose transparency must survive the round trip does; StickerRemoved
// converges. The emote twin above is the model — what differs is that
// stickers are keyed by HASH (never by name), carry pack/w/h, and ride a
// larger per-kind receipt cap.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn sticker_set_replicates_and_converges_on_removal() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 96;
    const J_MASTER: u8 = 97;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Sticker Server").await;
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // --- 1. Owner processes + registers a sticker; metadata replicates. ---
    use sha2::{Digest, Sha256};
    // A CUT-OUT source: transparent left half, opaque right half. A sticker
    // that comes back matted is a visible defect, so the alpha is asserted
    // after the pull rather than assumed.
    let (sticker_bytes, w, h, animated) = {
        let mut img = image::RgbaImage::from_pixel(256, 256, image::Rgba([0, 0, 0, 0]));
        for y in 0..256u32 {
            for x in 128..256u32 {
                img.put_pixel(x, y, image::Rgba([40, 200, 90, 255]));
            }
        }
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .expect("encode test png");
        super::image_convert::process_sticker_for_send(&png).expect("process sticker")
    };
    assert!(!animated, "still sticker");
    assert_eq!((w, h), (256, 256), "a 256px source is not upscaled to the 512 cap");
    assert!(
        sticker_bytes.len() <= super::assets::AssetKind::Sticker.recv_cap(),
        "authoring must produce something the receipt cap will accept"
    );
    let hash = hex::encode(Sha256::digest(&sticker_bytes));
    o.store()
        .save_asset_blob(&hash, &sticker_bytes, false, "sticker")
        .expect("owner caches its own sticker blob");

    o.cmd_tx
        .send(NodeCommand::AddServerSticker {
            server_id: server_id.clone(),
            hash: hash.clone(),
            name: "wave".to_string(),
            pack: "greetings".to_string(),
            animated: false,
            w,
            h,
        })
        .await
        .unwrap();
    let updated = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(updated, "J must receive ServerUpdated for the sticker add");
    sleep_ms(500).await;

    let j_state = j.server_state(&server_id).expect("J holds the server state");
    let sticker = j_state.stickers.get(&hash).expect("sticker metadata replicated to J");
    assert_eq!(sticker.name, "wave");
    assert_eq!(sticker.pack, "greetings");
    assert_eq!((sticker.w, sticker.h), (w, h), "dims ride the CRDT so the cell can be reserved");

    // --- 2. J pulls the bytes on demand, at the STICKER kind. ---
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "J must NOT have the bytes yet — they never ride the CRDT"
    );
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Sticker,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();
    let got_assets = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_assets, "J must receive the sticker bytes from the owner");
    sleep_ms(300).await;
    let pulled = j.store().load_emote_blob(&hash).unwrap().expect("bytes cached on J");
    assert_eq!(
        pulled.as_slice(),
        sticker_bytes.as_slice(),
        "pulled bytes must match byte-exact (hash-verified)"
    );
    // The cut-out survived authoring + replication. Decoded through
    // webp_animation, NOT the image crate — every asset we emit is an ANMF
    // container and the image crate reports alpha 255 for those (see the
    // note on image_convert::process_sticker_for_send).
    let frame = webp_animation::Decoder::new(&pulled)
        .expect("decode replicated sticker")
        .into_iter()
        .next()
        .expect("at least one frame");
    let px = |x: u32, y: u32| frame.data()[((y * w + x) * 4 + 3) as usize];
    assert_eq!(px(4, 4), 0, "the transparent half must stay transparent");
    assert_eq!(px(w - 4, 4), 255, "the opaque half must stay opaque");

    // --- 3. A plain Member's StickerAdded is REJECTED (no MANAGE_EMOTES). ---
    drain_events(&mut o);
    j.cmd_tx
        .send(NodeCommand::AddServerSticker {
            server_id: server_id.clone(),
            hash: hash.clone(),
            name: "sneaky".to_string(),
            pack: String::new(),
            animated: false,
            w,
            h,
        })
        .await
        .unwrap();
    let denied = wait_event(&mut j, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("cannot manage emotes"))
    })
    .await;
    assert!(denied, "member without MANAGE_EMOTES must be refused at authoring");
    sleep_ms(500).await;
    let o_state = o.server_state(&server_id).expect("owner state");
    assert_eq!(
        o_state.stickers.get(&hash).map(|s| s.name.as_str()),
        Some("wave"),
        "a member-authored sticker op must never reach the owner's state"
    );

    // --- 4. StickerRemoved converges. ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::RemoveServerSticker {
            server_id: server_id.clone(),
            hash: hash.clone(),
        })
        .await
        .unwrap();
    let removed = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(removed, "J must receive ServerUpdated for the sticker removal");
    sleep_ms(500).await;
    let j_state = j.server_state(&server_id).expect("J state after removal");
    assert!(j_state.stickers.is_empty(), "StickerRemoved must converge on J");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Asset rail: the size cap enforced on receipt comes from the kind WE
// recorded at request time, never from the sender. A 300 KB blob is refused
// when it was requested as an 'emote' (256 KB cap) and accepted when the
// same hash is re-requested as a 'gif' (2 MB cap) — the failed receipt must
// free the request slot so the re-ask isn't throttled away.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_cap_enforced_per_kind() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 81;
    const J_MASTER: u8 = 82;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    // O holds a 300 KB blob with a valid WebP container (the wire check is
    // container magic + content hash — it need not decode).
    use sha2::{Digest, Sha256};
    let mut big = Vec::with_capacity(300_012);
    big.extend_from_slice(b"RIFF");
    big.extend_from_slice(&300_004u32.to_le_bytes());
    big.extend_from_slice(b"WEBP");
    big.resize(300_012, 0u8);
    let hash = hex::encode(Sha256::digest(&big));
    o.store()
        .save_asset_blob(&hash, &big, false, "gif")
        .expect("owner caches the big blob");

    // --- 1. Requested as an EMOTE (256 KB cap): the reply must be REFUSED. ---
    drain_events(&mut j);
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Emote,
            server_id: None,
            peer_hint: Some(o_master.clone()),
        })
        .await
        .unwrap();
    let leaked = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(!leaked, "a 300 KB blob must be refused at the emote cap");
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "the over-cap blob must not be cached"
    );

    // --- 2. Re-requested as a GIF (2 MB cap): accepted byte-exact. ---
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: None,
            peer_hint: Some(o_master.clone()),
        })
        .await
        .unwrap();
    let got = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got, "the same blob must be accepted at the gif cap");
    sleep_ms(300).await;
    assert_eq!(
        j.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(big.as_slice()),
        "pulled gif bytes must match byte-exact"
    );

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Asset rail: an UNSOLICITED EmoteAssets bundle — valid container, valid
// content hash, from a friend, in a shared room — must be dropped, because
// the receiver never requested the hash. Without this gate any peer could
// stuff arbitrary blobs into our encrypted DB at the largest kind's cap.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_request_not_answered_for_unrequested_hash() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 83;
    const J_MASTER: u8 = 84;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Stuffing Server").await;
    sleep_ms(300).await;
    j.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(2000).await;
    drain_events(&mut j);

    // A perfectly valid small WebP bundle J never asked for.
    use sha2::{Digest, Sha256};
    let (blob, _) = {
        let img = image::RgbaImage::from_pixel(16, 16, image::Rgba([10, 200, 90, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .expect("encode test png");
        super::image_convert::process_emote_image(&png).expect("process emote")
    };
    let hash = hex::encode(Sha256::digest(&blob));
    let bundle = crate::api::showcase::encode_asset_bundle(&[(hash.clone(), blob)]);
    let msg = super::types::HavenMessage::EmoteAssets {
        bundle_json: String::from_utf8(bundle).expect("bundle is JSON"),
    };
    let frame = serde_json::to_vec(&msg).expect("serialize EmoteAssets");
    relay.inject_direct(&server_id, &o.device_id, &j.device_id, frame);

    let stored = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(!stored, "an unsolicited asset bundle must never emit EmoteAssetsReceived");
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "an unsolicited asset blob must never be cached"
    );

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Server banners (issue #25, asset-rail Phase 2): the CRDT carries ONLY the
// banner hash in settings["server_banner"]; a joined member sees the setting
// converge, then pulls the content-addressed BYTES on demand over the asset
// rail at AssetKind::Banner. Clearing converges too. The command sequence
// mirrors what the set_server_banner FFI decomposes into: blob into the
// local store, then UpdateServerSetting writes.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn server_banner_hash_replicates_and_bytes_pull_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 85;
    const J_MASTER: u8 = 86;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Banner Server").await;
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // --- 1. Owner processes a banner, caches the blob, writes the hash. ---
    use sha2::{Digest, Sha256};
    let (banner_bytes, animated) = {
        let img = image::RgbaImage::from_pixel(96, 32, image::Rgba([30, 90, 200, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .expect("encode test png");
        super::image_convert::process_server_banner_image(&png).expect("process banner")
    };
    assert!(!animated, "still banner");
    let hash = hex::encode(Sha256::digest(&banner_bytes));
    o.store()
        .save_asset_blob(&hash, &banner_bytes, false, "banner")
        .expect("owner caches its own banner blob");

    for (key, value) in [
        ("server_banner_animated", String::new()),
        ("server_banner", hash.clone()),
    ] {
        o.cmd_tx
            .send(NodeCommand::UpdateServerSetting {
                server_id: server_id.clone(),
                key: key.to_string(),
                value,
            })
            .await
            .unwrap();
    }
    let updated = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(updated, "J must receive ServerUpdated for the banner setting");
    // Fire-and-forget CrdtStore persist; poll the persisted setting.
    let mut hash_converged = false;
    for _ in 0..16 {
        sleep_ms(500).await;
        if j.server_setting(&server_id, "server_banner").as_deref() == Some(hash.as_str()) {
            hash_converged = true;
            break;
        }
    }
    assert!(hash_converged, "the banner hash must converge to J's settings");

    // --- 2. Bytes never ride the CRDT; J pulls them over the asset rail. ---
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "J must NOT have the banner bytes yet — the CRDT carries only the hash"
    );
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Banner,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();
    let got_assets = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_assets, "J must receive the banner bytes from the owner");
    sleep_ms(300).await;
    assert_eq!(
        j.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(banner_bytes.as_slice()),
        "pulled banner must match the owner's blob byte-exact (hash-verified)"
    );

    // --- 3. Clearing converges ("" = cleared, key persists per LWW). ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "server_banner".to_string(),
            value: String::new(),
        })
        .await
        .unwrap();
    let cleared_event = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(cleared_event, "J must receive ServerUpdated for the clear");
    let mut cleared = false;
    for _ in 0..16 {
        sleep_ms(500).await;
        if j.server_setting(&server_id, "server_banner").as_deref() == Some("") {
            cleared = true;
            break;
        }
    }
    assert!(cleared, "the cleared banner must converge to J's settings");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// A plain Member cannot write the banner setting: ServerSettingChanged is
// MANAGE_SERVER-gated at authoring (and the matching ingest gate), so the
// write dies with the author's own Error event and never reaches the owner.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn banner_write_rejected_without_manage_server() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 87;
    const J_MASTER: u8 = 88;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Locked Banner Server").await;
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    let fake_hash = "c".repeat(64);
    j.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "server_banner".to_string(),
            value: fake_hash.clone(),
        })
        .await
        .unwrap();
    let denied = wait_event(&mut j, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::Error { message } if message.contains("Manage Server"))
    })
    .await;
    assert!(denied, "a plain Member's banner write must be refused at authoring");

    sleep_ms(1000).await;
    assert!(
        o.server_setting(&server_id, "server_banner").is_none(),
        "a member-authored banner setting must never reach the owner's state"
    );

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Avatar frames (issue #54): the profile carries an ID, never the art. A
// built-in `b:<hue>` costs nothing on the wire; an uploaded frame puts a
// 64-hex hash on the LIGHT announce and the bytes ride the asset rail at
// AssetKind::Frame, pulled on demand from the owner's devices. An update
// that doesn't touch the frame must preserve it (old clients send None), and
// an explicit "" must clear it.
//
// This is the half a widget test cannot reach: whether the ID converges and
// whether the bytes stay OFF the profile push.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn avatar_frame_id_replicates_and_art_pulls_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 111;
    const A_DEV: u8 = 112;
    const B_MASTER: u8 = 113;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let send_update = |status: &str, frame: Option<String>| NodeCommand::UpdateProfile {
        display_name: "Anon A".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: frame,
        avatar_anim: None,
        banner_anim: None,
    };

    // --- 1. A built-in frame is just a short string: it rides the announce
    // with no blob anywhere. ---
    a.cmd_tx.send(send_update("hi", Some("b:200".into()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's profile update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap()
        .expect("B must hold A's profile keyed by A's MASTER (device != master)");
    assert_eq!(p.avatar_frame, "b:200", "a built-in frame ID must replicate");

    // --- 2. An uploaded frame: the ID is a hash, the ART stays local until
    // pulled. This is the whole reason frames are not profile blobs. ---
    let frame_png = {
        // Opaque ring, transparent middle - the shape the authoring gate wants.
        let mut img = image::RgbaImage::from_pixel(64, 64, image::Rgba([200, 90, 40, 255]));
        for y in 10..54 {
            for x in 10..54 {
                img.put_pixel(x, y, image::Rgba([0, 0, 0, 0]));
            }
        }
        let mut buf = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .expect("encode frame png");
        buf
    };
    let (art, animated) =
        super::image_convert::process_avatar_frame(&frame_png).expect("process frame");
    assert!(!animated, "a PNG source is a still frame");
    use sha2::{Digest, Sha256};
    let hash = hex::encode(Sha256::digest(&art));
    a.store()
        .save_asset_blob(&hash, &art, false, "frame")
        .expect("A caches the frame it authored");

    drain_events(&mut b);
    a.cmd_tx.send(send_update("hi", Some(hash.clone()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's frame-hash update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.avatar_frame, hash, "the frame HASH must replicate");
    assert!(
        !b.store().has_emote_blob(&hash).unwrap(),
        "the art must NOT ride the profile push - that is the whole design"
    );

    // B pulls it from A's devices with a peer hint, exactly as the renderer
    // does when it meets a hash it has no bytes for.
    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Frame,
            server_id: None,
            peer_hint: Some(a_master.clone()),
        })
        .await
        .unwrap();
    let got_art = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_art, "B must receive the frame art from A over the rail");
    sleep_ms(300).await;
    assert_eq!(
        b.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(art.as_slice()),
        "the pulled frame must match A's blob byte-exact (hash-verified)"
    );

    // --- 3. An update that doesn't touch the frame must PRESERVE it (this is
    // also what an old client that has never heard of frames sends). ---
    drain_events(&mut b);
    a.cmd_tx.send(send_update("status changed", None)).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's second update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.status, "status changed", "the non-frame field must update");
    assert_eq!(p.avatar_frame, hash, "an update that didn't touch the frame must NOT lose it");

    // --- 4. Explicit clear. ---
    drain_events(&mut b);
    a.cmd_tx.send(send_update("cleared", Some(String::new()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's clear update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.avatar_frame, "", "an explicit empty frame must clear on B");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Animated profile media on the asset rail: a person's ANIMATED avatar and
// banner stop riding the pushed profile blob. The still companion stays in
// `avatar`/`banner` (old clients and the guest thumb read it); the animation
// becomes a 64-hex hash on the LIGHT announce, with the bytes pulled on
// demand at AssetKind::Profile from the owner's devices.
//
// This is the bandwidth fix: before it, every re-announce path re-shipped
// megabytes of unchanged GIF. Only a live multi-node run can show that the
// hash converges while the bytes stay OFF the push.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn animated_profile_media_hash_replicates_and_bytes_pull_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 171;
    const A_DEV: u8 = 172;
    const B_MASTER: u8 = 173;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A 2-frame animated GIF is what a real upload looks like arriving; the
    // FFI decomposes into exactly this command.
    let source = {
        use image::codecs::gif::GifEncoder;
        use image::{Delay, Frame, Rgba, RgbaImage};
        let mut buf = Vec::new();
        {
            let mut enc = GifEncoder::new(&mut buf);
            for colour in [Rgba([220, 40, 40, 255]), Rgba([40, 40, 220, 255])] {
                enc.encode_frame(Frame::from_parts(
                    RgbaImage::from_pixel(240, 240, colour),
                    0,
                    0,
                    Delay::from_numer_denom_ms(100, 1),
                ))
                .unwrap();
            }
        }
        buf
    };
    let (anim, still) =
        super::image_convert::process_user_avatar_anim(&source).expect("process avatar");
    use sha2::{Digest, Sha256};
    let hash = hex::encode(Sha256::digest(&anim));
    a.store()
        .save_asset_blob(&hash, &anim, true, "profile")
        .expect("A caches the animation it authored");

    let send_update = |status: &str,
                       avatar: Option<Vec<u8>>,
                       anim: Option<String>| NodeCommand::UpdateProfile {
        display_name: "Anon A".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: avatar,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: None,
        avatar_anim: anim,
        banner_anim: None,
    };

    // --- 1. The hash replicates, the still rides the push, the bytes do not. ---
    a.cmd_tx
        .send(send_update("hi", Some(still.clone()), Some(hash.clone())))
        .await
        .unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's profile update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap()
        .expect("B must hold A's profile keyed by A's MASTER (device != master)");
    assert_eq!(p.avatar_anim, hash, "the animation HASH must replicate");
    assert_eq!(
        p.avatar_bytes.as_deref(),
        Some(still.as_slice()),
        "the STILL companion still rides the profile push (old clients read it)"
    );
    assert!(
        !b.store().has_emote_blob(&hash).unwrap(),
        "the animation must NOT ride the profile push - that is the whole point"
    );

    // --- 2. B pulls the animation from A's devices, exactly as the renderer
    // does when it meets a hash it has no bytes for. ---
    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Profile,
            server_id: None,
            peer_hint: Some(a_master.clone()),
        })
        .await
        .unwrap();
    let got_bytes = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_bytes, "B must receive the animation from A over the rail");
    sleep_ms(300).await;
    assert_eq!(
        b.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(anim.as_slice()),
        "the pulled animation must match A's blob byte-exact (hash-verified)"
    );

    // --- 3. An update that doesn't touch the media must PRESERVE it - which
    // is also exactly what an old client sends. ---
    drain_events(&mut b);
    a.cmd_tx.send(send_update("status changed", None, None)).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's second update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.status, "status changed", "the untouched field must update");
    assert_eq!(
        p.avatar_anim, hash,
        "an update that didn't touch the animation must NOT lose it"
    );

    // --- 4. A still-only pick clears the animation explicitly. ---
    drain_events(&mut b);
    a.cmd_tx
        .send(send_update("still now", Some(still.clone()), Some(String::new())))
        .await
        .unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's clear update");
    sleep_ms(300).await;
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.avatar_anim, "", "an explicit empty hash must clear on B");

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Animated server icons (asset-rail follow-up): the still icon stays base64
// in settings["server_avatar"]; an animated upload ADDITIONALLY writes only
// a hash into settings["server_avatar_anim"], with the 128px animated WebP
// blob riding the asset rail at AssetKind::Avatar. A joined member sees the
// hash converge, pulls the bytes on demand, and a later still upload (anim
// hash -> "") converges too. Command sequence mirrors what the
// set_server_avatar FFI decomposes into.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn server_avatar_anim_hash_replicates_and_bytes_pull_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 89;
    const J_MASTER: u8 = 95;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1500).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Animated Icon Server").await;
    sleep_ms(300).await;
    drain_events(&mut o);
    drain_events(&mut j);

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "J must join the server");
    sleep_ms(3000).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // --- 1. Owner processes an animated GIF icon: still b64 + anim blob. ---
    use sha2::{Digest, Sha256};
    let gif_bytes = {
        let f1 = image::RgbaImage::from_pixel(64, 48, image::Rgba([200, 40, 40, 255]));
        let f2 = image::RgbaImage::from_pixel(64, 48, image::Rgba([40, 200, 40, 255]));
        let mut buf = Vec::new();
        {
            let mut enc = image::codecs::gif::GifEncoder::new(&mut buf);
            enc.set_repeat(image::codecs::gif::Repeat::Infinite)
                .expect("gif repeat");
            for frame in [f1, f2] {
                enc.encode_frame(image::Frame::from_parts(
                    frame,
                    0,
                    0,
                    image::Delay::from_numer_denom_ms(100, 1),
                ))
                .expect("encode gif frame");
            }
        }
        buf
    };
    assert!(super::image_convert::is_animated_image(&gif_bytes), "test GIF must read as animated");
    let anim_bytes =
        super::image_convert::process_server_avatar_anim(&gif_bytes).expect("process anim icon");
    assert!(
        super::emotes::webp_is_animated(&anim_bytes),
        "processed icon must be an ANIMATED WebP"
    );
    // Mirror `set_server_avatar`: a SERVER still is SERVER_ICON_DIM, not a
    // person's AVATAR_DIM.
    let still_bytes = super::image_convert::process_still_avatar(
        &gif_bytes,
        super::image_convert::SERVER_ICON_DIM,
    )
    .expect("process still icon");
    let hash = hex::encode(Sha256::digest(&anim_bytes));
    o.store()
        .save_asset_blob(&hash, &anim_bytes, true, "avatar")
        .expect("owner caches its own anim-icon blob");

    use base64::Engine;
    let still_b64 = base64::engine::general_purpose::STANDARD.encode(&still_bytes);
    for (key, value) in [
        ("server_avatar_anim", hash.clone()),
        ("server_avatar", still_b64),
    ] {
        o.cmd_tx
            .send(NodeCommand::UpdateServerSetting {
                server_id: server_id.clone(),
                key: key.to_string(),
                value,
            })
            .await
            .unwrap();
    }
    let updated = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(updated, "J must receive ServerUpdated for the icon settings");
    // Fire-and-forget CrdtStore persist; poll the persisted setting.
    let mut hash_converged = false;
    for _ in 0..16 {
        sleep_ms(500).await;
        if j.server_setting(&server_id, "server_avatar_anim").as_deref() == Some(hash.as_str()) {
            hash_converged = true;
            break;
        }
    }
    assert!(hash_converged, "the anim-icon hash must converge to J's settings");

    // --- 2. Bytes never ride the CRDT; J pulls them over the asset rail. ---
    assert!(
        !j.store().has_emote_blob(&hash).unwrap(),
        "J must NOT have the anim-icon bytes yet — the CRDT carries only the hash"
    );
    j.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Avatar,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();
    let got_assets = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got_assets, "J must receive the anim-icon bytes from the owner");
    sleep_ms(300).await;
    assert_eq!(
        j.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(anim_bytes.as_slice()),
        "pulled anim icon must match the owner's blob byte-exact (hash-verified)"
    );

    // --- 3. A still re-upload clears the anim hash; the clear converges. ---
    drain_events(&mut j);
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "server_avatar_anim".to_string(),
            value: String::new(),
        })
        .await
        .unwrap();
    let cleared_event = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerUpdated { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(cleared_event, "J must receive ServerUpdated for the clear");
    let mut cleared = false;
    for _ in 0..16 {
        sleep_ms(500).await;
        if j.server_setting(&server_id, "server_avatar_anim").as_deref() == Some("") {
            cleared = true;
            break;
        }
    }
    assert!(cleared, "the cleared anim hash must converge to J's settings");

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// Conferences (reports/CONFERENCES_PLAN.md): the waiting room IS an MLS add.
// Host starts a meeting (fresh conf group + relay room `conf:{id}`), a knocker
// broadcasts a join request carrying its KeyPackage, the host admits (MLS add
// → direct Welcome → room-broadcast commit) or denies. Chat is an MLS
// application message attributed by the authenticated leaf credential, and the
// voice-channel machinery runs on the virtual server id (envelope join guard's
// conference branch). Also covers the wrong-access-code rejection.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn conference_waiting_room_admits_denies_and_chats() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // Host + two strangers (all keystone: device == master). No friendships —
    // a conference works between peers who share NOTHING.
    let mut host = spawn_node_on(&relay, 140, 140).await;
    let mut bee = spawn_node_on(&relay, 141, 141).await;
    let mut mallory = spawn_node_on(&relay, 142, 142).await;
    sleep_ms(1500).await;
    drain_events(&mut host);
    drain_events(&mut bee);
    drain_events(&mut mallory);

    let conf_id = "harnessconf1".to_string();
    let conf_sid = super::conference::conf_server_id(&conf_id);

    // --- 1. Host starts the meeting (waiting room ON, no code). ---
    host.cmd_tx
        .send(NodeCommand::ConferenceStart {
            conf_id: conf_id.clone(),
            waiting_room: true,
            access_code_hash: None,
            host_display_name: "Hosty".to_string(),
            host_avatar_hash: String::new(),
        })
        .await
        .unwrap();
    sleep_ms(800).await;

    // --- 2. Bee knocks: host sees the waiting-room entry, Bee sees the lobby. ---
    bee.cmd_tx
        .send(NodeCommand::ConferenceRequestJoin {
            conf_id: conf_id.clone(),
            display_name: "Bee".to_string(),
            avatar_hash: String::new(),
            access_code: None,
        })
        .await
        .unwrap();
    let bee_dev = bee.device_id.clone();
    let knocked = wait_event(&mut host, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceJoinRequestReceived { conf_id: c, peer_id, display_name, .. }
            if *c == conf_id && *peer_id == bee_dev && display_name == "Bee")
    })
    .await;
    assert!(knocked, "host must surface Bee's waiting-room entry");
    let lobby = wait_event(&mut bee, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceLobbyInfo { conf_id: c, host_name, .. }
            if *c == conf_id && host_name == "Hosty")
    })
    .await;
    assert!(lobby, "Bee must see whose meeting it's waiting for");

    // --- 3. Host admits: Bee gets the Welcome (=ConferenceAdmitted) and the
    // conf-group SFrame key. ---
    host.cmd_tx
        .send(NodeCommand::ConferenceAdmit {
            conf_id: conf_id.clone(),
            peer_id: bee.device_id.clone(),
        })
        .await
        .unwrap();
    let admitted = wait_event(&mut bee, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceAdmitted { conf_id: c } if *c == conf_id)
    })
    .await;
    assert!(admitted, "Bee must be admitted after the host's MLS add");
    drain_events(&mut bee);

    // --- 4. Chat rides the conf MLS group, attributed by leaf credential. ---
    bee.cmd_tx
        .send(NodeCommand::ConferenceSendChat {
            conf_id: conf_id.clone(),
            text: "hi from bee".to_string(),
            timestamp: 1111,
        })
        .await
        .unwrap();
    let bee_dev2 = bee.device_id.clone();
    let chat = wait_event(&mut host, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceChatMessage { conf_id: c, sender_peer_id, text, .. }
            if *c == conf_id && *sender_peer_id == bee_dev2 && text == "hi from bee")
    })
    .await;
    assert!(chat, "host must decrypt Bee's chat line with authenticated attribution");

    // --- 5. Voice machinery on the virtual server id: both sides join the
    // synthetic "main" channel; the MLS envelope join must pass the conference
    // membership branch and cross-arrive. ---
    host.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: conf_sid.clone(),
            channel_id: "main".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(500).await;
    drain_events(&mut host);
    bee.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: conf_sid.clone(),
            channel_id: "main".to_string(),
        })
        .await
        .unwrap();
    let bee_dev3 = bee.device_id.clone();
    let vc_seen = wait_event(&mut host, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { server_id, peer_id, .. }
            if *server_id == conf_sid && *peer_id == bee_dev3)
    })
    .await;
    assert!(vc_seen, "host must see Bee join the conference voice channel (envelope guard)");

    // Reply-on-join participant sync: the host joined the call BEFORE Bee was
    // admitted, so Bee never saw that broadcast — the host's direct plaintext
    // reply (accepted through the conf MLS-membership guard) must deliver it.
    let host_dev = host.device_id.clone();
    let host_seen = wait_event(&mut bee, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { server_id, peer_id, .. }
            if *server_id == conf_sid && *peer_id == host_dev)
    })
    .await;
    assert!(host_seen, "Bee must learn the host was ALREADY in the call (reply-on-join sync)");

    // --- 5b. Kick: MLS remove + courtesy signal reach the removed member. ---
    host.cmd_tx
        .send(NodeCommand::ConferenceKick {
            conf_id: conf_id.clone(),
            peer_id: bee.device_id.clone(),
        })
        .await
        .unwrap();
    let kicked = wait_event(&mut bee, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceKicked { conf_id: c, .. } if *c == conf_id)
    })
    .await;
    assert!(kicked, "the removed member must receive ConferenceKicked");

    // --- 6. Deny path: Mallory knocks, host declines, Mallory learns why. ---
    mallory.cmd_tx
        .send(NodeCommand::ConferenceRequestJoin {
            conf_id: conf_id.clone(),
            display_name: "Mallory".to_string(),
            avatar_hash: String::new(),
            access_code: None,
        })
        .await
        .unwrap();
    let mal_dev = mallory.device_id.clone();
    let mal_knock = wait_event(&mut host, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceJoinRequestReceived { peer_id, .. } if *peer_id == mal_dev)
    })
    .await;
    assert!(mal_knock, "host must surface Mallory's request");
    host.cmd_tx
        .send(NodeCommand::ConferenceDeny {
            conf_id: conf_id.clone(),
            peer_id: mallory.device_id.clone(),
            reason: "declined".to_string(),
        })
        .await
        .unwrap();
    let denied = wait_event(&mut mallory, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceJoinDenied { conf_id: c, reason }
            if *c == conf_id && reason == "declined")
    })
    .await;
    assert!(denied, "Mallory must receive the decline");

    // --- 7. Wrong access code is rejected BEFORE the waiting room. ---
    let coded_id = "harnessconf2".to_string();
    host.cmd_tx
        .send(NodeCommand::ConferenceStart {
            conf_id: coded_id.clone(),
            waiting_room: true,
            access_code_hash: Some(super::conference::derive_access_hash(&coded_id, "tiger")),
            host_display_name: "Hosty".to_string(),
            host_avatar_hash: String::new(),
        })
        .await
        .unwrap();
    sleep_ms(800).await;
    drain_events(&mut host);
    mallory.cmd_tx
        .send(NodeCommand::ConferenceRequestJoin {
            conf_id: coded_id.clone(),
            display_name: "Mallory".to_string(),
            avatar_hash: String::new(),
            access_code: Some("wrong".to_string()),
        })
        .await
        .unwrap();
    let code_denied = wait_event(&mut mallory, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ConferenceJoinDenied { conf_id: c, reason }
            if *c == coded_id && reason == "wrong_code")
    })
    .await;
    assert!(code_denied, "a wrong access code must be rejected");
    let ghost_knock = wait_event(&mut host, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::ConferenceJoinRequestReceived { conf_id: c, .. } if *c == coded_id)
    })
    .await;
    assert!(!ghost_knock, "a wrong-code knock must never reach the host's waiting room");

    drop(host);
    drop(bee);
    drop(mallory);
}

// ---------------------------------------------------------------------------
// 0.8.4 — deletion propagation through sync is AUTHENTICATED (reject-absent).
//
// `hidden_at` on a sync item is only honored with the author's own
// "ch-delete"/"dm-delete" proof riding next to it (`hidden_sig`/`hidden_pk`).
// Three scenarios:
//   1. A real deletion (signed by the author) reaches a late joiner via sync
//      and the joiner ADOPTS the proof (transitive propagation).
//   2. A bare hidden flag (no proof — legacy responder or omit-the-sig
//      attack) is DROPPED: the message stays visible.
//   3. A forged proof (a non-author identity signing the deletion payload
//      with its own key) is DROPPED: the pk↔author binding rejects it.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn synced_channel_deletion_hides_for_late_joiner() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A: u8 = 190;
    const B: u8 = 191;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A, A, &[&b_master]).await;
    sleep_ms(1000).await;
    let mut b = spawn_node_with_friends(&relay, B, B, &[&a_master]).await;
    sleep_ms(3000).await; // let Olm confirm A↔B
    drain_events(&mut a);
    drain_events(&mut b);

    // A creates the server, posts two messages and deletes one via the REAL
    // delete path (signs "ch-delete", stores the proof in message_deletions)
    // — all BEFORE B ever joins, so the deletion can only reach B via sync.
    let server_id = create_server_and_wait(&mut a, "Deletion Sync").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    for (mid, text) in [("keep-1", "stays"), ("del-1", "goes away")] {
        a.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: text.to_string(),
                message_id: mid.to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(80).await;
    }
    a.cmd_tx
        .send(NodeCommand::DeleteChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            message_id: "del-1".to_string(),
        })
        .await
        .unwrap();
    let a_deleted = wait_event(&mut a, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::ChannelMessageDeleted { message_id, .. } if message_id == "del-1")
    })
    .await;
    assert!(a_deleted, "A emits ChannelMessageDeleted for its own delete");
    assert!(
        a.store().load_deletion_proof("del-1").is_some(),
        "the real delete path must store a signed deletion proof"
    );
    drain_events(&mut a);

    // B joins fresh; the join-time channel sync must deliver BOTH messages,
    // one of them hidden — with the proof verifying on B.
    b.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let b_joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(b_joined, "B should join the server");
    sleep_ms(6000).await; // channel-sync round trip + commit

    let on_b = b.channel_messages(&server_id, &general);
    assert!(
        on_b.iter().any(|m| m.text == "stays"),
        "sync must deliver the surviving message, got {:?}",
        on_b.iter().map(|m| &m.text).collect::<Vec<_>>()
    );
    assert!(
        !on_b.iter().any(|m| m.text == "goes away"),
        "the deleted message must arrive HIDDEN on B (verified deletion applied)"
    );
    // Row present + hidden + proof ADOPTED, so B itself can re-serve the
    // deletion under reject-absent (transitive propagation).
    assert!(b.store().get_channel_message_hidden_at("del-1").is_some(), "del-1 hidden on B");
    assert!(b.store().load_deletion_proof("del-1").is_some(), "B adopts the deletion proof");

    drop(a);
    drop(b);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn synced_channel_deletion_rejects_unproven_hidden_flags() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A: u8 = 193;
    const B: u8 = 194;
    const EVIL: u8 = 195; // never spawned — a foreign identity forging proofs
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A, A, &[&b_master]).await;
    sleep_ms(1000).await;
    let mut b = spawn_node_with_friends(&relay, B, B, &[&a_master]).await;
    sleep_ms(3000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let server_id = create_server_and_wait(&mut a, "Censor Attempt").await;
    let general = general_channel_of(&server_id);
    sleep_ms(300).await;
    for (mid, text) in [("abs-1", "hidden with no proof"), ("forg-1", "hidden with forged proof")] {
        a.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: text.to_string(),
                message_id: mid.to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(80).await;
    }
    sleep_ms(400).await;

    // Tamper A's store the way a malicious/legacy responder would serve it.
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    {
        use base64::Engine as _;
        let store = a.store();
        // (1) hidden_at with NO deletion evidence — what a bare `hidden_at`
        //     injection (or a pre-signing legacy deletion) looks like.
        store.set_channel_message_hidden("abs-1", now_ms).unwrap();
        // (2) hidden_at with a FORGED proof: a NON-AUTHOR signs the correct
        //     "ch-delete" payload with ITS OWN key.
        let evil = NativeKeypair::from_secret_bytes(&seed_bytes(EVIL));
        let evil_pk = base64::engine::general_purpose::STANDARD.encode(evil.public_key_protobuf());
        let row = super::message_ops::RowExtras::load_channel(&store, "forg-1");
        let text = row.text.clone().unwrap_or_default();
        let (esig, epk) = super::crypto_handler::sign_message_versioned(
            &evil, &evil_pk, "ch-delete", &format!("{server_id}:{general}"),
            &a_master, now_ms + 100, &row.as_signed("forg-1"), &text,
        );
        store.hide_channel_message("forg-1", now_ms + 100, esig.as_deref(), epk.as_deref()).unwrap();
    }

    // B joins fresh and syncs the channel — both hidden flags must be DROPPED
    // (messages visible), while the rows themselves still replicate.
    b.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let b_joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(b_joined, "B should join the server");
    sleep_ms(6000).await;

    let on_b = b.channel_messages(&server_id, &general);
    for text in ["hidden with no proof", "hidden with forged proof"] {
        assert!(
            on_b.iter().any(|m| m.text == text),
            "{text:?} must stay VISIBLE on B (unproven deletion dropped), got {:?}",
            on_b.iter().map(|m| &m.text).collect::<Vec<_>>()
        );
    }
    assert_eq!(b.store().get_channel_message_hidden_at("abs-1"), None, "no-proof flag dropped");
    assert_eq!(b.store().get_channel_message_hidden_at("forg-1"), None, "forged-proof flag dropped");

    drop(a);
    drop(b);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn synced_dm_deletion_requires_proof() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A: u8 = 197;
    const B: u8 = 198;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A, A, &[&b_master]).await;
    sleep_ms(1000).await;
    let mut b = spawn_node_with_friends(&relay, B, B, &[&a_master]).await;
    sleep_ms(3000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // A sends B two DMs live (real Olm path); both land on B.
    for (mid, text) in [("dmdel-1", "dm to be deleted"), ("dmabs-1", "dm bare-hidden")] {
        a.cmd_tx
            .send(NodeCommand::SendMessage {
                peer_id: b_master.clone(),
                text: text.to_string(),
                message_id: mid.to_string(),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        sleep_ms(150).await;
    }
    let b_got = wait_event(&mut b, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "dm bare-hidden")
    })
    .await;
    assert!(b_got, "B must receive both live DMs");
    sleep_ms(300).await;

    // Hide both on A at the STORE level only (no live delete envelope is ever
    // sent), signing dmdel-1 exactly like the production delete path — so the
    // deletion can only reach B through DM sync.
    let del_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    {
        use base64::Engine as _;
        let store = a.store();
        let a_kp = NativeKeypair::from_secret_bytes(&seed_bytes(A));
        let a_pk = base64::engine::general_purpose::STANDARD.encode(a_kp.public_key_protobuf());
        let row = super::message_ops::RowExtras::load_dm(&store, "dmdel-1");
        let text = row.text.clone().unwrap_or_default();
        let (sig, pk) = super::crypto_handler::sign_message_versioned(
            &a_kp, &a_pk, "dm-delete", &b_master, &a_master, del_ts,
            &row.as_signed("dmdel-1"), &text,
        );
        store.hide_dm_message("dmdel-1", del_ts, sig.as_deref(), pk.as_deref()).unwrap();
        // The bare flag: hidden with NO proof to serve.
        store.set_dm_message_hidden("dmabs-1", del_ts + 10).unwrap();
    }

    // B reconnects; its connect flow fires a DmSyncRequest toward A, and A
    // re-serves both rows (their updated_at moved) with hidden flags.
    relay.set_online(&b.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut b);
    relay.set_online(&b.device_id, true);
    let b_synced = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::DmSyncCompleted { peer_id, .. } if *peer_id == a_master)
    })
    .await;
    assert!(b_synced, "B should complete a DM sync with A after reconnect");
    sleep_ms(800).await;

    let store_b = b.store();
    assert!(store_b.dm_message_exists("dmdel-1"), "dmdel-1 row exists on B");
    assert!(
        store_b.get_dm_message_hidden_at("dmdel-1").is_some(),
        "the author-signed deletion must propagate through DM sync"
    );
    assert!(
        store_b.load_deletion_proof("dmdel-1").is_some(),
        "B adopts the DM deletion proof for onward sync"
    );
    assert!(store_b.dm_message_exists("dmabs-1"), "dmabs-1 row exists on B");
    assert_eq!(
        store_b.get_dm_message_hidden_at("dmabs-1"),
        None,
        "a bare hidden flag with no proof must be dropped (REJECT-ABSENT)"
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// SFrame heal ladder (issue #27). Two nodes in a server-wide MLS group; the
// Dart layer detects sustained cryptor failures and fires VoiceSframeHeal.
// The harness can't drive the media plane, so it verifies the KEY layer:
//   * non-escalated heal re-emits the CURRENT epoch key (MlsEpochChanged);
//   * non-authority escalation drops the local group, re-bootstraps from the
//     owner, and converges leaves + epoch with the owner;
//   * authority escalation removes + re-adds the failing peer's leaf; the
//     peer's EVICTION recovery (inactive group → drop + re-bootstrap) pulls
//     it back in and both converge.
// ---------------------------------------------------------------------------

/// Shared setup: O = owner creates a server, B joins, wait until BOTH device
/// leaves are in the server-wide MLS group on both sides.
async fn setup_sframe_heal_pair(
    relay: &MockRelay,
    o_tag: u8,
    b_tag: u8,
) -> (TestNode, TestNode, String) {
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(o_tag)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(b_tag)).peer_id();

    let mut o = spawn_node_with_friends(relay, o_tag, o_tag, &[&b_master]).await;
    sleep_ms(1500).await;
    let mut b = spawn_node_with_friends(relay, b_tag, b_tag, &[&o_master]).await;
    expect_dm_pair_ready(relay, &o, &b, 15).await;
    drain_events(&mut o);
    drain_events(&mut b);

    let server_id = create_server_and_wait(&mut o, "SFrame Heal Server").await;
    sleep_ms(500).await;

    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let joined = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "B should join the server");

    // Both device leaves in the group, on BOTH sides (batch adds: 2s timer).
    let mut ok = false;
    for _ in 0..12 {
        sleep_ms(2000).await;
        let o_leaves = o.mls_members(&server_id).await;
        let b_leaves = b.mls_members(&server_id).await;
        if o_leaves.contains(&o.device_id)
            && o_leaves.contains(&b.device_id)
            && b_leaves == o_leaves
        {
            ok = true;
            break;
        }
    }
    assert!(ok, "both leaves must join the server-wide MLS group on both sides");
    drain_events(&mut o);
    drain_events(&mut b);
    (o, b, server_id)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sframe_heal_reemits_current_epoch_key() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, server_id) = setup_sframe_heal_pair(&relay, 90, 91).await;

    let epoch_before = b.mls_epoch(&server_id).await;
    assert!(epoch_before.is_some(), "B must hold the group before healing");

    // Non-escalated heal: must RE-EMIT the current key without advancing the epoch.
    b.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.clone(),
            channel_id: "general".to_string(),
            peer_id: o.device_id.clone(),
            escalate: false,
        })
        .await
        .unwrap();
    let reemitted = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::MlsEpochChanged { server_id: sid, channel_id: None, .. } if *sid == server_id)
    })
    .await;
    assert!(reemitted, "non-escalated heal must re-emit MlsEpochChanged");
    assert_eq!(
        b.mls_epoch(&server_id).await,
        epoch_before,
        "re-emit must not advance the epoch"
    );

    drop(o);
    drop(b);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sframe_heal_escalation_rebootstraps_non_authority() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, server_id) = setup_sframe_heal_pair(&relay, 92, 93).await;

    let o_epoch_before = o.mls_epoch(&server_id).await.unwrap();

    // B (NOT the owner) escalates: drops its group + KeyPackage → owner. The
    // owner's batch remove+re-add issues a fresh Welcome; both converge.
    b.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.clone(),
            channel_id: "general".to_string(),
            peer_id: o.device_id.clone(),
            escalate: true,
        })
        .await
        .unwrap();

    let mut converged = false;
    for _ in 0..15 {
        sleep_ms(2000).await;
        let o_leaves = o.mls_members(&server_id).await;
        let b_leaves = b.mls_members(&server_id).await;
        let (oe, be) = (o.mls_epoch(&server_id).await, b.mls_epoch(&server_id).await);
        if o_leaves.contains(&b.device_id) && b_leaves == o_leaves && oe.is_some() && oe == be {
            converged = true;
            break;
        }
    }
    assert!(
        converged,
        "after non-authority escalation B must re-join and converge with the owner"
    );
    assert!(
        o.mls_epoch(&server_id).await.unwrap() > o_epoch_before,
        "the remove+re-add must have rotated the epoch (fresh SFrame key)"
    );

    drop(o);
    drop(b);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sframe_heal_escalation_authority_removes_and_readds_peer() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, server_id) = setup_sframe_heal_pair(&relay, 94, 95).await;

    let o_epoch_before = o.mls_epoch(&server_id).await.unwrap();

    // O (owner = authority) escalates against B: queues B's leaf removal. The
    // removal commit EVICTS B (group goes inactive); B's eviction recovery
    // drops the dead group and re-bootstraps from the owner; the batch re-add
    // converges both at a fresh epoch.
    o.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.clone(),
            channel_id: "general".to_string(),
            peer_id: b.device_id.clone(),
            escalate: true,
        })
        .await
        .unwrap();

    let mut converged = false;
    for _ in 0..15 {
        sleep_ms(2000).await;
        let o_leaves = o.mls_members(&server_id).await;
        let b_leaves = b.mls_members(&server_id).await;
        let (oe, be) = (o.mls_epoch(&server_id).await, b.mls_epoch(&server_id).await);
        if o_leaves.contains(&b.device_id) && b_leaves == o_leaves && oe.is_some() && oe == be {
            converged = true;
            break;
        }
    }
    assert!(
        converged,
        "after authority escalation the failing peer must be evicted, recover, and converge"
    );
    assert!(
        o.mls_epoch(&server_id).await.unwrap() > o_epoch_before,
        "the authority remove+re-add must have rotated the epoch"
    );

    drop(o);
    drop(b);
}

// ---------------------------------------------------------------------------
// Join-order MLS epoch race (the "long black screens on run 2" bug, media
// forwarding field session 2026-08-07). MLS commits ride an UNBUFFERED 0x03
// room broadcast — a member whose socket misses them (join race, relay
// backpressure drop) holds the group at a silently STALE epoch: every
// recovery trigger keys on has_group/leaf-missing, no plaintext signal
// carried the epoch, and in a voice-only channel no MLS ciphertext ever
// fails a decrypt. The sharer rotates its SFrame key to the new epoch
// immediately → the stale viewer gets MissingKey until the escalated heal
// (~16 s; forever on a thrashed group).
//
// The fix under test: commit frames are CACHED per group; a stale member is
// DETECTED via epoch hints (first-contact SyncRequest / MlsEpochProbe at VC
// join + heal step 2) and served an MlsCommitCatchup REPLAY — marching to the
// current epoch with ZERO added commits (repair-by-re-add bumps the epoch for
// everyone and feeds the churn spiral). Fallback when the cache can't bridge:
// the existing remove+re-add.
//
// The harness models the loss with MockRelay::set_broadcast_deaf — the
// victim stays in the room, looks healthy, and silently misses 0x03 frames,
// exactly like a backpressured relay socket.
// ---------------------------------------------------------------------------

/// Trio setup: O = owner, B = future stale victim, C = churn generator.
/// All mutually friended; all three device leaves converged in the
/// server-wide MLS group on all sides.
async fn setup_epoch_race_trio(
    relay: &MockRelay,
    o_tag: u8,
    b_tag: u8,
    c_tag: u8,
) -> (TestNode, TestNode, TestNode, String) {
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(o_tag)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(b_tag)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(c_tag)).peer_id();

    let mut o = spawn_node_with_friends(relay, o_tag, o_tag, &[&b_master, &c_master]).await;
    sleep_ms(1500).await;
    let mut b = spawn_node_with_friends(relay, b_tag, b_tag, &[&o_master, &c_master]).await;
    sleep_ms(1500).await;
    let mut c = spawn_node_with_friends(relay, c_tag, c_tag, &[&o_master, &b_master]).await;
    expect_dm_pair_ready(relay, &o, &b, 15).await;
    expect_dm_pair_ready(relay, &o, &c, 15).await;
    expect_dm_pair_ready(relay, &b, &c, 15).await;
    drain_events(&mut o);
    drain_events(&mut b);
    drain_events(&mut c);

    let server_id = create_server_and_wait(&mut o, "Epoch Race Server").await;
    sleep_ms(500).await;

    for joiner in [&mut b, &mut c] {
        joiner
            .cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let joined = wait_event(joiner, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "member should join the server");
    }

    // All three leaves in the group, on all sides (batch adds: 2s timer).
    let mut ok = false;
    for _ in 0..15 {
        sleep_ms(2000).await;
        let o_leaves = o.mls_members(&server_id).await;
        let b_leaves = b.mls_members(&server_id).await;
        let c_leaves = c.mls_members(&server_id).await;
        if o_leaves.contains(&o.device_id)
            && o_leaves.contains(&b.device_id)
            && o_leaves.contains(&c.device_id)
            && b_leaves == o_leaves
            && c_leaves == o_leaves
        {
            ok = true;
            break;
        }
    }
    assert!(ok, "all three leaves must join the server-wide MLS group everywhere");
    drain_events(&mut o);
    drain_events(&mut b);
    drain_events(&mut c);
    (o, b, c, server_id)
}

/// Make B stale: deafen it to 0x03 broadcasts, then drive MLS churn through
/// C's escalated heal (drop group + KP → owner → remove+re-add commits).
/// Returns (o_epoch_after_churn, b_stale_epoch).
async fn make_b_stale(
    relay: &MockRelay,
    o: &mut TestNode,
    b: &mut TestNode,
    c: &mut TestNode,
    server_id: &str,
) -> (u64, u64) {
    relay.set_broadcast_deaf(&b.device_id, true);

    c.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.to_string(),
            channel_id: "general".to_string(),
            peer_id: o.device_id.clone(),
            escalate: true,
        })
        .await
        .unwrap();

    // O and C converge at a HIGHER epoch; B (deaf) must still sit on the old one.
    let mut churned = None;
    for _ in 0..15 {
        sleep_ms(2000).await;
        let (oe, ce, be) = (
            o.mls_epoch(server_id).await,
            c.mls_epoch(server_id).await,
            b.mls_epoch(server_id).await,
        );
        if let (Some(oe), Some(ce), Some(be)) = (oe, ce, be) {
            if oe == ce && oe > be {
                churned = Some((oe, be));
                break;
            }
        }
    }
    let (o_epoch, b_epoch) = churned.expect("churn must advance O+C past deaf B");
    relay.set_broadcast_deaf(&b.device_id, false);
    drain_events(o);
    drain_events(b);
    drain_events(c);
    (o_epoch, b_epoch)
}

/// Heal-path detector: a stale member's `VoiceSframeHeal(escalate: false)` —
/// ladder step 2, and the Dart MissingKey fast-path — probes the authority
/// and converges via commit REPLAY: same epoch as the owner afterwards, and
/// the owner's epoch NEVER moves (no repair churn).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn stale_epoch_heal_probe_converges_via_commit_replay() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, mut c, server_id) = setup_epoch_race_trio(&relay, 96, 97, 98).await;
    let (o_epoch, b_epoch) = make_b_stale(&relay, &mut o, &mut b, &mut c, &server_id).await;
    assert!(b_epoch < o_epoch, "precondition: B stale");

    b.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.clone(),
            channel_id: "general".to_string(),
            peer_id: o.device_id.clone(),
            escalate: false,
        })
        .await
        .unwrap();

    // The re-emit fires immediately (stale key), then the probe round-trip
    // brings the catch-up replay and a SECOND MlsEpochChanged at the real
    // epoch. Assert on the epoch inspector — the event stream carries both.
    let mut converged = false;
    for _ in 0..10 {
        sleep_ms(1000).await;
        if b.mls_epoch(&server_id).await == Some(o_epoch) {
            converged = true;
            break;
        }
    }
    assert!(converged, "stale B must converge to the owner's epoch via catch-up replay");
    assert_eq!(
        o.mls_epoch(&server_id).await,
        Some(o_epoch),
        "commit REPLAY must not advance the owner's epoch (no repair churn)"
    );
    let reemitted = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::MlsEpochChanged { server_id: sid, epoch, .. }
            if *sid == server_id && *epoch == o_epoch)
    })
    .await;
    assert!(reemitted, "the caught-up epoch key must reach the SFrame layer");

    drop(o);
    drop(b);
    drop(c);
}

/// VC-join detector: joining a voice channel with a silently-stale group
/// probes the authority and converges BEFORE any media failure — the exact
/// field scenario (last VC joiner black-screens for ~16 s).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn stale_epoch_vc_join_probe_converges_via_commit_replay() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, mut c, server_id) = setup_epoch_race_trio(&relay, 99, 100, 101).await;

    // A voice channel, known to everyone BEFORE the staleness window.
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "Voice Lounge".to_string(),
            category: None,
            channel_type: "voice".to_string(),
        })
        .await
        .unwrap();
    let mut voice_cid = None;
    let got = wait_event(&mut o, std::time::Duration::from_secs(5), |ev| {
        if let NetworkEvent::ChannelAdded { channel_id, channel_type, .. } = ev {
            if channel_type == "voice" {
                voice_cid = Some(channel_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(got, "voice channel must be created");
    let voice_cid = voice_cid.unwrap();
    sleep_ms(1500).await; // let the CRDT op replicate to B and C

    let (o_epoch, b_epoch) = make_b_stale(&relay, &mut o, &mut b, &mut c, &server_id).await;
    assert!(b_epoch < o_epoch, "precondition: B stale");

    b.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();

    let mut converged = false;
    for _ in 0..10 {
        sleep_ms(1000).await;
        if b.mls_epoch(&server_id).await == Some(o_epoch) {
            converged = true;
            break;
        }
    }
    assert!(converged, "VC join must detect the stale epoch and converge via catch-up");
    assert_eq!(
        o.mls_epoch(&server_id).await,
        Some(o_epoch),
        "commit REPLAY must not advance the owner's epoch"
    );

    drop(o);
    drop(b);
    drop(c);
}

/// First-contact detector: a member that was OFFLINE through the churn (not
/// merely deaf) reconnects and converges from the first-contact SyncRequest
/// epoch hints alone — no VC join, no heal call, no repair churn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn stale_epoch_first_contact_hint_converges_on_reconnect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }
    let relay = MockRelay::new();
    let (mut o, mut b, mut c, server_id) = setup_epoch_race_trio(&relay, 102, 103, 104).await;

    let b_epoch_before = b.mls_epoch(&server_id).await.expect("B holds the group");
    relay.set_online(&b.device_id, false);
    sleep_ms(500).await;

    // Churn while B is fully offline (0x03 broadcasts to it just vanish).
    c.cmd_tx
        .send(NodeCommand::VoiceSframeHeal {
            server_id: server_id.clone(),
            channel_id: "general".to_string(),
            peer_id: o.device_id.clone(),
            escalate: true,
        })
        .await
        .unwrap();
    let mut o_epoch = None;
    for _ in 0..15 {
        sleep_ms(2000).await;
        let (oe, ce) = (o.mls_epoch(&server_id).await, c.mls_epoch(&server_id).await);
        if let (Some(oe), Some(ce)) = (oe, ce) {
            if oe == ce && oe > b_epoch_before {
                o_epoch = Some(oe);
                break;
            }
        }
    }
    let o_epoch = o_epoch.expect("churn must advance O+C while B is offline");
    drain_events(&mut o);
    drain_events(&mut c);

    relay.set_online(&b.device_id, true);

    // Reconnect flow: B re-joins its rooms, first-contact SyncRequests fan in
    // BOTH directions with epoch hints — either direction converges B.
    let mut converged = false;
    for _ in 0..12 {
        sleep_ms(1000).await;
        if b.mls_epoch(&server_id).await == Some(o_epoch) {
            converged = true;
            break;
        }
    }
    assert!(
        converged,
        "reconnecting stale B must converge from first-contact epoch hints alone"
    );
    assert_eq!(
        o.mls_epoch(&server_id).await,
        Some(o_epoch),
        "commit REPLAY must not advance the owner's epoch"
    );

    drop(o);
    drop(b);
    drop(c);
}

/// Issue #45 — a link preview whose fetch finished AFTER the send still lands
/// on the message, everywhere the message went.
///
/// The regression this locks down is the whole complaint: the compose box
/// debounces 600 ms before fetching, so anyone who pastes a URL and sends
/// immediately used to get no card at all. The fetch was always still
/// running; nothing was listening for it.
///
/// What must hold once the card lands:
///  * the recipient's row shows it,
///  * OUR OWN other device's row shows it (the fan-out reaches siblings),
///  * the row still VERIFIES — the attach re-signs, and a preview that broke
///    the signature would stop the message replicating through signed sync,
///  * `edited_at` stays NULL. An attach is not an edit, and a bubble must not
///    sprout "(edited)" because a fetch was slow.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn late_link_preview_lands_on_recipient_and_sibling_without_marking_edited() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // M = us, two devices B (sending) + C (the phone). A = the friend.
    const A_MASTER: u8 = 140;
    const M_MASTER: u8 = 141;
    const B_DEV: u8 = 142;
    const C_DEV: u8 = 143;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);
    super::resolver::update_many(&m_master, [b_dev.as_str(), c_dev.as_str()]);

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    sleep_ms(1200).await;
    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;
    sleep_ms(5000).await;
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    // B sends with NO preview — the fetch is still in flight at this point.
    const MID: &str = "lp-late-1";
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "look at this https://example.com/post".to_string(),
            message_id: MID.to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let delivered = wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { message_id, .. } if message_id == MID)
    })
    .await;
    assert!(delivered, "the plain message must reach the friend first");
    sleep_ms(500).await;

    // Nobody has a card yet.
    assert!(
        a.store().get_dm_message_sig_row(MID).and_then(|r| r.link_preview).is_none(),
        "the friend's row must start with no card"
    );

    // ...and now the fetch lands. This is what the compose pane calls.
    let preview = crate::node::LinkPreviewRef {
        url: "https://example.com/post".to_string(),
        title: "A Post".to_string(),
        description: "body text".to_string(),
        domain: "example.com".to_string(),
        site_name: "Example".to_string(),
        thumb_webp_b64: Some("QUJD".to_string()),
        thumb_w: Some(800),
        thumb_h: Some(450),
        rich: crate::node::RichCard {
            kind: Some("large".to_string()),
            author: Some("Jane (@jane)".to_string()),
            ..Default::default()
        }
        .into_opt(),
    };
    b.cmd_tx
        .send(NodeCommand::AttachDmLinkPreview {
            peer_id: a_master.clone(),
            message_id: MID.to_string(),
            preview: Some(Box::new(preview.clone())),
        })
        .await
        .unwrap();
    sleep_ms(2500).await;

    // Every copy of the row: sender, recipient, and our own second device.
    for (name, node) in [("sender B", &b), ("friend A", &a), ("sibling C", &c)] {
        let row = node
            .store()
            .get_dm_message_sig_row(MID)
            .unwrap_or_else(|| panic!("{name} must have the message row"));
        let card = row
            .link_preview
            .as_ref()
            .unwrap_or_else(|| panic!("{name} must have the late card"));
        assert_eq!(card.title, "A Post", "{name} card title");
        assert_eq!(
            card.rich.as_ref().and_then(|r| r.author.as_deref()),
            Some("Jane (@jane)"),
            "{name} must carry the rich author line"
        );
        assert!(
            row.edited_at.is_none(),
            "{name}: a late card must NOT mark the message edited"
        );

        // The signature must cover the card that is now on the row.
        let digest = crate::node::crypto_handler::link_preview_digest(card);
        let extras = crate::node::crypto_handler::SignedExtras {
            mid: Some(MID),
            reply_to: row.reply_to_mid.as_deref(),
            file_id: row.file_id.as_deref(),
            order_us: row.order_us,
            lp_digest: Some(&digest),
        };
        // A DM signature binds the RECIPIENT's master as context, and every
        // side reconstructs that same value — the sender from who it sent to,
        // the recipient from its own identity, a sibling from the row's convo
        // peer. All three must agree or the card breaks the row.
        let ctx = a_master.clone();
        assert!(
            crate::node::crypto_handler::verify_message_signature_v2(
                &m_master,
                row.signature.as_deref(),
                row.public_key.as_deref(),
                "dm",
                &ctx,
                row.edited_at.unwrap_or(row.timestamp),
                &extras,
                &row.text,
                &mut crate::node::crypto_handler::PkCache::new(),
            ),
            "{name}: the row must still verify against the re-signed payload"
        );
    }

    // A non-author cannot paste a card onto someone else's message: A tries to
    // set one on the message M sent, and every copy must ignore it.
    let forged = crate::node::LinkPreviewRef {
        title: "Free crypto, click here".to_string(),
        ..preview.clone()
    };
    a.cmd_tx
        .send(NodeCommand::AttachDmLinkPreview {
            peer_id: m_master.clone(),
            message_id: MID.to_string(),
            preview: Some(Box::new(forged)),
        })
        .await
        .unwrap();
    sleep_ms(1500).await;
    for (name, node) in [("sender B", &b), ("friend A", &a), ("sibling C", &c)] {
        let title = node
            .store()
            .get_dm_message_sig_row(MID)
            .and_then(|r| r.link_preview)
            .map(|c| c.title)
            .unwrap_or_default();
        assert_eq!(
            title, "A Post",
            "{name}: a non-author's attach must be refused, card unchanged"
        );
    }

    drop(a);
    drop(b);
    drop(c);
}

/// Issue #45 — attaching `None` clears the card and re-signs, which is what an
/// edit that removes the URL does. The cleared row must still verify, or the
/// message would quietly stop replicating through signed backfill.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn clearing_a_link_preview_re_signs_and_propagates() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 150;
    const M_MASTER: u8 = 151;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    drain_events(&mut a);
    drain_events(&mut b);

    const MID: &str = "lp-clear-1";
    let preview = crate::node::LinkPreviewRef {
        url: "https://example.com/x".to_string(),
        title: "Original".to_string(),
        description: String::new(),
        domain: "example.com".to_string(),
        site_name: String::new(),
        thumb_webp_b64: None,
        thumb_w: None,
        thumb_h: None,
        rich: None,
    };
    // Sent WITH a card this time.
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "https://example.com/x".to_string(),
            message_id: MID.to_string(),
            reply_to_mid: None,
            link_preview: Some(preview),
        })
        .await
        .unwrap();
    let delivered = wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { message_id, .. } if message_id == MID)
    })
    .await;
    assert!(delivered, "the carded message must arrive");
    sleep_ms(400).await;
    assert!(
        a.store().get_dm_message_sig_row(MID).and_then(|r| r.link_preview).is_some(),
        "precondition: the friend has the original card"
    );

    // The author edits the URL out, so the card is cleared.
    b.cmd_tx
        .send(NodeCommand::AttachDmLinkPreview {
            peer_id: a_master.clone(),
            message_id: MID.to_string(),
            preview: None,
        })
        .await
        .unwrap();
    sleep_ms(2000).await;

    for (name, node) in [("sender", &b), ("recipient", &a)] {
        let row = node
            .store()
            .get_dm_message_sig_row(MID)
            .unwrap_or_else(|| panic!("{name} row"));
        assert!(row.link_preview.is_none(), "{name}: the card must be gone");
        assert!(row.edited_at.is_none(), "{name}: clearing is still not an edit");

        let extras = crate::node::crypto_handler::SignedExtras {
            mid: Some(MID),
            reply_to: row.reply_to_mid.as_deref(),
            file_id: row.file_id.as_deref(),
            order_us: row.order_us,
            lp_digest: None,
        };
        let ctx = a_master.clone(); // the recipient's master, on both sides
        assert!(
            crate::node::crypto_handler::verify_message_signature_v2(
                &m_master,
                row.signature.as_deref(),
                row.public_key.as_deref(),
                "dm",
                &ctx,
                row.edited_at.unwrap_or(row.timestamp),
                &extras,
                &row.text,
                &mut crate::node::crypto_handler::PkCache::new(),
            ),
            "{name}: the cleared row must still verify"
        );
    }

    drop(a);
    drop(b);
}

/// Issue #45 follow-up — a peer that gets a message through BACKFILL gets the
/// card with it, not just a bare link.
///
/// The field report: previews work when both peers are online and the sender
/// always sees their own, but a peer catching up gets the text and no card.
/// Backfill carried only `lp_digest` — the 64-char hash the signature binds —
/// on the reasoning that verification never needs more than the hash. True,
/// and exactly why the card never arrived: nothing else in the protocol ever
/// re-sends one.
///
/// The scenario is a member who joins AFTER the card exists, chosen because it
/// is the one where sync is provably the only vehicle. A member who merely
/// goes offline and returns can also be rescued by a queued live envelope or a
/// relay topic replay, which would make this test pass with the bug still in
/// place (it did, while being written).
///
/// Two things must hold on the joiner's row, and the second is the quieter
/// half of the bug:
///  * the card is THERE, and
///  * the row still VERIFIES against the digest of that card — because the row
///    a peer stores is the row it later re-serves. A row holding a signature
///    over a preview it does not have computes `lp_digest = None` when packed
///    for the next peer, and that peer REJECTS the message as forged. The card
///    used to die after one hop; so did the message behind it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn backfilled_member_gets_link_preview_through_channel_sync() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // O = owner/poster, J = the member who only ever sees history.
    const O_MASTER: u8 = 144;
    const J_MASTER: u8 = 145;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Preview Server").await;
    let general = general_channel_of(&server_id);
    drain_events(&mut o);
    drain_events(&mut j);

    // --- The message and its card happen with O alone in the server. ---
    const MID: &str = "lp-sync-1";
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "read this https://example.com/story".to_string(),
            message_id: MID.to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    sleep_ms(800).await;

    // The fetch lands after the send — the common case, and the one that made
    // the card a separate `lp_set` frame nobody later can re-request.
    let preview = crate::node::LinkPreviewRef {
        url: "https://example.com/story".to_string(),
        title: "The Story".to_string(),
        description: "what happened".to_string(),
        domain: "example.com".to_string(),
        site_name: "Example".to_string(),
        thumb_webp_b64: Some("SEVMTE8".to_string()),
        thumb_w: Some(800),
        thumb_h: Some(450),
        rich: crate::node::RichCard {
            kind: Some("large".to_string()),
            author: Some("A Reporter".to_string()),
            ..Default::default()
        }
        .into_opt(),
    };
    o.cmd_tx
        .send(NodeCommand::AttachChannelLinkPreview {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            message_id: MID.to_string(),
            preview: Some(Box::new(preview.clone())),
        })
        .await
        .unwrap();
    sleep_ms(1500).await;
    assert!(
        o.store().get_channel_message_sig_row(MID).and_then(|r| r.link_preview).is_some(),
        "precondition: the poster holds the card"
    );
    // Precondition: J was not a member for any of it, so nothing was ever
    // addressed, queued or broadcast to them. Backfill is the only vehicle.
    assert!(
        j.store().get_channel_message_sig_row(MID).is_none(),
        "precondition: the non-member must not have the row yet"
    );

    // --- J joins. History arrives as a ChannelSyncBatch and nothing else. ---
    drain_events(&mut j);
    j.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "member J should join the server");
    // STAYS A SLEEP: the settle signal is a row in J's DB, and polling for it
    // means opening J's DB while J is writing the backfill into it. See the note
    // in corrupt_device_keyed_channel_row_self_heals_from_verified_sync.
    sleep_ms(4000).await;

    let row = j
        .store()
        .get_channel_message_sig_row(MID)
        .expect("the joining member must backfill the message row");

    // 1. The card came with the message.
    let card = row
        .link_preview
        .as_ref()
        .expect("returning member must get the CARD through sync, not just the text");
    assert_eq!(card.title, "The Story", "synced card title");
    assert_eq!(
        card.thumb_webp_b64.as_deref(),
        Some("SEVMTE8"),
        "the thumbnail must ride the batch — a card with no image is half a card"
    );
    assert_eq!(
        card.rich.as_ref().and_then(|r| r.author.as_deref()),
        Some("A Reporter"),
        "rich fields must survive the round trip"
    );
    assert!(
        row.edited_at.is_none(),
        "a card arriving through sync must not mark the message edited"
    );

    // 2. The row verifies against THAT card's digest — so this member can
    //    re-serve the message and be believed. This is the assertion that
    //    fails on the old digest-only wire.
    let digest = crate::node::crypto_handler::link_preview_digest(card);
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(MID),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: Some(&digest),
    };
    assert!(
        crate::node::crypto_handler::verify_message_signature_v2(
            &o_master,
            row.signature.as_deref(),
            row.public_key.as_deref(),
            "ch",
            &format!("{server_id}:{general}"),
            row.edited_at.unwrap_or(row.timestamp),
            &extras,
            &row.text,
            &mut crate::node::crypto_handler::PkCache::new(),
        ),
        "the synced row must verify against the card it now holds — otherwise \
         re-serving it computes a digest nobody signed and the next peer drops \
         the message entirely"
    );

    // 3. Re-syncing is idempotent: the same card arriving again must not
    //    duplicate the row.
    relay.set_online(&j.device_id, false);
    sleep_ms(300).await;
    relay.set_online(&j.device_id, true);
    sleep_ms(3000).await;
    let count = j
        .channel_messages(&server_id, &general)
        .iter()
        .filter(|m| m.text.contains("https://example.com/story"))
        .count();
    assert_eq!(count, 1, "a re-synced card must not duplicate the message row");

    drop(o);
    drop(j);
}

/// The DM half of the same fix — a card reaching a device through
/// `DmSiblingSyncBatch`, which is the DM path where backfill is provably the
/// only vehicle.
///
/// A friend who merely goes offline is rescued by the sender's pending queue
/// and the relay's per-device buffer, so that scenario cannot tell the fix from
/// the bug. A device that did not EXIST when the message was sent has neither:
/// nothing was ever queued or buffered for it, and nothing re-broadcasts. It
/// has exactly what its sibling will hand it. This is the "link my phone and
/// scroll back" case.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn freshly_linked_device_backfills_dm_link_previews_from_its_sibling() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // A = the friend. M = us: device B exists, device C gets linked later.
    const A_MASTER: u8 = 146;
    const M_MASTER: u8 = 147;
    const B_DEV: u8 = 148;
    const C_DEV: u8 = 149;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let b_dev = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();

    // Only B exists so far — C is deliberately unknown to every node, so no
    // queue or buffer can be holding anything for it.
    super::resolver::seed_self(&m_master, &[b_dev.clone()]);
    super::resolver::update_many(&m_master, [b_dev.as_str()]);

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&m_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, M_MASTER, B_DEV, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    drain_events(&mut a);
    drain_events(&mut b);

    const MID: &str = "lp-sib-1";
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "see https://example.com/thread".to_string(),
            message_id: MID.to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let delivered = wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { message_id, .. } if message_id == MID)
    })
    .await;
    assert!(delivered, "the plain message must reach the friend first");

    let preview = crate::node::LinkPreviewRef {
        url: "https://example.com/thread".to_string(),
        title: "The Thread".to_string(),
        description: "a discussion".to_string(),
        domain: "example.com".to_string(),
        site_name: "Example".to_string(),
        thumb_webp_b64: Some("VEhSRUFE".to_string()),
        thumb_w: Some(800),
        thumb_h: Some(418),
        rich: None,
    };
    b.cmd_tx
        .send(NodeCommand::AttachDmLinkPreview {
            peer_id: a_master.clone(),
            message_id: MID.to_string(),
            preview: Some(Box::new(preview.clone())),
        })
        .await
        .unwrap();
    sleep_ms(2000).await;
    assert!(
        b.store().get_dm_message_sig_row(MID).and_then(|r| r.link_preview).is_some(),
        "precondition: the sending device holds the card"
    );

    // --- NOW device C is linked. Its DB is empty; sibling backfill is all it has. ---
    super::resolver::seed_self(&m_master, &[b_dev.clone(), c_dev.clone()]);
    super::resolver::update_many(&m_master, [b_dev.as_str(), c_dev.as_str()]);
    let c = spawn_node_full(
        &relay, M_MASTER, C_DEV, &[&a_master], Some(&[b_dev.clone()]),
    )
    .await;
    sleep_ms(9000).await; // link → inbox join → DmSiblingSyncRequest → batch

    let row = c
        .store()
        .get_dm_message_sig_row(MID)
        .expect("the freshly-linked device must backfill the DM row from its sibling");
    let card = row
        .link_preview
        .as_ref()
        .expect("the linked device must get the CARD through sibling backfill");
    assert_eq!(card.title, "The Thread", "backfilled DM card title");
    assert_eq!(
        card.thumb_webp_b64.as_deref(),
        Some("VEhSRUFE"),
        "the thumbnail must ride the DM batch too"
    );
    assert!(
        row.edited_at.is_none(),
        "a backfilled card must not mark the DM edited"
    );

    // And the row verifies against that card — same re-serve argument as the
    // channel test. A DM signature binds the RECIPIENT's master as context.
    let digest = crate::node::crypto_handler::link_preview_digest(card);
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(MID),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: Some(&digest),
    };
    assert!(
        crate::node::crypto_handler::verify_message_signature_v2(
            &m_master,
            row.signature.as_deref(),
            row.public_key.as_deref(),
            "dm",
            &a_master,
            row.edited_at.unwrap_or(row.timestamp),
            &extras,
            &row.text,
            &mut crate::node::crypto_handler::PkCache::new(),
        ),
        "the backfilled DM row must verify against the card it now holds"
    );

    drop(a);
    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// Media forwarder control plane (step 3, D3): the fwd_* client plumbing.
//
// A full mock node F plays the FORWARDER role (same relay-room mechanics; the
// real forwarder's engine/media plane is outside harness scope by doctrine —
// D6 field verification covers it). Verified here:
//   1. JoinForwarderRoom is a PURE transport join — no RoomCleared (the
//      NodeCommand::JoinRoom arm would wipe the open DM pane).
//   2. First ForwarderSendSignal with NO Olm session queues + fires a signed
//      KeyRequest; the envelope drains and arrives after key exchange.
//   3. A client-bound fwd envelope (fwd_attach at a client) hits the ignore
//      arm and the node stays healthy.
//   4. Forwarder-sendable signals (fwd_egress_offer / fwd_error) emit
//      NetworkEvent::ForwarderSignal on the client with origin + payload
//      intact (the test-only build arms impersonate the forwarder role).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn forwarder_room_and_signal_round_trip() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_TAG: u8 = 131;
    const F_TAG: u8 = 141;
    let mut a = spawn_node_with_friends(&relay, A_TAG, A_TAG, &[]).await;
    sleep_ms(800).await;
    let mut f = spawn_node_with_friends(&relay, F_TAG, F_TAG, &[]).await;
    sleep_ms(1200).await;
    let f_id = f.device_id.clone();
    let a_id = a.device_id.clone();

    // F "hosts" its own fwd room (what the real forwarder does on connect);
    // A joins it to reach the forwarder.
    //
    // Both nodes ALSO join `fwd:{a_id}` because step 4 below has F impersonate
    // the forwarder role over the CLIENT send path (`ForwarderSendSignal`),
    // which routes by `fwd:{target}` — correct for client→forwarder, but the
    // real forwarder ships its replies from its OWN room
    // (`forwarder::signaling::send_haven_direct`), a path no mock node runs.
    // Joining both rooms keeps that one artifice deliverable without weakening
    // the production routing rule under test.
    for room_owner in [&f_id, &a_id] {
        f.cmd_tx
            .send(NodeCommand::JoinForwarderRoom { forwarder_peer_id: room_owner.clone() })
            .await
            .unwrap();
    }
    sleep_ms(300).await;
    drain_events(&mut a);
    for room_owner in [&f_id, &a_id] {
        a.cmd_tx
            .send(NodeCommand::JoinForwarderRoom { forwarder_peer_id: room_owner.clone() })
            .await
            .unwrap();
    }
    sleep_ms(1200).await;

    // 1. The fwd-room join must NOT clear the DM conversation pane.
    let mut saw_room_cleared = false;
    while let Ok(ev) = a.event_rx.try_recv() {
        if matches!(ev, NetworkEvent::RoomCleared) {
            saw_room_cleared = true;
        }
    }
    assert!(!saw_room_cleared, "JoinForwarderRoom must never emit RoomCleared");

    // 2. First signal with no Olm session: queue + KeyRequest + drain.
    let origin = serde_json::json!({"peer": f_id, "kind": "screen", "stream": "ab12cd34"});
    a.cmd_tx
        .send(NodeCommand::ForwarderSendSignal {
            forwarder_peer_id: f_id.clone(),
            signal_type: "fwd_attach".to_string(),
            payload: serde_json::json!({"origin": origin}).to_string(),
        })
        .await
        .unwrap();
    // Key exchange (KeyRequest -> KeyBundle -> PreKey drain) takes a moment.
    // STAYS A SLEEP. What follows is an ABSENCE proof, and absence has no
    // state to poll: the window has to be real time for "it never happened"
    // to mean anything.
    sleep_ms(4000).await;

    // 3. F received the client-bound fwd envelope and IGNORED it (no
    //    ForwarderSignal emission), staying healthy.
    let mut f_emitted_fwd = false;
    while let Ok(ev) = f.event_rx.try_recv() {
        if matches!(ev, NetworkEvent::ForwarderSignal { .. }) {
            f_emitted_fwd = true;
        }
    }
    assert!(
        !f_emitted_fwd,
        "a client-bound fwd envelope must hit the ignore arm, not emit ForwarderSignal"
    );
    drain_events(&mut a);

    // 4a. Forwarder-sendable: F -> A fwd_egress_offer emits ForwarderSignal.
    f.cmd_tx
        .send(NodeCommand::ForwarderSendSignal {
            forwarder_peer_id: a_id.clone(),
            signal_type: "fwd_egress_offer".to_string(),
            payload: serde_json::json!({"origin": origin, "sdp": "v=0 fwd offer"}).to_string(),
        })
        .await
        .unwrap();
    let mut got_payload = None;
    let got = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        if let NetworkEvent::ForwarderSignal { from_peer, signal_type, payload } = ev {
            if signal_type == "fwd_egress_offer" && *from_peer == f_id {
                got_payload = Some(payload.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(got, "client must emit ForwarderSignal for fwd_egress_offer");
    let v: serde_json::Value =
        serde_json::from_str(&got_payload.expect("payload")).expect("valid json");
    assert_eq!(v["sdp"], serde_json::json!("v=0 fwd offer"));
    assert_eq!(v["origin"]["peer"], serde_json::json!(f_id.clone()));
    assert_eq!(v["origin"]["stream"], serde_json::json!("ab12cd34"));

    // 4b. fwd_error round-trips with code + detail.
    f.cmd_tx
        .send(NodeCommand::ForwarderSendSignal {
            forwarder_peer_id: a_id.clone(),
            signal_type: "fwd_error".to_string(),
            payload: serde_json::json!({
                "origin": origin, "code": "over_budget", "detail": "egress budget exhausted",
            })
            .to_string(),
        })
        .await
        .unwrap();
    let mut err_payload = None;
    let got_err = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        if let NetworkEvent::ForwarderSignal { signal_type, payload, .. } = ev {
            if signal_type == "fwd_error" {
                err_payload = Some(payload.clone());
                return true;
            }
        }
        false
    })
    .await;
    assert!(got_err, "client must emit ForwarderSignal for fwd_error");
    let v: serde_json::Value =
        serde_json::from_str(&err_payload.expect("payload")).expect("valid json");
    assert_eq!(v["code"], serde_json::json!("over_budget"));

    drop(a);
    drop(f);
}

// ---------------------------------------------------------------------------
// fwd-room discovery-cascade suppression (§9.4).
//
// A forwarder discards every profile / sync / friend / MLS / DM frame a client
// could send it, so presence in a `fwd:` room must NOT run the peer-discovery
// cascade (~45 junk frames per join at the forwarder — the burst that used to
// drain the removed fwd control-plane token bucket and eat the large frame
// behind it). Verified here:
//   1. Joining `fwd:{F}` emits NO PeerDiscovered for F (the cascade's first
//      emission) and pushes NO profile at F.
//   2. The Olm session STILL establishes — the one piece the lane needs, since
//      queued fwd envelopes drain through it.
//   3. `synced_peers` was NOT burned: a later join of a genuinely shared room
//      runs the FULL cascade for the same peer. This is the regression that
//      would otherwise be a silent, permanent discovery blackhole.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn fwd_room_join_skips_discovery_but_keeps_olm() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // Deliberately NOT friends and sharing NO server: the fwd room is the only
    // reason these two ever meet, so any discovery traffic is attributable.
    const A_TAG: u8 = 171;
    const F_TAG: u8 = 181;
    let mut a = spawn_node_with_friends(&relay, A_TAG, A_TAG, &[]).await;
    sleep_ms(800).await;
    let mut f = spawn_node_with_friends(&relay, F_TAG, F_TAG, &[]).await;
    sleep_ms(1200).await;
    let f_id = f.device_id.clone();
    let a_id = a.device_id.clone();

    drain_events(&mut a);
    drain_events(&mut f);

    // Both sides in the forwarder's room (F hosts it, A joins to reach it).
    f.cmd_tx
        .send(NodeCommand::JoinForwarderRoom { forwarder_peer_id: f_id.clone() })
        .await
        .unwrap();
    sleep_ms(300).await;
    a.cmd_tx
        .send(NodeCommand::JoinForwarderRoom { forwarder_peer_id: f_id.clone() })
        .await
        .unwrap();
    // Long enough for the full cascade to have fired if it were going to, and
    // for key exchange (KeyRequest -> KeyBundle -> confirm) to complete.
    // STAYS A SLEEP. What follows is an ABSENCE proof, and absence has no
    // state to poll: the window has to be real time for "it never happened"
    // to mean anything.
    sleep_ms(4000).await;

    // 1. No discovery emission for the forwarder, and no profile pushed at it.
    let mut a_discovered_f = false;
    let mut a_session_with_f = false;
    while let Ok(ev) = a.event_rx.try_recv() {
        match ev {
            NetworkEvent::PeerDiscovered { ref peer } if peer.peer_id == f_id => {
                a_discovered_f = true;
            }
            NetworkEvent::SessionEstablished { ref peer_id } if *peer_id == f_id => {
                a_session_with_f = true;
            }
            _ => {}
        }
    }
    assert!(
        !a_discovered_f,
        "a fwd-room join must NOT run the discovery cascade (PeerDiscovered leaked)"
    );

    let mut f_saw_profile_from_a = false;
    while let Ok(ev) = f.event_rx.try_recv() {
        if let NetworkEvent::ProfileUpdated { ref peer_id } = ev {
            if *peer_id == a_id {
                f_saw_profile_from_a = true;
            }
        }
    }
    assert!(
        !f_saw_profile_from_a,
        "a fwd-room join must NOT push our profile at the forwarder"
    );

    // 2. The Olm session still established — without it the lane wedges (a
    //    queued fwd_stream_register would never drain). The minimal path fires
    //    the signed KeyRequest; the key-exchange handler emits this once the
    //    session confirms.
    assert!(
        a_session_with_f,
        "the fwd minimal path must still establish an Olm session"
    );

    // 3. `synced_peers` was not burned: a later join of a SHARED room runs the
    //    full cascade for the very same peer.
    drain_events(&mut a);
    let shared_room = "harness-shared-room-171-181".to_string();
    f.cmd_tx
        .send(NodeCommand::JoinRoom { room_code: shared_room.clone() })
        .await
        .unwrap();
    sleep_ms(300).await;
    a.cmd_tx
        .send(NodeCommand::JoinRoom { room_code: shared_room.clone() })
        .await
        .unwrap();
    let rediscovered = wait_event(&mut a, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::PeerDiscovered { peer } if peer.peer_id == f_id)
    })
    .await;
    assert!(
        rediscovered,
        "the fwd-room join must not burn synced_peers — a later shared-room \
         join must still run the full discovery cascade"
    );

    drop(a);
    drop(f);
}

// ---------------------------------------------------------------------------
// vc_screen_assign + route hint (media forwarding step 3, D5 wire): the
// sharer assigns a relay-routed viewer to a media forwarder over the VC lane.
// Verified: route round-trips on screen_watch (absent = "" is serde-tested);
// screen_assign round-trips origin + forwarder; a SPOOFED origin (naming a
// third party) drops the whole signal and the node stays healthy.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn vc_screen_assign_and_route_round_trip() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 151;
    const J_MASTER: u8 = 161;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Assign Server").await;
    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
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

    j.cmd_tx
        .send(NodeCommand::JoinServer { server_id: server_id.clone(), twitch_proof_json: None, nsfw_confirmed: false })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should join the server");
    sleep_ms(1500).await;

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
    o.cmd_tx
        .send(NodeCommand::VoiceChannelJoin {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
        })
        .await
        .unwrap();
    let j_saw_join = wait_event(&mut j, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, .. } if *channel_id == voice_cid)
    })
    .await;
    assert!(j_saw_join, "joiner must see the owner enter the voice channel");
    drain_events(&mut o);
    drain_events(&mut j);

    async fn next_signal(
        node: &mut TestNode,
        wanted: &str,
        secs: u64,
    ) -> Option<serde_json::Value> {
        let mut got = None;
        let ok = wait_event(node, std::time::Duration::from_secs(secs), |ev| {
            if let NetworkEvent::VoiceChannelSignal { signal_type, payload, .. } = ev {
                if signal_type == wanted {
                    got = Some(payload.clone());
                    return true;
                }
            }
            false
        })
        .await;
        if !ok { return None; }
        Some(serde_json::from_str(&got.expect("payload")).expect("valid json"))
    }

    // --- 1. Viewer (J) -> sharer (O): screen_watch carries the route hint
    // and the phase-2 forwarding capability flag ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "screen_watch".to_string(),
            payload: serde_json::json!({
                "want": true,
                "viewer_width": 2560,
                "viewer_height": 1440,
                "source_quality": false,
                "route": "relay",
                "fwd_capable": true,
                "relay_private": true,
            })
            .to_string(),
        })
        .await
        .unwrap();
    let watch = next_signal(&mut o, "screen_watch", 4).await
        .expect("sharer must receive the screen_watch");
    assert_eq!(watch["route"], serde_json::json!("relay"));
    assert_eq!(watch["viewer_width"], serde_json::json!(2560));
    assert_eq!(watch["fwd_capable"], serde_json::json!(true));
    assert_eq!(watch["relay_private"], serde_json::json!(true));

    // --- 1b. A phase-1 payload (no fwd_capable) rebuilds as false — an old
    // watcher is never a peer-forwarder candidate ---
    j.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: o_master.clone(),
            signal_type: "screen_watch".to_string(),
            payload: serde_json::json!({
                "want": true,
                "viewer_width": 1920,
                "viewer_height": 1080,
                "source_quality": false,
                "route": "direct",
            })
            .to_string(),
        })
        .await
        .unwrap();
    let watch = next_signal(&mut o, "screen_watch", 4).await
        .expect("sharer must receive the second screen_watch");
    assert_eq!(watch["fwd_capable"], serde_json::json!(false));
    assert_eq!(watch["relay_private"], serde_json::json!(false));

    // --- 2. Sharer (O) -> viewer (J): screen_assign round-trips ---
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_assign".to_string(),
            payload: serde_json::json!({
                "origin": {"peer": o_master, "kind": "screen", "stream": "cafe0123"},
                "forwarder": "12D3KooWFwdInfra",
            })
            .to_string(),
        })
        .await
        .unwrap();
    let assign = next_signal(&mut j, "screen_assign", 4).await
        .expect("viewer must receive the screen_assign");
    assert_eq!(assign["origin"]["peer"], serde_json::json!(o_master.clone()));
    assert_eq!(assign["origin"]["stream"], serde_json::json!("cafe0123"));
    assert_eq!(assign["forwarder"], serde_json::json!("12D3KooWFwdInfra"));
    drain_events(&mut j);

    // --- 3. SPOOFED origin (third party) must drop the WHOLE signal ---
    let third_party = NativeKeypair::from_secret_bytes(&seed_bytes(199)).peer_id();
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_assign".to_string(),
            payload: serde_json::json!({
                "origin": {"peer": third_party, "kind": "screen", "stream": "deadbeef"},
                "forwarder": "12D3KooWFwdInfra",
            })
            .to_string(),
        })
        .await
        .unwrap();
    let spoofed = next_signal(&mut j, "screen_assign", 3).await;
    assert!(spoofed.is_none(), "a spoofed screen_assign origin must be dropped");

    // Node stays healthy: a legit assign still arrives afterwards.
    o.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: j_master.clone(),
            signal_type: "screen_assign".to_string(),
            payload: serde_json::json!({
                "origin": {"peer": o_master, "kind": "screen", "stream": "cafe0123"},
                "forwarder": "",
            })
            .to_string(),
        })
        .await
        .unwrap();
    let revert = next_signal(&mut j, "screen_assign", 4).await
        .expect("legit revert-to-direct assign must still arrive");
    assert_eq!(revert["forwarder"], serde_json::json!(""));

    drop(o);
    drop(j);
}

// ---------------------------------------------------------------------------
// CI guard: the harness's FIXED-sleep budget.
// ---------------------------------------------------------------------------

/// Fail when the total `sleep_ms` budget in this file grows.
///
/// This is how the suite reached 16 minutes: 471 fixed sleeps totalling 831
/// seconds, 87% of the runtime, with the CPU idle the whole time. Each one was a
/// settle with a condition nobody polled for. nextest made them overlap, which
/// hid the cost without removing it, and a suite that is 87% sleep grows back to
/// 40 minutes one reasonable-looking `sleep_ms(2000)` at a time.
///
/// So the budget is a number in a test now. A new sleep has to come out of the
/// existing total or be argued for by raising this cap in a diff someone reads.
/// The alternatives are in the module above: `wait_until`, `expect_olm_confirmed`,
/// `expect_mls_leaf`, `expect_mls_group`, `expect_no_mls_leaf`. Keep `sleep_ms`
/// for the two cases that genuinely have no condition to poll: proving an
/// ABSENCE, and a settle whose only signal is a running node's SQLCipher DB.
#[test]
fn harness_fixed_sleep_budget_does_not_grow() {
    const BUDGET_MS: u64 = 566_000;

    let src = include_str!("test_harness.rs");
    // Built from pieces so this scan does not count its own source text.
    let needle = concat!("sleep_", "ms(");

    let mut total = 0u64;
    let mut calls = 0usize;
    let mut current = "<file scope>";
    let mut per_fn: Vec<(&str, u64)> = Vec::new();

    for line in src.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("async fn ").or_else(|| trimmed.strip_prefix("fn ")) {
            if let Some(name) = rest.split('(').next() {
                current = name;
            }
        }
        if trimmed.starts_with("//") {
            continue;
        }
        let mut rest = line;
        while let Some(at) = rest.find(needle) {
            rest = &rest[at + needle.len()..];
            let Some(close) = rest.find(')') else { break };
            let Ok(ms) = rest[..close].parse::<u64>() else { continue };
            total += ms;
            calls += 1;
            match per_fn.iter_mut().find(|(f, _)| *f == current) {
                Some((_, sum)) => *sum += ms,
                None => per_fn.push((current, ms)),
            }
        }
    }

    // A direct tokio sleep would slip past the scan above.
    assert_eq!(
        src.matches(concat!("tokio::time::", "sleep(")).count(),
        1,
        "fixed sleeps go through sleep_ms so this budget can see them;          found a second direct tokio::time::sleep call"
    );

    per_fn.sort_by(|a, b| b.1.cmp(&a.1));
    let worst: Vec<String> = per_fn
        .iter()
        .take(5)
        .map(|(f, ms)| format!("{f} {:.1}s", *ms as f64 / 1000.0))
        .collect();

    assert!(
        total <= BUDGET_MS,
        "harness fixed-sleep budget grew to {:.1}s across {} calls (cap {:.1}s).          Worst: {}. Wait for the condition instead: wait_until / expect_olm_confirmed /          expect_mls_leaf / expect_mls_group / expect_no_mls_leaf. If the settle really has          no pollable signal (an ABSENCE proof, or a row in a running node's DB), say so at          the call site and raise BUDGET_MS deliberately.",
        total as f64 / 1000.0,
        calls,
        BUDGET_MS as f64 / 1000.0,
        worst.join(", "),
    );
}
