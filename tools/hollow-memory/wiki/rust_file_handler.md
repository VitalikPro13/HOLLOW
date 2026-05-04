# Rust File Transfer Handler

Covers `file_handler.rs` (file send/receive orchestration, stream completion, gossip relay), `file_transfer.rs` (chunking utilities, paths, MIME), and `image_convert.rs` (WebP pipeline, avatars, banners).

---

## file_handler.rs Overview

Orchestrates all file transfer flows: sending files in DMs and channels, receiving FileHeader/FileChunk envelopes, completing streamed transfers (both WSS and WebRTC), gossip relay broadcast, and WebRTC failure fallback. Every public function takes individual swarm state fields as parameters (no SwarmContext struct due to borrow checker constraints with crypto helpers).

---

## handle_send_file()

`file_handler.rs:handle_send_file()` -- Entry point for `NodeCommand::SendFile`. Handles both DM and channel file sends.

### Parameters
Receives: `peer_id` (Some for DM), `server_id`+`channel_id` (Some for channel), `file_path`, `message_id`, `message_text`, `vthumb` (video thumbnail back-reference), `override_width`/`override_height` (Dart-supplied dimensions for video previews), `share_ref` (hidden Share back-reference for >34 MB files), plus the full swarm state suite (event_tx, server_states, keypair, olm, mls, ws_cmd_tx, ws_room_peers, webrtc_peers, pending_webrtc_sends, gossip_overlays).

### Step-by-step flow

1. **Read file from disk.** `std::fs::read(&file_path)`. On failure, emits `NetworkEvent::FileFailed` and returns.

2. **Extract filename and extension.** Original name preserved for metadata; extension lowercased for MIME detection.

