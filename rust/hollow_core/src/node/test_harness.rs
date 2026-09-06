//! Headless multi-node integration test harness (Step 9B-i).
//!
//! Spins up several real `spawn_node` event loops IN ONE PROCESS, each with its
//! own keypairs and temp SQLCipher DBs, wired through an in-process
//! [`MockRelay`] that mimics only the relay's load-bearing behaviour (room
//! routing plus offline buffering; all crypto, sync and ordering live in the
//! nodes). No sockets, no TLS, no network. Design: `project_multinode_test_harness`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, OlmManager};
use crate::identity::native_identity::NativeKeypair;
use super::crdt_store::CrdtStore;
use super::types::{NetworkEvent, NodeCommand};
use super::ws_client::{WsCommand, WsEvent};

/// Process-wide guard: the resolver and the other global statics the nodes touch
/// are process-global, so harness tests run serially from a clean resolver. The
/// guard IS `resolver::test_lock()`, shared with the unit tests, so neither can
/// wipe the other's links mid-assert.
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
    /// (room_code, channel/topic) -> ring of (sender_device, frame data), mirroring
    /// the relay's per-channel topic buffers: key presence means registered, inbound
    /// topic frames tee in, catch-up replays them. Caps and TTL are not modelled.
    topic_buffers: HashMap<(String, String), Vec<(String, Vec<u8>)>>,
    /// nickname -> (claimer device_peer_id, claimer's self-reported master).
    /// Mirrors the relay's temporary-nickname registry. TTL not modeled;
    /// an offline holder resolves as not_found like the real staleness check.
    nicknames: HashMap<String, (String, String)>,
    /// Devices that silently DON'T receive 0x03 room broadcasts while still present
    /// in the room. Models the relay's backpressure drop on a long-lived socket (uWS
    /// returns DROPPED with no error to the sender), the loss mode behind the
    /// join-order MLS epoch race: the victim looks perfectly healthy to everyone.
    broadcast_deaf: HashSet<String>,
    /// Devices whose outgoing `profile_update` frames get their `support_creds`
    /// rewritten to `""` and their signature removed, IN FLIGHT. This is the attack
    /// `support_creds_sig` exists for: the plaintext fallback is a JSON body the relay
    /// can edit, and `Some("")` is an explicit clear on every receiver.
    strip_support_creds: HashSet<String>,
    /// Devices whose outgoing `profile_update` frames lose their
    /// `support_creds_sig` and keep the field. What every client that
    /// predates the signature sends, and the shape the pin has to tolerate
    /// until it has seen one signed announce.
    drop_support_creds_sig: HashSet<String>,
    /// Devices whose outgoing data frames are kept, so a test can replay one
    /// later (a captured older announce is a replay, not a forgery).
    recording: HashSet<String>,
    recorded: Vec<(String, Vec<u8>)>,
    /// Optional load meter (scaling benchmark). When `Some`, every command the
    /// relay handles and every frame the relay DELIVERS to a socket is tallied
    /// here — the ground truth for "what does one server operation cost the
    /// relay + the coordinator". `None` in normal tests (zero overhead).
    meter: Option<RelayMeter>,
}

/// Frame accounting for the scaling benchmark, cumulative from the last
/// [`MockRelay::reset_meter`]. `*_cmds` are inbound commands a NODE issued;
/// `deliveries` are outbound frames the RELAY copied to a socket, which is the
/// O(N) fan-out and the true bandwidth bottleneck.
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

    /// The DEVICE peer_ids the relay considers online. This is the relay's
    /// authoritative presence view, the same thing the real relay reports via
    /// `RoomMembers`, so inspectors read presence from here and never from a node.
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

    /// Frames currently buffered for `peer`. The relay buffers a direct frame under
    /// the TARGET device id when that device is not in the room and (on the real
    /// relay) pushes to it, so a non-zero count is the proxy for "would be woken".
    #[allow(dead_code)]
    pub(crate) fn buffered_count(&self, peer: &str) -> usize {
        let inner = self.inner.lock().unwrap();
        inner.offline.get(peer).map(|v| v.len()).unwrap_or(0)
    }

    /// The buffered payloads held for `peer`, CLONED (nothing is consumed).
    /// `buffered_count` answers "was anything left for them"; this answers
    /// "WHAT was left", which is the only way to assert that the frame waiting
    /// in a mailbox is the decline and that it names the right request.
    #[allow(dead_code)]
    pub(crate) fn buffered_frames(&self, target: &str) -> Vec<Vec<u8>> {
        let inner = self.inner.lock().unwrap();
        inner
            .offline
            .get(target)
            .map(|v| v.iter().map(|m| m.data.clone()).collect())
            .unwrap_or_default()
    }

    /// Drop everything buffered for `target`, simulating the mailbox TTL lapsing
    /// (the real relay holds a master's inbox for 3 days). The case that matters
    /// is a decline that expires BEFORE the requester next boots: the requester
    /// then re-deposits its request, and the decliner has to answer again.
    #[allow(dead_code)]
    pub(crate) fn expire_mailbox(&self, target: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.offline.remove(target);
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
    /// The real relay only broadcasts `PeerLeft` for a clean leave, so a pulled
    /// adapter leaves peers holding the dead node in `synced_peers`: on its return
    /// their `is_new` guard reads false and the whole reconnect cascade is skipped.
    /// `set_online(false)` is the polite version and cannot reproduce that.
    fn drop_socket_silently(&self, peer_id: &str) {
        self.set_online_inner(peer_id, false, false)
    }

    fn set_online_inner(&self, peer_id: &str, online: bool, announce_leave: bool) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(conn) = inner.conns.get_mut(peer_id) {
            conn.online = online;
        }
        if !online {
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
            // Tell the offline node its OWN socket died. Without `WsEvent::Disconnected` the
            // node never clears sync-gating state (`synced_peers`, `key_request_in_flight`,
            // ...), so on reconnect the `is_new` guard suppresses the proactive sync and key
            // exchange and the reconnect flow silently does nothing.
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

    /// Every frame currently sitting in a (room, topic) ring, oldest first, as
    /// `(sender_device, payload)`. This is the relay-side truth behind a parked
    /// join: the request the joiner deposited, and the members' resolutions.
    /// Nothing is consumed.
    #[allow(dead_code)]
    pub(crate) fn topic_frames(&self, room: &str, topic: &str) -> Vec<(String, Vec<u8>)> {
        let inner = self.inner.lock().unwrap();
        inner
            .topic_buffers
            .get(&(room.to_string(), topic.to_string()))
            .cloned()
            .unwrap_or_default()
    }

    /// Whether a (room, topic) ring has been REGISTERED (`set_topic_buffer`).
    /// An unregistered ring silently drops every publish, exactly like the real
    /// relay, so "the members registered it while they were here" is a real
    /// precondition of a parked join and a real thing to wait for.
    #[allow(dead_code)]
    pub(crate) fn topic_registered(&self, room: &str, topic: &str) -> bool {
        let inner = self.inner.lock().unwrap();
        inner.topic_buffers.contains_key(&(room.to_string(), topic.to_string()))
    }

    /// Test-only: write a frame straight into a (room, topic) ring as if `from` had
    /// published it, creating the ring if the room never registered one.
    ///
    /// Registration is deliberately bypassed, because this models a HOSTILE
    /// publisher: the RECEIVER must refuse the frame on its own merits.
    #[allow(dead_code)]
    pub(crate) fn inject_topic(&self, room: &str, topic: &str, from: &str, data: Vec<u8>) {
        let mut inner = self.inner.lock().unwrap();
        inner
            .topic_buffers
            .entry((room.to_string(), topic.to_string()))
            .or_default()
            .push((from.to_string(), data));
    }

    /// Make a device deaf to 0x03 room broadcasts (or restore it) — the
    /// silent-loss lever for the join-order MLS epoch race tests. The device
    /// stays in its rooms and keeps receiving presence + direct frames.
    #[allow(dead_code)]
    /// Rewrite `support_creds` out of this device's profile announces in
    /// flight, exactly as a hostile relay would.
    pub(crate) fn set_strip_support_creds(&self, peer_id: &str, on: bool) {
        let mut inner = self.inner.lock().unwrap();
        if on {
            inner.strip_support_creds.insert(peer_id.to_string());
        } else {
            inner.strip_support_creds.remove(peer_id);
        }
    }

    /// Send this device's profile announces with the field and no signature,
    /// the way a client that predates the signature does.
    pub(crate) fn set_drop_support_creds_sig(&self, peer_id: &str, on: bool) {
        let mut inner = self.inner.lock().unwrap();
        if on {
            inner.drop_support_creds_sig.insert(peer_id.to_string());
        } else {
            inner.drop_support_creds_sig.remove(peer_id);
        }
    }

    /// Keep a copy of every data frame this device sends.
    pub(crate) fn set_recording(&self, peer_id: &str, on: bool) {
        let mut inner = self.inner.lock().unwrap();
        if on {
            inner.recording.insert(peer_id.to_string());
        } else {
            inner.recording.remove(peer_id);
        }
    }

    /// The frames recorded from `peer_id`, oldest first.
    pub(crate) fn recorded_frames(&self, peer_id: &str) -> Vec<Vec<u8>> {
        let inner = self.inner.lock().unwrap();
        inner
            .recorded
            .iter()
            .filter(|(from, _)| from == peer_id)
            .map(|(_, data)| data.clone())
            .collect()
    }

    /// Deliver `data` to `target` as if `from` had just sent it into `room`.
    /// A replay: the bytes are whatever the test captured, unchanged.
    pub(crate) fn inject(&self, room: &str, from: &str, target: &str, data: Vec<u8>) {
        let inner = self.inner.lock().unwrap();
        if let Some(conn) = inner.conns.get(target).filter(|c| c.online) {
            let _ = conn.event_tx.send(WsEvent::Message {
                room: room.to_string(),
                from: from.to_string(),
                data,
            });
        }
    }

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
                for m in &existing {
                    if let Some(conn) = inner.conns.get(m) {
                        let _ = conn.event_tx.send(WsEvent::PeerJoined {
                            room: room_code.clone(),
                            peer_id: from.to_string(),
                        });
                    }
                }
                inner.replay_offline(from, &room_code);
            }
            WsCommand::JoinInbox { room_code, proof } => {
                // Same join as above, PLUS the master-keyed mailbox replay the real
                // relay does for a proven inbox owner (async friending, Change 1).
                let existing: Vec<String> = inner
                    .rooms
                    .get(&room_code)
                    .map(|s| s.iter().cloned().collect())
                    .unwrap_or_default();
                inner.rooms.entry(room_code.clone()).or_default().insert(from.to_string());
                let mut members = existing.clone();
                members.push(from.to_string());
                if let Some(conn) = inner.conns.get(from) {
                    let _ = conn.event_tx.send(WsEvent::RoomMembers {
                        room: room_code.clone(),
                        peers: members,
                    });
                }
                for m in &existing {
                    if let Some(conn) = inner.conns.get(m) {
                        let _ = conn.event_tx.send(WsEvent::PeerJoined {
                            room: room_code.clone(),
                            peer_id: from.to_string(),
                        });
                    }
                }
                inner.replay_offline(from, &room_code);

                // OWNERSHIP CHECK, every clause exactly as the real relay must: the device list
                // verifies under its own master pubkey, that pubkey derives to the claimed master
                // (`verify_device_list` folds both), THIS authenticated socket is a live
                // un-revoked member of it, and the room really is that master's inbox. Any
                // failure replays NOTHING and returns no error, so a stranger learns nothing.
                let owner_ok = super::crypto_handler::verify_device_list(&proof)
                    && proof.devices.iter().any(|d| d == from)
                    && !proof.revoked.iter().any(|r| r == from)
                    && room_code == format!("inbox:{}", proof.master_peer_id);
                if owner_ok {
                    inner.replay_mailbox(from, &proof.master_peer_id);
                }
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
                let data = inner.on_the_wire(from, data);
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
                let data = inner.on_the_wire(from, data);
                let n = data.len() as u64;
                let delivered = inner.deliver_direct(&room_code, from, &target_peer, data, true);
                if let Some(m) = inner.meter.as_mut() {
                    m.deliveries += delivered;
                    m.direct_deliveries += delivered;
                    m.bytes_out += delivered * n;
                }
            }
            WsCommand::SendBinaryDirect { room_code, target_peer, data } => {
                // Delivered as BinaryDirect when present, not buffered. Both ends must be in the
                // room: the relay drops a 0x02 whose SENDER never joined, so a sender that skips
                // the join must fail here too rather than passing only under the mock.
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
    /// Record and, when a test has armed it, TAMPER with one outgoing frame.
    ///
    /// The only rewrite modelled is the `support_creds` strip, the one the field
    /// signature defends against: every receiver honours `""` as an explicit clear.
    fn on_the_wire(&mut self, from: &str, data: Vec<u8>) -> Vec<u8> {
        if self.recording.contains(from) {
            self.recorded.push((from.to_string(), data.clone()));
        }
        let strip = self.strip_support_creds.contains(from);
        let unsign = self.drop_support_creds_sig.contains(from);
        if !strip && !unsign {
            return data;
        }
        let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&data) else {
            return data;
        };
        let Some(obj) = value.as_object_mut() else { return data };
        if obj.get("type").and_then(|t| t.as_str()) != Some("profile_update") {
            return data;
        }
        if strip {
            obj.insert("support_creds".to_string(), serde_json::Value::String(String::new()));
        }
        obj.remove("support_creds_sig");
        serde_json::to_vec(&value).unwrap_or(data)
    }

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

    /// Replay a MASTER's mailbox to a socket that has PROVEN it owns that inbox.
    ///
    /// TTL-only, NOT delete-on-replay: every sibling device must be able to collect
    /// the same request on its own next boot, so consuming it for the first device to
    /// ask would hide it from the rest. The receiver dedups on its friends row, which
    /// is what makes re-delivery harmless. Per-socket "already delivered" tracking is
    /// delete-on-replay wearing a hat.
    fn replay_mailbox(&mut self, peer: &str, master: &str) {
        let Some(buf) = self.offline.get(master) else { return };
        let frames: Vec<(String, String, Vec<u8>, bool)> = buf
            .iter()
            .map(|m| (m.room.clone(), m.from.clone(), m.data.clone(), m.direct))
            .collect();
        let Some(conn) = self.conns.get(peer) else { return };
        if !conn.online {
            return;
        }
        for (room, from, data, direct) in frames {
            let ev = if direct {
                WsEvent::DirectMessage { room, from, data }
            } else {
                WsEvent::Message { room, from, data }
            };
            let _ = conn.event_tx.send(ev);
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
    /// This node's MASTER keypair — the key its own event loop signs CRDT ops
    /// with. A test that has to forge (or legitimately author) an op on a
    /// node's behalf needs it, because a CrdtOp is bound to its author by
    /// signature now.
    pub master_kp: NativeKeypair,
    _join: tokio::task::JoinHandle<()>,
    // Keep the tempdir alive for the node's lifetime.
    _tmp: tempfile::TempDir,
}

impl TestNode {
    fn store(&self) -> crate::storage::MessageStore {
        crate::storage::MessageStore::open(&self.db_path, &self.passphrase)
            .expect("open node store")
    }

    /// End this node's life and hand back the storage a RESTART needs: the DB path
    /// and the tempdir that owns it.
    ///
    /// Aborting the join handle is what a process exit does to the event loop, and
    /// the store actors die with it, which is what lets the file be reopened.
    fn into_storage(self) -> (String, tempfile::TempDir) {
        self._join.abort();
        (self.db_path, self._tmp)
    }
}

// Inspectors: read a node's REAL state the way the UI does, in two layers,
// because the gap between them is where multi-device bugs hide. The UI layer is
// master-collapsed and reads through the same accessors the Dart providers use;
// the raw layer is device-keyed underlying truth, so a test can assert the
// invariant beneath the UI. DB-backed state comes from the node's own SQLCipher
// store; presence comes from the MockRelay, which is authoritative.

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

    /// Server ids this node is a member of (what the server strip shows), mirroring
    /// `get_joined_servers`: a tombstoned server is HIDDEN (the shell is kept only to
    /// serve the deletion op), and so is a shell we are no longer a member of.
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

    /// Parked/rejected join rows as `list_pending_joins` would hand them to the
    /// UI: `(server_id, state, reason)`, newest ask first. Reads the same table
    /// through the same accessor the FFI does.
    pub(crate) fn pending_joins(&self) -> Vec<(String, String, String)> {
        self.store()
            .load_pending_joins()
            .unwrap_or_default()
            .into_iter()
            .map(|r| (r.server_id, r.state, r.reason))
            .collect()
    }

    /// Load one server's CRDT state (None if not joined).
    fn server_state(&self, server_id: &str) -> Option<ServerState> {
        let json = self.store().load_server_state(server_id).ok().flatten()?;
        serde_json::from_str::<ServerState>(&json).ok()
    }

    /// A LIVE clone of the event loop's in-memory `ServerState`, the copy that
    /// ENFORCES, round-tripped exactly as `api::crdt::live_server_state` does.
    ///
    /// Prefer this over `server_state` when asserting that a hostile op did NOT land:
    /// the DB snapshot is written by a fire-and-forget actor, and polling SQLCipher
    /// starves that writer. `None` means the loop never answered, never "no change".
    pub(crate) async fn live_server_state(&self, server_id: &str) -> Option<ServerState> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.cmd_tx
            .send(NodeCommand::GetServerStateSnapshot {
                server_id: server_id.to_string(),
                reply: tx,
            })
            .await
            .ok()?;
        tokio::time::timeout(std::time::Duration::from_secs(5), rx)
            .await
            .ok()?
            .ok()?
    }

    /// A member's role as the LIVE state holds it. Panics if the loop does not
    /// answer or does not hold the server: a timed-out probe is not a role.
    pub(crate) async fn live_role(
        &self,
        server_id: &str,
        master: &str,
    ) -> crate::crdt::operations::MemberRole {
        self.live_server_state(server_id)
            .await
            .unwrap_or_else(|| panic!("no live state for {server_id}"))
            .get_role(master)
    }

    /// The server name as the LIVE state holds it. Panics like `live_role`.
    pub(crate) async fn live_server_name(&self, server_id: &str) -> String {
        self.live_server_state(server_id)
            .await
            .unwrap_or_else(|| panic!("no live state for {server_id}"))
            .name()
            .to_string()
    }

    /// The Owner the LIVE state currently recognises. Panics like `live_role`.
    pub(crate) async fn live_owner(&self, server_id: &str) -> Option<String> {
        self.live_server_state(server_id)
            .await
            .unwrap_or_else(|| panic!("no live state for {server_id}"))
            .current_owner()
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

    /// The RAW `sender_id` a channel message row is stored under, NOT collapsed
    /// device to master. A stored sender must be the sender's MASTER; a leaked DEVICE
    /// id means the receive path stored it unresolved, which the collapsed
    /// `channel_messages` inspector hides by resolving on read.
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

    /// The MLS group's leaf DEVICE ids for `group_id`, telling "the loop did not
    /// reply" (None) apart from "the group holds no such leaf" (empty). An EVICTION
    /// wait MUST use this: a timed-out snapshot yields an empty list, which reads
    /// exactly like a successful removal.
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
/// relay. A shared `master_tag` makes siblings; a distinct `device_tag` gives each
/// its own transport id. Friendless scenarios only.
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
        master_kp: master.clone(),
        _join: join,
        _tmp: tmp,
    }
}

/// Spawn a node on a db_path the CALLER already created, pre-seeded and owns.
/// Unlike `spawn_node_full` this neither creates nor seeds the DB, so a test can
/// stage arbitrary on-disk state and run the real startup code against it. The
/// caller must already have run `migrate_auto_vacuum_once` and saved an account.
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

    // LOAD the Olm account the way production does: the pickled account plus every
    // stored session. Minting a fresh account on a DB that already has one hands the
    // node a NEW identity key, so every peer's session silently stops decrypting and
    // a restart test would be measuring the harness rather than the code.
    let olm = {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase).expect("open store");
        match store.load_olm_account().expect("load olm account") {
            Some(account_json) => {
                let sessions = store.load_all_olm_sessions().expect("load olm sessions");
                OlmManager::from_pickles(&account_json, sessions).expect("restore olm")
            }
            None => {
                let mgr = OlmManager::new();
                let pickle = mgr.account_pickle_json().expect("pickle");
                store.save_olm_account(&pickle).expect("save olm");
                mgr
            }
        }
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
        master_kp: master.clone(),
        _join: join,
        _tmp: tmp,
    }
}

/// Restart one node: take it off the relay, kill its event loop, and boot a new
/// one on the SAME encrypted DB with the same master/device keys.
///
/// MLS state is the interesting half: the storage blob carrying the private half
/// of every minted KeyPackage is restored from the crypto store, so anything
/// minted but not persisted is gone. The returned `event_rx` is fresh.
async fn restart_node(
    relay: &MockRelay,
    node: TestNode,
    master_tag: u8,
    device_tag: u8,
) -> TestNode {
    let device_id = node.device_id.clone();
    relay.set_online(&device_id, false);
    assert!(
        wait_until(10, async || !relay.online_devices().contains(&device_id)).await,
        "{device_id} must be off the relay before its DB is reopened",
    );
    let (db_path, tmp) = node.into_storage();
    // The old loop is aborted, so its store actors are closing. Give the
    // SQLCipher handles a moment to go: there is no signal to poll for "a task
    // that was aborted has finished dropping its locals", and reopening the
    // file under the old writer costs a 4s busy_timeout on every query.
    sleep_ms(300).await;
    spawn_node_on_db(relay, master_tag, device_tag, &db_path, tmp).await
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
/// **This is the default settle primitive, not `sleep_ms`.** A fixed sleep must be
/// long enough for the slowest machine that will ever run it, so it is dead time
/// everywhere else and a silent flake where it turned out too short. Reach for
/// `sleep_ms` ONLY to prove an ABSENCE, which has no state to poll.
///
/// POLL LIVE STATE, NEVER A RUNNING NODE'S DB. `olm_status`, `mls_members` and
/// `mls_epoch` round-trip a `DebugSnapshot` and are free to ask repeatedly.
/// Everything else here calls `store()`, which opens a NEW SQLCipher connection
/// and starves the node's own writer (busy_timeout 4000ms): a 250ms poll for a
/// channel-row heal stopped it landing inside 15s where a sleep saw it in under 4.
/// If the only settle signal is on disk, use a sleep and say why.
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
/// Use this wherever a test must outlast a real timestamp: a grant expiry, a TTL,
/// a sweep window. The duration form silently depends on how long the steps above
/// took, which breaks the moment those steps start polling instead of sleeping.
async fn sleep_until_ms(deadline_ms: u64, grace_ms: u64) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    sleep_ms(deadline_ms.saturating_sub(now) + grace_ms).await;
}

/// Wait until `a` and `b` hold a CONFIRMED Olm session with each other, and panic
/// with both directions' status if they do not. Bidirectional on purpose: an
/// outbound-only session is not usable yet, which is exactly the half-built state
/// a too-short fixed sleep left behind.
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

/// Wait until a freshly spawned friend PAIR is actually usable: confirmed Olm both
/// ways, AND both devices present in the DM room their traffic rides.
///
/// Waiting only for Olm is not enough: the session confirms well before both nodes
/// finish joining their rooms, and tests converted to Olm-only went intermittent
/// by sending into a room the recipient had not joined yet.
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
/// panic with the leaf list if it never does. `group_id` is a `server_id`, or
/// `subgroup_id(server, channel)` for a per-channel group.
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

/// Wait until `holder`'s MLS group for `group_id` no longer carries `leaf`. An
/// eviction is a convergence, not an absence: the leaf is gone once the commit
/// that removed it has been applied, which is observable, so it is polled.
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

/// Build a CRDT op by hand the way `create_op` would, signed with `signer` or left
/// unsigned when it is `None`.
///
/// `author` is written VERBATIM, which is the point: the interesting cases are an
/// author the signing key does not derive, and no signature at all. `ahead_ms`
/// offsets the timestamp so an op that WOULD win the LWW comparison can be built.
fn forge_crdt_op(
    server_id: &str,
    author: &str,
    payload: crate::crdt::operations::CrdtPayload,
    ahead_ms: u64,
    signer: Option<&NativeKeypair>,
) -> crate::crdt::operations::CrdtOp {
    use base64::Engine as _;
    let mut op = crate::crdt::operations::CrdtOp {
        server_id: server_id.to_string(),
        hlc: crate::crdt::hlc::HlcTimestamp {
            physical_ms: crate::crdt::hlc::wall_clock_ms().saturating_add(ahead_ms),
            counter: 0,
            actor: author.to_string(),
        },
        author: author.to_string(),
        payload,
        auth: None,
    };
    if let Some(kp) = signer {
        let pk = base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf());
        op.sign(kp, &pk);
    }
    op
}

/// The exact bytes a peer would put on the wire to replicate one op.
fn crdt_broadcast_frame(server_id: &str, op: &crate::crdt::operations::CrdtOp) -> Vec<u8> {
    serde_json::to_vec(&super::types::HavenMessage::CrdtOpBroadcast {
        server_id: server_id.to_string(),
        op_json: serde_json::to_string(op).expect("serialize op"),
    })
    .expect("serialize frame")
}

/// The exact bytes a peer would put on the wire to answer a sync request with
/// a batch of ops.
fn sync_response_frame(server_id: &str, ops: &[crate::crdt::operations::CrdtOp]) -> Vec<u8> {
    serde_json::to_vec(&super::types::HavenMessage::SyncResponse {
        server_id: server_id.to_string(),
        ops_json: serde_json::to_string(ops).expect("serialize ops"),
    })
    .expect("serialize frame")
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

    // A = friend (outsider, device == master, the keystone case). M = our identity
    // with two devices B and C; C sends while B is offline, and B must later recover
    // those sends from A on the correct side.
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

    // Olm key exchange must FULLY CONFIRM before any DM is sent, or the DM rides an
    // unconfirmed ratchet and fails to decrypt. Glare resolution takes a couple of
    // round trips, so wait for the sessions rather than guessing at a duration.
    expect_dm_pair_ready(&relay, &a, &b, 20).await;
    expect_dm_pair_ready(&relay, &a, &c, 20).await;
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    // --- B goes offline; C and A exchange 6 DMs (C wrote FIRST) ---
    relay.set_online(&b.device_id, false);
    sleep_ms(300).await;

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

    {
        let thread = a.dm_thread(&b.master_id);
        assert_eq!(thread.len(), 6, "A should hold all 6 messages, got {}", thread.len());
    }

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

    let synced = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::DmSyncCompleted { .. })
    })
    .await;
    assert!(synced, "B should receive DmSyncCompleted from A");
    sleep_ms(200).await; // let the final inserts commit

    // --- THE ASSERTIONS: B recovered all 6 on the CORRECT side ---
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

// Rung 2: a friend JOINS a server, the MLS group forms across both nodes, and an
// encrypted channel message DECRYPTS on the joiner's device.

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

    assert_eq!(
        o.mls_members(&server_id).await,
        vec![o.device_id.clone()],
        "owner is the sole MLS leaf right after CreateServer"
    );
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

    // …then the MLS handshake (KeyPackage → 2s batch timer → Welcome) forms the
    // group on the joiner. Give the 2s mls_batch_timer room to fire after the KP.
    sleep_ms(5000).await;

    let owner_leaves = o.mls_members(&server_id).await;
    let joiner_leaves = j.mls_members(&server_id).await;
    let expected = {
        let mut v = vec![o.device_id.clone(), j.device_id.clone()];
        v.sort();
        v
    };
    assert_eq!(owner_leaves, expected, "owner's MLS group must contain both device leaves");
    assert_eq!(joiner_leaves, expected, "joiner's MLS group must contain both device leaves");
    assert!(o.mls_epoch(&server_id).await.unwrap_or(0) >= 1, "owner epoch advanced past the add");
    assert_eq!(
        o.mls_epoch(&server_id).await,
        j.mls_epoch(&server_id).await,
        "owner and joiner must be at the same MLS epoch"
    );

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

    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "hello channel").expect("message stored");
    assert_eq!(row.sender_master, o_master, "channel message attributed to owner master");
    assert!(!row.is_mine, "received message is not is_mine on the joiner");
}

// A PUBLIC channel broadcasts signed PLAINTEXT and the relay frame's `from` is the
// sender's DEVICE id, so the receiver must attribute the message to that sender's
// MASTER in BOTH the live event and the raw stored row. A device-keyed row breaks
// the name in the bubble and the signature check alike.

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
    let msgs = j.channel_messages(&server_id, &general);
    let row = msgs.iter().find(|m| m.text == "public from a device").expect("public message stored");
    assert_eq!(row.sender_master, o_master, "public channel message attributed to O's master");
    assert!(!row.is_mine, "received public message is not is_mine on J");
}

// A node emits a real RelayConnected event once its WS connection is up, which is
// the signal the UI shows "Connected" from.

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

// NSFW join-consent gate: an NSFW-flagged server rejects a first join with an
// `nsfw_confirm:` reason and accepts the retry that carries nsfw_confirmed, the
// reject-then-retry flow every join entry point rides for free.

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

    assert!(
        !j.raw_crdt_member_keys(&server_id).contains(&j_master),
        "joiner must not be a member before confirming NSFW consent"
    );
    drain_events(&mut j);

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

// A channel typing indicator round-trips over the MLS server group and is
// attributed to the sender's MASTER, which is what the UI keys "X is typing" on.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_typing_roundtrips_master_attributed() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Rung 3: device REVOCATION. One sibling revokes another and the cutoff is total:
// the revoked device gets SelfRevoked, the revoker drops its Olm session, and a
// later DM from a friend never reaches it, because fan-out targets only devices
// currently in a room.

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

    assert_ne!(
        b.olm_status(&c.device_id).await,
        "absent",
        "B should hold an Olm session with sibling C before revoking it"
    );

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

// Issue 1-C: "a NEW DEVICE appeared for this contact" must reach the friend as a
// visible alert, driven by a device list that genuinely propagated over the wire,
// and must NOT fire on the FIRST list a friend ever sees, which is a baseline
// rather than a change.

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

    let mut c = spawn_node_with_friends(&relay, M_MASTER, C_DEV, &[&a_master]).await;

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

// Push targeting: a DM to a multi-device identity must reach a fully-quit sibling
// device via the relay's offline buffer, so the real relay would fire a push to
// that device's token.

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

// Call signal routing. A call signal addressed to a friend's MASTER must be mapped
// from its whitelisted signal_type to the right HavenMessage variant and routed to
// the friend's concrete online DEVICE, since no socket authenticates as the
// master. An unknown signal_type is silently dropped, never delivered.

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
    // Call signaling rides Olm now (TRANSPORT-1), so the pair must be genuinely
    // usable before the first signal: confirmed session both ways AND both
    // devices in the DM room the signal routes through. A sleep is not that.
    expect_dm_pair_ready(&relay, &a, &b, 20).await;
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

    let mut got_call_id = None;
    let rang = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
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
    let saw_rec = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
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
    let saw_watch = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
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

// TRANSPORT-1: the 1:1 call SFrame media key must never be legible to the relay.
// Call signaling used to ride the wire as a bare `CallInvite`, so the relay read
// the AES-128-GCM key out of every invite and could inject a forged accept
// carrying its own. The invite now travels inside the Olm ciphertext.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn call_invite_never_exposes_sframe_key_to_the_relay() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 74;
    const B_MASTER: u8 = 84;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 20).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // Record every frame A hands the relay from here on. The relay sees exactly
    // these bytes, so anything legible in them is legible to the relay.
    relay.set_recording(&a.device_id, true);

    // A distinctive key: if any byte of it survives into a frame, a substring
    // search finds it. (Hex, like the real SFrame key the Dart side generates.)
    const SFRAME_KEY: &str = "deadbeefcafef00d0123456789abcdef";
    a.cmd_tx
        .send(NodeCommand::CallSendSignal {
            peer_id: b_master.clone(),
            signal_type: "invite".to_string(),
            payload: serde_json::json!({
                "call_id": "call-secret",
                "video": false,
                "sframe_key": SFRAME_KEY,
            })
            .to_string(),
        })
        .await
        .unwrap();

    let mut got_key = None;
    let rang = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::CallSignal { signal_type, payload, .. } = ev {
            if signal_type == "invite" {
                let v: serde_json::Value = serde_json::from_str(payload).unwrap_or_default();
                got_key = v["sframe_key"].as_str().map(|s| s.to_string());
                return true;
            }
        }
        false
    })
    .await;
    assert!(rang, "the callee must still receive the invite over the encrypted transport");
    assert_eq!(got_key.as_deref(), Some(SFRAME_KEY), "the callee must recover the SFrame key");

    relay.set_recording(&a.device_id, false);
    let frames = relay.recorded_frames(&a.device_id);
    assert!(!frames.is_empty(), "the relay must have handled at least the invite frame");
    for frame in &frames {
        let text = String::from_utf8_lossy(frame);
        assert!(
            !text.contains(SFRAME_KEY),
            "the relay read the SFrame key verbatim out of a frame: {text}",
        );
        assert!(
            !text.contains("sframe_key"),
            "the relay saw the call's key FIELD in the clear: {text}",
        );
        assert!(
            !text.contains("call-secret"),
            "the relay saw the call id in the clear: {text}",
        );
    }
}

// TRANSPORT-1, receive half: a Call* frame that arrives in the CLEAR is an
// injection and must be rejected, not handled. A forged CallAccept would otherwise
// hand our media session a key the attacker chose.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn plaintext_call_signal_is_rejected() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 75;
    const B_MASTER: u8 = 85;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 20).await;
    drain_events(&mut a);

    // B's socket pushes a bare, unencrypted CallInvite at A — exactly the frame
    // the old sender produced, and exactly what an on-path relay can synthesize.
    let dm_room = super::types::dm_room_code(&a.master_id, &b.master_id);
    let forged = serde_json::to_vec(&super::types::HavenMessage::CallInvite {
        call_id: "forged-call".to_string(),
        video: false,
        sframe_key: "00000000000000000000000000000000".to_string(),
    })
    .expect("serialize forged invite");
    relay.inject_direct(&dm_room, &b.device_id, &a.device_id, forged);

    // Absence proof: a bounded wait, then assert nothing rang. A CallSignal here
    // would mean the plaintext path is still live.
    let rang = wait_event(&mut a, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::CallSignal { .. })
    })
    .await;
    assert!(!rang, "a plaintext call signal must be REJECTED, never surfaced as a call");
}

// Full DM file send end to end: the FileHeader rides Olm and the encrypted bytes
// fall back to WSS-relay streaming when there is no data channel, so the bytes
// really transfer and decrypt in-process. Only the WebRTC byte path is out of
// scope; the relay fallback shares the assembly and decrypt logic.

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

    let done = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "receiver must complete the file transfer (relay byte fallback)");
    sleep_ms(200).await;

    let meta = b.file_meta(&fid).expect("receiver persisted a files row");
    assert_eq!(meta.context_type, "dm", "file context is a DM");
    assert!(meta.file_name.starts_with("hello"), "header name persisted, got {:?}", meta.file_name);
    assert_eq!(meta.size_bytes, contents.len() as u64, "size matches the source file");
    assert!(meta.completed_at.is_some(), "transfer completed");
    let disk = meta.disk_path.expect("completed file has a disk path");
    let got = std::fs::read(&disk).expect("read the received file");
    assert_eq!(got, contents, "received file must decrypt to the original contents");
    assert!(!b.missing_file_ids().contains(&fid), "completed file is not missing");
}

/// Issue #41 auto-download gate. With auto-download OFF the receiver keeps the
/// pushed file's METADATA (the card renders a manual Download button) but registers
/// no stream, so the bytes are discarded and the row never completes. An explicit
/// RequestFile then bypasses the gate and completes normally.
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

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
}

/// Issue #41, sender-side pre-negotiation. When the receiver's gating preference is
/// advertised BEFORE the send, the sender never streams the bytes at all: the
/// receiver gets a METADATA-ONLY header with no AES material. The manual
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

/// Issue #41: voice messages are exempt from the auto-download gate END TO END, so
/// a voice-flagged send streams and auto-completes on a gated conversation. Also
/// covers the wire filename, which is the recorder's temp basename rather than the
/// literal "Voice message.ogg" the old check matched.
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

// Honest file card states. A file whose bytes are not on disk used to show a
// Download button that could silently do nothing, because a holder that no longer
// had the bytes stayed SILENT. `FileUnavailable` is the negative answer and
// `node/file_asks.rs` is the asker-side table that rotates on it.

