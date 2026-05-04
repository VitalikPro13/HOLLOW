# Networking — WebSocket, Gossip, Signaling, Link Preview, Twitch

Covers seven Rust modules in `rust/hollow_core/src/node/` that handle relay communication, binary streaming, peer discovery, gossip overlays, link previews, and Twitch OAuth.

---

## ws_client.rs — WebSocket Relay Client

File: `rust/hollow_core/src/node/ws_client.rs`

### Purpose

Persistent WSS connection to the uWebSockets C++ relay at `relay.anonlisten.com:443`. All text messages (CRDT ops, key exchange, sync) and binary data (file/shard streaming, room broadcasts) flow through this single multiplexed connection. Auto-reconnects with exponential backoff.

### Public Entry Point

`ws_client.rs:spawn_ws_client()` — spawns a `tokio::spawn` background task that runs `ws_client_loop()` forever. Parameters:
- `relay_url` — WSS endpoint
- `peer_id` — local Ed25519 peer ID string
- `keypair_proto` — protobuf-encoded Ed25519 keypair bytes
- `pub_key_b64` — base64 public key
- `license_key` — optional license key for gated relays
- `cmd_rx` — `mpsc::UnboundedReceiver<WsCommand>` from swarm
- `event_tx` — `mpsc::UnboundedSender<WsEvent>` to swarm

### WsCommand Enum (swarm -> WS client)

- `JoinRoom { room_code }` — sends JSON `{"type":"join","room":"..."}` to relay
- `LeaveRoom { room_code }` — sends JSON `{"type":"leave","room":"..."}`
- `SendToRoom { room_code, data }` — binary frame: `[0x03][room_bytes][0x00][data]`. Relay broadcasts to all room members.
- `SendDirect { room_code, target_peer, data }` — binary frame: `[0x04][room_bytes][0x00][target_bytes][0x00][data]`. Relay routes to one peer. Used for shard transfers.
- `SendBinaryDirect { room_code, target_peer, data }` — binary frame: `[0x02][room_bytes][0x00][target_bytes][0x00][data]`. Used for file/shard streaming chunks.

### WsEvent Enum (WS client -> swarm)

- `Connected` — emitted after successful auth handshake
- `Disconnected` — emitted when connection drops (before backoff sleep)
- `PeerJoined { room, peer_id }` — relay notifies a new peer joined a room
- `PeerLeft { room, peer_id }` — relay notifies a peer left
- `RoomMembers { room, peers }` — full member list after joining a room
- `Message { room, from, data }` — decrypted text message payload from relay binary frame type `0x05`
- `DirectMessage { room, from, data }` — direct message from relay binary frame type `0x06`
- `BinaryDirect { room, from, data }` — binary streaming chunk from relay binary frame type `0x02`
- `LicenseError { reason }` — auth failed due to invalid license key; client stops reconnecting
- `RoomBudgetUpdate { joined, limit }` — tracks how many rooms are joined vs the 2000 cap (`ROOM_BUDGET_LIMIT`)
- `RoomCapHit { room }` — server rejected a room join because cap was hit

### Wire Protocol (JSON for control, binary for data)

**ClientMsg** (serde-tagged JSON sent to relay):
- `Auth { peer_id, public_key, timestamp, signature, license_key? }` — first message after WS connect
- `Join { room }` — join a relay room
- `Leave { room }` — leave a relay room

**ServerMsg** (serde-tagged JSON received from relay):
- `AuthOk` — authentication succeeded
- `AuthFailed { error }` — authentication failed
- `PeerJoined { room, peer_id }` — another peer joined
- `PeerLeft { room, peer_id }` — another peer left
- `Members { room, peers }` — initial room member list
- `Error { error }` — server-side error. If message contains "Too many rooms", the client rolls back the `last_join_attempt` room from `joined_rooms` and emits `RoomCapHit`.

### Authentication Flow

`ws_client.rs:connect_and_auth()`:
1. `tokio_tungstenite::connect_async(url)` — establish WSS connection
2. Build sign payload: `"hollow-ws-auth:{peer_id}:{timestamp}"` where timestamp is Unix epoch seconds
3. Sign with Ed25519 via `NativeKeypair::from_protobuf_encoding().sign()`
4. Send `Auth` JSON message with peer_id, public_key (base64), timestamp, signature (base64), optional license_key
5. Wait up to 5 seconds for response
6. `AuthOk` → reunite read/write halves, return stream. `AuthFailed` → return error string

### Connection Lifecycle

`ws_client.rs:ws_client_loop()`:
1. Connect + authenticate via `connect_and_auth()`
2. On success: reset `backoff_secs` to 1, emit `WsEvent::Connected`
3. Re-join all previously tracked rooms from `WsClientState.joined_rooms` (persisted in `Arc<RwLock<HashSet<String>>>`)
4. Flush `pending_commands` buffer (commands received while disconnected)
5. Enter main `tokio::select!` loop:
   - **30s keepalive ping** — sends WS Ping frame `[0x01]`. If send fails, break to reconnect.
   - **Incoming relay messages** — dispatches JSON text to `handle_server_message()`, dispatches binary frames by type byte
   - **Commands from swarm** — calls `send_command()` + `track_room_change()`
