# HOLLOW Rust Backend Performance Audit Report

**Date:** 2026-05-07
**Scope:** Full deep scan of all Rust node modules, storage layer, crypto, FFI/API, identity, gossip, voice, vault, file handling
**Method:** 8 parallel agents reading every file in `rust/hollow_core/src/` — swarm.rs, sync_handler.rs, crypto_handler.rs, gossip_relay.rs, gossip.rs, message_ops.rs, types.rs, ws_client.rs, vault_ops.rs, file_handler.rs, voice_handler.rs, social.rs, all API files, identity modules, storage/messages.rs, crdt_store.rs

---

## CRITICAL — Systemic Issues

### C1: MessageStore::open() called 100+ times on hot paths
**Impact:** CRITICAL — dominant CPU + I/O bottleneck
**Files:** swarm.rs (45 sites), message_ops.rs (17), social.rs (8), sync_handler.rs (6), file_handler.rs (7), vault_ops.rs (15)

Every message send/receive/edit/delete/reaction, every sync batch, every social action, every file chunk opens a **brand new SQLCipher connection**:
1. `Connection::open(path)` — file I/O
2. `PRAGMA key = '...'` — SQLCipher key derivation (PBKDF2)
3. `PRAGMA auto_vacuum` check + possible `VACUUM`
4. `PRAGMA incremental_vacuum(100)`
5. ~30 `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` statements
6. FTS5 trigger setup
7. **FTS5 full index rebuild** (see C2)

The passphrase derivation (`bundle_keypair.to_protobuf_encoding()` + `hex::encode()`) is also recomputed every time — same 5-line block copy-pasted 100+ times.

Meanwhile, the API layer already has a proper singleton (`static STORE: OnceLock<Mutex<Option<MessageStore>>>`), but the node modules (the hot path) completely bypass it.

**Solution:** Create a long-lived `MessageStore` in the swarm event loop at startup (following the existing `CrdtStore` actor pattern). Pass it by reference to all handler functions. Pre-compute `db_path` and `passphrase` once. Eliminate all 100+ ad-hoc `open()` calls.

**Estimated gain:** 5-50ms saved per message operation. During sync of 200 messages, eliminates ~200 SQLCipher connection cycles. During file transfer of 1500 chunks, eliminates ~1500 connection cycles. This is likely the single largest contributor to "sluggish sync" feel.

---

### C2: FTS5 full rebuild runs on every open() call
**Impact:** CRITICAL — compounds with C1
**File:** storage/messages.rs, lines 666-672

```rust
conn.execute_batch(
    "INSERT OR IGNORE INTO messages_fts(messages_fts) VALUES('rebuild');
     INSERT OR IGNORE INTO channel_messages_fts(channel_messages_fts) VALUES('rebuild');"
)
```

The `'rebuild'` FTS5 command drops the entire full-text index and re-inserts every row from the content table. This runs on every `MessageStore::open()`. With 10k messages, each rebuild is 50-200ms on SQLCipher. Combined with C1 (100+ opens), the FTS index could be rebuilt hundreds of times per session.

**Solution:** Replace with a one-time migration flag:
```rust
let fts_done: bool = conn.query_row(
    "SELECT 1 FROM app_settings WHERE key = 'fts_backfilled'", [], |_| Ok(true)
).unwrap_or(false);
if !fts_done {
    conn.execute_batch("INSERT OR IGNORE INTO messages_fts(messages_fts) VALUES('rebuild'); ...");
    conn.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES ('fts_backfilled', '1')", []).ok();
}
```

**Estimated gain:** Eliminates 50-200ms × N opens per session. With C1 fixed (single open), this becomes a one-time cost on first launch after the FTS feature was added.

---

### C3: No WAL mode or PRAGMA tuning
**Impact:** CRITICAL — affects all DB operations
**File:** storage/messages.rs, lines 97-114