/// State 3, both shapes of "I lost the bytes". The holder still has the ROW, so it
/// is entitled to answer, but cannot serve: first its disk file is deleted
/// underneath it, then the row's path is nulled the way "clear cached bytes" leaves
/// it. Both must come back as `gone`, and neither may complete.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn dm_file_request_gets_honest_gone_answer_when_holder_lost_bytes() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 203;
    const B_MASTER: u8 = 204;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    // Residual, and it earns its place: a file send PRE-NEGOTIATES the
    // recipient's auto-download preference and that advert has no live probe.
    // See dm_file_transfer_completes_and_decrypts for the full note.
    sleep_ms(1000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // Auto-download OFF for this DM: B keeps the card's metadata row and no
    // bytes, which is the only way a manual Download can be under test.
    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    // -- Shape 1: the bytes vanish from disk, the row still names the path --
    let one = global_tmp.path().join("lost_one.bin");
    std::fs::write(&one, b"the holder will lose these bytes").expect("write src one");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: one.to_str().unwrap().to_string(),
            message_id: "lost-one".to_string(),
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
    let mut fid_one = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("lost_one")
        {
            fid_one = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card for file one");
    let fid_one = fid_one.expect("file one id");

    // The sender's own copy disappears (a storage-cap eviction between two
    // `reset_stale_file_paths` passes leaves exactly this: a row that still
    // names a path and no file behind it).
    let a_disk = a
        .file_meta(&fid_one)
        .and_then(|m| m.disk_path)
        .expect("A holds file one on disk");
    std::fs::remove_file(&a_disk).expect("delete A's copy of file one");
    assert!(
        b.file_meta(&fid_one).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "B must not hold file one's bytes"
    );
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid_one.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let mut completed_one = false;
    let honest_one = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        if matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid_one) {
            completed_one = true;
        }
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, peer_id }
                if *file_id == fid_one && state == "gone" && *peer_id == a_master
        )
    })
    .await;
    assert!(
        honest_one,
        "a holder whose disk file vanished must answer gone, naming the holder"
    );
    assert!(!completed_one, "nothing may complete when the bytes are gone");

    // -- Shape 2: the row's path is NULL (downloads cleared) --
    let two = global_tmp.path().join("lost_two.bin");
    std::fs::write(&two, b"and these too").expect("write src two");
    drain_events(&mut b);
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: two.to_str().unwrap().to_string(),
            message_id: "lost-two".to_string(),
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
    let mut fid_two = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("lost_two")
        {
            fid_two = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card for file two");
    let fid_two = fid_two.expect("file two id");

    a.store().null_disk_path_all().expect("clear A's cached bytes");
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid_two.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let mut completed_two = false;
    let honest_two = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        if matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid_two) {
            completed_two = true;
        }
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, peer_id }
                if *file_id == fid_two && state == "gone" && *peer_id == a_master
        )
    })
    .await;
    assert!(
        honest_two,
        "a holder whose row lost its path must answer gone, not stay silent"
    );
    assert!(!completed_two, "nothing may complete when the path is gone");

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
    drop(a);
    drop(b);
}

/// State 2: the only holder is offline when the user taps Download, so the card
/// says so and the request is QUEUED. The asker's socket then dies and returns, the
/// holder comes back, and the queued ask fires with no further command. It can only
/// complete if the retry re-stamped the explicit-pull receipt.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn dm_file_request_waits_for_offline_holder_then_fetches_on_return() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 205;
    const B_MASTER: u8 = 206;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    sleep_ms(1000).await; // auto-download advert settle; see the note above
    drain_events(&mut a);
    drain_events(&mut b);

    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    let src = global_tmp.path().join("waiting.bin");
    let contents: &[u8] = b"these bytes arrive when the holder comes back";
    std::fs::write(&src, contents).expect("write src file");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "waiting-file".to_string(),
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
    let mut got_fid = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("waiting")
        {
            got_fid = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card");
    let fid = got_fid.expect("file id from header");
    assert!(
        b.file_meta(&fid).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "B must hold the row and none of the bytes"
    );

    // The holder leaves. Wait on B's OWN view of the roster, not the relay's:
    // an ask dispatched against a stale room table would go to a dead socket.
    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    let a_device = a.device_id.clone();
    go_offline(&relay, &a, &dm_room).await;
    let b_saw_it = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == a_device)
    })
    .await;
    assert!(b_saw_it, "B's own presence view must lose A before the ask");
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let waiting = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, peer_id }
                if *file_id == fid && state == "waiting" && *peer_id == a_master
        )
    })
    .await;
    assert!(waiting, "an unreachable holder must produce the waiting state");

    // B's socket dies and comes back. This is what makes the retry's receipt
    // re-stamp load-bearing: `requested_file_receipts` is cleared on
    // Disconnected, so the queued ask has to arm the gate again by itself.
    relay.set_online(&b.device_id, false);
    assert!(
        wait_until(10, async || !relay.online_devices().contains(&b.device_id)).await,
        "B must be off the relay"
    );
    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(15, async || relay.room_devices(&dm_room).contains(&a_device)).await,
        "A must be back in the DM room"
    );
    relay.set_online(&b.device_id, true);

    // No further command: the queued ask fires on the fresh roster alone.
    let done = wait_event(&mut b, std::time::Duration::from_secs(30), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "the queued ask must fetch the file when the holder returns");
    let meta = b.file_meta(&fid).expect("B persisted the files row");
    let disk = meta.disk_path.expect("completed file has a disk path");
    assert_eq!(
        std::fs::read(&disk).expect("read the received file"),
        contents,
        "the queued fetch must decrypt to the original contents"
    );

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
    drop(a);
    drop(b);
}

/// The asked-set rule: a device we never asked cannot steer our walk or delete our
/// ask by volunteering a miss. C really can route the frame and was never asked, so
/// nothing may move and the ask must still find its own holder.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn file_unavailable_from_unasked_device_changes_nothing() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 207;
    const B_MASTER: u8 = 208;
    const C_MASTER: u8 = 209;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master, &c_master]).await;
    let c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&b_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    expect_dm_pair_ready(&relay, &c, &b, 15).await;
    sleep_ms(1000).await; // auto-download advert settle; see the note above
    drain_events(&mut a);
    drain_events(&mut b);

    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    let src = global_tmp.path().join("unasked.bin");
    let contents: &[u8] = b"only A ever holds these bytes";
    std::fs::write(&src, contents).expect("write src file");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "unasked-file".to_string(),
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
    let mut got_fid = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("unasked")
        {
            got_fid = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card");
    let fid = got_fid.expect("file id from header");

    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    let a_device = a.device_id.clone();
    go_offline(&relay, &a, &dm_room).await;
    let b_saw_it = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == a_device)
    })
    .await;
    assert!(b_saw_it, "B's own presence view must lose A before the ask");
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let waiting = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid && state == "waiting"
        )
    })
    .await;
    assert!(waiting, "the ask must be queued against the offline holder");
    drain_events(&mut b);

    let bc_room = super::types::dm_room_code(&b_master, &c_master);
    relay.inject_direct(
        &bc_room,
        &c.device_id,
        &b.device_id,
        serde_json::to_vec(&super::types::HavenMessage::FileUnavailable {
            file_id: fid.clone(),
            reason: "gone".to_string(),
        })
        .expect("serialize FileUnavailable"),
    );
    let moved = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid && (state == "gone" || state == "expired")
        )
    })
    .await;
    assert!(!moved, "an unasked device's miss must not move the card off waiting");

    // The ask still belongs to A, and it completes when A comes back.
    relay.set_online(&a.device_id, true);
    let done = wait_event(&mut b, std::time::Duration::from_secs(30), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(done, "the surviving ask must still find its own holder");
    let meta = b.file_meta(&fid).expect("B persisted the files row");
    let disk = meta.disk_path.expect("completed file has a disk path");
    assert_eq!(
        std::fs::read(&disk).expect("read the received file"),
        contents,
        "the surviving ask must land the holder's bytes byte-exact"
    );

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
    drop(a);
    drop(b);
    drop(c);
}

/// The negative answer is gated exactly like the positive one: a stranger that
/// learned a file_id gets SILENCE, because answering would tell it "this device
/// holds a row for X". The entitled DM party gets the answer for the same file in
/// the same run, so silence cannot be an accident of routing.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn file_unavailable_never_answers_a_non_entitled_requester() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 215;
    const B_MASTER: u8 = 216;
    const D_MASTER: u8 = 217;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let d_master = NativeKeypair::from_secret_bytes(&seed_bytes(D_MASTER)).peer_id();

    // D is a friend of A (so a frame from D routes to A and A COULD answer it)
    // but has nothing to do with the A/B conversation the file lives in.
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master, &d_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    let d = spawn_node_with_friends(&relay, D_MASTER, D_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    expect_dm_pair_ready(&relay, &a, &d, 15).await;
    sleep_ms(1000).await; // auto-download advert settle; see the note above
    drain_events(&mut a);
    drain_events(&mut b);

    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    let src = global_tmp.path().join("gatecheck.bin");
    std::fs::write(&src, b"a private DM attachment").expect("write src file");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: src.to_str().unwrap().to_string(),
            message_id: "gatecheck-file".to_string(),
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
    let mut got_fid = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("gatecheck")
        {
            got_fid = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card");
    let fid = got_fid.expect("file id from header");

    a.store().null_disk_path_all().expect("clear A's cached bytes");
    relay.set_recording(&a.device_id, true);

    let ad_room = super::types::dm_room_code(&a_master, &d_master);
    relay.inject_direct(
        &ad_room,
        &d.device_id,
        &a.device_id,
        serde_json::to_vec(&super::types::HavenMessage::FileRequest {
            file_id: fid.clone(),
            chunks: Vec::new(),
            offset: 0,
        })
        .expect("serialize FileRequest"),
    );
    // An absence proof, polled: it fails the moment A answers the stranger.
    let leaked = wait_until(2, async || {
        frames_of_type(&relay, &a.device_id, "file_unavail")
            .iter()
            .any(|v| v.get("file_id").and_then(|f| f.as_str()) == Some(fid.as_str()))
    })
    .await;
    assert!(
        !leaked,
        "a non-entitled requester must get silence, never a file_unavail answer"
    );

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let answered = wait_until(10, async || {
        frames_of_type(&relay, &a.device_id, "file_unavail")
            .iter()
            .any(|v| v.get("file_id").and_then(|f| f.as_str()) == Some(fid.as_str()))
    })
    .await;
    assert!(answered, "the entitled DM party must get the negative answer");

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
    drop(a);
    drop(b);
    drop(d);
}

/// A channel file has more than one holder. The asker targets the SENDER, which no
/// longer has the bytes, and the ask must ROTATE to the next holder on the negative
/// rather than dying there; the card narrates the walk.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn channel_file_request_rotates_to_next_holder_after_gone() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 218; // sender / owner
    const C_MASTER: u8 = 219; // the other holder (online at send time)
    const B_MASTER: u8 = 249; // the asker (offline at send time)
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&c_master, &b_master]).await;
    sleep_ms(1200).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&a_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;

    let server_id = create_server_and_wait(&mut a, "Rotation Files").await;
    let general = general_channel_of(&server_id);

    for (label, node) in [("C", &mut c), ("B", &mut b)] {
        node.cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{label} should join the server");
    }
    // 3 members < 6 = full replication, and the group forming is the settle.
    expect_mls_group(&[&a, &c, &b], &server_id, 25).await;
    drain_events(&mut a);
    drain_events(&mut c);
    drain_events(&mut b);

    // The asker is offline while the file is posted, so it learns the row from
    // the relay's catch-up and never sees the bytes.
    relay.set_online(&b.device_id, false);
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let contents: &[u8] = b"rotate to the second holder";
    let src = global_tmp.path().join("rotate.bin");
    std::fs::write(&src, contents).expect("write src file");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "rotate-file-1".to_string(),
            message_text: "rotate-caption".to_string(),
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
    wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("rotate")
        {
            got_fid = Some(file_id.clone());
        }
        got_fid.is_some()
    })
    .await;
    let fid = got_fid.expect("C must receive the channel FileHeader");
    let c_done = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(c_done, "the online member must receive the full bytes");

    // The SENDER loses its copy (its own storage cap evicted it); C's copy and
    // C's row are untouched.
    a.store().null_disk_path_all().expect("clear A's cached bytes");
    relay.set_recording(&a.device_id, true);

    relay.set_online(&b.device_id, true);
    let b_header = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
        matches!(ev, NetworkEvent::FileHeaderReceived { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(b_header, "the asker must learn the file via relay catch-up");
    sleep_ms(500).await;
    assert!(
        b.file_meta(&fid).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "the asker must not hold the bytes yet"
    );
    drain_events(&mut b);

    // The UI targets the SENDER, the only holder it knows about.
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();

    let mut seq: Vec<(String, String)> = Vec::new();
    let done = wait_event(&mut b, std::time::Duration::from_secs(30), |ev| match ev {
        NetworkEvent::FileAvailability { file_id, state, peer_id } if *file_id == fid => {
            seq.push((state.clone(), peer_id.clone()));
            false
        }
        NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid => true,
        _ => false,
    })
    .await;
    assert!(done, "the rotated ask must complete, got states {seq:?}");
    assert_eq!(
        seq.first().map(|(s, p)| (s.as_str(), p.as_str())),
        Some(("requesting", a_master.as_str())),
        "the walk starts at the sender, got {seq:?}"
    );
    assert!(
        seq.iter().any(|(s, p)| s == "requesting" && *p == c_master),
        "the negative must rotate the walk to the second holder, got {seq:?}"
    );
    assert!(
        !seq.iter().any(|(s, _)| s == "gone" || s == "expired"),
        "a rotation that succeeds must never show a dead-end state, got {seq:?}"
    );

    let said_gone = frames_of_type(&relay, &a.device_id, "file_unavail").iter().any(|v| {
        v.get("file_id").and_then(|f| f.as_str()) == Some(fid.as_str())
            && v.get("reason").and_then(|r| r.as_str()) == Some("gone")
    });
    assert!(said_gone, "the sender must have answered gone, not stayed silent");

    let meta = b.file_meta(&fid).expect("the asker persisted the files row");
    let disk = meta.disk_path.expect("completed file has a disk path");
    assert_eq!(
        std::fs::read(&disk).expect("read the received file"),
        contents,
        "the rotated fetch must decrypt to the original contents"
    );

    // A completed file is finished: no dead-end state trails it. An ABSENCE, so
    // it costs a real window; the sweep ticks every second under cfg(test), so
    // this covers a full pass.
    let trailing = wait_event(&mut b, std::time::Duration::from_millis(1500), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid && (state == "gone" || state == "expired" || state == "waiting")
        )
    })
    .await;
    assert!(!trailing, "a completed file must not fall back into a pending state");

    drop(a);
    drop(b);
    drop(c);
}

/// State 4 is the ONE remote answer that can write to our own row, so it is
/// verified locally: a member cannot expire someone else's file by lying. A fresh
/// row downgrades the `expired` answer to `gone`; a row genuinely past the server's
/// retention is marked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn expired_answer_is_verified_locally_before_marking_our_row() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 98; // owner / sender / the asked holder
    const B_MASTER: u8 = 99; // the asker
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;

    let server_id = create_server_and_wait(&mut a, "Retention Server").await;
    let general = general_channel_of(&server_id);
    a.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "retention_files".to_string(),
            value: "30d".to_string(),
        })
        .await
        .unwrap();
    sleep_ms(500).await;

    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let joined = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(joined, "the asker should join the server");
    let policy_synced = wait_until(15, async || {
        b.server_state(&server_id)
            .and_then(|s| s.settings.get("retention_files").map(|r| r.read().clone()))
            .as_deref()
            == Some("30d")
    })
    .await;
    assert!(policy_synced, "the asker must know the server's retention policy");
    expect_mls_group(&[&a, &b], &server_id, 25).await;
    drain_events(&mut a);
    drain_events(&mut b);

    // The asker is offline for the send, so it holds the row and no bytes.
    relay.set_online(&b.device_id, false);
    sleep_ms(2000).await;
    drain_events(&mut a);
    drain_events(&mut b);

    let src = global_tmp.path().join("retained.bin");
    std::fs::write(&src, b"a file with a retention policy").expect("write src file");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "retained-file-1".to_string(),
            message_text: "retention-caption".to_string(),
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
    wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
        if let NetworkEvent::FileCompleted { file_id, .. } = ev {
            got_fid = Some(file_id.clone());
        }
        got_fid.is_some()
    })
    .await;
    let fid = got_fid.expect("the sender's own FileCompleted carries the file id");

    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    {
        let vault_dir = global_tmp.path().join("vault_a");
        let cs = crate::vault::content_store::ContentStore::open(
            &a.db_path, &a.passphrase, &vault_dir,
        )
        .expect("open the holder's content store");
        assert!(
            cs.mark_file_expired(&fid, now_secs).expect("mark the holder's row expired"),
            "the holder's row must actually flip to expired"
        );
    }

    relay.set_online(&b.device_id, true);
    let b_header = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
        matches!(ev, NetworkEvent::FileHeaderReceived { file_id, .. } if *file_id == fid)
    })
    .await;
    assert!(b_header, "the asker must learn the file via relay catch-up");
    sleep_ms(500).await;
    drain_events(&mut b);

    // -- Case A: our row is FRESH, so `expired` is not ours to believe --
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let downgraded = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid && (state == "gone" || state == "expired")
        )
    })
    .await;
    assert!(downgraded, "the asker must reach a dead-end state");
    let case_a = b.file_meta(&fid).expect("the asker holds the row");
    assert!(
        case_a.expired_at.is_none(),
        "a fresh row must NOT be marked expired on a peer's say-so"
    );

    // -- Case B: our row really is past the server's own retention window --
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    {
        let conn = rusqlite::Connection::open(&b.db_path).expect("open the asker's DB");
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", b.passphrase))
            .expect("key the asker's DB");
        conn.execute_batch("PRAGMA busy_timeout = 8000;").expect("busy timeout");
        conn.execute(
            "UPDATE files SET created_at = ?1 WHERE file_id = ?2",
            rusqlite::params![now_ms - 40 * 86_400_000i64, &fid],
        )
        .expect("age the asker's row past the retention window");
    }
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let expired = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid && state == "expired"
        )
    })
    .await;
    assert!(expired, "a row past its server's retention window must read as expired");
    let case_b = wait_until(5, async || {
        b.file_meta(&fid).map(|m| m.expired_at.is_some()).unwrap_or(false)
    })
    .await;
    assert!(case_b, "the verified expiry must be written to our own row");

    drop(a);
    drop(b);
}

/// "Stop waiting for this file" has to stop BOTH halves of the pull, and the second
/// is easy to forget: the queued ask is gone, so the holder's return no longer
/// fires it, and the explicit-pull RECEIPT goes with it, so an answer already in
/// flight is judged exactly as an unsolicited push would be. With the receipt still
/// standing the very same header completes, which is the proof it went.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn cancel_file_request_drops_the_queued_ask_and_its_receipt() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 166;
    const B_MASTER: u8 = 167;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    sleep_ms(1200).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    sleep_ms(1000).await; // auto-download advert settle; see the note above
    drain_events(&mut a);
    drain_events(&mut b);

    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    // -- (a) a cancelled queue does not fire when the holder returns --
    let one = global_tmp.path().join("cancel_one.bin");
    std::fs::write(&one, b"nobody is waiting for these any more").expect("write src one");
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: one.to_str().unwrap().to_string(),
            message_id: "cancel-one".to_string(),
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
    let mut fid_one = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("cancel_one")
        {
            fid_one = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card for file one");
    let fid_one = fid_one.expect("file one id");

    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    let a_device = a.device_id.clone();
    go_offline(&relay, &a, &dm_room).await;
    let b_saw_it = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == a_device)
    })
    .await;
    assert!(b_saw_it, "B's own presence view must lose A before the ask");
    drain_events(&mut b);

    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid_one.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    let waiting = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(
            ev,
            NetworkEvent::FileAvailability { file_id, state, .. }
                if *file_id == fid_one && state == "waiting"
        )
    })
    .await;
    assert!(waiting, "the ask must be queued before it can be cancelled");

    b.cmd_tx
        .send(NodeCommand::CancelFileRequest { file_id: fid_one.clone() })
        .await
        .unwrap();
    drain_events(&mut b);

    // The holder returns, which is exactly what would have fired the queue.
    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(15, async || relay.room_devices(&dm_room).contains(&a_device)).await,
        "A must be back in the DM room for the absence to mean anything"
    );
    let fired = wait_event(&mut b, std::time::Duration::from_secs(6), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid_one)
            || matches!(
                ev,
                NetworkEvent::FileAvailability { file_id, .. } if *file_id == fid_one
            )
    })
    .await;
    assert!(!fired, "a cancelled ask must not fire when the holder comes back");
    assert!(
        b.file_meta(&fid_one).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "no bytes may land for a cancelled ask"
    );

    // -- (b) the receipt went with the ask --
    let two = global_tmp.path().join("cancel_two.bin");
    std::fs::write(&two, b"this answer arrives after the cancel").expect("write src two");
    drain_events(&mut b);
    a.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: Some(b.master_id.clone()),
            server_id: None,
            channel_id: None,
            file_path: two.to_str().unwrap().to_string(),
            message_id: "cancel-two".to_string(),
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
    let mut fid_two = None;
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev
            && file_name.starts_with("cancel_two")
        {
            fid_two = Some(file_id.clone());
            return true;
        }
        false
    })
    .await;
    assert!(got, "B must get the gated card for file two");
    let fid_two = fid_two.expect("file two id");
    // By now B's gating preference has been advertised, so A pre-negotiated and
    // sent a METADATA-ONLY header: no AES material, so the receive gate had
    // nothing to refuse and said nothing. Any refusal from here on can only be
    // the answer to the request below.
    assert!(
        b.file_meta(&fid_two).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "the pre-negotiated push must leave the row without bytes"
    );
    drain_events(&mut b);

    // Both commands are queued on B's own channel before A can even receive the
    // request, so the cancel is processed first and the answering header lands
    // on a node that has already stopped waiting.
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid_two.clone(),
            peer_id: a_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();
    b.cmd_tx
        .send(NodeCommand::CancelFileRequest { file_id: fid_two.clone() })
        .await
        .unwrap();

    let mut completed = false;
    let refused = wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
        if matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if *file_id == fid_two) {
            completed = true;
        }
        matches!(
            ev,
            NetworkEvent::FileFailed { file_id, error }
                if *file_id == fid_two && error == "auto_download_off"
        )
    })
    .await;
    assert!(
        refused,
        "with the receipt cancelled the answering header must face the gate like any push"
    );
    assert!(!completed, "a cancelled pull must not complete");
    assert!(
        b.file_meta(&fid_two).map(|m| m.completed_at.is_none()).unwrap_or(true),
        "no bytes may land for a cancelled pull"
    );

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
    drop(a);
    drop(b);
}

/// FILE-2 regression: the voice exemption is not a free pass for bytes. It used to
/// read `voice || name`, both SENDER-filled, with no size bound and no look at the
/// extension, so a header flagged `voice: true` carried anything into a
/// conversation with auto-download OFF. Two headers that CLAIM to be voice notes
/// are pushed here, one over the note ceiling and one wearing the recorder's name
/// with the flag off, and neither may complete or reach disk.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn forged_voice_flag_does_not_bypass_auto_download_gate() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 244;
    const B_MASTER: u8 = 245;
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

    // Gate the conversation AFTER the advert exchange, so A still PUSHES and
    // it is B's own receive gate under test (the same shape
    // `dm_auto_download_off_declines_push_then_manual_request_completes` uses).
    super::file_handler::set_auto_download_conf(
        169,
        std::collections::HashMap::from([(format!("dm:{a_master}"), false)]),
    );

    // (b) A real .ogg with a real voice flag, one KB over the note ceiling.
    let oversize = global_tmp.path().join("voice_1730000000001_54321.ogg");
    std::fs::write(
        &oversize,
        vec![0x5Au8; (super::file_handler::VOICE_NOTE_MAX_BYTES + 1024) as usize],
    )
    .expect("write oversize voice src");

    // (c) The recorder's display name on a file the sender never flagged.
    let unflagged = global_tmp.path().join("Voice message.ogg");
    std::fs::write(&unflagged, b"not a recording, just named like one")
        .expect("write unflagged src");

    for (idx, (path, voice)) in [(&oversize, true), (&unflagged, false)]
        .into_iter()
        .enumerate()
    {
        a.cmd_tx
            .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
                peer_id: Some(b.master_id.clone()),
                server_id: None,
                channel_id: None,
                file_path: path.to_str().unwrap().to_string(),
                message_id: format!("forged-voice-msg-{idx}"),
                message_text: String::new(),
                vthumb: None,
                override_width: None,
                override_height: None,
                share_ref: None,
                voice,
                poster: None,
            })))
            .await
            .unwrap();
    }

    // Both cards land — the gate keeps the metadata row, it only refuses bytes.
    let mut fids: Vec<String> = Vec::new();
    for _ in 0..2 {
        let mut got = None;
        let header = wait_event(&mut b, std::time::Duration::from_secs(15), |ev| {
            if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
                if file_name.ends_with(".ogg") && !fids.contains(file_id) {
                    got = Some(file_id.clone());
                    return true;
                }
            }
            false
        })
        .await;
        assert!(header, "each claimed voice note still delivers its card");
        fids.push(got.expect("file id from header"));
    }

    let completed = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::FileCompleted { file_id, .. } if fids.contains(file_id))
    })
    .await;
    assert!(
        !completed,
        "a forged voice flag must not complete a push in a gated conversation",
    );

    sleep_ms(300).await;
    for fid in &fids {
        let meta = b.file_meta(fid).expect("metadata row persisted despite the gate");
        assert!(
            meta.completed_at.is_none(),
            "claimed voice note {fid} must stay incomplete",
        );
        assert!(
            meta.disk_path.is_none(),
            "claimed voice note {fid} must not reach disk",
        );
    }

    super::file_handler::set_auto_download_conf(169, std::collections::HashMap::new());
}

/// Video poster pipeline: a DM video send with Dart-supplied poster bytes delivers
/// a FileHeader whose `thumb_b64` carries the re-encoded poster and whose
/// width/height fall back to the poster's own dimensions when the probe supplied
/// none, so the bubble renders at the right aspect before any video byte is local.
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
    assert_eq!((w, h), (Some(64), Some(36)), "header w/h fall back to poster dims");
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

// Voice-channel join/leave, participant tracking and signal routing. Real audio is
// out of scope; the control path rides a plaintext fallback needing only server
// membership and a Voice channel. Also guards the VC signal whitelist: an unknown
// type is silently dropped.

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
        matches!(ev, NetworkEvent::VoiceChannelSignal { signal_type, .. } if signal_type == "made-up-vc-signal")
    })
    .await;
    assert!(!leaked, "an unknown VC signal type must be silently dropped");

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

// The VC self-ghost regression. The participant set is keyed by ROUTABLE DEVICE
// ids including OUR OWN entry, but the own-join path emitted the MASTER id while
// Dart's self-skip compared the DEVICE id, so both ends dialed their own master as
// a remote participant. These nodes have device != master, which the other VC
// tests cannot catch.

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

// Originator attribution on the VC screen lane: vc_screen_* carry an optional
// StreamOrigin, who the stream is FROM versus who delivered it. An absent origin is
// old wire and passes through untouched; a spoofed one is DROPPED, because the
// SFrame key is shared and spoofed attribution renders pixels under a victim's name.

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

// A voice peer that reconnects must be able to RECEIVE again, not just send.
// `WsEvent::Disconnected` purges every remote peer from
// `voice_channel_participants`, which gates every inbound VC signal, and nothing
// refilled it: the peer never left its own channel, and the one re-announce sat
// behind the `is_new` guard, which is false for exactly the peer that came back.
// The socket is dropped SILENTLY here because that is what left `is_new` false.

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

// The voice mesh's `leg_restart` request. The mesh gives the SDP offer to the
// lexicographically lower peer id, so the higher side had no way to rebuild a leg
// only it could see was broken. A VC signal type is whitelisted across three
// touches and missing one drops it SILENTLY, so this drives both directions.

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

// Recovery-pool formation: an initiator opens a pool, a second node joins and
// broadcasts a RecoveryHello, and the initiator registers it as a member. Shard
// streaming needs a populated vault and is out of harness scope.

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

    j.cmd_tx
        .send(NodeCommand::JoinRecoveryPool { server_id: server_id.clone(), token: token.clone() })
        .await
        .unwrap();
    let joined = wait_event(&mut j, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::RecoveryPoolJoined { server_id: sid } if *sid == server_id)
    })
    .await;
    assert!(joined, "joiner should emit RecoveryPoolJoined");

    let o_saw_member = wait_event(&mut o, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::RecoveryPoolMemberJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(o_saw_member, "initiator must register the joiner as a recovery-pool member");
}

// Sibling-to-sibling SERVER-message backfill, the server analog of the DM
// peer-fallback: C recovers its own identity's channel messages, sent from a now
// offline sibling B, from A, the only present member. No new code is needed for
// that, which is what this confirms.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sibling_recovers_own_channel_messages_from_present_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    let a_leaves = a.mls_members(&server_id).await;
    assert!(
        a_leaves.contains(&b.device_id),
        "A's MLS group must contain B's device leaf, got {a_leaves:?}"
    );

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

    let recovered = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::MessageSyncCompleted { server_id: sid, new_message_count }
            if *sid == server_id && *new_message_count > 0)
            || matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "from-B-3")
    })
    .await;
    assert!(recovered, "C should receive a channel-sync carrying B's messages from A on join");
    sleep_ms(700).await; // let any remaining inserts commit

    let on_c = c.channel_messages(&server_id, &general);
    for t in ["from-B-1", "from-B-2", "from-B-3"] {
        let row = on_c.iter().find(|m| m.text == t).unwrap_or_else(|| {
            panic!(
                "C must recover its own identity's channel message {t:?} from A on join \
                 (sibling server backfill). Got: {:?}",
                on_c.iter().map(|m| &m.text).collect::<Vec<_>>()
            )
        });
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

// Multi-device self-heal of a PRE-FIX channel row. A row stored before the
// device-to-master resolve fix is keyed under a DEVICE id with signature material
// that no longer verifies, and INSERT OR IGNORE means a later sync carrying the
// correct copy cannot overwrite it. The heal: when a synced item's signature
// VERIFIES and our row names a different sender, repair the row.

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

// Server MODERATION actions reach the actor's OWN sibling devices. Kick, ban, role
// change and leave used to broadcast their CRDT op only to the REMAINING members,
// so a sibling of the actor converged only on restart. Each handler now also fans
// the op, and the MLS leaf-removal commit, to our own online siblings.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn moderation_action_converges_on_actor_sibling_without_restart() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    {
        let panel = c.member_panel(&server_id, &relay);
        let v_row = panel.iter().find(|r| r.master == v_master)
            .unwrap_or_else(|| panic!("C should see V as a member pre-action, got {:?}",
                panel.iter().map(|r| &r.master).collect::<Vec<_>>()));
        assert_eq!(v_row.role, crate::crdt::operations::MemberRole::Member,
            "V starts as a plain Member on C");
    }

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

    b.cmd_tx
        .send(NodeCommand::KickMember {
            server_id: server_id.clone(),
            peer_id: v_master.clone(),
        })
        .await
        .unwrap();
    let b_kicked = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::MemberLeft { peer_id, .. } if *peer_id == v_master)
    })
    .await;
    assert!(b_kicked, "actor B should emit MemberLeft for the kicked victim");
    sleep_ms(1500).await; // removal op fans to C (the fix) — no restart

    {
        let panel = c.member_panel(&server_id, &relay);
        assert!(
            !panel.iter().any(|r| r.master == v_master),
            "sibling C must drop the kicked V from its member panel WITHOUT restart (C2 fix), got {:?}",
            panel.iter().map(|r| &r.master).collect::<Vec<_>>()
        );
        assert!(
            panel.iter().any(|r| r.master == m_master),
            "C still shows the owner identity M after the kick"
        );
    }
}

// "Latest authorized write wins": an Admin holding MANAGE_SERVER flips a setting
// the OWNER wrote earlier. Under the old priority-first merge the admin's op
// silently lost on every replica. Pure HLC LWW plus the permission-gated ingest
// must land it on the owner, on the admin, and on a member that was offline.

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

// A freshly LINKED sibling's device list shows BOTH devices immediately. The
// imported backup carries the SOURCE device's signed list, which does not name the
// new sibling, so a startup seed from that list alone resolved the running device
// to ITSELF. The fix seeds `list.devices` plus this device; the panel render is a
// visual check, the resolver links are the half asserted here.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn linked_sibling_resolves_both_devices_at_startup() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// A plaintext-only lifecycle op fans to the actor's OWN sibling DIRECTLY when no
// other member is online to re-gossip it. M's two devices are ALONE in a server,
// so only `fan_to_own_siblings` can carry a nickname change from B to C.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn sibling_nickname_fans_directly_with_no_relayer() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// A member offline when the owner deleted a server learns it is gone on RECONNECT,
// via the grow-only sync path carrying the ServerDeleted tombstone. Deletion used
// to be a missable one-shot; the MockRelay does not queue that one-shot, so this
// proves the tombstone path specifically.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn offline_member_reconciles_server_deletion_on_reconnect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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
    assert!(!o.servers().contains(&server_id), "O's UI drops the deleted server");

    drain_events(&mut m);
    relay.set_online(&m.device_id, true);
    let m_saw_delete = wait_event(&mut m, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerDeleted { server_id: sid } if *sid == server_id)
            || matches!(ev, NetworkEvent::MemberLeft { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(m_saw_delete, "M must learn the server was deleted on reconnect (tombstone sync)");
    sleep_ms(500).await;

    assert!(
        !m.servers().contains(&server_id),
        "offline member M must reconcile the deletion on reconnect (server gone), got {:?}",
        m.servers()
    );
}

// When one of M's devices creates a server, M's other online device must
// auto-onboard: see the server AND get its own MLS leaf, so it can decrypt channel
// messages.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn server_create_auto_onboards_online_sibling() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    let server_id = create_server_and_wait(&mut b, "Shared Server").await;
    let general = general_channel_of(&server_id);

    let c_onboarded = wait_event(&mut c, std::time::Duration::from_secs(10), |ev| {
        matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
    })
    .await;
    assert!(c_onboarded, "sibling C must auto-onboard the newly-created server (ServerJoined)");
    expect_mls_leaf(&b, &server_id, &c.device_id, 15).await;

    assert!(
        c.servers().contains(&server_id),
        "sibling C's server list must include the auto-onboarded server, got {:?}",
        c.servers()
    );

    let b_leaves = b.mls_members(&server_id).await;
    assert!(
        b_leaves.contains(&c.device_id),
        "creator B's MLS group must contain sibling C's leaf, got {b_leaves:?}"
    );

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

// Server create and join re-announce to OFFLINE siblings on reconnect. The live
// announce only reaches siblings online at the time, so a sibling that was away
// never learned the server existed. C comes back, auto-onboards, gets its MLS leaf
// and decrypts a channel message without ever calling JoinServer.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn server_create_reannounces_to_offline_sibling_on_reconnect() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    assert!(
        !c.servers().contains(&server_id),
        "offline sibling C must NOT have the server yet (live announce can't reach it)"
    );

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

    let b_leaves = b.mls_members(&server_id).await;
    assert!(
        b_leaves.contains(&c.device_id),
        "creator B's MLS group must contain reconnected sibling C's leaf, got {b_leaves:?}"
    );

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

// MANUAL state sync ("Sync from this device"), the deterministic escape hatch: the
// DESTINATION asks a chosen SOURCE sibling to push its servers and friends, the
// source announces every server it holds, and the destination runs its join flow.
// The on-demand equivalent of the reconnect re-announce.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn manual_state_sync_pulls_servers_from_source_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    c.cmd_tx
        .send(NodeCommand::RequestStateSync { source_device_id: b.device_id.clone() })
        .await
        .unwrap();

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

// Per-channel MLS subgroups: a restricted channel encrypts under its OWN subgroup,
// so a plain Member is not a leaf and cannot decrypt it. Channel visibility is
// cryptographically enforced, not UI-filtered: promotion adds the member to the
// subgroup, demotion removes it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn restricted_channel_subgroup_enforces_visibility() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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
    assert!(
        !a.mls_members(&subgroup).await.contains(&a.device_id),
        "A must not hold the restricted subgroup before promotion"
    );

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
    assert!(
        !owner_sub_leaves2.contains(&m.device_id),
        "M (still Member) must remain excluded from the subgroup, got {owner_sub_leaves2:?}"
    );

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

// Label-gated channel access (issue #32): a channel gated on an ACCESS label is
// encrypted under its own subgroup, and only label holders plus Admin+ are leaves.
// The gate op is paired with a legacy `visibility: admin` stamp so old clients fail
// closed, and both must replicate.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn label_gated_channel_subgroup_and_fallback() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Access labels are NOT self-assignable, since the label gates channels: the
// authoring gate refuses locally and `op_allowed` refuses remotely, while cosmetic
// labels keep self-service.
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

// Temporary channel access grants, MLS lifecycle: a grant admits a plain Member to
// a restricted channel's subgroup, and revoking evicts the leaf.
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

// Temporary grant EXPIRY: the predicate denies lazily the instant the clock passes
// `expires_at` (no revoke op), and the sweep then removes the MLS leaf.
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

// Per-channel subgroups, VOICE. A restricted voice channel derives its SFrame media
// key from the channel's own subgroup, so only members whose role satisfies the
// visibility tier are leaves and can `export_secret` the key. A non-qualifying
// Member is excluded and its VC join is rejected outright; promotion adds it,
// demotion removes it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn restricted_voice_channel_subgroup_enforces_sframe_membership() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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
    // Wait until ALL THREE distinct identities are leaves of the server-wide group,
    // the precondition for an MLS-broadcast ChannelAdded op to reach them. The budget
    // is 60s because a coverage-instrumented runner takes about twice as long; the
    // loop exits as soon as the leaves converge.
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

// Real-time channel visibility and posting propagation to a REMOTE member. The UI
// recomputes its providers from the local DB, so this proves the DATA LAYER those
// providers read reflects a live change on the receiving member, and that an
// offline member catches up on reconnect.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_visibility_posting_propagate_to_remote_member_realtime() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    assert_eq!(v.channel_visibility(&server_id, &cid).as_deref(), Some("everyone"),
        "V's DB shows the new channel as everyone-visible");
    assert!(v.can_see_channel(&server_id, &cid, &v_master),
        "V (Member) can see an everyone channel");
    assert_eq!(v.channel_posting(&server_id, &cid).as_deref(), Some("everyone"),
        "V's DB shows everyone-posting baseline");

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

// MODERATION TRIO: mute (timed and permanent), per-channel slow mode and media-only
// channels. Covers CRDT convergence to a remote member, send-side rejection, unmute
// and expiry restoring posting, and the Moderator+ slow-mode exemption.

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

