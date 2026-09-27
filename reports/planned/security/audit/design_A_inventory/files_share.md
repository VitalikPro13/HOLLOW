# Design A inventory: files, vault, recovery pool, Share

Read-only pass, 2026-09-27, working tree on top of `a71e72fa` (no uncommitted edits in
the files modules). Paths are relative to `rust/hollow_core/src/` unless they start with
`relay-uws/` or `lib/`. P-01 = fully malicious relay (stamps any `from`, replays,
re-routes, drops, reorders). Old evidence `phase_b_evidence/authz_files.md` was used as
hints only; every line below was re-read in the current code.

## Shorthands and shared facts

- **ROOM-FROM**: `from` the relay stamps on 0x02/0x05/0x06/0x08 frames
  (`node/ws_client.rs:516-552`). An honest relay writes the authenticated socket's id
  (`relay-uws/src/ws_handler.cpp:1646` `forwarded.append(data->peer_id);`, `:768-771`
  `build_direct_frame`). P-01 forges it freely.
- **OLM-DEV**: the device whose Olm session decrypted an `Encrypted` frame
  (`node/swarm.rs:7071` `match olm.decrypt(&peer_str, message_type, &ciphertext) {`),
  PreKey identity device-signed (`:6896` `if !crypto_handler::verify_olm_identity(`).
  P-01 cannot forge it.
- **MLS-LEAF**: bound leaf of the group (`node/swarm.rs:10281`
  `let sender_peer_id = sender.device.clone();`); envelope must fit the group
  (`:10304` `mls_envelope_fits_group(`); MLS replays dropped (`:10273`
  `Ok(crate::crypto::Decrypted::Replay) => return,`).
- Opcodes: client sends 0x02 binary direct (`node/ws_client.rs:811`), 0x03 room
  (`:1048`), 0x04 direct (`:1062`), 0x07 topic (`:1033`), 0x08 direct-image (`:1080`).
  Relay: 0x02 forwarded live only, sender AND target must be in the room
  (`ws_handler.cpp:1631` `if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;`,
  `:1637-1638`); 0x03 fanned out live only as 0x05 (`:1667-1686`); 0x04/0x08 delivered as
  0x06 and BUFFERED + replayed when the target is not in the room (`:1736-1740`,
  `:1751-1765`); 0x07 feeds the catch-up ring.
- Plaintext dispatch (`node/swarm.rs:4576`): per-ROOM-FROM token bucket (`:4592`
  `let rate_ok = {`), recovery intercept `:4616`, Share intercept `:4856`, the rest
  `handle_incoming_request(... &from ...)` (`:4900-4946`); the ROOM is not passed on, so
  FileRequest/FileUnavailable/PublicFileHeader handlers cannot see which room a frame used.
  Binary frames skip the rate limit (`:4400-4433`).
- `send_message_to_peer` = plaintext SendDirect into the FIRST room holding the peer
  (`node/crypto_handler.rs:2993` `if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {`,
  first match `:2675-2678`). `send_encrypted_message` = Olm then the same room lookup
  (`:2830`, `:2840`); needs a session (`crypto/olm_manager.rs:154`
  `.ok_or_else(|| format!("No session for peer {peer_id}"))?;`).

---

## File request family

### HavenMessage::FileRequest

1. **Send** (all plaintext SendDirect 0x04, no encrypted twin anywhere):
   - pull walk `node/file_asks.rs:227-236` `send_message_to_peer_in_room(ws_cmd_tx, room, device, HavenMessage::FileRequest {`;
     room = the server room for channel asks when the device is in it (`:142-149`), else
     first match; DM asks first match (`:118`). Re-stamps the receipt first (`:224`
     `requested_file_receipts.insert(file_id.to_string(), Instant::now());`).
   - rowless pull `node/file_handler.rs:2112-2117`; decrypt-fail retry to `pfs.sender`
     `:2513-2520`; WebRTC receiver fallback `:2255-2262`; guest pull to ONE room peer
     `node/swarm.rs:2549-2552`.
2. **Receive**: `node/swarm.rs:12876` `HavenMessage::FileRequest { file_id, chunks, offset } => {`.
   Not in the push node (`node/fetch.rs:959` `_ => None,`).
3. **Effect**: reads our bytes (`:12941`), fresh AES key per request (`:12960`
   `if let Ok(enc) = crate::vault::pipeline::aes_encrypt(&file_data) {`), temp
   `.stream_send_{file_id}_{nonce}.tmp` (`:12968`); member -> Olm `FileHeader` carrying the
   key, `sig: None,` (`:12997`, sent `:13018`); public non-member -> plaintext
   `PublicFileHeader` (`:13027-13045`); then the ciphertext: `offset > 0` ->
   `ws_stream_send` from offset (`:13048-13056`), else `stream_to_peer` (`:13061`); or a
   `FileUnavailable` (`:12950`). `chunks` is ignored.
