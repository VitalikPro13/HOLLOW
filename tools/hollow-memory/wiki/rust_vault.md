# Vault System — Distributed Encrypted Storage

The vault is Hollow's distributed file storage layer. Files uploaded to servers are AES-256-GCM encrypted, optionally erasure-coded into shards, and distributed across server members. Each member stores only their assigned shards on disk in `~/.hollow/vault/{server_id}/`. The system adapts between full replication (small servers) and Reed-Solomon erasure coding (6+ members), with deterministic XOR-distance shard placement, automatic rebalancing on membership changes, and a recovery pool protocol for dead servers.

**Module layout:** `rust/hollow_core/src/vault/` contains the pure-logic crate modules (adaptive, content_store, erasure, pipeline, placement, rebalancer). `rust/hollow_core/src/node/vault_ops.rs` contains the command handlers that wire these modules into the swarm event loop. `rust/hollow_core/src/node/recovery_pool.rs` manages cooperative shard recovery.

---

## adaptive.rs — Vault Mode Selection and Retention

File: `rust/hollow_core/src/vault/adaptive.rs`

### VaultMode Enum

Two modes, selected automatically by member count:

- `VaultMode::FullReplication` — every eligible member stores every file. Used when member_count < 6.
- `VaultMode::ErasureCoding { k, m }` — Reed-Solomon with k data shards and m parity shards. Used when member_count >= 6.

### adaptive:compute_adaptive_params()

Lookup table mapping member_count to VaultMode. k scales logarithmically with member count, m = roughly ceil(k/2). Total shards n = k + m never exceeds 30. Storage overhead converges to ~1.5x.

| Members | Mode | k | m | n = k+m |
|---------|------|---|---|---------|
| 0-5     | FullReplication | - | - | - |
| 6-8     | ErasureCoding | 3 | 2 | 5 |
| 9-15    | ErasureCoding | 5 | 3 | 8 |
| 16-30   | ErasureCoding | 8 | 4 | 12 |
| 31-60   | ErasureCoding | 10 | 5 | 15 |
| 61-150  | ErasureCoding | 12 | 6 | 18 |
| 151-500 | ErasureCoding | 16 | 8 | 24 |
| 501+    | ErasureCoding | 20 | 10 | 30 |

### adaptive:apply_tier_multiplier()

Accepts (k, m, StorageTier), returns (k, m). Currently a no-op identity function for all tiers. `StorageTier::Low` exists for backward compatibility with existing DB rows but behaves identically to Standard. k is never modified.

### adaptive:determine_tier()

Accepts a MIME type string, always returns `StorageTier::Standard`. Low tier is no longer produced but kept in the enum for DB backward compat.

### Retention Policy Helpers

- `adaptive:parse_retention_days(policy)` — parses "365d", "90d", "permanent", etc. into `Option<u32>`. Returns None for "permanent" or empty string.
- `adaptive:retention_for_tier(tier, settings)` — reads `retention_files` from server settings HashMap. Default "365d". The tier parameter is accepted but ignored (Low = Standard).

---

## erasure.rs — Reed-Solomon Erasure Coding

File: `rust/hollow_core/src/vault/erasure.rs`

Uses `reed_solomon_erasure::galois_8::ReedSolomon` for GF(2^8) operations.

### ShardMetadata Struct

Self-describing header prepended to every stored shard. Allows any shard to be independently identified without external metadata:

- `shard_index: u16` — position in the erasure set (0..k+m)
- `content_id: String` — SHA-256 hex of the original encrypted data
- `k: u16` — number of data shards
- `m: u16` — number of parity shards
- `shard_size: u32` — size of each shard in bytes (after padding)
- `total_data_size: u64` — original data size before padding, used to strip padding on decode

### Packing Format

Each stored shard is: `[header_len: u32 LE][header JSON bytes][raw shard data]`

- `erasure:pack_shard(metadata, shard_data)` — serializes ShardMetadata to JSON, prepends 4-byte LE length prefix, appends raw shard bytes.
- `erasure:unpack_shard(packed)` — inverse operation. Validates minimum length (4 bytes for header), reads header_len, deserializes JSON, returns (ShardMetadata, raw_data).

### Raw Encode/Decode (No Headers)