// ANTI-MIS-LINK: a friend request between two DISTINCT identities must NEVER fuse
// them. Sending one makes the requester join the TARGET's inbox room, which used to
// trip the inbox-proof and merge the stranger as a sibling device (resolver poison,
// device-list merge, friend-list leak). The stranger holds only ITS OWN master key
// and cannot answer the target's nonce challenge.

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
    let a_devices = super::resolver::devices_for(&a_master);
    assert!(
        !a_devices.contains(&b_dev),
        "A's device set must NOT contain B's device, got {a_devices:?}"
    );

    // B's incoming-friend row is genuinely pending and keyed by A's MASTER, since save
    // sites resolve device to master. If B has not learned the mapping yet it keys under
    // the device id: either is fine, but it must not collapse into B's own identity.
    let b_friends = b.store().load_friends(None).unwrap_or_default();
    assert!(
        b_friends.iter().any(|(pid, status, dir, _, _)| {
            (*pid == a_master || *pid == a_dev) && status == "pending" && dir == "incoming"
        }),
        "B must hold a pending INCOMING friend row for A (master or device), got {b_friends:?}"
    );
    assert!(
        b_friends.iter().all(|(pid, _, _, _, _)| !super::resolver::same_identity(pid, &b_master)),
        "no friend row may be keyed under B's own identity, got {b_friends:?}"
    );

    drop(a);
    drop(b);
}

// Friend convergence across DEVICE != MASTER: when A friend-requests B and B
// accepts, A must LEARN B's device-to-master mapping and end with a SINGLE accepted
// friend keyed by B's MASTER, not a split row per id. The handlers push our profile
// and device list over the durable room, past the `is_new` gate.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn friend_converges_to_master_across_distinct_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    // THE CORE FIX: A learned B's device-to-master mapping from the pushed device list.
    // A's only chance used to be the transient inbox window, after which the is_new gate
    // suppressed it forever and A never collapsed B's device.
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

// Showcase board replication: A's board JSON rides ProfileUpdate to B keyed by A's
// MASTER, a later update that does not touch the board must not lose it (None means
// preserve), and `Some("")` clears it.

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
        support_creds: None,
    };

    // 1. A composes an ENRICHED game-block board plus a two-asset bundle (cover and
    // company logo): the JSON is opaque and the images ride the bundle, which exercises
    // the multi-asset replication path.
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

// The sibling-proof handshake links two genuine siblings that meet LIVE in the inbox
// with NO pre-seeded resolver: neither device knows the other at boot, so the
// challenge, master-signed response and merge are the only way they converge. The
// handshake must not break genuine multi-device convergence.

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

// Friend REMOVAL must be symmetric across a device != master shape. Every
// remove_friend call used to pass a RAW id with no resolution, so A addressed the
// bare master while B deleted `WHERE peer_id = <A device>` and missed its
// master-keyed row. Both sides must end with NO row for the other.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_removal_is_symmetric_across_distinct_device() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    // Accept and wait for BOTH sides to record it. Delivery depends on the device lists
    // having propagated so both agree on the DM room, so re-send the idempotent accept
    // a few times rather than racing one fixed sleep.
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

// The REQUESTER must end up with an ACCEPTED friend row after the other side
// accepts, even though it never clicked Accept. The FriendAccept could be lost (the
// requester was not yet in the accepter's DM room, or that room was device-keyed),
// leaving it stuck "pending outgoing" forever.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn requester_gets_accepted_row_after_acceptance() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Temporary nicknames: a nickname is claimed under the claimer's WS-auth DEVICE id,
// but friend requests must target the MASTER, so the claim carries the master
// through the relay and resolve hands it back. Harness caveat: the resolver is
// process-global, so B's node incidentally knows A's mapping; the relay-reported
// `master_id` path this test drives bypasses the resolver entirely.

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

// REMOVE then RE-ADD must NOT ping-pong. Removing an offline friend queued a
// FriendRemove and re-adding queued a FriendRequest, so both drained on the peer's
// reconnect and the friendship flapped. Sending a request now CANCELS a pending
// removal, and removing CANCELS a pending request or accept.

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

    a.cmd_tx
        .send(NodeCommand::RemoveFriend { peer_id: b_master.clone() })
        .await
        .unwrap();
    sleep_ms(500).await;
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

// REMOVE then RE-ADD while BOTH stay ONLINE must require fresh CONSENT. B's
// `pending_friend_accepts[A]` survived the FriendRemove, so when A re-added, B's
// drain AUTO-SENT a FriendAccept without ever showing A's request in Incoming: A
// had B as a friend, B had no row and never consented. B must get a genuine
// INCOMING request on re-add.

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

/// A copy of an accept that answered an EARLIER request (parked by the relay for a
/// room the requester had left, replayed from a mailbox, or simply late) must neither
/// recreate a friendship after its removal nor flip the request that follows the
/// removal. An accept with no stamp is a pre-0.11.1 client and stays honoured while a
/// request of ours is open.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn stale_friend_accept_replayed_after_readd_is_dropped() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 27;
    const A_DEV: u8 = 128;
    const B_MASTER: u8 = 129;
    const B_DEV: u8 = 168;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let a_dev = a.device_id.clone();
    let b_dev = b.device_id.clone();
    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    assert!(
        wait_until(10, async || {
            let on = relay.online_devices();
            on.contains(&a_dev) && on.contains(&b_dev)
        })
        .await,
        "both nodes must be connected"
    );
    drain_events(&mut a);
    drain_events(&mut b);
    relay.set_recording(&b_dev, true);

    let accepted = |n: &TestNode, m: &str| {
        friend_row(n, m).map(|(s, _)| s) == Some("accepted".to_string())
    };
    let is_accept = |f: &Vec<u8>| {
        std::str::from_utf8(f).map(|s| s.contains("\"friend_accept\"")).unwrap_or(false)
    };

    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    let mut a_id_as_b_saw = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                a_id_as_b_saw = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must receive A's first request"
    );
    b.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: a_id_as_b_saw.expect("A's id") })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || accepted(&a, &b_master) && accepted(&b, &a_master)).await,
        "precondition: both accepted, A {:?} B {:?}",
        friend_row(&a, &b_master),
        friend_row(&b, &a_master)
    );
    relay.set_recording(&b_dev, false);
    let stale_accept = relay
        .recorded_frames(&b_dev)
        .into_iter()
        .find(is_accept)
        .expect("B's accept crossed the relay in the clear");
    let first_stamp = friend_row_full(&a, &b_master).map(|(_, _, t)| t).expect("A's accepted row");
    assert_eq!(
        relay.buffered_frames(&a_dev).iter().filter(|f| is_accept(f)).count(),
        0,
        "the accept goes to the DM room A sits in, never to a room it already left"
    );

    a.cmd_tx
        .send(NodeCommand::RemoveFriend { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::FriendRemoved { .. })
        })
        .await,
        "B must receive the FriendRemove"
    );
    assert!(
        wait_until(5, async || {
            friend_row(&a, &b_master).is_none() && friend_row(&b, &a_master).is_none()
        })
        .await,
        "both rows must be gone after the removal"
    );
    drain_events(&mut a);
    drain_events(&mut b);

    relay.inject_direct(&dm_room, &b_dev, &a_dev, stale_accept.clone());
    relay.inject_direct(&dm_room, &b_dev, &a_dev, br#"{"type":"friend_accept"}"#.to_vec());
    assert!(
        !wait_until(3, async || friend_row(&a, &b_master).is_some()).await,
        "after a removal no copy of the old accept, stamped or bare, may recreate the friendship, A row {:?}",
        friend_row(&a, &b_master)
    );

    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { .. })
        })
        .await,
        "B must surface the re-add as a new request"
    );
    let second_stamp = friend_row_full(&a, &b_master)
        .map(|(_, _, t)| t)
        .expect("A's fresh outgoing row");
    assert!(
        second_stamp > first_stamp,
        "the re-add carries a newer stamp ({second_stamp} vs {first_stamp})"
    );

    relay.inject_direct(&dm_room, &b_dev, &a_dev, stale_accept);
    let flipped = wait_until(3, async || accepted(&a, &b_master)).await;
    assert!(
        !flipped,
        "a replayed accept for the FIRST request must not flip the re-add, A row {:?}",
        friend_row(&a, &b_master)
    );
    assert_eq!(
        friend_row(&a, &b_master),
        Some(("pending".to_string(), "outgoing".to_string()))
    );
    assert_eq!(
        friend_row(&b, &a_master),
        Some(("pending".to_string(), "incoming".to_string())),
        "B never consented"
    );

    relay.inject_direct(&dm_room, &b_dev, &a_dev, br#"{"type":"friend_accept"}"#.to_vec());
    assert!(
        wait_until(5, async || accepted(&a, &b_master)).await,
        "an accept without a stamp is a pre-0.11.1 client and stays honoured"
    );

    drop(a);
    drop(b);
}

// The startup CANONICALIZATION sweep heals a friend row stranded under a DEVICE id,
// the legacy temp-nickname shape. With a persisted device list mapping that device
// to its master, the resolver warms and the sweep folds the row to the master with
// no re-add and no network, repairing an existing DB on the next launch.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)]
async fn startup_canonicalizes_device_keyed_friend_row() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const LOCAL_MASTER: u8 = 20;
    const LOCAL_DEV: u8 = 21;
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

// Two FRESH single-device people, each with device != master, become friends
// ORGANICALLY and DM each other both ways. Every fresh install mints a random device
// key, so device != master even with no sibling. The whole chain is pinned: each
// side's resolver maps the other's device to master, Olm confirms both ways, a DM
// each way RENDERS in the receiver's MASTER-keyed thread (a device-keyed file leaves
// `dm_thread` empty), and the bubble is incoming and signed.

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

// Reject must NOT silently re-friend: rejecting an incoming request while our OWN
// outbound request to the same person was queued left that request armed, so it
// drained later and the pair became friends behind the user's back.
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

    // And the decline is SYMMETRIC: AL's reject names the very request that produced the
    // friendship, so VM must drop AL too. Leaving VM "accepted" is not cosmetic, because
    // VM re-seeds `pending_friend_accepts` at startup and re-fires on AL's next appearance.
    let vm_status = vm.friend_status(&al_master);
    assert_eq!(
        vm_status, None,
        "VM must drop AL on the reject; a one-sided decline leaves VM re-sending \
         FriendAccept forever (got {vm_status:?})",
    );

    drop(al);
    drop(vm);
}

// Mutual friend requests converge to friends WITHOUT a reject prompt: an inbound
// request arriving while our own outbound one is live is an implicit accept.
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

// One-way DM delivery guard: a DM must arrive when the sender is in several relay
// rooms alongside the DM room. The online send path used to route via
// `ws_room_for_peer` (first match over a HashMap), so it could pick a room the
// recipient has since left and the frame was buffered against one they never rejoin.
// The harness cannot force a stale relay room, so this asserts delivery under
// multiple shared rooms; the fix is that a DM never consults that lookup.
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

    // AL joins EXTRA rooms VM never joins, so AL's `ws_room_peers` can list VM's device
    // under more than one key. The send must deterministically target the DM room rather
    // than a first match VM is absent from.
    for i in 0..6 {
        al.cmd_tx
            .send(NodeCommand::JoinRoom { room_code: format!("extra_room_{i}") })
            .await
            .unwrap();
    }
    sleep_ms(1000).await;
    drain_events(&mut al);
    drain_events(&mut vm);

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

// A friend request to a target whose device-to-master mapping the requester has not
// learned queues under the target MASTER, and the presence drain no-ops while the
// resolver is cold, so the target never received it until a restart. The queue is
// now drained the moment the mapping is learned. The MockRelay collapses the field
// race's timing, so this is a delivery guarantee for the cold-requester path.
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

// LEAVE converges DURABLY on the leaver's sibling devices. The acting device tears
// down fully, but a SIBLING applying the fanned self-MemberRemoved only emitted
// MemberLeft: the shell reloaded on restart, re-listed the server, and the
// re-announce loop could re-ADD the identity to a server it had left, authored by a
// non-member and rejected by real members, a permanent fork. C must tear down
// durably and a later reconnect must not resurrect the server.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn leave_tears_down_durably_on_sibling_and_owner_prunes_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Relay availability cache, DM leg. Alice DMs Bob while Bob is offline, then Alice
// goes offline too, so no peer holds the message online and only the relay's buffer
// can deliver it. It must replay on Bob's DM-room join and be CLEARED afterwards;
// the replayed frame rides the normal decrypt and dedup path.

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

    relay.set_online(&b.device_id, true);
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::MessageReceived { text, .. } if text == "missed-you")
    })
    .await;
    assert!(got, "Bob must receive the buffered DM from the relay with Alice offline");
    sleep_ms(300).await;

    assert_eq!(
        relay.buffered_count(&b.device_id), 0,
        "the relay buffer for Bob must be cleared after replay"
    );

    let dm_texts: Vec<String> = b.dm_thread(&a_master).iter().map(|m| m.text.clone()).collect();
    assert!(
        dm_texts.contains(&"missed-you".to_string()),
        "buffered DM must be persisted on Bob, got {dm_texts:?}"
    );

    drop(a);
    drop(b);
}

// Relay availability cache, CHANNEL leg. The owner opts in via `relay_catchup_secs`,
// after which channel topic frames tee into a per-channel ring. Alice posts while
// Bob is offline and then goes offline herself; Bob's reconnect must get the message
// from the ring, with no member staying online.

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

// Relay catch-up must cover EVERY text channel, not just the selected one: the owner
// posts to TWO channels while the joiner is offline, then goes offline, and the
// returning joiner must get both.

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

// Relay catch-up must deliver a PUBLIC channel's file caption too. The caption is a
// plaintext `PublicChannelMessage` sent as a 0x03 broadcast, because guests cannot
// decrypt an MLS topic frame, and a 0x03 broadcast never enters the ring while the
// FileHeader rides the topic either way. The member came back to file metadata with
// no message row to hang it on, so the post showed as nothing at all.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_relay_catchup_delivers_public_channel_file_caption() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 114;
    const J_MASTER: u8 = 124;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Public Catchup Server").await;
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
    expect_mls_group(&[&o, &j], &server_id, 15).await;

    o.cmd_tx
        .send(NodeCommand::SetChannelPublic {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            is_public: true,
        })
        .await
        .unwrap();
    let published = wait_until(10, async || {
        j.server_state(&server_id)
            .is_some_and(|s| s.is_channel_public(&general))
    })
    .await;
    assert!(published, "the member must know #general is public before it leaves");
    drain_events(&mut o);
    drain_events(&mut j);

    // Member offline, owner posts a file with a caption, owner offline. The
    // relay's ring is the only path either half can take.
    relay.set_online(&j.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut j);

    let src = global_tmp.path().join("public.txt");
    std::fs::write(&src, b"public channel file catch-up").expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "public-file-catchup-1".to_string(),
            message_text: "public-caption-test".to_string(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();
    // Wait on the ring rather than the clock. Both halves BELONG there; before
    // the fix only the header arrived, so this is deliberately not an assertion
    // — the verdict is the caption assertion further down, which says what the
    // member actually ends up with.
    let _ = wait_until(10, async || {
        relay.topic_frames(&server_id, &general).len() >= 2
    })
    .await;
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    relay.set_online(&j.device_id, true);
    let mut got_msg = false;
    let mut got_fid: Option<String> = None;
    wait_event(&mut j, std::time::Duration::from_secs(12), |ev| {
        match ev {
            NetworkEvent::ChannelMessageReceived { text, .. } if text == "public-caption-test" => {
                got_msg = true;
            }
            NetworkEvent::FileHeaderReceived { file_id, file_name, .. }
                if file_name.starts_with("public") =>
            {
                got_fid = Some(file_id.clone());
            }
            _ => {}
        }
        got_msg && got_fid.is_some()
    })
    .await;
    let fid = got_fid.expect("the FileHeader must arrive via relay catch-up");
    sleep_ms(500).await;

    // The header alone is the bug: a files row with no message row renders as
    // nothing, because the channel list is built from `channel_messages`.
    assert!(
        got_msg,
        "a PUBLIC channel's file caption must reach a returning member: only the header replayed, so the card has no row to hang on"
    );
    assert!(
        j.channel_messages(&server_id, &general).iter().any(|m| m.text == "public-caption-test"),
        "caption row stored"
    );
    assert!(
        j.file_meta(&fid).is_some(),
        "file metadata row persisted from the replayed header"
    );

    drop(o);
    drop(j);
}

// Relay catch-up must survive a channel subscribe that BEATS the room join. Dart
// subscribes the moment the shell picks a channel, well before the socket has joined
// the server room, and the relay answers neither `set_topic_buffer` nor
// `topic_catchup` from a non-member and says nothing about the refusal, while the
// client had already recorded the pull. Modelled by sending the subscribe into a
// socket that cannot answer, which is what a pre-join subscribe is.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn channel_relay_catchup_survives_subscribe_before_room_join() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 112;
    const J_MASTER: u8 = 122;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&j_master]).await;
    sleep_ms(1200).await;
    let mut j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &j, 15).await;

    let server_id = create_server_and_wait(&mut o, "Subscribe Race Server").await;
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
    expect_mls_group(&[&o, &j], &server_id, 15).await;
    drain_events(&mut o);
    drain_events(&mut j);

    // Joiner offline.
    relay.set_online(&j.device_id, false);
    sleep_ms(500).await;
    drain_events(&mut j);

    // Owner posts a channel file while the joiner is gone, then leaves too, so
    // the relay ring is the ONLY way the joiner can ever learn about it.
    let src = global_tmp.path().join("race.txt");
    std::fs::write(&src, b"subscribe raced the room join").expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(general.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "chan-file-subscribe-race".to_string(),
            message_text: "race-caption-test".to_string(),
            vthumb: None,
            override_width: None,
            override_height: None,
            share_ref: None,
            voice: false,
            poster: None,
        })))
        .await
        .unwrap();
    // Settle on the ring, not the clock: both halves have to be IN the buffer
    // before the owner leaves, or the test proves nothing about replay.
    let ringed = wait_until(10, async || {
        relay.topic_frames(&server_id, &general).len() >= 2
    })
    .await;
    assert!(ringed, "the caption and the header must both reach the channel ring");
    relay.set_online(&o.device_id, false);
    sleep_ms(300).await;
    drain_events(&mut o);

    // THE RACE: the shell picks #general and subscribes while the socket is
    // still down. Nothing can answer, and the connection that CAN answer has
    // not started yet.
    j.cmd_tx
        .send(NodeCommand::SubscribeChannels {
            server_id: server_id.clone(),
            channel_ids: vec![general.clone()],
        })
        .await
        .unwrap();
    sleep_ms(500).await;

    // Now the socket comes up. The connect-time sweep is the only catch-up
    // left, and it must still run for this channel.
    relay.set_online(&j.device_id, true);
    let mut got_msg = false;
    let mut got_fid: Option<String> = None;
    wait_event(&mut j, std::time::Duration::from_secs(12), |ev| {
        match ev {
            NetworkEvent::ChannelMessageReceived { text, .. } if text == "race-caption-test" => {
                got_msg = true;
            }
            NetworkEvent::FileHeaderReceived { file_id, file_name, .. }
                if file_name.starts_with("race") =>
            {
                got_fid = Some(file_id.clone());
            }
            _ => {}
        }
        got_msg && got_fid.is_some()
    })
    .await;
    assert!(
        got_msg,
        "a subscribe that beat the room join must not consume the channel's catch-up: the caption never arrived"
    );
    let fid = got_fid.expect("the channel FileHeader must still replay after a pre-join subscribe");
    sleep_ms(500).await;

    assert!(
        j.channel_messages(&server_id, &general).iter().any(|m| m.text == "race-caption-test"),
        "caption row stored"
    );
    assert!(
        j.file_meta(&fid).is_some(),
        "file metadata row persisted from the replayed header"
    );

    drop(o);
    drop(j);
}

// Relay catch-up must deliver CHANNEL FILE messages. The companion text message used
// to fan targeted per-member sends, so offline members got nothing and nothing
// entered the ring, leaving the FileHeader with no message row to hang on. Both now
// ride the topic broadcast.

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

// Channel file fallback: O sends a file to a full-replication channel, B receives the
// bytes, O goes offline, and C then requests the file targeting O, the only holder
// the UI knows. The request reroutes to one online device of another member; O being
// offline proves the bytes can only have come from B.

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

// FileRequest gate and guest public downloads. Serving used to be UNGATED, so any
// peer that learned a file_id could pull any file. Now a NON-member is refused a
// private channel's file entirely; once the channel is PUBLIC, guest sync carries the
// file's metadata, RequestPublicFile serves the bytes against the receipt cap, and a
// file posted live reaches the guest as a plaintext message plus metadata.

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

    // 5. Owner-preview window: the LOCAL sync branch must return the LATEST page like
    // the remote responder. `messages_since(0)` returned the OLDEST 50, landing a
    // cold-started owner at the top of history.
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

// SELF-DM ("Saved messages"): a DM whose recipient is our OWN master is a
// notes-to-self thread. The send stores it locally like any DM, but fan-out must SKIP
// the recipient-device expansion, or the bare-master fallback queues a dead envelope
// forever. Our own SIBLINGS still get the echo under the same thread key, so the note
// appears on every device.

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

// BLOCK ENFORCEMENT AT INGEST: blocking is receiver-side self-protection, so the
// blocked identity's traffic still arrives at the socket and the swarm guards drop it
// BEFORE store and emit. Both hot surfaces are driven: a live DM from a blocked
// FRIEND and a friend request from a blocked STRANGER.
//
// CAUTION: the blocklist is PROCESS-GLOBAL, so a block "by A" is visible to every
// node's guards here. The asserted deliveries are all TO A, the control sender is
// never blocked, and the set is cleared at start and on scope exit.

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

    super::blocklist::block(&b_master);

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

    let a_thread = a.dm_thread(&b_master);
    assert!(
        a_thread.iter().any(|m| m.text == "before-block"),
        "A keeps the pre-block message, got {a_thread:?}"
    );
    assert!(
        !a_thread.iter().any(|m| m.text == "after-block"),
        "the blocked DM must never reach A's store, got {a_thread:?}"
    );
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
    let c_late = wait_event(&mut a, std::time::Duration::from_secs(2), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id } if *peer_id == c_master)
    })
    .await;
    assert!(
        !saw_c && !c_late,
        "A must emit NO FriendRequestReceived for blocked stranger C"
    );

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

    super::blocklist::clear_for_test();

    drop(a);
    drop(b);
    drop(c);
    drop(d);
}

// SCALING BENCHMARK (large-server MLS viability). Measures the two O(N) fan-out
// points on the real join/commit/message code so the slope is fact rather than
// estimate, then extrapolates to 1k and 50k members. The metric source is the
// MockRelay load meter, which counts what the production relay would copy to sockets
// plus the coordinator's targeted fan-out. Ignored, since it spawns many real nodes
// and waits on MLS batch timers:
//   cargo test --lib scaling_benchmark_mls_fanout -- --nocapture --ignored

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


// Custom emotes: EmojiAdded replicates the (name, hash) metadata via the CRDT, the
// member pulls the content-addressed BYTES on demand and verifies them, a member
// without MANAGE_EMOTES is rejected at ingest, and EmojiRemoved converges.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn server_emote_replicates_and_bytes_pull_on_demand() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Server sticker packs: StickerAdded replicates hash-keyed metadata to a joined
// member who pulls the BYTES at AssetKind::Sticker, a member without MANAGE_EMOTES
// is refused, transparency survives the round trip, and StickerRemoved converges.
// Unlike emotes, stickers are keyed by HASH, carry pack/w/h and get a bigger cap.

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

// Asset rail: the size cap enforced on receipt comes from the kind WE recorded at
// request time, never from the sender. A 300 KB blob is refused as an 'emote' (256
// KB cap) and accepted when the same hash is re-requested as a 'gif' (2 MB), and the
// failed receipt must free the slot so the re-ask is not throttled away.

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

// Asset rail: an UNSOLICITED bundle with a valid container and content hash, from a
// friend in a shared room, is dropped because the receiver never requested the hash.
// Otherwise any peer could stuff blobs into our encrypted DB at the largest cap.

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
        missing: Vec::new(),
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

// Server banners: the CRDT carries ONLY the banner hash in
// settings["server_banner"], and a joined member pulls the content-addressed BYTES on
// demand at AssetKind::Banner. The command sequence mirrors what the
// set_server_banner FFI decomposes into; clearing converges too.

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

// A plain Member cannot write the banner setting: ServerSettingChanged is
// MANAGE_SERVER-gated at authoring and at ingest, so the write dies with the author's
// own Error event and never reaches the owner.

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

// Avatar frames (issue #54): the profile carries an ID, never the art. A built-in
// `b:<hue>` costs nothing on the wire; an uploaded frame puts a 64-hex hash on the
// LIGHT announce with the bytes on the asset rail at AssetKind::Frame. An update that
// does not touch the frame preserves it and `""` clears it. Only a live run can show
// the ID converging while the bytes stay OFF the push.

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
        support_creds: None,
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

// Animated profile media on the asset rail: the still companion stays in
// `avatar`/`banner` for old clients and the guest thumb, while the animation becomes
// a 64-hex hash on the LIGHT announce with the bytes pulled at AssetKind::Profile.
// This is the bandwidth fix: every re-announce path used to re-ship megabytes of
// unchanged GIF.

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
        support_creds: None,
    };

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

// Animated server icons: the still icon stays base64 in settings["server_avatar"]
// while an animated upload writes only a hash into settings["server_avatar_anim"],
// with the 128px animated WebP on the rail at AssetKind::Avatar. A later still upload
// clears the anim hash and converges.

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

// Conferences: the waiting room IS an MLS add. The host starts a meeting, a knocker
// broadcasts a join request carrying its KeyPackage, and the host admits (MLS add,
// direct Welcome, room-broadcast commit) or denies. Chat is an MLS application
// message attributed by the authenticated leaf credential.

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

// Deletion propagation through sync is AUTHENTICATED: `hidden_at` on a sync item is
// honoured only with the author's own signed proof beside it. Three cases: a real
// deletion reaches a late joiner and the joiner ADOPTS the proof; a bare hidden flag
// with no proof is DROPPED and the message stays visible; and a forged proof signed
// by a non-author is DROPPED by the pk-to-author binding.

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

// SFrame heal ladder (issue #27). The harness cannot drive the media plane, so this
// verifies the KEY layer: a non-escalated heal re-emits the CURRENT epoch key; a
// non-authority escalation drops the local group, re-bootstraps from the owner and
// converges; an authority escalation removes and re-adds the failing peer's leaf,
// whose own eviction recovery pulls it back in.

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

// Join-order MLS epoch race. MLS commits ride an UNBUFFERED 0x03 room broadcast, so a
// member whose socket misses them holds the group at a silently STALE epoch: every
// recovery trigger keys on has_group or a missing leaf, and a voice-only channel has
// no ciphertext to fail a decrypt. The fix caches commit frames per group, detects a
// stale member via epoch hints, and serves an MlsCommitCatchup REPLAY, which adds no
// commits (repair-by-re-add bumps the epoch for everyone and feeds the churn
// spiral). `set_broadcast_deaf` models the loss.

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
    // The join bootstrap is racy by construction: a joiner sends its KeyPackage twice,
    // and two copies straddling a batch tick become a remove + re-add whose removal
    // commit the joiner reads as an eviction. That churn settles, but a pending batch can
    // still re-add the member that must stay stale, so wait for a QUIET group: one epoch,
    // agreed by all three, unchanged across two batch ticks.
    let mut quiet_since = std::time::Instant::now();
    let mut last: Option<u64> = None;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let (oe, be, ce) = (
            o.mls_epoch(&server_id).await,
            b.mls_epoch(&server_id).await,
            c.mls_epoch(&server_id).await,
        );
        let agreed = match (oe, be, ce) {
            (Some(x), Some(y), Some(z)) if x == y && y == z => Some(x),
            _ => None,
        };
        if agreed.is_some() && agreed == last {
            if quiet_since.elapsed() >= std::time::Duration::from_millis(4500) {
                break;
            }
        } else {
            quiet_since = std::time::Instant::now();
            last = agreed;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the server group must go quiet before the heal is staged, got o={oe:?} b={be:?} c={ce:?}"
        );
        // Polls the live snapshot only (never a running node's DB).
        sleep_ms(500).await;
    }
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

/// Issue #45: a link preview whose fetch finished AFTER the send still lands on the
/// message, everywhere the message went. The compose box debounces 600ms before
/// fetching, so anyone who pasted a URL and sent immediately got no card at all.
///
/// Once the card lands the recipient's row shows it, our own other device's row shows
/// it, the row still VERIFIES (the attach re-signs, and a broken signature would stop
/// the message replicating through signed sync), and `edited_at` stays NULL.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn late_link_preview_lands_on_recipient_and_sibling_without_marking_edited() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

    assert!(
        a.store().get_dm_message_sig_row(MID).and_then(|r| r.link_preview).is_none(),
        "the friend's row must start with no card"
    );

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

/// Issue #45 follow-up: a peer that gets a message through BACKFILL gets the card with
/// it, not just a bare link. Backfill carried only `lp_digest`, the hash the signature
/// binds, and nothing else in the protocol ever re-sends a card.
///
/// The scenario is a member who joins AFTER the card exists, because that is the one
/// where sync is provably the only vehicle. Two things must hold on the joiner's row:
/// the card is THERE, and the row still VERIFIES against its digest, because a row
/// holding a signature over a preview it does not have packs `lp_digest = None` for
/// the next peer, who then rejects the message as forged.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn backfilled_member_gets_link_preview_through_channel_sync() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

/// The DM half of the same fix: a card reaching a device through
/// `DmSiblingSyncBatch`, the DM path where backfill is provably the only vehicle. A
/// friend who merely goes offline is rescued by the sender's queue and the relay's
/// per-device buffer, but a device that did not EXIST when the message was sent has
/// neither: it has exactly what its sibling hands it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn freshly_linked_device_backfills_dm_link_previews_from_its_sibling() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

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

// Media forwarder control plane: the fwd_* client plumbing, with a mock node F
// playing the FORWARDER role (the real forwarder's media plane is out of harness
// scope). Verified: JoinForwarderRoom is a PURE transport join with no RoomCleared;
// a first ForwarderSendSignal with no Olm session queues and fires a signed
// KeyRequest, then drains; a client-bound fwd envelope hits the ignore arm and the
// node stays healthy; and forwarder-sendable signals emit ForwarderSignal with origin
// and payload intact.

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

    // F hosts its own fwd room and A joins it. Both ALSO join `fwd:{a_id}` because step 4
    // has F impersonate the forwarder over the CLIENT send path, which routes by
    // `fwd:{target}`, while the real forwarder replies from its OWN room. Joining both
    // keeps that one artifice deliverable without weakening the routing rule under test.
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

    let mut saw_room_cleared = false;
    while let Ok(ev) = a.event_rx.try_recv() {
        if matches!(ev, NetworkEvent::RoomCleared) {
            saw_room_cleared = true;
        }
    }
    assert!(!saw_room_cleared, "JoinForwarderRoom must never emit RoomCleared");

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

// fwd-room discovery-cascade suppression. A forwarder discards every profile, sync,
// friend, MLS and DM frame a client could send it, so presence in a `fwd:` room must
// NOT run the peer-discovery cascade (~45 junk frames per join). Verified: no
// PeerDiscovered and no profile push, the Olm session still establishes because
// queued fwd envelopes drain through it, and `synced_peers` is NOT burned, or a later
// genuinely shared room would be a permanent discovery blackhole.

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

// vc_screen_assign and route hint: the sharer assigns a relay-routed viewer to a
// media forwarder over the VC lane. The route round-trips on screen_watch, assign
// round-trips origin and forwarder, and a SPOOFED origin drops the whole signal.

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

// OWNER OFFLINE: a plain member carries a stranger's whole join. The owner is
// PREFERRED, not required, but nothing covered the fallback end to end, so the claim
// that a member can admit someone on its own, on the CRDT side and the MLS side both,
// was argued from the election's fallback arm and never driven.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn join_succeeds_while_owner_is_offline() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 34; // owner — offline for the entire join
    const A_MASTER: u8 = 35; // plain member — the fallback coordinator
    const B_MASTER: u8 = 36; // stranger holding an invite, friends with nobody
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Owner Away").await;
    let general = general_channel_of(&server_id);

    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "member A joins normally while the owner is online"
    );
    expect_mls_group(&[&o, &a], &server_id, 20).await;

    // --- The owner leaves. A has to OBSERVE it: `elect_server_coordinator`
    // reads A's own `ws_room_peers`, so until the PeerLeft lands A still elects
    // the (unreachable) owner and drops the joiner's KeyPackage on the floor. ---
    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop before the join, or it elects a ghost committer"
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "CRDT admission must not need the owner — A serves the snapshot + op log"
    );

    expect_mls_leaf(&a, &server_id, &b.device_id, 30).await;
    expect_mls_leaf(&b, &server_id, &b.device_id, 30).await;
    // …and the ABSENT owner's leaf survives the commit (an add must never
    // double as an eviction of whoever happened to be offline).
    expect_mls_leaf(&b, &server_id, &o.device_id, 30).await;

    let mut expect_members = vec![o_master.clone(), a_master.clone(), b_master.clone()];
    expect_members.sort();
    assert!(
        wait_until(20, async || b.raw_crdt_member_keys(&server_id) == expect_members).await,
        "joiner CRDT members must be all three masters, got {:?}",
        b.raw_crdt_member_keys(&server_id),
    );

    // The group actually WORKS for the joiner: A encrypts at the epoch A itself
    // committed, B decrypts. A leaf in a list proves nothing on its own.
    drain_events(&mut b);
    a.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "owner is asleep".to_string(),
            message_id: "owner-away-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "owner is asleep"
        ))
        .await,
        "the joiner must decrypt a channel message keyed to the epoch A committed"
    );

    drop(o);
    drop(a);
    drop(b);
}

// ...and the owner comes BACK, having slept through an epoch advance it did not
// author: it still holds a leaf, so nothing keyed on `has_group` fires. Both epoch
// hints the reconnect generates used to be dropped. The hint from the NEW member
// races the CRDT delta, so `handle_epoch_hint`'s membership gate returned and nothing
// re-sent it; and the owner-as-authority deadlock had the owner bail out of
// `send_epoch_probe` while the member holding the newer epoch refused to serve. The
// fix is `epoch_catchup_responder`: both sides elect with the peer that is BEHIND
// excluded, and the non-member branch self-probes instead of returning.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn owner_returns_from_a_join_it_missed_and_converges() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 37;
    const A_MASTER: u8 = 38;
    const B_MASTER: u8 = 39;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Owner Returns").await;
    let general = general_channel_of(&server_id);

    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "member A joins normally while the owner is online"
    );
    expect_mls_group(&[&o, &a], &server_id, 20).await;
    let epoch_before = o.mls_epoch(&server_id).await.expect("owner holds the group");

    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop before the join"
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "the stranger joins on A alone"
    );
    expect_mls_leaf(&a, &server_id, &b.device_id, 30).await;
    let epoch_after = a.mls_epoch(&server_id).await.expect("A holds the group");
    assert!(
        epoch_after > epoch_before,
        "the add must have advanced the epoch past the owner ({epoch_before} -> {epoch_after})"
    );

    drain_events(&mut o);
    relay.set_online(&o.device_id, true);

    // CRDT first: the plaintext op broadcast + reconnect sync must tell the
    // owner there is a third member now. Asserted on DB TRUTH, not on an event:
    // the reconnect delta arrives as a SyncResponse op-log merge, which is a
    // different emit path from the live `CrdtOpBroadcast` ingest.
    let mut expect_members = vec![o_master.clone(), a_master.clone(), b_master.clone()];
    expect_members.sort();
    assert!(
        wait_until(30, async || o.raw_crdt_member_keys(&server_id) == expect_members).await,
        "returning owner CRDT members must converge, got {:?}",
        o.raw_crdt_member_keys(&server_id),
    );

    // Then MLS, and this is the claim the fix makes: the heal is TRAFFIC-FREE. Nothing
    // healed until three channel messages had failed to decrypt, so a quiet server, or a
    // voice-only channel, left the owner stale indefinitely. Assert with nothing yet sent.
    expect_mls_leaf(&o, &server_id, &b.device_id, 45).await;
    assert!(
        wait_until(30, async || {
            let e = o.mls_epoch(&server_id).await;
            e.is_some() && e == a.mls_epoch(&server_id).await && e == b.mls_epoch(&server_id).await
        })
        .await,
        "all three must converge on one epoch with no traffic, got owner={:?} A={:?} B={:?}",
        o.mls_epoch(&server_id).await,
        a.mls_epoch(&server_id).await,
        b.mls_epoch(&server_id).await,
    );

    // And once healed it stays healed: every message lands LIVE, not via the
    // backfill that used to paper over the stale window.
    drain_events(&mut o);
    let mut delivered: Vec<u32> = Vec::new();
    for n in 1..=3u32 {
        b.cmd_tx
            .send(NodeCommand::SendChannelMessage {
                server_id: server_id.clone(),
                channel_id: general.clone(),
                text: format!("welcome back {n}"),
                message_id: format!("owner-back-{n}"),
                reply_to_mid: None,
                link_preview: None,
            })
            .await
            .unwrap();
        let want = format!("welcome back {n}");
        if wait_event(&mut o, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ChannelMessageReceived { text, .. } if *text == want
        ))
        .await
        {
            delivered.push(n);
        }
    }
    assert_eq!(
        delivered,
        (1..=3).collect::<Vec<u32>>(),
        "a healed owner must decrypt every message live (got {delivered:?} of 1..=3)"
    );

    drop(o);
    drop(a);
    drop(b);
}

