# Authorisation matrix evidence: FILES, VAULT SHARDS, SHARE, RECOVERY POOL, ASSET RAIL

Scope: items 1-7 of the task. Read-only; no builds, no cargo.

## Read me first (how to re-check these citations)

- The tree was being edited by another session WHILE this was gathered
  (`git status`: `swarm.rs`, `types.rs`, `fetch.rs`, `crypto_handler.rs`,
  `olm_manager.rs`, `test_harness.rs` modified, uncommitted; the diff is the
  HOL-SEC-003 PreKey identity-proof fix). Every `swarm.rs`, `types.rs`,
  `fetch.rs`, `crypto_handler.rs` line number below was re-taken with
  `grep -n -F <quoted text>` against the WORKING TREE at the end of the pass.
  Relative to HEAD: `swarm.rs` is +1 between lines 571..6680 and +9 after 6712;
  `types.rs` is +9 after 1413. `file_handler.rs`, `vault_ops.rs`,
  `share_handler.rs`, `emotes.rs`, `file_asks.rs`, `ws_stream_transfer.rs`,
  `recovery_pool.rs`, `vault/*`, `storage/messages.rs`, `crdt/server_state.rs`
  were unmodified, so HEAD == working tree for them.
- Paths are relative to `rust/hollow_core/src/` unless they start with
  `relay-uws/` or `lib/`.
- Principal shorthands used throughout:
  - **OLM-PEER** = `peer_str`, the relay-stamped sender DEVICE id, "authenticated"
    only by the fact that an Olm session keyed on that id decrypted the frame
    (`node/swarm.rs:6683` `HavenMessage::Encrypted { message_type, body, identity_key, identity_sig, identity_pk } => {`).
    On HEAD a PreKey could be built on any identity key, so the relay could open a
    session in any device's name (the working-tree fix is
    `node/swarm.rs:6714` `if !crypto_handler::verify_olm_identity(`). Who else may
    hold an Olm session with Alice (friends, co-members, strangers in a shared
    room) is the key-exchange agent's area and is NOT established here.
  - **MLS-LEAF** = `sender_peer_id`, the MLS leaf credential (a DEVICE id) returned by
    `node/swarm.rs:10964` `match mls_mgr.decrypt_fresh(&group_key, &ciphertext) {`;
    the group is chosen from the PLAINTEXT outer `server_id`
    (`node/swarm.rs:10893` `HavenMessage::MlsChannelMessage { server_id, body, channel_id: msg_channel_id } => {`).
  - **ROOM-PEER** = relay-stamped `from` on a plaintext `HavenMessage` or binary
    frame. An honest relay only forwards when sender AND target are in the named
    room (`relay-uws/src/ws_handler.cpp:1622`
    `if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;`,
    `:1628-1629` `auto tit = rit->second.peers.find(target_str); if (tit == rit->second.peers.end()) return;`).
    P-01 can forge any `from`.
- The plaintext dispatcher applies ONE generic gate before everything in this
  report: a per-`from` token bucket (`node/swarm.rs:4577` `let rate_ok = {`,
  `node/swarm.rs:1168-1169` `const RATE_LIMIT_BURST: u32 = 100;` /
  `const RATE_LIMIT_REFILL: u32 = 20; // tokens per second`). Binary frames
  (`WsEvent::BinaryDirect`) do NOT go through it (`node/swarm.rs:4386`).

---

## 1. File announce and bytes

### A-F1 MessageEnvelope::FileHeader (registers file metadata, a decrypt key/pending stream, may write inline bytes)

- Dispatch sites:
  - Olm arm: `node/swarm.rs:8241` `Ok(MessageEnvelope::FileHeader { inner }) => {` (inside the Olm envelope match at `node/swarm.rs:6978`).
  - MLS arm: `node/swarm.rs:11044` `MessageEnvelope::FileHeader { inner } => {` -> `file_handler::handle_envelope_file_header` (`node/file_handler.rs:2758`).
  - fetch.rs (push background node, DM-room buffered frames only): `node/fetch.rs:753` `Ok(MessageEnvelope::FileHeader { inner }) => {` -> `handle_file_header` (`node/fetch.rs:1116`).
  - Plaintext `PublicFileHeader` reuses the MLS handler (see A-F5).
  - Sync backfill writes the same `files` rows through `SyncFileMetaItem` (not a FileHeader, same table, same guard): `node/swarm.rs:7218`, `:7614`, `:7856`, `node/sync_handler.rs:3623` (see SUSPICION F1-5).
  - No relay 0x07 / gossip / WebRTC path for this envelope found.