6. On disconnect: emit `WsEvent::Disconnected`, drain `cmd_rx` into `pending_commands` buffer
7. Exponential backoff: sleep `backoff_secs` (starts 1, doubles to max 30), then loop back to step 1
8. **License error special case**: if `connect_and_auth` error contains "license_key" or "license key", emit `LicenseError` and `return` (no reconnect)

### Binary Frame Protocol

All data frames are type-prefixed. NUL byte (`0x00`) separates room/peer/payload fields.

**Outbound (client to relay):**
| Type byte | Format | Purpose |
|-----------|--------|---------|
| `0x02` | `[0x02][room][0x00][target][0x00][data]` | Binary direct (file streaming) |
| `0x03` | `[0x03][room][0x00][data]` | Room broadcast |
| `0x04` | `[0x04][room][0x00][target][0x00][data]` | Direct message |

**Inbound (relay to client):**
| Type byte | Format | Emits |
|-----------|--------|-------|
| `0x02` | `[0x02][room][0x00][from][0x00][payload]` | `WsEvent::BinaryDirect` |
| `0x05` | `[0x05][room][0x00][from][0x00][payload]` | `WsEvent::Message` |
| `0x06` | `[0x06][room][0x00][from][0x00][payload]` | `WsEvent::DirectMessage` |

Parsing: `ws_client.rs:parse_binary_relay_frame()` — finds first two NUL bytes to split into (room, from, payload).

### Room Budget Tracking

`ws_client.rs:track_room_change()` — called on every `JoinRoom`/`LeaveRoom` command. Updates `joined_rooms` HashSet and emits `RoomBudgetUpdate { joined, limit: 2000 }`. On `JoinRoom`, also sets `last_join_attempt` (used for rollback on "Too many rooms" error).

`ws_client.rs:handle_server_message()` — on `Error` containing "Too many rooms": removes the last attempted room from `joined_rooms`, emits corrected `RoomBudgetUpdate`, emits `RoomCapHit`.

### State

`WsClientState`:
- `joined_rooms: Arc<RwLock<HashSet<String>>>` — rooms to re-join on reconnect
- `last_join_attempt: Arc<RwLock<Option<String>>>` — for error rollback

---

## ws_stream_transfer.rs — Binary Stream Reassembly

File: `rust/hollow_core/src/node/ws_stream_transfer.rs`

### Purpose

Chunked binary streaming of files, vault shards, and Share chunks over WebSocket `SendBinaryDirect` frames. Replaces the old libp2p Yamux/QUIC streaming. Since WS runs over TCP, chunks arrive in order and reassembly is straightforward.

### Constants

- `WS_CHUNK_SIZE` = 256 KB — max payload per WS binary frame
- `TYPE_FILE` = `0x00` — file transfer
- `TYPE_SHARD` = `0x01` — vault shard transfer
- `TYPE_SHARE_CHUNK` = `0x02` — Hollow Share encrypted chunk
- `TYPE_CONTINUATION` = `0xFF` — continuation chunk (not the first)

### StreamKind Enum

- `File` — P2P file transfer (DM or channel file)
- `Shard { shard_index: u16 }` — vault shard with 2-byte index
- `ShareChunk { chunk_index: u32 }` — Share encrypted chunk with 4-byte index

### Wire Format

**First chunk:**
```
[type:1][id:64][total_size:8][extra...][data...]
```
- `type` — `0x00` (File), `0x01` (Shard), `0x02` (ShareChunk)
- `id` — 64-byte zero-padded ASCII identifier (file_id hex for files, content_id for shards)
- `total_size` — 8-byte LE u64, total transfer size in bytes
- `extra` — 0 bytes for File, 2 bytes LE u16 shard_index for Shard, 4 bytes LE u32 chunk_index for ShareChunk
- `data` — first chunk of actual file data (up to `WS_CHUNK_SIZE - header_len`)

Header sizes: File = 73 bytes (1+64+8), Shard = 75 bytes (1+64+8+2), ShareChunk = 77 bytes (1+64+8+4).

**Continuation chunks:**
```
[0xFF:1][id:64][data...]
```
- Just the continuation marker, the 64-byte padded ID, and raw data bytes
- Continuation data capacity: `WS_CHUNK_SIZE - 65` bytes per chunk

### Sending: ws_stream_transfer.rs:ws_stream_send()

Parameters: `ws_cmd_tx`, `room_code`, `target_peer`, `kind`, `id`, `source_path`, `total_size`.

1. Read entire source file into memory via `std::fs::read()`
2. Build first chunk: type byte + `pad_id(id)` + total_size LE + kind-specific extra + first data slice
3. Send via `WsCommand::SendBinaryDirect`
4. Loop over remaining data in continuation chunks, each prefixed `[0xFF][id:64]`
5. `tokio::task::yield_now().await` between continuation chunks for cooperative backpressure
6. Logs total chunk count on completion

### Receiving: ws_stream_transfer.rs:ws_stream_receive()

Parameters: `pending: &mut HashMap<String, WsTransferState>`, `data: &[u8]`.

Returns `Some(StreamRequest)` when transfer completes, `None` when more chunks needed.

