# Relay Server — uWebSockets C++ Production Relay

The relay is the ONLY infrastructure component in the entire Hollow distributed system. Every text message, CRDT sync op, MLS key exchange, WebRTC signaling offer, file header, typing indicator, and presence event between peers flows through this single C++ process. It runs on an OVH VPS at `relay.anonlisten.com:443` with native OpenSSL TLS. The relay is zero-knowledge — it routes opaque encrypted payloads between authenticated peers without decrypting or inspecting content.

Source: `relay-uws/src/` (6 source files + 2 headers + `json.hpp`)
Build: CMake, C++20, links against uSockets (static), OpenSSL, libsodium, zlib, pthreads
Binary name: `hollow-relay`

---

## config.h — Configuration

### Config struct

All fields have defaults and can be overridden via CLI args:

| Field | Default | CLI Flag | Description |
|-------|---------|----------|-------------|
| `port` | `443` | `--port` | TLS listen port |
| `public_ip` | (empty) | `--public-ip` | Public IP for signaling responses |
| `domain` | `"relay.anonlisten.com"` | `--domain` | Domain name |
| `keys_file` | `"keys.json"` | `--keys-file` | License keys JSON file path |
| `cert_file` | `/etc/letsencrypt/live/relay.anonlisten.com/fullchain.pem` | `--cert-file` | TLS certificate (fullchain) |
| `key_file` | `/etc/letsencrypt/live/relay.anonlisten.com/privkey.pem` | `--key-file` | TLS private key |
| `turn_secret` | (empty) | env `TURN_SECRET` | HMAC secret for TURN credential generation |

### config.h:parse_args()

Reads CLI flags sequentially. `TURN_SECRET` is loaded from the environment variable (not a CLI arg). Returns a `Config` struct. Calls `print_help()` and `exit(0)` on `--help`.

---