// The join coordinator gate's failure mode. Joins are served by ONE elected member,
// and the election reads each member's OWN `ws_room_peers`, so a coordinator whose
// socket died WITHOUT a PeerLeft is still elected by everyone and answers for nobody.
// The safety net is the joiner's 4s re-ask, so the gate degrades to the OLD fan-out
// rather than to a failed join.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn join_survives_a_coordinator_that_vanished_silently() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 24; // owner — elected coordinator, then silently gone
    const A_MASTER: u8 = 28; // the member that has to notice and step in
    const B_MASTER: u8 = 29; // joiner
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Vanishing Coordinator").await;
    let general = general_channel_of(&server_id);

    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "member A joins normally first"
    );
    expect_mls_group(&[&o, &a], &server_id, 20).await;

    // --- The owner's socket dies with NOBODY told. A keeps it in
    // `ws_room_peers`, so A's election still names the owner: the polite
    // `set_online(false)` cannot reproduce this, which is the whole point. ---
    drain_events(&mut a);
    relay.drop_socket_silently(&o.device_id);
    assert!(
        !relay.room_devices(&server_id).contains(&o.device_id),
        "the relay must have dropped the owner from the room"
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();

    // The first ask goes unserved (A defers to a coordinator that is gone). The
    // 4s re-ask is what has to rescue it, well inside the 15s failure.
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(14), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "the re-ask must rescue a join whose elected coordinator vanished"
    );
    let mut expect_members = vec![o_master.clone(), a_master.clone(), b_master.clone()];
    expect_members.sort();
    assert!(
        wait_until(20, async || b.raw_crdt_member_keys(&server_id) == expect_members).await,
        "rescued join converges to all three masters, got {:?}",
        b.raw_crdt_member_keys(&server_id),
    );

    // SCOPE, deliberately: the MLS leaf does NOT follow here, and that is not this fix
    // regressing (the same assertion fails with the gate reverted). The committer
    // election reads the same stale `ws_room_peers` and a KeyPackage has no re-ask of its
    // own. In production the relay's keepalive evicts the dead socket and corrects the
    // view; `drop_socket_silently` models the window before that.
    assert!(
        b.mls_members(&server_id).await.is_empty(),
        "if the MLS add now lands here too, the residual is fixed — tighten this test          to assert the leaf and the decrypt instead of pinning the gap"
    );

    drop(o);
    drop(a);
    drop(b);
}

// ASYNC FRIENDING: two people who are NEVER online at the same moment. Three legs had
// to land together, each failing silently on its own. The request is addressed to a
// MASTER, which no socket authenticates as, so it needs a mailbox gated by an
// ownership proof; the accept rides the device-keyed buffer, but only because the
// accepter learned the requester's device from the request; and the Olm handshake
// needed co-presence, so the bundle now rides INSIDE the request under its own
// freshness rule. "Offline" here is `set_online(false)`.

/// A raw socket on the MockRelay with no node behind it: the only way to drive a
/// join a real node would never send (a stranger claiming someone else's inbox,
/// or a forged proof).
struct RawSocket {
    cmd_tx: mpsc::UnboundedSender<WsCommand>,
    event_rx: mpsc::UnboundedReceiver<WsEvent>,
}

fn raw_socket(relay: &MockRelay, device_id: &str) -> RawSocket {
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<WsCommand>();
    let (event_tx, event_rx) = mpsc::unbounded_channel::<WsEvent>();
    relay.register(device_id.to_string(), cmd_rx, event_tx);
    RawSocket { cmd_tx, event_rx }
}

impl RawSocket {
    /// Collect every DirectMessage payload delivered within `ms`. Absence is the
    /// assertion in most of these cases, and an absence has no condition to poll,
    /// so this deliberately waits out a real window.
    async fn direct_payloads(&mut self, ms: u64) -> Vec<Vec<u8>> {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(ms);
        let mut out = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return out;
            }
            match tokio::time::timeout(remaining, self.event_rx.recv()).await {
                Ok(Some(WsEvent::DirectMessage { data, .. })) => out.push(data),
                Ok(Some(_)) => {}
                _ => return out,
            }
        }
    }
}

/// The friends row for `master` as (status, direction), or None.
fn friend_row(node: &TestNode, master: &str) -> Option<(String, String)> {
    node.store().get_friend_status_direction(master).ok().flatten()
}

/// The friends row for `master` as (status, direction, requested_at), or None.
/// The timestamp is the whole game for the dedup/anti-downgrade guards, so the
/// tests that reason about them read it rather than inferring it.
fn friend_row_full(node: &TestNode, master: &str) -> Option<(String, String, i64)> {
    node.store().get_friend_row(master).ok().flatten()
}

/// The `requested_at` of every buffered frame in `target`'s mailbox that parses
/// as a friend REJECT. Reading the mailbox rather than counting it is what proves
/// the decline names the request it answers.
fn buffered_reject_ats(relay: &MockRelay, target: &str) -> Vec<i64> {
    relay
        .buffered_frames(target)
        .into_iter()
        .filter_map(|f| match serde_json::from_slice::<super::types::HavenMessage>(&f) {
            Ok(super::types::HavenMessage::FriendReject { requested_at, .. }) => Some(requested_at),
            _ => None,
        })
        .collect()
}

/// The `requested_at` of every buffered frame in `target`'s mailbox that parses
/// as a friend REQUEST.
fn buffered_request_ats(relay: &MockRelay, target: &str) -> Vec<i64> {
    relay
        .buffered_frames(target)
        .into_iter()
        .filter_map(|f| match serde_json::from_slice::<super::types::HavenMessage>(&f) {
            Ok(super::types::HavenMessage::FriendRequest { requested_at, .. }) => Some(requested_at),
            _ => None,
        })
        .collect()
}

// Leg 1. A requests B while B has never connected, then A goes dark; B boots ALONE
// and must still find the request waiting. Before the mailbox the request reached no
// socket, and its retry queue only fired on a co-presence that never came.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_request_delivered_with_no_overlap() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 61;
    const A_DEV: u8 = 62;
    const B_MASTER: u8 = 63;
    const B_DEV: u8 = 64;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // B does not exist yet — not offline, ABSENT. Nothing about the deposit may
    // depend on the target ever having connected.
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "the request must be buffered under B's MASTER — that is the mailbox",
    );

    // A leaves. From here the two are never reachable together.
    relay.set_online(&a.device_id.clone(), false);
    drain_events(&mut a);

    // B's first ever boot. Its `Connected` joins inbox:{b_master} WITH the
    // ownership proof, which is what makes the relay hand the mailbox over.
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { .. })
        })
        .await,
        "B must surface the mailbox request on its first boot",
    );

    assert_eq!(
        friend_row(&b, &a_master),
        Some(("pending".to_string(), "incoming".to_string())),
        "the row must key on A's MASTER — the carried device list is what teaches B that",
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Legs 2 and 3, the acceptance test from the contract in full: request, accept,
// and DMs BOTH ways, with zero overlap at any point.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_accept_and_dms_with_zero_overlap() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 71;
    const A_DEV: u8 = 72;
    const B_MASTER: u8 = 73;
    const B_DEV: u8 = 74;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let b_device = b.device_id.clone();
    let mut requester_id = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                requester_id = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must see the mailbox request",
    );
    let accept_id = requester_id.expect("captured requester id");
    b.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: accept_id })
        .await
        .unwrap();

    // Our profile, the accept, and the ONE pre-key establisher all have to be
    // waiting for A. They are addressed at A's DEVICE in the deterministic DM
    // room, so the relay buffers them under that device.
    assert!(
        wait_until(10, async || relay.buffered_count(&a_device) >= 3).await,
        "profile + accept + establisher must be buffered for the absent requester, got {}",
        relay.buffered_count(&a_device),
    );
    // B holds the outbound half already, built from the CARRIED bundle with the
    // requester nowhere in sight.
    assert!(
        wait_until(10, async || b.olm_status(&a_device).await != "absent").await,
        "B must build its Olm session from the carried bundle at accept time",
    );

    relay.set_online(&b_device, false);
    drain_events(&mut b);
    relay.set_online(&a_device, true);

    assert!(
        wait_until(20, async || {
            friend_row(&a, &b_master).map(|(st, _)| st) == Some("accepted".to_string())
        })
        .await,
        "A must record the acceptance from the buffered FriendAccept, got {:?}",
        friend_row(&a, &b_master),
    );
    assert!(
        wait_until(20, async || a.olm_status(&b_device).await == "confirmed").await,
        "the establisher must give A a CONFIRMED inbound session, got {:?}",
        a.olm_status(&b_device).await,
    );
    assert!(
        a.dm_thread(&b_master).is_empty(),
        "the handshake sentinel must not insert a DM row, got {:?}",
        a.dm_thread(&b_master),
    );
    drain_events(&mut a);

    a.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: b_master.clone(),
            text: "from A, alone".to_string(),
            message_id: "af-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_device) > 0).await,
        "A's DM must be buffered for the offline B",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);
    relay.set_online(&b_device, true);
    assert!(
        wait_until(20, async || {
            b.dm_thread(&a_master).iter().any(|m| m.text == "from A, alone" && !m.is_mine)
        })
        .await,
        "B must decrypt A's DM, got {:?}",
        b.dm_thread(&a_master),
    );
    assert!(
        wait_until(10, async || b.olm_status(&a_device).await == "confirmed").await,
        "decrypting A's message confirms B's half, got {:?}",
        b.olm_status(&a_device).await,
    );
    drain_events(&mut b);
    b.cmd_tx
        .send(NodeCommand::SendMessage {
            peer_id: a_master.clone(),
            text: "from B, alone".to_string(),
            message_id: "af-2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&a_device) > 0).await,
        "B's reply must be buffered for the offline A",
    );

    relay.set_online(&b_device, false);
    drain_events(&mut b);
    relay.set_online(&a_device, true);
    assert!(
        wait_until(20, async || {
            a.dm_thread(&b_master).iter().any(|m| m.text == "from B, alone" && !m.is_mine)
        })
        .await,
        "A must decrypt B's reply, got {:?}",
        a.dm_thread(&b_master),
    );

    // Both halves confirmed, and neither node was ever reachable while the other
    // was — the whole point of the feature.
    assert_eq!(a.olm_status(&b_device).await, "confirmed");
    assert_eq!(b.olm_status(&a_device).await, "confirmed");

    drop(a);
    drop(b);
}

// FIX A, the accepted-friend DOWNGRADE. The inbox mailbox is TTL-only and re-delivers
// the ORIGINAL request on EVERY `inbox:` join, so an accepter who rebooted had the
// replay walk its "accepted" row back to "pending incoming" and re-fire
// FriendRequestReceived. A reboot is modelled as an offline-online cycle, which
// re-runs the whole join flow, and the guard reads the DURABLE friends row.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_accept_survives_mailbox_redelivery() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 101;
    const A_DEV: u8 = 102;
    const B_MASTER: u8 = 103;
    const B_DEV: u8 = 104;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let b_device = b.device_id.clone();
    let mut requester_id = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                requester_id = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must see the mailbox request on its first boot",
    );
    b.cmd_tx
        .send(NodeCommand::AcceptFriendRequest {
            peer_id: requester_id.expect("captured requester id"),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || {
            friend_row(&b, &a_master).map(|(s, _)| s) == Some("accepted".to_string())
        })
        .await,
        "B's row for A must reach accepted, got {:?}",
        friend_row(&b, &a_master),
    );

    // 4. B reboots (offline → online). Its reconnect re-runs the JoinInbox flow,
    //    and the TTL-only mailbox re-delivers the ORIGINAL request — the exact
    //    field trigger. Drain FIRST so the first-boot event cannot be miscounted.
    drain_events(&mut b);
    relay.set_online(&b_device, false);
    relay.set_online(&b_device, true);

    // 5. ASSERT the guard held. The absence check rides `wait_event`'s timeout
    //    (not a fixed `sleep_ms`, so it costs nothing against the sleep budget),
    //    a window long enough for the in-process replay to have been processed.
    let saw_second = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(
        !saw_second,
        "a re-delivered mailbox request for an ALREADY-ACCEPTED friend must NOT \
         re-emit FriendRequestReceived",
    );
    assert_eq!(
        friend_row(&b, &a_master),
        Some(("accepted".to_string(), String::new())),
        "the accepted friendship must survive the mailbox replay — no downgrade to \
         pending incoming",
    );

    drop(a);
    drop(b);
}

// FIX B: a friend request carries the sender's OWN signed profile, so a stranger's
// incoming card renders a real name. LIGHT: the avatar HASH rides, never the bytes. A
// TAMPERED signature means the request still lands but the profile is not stored,
// because an unverified profile is never store-and-logged.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_request_carries_sender_profile() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 111;
    const A_DEV: u8 = 112;
    const B_MASTER: u8 = 113;
    const B_DEV: u8 = 114;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // --- 1. A sets a profile, THEN requests B (absent). The request carries A's
    //        signed profile into B's mailbox. ---
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::UpdateProfile {
            display_name: "Alice Example".to_string(),
            status: "around".to_string(),
            about_me: String::new(),
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username: String::new(),
            showcase_board: None,
            showcase_assets: None,
            avatar_frame: None,
            avatar_anim: None,
            banner_anim: None,
        support_creds: None,
        })
        .await
        .unwrap();
    // A emits ProfileUpdated once its own row is written — a request built after
    // this will carry it.
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::ProfileUpdated { .. })
        })
        .await,
        "A must persist its own profile before sending the request",
    );
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request (carrying A's profile) must reach B's mailbox",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { .. })
        })
        .await,
        "B must see the mailbox request",
    );
    // The carried profile is verified + stored BEFORE the request event fires, so
    // by the time we saw it B already holds A's name keyed under A's MASTER — no
    // ProfileRequest round trip needed.
    let stored = b.store().load_profile(&a_master).unwrap();
    assert_eq!(
        stored.map(|p| p.display_name),
        Some("Alice Example".to_string()),
        "B must hold A's carried display name for the incoming card",
    );

    // --- 3. A TAMPERED carried profile from a THIRD identity C: valid device
    //        list, but the signature covers a DIFFERENT name than the one carried.
    //        The profile is rejected; the request still lands; nothing is stored
    //        for C. Injected directly as a hostile peer would push it. ---
    const C_MASTER: u8 = 115;
    const C_DEV: u8 = 116;
    let c_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER));
    let c_dev = NativeKeypair::from_secret_bytes(&seed_bytes(C_DEV)).peer_id();
    let c_master = c_master_kp.peer_id();
    let c_list = super::crypto_handler::build_signed_device_list(
        &c_master_kp, 1, vec![c_dev.clone()], Vec::new(),
    );
    // Sign over the REAL name, then carry a DIFFERENT one — a genuine tamper the
    // signature cannot cover.
    use base64::Engine as _;
    let c_pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(c_master_kp.public_key_protobuf());
    let (sig, pk) = super::crypto_handler::sign_profile(
        &c_master_kp, &c_pub_b64, &c_master, 1_700_000_000_000,
        "Real Name", "", "", "", "",
    );
    let tampered = super::types::CarriedProfile {
        source_peer_id: c_master.clone(),
        display_name: "Tampered Name".to_string(), // NOT what was signed
        status: String::new(),
        about_me: String::new(),
        updated_at: 1_700_000_000_000,
        twitch_username: String::new(),
        avatar_hash: String::new(),
        profile_sig: sig,
        profile_pk: pk,
    };
    let frame = super::types::HavenMessage::FriendRequest {
        requested_at: 1_700_000_000_001,
        carried_bundle: None,
        device_list: Some(c_list),
        carried_profile: Some(tampered),
    };
    let data = serde_json::to_vec(&frame).unwrap();
    let inbox = format!("inbox:{b_master}");
    relay.inject_direct(&inbox, &c_dev, &b.device_id, data);

    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id } if *peer_id == c_dev)
        })
        .await,
        "the request must still land even though its carried profile is unverifiable",
    );
    assert!(
        b.store().load_profile(&c_master).unwrap().is_none(),
        "a tampered carried profile must NOT be stored",
    );

    drop(a);
    drop(b);
}

// DECLINE IS STICKY. Reject writes a "declined" tombstone preserving the original
// requested_at instead of deleting the row, because under a TTL-only mailbox a
// deleted row let the buffered request resurface on every reboot for three days. A
// genuinely NEWER request still falls through and shows again.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn declined_request_does_not_resurrect_on_mailbox_redelivery() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 121;
    const A_DEV: u8 = 122;
    const B_MASTER: u8 = 123;
    const B_DEV: u8 = 124;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let b_device = b.device_id.clone();
    let mut requester_id = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                requester_id = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must see the mailbox request on its first boot",
    );
    b.cmd_tx
        .send(NodeCommand::RejectFriendRequest {
            peer_id: requester_id.expect("captured requester id"),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || {
            friend_row(&b, &a_master).map(|(s, _)| s) == Some("declined".to_string())
        })
        .await,
        "reject must write a sticky declined tombstone, got {:?}",
        friend_row(&b, &a_master),
    );

    // 3. B reboots (offline → online). The TTL-only mailbox re-delivers the SAME
    //    original request. Drain FIRST so the first-boot event cannot be miscounted.
    drain_events(&mut b);
    relay.set_online(&b_device, false);
    relay.set_online(&b_device, true);

    // 4. ASSERT the decline stuck: no second FriendRequestReceived (bounded via
    //    wait_event's timeout, budget-free), and the row is STILL declined — never
    //    resurrected as pending incoming.
    let saw_replay = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(
        !saw_replay,
        "a re-delivered mailbox request for a DECLINED person must NOT re-emit \
         FriendRequestReceived",
    );
    assert_eq!(
        friend_row(&b, &a_master),
        Some(("declined".to_string(), String::new())),
        "the decline must survive the mailbox replay — no resurrection as pending \
         incoming",
    );

    // 5. A genuinely NEWER request (a cancel + re-add mints a fresh requested_at)
    //    MUST fall through and show again. Injected directly as A pushing it, with
    //    a requested_at strictly newer than the tombstone's.
    drain_events(&mut b);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let newer_at = now_ms + 60_000;
    let a_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER));
    let a_list = super::crypto_handler::build_signed_device_list(
        &a_master_kp, 1, vec![a_device.clone()], Vec::new(),
    );
    let frame = super::types::HavenMessage::FriendRequest {
        requested_at: newer_at,
        carried_bundle: None,
        device_list: Some(a_list),
        carried_profile: None,
    };
    let data = serde_json::to_vec(&frame).unwrap();
    let inbox = format!("inbox:{b_master}");
    relay.inject_direct(&inbox, &a_device, &b.device_id, data);

    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
                if super::resolver::resolve(peer_id) == a_master)
        })
        .await,
        "a genuinely NEWER request must fall through the declined guard and show again",
    );
    assert!(
        wait_until(10, async || {
            matches!(
                friend_row(&b, &a_master).as_ref().map(|(s, d)| (s.as_str(), d.as_str())),
                Some(("pending", "incoming"))
            )
        })
        .await,
        "the newer request must land as pending incoming, got {:?}",
        friend_row(&b, &a_master),
    );

    drop(a);
    drop(b);
}

// The mailbox is only as safe as its gate: a master's inbox room name is public, so
// without the ownership proof anyone could join it and read every request the victim
// has not collected yet.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn mailbox_requires_ownership_proof() {
    let _g = test_guard();
    let relay = MockRelay::new();

    let b_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(81));
    let b_master = b_master_kp.peer_id();
    let b_dev2 = NativeKeypair::from_secret_bytes(&seed_bytes(82)).peer_id();
    let stranger_master = NativeKeypair::from_secret_bytes(&seed_bytes(83));
    let stranger_dev = NativeKeypair::from_secret_bytes(&seed_bytes(84)).peer_id();
    let inbox = format!("inbox:{b_master}");

    // A depositor drops one frame addressed at B's MASTER. B is absent, so the
    // relay buffers it under the master exactly as it would in production.
    let depositor = raw_socket(&relay, "depositor-device");
    depositor.cmd_tx.send(WsCommand::JoinRoom { room_code: inbox.clone() }).unwrap();
    depositor.cmd_tx.send(WsCommand::SendDirect {
        room_code: inbox.clone(),
        target_peer: b_master.clone(),
        data: b"the-request".to_vec(),
    }).unwrap();
    assert!(
        wait_until(5, async || relay.buffered_count(&b_master) == 1).await,
        "precondition: the frame is buffered under the master",
    );

    // 1. A stranger joins the inbox with NO proof. The join succeeds (the room is
    //    not a secret) and hands over nothing.
    let mut stranger = raw_socket(&relay, &stranger_dev);
    stranger.cmd_tx.send(WsCommand::JoinRoom { room_code: inbox.clone() }).unwrap();
    assert!(
        stranger.direct_payloads(600).await.is_empty(),
        "an unproven join must collect NOTHING from the mailbox",
    );

    // 2. The same stranger with a proof it can genuinely sign: its OWN master's
    //    device list. The signature is real, the master is wrong, and the room
    //    check is what refuses it.
    let own_list = super::crypto_handler::build_signed_device_list(
        &stranger_master, 1, vec![stranger_dev.clone()], Vec::new(),
    );
    stranger.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: own_list,
    }).unwrap();
    assert!(
        stranger.direct_payloads(600).await.is_empty(),
        "a valid list for the WRONG master must not open this mailbox",
    );

    // 3. A FORGED proof: B's real master id, signed by nobody holding B's key.
    //    This is the attack the signature exists to stop.
    let mut forged = super::crypto_handler::build_signed_device_list(
        &stranger_master, 9, vec![stranger_dev.clone()], Vec::new(),
    );
    forged.master_peer_id = b_master.clone();
    forged.devices = vec![stranger_dev.clone()];
    stranger.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: forged,
    }).unwrap();
    assert!(
        stranger.direct_payloads(600).await.is_empty(),
        "a forged proof must collect NOTHING",
    );

    // 4. A genuine list of B's, but naming a device that is NOT this socket.
    //    Holding someone's real device list is not owning their inbox.
    let not_us = super::crypto_handler::build_signed_device_list(
        &b_master_kp, 1, vec![b_dev2.clone()], Vec::new(),
    );
    stranger.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: not_us,
    }).unwrap();
    assert!(
        stranger.direct_payloads(600).await.is_empty(),
        "a list that does not name THIS socket must not open the mailbox",
    );

    // 5. B's own second device, with a valid proof naming itself. THIS collects.
    let mut b2 = raw_socket(&relay, &b_dev2);
    let good = super::crypto_handler::build_signed_device_list(
        &b_master_kp, 2, vec![b_dev2.clone()], Vec::new(),
    );
    b2.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: good.clone(),
    }).unwrap();
    assert_eq!(
        b2.direct_payloads(1500).await,
        vec![b"the-request".to_vec()],
        "a proven owner collects the mailbox",
    );

    // 6. TTL-only, NOT delete-on-replay. Every sibling device has to be able to
    //    collect the same request on its own next boot, so reading can never
    //    consume it. The receiver's friends-row dedup is what makes the repeat
    //    harmless — do NOT "fix" this by tracking per-socket delivery.
    assert_eq!(
        relay.buffered_count(&b_master), 1,
        "the mailbox must survive being read",
    );
    b2.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: good,
    }).unwrap();
    assert_eq!(
        b2.direct_payloads(1500).await,
        vec![b"the-request".to_vec()],
        "a rejoin re-collects it",
    );

    // 7. A device the master has REVOKED is not an owner any more.
    let revoked_list = super::crypto_handler::build_signed_device_list(
        &b_master_kp, 3, vec![b_dev2.clone()], vec![b_dev2.clone()],
    );
    let mut b2_revoked = raw_socket(&relay, &b_dev2);
    b2_revoked.cmd_tx.send(WsCommand::JoinInbox {
        room_code: inbox.clone(),
        proof: revoked_list,
    }).unwrap();
    assert!(
        b2_revoked.direct_payloads(600).await.is_empty(),
        "a revoked device must not open the mailbox",
    );
}

// The two freshness rules are independent, and that is the point: the carried rule
// has to be days long, and widening the LIVE rule to reach it would hand every peer a
// days-long key-exchange replay window.

#[test]
fn carried_bundle_freshness_is_its_own_rule() {
    use super::crypto_handler::{
        build_signed_device_list, carried_bundle_signing_payload, key_bundle_signing_payload,
        key_exchange_now, signed_carried_bundle, verify_carried_bundle, verify_key_exchange,
        KeyExchangeAuth, KEY_EXCHANGE_SKEW_SECS,
    };
    use super::types::CarriedBundle;
    use base64::Engine;

    let b64 = base64::engine::general_purpose::STANDARD;
    let sender_master = NativeKeypair::from_secret_bytes(&seed_bytes(91));
    let sender_device = NativeKeypair::from_secret_bytes(&seed_bytes(92));
    let sender_device_id = sender_device.peer_id();
    let our_master = NativeKeypair::from_secret_bytes(&seed_bytes(93)).peer_id();
    let our_device = NativeKeypair::from_secret_bytes(&seed_bytes(94)).peer_id();
    let list = build_signed_device_list(
        &sender_master, 1, vec![sender_device_id.clone()], Vec::new(),
    );
    let now = key_exchange_now();

    // A CARRIED bundle three days old is fine: it has been sitting in a mailbox,
    // which is the entire feature. Replay protection here is the one-time key.
    let three_days = now - 3 * 24 * 3600;
    let payload = carried_bundle_signing_payload(
        &sender_device_id, &our_master, "ik", "otk", three_days,
    );
    let old_carried = CarriedBundle {
        identity_key: "ik".to_string(),
        one_time_key: "otk".to_string(),
        to_master: our_master.clone(),
        ts: three_days,
        sig_b64: b64.encode(sender_device.sign(payload.as_bytes())),
        device_pk_b64: b64.encode(sender_device.public_key_protobuf()),
    };
    assert!(
        verify_carried_bundle(&our_master, &list, &old_carried),
        "a three-day-old CARRIED bundle must still be accepted",
    );

    // A LIVE bundle six minutes old is still refused. Same key material, same
    // signer, different rule — which stays true only because they are separate
    // functions with separate constants.
    let six_min_ago = now - 360;
    assert!(six_min_ago < now - KEY_EXCHANGE_SKEW_SECS);
    let live_payload = key_bundle_signing_payload(
        &sender_device_id, &our_device, "ik", "otk", six_min_ago,
    );
    let sig = b64.encode(sender_device.sign(live_payload.as_bytes()));
    let pk = b64.encode(sender_device.public_key_protobuf());
    assert_eq!(
        verify_key_exchange(
            &sender_device_id, &our_device, Some(&our_device), Some(six_min_ago),
            Some(&sig), Some(&pk), &live_payload,
        ),
        KeyExchangeAuth::Invalid,
        "the LIVE key-exchange window must NOT have been widened",
    );

    // The domains cannot be crossed either: a carried bundle's signature is over
    // a different message, so it can never be replayed at the live verifier.
    let fresh = signed_carried_bundle(
        &sender_device, &sender_device_id, &our_master,
        "ik".to_string(), "otk".to_string(),
    );
    let as_live = key_bundle_signing_payload(
        &sender_device_id, &our_master, "ik", "otk", fresh.ts,
    );
    assert_eq!(
        verify_key_exchange(
            &sender_device_id, &our_master, Some(&our_master), Some(fresh.ts),
            Some(&fresh.sig_b64), Some(&fresh.device_pk_b64), &as_live,
        ),
        KeyExchangeAuth::Invalid,
        "a carried bundle reflected at the live verifier must fail",
    );
}

// Re-depositing on every connect is the design, since a relay buffer has a TTL and
// dies with a relay restart, so the receiver dedups on the friends row and the bundle
// is minted ONCE per target so every copy carries the same one-time key.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn mailbox_redeposit_dedups() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 101;
    const A_DEV: u8 = 102;
    const B_MASTER: u8 = 103;
    const B_DEV: u8 = 104;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(wait_until(10, async || relay.buffered_count(&b_master) > 0).await);

    for i in 0..5u64 {
        relay.set_online(&a_device, false);
        relay.set_online(&a_device, true);
        let want = (2 + i) as usize;
        assert!(
            wait_until(10, async || relay.buffered_count(&b_master) >= want).await,
            "reconnect {i} must re-deposit, mailbox holds {}",
            relay.buffered_count(&b_master),
        );
        drain_events(&mut a);
    }
    let deposits = relay.buffered_count(&b_master);
    assert!(deposits >= 6, "expected repeated deposits, got {deposits}");

    relay.set_online(&a_device, false);
    drain_events(&mut a);

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { .. })
        })
        .await,
        "B must see the request",
    );

    let rows: Vec<_> = b.store().load_friends(None).unwrap_or_default()
        .into_iter()
        .filter(|(pid, _, _, _, _)| super::resolver::same_identity(pid, &a_master))
        .collect();
    assert_eq!(
        rows.len(), 1,
        "duplicate deposits must collapse to ONE friend row, got {rows:?}",
    );
    assert_eq!(rows[0].1, "pending");
    assert_eq!(rows[0].2, "incoming");

    // And ONE usable session: every copy carried the same minted one-time key, so
    // accepting builds exactly one Olm session instead of spending a key per copy
    // and stranding the requester on a ratchet it cannot answer.
    b.cmd_tx
        .send(NodeCommand::AcceptFriendRequest { peer_id: a_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || b.olm_status(&a_device).await != "absent").await,
        "accepting must build the session from the carried bundle",
    );

    drop(a);
    drop(b);
}

// ---------------------------------------------------------------------------
// Blocking is receiver-side self-protection, and a mailbox is a new way in. The
// guard has to run on the replayed path too, BEFORE any row, event or ingest.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn blocked_sender_mailbox_request_dropped() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 111;
    const A_DEV: u8 = 112;
    const B_MASTER: u8 = 113;
    const B_DEV: u8 = 114;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    super::blocklist::block(&a_master);

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "the deposit still happens — blocking is enforced by the RECEIVER",
    );
    relay.set_online(&a_device, false);
    drain_events(&mut a);

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    // An absence has no condition to poll, so this waits out a real window.
    let leaked = wait_event(&mut b, std::time::Duration::from_secs(5), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { .. })
    })
    .await;
    assert!(!leaked, "a blocked sender's mailbox request must emit NO event");
    assert_eq!(
        friend_row(&b, &a_master), None,
        "and must leave NO friends row",
    );

    super::blocklist::clear_for_test();
    drop(a);
    drop(b);
}

// DECLINE STICKS END TO END. The tombstone alone only made the DECLINER quiet: the
// reject was a best-effort live send, so a requester who was offline never learned,
// stayed "pending outgoing" forever and re-deposited on every reconnect. The decline
// now rides the requester's OWN master-keyed mailbox, the only leg that reaches
// somebody who is simply not here. Nobody is online together until the final re-add.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_reject_delivered_with_no_overlap() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 131;
    const A_DEV: u8 = 132;
    const B_MASTER: u8 = 133;
    const B_DEV: u8 = 134;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );
    let original_at = friend_row_full(&a, &b_master)
        .expect("A must hold a pending outgoing row")
        .2;

    relay.set_online(&a_device, false);
    drain_events(&mut a);

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let b_device = b.device_id.clone();
    let mut requester_id = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                requester_id = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must see the mailbox request on its first boot",
    );
    b.cmd_tx
        .send(NodeCommand::RejectFriendRequest {
            peer_id: requester_id.expect("captured requester id"),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || {
            friend_row(&b, &a_master).map(|(s, _)| s) == Some("declined".to_string())
        })
        .await,
        "reject must write a sticky declined tombstone, got {:?}",
        friend_row(&b, &a_master),
    );
    // THE ROOT FIX: the decline is deposited into the REQUESTER's own mailbox,
    // symmetric to the request. Without this leg an absent requester never learns.
    assert!(
        wait_until(10, async || {
            buffered_reject_ats(&relay, &a_master).contains(&original_at)
        })
        .await,
        "the decline must be waiting in A's mailbox, naming the request it answers \
         ({original_at}); mailbox holds {:?}",
        buffered_reject_ats(&relay, &a_master),
    );

    relay.set_online(&b_device, false);
    drain_events(&mut b);
    // HARNESS HONESTY: the resolver is process-GLOBAL in the test binary, so every node
    // sees every device-to-master link and `resolve(b_device)` succeeds for a node that
    // in the field has never heard of B. That gap is what hid the field bug, so forget
    // the link and make attribution come from the list the reject carries.
    super::resolver::forget(&b_device);
    relay.set_online(&a_device, true);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(20), |ev| {
            matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
        })
        .await,
        "A must surface the decline it collected from its own mailbox",
    );
    assert!(
        wait_until(10, async || friend_row(&a, &b_master).is_none()).await,
        "the declined outgoing request must be gone from A's books, got {:?}",
        friend_row(&a, &b_master),
    );
    let twice = wait_event(&mut a, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
    })
    .await;
    assert!(!twice, "a replayed decline must not re-emit FriendRequestRejected");

    // 5. And A stops RE-DEPOSITING. This is the half that made the decline
    //    un-stickable: every reconnect refreshed the request in B's mailbox, so B
    //    saw it again forever. Bounce A and assert the depth does not move.
    let deposits = relay.buffered_count(&b_master);
    relay.set_online(&a_device, false);
    relay.set_online(&a_device, true);
    // An absence has no condition to poll; ride wait_event's timeout as the window.
    let _ = wait_event(&mut a, std::time::Duration::from_secs(3), |_| false).await;
    assert_eq!(
        relay.buffered_count(&b_master), deposits,
        "a declined request must never be re-deposited on reconnect",
    );

    // 6. A goes dark; B boots into a mailbox that STILL holds A's request (TTL,
    //    not delete-on-read). The decline must swallow it silently. B's own node
    //    needs its own device -> master mapping back for that.
    relay.set_online(&a_device, false);
    drain_events(&mut a);
    super::resolver::update(&b_device, &b_master);
    relay.set_online(&b_device, true);
    let resurrected = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(
        !resurrected,
        "the stale re-delivery must NOT resurface as an incoming request",
    );
    assert_eq!(
        friend_row(&b, &a_master),
        Some(("declined".to_string(), String::new())),
        "and the tombstone must still stand",
    );

    // 7. Declining is not a permanent block: a genuine re-add (a fresh
    //    requested_at) must reach B and show. The only step where both are up.
    drain_events(&mut b);
    relay.set_online(&a_device, true);
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
                if super::resolver::resolve(peer_id) == a_master)
        })
        .await,
        "a NEWER request must cross the tombstone and show again",
    );
    assert!(
        wait_until(10, async || {
            matches!(
                friend_row_full(&b, &a_master)
                    .as_ref()
                    .map(|(s, d, r)| (s.as_str(), d.as_str(), *r)),
                Some(("pending", "incoming", r)) if r > original_at
            )
        })
        .await,
        "the re-add must land as pending incoming with a NEWER requested_at than \
         the tombstone's ({original_at}), got {:?}",
        friend_row_full(&b, &a_master),
    );

    drop(a);
    drop(b);
}

// The mailbox has a TTL, so a decline can EXPIRE before the requester next boots. The
// requester then re-deposits, the decliner swallows it against the tombstone, and
// without a re-arm nobody ever answers again. Every swallow therefore RE-ARMS the
// answer, once per requester per connection.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn declined_reject_is_resent_when_stale_redeposit_returns() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 141;
    const A_DEV: u8 = 142;
    const B_MASTER: u8 = 143;
    const B_DEV: u8 = 144;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );
    let original_at = friend_row_full(&a, &b_master)
        .expect("A must hold a pending outgoing row")
        .2;
    relay.set_online(&a_device, false);
    drain_events(&mut a);

    // 2. Clear B's mailbox and hand it the request DIRECTLY. The re-arm is bounded to one
    // deposit per requester, so the test must own exactly when the first swallow happens;
    // a mailbox replaying twice on one boot would spend the budget here.
    relay.expire_mailbox(&b_master);
    let a_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER));
    let a_list = super::crypto_handler::build_signed_device_list(
        &a_master_kp, 1, vec![a_device.clone()], Vec::new(),
    );
    let request_frame = serde_json::to_vec(&super::types::HavenMessage::FriendRequest {
        requested_at: original_at,
        carried_bundle: None,
        device_list: Some(a_list),
        carried_profile: None,
    })
    .unwrap();

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let b_device = b.device_id.clone();
    let inbox = format!("inbox:{b_master}");
    relay.inject_direct(&inbox, &a_device, &b_device, request_frame.clone());
    let mut requester_id = None;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            if let NetworkEvent::FriendRequestReceived { peer_id } = ev {
                requester_id = Some(peer_id.clone());
                true
            } else {
                false
            }
        })
        .await,
        "B must see the request",
    );
    b.cmd_tx
        .send(NodeCommand::RejectFriendRequest {
            peer_id: requester_id.expect("captured requester id"),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || {
            buffered_reject_ats(&relay, &a_master).contains(&original_at)
        })
        .await,
        "the decline must reach A's mailbox first time round",
    );
    relay.set_online(&b_device, false);
    drain_events(&mut b);

    relay.expire_mailbox(&a_master);
    assert_eq!(relay.buffered_count(&a_master), 0, "precondition: the decline expired");

    let deposits_before = relay.buffered_count(&b_master);
    relay.set_online(&a_device, true);
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > deposits_before).await,
        "A cannot have learned anything, so it re-deposits its still-pending request",
    );
    assert!(
        matches!(
            friend_row(&a, &b_master).as_ref().map(|(s, d)| (s.as_str(), d.as_str())),
            Some(("pending", "outgoing"))
        ),
        "A's request is still pending — the decline it never saw cannot have landed, got {:?}",
        friend_row(&a, &b_master),
    );
    relay.set_online(&a_device, false);
    drain_events(&mut a);

    // 6. B boots into the re-deposited request. It stays swallowed (the tombstone
    //    holds), AND the answer is re-armed into A's now-empty mailbox.
    relay.set_online(&b_device, true);
    let resurrected = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(!resurrected, "the tombstone must still swallow the re-deposit");
    assert!(
        wait_until(10, async || {
            buffered_reject_ats(&relay, &a_master).contains(&original_at)
        })
        .await,
        "swallowing a re-deposit must RE-SEND the decline, naming the same request          ({original_at}); mailbox holds {:?}",
        buffered_reject_ats(&relay, &a_master),
    );

    // 7. And it re-arms on the NEXT reconnect too: the re-send set is connection-scoped,
    // not process-scoped, because the mailbox only replays on an inbox rejoin. Otherwise
    // a decliner whose process stays up answers a returning requester once, ever.
    relay.expire_mailbox(&a_master);
    assert_eq!(
        relay.buffered_count(&a_master), 0,
        "precondition: the second decline expired too",
    );
    drain_events(&mut b);
    relay.set_online(&b_device, false);
    relay.set_online(&b_device, true);
    relay.inject_direct(&inbox, &a_device, &b_device, request_frame.clone());
    assert!(
        wait_until(10, async || {
            buffered_reject_ats(&relay, &a_master).contains(&original_at)
        })
        .await,
        "a reconnect must re-arm the decline re-send, got {:?}",
        buffered_reject_ats(&relay, &a_master),
    );

    relay.set_online(&b_device, false);
    drain_events(&mut b);
    // HARNESS HONESTY: the resolver is process-GLOBAL in the test binary, so every node
    // sees every device-to-master link and `resolve(b_device)` succeeds for a node that
    // in the field has never heard of B. Forget the link so attribution must come from
    // the list the reject carries; it is restored below.
    super::resolver::forget(&b_device);
    relay.set_online(&a_device, true);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(20), |ev| {
            matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
        })
        .await,
        "A must finally learn it was declined",
    );
    assert!(
        wait_until(10, async || friend_row(&a, &b_master).is_none()).await,
        "and drop the request, got {:?}",
        friend_row(&a, &b_master),
    );
    let twice = wait_event(&mut a, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
    })
    .await;
    assert!(!twice, "exactly one FriendRequestRejected, however many copies replay");

    drop(a);
    drop(b);
}