**First chunk path (type 0x00/0x01/0x02):**
1. Parse type, ID (64 bytes, stripped of trailing zeros via `parse_id()`), total_size, kind-specific extra
2. Create temp file at `~/.hollow/files/.ws_recv_{id}.tmp`
3. Write initial payload data
4. If `StreamKind::File`, register in global `stream_progress()` map for UI progress tracking
5. If `bytes_received >= total_size`, single-chunk transfer — call `complete_transfer()` immediately
6. Otherwise insert `WsTransferState` into `pending` map

**Continuation chunk path (type 0xFF):**
1. Parse ID from bytes 1..65
2. Look up `WsTransferState` in `pending` map
3. Write payload to temp file
4. Update `bytes_received` and atomic progress counter
5. If `bytes_received >= total_size`, call `complete_transfer()`

### WsTransferState

Per-transfer receiver state stored in `pending` HashMap keyed by transfer ID:
- `kind: StreamKind`
- `id: String`
- `total_size: u64`
- `bytes_received: u64`
- `temp_file: std::fs::File` — open file handle for writing
- `temp_path: PathBuf` — temp file location
- `progress: Option<Arc<AtomicU64>>` — for File kind only, shared with UI progress tracking

### StreamRequest (completion result)

Returned when all bytes received:
- `kind: StreamKind`
- `id: String` — hex identifier
- `size: u64` — total bytes
- `temp_path: PathBuf` — where the reassembled data lives

### StreamProgress (global progress tracking)

`ws_stream_transfer.rs:stream_progress()` — returns `&'static Mutex<HashMap<String, StreamProgress>>` singleton.

`StreamProgress` struct: `bytes_received: Arc<AtomicU64>`, `total_bytes: u64`. Only registered for `StreamKind::File` transfers. Polled by the swarm event loop to emit `FileProgress` events to the Dart UI. Cleaned up in `complete_transfer()`.

### ID Encoding

- `ws_stream_transfer.rs:pad_id()` — pads string to exactly 64 bytes (zero-filled)
- `ws_stream_transfer.rs:parse_id()` — strips trailing zeros from 64-byte buffer

---

## signaling.rs — Bootstrap Peer Discovery

File: `rust/hollow_core/src/node/signaling.rs`

### Purpose

HTTP-based peer registration and discovery against the relay server (`https://relay.anonlisten.com`). Peers register themselves when joining a room, send heartbeats to stay listed, and bootstrap by querying the relay for other registered peers. All requests are Ed25519-signed to prevent spoofing.

### Constants

- `SIGNALING_URL` = `"https://relay.anonlisten.com"` — base URL for all HTTP endpoints
- `HEARTBEAT_INTERVAL` = 120 seconds — must be less than the relay's 3-minute stale threshold

### Commands and Events

**SignalingCmd** (swarm -> signaling task):
- `Bootstrap { room_code }` — fetch peers for a room
- `SetRoom { room_code }` — set active room for heartbeat registration
- `Unregister { room_code }` — unregister from a room and stop heartbeat

**SignalingEvent** (signaling task -> swarm):
- `BootstrapPeers { peers: Vec<BootstrapPeer> }` — discovered peers with IDs and addresses
- `Error { message }` — any failure

**BootstrapPeer**: `peer_id: String`, `addresses: Vec<String>`

### Background Task

`signaling.rs:spawn_signaling_task()` — takes `NativeKeypair` + `peer_id_str`, returns `(Sender<SignalingCmd>, Receiver<SignalingEvent>)`. Spawns `signaling_loop()`.

`signaling.rs:signaling_loop()`:
- `reqwest::Client` for HTTP
- Encodes public key as base64 protobuf (`keypair.public_key_protobuf()`)
- Tracks `active_room: Option<String>` and `active_addrs: Vec<String>`
- `tokio::select!` on command channel and 120s heartbeat timer
- On `SetRoom` — stores room for heartbeat
- On `Bootstrap` — calls `do_bootstrap()`
- On `Unregister` — calls `do_unregister()`, clears `active_room`
- On heartbeat tick — if `active_room` is Some, calls `do_register()` to re-register (keeps entry fresh)

### HTTP Endpoints

**POST /register** — `signaling.rs:do_register()`
- Payload: `RegisterPayload { room_code, peer_id, addresses (max 5), timestamp, public_key (base64), signature (base64) }`
- Signature payload: `"hollow-register:{room_code}:{peer_id}:{addresses_joined}:{timestamp}"`
- 10-second HTTP timeout
- Addresses are comma-joined for the signature string, capped at 5

**POST /unregister** — `signaling.rs:do_unregister()`
- Payload: `UnregisterPayload { room_code, peer_id, timestamp, public_key (base64), signature (base64) }`
- Signature payload: `"hollow-unregister:{room_code}:{peer_id}:{timestamp}"`
- 10-second HTTP timeout

**GET /bootstrap/{room_code}** — `signaling.rs:do_bootstrap()`
- URL-encodes the room_code via `urlencoding_encode()` (custom percent-encoding for path safety)
- 10-second HTTP timeout
- Response: `BootstrapResponse { peers: Vec<BootstrapPeerWire { peer_id, addresses }> }`
- Maps wire type to `BootstrapPeer`