## state.h — Server State

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_CONNS_PER_IP` | 34 | Max simultaneous WS connections per IP |
| `MAX_NEW_CONNS_PER_MIN_PER_IP` | 10 | Max new connections per minute per IP (sliding window) |
| `MAX_GUEST_ROOMS` | 3 | Max rooms a guest can join |
| `GUEST_IDLE_SECS` | 1800 | Guest idle timeout (30 min no binary activity) |
| `GUEST_BINARY_PER_MIN` | 10 | Max 0x03 binary frames per minute for guests |

### PerSocketData (per-connection state)

Attached to every WebSocket via uWebSockets' templated user data. Fields:

| Field | Type | Description |
|-------|------|-------------|
| `peer_id` | `std::string` | Hex-encoded Ed25519 public key, set on auth |
| `authenticated` | `bool` | `false` until auth handshake completes |
| `auth_timer` | `us_timer_t*` | 10-second auth timeout timer, nulled after auth or on close |
| `license_key` | `std::string` | The license key this peer authenticated with (empty if license not required) |
| `is_guest` | `bool` | `true` if auth included `"guest": true` flag. Guests are invisible to members, rate-limited, room-capped |
| `ip_key` | `std::string` | Raw IP address bytes (stored for decrement on close, never logged) |
| `last_binary_activity` | `steady_clock::time_point` | Last 0x03 binary frame timestamp (for guest idle timeout) |
| `binary_frames_this_minute` | `uint32_t` | Guest rate limit counter (reset every 60s) |
| `minute_window_start` | `steady_clock::time_point` | Start of current rate limit window |

### IpState (per-IP connection tracking)

In-memory only — never logged, never persisted. Erased when `active_count` drops to 0.

| Field | Type | Description |
|-------|------|-------------|
| `active_count` | `uint32_t` | Currently open connections from this IP |
| `recent_connects` | `deque<steady_clock::time_point>` | Sliding window of connection timestamps for rate limiting |

### PeerEntry (signaling registration)

Used for HTTP-based peer discovery (bootstrap):

| Field | Type | Description |
|-------|------|-------------|
| `peer_id` | `std::string` | Peer identity |
| `addresses` | `vector<string>` | Network addresses (up to 5) |
| `last_seen` | `uint64_t` | Unix timestamp of last registration |

### WsRoom

```cpp
struct WsRoom {
    std::unordered_map<std::string, SSLWebSocket*> peers;  // peer_id -> ws pointer
};
```

A room is a named group of connected WebSocket peers. Rooms are created implicitly on first join and destroyed when the last peer leaves. The key is the room code string (typically a hex-encoded server ID or DM channel ID).

### ServerStatsCache

Caches `/server-stats` JSON for 5 seconds to avoid re-reading `/proc` on every request:

| Field | Type | Description |
|-------|------|-------------|
| `cached_json` | `string` | Pre-serialized JSON response |
| `fetched_at` | `steady_clock::time_point` | When cache was populated |
| `prev_rx_bytes` / `prev_tx_bytes` | `uint64_t` | Previous sample's network counters |
| `prev_sample_at` | `steady_clock::time_point` | When previous sample was taken |
| `rx_mbps` / `tx_mbps` | `double` | Calculated bandwidth rates |
| `has_prev` | `bool` | Whether a previous sample exists (false on first call) |

`is_fresh()` returns true if cache is less than 5 seconds old.

### RelayState (global server state)

| Field | Type | Description |
|-------|------|-------------|
| `signaling_rooms` | `unordered_map<string, vector<PeerEntry>>` | HTTP signaling: room_code -> registered peers |
| `ws_rooms` | `unordered_map<string, WsRoom>` | WebSocket rooms: room_code -> room with peer map |
| `peer_rooms` | `unordered_map<string, unordered_set<string>>` | Reverse index: peer_id -> set of room codes they're in |
| `peer_sockets` | `unordered_map<string, SSLWebSocket*>` | peer_id -> WebSocket pointer (for license kicks + online count) |
| `ip_states` | `unordered_map<string, IpState>` | Per-IP connection tracking (in-memory only, never logged) |
| `guest_sockets` | `unordered_set<SSLWebSocket*>` | All guest WebSocket pointers (for idle timeout iteration) |
| `guest_count` | `size_t` | Global guest connection counter |
| `license` | `LicenseState` | License key validation state |
| `stats_cache` | `ServerStatsCache` | Cached stats response |

`online_users()` returns `peer_sockets.size() - guest_count` (guests excluded from the count).

### Backpressure

No soft backpressure limit — removed because it silently dropped CRDT sync messages and broke all offline-to-online flows. Hard limit (64 MB) is set via uWebSockets' `.maxBackpressure` in `setup_ws_handler()` as a safety net for dead connections.

### Type alias

```cpp
using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;
```

`true, true` = SSL enabled, server-side. Third template param is the per-socket user data type.

---

## main.cpp — Entry Point

### Initialization sequence

1. **`sodium_init()`** — Initialize libsodium. Fatal exit on failure.
2. **`parse_args()`** — Parse CLI args into `Config` struct.
3. **Banner** — Print port and startup info to stderr.
4. **`RelayState` construction** — Default-constructed (all maps empty).
5. **License loading** — `state.license.load_from_file(config.keys_file)`. Non-fatal if missing (license system disabled).
6. **Signal handlers** — `SIGINT` and `SIGTERM` set `should_shutdown` atomic bool.

### TLS setup

```cpp
auto app = uWS::SSLApp({
    .key_file_name = config.key_file.c_str(),
    .cert_file_name = config.cert_file.c_str(),
    .ssl_prefer_low_memory_usage = 1,
});
```

- `ssl_prefer_low_memory_usage = 1` enables `SSL_MODE_RELEASE_BUFFERS`, which releases read/write buffers when idle — critical for low per-connection memory (contributes to the 13.4 KB/conn figure).

### TLS session resumption

After app creation, the native `SSL_CTX*` is extracted and configured for server-side session caching:

```cpp
SSL_CTX_set_session_cache_mode(ssl_ctx, SSL_SESS_CACHE_SERVER);
SSL_CTX_sess_set_cache_size(ssl_ctx, 20000);
```

Reconnecting clients reuse cached TLS session keys for ~10x faster handshakes. Cache holds 20,000 sessions.

### Handler setup

- `setup_ws_handler(app, state)` — Registers the `/ws` WebSocket endpoint.
- `setup_http_handlers(app, state, config)` — Registers all HTTP routes.

### Listen and timers

On successful bind to `config.port`, three timers are created on the uWS event loop:

| Timer | Interval | Callback | Purpose |
|-------|----------|----------|---------|
| License reload | 30,000 ms | `s->license.try_reload(*s)` | Hot-reload `keys.json`, kick peers with revoked keys |
| Signaling cleanup | 120,000 ms | `cleanup_stale_signaling(*s)` | Remove HTTP signaling entries older than 180s |
| Guest idle | 60,000 ms | Iterate `guest_sockets`, close idle guests | Disconnect guests with >30 min no binary activity |
| Shutdown check | 1,000 ms | Check `should_shutdown` atomic | Close listen socket on SIGINT/SIGTERM |

Timer state pointers are stored via `us_timer_ext()` — each timer gets a `sizeof(RelayState*)` or `sizeof(void*)` block to hold a pointer to the state or listen socket.

### main.cpp:cleanup_stale_signaling()

Iterates all `signaling_rooms`, removes `PeerEntry` records where `now - last_seen >= 180` seconds. Deletes empty rooms from the map.

### Graceful shutdown

When `should_shutdown` is true (from SIGINT/SIGTERM):
1. The shutdown timer closes the listen socket via `us_listen_socket_close()`.
2. The timer closes itself.
3. `app.run()` returns when the event loop drains.
4. Process exits cleanly.

Fatal: if the port bind fails, the process calls `exit(1)` immediately.

---

## crypto.cpp / crypto.h — Cryptographic Operations

### crypto.cpp:verify_ed25519()

Verifies an Ed25519 signature for WebSocket and HTTP authentication.

**Parameters:** `pubkey_b64` (base64-encoded protobuf-wrapped public key), `sig_b64` (base64 signature), `message` (plaintext message that was signed).

**Key format:** The public key is NOT raw 32 bytes. It's a 36-byte protobuf-wrapped key:
- Bytes 0-3: protobuf header `08 01 12 20` (Ed25519 key type tag + 32-byte length prefix)
- Bytes 4-35: raw Ed25519 public key (32 bytes)

This matches the key format used by Hollow's Rust `NativeKeypair` (libp2p-compatible protobuf encoding).

**Process:**
1. Base64-decode `pubkey_b64` into 36 bytes. Reject if length != 36.
2. Validate protobuf header bytes. Reject if wrong.
3. Extract 32-byte Ed25519 key from offset 4.
4. Base64-decode `sig_b64` into 64 bytes. Reject if length != 64.
5. Call `crypto_sign_verify_detached()` (libsodium). Return true on success.

Uses `sodium_base64_VARIANT_ORIGINAL` (standard base64, not URL-safe).

### crypto.cpp:hmac_sha1_base64()

Generates HMAC-SHA1 for TURN credential generation (coturn time-limited credentials protocol).

**Parameters:** `secret` (shared TURN secret), `message` (the username string `"expiry:hollow"`).

**Process:**
1. Compute HMAC-SHA1 using OpenSSL `HMAC()` with `EVP_sha1()`.
2. Base64-encode the 20-byte result using libsodium's `sodium_bin2base64()`.
3. Return the base64 string.

### crypto.cpp:hex_encode()

Converts binary data to lowercase hex string. Used to convert 32-byte binary room IDs from binary WebSocket frames into room code strings for map lookups.

### crypto.cpp:now_unix_secs()

Returns current Unix timestamp in seconds using `std::chrono::system_clock`. Used for timestamp validation, TURN credential expiry, and signaling entry staleness.

---

## license.cpp / license.h — License Key System

### LicenseResult enum

| Value | Meaning |
|-------|---------|
| `Ok` | Key is valid and has been reserved for this peer |
| `NotRequired` | License system is disabled (`enabled = false`) |
| `InvalidKey` | Key not found in the valid key set |
| `KeyInUse` | Key is valid but already bound to a different peer_id |
| `KeyRequired` | License system is enabled but no key was provided |

### LicenseState struct

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | `bool` | Whether license enforcement is active |
| `keys` | `unordered_set<string>` | Set of valid license key strings |
| `active_keys` | `unordered_map<string, string>` | license_key -> peer_id mapping for in-use keys |
| `file_path` | `string` | Path to keys.json (saved for reload) |
| `last_mtime` | `time_t` | Last modification time of keys.json (for change detection) |

### keys.json format

```json
{
  "enabled": true,
  "keys": ["key1", "key2", "key3"]
}
```

### license.cpp:load_from_file()

Initial load on startup:
1. Open and read the JSON file.
2. Parse `enabled` boolean (defaults to `false`).
3. Parse `keys` array into the `keys` set.
4. Record `last_mtime` via `stat()` for change detection.
5. Log key count and enabled status to stderr.
6. Returns `false` if file doesn't exist or can't be parsed (non-fatal — license system stays disabled).

### license.cpp:validate_key()

Called during WebSocket auth (`handle_auth()`):
1. If `!enabled`, return `NotRequired` (all peers connect freely).
2. If no key provided (`key == nullptr || key->empty()`), return `KeyRequired`.
3. If key not in `keys` set, return `InvalidKey`.
4. If key is in `active_keys` mapped to a DIFFERENT peer_id, return `KeyInUse`.
5. Otherwise, bind the key to this peer_id in `active_keys` and return `Ok`.

One key can be reused by the same peer_id (reconnection). One key cannot be shared across different peer_ids simultaneously.

### license.cpp:release_key()

Called when a peer disconnects (`cleanup_peer()`). Iterates `active_keys` and removes all entries where `value == peer_id`. A peer could theoretically hold multiple keys (though the current client sends only one).

### license.cpp:try_reload()

Called every 30 seconds by the license reload timer:
1. `stat()` the keys file. If `st_mtime == last_mtime`, return (no change).
2. Re-read and parse the JSON file.
3. Build a new key set.
4. **Revocation check:** For every `(license_key, peer_id)` in `active_keys`, if `license_key` is NOT in the new key set, add `peer_id` to `peers_to_kick`.
5. Update `enabled`, `keys`, and `last_mtime`.
6. Remove kicked peers from `active_keys`.
7. **Active connection revocation:** For each peer to kick, look up their `SSLWebSocket*` in `state.peer_sockets`, send `{"type":"auth_failed","error":"invalid_license_key"}`, and call `ws->end(1008, "license_revoked")`. This triggers the close handler which calls `cleanup_peer()`.

The 30-second reload cycle means key revocation takes at most 30 seconds to take effect on active connections.

---

## ws_handler.cpp / ws_handler.h — WebSocket Handler

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `TIMESTAMP_SKEW_SECS` | 60 | Max allowed clock skew for auth timestamps |
| `MAX_ROOMS_PER_PEER` | 2000 | Maximum rooms a single peer can join |

### ws_handler.cpp:setup_ws_handler() — WebSocket endpoint configuration

Registers the `/ws` endpoint with these settings:

| Setting | Value | Description |
|---------|-------|-------------|
| `.compression` | `uWS::DISABLED` | No per-message compression (content is already encrypted) |
| `.maxPayloadLength` | `64 * 1024 * 1024` (64 MB) | Maximum single message size. NEVER lower — ChannelSyncBatch can exceed 2 MB after MLS+base64. Silently kills connections if exceeded. |
| `.idleTimeout` | `120` seconds | Connection closed if no data (including pings) for 120s |
| `.maxBackpressure` | `64 * 1024 * 1024` (64 MB) | Hard backpressure limit — uWS force-closes truly dead connections at this threshold |
| `.sendPingsAutomatically` | `true` | uWS sends WebSocket pings automatically |

### Connection lifecycle

#### .open handler

When a new WebSocket connects:
1. Initialize `rate_last_refill` to `now`.
2. Create a 10-second one-shot timer (`auth_timer`). If the peer hasn't authenticated within 10 seconds:
   - Detach `auth_timer` pointer from `PerSocketData` BEFORE calling `end()` (prevents double-free since `end()` triggers the close handler).
   - Send `{"type":"auth_failed","error":"Authentication failed"}`.
   - Close with code 1008 reason "auth_timeout".
   - Close the timer.

#### .message handler

1. If `!authenticated`: route to `handle_auth()`. First message MUST be auth.
2. If `TEXT` opcode: reject if >1 MB (silent drop). Route to `handle_text_message()`.
3. If `BINARY` opcode:
   - Dispatch on first byte:
     - `0x01` -> `handle_binary_broadcast()` — room broadcast via 32-byte room hash
     - `0x02` -> `handle_binary_direct()` — peer-to-peer direct via NUL-delimited fields
     - `0x03` -> `handle_binary_msg()` — room broadcast via NUL-delimited room string
     - `0x04` -> `handle_binary_direct_msg()` — peer-to-peer direct via NUL-delimited fields
   - Unknown first bytes are silently ignored.

#### .drain handler

Empty (no-op).

#### .close handler

1. If `auth_timer` is set, close it and null the pointer.
2. If `authenticated`, call `cleanup_peer()` to remove from all rooms and notify peers.

### ws_handler.cpp:handle_auth() — Authentication

Authentication protocol (first message after WebSocket open):

**Expected JSON:**
```json
{
  "type": "auth",
  "peer_id": "<hex-encoded Ed25519 public key>",
  "public_key": "<base64-encoded protobuf-wrapped Ed25519 public key>",
  "timestamp": <unix_seconds>,
  "signature": "<base64-encoded Ed25519 signature>",
  "license_key": "<optional license key string>"
}
```

**Validation steps:**
1. Parse JSON. Reject on parse failure.
2. Check `type == "auth"`. Reject otherwise.
3. Validate `peer_id`, `public_key`, `signature` are non-empty. Reject if any missing.
4. Check timestamp skew: `|now - timestamp| <= 60s`. Reject if too far.
5. Build signed message: `"hollow-ws-auth:" + peer_id + ":" + timestamp`.
6. Verify Ed25519 signature via `verify_ed25519()`. Reject if invalid.
7. Validate license key via `state.license.validate_key()`. Handle all `LicenseResult` cases:
   - `Ok` / `NotRequired`: continue.
   - `InvalidKey`: send `{"type":"auth_failed","error":"invalid_license_key"}`, close with "bad_license".
   - `KeyInUse`: send `{"type":"auth_failed","error":"license_key_in_use"}`, close with "bad_license".
   - `KeyRequired`: send `{"type":"auth_failed","error":"license_key_required"}`, close with "bad_license".

**On success:**
1. Set `data->peer_id`, `data->authenticated = true`, `data->license_key`.
2. Cancel auth timeout timer.
3. Register peer in `state.peer_rooms[peer_id]` (empty room set) and `state.peer_sockets[peer_id]`.
4. Send `{"type":"auth_ok"}`.

All auth failures send `{"type":"auth_failed","error":"Authentication failed"}` (generic, no information leak) except license-specific errors which have distinct error strings. Close code is always 1008.

### ws_handler.cpp:is_valid_room_code()

Room code validation:
- Not empty, max 128 characters.
- Allowed characters: alphanumeric, `:`, `-`, `_`, `.`.

### ws_handler.cpp:send_json()

Helper: serializes `nlohmann::json` to string and sends as TEXT opcode. No backpressure check (used for control messages).

### ws_handler.cpp:send_to_peer()

The CRITICAL message delivery function. All routed messages go through this:

```cpp
ws->send(data, op);
```

No soft limit — sends unconditionally. `maxBackpressure` (64 MB) is the only safety net for dead connections. Previous soft limit (2 MB) silently dropped CRDT sync responses and broke all offline-to-online flows.

### ws_handler.cpp:handle_join() — Room join

**Input:** `{"type":"join","room":"<room_code>"}`

**Process:**
1. Validate room code via `is_valid_room_code()`.
2. Check peer hasn't exceeded `MAX_ROOMS_PER_PEER` (2000). Error if so.
3. Collect list of existing peer IDs in the room.
4. Add this peer to `ws_rooms[room].peers[peer_id]`.
5. Add room to `peer_rooms[peer_id]`.
6. Send `members` message to the joiner containing ALL peers (including self):
   ```json
   {"type":"members","room":"<room>","peers":["peer1","peer2","self"]}
   ```
7. Send `peer_joined` to every OTHER peer in the room:
   ```json
   {"type":"peer_joined","room":"<room>","peer_id":"<joiner>"}
   ```

Room creation is implicit — joining a room that doesn't exist creates it.

### ws_handler.cpp:leave_room() — Room leave

Called explicitly via `{"type":"leave","room":"..."}` or implicitly on disconnect.

**Process:**
1. Remove peer from `ws_rooms[room].peers`.
2. If room is now empty, delete it from `ws_rooms`.
3. Remove room from `peer_rooms[peer_id]`.
4. If room still has peers, send `peer_left` to all remaining:
   ```json
   {"type":"peer_left","room":"<room>","peer_id":"<leaver>"}
   ```

### ws_handler.cpp:handle_msg() — Room text broadcast

**Input:** `{"type":"msg","room":"<room>","data":"<payload>"}`

**Process:**
1. Find the room. Return silently if room doesn't exist.
2. Verify the sender is a member of the room. Return silently if not.
3. Broadcast to ALL other peers in the room:
   ```json
   {"type":"msg","room":"<room>","from":"<sender_peer_id>","data":"<payload>"}
   ```

The `data` field contains opaque encrypted content (MLS ciphertext, Olm ciphertext, plaintext HavenMessage JSON — the relay doesn't know or care).

### ws_handler.cpp:handle_direct() — Peer-to-peer text direct

**Input:** `{"type":"direct","room":"<room>","target":"<target_peer_id>","data":"<payload>"}`

**Process:**
1. Find the room. Return silently if not found.
2. Verify sender is in the room. Return silently if not.
3. Find target in the room. Return silently if not found.
4. Send to target only:
   ```json
   {"type":"direct","room":"<room>","from":"<sender_peer_id>","data":"<payload>"}
   ```

Used for: Olm key exchange (DMs), WebRTC signaling offers/answers, friend requests, direct sync probes.

### ws_handler.cpp:handle_text_message() — Text message dispatcher

Parses JSON and dispatches on `type` field:
- `"join"` -> `handle_join()`
- `"leave"` -> `leave_room()`
- `"msg"` -> `handle_msg()`
- `"direct"` -> `handle_direct()`
- `"check_peers"` -> inline handler: accepts `peers` (array of peer IDs) and `rooms` (array of room IDs), does O(1) hashmap lookups against `peer_sockets` and `ws_rooms`, returns `{"type":"peer_status","online":[...],"active_rooms":[...]}`. Used by the 60s client-side peer liveness timer for offline friend self-healing. No privacy leak — relay already knows all peer connections and room memberships.
- `"subscribe"` -> `handle_subscribe()`

Unknown types are silently ignored. Invalid JSON is silently ignored.

### Binary message protocol

Binary messages use a type-byte prefix system for zero-copy routing. Four binary message types exist:

#### Type 0x01 — Binary room broadcast (hash-addressed)

**Frame:** `[0x01][32-byte room hash][payload]`

`handle_binary_broadcast()`:
1. Minimum size check: > 33 bytes.
2. Extract 32 bytes starting at offset 1 — this is the raw binary room hash.
3. Hex-encode the 32 bytes to get the room code string for map lookup.
4. Broadcast the ENTIRE raw frame (including type byte and room hash) to all other peers in the room.

Used for: MLS-encrypted `MessageEnvelope` broadcasts (the room hash is the server ID).

#### Type 0x02 — Binary peer-to-peer direct

**Frame:** `[0x02][room_code\0][target_peer_id\0][payload]`

`handle_binary_direct()`:
1. Parse room code (from offset 1 to first NUL).
2. Parse target peer ID (from after first NUL to second NUL).
3. Extract payload (everything after second NUL).
4. **Rewrite the frame:** Replace the target peer ID with the sender's peer ID, so the receiver knows who sent it:
   ```
   Forwarded: [0x02][room_code\0][sender_peer_id\0][payload]
   ```
5. Route to the target peer only.

Used for: Olm-encrypted DM payloads, WebRTC binary signaling, file stream chunks.

#### Type 0x03 — Binary room broadcast (string-addressed)

**Frame:** `[0x03][room_code\0][payload]`

`handle_binary_msg()`:
1. Parse room code (from offset 1 to NUL).
2. Verify sender is in the room.
3. **Rewrite to type 0x05:** Build forwarded frame:
   ```
   Forwarded: [0x05][room_code\0][sender_peer_id\0][payload]
   ```
4. Broadcast to all other peers in the room.

The type change from 0x03 to 0x05 lets receivers distinguish "this is a forwarded broadcast" from "this is a client-originated broadcast." The sender's peer_id is injected by the relay (cannot be spoofed by the sender).

#### Type 0x04 — Binary peer-to-peer direct (string-addressed)

**Frame:** `[0x04][room_code\0][target_peer_id\0][payload]`

`handle_binary_direct_msg()`:
1. Parse room code (from offset 1 to first NUL).
2. Parse target peer ID.
3. Extract payload.
4. Verify sender is in the room.
5. Verify target is in the room.
6. **Rewrite to type 0x06:** Build forwarded frame:
   ```
   Forwarded: [0x06][room_code\0][sender_peer_id\0][payload]
   ```
7. Route to target peer only.

The type change from 0x04 to 0x06 lets receivers distinguish forwarded direct messages. Sender identity is relay-injected.

### Binary type byte summary

| Client sends | Relay forwards as | Mode | Room addressing |
|-------------|-------------------|------|-----------------|
| `0x01` | `0x01` (unchanged) | Broadcast | 32-byte binary hash |
| `0x02` | `0x02` (target->sender rewrite) | Direct | NUL-delimited string |
| `0x03` | `0x05` (type change + sender inject) | Broadcast | NUL-delimited string |
| `0x04` | `0x06` (type change + sender inject) | Direct | NUL-delimited string |
| `0x08` | `0x06` (same as 0x04) | Direct (image) | NUL-delimited string |

The 0x01 broadcast is the only type that doesn't rewrite — it forwards the entire frame as-is (the sender identity is embedded in the encrypted MLS payload, not the routing header). `0x08` is identical to `0x04` on the wire/forward path — the only difference is the offline buffer tags it `is_image` so it counts against the per-peer image cap (1) instead of the text cap (100). Used for offline inlined-image delivery (see Push notifications section).

### ws_handler.cpp — Binary rate limiting (REMOVED)

Previously used a token bucket algorithm (removed — broke reconnection bursts):
- Bucket capacity: 100 tokens.
- Refill rate: 20 tokens/second.
- Cost: 1 token per binary message.
- On each binary message, calculate elapsed time since last refill, add `elapsed * 20` tokens (capped at 100), then consume 1 token.
- If bucket is empty (0 tokens), the message is silently dropped (no error sent to client).

This limits binary messages to a burst of 100 + sustained 20/second. Text messages have a 1 MB size cap but are NOT rate-limited (text frames are only small JSON commands: join/leave/subscribe, and the reconnection burst is too heavy to cap without breaking sync).

### ws_handler.cpp:cleanup_peer() — Disconnect cleanup

Called from the close handler when an authenticated peer disconnects:
1. `state.license.release_key(peer_id)` — Free the license key.
2. `state.peer_sockets.erase(peer_id)` — Remove from global socket map.
3. Copy the peer's room set (since `leave_room` modifies it during iteration).
4. Call `leave_room()` for each room — removes peer from room, notifies remaining peers with `peer_left`, deletes empty rooms.
5. `state.peer_rooms.erase(peer_id)` — Remove reverse index.

---

## http_handlers.cpp / http_handlers.h — HTTP Endpoints

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_PEERS_PER_ROOM` | 50 | Max signaling peers per room |
| `MAX_ADDRS_PER_PEER` | 5 | Max addresses per peer registration |
| `STALE_THRESHOLD_SECS` | 180 | Entries older than 3 min are stale |
| `TIMESTAMP_SKEW_SECS` | 60 | Max clock skew for signed requests |
| `MAX_BOOTSTRAP_PEERS` | 10 | Max peers returned by bootstrap |

