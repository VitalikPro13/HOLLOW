# Rust Share Handler (Hollow Share)

Covers `share_handler.rs` -- Phase 7A backend for private, encrypted, zero-tracker file sharing built on the existing relay rooms + WebRTC data channel pipeline.

---

## Architecture Overview

Hollow Share is a BitTorrent-like file sharing system using:
- **Relay rooms** for peer discovery and signaling (room ID = `share:{root_hash_hex}`).
- **WebRTC data channels** for chunk transfer (STUN-only for user shares, TURN-enabled for hidden/channel shares).
- **AES-256-GCM** encryption with per-chunk nonce derivation.
- **SHA-256** manifest root hash for link integrity + per-chunk hash verification.
- **Rarest-first** or **sequential** chunk scheduling.
- **Token bucket** seed bandwidth cap (20 MiB/s refill, 40 MiB burst).

All state lives in `ShareRegistry` (`HashMap<String, ShareSwarmState>`) owned by the swarm event loop. No separate threads or tasks -- the scheduler tick runs once per second from the main loop.

---

## Constants

| Name | Value | Purpose |
|------|-------|---------|
| `CHUNK_SIZE` | 262,144 (256 KiB) | Matches ws_stream_transfer framing |
| `MANIFEST_VERSION` | 1 | Bump if hash domain or nonce derivation changes |
| `LINK_VERSION` | 1 | Share link envelope version |
| `SHARE_ROOM_PREFIX` | `"share:"` | Prefix for share swarm room IDs on relay |
| `LINK_SCHEME_PREFIX` | `"hollow://share/"` | URL scheme for share links |
| `HAVE_REBROADCAST_INTERVAL` | 10 seconds | How often to re-send Have bitmap |
| `CHUNK_REQUEST_TIMEOUT` | 8 seconds | In-flight request timeout before re-request |
| `MAX_INFLIGHT_PER_PEER` | 4 | Maximum concurrent chunk requests per peer |
| `SPEED_WINDOW_SECS` | 3.0 seconds | Sliding window for speed calculation |
| `SEED_REFILL_BPS` | 20 MiB/s | Token bucket refill rate |
| `SEED_BURST_BYTES` | 40 MiB | Token bucket maximum burst |
| `COEXIST_PAUSE` | 200 ms | Pause scheduling after messaging/voice traffic |

---

## Share Link Codec

### Link format
`hollow://share/{base64url_no_pad}` where payload is: `[version:1 byte][root_hash:32 bytes][key:32 bytes]` = 65 bytes total.

### encode_link()
`share_handler.rs:encode_link()` -- Builds a share link from root_hash + key. Prepends LINK_VERSION byte, concatenates root_hash and key, base64url encodes (no padding), prefixes with `hollow://share/`.

### decode_link()
`share_handler.rs:decode_link()` -- Parses a share link. Validates: correct scheme prefix, valid base64url, exactly 65 bytes, version == 1. Returns `ShareLinkInfo { root_hash, key }`.

### ShareLinkInfo
Extracted from a decoded link. Methods: `root_hash_hex()` returns hex string, `room_id()` returns `"share:{hex}"`.

---

## Crypto Helpers

### chunk_nonce()
`share_handler.rs:chunk_nonce()` -- Derives the AES-256-GCM nonce for a chunk: `[0;4] || chunk_index_be:8` (12 bytes total). Index uniqueness guarantees nonce uniqueness for the lifetime of the key. First 4 bytes always zero, last 8 bytes are the chunk index as big-endian u64.

### encrypt_chunk()
`share_handler.rs:encrypt_chunk()` -- Encrypts plaintext with the share's per-link AES-256-GCM key using the derived nonce. Uses `aes_gcm` crate directly.

### decrypt_chunk()
`share_handler.rs:decrypt_chunk()` -- Decrypts ciphertext. Delegates to `vault::pipeline::aes_decrypt()` with the derived nonce. Returns Err if auth tag doesn't verify (wrong key or tampered data).

---

## ChunkBitmap

`share_handler.rs:ChunkBitmap` -- Compact Have representation. Bit i is set iff chunk i is held. Stored MSB-first within each byte.