### URL Encoding

`signaling.rs:urlencoding_encode()` — manual percent-encoding. Preserves `A-Z a-z 0-9 - _ . ~`, percent-encodes everything else as `%XX`. No external dependency.

### Integration with Room Discovery

Signaling is the HTTP complement to the WS relay. The WS relay handles real-time room membership (`PeerJoined`/`PeerLeft`/`Members`), while signaling provides out-of-band bootstrap for peers that haven't joined the WS room yet. The heartbeat keeps the registration alive; the relay's server-side stale timeout (3 minutes) automatically removes dead registrations.

---

## gossip.rs — Gossip Overlay

File: `rust/hollow_core/src/node/gossip.rs`

### Purpose

Per-server gossip overlay that manages which peers to maintain WebRTC data channels with. For small servers (<6 members), every peer connects to every other peer (full mesh). For larger servers, the gossip overlay selects 6-12 "gossip neighbors" based on composite scoring, and messages are relayed through the overlay graph instead of direct full-mesh connections. This keeps WebRTC connection count manageable.

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_GOSSIP_NEIGHBORS` | 6 | Minimum neighbors per server overlay |
| `MAX_GOSSIP_NEIGHBORS` | 12 | Maximum neighbors per server overlay |
| `MAX_TOTAL_WEBRTC` | 50 | Global cap across ALL server overlays |
| `ROTATION_INTERVAL_SECS` | 300 (5 min) | How often neighbor rotation runs |
| `BROADCAST_DEDUP_TTL_SECS` | 60 | Dedup cache entry lifetime |
| `GOSSIP_ACTIVATION_THRESHOLD` | 6 | Server size at which gossip activates |
| `DEFAULT_BROADCAST_TTL` | 4 | Max relay hops for broadcasts |
| `VOICE_GOSSIP_THRESHOLD_UP` | 6 | Voice switches to gossip at this count |
| `VOICE_GOSSIP_THRESHOLD_DOWN` | 4 | Voice switches back to mesh at this count |
| `BROADCAST_FALLBACK_TIMEOUT_SECS` | 30 | Timeout before direct file request fallback |

### PeerScore — Composite Peer Scoring

`gossip.rs:PeerScore` — scoring data per peer per server overlay.

**Fields:**
- `uptime_ratio: f64` — 0.0-1.0, fraction of tracked time the peer was connected
- `avg_latency_ms: f64` — exponential moving average RTT (default 100ms)
- `bandwidth_score: f64` — EMA of bytes/sec throughput from file transfers
- `shard_overlap: u32` — number of vault shards this peer holds that we recently accessed
- `connected_since: Option<Instant>` — None if currently disconnected
- `total_connected_secs: f64` — accumulated connection time
- `total_tracked_secs: f64` — total observation time
- `last_updated: Instant`

**Composite score formula** — `gossip.rs:PeerScore::composite()`:
```
score = (shard_overlap * 0.10)           // each overlap adds 0.10
      + latency_score * 0.30             // 1.0 - (avg_latency_ms / 500).min(1.0)
      + uptime_ratio * 0.20
      + bandwidth_normalized * 0.10      // (bandwidth_score / 10_000_000).min(1.0)