4. **Authz**: `is_blocked(peer_str)` (`:12890`); `requester_master = super::resolver::resolve(peer_str);`
   (`:12894`); DM: `same_identity(peer_str, local_peer_str) || same_identity(peer_str, &file_meta.context_id)`
   (`:12897-12898`); channel: `s.is_member(&requester_master) && channel_readable_by(...)`
   (`:12911-12914`) or `s.is_channel_public(cid)` (`:12915`); unknown server fails closed
   (`:12919`). Principal = ROOM-FROM resolved to its MASTER. No signature, nonce or
   freshness. `context_id` is whatever the first card writer (or the verified sync author)
   stored.
5. **Timing**: live; being 0x04, an honest relay buffers it and replays it when the target
   rejoins the room (`ws_handler.cpp:1751-1765`).
6. **P-01**: forge ROOM-FROM = any entitled device -> the holder re-reads, re-encrypts and
   re-streams the whole file per frame (no dedup; bandwidth/CPU amplification up to
   20/s per forged `from`). Member answers are Olm to the claimed device (no disclosure).
   Public-channel answers are plaintext with the key (public trust model; P-01 can also
   join as a guest). Oracle: a forged entitled `from` gets a plaintext `file_unavail`
   `gone`/`expired`, telling P-01 which device holds which file. P-01 can drop requests.
7. **Session**: request needs none. A member answer needs an Olm session with the asking
   device; without one the header is lost (return value ignored `:13018-13022`) but the
   stream still leaves (`:13061`) and parks as an early arrival
   (`node/file_handler.rs:2410-2415`) until the 5-minute sweep (`node/swarm.rs:5306-5320`).
8. **Relay sees**: file_id, offset, asker and target device ids, room (the server id for
   channel asks, linking file_id to the server), timing.

### HavenMessage::FileUnavailable

1. **Send**: `node/swarm.rs:12950-12956` plaintext `send_message_to_peer`, only after the
   entitlement gate (`:12926`) and only when a row exists. No twin.
2. **Receive**: `node/swarm.rs:13085` -> `node/file_asks.rs:449` `handle_file_unavailable`.
3. **Effect**: negative recorded, in-flight cleared (`:474-475`); `expired` + local check
   -> `let _ = cs.mark_file_expired(&file_id, now_secs);` (`:492`), ask removed,
   `FileAvailability{expired}`; otherwise `advance` to the next holder (`:506`) or the
   `gone` dead-end event.
4. **Authz**: `if !ask.asked.contains(peer_str) {` (`:469`), the device asked on this
   connection, matched on ROOM-FROM only. Expiry is believed only when
   `retention_expired_locally` (our row + our server settings, `:408-442`).
5. **Timing**: live / 0x04-buffered. Asked sets reset on disconnect (`:721-731`).
6. **P-01**: forge `from` = the asked device -> every ask rotates at will: the walk can be
   exhausted to `gone` or steered to a chosen (colluding) holder. It cannot expire a file.
7. **Session**: none. 8. **Relay sees**: file_id, reason, which holder lacks what.

### HavenMessage::PublicFileHeader

1. **Send**: `node/swarm.rs:13027-13045` plaintext `send_message_to_peer` to a non-member
   asker for a public-channel file; carries `aes_key: hex::encode(enc.key),` (`:13042`),
   nonce, name, ext, mime, size, dims, mid, sid, cid, ts. Twin for members: the Olm
   `FileHeader` (`:12980-13022`).
2. **Receive**: `node/swarm.rs:12571`.
3. **Effect**: receipt removed (`:12589`), then `file_handler::handle_envelope_file_header`
   with `from_guest_pull = true` (`:12597-12609`, `None, false, true,` at `:12605`): files
   row written with the RESPONDER as sender (a guest holds no row, so
   `node/file_handler.rs:207` `return true; // No row yet — nothing to overwrite.`), the
   plaintext key registered as the pending stream (`:2969-2976`), early arrivals
   processed, `FileHeaderReceived` emitted. The receipt set at `node/swarm.rs:2547` makes
   it `explicitly_requested`, so the size cap and auto-download gate are skipped
   (`node/file_handler.rs:2889-2902`, `:2951`).