### Methods
- `empty(chunk_count)` -- All zeros bitmap.
- `from_bytes(bits, chunk_count)` -- Constructs from wire bytes. Pads if too short, truncates if too long, masks trailing bits in the last byte to prevent phantom chunks.
- `as_bytes()` -- Returns the raw byte slice for wire transmission.
- `has(idx)` -- Tests if chunk idx is held.
- `set(idx)` -- Marks chunk idx as held.
- `count_set()` -- Counts set bits (popcount).
- `is_complete()` -- True if `count_set() >= chunk_count`.

---

## ShareSwarmState

`share_handler.rs:ShareSwarmState` -- In-memory state for one active share.

### Key fields
| Field | Type | Purpose |
|-------|------|---------|
| `root_hash` | `[u8; 32]` | SHA-256 of the manifest JSON bytes |
| `key` | `[u8; 32]` | AES-256-GCM encryption key from the link |
| `manifest` | `Option<ShareManifest>` | None until received from seeder |
| `file_ext` | `String` | Original extension for `.partial` rename |
| `save_dir` | `Option<PathBuf>` | Download destination; None until ShareStart |
| `have` | `ChunkBitmap` | Which chunks we hold |
| `data_file` | `Option<File>` | Open handle: partial file (download) or source (seed) |
| `seeding` | `bool` | Whether we're serving chunks |
| `bytes_uploaded` / `bytes_downloaded` | `u64` | Transfer stats |
| `peer_have` | `HashMap<String, ChunkBitmap>` | Per-peer Have bitmaps from ShareHave envelopes |
| `inflight` | `HashMap<u32, (String, Instant)>` | Outstanding chunk requests: idx -> (peer_id, requested_at) |
| `last_have_broadcast` | `Instant` | For 10s rebroadcast interval |
| `speed_samples` | `Vec<(Instant, usize)>` | Sliding window for speed calculation |
| `speed_bps` | `u64` | Cached bytes/sec |
| `manifest_requested_at` | `Option<Instant>` | For 10s manifest timeout; None for seeders |
| `sequential` | `bool` | True: request chunks in order (video streaming). False: rarest-first |
| `hidden` | `bool` | Not shown in Share tab; uses TURN-enabled ICE for WebRTC |
| `server_id` | `Option<String>` | For channel file shares (grouping in Share tab) |
| `context_type` | `Option<String>` | "channel", "dm", or None for user-initiated |

### Methods
- `root_hash_hex()` -- hex-encoded root hash.
- `room_id()` -- `"share:{root_hash_hex}"`.
- `seeder_leecher_counts()` -- Iterates `peer_have`, counts complete vs incomplete bitmaps. Returns `(seeders: u8, leechers: u8)`.

---

## ShareManifest (from types.rs)

Describes a shared file. Transmitted in cleartext over the swarm room (the SHA-256 of the serialized manifest IS the root_hash, so encrypting it would make discovery impossible). The decryption key is only in the link.

Fields: `version` (u16), `file_name`, `mime`, `total_size` (u64), `chunk_size` (u32, 262144 for v1), `chunk_count` (u32), `chunk_hashes` (Vec of `[u8; 32]` -- SHA-256 of each encrypted chunk), `created_at` (unix seconds), `note` (optional).

---

## Storage Layout

| Path | Content | Lifecycle |
|------|---------|-----------|
| `~/.hollow/shares/` | Default share directory | Persistent |
| `~/.hollow/shares/{root_hash_hex}.partial` | Sparse file during download | Renamed on completion |
| `~/.hollow/shares/{root_hash_hex}.{ext}` or `{file_name}` | Completed file (default save) | Persistent |
| `~/.hollow/shares/.send_{short_root}_{idx}.tmp` | Temp ciphertext for seeding chunks | Deleted after send |
| `~/.hollow/vault_cache/{...}` | Hidden share downloads (channel files) | LRU-evicted |

Hidden shares (channel file downloads) save to `vault_cache_dir()` for LRU management instead of the shares directory.

---

## Manifest Helpers

