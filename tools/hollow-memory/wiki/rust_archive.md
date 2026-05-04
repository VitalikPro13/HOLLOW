# Archive System — Export, Import, Verification

Module path: `rust/hollow_core/src/archive/` (mod.rs re-exports `types`, `exporter`, `loader`). Provides cryptographically signed, tamper-evident export of DMs, channels, or entire servers as `.hollow-archive` ZIP files. Every message retains its Ed25519 signature chain; the archive itself is signed by the exporter's keypair with a deterministic SHA-256 content hash.

Format version: `ARCHIVE_FORMAT_VERSION = 1` (constant in `types.rs`).

---

## types.rs — Data Structures

### ArchiveTarget (enum, not serialized)

Specifies what to export. Constructed by the FFI layer, consumed by `exporter::export_archive()`.

- `Dm { peer_id }` — all messages with a specific DM peer.
- `Channel { server_id, channel_id, channel_name: Option }` — single server channel.
- `Server { server_id, server_name, channels: Vec<(channel_id, channel_name)> }` — all channels in a server, exported as one archive.

### FileMode (enum, serialized as snake_case string)

Controls which file attachments are embedded in the archive ZIP.

- `Full` — include all files referenced by messages.
- `ImagesOnly` — include only files where `is_image == true`.
- `Placeholder` — include no file bytes, only metadata stubs.

Conversion: `FileMode::from_str("full"|"images_only"|_)`, `FileMode::as_str()`.

### ArchiveManifest (manifest.json)

Top-level metadata stored at the ZIP root.

| Field | Type | Notes |
|---|---|---|
| `format_version` | u32 | Always `ARCHIVE_FORMAT_VERSION` (1) |
| `archive_type` | String | `"dm"`, `"channel"`, or `"server"` |
| `exporter_peer_id` | String | Ed25519-derived PeerId of the exporter |
| `export_timestamp` | i64 | Milliseconds since epoch |
| `message_count` | u32 | Total messages in archive |
| `file_mode` | String | `"full"` / `"images_only"` / `"placeholder"` |
| `peer_id` | Option | DM-only: the other participant |
| `server_id` | Option | Channel/server archives |
| `channel_id` | Option | Channel archives only |
| `channel_name` | Option | Channel archives only |
| `server_name` | Option | Server archives only |
| `channels` | Vec\<ArchiveChannelInfo\> | Server archives: per-channel id/name/count |
| `participants` | Vec\<String\> | All unique sender peer_ids, sorted |

Optional fields use `#[serde(skip_serializing_if = "Option::is_none")]` / `#[serde(default)]`.

### ArchiveChannelInfo

Used in server (multi-channel) archives inside `ArchiveManifest.channels`.

Fields: `channel_id`, `channel_name`, `message_count: u32`.

### ArchiveMessage (messages/{message_id}.json)

One file per message in the ZIP.

| Field | Type | Notes |
|---|---|---|
| `message_id` | String | UUID; legacy fallback: `"legacy-{sender}-{timestamp}"` |
| `sender_id` | String | PeerId of the sender |
| `text` | String | Message content |
| `timestamp` | i64 | Original send time (millis) |
| `signature` | Option | Base64 Ed25519 signature of message_signing_payload() |
| `public_key` | Option | Base64 Ed25519 public key (protobuf-encoded) |
| `edited_at` | Option | Timestamp of latest edit |
| `hidden_at` | Option | Timestamp of hide/delete action |
| `reply_to_mid` | Option | Message ID being replied to |
| `file_id` | Option | Attached file ID |
| `channel_id` | Option | Populated only in server (multi-channel) archives |
| `reactions` | Vec\<ArchiveReaction\> | Inline reactions (default empty) |

### ArchiveReaction (inline in ArchiveMessage)

Fields: `emoji`, `peer_id`, `added_at: i64`, `signature: Option`, `public_key: Option`.

### ArchiveEdit (edits/{message_id}.json — JSON array per message)

Each file contains a JSON array of all edits for that message ID.

