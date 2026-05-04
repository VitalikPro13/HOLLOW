# FFI Share, Identity, Twitch, Updater, and Archive API

Covers the remaining `api/` FFI modules that bridge Dart to Rust for file sharing, identity/keypair management, Twitch OAuth, application updates, and cryptographic archive export/import. All functions are `#[frb]`-annotated for flutter_rust_bridge codegen.

## Share API (`api/share.rs`)

Phase 7A file-sharing surface. Every function except `share_decode_link` and `evict_vault_cache` pushes a `NodeCommand` into the swarm event loop via `cmd_tx.send()` and returns immediately. Results stream back to Dart via `watch_network_events()` as `Share*` network events.

### Command dispatch pattern

All share commands follow an identical lock-send pattern:
1. `get_node()` acquires the global `Mutex<Option<RunningNode>>`.
2. Extracts the `cmd_tx` (tokio mpsc sender) from the running node state.
3. `get_runtime().block_on(cmd_tx.send(NodeCommand::Share*))` to dispatch.
4. Returns `Ok(())` immediately; the swarm event loop processes asynchronously.

### `share_decode_link(link: String) -> Result<ShareLinkInfo, String>`

Pure synchronous helper with no I/O. Delegates to `share_handler::decode_link()`. Returns `ShareLinkInfo { root_hash: String, room_id: String }`. The link format is `hollow://share/{base64url}` where the payload is `[version:1][root_hash:32][key:32]` (65 bytes, URL_SAFE_NO_PAD base64). The `room_id` is `"share:{root_hash_hex}"` used as the relay room identifier.

### `share_create_from_file(source_path: String) -> Result<(), String>`

Sends `NodeCommand::ShareCreate { source_path }`. The swarm event loop builds a manifest from the local file, encrypts every chunk with a fresh random AES-256-GCM key (256 KiB chunks matching `ws_stream_transfer` framing), persists the share row in SQLCipher, writes the encrypted stream to `~/.hollow/shares/{root_hash}.{ext}`, joins the swarm relay room, and starts seeding. Emits `NetworkEvent::ShareCreated { root_hash, link, file_name, total_size }` on success or `ShareFailed` on error.

### `share_open_link(link: String) -> Result<(), String>`

Sends `NodeCommand::ShareOpenLink { link, server_id: None, context_type: None }`. Decodes the share link, persists a placeholder row, joins the swarm relay room, and queues a manifest request. Emits `NetworkEvent::ShareManifestReady` when the manifest arrives from a seeder. This is the first step for a receiver -- download does not begin until `share_start_download` is called.

### `share_start_download(root_hash, save_dir, link, sequential: bool) -> Result<(), String>`

Sends `NodeCommand::ShareStart { root_hash, save_dir, link, sequential }`. Called after `ShareManifestReady`. When `sequential` is true, chunks are fetched in order (0, 1, 2, ...) for progressive video streaming instead of rarest-first order. Emits `ShareProgress` events during download and `ShareCompleted` when finished.

### `share_cancel(root_hash: String) -> Result<(), String>`

Sends `NodeCommand::ShareCancel { root_hash }`. Stops an in-flight download but keeps the partial file and bitmap on disk so that a subsequent `share_start_download` resumes from where it left off.

### `share_set_seeding(root_hash: String, seeding: bool) -> Result<(), String>`

Sends `NodeCommand::ShareSetSeeding { root_hash, seeding }`. Toggles seeding for a completed share. When enabled, the node serves chunk requests to other peers in the swarm room.

### `share_remove(root_hash: String, delete_file: bool) -> Result<(), String>`

Sends `NodeCommand::ShareRemove { root_hash, delete_file }`. Drops the share entry from SQLCipher. If `delete_file` is true, also unlinks the on-disk file (including partial downloads).

### `share_start_from_ref(root_hash, key_hex, save_dir, sequential, server_id, context_type) -> Result<(), String>`