### manifest_root_hash()
`share_handler.rs:manifest_root_hash()` -- SHA-256 of the raw manifest JSON bytes. This hash IS the root_hash in the share link. Canonical: the same JSON bytes that go on the wire as `ShareManifestResponse.manifest_b64`.

### build_manifest_from_file()
`share_handler.rs:build_manifest_from_file()` -- Builds a manifest from a plaintext source file.
1. Stats the file for `total_size`.
2. Rejects empty files and files with > u32::MAX chunks.
3. Extracts filename and MIME from path.
4. Reads the file chunk by chunk (CHUNK_SIZE = 256 KiB).
5. For each chunk: encrypts transiently (`encrypt_chunk()`), computes SHA-256 of the ciphertext, stores hash. Does NOT keep ciphertexts -- chunks are encrypted on-the-fly when served.
6. Returns `ShareManifest` with all chunk hashes.

---

## Command Handlers

### handle_command_share_create()

`share_handler.rs:handle_command_share_create()` -- Creates a new share from a local file.

1. Generates 32-byte random key via `getrandom`.
2. Builds manifest via `build_manifest_from_file()` (hashes each chunk's ciphertext).
3. Serializes manifest to JSON, computes root hash.
4. Encodes the share link (`encode_link()`).
5. Persists to DB via `upsert_share()` with state "completed", seeding=true. Stores the original source path -- no file copy.
6. Creates `ShareSwarmState` with full Have bitmap (all bits set), opens source file read-only as `data_file`.
7. Joins the relay room (`WsCommand::JoinRoom`).
8. **Hidden shares:** Emits `NetworkEvent::ShareCreatedHidden` (includes root_hash + key_hex for building ShareRef). Returns early -- no link shown to user.
9. **Normal shares:** Emits `NetworkEvent::ShareCreated` (includes link, file_name, total_size).

### handle_command_share_open_link()

`share_handler.rs:handle_command_share_open_link()` -- Pure probe: opens a share link without downloading.

1. Decodes the link via `decode_link()`.
2. Joins the relay room.
3. Sends `HavenMessage::ShareManifestRequest` to the room (broadcast to all peers).
4. Creates a minimal registry entry with `manifest: None` and `manifest_requested_at: Some(now)` for timeout tracking.
5. If `server_id` is provided, marks the entry as `hidden: true`.
6. Does NOT create a DB entry or start downloading -- that happens only on ShareStart.

### handle_command_share_start()

`share_handler.rs:handle_command_share_start()` -- Starts downloading a share whose manifest was already received via ShareOpenLink.

1. Requires registry entry with manifest (probe must have succeeded).
2. **Resolves save_dir:**
   - Non-empty `save_dir` param: use as-is.
   - Hidden shares (channel files): `vault_cache_dir()` for LRU management.
   - Default: `~/.hollow/shares/`.
3. Creates DB entry via `upsert_share()` with state "downloading".
4. Creates/opens the `.partial` file (sparse file, pre-allocated to `total_size` via `set_len()`).
5. Updates the registry entry: sets `data_file`, `save_dir`, empty Have bitmap, clears manifest timeout, sets `sequential` flag.
6. Joins the relay room (may already be joined from probe).
7. Broadcasts initial Have bitmap (empty -- signals "I need everything").

### handle_command_share_cancel()

`share_handler.rs:handle_command_share_cancel()` -- Cancels a download or dismisses a probe.

- If the share is already seeding (user opened their own link), only emits `ShareFailed` with "Cancelled" -- does NOT destroy the active seed.
- Otherwise: leaves relay room, removes from registry (drops data_file handle), deletes `.partial` file, deletes DB entry, emits `ShareFailed`.

### handle_command_share_set_seeding()

`share_handler.rs:handle_command_share_set_seeding()` -- Toggles seeding on/off.

- Updates DB via `set_share_seeding()`.
- **Enabling seeding:** If `data_file` is None, loads `disk_path` from DB and re-opens the file. Joins relay room.
- **Disabling seeding:** Leaves relay room.
- Emits `NetworkEvent::ShareSeedingChanged` with current stats.

### handle_command_share_remove()

`share_handler.rs:handle_command_share_remove()` -- Permanently removes a share entry.

- Leaves relay room.
- Removes from registry.
- If `delete_file`: deletes both the final file (from `disk_path` in DB) and the `.partial` file.
- Deletes DB entry.

### handle_command_share_list()

`share_handler.rs:handle_command_share_list()` -- Returns all shares for the UI.

1. Loads all rows from DB via `load_shares()`.
2. **Auto-cleanup:** Removes stale entries and orphan unknowns (state="downloading", no manifest, no registry entry).
3. **Temp file cleanup:** Removes orphaned `.send_*.tmp` files from shares directory.
4. Maps each row to `ShareEntryRef`, merging in-memory chunk progress from registry where available.
5. Emits `NetworkEvent::ShareList`.

---

## Auto-Rejoin on Startup

### auto_rejoin_seeders()

`share_handler.rs:auto_rejoin_seeders()` -- Called once from `spawn_node` after registry creation.

1. Loads all shares from DB.
2. For each completed + seeding share:
   - Deserializes manifest from stored JSON.
   - Opens the source file read-only. If file is missing, marks the share as stale and disables seeding.
   - Rebuilds full `ShareSwarmState` with complete Have bitmap.
   - Sets `last_have_broadcast` to slightly before now (triggers immediate rebroadcast).
   - Joins the relay room.
3. Logs count of rejoined shares.

Without this, restarting the app would silently kill all seeding.

---

## SeedBudget (Token Bucket)

`share_handler.rs:SeedBudget` -- Process-wide outbound seeding bandwidth cap. Single instance owned by swarm event loop.

- **Refill rate:** 20 MiB/s (`SEED_REFILL_BPS`).
- **Max burst:** 40 MiB (`SEED_BURST_BYTES`).
- `try_consume(bytes)` -- Refills based on elapsed time, then attempts to consume. Returns true on success, false if caller should defer. No partial consumption.
- Purpose: prevents runaway saturation. The coexistence pause (200ms after messaging) already protects real-time traffic; the bucket prevents Share from saturating bandwidth continuously.

---

## Scheduler Tick

`share_handler.rs:tick()` -- Driven once per second from the swarm main loop. The core scheduler that drives all share download progress.

### Phase 0: Housekeeping

For each share in the registry:

1. **Manifest timeout:** If no manifest after 10 seconds, emits `ShareFailed` with "No seeders found" and removes the entry.
2. **Stale file check:** If seeding but `data_file` is None (source file deleted), disables seeding, marks state "stale" in DB, emits `ShareSeedingChanged`.
3. **Seeding progress emit:** Every ~2 seconds, emits `ShareSeedingChanged` with current seeder/leecher counts and bytes_uploaded.

### Phase 1: Have Rebroadcast

Every `HAVE_REBROADCAST_INTERVAL` (10 seconds), calls `broadcast_have()` to send our Have bitmap to the share room. This lets peers learn about chunks we acquire after initial join.

### Phase 2: Timeout In-Flight Requests

Retains only inflight entries younger than `CHUNK_REQUEST_TIMEOUT` (8 seconds). Timed-out chunks become available for re-request on the next tick.

### Phase 3: Schedule New Chunk Requests

Skipped when:
- `messaging_active` is true (coexistence pause with voice/messages).
- Share is complete (all chunks held).
- Manifest not yet received.
- No data_file (download hasn't started).
- No peer_have data (no peers known).

#### WebRTC Connection Requests
For each peer in `peer_have` that is not in `webrtc_peers`, emits `NetworkEvent::ShareNeedWebRtc` so Dart establishes a connection. Hidden shares pass `hidden: true` to enable TURN-based ICE config.

#### Chunk Selection

**Sequential mode** (for progressive video streaming):
- Finds the lowest missing chunk index.
- Limits lookahead to 64 chunks from that point.
- Keeps ascending index order (no rarest-first sort).

**Rarest-first mode** (default):
- Considers all missing chunks not currently in-flight.
- For each, collects which peers hold it (only peers with active WebRTC connections).
- Sorts by rarity (fewest owners first).

#### Assignment Algorithm
For each needed chunk (in rarest-first or sequential order):
1. Pick the owner with the smallest current backlog (inflight count).
2. If that peer is at `MAX_INFLIGHT_PER_PEER` (4), skip this chunk.
3. Otherwise, assign chunk to that peer.

#### Dispatch
- Marks all assigned chunks as in-flight with current timestamp.
- Sends `HavenMessage::ShareChunkRequest` via `WsCommand::SendDirect` to each peer with their assigned chunk indices.

---

## Envelope Handlers

### handle_envelope_share_manifest_request()

`share_handler.rs:handle_envelope_share_manifest_request()` -- Responds to a manifest request from a peer. If we have the manifest, serializes to JSON, base64 encodes, sends `HavenMessage::ShareManifestResponse` via `WsCommand::SendDirect` to the requesting peer.

### handle_envelope_share_manifest_response()

`share_handler.rs:handle_envelope_share_manifest_response()` -- Processes a received manifest.

1. Base64-decodes the manifest bytes.
2. **Integrity verification:** Computes SHA-256 of the received bytes, compares to the claimed root_hash. Rejects on mismatch (logs "REJECTED manifest from peer: hash mismatch").
3. Deserializes the JSON manifest.
4. Validates: `chunk_hashes.len() == chunk_count`.
5. Extracts file extension from `file_name`.
6. Caches manifest in registry (DB write deferred to ShareStart).
7. Resets Have bitmap to empty for the new chunk_count.
8. Clears `manifest_requested_at` (stops timeout).
9. Emits `NetworkEvent::ShareManifestReady` (file_name, total_size, chunk_count).

### handle_envelope_share_have()

`share_handler.rs:handle_envelope_share_have()` -- Updates a peer's Have bitmap.

1. Validates chunk_count matches manifest (if manifest known).
2. Base64-decodes the bitmap bytes.
3. Constructs `ChunkBitmap::from_bytes()` (handles padding/masking).
4. Stores in `state.peer_have[sender_peer_id]`.

### handle_envelope_share_chunk_request()

`share_handler.rs:handle_envelope_share_chunk_request()` -- Serves chunk data to a requesting peer.

1. Requires seeding or having chunks. Checks `data_file` is open.
2. For each requested index:
   - Validates: index in range, we have the chunk.
   - **Bandwidth cap:** `seed_budget.try_consume()` -- if no tokens, breaks the loop (peer retries via scheduler timeout).
   - Reads plaintext from source file at `idx * chunk_size` offset.
   - **Encrypts on-the-fly:** `encrypt_chunk(&state.key, idx, &pt_buf)`. No pre-encrypted storage.
   - **WebRTC only:** If peer has no WebRTC connection, logs skip and continues. Share chunks are NOT sent via WSS relay.
   - Writes ciphertext to temp file `.send_{short_root}_{idx}.tmp`.
   - Emits `NetworkEvent::WebRtcSendFile` with kind="share_chunk" and the chunk_index.
3. Updates `bytes_uploaded` stat and persists to DB.

### handle_envelope_share_chunk_response() (relay path)

`share_handler.rs:handle_envelope_share_chunk_response()` -- Processes a chunk received via relay (base64 in JSON envelope). Logs a warning ("unexpected relay-routed ShareChunkResponse") because chunks should normally arrive via WebRTC binary.

1. Base64-decodes the ciphertext.
2. **Hash verification:** SHA-256 of ciphertext must match `manifest.chunk_hashes[index]`. Rejects on mismatch.
3. **Decryption:** `decrypt_chunk(&state.key, index, &ct)`. On failure, emits `ShareFailed` with "decryption failed".
4. Writes plaintext to the partial file at offset `index * chunk_size`.
5. Updates Have bitmap, bytes_downloaded, removes from inflight.
6. **Speed calculation:** Pushes sample to sliding window, prunes samples older than 3 seconds, computes bytes/sec.
7. Persists bitmap snapshot to DB.
8. Emits `NetworkEvent::ShareProgress`.
9. If complete, calls `finalize_completed_download()`.

---

## WebRTC Chunk Completion

### handle_webrtc_share_chunk_complete()

`share_handler.rs:handle_webrtc_share_chunk_complete()` -- Receiver-side handler when a chunk arrives via WebRTC binary frames (the primary chunk delivery path).

1. **Resolves short_root to full root_hash:** Transfer ID format is `"{short_root}:{idx}"` where short_root is the first 32 hex chars. Searches registry keys for a match (128-bit collision resistance).
2. Reads ciphertext from the temp file Dart wrote, then deletes it.
3. **Hash verification:** Same as relay path -- SHA-256 must match manifest.
4. **Decryption:** Same as relay path.
5. Writes plaintext to partial file at correct offset.
6. Updates Have bitmap, bytes_downloaded, removes from inflight.
7. Speed calculation (same sliding window algorithm).
8. Persists bitmap snapshot.
9. Emits `ShareProgress`.
10. If complete, calls `finalize_completed_download()`.

---

## Download Completion

### finalize_completed_download()

`share_handler.rs:finalize_completed_download()` -- Called when all chunks are received.

1. Resolves save directory (from state or default shares_dir).
2. Closes data_file handle (sets to None in registry).
3. Renames `.partial` to the original filename in save_dir.
4. **Collision avoidance:** If filename already exists, appends ` (1)`, ` (2)`, ... up to 999.
5. Marks share complete in DB (`mark_share_complete()`).
6. **Auto-seeding:** Non-hidden shares automatically start seeding. Hidden shares (channel files) don't auto-seed -- receiver opts in via "Keep & Seed".
7. Re-opens the final file read-only as `data_file` for seeding.
8. Emits `NetworkEvent::ShareCompleted` with disk_path.

---

## Have Broadcasting

### broadcast_have()

`share_handler.rs:broadcast_have()` -- Sends our Have bitmap to the share room. Base64-encodes the bitmap bytes, sends `HavenMessage::ShareHave` via `WsCommand::SendToRoom` (broadcast to all room peers).

---

## Peer Lifecycle

### forget_peer()

`share_handler.rs:forget_peer()` -- Called when a peer leaves a share room.

- **For all shares:** Removes the peer from inflight (clears any pending chunk requests to that peer).
- **For completed/seeding shares:** Removes the peer from peer_have (keeps seeder count accurate).
- **For active downloads:** Keeps peer_have intact so the tick resumes immediately after WebRTC re-establishes. This is critical: the receiver drives reconnection via `ShareNeedWebRtc`, and keeping peer_have means we don't lose knowledge of what chunks that peer holds.

---

## Hidden Shares for Channel Files

Files >34 MB in channels use a hidden Share for delivery. The flow:

1. Dart creates the share via `ShareCreate` with `hidden: true`.
2. Rust emits `ShareCreatedHidden` (root_hash + key_hex, no link).
3. Dart builds a `ShareRef { root_hash, key }` and attaches it to the `SendFile` command.
4. `handle_send_file()` includes `share_ref` in the `FileHeader`, skips binary streaming.
5. Receiver gets `FileHeaderReceived` with `share_ref`. Dart calls `ShareOpenLink` with a reconstructed link.
6. Two-step auto-download: `ShareOpenLink` -> `ShareManifestReady` -> `ShareStart`.
7. Hidden shares save to `vault_cache_dir()` (LRU-managed).
8. Hidden shares don't auto-seed after completion.
9. Hidden shares use `hidden: true` in `ShareNeedWebRtc`, signaling Dart to use TURN-enabled ICE config.

---

## Coexistence with Real-Time Traffic

Two mechanisms prevent Share from degrading voice/messaging:

1. **Coexistence pause (`COEXIST_PAUSE = 200ms`):** The swarm event loop tracks `messaging_active` -- set true if any voice/message traffic happened recently. When active, the tick skips Phase 3 (new chunk requests). Have rebroadcast and timeout cleanup still run.

2. **Seed bandwidth budget (`SeedBudget`):** Token bucket at 20 MiB/s refill, 40 MiB burst. `handle_envelope_share_chunk_request()` calls `try_consume()` before serving each chunk. If budget is exhausted, remaining chunks in the request are deferred -- the requesting peer's scheduler will timeout and re-request.

---

## Manifest Verification

Manifest integrity is verified at two levels:

1. **Root hash:** The SHA-256 of the serialized manifest JSON must match the root_hash from the share link. Checked in `handle_envelope_share_manifest_response()`. A tampered manifest would produce a different hash.

2. **Per-chunk hash:** Each chunk's SHA-256(ciphertext) must match the corresponding entry in `manifest.chunk_hashes[]`. Checked in both `handle_envelope_share_chunk_response()` (relay) and `handle_webrtc_share_chunk_complete()` (WebRTC). This prevents a malicious peer from serving corrupted chunk data.

The encryption key is never in the manifest or on the wire -- only in the share link. So the manifest can be transmitted in cleartext for discovery, while the content remains encrypted.

---

## Speed Calculation

Both chunk completion handlers maintain a sliding window:
- `speed_samples: Vec<(Instant, usize)>` -- timestamps and byte counts.
- Window duration: 3 seconds (`SPEED_WINDOW_SECS`).
- On each chunk arrival: push sample, prune old samples, compute `window_bytes / window_dt`.
- Cached in `speed_bps: u64`, emitted in `ShareProgress` events.
- Minimum window_dt of 0.01s prevents division-by-zero.

---

## WebRTC Peer Management for Shares

Share chunk transfer requires WebRTC data channels (relay path exists as fallback but logs warnings). The scheduler tick handles connection establishment:

1. Each tick, for each downloading share with known peers, checks if each peer in `peer_have` is in `webrtc_peers`.
2. For missing connections, emits `NetworkEvent::ShareNeedWebRtc { peer_id, hidden }`.
3. Dart calls `ensureConnection()` on the peer. Hidden shares use TURN-enabled ICE config (more reliable NAT traversal for channel-file scenarios).
4. Chunk requests are only sent to peers with active WebRTC connections (the `webrtc_peers.contains()` filter in the needed-chunk collection).
5. `handle_envelope_share_chunk_request()` skips relay-only peers (`!prefer_webrtc`).
6. On WebRTC send completion, `handle_webrtc_send_complete()` cleans up temp files using the `{short_root}:{idx}` transfer ID pattern.

---

## Key Data Flows

### Creating a share (seeder)
```
NodeCommand::ShareCreate
  -> handle_command_share_create()
     -> getrandom key
     -> build_manifest_from_file() [hash each chunk's ciphertext]
     -> manifest_root_hash()
     -> encode_link()
     -> upsert_share() [DB: state=completed, seeding=true]
     -> ShareSwarmState with full Have
     -> WsCommand::JoinRoom
     -> NetworkEvent::ShareCreated (or ShareCreatedHidden)
```

### Opening a link (leecher probe)
```
NodeCommand::ShareOpenLink
  -> handle_command_share_open_link()
     -> decode_link()
     -> WsCommand::JoinRoom
     -> HavenMessage::ShareManifestRequest [broadcast]
     -> minimal registry entry [manifest_requested_at set]
```

### Starting download
```
NodeCommand::ShareStart
  -> handle_command_share_start()
     -> validate manifest exists
     -> resolve save_dir
     -> upsert_share() [DB: state=downloading]
     -> create .partial file [sparse, pre-allocated]
     -> update registry state
     -> broadcast_have() [empty bitmap]
```

### Chunk download cycle (tick-driven)
```
tick() Phase 3:
  -> build needed chunks (rarest-first or sequential)
  -> assign to peers (least-loaded)
  -> mark inflight
  -> HavenMessage::ShareChunkRequest [per-peer batch]

Peer serves chunk:
  -> handle_envelope_share_chunk_request()
     -> read plaintext from source file
     -> encrypt_chunk() on-the-fly
     -> write temp file
     -> NetworkEvent::WebRtcSendFile [kind=share_chunk]

Chunk arrives:
  -> handle_webrtc_share_chunk_complete()
     -> verify SHA-256(ciphertext) == manifest hash
     -> decrypt_chunk()
     -> write to .partial at offset
     -> update Have bitmap
     -> NetworkEvent::ShareProgress
     -> if complete: finalize_completed_download()
```

### Download completion
```
finalize_completed_download()
  -> rename .partial -> filename (with collision avoidance)
  -> mark_share_complete() [DB]
  -> auto-seed (non-hidden only)
  -> NetworkEvent::ShareCompleted
```