- Handler: inline block (Olm), `handle_envelope_file_header` (MLS), `handle_file_header` (fetch).
- Target object: `fid` (file id, any string), `mid`, `sid`/`cid` (conversation it is filed under), `ext`/`name`/`mime`/`size`, `aes_key`/`aes_nonce`, `share_ref`, `inline_bytes`.
- State changes, Olm arm, in order:
  1. `node/swarm.rs:8252` `let explicitly_requested = requested_file_receipts` `.remove(&fid)` (consumes Alice's explicit-pull receipt for `fid`).
  2. `node/swarm.rs:8257` `declined_file_ids.remove(&fid);` (when a receipt was consumed).
  3. `node/swarm.rs:8260` `file_asks::retire(pending_file_asks, &fid);` (drops Alice's pending file ask).
  4. `node/swarm.rs:8336` `let _ = store.insert_file_metadata(` (behind the owner guard at `:8335`). UPSERT that overwrites name/ext/mime/size/chunk_count/dims but NOT context/sender: `storage/messages.rs:5185-5193` `ON CONFLICT(file_id) DO UPDATE SET file_name = excluded.file_name, file_ext = excluded.file_ext, ...`.
  5. `node/swarm.rs:8348` `let _ = store.set_file_share_ref(&fid, sr);` (inside the guard).
  6. If the file is already complete on disk: `pending_file_streams.remove(&fid)` / early-arrival temp deleted (`node/swarm.rs:8365` `let already_complete = {` and following).
  7. Inline bytes (`inline_bytes` + key + nonce, not complete, no share_ref): DM sentinel message row `store.insert(` guarded by `sentinel_sig_ok` (`node/swarm.rs:8442` `let sentinel_sig_ok = from_sibling || {`), then the DECRYPTED bytes are written `node/swarm.rs:8490` `if crate::node::at_rest::write_all(&disk_path, &plaintext).is_ok() {` and `node/swarm.rs:8493` `let _ = store.mark_file_complete(&fid, &disk_str);` + `FileCompleted` event. Only guarded by `auto_ok` (`:8471` `if !auto_ok {`) and the FILE-1 shape check (`:8477` `} else if !file_transfer::is_wire_file_id(&fid)`). NOT guarded by the owner guard.
  8. Auto-download decline: `declined_file_ids.insert`, `FileFailed{auto_download_off}` (`node/swarm.rs:8511` `if !already_complete && !inline_done && !auto_ok`).
  9. Pending decrypt key: `node/swarm.rs:8530` `if !already_complete && !inline_done && auto_ok && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {` -> `node/swarm.rs:8539` `pending_file_streams.insert(fid.clone(), PendingFileStream {` (overwrites any existing registration for `fid`, keeps only `retry_count`, `:8551`). NOT guarded by the owner guard.
  10. Early arrival processed immediately: `node/swarm.rs:8556` `if let Some((temp_path, file_size, sender)) = early_file_streams.remove(&fid) {` -> `file_handler::handle_completed_stream(` (`:8567`) which decrypts and WRITES the final file (A-F7).
  11. `NetworkEvent::FileHeaderReceived` with `sender_id: peer_str.to_string()` (`node/swarm.rs:8587`) and the header's own `share_ref`, emitted even when the owner guard refused step 4.
- State changes, MLS arm (`node/file_handler.rs`): receipt consumed `:2797-2803`; metadata `:2831` `if file_meta_write_allowed(&store, &fid, &sender_peer_id) {` -> `:2832` insert, `:2843` share ref; decline `:2855-2866`; pending key `:2871` `register_pending_file_stream_and_reprocess(` -> `:2981` `pending_file_streams.insert(fid.to_string(), PendingFileStream {` + early-arrival processing `:2998`; event `:2880` with `sender_id: sender_peer_id,` (`:2888`) and `server_id: sid.unwrap_or_else(|| server_id.to_string()),` (`:2889`). There is NO `already_complete` check and NO `file_asks::retire` in this arm.
- State changes, fetch arm (`node/fetch.rs:1116-1302`): inline bytes decrypted and written FIRST: `:1167` `if crate::node::at_rest::write_all(&disk_path, &plaintext).is_ok() {`; then `persist_inline_image` inserts the sentinel DM row only if `sentinel_sig_ok` (`:1269-1273`), metadata only behind `:1287` `if crate::node::file_handler::file_meta_write_allowed(&store, &p.fid, convo) {`, and then UNCONDITIONALLY `:1299` `let _ = store.mark_file_complete(&p.fid, disk_str);`.
- Checks before the FIRST state change: NONE (Olm steps 1-3 run before any check; MLS receipt removal `node/file_handler.rs:2797` runs first). Later checks, Olm arm:
  - Size cap, skipped for share-backed or explicitly requested: `node/swarm.rs:8265` `if share_ref.is_none() && !explicitly_requested {` / `:8279` `if size > max_bytes {` (no principal).
  - Mute: `node/swarm.rs:8293` `if state.is_muted(&peer_str, now_ms) {` (resolved MASTER of OLM-PEER via `crdt/server_state.rs:1445` `let key = super::resolve_identity(peer_id);`), only when `sid` names a known server.
  - Media-only channel: `node/swarm.rs:8298` `if state.is_channel_media_only(c) {` (no principal).
  - DM block guard: `node/swarm.rs:8317` `&& super::blocklist::is_blocked(&peer_str)` (MASTER via `node/blocklist.rs:42`), DM only.
  - Owner guard (metadata write only): `node/swarm.rs:8335` `if file_handler::file_meta_write_allowed(&store, &fid, &peer_str) {` -> `node/file_handler.rs:206` `let Ok(Some(existing)) = store.get_file_metadata(file_id) else {` `return true;`, `:209` `let owner = super::resolver::resolve(&existing.sender_id);`, `:210` `if owner == super::resolver::resolve(incoming_sender) {` (MASTER of OLM-PEER vs stored sender's MASTER).
  - MLS arm: cap `node/file_handler.rs:2807` (outer `server_id`), mute `:2935` `if state.is_muted(sender_peer_id, now_ms) {` on the OUTER `server_id`'s state (`:2930`), media-only on the PAYLOAD `cid` against the OUTER server's channels (`:2939-2940`), owner guard `:2831`.
  - fetch arm: blocklist on the DM sender (`node/fetch.rs:712`), own-sibling skip (`:700`), auto-download gate (`:1127`), shape check (`:1155`), then write.
  - NOT checked on any arm: that OLM-PEER / MLS-LEAF is a member of the payload `sid`, can see or post in `cid`, or is the author of the message `mid` the header names.
- Who can sign: unsigned (authority = transport sender: OLM-PEER, MLS-LEAF, or the Olm DM sender in fetch). The optional `sig`/`pk` is the companion MESSAGE signature, checked only to insert the inline-image sentinel DM row (`node/swarm.rs:8442`, `node/fetch.rs:1269`).
- Binding: between sender and `fid`, only `file_meta_write_allowed` for the metadata row (`node/file_handler.rs:210`). Between sender and the decrypt key / bytes written for `fid`: NONE FOUND. Between sender and the payload `sid`/`cid`: NONE FOUND. Between MLS outer `server_id` and payload `sid`: NONE FOUND.
- Transport parity:
  - Olm skips a complete file (`node/swarm.rs:8365`); MLS does not (no such check in `node/file_handler.rs:2758-2895`); fetch does not (`node/fetch.rs:1148-1167` write happens with no completeness check).
  - Olm retires the pending ask (`node/swarm.rs:8260`); MLS does not.
  - fetch writes bytes and marks complete outside the owner guard (`node/fetch.rs:1167`, `:1299`); Olm writes inline bytes outside it too (`node/swarm.rs:8490-8493`).
  - Mute/cap: Olm uses payload `sid`; MLS uses the outer `server_id` for mute/cap but payload `sid`/`cid` for the stored context (`node/file_handler.rs:2819-2822` `let ctx_id = match (&sid, &cid) {`).
- Freshness / replay: none at application level (no ts window, no dedup by header). Olm/MLS ratchet replay protection not examined. Receipts expire after 300 s (`node/swarm.rs:8254`). NONE FOUND beyond that.
- Absent fields: `sid` absent = DM filed under OLM-PEER's MASTER (`node/swarm.rs:8325` `let dm_convo = super::resolver::resolve(&peer_str);`). `aes_key`/`aes_nonce` absent = no pending stream, metadata only. `share_ref` present = size cap skipped (`:8265`) and no stream registered. `target` (MLS) absent = processed by everyone (`node/swarm.rs:10983` `if let Some(target) = envelope.target() {`).
- Blast radius: local to Alice's disk and DB; overwritten file bytes are served onward by Alice's `FileRequest` responder (A-F3) to other entitled peers, so a substituted file propagates. `insert_file_metadata` is reversible only by the owner re-sending.
- Tests: none found for a rejected header (owner guard, foreign `fid`, foreign `sid`). `file_transfer.rs` `final_file_path_stays_inside_files_dir` (path shape only); `file_handler.rs` `voice_exemption_requires_flag_name_ext_and_size` (gate only).
- SUSPICION F1-1 (CONFIRMED-BY-READING): **foreign-file byte substitution through the pending-key registration.** The owner guard covers only the metadata row; the decrypt key registration (`node/swarm.rs:8539`, `node/file_handler.rs:2981`) and the stream write that follows (`node/file_handler.rs:2384` `let final_path = file_transfer::final_file_path(&request.id, &pfs.ext);`, `:2386` write, `:2395` `let _ = store.mark_file_complete(&request.id, &disk_path);`) accept any sender. Mallory (server co-member, MLS arm) who has seen Bob's channel attachment id sends an MLS FileHeader `{fid: Bob's fid, ext: same, small size, aes_key: hers}` and then streams her own ciphertext with id = fid (A-F7). Alice's disk now holds Mallory's bytes under Bob's card; the MLS arm has no completeness check, so even an already-downloaded file is replaced (`node/at_rest.rs:393` `std::fs::rename(&tmp, path)` replaces the target). Olm arm: same for any not-yet-complete file (every card still showing a Download button).
- SUSPICION F1-2 (CONFIRMED-BY-READING): **inline-bytes substitution with no stream at all.** Olm arm writes `inline_bytes` decrypted under the header's own key to `final_file_path(fid, ext)` and marks complete (`node/swarm.rs:8490`, `:8493`) with no owner guard; fetch arm does the same with no completeness check (`node/fetch.rs:1167`, `:1299`). Mallory (Olm peer of Alice, e.g. a friend or a relay on HEAD per HOL-SEC-003) sends one Olm FileHeader naming Bob's `fid`; on mobile the push-fetch node overwrites even a completed file.
- SUSPICION F1-3 (CONFIRMED-BY-READING): **state change before check.** `requested_file_receipts.remove`, `declined_file_ids.remove`, `file_asks::retire` (`node/swarm.rs:8252-8260`) run before any gate and for any sender. Mallory answering first for a `fid` Alice asked for consumes the receipt (bypassing the size cap and auto-download gate for HER header) and kills Alice's ask; the honest answer then faces the gate as an unsolicited push.
- SUSPICION F1-4 (CONFIRMED-BY-READING): **no membership binding for the announced conversation.** Olm arm files the header under payload `sid:cid` (`node/swarm.rs:8325-8330`) with no `is_member`/`can_post` check on OLM-PEER; MLS arm files under payload `sid:cid` while every check uses the outer `server_id` (`node/file_handler.rs:2807`, `:2813`, `:2819`). A member muted in server A sends through group B naming `sid: A` and the mute check reads B's state. Impact is bounded by F1-1 (the card only renders where a message row references the fid).
- SUSPICION F1-5 (CONFIRMED-BY-READING): **owner guard is bypassable on the sync path.** Sync file_meta passes the SENDER-CONTROLLED claimed owner into the guard: `node/sync_handler.rs:3623` `.filter(|fm| super::file_handler::file_meta_write_allowed(store, &fm.fid, &fm.sender))`, same at `node/swarm.rs:7218`, `:7614`, `:7856`; `fm.sender` is a plain wire field (`node/types.rs:4016` `pub sender: String,`). A sync responder (any member answering Alice's channel sync) sets `fm.sender` = Bob's master and relabels Bob's card (name/ext/mime/size/dims, `storage/messages.rs:5185-5193`). The guard's own doc comment claims it stops exactly this.
- SUSPICION F1-6 (PLAUSIBLE, Dart side only partly read): `FileHeaderReceived` is emitted with the attacker's `share_ref`, `mid`, `sid`, `cid` even when the owner guard refused the metadata write (`node/swarm.rs:8579-8593`, `node/file_handler.rs:2880-2894`). Dart attaches it to the named message and auto-starts a share download bridged to that `fileId`: `lib/src/core/providers/event_provider.dart:1180-1200` (`attachFileMeta(serverId, channelId, messageId, ...)`), `:1203` `if (shareRootHash != null && shareKeyHex != null) {`, `:1225` `share_api.shareStartFromRef(`. Mallory re-points Bob's attachment on Alice's screen at a share Mallory seeds.

### A-F2 MessageEnvelope::FileChunk (writes a chunk file; assembles and marks the file complete)

- Dispatch sites: Olm `node/swarm.rs:8595` `Ok(MessageEnvelope::FileChunk { fid, idx, data }) => {`; MLS `node/swarm.rs:11058` `MessageEnvelope::FileChunk { fid, idx, data } => {` -> `node/file_handler.rs:3023` `handle_envelope_file_chunk`. Not in fetch.rs. No sender constructs this variant anywhere in `src/` (grep `FileChunk` finds only the type, the two receive arms and the handler doc), so it is a receive-only legacy path.
- Handler: inline (Olm), `handle_envelope_file_chunk` + `ingest_file_chunk_progress` + `assemble_completed_chunked_file` (MLS).
- Target object: `fid`, chunk index `idx`.
- State changes: `node/swarm.rs:8603` `if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {` (writes `files/{sanitized fid}.chunk.{idx}`, `node/file_transfer.rs:25-29`, `:65-68`); `node/swarm.rs:8608` `if let Ok(received) = store.mark_chunk_received(&fid, idx) {` (`storage/messages.rs:5245` `INSERT OR IGNORE INTO file_chunks`, `:5256` `UPDATE files SET chunks_received = chunks_received + 1`); when `received >= file_meta.chunk_count`: `node/swarm.rs:8618` `match file_transfer::assemble_file(&fid, file_meta.chunk_count, &final_path) {` (overwrites `files/{fid}.{stored ext}`, `node/file_transfer.rs:48`) and `node/swarm.rs:8621` `let _ = store.mark_file_complete(&fid, &disk_path);` + `FileCompleted`. MLS twin: `node/file_handler.rs:3040`, `:3058`, `:3066`, `:3087`, `:3090`.
- Checks before the first state change: NONE. No sender, membership, owner, pending-transfer, completeness, size or count check; the chunk is written as plaintext (no decryption).
- Who can sign: unsigned (authority = OLM-PEER or MLS-LEAF).
- Binding: NONE FOUND.
- Transport parity: identical (both unguarded).
- Freshness / replay: NONE FOUND.
- Absent fields: none.
- Blast radius: local; the replaced file is re-served to others by the FileRequest responder.
- Tests: none found.
- SUSPICION F2-1 (CONFIRMED-BY-READING): **any Olm peer or group member destroys or replaces any file whose id it knows, completed or not.** Legitimate senders put `chunks: 0` in their headers (`node/file_handler.rs:1031`, `:1626`), and the sync path stores 0 too (`node/sync_handler.rs:3629` `fm.size, 0, fm.img, fm.w, fm.h,`), so a normally received row has `chunk_count = 0`. ONE FileChunk for Bob's `fid` then makes `received >= file_meta.chunk_count` true (`node/swarm.rs:8616` `if received >= file_meta.chunk_count {`, `node/file_handler.rs:3066`), `assemble_file(fid, 0, ..)` reads nothing and writes an EMPTY file over `files/{fid}.{ext}` (`node/file_transfer.rs:41-48`) and the row is marked complete. For a row with `chunk_count = n > 0`, Mallory sends all n chunks and the file becomes her raw plaintext. The stream path never inserts `file_chunks` rows (`node/file_handler.rs:2366-2399`), so the counter starts from zero.
- SUSPICION F2-2 (CONFIRMED-BY-READING): **disk exhaustion.** For an unknown `fid` the chunk file is still written (`node/swarm.rs:8603`) before `mark_chunk_received` fails on the missing `files` row; `idx` is any u32, `data` any size. Nothing deletes these orphans (the boot sweep only matches `.stream_send_`/`.stream_shard_`, `node/swarm.rs:722`).

---

## 2. File request family

### A-F3 HavenMessage::FileRequest (serving gate: we send a decrypt key and the bytes)

- Dispatch sites: plaintext only, `node/swarm.rs:13579` `HavenMessage::FileRequest { file_id, chunks, offset } => {`. Not intercepted earlier, not in fetch.rs.
- Handler: inline in `handle_incoming_request`.
- Target object: `file_id` (our row), `offset`.
- State changes: none before the gate; after it: a fresh AES key per request, temp `files/.stream_send_{file_id}_{nonce}.tmp` (`node/swarm.rs:13663-13672`), Olm `FileHeader` (member) or plaintext `PublicFileHeader` with the AES key (`node/swarm.rs:13732`), then `stream_to_peer` / `ws_stream_send` from `offset` (`node/swarm.rs:13751` `if offset > 0 {`), or `FileUnavailable` (`:13655`).
- Checks, in order: `node/swarm.rs:13593` `if crate::node::blocklist::is_blocked(peer_str) {` (ROOM-PEER's MASTER); `:13597` `let requester_master = super::resolver::resolve(peer_str);`; DM: `:13601` `|| super::resolver::same_identity(peer_str, &file_meta.context_id),` (or own sibling, `:13600`); channel: `:13614` `s.is_member(&requester_master)` `&& crate::node::crypto_handler::channel_readable_by(` (`node/crypto_handler.rs:2124-2125` `(state.is_member(&master) || state.is_channel_public(channel_id)) && state.can_see_channel(&master, channel_id)`), or public `:13618` `s.is_channel_public(cid),`; unknown server `:13622` `None => (false, false),`; reject `:13629` `if !requester_is_member && !public_ok {`. Principal: ROOM-PEER resolved to MASTER.
- Who can sign: unsigned (authority = relay `from`).
- Binding: `context_id` of OUR row to the requester (`:13601`, `:13614`). The row's context was set by whoever FIRST inserted it (A-F1, F1-4), not re-validated here.
- Transport parity: single site.
- Freshness / replay: NONE FOUND (a relay can replay; the answer is Olm-encrypted to the claimed device for members, plaintext for public).
- Absent fields: `chunks`, `offset` default empty/0.
- Blast radius: disclosure of file bytes (encrypted to the requester device for members).
- Tests (rejection): `file_request_gate_refuses_stranger_and_serves_guest_public`, `file_unavailable_never_answers_a_non_entitled_requester`, `restricted_channel_history_and_files_never_reach_a_non_qualifier`.
- SUSPICION F3-1 (PLAUSIBLE): **work amplification.** Every accepted request re-reads and re-encrypts the whole file and streams it (`node/swarm.rs:13640-13663`), with no per-file or per-peer dedup beyond the 20/s token bucket. A guest (or relay spoofing guests) on a public channel repeats FileRequest for the largest public file.
- SUSPICION F3-2 (PLAUSIBLE): FileRequest and its `file_id` are plaintext, so the relay learns which file ids each device pulls; combined with A-F5 it can answer first for guests.

### A-F4 HavenMessage::FileUnavailable (rotates Alice's ask; can mark a file expired)

- Dispatch sites: plaintext `node/swarm.rs:13788` `HavenMessage::FileUnavailable { file_id, reason } => {` -> `node/file_asks.rs:447` `handle_file_unavailable`.
- Target object: `file_id`, `reason`.
- State changes: `ask.negatives.push`, `ask.in_flight = None` (`node/file_asks.rs:472-473`); for `expired` AND locally verified: `node/file_asks.rs:490` `let _ = cs.mark_file_expired(&file_id, now_secs);`, ask removed, `FileAvailability{expired}`; else `advance` (next FileRequest).
- Checks before first state change: `node/file_asks.rs:464` `let Some(ask) = pending.get_mut(&file_id) else {`; `:467` `if !ask.asked.contains(peer_str) {` (ROOM-PEER device must be the one we asked); expiry `:477` `&& retention_expired_locally(&file_id, server_states, db_path, db_passphrase)` (our own row + our own settings, `:406-440`).
- Who can sign: unsigned (authority = relay `from`).
- Binding: `ask.asked.contains(peer_str)` (`:467`).
- Transport parity: single site.
- Freshness / replay: `asked` is per connection (`node/file_asks.rs:724` in `reset_on_disconnect`). A relay can forge `from` = the asked device.
- Absent fields: `reason` absent = "gone" (`:471`).
- Blast radius: local; `mark_file_expired` only when our own retention says so.
- Tests (rejection): `file_unavailable_from_unasked_device_changes_nothing`.
- SUSPICION: none beyond P-01 steering the walk (relay forges `from` = asked device to rotate every ask to a dead end). PLAUSIBLE, low.

### A-F5 HavenMessage::PublicFileHeader (guest: registers a decrypt key and metadata)

- Dispatch sites: plaintext `node/swarm.rs:13296` `HavenMessage::PublicFileHeader {`.
- Handler: gate inline, then `file_handler::handle_envelope_file_header` (the MLS handler, A-F1) with `sender_peer_id = peer_str`.
- Target object: `file_id`, `sid`, `cid`, `mid`, key/nonce.
- State changes: receipt removed `node/swarm.rs:13303` `let Some((req_sid, req_at)) = pending_public_file_requests.remove(&file_id) else {`; then everything in A-F1 MLS arm (metadata, pending key, early-arrival processing, event).
- Checks: `:13303` a receipt for `file_id` exists; `:13307` `if req_sid != sid` / `|| !guest_rooms.contains(&sid)` / `:13309` `|| req_at.elapsed() > std::time::Duration::from_secs(120)`. Principal: NONE (the receipt records `(server_id, time)` only: `node/swarm.rs:2537` `pending_public_file_requests.insert(` with `(server_id.clone(), std::time::Instant::now())`, although the request went to ONE chosen peer `t`, `:2548`).
- Also inserted at request time: `node/swarm.rs:2544` `requested_file_receipts.insert(file_id.clone(), std::time::Instant::now());`, so the answering header bypasses the size cap and auto-download gate (`node/file_handler.rs:2805-2807`, `:2852-2854`).
- Who can sign: unsigned (authority = relay `from`).
- Binding: between the answering sender and the peer we asked: NONE FOUND.
- Transport parity: single site.
- Freshness / replay: 120 s receipt, consumed once.
- Absent fields: `w`/`h`/`mid` optional.
- Blast radius: local to the guest.
- Tests: none found for a rejected PublicFileHeader.
- SUSPICION F5-1 (CONFIRMED-BY-READING): **any room peer, or the relay, answers a guest's public-file request first and supplies the file.** The FileRequest is plaintext, so P-01 sees `file_id`, forges a PublicFileHeader with any `from`, its own key, and then streams its own ciphertext (A-F7). The guest stores Mallory's bytes, name and ext (guests hold no row, so the owner guard's "no row" branch passes, `node/file_handler.rs:206-207`), with no size cap.

### A-F6 HavenMessage::FileProbe / FileProbeResponse

- Dispatch sites: sender only (`node/gossip_relay.rs:168` `HavenMessage::FileProbe { file_id: file_id.clone() },`). No receive arm; both fall to `node/swarm.rs:14175` `_ => {}`. Not in fetch.rs.
- State changes: none. Checks: n/a. Binding: n/a. Tests: n/a.
- SUSPICION: none (dead on receive).

---

## 3. Byte lanes

### A-F7 WS binary stream lane (`WsEvent::BinaryDirect` -> `ws_stream_receive` -> `handle_completed_stream`)

- Dispatch sites: `node/swarm.rs:4386` `WsEvent::BinaryDirect { room: _, from, data } => {` (room ignored, no rate limit, no sender check).
- Handler: `node/ws_stream_transfer.rs:300` `ws_stream_receive`; completion `node/file_handler.rs:2214` `handle_completed_stream` -> File `:2323`, Shard `:2455`, LinkSnapshot `:2261`, ShareChunk dropped `:2233`.
- Target object: the 64-byte `id` in the frame (file id, content id, link id, share root), kind byte, declared `total_size`, shard index / chunk index.
- `parse_id`: `node/ws_stream_transfer.rs:475-483`, allowlist `:478` `let allowed = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b':' | b'_' | b'-');` (no `.`, no separators). Temp name `:387` `let temp_path = files_dir().join(format!(".ws_recv_{id}.tmp"));`.
- Matching to a pending transfer: receive-side state is keyed by `id` ALONE: continuation `:321` `let state = pending.get_mut(&id)?;` then `:322` write; a first frame for an existing id is treated as a resume and APPENDS (`:370` `if let Some(state) = pending.get_mut(&id) {`). No sender is stored in `WsTransferState` (`node/ws_stream_transfer.rs:79-87`).
- Unsolicited streams: a first frame for an unknown id creates the temp file and entry with the sender-declared size (`:346`, `:388`, `:425-427`). Nothing requires a prior FileHeader/ShardStore. Temp entries are only dropped on disconnect (`node/swarm.rs:3277` `for (id, state) in pending_ws_transfers.drain() {`).
- Completion:
  - Declined ids deleted: `node/swarm.rs:4393` `if declined_file_ids.contains(&completed.id) {`.
  - File: `node/file_handler.rs:2337` `let Some(pfs) = pending_file_streams.remove(&file_id) else {` (keyed by id only; `pfs.sender` is never compared to `sender_peer`); unknown id -> `:2340` `early_file_streams.insert(file_id, (request.temp_path.clone(), request.size, sender_peer.to_string()));` (5-minute cleanup, `node/swarm.rs:5250-5268`); decrypt with the registered key `:2347`, write `:2384-2386`, `:2395` mark complete. Decrypt failure -> bytes parked as early arrival and a bounded re-request to `pfs.sender` (`:2424`, `:2431`).
  - Shard: `node/file_handler.rs:2469` `let Some(pss) = pending_shard_streams.remove(&key) else {` (key `{content_id}:{si}`, no sender); per-shard hash check only when `:2480` `if pss.k > 0 || pss.m > 0 {`; store `:2498` `let _ = content_store.store_shard(`; may trigger reconstruction `:2510`.
  - LinkSnapshot: `node/file_handler.rs:2275` `let Some(state) = pending_link_snapshots.remove(&link_id) else {` (no sender binding) -> `:2290` `crate::api::storage::stash_pending_link(&blob, &state.code)` + ack to `sender_peer`. Registered at `node/link_handler.rs:208`.
  - ShareChunk: `node/file_handler.rs:2233` `if matches!(request.kind, StreamKind::ShareChunk { .. }) { return; }` (temp file NOT deleted).
- Checks before the first state change: `parse_id` shape only (`:315`, `:342`). Principal: nothing.
- Who can sign: unsigned (authority = ROOM-PEER, and the AES-GCM key registered by the header for File).
- Binding: NONE FOUND between the stream sender and the pending transfer, the header sender, or the in-progress stream of another sender.
- Transport parity: see A-F8 (WebRTC lane has the same completion functions).
- Freshness / replay: NONE FOUND.
- Absent fields: n/a.
- Blast radius: local disk; substituted files propagate via FileRequest.
- Tests (rejection): `ws_stream_transfer.rs` `test_parse_id_rejects_path_characters` (shape only). None for sender binding or unsolicited streams.
- SUSPICION F7-1 (CONFIRMED-BY-READING): **stream hijack / corruption by any room peer.** Mallory, in any room with Alice, sends continuation frames with the id of Bob's in-flight stream; they are appended to Bob's temp file (`node/ws_stream_transfer.rs:321-322`), the GCM check fails and the download dies (retry capped). For a co-recipient of a channel file (all members get the same key via the MLS header) Mallory can instead complete the transfer herself with ciphertext under that key and nonce, and her plaintext is written (`node/file_handler.rs:2337`, `:2384-2395`).
- SUSPICION F7-2 (CONFIRMED-BY-READING): **unbounded unsolicited disk writes.** Any room peer opens streams with fresh ids and a huge declared size; every frame is written to `files/.ws_recv_{id}.tmp` until Alice disconnects. ShareChunk-kind streams are never deleted even on completion (`node/file_handler.rs:2233`), and no sweep matches `.ws_recv_` (`node/swarm.rs:722` sweeps only `.stream_send_`/`.stream_shard_`).
- SUSPICION F7-3 (CONFIRMED-BY-READING for the Rust side): **shard stream accepted from anyone once a key is registered, and the FILE-3 hash check is opt-out by the registrant.** `pss.k`/`pss.m` come from whoever registered the pending shard (`ShardStore`/`ShardResponse`, A-V1/A-V6); `k = m = 0` skips the check (`node/file_handler.rs:2480`).
- SUSPICION F7-4 (PLAUSIBLE, device-linking area): LinkSnapshot completion has no sender binding (`node/file_handler.rs:2275`); whoever knows the link id and code (the relay sees the `link:{code}` room, see memory `lk2`) can deliver a snapshot of its choosing, which is imported at next launch. Out of this scope; flagged for the linking agent.

### A-F8 WebRTC file lane (`NodeCommand::WebRtcTransferComplete`)

- Dispatch sites: `node/swarm.rs:2589` `NodeCommand::WebRtcTransferComplete { transfer_id, temp_path, sender_peer_id, kind, shard_index, chunk_index } => {`; share chunks `:2590` `if kind == "share_chunk" {` -> `share_handler::handle_webrtc_share_chunk_complete`; declined files `:2596`; else `:2606` `file_handler::handle_webrtc_transfer_complete(` (`node/file_handler.rs:2063`), which calls the same `handle_completed_stream` (`:2098`). `transfer_id`, `temp_path`, `sender_peer_id` come from Dart (Dart parses the id with `parseWireTransferId`, not read here).
- Checks: same as A-F7 (none on sender). Binding: NONE FOUND. Freshness: NONE FOUND.
- Differences from the WS lane: kinds are only `file`/`shard` (`node/file_handler.rs:2083-2087`); the gossip relay copy (`:2114-2135`) re-floods a file whose id matches a pending relay.
- Tests: none found.
- SUSPICION: F7-1 and F7-3 apply identically (data-channel peer instead of room peer).

---

## 4. Vault shards

Common facts for this section:
- `store_shard` OVERWRITES by content id + index: key `vault/content_store.rs:220` `let key = shard_key(cid, shard_index);` (= SHA-256(cid || index), `:71-76`), `:225` `std::fs::write(&path, data)`, `:230` `INSERT OR REPLACE INTO vault_shards`. The stored `data_hash` is computed from the new bytes (`:222`), so the later checked read (`:255-274`) accepts them. The row's `server_id` is replaced by the new call's `sid`, but the path is `{vault}/{sid}/{key}.shard` (`:201-204`), so a store under a different `sid` repoints the row and orphans the old file.
- Vault placement and manifest distribution are server-wide, not channel-scoped: placements over `state.members.keys()` (`node/vault_ops.rs:239`), manifest (which carries the AES key, `vault/pipeline.rs:18` `pub encryption_key: String,`) broadcast to the SERVER group `node/vault_ops.rs:445-447` `mls.as_ref().is_some_and(|m| m.has_group(&server_id))` / `send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &manifest_envelope, crypto_store)` plus Olm to every leaf-less member (`:451-465`). Dart vault-uploads every channel file in a 6+ member server with no restricted-channel exclusion: `lib/src/core/providers/file_transfer_provider.dart:231-232` `final isVaultMode = serverId != null && channelId != null && memberCount >= 6;`, `:310-317`.

### A-V1 MessageEnvelope::ShardStore (stores a shard, or registers a pending shard stream)

- Dispatch sites: Olm `node/swarm.rs:8645` `Ok(MessageEnvelope::ShardStore { inner }) => {`; MLS `node/swarm.rs:11274` -> `node/vault_ops.rs:816` `handle_envelope_shard_store`.
- Target object: `sid`, `cid`, `si`, `sk`, `k`, `m`, `total_size`, `tier`, `data`, `chunks`.
- State changes: streamed (`chunks == 0 && data.is_empty()`): `node/swarm.rs:8658` `pending_shard_streams.insert(key.clone(), PendingShardStream {` (key `{cid}:{si}`, `:8657`, overwrites any other registration); inline: `node/swarm.rs:8690` `match content_store.store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes) {` + `ShardStored` + ack; chunked: `node/swarm.rs:8732` `pending_shard_assembly.insert(key, PendingShardAssembly {` (key `{cid}:{si}:{peer_str}`, `:8731`). MLS: `node/vault_ops.rs:845` pending, `:856` `let _ = cs.store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes);`, `:866` ack.
- Checks before the first state change: Olm `node/swarm.rs:8650-8652` `let is_member = server_states.get(&sid)` `.map(|s| s.is_member(peer_str))` (MASTER of OLM-PEER in payload `sid`, `crdt/server_state.rs:1290-1291`); Olm inline only: pledge `node/swarm.rs:8668` `.map(|s| s.get_storage_pledge(&local_peer))` and `:8674` `if pledge > 0 && used + shard_bytes.len() as u64 > pledge {` (0 = unlimited; our pledge, not the sender's). MLS `node/vault_ops.rs:840-841` `let is_member = server_states.get(&sid).map(|s| s.is_member(&sender_peer_id)).unwrap_or(false);` `if !is_member { return; }`.
- Who can sign: unsigned (OLM-PEER / MLS-LEAF).
- Binding: sender is a member of payload `sid`. Between sender and `cid` (whose content / whose upload): NONE FOUND. Between the placement plan and this receiver: NONE FOUND (no check that we were chosen).
- Transport parity: MLS inline has NO pledge check (`node/vault_ops.rs:849-857`); neither streamed path has one.
- Freshness / replay: NONE FOUND.
- Absent fields: `target` absent = everyone (MLS).
- Blast radius: local vault; overwritten shards are re-served to other members (A-V5) and break reconstruction for everyone who pulls them.
- Tests: none found.
- SUSPICION V1-1 (CONFIRMED-BY-READING): **any member overwrites any shard Alice holds.** Mallory, a member of server S, sends ShardStore `{sid: S, cid: <someone else's content>, si: n, data: garbage}`; `store_shard` replaces the file and row (`vault/content_store.rs:225`, `:230`) and records a matching hash. Via a streamed store she also sets `k = m = 0`, skipping FILE-3 (F7-3).
- SUSPICION V1-2 (CONFIRMED-BY-READING): **storage exhaustion by any member.** Pledge is only enforced on the Olm inline path and only when Alice set a pledge; streamed and MLS paths store unconditionally; `cid`/`si` are free so every message is a new shard.
- SUSPICION V1-3 (PLAUSIBLE): **cross-server repoint.** A member of server M stores `{sid: M, cid: X, si: n}` where X is content of server A; the `vault_shards` row for that key now says `server_id = M` and points at `vault/M/...`, so A's inventory (`list_content_shards(A, X)`, `vault/content_store.rs:363-388`) loses it while the old file stays on disk.

### A-V2 MessageEnvelope::ShardChunk (chunked shard assembly)

- Dispatch sites: Olm `node/swarm.rs:8750`; MLS `node/swarm.rs:11285` -> `node/vault_ops.rs:875-877` (log only, no-op).
- State changes (Olm): `node/swarm.rs:8756` `assembly.chunk_data.push((ci, chunk_bytes));`; on count reached, `node/swarm.rs:8771` `match content_store.store_shard(&asm.server_id, &asm.content_id, asm.shard_index, asm.k, asm.m, asm.total_size, tier_enum, &full_data) {` + ack.
- Checks: the assembly must exist under `{cid}:{si}:{peer_str}` (`node/swarm.rs:8751`), which only a ShardStore from the SAME OLM-PEER creates after its membership check (A-V1). Principal: OLM-PEER (sender-bound key).
- Binding: sender-bound assembly key.
- Transport parity: MLS ignores it.
- Freshness / replay: assemblies evicted after 600 s (`node/swarm.rs:5249`).
- Tests: none found.
- SUSPICION V2-1 (PLAUSIBLE): RAM exhaustion by a member: `expected_chunks` is sender-set (u32) and every distinct `ci` is buffered in memory until the 600 s sweep.

### A-V3 MessageEnvelope::ShardStoreAck (marks our placement confirmed)

- Dispatch sites: Olm `node/swarm.rs:8815`; MLS `node/swarm.rs:11289` -> `node/vault_ops.rs:880`.
- State changes: event `ShardStoreAckReceived`; Olm only: `node/swarm.rs:8828` `let _ = content_store.confirm_placement(&cid, si);` (`vault/content_store.rs:551-552` `UPDATE vault_placement SET confirmed = 1 WHERE content_id = ?1 AND shard_index = ?2`).
- Checks: NONE (no check that OLM-PEER is the placement's `target_peer`).
- Binding: NONE FOUND.
- Transport parity: MLS does not confirm placements (event only).
- Tests: none found.
- SUSPICION V3-1 (CONFIRMED-BY-READING, low): any Olm peer marks Alice's uploaded shard placements confirmed, so her redundancy accounting (`unconfirmed_placement_count`, `vault/content_store.rs:604-614`) lies and a failed placement is never retried.

### A-V4 MessageEnvelope::ShardDelete (makes us DELETE shards we hold)

- Dispatch sites: Olm `node/swarm.rs:8833` `Ok(MessageEnvelope::ShardDelete { sid, cid }) => {`; MLS `node/swarm.rs:11295` -> `node/vault_ops.rs:903` `handle_envelope_shard_delete`.
- Target object: `sid`, `cid`.
- State changes: Olm `node/swarm.rs:8849` `let _ = cs.delete_content(&sid, &cid);` (files + rows WHERE `server_id = sid AND content_id = cid`, `vault/content_store.rs:310-336`), `:8850` `let _ = cs.delete_placements(&cid);` (`vault/content_store.rs:564` `DELETE FROM vault_placement WHERE content_id = ?1`, NOT server-scoped), `ShardDeleted` event. MLS `node/vault_ops.rs:921` `let _ = cs.delete_content(&sid, &cid);` + event.
- Checks before first state change: Olm `node/swarm.rs:8839-8840` `s.is_member(peer_str) &&` `s.has_permission(&peer_str, crate::crdt::operations::Permission::MANAGE_SERVER)` (MASTER; override-aware, `crdt/server_state.rs:1203-1212`, `:1226-1228`). MLS `node/vault_ops.rs:912-916` `let role = s.get_role(sender_peer_id);` `let perms = role.default_permissions();` `(perms & crate::crdt::operations::Permission::MANAGE_SERVER) != 0` (ignores `role_permissions` overrides; no `is_member`).
- Who can sign: unsigned (OLM-PEER / MLS-LEAF). Authority = MANAGE_SERVER in payload `sid`.
- Binding: permission in `sid` to shards stored under `sid` (delete_content filter). Between `sid` and `cid` for placements: NONE FOUND.
- Transport parity: Olm is override-aware and deletes placements; MLS uses DEFAULT role permissions and keeps placements.
- Freshness / replay: NONE FOUND (a replayed delete deletes a re-stored shard).
- Blast radius: irreversible local deletion; the sender fans it to every member (`node/vault_ops.rs:518-546`), so it is network-wide.
- Tests: none found.
- SUSPICION V4-1 (CONFIRMED-BY-READING): **placement wipe across servers.** An owner/admin of ANY server Alice is in (Mallory creates server M and invites Alice) sends Olm `ShardDelete {sid: M, cid: X}` where X is Alice's upload in server A: the permission check passes on M and `delete_placements(&cid)` (`node/swarm.rs:8850`) deletes Alice's placement records for X in A.
- SUSPICION V4-2 (CONFIRMED-BY-READING): **permission model differs by transport.** MLS path reads `role.default_permissions()` (`node/vault_ops.rs:914`) instead of `get_permissions`, so an admin whose MANAGE_SERVER was revoked by a role override still deletes every shard via MLS, and an override-granted member is refused.
- SUSPICION V4-3 (PLAUSIBLE, chain with V1-3): after repointing X's row to `server_id = M`, the owner of M deletes it via `delete_content(M, X)`.

### A-V5 MessageEnvelope::ShardRequest (we serve shard bytes)

- Dispatch sites: Olm `node/swarm.rs:8862`; MLS `node/swarm.rs:11303` -> `node/vault_ops.rs:930`.
- Target object: `sid`, `cid`, `si`, `sk` (shard key; independent of `cid`/`si`).
- State changes: read `node/swarm.rs:8873` `match cs.read_shard_unchecked(&sid, &sk) {`; Olm writes a temp `node/swarm.rs:8890-8893` `let shard_safe_prefix = &cid[..16.min(cid.len())];` / `let shard_temp_name = format!(".stream_shard_{}_{}.tmp", shard_safe_prefix, si);` / `if let Ok(()) = tokio::fs::write(&shard_temp_path, &shard_data).await {` then `file_handler::stream_to_peer(` (`:8895`) with stream id `&cid`. MLS `node/vault_ops.rs:955` read, `:964-969` `file_handler::stream_to_peer_bytes(` with id `&cid`, which for a WebRTC peer writes `node/file_handler.rs:2674` `let temp_path = file_transfer::files_dir().join(format!(".stream_shard_{id}.tmp"));`.
- Checks: Olm `node/swarm.rs:8864-8866` member of payload `sid` (MASTER); MLS `node/vault_ops.rs:950-951` member of payload `sid`. No `channel_readable_by` / `can_see_channel` for the channel the content belongs to; no check that `sk` belongs to `cid`.
- Who can sign: unsigned.
- Binding: membership of `sid` only. Channel entitlement: NONE FOUND.
- Transport parity: Olm truncates `cid` to 16 bytes for the temp name; MLS uses the whole `cid` (WebRTC branch).
- Freshness / replay: NONE FOUND.
- Blast radius: disclosure of ciphertext; with the manifest (below) disclosure of plaintext.
- Tests: none found.
- SUSPICION V5-1 (CONFIRMED-BY-READING, Rust + Dart send side): **restricted-channel vault files readable by every member.** Any channel file in a 6+ member server is vault-uploaded (`file_transfer_provider.dart:231-232`), its manifest with the AES key goes to the whole SERVER group (`node/vault_ops.rs:445-447`), shards are placed on all members (`:239`), and ShardRequest serves any member (`node/swarm.rs:8864`, `node/vault_ops.rs:950`). A plain Member who cannot see an Admin-only channel holds its files' keys and shards. This is the restricted-channel backfill rule ("EVERY path that SERVES ... stored channel content asks `channel_readable_by` FIRST") broken on the vault lane.
- SUSPICION V5-2 (CONFIRMED-BY-READING): **remote panic of the event loop.** `&cid[..16.min(cid.len())]` (`node/swarm.rs:8890`) slices a sender-chosen `String` at byte 16; a `cid` with a multi-byte character straddling byte 16 panics. Mallory (member of `sid`) needs only one valid `sk` of a shard Alice holds for `sid` (computable as SHA-256(cid||index) from a known manifest, or planted first via A-V1). No `panic =` setting exists in any `rust/*/Cargo.toml` (grep), so the default unwind applies and the swarm task dies while the window lives (task-level effect inferred, not traced).
- SUSPICION V5-3 (PLAUSIBLE, Windows): **file write outside `files/` with attacker-chosen bytes.** MLS path, when Mallory has a WebRTC data channel with Alice: `.stream_shard_{cid}.tmp` with `cid = "/../../../<path>"` (`node/file_handler.rs:2674-2675`); the bytes are whatever shard `sk` names, which Mallory can plant via A-V1. Same class `parse_id` guards against for `.ws_recv_` (`node/ws_stream_transfer.rs:470-474` comment). The Olm path is limited to a 16-byte prefix (`node/swarm.rs:8890`). The file is never cleaned (the boot sweep only lists the files dir itself, `node/swarm.rs:717` `let Ok(entries) = std::fs::read_dir(&files_dir) else { return 0u32 };`).

### A-V6 MessageEnvelope::ShardResponse (stores a shard or registers a pending shard stream)

- Dispatch sites: Olm `node/swarm.rs:8922`; MLS `node/swarm.rs:11313` -> `node/vault_ops.rs:984`.
- State changes: `found == false` -> `ShardRequestFailed` event (`node/swarm.rs:8924`); `data` empty -> `node/swarm.rs:8933` `pending_shard_streams.insert(key.clone(), PendingShardStream {` with `node/swarm.rs:8935` `shard_key: String::new(), k: 0, m: 0, total_size: 0,` (MLS `node/vault_ops.rs:998-1001`); inline data (Olm only) -> `node/swarm.rs:8945` `let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);` + `ShardReceived`.
- Checks before first state change: NONE (no membership, no "we asked for this `cid`/`si`", no `pending_vault_downloads` check).
- Who can sign: unsigned.
- Binding: NONE FOUND.
- Transport parity: MLS inline only emits an event (`node/vault_ops.rs:1002-1008`); Olm inline stores.
- Freshness / replay: NONE FOUND.
- Tests: none found.
- SUSPICION V6-1 (CONFIRMED-BY-READING): **any Olm peer writes or overwrites any shard in any server's vault directory** (Olm inline `node/swarm.rs:8945`), and any MLS group member registers a `k = m = 0` pending stream for any `{cid}:{si}` (`node/vault_ops.rs:998-1001`) that it then fills by stream, skipping the FILE-3 hash check (F7-3). Combined with a forged VaultManifestBroadcast (A-V10) this substitutes the content of a vault download.
- SUSPICION V6-2 (CONFIRMED-BY-READING): unsolicited ShardResponse overwrites a legitimate pending registration for the same `{cid}:{si}` (HashMap insert), dropping the real `k`/`m` and so the hash check for the real response too.

### A-V7 MessageEnvelope::ShardResponseChunk

- Dispatch sites: Olm `node/swarm.rs:8955`; MLS `node/swarm.rs:11320` -> `node/vault_ops.rs:1013-1015` (no-op).
- State changes (Olm): only on an existing assembly keyed `resp:{cid}:{si}:{peer_str}` (`node/swarm.rs:8956`); nothing in `src/` inserts that key (grep `pending_shard_assembly.insert` finds only `:8732`, key without `resp:`), so the arm is dead; on completion it only emits `ShardReceived` and discards the data (`:8967-8971`, `let _full_data: Vec<u8> = ...`).
- Checks/Binding: sender-bound key. Tests: none. SUSPICION: none.

### A-V8 MessageEnvelope::ShardProbe (we list shard indices we hold)

- Dispatch sites: Olm `node/swarm.rs:8977`; MLS `node/swarm.rs:11324` -> `node/vault_ops.rs:1019`.
- State changes: none; reply `ShardProbeResponse` with `list_content_shards(&sid, &cid)` (`node/swarm.rs:8987`, `node/vault_ops.rs:1039`).
- Checks: member of payload `sid` (`node/swarm.rs:8979-8981`, `node/vault_ops.rs:1033-1034`). No channel entitlement.
- Binding: membership only. Tests: none.
- SUSPICION: inventory disclosure for restricted-channel content (same root as V5-1), PLAUSIBLE, low.

### A-V9 MessageEnvelope::ShardProbeResponse

- Dispatch sites: Olm `node/swarm.rs:9005` (log only, `:9007` `// Logged for now — download pipeline will use this data when built`); MLS `node/swarm.rs:11333` -> `node/vault_ops.rs:1051-1058` (log only).
- State changes: none. SUSPICION: none.

### A-V10 MessageEnvelope::VaultManifestBroadcast (stores a vault manifest incl. the AES key; links a file row)

- Dispatch sites: Olm `node/swarm.rs:9010`; MLS `node/swarm.rs:11339` -> `node/vault_ops.rs:1061`.
- Target object: `sid`, `chid`, and inside the JSON: `content_id`, `encryption_key`, `nonce`, `k`, `m`, `file_name`, `creator_peer_id`, `message_id` (`vault/pipeline.rs:16-33`). The envelope `cid` is ignored.
- State changes: `node/swarm.rs:9015` `let _ = cs.save_manifest(&sid, &chid, &manifest_obj);` (`vault/content_store.rs:629` `INSERT OR REPLACE INTO vault_manifests`, keyed by the JSON's `content_id`, `creator_peer_id` from the JSON); `node/swarm.rs:9020` `let _ = ms.set_file_content_id(&manifest_obj.message_id, &manifest_obj.content_id);` (`storage/messages.rs:5843` `UPDATE files SET content_id = ?1 WHERE message_id = ?2`). MLS: `node/vault_ops.rs:1074`, `:1078`.
- Checks before first state change: NONE on either arm (no membership, no `creator_peer_id == sender`, no existing-manifest check, no `sid` binding).
- Who can sign: unsigned.
- Binding: NONE FOUND.
- Transport parity: identical (both unguarded).
- Freshness / replay: NONE FOUND.
- Blast radius: local; the manifest drives reconstruction (`node/file_handler.rs:2539`, `vault/pipeline.rs:220-250`) and the cache path (`vault/pipeline.rs:296-300`).
- Tests: none found.
- SUSPICION V10-1 (CONFIRMED-BY-READING): **any Olm peer or group member replaces any vault manifest and relinks any file row.** Mallory sends a manifest with Alice's pending `content_id`, her own key and `k = m = 0`, plus a shard via A-V6: reconstruction decrypts Mallory's ciphertext with Mallory's key and writes it to the vault cache as the requested file (`node/file_handler.rs:2584-2591`). Separately, `set_file_content_id(message_id, …)` repoints any message's file row at a content id of Mallory's choosing.

### A-V11 MessageEnvelope::ShardMigrate (stores a shard)

- Dispatch sites: Olm `node/swarm.rs:9026`; MLS `node/swarm.rs:11346` -> `node/vault_ops.rs:1086`.
- State changes: Olm `node/swarm.rs:9037` `let _ = content_store.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);`; MLS `node/vault_ops.rs:1104`.
- Checks: member of payload `sid` (`node/swarm.rs:9029-9031`, `node/vault_ops.rs:1097-1098`). `sk` ignored (`_sk`, `node/vault_ops.rs:1092`). No check that a migration was planned, that we are the new holder, or that the sender held the shard.
- Binding: membership only. Freshness: NONE FOUND. Tests: none found.
- SUSPICION V11-1 (CONFIRMED-BY-READING): same overwrite + exhaustion primitive as V1-1/V1-2, with no pledge check on either transport.

---

## 5. Recovery pool

Common facts:
- All seven variants are intercepted BEFORE `handle_incoming_request`, from ANY room: `node/swarm.rs:4601` `let is_recovery = matches!(msg,` then `:4611` `if let Some(pool) = recovery_pool_state.as_mut() {`, ending `:4838` `continue; // Don't pass to handle_incoming_request.`. The event's `room` (bound at `node/swarm.rs:4561` `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } => {`) is never compared to `pool.room_code()` in this block; only the PeerJoined/PeerLeft hooks check it (`node/swarm.rs:3351` `if room == pool.room_code() && peer_id != local_peer_str && peer_id != device_peer_id {`).
- Principal = ROOM-PEER (`from`), any room. Unsigned, plaintext (`node/types.rs:2667` `// Plaintext messages (not MLS) — no group exists for a dead server.`).
- HOL-SEC-002 class: the pool's only secret is the token, and it IS the relay room name: `node/vault_ops.rs:689` `let room_code = format!("recovery:{}:{}", server_id, token);` (join `:693-695`; same at `:739`, `node/recovery_pool.rs:240-242`), and it is in the invite link (`node/vault_ops.rs:705`). No key is derived from it; nothing in the pool is encrypted beyond the shards' own AES layer. Manifests (keys) never cross the pool: `RecoveryManifestSync` has no sender in `src/` (grep finds only the type and the receive arm).
- State lives in RAM only (`node/swarm.rs:756`); nothing survives a restart. No application-level replay protection anywhere in the pool.
- Tests: `recovery_pool_membership_forms` (positive only). No rejection tests.

### A-R1 HavenMessage::RecoveryHello (adds a pool member; coordinator may broadcast a plan)
- Site `node/swarm.rs:4613`. Check: `:4614` `if server_id == pool.server_id {` (payload value, not secret, no principal). State: `:4622` `pool.add_member(from.clone(), inventory);` (inventory sender-supplied, `node/recovery_pool.rs:109-114`), direct `RecoveryWelcome` to `from`, events, and if coordinator `:4654` `if pool.is_coordinator() && pool.members.len() >= 2 {` a `RecoveryTransferPlan` to the pool room. Binding: NONE FOUND (room not checked).
- SUSPICION R-1 (CONFIRMED-BY-READING): any peer sharing ANY room with Alice (and the relay, which knows the token) joins her pool's member set and inventory, steering the coordinator's plan (`compute_transfer_plan` trusts every inventory, `node/recovery_pool.rs:171-237`) and the election (lowest peer id, `:255-257`).

### A-R2 HavenMessage::RecoveryWelcome
- Site `node/swarm.rs:4670`. Checks: NONE (no `server_id` in the message, no room check). State: `:4678` `pool.add_member(from.clone(), inventory);`, events, coordinator plan (`:4695`). Binding: NONE FOUND.
- SUSPICION: as R-1, without even the `server_id` check. CONFIRMED-BY-READING.

### A-R3 HavenMessage::RecoveryManifestSync
- Site `node/swarm.rs:4744`. Checks: parse only; `:4748` `if m.k > 0 || m.m > 0 {`. State: `pool.all_manifest_ids`, `file_k_values`, `manifest_meta` inserted/overwritten per `content_id` (`:4749-4757`). Binding: NONE FOUND.
- SUSPICION R-3 (CONFIRMED-BY-READING, DoS): any room peer overwrites `manifest_meta` (k, m, size, tier, name) for real content ids; the next plan registers pending shard streams and `pending_vault_downloads` with those values (`node/swarm.rs:4778-4790`), so reconstruction runs with the attacker's `k`.

### A-R4 HavenMessage::RecoveryTransferPlan (makes us receive AND SEND shards)
- Site `node/swarm.rs:4762`. Checks: parse only; no coordinator check, no room check. State for `dest_peer == local` (`:4771` `if assignment.dest_peer == local_peer_str {`): skip if held (`:4775` `if cs.has_shard(&sk).unwrap_or(false) {`), else `:4778` `pending_shard_streams.insert(key, PendingShardStream {` and `:4789` `pending_vault_downloads.entry(assignment.content_id.clone())`. For `source_peer == local` (`:4794`): `:4796` `if let Ok(shard_bytes) = cs.read_shard_unchecked(&pool.server_id, &sk) {`, temp write, `ws_stream_send` to `&assignment.dest_peer` (`:4809`) in the pool room, and a `RecoveryShardReceived` broadcast.
- Binding: NONE FOUND (any `from`; `dest_peer` any string).
- SUSPICION R-4a (CONFIRMED-BY-READING): a plan from any room peer makes Alice stream every shard she holds for the pool's server to any `dest_peer` present in the pool room (the relay, or anyone with the token), repeatedly (no dedup).
- SUSPICION R-4b (CONFIRMED-BY-READING, chain): **remote panic.** `&assignment.content_id[..8.min(assignment.content_id.len())]` (`node/swarm.rs:4800`) byte-slices a sender-chosen string. Reached once `read_shard_unchecked(&pool.server_id, &sk)` succeeds for `sk = shard_key(content_id, idx)`; a shard under such a `content_id` can be planted first by any Olm peer through A-V6 (`store_shard` with any `sid`/`cid`, `node/swarm.rs:8945`). A `content_id` with a multi-byte char across byte 8 then kills the node task.

### A-R5 HavenMessage::RecoveryShardReceived
- Site `node/swarm.rs:4710`. Checks: none. State: `:4712` `pool.mark_shard_received(&content_id, shard_index);` (RAM set, read by nothing else found) + UI event. SUSPICION: UI spoof only, low.

### A-R6 HavenMessage::RecoveryStatus
- Site `node/swarm.rs:4720`. Checks: parse only (`:4721`). State: `RecoveryPoolStatus` event with sender-chosen numbers. SUSPICION: UI spoof, low.

### A-R7 HavenMessage::RecoveryStop (stops Alice's pool)
- Site `node/swarm.rs:4732`. Checks: NONE (comment in the type says "Initiator stops the pool", `node/types.rs:2720`, not enforced). State: `:4736` `recovery_pool_state = None;`, `LeaveRoom`, `RecoveryPoolStopped`.
- SUSPICION R-7 (CONFIRMED-BY-READING): any peer in any shared room (a server co-member, a friend's DM room) ends Alice's active recovery pool with one plaintext frame.

---

## 6. Share

Common facts:
- Intercepted before `handle_incoming_request`, from ANY room, no room check: `node/swarm.rs:4844` `let is_share = matches!(msg,` ... `continue;` (`:4881`). Principal = ROOM-PEER. Unsigned, plaintext. State in RAM `ShareRegistry` + `shares` DB table.
- Key derivation (the HOL-SEC-002 question): the share key is RANDOM, `node/share_handler.rs:492-493` `let mut key = [0u8; 32];` `if let Err(e) = getrandom::fill(&mut key) {`; the room is `share:{root_hash}` (`:48`), root hash = SHA-256 of the manifest JSON (`:414-419`, `:521`); the key lives only in the link (`:52-59`) or in an E2EE `FileHeader.share_ref` (`node/types.rs:4052-4059`). Per-chunk nonce = chunk index (`:85-90`), unique per key. No key or passphrase is derived from a relay-visible value. What IS relay-visible in plaintext: the root hash (room name) and the whole manifest (file name, size, mime, chunk hashes, optional note; `node/types.rs:2773-2775` states it is sent in the clear).
- Tests (rejection): `share_handler.rs` `link_rejects_short_payload`, `link_rejects_wrong_scheme`, `link_rejects_bad_version`, `wrong_index_fails_decrypt`, `safe_name_*`, `unique_final_path_stays_inside_dir`. None for the envelope handlers.

### A-S1 HavenMessage::ShareManifestRequest (we send the manifest)
- Site `node/swarm.rs:4854` -> `node/share_handler.rs:1448`. Checks: `:1454` a registry entry for `root_hash`, `:1455` a manifest. Reply `SendDirect` in the share room to `from`. Binding: knowledge of the root hash (public to the relay). SUSPICION: none beyond metadata (by design).

### A-S2 HavenMessage::ShareManifestResponse (sets our manifest and RESETS our have-bitmap)
- Site `node/swarm.rs:4859` -> `node/share_handler.rs:1470`. Checks: `:1489` `if computed != claimed {` (SHA-256 of the bytes equals the claimed root), `:1498` count consistency. No check that we requested a manifest (`manifest_requested_at`) or lack one. State: `:1509-1514` for any registered share `state.manifest = Some(manifest.clone());` ... `:1512` `state.have = ChunkBitmap::empty(manifest.chunk_count);` + `ShareManifestReady` event.
- Binding: content-bound (hash). Freshness: NONE FOUND.
- SUSPICION S-2 (CONFIRMED-BY-READING, DoS): the relay (which sees every manifest in plaintext) or any room peer replays the valid manifest to Alice for a share she is SEEDING or half-downloaded: her `have` bitmap is zeroed, so she stops serving chunks (`:1614` `if !state.seeding && state.have.count_set() == 0 { return; }`, `:1653` `if !have.has(idx) { continue; }`) and her in-memory progress is lost, and Dart receives a spurious `ShareManifestReady`.

### A-S3 HavenMessage::ShareHave (records a peer's chunk bitmap)
- Site `node/swarm.rs:4864` -> `node/share_handler.rs:1524`. Checks: registry entry; `:1533-1537` chunk_count must match ONLY when a manifest is present. State: `:1542` `ChunkBitmap::from_bytes(bytes, chunk_count)` (`:291` `bits.resize(needed, 0)` with `needed = chunk_count/8`), `:1543` `state.peer_have.insert(sender_peer_id.to_string(), bitmap);`.
- SUSPICION S-3 (PLAUSIBLE, DoS): while Alice probes a link and has no manifest yet, a `ShareHave` with `chunk_count = u32::MAX` allocates ~512 MiB per distinct `from` (the relay can mint `from`s). Also any room peer inserts itself as a seeder, so the scheduler requests chunks from it (served chunks are hash-checked, `:1848-1852`).

### A-S4 HavenMessage::ShareChunkRequest (we serve encrypted chunks)
- Site `node/swarm.rs:4869` -> `node/share_handler.rs:1601`. Checks: registry entry; `:1614` seeding or holding chunks; per index `:1652` `if idx >= chunk_count { continue; }`, `:1653` held, `:1656` `if !prefer_webrtc {` (requester must have a live Share data channel, `:1612`); seed budget `:1664`. Serves ciphertext only (key in the link). Binding: knowledge of the root hash + a Share data channel. SUSPICION: none beyond bandwidth (budgeted).

### A-S5 HavenMessage::ShareChunkResponse (relay-routed inline chunk)
- Site `node/swarm.rs:4875` -> `node/share_handler.rs:1829`. Checks: registry + manifest, `:1844` index bound, `:1848-1852` SHA-256(ct) equals the manifest hash, `:1855` AES-GCM decrypt with the link key; then write + progress + finalize. Binding: content-bound. SUSPICION: none (integrity holds; a wrong-key decrypt failure emits `ShareFailed`, `:1860`, which a peer cannot trigger without a ciphertext matching the manifest hash).

---

## 7. Asset rail

### A-E1 HavenMessage::EmoteRequest (we serve content-addressed blobs)
- Dispatch sites: plaintext `node/swarm.rs:14005` `HavenMessage::EmoteRequest { hashes } => {` -> `node/emotes.rs:460` `handle_emote_request`. Not in fetch.rs.
- Target object: up to 20 hashes (`node/emotes.rs:475`).
- State changes: none; reply `EmoteAssets` via `send_message_to_peer` (`:500-505`) with held blobs up to `MAX_BUNDLE_REPLY_BYTES` (`node/assets.rs:95` `= 8 * 1024 * 1024`) and a `missing` list.
- Checks: hash shape `:476` `if !crate::crdt::valid_emote_hash(&h) {`. Principal: NONE (any ROOM-PEER, any kind, any blob we hold, including profile media and personal emotes).
- Who can sign: unsigned. Binding: knowledge of the hash. Freshness: n/a.
- Tests: `emote_request_for_unheld_hashes_answers_missing` (positive).
- SUSPICION E-1 (PLAUSIBLE, privacy): the `missing` list is a membership oracle: any room peer (or the relay, which sees every request/response in plaintext) learns whether Alice holds blob H (e.g. whether she has seen a given server's emote or someone's animated avatar).
- SUSPICION E-2 (PLAUSIBLE, DoS): up to 8 MiB of upload per request at the generic 20/s per-`from` budget.

### A-E2 HavenMessage::EmoteAssets (we cache blobs)
- Dispatch sites: plaintext `node/swarm.rs:14012` -> `node/emotes.rs:516` `handle_emote_assets`.
- State changes: rotate asks only for hashes asked of THIS device (`:528-535`); `:575` `.save_asset_blob(&hash, &bytes, animated, kind.db_kind())`, `:578` `pending.remove(&hash);`, `EmoteAssetsReceived` event.
- Checks before the store write, in order: bundle size `:536`; `api/showcase.rs:263` `if hex::encode(Sha256::digest(&bytes)) != hash {` (content address); `:550` `let Some(kind) = pending.get(&hash).map(|a| a.kind) else {` (we asked for this hash; kind is OURS); `:563` `bytes.len() > kind.recv_cap() || !is_webp(&bytes) || !canvas_ok`.
- Principal: none needed (content-addressed); the `missing`/refusal rotation is gated on `ask.asked.contains(peer_str)` (`:531`, `:568`).
- Binding: hash to bytes. Freshness: receipt = pending ask. Absent fields: `missing` default empty.
- Tests (rejection): `asset_request_not_answered_for_unrequested_hash`, `asset_cap_enforced_per_kind`, `asset_pull_ignores_missing_from_a_peer_we_did_not_ask`, `asset_pull_rotates_after_invalid_bytes`.
- SUSPICION: none.

---

## SUSPICION index (one line each)

- F1-1 `node/swarm.rs:8539` / `node/file_handler.rs:2981`: FileHeader from any Olm peer / group member registers its own key for someone else's `fid`; the stream write replaces the file (MLS arm even when complete). CONFIRMED-BY-READING.
- F1-2 `node/swarm.rs:8490` and `node/fetch.rs:1167` + `:1299`: inline FileHeader bytes written and marked complete outside the owner guard (fetch: even over a completed file). CONFIRMED-BY-READING.
- F1-3 `node/swarm.rs:8252-8260`: receipt/decline/ask consumed by any sender before any check. CONFIRMED-BY-READING.
- F1-4 `node/swarm.rs:8325-8330`, `node/file_handler.rs:2807/2813/2819`: no membership/post check on the announced `sid:cid`; MLS mute/cap read the outer server, context uses the payload server. CONFIRMED-BY-READING.
- F1-5 `node/sync_handler.rs:3623`, `node/swarm.rs:7218/7614/7856`: owner guard fed the sender-controlled `fm.sender`, so a sync responder relabels any file card. CONFIRMED-BY-READING.
- F1-6 `node/swarm.rs:8579-8593`, `lib/src/core/providers/event_provider.dart:1203-1225`: FileHeaderReceived with attacker share_ref emitted even when the guard refused; Dart auto-starts that share for the named file. PLAUSIBLE.
- F2-1 `node/swarm.rs:8603-8621`, `node/file_handler.rs:3040-3090`: FileChunk (no legitimate sender exists) lets any Olm peer / group member truncate any known file to empty with ONE frame (stored chunk_count is 0), or replace it with raw bytes. CONFIRMED-BY-READING.
- F2-2 `node/swarm.rs:8603`: FileChunk writes orphan chunk files for unknown ids, unbounded. CONFIRMED-BY-READING.
- F3-1 `node/swarm.rs:13640-13663`: FileRequest re-encrypts and re-streams the whole file per request; amplification. PLAUSIBLE.
- F5-1 `node/swarm.rs:13303-13309` (+ `:2537`): PublicFileHeader receipt not bound to the peer asked; relay/any room peer substitutes a guest's public file, cap-free. CONFIRMED-BY-READING.
- F7-1 `node/ws_stream_transfer.rs:321-322,370`, `node/file_handler.rs:2337`: stream state keyed by id only; any room peer appends to or completes another sender's transfer. CONFIRMED-BY-READING.
- F7-2 `node/ws_stream_transfer.rs:387-427`, `node/file_handler.rs:2233`: unsolicited streams write unbounded temp files; ShareChunk-kind temps never deleted. CONFIRMED-BY-READING.
- F7-3 `node/file_handler.rs:2480`: FILE-3 shard hash check skipped when the (untrusted) registrant set k=m=0. CONFIRMED-BY-READING.
- F7-4 `node/file_handler.rs:2275`: LinkSnapshot completion not sender-bound (device-linking area). PLAUSIBLE.
- V1-1 `node/swarm.rs:8690`, `node/vault_ops.rs:856`, `vault/content_store.rs:225/230`: any member overwrites any shard Alice holds. CONFIRMED-BY-READING.
- V1-2 `node/swarm.rs:8674` (only Olm inline, pledge 0 = unlimited): shard storage exhaustion by any member. CONFIRMED-BY-READING.
- V1-3 `vault/content_store.rs:201-204/230`: a store under another `sid` repoints a shard row across servers. PLAUSIBLE.
- V2-1 `node/swarm.rs:8732/8756`: ShardChunk assembly buffers unbounded RAM per member for 600 s. PLAUSIBLE.
- V3-1 `node/swarm.rs:8828`: any Olm peer confirms Alice's shard placements. CONFIRMED-BY-READING.
- V4-1 `node/swarm.rs:8850`, `vault/content_store.rs:564`: ShardDelete from an admin of ANY shared server wipes Alice's placement records for content of another server. CONFIRMED-BY-READING.
- V4-2 `node/vault_ops.rs:912-916`: MLS ShardDelete uses default role permissions (ignores overrides) and skips is_member; Olm is override-aware. CONFIRMED-BY-READING.
- V5-1 `node/vault_ops.rs:239,445-447`, `node/swarm.rs:8864`, `node/vault_ops.rs:950`, `lib/src/core/providers/file_transfer_provider.dart:231-232`: restricted-channel vault files: key to the whole server group, shards to all members, served to any member with no channel_readable_by. CONFIRMED-BY-READING.
- V5-2 `node/swarm.rs:8890`: `&cid[..16]` byte slice of a sender string, remote panic of the node task by a member. CONFIRMED-BY-READING.
- V5-3 `node/file_handler.rs:2674`: `.stream_shard_{cid}.tmp` with unsanitized `cid`; attacker-content write outside files/ on Windows. PLAUSIBLE.
- V6-1 `node/swarm.rs:8945`, `node/vault_ops.rs:998-1001`: unsolicited ShardResponse stores/overwrites any shard (Olm, no membership) or registers a k=m=0 stream (MLS). CONFIRMED-BY-READING.
- V6-2 `node/swarm.rs:8933`: unsolicited ShardResponse overwrites a legitimate pending shard registration. CONFIRMED-BY-READING.
- V10-1 `node/swarm.rs:9015/9020`, `node/vault_ops.rs:1074/1078`: VaultManifestBroadcast from anyone replaces any manifest (key) and relinks any file row. CONFIRMED-BY-READING.
- V11-1 `node/swarm.rs:9037`, `node/vault_ops.rs:1104`: ShardMigrate = unplanned overwrite + exhaustion by any member. CONFIRMED-BY-READING.
- R-1 `node/swarm.rs:4614/4622`: RecoveryHello from any room joins Alice's pool and steers plan/election. CONFIRMED-BY-READING.
- R-2 `node/swarm.rs:4678`: RecoveryWelcome, same without a server_id check. CONFIRMED-BY-READING.
- R-3 `node/swarm.rs:4748-4757`: RecoveryManifestSync from anyone overwrites pool manifest metadata. CONFIRMED-BY-READING.
- R-4a `node/swarm.rs:4794-4809`: RecoveryTransferPlan from anyone makes Alice stream her shards to any pool-room peer. CONFIRMED-BY-READING.
- R-4b `node/swarm.rs:4800`: `&content_id[..8]` byte slice, remote panic reachable after planting a shard via V6-1. CONFIRMED-BY-READING (chain).
- R-7 `node/swarm.rs:4732-4736`: RecoveryStop from anyone in any room ends Alice's pool. CONFIRMED-BY-READING.
- Recovery token = relay room name (`node/vault_ops.rs:689`): HOL-SEC-002 class for ACCESS (relay can join the pool), not for a key. CONFIRMED-BY-READING.
- S-2 `node/share_handler.rs:1509-1514`: replayed valid manifest zeroes a seeder's/downloader's have-bitmap. CONFIRMED-BY-READING.
- S-3 `node/share_handler.rs:1533-1543`, `:291`: ShareHave with huge chunk_count before a manifest allocates ~512 MiB per `from`. PLAUSIBLE.
- E-1 `node/emotes.rs:480-492`: EmoteRequest `missing` is a holds-blob oracle for any room peer / relay. PLAUSIBLE.
- E-2 `node/emotes.rs:485`, `node/assets.rs:95`: 8 MiB reply per request, 20 req/s per `from`. PLAUSIBLE.