```
Weights: shard overlap is per-shard additive (40% weight at 4 overlaps), latency 30%, uptime 20%, bandwidth 10%.

**Update methods:**
- `PeerScore::refresh_uptime()` — recalculates `uptime_ratio` from accumulated connected/tracked seconds
- `PeerScore::mark_connected()` — calls `refresh_uptime()`, sets `connected_since`
- `PeerScore::mark_disconnected()` — calls `refresh_uptime()`, clears `connected_since`
- `PeerScore::update_latency(rtt_ms)` — EMA with alpha=0.3: `new = 0.3 * rtt + 0.7 * old`
- `PeerScore::update_bandwidth(bytes, duration_secs)` — EMA with alpha=0.3 on throughput (bytes/sec)

### GossipOverlay — Per-Server State

`gossip.rs:GossipOverlay` — one instance per server.

**Fields:**
- `server_id: String`
- `neighbors: HashSet<String>` — current gossip neighbors (WebRTC data channel targets)
- `known_peers: HashSet<String>` — all online peers in this server (superset of neighbors)
- `peer_scores: HashMap<String, PeerScore>`
- `seen_broadcasts: HashMap<String, Instant>` — broadcast dedup cache
- `pending_relays: HashMap<String, PendingRelay>` — waiting for file data after BroadcastMeta arrived via MLS
- `last_rotation: Instant`

### Neighbor Selection

**Initial selection** — `gossip.rs:GossipOverlay::select_initial_neighbors()`:
1. Compute budget: `min(MAX_TOTAL_WEBRTC - global_count, MAX_GOSSIP_NEIGHBORS)`
2. Target: `max(budget, MIN_GOSSIP_NEIGHBORS)` capped by `known_peers.len()`
3. Sort all known peers by composite score descending
4. Take top N as neighbors
5. Returns the selected peer IDs (caller must establish WebRTC connections)

**Auto-add below minimum** — `gossip.rs:GossipOverlay::add_known_peer()`:
- Inserts peer into `known_peers` and ensures a `PeerScore` entry exists
- If `neighbors.len() < MIN_GOSSIP_NEIGHBORS`, adds the peer as a neighbor immediately
- Returns `Some(peer_id)` if the peer was added as a neighbor, `None` otherwise

**Peer removal** — `gossip.rs:GossipOverlay::remove_known_peer()`:
- Removes from `known_peers`
- If the peer was a neighbor, picks the best-scoring non-neighbor as replacement
- Returns `(was_neighbor: bool, replacement: Option<String>)`

### Neighbor Rotation

`gossip.rs:GossipOverlay::rotate()` — called periodically (every 5 minutes via `gossip_relay.rs`).

1. Refreshes uptime for all scored peers
2. **Fill below minimum**: repeatedly picks best non-neighbor until `neighbors.len() >= MIN_GOSSIP_NEIGHBORS`
3. **Trim above maximum**: repeatedly drops worst neighbor until `neighbors.len() <= MAX_GOSSIP_NEIGHBORS`
4. **Swap (when in range [MIN, MAX])**: finds worst neighbor and best non-neighbor. Swaps only if best candidate scores >10% higher than worst neighbor (`best_score > worst_score * 1.1`)
5. At most 1 swap per rotation for stability
6. Returns `(to_connect: Vec<String>, to_disconnect: Vec<String>)`

**Priority peer protection** — `gossip.rs:GossipOverlay::pick_worst_neighbor()`:
- Filters out peers with `shard_overlap >= 3` — they are never candidates for removal
- Among remaining, picks the one with lowest composite score

### Broadcast Dedup

- `gossip.rs:GossipOverlay::should_relay_broadcast(broadcast_id)` — returns `true` (first time) or `false` (duplicate). Inserts into `seen_broadcasts` on first call.
- `gossip.rs:GossipOverlay::mark_broadcast_seen(broadcast_id)` — marks as seen without relay decision (used by originator)
- `gossip.rs:GossipOverlay::evict_stale_broadcasts()` — removes entries older than `BROADCAST_DEDUP_TTL_SECS` (60s). Also evicts `pending_relays` older than `BROADCAST_FALLBACK_TIMEOUT_SECS` (30s).

### Pending Relay System

For gossip file relay: when a `BroadcastMeta` arrives via MLS (metadata about a file being broadcast), the overlay registers a pending relay. When the actual file data arrives via WebRTC data channel, the overlay consumes the pending relay and forwards the file to gossip neighbors.

- `gossip.rs:GossipOverlay::add_pending_relay(file_id, broadcast_id, ttl, origin, channel_id, sender_peer_id)` — registers a pending relay
- `gossip.rs:GossipOverlay::take_pending_relay(file_id)` — consumes and returns the relay info (returns None if not found or already consumed)
- `gossip.rs:GossipOverlay::get_timed_out_relays()` — returns file_ids of relays older than 30s (file never arrived via gossip, need direct fallback)

`PendingRelay` struct: `broadcast_id`, `file_id`, `ttl`, `origin`, `channel_id`, `sender_peer_id`, `created: Instant`.

### Relay Target Selection

- `gossip.rs:GossipOverlay::get_relay_targets(exclude_peer)` — returns all neighbors except the excluded peer (the sender). Used when forwarding a broadcast.
- `gossip.rs:GossipOverlay::get_voice_gossip_neighbors(voice_participants, local_peer_id)` — returns neighbors that are also in the voice channel participant set (intersection). Excludes local peer.

### Voice Channel Gossip Thresholds

Hysteresis pattern to prevent thrashing:
- At `VOICE_GOSSIP_THRESHOLD_UP` (6) participants, voice switches from full mesh to gossip relay
- At `VOICE_GOSSIP_THRESHOLD_DOWN` (4) participants, voice switches back to full mesh
- This 2-participant hysteresis band prevents rapid switching when participants hover around the threshold

### Broadcast ID Generation

`gossip.rs:generate_broadcast_id()` — 16 random bytes via `getrandom::fill()`, hex-encoded to 32 characters.

---

## gossip_relay.rs — Gossip Relay Branching

File: `rust/hollow_core/src/node/gossip_relay.rs`

### Purpose

Timer-driven gossip operations that run from the swarm event loop. Handles broadcast relay, neighbor rotation, dedup eviction, and peer exchange. These are the "do something periodically" functions that operate on the `GossipOverlay` state.

### Functions

#### gossip_relay.rs:handle_webrtc_broadcast_received()

Called when a WebRTC data channel delivers a gossip broadcast from a neighbor.

Parameters: `gossip_overlays`, `event_tx`, `webrtc_peers`, `broadcast_id`, `ttl`, `origin_peer_id`, `sender_peer_id`, `temp_path`, `total_size`, `kind`, `shard_index`.

Flow:
1. Iterate all server overlays looking for one that hasn't seen this `broadcast_id`
2. Call `overlay.should_relay_broadcast(broadcast_id)` — returns true on first match
3. If `ttl > 0`, get relay targets (excluding sender) from the matched overlay
4. For each target that has an active WebRTC connection (`webrtc_peers.contains(target)`), emit `NetworkEvent::GossipRelayFile` with `ttl - 1`
5. Break after first matching overlay (broadcast belongs to one server)
6. If no overlay accepted (already seen everywhere), log and skip

#### gossip_relay.rs:handle_gossip_rotation()

Timer tick handler for neighbor rotation. Called periodically from the swarm event loop.

Flow:
1. Iterate all server overlays
2. Skip overlays where `known_peers.len() < GOSSIP_ACTIVATION_THRESHOLD` (6) — small servers don't need gossip
3. Call `overlay.rotate()` to get `(to_connect, to_disconnect)` lists
4. Emit `NetworkEvent::GossipConnect { peer_id }` for each peer to connect
5. Emit `NetworkEvent::GossipDisconnect { peer_id }` for each peer to disconnect

#### gossip_relay.rs:handle_gossip_eviction()

Timer tick handler for broadcast dedup eviction and relay timeout fallback.

Flow:
1. Iterate all server overlays
2. Get timed-out pending relays (file didn't arrive via gossip within 30s)
3. For each timed-out relay, fall back to direct file request:
   - Check if origin peer is reachable via `crypto_handler::peer_is_reachable()`
   - If reachable, send `HavenMessage::FileProbe { file_id }` to origin via `crypto_handler::send_message_to_peer()`
4. Call `overlay.evict_stale_broadcasts()` to clean up dedup cache and expired pending relays

#### gossip_relay.rs:handle_gossip_exchange()

Timer tick handler for peer exchange protocol. Broadcasts neighbor lists to server rooms.

Flow:
1. Iterate all server overlays
2. Skip overlays with empty neighbor sets
3. Build `HavenMessage::PeerExchange { server_id, peers }` with the overlay's neighbor list
4. Serialize to JSON and send via `WsCommand::SendToRoom` to the server room
5. This lets all room members learn about the overlay topology for better neighbor selection

### Integration with Swarm Event Loop

These four functions are called from `swarm.rs` match arms on timer ticks:
- `handle_gossip_rotation()` — every `ROTATION_INTERVAL_SECS` (300s / 5 min)
- `handle_gossip_eviction()` — periodically (tied to broadcast cleanup interval)
- `handle_gossip_exchange()` — periodically (tied to peer exchange interval)
- `handle_webrtc_broadcast_received()` — on each `WebRtcBroadcastReceived` event

---

## link_preview.rs — URL Link Preview Fetching

File: `rust/hollow_core/src/node/link_preview.rs`

### Purpose

Fetches OpenGraph metadata from URLs typed in the compose box and builds a `LinkPreviewRef` struct embedded in the outgoing message envelope. **Privacy-critical: sender-side only.** Receivers render the embedded preview and NEVER make HTTP requests to the previewed URL. This prevents Hollow from becoming an IP-harvesting amplifier.

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_HTML_BYTES` | 2 MB | HTML response body cap. YouTube ships ~1.2 MB inline, so 1 MB would cut off OG tags. |
| `MAX_IMAGE_BYTES` | 4 MB | OG image response body cap. Typical OG images are <500 KB. |
| `FETCH_TIMEOUT_SECS` | 3 | Total timeout for HTML + image fetches combined |
| `MAX_TITLE_CHARS` | 200 | Unicode character cap for title |
| `MAX_DESC_CHARS` | 400 | Unicode character cap for description |
| `THUMB_MAX_DIM` | 400 px | Max dimension for WebP thumbnail |
| `USER_AGENT` | `"Hollow/0.1 LinkPreview"` | Identifies the fetcher |