// A re-deposit must be the SAME request, not a fresh one: `requested_at` is what
// every dedup and anti-downgrade decision compares against, so a new stamp would make
// a declined request look strictly newer and resurface forever.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn redeposit_keeps_original_requested_at_and_dedups() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 151;
    const A_DEV: u8 = 152;
    const B_MASTER: u8 = 153;
    const B_DEV: u8 = 154;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[]).await;
    let a_device = a.device_id.clone();
    a.cmd_tx
        .send(NodeCommand::SendFriendRequest { peer_id: b_master.clone() })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || relay.buffered_count(&b_master) > 0).await,
        "request must reach B's mailbox",
    );
    let original_at = friend_row_full(&a, &b_master)
        .expect("A must hold a pending outgoing row")
        .2;

    for i in 0..3usize {
        let before = relay.buffered_count(&b_master);
        relay.set_online(&a_device, false);
        relay.set_online(&a_device, true);
        assert!(
            wait_until(10, async || relay.buffered_count(&b_master) > before).await,
            "reconnect {i} must re-deposit",
        );
        drain_events(&mut a);
    }

    let ats = buffered_request_ats(&relay, &b_master);
    assert!(ats.len() >= 4, "expected a copy per connect, got {ats:?}");
    assert!(
        ats.iter().all(|at| *at == original_at),
        "every re-deposit must carry the ORIGINAL requested_at {original_at}, got {ats:?}",
    );

    relay.set_online(&a_device, false);
    drain_events(&mut a);
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
                if super::resolver::resolve(peer_id) == a_master)
        })
        .await,
        "B must see the request",
    );
    let twice = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(!twice, "the other copies must dedup, not re-notify");

    drop(a);
    drop(b);
}

// The stored `requested_at` on a pending row has to ADVANCE. The upsert kept whatever
// was written first, so a genuinely newer request still measured against the OLD
// timestamp, fell through the dedup guard and re-notified on every replay.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn newer_request_advances_stored_requested_at() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const B_MASTER: u8 = 163;
    const B_DEV: u8 = 164;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    // A is a bare identity here: the point is the RECEIVER's dedup arithmetic, so
    // its requests are injected as a real sender's frames, timestamps and all.
    let a_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(161));
    let a_master = a_master_kp.peer_id();
    let a_device = NativeKeypair::from_secret_bytes(&seed_bytes(162)).peer_id();
    let a_list = super::crypto_handler::build_signed_device_list(
        &a_master_kp, 1, vec![a_device.clone()], Vec::new(),
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;
    let inbox = format!("inbox:{b_master}");
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let t0 = now_ms;
    let t2 = now_ms + 60_000;
    let request_at = |at: i64| {
        serde_json::to_vec(&super::types::HavenMessage::FriendRequest {
            requested_at: at,
            carried_bundle: None,
            device_list: Some(a_list.clone()),
            carried_profile: None,
        })
        .unwrap()
    };

    relay.inject_direct(&inbox, &a_device, &b.device_id, request_at(t0));
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
                if super::resolver::resolve(peer_id) == a_master)
        })
        .await,
        "B must show the first request",
    );

    drain_events(&mut b);
    relay.inject_direct(&inbox, &a_device, &b.device_id, request_at(t2));
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
                if super::resolver::resolve(peer_id) == a_master)
        })
        .await,
        "a strictly newer request must show again",
    );
    assert!(
        wait_until(10, async || {
            friend_row_full(&b, &a_master).map(|(_, _, r)| r) == Some(t2)
        })
        .await,
        "the stored requested_at must ADVANCE to the newer request, got {:?}",
        friend_row_full(&b, &a_master),
    );

    // 3. The SAME T2 arriving again (the mailbox replays on every boot) must now
    //    measure against T2, not T0, and be swallowed.
    drain_events(&mut b);
    relay.inject_direct(&inbox, &a_device, &b.device_id, request_at(t2));
    let renotified = wait_event(&mut b, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestReceived { peer_id }
            if super::resolver::resolve(peer_id) == a_master)
    })
    .await;
    assert!(
        !renotified,
        "a re-delivery of the SAME request must not re-notify — the stored \
         requested_at never advanced, so every replay looked new",
    );

    drop(b);
}

// A decline travels through a mailbox, so it can arrive late, out of order or
// replayed for the whole TTL. A reject therefore only ever acts on the request it
// NAMES: an older stamp, or the legacy no-stamp wire form, must never become a remote
// un-friend primitive. The positive half runs last because it is destructive.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn stale_reject_never_deletes_an_accepted_friendship() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 171;
    const A_DEV: u8 = 172;
    const B_MASTER: u8 = 173;
    const B_DEV: u8 = 174;
    let b_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER));
    let b_master = b_master_kp.peer_id();
    let b_device = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    // B's own master-signed device list, exactly what its reject carries. Every
    // frame below is attributed through THIS, not through the resolver.
    let b_list = super::crypto_handler::build_signed_device_list(
        &b_master_kp, 1, vec![b_device.clone()], Vec::new(),
    );

    // A and B are already friends. Re-seed the row so it carries a REAL request
    // stamp: the freshness compare is the whole gate, and the harness's seeded
    // friendships are stamped 0, against which nothing is stale.
    const STORED: i64 = 1_700_000_000_000;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    {
        let store = a.store();
        store.remove_friend(&b_master).unwrap();
        store.save_friend(&b_master, "accepted", "", STORED).unwrap();
    }
    assert_eq!(
        friend_row_full(&a, &b_master),
        Some(("accepted".to_string(), String::new(), STORED)),
        "precondition: an accepted friendship stamped with the request it came from",
    );
    drain_events(&mut a);

    let room = super::types::dm_room_code(&a.master_id, &b_master);
    // A copy of a reject for an OLDER request than the one we accepted: a cancel +
    // re-add mints a strictly newer stamp, and the accepted row freezes at it, so
    // this is exactly what a replay out of a 3-day mailbox looks like.
    let stale = serde_json::to_vec(
        &super::types::HavenMessage::FriendReject {
            requested_at: STORED - 1,
            device_list: Some(b_list.clone()),
        },
    ).unwrap();
    // The legacy wire form from a pre-2026-08-29 client: no requested_at at all,
    // i.e. "decline whatever is pending". It names no request, so it can only ever
    // touch a still-pending one; an old client is not a downgrade path.
    let legacy = br#"{"type":"friend_reject"}"#.to_vec();
    // Both attribution paths: the stale frame rides B's signed list (cryptographic
    // attribution, so it finds the row without the two ever having met), and the
    // legacy frame comes bare from the master id (resolver attribution, the only
    // thing a pre-carried-list client can offer). Neither may touch the row.
    relay.inject_direct(&room, &b_device, &a.device_id, stale.clone());
    relay.inject_direct(&room, &b_master, &a.device_id, legacy.clone());

    let unfriended = wait_event(&mut a, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestRejected { .. })
    })
    .await;
    assert!(
        !unfriended,
        "a reject that names no live request, or an older one, must emit nothing",
    );
    assert_eq!(
        friend_row_full(&a, &b_master),
        Some(("accepted".to_string(), String::new(), STORED)),
        "and the accepted friendship must survive untouched",
    );

    // THE POSITIVE HALF, destructive so last. Both sides requested each other and
    // auto-converged; B's reject carries the stamp our accepted row froze at, so it
    // answers the request this friendship is made of and must land.
    drain_events(&mut a);
    let answered = serde_json::to_vec(
        &super::types::HavenMessage::FriendReject {
            requested_at: STORED,
            device_list: Some(b_list.clone()),
        },
    ).unwrap();
    relay.inject_direct(&room, &b_device, &a.device_id, answered);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
        })
        .await,
        "a reject naming the accepted row's OWN request must be honoured",
    );
    assert!(
        wait_until(10, async || friend_row(&a, &b_master).is_none()).await,
        "and the friendship must be gone, got {:?}",
        friend_row(&a, &b_master),
    );
    let twice = wait_event(&mut a, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestRejected { .. })
    })
    .await;
    assert!(!twice, "exactly one FriendRequestRejected");

    drop(a);
}


// The carried list is ATTRIBUTION, so it is a trust boundary: it decides which friend
// row a reject deletes. A list that is present but bad must be a REJECTED message,
// never a quiet downgrade to the resolver, since `if list.is_some()` is the bypass.
// Checked against a resolver that WOULD have found the row.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests vs the global resolver
async fn friend_reject_with_bad_carried_list_is_dropped() {
    let _g = test_guard();
    super::blocklist::clear_for_test();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const A_MASTER: u8 = 181;
    const A_DEV: u8 = 182;
    const B_MASTER: u8 = 183;
    const B_DEV: u8 = 184;
    let b_master_kp = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER));
    let b_master = b_master_kp.peer_id();
    let b_device = NativeKeypair::from_secret_bytes(&seed_bytes(B_DEV)).peer_id();
    let b_unlisted = NativeKeypair::from_secret_bytes(&seed_bytes(185)).peer_id();
    let b_list = super::crypto_handler::build_signed_device_list(
        &b_master_kp, 1, vec![b_device.clone()], Vec::new(),
    );

    const STORED: i64 = 1_700_000_000_000;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    {
        let store = a.store();
        store.remove_friend(&b_master).unwrap();
        store.save_friend(&b_master, "accepted", "", STORED).unwrap();
    }
    // The resolver KNOWS the unlisted device speaks for B. Every drop below is
    // therefore the carried-list gate refusing, not attribution failing to resolve.
    super::resolver::update(&b_unlisted, &b_master);
    assert_eq!(
        super::resolver::resolve(&b_unlisted), b_master,
        "precondition: the resolver would have found the row on its own",
    );
    drain_events(&mut a);

    let room = super::types::dm_room_code(&a.master_id, &b_master);
    let reject_with = |list: Option<super::types::SignedDeviceList>| {
        serde_json::to_vec(&super::types::HavenMessage::FriendReject {
            requested_at: STORED,
            device_list: list,
        })
        .unwrap()
    };

    // (1) Sender device is NOT in the list it carries. A valid list captured off
    //     the wire must not let any other device speak for that identity.
    relay.inject_direct(&room, &b_unlisted, &a.device_id, reject_with(Some(b_list.clone())));
    // (2) A RELABELLED list: B's signed payload wearing a stranger's master id.
    //     The pubkey -> peer_id binding inside verify_device_list is what stops it.
    let mut stolen = b_list.clone();
    stolen.master_peer_id = NativeKeypair::from_secret_bytes(&seed_bytes(186)).peer_id();
    relay.inject_direct(&room, &b_device, &a.device_id, reject_with(Some(stolen)));
    let mut tampered = b_list.clone();
    tampered.devices.push(b_unlisted.clone());
    relay.inject_direct(&room, &b_unlisted, &a.device_id, reject_with(Some(tampered)));

    let unfriended = wait_event(&mut a, std::time::Duration::from_secs(3), |ev| {
        matches!(ev, NetworkEvent::FriendRequestRejected { .. })
    })
    .await;
    assert!(
        !unfriended,
        "a reject whose carried list does not bind its sender must emit nothing",
    );
    assert_eq!(
        friend_row_full(&a, &b_master),
        Some(("accepted".to_string(), String::new(), STORED)),
        "and must leave the friendship untouched",
    );

    // (4) CONTROL, and destructive so it runs last: the SAME frame from the SAME
    //     device with NO list at all is a pre-carried-list client, falls back to
    //     the resolver, and lands. The only difference from (1) is the bad list --
    //     which is the proof that the drops above were the gate, not the lookup.
    drain_events(&mut a);
    relay.inject_direct(&room, &b_unlisted, &a.device_id, reject_with(None));
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::FriendRequestRejected { peer_id } if *peer_id == b_master)
        })
        .await,
        "a legacy reject that resolves to the friend must still be honoured",
    );
    assert!(
        wait_until(10, async || friend_row(&a, &b_master).is_none()).await,
        "and delete the row, got {:?}",
        friend_row(&a, &b_master),
    );

    drop(a);
}

// PARKED JOINS. A join into a server whose members are ALL offline used to fail on
// the 15s timeout. It now PARKS: the request is persisted locally and deposited into
// the server room's `~join` ring, the next member back reads the ring, admits or
// rejects, and publishes its answer there for the joiner's next connect. The request
// carries a signed device list because a member serving a parked request has never
// been online with the joiner, so `resolve` would hand back a DEVICE id; the tests
// call `resolver::forget` to hold that shape against a process-global resolver.

/// Every `~join` ring frame for `server_id`, parsed, paired with the
/// relay-stamped sender device. The relay-side truth behind a parked join.
fn join_ring(relay: &MockRelay, server_id: &str) -> Vec<(String, super::types::HavenMessage)> {
    relay
        .topic_frames(server_id, super::types::JOIN_TOPIC)
        .into_iter()
        .filter_map(|(from, data)| {
            serde_json::from_slice::<super::types::HavenMessage>(&data)
                .ok()
                .map(|m| (from, m))
        })
        .collect()
}

/// How many parked join REQUESTS `device` has in the room's ring.
fn ring_requests_from(relay: &MockRelay, server_id: &str, device: &str) -> usize {
    join_ring(relay, server_id)
        .iter()
        .filter(|(from, msg)| {
            from == device && matches!(msg, super::types::HavenMessage::ServerJoinRequest { .. })
        })
        .count()
}

/// Wait until `device`'s parked request is actually IN the room's ring.
///
/// `ServerJoinParked` fires the instant the deposit is QUEUED, and taking the node
/// offline in between makes the mock drop the still-queued frame, exactly as a dead
/// socket does. So wait for the frame, never for the event.
async fn expect_ring_request(relay: &MockRelay, server_id: &str, device: &str, count: usize) {
    let ok = wait_until(15, async || {
        ring_requests_from(relay, server_id, device) == count
    })
    .await;
    assert!(
        ok,
        "the join ring for {} must hold {} request(s) from {}, got {}",
        server_id,
        count,
        device,
        ring_requests_from(relay, server_id, device),
    );
}

/// Wait until `from_device`'s verdict on `joiner_master` is in the room's ring.
///
/// A node applies `MemberAdded` and only then queues the frame that publishes the
/// resolution, so reading `join_ring` once at that moment is a race. Polling is free
/// here: the inspector is a mutex read, not a DB open.
async fn expect_ring_resolution(
    relay: &MockRelay,
    server_id: &str,
    from_device: &str,
    joiner_master: &str,
    admitted: bool,
) {
    let ok = wait_until(10, async || {
        join_ring(relay, server_id).iter().any(|(from, msg)| {
            from == from_device
                && matches!(
                    msg,
                    super::types::HavenMessage::ServerJoinResolved { joiner_master: jm, admitted: ad, .. }
                        if *ad == admitted && jm == joiner_master
                )
        })
    })
    .await;
    assert!(
        ok,
        "the join ring for {} must hold {}'s {} verdict on {}, got {:?}",
        server_id,
        from_device,
        if admitted { "admission" } else { "refusal" },
        joiner_master,
        join_ring(relay, server_id),
    );
}

/// Wait until `device`'s request in the ring is the PARKED copy. Same race as
/// the two above: the flag is only observable once the frame has landed.
async fn expect_ring_parked_request(relay: &MockRelay, server_id: &str, device: &str) {
    let ok = wait_until(10, async || {
        join_ring(relay, server_id).iter().any(|(from, msg)| {
            from == device
                && matches!(
                    msg,
                    super::types::HavenMessage::ServerJoinRequest { parked, .. } if *parked
                )
        })
    })
    .await;
    assert!(
        ok,
        "the join ring for {server_id} must hold a PARKED request from {device}, got {:?}",
        join_ring(relay, server_id),
    );
}

/// Barrier: every ws command `node` had queued when this is called has now been
/// processed by the relay.
///
/// A node's outbound commands ride ONE channel drained in order, so joining a
/// throwaway room and waiting to appear in it proves everything queued earlier has
/// landed. That is what makes a NEGATIVE assertion about relay state honest. The
/// caller must already have observed that the handler under test RAN.
async fn expect_relay_drained(relay: &MockRelay, node: &TestNode, tag: &str) {
    let room = format!("barrier:{}:{}", node.device_id, tag);
    node.cmd_tx
        .send(NodeCommand::JoinRoom { room_code: room.clone() })
        .await
        .unwrap();
    let ok = wait_until(15, async || relay.room_devices(&room).contains(&node.device_id)).await;
    assert!(ok, "the relay never drained {}'s queued commands (barrier {room})", node.device_id);
}

/// Take one node offline and wait until the relay agrees it has left `room`.
async fn go_offline(relay: &MockRelay, node: &TestNode, room: &str) {
    relay.set_online(&node.device_id, false);
    assert!(
        wait_until(10, async || !relay.room_devices(room).contains(&node.device_id)).await,
        "{} must leave room {} when its socket dies, got {:?}",
        node.device_id,
        room,
        relay.room_devices(room),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_join_completes_with_zero_overlap() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 55; // owner
    const A_MASTER: u8 = 56; // plain member: the one that comes back and admits
    const B_MASTER: u8 = 57; // stranger holding an invite
    // B's transport id is NOT its master id, which is what every real install looks like
    // and also keeps the mock honest: it keys the offline buffer and the master mailbox
    // by the same string, so device == master gets its frames delivered twice.
    const B_DEVICE: u8 = 227;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Cold Start").await;
    let general = general_channel_of(&server_id);

    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "member A joins normally while the owner is online"
    );
    expect_mls_group(&[&o, &a], &server_id, 20).await;

    // --- Everybody goes dark. A must OBSERVE the owner's departure first, or
    // its own stale `ws_room_peers` elects the unreachable owner later. ---
    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop, or it elects a ghost coordinator on its return"
    );
    go_offline(&relay, &a, &server_id).await;
    assert!(
        relay.room_devices(&server_id).is_empty(),
        "the server room must be empty, got {:?}",
        relay.room_devices(&server_id),
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEVICE, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    let mut failed = false;
    let parked = wait_event(&mut b, std::time::Duration::from_secs(30), |ev| match ev {
        NetworkEvent::ServerJoinFailed { server_id: sid, .. } if *sid == server_id => {
            failed = true;
            true
        }
        NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id => true,
        _ => false,
    })
    .await;
    assert!(
        parked && !failed,
        "a join into an empty server parks; it must never emit ServerJoinFailed"
    );
    assert_eq!(
        b.pending_joins(),
        vec![(server_id.clone(), "pending".to_string(), String::new())],
        "the park is PERSISTED, so the tile survives a restart"
    );
    assert!(
        !b.servers().contains(&server_id),
        "a parked join must leave no half-built server behind"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    // Rung 2: the parked copy names the LEAF it wants seated as well as the
    // membership it is asking for.
    assert!(
        join_ring(&relay, &server_id).iter().any(|(from, msg)| from == &b.device_id
            && matches!(
                msg,
                super::types::HavenMessage::ServerJoinRequest { parked: true, key_package: Some(_), .. }
            )),
        "the parked request must carry B's KeyPackage, got {:?}",
        join_ring(&relay, &server_id),
    );

    go_offline(&relay, &b, &server_id).await;
    // The harness resolver is PROCESS-GLOBAL, so without this A could attribute
    // B's device from a link no real member could possibly hold. Forgetting it
    // makes the carried signed device list the only thing that can work.
    super::resolver::forget(&b.device_id);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "A must admit B from the ring, keyed by B's MASTER, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    // The ring is RELAY state and the wait above was on NODE state: A applies
    // MemberAdded and only then queues the publish, so both of these have to be
    // waited for, not read.
    expect_ring_parked_request(&relay, &server_id, &b.device_id).await;
    expect_ring_resolution(&relay, &server_id, &a.device_id, &b_master, true).await;

    // Rung 2: the admission seated B's LEAF too, out of the KeyPackage the ring
    // copy carried, with B nowhere near.
    expect_mls_leaf(&a, &server_id, &b.device_id, 30).await;
    // And the Welcome for it is WAITING in B's mailbox rather than having been
    // dropped for being unreachable. Relay state after a node-state wait, so
    // this has to be a wait of its own.
    assert!(
        wait_until(20, async || relay
            .buffered_frames(&b.device_id)
            .iter()
            .any(|f| matches!(
                serde_json::from_slice::<super::types::HavenMessage>(f),
                Ok(super::types::HavenMessage::MlsWelcome { server_id: ref sid, .. }) if *sid == server_id
            )))
        .await,
        "a Welcome must be buffered for the absent joiner, got {} frame(s)",
        relay.buffered_frames(&b.device_id).len(),
    );

    // A says something into the channel and goes dark. B has never been online
    // with A, and will not be for the rest of this phase.
    a.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "said before you got here".to_string(),
            message_id: "parked-join-0".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    expect_relay_drained(&relay, &a, "posted-before-return").await;

    go_offline(&relay, &a, &server_id).await;
    relay.set_online(&b.device_id, true);
    let mut saw_admitted = false;
    let joined = wait_event(&mut b, std::time::Duration::from_secs(25), |ev| match ev {
        NetworkEvent::PendingJoinUpdated { server_id: sid, state, .. }
            if *sid == server_id && state == "admitted" =>
        {
            saw_admitted = true;
            false
        }
        NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id => true,
        _ => false,
    })
    .await;
    assert!(joined, "B completes its join from the buffered snapshot with nobody online");
    assert!(saw_admitted, "the tile is told it was admitted BEFORE ServerJoined");
    assert!(b.servers().contains(&server_id), "B holds the server");
    assert!(
        b.server_state(&server_id).map(|s| !s.channels.is_empty()).unwrap_or(false),
        "B holds the channel list, not just a membership row"
    );
    assert!(b.pending_joins().is_empty(), "a completed join deletes its row");

    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(40), |ev| matches!(
            ev, NetworkEvent::PendingJoinUpdated { server_id: sid, state, .. }
                if *sid == server_id && state == "ready"
        ))
        .await,
        "the tile flips to ready off the buffered Welcome, with nobody online"
    );
    assert_eq!(
        relay.online_devices(),
        std::collections::HashSet::from([b.device_id.clone()]),
        "B was the only node online for the whole of that",
    );
    expect_mls_group(&[&b], &server_id, 40).await;
    // The message A sent before B returned. It replays out of the channel ring
    // AFTER the Welcome (the post-Welcome catch-up re-issue): anything that
    // arrived before the leaf existed could not be decrypted and was dropped.
    assert!(
        wait_until(30, async || b
            .channel_messages(&server_id, &general)
            .iter()
            .any(|m| m.text == "said before you got here"))
        .await,
        "B decrypts the backlog it was admitted into, alone, got {:?}",
        b.channel_messages(&server_id, &general).iter().map(|m| m.text.clone()).collect::<Vec<_>>(),
    );

    relay.set_online(&a.device_id, true);
    expect_mls_group(&[&a, &b], &server_id, 40).await;
    drain_events(&mut b);
    a.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "you made it".to_string(),
            message_id: "parked-join-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(20), |ev| matches!(
            ev, NetworkEvent::ChannelMessageReceived { text, .. } if text == "you made it"
        ))
        .await,
        "a parked joiner ends up a full member: it decrypts channel traffic"
    );

    drop(o);
    drop(a);
    drop(b);
}

// A join costs exactly ONE epoch: three members, two live joins, epoch 2. The joiner
// used to send its KeyPackage TWICE, and two copies straddling a batch tick are a
// remove + re-add whose removal commit evicts the leaf the first Welcome granted;
// the eviction then asked for a third, landing a clean three-member join at epoch 5.

/// The epoch every node in `nodes` reports for `group_id`, or `None` if they
/// disagree or one of them did not answer. A timed-out snapshot is NOT an
/// answer: `mls_epoch` returns None and so does this.
async fn agreed_epoch(nodes: &[&TestNode], group_id: &str) -> Option<u64> {
    let mut seen: Option<u64> = None;
    for n in nodes {
        let e = n.mls_epoch(group_id).await?;
        match seen {
            None => seen = Some(e),
            Some(v) if v == e => {}
            Some(_) => return None,
        }
    }
    seen
}

/// Wait until `nodes` agree on an epoch for `group_id` AND still agree on the same
/// one two batch ticks later. Returns that epoch.
///
/// "Formed" is not "settled": a remove + re-add treadmill passes through agreement at
/// every rung. There is no state to poll for "no commit happened", which is why that
/// one window is real time rather than a condition.
async fn expect_quiet_group(nodes: &[&TestNode], group_id: &str, secs: u64) -> u64 {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(secs);
    loop {
        if let Some(first) = agreed_epoch(nodes, group_id).await {
            sleep_ms(2500).await;
            if let Some(second) = agreed_epoch(nodes, group_id).await
                && second == first
            {
                return first;
            }
        }
        if tokio::time::Instant::now() >= deadline {
            let mut seen = Vec::new();
            for n in nodes {
                seen.push((n.device_id.clone(), n.mls_epoch(group_id).await));
            }
            panic!("MLS group {group_id} never went quiet within {secs}s, got {seen:?}");
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn three_member_live_join_lands_at_minimal_epoch() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 224; // owner
    const M_MASTER: u8 = 225; // first joiner
    const J_MASTER: u8 = 226; // second joiner
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();
    let j_master = NativeKeypair::from_secret_bytes(&seed_bytes(J_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&m_master, &j_master]).await;
    let m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master, &j_master]).await;
    let j = spawn_node_with_friends(&relay, J_MASTER, J_MASTER, &[&o_master, &m_master]).await;
    expect_dm_pair_ready(&relay, &o, &m, 25).await;
    expect_dm_pair_ready(&relay, &o, &j, 25).await;
    expect_dm_pair_ready(&relay, &m, &j, 25).await;
    // Count what each joiner actually puts on the wire. The epoch is the
    // SYMPTOM; "one KeyPackage per join" is the property, and it is the one a
    // fast machine can still see when both copies happen to land in the same
    // batch and get deduplicated into one add.
    relay.set_recording(&m.device_id, true);
    relay.set_recording(&j.device_id, true);

    let server_id = create_server_and_wait(&mut o, "Minimal Epochs").await;

    let general = general_channel_of(&server_id);

    let mut m = m;
    let mut j = j;
    m.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut m, std::time::Duration::from_secs(25), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "M joins while the owner is online",
    );
    // A real server is not silent while a joiner waits for its leaf, and ANY MLS frame
    // arriving in the one-tick window used to make the joiner mint a SECOND KeyPackage.
    // So post the moment the join lands, which is what a live room does by itself.
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "welcome M".to_string(),
            message_id: "min-epoch-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &server_id, &m.device_id, 30).await;

    j.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut j, std::time::Duration::from_secs(25), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "J joins while the owner is online",
    );
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "welcome J".to_string(),
            message_id: "min-epoch-2".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    expect_mls_leaf(&o, &server_id, &j.device_id, 30).await;

    let epoch = expect_quiet_group(&[&o, &m, &j], &server_id, 60).await;

    let key_packages_sent = |dev: &str| {
        relay
            .recorded_frames(dev)
            .iter()
            .filter(|f| {
                matches!(
                    serde_json::from_slice::<super::types::HavenMessage>(f),
                    Ok(super::types::HavenMessage::MlsKeyPackage { server_id: ref sid, channel_id: None, .. })
                        if *sid == server_id
                )
            })
            .count()
    };
    assert_eq!(
        key_packages_sent(&m.device_id), 1,
        "M asks for a leaf exactly once. A second KeyPackage from the same          device is a remove + re-add the moment the two straddle a batch tick.",
    );
    assert_eq!(
        key_packages_sent(&j.device_id), 1,
        "J asks for a leaf exactly once",
    );
    assert_eq!(
        epoch, 2,
        "a three-member server costs exactly two commits: create is epoch 0, \
         +M is 1, +J is 2. Anything above means a KeyPackage was sent twice and \
         the batch turned it into a remove + re-add.",
    );

    let mut expected = vec![o.device_id.clone(), m.device_id.clone(), j.device_id.clone()];
    expected.sort();
    assert_eq!(
        o.mls_members_checked(&server_id).await,
        Some(expected),
        "the owner's group holds exactly the three devices, no stale leaves",
    );
    assert_eq!(m.mls_epoch(&server_id).await, Some(2), "M is at the same epoch");
    assert_eq!(j.mls_epoch(&server_id).await, Some(2), "J is at the same epoch");

    // --- And a LEAF REPAIR costs exactly two: one remove, one re-add. ---
    //
    // The removal commit reaches J BEFORE the Welcome that puts it back, because phase 1
    // goes out ahead of phase 2. Asking for a leaf on seeing that removal is what turned
    // one repair into a treadmill, so J holds the eviction for a short grace instead.
    let request = serde_json::to_vec(&super::types::HavenMessage::MlsKeyPackageRequest {
        server_id: server_id.clone(),
        channel_id: None,
    })
    .unwrap();
    relay.inject_direct(&server_id, &o.device_id, &j.device_id, request);

    let epoch = expect_quiet_group(&[&o, &m, &j], &server_id, 60).await;
    assert_eq!(
        epoch, 4,
        "a leaf repair is one removal and one add: epoch 2 -> 3 -> 4. Higher \
         means the evicted device asked for another leaf instead of waiting for \
         the Welcome that was already on its way.",
    );
    assert_eq!(
        key_packages_sent(&j.device_id), 2,
        "J put two KeyPackages on the wire in its whole life: the one that \
         joined it, and the one the owner asked for.",
    );
    let mut expected = vec![o.device_id.clone(), m.device_id.clone(), j.device_id.clone()];
    expected.sort();
    assert_eq!(
        o.mls_members_checked(&server_id).await,
        Some(expected),
        "the repaired group still holds exactly the three devices, once each",
    );

    drop(o);
    drop(m);
    drop(j);
}

// A parked join's KeyPackage has to be usable on the other side of a RESTART. Its
// private half lives in OpenMLS storage, which nothing on the mint path used to write
// to disk, so the admitting member seated a leaf the joiner had no key for:
// "NoMatchingKeyPackage", forever. A parked join is measured in days.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_join_key_package_survives_a_restart_before_the_welcome() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 234; // owner
    const B_MASTER: u8 = 235; // stranger holding an invite
    // Distinct device tag, the way every fresh install is: the mock relay keys its
    // offline buffer and its master mailbox by the same string, so device == master gets
    // every buffered server-room frame delivered a second time by the inbox replay.
    const B_DEVICE: u8 = 236;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut a, "Cold Restart").await;
    // The ring is registered by MEMBERS, so waiting for it is waiting for the
    // server to be joinable-while-empty at all.
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark",
    );
    go_offline(&relay, &a, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEVICE, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "a join into an empty server parks",
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    assert!(
        join_ring(&relay, &server_id).iter().any(|(from, msg)| from == &b.device_id
            && matches!(
                msg,
                super::types::HavenMessage::ServerJoinRequest { parked: true, key_package: Some(_), .. }
            )),
        "the parked copy names the leaf it wants seated, got {:?}",
        join_ring(&relay, &server_id),
    );

    let mut b = restart_node(&relay, b, B_MASTER, B_DEVICE).await;
    assert_eq!(
        b.pending_joins(),
        vec![(server_id.clone(), "pending".to_string(), String::new())],
        "the parked row is restored, so the joiner is still waiting on the same ask",
    );
    // Offline while the owner answers, so the admission comes from the RING
    // copy rather than from a live re-request racing it.
    go_offline(&relay, &b, &server_id).await;

    relay.set_online(&a.device_id, true);
    expect_mls_leaf(&a, &server_id, &b.device_id, 40).await;

    relay.set_online(&b.device_id, true);
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(40), |ev| matches!(
            ev, NetworkEvent::PendingJoinUpdated { server_id: sid, state, .. }
                if *sid == server_id && state == "ready"
        ))
        .await,
        "the tile flips to ready: the leaf the owner seated is one B holds the key for",
    );
    expect_mls_group(&[&a, &b], &server_id, 40).await;

    // One member, ONE commit. A second one would mean the leaf seated from the
    // ring copy was dead and had to be removed and re-added with a fresh
    // KeyPackage, which is exactly the failure this test exists for.
    let epoch = expect_quiet_group(&[&a, &b], &server_id, 40).await;
    assert_eq!(
        epoch, 1,
        "create is epoch 0 and B's add is epoch 1; anything higher means the \
         restarted joiner could not use the KeyPackage it had deposited",
    );
    assert!(b.servers().contains(&server_id), "B holds the server");
    assert!(b.pending_joins().is_empty(), "a completed join deletes its row");
    assert!(
        a.raw_crdt_member_keys(&server_id).contains(&b_master),
        "the owner keyed B by its MASTER, from the device list the ring copy carried, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );

    drop(a);
    drop(b);
}

// A join into a room with NOBODY in it should say so quickly. Parking is the honest
// answer to "everyone who could admit you is asleep", so an empty room parks after a
// short window while a room with somebody in it keeps the full one: a present member
// may still be seconds from answering, and parking under them would put a waiting
// tile in front of a join that is about to complete.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn empty_server_join_parks_within_the_short_window() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 228; // owner
    const B_MASTER: u8 = 229; // stranger holding an invite
    const B_DEVICE: u8 = 246;

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut a, "Nobody Home").await;
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark",
    );
    go_offline(&relay, &a, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEVICE, &[]).await;
    let started = tokio::time::Instant::now();
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    // Generous ceiling on purpose: the interesting failure is "it parked, but
    // only after the long window", and that reads as an elapsed-time assertion
    // rather than as a timeout with nothing to say.
    let parked = wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
        ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
    ))
    .await;
    let elapsed = started.elapsed();
    assert!(parked, "a join into an empty server parks; it must never just fail");
    assert!(
        elapsed < std::time::Duration::from_secs(6),
        "an empty room is known to be empty the moment the relay answers our room join, \
         so the tile must appear on the short window and not on the long one, got {elapsed:?}",
    );
    // And it is a real park, not just an event: the request is in the ring for
    // whoever comes back.
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    assert_eq!(
        b.pending_joins(),
        vec![(server_id.clone(), "pending".to_string(), String::new())],
        "the early park is PERSISTED like any other",
    );

    drop(a);
    drop(b);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn join_with_a_silent_member_present_keeps_the_long_window() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 237; // owner, gone by the time B asks
    const B_MASTER: u8 = 238; // stranger holding an invite
    const B_DEVICE: u8 = 247;
    const GHOST_DEVICE: u8 = 248; // a socket in the room with nothing behind it

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut a, "Somebody Is In").await;
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark",
    );
    go_offline(&relay, &a, &server_id).await;

    // A device in the server room that answers NOTHING. This is the case the
    // long window exists for and the one a bare "is the room empty" check would
    // get wrong in the other direction: presence is not responsiveness, but it
    // IS a reason to give the join its full chance before saying nobody is home.
    let ghost = NativeKeypair::from_secret_bytes(&seed_bytes(GHOST_DEVICE)).peer_id();
    let ghost_sock = raw_socket(&relay, &ghost);
    ghost_sock
        .cmd_tx
        .send(super::ws_client::WsCommand::JoinRoom { room_code: server_id.clone() })
        .unwrap();
    assert!(
        wait_until(10, async || relay.room_devices(&server_id).contains(&ghost)).await,
        "the silent device must be in the room before the joiner looks, got {:?}",
        relay.room_devices(&server_id),
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEVICE, &[]).await;
    let started = tokio::time::Instant::now();
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();

    // ABSENCE, and there is nothing to poll for a decision that must NOT be
    // taken, so this is a real six-second window. It rides `wait_event` rather
    // than a sleep because the thing being waited out is an event: returning
    // early with `true` is the failure, and the wait says which event it was.
    let parked_early = wait_event(&mut b, std::time::Duration::from_secs(6), |ev| matches!(
        ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
    ))
    .await;
    assert!(
        !parked_early,
        "somebody is in the room, so the join keeps the full live window: they may \
         be one round trip from answering, and a parked tile under them is a lie",
    );

    // The long window still ends in a park, because the presence was never an answer.
    let parked = wait_event(&mut b, std::time::Duration::from_secs(20), |ev| matches!(
        ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
    ))
    .await;
    let elapsed = started.elapsed();
    assert!(parked, "a silent room still parks, on the long window");
    assert!(
        elapsed >= std::time::Duration::from_secs(6),
        "the park must be the LONG window's, got {elapsed:?}",
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;

    drop(ghost_sock);
    drop(a);
    drop(b);
}