4. **Authz**: a receipt for the fid (`:12578`); `if asked != peer_str {` (`:12584`,
   ROOM-FROM equality); `let fresh = *req_sid == sid && req_at.elapsed() <= std::time::Duration::from_secs(120);`
   (`:12588`); `guest_rooms.contains(&sid)` (`:12590`). The shared gate then runs with
   `let judged_sid = if from_guest_pull { None } else { sid.as_deref() };`
   (`node/file_handler.rs:2878`) and `asked = true`: no membership, no ownership.
   NOTHING binds this header, its key or its name/ext to the message author: the signed
   `PublicChannelMessage` binds only `file_id`, and its unsigned `file_meta` goes to Dart
   as a UI event only (`node/swarm.rs:12169-12190`).
5. **Timing**: live; 0x04 (buffered); receipt 120 s, cleared on disconnect (`:3252`).
6. **P-01**: sees the plaintext FileRequest (fid, target), forges `from` = the asked peer,
   supplies its own name/ext/mime/size/key and its own 0x02 stream (or keeps the honest
   header and rewrites the stream, since the honest key is plaintext too). The guest
   stores relay bytes under the signed card, any alphanumeric ext (e.g. `exe`,
   `node/file_transfer.rs:31-35`), with no size cap. Replay: once, inside 120 s.
7. **Session**: plaintext by design (`node/types.rs:2288-2294`).
8. **Relay sees**: everything, including the AES key and the full ciphertext stream.

### HavenMessage::FileProbe

1. **Send**: `node/gossip_relay.rs:164-169` `send_message_to_peer(... HavenMessage::FileProbe { file_id: file_id.clone() },`
   to the gossip origin on a relay timeout; plaintext 0x04.
2. **Receive**: none: falls into `node/swarm.rs:13464` `_ => {}` (and `node/fetch.rs:959`).
3-7. No effect, no check, dead on receive. The comment at `node/gossip_relay.rs:163`
   (`// Fall back: request the file from the origin via normal FileRequest.`) is wrong: the
   gossip fallback fetches nothing.
8. **Relay sees**: file_id + gossip origin (overlay topology).

### HavenMessage::FileProbeResponse

No send site and no receive arm (grep; `node/swarm.rs:13464`). Dead type.

---

## Recovery pool (all plaintext, intercepted at `node/swarm.rs:4616`)

Common: frames count only when `let in_pool_room = recovery_pool_state.as_ref().is_some_and(|p| room == p.room_code());`
(`:4627`) - the relay-stamped room. The room is `recovery:{server_id}:{token}`
(`node/vault_ops.rs:696`, `:746`; token also in the invite link `:712`), so P-01 always
knows it and is always "in the pool" (HOL-SEC-002 class, HOL-SEC-026 Variants). No
signature, no replay protection; state in RAM only. No session exists or is used
(`node/types.rs:2653` `// Plaintext messages (not MLS) — no group exists for a dead server.`).
PeerLeft in the pool room removes a member (`node/swarm.rs:3803-3810`), so P-01 also
controls membership removal.

### HavenMessage::RecoveryHello

1. **Send**: `node/vault_ops.rs:763-773` SendToRoom (0x03) into the pool room on join.
2. **Receive**: `node/swarm.rs:4633`.
3. **Effect**: `pool.add_member(from.clone(), inventory);` (`:4642`) with sender-chosen
   manifest ids + shard inventory; Welcome back (`:4650-4654`); UI events; if we are the
   lowest id, a new transfer plan to the room (`:4674-4686`).
4. **Authz**: pool room (`:4627`) + `if server_id == pool.server_id {` (`:4634`, a
   non-secret payload value). Principal = ROOM-FROM.
5. **Timing**: live 0x03.
6. **P-01**: injects members with any forged id and inventory; a lexically lowest forged id
   becomes coordinator (`node/recovery_pool.rs:255-257`). Replay re-adds.
7. **Session**: none. 8. **Relay sees**: server id, token, manifest content ids, every
   member's shard inventory.

### HavenMessage::RecoveryWelcome

1. **Send**: `node/swarm.rs:4645-4655` SendDirect to the Hello sender; `:3354-3368`
   SendDirect on PeerJoined in the pool room (0x04, so buffered by an honest relay).
2. **Receive**: `node/swarm.rs:4690`.
3. **Effect**: `pool.add_member(from.clone(), inventory);` (`:4698`), events, coordinator
   plan (`:4715-4728`).
4. **Authz**: pool room only; the message carries no server id at all.
5-8. As Hello.

### HavenMessage::RecoveryTransferPlan

1. **Send**: `node/swarm.rs:4679-4685`, `:4720-4726` SendToRoom, only when
   `pool.is_coordinator()`.