Used when a `FileHeader` carries a `ShareRef` (hidden share-backed large files >34 MB). Reconstructs a share link from raw `root_hash` (32 bytes hex) + `key_hex` (32 bytes hex) via `share_handler::encode_link()`, then sends `NodeCommand::ShareOpenLink` with the synthesized link and optional `server_id`/`context_type` for context tracking. Validates both hex strings are exactly 32 bytes. This is the receiver-side entry point for share-backed channel files.

### `share_list() -> Result<(), String>`

Sends `NodeCommand::ShareList`. The swarm enumerates all persisted shares from SQLCipher and emits `NetworkEvent::ShareList { entries: Vec<ShareEntryRef> }` back to Dart.

### `evict_vault_cache(exempt_paths: Vec<String>) -> Result<u64, String>`

Synchronous function (not a NodeCommand). Calls `vault::pipeline::evict_cache_if_needed()` with `VAULT_CACHE_CAP` (1 GB = 1,073,741,824 bytes). Evicts LRU files from `~/.hollow/vault_cache/` that exceed the cap, skipping any paths in `exempt_paths` (e.g., currently playing video). Returns bytes freed. Runs every 30 minutes from the Dart side.

### `share_keep_and_seed(root_hash: String) -> Result<String, String>`

"Keep & Seed" action for share-backed video/file cards. Copies the completed file from `vault_cache` to `~/.hollow/files/{filename}`, deletes the cache copy, updates the share's `disk_path` in SQLCipher via `update_share_disk_path()`, sets seeding to true via `set_share_seeding()`, and sends `NodeCommand::ShareSetSeeding` to the swarm. Returns the new file path string. Operates in two phases: first acquires the message store lock for DB + filesystem operations, releases it, then acquires the node lock to dispatch the seeding command.

### Share link format (from `share_handler.rs`)

- Scheme: `hollow://share/`
- Payload: `[LINK_VERSION:u8=1][root_hash:32 bytes][key:32 bytes]` = 65 bytes total
- Encoding: base64url no-pad
- Room ID derived as: `"share:{hex(root_hash)}"`
- Chunk size: 262,144 bytes (256 KiB), matching `ws_stream_transfer` framing
- Encryption: AES-256-GCM per chunk, nonce derived as `[0;4] || chunk_index_be:8` (12 bytes)

### NetworkEvent variants for Share

- `ShareCreated { root_hash, link, file_name, total_size }` -- share created and seeding started
- `ShareCreatedHidden { root_hash, key_hex, file_name, total_size }` -- hidden share (no link URL, used for channel file backing)
- `ShareManifestReady` -- manifest received from seeder, ready to start download
- `ShareProgress` -- chunk download progress
- `ShareCompleted` -- download finished
- `ShareFailed` -- error during any share operation
- `ShareList { entries: Vec<ShareEntryRef> }` -- response to `share_list()`

## Identity API (`api/identity.rs`)

Manages Ed25519 keypair creation, loading, and restoration. The keypair is the user's cryptographic identity -- the peer_id (derived from the public key) is the permanent user identifier across all of Hollow.

### FFI struct: `IdentityInfo`

```
pub struct IdentityInfo {
    pub peer_id: String,
    pub mnemonic: Option<String>,  // Only present on first creation
}
```

### `load_or_create_identity() -> Result<IdentityInfo, String>`

Primary entry point called during app startup. Delegates to `identity::load_or_create_identity()` in `identity/keys.rs`. Checks if `~/.hollow/identity.key` (protobuf-encoded Ed25519 keypair) exists. If yes, loads and decodes it via `NativeKeypair::from_protobuf_encoding()`, returns peer_id with `mnemonic: None`. If no file exists, generates a fresh identity: creates 32 bytes of entropy via `getrandom`, derives a 24-word BIP-39 mnemonic, derives the Ed25519 keypair via `NativeKeypair::from_mnemonic()`, saves to disk, and returns both peer_id and mnemonic. The mnemonic is only ever returned on first creation -- it is never stored persistently.

### `generate_new_identity() -> Result<IdentityInfo, String>`