// A rejection has to travel the same road the request did: a banned stranger that
// asks into an empty room must learn it was refused, days later, without ever having
// been online with the person who refused it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_join_rejection_reaches_an_offline_joiner() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 58;
    const B_MASTER: u8 = 59;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "No Entry").await;
    // The ring is registered by MEMBERS. Until the owner's registration has
    // reached the relay, a stranger's deposit is dropped, so waiting for it is
    // waiting for the server to be joinable-while-empty at all.
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark"
    );

    o.cmd_tx
        .send(NodeCommand::BanMember {
            server_id: server_id.clone(),
            peer_id: b_master.clone(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || o
            .server_state(&server_id)
            .map(|s| s.is_banned(&b_master))
            .unwrap_or(false))
        .await,
        "the owner must hold the ban before it goes dark"
    );
    go_offline(&relay, &o, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "a ban is invisible from an empty room: the request parks like any other"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    go_offline(&relay, &b, &server_id).await;
    super::resolver::forget(&b.device_id);

    relay.set_online(&o.device_id, true);
    expect_ring_resolution(&relay, &server_id, &o.device_id, &b_master, false).await;
    // Race-free now that the frame is known to be there: the refusal names the
    // gate that produced it, which is what the joiner's tile will show.
    assert!(
        join_ring(&relay, &server_id).iter().any(|(from, m)| from == &o.device_id
            && matches!(
                m,
                super::types::HavenMessage::ServerJoinResolved { reason, .. } if reason == "banned"
            )),
        "the refusal must say `banned`, got {:?}",
        join_ring(&relay, &server_id),
    );
    go_offline(&relay, &o, &server_id).await;

    relay.set_online(&b.device_id, true);
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(25), |ev| matches!(
            ev, NetworkEvent::PendingJoinUpdated { server_id: sid, state, reason }
                if *sid == server_id && state == "rejected" && reason == "banned"
        ))
        .await,
        "the refusal reaches a joiner that was never online with the refuser"
    );
    let rejected = vec![(server_id.clone(), "rejected".to_string(), "banned".to_string())];
    assert!(
        wait_until(5, async || b.pending_joins() == rejected).await,
        "the row stays so the tile can say WHY, got {:?}",
        b.pending_joins(),
    );
    assert!(!b.servers().contains(&server_id), "a rejected join builds no server");
    assert!(
        wait_until(10, async || !relay.room_devices(&server_id).contains(&b.device_id)).await,
        "a rejected joiner leaves the room, got {:?}",
        relay.room_devices(&server_id),
    );

    drop(o);
    drop(b);
}

// The resolution is what stops a LATE member re-serving a join that has already been
// answered. C was offline before B ever asked, so its own state says nothing about B:
// it must learn the outcome from the ring and do nothing about it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn late_member_does_not_reserve_a_parked_join() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 67;
    const A_MASTER: u8 = 68;
    const C_MASTER: u8 = 69;
    const B_MASTER: u8 = 75;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master, &c_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 20).await;
    expect_dm_pair_ready(&relay, &o, &c, 20).await;

    let server_id = create_server_and_wait(&mut o, "Late Shift").await;
    for joiner in [&mut a, &mut c] {
        joiner
            .cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        assert!(
            wait_event(joiner, std::time::Duration::from_secs(15), |ev| matches!(
                ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
            ))
            .await,
            "both members join normally first"
        );
    }
    expect_mls_group(&[&o, &a, &c], &server_id, 30).await;

    drain_events(&mut a);
    relay.set_online(&c.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == c.device_id
        ))
        .await,
        "A must observe C leave"
    );
    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must observe the owner leave"
    );

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_until(30, async || a.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "A is online, so this join is served LIVE, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    expect_ring_resolution(&relay, &server_id, &a.device_id, &b_master, true).await;

    go_offline(&relay, &b, &server_id).await;
    go_offline(&relay, &a, &server_id).await;
    super::resolver::forget(&b.device_id);

    let buffered_before = relay.buffered_count(&b.device_id);
    relay.reset_meter();
    relay.set_online(&c.device_id, true);
    assert!(
        wait_until(40, async || c.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "C learns B's membership from the resolution's op, got {:?}",
        c.raw_crdt_member_keys(&server_id),
    );
    // BARRIER for the two negatives below. Both are point reads of RELAY state
    // after a wait on NODE state, so without this a targeted send C had queued
    // could simply not have landed yet and the test would pass on a race.
    expect_relay_drained(&relay, &c, "late-member-no-reserve").await;
    let meter = relay.meter().expect("meter is on");
    assert_eq!(
        meter.send_direct_cmds, 0,
        "C is the only node online, so any targeted send it made was aimed at B: \
         a resolved join must not be re-served"
    );
    assert_eq!(
        relay.buffered_count(&b.device_id),
        buffered_before,
        "nothing new is queued for B's device"
    );

    relay.set_online(&b.device_id, true);
    expect_mls_group(&[&b, &c], &server_id, 40).await;
    let mut expect_members =
        vec![o_master.clone(), a_master.clone(), b_master.clone(), c_master.clone()];
    expect_members.sort();
    assert!(
        wait_until(30, async || b.raw_crdt_member_keys(&server_id) == expect_members).await,
        "B converges on the full member list, got {:?}",
        b.raw_crdt_member_keys(&server_id),
    );

    drop(o);
    drop(a);
    drop(b);
    drop(c);
}

// A ring is 200 frames shared by everyone joining a server, so a joiner that flaps
// must not own it: reconnects re-send LIVE and re-deposit only on a 12h interval,
// while the user asking again is the one thing that always writes.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_join_redeposit_is_interval_bounded() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 76;
    const B_MASTER: u8 = 77;

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Flap House").await;
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark"
    );
    go_offline(&relay, &o, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "the request parks"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;

    for _ in 0..5 {
        go_offline(&relay, &b, &server_id).await;
        relay.set_online(&b.device_id, true);
        assert!(
            wait_until(15, async || relay.room_devices(&server_id).contains(&b.device_id)).await,
            "B rejoins its parked server's room on every reconnect, got {:?}",
            relay.room_devices(&server_id),
        );
    }
    // A NEGATIVE, so it cannot be a `wait_until` (an absence is true the instant
    // you look). It is backstopped downstream instead: the retry below waits for
    // the count to be EXACTLY 2, which never becomes true if a stray reconnect
    // deposit slipped in and made it 3.
    assert_eq!(
        ring_requests_from(&relay, &server_id, &b.device_id),
        1,
        "five reconnects inside the 12h window must not write five frames"
    );

    drain_events(&mut b);
    b.cmd_tx
        .send(NodeCommand::RequestPendingJoinAgain { server_id: server_id.clone() })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "Request again re-parks"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 2).await;

    drop(o);
    drop(b);
}

// The carried device list is SECURITY-BEARING, so present-but-bad is a DROP, never a
// downgrade to the resolver. A request with no list at all is a pre-parked-joins
// client and still works through the legacy resolver path.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_join_with_a_bad_carried_device_list_is_dropped() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 78;
    const A_MASTER: u8 = 79;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Forgery Desk").await;
    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "A joins normally first"
    );

    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must observe the owner leave"
    );
    go_offline(&relay, &a, &server_id).await;

    // A list that was signed over ONE device set and then edited to claim
    // another. The signature no longer covers what the list says.
    let forged_master = NativeKeypair::from_secret_bytes(&seed_bytes(98));
    let honest_device = NativeKeypair::from_secret_bytes(&seed_bytes(99)).peer_id();
    let tampered_device = NativeKeypair::from_secret_bytes(&seed_bytes(128)).peer_id();
    let mut tampered = super::crypto_handler::build_signed_device_list(
        &forged_master,
        1,
        vec![honest_device],
        Vec::new(),
    );
    tampered.devices = vec![tampered_device.clone()];
    let forged_master_id = forged_master.peer_id();

    let now = super::types::now_ms();
    let bad = serde_json::to_vec(&super::types::HavenMessage::ServerJoinRequest {
        server_id: server_id.clone(),
        twitch_proof_json: None,
        nsfw_confirmed: false,
        requested_at: now,
        device_list: Some(tampered),
        parked: true,
        key_package: None,
    })
    .unwrap();
    relay.inject_topic(&server_id, super::types::JOIN_TOPIC, &tampered_device, bad);

    // …and a legacy client, which carries no list at all. It is the CONTROL:
    // when this one lands we know A's catch-up has run, so the tampered frame's
    // absence from the member list is a decision, not a race.
    let legacy_device = NativeKeypair::from_secret_bytes(&seed_bytes(129)).peer_id();
    let legacy = serde_json::to_vec(&super::types::HavenMessage::ServerJoinRequest {
        server_id: server_id.clone(),
        twitch_proof_json: None,
        nsfw_confirmed: false,
        requested_at: now,
        device_list: None,
        parked: true,
        key_package: None,
    })
    .unwrap();
    relay.inject_topic(&server_id, super::types::JOIN_TOPIC, &legacy_device, legacy);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&legacy_device)).await,
        "a request with NO carried list still works, via the resolver, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    let members = a.raw_crdt_member_keys(&server_id);
    assert!(
        !members.contains(&forged_master_id) && !members.contains(&tampered_device),
        "a present-but-bad device list is a DROP, never a downgrade to the resolver, got {members:?}"
    );
    // BARRIER for the negative below. The tampered frame was injected FIRST, so
    // anything it would have published was queued BEFORE the legacy joiner's
    // admission. Once that admission is in the ring, a resolution for the
    // forgery would be too: its absence is a decision, not a frame in flight.
    expect_ring_resolution(&relay, &server_id, &a.device_id, &legacy_device, true).await;
    assert!(
        !join_ring(&relay, &server_id).iter().any(|(_, m)| matches!(
            m,
            super::types::HavenMessage::ServerJoinResolved { joiner_master, .. }
                if *joiner_master == forged_master_id || *joiner_master == tampered_device
        )),
        "and it writes no resolution either, got {:?}",
        join_ring(&relay, &server_id),
    );

    drop(o);
    drop(a);
}

// Discarding is the user changing their mind. The ring copy cannot be recalled, so a
// member WILL still admit them; the guarantee is local (no row, no room, no server)
// and the buffered answer is never collected because we never rejoin.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn discarded_parked_join_ignores_a_late_answer() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 117;
    const A_MASTER: u8 = 118;
    const B_MASTER: u8 = 119;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Second Thoughts").await;
    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "A joins normally first"
    );
    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must observe the owner leave"
    );
    go_offline(&relay, &a, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "the request parks"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;

    b.cmd_tx
        .send(NodeCommand::DiscardPendingJoin { server_id: server_id.clone() })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PendingJoinUpdated { server_id: sid, state, .. }
                if *sid == server_id && state == "discarded"
        ))
        .await,
        "discard is confirmed to the UI"
    );
    assert!(
        wait_until(5, async || b.pending_joins().is_empty()).await,
        "the row is gone, got {:?}",
        b.pending_joins(),
    );
    assert!(
        wait_until(10, async || !relay.room_devices(&server_id).contains(&b.device_id)).await,
        "and B leaves the room, got {:?}",
        relay.room_devices(&server_id),
    );

    go_offline(&relay, &b, &server_id).await;
    super::resolver::forget(&b.device_id);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "A admits from the ring, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    go_offline(&relay, &a, &server_id).await;

    // --- B returns. Its connect flow runs in full; it just has no reason to
    // rejoin that room, so the answer waiting there is never collected. ---
    relay.set_online(&b.device_id, true);
    let inbox = format!("inbox:{}", b.master_id);
    assert!(
        wait_until(20, async || relay.room_devices(&inbox).contains(&b.device_id)).await,
        "B's connect flow ran (it rejoined its own inbox)"
    );
    assert!(
        !relay.room_devices(&server_id).contains(&b.device_id),
        "a discarded join never rejoins the server room"
    );
    assert!(b.servers().is_empty(), "and never builds the server, got {:?}", b.servers());
    assert!(b.pending_joins().is_empty(), "and never resurrects the row");

    drop(o);
    drop(a);
    drop(b);
}

// A Twitch-gated join PARKS like any other. It could not before: the old proof was
// the joiner's own JSON naming a Twitch account, and a RING copy can be pulled by
// anyone holding the invite for the ring's whole retention. A follow CREDENTIAL is
// different in kind, a channel id, an age bucket and a tier blind-signed onto the
// joiner's master with no field that can name an account, so it rides the ring and
// the owner runs the same offline gate on the parked copy as on a live one.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_twitch_gated_join_carries_the_credential_and_leaks_no_identity() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 126;
    const B_MASTER: u8 = 127;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Stream Team").await;
    for (key, value) in [
        ("twitch_verification_enabled", "true"),
        ("twitch_channel_id", "1234567"),
        ("twitch_channel_name", "vitalik"),
        ("twitch_min_follow_days", "14"),
    ] {
        o.cmd_tx
            .send(NodeCommand::UpdateServerSetting {
                server_id: server_id.clone(),
                key: key.to_string(),
                value: value.to_string(),
            })
            .await
            .unwrap();
    }
    assert!(
        wait_until(10, async || o
            .server_setting(&server_id, "twitch_min_follow_days")
            .as_deref()
            == Some("14"))
        .await,
        "the Twitch gate must be live before the owner goes dark"
    );
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark"
    );
    go_offline(&relay, &o, &server_id).await;

    use super::support_creds::{self, testing};
    let credential = testing::mint_follow_for(
        &b_master,
        "1234567",
        30,
        "0",
        support_creds::now_period(),
    );
    let proof = serde_json::to_string(&credential).expect("entry json");

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: Some(proof),
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "the request parks"
    );

    // The ring copy CARRIES the credential, and everything it says is about
    // this server's own channel. Read it back out of the ring rather than
    // trusting the sender: this frame is what a stranger with the invite can
    // pull, so it is the thing that has to be safe.
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    let parked_proof = join_ring(&relay, &server_id)
        .into_iter()
        .find_map(|(from, msg)| match msg {
            super::types::HavenMessage::ServerJoinRequest { twitch_proof_json, .. }
                if from == b.device_id =>
            {
                twitch_proof_json
            }
            _ => None,
        })
        .expect("the parked request carries its credential");
    let parked: support_creds::CredentialEntry =
        serde_json::from_str(&parked_proof).expect("the ring copy is a credential");
    assert_eq!(parked.t, support_creds::T_TWITCH_FOLLOW);
    assert_eq!(
        parked.parts,
        vec!["1234567".to_string(), "30".to_string(), "0".to_string()],
        "the whole claim is the channel, the bucket and the tier",
    );
    // And it is still bound to the joiner's master, so lifting it out of the
    // ring buys a stranger nothing.
    assert!(
        support_creds::verify_entry(&parked, &b_master, &support_creds::root_verifying_key())
            .is_ok(),
        "the parked credential verifies for the joiner",
    );
    let raw = relay.topic_frames(&server_id, super::types::JOIN_TOPIC);
    let mine: Vec<&(String, Vec<u8>)> =
        raw.iter().filter(|(from, _)| from == &b.device_id).collect();
    let text = String::from_utf8(mine[0].1.clone()).expect("the frame is JSON");
    assert!(
        !text.contains("twitch_username") && !text.contains("twitch_user_id"),
        "no field in the ring copy can name a Twitch account, got {text}"
    );

    go_offline(&relay, &b, &server_id).await;
    super::resolver::forget(&b.device_id);

    // --- The owner returns alone, runs the SAME offline gate on the parked
    //     copy, and admits. This is what the strip used to make impossible. ---
    relay.set_online(&o.device_id, true);
    expect_ring_resolution(&relay, &server_id, &o.device_id, &b_master, true).await;
    assert!(
        wait_until(10, async || o
            .server_state(&server_id)
            .map(|st| st.members_list().iter().any(|m| m.peer_id == b_master))
            .unwrap_or(false))
        .await,
        "the owner holds the joiner as a member"
    );
    go_offline(&relay, &o, &server_id).await;

    relay.set_online(&b.device_id, true);
    assert!(
        wait_until(25, || async { b.servers().contains(&server_id) }).await,
        "the joiner builds the server it was admitted to while it was away, got {:?}",
        b.servers(),
    );

    drop(o);
    drop(b);
}

// An NSFW consent prompt is a QUESTION, not a refusal, and must not become permanent:
// the member never writes one into the ring (it would be re-served to every member
// for days) and the joiner never keeps a row for one (it would pop the same dialog at
// every boot). The nonce on the refusal is what makes the re-request survive, since
// the buffered `nsfw_confirm:` replays the instant the joiner rejoins that room.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn parked_nsfw_join_asks_for_consent_once_then_completes() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 135;
    const B_MASTER: u8 = 136;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Back Room").await;
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "is_nsfw".to_string(),
            value: "true".to_string(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || o.server_setting(&server_id, "is_nsfw").as_deref() == Some("true"))
            .await,
        "the NSFW flag must be live before the owner goes dark"
    );
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the owner must register the join ring before it goes dark"
    );
    go_offline(&relay, &o, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "the request parks"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    go_offline(&relay, &b, &server_id).await;
    super::resolver::forget(&b.device_id);

    relay.set_online(&o.device_id, true);
    assert!(
        wait_until(40, async || relay.buffered_count(&b.device_id) > 0).await,
        "the owner must queue the consent prompt for the absent joiner"
    );
    // BARRIER for the negative below. The buffered prompt proves the handler
    // RAN; `send_join_rejection` queues the targeted prompt first and the
    // publish (if any) second, so seeing the prompt is not yet evidence that no
    // publish is in flight. Draining the owner's queue makes it evidence.
    expect_relay_drained(&relay, &o, "nsfw-no-resolution").await;
    assert!(
        !join_ring(&relay, &server_id)
            .iter()
            .any(|(_, m)| matches!(m, super::types::HavenMessage::ServerJoinResolved { .. })),
        "a question is never a resolution: nothing about it may be written into the ring, got {:?}",
        join_ring(&relay, &server_id),
    );
    go_offline(&relay, &o, &server_id).await;

    relay.set_online(&b.device_id, true);
    let mut discarded = false;
    let asked = wait_event(&mut b, std::time::Duration::from_secs(25), |ev| match ev {
        NetworkEvent::PendingJoinUpdated { server_id: sid, state, .. }
            if *sid == server_id && state == "discarded" =>
        {
            discarded = true;
            false
        }
        NetworkEvent::TwitchJoinRejected { server_id: sid, reason }
            if *sid == server_id && reason.starts_with("nsfw_confirm:") =>
        {
            true
        }
        _ => false,
    })
    .await;
    assert!(asked, "the consent prompt reaches a joiner that was never online with the owner");
    assert!(
        wait_until(10, async || b.pending_joins().is_empty()).await,
        "a question leaves NO row behind, got {:?}",
        b.pending_joins(),
    );
    assert!(discarded, "and the tile is told to go");
    assert!(
        wait_until(10, async || !relay.room_devices(&server_id).contains(&b.device_id)).await,
        "no row means not in that room, got {:?}",
        relay.room_devices(&server_id),
    );

    // --- The user consents. The owner is back and is STILL re-serving the old
    // parked copy from the ring, so an `nsfw_confirm:` for the OLD ask is
    // buffered and replays the moment we rejoin that room. The nonce is what
    // stops it killing the request we are making now. ---
    relay.set_online(&o.device_id, true);
    assert!(
        wait_until(20, async || relay.room_devices(&server_id).contains(&o.device_id)).await,
        "the owner is back in the room"
    );
    drain_events(&mut b);
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: true,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "the consented re-request completes; a replayed refusal for the OLD ask must not kill it"
    );
    assert!(
        wait_until(20, async || o.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "and the owner admits the joiner's MASTER, got {:?}",
        o.raw_crdt_member_keys(&server_id),
    );
    assert!(b.pending_joins().is_empty(), "a completed join leaves no row");

    drop(o);
    drop(b);
}

// A tombstone must reach a member that cannot read MLS. A parked join completes its
// CRDT half from a buffered snapshot with nobody online, so the joiner holds the
// server while holding no MLS leaf, and `ServerDeleted` was sent MLS-only.
// Field-caught on a fleet run: the owner deleted in exactly that window, the joiner
// logged "unknown group" and went on listing a server that no longer existed.
// `set_broadcast_deaf` drops 0x03 broadcasts while leaving targeted 0x04 frames
// alone, which is precisely the asymmetry the bug lives in.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn server_deleted_reaches_a_parked_member_with_no_mls_leaf() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 137;
    const A_MASTER: u8 = 138;
    const B_MASTER: u8 = 139;
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 15).await;

    let server_id = create_server_and_wait(&mut o, "Closing Time").await;

    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "member A joins normally while the owner is online"
    );
    expect_mls_group(&[&o, &a], &server_id, 20).await;

    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop, or it elects a ghost coordinator on its return"
    );
    go_offline(&relay, &a, &server_id).await;

    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(30), |ev| matches!(
            ev, NetworkEvent::ServerJoinParked { server_id: sid } if *sid == server_id
        ))
        .await,
        "the request parks"
    );
    expect_ring_request(&relay, &server_id, &b.device_id, 1).await;
    go_offline(&relay, &b, &server_id).await;
    super::resolver::forget(&b.device_id);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&b_master)).await,
        "A must admit B from the ring, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    expect_ring_resolution(&relay, &server_id, &a.device_id, &b_master, true).await;
    go_offline(&relay, &a, &server_id).await;

    relay.set_online(&b.device_id, true);
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(25), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "B completes its join from the buffered snapshot with nobody online"
    );
    assert!(b.servers().contains(&server_id), "B holds the server");
    assert!(b.pending_joins().is_empty(), "a completed join deletes its row");
    // The precondition this whole test exists for. `Some(v)` and not `None`:
    // a snapshot that never came back would read exactly like an empty group.
    assert!(
        matches!(b.mls_members_checked(&server_id).await, Some(v) if v.is_empty()),
        "B must hold NO MLS leaf yet, got {:?}",
        b.mls_members_checked(&server_id).await,
    );

    // --- The owner returns to a member that cannot consume an MLS frame. ---
    // Deaf BEFORE the owner arrives, so no 0x03 frame is ever consumed by B, while
    // targeted 0x04 frames still flow: the asymmetry is the point.
    relay.set_broadcast_deaf(&b.device_id, true);
    relay.set_online(&o.device_id, true);
    assert!(
        wait_until(20, async || {
            let devices = relay.room_devices(&server_id);
            devices.contains(&o.device_id) && devices.contains(&b.device_id)
        })
        .await,
        "owner and joiner must both be in the server room, got {:?}",
        relay.room_devices(&server_id),
    );
    // Let the co-presence cascade finish BEFORE deleting, which is what isolates the
    // broadcast: the grow-only sync round trip fires once per connection, so a delete
    // landing while a `SyncRequest` is in flight rides the `SyncResponse` op log instead
    // and proves nothing. Olm confirming both ways means the burst has run, and draining
    // both queues rules out a response still in flight. B's MLS leaf is NOT waited for,
    // because a deaf device can never form one.
    expect_olm_confirmed(&o, &b, 30).await;
    expect_relay_drained(&relay, &o, "pre-delete").await;
    expect_relay_drained(&relay, &b, "pre-delete").await;

    o.cmd_tx
        .send(NodeCommand::DeleteServer { server_id: server_id.clone() })
        .await
        .unwrap();

    assert!(
        wait_until(30, async || !b.servers().contains(&server_id)).await,
        "the tombstone must reach a member that cannot read MLS: it rides the \
         plaintext twin, which is why that twin is unconditional and is aimed at \
         the membership captured BEFORE the tombstone drains it. B still lists {:?}",
        b.servers(),
    );

    drop(o);
    drop(a);
    drop(b);
}


// The MLS-first / fallback sweep: a member who cannot read the MLS copy, in two
// shapes that are NOT the same failure. DEAF means the member holds a good leaf but
// its socket never consumes a 0x03 room broadcast, so only an UNCONDITIONAL plaintext
// twin reaches it, which is why CRDT ops and VC signals send one every time instead
// of `if !mls_sent`. LEAF-LESS means the member is reachable but holds no leaf in the
// sender's copy of the group, which a parked joiner is by design. The sender can see
// NEITHER: its own encrypt succeeding measures the wrong end of the wire.

/// Count the events already queued on `node` that match `pred`, without
/// blocking. Used for the "and the member WITH a leaf got it exactly once"
/// half of the complement rule: a duplicate is as much a regression as a
/// silence, and only a count can tell them apart.
fn count_queued(node: &mut TestNode, mut pred: impl FnMut(&NetworkEvent) -> bool) -> usize {
    let mut n = 0;
    while let Ok(ev) = node.event_rx.try_recv() {
        if pred(&ev) {
            n += 1;
        }
    }
    n
}

// CRDT ops reach a member that cannot consume a room broadcast: `MemberAdded` at
// admission and the joiner's own auto-`StoragePledgeChanged`. Both used to send the
// plaintext twin only in the `else` of `if mls_ok`, so a member whose socket drops
// 0x03 frames kept a stale member panel and nothing on the sender side showed it. The
// member here is a relay socket rather than a node, so it is deaf by construction AND
// never runs the co-presence sync that would deliver the op anyway; the assertion is
// on the frames the sender actually delivered.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn member_added_and_pledge_ops_reach_a_deaf_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 231; // owner, author of MemberAdded
    const A_MASTER: u8 = 232; // member WITH a leaf, so the MLS leg is real
    const B_MASTER: u8 = 233; // the deaf member
    const C_MASTER: u8 = 234; // joins live, author of the auto-pledge
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_device = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master, &c_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 20).await;

    let server_id = create_server_and_wait(&mut o, "Twin Server").await;
    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "A joins normally and gets a leaf"
    );
    expect_mls_group(&[&o, &a], &server_id, 25).await;
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the join ring must be registered before anyone parks into it"
    );

    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop, or it elects a ghost coordinator on its return"
    );
    go_offline(&relay, &a, &server_id).await;

    let mut sock = raw_socket(&relay, &b_device);
    let legacy = serde_json::to_vec(&super::types::HavenMessage::ServerJoinRequest {
        server_id: server_id.clone(),
        twitch_proof_json: None,
        nsfw_confirmed: false,
        requested_at: super::types::now_ms(),
        device_list: None,
        parked: true,
        key_package: None,
    })
    .unwrap();
    relay.inject_topic(&server_id, super::types::JOIN_TOPIC, &b_device, legacy);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&b_device)).await,
        "A must admit the parked member from the ring, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    expect_ring_resolution(&relay, &server_id, &a.device_id, &b_device, true).await;

    relay.set_online(&o.device_id, true);
    assert!(
        wait_until(40, async || o.raw_crdt_member_keys(&server_id).contains(&b_device)).await,
        "the owner must learn the admitted member from A, got {:?}",
        o.raw_crdt_member_keys(&server_id),
    );

    // Deaf: the relay stops delivering 0x03 room frames to it, which is where
    // the MLS copy of every broadcast rides. Targeted 0x04 frames still flow.
    relay.set_broadcast_deaf(&b_device, true);
    sock.cmd_tx
        .send(WsCommand::JoinRoom { room_code: server_id.clone() })
        .unwrap();
    assert!(
        wait_until(20, async || {
            let devices = relay.room_devices(&server_id);
            devices.contains(&o.device_id)
                && devices.contains(&a.device_id)
                && devices.contains(&b_device)
        })
        .await,
        "owner, leafed member and deaf member must all be in the server room, got {:?}",
        relay.room_devices(&server_id),
    );
    expect_relay_drained(&relay, &o, "pre-c-join").await;
    expect_relay_drained(&relay, &a, "pre-c-join").await;

    // The premise: the owner really does hold a formed group, so `mls_ok` is
    // true on the send path under test and the twin is the ONLY thing that can
    // reach this member.
    let leaves = o.mls_members(&server_id).await;
    assert!(
        leaves.contains(&o.device_id) && leaves.contains(&a.device_id),
        "the owner must hold a formed group with A in it, got {leaves:?}"
    );

    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &c, 20).await;
    c.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut c, std::time::Duration::from_secs(20), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "C joins live"
    );

    let payloads = sock.direct_payloads(6000).await;
    let ops: Vec<crate::crdt::operations::CrdtOp> = payloads
        .iter()
        .filter_map(|f| serde_json::from_slice::<super::types::HavenMessage>(f).ok())
        .filter_map(|m| match m {
            super::types::HavenMessage::CrdtOpBroadcast { server_id: sid, op_json }
                if sid == server_id =>
            {
                serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json).ok()
            }
            _ => None,
        })
        .collect();

    assert!(
        ops.iter().any(|op| matches!(&op.payload,
            crate::crdt::operations::CrdtPayload::MemberAdded { peer_id, .. } if *peer_id == c_master)),
        "the owner's MemberAdded must ride the plaintext twin to a member that cannot \
         read a room broadcast. The twin is UNCONDITIONAL for exactly this reason: our \
         own encrypt succeeding says nothing about whether this member can decrypt. \
         Got {ops:?}"
    );
    assert!(
        ops.iter().any(|op| matches!(&op.payload,
            crate::crdt::operations::CrdtPayload::StoragePledgeChanged { peer_id, pledge_bytes }
                if *peer_id == c_master && *pledge_bytes > 0)),
        "the joiner's auto-pledge must ride the same unconditional twin, got {ops:?}"
    );

    drop(o);
    drop(a);
    drop(c);
}

// A VC state signal reaches a DEAF member. `broadcast_vc_state_signal` carried the
// literal `if !mls_sent` this sweep is named after, so a deaf member's tile kept
// showing somebody unmuted who had muted minutes earlier.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn vc_state_signal_reaches_a_deaf_member() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 234; // owner + sender
    const B_MASTER: u8 = 235; // the deaf member
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 20).await;

    let server_id = create_server_and_wait(&mut a, "VC Twin Server").await;
    a.cmd_tx
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
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(5), |ev| {
            if let NetworkEvent::ChannelAdded { channel_id, channel_type, .. } = ev {
                if channel_type == "voice" {
                    voice_cid = Some(channel_id.clone());
                    return true;
                }
            }
            false
        })
        .await,
        "owner creates a voice channel"
    );
    let voice_cid = voice_cid.expect("voice channel id");

    b.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "B joins the server"
    );
    // A real leaf on both sides, so the MLS leg genuinely encrypts and the only
    // thing standing between it and B is the dropped room broadcast.
    expect_mls_group(&[&a, &b], &server_id, 25).await;

    relay.set_broadcast_deaf(&b.device_id, true);
    expect_relay_drained(&relay, &a, "pre-vc").await;
    expect_relay_drained(&relay, &b, "pre-vc").await;

    // Both in the voice channel. Presence itself already sends an unconditional
    // plaintext twin (the reference shape), so the deaf member still sees the
    // join — that is the contrast this test is drawing.
    for (node, who) in [(&mut b, "B"), (&mut a, "A")] {
        node.cmd_tx
            .send(NodeCommand::VoiceChannelJoin {
                server_id: server_id.clone(),
                channel_id: voice_cid.clone(),
            })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(6), |ev| {
            matches!(ev, NetworkEvent::VoiceChannelJoined { channel_id, is_self, .. }
                if *channel_id == voice_cid && *is_self)
        })
        .await;
        assert!(joined, "{who} joins the voice channel");
    }
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::VoiceChannelJoined { channel_id, is_self, .. }
                if *channel_id == voice_cid && !*is_self
        ))
        .await,
        "the deaf member sees the owner enter the voice channel (presence twin)"
    );
    drain_events(&mut b);

    a.cmd_tx
        .send(NodeCommand::VoiceChannelSendSignal {
            server_id: server_id.clone(),
            channel_id: voice_cid.clone(),
            peer_id: String::new(),
            signal_type: "audio_state".to_string(),
            payload: serde_json::json!({"call_id": voice_cid, "muted": true, "deafened": false})
                .to_string(),
        })
        .await
        .unwrap();

    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::VoiceChannelSignal { signal_type, .. } if signal_type == "audio_state"
        ))
        .await,
        "a deaf member must still receive the audio_state signal: the MLS copy \
         rides a room broadcast its socket drops, so the plaintext twin has to go \
         out every time, not only when our own encrypt failed"
    );

    drop(a);
    drop(b);
}

// Channel typing and a profile update reach a member device that holds NO LEAF, and
// reach a member device that DOES hold one exactly once.
//
// A live node co-present with the coordinator is pulled in within about a second, so
// racing that window would make this test pass or fail on machine load. What stays
// leaf-less is a member that never offers a KeyPackage: a plain relay socket, online
// and reachable but permanently invisible to MLS. The assertion is on the FRAME the
// sender delivered, and it COUNTS, so a duplicate is as visible as a silence.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn channel_typing_and_profile_update_reach_a_member_without_a_leaf() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 236; // owner + sender
    const A_MASTER: u8 = 237; // member WITH a leaf
    const B_MASTER: u8 = 238; // member WITHOUT a leaf (a socket, never answers MLS)
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_device = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&a_master]).await;
    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &a, 20).await;

    let server_id = create_server_and_wait(&mut o, "Complement Server").await;
    let general = general_channel_of(&server_id);
    a.cmd_tx
        .send(NodeCommand::JoinServer {
            server_id: server_id.clone(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
        })
        .await
        .unwrap();
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id
        ))
        .await,
        "A joins normally and gets a leaf"
    );
    expect_mls_group(&[&o, &a], &server_id, 25).await;
    assert!(
        wait_until(15, async || relay.topic_registered(&server_id, super::types::JOIN_TOPIC)).await,
        "the join ring must be registered before anyone parks into it"
    );

    // --- Everybody dark; the old client parks a join carrying no KeyPackage. ---
    drain_events(&mut a);
    relay.set_online(&o.device_id, false);
    assert!(
        wait_event(&mut a, std::time::Duration::from_secs(15), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == o.device_id
        ))
        .await,
        "A must see the owner drop, or it elects a ghost coordinator on its return"
    );
    go_offline(&relay, &a, &server_id).await;

    let mut sock = raw_socket(&relay, &b_device);
    let legacy = serde_json::to_vec(&super::types::HavenMessage::ServerJoinRequest {
        server_id: server_id.clone(),
        twitch_proof_json: None,
        nsfw_confirmed: false,
        requested_at: super::types::now_ms(),
        device_list: None,
        parked: true,
        key_package: None,
    })
    .unwrap();
    relay.inject_topic(&server_id, super::types::JOIN_TOPIC, &b_device, legacy);

    relay.set_online(&a.device_id, true);
    assert!(
        wait_until(40, async || a.raw_crdt_member_keys(&server_id).contains(&b_device)).await,
        "A must admit the old client from the ring, got {:?}",
        a.raw_crdt_member_keys(&server_id),
    );
    expect_ring_resolution(&relay, &server_id, &a.device_id, &b_device, true).await;

    // The owner returns and learns the new member from A. It never saw a
    // KeyPackage for that member, so it never created a leaf for it.
    relay.set_online(&o.device_id, true);
    assert!(
        wait_until(40, async || o.raw_crdt_member_keys(&server_id).contains(&b_device)).await,
        "the owner must learn the admitted member from A, got {:?}",
        o.raw_crdt_member_keys(&server_id),
    );

    sock.cmd_tx
        .send(WsCommand::JoinRoom { room_code: server_id.clone() })
        .unwrap();
    assert!(
        wait_until(20, async || {
            let devices = relay.room_devices(&server_id);
            devices.contains(&o.device_id)
                && devices.contains(&a.device_id)
                && devices.contains(&b_device)
        })
        .await,
        "owner, leafed member and leaf-less member must all be in the server room, got {:?}",
        relay.room_devices(&server_id),
    );
    expect_relay_drained(&relay, &o, "pre-send").await;
    expect_relay_drained(&relay, &a, "pre-send").await;

    // The premise, stated before the sends: the sender holds the group, A is in
    // it, the old client is not.
    let leaves = o.mls_members(&server_id).await;
    assert!(
        leaves.contains(&o.device_id) && leaves.contains(&a.device_id),
        "the owner must hold a formed group with A in it, got {leaves:?}"
    );
    assert!(
        !leaves.contains(&b_device),
        "the member under test must hold NO leaf in the sender's group, got {leaves:?}"
    );

    drain_events(&mut a);
    o.cmd_tx
        .send(NodeCommand::SendTypingIndicator {
            server_id: server_id.clone(),
            channel_id: general.clone(),
        })
        .await
        .unwrap();
    o.cmd_tx
        .send(NodeCommand::UpdateProfile {
            display_name: "Owner Renamed".to_string(),
            status: "online".to_string(),
            about_me: String::new(),
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username: String::new(),
            showcase_board: None,
            showcase_assets: None,
            avatar_frame: None,
            avatar_anim: None,
            banner_anim: None,
            support_creds: None,
        })
        .await
        .unwrap();

    // One window, both frames. This doubles as the duplicate check's settle: by
    // the time it returns, anything A was going to receive has been queued.
    let payloads = sock.direct_payloads(6000).await;
    let decoded: Vec<super::types::HavenMessage> = payloads
        .iter()
        .filter_map(|f| serde_json::from_slice::<super::types::HavenMessage>(f).ok())
        .collect();

    let typing = decoded
        .iter()
        .filter(|m| matches!(m, super::types::HavenMessage::TypingIndicator { server_id: sid, channel_id: cid }
            if *sid == server_id && *cid == general))
        .count();
    assert_eq!(
        typing, 1,
        "the leaf-less member must be sent the plaintext typing indicator exactly \
         once: the MLS copy is undecryptable for it, and the complement copy is \
         aimed at precisely the devices with no leaf"
    );

    let profiles = decoded
        .iter()
        .filter(|m| matches!(m, super::types::HavenMessage::ProfileUpdate { display_name, .. }
            if display_name == "Owner Renamed"))
        .count();
    assert_eq!(
        profiles, 1,
        "the leaf-less member must be sent the plaintext profile update exactly \
         once: `mls_reached` now holds only the masters that actually hold a leaf, \
         so a leaf-less member is no longer skipped as already reached"
    );

    // The other half of the complement rule: the member WITH a leaf reads the
    // MLS copy and is not also sent a plaintext duplicate.
    let a_typing = count_queued(&mut a, |ev| {
        matches!(ev, NetworkEvent::TypingStarted { peer_id, server_id: sid, channel_id: cid }
            if *peer_id == o_master && *sid == server_id && *cid == general)
    });
    assert_eq!(a_typing, 1, "the member with a leaf must see the typing exactly once");

    // Still leaf-less at the end, so nothing above landed because the group
    // quietly healed underneath the assertions.
    let leaves_after = o.mls_members(&server_id).await;
    assert!(
        !leaves_after.contains(&b_device),
        "the member under test must still hold no leaf, got {leaves_after:?}"
    );

    drop(o);
    drop(a);
}