2. **Receive**: `node/swarm.rs:4764`.
3. **Effect**: `dest_peer == local` and content with a LOCAL manifest
   (`pool.manifest_meta.get(&assignment.content_id)` `:4782`, filled from our own content
   store `node/recovery_pool.rs:261-283`) and shard not held (`:4785`) ->
   `pending_shard_streams.insert(key, PendingShardStream {` (`:4788`) with local k/m +
   `pending_vault_downloads` (`:4799`). `source_peer == local` and dest a pool member
   (`:4804-4805`) -> read shard (`:4808`), temp in the OS temp dir (`:4809-4813`),
   `ws_stream_send` 0x02 to dest (`:4818-4827`), then a `RecoveryShardReceived` broadcast.
4. **Authz**: pool room + `let from_coordinator = pool.members.keys().min() == Some(&from);`
   (`:4767`); dest must be in `pool.members`. Both rest on ROOM-FROM.
5. **Timing**: live 0x03.
6. **P-01**: via a forged lowest-id member it is the coordinator: it makes us stream every
   shard we hold for the pool's server to any member id it minted (shard ciphertext; the
   manifest key never crosses the pool), repeatedly (no dedup), and opens pending shard
   streams it can then fill with poisoned shards (see the 0x02 section).
7. **Session**: none. 8. **Relay sees**: the full plan (who holds and sends what).

### HavenMessage::RecoveryShardReceived

1. **Send**: `node/swarm.rs:4830-4839` SendToRoom after each send.
2. **Receive**: `node/swarm.rs:4730`. 3. `pool.mark_shard_received(&content_id, shard_index);`
   (`:4732`, a RAM set nothing else reads) + UI event. 4. Pool room only.
5. Live. 6. P-01: UI spoof. 7. None. 8. content id + index.

### HavenMessage::RecoveryStatus

1. **Send**: NONE in `src/` (grep: only `node/types.rs:2694` and the receive arm).
2. **Receive**: `node/swarm.rs:4740`. 3. `RecoveryPoolStatus` UI event with
   sender-chosen numbers (`:4741-4749`). 4. Pool room only. 6. P-01: UI spoof. 7-8 n/a.

### HavenMessage::RecoveryStop

1. **Send**: `node/vault_ops.rs:805-810` SendToRoom on stop.
2. **Receive**: `node/swarm.rs:4752`. 3. `recovery_pool_state = None;` (`:4756`), leave
   room, `RecoveryPoolStopped`.
4. **Authz**: pool room only; any member, not only the initiator (the doc
   `/// Initiator stops the pool.` `node/types.rs:2699` is not enforced).
5. Live. 6. **P-01**: one forged frame (or a replay) ends our pool. 7. None.
8. That the pool ended.

---

## Share (all plaintext, intercepted at `node/swarm.rs:4856`)

Common: room `share:{root_hash}` (`node/share_handler.rs:48`); root hash = SHA-256 of the
manifest JSON (`:414-419`); the key is random (`:492-493`) and lives in the link
(`:52-59`) or in a `FileHeader.share_ref` (`node/types.rs:4033-4041`). Principal
everywhere = ROOM-FROM. Chunks never ride the relay: they go over a dedicated Share
WebRTC data channel (`:1547-1553`; hidden shares use `streamIceConfigProvider`, which is
`shareIceConfigProvider`, `lib/src/core/providers/ice_config_provider.dart:129-131`).

### HavenMessage::ShareManifestRequest

1. **Send**: `node/share_handler.rs:648-655` SendToRoom (0x03) on ShareOpenLink.
2. **Receive**: `node/swarm.rs:4865` -> `node/share_handler.rs:1448`.
3. **Effect**: SendDirect `ShareManifestResponse` to ROOM-FROM (`:1459-1466`).
4. **Authz**: we hold that root hash and its manifest (`:1454-1455`); knowledge of the
   root hash (= the room name) only.
5. Live. 6. P-01: can pull any manifest whose room it saw. 7. None by design.
8. Root hash.

### HavenMessage::ShareManifestResponse

1. **Send**: `node/share_handler.rs:1459-1466` SendDirect (0x04).
2. **Receive**: `node/swarm.rs:4870` -> `node/share_handler.rs:1470`.
3. **Effect**: taken once: `if let Some(state) = registry.get_mut(&root_hash).filter(|s| s.manifest.is_none()) {`
   (`:1511`) sets manifest, ext, empty bitmap; `ShareManifestReady` is emitted on every
   copy, replays included (`:1518-1523`).
4. **Authz**: content-bound: `if computed != claimed {` (`:1489`), chunk-count consistency
   (`:1498`). Sender irrelevant.
5. 0x04 (buffered). 6. **P-01**: can only replay the genuine manifest -> spurious UI
   events, no state change (HOL-SEC-027). 7. None.