Force-generates a fresh identity, replacing any existing one. Same flow as the creation path in `load_or_create_identity()`: 32 bytes entropy, BIP-39 mnemonic, keypair derivation, save to `identity.key`. Always returns the mnemonic. Used for identity reset.

### `restore_identity_from_mnemonic(phrase: String) -> Result<IdentityInfo, String>`

Restores a keypair from a 24-word mnemonic. Parses the phrase via `Mnemonic::parse()`, derives the keypair, overwrites `identity.key` on disk. Returns peer_id and the mnemonic back. Used for account recovery and multi-device sync.

### Underlying identity system (`identity/keys.rs`, `identity/native_identity.rs`)

- **Data directory:** `identity::data_dir()` returns `~/.hollow/` (or `HOLLOW_DATA_DIR` env var for multi-instance testing). Falls back to `dirs::data_dir().join("hollow")` which is `%APPDATA%/hollow` on Windows.
- **Storage:** `identity.key` file in protobuf encoding (backward compatible with libp2p format).
- **NativeKeypair:** Wraps `ed25519_dalek::SigningKey` + `VerifyingKey`. Methods: `peer_id()` (multihash of protobuf-encoded public key), `sign(msg)`, `public_key_bytes()`, `secret_key_bytes()`, `verify_peer_signature()`, `public_key_protobuf()`.
- **Mnemonic flow:** BIP-39 24-word (256-bit entropy) -> SHA-512 HMAC seed -> first 32 bytes -> Ed25519 secret key.
- **Peer ID derivation:** Public key -> protobuf encoding -> SHA-256 -> multihash -> base58 string.

## Twitch API (`api/twitch.rs`)

Full Twitch OAuth Device Code Grant flow + proof generation for Hollow server join gates. Uses an in-memory token cache (`OnceLock<Mutex<Option<CachedToken>>>`) and persists refresh tokens + user info in SQLCipher settings.

### Persistence layer

Three SQLCipher settings keys managed via `save_tw_setting()` / `load_tw_setting()`:
- `twitch_refresh_token` -- OAuth refresh token (rotated on each use)
- `twitch_user_id` -- Twitch numeric user ID
- `twitch_username` -- Twitch display login

### In-memory token cache (`CachedToken`)

```
struct CachedToken {
    access_token: String,
    expires_at: Instant,
    last_validated: Instant,
}
```

Stored in a `OnceLock<Mutex<Option<CachedToken>>>` static. Token is cached with an expiry 60 seconds before the actual OAuth expiry (safety margin). Hourly re-validation is tracked via `last_validated`.

### `twitch_start_device_flow() -> Result<TwitchDeviceFlowResult, String>`

Initiates the Twitch Device Code Grant flow. Calls `twitch::start_device_flow()` (in `node/twitch.rs`) via the tokio runtime. Returns `TwitchDeviceFlowResult { user_code, verification_uri, device_code, interval_secs }`. Dart displays the `user_code` and opens `verification_uri` in a browser for the user.

### `twitch_poll_for_token(device_code: String, interval_secs: u64) -> Result<String, String>`

Polls Twitch until the user completes browser authorization. Calls `twitch::poll_for_token()` which retries at the specified interval. On success:
1. Validates the access token via `twitch::validate_token()` to get `user_id` and `login`.
2. Persists `refresh_token`, `user_id`, and `username` to SQLCipher.
3. Caches the access token in memory with expiry (`expires_in - 60s` safety margin).
Returns the Twitch `user_id` string.

### `twitch_ensure_token() -> Result<bool, String>`

Silent token maintenance. Called before any Twitch API operation. Logic:
1. Check in-memory cache: if token exists and not expired, check if hourly validation is due. If under 1 hour since last validation, return `true` (token valid).
2. If cache miss or expired: load refresh token from SQLCipher.
3. If no refresh token stored, return `false` (not connected).
4. Call `twitch::refresh_access_token()` with the stored refresh token.
5. If refresh fails (expired/revoked): clear stored refresh token, return `false`.
6. On success: save the new refresh token (Twitch refresh tokens are one-time use), validate the new access token, update cached username, cache the new access token.
7. Return `true`.