- `erasure:encode_raw(data, k, m)` — splits data into k equal-sized shards (zero-pads last shard if not evenly divisible), creates m empty parity shards, runs `ReedSolomon::encode()`. Returns k+m raw Vec<u8> shards. Validates k >= 1, m >= 1, data non-empty.
- `erasure:decode_raw(shards, k, m, total_data_size)` — takes k+m Option<Vec<u8>> entries (Some = present, None = missing). Requires at least k present. Calls `ReedSolomon::reconstruct_data()`, concatenates data shards, truncates to `total_data_size` to strip padding.

### Packed Encode/Decode (With Headers)

- `erasure:encode(data, k, m, content_id)` — calls `encode_raw()`, then wraps each raw shard with a ShardMetadata header via `pack_shard()`. Returns k+m packed shard byte vectors.
- `erasure:decode(packed_shards, k, m)` — takes k+m Option<Vec<u8>> packed shards. Unpacks each present shard via `unpack_shard()`, validates metadata consistency (all shards must agree on k, m, shard_size, total_data_size), routes shards to correct positions by shard_index, then calls `decode_raw()`. Handles shuffled shard order correctly since each shard self-identifies.

### Performance

Benchmark test (1MB data, k=10, m=5, 50 iterations) targets >100 MB/s for both encode and decode. Run with `cargo test --release -p hollow_core erasure::tests::bench_throughput -- --ignored --nocapture`.

---

## placement.rs — Deterministic Shard Placement

File: `rust/hollow_core/src/vault/placement.rs`

### ShardPlacement Struct

Output type: `{ shard_index: u16, target_peer: String, shard_key: String }`.

### placement:place()

Unified entry point. Branches on VaultMode:
- `FullReplication` -> `compute_full_replication_placements()`
- `ErasureCoding { k, m }` -> `compute_shard_placements(content_id, k+m, members, pledges)`

Pure function. No I/O, no DB. Fully deterministic given the same inputs.

### placement:compute_full_replication_placements()

Every member with non-zero pledge stores the full file (shard_index=0). Members are sorted alphabetically for determinism. All receive the same shard_key (SHA-256 of content_id + index 0).

### placement:compute_shard_placements()

XOR-distance placement with pledge-weighted caps. For each shard index 0..n:

1. Compute shard_key = `content_store:shard_key(content_id, shard_index)` (SHA-256 of content_id bytes + shard_index as BE u16).
2. For each eligible member, compute XOR distance = `SHA-256(shard_key) XOR SHA-256(peer_id)`.
3. Sort members by XOR distance ascending (closest first).
4. Pick the closest member whose assignment count hasn't exceeded their cap.

**Pledge-weighted caps:** Each member's cap = `ceil(n * pledge / total_pledge)`, minimum 1. This means members who pledge more storage capacity get assigned proportionally more shards.

**Zero-pledge exclusion:** Members with pledge == 0 are filtered out entirely.

**Fallback:** If all eligible members are at cap (rounding edge case), assigns to the closest member regardless of cap.

**Determinism:** Members are sorted alphabetically before processing, ensuring identical results across all peers.

---

## pipeline.rs — Upload/Download Pipeline

File: `rust/hollow_core/src/vault/pipeline.rs`

### VaultManifest Struct

Describes a vault-stored file. Contains the AES decryption key. Encrypted with MLS group key before broadcast, stored in SQLCipher at rest.