8. **Relay sees**: the whole manifest in clear: file name, mime, size, chunk hashes,
   created_at, note (`node/types.rs:2750-2772`).

### HavenMessage::ShareHave

1. **Send**: `node/share_handler.rs:989-1005` SendToRoom every 10 s (`:328`) and on
   PeerJoined in a share room (`node/swarm.rs:3377-3382`).
2. **Receive**: `node/swarm.rs:4875` -> `node/share_handler.rs:1526`.
3. **Effect**: `state.peer_have.insert(sender_peer_id.to_string(), bitmap);` (`:1544`);
   the scheduler then asks that peer for chunks.
4. **Authz**: manifest known and matching count
   (`if state.manifest.as_ref().is_none_or(|m| m.chunk_count != chunk_count) {` `:1536`).
5. Live. 6. **P-01**: phantom seeders under forged ids -> requests that time out (8 s,
   `:329`), slowing downloads; bytes stay hash-checked. 7. None.
8. Per-peer progress bitmaps.

### HavenMessage::ShareChunkRequest

1. **Send**: `node/share_handler.rs:1426-1443` SendDirect to assigned peers.
2. **Receive**: `node/swarm.rs:4880` -> `node/share_handler.rs:1602`.
3. **Effect**: encrypted chunks emitted as `WebRtcSendFile` (`:1682-1690`), budgeted
   (`:1665`); never over the relay.
4. **Authz**: seeding or holding chunks (`:1615`), index held (`:1653-1654`),
   `let prefer_webrtc = webrtc_share_peers.contains(sender_peer_id);` (`:1613`) else skip
   (`:1657-1660`). ROOM-FROM + Dart's data-channel peer mapping.
5. Live. 6. **P-01**: forged requests only cause sends on an existing Share channel to
   that peer id (ciphertext; key in the link), inside the seed budget. 7. Dedicated
   STUN-only peer connection. 8. Chunk indices wanted.

### HavenMessage::ShareChunkResponse

1. **Send**: NONE (`node/share_handler.rs:1838`
   `hollow_log!("[SHARE] WARN: unexpected relay-routed ShareChunkResponse");`).
2. **Receive**: `node/swarm.rs:4886` -> `node/share_handler.rs:1830`.
3. **Effect**: writes the chunk to the partial, progress, finalize (`:1870-1918`).
4. **Authz**: content-bound: index bound (`:1845`),
   `if h.as_slice() != expected.as_slice() {` (`:1850`), AES-GCM with the link key (`:1856`).
5-8. P-01 can deliver only a genuine chunk; nothing to substitute. Would expose the
   chunk ciphertext if anyone sent it.

---

## Byte lane

### Binary 0x02 stream frames (`WsEvent::BinaryDirect`)

1. **Send**: `node/ws_stream_transfer.rs:104` `ws_stream_send` / `:218`
   `ws_stream_send_bytes` -> `SendBinaryDirect` (`:175-179`); frame
   `[type:1][id:64][total_size:8][shard_index:2 | chunk_index:4][data]`, continuation
   `[0xFF][id:64][data]` (`:3-5`). Callers: `node/file_handler.rs:2727-2730`
   (`stream_to_peer` fallback, first-match room), `:2782-2785`; FileRequest resume
   `node/swarm.rs:13051`; recovery `:4818`; link snapshots (out of area). WebRTC is
   preferred when a data channel exists (`node/file_handler.rs:2698-2724`). Payload: File =
   AES-256-GCM ciphertext under the header's key; Shard = packed vault shard; LinkSnapshot
   = code-encrypted `.hollow` blob; ShareChunk-kind frames are dropped on arrival
   (`:2300-2302`).
2. **Receive**: `node/swarm.rs:4400` `WsEvent::BinaryDirect { room: _, from, data } => {`
   -> `node/ws_stream_transfer.rs:353` -> `node/file_handler.rs:2280`.
3. **Effect**: `.ws_recv_{id}.tmp` (`:432`); File -> decrypt with the pending key, write the
   final file, `mark_file_complete` (`node/file_handler.rs:2439-2471`); unknown id -> early
   arrival (`:2410-2415`); Shard -> `store_shard` (`:2577`) and reconstruction (`:2589`);
   LinkSnapshot -> stash (`:2363`).