SQLite defaults to DELETE journal mode. No performance PRAGMAs are set. Missing:
- `journal_mode = WAL` — 2-5x faster writes, concurrent readers while writing
- `synchronous = NORMAL` — reduces fsync calls (safe with WAL)
- `cache_size = -8000` — 8MB page cache vs default 2MB
- `temp_store = MEMORY` — temp tables in memory instead of disk

Note: `mmap_size` is NOT supported with SQLCipher (encrypted pages can't be memory-mapped).

**Solution:** Add after `PRAGMA key`:
```rust
conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA synchronous = NORMAL;
     PRAGMA cache_size = -8000;
     PRAGMA temp_store = MEMORY;"
)?;
```

**Estimated gain:** 2-5x write throughput improvement. Eliminates reader-blocks-writer contention between the API FFI thread and the swarm event loop. 4 lines of code for massive improvement.

---

### C4: FFI layer re-derives identity + opens DB + parses full ServerState on every call
**Impact:** CRITICAL — affects app responsiveness on navigation
**File:** api/crdt.rs (14 sites), api/storage.rs

Every Dart→Rust FFI query (`get_server_channels`, `get_server_members`, `get_my_role`, `get_my_permissions`, `get_pinned_messages`, `get_channel_layout`, `get_server_labels`) does:
1. `load_or_create_identity()` — reads `identity.key` from disk (file I/O)
2. `to_protobuf_encoding()` — serializes keypair (heap alloc)
3. `hex::encode()` — derives passphrase (heap alloc)
4. `MessageStore::open()` — full SQLCipher connection cycle
5. `serde_json::from_str::<ServerState>()` — parses the ENTIRE server state JSON

Switching to a server triggers 4-7 of these in sequence. The same ServerState JSON blob is parsed 7 times. With 50 members and 20 channels, each parse is non-trivial.

**Solution:**
1. Cache passphrase in `OnceLock<String>` (never changes after identity load)
2. Use existing global `STORE` singleton for read-only queries
3. Add batch FFI: `get_server_info(server_id) -> ServerInfoFfi` returning channels, members, role, permissions, layout in one call (one DB open, one JSON parse)

**Estimated gain:** 7x reduction in DB opens and JSON parses per server switch. Directly impacts the "weird reloading" feel when navigating between servers.

---

## HIGH Impact

### H1: persist_mls_state() on every MLS encrypt AND decrypt
**Impact:** HIGH — fires on every channel message in/out
**File:** crypto_handler.rs, lines 80-94

Serializes the entire OpenMLS MemoryStorage HashMap (all groups, all epochs, all members) on every single message encrypt and decrypt. The signer and credential bytes (immutable after creation) are also re-serialized every time.

In an active server with 10 people chatting, this fires on every incoming and outgoing message — dozens of times per second.

**Solution:** Debounce: only persist on epoch-changing operations (commit, welcome, process_commit), not on application messages. Use a dirty flag + 2-second timer for crash recovery. Cache signer/credential bytes (they never change).

**Estimated gain:** Eliminates the biggest CPU sink in the crypto hot path. Reduces MLS overhead from per-message to per-epoch-change (orders of magnitude less frequent).

---

### H2: persist_crypto_state() pickles entire Olm account on every DM
**Impact:** HIGH — fires on every DM send/receive + every file chunk
**File:** crypto_handler.rs, lines 328-335

Account state (identity keys, one-time keys) doesn't change per-message, but gets fully pickled on every encrypt/decrypt. During file transfers (100MB at 256KB chunks = 400 chunks), that's 400 account pickles.

**Solution:** Split into `persist_session_state` (session ratchet only, per-message) and `persist_account_state` (full account, only on key generation/consumption). Add `account_dirty` flag.

**Estimated gain:** Eliminates redundant account serialization. Session pickle is still needed (ratchet advances), but account pickle drops from per-message to per-key-event.

---

### H3: Full ServerState serialization (including op_log) on every CRDT op
**Impact:** HIGH — grows linearly with server history
**File:** sync_handler.rs (23 sites), swarm.rs (6 sites)

Every CRDT mutation (nickname change, channel rename, role edit, etc.) serializes the ENTIRE ServerState to JSON — members, channels, roles, AND the complete `op_log: Vec<CrdtOp>` which grows unboundedly. A server with 1000 ops produces 100KB+ JSON on every single operation.

Pattern (appears 29 times):
```rust
crdt_store.insert_op(op.clone());
if let Ok(json) = serialize_state_lean(state) {
    crdt_store.save_state(server_id.clone(), json);
}
```

**Solution:** Add `#[serde(skip_serializing)]` to `op_log` in ServerState. Ops are already individually persisted via `insert_op`. Reconstruct op_log from DB on load. This alone reduces serialization cost by 60-80%.

Alternative: dirty flag + deferred serialization (serialize only when CrdtStore batch-drain fires).

**Estimated gain:** For a server with 500 ops, each CRDT mutation drops from serializing ~50-100KB to ~10-20KB. Prevents linear degradation as servers age.

---

### H4: Share scheduler tick at 50ms instead of documented 1000ms
**Impact:** HIGH — 20 unnecessary wakeups/sec when idle
**File:** swarm.rs, line 410-411

```rust
let mut share_tick_timer = tokio::time::interval(Duration::from_millis(50));
```

Comment says "1 second" but actual interval is 50ms. That's 20 ticks/sec even with zero active shares. Each tick does HashMap lookups and time checks.

**Solution:** Change to `Duration::from_millis(1000)`. Use adaptive interval if finer granularity needed during active downloads.

**Estimated gain:** 19 fewer async wakeups per second when idle. Reduces baseline CPU usage.

---

### H5: MessageEnvelope enum bloat — 405 bytes per instance
**Impact:** HIGH — this is the primary wire type
**File:** types.rs, lines 989-1609

`FileHeader` variant has ~20 fields (~405 bytes). ALL 46 variants pay this cost. Even a tiny `SessionAck` or `Typing` is 405 bytes. This enum is deserialized on every incoming encrypted message.

**Solution:** Box the top 3-4 fat variants:
```rust
FileHeader(Box<FileHeaderPayload>),
ChannelMessage(Box<ChannelMessagePayload>),
DirectMessage(Box<DirectMessagePayload>),
ShardStore(Box<ShardStorePayload>),
```
Shrinks enum from ~405 bytes to ~136 bytes.

**Estimated gain:** ~60% memory reduction for envelope storage/transit. Faster moves and assignments.

---

### H6: HavenMessage Clone fan-out copies 200KB+ per peer
**Impact:** HIGH — fires on profile updates, gossip broadcasts
**File:** types.rs (67 variants with Clone), social.rs, gossip_relay.rs

`ProfileUpdate` with avatar+banner (200KB base64) is `.clone()`d for every peer in the broadcast loop. Each clone is immediately re-serialized to JSON by `send_message_to_peer`. 10 peers = 2MB of pointless copying + 10 redundant serializations.

**Solution:** Serialize the message once before the loop, send the same bytes/Arc to each peer:
```rust
let msg_bytes = serde_json::to_vec(&msg)?;
for peer in targets {
    send_raw_to_peer(ws_cmd_tx, ws_room_peers, peer, msg_bytes.clone());
}
```

**Estimated gain:** Eliminates O(N) deep clones of potentially large messages. Profile broadcast with 10 peers drops from ~2MB allocations to ~200KB.

---

### H7: Double erasure encoding in vault upload
**Impact:** HIGH — doubles CPU cost of every vault upload
**File:** vault_ops.rs, lines 232-344

`prepare_upload()` (Reed-Solomon encoding) is called twice for the same file. The entire UploadPlan — including all k+m shards — is computed, stored locally, dropped, then recomputed to distribute remote shards. For a 34MB file with k=3, m=2: ~70MB of shard buffers allocated twice, Reed-Solomon GF(2^8) computed twice (~340ms wasted).

**Solution:** Preserve the UploadPlan from the first call. Return it from the closure and reuse in the distribution phase.

**Estimated gain:** Halves CPU time and peak memory of every vault upload. Saves ~340ms + ~70MB per upload.

---

### H8: Unnecessary 34MB file_data.clone() in file handler
**Impact:** HIGH for large files
**File:** file_handler.rs, lines 131, 137, 162

Non-image files unconditionally clone the entire file buffer even though the original is never used again. A 34MB file → 68MB peak memory from the clone alone. Combined with AES encryption output, peak memory per file send reaches ~102MB when it could be ~68MB.

**Solution:** Use `std::mem::take(&mut file_data)` on pass-through paths instead of `.clone()`.

**Estimated gain:** ~34MB peak memory reduction per large file send.

---

## MEDIUM Impact

### M1: Sync batch inserts — no transaction wrapping
**File:** sync_handler.rs, lines 2383-2452

200 messages with reactions = 500+ individual autocommit SQL operations. SQLite is 10-50x faster with explicit transactions.

**Solution:** Wrap the entire batch in `BEGIN`/`COMMIT`.

**Estimated gain:** 10-50x faster sync batch ingest. Directly impacts "sync feels slow" perception.

---

### M2: Per-message get_file_metadata() — O(n) separate DB queries
**File:** sync_handler.rs, lines 1849-1863

Each message in a sync batch gets its own SQL query for file metadata. Reactions are correctly batched (single IN query), but file metadata is not.

**Solution:** Add `load_file_metadata_for_sync(file_ids: &[String])` batch method. Single `WHERE file_id IN (...)` query.

**Estimated gain:** Eliminates 50-100 individual SQLCipher queries per file-heavy sync batch.

---

### M3: compute_delta clones all matching CrdtOps before serializing
**File:** crdt/sync.rs, lines 46-57

All ops matching the delta are `.cloned()` into a Vec, then immediately serialized to JSON, then the Vec is dropped. Each CrdtOp contains multiple Strings.

**Solution:** Serialize directly from `Vec<&CrdtOp>` (serde handles references identically).

**Estimated gain:** Eliminates O(delta_size) clone allocations during sync.

---

### M4: CrdtStore batch flush not wrapped in single transaction
**File:** crdt_store.rs, lines 53-63

After batch-draining the mpsc channel, each `save_server_state` and `save_server_blob` is a separate autocommit transaction. 5 servers updating = 5 individual fsyncs.

**Solution:** Wrap entire flush in `BEGIN`/`COMMIT`.

**Estimated gain:** Coalesces N fsyncs into 1 per batch cycle.

---

### M5: verify_message_signature re-derives PeerId on every sync batch message
**File:** crypto_handler.rs, lines 39-77

500-message sync = 500 base64 decodes + 500 multihash constructions + 500 bs58 encodings, when typically only 3-5 unique senders exist.

**Solution:** Cache `(sender_peer_id, pk_b64) → verified` in a local HashMap during batch processing.

**Estimated gain:** ~99% reduction in PeerId derivation work during large sync batches.

---

### M6: No prepared statement caching
**File:** storage/messages.rs — all 43 query methods

Every query calls `self.conn.prepare()` which compiles the SQL from scratch. rusqlite provides `prepare_cached()` with an LRU statement cache.

**Solution:** Mechanical find-and-replace: `prepare(` → `prepare_cached(`.

**Estimated gain:** Eliminates SQL compilation overhead on repeated queries. Especially impactful under SQLCipher.

---

### M7: OR across columns defeats index in sync queries
**File:** storage/messages.rs, lines 909 and 1233

```sql
WHERE peer_id = ?1 AND (timestamp >= ?2 OR updated_at >= ?2)
```

SQLite can't use a single index for OR across different columns.

**Solution:** Rewrite as `UNION` so each branch uses its own index, or add a composite `sync_ts = MAX(timestamp, updated_at)` column.

**Estimated gain:** Sync probe queries go from partial/full scan to index-only lookups.

---

### M8: NOT IN subquery in get_missing_file_ids
**File:** storage/messages.rs, lines 3164-3174

Correlated subquery scans the `files` table for every candidate row.

**Solution:** Add index `idx_files_completed ON files (file_id, completed_at)` + rewrite as LEFT JOIN.

**Estimated gain:** O(n*m) → O(n+m) for missing file detection.

---

### M9: AES encryption + temp file write wasted when use_vault_only is true
**File:** file_handler.rs, lines 434-497

Channel path encrypts the file and writes a temp file even when `use_vault_only` is true (6+ member server, non-image). The ciphertext is never streamed — only the key/nonce from the header are needed.

**Solution:** Skip temp file write when `use_vault_only`. Consider an `aes_key_nonce_only()` API that returns key+nonce without allocating the full ciphertext buffer.

**Estimated gain:** Saves ~34MB allocation + ~34MB disk write + AES-GCM computation for large vault-only files.

---

### M10: Synchronous disk I/O on the async event loop
**Files:** file_handler.rs (lines 51, 735, 788), vault_ops.rs (lines 373, 606, 916)

`std::fs::read` and `std::fs::write` of files up to 34MB block the tokio runtime. On HDD or under disk pressure, this can stall all async tasks (WebSocket messages, keepalive pings).

**Solution:** Wrap heavy I/O (>1MB) in `tokio::task::spawn_blocking`.

**Estimated gain:** Eliminates latency spikes from disk I/O blocking the event loop. Prevents keepalive timeouts during file operations.

---

### M11: Duplicated PeerJoined / RoomMembers sync logic (~400 lines copy-pasted)
**File:** swarm.rs, lines 1260-1504 vs 1597-1821

Nearly identical logic for profile sending, Olm key exchange, CRDT sync, channel message sync, DM sync. In RoomMembers, this runs in a loop over all peers — so DB opens, StateVector computations, etc. multiply by peer count.

**Solution:** Extract `fn handle_new_peer_sync(...)` helper.

**Estimated gain:** DB opened once per RoomMembers event instead of once per peer. StateVector computed once per server instead of once per (peer × server).

---

### M12: StateVector computed per-peer instead of per-server
**File:** swarm.rs, lines 1390-1403, 1685-1695

In RoomMembers handler, StateVector is computed and serialized for each server for each peer. With 20 peers and 5 shared servers: 100 StateVectors when 5 would suffice.

**Solution:** Pre-compute StateVector JSON per server before the peer loop.

**Estimated gain:** 20x reduction in StateVector computations during room joins with many peers.

---

### M13: Shard data written to disk then immediately read back for WS streaming
**File:** vault_ops.rs, lines 369-382

Every remote shard is written to a temp file via synchronous `std::fs::write`, then `ws_stream_send` reads it back via `BufReader`. For 34MB file with k=3, m=2: ~47MB unnecessary disk round-trip.

**Solution:** Add `stream_to_peer_from_bytes()` that reads from `Cursor<&[u8]>` instead of file. Only write temp file for WebRTC fallback path.

**Estimated gain:** Eliminates ~47MB of write-then-read disk I/O per vault upload.

---

### M14: Double DB open in delete handlers
**File:** message_ops.rs, lines 523-549, 630-656

DB opened once to read current text for signing, dropped, then opened again to hide the message.

**Solution:** Open once, do both operations in the same scope.

**Estimated gain:** Eliminates one full SQLCipher cycle per delete.

---

### M15: envelope_json always serialized but unused on MLS success path
**File:** message_ops.rs, lines 184-220

Every channel message, edit, delete, reaction serializes the envelope to JSON before checking if MLS is available. On the MLS path (common case), this JSON string is never used. MLS re-serializes internally.

**Solution:** Lazily compute `envelope_json` only in the Olm fallback branch.

**Estimated gain:** Eliminates one redundant serde_json::to_string (500-2000 bytes) per channel message.

---

### M16: Double serialize + double save in handle_create_server
**File:** sync_handler.rs, lines 57-84

ServerState serialized to JSON twice and two `save_state` messages sent within the same function. First serialization is wasted because state immediately changes.

**Solution:** Apply both ops first, then serialize once.

**Estimated gain:** One fewer full ServerState serialization per server creation.

---

## LOW Impact

### L1: Gossip PeerExchange clones HavenMessage N times for N neighbors
**File:** gossip_relay.rs, lines 118-128. Fires every 120-240s.
**Fix:** Pre-serialize once, send bytes to each neighbor.

### L2: Broadcast relay clones 6 strings per relay target
**File:** gossip_relay.rs, lines 28-43. Only fires on actual broadcasts.
**Fix:** Use `Arc<str>` or pre-wrap shared strings.

### L3: composite() score recomputed redundantly in rotate_with_budget
**File:** gossip.rs, lines 286-349. Fires every 5 minutes.
**Fix:** Compute scores once into a HashMap.

### L4: add_known_peer allocates peer_id string up to 4 times
**File:** gossip.rs, lines 203-219. Only on PeerJoined events.
**Fix:** Take `String` by value, check existence before inserting.

### L5: Repeated local_peer_str.to_string() in same function
**File:** sync_handler.rs — most handlers. One small String per handler.
**Fix:** Hoist allocation or use `&str` comparisons.

### L6: peer_is_reachable scans all rooms linearly
**File:** crypto_handler.rs, lines 97-102.
**Fix:** Maintain reverse index `peer_id → room_code`.

### L7: Unused _topic String allocation on every channel message
**File:** ws_client.rs, lines 214-215.
**Fix:** Remove the allocation — just skip past the bytes.

### L8: sign() returns Vec<u8> instead of [u8; 64]
**File:** identity/native_identity.rs, lines 96-99.
**Fix:** Return `[u8; 64]`, callers convert if needed.

### L9: peer_id() allocates 3 intermediate Vecs per call
**File:** identity/native_identity.rs, lines 84-93. Amplified by C4.
**Fix:** Cache peer_id on the NativeKeypair struct.

### L10: Voice rate-limit map never evicts stale entries
**File:** voice_handler.rs, lines 640-661.
**Fix:** Evict entries older than 10 minutes during periodic cleanup.

### L11: format!("{}:{}", server_id, channel_id) repeated on every channel op
**File:** message_ops.rs. One small allocation per op.
**Fix:** Accept separate parameters in signing function.

### L12: Mention parsing scans all text even when no @ present
**File:** message_ops.rs, lines 224-231.
**Fix:** Early exit if `!text.contains('@')`.

### L13: count_unread_dm uses two separate queries for badge count
**File:** storage/messages.rs, lines 1347-1367.
**Fix:** Combine into single subquery.

### L14: reset_stale_file_paths — N+1 UPDATE without transaction
**File:** storage/messages.rs, lines 3211-3253.
**Fix:** Wrap in BEGIN/COMMIT.

### L15: edit_channel_message / edit_dm_message — 3 statements, no transaction
**File:** storage/messages.rs, lines 1988-2087.
**Fix:** Wrap in single transaction.

### L16: PendingShardAssembly uses Vec + sort instead of BTreeMap
**File:** types.rs, line 1658.
**Fix:** Use `BTreeMap<u32, Vec<u8>>`, eliminates sort and dedup set.

### L17: NodeCommand enum bloat from VaultUploadFile (~224 bytes)
**File:** types.rs, lines 263-443.
**Fix:** Box the fat variants.

### L18: NetworkEvent enum size disparity (224 bytes for all 70+ variants)
**File:** types.rs, lines 44-241.
**Fix:** Box the top 4 largest variants.

### L19: Temp files not cleaned up on WS relay streaming path
**File:** file_handler.rs, lines 467-471.
**Fix:** Delete temp file after WS stream completes.

### L20: to_ffi_event() double-matches every NetworkEvent (log + convert)
**File:** api/network.rs, lines 364-858.
**Fix:** Merge logging into conversion match.

---

## Recommended Implementation Order

### Phase 1: Foundation (biggest systemic wins) — DONE
1. **C1 + C2: MessageStore singleton for node modules** — Pre-computed passphrase, eliminated ~100 redundant derivations. DONE.
2. **C3: WAL mode + PRAGMAs** — WAL + NORMAL sync + 8MB cache + memory temp. DONE.
3. **H4: Share tick 50ms → 1000ms** — Kept 50ms but added early-return when registry empty. DONE.
4. **M6: prepare() → prepare_cached()** — 48 statements cached across messages.rs + content_store.rs. DONE.
5. **C2: FTS one-time rebuild** — Was rebuilding on every open(), now migration-flagged. DONE.

### Phase 2: Crypto persistence (constant CPU drain) — DONE
5. **H1: Debounce persist_mls_state** — 2s dirty-flag timer, epoch-change ops still immediate. DONE.
6. **H2: Split Olm persist** — persist_olm_session (ratchet only) for per-message, full persist on session lifecycle. DONE.

### Phase 3: Serialization reduction — DONE
7. **H3: Skip op_log in ServerState serialization** — `#[serde(skip_serializing)]` + restore_op_log from DB at startup. DONE.
8. **H5: Box fat enum variants** — `#[serde(flatten)] inner: Box<XxxPayload>` for DirectMessage, ChannelMessage, FileHeader, ShardStore. ~405→~136 bytes per enum instance. 21 sites updated. DONE.
9. **M15: Lazy envelope_json** — Moved into Olm-only branches, skipped on MLS success path. DONE.

### Phase 4: Sync performance
10. **M1: Transaction-wrap sync batch inserts** — 10-50x faster batch ingest.
11. **M5: Cache PeerId derivation in sync batches** — 99% less work.
12. **M2: Batch file metadata query** — Single IN query instead of per-message.
13. **M3: compute_delta without cloning** — Serialize from references.
14. **M4: CrdtStore flush in single transaction** — Coalesce fsyncs.

### Phase 5: FFI optimization
15. **C4: Batch FFI get_server_info()** — 7x fewer DB opens per server switch.
16. **L9: Cache peer_id on NativeKeypair** — Eliminate cascading allocs.

### Phase 6: Memory optimization
17. **H6: Serialize-once broadcast pattern** — Eliminate clone amplification.
18. **H7: Fix double erasure encoding** — Halve vault upload cost.
19. **H8: std::mem::take instead of file_data.clone()** — 34MB savings per send.
20. **M9: Skip AES + temp file when vault_only** — 34MB wasted work.

### Phase 7: I/O optimization
21. **M10: spawn_blocking for heavy disk I/O** — Prevent event loop stalls.
22. **M13: In-memory shard streaming** — Eliminate disk round-trip.
23. **M11 + M12: Deduplicate PeerJoined/RoomMembers** — DB + StateVector once.

### Phase 8: Polish (LOW items + deferred fixes)
24-43. All LOW items — individually small but collectively meaningful.
44. **Proactive Olm re-key on stale peers** — If PeerJoined key exchange is lost, neither side retries. Add periodic re-key probe for peers in shared rooms with no active session.
45. **Stale share cleanup** — Old share entries persist in SQLCipher across builds. Prune on startup where source file no longer exists on disk, or add manual "clear stale shares" action.

---

## Expected Overall Impact

### CPU
- Phases 1-2 alone should dramatically reduce steady-state CPU from crypto persistence + DB connection churn
- Phase 3 prevents CPU degradation as servers age (op_log growth)
- Phase 4 makes sync operations 10-50x faster

### RAM
- Enum boxing (H5) reduces per-message memory by ~60%
- File handling fixes (H7, H8, M9) reduce peak memory by 34-70MB per operation
- Clone elimination (H6) prevents multi-MB transient spikes

### Responsiveness
- C4 directly fixes "weird reloading" on server switch (7x fewer FFI round-trips)
- M1 makes sync batch ingest 10-50x faster (faster "catch-up" after reconnection)
- C1-C3 make every DB operation faster (affects everything)

### Idle baseline
- H4 (share tick fix) reduces idle wakeups from 20/sec to 1/sec
- Crypto debouncing (H1, H2) eliminates constant serialization during active chat