### `twitch_generate_proof(broadcaster_id: String) -> Result<String, String>`

Generates a cryptographic proof that the user follows/subscribes to a specific Twitch channel. Flow:
1. Calls `twitch_ensure_token()` -- fails if not connected.
2. Loads `user_id` and `username` from SQLCipher.
3. Extracts `access_token` from the in-memory cache.
4. Calls `twitch::generate_proof(access_token, user_id, username, broadcaster_id)` which checks follow/sub status against the Twitch API and produces a signed proof.
5. Serializes the proof to JSON via `serde_json::to_string()`.

### `twitch_disconnect() -> Result<(), String>`

Clears all Twitch state: empties the three SQLCipher settings keys and sets the in-memory cache to `None`.

### `twitch_is_connected() -> Result<bool, String>`

Returns `true` if `twitch_user_id` is stored and non-empty in SQLCipher.

### `twitch_get_user_id() -> Result<Option<String>, String>`

Returns the stored Twitch user ID, or `None` if empty/missing.

### `twitch_get_username() -> Result<Option<String>, String>`

Returns the stored Twitch username, or `None` if empty/missing.

## Updater API (`api/updater.rs`)

Application self-update system. Fetches a version manifest from a remote URL, downloads update ZIPs with progress streaming, and generates a Windows batch script for file replacement while the app is closed.

### Constants

- `APP_VERSION: &str = "0.1.0"` -- current hardcoded version string.

### FFI struct: `DownloadProgress`

```
pub struct DownloadProgress {
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
}
```

### `get_current_version() -> String`

Sync function (`#[frb(sync)]`). Returns `APP_VERSION` ("0.1.0").

### `fetch_version_manifest(manifest_url: String) -> Result<String, String>`

Fetches the remote version manifest JSON via HTTP GET with a 10-second timeout and `Cache-Control: no-cache` header. Returns the raw response body as a string. Dart parses the JSON to determine if an update is available by comparing versions. The manifest is hosted at `legal/manifest.json` on the CDN.

### `download_update(url: String, dest_path: String, sink: StreamSink<DownloadProgress>) -> Result<(), String>`

Spawns an async download task on the tokio runtime (non-blocking). Streams the update ZIP from `url` to `dest_path` using `reqwest::get()` + `bytes_stream()`. Pushes `DownloadProgress` events to the Dart `StreamSink` after each chunk write. If the sink is closed (Dart cancelled), the download stops. On error, sends a zero-progress event and logs via `hollow_log!`. Creates parent directories for `dest_path` if needed.

### `apply_update(zip_path: String, app_dir: String, version: String) -> Result<String, String>`

Generates a Windows batch script that performs the update after the app exits. Full flow:
1. Creates staging directory at `~/.hollow/updates/staging-{version}`.
2. Opens the downloaded ZIP and detects if all entries share a common top-level prefix (e.g., `Release/`) via `detect_common_prefix()`. If so, strips it during extraction.
3. Extracts all ZIP entries to the staging directory, creating subdirectories as needed.
4. Generates `~/.hollow/updates/update.bat` with the following steps:
   - Polls `tasklist` in a loop waiting for `hollow.exe` to exit.
   - `xcopy /E /Y /Q` from staging to `app_dir`.
   - Removes staging directory and ZIP file.
   - Displays a countdown (5 to 1).
   - Launches `hollow.exe` from `app_dir`.
5. Returns the path to the generated `.bat` file. Dart launches this script and then exits.

### `detect_common_prefix(archive) -> Option<String>`

Internal helper. Iterates all ZIP entries and checks if they all share the same first path component (e.g., `Release/`). Returns `Some("Release/")` if uniform, `None` otherwise. Used to strip wrapper directories from release ZIPs.

## Archive API (`api/archive.rs`)

Cryptographic evidence archive system for exporting, verifying, and loading `.hollow-archive` files (ZIP bundles containing signed messages, edit histories, deletion evidence, reactions, and optionally file attachments). Also handles `.hollow-shards` bundles for vault shard recovery.