4. **Authz**: `parse_id` allowlist (`:519-527`); the stream belongs to its opener
   (`if pending.get(&id)?.sender != from {` `:373`), takeover after 10 s idle (`:416`),
   16 per sender / 128 total (`:423`), bounded by the sender-declared size (`:388`, `:319`);
   declined ids deleted (`node/swarm.rs:4407`). NOTHING binds the stream sender to the
   header or registration it completes: File completion is keyed by id only
   (`node/file_handler.rs:2410` `let Some(pfs) = pending_file_streams.remove(&file_id) else {`;
   `pfs.sender`, stored at `:3086`/`swarm.rs:8269`, is never compared); Shard completion
   likewise (`:2542` `let Some(pss) = pending_shard_streams.remove(&key) else {`).
   LinkSnapshot does compare (`:2347` `.is_some_and(|state| state.sender == sender_peer);`),
   but to ROOM-FROM. File content check = AES-GCM tag under the pending key (`:2455`), no
   size check against the header. Shard check = self-referential per-shard hash
   (`:2553` `if pss.k > 0 || pss.m > 0 {`, `:2557`; stamped by the packer itself,
   `vault/erasure.rs:164`); the real check is the content id at reconstruction
   (`vault/pipeline.rs:251`).
5. **Timing**: live only (the relay never buffers 0x02); receive state dropped on
   disconnect (`node/swarm.rs:3280`).
6. **P-01**: forges `from`, so the ownership rule is ROOM-FROM equality and P-01 can open,
   hold or take over any stream id. File stream: substitution needs the key, so it is
   full substitution for guest pulls (plaintext key) and corruption/DoS otherwise (GCM
   failure parks the bytes and triggers a bounded re-request, `:2483-2522`). Shard
   stream: any registered `{cid}:{si}` takes P-01's self-consistent shard, stores it, and
   the genuine shard is later refused (`:2571` `if content_store.has_shard(&key).unwrap_or(true) {`):
   reconstruction then fails the content-id check for good on that device (integrity
   holds, availability does not). Drop/truncate at will.
7. **Session**: none on this lane; confidentiality is the header key.
8. **Relay sees**: kind, id (file id, vault content id + shard index, link id), declared
   size, sender/target devices, room, timing, all ciphertext bytes.

WebRTC twin: same completion (`node/file_handler.rs:2127-2176`), `sender_peer_id` from Dart
(`node/swarm.rs:2593-2619`); gossip neighbours re-flood completed files
(`node/file_handler.rs:2179-2198`). The data channel's peer identity rides plaintext
`RtcOffer`/`RtcAnswer` SDP through the relay (`node/swarm.rs:13097-13117`, gate: friend or
shared server only) - whether the DTLS fingerprint is bound to that peer id is UNTRACED
here (transport inventory).

---

## Encrypted envelopes: transport and sender binding only

| Variant | Sent over | Receive arms | Sender binding |
|---|---|---|---|
| `FileHeader` | DM live: Olm 0x04 first-match (`node/file_handler.rs:1419-1423`), `msg, None, None,` = unsigned (`:1414`); DM offline image: Olm 0x08 into `dm_room` with inline bytes + message sig (`:1463-1480`); DM offline: Olm 0x04 into `dm_room`, metadata only (`:1514-1523`); DM live but receiver-pref-gated: Olm 0x04 first-match, metadata only (`:1325-1334`); channel: MLS topic 0x07, subgroup-aware (`:1834`) + Olm to leaf-less devices (`:1857-1861`), `sig: None,` (`:1697`); FileRequest re-serve: Olm, `sig: None,` (`node/swarm.rs:12997`) | Olm `node/swarm.rs:7962`; MLS `:10369` -> `node/file_handler.rs:2837`; push `node/fetch.rs:949` -> `:1308` (DM only, `:1317`); guest via PublicFileHeader | OLM-DEV / MLS-LEAF, then `file_header_refused` (`node/file_handler.rs:227-250`): a channel header needs a member who can see the channel (`:239`); an existing card needs its owner's master or `asked` (`:245` `Ok(Some(row)) if !asked && super::resolver::resolve(&row.sender_id) != master => {`); Olm `asked` = `pending_file_asks...asked.contains(peer_str)` or `pending_file_streams...p.sender == peer_str` (`node/swarm.rs:7973-7974`); MLS `asked = false` except guests (`node/file_handler.rs:2880`). First header for an unseen fid creates the card owned by its sender (`:207`). |
| `ShardStore` | Olm only (`node/vault_ops.rs:405-422`, `:649-669`); MLS copy ignored (`node/swarm.rs:10602-10607`) | Olm `node/swarm.rs:8323` | OLM-DEV -> `shard_write_refused` (`node/vault_ops.rs:836` member of sid, `:839` shard not held, `:844` pledge); streamed registration `or_insert` (`node/swarm.rs:8350`). Bytes that follow on 0x02 are not bound to this sender. |
| `ShardStoreAck` | Olm reply (`node/swarm.rs:8375-8382`) | Olm `:8386` | OLM-DEV same identity as the placement target (`:8391-8395`) |
| `ShardDelete` | MLS 0x03 + Olm to leaf-less (`node/vault_ops.rs:533-553`) | Olm `node/swarm.rs:8412`, MLS `:10587` -> `handle_shard_delete` | member + MANAGE_SERVER in the named sid (`node/vault_ops.rs:884-887`) |
| `ShardRequest` | Olm (`node/vault_ops.rs:150-162`, `:590-602`; `node/swarm.rs:5572-5586`, `:5693-5707`) | Olm `node/swarm.rs:8421` | OLM-DEV -> `shard_serve_refused` (`node/vault_ops.rs:852-871`: member, manifest home, `channel_readable_by`); key must be this shard's (`node/swarm.rs:8430`) |
| `ShardResponse` | Olm metadata (`node/swarm.rs:8435-8444`), bytes on 0x02/WebRTC (`:8455`) | Olm `:8466` | OLM-DEV -> `shard_write_refused` (`:8479`); registers a `k: 0, m: 0` stream (`:8488-8492`), so the per-shard hash check is off for it |
| `VaultManifestBroadcast` | MLS 0x03 (live only, not the topic ring) + Olm to leaf-less (`node/vault_ops.rs:452-473`) | Olm `node/swarm.rs:8504`, MLS `:10595` -> `ingest_vault_manifest` | member, `resolve(sender) == creator_peer_id` (`node/vault_ops.rs:921`), shape checks (`:923`), never over another creator (`:936-940`); relinks a card only if all cards for that message are the creator's (`:948`). Unsigned. |
| `ShardMigrate` | Olm to `migration.to_peer` (`node/swarm.rs:5735-5744`; a placement MASTER id, not resolved to a device, so likely no session and dropped: UNTRACED) | Olm `:8511` | OLM-DEV -> `shard_write_refused` (`:8516`) |