3. **Size limit check (share_ref bypass #1).** Default 34 MB for DMs (`file_transfer::DEFAULT_MAX_FILE_SIZE`). For channels, reads `max_file_size_mb` from the server's CRDT settings (falls back to 34). **When `share_ref.is_some()`, the size check is skipped entirely** -- Share handles delivery with no size limit. This is the first of three share_ref bypass points. On size violation, emits `FileFailed`.

4. **WebP conversion (image pipeline).** Reads the user's `image_quality` setting from SQLCipher (`app_settings` table) to determine `WebpQuality` tier. Then branches:
   - **Convertible images** (png/jpg/jpeg/bmp/tiff): `image_convert::convert_to_webp_with_quality()`. On failure, falls back to original bytes with extracted dimensions.
   - **WebP passthrough**: Strips metadata via decode+re-encode (`image_convert::strip_webp_metadata()`). Lossless re-encode to avoid generation loss.
   - **GIF**: Converts to animated WebP via `image_convert::convert_gif_to_animated_webp()` at all quality tiers (even lossless WebP beats GIF LZW). On failure, strips GIF metadata and sends as GIF.
   - **Non-images**: Uses `override_width`/`override_height` from Dart (for video preview dimensions).

5. **Generate file ID.** `file_transfer::generate_file_id()` -- 32-char hex (16 random bytes).

6. **Determine storage mode.** `store_full_file = true` when: DM (`server_id.is_none()`), small server (<6 members), or image (need local preview). For 6+ member servers with non-image files, vault shards handle storage instead.

7. **Store file locally.** Writes to `~/.hollow/files/{file_id}.{ext}` if `store_full_file` is true.

8. **Save file metadata to DB.** `MessageStore::insert_file_metadata()` with context type "dm" or "channel" and context ID formatted as `server_id:channel_id` for channels. If `store_full_file`, also calls `mark_file_complete()`.

9. **Emit sender-side FileCompleted.** When `store_full_file` is true, emits `NetworkEvent::FileCompleted` so the sender's UI reloads from DB and picks up the real width/height/videoThumb. Without this, the sender's optimistic FileAttachment built by `addFileMessage` in Dart would be stuck with wrong dimensions. Receivers already get this via the stream-receive code path.

10. **Sign the message.** Uses `message_signing_payload()` with canonical format. Text is `[file:{file_id}]` if `message_text` is empty. DMs sign with context=recipient, channels sign with context=`{sid}:{cid}`.

11. **DM path** (`peer_id` is Some):
    - Builds `MessageEnvelope::DirectMessage` with `file_id`.
    - Stores text message in DB via `MessageStore::insert()`.
    - If Olm session exists with peer: sends encrypted message envelope.
    - If peer is reachable (`peer_is_reachable()`): AES-encrypts file data (`vault::pipeline::aes_encrypt()`), writes ciphertext to temp file `.stream_send_{file_id}.tmp`, sends `MessageEnvelope::FileHeader` via Olm (carries AES key securely), then streams encrypted bytes via `stream_to_peer()`.
    - If peer is offline, the `file_id` is in the message -- sync will request it later.

12. **Channel path** (`server_id` + `channel_id` are Some):
    - Builds `MessageEnvelope::ChannelMessage` with `file_id`.
    - Stores text message in DB via `MessageStore::insert_channel_message()`.
    - Sends text message via MLS single encrypt + relay fan-out to all reachable members.
    - AES-encrypts file data for binary transport.
    - Builds `MessageEnvelope::FileHeader` with AES key/nonce and optional `share_ref`.
    - **Share-backed files bypass:** When `share_ref.is_some()`, skips writing ciphertext to temp file and sets `ct_size = 0`. Logs "Share-backed file -- skipping binary streaming".
    - Broadcasts FileHeader via MLS (`send_mls_broadcast()`) or Olm fallback.
    - **Binary streaming decision:**
      - `share_ref.is_some()`: Skip all binary streaming (Share handles delivery).
      - `use_vault_only` (6+ members, non-image): Skip streaming (vault shards distribute separately).
      - Gossip overlay exists: Gossip broadcast to neighbors. Sends `BroadcastMeta` via MLS, then `broadcast_to_gossip_neighbors()`.
      - Small server (no gossip): Full replication -- stream to each reachable member via `stream_to_peer()`.

---

## handle_request_file()

`file_handler.rs:handle_request_file()` -- Handles `NodeCommand::RequestFile`. Sends a `HavenMessage::FileRequest` to a specific peer asking them to send file data. Used when a file_id is known from a message but the binary data wasn't received (offline sync scenario).

---

## stream_to_peer()

`file_handler.rs:stream_to_peer()` -- Routes file/shard data to a peer. Prefers WebRTC data channel if peer is in `webrtc_peers` set; falls back to WSS relay binary frames. For WebRTC: emits `NetworkEvent::WebRtcSendFile` (Dart handles the actual data channel send), stores in `pending_webrtc_sends` for fallback on failure. For WSS: calls `ws_stream_transfer::ws_stream_send()`.

---

## handle_webrtc_transfer_complete()

`file_handler.rs:handle_webrtc_transfer_complete()` -- Handles `NodeCommand::WebRtcTransferComplete`. Called when Dart reports a completed WebRTC binary transfer. Constructs a `StreamRequest` from the temp file path, then delegates to `handle_completed_stream()`. After completion, checks gossip overlays for pending relay -- if a relay exists with TTL > 0, forwards the file to gossip neighbors via `broadcast_to_gossip_neighbors()`.

---

## handle_webrtc_send_complete()

`file_handler.rs:handle_webrtc_send_complete()` -- Handles `NodeCommand::WebRtcSendComplete`. Cleans up after a successful send: removes the entry from `pending_webrtc_sends`, deletes temp `.stream_send_*` files. Also cleans Share chunk temps: if the transfer_id contains `:` (format `{short_root}:{chunk_index}`), removes `.send_{short_root}_{idx}.tmp` from the shares directory.

---

## handle_webrtc_transfer_failed()

`file_handler.rs:handle_webrtc_transfer_failed()` -- Handles `NodeCommand::WebRtcTransferFailed`. Removes the peer from `webrtc_peers`. Two retry paths:
- **Sender-side:** If the transfer is in `pending_webrtc_sends`, retries via `stream_to_peer()` (WSS relay fallback).
- **Receiver-side:** If the transfer is in `pending_file_streams` or `early_file_streams`, sends a `HavenMessage::FileRequest` to get the file via WSS.

---

## handle_completed_stream()

`file_handler.rs:handle_completed_stream()` -- Core handler for completed stream transfers. Dispatches on `StreamKind`:

### StreamKind::ShareChunk
Early return -- share chunks have their own completion path (`share_handler::handle_webrtc_share_chunk_complete()`).

### StreamKind::File
1. Looks up `PendingFileStream` by file_id.
2. Reads ciphertext from temp file.
3. AES-256-GCM decrypts using the key/nonce from the PendingFileStream.
4. Writes plaintext to `~/.hollow/files/{file_id}.{ext}`.
5. Marks file complete in DB (`MessageStore::mark_file_complete()`).
6. Emits `NetworkEvent::FileCompleted`.
7. Cleans up temp file.
8. **Early arrival handling:** If no PendingFileStream exists (WebRTC bytes arrived before FileHeader), saves the temp file in `early_file_streams` for later processing when the FileHeader arrives.

### StreamKind::Shard
1. Looks up `PendingShardStream` by `{content_id}:{shard_index}`.
2. Reads shard bytes from temp file.
3. Stores shard via `ContentStore::store_shard()`.
4. Emits `NetworkEvent::ShardStored`.
5. **Vault download trigger:** If a `pending_vault_download` exists for this content_id, attempts reconstruction. Loads manifest, collects available shards, checks if `available >= k`. If so, reconstructs file via `vault::pipeline::reconstruct_file()`, writes to vault cache, emits `VaultDownloadComplete`. Otherwise, re-inserts the pending download entry.

---

## handle_envelope_file_header() (MLS channel path)

`file_handler.rs:handle_envelope_file_header()` -- Handles `MessageEnvelope::FileHeader` received via MLS decryption in the channel path.

### Share_ref bypass #2 (size check)
When `share_ref.is_none()`, validates file size against server's `max_file_size_mb` setting. When `share_ref.is_some()`, skips the size check entirely.

### Flow
1. Logs the FileHeader with share_ref status.
2. Size validation (with share_ref bypass).
3. Saves file metadata to DB (`insert_file_metadata()`).
4. **PendingFileStream registration (share_ref bypass):** When `share_ref.is_none()` and AES key/nonce are present, registers a `PendingFileStream` for binary stream completion. When `share_ref.is_some()`, skips registration entirely -- Share handles delivery.
5. **Early arrival check:** If an early file stream exists (WebRTC bytes arrived before header), immediately processes it via `handle_completed_stream()`.
6. Emits `NetworkEvent::FileHeaderReceived` with `share_ref` passed through (Dart uses this to trigger Share-based download).

---

## DM FileHeader handler in swarm.rs (share_ref bypass #3)

`swarm.rs` line ~3445 -- Handles `MessageEnvelope::FileHeader` received via Olm decryption in the DM path. Same three bypass points as the MLS path:

1. **Size check bypass:** `if share_ref.is_none()` gates the size validation against 34 MB default or server setting.
2. **PendingFileStream skip:** `if share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce)` gates stream registration.
3. Emits `FileHeaderReceived` with `share_ref` for Dart to handle.

---

## The THREE share_ref Bypass Points (Critical)

Files >34 MB use a hidden Share for delivery. `ShareRef` in the `FileHeader` signals this. Three code locations must skip size checks and P2P stream registration:

| # | Location | What is bypassed |
|---|----------|-----------------|
| 1 | `file_handler.rs:handle_send_file()` line ~83 | Sender-side size limit check (`if share_ref.is_none() && file_data.len() > max_size`) |
| 2 | `file_handler.rs:handle_envelope_file_header()` line ~978 | Receiver-side MLS path size check + PendingFileStream registration |
| 3 | `swarm.rs` DM FileHeader handler line ~3451 | Receiver-side Olm/DM path size check + PendingFileStream registration |

Additionally, `handle_send_file()` skips writing ciphertext to temp and skips binary streaming when `share_ref.is_some()` (line ~468 and ~494).

---

## handle_envelope_file_chunk()

`file_handler.rs:handle_envelope_file_chunk()` -- Legacy chunked file transfer path. Handles `MessageEnvelope::FileChunk`.

1. Base64-decodes the chunk data.
2. Writes chunk to disk via `file_transfer::write_chunk()`.
3. Marks chunk received in DB (`mark_chunk_received()`).
4. Emits `NetworkEvent::FileProgress`.
5. When all chunks received (`received >= chunk_count`), assembles via `file_transfer::assemble_file()`, marks complete, emits `FileCompleted`.

Note: The streamed transfer path (`chunks: 0`) is the primary path now. This chunked path is for fallback/legacy.

---

## handle_envelope_broadcast_meta()

`file_handler.rs:handle_envelope_broadcast_meta()` -- Gossip relay tree metadata. Validates TTL (capped at `MAX_BROADCAST_TTL`), marks broadcast seen in the gossip overlay, and registers a pending relay if TTL > 0 and origin is not local peer. The actual relay happens in `handle_webrtc_transfer_complete()` after the file bytes arrive.

---

## broadcast_to_gossip_neighbors()

`file_handler.rs:broadcast_to_gossip_neighbors()` -- Sends a file to all gossip overlay neighbors (minus optional exclude peer). Gets relay targets from `GossipOverlay::get_relay_targets()`. For each target with a WebRTC data channel, emits `NetworkEvent::GossipRelayFile` (Dart sends via data channel with broadcast header). Peers without data channels are skipped.

---

# file_transfer.rs -- Chunking Utilities

## Constants

- `DEFAULT_MAX_FILE_SIZE`: 34 MB (34 * 1024 * 1024). Hard cap on the default relay.

## generate_file_id()

`file_transfer.rs:generate_file_id()` -- Generates a 32-char hex file ID from 16 random bytes via `getrandom`. Same format as message IDs.

## files_dir()

`file_transfer.rs:files_dir()` -- Returns `~/.hollow/files/`. Creates the directory if missing.

## write_chunk()

`file_transfer.rs:write_chunk()` -- Writes a single chunk to `{files_dir}/{safe_id}.chunk.{chunk_index}`.

## assemble_file()

`file_transfer.rs:assemble_file()` -- Reads chunk files 0..total_chunks in order, concatenates to the final path, then cleans up chunk files.

## sanitize_path_component()

`file_transfer.rs:sanitize_path_component()` -- Security: strips all non-alphanumeric characters from file IDs and extensions to prevent path traversal attacks. Used by `chunk_path()` and `final_file_path()`.

## final_file_path()

`file_transfer.rs:final_file_path()` -- Returns `{files_dir}/{safe_id}.{safe_ext}`. Both components are sanitized.

## mime_from_ext()

`file_transfer.rs:mime_from_ext()` -- Maps file extensions to MIME types. Covers: png, jpg/jpeg, gif, bmp, webp, svg, mp4, webm, mp3, ogg, wav, pdf, zip, txt. Unknown extensions map to `application/octet-stream`.

## is_image_mime()

`file_transfer.rs:is_image_mime()` -- Returns true if MIME starts with `image/`.

---

# image_convert.rs -- WebP Image Pipeline

## WebpQuality Enum

Three user-configurable tiers stored in `app_settings`:

| Tier | Setting string | WebP mode | Quality value | Use case |
|------|---------------|-----------|--------------|----------|
| Lossless | `"lossless"` | Lossless WebP via `image` crate | N/A | Pixel art, screenshots with tiny text, diagrams |
| Balanced | `"balanced"` (default) | Lossy WebP via `webp` crate | Q=50 | Photographic content, ~95-98% smaller than PNG |
| Small | `"small"` | Lossy WebP via `webp` crate | Q=30 | Low-bandwidth situations, noticeable on gradients |

- `WebpQuality::from_setting(s)` -- parses from DB string; unknown/missing falls back to Balanced.
- `WebpQuality::as_setting()` -- serializes for DB storage.
- Default impl returns Balanced.

## should_convert_to_webp()

`image_convert.rs:should_convert_to_webp()` -- Returns true for: png, jpg, jpeg, bmp, tiff, tif. GIFs excluded (handled separately for animation). WebP excluded (already encoded).

## convert_to_webp_with_quality()

`image_convert.rs:convert_to_webp_with_quality()` -- Main entry point for the user-configurable image send pipeline. Preserves original dimensions (no resize).
- Lossless: delegates to `convert_to_webp_lossless()` (uses `image` crate's WebP writer).
- Balanced/Small: decodes via `image` crate, converts to RGBA8, encodes via `webp::Encoder::from_rgba()` at Q=50 or Q=30.
- Returns `(webp_bytes, width, height)`.

## convert_to_webp_lossless()

`image_convert.rs:convert_to_webp_lossless()` -- Decodes any supported image format, writes as lossless WebP via `image::ImageFormat::WebP`. ~20-40% smaller than PNG.

## convert_to_webp_preview()

`image_convert.rs:convert_to_webp_preview()` -- For link preview thumbnails and small preview images. Always lossy Q=50, resized so max dimension is `max_dim_px` (preserves aspect ratio, Lanczos3 filter). NOT affected by user quality setting. Returns `(webp_bytes, width, height)`.

## convert_gif_to_animated_webp()

`image_convert.rs:convert_gif_to_animated_webp()` -- Converts animated GIF to animated WebP. Uses `image::codecs::gif::GifDecoder` for frame extraction, `webp_animation::Encoder` for output.

- Decodes all frames via `GifDecoder::into_frames().collect_frames()`.
- Encoding config per quality tier: Lossless uses `EncodingType::Lossless`, Balanced uses Lossy Q=50, Small uses Lossy Q=30.
- Frame delays preserved with browser convention: delays < 20ms treated as 100ms (matching `animated_gif_image.dart`).
- `encoder.finalize(timestamp_ms)` produces the WebP bytes.
- Returns `(webp_bytes, width, height)`.

## strip_webp_metadata()

`image_convert.rs:strip_webp_metadata()` -- Strips EXIF/XMP metadata from WebP by decoding to pixels and lossless re-encoding. Used for WebP passthrough in the send pipeline to remove privacy-leaking metadata.

## strip_gif_metadata()

`image_convert.rs:strip_gif_metadata()` -- Strips metadata from GIF without re-encoding (preserves animation). Manual binary parser that:
- Copies: Header, Logical Screen Descriptor, Global Color Table, Image Descriptors, Local Color Tables, LZW data, Graphic Control Extensions, NETSCAPE2.0 Application Extension (animation loop control).
- Strips: Comment Extension blocks (0xFE), non-NETSCAPE Application Extension blocks (EXIF, XMP, ICC profiles).
- Falls back to returning original bytes if the file is not a valid GIF.

## get_image_dimensions()

`image_convert.rs:get_image_dimensions()` -- Decodes image and returns `(width, height)` without conversion. Used for dimension extraction when WebP conversion fails.

## convert_from_webp()

`image_convert.rs:convert_from_webp()` -- Converts WebP to another format (for "Save As" functionality). Supports target formats: png, jpg/jpeg, bmp, gif.

## process_avatar_image()

`image_convert.rs:process_avatar_image()` -- Processes raw image into avatar format:
1. Center-crops to square (smallest dimension).
2. Resizes to 128x128 using Lanczos3 filter.
3. Encodes as lossless WebP.
4. Rejects if result > 100 KB.

## process_banner_image()

`image_convert.rs:process_banner_image()` -- Processes raw image into banner format:
1. Center-crops to 3:1 aspect ratio (crops the widest 3:1 region from center).
2. Resizes to 600x200 using Lanczos3 filter.
3. Encodes as lossless WebP.
4. Rejects if result > 200 KB.

---

## Key Types (from types.rs)

### PendingFileStream
Stored in `pending_file_streams: HashMap<String, PendingFileStream>` keyed by file_id. Holds AES key/nonce, file metadata, and sender info. Created when a FileHeader arrives with AES key (non-share-ref). Consumed when the binary stream completes.

Fields: `aes_key`, `aes_nonce`, `file_name`, `ext`, `sender`, `server_id`, `channel_id`, `message_id`, `is_image`, `width`, `height`.

### VideoThumbRef
Back-reference from a thumbnail image to the underlying video stored in the vault. Carried in `MessageEnvelope::FileHeader`. Fields: `cid` (vault content_id), `ext`, `name`, `size`, `dur_ms`.

### ShareRef
Back-reference to a hidden Share for large file delivery. Fields: `root_hash` (hex, 64 chars), `key` (AES-256-GCM key, hex, 64 chars). Embedded in `MessageEnvelope::FileHeader` so the receiver joins the share swarm.

---

## Transport Priority

`stream_to_peer()` implements the transport preference:
1. **WebRTC data channel** -- if peer is in `webrtc_peers` set. Emits `WebRtcSendFile` for Dart to handle.
2. **WSS relay binary frames** -- fallback via `ws_stream_transfer::ws_stream_send()`.

On WebRTC failure, `handle_webrtc_transfer_failed()` retries via WSS (sender) or sends FileRequest (receiver).

---

## Storage Paths

| Path | Content | Lifetime |
|------|---------|----------|
| `~/.hollow/files/{file_id}.{ext}` | Full file (DMs, <6 servers, all images) | Persistent |
| `~/.hollow/files/.stream_send_{file_id}.tmp` | AES-encrypted ciphertext for in-progress sends | Deleted after send completes |
| `~/.hollow/files/{file_id}.chunk.{idx}` | Individual chunks during assembly | Deleted after assembly |
| `~/.hollow/vault/{server_id}/{shard_key}.shard` | Erasure-coded shards (6+ servers) | Retention-based |
| `~/.hollow/vault_cache/{content_id}.{ext}` | LRU-evicted decrypted cache | 1 GB cap |

---

## Early Arrival Race Condition

WebRTC binary data can arrive before the FileHeader (MLS decryption is slower). `early_file_streams: HashMap<String, (PathBuf, u64, String)>` stores the temp path, size, and sender peer ID. When the FileHeader later arrives, both `handle_envelope_file_header()` and the swarm.rs DM handler check for early arrivals and immediately process them via `handle_completed_stream()`.

---

## Gossip File Distribution

For servers with gossip overlays (large servers), files are distributed via a gossip relay tree instead of full replication:

1. Sender calls `broadcast_to_gossip_neighbors()` with a new `broadcast_id`.
2. `BroadcastMeta` sent via MLS so all peers know the file is coming.
3. Gossip neighbors receive file via WebRTC data channel.
4. On receive completion (`handle_webrtc_transfer_complete()`), each peer checks for pending relays and forwards to their own neighbors with decremented TTL.
5. TTL capped at `MAX_BROADCAST_TTL` for security. TTL=0 messages are not relayed.