### FFI result structs

#### `ArchiveVerifyResult`

Quick verification summary returned by `verify_archive()` and embedded in `ArchiveData`:
- `archive_type: String` -- `"dm"`, `"channel"`, or `"server"`
- `exporter_peer_id: String` -- who exported the archive
- `export_timestamp: i64` -- millis since epoch
- `message_count: u32` -- total messages
- `archive_signature_valid: bool` -- Ed25519 signature over the canonical content hash
- `messages_with_valid_sig / messages_with_invalid_sig / messages_without_sig: u32` -- per-message breakdown
- `participant_ids: Vec<String>` -- all unique sender peer IDs
- Context fields: `peer_id` (DM), `server_id`/`channel_id`/`channel_name` (channel), `server_name`/`channels` (server)

#### `ArchiveChannelInfoFfi`

Per-channel metadata for multi-channel (server) archives: `channel_id`, `channel_name`, `message_count`.

#### `ArchiveMessageFfi`

Full message record: `message_id`, `sender_id`, `text`, `timestamp`, `signature`, `public_key`, `edited_at`, `hidden_at`, `reply_to_mid`, `file_id`, `channel_id` (server archives only), `reactions: Vec<ArchiveReactionFfi>`, `signature_valid: Option<bool>` (verified during load).

#### `ArchiveReactionFfi`

Reaction on a message: `emoji`, `peer_id`, `added_at`, `signature`, `public_key`.

#### `ArchiveEditFfi`

Edit history entry: `message_id`, `old_text`, `new_text`, `edited_at`, `signature`, `public_key`, `prev_signature`, `prev_public_key`, `prev_timestamp`. The `prev_*` fields form a chain linking to the previous version for tamper detection.

#### `ArchiveDeletionFfi`

Deletion evidence: `message_id`, `deleted_text`, `deleted_at`, `signature`, `public_key`. Preserves the deleted content as cryptographic evidence.

#### `ArchiveReactionRemovalFfi`

Reaction removal evidence: `message_id`, `emoji`, `peer_id`, `removed_at`, `signature`, `public_key`.

#### `ArchivePubKeyFfi`

Public key entry for offline verification: `peer_id`, `public_key_b64`. Included in archives so signatures can be verified without network access.

#### `ArchiveFileFfi`

File attachment metadata: `file_id`, `file_name`, `file_ext`, `mime_type`, `size_bytes`, `is_image`, `width`, `height`, `sha256` (hex, only when included), `included: bool`.

#### `ArchiveData`

Full loaded archive for the POV (point-of-view) viewer. Contains all the above plus `file_mode: String`, `participants: Vec<String>`, `messages`, `edits`, `deletions`, `reaction_removals`, `pubkeys`, `files`, `verification: ArchiveVerifyResult`, and `files_dir: Option<String>` (temp directory with extracted file bytes).

### Export functions

All export functions follow the same pattern: acquire the message store lock, load the identity keypair, call `archive::exporter::export_archive()` with the appropriate `ArchiveTarget`, write the resulting ZIP bytes to `output_path`, and return the file size in bytes.

#### `export_dm_archive(peer_id, output_path, file_mode) -> Result<u64, String>`

Exports a DM conversation. Target: `ArchiveTarget::Dm { peer_id }`.

#### `export_channel_archive(server_id, channel_id, channel_name, output_path, file_mode) -> Result<u64, String>`

Exports a single channel conversation. Target: `ArchiveTarget::Channel { server_id, channel_id, channel_name }`.

#### `export_server_archive(server_id, server_name, channels_json, output_path, file_mode) -> Result<u64, String>`

Exports all text channels of a server as a single archive. Parses `channels_json` (JSON array of `[{"channel_id": "...", "channel_name": "..."}]`) into `Vec<(String, String)>`. Target: `ArchiveTarget::Server { server_id, server_name, channels }`.

#### File mode (`archive::types::FileMode`)

Three modes controlling file attachment inclusion:
- `"full"` -- all file attachments included with SHA-256 integrity hashes
- `"images_only"` -- only image attachments included
- `"placeholder"` -- metadata only, no file bytes (smallest archive)