Replay: MLS replays are dropped (`node/swarm.rs:10273`). A replayed Olm frame fails
decrypt and tears the session down (5 s throttle) + KeyRequest (`node/swarm.rs:7088-7141`):
a cross-area relay DoS on every Olm-carried file/vault envelope, UNTRACED here (Olm
inventory).

---

## 9. File content integrity end to end

**What the author signs.** The message signature, by the MASTER (`bundle_keypair` =
`native_keypair`, `node/swarm.rs:456-457`; `node/file_handler.rs:933-970`), over
`"hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}"`
(`node/crypto_handler.rs:236`; v3 adds `{album}`). It binds `file_id` only: NO content
hash, size, key, share root or vault content id. `FileHeaderPayload.sig/pk`
(`node/types.rs:2855-2858`) is that same message signature over `[file:{fid}]`, set only on
offline or pref-gated DM headers, verified only to insert the sentinel DM row
(`node/swarm.rs:8165-8194`, `node/fetch.rs:1472-1494`); never over bytes. The `files`
table has no hash column (`storage/messages.rs:790-810`; `content_id` at `:902` is
vault-only). Nothing on message ingest compares the card's `sender_id` (first header
writer) with the signed author. On completion the only bytes check is the AES-GCM tag
under the key of whichever header was accepted (`node/file_handler.rs:2455`): it proves
"someone who held that key", not "the author". First successful bytes stick
(`file_bytes_on_disk`, `:254-260`) and are re-served onward (`node/swarm.rs:12941`).

**DM file.** Signed `DirectMessage` binds fid (`node/file_handler.rs:1267-1281`) ->
unsigned Olm header from the author device with a per-device fresh key (`:1407`,
`:1413-1416`) -> GCM bytes. Re-pull candidates are the counterparty's devices and our own
siblings (`node/file_asks.rs:113-133`); an asked holder skips the owner check and picks
both key and bytes (`node/swarm.rs:12960-13016`).
- Relay: cannot substitute (key only inside Olm).
- Counterparty: can substitute a file OUR identity sent, when a device of ours holds its
  card from DM sync (context = the counterparty, author = us, `node/swarm.rs:7540-7548`)
  and pulls the bytes: the counterparty's devices are asked first (`node/file_asks.rs:115-121`).
  A self-echoed live header files the card under our own master instead
  (`node/swarm.rs:8060-8064`), so that path only asks our siblings.
- Our own siblings: can serve anything (same identity, trusted).
- Author: can equivocate per recipient device (per-device keys, no commitment).