| Field | Type | Notes |
|---|---|---|
| `message_id` | String | |
| `old_text` | String | Text before this edit |
| `new_text` | String | Text after this edit |
| `edited_at` | i64 | When the edit occurred |
| `signature` | Option | Signature of the new text |
| `public_key` | Option | Public key for verification |
| `prev_signature` | Option | Signature of the pre-edit state |
| `prev_public_key` | Option | Public key of the pre-edit state |
| `prev_timestamp` | Option | Timestamp of the pre-edit state |

The `prev_*` fields form a cryptographic chain linking each edit back to the state it replaced.

### ArchiveDeletion (deletions/{message_id}.json — JSON array per message)

Fields: `message_id`, `deleted_text` (content at time of deletion), `deleted_at: i64`, `signature: Option`, `public_key: Option`.

### ArchiveReactionRemoval (reaction_removals/{message_id}.json — JSON array per message)

Fields: `message_id`, `emoji`, `peer_id`, `removed_at: i64`, `signature: Option`, `public_key: Option`.

### ArchiveFileMetadata (files/{file_id}.meta.json)

| Field | Type | Notes |
|---|---|---|
| `file_id` | String | |
| `file_name` | String | Original filename |
| `file_ext` | String | Extension |
| `mime_type` | String | |
| `size_bytes` | u64 | |
| `is_image` | bool | |
| `width` / `height` | Option\<u32\> | Image dimensions |
| `sha256` | Option | Hex SHA-256 of file bytes (only when included) |
| `included` | bool | Whether actual bytes are in the archive |

### ArchivePubKey (pubkeys.json — JSON array)

Fields: `peer_id`, `public_key_b64`. One entry per unique participant whose public key was found across messages, reactions, edits, deletions, and removals.

### ArchiveSignature (archive_signature.json)

Fields: `exporter_peer_id`, `signature_b64` (Ed25519 over content_hash), `public_key_b64`, `content_hash_hex` (SHA-256 hex of the deterministic archive hash).

### Loader Result Types

**MessageVerification**: `message_id`, `has_signature: bool`, `signature_valid: bool`. One per message.

**LoadedArchive**: Full parsed result returned by `loader::load_archive()`.
- `manifest: ArchiveManifest`
- `messages: Vec<ArchiveMessage>` (sorted by timestamp)
- `edits`, `deletions`, `reaction_removals` — flat Vecs
- `pubkeys: Vec<ArchivePubKey>`
- `file_metadata: Vec<ArchiveFileMetadata>`
- `files_dir: Option<String>` — temp directory path with extracted file bytes (if any)
- `archive_signature_valid: bool`
- `per_message_results: Vec<MessageVerification>`

**VerifyResult**: Summary for quick verification (used by `loader::verify_archive()`).
- Archive metadata: `archive_type`, `exporter_peer_id`, `export_timestamp`, `message_count`
- `archive_signature_valid: bool`
- Signature counts: `messages_with_valid_sig`, `messages_with_invalid_sig`, `messages_without_sig`
- `participant_ids: Vec<String>`
- Context fields: `peer_id`, `server_id`, `channel_id`, `channel_name`, `server_name`, `channels`

---

## exporter.rs — Archive Creation

### exporter::export_archive()

**Signature:** `pub(crate) fn export_archive(store: &MessageStore, keypair: &NativeKeypair, target: ArchiveTarget, file_mode: FileMode, data_dir: &Path) -> Result<Vec<u8>, String>`

Returns the complete `.hollow-archive` ZIP as in-memory bytes. The function is synchronous and performs 15 sequential steps:

#### Step 1: Load all messages

Dispatches on `ArchiveTarget`:

- **DM**: Calls `store.load_all_dm_messages(peer_id)`. Maps `is_mine` to the exporter's peer_id or the message's `peer_id` for sender_id. Legacy messages without `message_id` get a synthetic ID: `"legacy-{sender}-{timestamp}"`. `channel_id` is `None` for all DM messages. Reactions are left empty (attached in step 4).