// A channel FileHeader and the members with no leaf in the group that carried it. The
// group is a restricted channel's SUBGROUP, where a qualifying member stays leaf-less
// on its own, because subgroup membership is reconciled on lifecycle events rather
// than on co-presence. The caption stays unreadable but the header must arrive, or
// the member renders a message with no card and no way to ask for the bytes; the
// fallback is Olm, never plaintext, since a header carries the file's key. Read this
// as a regression guard: channel content has other redelivery paths, so what the test
// pins is the sender's state when it chose recipients, a formed subgroup with neither
// member's leaf in it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn channel_file_header_reaches_a_member_without_a_leaf() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 239; // owner + sender
    const B_MASTER: u8 = 240; // Admin: qualifies, holds no subgroup leaf
    const M_MASTER: u8 = 241; // plain Member: does NOT qualify
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(M_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&b_master, &m_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&o_master]).await;
    let mut m = spawn_node_with_friends(&relay, M_MASTER, M_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &b, 25).await;
    expect_dm_pair_ready(&relay, &o, &m, 25).await;

    let server_id = create_server_and_wait(&mut o, "Header Server").await;
    // Relay catch-up OFF, before anybody registers a ring: otherwise a member
    // that heals after failing to decrypt is simply replayed the frame it
    // missed, and the fallback under test is not what delivered anything.
    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "relay_catchup_secs".to_string(),
            value: "0".to_string(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(15, async || o
            .live_server_state(&server_id)
            .await
            .is_some_and(|s| s.relay_catchup_secs() == 0))
            .await,
        "the owner must turn relay catch-up off before anyone joins"
    );

    for (node, who) in [(&mut b, "B"), (&mut m, "M")] {
        node.cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(15), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{who} joins the server");
    }
    expect_mls_group(&[&o, &b, &m], &server_id, 30).await;
    // The Olm fallback only writes to devices with a session, so both sessions
    // are a precondition of the test rather than part of what it measures.
    expect_olm_confirmed(&o, &b, 30).await;
    expect_olm_confirmed(&o, &m, 30).await;

    // B is an Admin, so it QUALIFIES for the restricted channel below. M stays a
    // plain Member and must never be sent anything from it.
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: b_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(20, async || {
            b.live_role(&server_id, &b_master).await
                == crate::crdt::operations::MemberRole::Admin
        })
        .await,
        "B must be Admin before the channel is restricted"
    );

    // Both go dark, and the channel becomes restricted while they are away. The
    // subgroup reconcile only pulls in ONLINE qualifying members, and nothing
    // re-runs it on co-presence, so B comes back qualifying and leaf-less.
    go_offline(&relay, &b, &server_id).await;
    go_offline(&relay, &m, &server_id).await;

    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "vault".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut restricted_cid = None;
    assert!(
        wait_event(&mut o, std::time::Duration::from_secs(8), |ev| {
            if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
                if name == "vault" {
                    restricted_cid = Some(channel_id.clone());
                    return true;
                }
            }
            false
        })
        .await,
        "owner creates the channel"
    );
    let restricted_cid = restricted_cid.expect("channel id");

    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    let subgroup = crate::crypto::subgroup_id(&server_id, &restricted_cid);
    expect_mls_leaf(&o, &subgroup, &o.device_id, 25).await;

    relay.set_online(&b.device_id, true);
    relay.set_online(&m.device_id, true);
    assert!(
        wait_until(25, async || {
            let devices = relay.room_devices(&server_id);
            devices.contains(&b.device_id) && devices.contains(&m.device_id)
        })
        .await,
        "both members must be back in the server room, got {:?}",
        relay.room_devices(&server_id),
    );
    assert!(
        wait_until(25, async || o
            .live_server_state(&server_id)
            .await
            .is_some_and(|s| s.can_see_channel(&b_master, &restricted_cid)
                && !s.can_see_channel(&m_master, &restricted_cid)))
            .await,
        "B must qualify for the restricted channel and M must not"
    );
    expect_relay_drained(&relay, &o, "pre-file").await;
    expect_relay_drained(&relay, &b, "pre-file").await;
    expect_relay_drained(&relay, &m, "pre-file").await;

    // The premise: the owner holds the subgroup and neither member is in it, so
    // both are leaf-less and only the visibility filter separates them.
    let sub_leaves = o.mls_members(&subgroup).await;
    assert!(
        sub_leaves.contains(&o.device_id)
            && !sub_leaves.contains(&b.device_id)
            && !sub_leaves.contains(&m.device_id),
        "the owner must hold the subgroup with neither member's leaf, got {sub_leaves:?}"
    );

    drain_events(&mut b);
    drain_events(&mut m);
    let src = global_tmp.path().join("ledger.txt");
    std::fs::write(&src, b"restricted channel file body").expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(restricted_cid.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "restricted-file-1".to_string(),
            message_text: "ledger".to_string(),
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
    wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("ledger") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    let fid = got_fid.expect(
        "the header must reach the qualifying member with no leaf in the group \
         that carried it: the MLS topic copy is undecryptable for it, so the Olm \
         copy goes to exactly the leaf-less devices",
    );
    let meta = b.file_meta(&fid).expect("header persisted on the leaf-less member");
    assert_eq!(meta.file_name, "ledger.txt", "the header names the file");

    // NOT asserted here, though it belongs to this site: that a member who does NOT
    // qualify is never sent the header. The complement set IS filtered through
    // `can_see_channel`, but `replicate_channel_file_full` and the channel-sync responder
    // both hand it over with no visibility gate, and both predate this sweep.

    // No assertion on the subgroup AFTER the send, on purpose: a leaf-less member that
    // reads an undecryptable frame asks to be bootstrapped, so its leaf state a second
    // later is not a stable fact to pin.

    drop(o);
    drop(b);
    drop(m);
}

// A restricted channel's HISTORY and FILES never reach a member who cannot see it.
// The per-channel subgroup protects LIVE traffic only, and backfill went round it
// three ways, all reachable by any plain Member: the channel sync responder gated on
// holding the SERVER and served any channel's rows, file headers (which carry the
// AES key) included, with the probe alone leaking the hidden channel's message count;
// `replicate_channel_file_full` streamed the ciphertext with no check at all; and the
// `FileRequest` responder never asked whether the requester could see the channel. B
// must end with nothing about either, having asked for all three.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn restricted_channel_history_and_files_never_reach_a_non_qualifier() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 242; // owner
    const B_MASTER: u8 = 243; // plain Member: must never see the channel
    const C_MASTER: u8 = 244; // Admin: must see everything
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(O_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[&b_master, &c_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&o_master]).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&o_master]).await;
    expect_dm_pair_ready(&relay, &o, &b, 25).await;
    expect_dm_pair_ready(&relay, &o, &c, 25).await;

    let server_id = create_server_and_wait(&mut o, "Vault Server").await;
    let general = general_channel_of(&server_id);
    for (node, who) in [(&mut b, "B"), (&mut c, "C")] {
        node.cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let joined = wait_event(node, std::time::Duration::from_secs(15), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "{who} joins the server");
    }
    expect_mls_group(&[&o, &b, &c], &server_id, 30).await;
    // Olm both ways for both, so a silence later is a REFUSAL and not a missing
    // session: every path under test would use these if it decided to serve.
    expect_olm_confirmed(&o, &b, 30).await;
    expect_olm_confirmed(&o, &c, 30).await;

    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: c_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(20, async || {
            o.live_role(&server_id, &c_master).await
                == crate::crdt::operations::MemberRole::Admin
        })
        .await,
        "C must be Admin before the channel is restricted"
    );

    o.cmd_tx
        .send(NodeCommand::CreateChannel {
            server_id: server_id.clone(),
            channel_id: crate::node::new_channel_id(&server_id),
            name: "vault".to_string(),
            category: None,
            channel_type: "text".to_string(),
        })
        .await
        .unwrap();
    let mut restricted_cid = None;
    assert!(
        wait_event(&mut o, std::time::Duration::from_secs(8), |ev| {
            if let NetworkEvent::ChannelAdded { channel_id, name, .. } = ev {
                if name == "vault" {
                    restricted_cid = Some(channel_id.clone());
                    return true;
                }
            }
            false
        })
        .await,
        "owner creates the channel"
    );
    let restricted_cid = restricted_cid.expect("channel id");

    o.cmd_tx
        .send(NodeCommand::SetChannelVisibility {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            visibility: "admin".to_string(),
        })
        .await
        .unwrap();
    let subgroup = crate::crypto::subgroup_id(&server_id, &restricted_cid);
    expect_mls_leaf(&o, &subgroup, &o.device_id, 25).await;
    expect_mls_leaf(&c, &subgroup, &c.device_id, 25).await;
    expect_no_mls_leaf(&o, &subgroup, &b.device_id, 20).await;

    // B must KNOW the channel exists (it is in the CRDT for everyone) — that is
    // what makes its own sync coordinator probe and request it, which is the
    // path under test. Hiding it from the CRDT would prove nothing.
    assert!(
        wait_until(25, async || b
            .live_server_state(&server_id)
            .await
            .is_some_and(|s| s.channels.contains_key(&restricted_cid)
                && !s.can_see_channel(&b_master, &restricted_cid)))
            .await,
        "B must hold the channel in its CRDT and not qualify for it"
    );

    drain_events(&mut b);
    drain_events(&mut c);
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: restricted_cid.clone(),
            text: "admins only".to_string(),
            message_id: "vault-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    let src = global_tmp.path().join("payroll.txt");
    std::fs::write(&src, b"restricted channel file body").expect("write src file");
    o.cmd_tx
        .send(NodeCommand::SendFile(Box::new(super::types::SendFilePayload {
            peer_id: None,
            server_id: Some(server_id.clone()),
            channel_id: Some(restricted_cid.clone()),
            file_path: src.to_str().unwrap().to_string(),
            message_id: "vault-file-1".to_string(),
            message_text: "payroll".to_string(),
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
    wait_event(&mut c, std::time::Duration::from_secs(25), |ev| {
        if let NetworkEvent::FileHeaderReceived { file_id, file_name, .. } = ev {
            if file_name.starts_with("payroll") {
                got_fid = Some(file_id.clone());
                return true;
            }
        }
        false
    })
    .await;
    let fid = got_fid.expect("the Admin must receive the restricted channel's FileHeader");
    assert!(
        wait_until(20, async || c
            .channel_messages(&server_id, &restricted_cid)
            .iter()
            .any(|m| m.text == "admins only"))
            .await,
        "the Admin must receive the restricted channel's message"
    );

    // --- B now asks for all three, and must be refused every time. ---
    //
    // A reconnect makes B's own sync coordinator fire a probe and a request for EVERY
    // channel it holds; the explicit RequestFile covers the third path. The owner also
    // posts in #general while B is away, so the same run proves the gate does not
    // OVER-block.
    drain_events(&mut b);
    go_offline(&relay, &b, &server_id).await;
    o.cmd_tx
        .send(NodeCommand::SendChannelMessage {
            server_id: server_id.clone(),
            channel_id: general.clone(),
            text: "general chatter".to_string(),
            message_id: "general-msg-1".to_string(),
            reply_to_mid: None,
            link_preview: None,
        })
        .await
        .unwrap();
    relay.set_online(&b.device_id, true);
    assert!(
        wait_until(25, async || relay.room_devices(&server_id).contains(&b.device_id)).await,
        "B must rejoin the server room so its sync round runs, got {:?}",
        relay.room_devices(&server_id),
    );
    expect_olm_confirmed(&o, &b, 30).await;
    b.cmd_tx
        .send(NodeCommand::RequestFile {
            file_id: fid.clone(),
            peer_id: o_master.clone(),
            chunks: Vec::new(),
        })
        .await
        .unwrap();

    // NEGATIVES, so they wait out a real window rather than polling for a state
    // that must never exist. The window covers the sync round trip and the file
    // request; C's arrival above is the proof the sender was willing and able.
    let b_leaked = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::FileHeaderReceived { file_name, .. }
            if file_name.starts_with("payroll"))
            || matches!(ev, NetworkEvent::ChannelMessageReceived { text, .. }
                if text == "admins only")
    })
    .await;
    assert!(
        !b_leaked,
        "a plain Member must receive neither the restricted channel's message nor \
         its FileHeader: the sync responders and the FileRequest responder gate on \
         `can_see_channel`, not on server membership"
    );
    assert!(
        b.file_meta(&fid).is_none(),
        "and nothing about the file may be stored on it: the header carries the \
         AES key, and full replication no longer streams the bytes to a member \
         who cannot see the channel"
    );
    assert!(
        b.channel_messages(&server_id, &restricted_cid).is_empty(),
        "and no row from the channel either, got {:?}",
        b.channel_messages(&server_id, &restricted_cid),
    );
    assert!(
        !b.missing_file_ids().contains(&fid),
        "not even a placeholder row it would keep re-requesting"
    );

    // NOT over-blocked: B is a member of #general, so the same responders that
    // just refused it the restricted channel must serve it that backfill.
    assert!(
        wait_until(25, async || b
            .channel_messages(&server_id, &general)
            .iter()
            .any(|m| m.text == "general chatter"))
            .await,
        "a member must still be served the channels it CAN see, got {:?}",
        b.channel_messages(&server_id, &general),
    );

    // --- And a NON-MEMBER in the room gets nothing, for an Everyone channel that is not
    //     public. ---
    //
    // `can_see_channel` on its own is not a gate: an unknown peer's role resolves to
    // plain Member, so membership is the first rung. The probe response is the
    // discriminating frame because it goes out in the CLEAR.
    const X_MASTER: u8 = 245; // never joins the server
    let x_device = NativeKeypair::from_secret_bytes(&seed_bytes(X_MASTER)).peer_id();
    assert!(
        !o.live_server_state(&server_id)
            .await
            .expect("owner state")
            .is_member(&x_device),
        "the stranger must not be a member"
    );
    let mut x = raw_socket(&relay, &x_device);
    x.cmd_tx
        .send(WsCommand::JoinRoom { room_code: server_id.clone() })
        .unwrap();
    assert!(
        wait_until(20, async || relay.room_devices(&server_id).contains(&x_device)).await,
        "the stranger must be in the server room, got {:?}",
        relay.room_devices(&server_id),
    );
    let probe = serde_json::to_vec(&super::types::HavenMessage::ChannelSyncProbe {
        server_id: server_id.clone(),
        channel_id: general.clone(),
        our_latest: 0,
        msg_count: 0,
    })
    .unwrap();
    let req = serde_json::to_vec(&super::types::HavenMessage::ChannelSyncRequest {
        server_id: server_id.clone(),
        channel_id: general.clone(),
        since_timestamp: 0,
        sender_timestamps: HashMap::new(),
    })
    .unwrap();
    for frame in [probe, req] {
        x.cmd_tx
            .send(WsCommand::SendDirect {
                room_code: server_id.clone(),
                target_peer: o.device_id.clone(),
                data: frame,
            })
            .unwrap();
    }
    let stranger_frames = x.direct_payloads(6000).await;
    let served = stranger_frames
        .iter()
        .filter_map(|f| serde_json::from_slice::<super::types::HavenMessage>(f).ok())
        .filter(|m| matches!(m, super::types::HavenMessage::ChannelSyncProbeResponse { channel_id, .. }
            if *channel_id == general))
        .count();
    assert_eq!(
        served, 0,
        "a NON-MEMBER must be served nothing for a non-public channel, not even the          probe's message count and latest timestamp: membership is the first rung of          the gate, and the visibility ladder alone says yes to every Everyone channel"
    );

    let meta = c.file_meta(&fid).expect("the Admin still holds the header");
    assert_eq!(meta.file_name, "payroll.txt", "the header names the file");

    drop(o);
    drop(b);
    drop(c);
}

// ---------------------------------------------------------------------------
// CI guard: the harness's FIXED-sleep budget.
// ---------------------------------------------------------------------------

/// Fail when the total `sleep_ms` budget in this file grows.
///
/// The suite once reached 16 minutes: 471 fixed sleeps totalling 831 seconds, 87% of
/// the runtime with the CPU idle, each a settle with a condition nobody polled for.
/// So the budget is a number in a test: a new sleep comes out of the existing total,
/// or is argued for by raising this cap in a diff someone reads. The alternatives are
/// in the module above (`wait_until`, `expect_olm_confirmed`, `expect_mls_leaf`,
/// `expect_mls_group`, `expect_no_mls_leaf`); keep `sleep_ms` for an ABSENCE proof and
/// for a settle whose only signal is a running node's SQLCipher DB.
#[test]
fn harness_fixed_sleep_budget_does_not_grow() {
    // The cap moves only for sleeps with nothing to poll: an ABSENCE proof, a settle
    // whose only signal is a running node's DB, the spawn stagger, and the auto-download
    // advert window that has no live probe. Every such sleep says so at its own call
    // site, which is where the reason for the current number lives.
    const BUDGET_MS: u64 = 601_900;

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


// A verified Twitch account rides the profile as a `t = 3` support credential and
// nothing else: the purple chip draws from THIS or from nothing. It is bound to one
// master, so a transplant is dropped, and its `period` means time, so an entry minted
// two windows ago is dropped as well, chain and signature notwithstanding.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn twitch_owner_credential_replicates_and_stale_period_is_dropped() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 221;
    const A_DEV: u8 = 222;
    const B_MASTER: u8 = 223;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    assert!(
        wait_until(15, || async {
            a.online_identities(&relay).contains(&b_master)
                && b.online_identities(&relay).contains(&a_master)
        })
        .await,
        "A and B must see each other before the announce"
    );
    drain_events(&mut a);
    drain_events(&mut b);

    use super::support_creds::{self, testing};
    let now = support_creds::now_period();
    let real = testing::mint_owner_for(&a_master, "12345", "somestreamer", now);
    let transplant = testing::mint_owner_for("somebody-else", "99999", "otherperson", now);
    // A's own, chain and signature perfect, but minted two windows ago: past
    // the one window of grace. A different account so its `item` differs from
    // the real one and the assertion below cannot pass by accident.
    let stale = testing::mint_owner_for(&a_master, "55555", "oldstreamer", now - 2);
    let announced =
        support_creds::encode_entries(&[transplant.clone(), stale.clone(), real.clone()]);

    a.cmd_tx
        .send(NodeCommand::UpdateProfile {
            display_name: "Anon A".to_string(),
            status: "hi".to_string(),
            about_me: String::new(),
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username: String::new(),
            showcase_board: None,
            showcase_assets: None,
            avatar_frame: None,
            avatar_anim: None,
            banner_anim: None,
            support_creds: Some(announced),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&a_master)
                .ok()
                .flatten()
                .is_some_and(|p| !p.support_creds.is_empty())
        })
        .await,
        "B must store A's account credential"
    );

    let p = b.store().load_profile(&a_master).unwrap().expect("A's profile on B");
    let kept = support_creds::parse_stored(&p.support_creds);
    assert_eq!(
        kept.len(),
        1,
        "exactly the real, in-window entry survives: {}",
        p.support_creds
    );
    assert_eq!(kept[0].t, support_creds::T_TWITCH_OWNER);
    assert_eq!(
        kept[0].parts,
        vec!["12345".to_string(), "somestreamer".to_string()],
        "the chip draws parts[1] and the id keeps it meaningful across a rename",
    );
    assert!(
        !p.support_creds.contains(&transplant.item),
        "the transplant is gone: {}",
        p.support_creds
    );
    assert_eq!(kept[0].item, real.item, "the surviving entry is this window's");
    assert_eq!(kept[0].period, now);
    assert!(
        !p.support_creds.contains(&stale.item),
        "and the entry from two windows ago is gone, chain and signature notwithstanding: {}",
        p.support_creds
    );
    support_creds::verify_entry(&kept[0], &a_master, &support_creds::root_verifying_key())
        .expect("B's stored account entry verifies for A's master");

    drop(a);
    drop(b);
}

// The Twitch join gate, offline. A joiner presents a blind-signed FOLLOW credential
// bound to its own master; the owner checks the chain against the pinned root, the
// channel, the age bucket and the tier, and contacts nobody. The bucket is the whole
// claim, so a setting rounds UP, and the old JSON proof (the joiner's own unsigned
// word) is refused with a sentence that says what to do about it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn twitch_follow_gate_accepts_bucket_and_refuses_the_rest() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 231;
    const B_MASTER: u8 = 232;
    const B_DEV: u8 = 233;
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Stream Team").await;
    for (key, value) in [
        ("twitch_verification_enabled", "true"),
        ("twitch_channel_id", "1234567"),
        ("twitch_channel_name", "vitalik"),
        ("twitch_min_follow_days", "14"),
    ] {
        o.cmd_tx
            .send(NodeCommand::UpdateServerSetting {
                server_id: server_id.clone(),
                key: key.to_string(),
                value: value.to_string(),
            })
            .await
            .unwrap();
    }
    assert!(
        wait_until(10, async || o
            .server_setting(&server_id, "twitch_min_follow_days")
            .as_deref()
            == Some("14"))
        .await,
        "the gate must be live before anyone knocks"
    );

    use super::support_creds::{self, testing};
    let now = support_creds::now_period();
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_DEV, &[]).await;

    // One helper: knock, and answer with the refusal sentence (or None when
    // the join went through).
    async fn knock(
        b: &mut TestNode,
        server_id: &str,
        proof: String,
    ) -> Option<String> {
        drain_events(b);
        b.cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.to_string(),
                twitch_proof_json: Some(proof),
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let mut said: Option<String> = None;
        let _ = wait_event(b, std::time::Duration::from_secs(12), |ev| match ev {
            NetworkEvent::TwitchJoinRejected { reason, .. } => {
                said = Some(reason.clone());
                true
            }
            NetworkEvent::ServerJoined { server_id: sid, .. } if sid == server_id => true,
            _ => false,
        })
        .await;
        said
    }

    let short = serde_json::to_string(&testing::mint_follow_for(&b_master, "1234567", 7, "0", now))
        .expect("entry json");
    let said = knock(&mut b, &server_id, short).await.expect("a refusal");
    assert!(
        said.contains("at least 14 days"),
        "a 7-day bucket must not satisfy a 14-day gate, got {said}",
    );
    assert!(b.servers().is_empty(), "and nothing was joined");

    let elsewhere =
        serde_json::to_string(&testing::mint_follow_for(&b_master, "7654321", 365, "0", now))
            .expect("entry json");
    let said = knock(&mut b, &server_id, elsewhere).await.expect("a refusal");
    assert!(
        said.contains("different channel"),
        "a credential for another channel must be refused, got {said}",
    );

    // (c) A credential minted for another identity: the blind signature binds
    //     the JOINER's master, so a borrowed one is worth nothing.
    let borrowed =
        serde_json::to_string(&testing::mint_follow_for("somebody-else", "1234567", 365, "0", now))
            .expect("entry json");
    let said = knock(&mut b, &server_id, borrowed).await.expect("a refusal");
    assert!(
        said.contains("did not verify"),
        "a credential bound to another master must be refused, got {said}",
    );

    // (d) The OLD shape: the joiner's own unsigned JSON. Refused with the
    //     sentence that tells the user what to do.
    let old_shape = serde_json::json!({
        "twitch_user_id": "998877",
        "twitch_username": "someviewer",
        "followed_at": "2020-01-01T00:00:00Z",
        "is_subscribed": true,
        "timestamp": super::types::now_ms() / 1000,
    })
    .to_string();
    let said = knock(&mut b, &server_id, old_shape).await.expect("a refusal");
    assert!(
        said.contains(super::twitch::OLD_PROOF_SENTENCE),
        "the old proof shape must be refused with its own sentence, got {said}",
    );

    o.cmd_tx
        .send(NodeCommand::UpdateServerSetting {
            server_id: server_id.clone(),
            key: "twitch_require_sub".to_string(),
            value: "true".to_string(),
        })
        .await
        .unwrap();
    assert!(
        wait_until(10, async || o
            .server_setting(&server_id, "twitch_require_sub")
            .as_deref()
            == Some("true"))
        .await,
        "the sub requirement must be live"
    );
    let unsubbed =
        serde_json::to_string(&testing::mint_follow_for(&b_master, "1234567", 30, "0", now))
            .expect("entry json");
    let said = knock(&mut b, &server_id, unsubbed).await.expect("a refusal");
    assert!(
        said.contains("subscribed"),
        "tier 0 must not satisfy a sub requirement, got {said}",
    );

    let good =
        serde_json::to_string(&testing::mint_follow_for(&b_master, "1234567", 30, "1000", now))
            .expect("entry json");
    assert_eq!(
        knock(&mut b, &server_id, good).await,
        None,
        "a 30-day tier-1000 follower must be admitted",
    );
    assert!(
        wait_until(10, || async { b.servers().contains(&server_id) }).await,
        "the joiner holds the server, got {:?}",
        b.servers(),
    );
    // The owner never minted a handle for them: a follow credential names no
    // Twitch account, and there is nothing to display.
    let panel = o.member_panel(&server_id, &relay);
    assert!(
        panel.iter().any(|r| r.master == b_master),
        "the owner has the joiner as a member, got {:?}",
        panel.iter().map(|r| r.master.clone()).collect::<Vec<_>>(),
    );

    drop(o);
    drop(b);
}

// CRYPTO-1, over the wire. A master-signed device list rides every profile announce
// in the clear, so anyone who has seen one holds a genuine, perfectly valid list for
// somebody else. The receiver used to bind whichever device DELIVERED it to that
// master, which hands the attacker the victim's DM fan-out, its Olm authorisation and
// its CRDT role checks. The attacker here is a bare device id with a socket, so
// nothing can re-teach the target that id afterwards and mask the result.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn replayed_device_list_from_an_unlisted_device_does_not_bind() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    // V = the victim whose signed list is public. T = the target that must not
    // be fooled. A = a device id V has never named.
    const V_MASTER: u8 = 191;
    const V_DEV: u8 = 192;
    const T_MASTER: u8 = 193;
    const A_DEV: u8 = 194;
    let v_master = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER)).peer_id();
    let t_master = NativeKeypair::from_secret_bytes(&seed_bytes(T_MASTER)).peer_id();
    let v_dev = NativeKeypair::from_secret_bytes(&seed_bytes(V_DEV)).peer_id();
    let a_dev = NativeKeypair::from_secret_bytes(&seed_bytes(A_DEV)).peer_id();

    // Armed before V exists: the replay has to be V's REAL frame, bytes
    // unchanged, or this proves nothing about a genuine signed list.
    relay.set_recording(&v_dev, true);

    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_DEV, &[&t_master]).await;
    let mut t = spawn_node_with_friends(&relay, T_MASTER, T_MASTER, &[&v_master]).await;
    expect_dm_pair_ready(&relay, &v, &t, 15).await;

    let profile = |name: &str, status: &str| NodeCommand::UpdateProfile {
        display_name: name.to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: None,
        avatar_anim: None,
        banner_anim: None,
        support_creds: None,
    };

    v.cmd_tx.send(profile("Victim", "the real one")).await.unwrap();
    assert!(
        wait_until(20, || async {
            t.store()
                .load_profile(&v_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.display_name == "Victim")
                && t.known_devices(&v_master).iter().any(|d| *d == v_dev)
        })
        .await,
        "T must hold V's signed profile and V's device list first, got {:?}",
        t.known_devices(&v_master),
    );

    // V's own announce, captured off the wire: a real signature over real
    // profile fields, carrying V's real master-signed device list.
    let replay = relay
        .recorded_frames(&v_dev)
        .into_iter()
        .filter(|data| {
            serde_json::from_slice::<serde_json::Value>(data)
                .ok()
                .and_then(|val| {
                    let obj = val.as_object()?.clone();
                    Some(
                        obj.get("type")?.as_str()? == "profile_update"
                            && obj.get("device_list").is_some_and(|d| !d.is_null())
                            && obj.get("profile_sig").is_some_and(|s| !s.is_null()),
                    )
                })
                .unwrap_or(false)
        })
        .next_back()
        .expect("V announces a signed profile carrying its signed device list");

    // The resolver is process-global in this harness, so clear anything already
    // known about the attacker's id: a pass has to mean "refused", never
    // "we happened not to have learned it".
    super::resolver::forget(&a_dev);

    let room = super::types::dm_room_code(&v_master, &t_master);
    relay.inject(&room, &a_dev, &t.device_id, replay);

    // BARRIER: a later frame from V, on the same channel into T, that the
    // injected one must have been processed before. It is V's, not the
    // attacker's, precisely so it cannot overwrite the mapping under test.
    v.cmd_tx.send(profile("Victim", "barrier")).await.unwrap();
    assert!(
        wait_until(20, || async {
            t.store()
                .load_profile(&v_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "barrier")
        })
        .await,
        "the barrier announce must land, so the replay's outcome is a decision"
    );

    assert_ne!(
        super::resolver::resolve(&a_dev),
        v_master,
        "the delivering device must never resolve to the victim's master",
    );
    let known = t.known_devices(&v_master);
    assert!(
        !known.iter().any(|d| *d == a_dev),
        "and it must not be written into T's device list for V, got {known:?}",
    );
    assert!(
        known.iter().any(|d| *d == v_dev),
        "while V's real device is still there, got {known:?}",
    );

    drop(v);
    drop(t);
}

// The same replay through the OTHER stranger-reachable door. A friend request lands
// in `inbox:{master}` from someone the target has never met, carrying a device list
// precisely because the resolver is cold for a stranger, which made it the cheapest
// place to plant the mapping. A list that does not name its deliverer is DROPPED.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn friend_request_from_an_unlisted_device_does_not_bind() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const V_MASTER: u8 = 195;
    const V_DEV: u8 = 196;
    const T_MASTER: u8 = 197;
    const A_DEV: u8 = 198;
    let v_keypair = NativeKeypair::from_secret_bytes(&seed_bytes(V_MASTER));
    let v_master = v_keypair.peer_id();
    let t_master = NativeKeypair::from_secret_bytes(&seed_bytes(T_MASTER)).peer_id();
    let v_dev = NativeKeypair::from_secret_bytes(&seed_bytes(V_DEV)).peer_id();
    let a_dev = NativeKeypair::from_secret_bytes(&seed_bytes(A_DEV)).peer_id();

    let mut v = spawn_node_with_friends(&relay, V_MASTER, V_DEV, &[&t_master]).await;
    let mut t = spawn_node_with_friends(&relay, T_MASTER, T_MASTER, &[&v_master]).await;
    expect_dm_pair_ready(&relay, &v, &t, 15).await;

    let profile = |status: &str| NodeCommand::UpdateProfile {
        display_name: "Victim".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: None,
        avatar_anim: None,
        banner_anim: None,
        support_creds: None,
    };

    assert!(
        wait_until(20, || async {
            t.known_devices(&v_master).iter().any(|d| *d == v_dev)
        })
        .await,
        "T must hold V's device list first, got {:?}",
        t.known_devices(&v_master),
    );

    // V's genuine list, signed by V's own master key. Nothing about it is
    // forged; the attacker simply is not in it.
    let v_list = super::crypto_handler::build_signed_device_list(
        &v_keypair, 1, vec![v_dev.clone()], Vec::new(),
    );
    assert!(super::crypto_handler::verify_device_list(&v_list), "the carried list is real");

    super::resolver::forget(&a_dev);

    let request = serde_json::to_vec(&super::types::HavenMessage::FriendRequest {
        requested_at: super::types::now_ms(),
        carried_bundle: None,
        device_list: Some(v_list),
        carried_profile: None,
    })
    .unwrap();
    relay.inject(&format!("inbox:{t_master}"), &a_dev, &t.device_id, request);

    // BARRIER, same reasoning as the replay test: a later frame from V.
    v.cmd_tx.send(profile("barrier")).await.unwrap();
    assert!(
        wait_until(20, || async {
            t.store()
                .load_profile(&v_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "barrier")
        })
        .await,
        "the barrier announce must land, so the request's outcome is a decision"
    );

    assert_ne!(
        super::resolver::resolve(&a_dev),
        v_master,
        "a carried list must not bind the device that carried it",
    );
    let known = t.known_devices(&v_master);
    assert!(
        !known.iter().any(|d| *d == a_dev),
        "and T's device list for V must not name the requester, got {known:?}",
    );

    drop(v);
    drop(t);
}

// `support_creds` sits outside the profile signature, so on the plaintext fallback a
// relay can rewrite it to `""` and every receiver reads the holder's explicit clear.
// The field's OWN master signature closes that, and it is REQUIRED. The earlier
// per-master pin was worse than nothing: a relay that stripped the signature from the
// FIRST announce kept that master on the unsigned branch permanently, so the baseline
// never existed for exactly the masters that needed it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn stripped_support_creds_never_clears_a_pinned_mark() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 241;
    const A_DEV: u8 = 242;
    const B_MASTER: u8 = 243;
    const C_MASTER: u8 = 244;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    // Keep every frame A sends from the start: leg 3 replays one of them.
    relay.set_recording(&a.device_id, true);
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master, &c_master]).await;
    let mut c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&b_master]).await;
    assert!(
        wait_until(20, || async {
            b.online_identities(&relay).contains(&a_master)
                && b.online_identities(&relay).contains(&c_master)
                && a.online_identities(&relay).contains(&b_master)
        })
        .await,
        "everybody must see everybody before the announces"
    );
    drain_events(&mut a);
    drain_events(&mut b);
    drain_events(&mut c);

    use super::support_creds::{self, testing};
    let mark = testing::mint_for(&a_master, &[hex::encode([0x5au8; 32])]);

    let profile = |status: &str, creds: Option<String>| NodeCommand::UpdateProfile {
        display_name: "Anon".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: None,
        avatar_anim: None,
        banner_anim: None,
        support_creds: creds,
    };

    // --- 0. A holder with nothing yet: a signed announce of the empty field.
    //        This is the frame leg 3 replays, and it is entirely genuine. ---
    a.cmd_tx
        .send(profile("no marks yet", Some(String::new())))
        .await
        .unwrap();
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&a_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "no marks yet")
        })
        .await,
        "B must see A before there is anything to strip"
    );

    a.cmd_tx
        .send(profile("with a mark", Some(support_creds::encode_entries(&[mark.clone()]))))
        .await
        .unwrap();
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&a_master)
                .ok()
                .flatten()
                .is_some_and(|p| !p.support_creds.is_empty())
        })
        .await,
        "B must store A's mark"
    );
    let after_first = b.store().load_profile(&a_master).unwrap().unwrap();
    let earlier_updated_at = after_first.updated_at;

    // --- 1b. The field PRESENT and the signature gone: a relay writing marks
    //         rather than deleting them. A picks up a second mark; B must not
    //         see it, because the frame that carries it proves nothing. ---
    let second = testing::mint_for(&a_master, &[hex::encode([0x5cu8; 32])]);
    relay.set_drop_support_creds_sig(&a.device_id, true);
    drain_events(&mut b);
    a.cmd_tx
        .send(profile(
            "a second mark, unsigned",
            Some(support_creds::encode_entries(&[mark.clone(), second.clone()])),
        ))
        .await
        .unwrap();
    // CONTROL: the rest of the profile IS signed and lands, so once the status
    // is through, the unchanged field is a decision rather than a frame in
    // flight.
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&a_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "a second mark, unsigned")
        })
        .await,
        "B must receive the unsigned update (the signed half of the profile is fine)"
    );
    let p = b.store().load_profile(&a_master).unwrap().unwrap();
    assert_eq!(
        support_creds::parse_stored(&p.support_creds),
        vec![mark.clone()],
        "an unsigned field must not add a mark either: {}",
        p.support_creds,
    );
    relay.set_drop_support_creds_sig(&a.device_id, false);

    relay.set_strip_support_creds(&a.device_id, true);
    drain_events(&mut b);
    a.cmd_tx.send(profile("stripped in flight", None)).await.unwrap();
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&a_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "stripped in flight")
        })
        .await,
        "B must receive the tampered update (the rest of the profile is fine)"
    );
    let p = b.store().load_profile(&a_master).unwrap().unwrap();
    assert_eq!(
        support_creds::parse_stored(&p.support_creds),
        vec![mark.clone()],
        "a relay that rewrote the field to \"\" must change NOTHING: {}",
        p.support_creds,
    );
    relay.set_strip_support_creds(&a.device_id, false);

    // --- 3. A replayed OLDER announce, genuinely signed, must not clear it.
    //        A's first profile announce carried no credentials and a perfectly
    //        good signature over the empty field; replaying it is the cheapest
    //        way to undo a purchase, and `updated_at` is what refuses it. ---
    let older: Vec<Vec<u8>> = relay
        .recorded_frames(&a.device_id)
        .into_iter()
        .filter(|data| {
            serde_json::from_slice::<serde_json::Value>(data)
                .ok()
                .and_then(|v| {
                    let obj = v.as_object()?.clone();
                    let is_profile =
                        obj.get("type")?.as_str()? == "profile_update";
                    let empty = obj.get("support_creds")?.as_str()?.is_empty();
                    let signed = obj.contains_key("support_creds_sig");
                    let stamp = obj.get("updated_at")?.as_i64()?;
                    Some(is_profile && empty && signed && stamp < earlier_updated_at)
                })
                .unwrap_or(false)
        })
        .collect();
    assert!(
        !older.is_empty(),
        "the test needs a genuine older signed announce with an empty field to replay",
    );
    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    relay.inject(&dm_room, &a.device_id, &b.device_id, older[0].clone());
    // ABSENCE proof: there is no state change to poll for, so the window has
    // to be real time, and then the row is read.
    sleep_ms(1500).await;
    let p = b.store().load_profile(&a_master).unwrap().unwrap();
    assert_eq!(
        support_creds::parse_stored(&p.support_creds),
        vec![mark.clone()],
        "a replayed OLDER signed announce must not clear the field: {}",
        p.support_creds,
    );

    // --- 4. A master B has NEVER seen sign gets no softer rule. This is the leg that
    // used to go the other way, on a per-master pin a relay could keep unset forever.
    // There is no trust-on-first-use left to attack. ---
    relay.set_drop_support_creds_sig(&c.device_id, true);
    let c_mark = testing::mint_for(&c_master, &[hex::encode([0x5bu8; 32])]);
    c.cmd_tx
        .send(profile("old client", Some(support_creds::encode_entries(&[c_mark.clone()]))))
        .await
        .unwrap();
    // CONTROL again: the signed half of C's profile lands, so the empty field
    // that follows is a decision.
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&c_master)
                .ok()
                .flatten()
                .is_some_and(|p| p.status == "old client")
        })
        .await,
        "B must receive C's update"
    );
    assert!(
        b.store().load_profile(&c_master).unwrap().unwrap().support_creds.is_empty(),
        "an unsigned field is refused from every master, first announce included",
    );

    // --- 5. And the same mark, signed, lands: leg 4 failed on the signature,
    //        not on the credential. ---
    relay.set_drop_support_creds_sig(&c.device_id, false);
    c.cmd_tx
        .send(profile("signed now", Some(support_creds::encode_entries(&[c_mark.clone()]))))
        .await
        .unwrap();
    assert!(
        wait_until(10, || async {
            b.store()
                .load_profile(&c_master)
                .ok()
                .flatten()
                .is_some_and(|p| !p.support_creds.is_empty())
        })
        .await,
        "the same mark, signed this time, must apply"
    );
    assert_eq!(
        support_creds::parse_stored(&b.store().load_profile(&c_master).unwrap().unwrap().support_creds),
        vec![c_mark],
        "and it is C's own mark",
    );

    drop(a);
    drop(b);
    drop(c);
}