**Channel file (MLS, restricted subgroups included).** Signed `ChannelMessage` binds fid
(`:1594-1609`) -> unsigned MLS header from the author leaf; ONE key+nonce for every member
of the (sub)group (`:1682-1710`) -> pushed by replication/gossip or pulled from any
readable member (`node/file_asks.rs:139-165`, `node/file_handler.rs:1981-2001`).
- Any member holding K+N whose stream completes first (or takes over after 10 s idle):
  completion is keyed by id only, GCM passes for its own ciphertext.
- Any holder we ask via FileRequest (asked bypass; unsigned Olm header, its own key).
- Gossip neighbours re-flooding the file (they hold K).
- Relay alone: cannot (no K). It can steer: forged `FileUnavailable` (asked-set on
  ROOM-FROM), dropping honest streams, and possibly reordering the topic ring so a
  colluding member's header for the fid lands first (first-header card ownership).
  That last race is UNTRACED to the rendered card.

**Public-channel file.** Members: as channel. Guests: signed `PublicChannelMessage` binds
fid (`node/swarm.rs:12158-12164`); `file_meta` is unsigned UI data; key, name, ext and
bytes all come from ONE plaintext `PublicFileHeader` accepted on ROOM-FROM equality.
- Relay: substitutes trivially (key in clear, forged `from`), any ext, no size cap.
- Any member responder: substitutes.

**Share-backed file (>34 MB, channels only).** DM drops the reference
(`node/file_handler.rs:1106` `share_ref: None,`), so DM large files stream directly.
`share_ref {root_hash, key}` rides the unsigned MLS header (`:1703`) and reaches Dart only
from the card owner (`:2992`, `node/swarm.rs:8317`). Bytes: manifest SHA-256 == root hash
(`node/share_handler.rs:1484-1493`), each chunk SHA-256(ciphertext) == manifest
(`:1848-1853`, `:1963-1968`), GCM with the link key (`:1856`, `:1971`); Dart bridges
completion to the fid (`lib/src/core/providers/event_provider.dart:1597-1607`).
- Relay, seeders: cannot substitute (content-addressed).
- But the root hash is bound to the author only by MLS-LEAF + first-header ownership,
  not by the signature: the same first-header race as channel files applies.

**Vault file (6+ members, non-image, non-restricted).** `content_id` = SHA-256 of the
ciphertext (`api/crdt.rs:1759`, `vault/content_store.rs:64-66`); the manifest (key,
content id, message id, `vault/pipeline.rs:16-33`) lands only from its creator
(`node/vault_ops.rs:918-941`); reconstruction refuses
`if content_id(&ciphertext) != manifest.content_id {` (`vault/pipeline.rs:251`).
- Relay, holders, other key holders: cannot substitute.
- The hash is not signed; it is tied to the card by transport (creator == sender) and
  the relink rule (all cards for the message are the creator's, `:948`).
- Poisoned shards stick (0x02 section): availability, not integrity.

**Recovery pool.** Shards registered only for content with a LOCAL manifest
(`node/swarm.rs:4782`), rebuilt against its content id: integrity holds; poisoning and
ciphertext exfiltration by P-01 remain (HOL-SEC-002 class).

| Lane | Signed hash? | Relay can substitute | Non-author holder can substitute |
|---|---|---|---|
| DM | no | no | yes, when asked (counterparty re-serving a file we sent, card from DM sync; our siblings) |
| Channel (MLS) | no | no alone; yes colluding with a member | yes: any member (shared K) or asked holder |
| Public, guest | no | yes | yes (asked responder) |
| Public, member | no | as channel | as channel |
| Share-backed | unsigned root hash in MLS header | no | no (bytes); root hash via first-header race only |
| Vault | unsigned content id in creator's manifest | no | no (DoS by poisoned shard only) |

H8 answer: the gap is real for DM re-pulls, every channel and public file, and guests;
closing it needs the author to sign a content commitment (e.g. a hash of the plaintext
or of a canonical ciphertext, plus size) inside the message signature payload, with
every completion path (`try_decrypt_file_stream`, inline writes, share bridge, vault
relink) checking the bytes against it before `mark_file_complete`.

---

## UNTRACED / open

- WebRTC data-channel peer identity vs relay-carried SDP (transport inventory).
- Olm replay -> session teardown on every Olm-carried file/vault envelope (Olm inventory).
- Relay reordering of the 0x07 ring to win first-header card ownership: not followed to
  what Dart renders under the author's signed caption.
- `ShardMigrate` sent to a master id (`node/swarm.rs:5744`): delivery not followed.
- Dart `GossipRelayFile` forwarding path not read.
- A FileRequest resume (`offset > 0`) is answered under a fresh key while the receiver
  keeps the old prefix (`node/swarm.rs:12960`, `:13048-13056`): looks like it can only
  fail GCM; functional, not followed further.