Fields: `content_id`, `encryption_key` (32-byte AES key, hex-encoded), `nonce` (12-byte AES-GCM nonce, hex-encoded), `original_size: u64`, `k: u16` (0 = full replication sentinel), `m: u16` (0 = full replication sentinel), `shard_count: u16`, `file_name`, `mime_type`, `storage_tier`, `created_at: i64`, `creator_peer_id`, `channel_id`, `message_id` (#[serde(default)] for backward compat).

### UploadPlan Struct

Contains everything needed to distribute a file: `manifest: VaultManifest`, `shards: Vec<(u16, Vec<u8>)>` (indexed by shard_index), `placements: Vec<ShardPlacement>`, `content_id: String`.

### AES-256-GCM Helpers

- `pipeline:aes_encrypt(plaintext)` — generates random 32-byte key + 12-byte nonce via `getrandom`, encrypts with `aes_gcm::Aes256Gcm`. Returns `EncryptedFile { ciphertext, key, nonce }`.
- `pipeline:aes_decrypt(ciphertext, key, nonce)` — decrypts AES-256-GCM. Used by download pipeline.

### pipeline:prepare_upload()

Pure function — no I/O, no network. The caller provides pre-encrypted data (ciphertext + key + nonce) and the pre-computed content_id. Steps:

1. `adaptive:determine_tier(mime_type)` — determines storage tier.
2. `adaptive:compute_adaptive_params(members.len())` — determines VaultMode.
3. Branches on mode:
   - **FullReplication:** Single shard at index 0 containing the full ciphertext. k=0, m=0, shard_count=0 (sentinels).
   - **ErasureCoding:** Applies `adaptive:apply_tier_multiplier()` to adjust m, then calls `erasure:encode()` to produce k+m packed shards. Calls `placement:place()` to determine shard targets.
4. Builds VaultManifest with all metadata.
5. Returns UploadPlan.

### pipeline:reconstruct_file()

Reconstructs a file from its manifest and collected shards:

1. Decodes AES key (32 bytes) and nonce (12 bytes) from manifest hex strings.
2. **Replication mode (k=0, m=0):** Takes the first available shard as the full ciphertext.
3. **Erasure mode:** Calls `erasure:decode()` with the packed shard array.
4. Decrypts the ciphertext with `aes_decrypt()`.
5. Returns plaintext bytes.

### Vault Cache

Decrypted files are cached in `~/.hollow/vault_cache/{content_id}.{ext}`.

- `pipeline:VAULT_CACHE_CAP` — 1 GB hard cap.
- `pipeline:vault_cache_dir()` — returns path, creates directory if needed.
- `pipeline:cache_path(content_id, ext)` — deterministic cache file path.
- `pipeline:check_cache(content_id, ext)` — returns Some(path) if file exists on disk.
- `pipeline:write_to_cache(content_id, ext, data)` — writes decrypted data to cache, returns path.
- `pipeline:evict_cache_if_needed(max_bytes, exempt_paths)` — LRU eviction. Sorts cache files by modified time (oldest first). Evicts until total size <= 80% of max_bytes. Files in `exempt_paths` HashSet are skipped (e.g., currently playing video). Returns bytes freed. No-op if already under limit.

### Utility Functions

- `pipeline:mime_from_ext(ext)` — maps common extensions to MIME types. Fallback: "application/octet-stream".
- `pipeline:ext_from_filename(name)` — extracts lowercase extension. Fallback: "bin".

---

## content_store.rs — Shard Persistence Layer

File: `rust/hollow_core/src/vault/content_store.rs`

### StorageTier Enum

Two variants: `Standard` (images, documents, files) and `Low` (voice recordings). Serializes to "standard"/"low". `from_str()` defaults unknown values to Standard.

### ShardRecord Struct

Mirrors a `vault_shards` DB row: `shard_key`, `server_id`, `content_id`, `shard_index: u16`, `k: u16`, `m: u16`, `shard_size: u64`, `total_data_size: u64`, `stored_at: i64`, `last_verified: Option<i64>`, `storage_tier: StorageTier`, `data_hash: String`.

### PlacementRecord Struct

Tracks which peer should store which shard: `content_id`, `shard_index: u16`, `target_peer`, `server_id`, `shard_key`, `stored_at: i64`, `confirmed: bool`.

### Pure Functions

- `content_store:content_id(data)` — SHA-256 of data bytes, hex-encoded (64 chars). Canonical content identifier.
- `content_store:shard_key(content_id, shard_index)` — SHA-256(content_id_bytes || shard_index as BE u16), hex-encoded. Used as DHT routing key and local filename.

### ContentStore Struct

Content-addressed storage layer. Manages shard files on disk and metadata in SQLCipher. Created with `ContentStore::open(db_path, passphrase, base_dir)`.

### SQLCipher Tables

Created on `open()`:

**vault_shards** (PRIMARY KEY: shard_key):
- shard_key TEXT, server_id TEXT, content_id TEXT, shard_index INTEGER, k INTEGER, m INTEGER, shard_size INTEGER, total_data_size INTEGER, stored_at INTEGER, last_verified INTEGER (nullable), storage_tier TEXT (default 'standard'), data_hash TEXT
- Indices: `(server_id, content_id)`, `(server_id, storage_tier)`

**vault_placement** (PRIMARY KEY: content_id, shard_index):
- content_id TEXT, shard_index INTEGER, target_peer TEXT, server_id TEXT, shard_key TEXT, stored_at INTEGER, confirmed INTEGER (default 0)
- Indices: `(server_id)`, `(target_peer)`

**vault_manifests** (PRIMARY KEY: content_id):
- content_id TEXT, server_id TEXT, channel_id TEXT, manifest_json TEXT, k INTEGER, m INTEGER, original_size INTEGER, storage_tier TEXT (default 'standard'), created_at INTEGER, creator_peer_id TEXT
- Indices: `(server_id)`, `(server_id, created_at)`

**vault_member_status** (PRIMARY KEY: peer_id, server_id):
- peer_id TEXT, server_id TEXT, last_seen INTEGER

### Disk Layout

Shard files live at `{base_dir}/{sanitized_server_id}/{sanitized_shard_key}.shard`. The base_dir is typically `~/.hollow/vault/`. `sanitize_path_component()` keeps only alphanumeric, hyphen, underscore.

### Shard Operations

- `content_store:ContentStore::store_shard(server_id, cid, shard_index, k, m, total_data_size, tier, data)` — computes shard_key from (cid, shard_index), computes SHA-256 data_hash, writes data to disk, inserts/replaces metadata in vault_shards. Returns shard_key.
- `content_store:ContentStore::read_shard(server_id, shard_key)` — reads data from disk, looks up expected data_hash from DB, verifies SHA-256 match. Updates last_verified timestamp on success. Returns error on integrity failure ("expected X, got Y").
- `content_store:ContentStore::read_shard_unchecked(server_id, shard_key)` — reads data from disk without integrity check. Performance path used in download pipeline.
- `content_store:ContentStore::delete_shard(server_id, shard_key)` — removes file from disk, deletes DB record.
- `content_store:ContentStore::delete_content(server_id, cid)` — collects all shard_keys for the content, deletes files and DB records. Returns count deleted.
- `content_store:ContentStore::has_shard(shard_key)` — DB existence check.
- `content_store:ContentStore::get_shard_record(shard_key)` — full metadata lookup from DB.
- `content_store:ContentStore::mark_verified(shard_key)` — updates last_verified to now.

### Listing and Stats

- `content_store:ContentStore::list_shards(server_id)` — all shards for a server, ordered by (content_id, shard_index).
- `content_store:ContentStore::list_content_shards(server_id, cid)` — shards for one content item, ordered by shard_index.
- `content_store:ContentStore::total_storage_used(server_id)` — SUM(shard_size) in bytes.
- `content_store:ContentStore::total_manifest_size(server_id)` — SUM(original_size) from manifests. Represents total logical data, not local shard size.
- `content_store:ContentStore::total_storage_used_all()` — SUM(shard_size) across all servers.
- `content_store:ContentStore::verify_server_shards(server_id)` — integrity-checks every shard for a server via `read_shard()`. Returns list of shard_keys that failed (corrupt or missing).

### Placement Tracking

- `content_store:ContentStore::save_placements(server_id, cid, placements)` — INSERT OR REPLACE for each ShardPlacement.
- `content_store:ContentStore::load_placements(cid)` — ordered by shard_index.
- `content_store:ContentStore::confirm_placement(cid, shard_index)` — sets confirmed=1.
- `content_store:ContentStore::delete_placements(cid)` — deletes all for a content item.
- `content_store:ContentStore::list_server_placements(server_id)` — all placements for a server, ordered by (content_id, shard_index).
- `content_store:ContentStore::unconfirmed_placement_count(cid)` — count of unconfirmed placements.
- `content_store:ContentStore::count_confirmed_shards(content_id)` — count of confirmed placements.

### Manifest Tracking

- `content_store:ContentStore::save_manifest(server_id, channel_id, manifest)` — serializes VaultManifest to JSON, INSERT OR REPLACE.
- `content_store:ContentStore::load_manifest(cid)` — returns Option<VaultManifest>.
- `content_store:ContentStore::list_manifests(server_id)` — ordered by created_at DESC.
- `content_store:ContentStore::list_channel_manifests(server_id, channel_id)` — filtered by channel, ordered by created_at DESC.
- `content_store:ContentStore::delete_manifest(cid)` — returns bool (true if row existed).
- `content_store:ContentStore::find_expired_manifests(server_id, before_timestamp)` — for retention enforcement.

### Channel File Retention

- `content_store:ContentStore::find_expirable_channel_files(server_id_prefix, before_timestamp)` — queries the `files` table (not vault_shards) for channel files matching `context_id LIKE {server_id}%` that are completed, not expired, and created before the given timestamp. Returns `Vec<(file_id, Option<disk_path>)>`.
- `content_store:ContentStore::mark_file_expired(file_id, expired_at)` — sets expired_at on the file record.

### Member Status Tracking

- `content_store:ContentStore::update_member_last_seen(server_id, peer_id, timestamp)` — INSERT OR REPLACE into vault_member_status.
- `content_store:ContentStore::load_member_statuses(server_id)` — returns Vec<(peer_id, last_seen)>.

---

## vault_ops.rs — Swarm Command Handlers

File: `rust/hollow_core/src/node/vault_ops.rs`

All handlers are `pub(crate) async fn` called from swarm.rs match arms. They take individual state parameters (no SwarmContext struct).

### vault_ops:handle_vault_upload_file()

Orchestrates file upload to the vault. Called when the Dart side sends `NodeCommand::VaultUploadFile`. Receives pre-encrypted ciphertext, AES key, AES nonce, content_id, and metadata.

**Upload flow:**

1. Reads server state to get members list and storage pledges.
2. **Upload guard:** Computes which members are online via `peer_is_reachable()`. If not enough online for erasure coding (online < k+m), falls back to full replication among online members only. Logs warning and emits `VaultUploadReplicationFallback` event.
3. Calls `pipeline:prepare_upload()` to create the UploadPlan (shards + placements + manifest).
4. Opens ContentStore, stores local shards (those placed on self), saves placements and manifest to DB.
5. Re-prepares plan for remote distribution (needs shard data again).
6. **Remote shard distribution:** For each placement targeting a remote peer:
   - Sends `MessageEnvelope::ShardStore` metadata via MLS (targeted to peer) or Olm fallback. The `data` field is empty (data comes via binary stream).
   - Writes shard to temp file (`.stream_shard_{cid_prefix}_{shard_index}.tmp`).
   - Calls `file_handler:stream_to_peer()` to stream shard bytes via WS or WebRTC.
7. **Manifest broadcast:** Sends `MessageEnvelope::VaultManifestBroadcast` via MLS broadcast (or Olm to each member).
8. Links vault content_id to the file record in MessageStore via `set_file_content_id(message_id, content_id)`.
9. Emits `NetworkEvent::VaultUploadComplete`.

### vault_ops:handle_vault_download_file()

Orchestrates file download from the vault. Called when Dart sends `NodeCommand::VaultDownloadFile`.

**Download flow:**

1. Opens ContentStore, loads manifest by content_id.
2. Extracts file extension, checks vault cache first — returns immediately if cached.
3. Collects local shards for the content.
4. **Replication mode (k=0, m=0):** If a local shard exists, it IS the full ciphertext. Calls `pipeline:reconstruct_file()`, writes to cache, emits `VaultDownloadComplete`.
5. **Erasure mode:** Assembles k+m Option slots. For each local shard, reads data via `read_shard_unchecked()` and places in the correct index.
   - If available >= k: reconstructs locally, writes to cache, done.
   - If available < k: needs remote shards. Loads saved placements (or recomputes deterministically from server state if non-uploader). Identifies missing indices. For each missing shard whose target peer is reachable, sends `MessageEnvelope::ShardRequest` via MLS or Olm. Tracks in `pending_vault_downloads` map: `content_id -> (server_id, k, requested_count)`.
   - If not enough shard holders online (available + requested < k): emits `VaultDownloadFailed` immediately.

**Note on placement recomputation:** Non-uploaders may not have saved placements. The handler recomputes them deterministically using `adaptive:compute_adaptive_params()` + `placement:place()` with the current server state members and pledges.

### vault_ops:handle_delete_vault_content()

Deletes vault content. Requires `MANAGE_SERVER` permission.

1. Permission check via `server_state.has_permission()`.
2. Opens ContentStore, calls `delete_content()` (removes local shards) and `delete_placements()`.
3. Broadcasts `MessageEnvelope::ShardDelete` via MLS or Olm to all server members.
4. Emits `NetworkEvent::ShardDeleted`.

### vault_ops:handle_request_shard_from_peer()

Sends a `MessageEnvelope::ShardRequest` to a specific peer. Checks reachability first. Uses MLS targeted send if in group, Olm fallback otherwise. Emits `ShardRequestFailed` if peer not reachable.

### vault_ops:handle_store_shard_on_peer()

Sends a shard to a specific peer. Sends ShardStore metadata envelope (MLS or Olm), writes shard data to temp file, streams via `file_handler:stream_to_peer()`. Emits `ShardStoreFailed` if peer not reachable.

### Incoming Envelope Handlers

These handle `MessageEnvelope` variants received from other peers via MLS or Olm:

**vault_ops:handle_envelope_shard_store()** — receives ShardStore metadata. Validates sender is server member. If `chunks == 0 && data.is_empty()`: streamed shard, registers in `pending_shard_streams` map (key = `{cid}:{si}`) for binary WS stream arrival. If `chunks == 0 && data` non-empty: inline shard (base64), decodes and stores via ContentStore. Sends `ShardStoreAck` back via MLS.

**vault_ops:handle_envelope_shard_chunk()** — legacy no-op. Logs and ignores.

**vault_ops:handle_envelope_shard_store_ack()** — processes ack from peer. Emits `NetworkEvent::ShardStoreAckReceived` with success/failure.

**vault_ops:handle_envelope_shard_delete()** — receives deletion command. Validates sender has MANAGE_SERVER permission (checks role default_permissions). Deletes local shards via ContentStore. Emits `ShardDeleted`.

**vault_ops:handle_envelope_shard_request()** — peer requests a shard from us. Validates sender is server member. Reads shard from ContentStore. Sends `ShardResponse` metadata (data field empty, found=true) via MLS/Olm, then streams shard bytes via temp file + `stream_to_peer()`. If shard not found: sends ShardResponse with found=false.

**vault_ops:handle_envelope_shard_response()** — receives shard response metadata. If found && data empty: registers in `pending_shard_streams` for binary stream arrival. If found && data non-empty: decodes base64, emits `ShardReceived`.

**vault_ops:handle_envelope_shard_response_chunk()** — legacy no-op.

**vault_ops:handle_envelope_shard_probe()** — peer asks "what shards do you have for this content?" Validates membership. Lists local shards via ContentStore, sends `ShardProbeResponse` with shard index list.

**vault_ops:handle_envelope_shard_probe_response()** — informational log only. Records which shards a peer has for a given content_id.

**vault_ops:handle_envelope_vault_manifest_broadcast()** — receives manifest from another member. Deserializes VaultManifest JSON, saves to local ContentStore. If message_id is present, links it in MessageStore via `set_file_content_id()`.

**vault_ops:handle_envelope_shard_migrate()** — receives a migrated shard (rebalancing). Validates sender is server member. Decodes base64 shard data, stores via ContentStore with tier=Standard and k=0,m=0,total_size=0 (placeholder metadata).

---

## rebalancer.rs — Under-Replication Detection and Repair

File: `rust/hollow_core/src/vault/rebalancer.rs`

### Data Types

- `UnderReplicatedContent` — content at risk: `content_id`, `server_id`, `k`, `available_count`, `total_count`, `missing_indices`.
- `RepairPlan` — plan to fix under-replication: `content_id`, `server_id`, `missing_indices`, `available_shards: Vec<(shard_index, peer_id)>`, `new_targets: Vec<(shard_index, peer_id)>`.
- `ShardMigration` — move shard between peers: `content_id`, `shard_index`, `from_peer`, `to_peer`, `shard_key`.

### rebalancer:scan_under_replicated()

Scans all manifests for content that has fewer confirmed+online shard holders than needed.

- **Erasure-coded content (k > 0):** Counts placements where `confirmed == true AND target_peer in online_peers`. If count < k, content is under-replicated. Missing indices = all indices 0..n where no confirmed+online placement exists.
- **Full-replication content (k=0, m=0):** Counts confirmed+online placements. If count < 2 (and total placements >= 2), content is under-replicated.

Returns `Vec<UnderReplicatedContent>`.

### rebalancer:compute_repair_plan()

Given a manifest, its placements, online peers, members, and pledges, computes how to fix under-replication.

1. Identifies available shards (confirmed + target online).
2. For erasure-coded content: if available < k, returns None (can't reconstruct, repair impossible).
3. Identifies missing shard indices.
4. Recomputes full placement using `placement:compute_shard_placements()` to determine new targets for missing indices.
5. Returns RepairPlan with available_shards (for reconstruction source) and new_targets (where to store repaired shards).

### rebalancer:compute_migration_plan()

Computes shard movements when membership changes (e.g., new member joins). Compares old PlacementRecords with newly computed ShardPlacements. For each shard index where the target_peer differs between old and new, emits a ShardMigration entry.

Used when: a new member joins and the XOR-distance-based placement shifts some shards to them for better distribution.

---

## recovery_pool.rs — Evidence Recovery Protocol

File: `rust/hollow_core/src/node/recovery_pool.rs`

Manages cooperative shard gathering for ex-members of dead/disbanded servers. Members pool their locally stored shards to reconstruct as many files as possible.

### Data Types

- `MemberInventory` — a member's local shard inventory: `manifest_ids: Vec<String>`, `shards: HashMap<String, Vec<u16>>` (content_id -> shard indices).
- `TransferAssignment` — single transfer in the plan: `content_id`, `shard_index`, `source_peer`, `dest_peer`.
- `PoolStatus` — dashboard summary: `total_files`, `reconstructable`, `partial`, `no_shards`, `progress_pct`.
- `ManifestMeta` — manifest metadata: `k`, `m`, `total_data_size`, `storage_tier`, `file_name`.

### RecoveryPoolState Struct

State of an active recovery pool:

- `server_id`, `token`, `is_initiator`, `local_peer_id`
- `members: HashMap<String, MemberInventory>` — all pool participants and their inventories
- `all_manifest_ids: HashSet<String>` — union of all known manifest content_ids
- `file_k_values: HashMap<String, u16>` — k value needed for each file's reconstruction
- `manifest_meta: HashMap<String, ManifestMeta>` — full metadata per file
- `received_shards: HashSet<(String, u16)>` — shards received during this session
- `reconstructed: HashSet<String>` — files successfully reconstructed

### RecoveryPoolState Methods

- `recovery_pool:RecoveryPoolState::new()` — initializes with local peer's inventory. Sets up members map with self.
- `recovery_pool:RecoveryPoolState::add_member(peer_id, inventory)` — adds peer, merges their manifest_ids into all_manifest_ids.
- `recovery_pool:RecoveryPoolState::remove_member(peer_id)` — removes peer from pool.
- `recovery_pool:RecoveryPoolState::mark_shard_received(content_id, shard_index)` — records shard receipt.
- `recovery_pool:RecoveryPoolState::mark_reconstructed(content_id)` — marks file as done.
- `recovery_pool:RecoveryPoolState::compute_status()` — computes PoolStatus. Categorizes files as reconstructed, partial (at least one shard in pool), or no_shards (zero shards in pool).
- `recovery_pool:RecoveryPoolState::compute_transfer_plan()` — determines which shards to send where. For each unreconstructed content_id, builds a map of shard_index -> holder peers. For each shard, the first holder is designated as source. Assigns transfers to every other pool member who doesn't have that shard (including peers with zero shards for this content). Returns Vec<TransferAssignment>.
- `recovery_pool:RecoveryPoolState::room_code()` — returns `"recovery:{server_id}:{token}"`.
- `recovery_pool:RecoveryPoolState::is_coordinator()` — lowest peer_id among all members. Deterministic coordinator election.
- `recovery_pool:RecoveryPoolState::populate_from_content_store(cs)` — reads all manifests for the server from ContentStore. Populates `manifest_meta` and `file_k_values` for erasure-coded files (skips full-replication files).

### recovery_pool:build_local_inventory()

Builds a MemberInventory from the local ContentStore for a given server. Lists all manifests (filtering to erasure-coded only for manifest_ids) and all local shards. Returns MemberInventory with content_id -> shard_index mapping.

### Recovery Pool Command Handlers (in vault_ops.rs)

**vault_ops:handle_initiate_recovery_pool():**
1. Joins a WSS relay room with code `"recovery:{server_id}:{token}"`.
2. Builds local shard inventory via `build_local_inventory()`.
3. Generates invite link: `hollow://recovery?server={server_id}&token={token}`.
4. Creates RecoveryPoolState (is_initiator=true), populates manifest metadata.
5. Emits `NetworkEvent::RecoveryPoolCreated` with invite_link.

**vault_ops:handle_join_recovery_pool():**
1. Joins the WSS relay room.
2. Builds local inventory.
3. Sends `HavenMessage::RecoveryHello` to the room (plaintext, not MLS) with manifest_ids and shard_inventory_json.
4. Creates RecoveryPoolState (is_initiator=false), populates manifest metadata.
5. Emits `NetworkEvent::RecoveryPoolJoined`.

**vault_ops:handle_stop_recovery_pool():**
1. Takes the pool state (Option::take).
2. Broadcasts `HavenMessage::RecoveryStop` to the room.
3. Leaves the WSS relay room.
4. Emits `NetworkEvent::RecoveryPoolStopped`.

---

## Network Protocol — MessageEnvelope Variants

All vault-related MessageEnvelope variants (defined in `node/types.rs`):

| Variant | Direction | Purpose |
|---------|-----------|---------|
| `ShardStore { sid, cid, si, sk, k, m, total_size, tier, data, chunks, target }` | uploader -> holder | Shard storage metadata. data="" means binary stream follows |
| `ShardChunk { sid, cid, si, ci, data }` | legacy | No-op, ignored |
| `ShardStoreAck { sid, cid, si, ok, err, target }` | holder -> uploader | Confirms shard receipt |
| `ShardDelete { sid, cid }` | admin -> all | Delete all shards for content |
| `ShardRequest { sid, cid, si, sk, target }` | downloader -> holder | Request a specific shard |
| `ShardResponse { sid, cid, si, data, chunks, found, target }` | holder -> downloader | Shard response metadata. data="" means stream |
| `ShardResponseChunk { sid, cid, si, ci, data, target }` | legacy | No-op, ignored |
| `ShardProbe { sid, cid, target }` | any -> any | "What shards do you have for this content?" |
| `ShardProbeResponse { sid, cid, shards, target }` | any -> any | List of shard indices held |
| `ShardMigrate { sid, cid, si, sk, data, target }` | old holder -> new holder | Rebalance shard transfer (base64 data) |
| `VaultManifestBroadcast { sid, cid, chid, manifest }` | uploader -> all | Broadcast manifest JSON to server |

All variants with `target: Option<String>` support MLS targeted delivery.

### Pending State in swarm.rs

- `pending_vault_downloads: HashMap<String, (String, usize, usize)>` — content_id -> (server_id, k, requested_count). Tracks in-progress downloads waiting for remote shards.
- `pending_shard_streams: HashMap<String, PendingShardStream>` — key `"{cid}:{si}"`. Registered when ShardStore/ShardResponse metadata arrives with empty data, indicating binary stream follows. Contains server_id, content_id, shard_index, shard_key, k, m, total_size, tier.

---

## End-to-End Flow Examples

### Upload Flow (Erasure-Coded, 8-Member Server)

1. Dart sends `NodeCommand::VaultUploadFile` with pre-encrypted ciphertext + AES key/nonce.
2. `handle_vault_upload_file()` checks 8 members -> VaultMode::ErasureCoding { k:3, m:2 }.
3. `prepare_upload()` splits ciphertext into 3 data + 2 parity = 5 packed shards.
4. `place()` assigns each shard to a different member via XOR distance.
5. Local shards stored via ContentStore. Placements and manifest saved to DB.
6. For each remote shard: ShardStore metadata sent via MLS, shard bytes streamed via WS binary.
7. VaultManifestBroadcast sent to all members via MLS.
8. Each receiver's `handle_envelope_vault_manifest_broadcast()` saves manifest locally.
9. Each shard receiver's `handle_envelope_shard_store()` registers pending_shard_stream, receives binary data, stores via ContentStore, sends ShardStoreAck.

### Download Flow (Erasure-Coded, Partial Local Shards)

1. Dart sends `NodeCommand::VaultDownloadFile`.
2. `handle_vault_download_file()` loads manifest, checks cache (miss).
3. Finds 1 local shard out of 5 (need k=3).
4. Loads/recomputes placements. Identifies 2 missing shards with online holders.
5. Sends ShardRequest to each holder via MLS.
6. Registers content_id in `pending_vault_downloads`.
7. Holders respond with ShardResponse metadata + binary stream.
8. As each shard arrives (via pending_shard_streams), stored locally.
9. When pending_vault_downloads reaches k=3 available shards, triggers reconstruction.
10. `reconstruct_file()` decodes erasure shards, decrypts AES, writes to vault_cache.
11. Emits `VaultDownloadComplete` with disk_path.

### Recovery Pool Flow

1. Initiator calls `handle_initiate_recovery_pool()`, joins `recovery:{server_id}:{token}` room.
2. Participants call `handle_join_recovery_pool()`, send RecoveryHello with shard inventories.
3. Pool coordinator (lowest peer_id) calls `compute_transfer_plan()` to determine shard transfers.
4. Shards streamed between pool members as TransferAssignments.
5. When a member accumulates >= k shards for a file, reconstructs it locally.
6. Initiator or any member can call `handle_stop_recovery_pool()` to end session.