// Artist shop, phase 2: a support credential rides the profile as `support_creds`,
// the receiver verifies it OFFLINE against the pinned root and stores it under the
// sender's MASTER, a transplanted entry is dropped in silence, an untouched update
// preserves it, an explicit `""` clears it, and a sibling of the holder receives it.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other test
async fn support_credential_replicates_and_transplant_is_dropped() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 211;
    const A_DEV: u8 = 212;
    const A_DEV2: u8 = 213;
    const B_MASTER: u8 = 214;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let mut a = spawn_node_with_friends(&relay, A_MASTER, A_DEV, &[&b_master]).await;
    let mut a2 = spawn_node_with_friends(&relay, A_MASTER, A_DEV2, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    assert!(
        wait_until(15, || async {
            a.online_identities(&relay).contains(&b_master)
                && b.online_identities(&relay).contains(&a_master)
        })
        .await,
        "A and B must see each other before the announce"
    );
    drain_events(&mut a);
    drain_events(&mut a2);
    drain_events(&mut b);

    use super::support_creds::{self, testing};
    let frame_hash = hex::encode([0x5au8; 32]);
    let real = testing::mint_for(&a_master, &[frame_hash.clone()]);
    let transplant = testing::mint_for("somebody-else", &[hex::encode([0x5bu8; 32])]);
    let announced = support_creds::encode_entries(&[transplant.clone(), real.clone()]);

    let send = |status: &str, creds: Option<String>| NodeCommand::UpdateProfile {
        display_name: "Anon A".to_string(),
        status: status.to_string(),
        about_me: String::new(),
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: String::new(),
        showcase_board: None,
        showcase_assets: None,
        avatar_frame: None,
        avatar_anim: None,
        banner_anim: None,
        support_creds: creds,
    };

    a.cmd_tx.send(send("hi", Some(announced))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's profile update");
    assert!(
        wait_until(5, || async {
            b.store().load_profile(&a_master).ok().flatten().is_some_and(|p| !p.support_creds.is_empty())
        })
        .await,
        "B must store A's credentials"
    );
    let p = b.store().load_profile(&a_master).unwrap()
        .expect("B must hold A's profile keyed by A's MASTER (device != master)");
    let kept = support_creds::parse_stored(&p.support_creds);
    assert_eq!(kept.len(), 1, "exactly the real credential survives: {}", p.support_creds);
    assert_eq!(kept[0].item, real.item, "the surviving entry is the one minted for A");
    assert!(!p.support_creds.contains(&transplant.item), "the transplant is gone");
    support_creds::verify_entry(&kept[0], &a_master, &support_creds::root_verifying_key())
        .expect("B's stored entry verifies for A's master");
    assert_eq!(kept[0].parts, vec![frame_hash.clone()], "the parts name the frame hash");

    let got = wait_event(&mut a2, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { peer_id } if *peer_id == a_master)
    })
    .await;
    assert!(got, "the sibling must receive its own master's profile update");
    assert!(
        wait_until(5, || async {
            a2.store().load_profile(&a_master).ok().flatten().is_some_and(|p| !p.support_creds.is_empty())
        })
        .await,
        "the sibling must store the credentials"
    );
    let sib = a2.store().load_profile(&a_master).unwrap().expect("sibling profile row");
    let sib_kept = support_creds::parse_stored(&sib.support_creds);
    assert_eq!(sib_kept.len(), 1, "the sibling keeps the real credential: {}", sib.support_creds);
    assert_eq!(sib_kept[0].item, real.item);

    // --- 3. An update that does not touch the field PRESERVES it (which is
    // also exactly what an old client sends). ---
    drain_events(&mut b);
    a.cmd_tx.send(send("status changed", None)).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's second update");
    assert!(
        wait_until(5, || async {
            b.store().load_profile(&a_master).ok().flatten().is_some_and(|p| p.status == "status changed")
        })
        .await,
        "B must store the second update"
    );
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.status, "status changed");
    assert_eq!(
        support_creds::parse_stored(&p.support_creds),
        vec![real.clone()],
        "an update that did not touch the credentials must NOT lose them"
    );

    drain_events(&mut b);
    a.cmd_tx.send(send("cleared", Some(String::new()))).await.unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(8), |ev| {
        matches!(ev, NetworkEvent::ProfileUpdated { .. })
    })
    .await;
    assert!(got, "B must receive A's clear");
    assert!(
        wait_until(5, || async {
            b.store().load_profile(&a_master).ok().flatten().is_some_and(|p| p.status == "cleared")
        })
        .await,
        "B must store the clear"
    );
    let p = b.store().load_profile(&a_master).unwrap().expect("profile row");
    assert_eq!(p.support_creds, "", "an explicit empty field must clear on B");

    drop(a);
    drop(a2);
    drop(b);
}

// CRDT op authenticity (audit 2026-09). Before the fix a `CrdtOp` carried no signature
// and `author` was a free string, so anyone who could put a frame into a server room
// could write ops as the Owner, and `op_allowed` waved `ServerCreated` through for
// everyone. Three of the four ingest paths ran no permission check at all. These
// tests push forged frames in through the relay on every path and read the LIVE
// in-memory copy, the one that enforces.

/// Bring three friends up, have O create a server, and have M and X join it.
/// Returns (o, m, x, server_id) with everyone converged on two members plus
/// the owner.
async fn three_member_server(
    relay: &MockRelay,
    o_tag: u8,
    m_tag: u8,
    x_tag: u8,
) -> (TestNode, TestNode, TestNode, String) {
    let o_master = NativeKeypair::from_secret_bytes(&seed_bytes(o_tag)).peer_id();
    let m_master = NativeKeypair::from_secret_bytes(&seed_bytes(m_tag)).peer_id();
    let x_master = NativeKeypair::from_secret_bytes(&seed_bytes(x_tag)).peer_id();

    let mut o = spawn_node_with_friends(relay, o_tag, o_tag, &[&m_master, &x_master]).await;
    let mut m = spawn_node_with_friends(relay, m_tag, m_tag, &[&o_master, &x_master]).await;
    let mut x = spawn_node_with_friends(relay, x_tag, x_tag, &[&o_master, &m_master]).await;
    expect_dm_pair_ready(relay, &o, &m, 15).await;
    expect_dm_pair_ready(relay, &o, &x, 15).await;

    let server_id = create_server_and_wait(&mut o, "Real Server").await;
    assert!(
        wait_until(10, async || relay.room_devices(&server_id).contains(&o.device_id)).await,
        "owner must join its own server room"
    );

    for joiner in [&mut m, &mut x] {
        joiner
            .cmd_tx
            .send(NodeCommand::JoinServer {
                server_id: server_id.clone(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
            })
            .await
            .unwrap();
        let joined = wait_event(joiner, std::time::Duration::from_secs(10), |ev| {
            matches!(ev, NetworkEvent::ServerJoined { server_id: sid, .. } if *sid == server_id)
        })
        .await;
        assert!(joined, "joiner should emit ServerJoined");
    }

    for (node, who) in [(&o, "O"), (&m, "M"), (&x, "X")] {
        let ok = wait_until(10, async || {
            let Some(state) = node.live_server_state(&server_id).await else { return false };
            state.is_member(&m_master) && state.is_member(&x_master)
        })
        .await;
        assert!(ok, "{who} must see both members before the attack");
        assert_eq!(
            node.live_role(&server_id, &m_master).await,
            crate::crdt::operations::MemberRole::Member,
            "{who}: M starts as a plain Member"
        );
        assert_eq!(
            node.live_owner(&server_id).await.as_deref(),
            Some(o_master.as_str()),
            "{who}: O is the Owner"
        );
    }

    drain_events(&mut o);
    drain_events(&mut m);
    drain_events(&mut x);
    (o, m, x, server_id)
}

/// CRDT-1: a plain member forges ops naming the Owner as author, and forges a
/// second founding op naming itself. Delivered on every ingest path there is
/// (plaintext broadcast, sync batch), against two victims. Nothing lands.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn crdt_forged_author_op_is_rejected_on_every_ingest_path() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const O_TAG: u8 = 13;
    const M_TAG: u8 = 14;
    const X_TAG: u8 = 15;
    let (o, m, x, server_id) = three_member_server(&relay, O_TAG, M_TAG, X_TAG).await;
    let o_master = o.master_id.clone();
    let m_master = m.master_id.clone();

    // The promotion M wants: itself to Admin, attributed to the Owner. Only
    // the Owner may author this, and only the Owner's key can prove it.
    let promote = || crate::crdt::operations::CrdtPayload::RoleChanged {
        peer_id: m_master.clone(),
        role: crate::crdt::operations::MemberRole::Admin,
        priority: crate::crdt::operations::MemberRole::Admin.priority(),
    };
    // A minute ahead of the wall clock: still inside the drift window, but
    // late enough to WIN the LWW comparison if it were ever applied. A forged
    // op that could not have won would prove nothing.
    const AHEAD: u64 = 60_000;

    let attacks: Vec<(&str, Vec<u8>)> = vec![
        (
            "unsigned author-spoof over CrdtOpBroadcast",
            crdt_broadcast_frame(
                &server_id,
                &forge_crdt_op(&server_id, &o_master, promote(), AHEAD, None),
            ),
        ),
        (
            "author-spoof signed with the attacker's own key",
            crdt_broadcast_frame(
                &server_id,
                &forge_crdt_op(&server_id, &o_master, promote(), AHEAD, Some(&m.master_kp)),
            ),
        ),
        (
            "the same forged op smuggled inside a SyncResponse batch",
            sync_response_frame(
                &server_id,
                &[
                    forge_crdt_op(&server_id, &o_master, promote(), AHEAD, None),
                    forge_crdt_op(&server_id, &o_master, promote(), AHEAD + 1, Some(&m.master_kp)),
                ],
            ),
        ),
        (
            "a second ServerCreated naming the attacker as owner",
            crdt_broadcast_frame(
                &server_id,
                &forge_crdt_op(
                    &server_id,
                    &m_master,
                    crate::crdt::operations::CrdtPayload::ServerCreated {
                        name: "PWNED".into(),
                        owner_peer_id: m_master.clone(),
                    },
                    AHEAD,
                    Some(&m.master_kp),
                ),
            ),
        ),
    ];

    for (what, frame) in attacks {
        for target in [&o, &x] {
            relay.inject(&server_id, &m.device_id, &target.device_id, frame.clone());
        }
        // Absence proof: give both victims a bounded window to have applied
        // the op, THEN assert they did not.
        sleep_ms(1500).await;
        for (node, who) in [(&o, "O"), (&x, "X")] {
            assert_eq!(
                node.live_role(&server_id, &m_master).await,
                crate::crdt::operations::MemberRole::Member,
                "{who} must still see M as a plain Member after: {what}"
            );
            assert_eq!(
                node.live_owner(&server_id).await.as_deref(),
                Some(o_master.as_str()),
                "{who} must still recognise O as Owner after: {what}"
            );
            assert_eq!(
                node.live_server_name(&server_id).await,
                "Real Server",
                "{who}'s server name must be untouched after: {what}"
            );
        }
    }

    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: m_master.clone(),
            new_role: "moderator".to_string(),
        })
        .await
        .unwrap();
    let promoted = wait_until(10, async || {
        x.live_role(&server_id, &m_master).await == crate::crdt::operations::MemberRole::Moderator
    })
    .await;
    assert!(promoted, "the real Owner must still be able to change a role");

    drop(o);
    drop(m);
    drop(x);
}

/// CRDT-2: an op stamped at the end of time. Signed by a peer who really is
/// allowed to write it, so only the clock bound catches it — and because it is
/// refused rather than merged, the Owner can still rename afterwards.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn crdt_future_hlc_op_is_rejected_and_owner_can_still_rename() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const O_TAG: u8 = 16;
    const M_TAG: u8 = 17;
    const X_TAG: u8 = 18;
    let (o, m, x, server_id) = three_member_server(&relay, O_TAG, M_TAG, X_TAG).await;
    let m_master = m.master_id.clone();

    // M is promoted for real, so it genuinely holds MANAGE_SERVER: the op
    // below is refused on its TIMESTAMP alone, not on permission.
    o.cmd_tx
        .send(NodeCommand::ChangeRole {
            server_id: server_id.clone(),
            peer_id: m_master.clone(),
            new_role: "admin".to_string(),
        })
        .await
        .unwrap();
    for (node, who) in [(&o, "O"), (&x, "X"), (&m, "M")] {
        let ok = wait_until(10, async || {
            node.live_role(&server_id, &m_master).await
                == crate::crdt::operations::MemberRole::Admin
        })
        .await;
        assert!(ok, "{who} must see M as Admin before the attack");
    }

    // A validly signed rename, stamped at the end of time. Applied, it would
    // win every future LWW comparison and lock the name forever.
    let poison = forge_crdt_op(
        &server_id,
        &m_master,
        crate::crdt::operations::CrdtPayload::ServerRenamed { new_name: "PWNED".into() },
        u64::MAX - crate::crdt::hlc::wall_clock_ms(),
        Some(&m.master_kp),
    );
    assert_eq!(poison.hlc.physical_ms, u64::MAX, "the op really is stamped at the end of time");
    assert!(poison.verify_author().is_ok(), "and its signature is genuinely valid");
    let frame = crdt_broadcast_frame(&server_id, &poison);
    for target in [&o, &x] {
        relay.inject(&server_id, &m.device_id, &target.device_id, frame.clone());
    }
    sleep_ms(1500).await;
    for (node, who) in [(&o, "O"), (&x, "X")] {
        assert_eq!(
            node.live_server_name(&server_id).await,
            "Real Server",
            "{who} must keep the old name"
        );
    }

    o.cmd_tx
        .send(NodeCommand::RenameServer {
            server_id: server_id.clone(),
            new_name: "Fine".to_string(),
        })
        .await
        .unwrap();
    for (node, who) in [(&o, "O"), (&x, "X"), (&m, "M")] {
        let ok = wait_until(10, async || {
            node.live_server_name(&server_id).await == "Fine"
        })
        .await;
        assert!(
            ok,
            "{who} must converge on the Owner's rename, got {:?}",
            node.live_server_name(&server_id).await
        );
    }

    drop(o);
    drop(m);
    drop(x);
}

/// The gate binds an op to its AUTHOR, not to whoever handed it over. A member
/// relaying somebody else's correctly signed op is the normal case (join
/// fan-out, gossip re-flood) and must keep working.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn crdt_signed_op_relayed_by_another_member_is_accepted() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();
    const O_TAG: u8 = 19;
    const M_TAG: u8 = 25;
    const X_TAG: u8 = 26;
    let (o, m, x, server_id) = three_member_server(&relay, O_TAG, M_TAG, X_TAG).await;
    let o_master = o.master_id.clone();

    // An op authored by O — O's master key is what makes it O's — that M has
    // never seen, delivered to M from X's socket.
    let renamed = forge_crdt_op(
        &server_id,
        &o_master,
        crate::crdt::operations::CrdtPayload::ServerRenamed { new_name: "Relayed".into() },
        60_000,
        Some(&o.master_kp),
    );
    assert_ne!(
        m.live_server_name(&server_id).await,
        "Relayed",
        "precondition: M has not seen this rename"
    );
    relay.inject(
        &server_id,
        &x.device_id,
        &m.device_id,
        crdt_broadcast_frame(&server_id, &renamed),
    );

    let ok = wait_until(10, async || {
        m.live_server_name(&server_id).await == "Relayed"
    })
    .await;
    assert!(
        ok,
        "M must apply an op signed by the Owner even though X handed it over, got {:?}",
        m.live_server_name(&server_id).await
    );

    drop(o);
    drop(m);
    drop(x);
}

// Asset rail: the pull RETRIES. A message carrying an asset token replays fine from
// the relay ring, but the BYTES never arrived when the holder was not reachable at
// the moment of the first ask: the ask was made once per connection and nothing ever
// asked again. Four halves: a holder that shows up later gets asked, one that answers
// "I don't have it" hands the ask on, the walk is bounded, and an unasked peer cannot
// steer it.

/// Every frame this device sent that decodes as a HavenMessage of `kind`
/// (the externally-tagged `type` field). Recording is armed per device with
/// `MockRelay::set_recording`.
fn frames_of_type(relay: &MockRelay, device: &str, kind: &str) -> Vec<serde_json::Value> {
    relay
        .recorded_frames(device)
        .into_iter()
        .filter_map(|d| serde_json::from_slice::<serde_json::Value>(&d).ok())
        .filter(|v| v.get("type").and_then(|t| t.as_str()) == Some(kind))
        .collect()
}

/// A small, real, still WebP the way authoring produces one, plus its hash.
/// `tint` keeps each test's blob (and therefore its hash) its own.
fn asset_blob(tint: u8) -> (Vec<u8>, String) {
    use sha2::{Digest, Sha256};
    let img = image::RgbaImage::from_pixel(24, 24, image::Rgba([tint, 90, 200, 255]));
    let mut png = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .expect("encode test png");
    let (bytes, _) = super::image_convert::process_emote_image(&png).expect("process asset");
    let hash = hex::encode(Sha256::digest(&bytes));
    (bytes, hash)
}

// 1. The DM case. B asks for a GIF whose only holder is offline, so the ask has
// nowhere to go; the holder comes back minutes later and the bytes have to follow it
// in, off ONE retry.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_pull_retries_when_the_holder_comes_online() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 155;
    const B_MASTER: u8 = 156;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;

    let (blob, hash) = asset_blob(210);
    a.store()
        .save_asset_blob(&hash, &blob, false, "gif")
        .expect("A caches the gif it sent");

    // A quits before B ever renders the token — the exact boot ordering the
    // relay's offline ring produces.
    relay.set_online(&a.device_id, false);
    let gone = wait_until(10, async || !relay.online_devices().contains(&a.device_id)).await;
    assert!(gone, "A must be off the relay before B asks");
    drain_events(&mut b);
    relay.set_recording(&b.device_id, true);

    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: None,
            peer_hint: Some(a_master.clone()),
        })
        .await
        .unwrap();

    let early = wait_event(&mut b, std::time::Duration::from_secs(4), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(!early, "nothing can arrive while the only holder is offline");
    assert!(
        !b.store().has_emote_blob(&hash).unwrap(),
        "B must not have the bytes yet"
    );

    // The holder comes back. Nothing re-asks in Dart, and the message is long
    // since rendered — the pull has to restart on its own.
    relay.set_online(&a.device_id, true);
    let got = wait_event(&mut b, std::time::Duration::from_secs(25), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got, "the pull must retry once the holder is reachable again");
    let cached = wait_until(5, async || {
        b.store().has_emote_blob(&hash).unwrap_or(false)
    })
    .await;
    assert!(cached, "the bytes have to reach the store, not just the event");
    assert_eq!(
        b.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(blob.as_slice()),
        "the retried pull must land the holder's bytes byte-exact"
    );

    // One dead ask and one retry at the outside — the retry must not become a
    // poll that hammers the room every tick.
    let asks = frames_of_type(&relay, &b.device_id, "emote_request");
    assert!(
        asks.len() <= 2,
        "at most one dead ask plus one retry, sent {}",
        asks.len()
    );

    drop(a);
    drop(b);
}

// 2. The server case. Three members, the blob on exactly one of them, and the first
// holder the deterministic walk picks is the one WITHOUT it: the miss comes back
// named and the ask moves on.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_pull_rotates_to_another_holder_after_a_miss() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 157;
    const G_MASTER: u8 = 158;
    const B_MASTER: u8 = 159;

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Rotation Server").await;

    // Two more nodes in the same room. Browsing is enough: the asset rail asks
    // whoever is IN the room, which is what makes any member a candidate.
    let g = spawn_node_with_friends(&relay, G_MASTER, G_MASTER, &[]).await;
    g.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    let roomed = wait_until(15, async || {
        let devs = relay.room_devices(&server_id);
        devs.contains(&o.device_id) && devs.contains(&g.device_id) && devs.contains(&b.device_id)
    })
    .await;
    assert!(roomed, "all three have to share the server room");

    // Candidates are walked in ascending peer-id order, so putting the blob on
    // the HIGHER id guarantees the first ask lands on an empty node.
    let (empty_id, holder_id) = if o.device_id < g.device_id {
        (o.device_id.clone(), g.device_id.clone())
    } else {
        (g.device_id.clone(), o.device_id.clone())
    };
    let (blob, hash) = asset_blob(60);
    let holder_store = if holder_id == o.device_id { o.store() } else { g.store() };
    holder_store
        .save_asset_blob(&hash, &blob, false, "gif")
        .expect("the holder caches the gif");
    let empty_store = if empty_id == o.device_id { o.store() } else { g.store() };
    assert!(
        !empty_store.has_emote_blob(&hash).unwrap(),
        "the other member must genuinely not hold it"
    );

    drain_events(&mut b);
    relay.set_recording(&b.device_id, true);
    relay.set_recording(&empty_id, true);
    relay.set_recording(&holder_id, true);

    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();

    let got = wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got, "the ask has to reach the member that actually holds the bytes");
    let cached = wait_until(5, async || {
        b.store().has_emote_blob(&hash).unwrap_or(false)
    })
    .await;
    assert!(cached, "the bytes have to reach the store, not just the event");
    assert_eq!(
        b.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(blob.as_slice()),
        "rotated pull must land the bytes byte-exact"
    );

    let empty_replies = frames_of_type(&relay, &empty_id, "emote_assets");
    assert!(
        empty_replies.iter().any(|v| {
            v.get("missing")
                .and_then(|m| m.as_array())
                .is_some_and(|a| a.iter().any(|h| h.as_str() == Some(hash.as_str())))
                && crate::api::showcase::decode_asset_bundle(
                    v.get("bundle_json").and_then(|b| b.as_str()).unwrap_or("").as_bytes(),
                )
                .is_empty()
        }),
        "the member without the bytes must answer, naming the hash as missing"
    );

    let holder_replies = frames_of_type(&relay, &holder_id, "emote_assets");
    assert!(
        holder_replies.iter().any(|v| {
            crate::api::showcase::decode_asset_bundle(
                v.get("bundle_json").and_then(|b| b.as_str()).unwrap_or("").as_bytes(),
            )
            .iter()
            .any(|(h, _)| *h == hash)
        }),
        "the holder must answer with the bytes"
    );

    // Exactly two asks: the empty node, then the holder. One would mean the
    // walk got lucky and proves nothing; three would mean it sprayed.
    let asks = frames_of_type(&relay, &b.device_id, "emote_request");
    assert_eq!(
        asks.len(),
        2,
        "one ask that missed and one that landed, sent {}",
        asks.len()
    );

    drop(o);
    drop(g);
    drop(b);
}

// 3. The walk is BOUNDED. Five other members, none of them holding the blob: the
// asker tries four and then stops, and only a new socket starts it again. Otherwise
// one unrenderable token becomes a permanent trickle of requests around the room.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_pull_asks_are_bounded_per_connection() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 165;
    const B_MASTER: u8 = 175;

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Bounded Server").await;

    let mut others: Vec<TestNode> = Vec::new();
    for tag in [166u8, 167, 168, 169] {
        let n = spawn_node_with_friends(&relay, tag, tag, &[]).await;
        n.cmd_tx
            .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
            .await
            .unwrap();
        others.push(n);
    }
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    let roomed = wait_until(20, async || relay.room_devices(&server_id).len() == 6).await;
    assert!(
        roomed,
        "six devices have to share the room, got {}",
        relay.room_devices(&server_id).len()
    );

    let (_, hash) = asset_blob(30);
    drain_events(&mut b);
    relay.set_recording(&b.device_id, true);

    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();

    let bounded = wait_until(20, async || {
        frames_of_type(&relay, &b.device_id, "emote_request").len() >= 4
    })
    .await;
    assert!(
        bounded,
        "the walk must try four holders, tried {}",
        frames_of_type(&relay, &b.device_id, "emote_request").len()
    );
    // Sit through several retry sweeps: a fifth ask would mean the bound is
    // not a bound. Polled rather than slept so it fails the moment a fifth
    // one goes out, and so the harness sleep budget stays where it was.
    let fifth = wait_until(4, async || {
        frames_of_type(&relay, &b.device_id, "emote_request").len() > 4
    })
    .await;
    assert!(!fifth, "four asks and no more, however many sweeps run");
    let settled = frames_of_type(&relay, &b.device_id, "emote_request").len();
    assert_eq!(settled, 4, "four asks and no more, sent {settled}");

    relay.set_online(&b.device_id, false);
    let dropped = wait_until(10, async || !relay.online_devices().contains(&b.device_id)).await;
    assert!(dropped, "B must actually leave the relay");
    relay.set_online(&b.device_id, true);
    let resumed = wait_until(25, async || {
        frames_of_type(&relay, &b.device_id, "emote_request").len() > settled
    })
    .await;
    assert!(
        resumed,
        "asks must resume on a new connection, still {}",
        frames_of_type(&relay, &b.device_id, "emote_request").len()
    );

    drop(o);
    drop(others);
    drop(b);
}

// 4. A "missing" from a peer we never asked changes nothing. Otherwise any member of
// a shared room could make us fan requests around it by volunteering that it does not
// hold things nobody asked it for.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_pull_ignores_missing_from_a_peer_we_did_not_ask() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 176;
    const B_MASTER: u8 = 177;
    const C_MASTER: u8 = 178;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();
    let c_master = NativeKeypair::from_secret_bytes(&seed_bytes(C_MASTER)).peer_id();

    let a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master, &c_master]).await;
    let c = spawn_node_with_friends(&relay, C_MASTER, C_MASTER, &[&b_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;
    expect_dm_pair_ready(&relay, &b, &c, 15).await;

    let (blob, hash) = asset_blob(120);
    a.store()
        .save_asset_blob(&hash, &blob, false, "gif")
        .expect("A caches the gif");

    relay.set_online(&a.device_id, false);
    let gone = wait_until(10, async || !relay.online_devices().contains(&a.device_id)).await;
    assert!(gone, "A must be off the relay before B asks");
    // The relay's view is not B's: until the PeerLeft lands, B still holds A
    // in its room and an ask to A would be legitimate.
    assert!(
        wait_event(&mut b, std::time::Duration::from_secs(10), |ev| matches!(
            ev, NetworkEvent::PeerDisconnected { peer_id } if *peer_id == a.device_id
        ))
        .await,
        "B must see A drop before it is asked"
    );
    drain_events(&mut b);
    relay.set_recording(&b.device_id, true);

    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: None,
            peer_hint: Some(a_master.clone()),
        })
        .await
        .unwrap();
    // An absence proof, polled: it fails the moment an ask goes out, and it
    // costs the harness sleep budget nothing.
    let asked = wait_until(3, async || {
        !frames_of_type(&relay, &b.device_id, "emote_request").is_empty()
    })
    .await;
    assert!(!asked, "no ask can go out while the only holder is offline");

    let msg = super::types::HavenMessage::EmoteAssets {
        bundle_json: String::from_utf8(crate::api::showcase::encode_asset_bundle(&[]))
            .expect("empty bundle is JSON"),
        missing: vec![hash.clone()],
    };
    let dm_room = super::types::dm_room_code(&b_master, &c_master);
    relay.inject_direct(
        &dm_room,
        &c.device_id,
        &b.device_id,
        serde_json::to_vec(&msg).expect("serialize EmoteAssets"),
    );
    let fanned = wait_until(3, async || {
        !frames_of_type(&relay, &b.device_id, "emote_request").is_empty()
    })
    .await;
    assert!(
        !fanned,
        "an unasked peer's miss must not move the ask anywhere"
    );

    // The ask is untouched: it still belongs to A, and it completes when A
    // comes back.
    relay.set_online(&a.device_id, true);
    let got = wait_event(&mut b, std::time::Duration::from_secs(25), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got, "the pending ask must still find its own holder");

    drop(a);
    drop(b);
    drop(c);
}

// 5. The responder side of the rotation: asked for a hash it does not hold, a node
// answers and NAMES it rather than saying nothing and leaving the asker to time out.
// The bundle is empty, and an old client has to be able to decode that.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn emote_request_for_unheld_hashes_answers_missing() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const A_MASTER: u8 = 179;
    const B_MASTER: u8 = 185;
    let a_master = NativeKeypair::from_secret_bytes(&seed_bytes(A_MASTER)).peer_id();
    let b_master = NativeKeypair::from_secret_bytes(&seed_bytes(B_MASTER)).peer_id();

    let a = spawn_node_with_friends(&relay, A_MASTER, A_MASTER, &[&b_master]).await;
    let b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[&a_master]).await;
    expect_dm_pair_ready(&relay, &a, &b, 15).await;

    let (_, hash) = asset_blob(200);
    assert!(
        !a.store().has_emote_blob(&hash).unwrap(),
        "A must not hold the hash we are about to ask it for"
    );

    relay.set_recording(&a.device_id, true);
    let ask = super::types::HavenMessage::EmoteRequest { hashes: vec![hash.clone()] };
    let dm_room = super::types::dm_room_code(&a_master, &b_master);
    relay.inject_direct(
        &dm_room,
        &b.device_id,
        &a.device_id,
        serde_json::to_vec(&ask).expect("serialize EmoteRequest"),
    );

    let answered = wait_until(10, async || {
        frames_of_type(&relay, &a.device_id, "emote_assets")
            .iter()
            .any(|v| {
                v.get("missing")
                    .and_then(|m| m.as_array())
                    .is_some_and(|arr| arr.iter().any(|h| h.as_str() == Some(hash.as_str())))
            })
    })
    .await;
    assert!(answered, "a node that lacks the hash must say so, not stay silent");

    // The empty bundle that reply carries has to survive the ordinary receive
    // path — an old client decodes it and moves on.
    let reply = frames_of_type(&relay, &a.device_id, "emote_assets")
        .into_iter()
        .next()
        .expect("the reply was just asserted");
    let bundle = reply.get("bundle_json").and_then(|b| b.as_str()).unwrap_or("");
    assert!(
        crate::api::showcase::decode_asset_bundle(bundle.as_bytes()).is_empty(),
        "an all-missing reply carries an empty bundle, got {bundle}"
    );

    drop(a);
    drop(b);
}

// 6. Garbage from a holder is a MISS, not the end of the hunt. A holder that answers
// with bytes we refuse used to delete the ask outright, and since the UI asks once a
// session, that ended the search for that hash for good. "Invalid" here is the
// RECORDED KIND's cap, the only kind of invalidity a test can recover from, since
// every honest holder of a hash serves the same bytes.

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::await_holding_lock)] // serializes harness tests; see other tests
async fn asset_pull_rotates_after_invalid_bytes() {
    let _g = test_guard();
    let global_tmp = tempfile::tempdir().expect("global tmp");
    unsafe { std::env::set_var("HOLLOW_DATA_DIR", global_tmp.path()); }

    let relay = MockRelay::new();

    const O_MASTER: u8 = 186;
    const G_MASTER: u8 = 187;
    const B_MASTER: u8 = 188;

    let mut o = spawn_node_with_friends(&relay, O_MASTER, O_MASTER, &[]).await;
    let server_id = create_server_and_wait(&mut o, "Refusal Server").await;

    let g = spawn_node_with_friends(&relay, G_MASTER, G_MASTER, &[]).await;
    g.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    let mut b = spawn_node_with_friends(&relay, B_MASTER, B_MASTER, &[]).await;
    b.cmd_tx
        .send(NodeCommand::RequestPublicChannels { server_id: server_id.clone() })
        .await
        .unwrap();
    let roomed = wait_until(15, async || {
        let devs = relay.room_devices(&server_id);
        devs.contains(&o.device_id) && devs.contains(&g.device_id) && devs.contains(&b.device_id)
    })
    .await;
    assert!(roomed, "all three have to share the server room");

    // A 300 KB blob with a valid WebP container: over the emote ceiling
    // (256 KB) and well under the GIF one (2 MB). BOTH members hold it,
    // because content addressing means every honest holder of a hash holds
    // the same bytes.
    use sha2::{Digest, Sha256};
    let mut big = Vec::with_capacity(300_012);
    big.extend_from_slice(b"RIFF");
    big.extend_from_slice(&300_004u32.to_le_bytes());
    big.extend_from_slice(b"WEBP");
    big.resize(300_012, 0u8);
    let hash = hex::encode(Sha256::digest(&big));
    for holder in [&o, &g] {
        holder
            .store()
            .save_asset_blob(&hash, &big, false, "gif")
            .expect("both members cache the blob");
    }

    let (first_id, second_id) = if o.device_id < g.device_id {
        (o.device_id.clone(), g.device_id.clone())
    } else {
        (g.device_id.clone(), o.device_id.clone())
    };

    drain_events(&mut b);
    relay.set_recording(&b.device_id, true);
    relay.set_recording(&first_id, true);
    relay.set_recording(&second_id, true);

    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Emote,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();

    // THE POINT: the refusal must move the ask to the next holder. Before
    // this it deleted the ask and the count stayed at one forever.
    let rotated = wait_until(20, async || {
        frames_of_type(&relay, &b.device_id, "emote_request").len() >= 2
    })
    .await;
    assert!(
        rotated,
        "refused bytes must move the ask to the next holder, sent {}",
        frames_of_type(&relay, &b.device_id, "emote_request").len()
    );
    assert!(
        !b.store().has_emote_blob(&hash).unwrap(),
        "the over-cap blob must not be cached at either holder"
    );

    let second_answered = wait_until(10, async || {
        frames_of_type(&relay, &second_id, "emote_assets").iter().any(|v| {
            crate::api::showcase::decode_asset_bundle(
                v.get("bundle_json").and_then(|s| s.as_str()).unwrap_or("").as_bytes(),
            )
            .iter()
            .any(|(h, _)| *h == hash)
        })
    })
    .await;
    assert!(
        second_answered,
        "the ask has to reach the second holder, not just leave the first"
    );

    // And the entry is still OURS to re-aim: asked as a GIF, the same
    // surviving ask lands the bytes at a cap that admits them.
    b.cmd_tx
        .send(NodeCommand::RequestEmotes {
            hashes: vec![hash.clone()],
            kind: super::assets::AssetKind::Gif,
            server_id: Some(server_id.clone()),
            peer_hint: None,
        })
        .await
        .unwrap();
    let got = wait_event(&mut b, std::time::Duration::from_secs(20), |ev| {
        matches!(ev, NetworkEvent::EmoteAssetsReceived { hashes } if hashes.contains(&hash))
    })
    .await;
    assert!(got, "the re-aimed ask must land the bytes at the gif cap");
    let cached = wait_until(5, async || {
        b.store().has_emote_blob(&hash).unwrap_or(false)
    })
    .await;
    assert!(cached, "the bytes have to reach the store, not just the event");
    assert_eq!(
        b.store().load_emote_blob(&hash).unwrap().as_deref(),
        Some(big.as_slice()),
        "the landed bytes must match byte-exact"
    );
    let _ = first_id;

    drop(o);
    drop(g);
    drop(b);
}