### Public API

`link_preview.rs:fetch_link_preview(url)` -> `Result<LinkPreviewRef, String>`

Flow:
1. Parse URL via `reqwest::Url::parse()`. Reject non-http/https schemes.
2. Extract display domain from parsed URL
3. Build `reqwest::Client` with `USER_AGENT`, 3s timeout, max 3 redirects
4. Fetch HTML via `fetch_bounded()` with 2 MB cap
5. Parse OG metadata via `parse_og_metadata()`
6. If `og:image` or `twitter:image` found:
   a. Resolve relative URL against base URL via `parsed.join(img_src)`
   b. Fetch image via `fetch_bounded()` with 4 MB cap
   c. Compress to WebP thumbnail via `image_convert::convert_to_webp_preview()` with 400px max dimension
   d. Base64-encode the WebP bytes
7. Return `LinkPreviewRef { url, title, description, domain, site_name, thumb_webp_b64, thumb_w, thumb_h }`
8. Errors are returned as `Err(String)` — caller silently drops the preview without blocking the message send

### HTML Fetching

`link_preview.rs:fetch_bounded(client, url, max_bytes)`:
1. `client.get(url).send().await`
2. If `Content-Length` header exceeds `max_bytes`, bail early
3. Read full body via `resp.bytes().await`
4. If body length exceeds `max_bytes`, bail
5. Return bytes

### OG Tag Parsing

`link_preview.rs:parse_og_metadata(html)` -> `ParsedMeta`:

Uses the `scraper` crate to parse HTML and select `<meta>` tags.