- **Channel**: Calls `store.load_all_channel_messages(server_id, channel_id)`. Uses `sender_id` directly from stored messages. Same legacy ID fallback. `channel_id` is `None` (single-channel archives don't need it).

- **Server**: Iterates each `(channel_id, channel_name)` pair, calls `store.load_all_channel_messages()` per channel. Sets `channel_id = Some(ch_id)` on each message. Builds `Vec<ArchiveChannelInfo>` with per-channel `message_count`. All messages are collected into one flat `Vec<ArchiveMessage>`.

Return tuple: `(archive_type, _context_str, peer_id_opt, server_id_opt, channel_id_opt, channel_name_opt, server_name_opt, channel_infos, messages)`.

#### Step 2: Collect message IDs

Extracts all `message_id` values into `Vec<String>` for batch database queries.

#### Step 3: Batch-load related data

Four batch queries to `MessageStore`:
- `store.load_reactions_for_sync(&message_ids)` — returns `HashMap<String, Vec<(emoji, peer_id, added_at, sig, pk)>>`
- `store.load_edits_for_messages(&message_ids)` — returns `HashMap<String, Vec<(old_text, new_text, edited_at, sig, pk, prev_sig, prev_pk, prev_ts)>>`
- `store.load_deletions_for_messages(&message_ids)` — returns `HashMap<String, Vec<(deleted_text, deleted_at, sig, pk)>>`
- `store.load_reaction_removals_for_messages(&message_ids)` — returns `HashMap<String, Vec<(emoji, peer_id, removed_at, sig, pk)>>`

#### Step 4: Attach reactions inline

For each message, looks up `reactions_map` by `message_id` and converts tuples to `ArchiveReaction` structs, attaching them directly to `ArchiveMessage.reactions`.

#### Steps 5-7: Build edits, deletions, reaction removals

For each related data type:
1. Builds a flat `Vec` (e.g., `all_edits`) for later use.
2. Builds a `BTreeMap<String, Vec<...>>` keyed by `message_id` for per-message JSON serialization.

BTreeMap is critical here: it guarantees sorted iteration by message_id, which is required for deterministic hashing.

#### Step 8: Collect unique public keys

Scans four sources for public keys, building `HashMap<peer_id, pk_b64>`:
1. `ArchiveMessage.public_key` (keyed by `sender_id`)
2. `ArchiveReaction.public_key` (keyed by `peer_id`)
3. `ArchiveEdit.public_key` (keyed by the sender of the parent message, found via lookup)
4. `ArchiveDeletion.public_key` (same parent-message lookup)
5. `ArchiveReactionRemoval.public_key` (keyed by `peer_id`)

Uses `or_insert_with` to keep only the first public key found per peer (all should be identical).

#### Step 9: Handle files

- Reads `data_dir.join("files")` for stored file bytes.
- Collects unique `file_id` values from messages.
- For each file ID, calls `store.get_file_metadata(fid)` to get `StoredFile` metadata.
- File inclusion logic based on `FileMode`:
  - `Full` — always include.
  - `ImagesOnly` — include only if `sf.is_image`.
  - `Placeholder` — never include bytes.
- If included and the file exists on disk at `{files_dir}/{file_id}.{ext}`, reads bytes and computes SHA-256.
- Stores bytes in `BTreeMap<String, Vec<u8>>` keyed by `"{file_id}.{ext}"` (BTreeMap for deterministic ZIP order).
- Builds `ArchiveFileMetadata` with `included: bool` and optional `sha256`.

#### Step 10: Build participants list

Collects all unique `sender_id` values from messages into a `HashSet`, converts to sorted `Vec<String>`.

#### Step 11: Build manifest

Constructs `ArchiveManifest` from all collected data.

#### Step 12: Serialize everything to JSON

All serialization uses `serde_json::to_vec_pretty()`. Everything goes into `BTreeMap<String, Vec<u8>>` containers:
- `message_jsons`: keyed by `message_id`
- `edit_jsons`: keyed by `message_id`
- `deletion_jsons`: keyed by `message_id`
- `removal_jsons`: keyed by `message_id`
- `file_meta_jsons`: keyed by `file_id`

BTreeMap ensures sorted key order for deterministic hashing.

#### Step 13: Compute archive-level hash

Calls `compute_archive_hash()` (see below). Produces `content_hash_hex` (SHA-256 hex string).

#### Step 14: Sign the hash

- `keypair.sign(&content_hash)` — Ed25519 signature over the raw 32-byte hash.
- Encodes signature and public key as base64.
- Builds `ArchiveSignature` struct.

#### Step 15: Write ZIP

Uses `zip::ZipWriter` with `Deflated` compression. Writes entries in this exact order:

1. `manifest.json`
2. `messages/{message_id}.json` (one per message, BTreeMap-sorted by ID)
3. `edits/{message_id}.json` (one per edited message)
4. `deletions/{message_id}.json` (one per deleted message)
5. `reaction_removals/{message_id}.json` (one per message with removed reactions)
6. `pubkeys.json`
7. `files/{file_id}.meta.json` (one per referenced file)
8. `files/{file_id}.{ext}` (actual bytes, only for included files)
9. `archive_signature.json`

Returns `Vec<u8>` (the in-memory ZIP bytes).

### exporter::compute_archive_hash()

**Signature:** `fn compute_archive_hash(manifest_json: &[u8], message_jsons: &BTreeMap<String, Vec<u8>>, edit_jsons: &BTreeMap<String, Vec<u8>>, deletion_jsons: &BTreeMap<String, Vec<u8>>, removal_jsons: &BTreeMap<String, Vec<u8>>, file_hashes: &BTreeMap<String, String>) -> [u8; 32]`

Produces a deterministic SHA-256 hash over the entire archive content. The algorithm:

1. Hash the manifest JSON bytes, append `\n`.
2. For each message JSON (BTreeMap-sorted by message_id): compute SHA-256 of the JSON bytes, append the hex-encoded hash + `\n` to the running hasher.
3. Same for edit JSONs (sorted by message_id).
4. Same for deletion JSONs (sorted by message_id).
5. Same for reaction removal JSONs (sorted by message_id).
6. For each file hash (BTreeMap-sorted by file_id): append the SHA-256 hex string (or `"placeholder"` for non-included files) + `\n`.

The two-level hashing (SHA-256 of individual JSONs fed into the outer SHA-256) prevents length-extension issues while keeping memory usage bounded.

BTreeMap iteration guarantees lexicographic key ordering, making the hash fully deterministic regardless of insertion order.

---

## loader.rs — Archive Import and Verification

### loader::load_archive()

**Signature:** `pub(crate) fn load_archive(zip_bytes: &[u8]) -> Result<LoadedArchive, String>`

Loads and fully verifies a `.hollow-archive` from raw bytes. Returns `LoadedArchive` with all parsed data and verification results.

#### Step 1: Parse manifest

Opens the ZIP, reads `manifest.json`, deserializes to `ArchiveManifest`. Validates `format_version == ARCHIVE_FORMAT_VERSION`; returns error if mismatched.

#### Step 2: Read pubkeys.json

Parses `pubkeys.json` into `Vec<ArchivePubKey>`. Gracefully defaults to empty Vec if the file is missing.

#### Step 3: Read all ZIP entries for hash verification

Single-pass iteration over all ZIP entries. Reads raw bytes into categorized BTreeMaps:
- `manifest_bytes: Option<Vec<u8>>`
- `message_entries: BTreeMap<String, Vec<u8>>` — key extracted from `messages/{mid}.json`
- `edit_entries: BTreeMap<String, Vec<u8>>` — from `edits/{mid}.json`
- `deletion_entries: BTreeMap<String, Vec<u8>>` — from `deletions/{mid}.json`
- `removal_entries: BTreeMap<String, Vec<u8>>` — from `reaction_removals/{mid}.json`
- `file_meta_entries: BTreeMap<String, Vec<u8>>` — from `files/{fid}.meta.json`
- `file_data_entries: BTreeMap<String, Vec<u8>>` — from `files/{name}` (actual file bytes)
- `archive_sig_bytes: Option<Vec<u8>>`

Uses `strip_prefix`/`strip_suffix` for path parsing. `pubkeys.json` is skipped (already parsed).

#### Step 4: Parse messages

Deserializes each entry in `message_entries` to `ArchiveMessage`. Malformed entries are logged via `hollow_log!` and skipped (not fatal). Messages are sorted by `timestamp` after parsing.

#### Steps 5-7: Parse edits, deletions, reaction removals

Each is deserialized as `Vec<T>` (since each file is a JSON array per message_id). Malformed entries are logged and skipped.

#### Step 8: Parse file metadata

Deserializes each `file_meta_entries` value to `ArchiveFileMetadata`. Malformed entries logged and skipped.

#### Step 9: Extract file bytes to temp directory

If any file data entries exist, creates a temp directory at `{std::env::temp_dir()}/hollow-archive-{timestamp_millis}/`. Writes each file's bytes to `{tmp}/{name}`. Returns the directory path as `files_dir: Option<String>`.

Uses `export_timestamp_slug()` for unique directory naming.

#### Step 10: Per-message signature verification

Determines verification context based on `archive_type`:
- **DM**: `msg_type = "dm"`, context = `manifest.peer_id`
- **Channel**: `msg_type = "ch"`, context = `"{server_id}:{channel_id}"` from manifest
- **Server**: `msg_type = "ch"`, context varies per message: `"{server_id}:{msg.channel_id}"`

For each message:
1. Check if `signature` AND `public_key` are both present (`has_signature`).
2. If signed: compute the signing payload via `message_signing_payload(msg_type, &context, &sender_id, ts, &text)`.
   - For edited messages, uses `edited_at` timestamp (not original `timestamp`), matching the signing behavior at edit time.
3. Verify via `verify_message_signature(sender_id, signature, public_key, &payload)`.
4. Record `MessageVerification { message_id, has_signature, signature_valid }`.

The `message_signing_payload()` and `verify_message_signature()` functions are imported from `crate::node` — the same functions used for live message verification, ensuring consistency.

#### Step 11: Archive-level signature verification

1. Parse `archive_signature.json` to `ArchiveSignature`.
2. Build `file_hashes: BTreeMap<String, String>` from file metadata (SHA-256 hex or `"placeholder"`).
3. Recompute `compute_archive_hash()` using the raw ZIP entry bytes (not re-serialized data). This ensures the hash matches exactly what the exporter produced.
4. Compare `recomputed_hex` with `arch_sig.content_hash_hex`. If mismatch, log and return `false`.
5. If hash matches, verify the Ed25519 signature via `verify_archive_signature()`.
6. If `archive_signature.json` is missing, logs and returns `archive_signature_valid = false`.

### loader::verify_archive()

**Signature:** `pub(crate) fn verify_archive(zip_bytes: &[u8]) -> Result<VerifyResult, String>`

Quick-verify wrapper. Calls `load_archive()` internally, then summarizes:
- Counts messages into three buckets: `messages_with_valid_sig`, `messages_with_invalid_sig`, `messages_without_sig`.
- Copies manifest metadata into `VerifyResult`.
- Does NOT return the full message/edit/deletion data — only the summary.

### loader::compute_archive_hash()

Identical algorithm to `exporter::compute_archive_hash()`. Duplicated (not shared) between the two modules. Both use the same BTreeMap-sorted iteration + two-level SHA-256 approach.

### loader::verify_archive_signature()

**Signature:** `fn verify_archive_signature(exporter_peer_id: &str, sig_b64: &str, pk_b64: &str, content_hash: &[u8; 32]) -> bool`

1. Base64-decode `pk_b64` and `sig_b64`.
2. Validate the public key is a protobuf-encoded Ed25519 key: checks `pk_bytes[0] == 0x08` and `pk_bytes[1] == 0x01` and length >= 36.
3. Derive PeerId from the public key: `multihash = [0x00, len, ...pk_bytes]`, then Base58 (Bitcoin alphabet) encode.
4. Verify derived PeerId matches `exporter_peer_id`. Rejects if mismatch (prevents signature transplant attacks).
5. Call `NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, content_hash)`.

### loader::export_timestamp_slug()

Returns current system time in millis as a string. Used for unique temp directory naming when extracting file bytes.

---

## .hollow-archive ZIP Structure

```
archive.hollow-archive (Deflated ZIP)
├── manifest.json                          # ArchiveManifest
├── messages/
│   ├── {message_id_1}.json                # ArchiveMessage (one per message)
│   ├── {message_id_2}.json
│   └── ...
├── edits/
│   ├── {message_id}.json                  # Vec<ArchiveEdit> (one file per edited message)
│   └── ...
├── deletions/
│   ├── {message_id}.json                  # Vec<ArchiveDeletion> (one file per deleted message)
│   └── ...
├── reaction_removals/
│   ├── {message_id}.json                  # Vec<ArchiveReactionRemoval> (one file per message)
│   └── ...
├── pubkeys.json                           # Vec<ArchivePubKey> (all participants)
├── files/
│   ├── {file_id}.meta.json                # ArchiveFileMetadata (always present)
│   ├── {file_id}.{ext}                    # Actual file bytes (only if included per FileMode)
│   └── ...
└── archive_signature.json                 # ArchiveSignature (Ed25519 over content hash)
```

## Cryptographic Properties

- **Per-message integrity**: Each message carries its Ed25519 signature (from `message_signing_payload()`) and public key. The loader verifies these independently using the same `verify_message_signature()` function used during live chat.
- **Edit chain**: Each edit record contains `prev_signature`/`prev_public_key`/`prev_timestamp`, linking to the pre-edit state. This forms a verifiable chain of modifications.
- **Archive-level integrity**: The deterministic content hash covers all serialized data in sorted order. BTreeMap guarantees reproducible ordering. The exporter's Ed25519 signature over this hash proves who created the archive and that nothing was added/removed/modified after export.
- **PeerId binding**: `verify_archive_signature()` derives the PeerId from the public key and checks it matches `exporter_peer_id`, preventing signature transplant attacks where someone replaces the signature but keeps the claimed identity.
- **File integrity**: Included files have SHA-256 hashes stored in metadata and incorporated into the archive-level hash. Non-included files use `"placeholder"` in the hash, so their absence is accounted for.
- **Tamper evidence**: Any modification to any JSON entry inside the ZIP invalidates the archive-level hash. Any modification to a message's text invalidates both the per-message signature and the archive-level hash.

## Key Implementation Details

- **Legacy message IDs**: Messages without a UUID get `"legacy-{sender}-{timestamp}"` as a synthetic ID. This ensures all messages have unique keys in the BTreeMap.
- **Edited message timestamp for signing**: The loader uses `msg.edited_at.unwrap_or(msg.timestamp)` when computing the signing payload. This matches the signing behavior at edit time, where the edit timestamp replaces the original.
- **Server archive context routing**: In server (multi-channel) archives, the signing context varies per message (`"{server_id}:{channel_id}"` from `msg.channel_id`), while DM/channel archives use a fixed context from the manifest.
- **Graceful degradation**: Malformed individual entries (messages, edits, deletions, etc.) are logged and skipped, not fatal. The archive can still be partially loaded and verified.
- **Hash duplication**: `compute_archive_hash()` is implemented identically in both `exporter.rs` and `loader.rs` rather than shared. Both use the exact same algorithm.
- **In-memory ZIP**: The entire archive is built and returned as `Vec<u8>` in memory, not written to disk. The caller (FFI layer) handles writing to the filesystem.
- **Temp file extraction**: Only the loader writes to disk (temp directory for file bytes). The directory path is returned to the caller for later access/cleanup.