### CORS

All HTTP responses include:
```
Access-Control-Allow-Origin: *
Content-Type: application/json
```

A global OPTIONS handler at `/*` responds with:
```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

### POST /register — Peer registration (signaling)

**Request body:**
```json
{
  "room_code": "<string, max 64 chars>",
  "peer_id": "<string>",
  "addresses": ["addr1", "addr2"],
  "timestamp": <unix_seconds>,
  "public_key": "<base64 protobuf Ed25519 public key>",
  "signature": "<base64 Ed25519 signature>"
}
```

**Signed message format:** `"hollow-register:" + room_code + ":" + peer_id + ":" + addresses_joined + ":" + timestamp`

Where `addresses_joined` is comma-separated (e.g., `"addr1,addr2"`).

**Process:**
1. Validate `room_code` (non-empty, max 64), `addresses` (non-empty), `peer_id`, `public_key`, `signature`.
2. Check timestamp skew (<= 60s).
3. Truncate addresses to 5 entries.
4. Verify Ed25519 signature.
5. Clean stale entries (>= 180s old) from the room.
6. Upsert: if peer already registered, update addresses and timestamp. If new:
   - If room is full (>= 50 peers), evict the oldest entry.
   - Add new entry.
7. Return `{"ok":true,"peers_in_room":<count>}`.

**Error responses:** 400 for validation, 403 for timestamp skew or bad signature.

Uses `res->onData()` streaming pattern for POST body (uWebSockets doesn't buffer POST bodies by default).

### POST /unregister — Peer unregistration (signaling)

**Request body:**
```json
{
  "room_code": "<string>",
  "peer_id": "<string>",
  "timestamp": <unix_seconds>,
  "public_key": "<base64 key>",
  "signature": "<base64 signature>"
}
```

**Signed message format:** `"hollow-unregister:" + room_code + ":" + peer_id + ":" + timestamp`

**Process:**
1. Validate fields, check timestamp, verify signature (same as register).
2. Find the room in `signaling_rooms`.
3. Remove the entry with matching `peer_id`.
4. If the room is now empty, delete it.
5. Return `{"ok":true}`.

### GET /bootstrap/:room_code — Peer discovery

**URL parameter:** `room_code` (max 64 chars).

**Process:**
1. Look up room in `signaling_rooms`.
2. If not found, return `{"peers":[]}`.
3. Iterate entries, skip stale ones (>= 180s old).
4. Return up to `MAX_BOOTSTRAP_PEERS` (10) entries:
   ```json
   {"peers":[{"peer_id":"...","addresses":["..."]}]}
   ```

No authentication required — room codes are unguessable (derived from server/channel IDs).

### GET /health — Health check

Returns: `{"status":"ok","service":"hollow-signaling"}`

No authentication, no state access. Used for uptime monitoring.

### GET /turn-credentials — TURN credential generation

Returns time-limited TURN credentials for WebRTC media relay.

**Process:**
1. If `config.turn_secret` is empty, return 503 `{"error":"TURN not configured"}`.
2. Calculate expiry: `now + 3600` (1 hour TTL).
3. Build username: `"<expiry>:hollow"` (coturn time-limited format).
4. Compute password: `HMAC-SHA1(turn_secret, username)` base64-encoded.
5. Return:
   ```json
   {
     "username": "1714876800:hollow",
     "password": "<base64 HMAC>",
     "ttl": 3600,
     "uris": [
       "turn:relay.anonlisten.com:3478",
       "turn:relay.anonlisten.com:3478?transport=tcp",
       "turns:relay.anonlisten.com:5349"
     ]
   }
   ```

The three TURN URIs cover: UDP (fastest), TCP fallback, and TLS-wrapped (for restrictive networks). The Dart client MUST split these into separate `IceServer` entries due to flutter_webrtc's native `CreateIceServers` limitations.

### GET /server-stats — Server statistics

Returns real-time server resource utilization. Cached for 5 seconds.

**Data sources (Linux-specific):**
- `/proc/meminfo` — `MemTotal` and `MemAvailable` (in KB).
- `/proc/net/dev` — Network interface `ens16` (OVH VPS interface name) rx/tx byte counters.

**Bandwidth calculation:**
- Compares current byte counters with previous sample.
- Calculates Mbps: `(delta_bytes * 8) / (elapsed_seconds * 1,000,000)`.
- Skips calculation if elapsed < 0.5s (uses previous values).

**Response:**
```json
{
  "mem_total_kb": 8167352,
  "mem_used_kb": 1234567,
  "rx_mbps": 12.34,
  "tx_mbps": 5.67,
  "bandwidth_cap_mbps": 400,
  "online_users": 42
}
```

`bandwidth_cap_mbps` is hardcoded to 400 (the OVH VPS bandwidth allocation). `online_users` comes from `state.peer_sockets.size() - guest_count` (excludes guest connections).

### GET /relay-status — Relay status for client bootstrap

**Response:**
```json
{
  "license_required": true,
  "version": "0.1.0"
}
```

The Dart client checks this endpoint on startup. If `license_required` is true and the user hasn't cached a key, the app shows the license key input dialog.

---

## Build System (CMakeLists.txt)

**C++20**, C11 for uSockets.

**Dependencies (linked):**
- `uSockets` — Built as a static library from vendored source with `LIBUS_USE_OPENSSL`.
- `ssl` + `crypto` — OpenSSL for TLS and HMAC.
- `sodium` — libsodium for Ed25519 verification and base64.
- `z` — zlib (uWebSockets dependency, even though compression is disabled for the WS endpoint).
- `pthread` — Threading.

**uSockets eventing:** Compiles `epoll_kqueue.c`, `gcd.c`, and `libuv.c` — the correct backend is selected at compile time based on the platform. On Linux (production), epoll is used.

**Source files compiled:**
- `main.cpp`, `crypto.cpp`, `license.cpp`, `http_handlers.cpp`, `ws_handler.cpp`

**Include paths:**
- `uWebSockets/src` — uWebSockets headers
- `uSockets/src` — uSockets headers
- `src` — Project headers (including vendored `json.hpp`)

---

## BENCHMARK.md — Performance Data

### Test environment

OVH VPS: 4 vCPU, 8 GB RAM, Ubuntu. Relay is single-threaded epoll.

### Test methodology

Custom Rust stress test tool (`bench/stress_test/`):
- Each connection: open TLS WebSocket, authenticate with unique Ed25519 keypair, hold idle.
- Ramp: batches of 500, 100 concurrent TLS handshakes.
- Measurement: relay process RSS via `ps -o rss=` at 5-second intervals.
- Client uses `rustls` with shared `ClientConfig` (~28 KB/conn client-side vs ~700 KB with OpenSSL).

### Key results

- **13.4 KB per connection** (stabilized from 15k to 44.6k, perfectly linear).
- **44,600 simultaneous connections** — bottleneck was client-side port exhaustion, NOT relay capacity.
- **0 connection failures, 0 drops.**
- **Single-threaded** — all 44.6k connections on one epoll thread.

### Capacity estimates

| VPS RAM | Max Connections |
|---------|-----------------|
| 8 GB | ~572,000 |
| 12 GB | ~878,000 |
| 16 GB | ~1,183,000 |

Based on 13.4 KB/conn with ~200 MB reserved for OS + relay baseline.

### Memory progression

RSS grows linearly: 45 MB at 1k connections -> 614 MB at 44.6k. No memory cliffs, fragmentation, or degradation.

### System tuning for high connection counts

```bash
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = "1024 65535"
ulimit -n 500000
```

---

## Message flow: complete path of a chat message

1. Sender's Rust `node/` encrypts the message with MLS and sends a binary frame: `[0x01][32-byte server_id][MLS ciphertext]`.
2. Rust `ws_client.rs` sends this over the WSS connection to `relay.anonlisten.com:443/ws`.
3. Relay's `.message` handler receives it as `BINARY` opcode.
4. First byte is `0x01` -> `handle_binary_broadcast()`.
6. Bytes 1-32 are hex-encoded to get the room code (server ID).
7. The room is looked up in `ws_rooms`.
8. The entire raw frame is forwarded via `send_to_peer()` to every other peer in the room.
9. `send_to_peer()` checks each recipient's `getBufferedAmount()` < 2 MB soft limit.
10. Each recipient's Rust `ws_client.rs` receives the binary frame, strips the type byte and room hash, decrypts with MLS.

---

## Docker self-hosting

Files in `relay-uws/`: `Dockerfile`, `docker-compose.yml`, `.env.example`, `turnserver.conf.example`.

Docker Compose runs three services:
- **relay** — builds from Dockerfile (multi-stage: debian bookworm build → slim runtime), TLS on port 443, certs from shared volume
- **certbot** — auto-provisions Let's Encrypt certs, renews every 12h, copies to shared volume
- **coturn** — TURN server on host network (ports 3478/5349)

Self-hoster setup: `cp .env.example .env` (edit domain/IP/secret), `cp turnserver.conf.example turnserver.conf` (edit realm/secret), `docker compose up -d`.

The relay binary is SSL-only (`uWS::SSLApp`) — cannot run without TLS certs. No `--no-tls` mode exists. This is intentional: every self-hosted relay is TLS-secured by default.

---

## Error conditions and failure modes

| Condition | Behavior |
|-----------|----------|
| Auth not sent within 10s | `auth_timeout`, connection closed 1008 |
| Invalid auth JSON | `auth_failed`, connection closed 1008 |
| Bad Ed25519 signature | `auth_failed`, connection closed 1008 |
| Timestamp skew > 60s | `auth_failed`, connection closed 1008 |
| License key required but missing | `license_key_required`, connection closed 1008 |
| License key invalid | `invalid_license_key`, connection closed 1008 |
| License key in use by another peer | `license_key_in_use`, connection closed 1008 |
| IP has ≥34 active connections | `ip_limit`, connection closed 1008 (pre-auth) |
| IP opened ≥10 connections in last 60s | `rate_limit`, connection closed 1008 (pre-auth) |
| Guest joins > 3 rooms | `{"type":"error","error":"Guest room limit reached"}` |
| Guest sends 0x04 (SendDirect) | Silently dropped |
| Guest sends >10 binary 0x03 frames/min | Silently dropped |
| Guest idle >30 min (no binary activity) | `guest_idle`, connection closed 1008 |
| Peer joins > 10,000 rooms | `{"type":"error","error":"Too many rooms"}` |
| Invalid room code | `{"type":"error","error":"Invalid room code"}` |
| Message to non-existent room | Silently dropped |
| Message from non-member | Silently dropped |
| Direct to offline target | Buffered (offline_buffer) + FCM push fired |
| Backpressure > 64 MB (hard) | uWebSockets force-closes dead connection |
| No data for 120s | uWebSockets idle timeout, connection closed |
| keys.json removed keys | Affected peers kicked within 30s |
| TLS cert/key missing on startup | Fatal exit |
| Port already in use | Fatal exit |
| libsodium init failure | Fatal exit |

---

## Push notifications & offline message buffer (FCM Tier 2)

The relay is normally a dumb pipe, but to make FCM push notifications deliver real message content it holds offline DMs briefly in RAM.

**State (`RelayState`, state.h):**
- `push_tokens`: `peer_id -> {token, platform}`. Registered via `register_push_token` WS message (`handle_register_push_token`). RAM only, re-registered each app launch.
- `last_push_sent`: `peer_id -> time_point`. Debounce, `PUSH_DEBOUNCE_SECS = 10` (was 30). Throttles FCM call rate only — does NOT drop messages (the buffer keeps them). NOTE: rapid-fire sends within the debounce window suppress later FCM wakes, so some Tier-2 previews won't run until the next un-debounced send — looks flaky under burst testing, fine under normal use.
- `offline_buffer`: `peer_id -> deque<BufferedMsg{room, frame, at, is_image}>`. Each `frame` is a ready-to-send `0x06` direct frame (ciphertext only). **Two independent per-peer caps**: `MAX_BUFFERED_MSGS_PER_PEER = 100` (text) and `MAX_BUFFERED_IMAGES_PER_PEER = 1` (image — a notification shows only one image preview + one notif/peer). `OFFLINE_BUFFER_TTL_SECS = 86400` (24h).

**Flow (ws_handler.cpp):**
1. `handle_binary_direct_msg` (0x04 text / **0x08 image**) / `handle_direct` (text): target offline (`peer_sockets` miss) → `buffer_offline_msg(.., is_image)` stores the `0x06` frame → `try_push_notify()` → `notify_push_sidecar()` POSTs `{token, platform, sender}` to localhost:3001. `buffer_offline_msg` evicts oldest of each kind independently (`count_kind`/`drop_oldest_kind`) so an image burst never pushes out buffered text.
2. The peer's FCM fetch node (or full node) later joins the DM room → `handle_join` calls `replay_buffered_msgs()` → sends ALL buffered frames for that room (text + image, both as 0x06), drops delivered entries.
3. `sweep_offline_buffer()` (5-min timer in main.cpp) evicts entries older than 24h.

**Inlined-image delivery (0x08):** An image DM is two wire messages: the text DM (carries only `file_id`) and a separate FileHeader (metadata + AES key) + streamed bytes. The stream is NEVER sent to an offline peer. So for offline images the **sender inlines the AES-encrypted bytes (base64) into the FileHeader's `inline_bytes` field** and sends the Olm-encrypted FileHeader via a **`0x08` SendDirectImage** frame (ws_client.rs `SendDirectImage`, crypto_handler.rs `send_encrypted_image_to_peer` — targets `dm_room_code(local,peer)` DIRECTLY since an offline peer is in no room). The relay buffers it under the image cap. The fetch node (`fetch.rs`) parses `MessageEnvelope::FileHeader`, decrypts the inline bytes, writes `files/{fid}.{ext}`, and **inserts the `messages` row itself** (`[file:{fid}]`, INSERT OR IGNORE) + `insert_file_metadata` + `mark_file_complete` — because the companion text DM is dropped to offline peers. `FetchedMessage.image_path` flows to the notification for a `BigPictureStyleInformation` photo preview. Guests blocked from 0x08. iOS: works once APNs is configured (same path).

**Fetch-mode peers** (`is_fetch`, set from `fetch:true` in Auth): excluded from `peer_sockets`, `PeerJoined`, member lists — invisible, so waking via push doesn't show the user online. Buffer replay works for them via `handle_join`.

E2EE preserved — buffer holds ciphertext only (image bytes are AES-encrypted inside the Olm-encrypted FileHeader). Durable delivery still owned by full-node DM-sync; the buffer is latency glue so push previews are accurate. Client side: `rust/hollow_core/src/node/fetch.rs` + `lib/src/core/services/push_notification_service.dart`. See memory `project_push_notification_implementation.md`, `feedback_fcm_image_invisible_bubble.md`.

---

## Security properties

- **Zero-knowledge routing:** The relay never decrypts message content. All payloads are opaque bytes.
- **Authenticated connections:** Every WebSocket connection requires a valid Ed25519 signature over a timestamped challenge. No anonymous connections.
- **No connection logging:** Comments throughout the code (`// privacy: no connection logging`) indicate deliberate suppression of peer connect/disconnect logs.
- **Sender identity injection:** For binary types 0x02/0x03/0x04, the relay replaces/injects the sender's peer_id — peers cannot spoof their identity to the relay.
- **Timestamp anti-replay:** 60-second skew window limits replay attacks on auth and signaling requests.
- **No rate limiting:** Removed — Ed25519 auth + license keys are the DoS protection layer.
- **Room isolation:** Peers can only send to rooms they've joined. Non-members are silently rejected.
- **License revocation:** Active connections can be terminated within 30 seconds by removing their key from `keys.json`.