### Verification and loading

#### `verify_archive(archive_path: String) -> Result<ArchiveVerifyResult, String>`

Quick verification. Reads the ZIP bytes, calls `archive::loader::verify_archive()`, which parses `manifest.json` and `archive_signature.json`, verifies the archive-level Ed25519 signature over the canonical content hash, and checks per-message signatures. Returns an `ArchiveVerifyResult` summary without loading full message data into memory.

#### `load_archive(archive_path: String) -> Result<ArchiveData, String>`

Full archive load for the POV viewer UI. Reads the ZIP bytes, calls `archive::loader::load_archive()`, which extracts all content. Processing:
1. Builds a `HashMap<String, bool>` from `per_message_results` mapping message_id to signature validity.
2. Converts all internal types to FFI types: messages (with per-message `signature_valid` lookup), edits, deletions, reaction_removals, pubkeys, file metadata.
3. Recomputes verification summary counts (valid/invalid/unsigned) from `per_message_results`.
4. Assembles `ArchiveData` with the full manifest metadata, all converted data, and the verification summary.

### Archive ZIP structure (from `archive::types`)

```
manifest.json              -- ArchiveManifest (type, exporter, timestamp, participants, etc.)
archive_signature.json     -- Ed25519 signature over content hash
pubkeys.json               -- Array of peer_id + public_key_b64
messages/{message_id}.json -- Per-message data with text, sig, reactions
edits/{message_id}.json    -- Edit history arrays (old_text -> new_text chains)
deletions/{message_id}.json -- Deletion evidence with preserved text
reaction_removals/{message_id}.json -- Reaction removal evidence
files/{file_id}.meta.json  -- File attachment metadata
files/{file_id}.{ext}      -- Actual file bytes (if included per file_mode)
```

### Shard export/import (Evidence Recovery Phase B)

#### `ShardImportResultFfi`

Result of importing a `.hollow-shards` bundle: `server_id`, `manifests_imported`, `shards_imported`, `shards_skipped`, `new_reconstructable` (files now having enough shards for erasure-code reconstruction).

#### `export_server_shards(server_id, output_path) -> Result<u64, String>`

Exports all vault shards for a server as a `.hollow-shards` ZIP bundle. Opens the `ContentStore` using the identity keypair's protobuf encoding (first 32 bytes hex-encoded as passphrase). Lists all manifests and shards for the server. Builds a bundle manifest JSON with `format_version: 1`, server_id, exporter_peer_id, timestamp, counts, and full manifest data. Writes a ZIP containing `manifest.json` and `shards/{content_id}/{shard_index}.shard` files. Returns file size in bytes.

#### `import_server_shards(archive_path: String) -> Result<ShardImportResultFfi, String>`

Imports a `.hollow-shards` ZIP bundle. Processing:
1. Reads and opens the ZIP, parses `manifest.json` to extract `server_id`.
2. Opens the local `ContentStore` with the same passphrase derivation as export.
3. Imports manifests: deserializes each `VaultManifest` from the bundle's `manifests` array and calls `content_store.save_manifest()`.
4. Imports shards: iterates all `shards/{content_id}/{shard_index}.shard` entries. For each:
   - Generates the shard key via `content_store::shard_key(content_id, shard_index)`.
   - Skips if `content_store.has_shard()` returns true (already present).
   - Looks up the manifest entry for this content_id to get `k`, `m`, `total_data_size`, and `storage_tier`.
   - Calls `content_store.store_shard()` with the extracted data.
   - Shards without a matching manifest are skipped entirely.
5. Counts newly reconstructable files: iterates all manifests, checks if local shard count >= `k` (minimum for reconstruction).
6. Returns `ShardImportResultFfi` with all counts.

### Content store passphrase derivation

Both `export_server_shards` and `import_server_shards` derive the content store passphrase from the identity keypair: `hex::encode(keypair.to_protobuf_encoding()[..32])`. This ensures the content store is tied to the user's identity.