**Fallback chain:**
- **title**: `og:title` -> `<title>` tag text -> `""`
- **description**: `og:description` -> `<meta name="description">` -> `""`
- **site_name**: `og:site_name` -> `""`
- **image**: `og:image` -> `twitter:image` / `twitter:image:src` -> `None`

Iterates all `<meta>` elements, reads `property` or `name` attribute (lowercased), matches against known OG/Twitter keys.

### Text Truncation

`link_preview.rs:truncate_chars(s, max_chars)` — truncates by Unicode code point count (not byte count). Preserves multi-byte characters (emoji, CJK, etc.) correctly.

### LinkPreviewRef Output Struct

Defined elsewhere (likely `types.rs`), populated by `fetch_link_preview()`:
- `url: String` — original URL
- `title: String` — truncated to 200 chars
- `description: String` — truncated to 400 chars
- `domain: String` — display domain from URL host
- `site_name: String` — from `og:site_name`
- `thumb_webp_b64: Option<String>` — base64 WebP thumbnail
- `thumb_w: Option<u32>` — thumbnail width
- `thumb_h: Option<u32>` — thumbnail height

---

## twitch.rs — Twitch OAuth

File: `rust/hollow_core/src/node/twitch.rs`

### Purpose

Twitch integration for server join gating. Server owners can require that joiners follow or subscribe to a Twitch channel. Uses the OAuth 2.0 Device Code Grant flow (no redirect URI needed, works on all platforms). The joiner proves their Twitch status locally and attaches a `TwitchProof` to their join request; the server validates the proof without making any network calls.

### Constants

- `TWITCH_CLIENT_ID` = `"z3piofwp5qr458qfn0ncn6a501ua05"` — Hollow's registered Twitch application
- `DEVICE_CODE_URL` = `"https://id.twitch.tv/oauth2/device"`
- `TOKEN_URL` = `"https://id.twitch.tv/oauth2/token"`
- `VALIDATE_URL` = `"https://id.twitch.tv/oauth2/validate"`
- `HELIX_BASE` = `"https://api.twitch.tv/helix"`

### Data Types

**TwitchDeviceCodeResponse**: `device_code`, `user_code`, `verification_uri`, `expires_in`, `interval` — returned when starting the device flow. The `user_code` and `verification_uri` are shown to the user in the UI.

**TwitchTokenResponse**: `access_token`, `refresh_token`, `expires_in`, `token_type` — OAuth tokens after successful authorization.

**TwitchValidateResponse**: `client_id`, `login`, `user_id`, `expires_in` — from token validation endpoint. Provides the Twitch user ID and login name.

**TwitchProof**: `twitch_user_id`, `twitch_username`, `followed_at: Option<String>`, `is_subscribed`, `sub_tier: Option<String>`, `timestamp: i64` — attached to server join requests. Generated by the joiner, validated by the server.

**TwitchServerSettings**: `channel_id`, `channel_name`, `min_follow_days`, `require_sub`, `owner_verify` — parsed from `ServerState` CRDT settings.

### TwitchServerSettings::from_server_state()

`twitch.rs:TwitchServerSettings::from_server_state(state)` -> `Option<Self>`

Reads from the CRDT `ServerState.settings` map:
- `twitch_verification_enabled` — must be `"true"` or returns None
- `twitch_channel_id` — must be non-empty or returns None
- `twitch_channel_name` — display name
- `twitch_min_follow_days` — parsed as u32, defaults to 0
- `twitch_require_sub` — `"true"` or false
- `twitch_owner_verify` — `"true"` or false

### Device Code Grant Flow

**Step 1: Start** — `twitch.rs:start_device_flow()` -> `Result<TwitchDeviceCodeResponse, String>`
- POST to `https://id.twitch.tv/oauth2/device` with `client_id` and `scopes: "user:read:follows user:read:subscriptions"`
- Returns device code, user code, verification URI

**Step 2: Poll** — `twitch.rs:poll_for_token(device_code, interval_secs)` -> `Result<TwitchTokenResponse, String>`
- Minimum poll interval: 5 seconds
- POST to token URL with `client_id`, `device_code`, `grant_type: "urn:ietf:params:oauth:grant-type:device_code"`
- On success: parse and return `TwitchTokenResponse`
- On `authorization_pending`: continue polling
- On `slow_down`: increase interval by 5 seconds and continue
- Any other error: return Err

### Token Management

**Refresh** — `twitch.rs:refresh_access_token(refresh_token)` -> `Result<TwitchTokenResponse, String>`
- POST to token URL with `grant_type: "refresh_token"` and the refresh token
- Returns new `TwitchTokenResponse` with fresh access/refresh tokens

**Validate** — `twitch.rs:validate_token(access_token)` -> `Result<TwitchValidateResponse, String>`
- GET to `https://id.twitch.tv/oauth2/validate` with `Authorization: OAuth {token}` header
- Returns user info including `user_id` and `login` name

### Helix API Checks

**Follow check** — `twitch.rs:check_follow(access_token, user_id, broadcaster_id)` -> `Result<Option<String>, String>`
- GET `{HELIX_BASE}/channels/followed?user_id={}&broadcaster_id={}`
- Headers: `Client-Id` and `Authorization: Bearer`
- Returns `Some(followed_at_iso8601)` if following, `None` if not
- Response parsed from `{ data: [{ followed_at }] }`

**Subscription check** — `twitch.rs:check_subscription(access_token, user_id, broadcaster_id)` -> `Result<(bool, Option<String>), String>`
- GET `{HELIX_BASE}/subscriptions/user?broadcaster_id={}&user_id={}`
- 404 = not subscribed (returns `(false, None)`)
- Success: returns `(true, Some(tier))` where tier is e.g. "1000", "2000", "3000"
- Response parsed from `{ data: [{ tier }] }`

### Proof Generation (Joiner-Side)

`twitch.rs:generate_proof(access_token, twitch_user_id, twitch_username, broadcaster_id)` -> `Result<TwitchProof, String>`

1. Call `check_follow()` to get `followed_at`
2. Call `check_subscription()` to get `(is_subscribed, sub_tier)`
3. Timestamp with current Unix epoch seconds
4. Return `TwitchProof` struct

### Proof Validation (Server-Side, Synchronous)

`twitch.rs:validate_proof(proof, settings)` -> `Result<(), String>`

**No network calls** — purely synchronous validation of the proof data.

Checks:
1. `twitch_user_id` must not be empty
2. **Freshness**: proof `timestamp` must be within 5 minutes into the past or 1 minute into the future (`age_secs > 300 || age_secs < -60`)
3. **Follow required**: `followed_at` must be `Some`. If `min_follow_days > 0`, the follow age must meet the threshold.
4. **Subscription required** (if `settings.require_sub`): `is_subscribed` must be true

Error messages include the channel name for user-friendly display.

### ISO 8601 Date Parsing

`twitch.rs:parse_follow_age_days(followed_at)` — calculates days since follow.

`twitch.rs:parse_iso8601_to_epoch(s)` — minimal manual parser for `"YYYY-MM-DDTHH:MM:SSZ"` format. Avoids `chrono` dependency.
- Strips trailing `Z`
- Splits on `T` for date/time
- Splits date on `-` for year/month/day
- Splits time on `:` for hour/min/sec
- Manually accumulates days from 1970 accounting for leap years via `is_leap()`
- Returns Unix epoch seconds

`twitch.rs:is_leap(year)` — standard leap year check: `(year % 4 == 0 && year % 100 != 0) || year % 400 == 0`

---

## Cross-Module Integration Map

### Message Flow: Text Message Through Relay

1. Swarm sends `WsCommand::SendToRoom` or `WsCommand::SendDirect` to `ws_client.rs`
2. `ws_client.rs:send_command()` builds binary frame (`0x03` for room, `0x04` for direct)
3. Relay broadcasts/routes the frame
4. Recipient's `ws_client.rs` receives binary frame type `0x05` (room) or `0x06` (direct)
5. Emits `WsEvent::Message` or `WsEvent::DirectMessage` to swarm

### Message Flow: File/Shard Streaming

1. Sender calls `ws_stream_transfer.rs:ws_stream_send()` with source path
2. First chunk + continuations sent via `WsCommand::SendBinaryDirect` (type `0x02`)
3. Recipient's `ws_client.rs` receives binary frame type `0x02`, emits `WsEvent::BinaryDirect`
4. Swarm calls `ws_stream_transfer.rs:ws_stream_receive()` with the data
5. Returns `Some(StreamRequest)` when all chunks received

### Message Flow: Gossip Broadcast (Large Servers)

1. Originator sends file metadata via MLS (through relay) and file data to gossip neighbors via WebRTC
2. Neighbor receives both: MLS metadata registered via `gossip.rs:add_pending_relay()`, file data via WebRTC
3. When file arrives, `gossip.rs:take_pending_relay()` consumes the pending entry
4. `gossip_relay.rs:handle_webrtc_broadcast_received()` checks dedup and relays to other neighbors with `ttl - 1`
5. If file doesn't arrive within 30s, `gossip_relay.rs:handle_gossip_eviction()` falls back to direct `FileProbe` request

### Peer Discovery Flow

1. Swarm sends `SignalingCmd::SetRoom` to start heartbeat registration
2. Swarm sends `SignalingCmd::Bootstrap` to discover peers
3. `signaling.rs:do_bootstrap()` returns `BootstrapPeers`
4. Simultaneously, `ws_client.rs` receives `WsEvent::PeerJoined`/`WsEvent::RoomMembers` from the relay
5. Both sources feed into the swarm's peer tracking (`ws_room_peers`, `synced_peers`)

### Gossip Overlay Lifecycle

1. Server joined with >6 peers -> `GossipOverlay::new()` + `select_initial_neighbors()`
2. `GossipConnect` events trigger WebRTC data channel establishment
3. Every 5 min: `handle_gossip_rotation()` swaps neighbors based on scores
4. Every tick: `handle_gossip_eviction()` cleans dedup cache, falls back on timed-out relays
5. Periodically: `handle_gossip_exchange()` broadcasts neighbor lists for topology awareness
6. Peer goes offline: `remove_known_peer()` finds replacement neighbor
