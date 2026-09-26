# Authz matrix evidence: CHANNEL CONTENT

Scope: channel messages, sync batches, edits, deletes, reactions, link previews,
channel sync request/probe/response, public channels, notification hints, typing,
pin consumption. All paths are relative to `rust/hollow_core/src/` unless noted.
Every quote below was read at the cited line. Read-only; nothing built or run.

## Cross-cutting facts used by several sections

- F1. Plaintext WS frames reach `handle_incoming_request` with the relay-stamped
  sender and WITHOUT the room they arrived in: `node/swarm.rs:4560`
  `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } => {`
  and `node/swarm.rs:4920` `&local_peer_str, &from, is_invisible,` (the `room`
  binding is only used in log lines, e.g. 4567, 4936). So a HavenMessage naming
  server S is processed the same whether it arrived in S's room, a DM room, an
  inbox room or a conference room.
- F2. Relay room join has no membership gate: `relay-uws/src/ws_handler.cpp:493`
  `if (!is_valid_room_code(room)) {` is the only refusal besides the per-peer room
  cap (499-503); then `ws_handler.cpp:526` `ws_room.peers[data->peer_id] = ws;`.
  The client itself joins a server's room as a GUEST by id:
  `node/swarm.rs:1873-1874` `guest_rooms.insert(server_id.clone());` /
  `WsCommand::JoinRoom { room_code: server_id.clone() }`.
- F3. Any stranger can obtain an Olm session with any peer: KeyRequest refuses a
  device only via `node/swarm.rs:6531` `if key_exchange_device_unauthorized(peer_str) {`,
  and that returns false for any device the resolver does not know:
  `node/crypto_handler.rs:587-589` `if master == sender_device {` /
  `// Unknown device, or a single-device peer: nothing to cross-check.` / `return false;`.
  The Olm `Encrypted` arm (swarm.rs:6682-6969) has no friend/member gate before
  the `MessageEnvelope` match at 6969.
- F4. MLS arm: the group is chosen from the OUTER frame, the inner envelope names
  its own sid/cid, and nothing compares them.
  `node/swarm.rs:10888-10891` `let group_key = match &msg_channel_id { Some(cid) => crate::crypto::subgroup_id(&server_id, cid), None => server_id.clone(), };`
  `node/swarm.rs:10955` `match mls_mgr.decrypt_fresh(&group_key, &ciphertext) {`
  `node/swarm.rs:10984` `let sender_master = super::resolver::resolve(&sender_peer_id);`
  then each arm (10987-11261) takes `sid`/`cid` from the decrypted envelope.
  grep for any sid-vs-group compare in swarm.rs/types.rs/sync_handler.rs: NOT FOUND.
  Conference meetings are MLS groups in the same `MlsManager`
  (`node/conference.rs:169` `let sid = conf_server_id(&conf_id);`,
  `node/conference.rs:177` `if let Err(e) = mls_mgr.create_group(&sid) {`), so a
  conference group decrypts through this same arm. `sender_peer_id` = leaf
  credential bytes: `crypto/mls_manager.rs:550-553`.
- F5. Posting permission exists but is only called on the SEND side and the FFI:
  `crdt/server_state.rs:1592` `pub fn can_post_in_channel(&self, peer_id: &str, channel_id: &str) -> bool {`.
  Callers (grep `can_post_in_channel`): `node/message_ops.rs:964`
  `if !server.can_post_in_channel(local_peer_str, channel_id) {` (send gate),
  `node/file_handler.rs:581` `if !server.can_post_in_channel(local_peer_str, cid) {` (send gate),
  `api/crdt.rs:377` (FFI `me_can_post`). Ingest callers: NONE FOUND. The send
  gate's doc claims otherwise: `node/message_ops.rs:952-953`
  `/// Cooperative-client fast-fail gates for a channel send: posting permission plus`
  `/// the moderation trio. Receivers drop violations too.` (true for the trio on the
  MLS/public path only, false for posting permission everywhere).
- F6. `can_see_channel` is never called on a channel-content INGEST path (only on
  serving paths via `channel_readable_by`, `node/crypto_handler.rs:2057-2065`, and
  in MLS subgroup bootstrap at swarm.rs:10908).
- F7. Ban removes the member from `members`: `crdt/server_state.rs:913`
  `self.members.remove(peer_id);`, so `is_member` covers ban where it is called.
  `is_banned` is never called on a channel ingest path (grep: only swarm.rs:9811,
  10016, both join-related).
- F8. Store-level writers do not check authorship; every authorship decision is
  in the caller:
  - edit: `storage/messages.rs:3181-3187` (row lookup, `if old_text == new_text { return Ok(false); }`),
    then `storage/messages.rs:3201`
    `UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4, updated_at = ?2 WHERE message_id = ?5`
  - sender repair: `storage/messages.rs:3234`
    `"UPDATE channel_messages SET sender_id = ?1, is_mine = ?2, signature = ?3, public_key = ?4 WHERE message_id = ?5"`
  - card + sig: `storage/messages.rs:1474-1475`
    `"UPDATE {table} SET link_preview_json = ?1, signature = ?2, \ public_key = ?3 WHERE message_id = ?4"`
  - reactions: `storage/messages.rs:3481` `"INSERT OR IGNORE INTO message_reactions ...`
    (no read of `reaction_removals`), removal `storage/messages.rs:3502`
    `"DELETE FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3"`.
  - `channel_message_exists` is GLOBAL by mid (any server/channel):
    `storage/messages.rs:3338` `"SELECT 1 FROM channel_messages WHERE message_id = ?1 LIMIT 1"`.
- F9. Signature primitive: `node/crypto_handler.rs:232-237` payload
  `"hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}"`
  (v3 adds `{album}`), key bound to the claimed sender by
  `node/crypto_handler.rs:1785` `if derived_pid != sender_peer_str {` (cached) /
  1734 (uncached). Missing sig or pk returns false (1720-1723, 1765-1768).
  Backfill: `node/crypto_handler.rs:1868-1869`
  `if sig_b64.is_none() && pk_b64.is_none() { return BackfillSig::Absent; }`,
  `1830` `BackfillSig::Absent => !REQUIRE_SIGNED_BACKFILL,` with
  `1804` `pub(crate) const REQUIRE_SIGNED_BACKFILL: bool = true;`.

---

### A-CH01 MessageEnvelope::ChannelMessage  (new channel message row)

- Dispatch sites:
  - Olm MessageEnvelope arm: `node/swarm.rs:6970` `Ok(MessageEnvelope::ChannelMessage { inner }) => {`
  - MLS MessageEnvelope arm: `node/swarm.rs:10987` `MessageEnvelope::ChannelMessage { inner } => {` -> `message_ops::handle_envelope_channel_message` (10990)
  - Plaintext `HavenMessage::PublicChannelMessage` reuses the MLS handler: `node/swarm.rs:12909` (see A-CH10)
  - fetch.rs (push background node), MLS: `node/fetch.rs:492` `MessageEnvelope::ChannelMessage { inner } => {`; public twin `node/fetch.rs:545`
  - relay 0x07 ring / 0x06 replay: arrives as the same WS frame (F1) or, in fetch, via `node/fetch.rs:335-336` (`0x06 | 0x05 => parse_direct_frame`, `0x08 => parse_topic_frame`)
  - sync backfill: see A-CH02. Gossip / WebRTC data channel: NOT FOUND (the only other `handle_incoming_request` caller, swarm.rs:2920, is fed by `accept_gossip_op`, CRDT ops only).
- Handler: Olm inline in `handle_incoming_request` (swarm.rs:6970-7081); MLS/public `handle_envelope_channel_message`, `node/message_ops.rs:2372`; fetch `try_process_channel_msg`, `node/fetch.rs:459`.
- Target object: (`sid`, `cid`) from the payload + `mid` (dedup key).
- State changes (Olm): `node/swarm.rs:7040` `match store.insert_channel_message(` (sender = `&sender_master`), `7053` `let _ = store.update_channel_link_preview(message_id, &lp_json);`, event `7064` `.send(NetworkEvent::ChannelMessageReceived {`.
  (MLS/public): `node/message_ops.rs:2603` `store.insert_channel_message(`, `2611` `store.update_channel_link_preview(`, event `2451`.
  (fetch): `node/fetch.rs:656` `let inserted = store.insert_channel_message(`, `665` preview.
  All: `storage/messages.rs:2068` `crate::chat_clock::observe(...)` (clamped to now+5 min, `chat_clock.rs:41`).
- Checks before first state change, in order:
  - Olm:
    1. `node/swarm.rs:6976` `let sender_master = super::resolver::resolve(peer_str);` (relay-stamped device -> master)
    2. `node/swarm.rs:6978-6981` `if let Some(state) = server_states.get(&sid) {` / `if !state.is_member(&sender_master) {` -> reject; unknown sid rejected at 6983-6985. Principal: resolved MASTER vs payload `sid`.
    3. `node/swarm.rs:7004-7011` `verify_message_signature_v2(&sender_master, sig.as_deref(), pk.as_deref(), "ch", &format!("{sid}:{cid}"), ts, &extras, &msg_text, ...)` -> reject. Principal: signer key == master.
    4. `node/swarm.rs:7018` `let msg_text = clip_text(msg_text);`
    5. dedup `node/swarm.rs:7034-7036` `store.channel_message_exists(m)`.
    NOT checked: `can_see_channel`, `can_post_in_channel` (F5), mute, slow mode, media-only (no call between 6970 and 7081).
  - MLS / public:
    1. `node/message_ops.rs:2396` `if super::conference::is_conference_sid(&sid) {` -> drop (inner sid only).
    2. `node/message_ops.rs:2414` `if channel_sig_rejected(` -> `2493-2495` v2 verify against `sender_peer_id` (= `sender_master`, swarm.rs:10992) over `"ch"`, `"{sid}:{cid}"`.
    3. `node/message_ops.rs:2425-2430` only `if let Some(state) = server_state {` -> `live_channel_moderation_drop`: `2524` `if state.is_muted(sender_peer_id, now_ms) {`, `2528` `if state.is_channel_media_only(cid) && !has_file {`, `2532-2533` slow mode (see SUSPICION S8).
    NOT checked: `state.is_member(sender)`, sid known (unknown sid skips moderation and still persists), sid matches the MLS group (F4), `can_see_channel`, `can_post_in_channel`, text length (no `clip_text`; grep `clip_text(` has no hit in message_ops.rs).
  - fetch: `node/fetch.rs:499` conference guard; `505` resolve; `518` `if fetch_channel_sig_rejected(` (backfill rule, 613-617); `524` `let text = clip_text(text);`. NOT checked: membership, sid-vs-group, visibility, posting, moderation trio (fetch has no ServerState at all).
- Who can sign: the author's MASTER key over `hollow-msg2:ch:{sid}:{cid}:{master}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}` (F9). Any identity can produce this for any sid/cid of its choice.
- Binding (signer -> right to post in THIS channel):
  - Olm: server membership only, `node/swarm.rs:6979` `if !state.is_member(&sender_master) {`. Channel-level binding: NONE FOUND.
  - MLS/public/fetch: NONE FOUND (MLS group membership is for the OUTER group, F4).
- Transport parity:
  - membership: Olm yes (6979); MLS no; public no; fetch no.
  - moderation trio: MLS/public yes (2425-2430); Olm no; fetch no.
  - text clamp: Olm (7018) and fetch (524, 575) yes; MLS/public no.
  - conference-sid guard: MLS (2396) and fetch (499); Olm relies on unknown-server reject (conference sids are never in `server_states`: inserts only at swarm.rs:862, 9523, sync_handler.rs:634).
- Freshness / replay: dedup by `mid` (`channel_message_exists`, survives restart). No ts window (author picks `ts`; order clamp only in chat_clock). A message with `mid: None` is not deduped by id (legacy content-unique index only).
- Absent fields: `sig`/`pk` absent -> reject (all transports). `mid` absent -> accepted, not dedupable, not editable. `album` absent -> v2 payload. `link_preview` absent -> fine.
- Blast radius: row persists locally and is re-served by us in channel sync to every reader of that channel (the row verifies), so it propagates; not reversible by anyone but the author's own delete.
- Tests (rejection on this path): signature unit tests in `node/crypto_handler.rs` (`v1_signature_is_rejected` 4148, `malformed_album_is_rejected_even_when_signed` 4097). Harness: `moderation_trio_mute_slowmode_mediaonly` (test_harness.rs:8342) exercises the SEND-side refusal (`8417-8421` waits for the local `Error` "muted"), not a receiver drop of a modified client's frame. Non-member / restricted-channel / non-poster injection rejection: none found.
- SUSPICION S4 (MLS: no sid binding, no membership). Mallory = plain member of server S (in the server-wide group, NOT in restricted subgroup S#R), or a member of any other MLS group Alice holds (another server, or a conference `conf:*` group she was admitted to). Mallory sends `MlsChannelMessage{server_id: <group she is in>, channel_id: None}` whose inner `ChannelMessage{sid: S, cid: R}` is signed by her own master. Alice decrypts (swarm.rs:10955), `handle_envelope_channel_message` persists it in S/R (message_ops.rs:2433) and emits it. CONFIRMED-BY-READING.
- SUSPICION S5 (no posting permission at ingest, all transports). Mallory = plain member; channel `announcements` has `ChannelPosting::AdminPlus`. Mallory's modified client skips the send gate (message_ops.rs:964) and sends normally; every receiver stores it (no ingest call, F5). CONFIRMED-BY-READING.
- SUSPICION S6 (Olm arm skips the moderation trio). Mallory = muted member. She sends her ChannelMessage as an Olm envelope (the MLS-failure fallback shape) instead of MLS; swarm.rs:6970-7081 checks only membership + signature, so the message is stored and displayed despite the mute / slow mode / media-only. Same for any row reaching a mobile victim through fetch.rs:492-529. CONFIRMED-BY-READING.
- SUSPICION S8 (slow mode trusts the sender's `ts`). `node/message_ops.rs:2536` `let window_start = ts - (slow as i64) * 1000;` and `2542` `store.channel_sender_has_msg_in_range(&sid_o, &cid_o, &sender, window_start, ts)` (storage `timestamp > ?4 AND timestamp < ?5`, messages.rs:2165). Mallory (member, slow mode 60 s) sends a burst with `ts` values spaced more than 60 s apart (past or future, she signs them herself); every one passes. CONFIRMED-BY-READING.
- SUSPICION S18 (size clamp parity, low). MLS/public live messages are stored unclipped (no `clip_text` in message_ops.rs), unlike Olm (swarm.rs:7018) and fetch (524). Storage bloat on every member up to the relay frame size. CONFIRMED-BY-READING.

### A-CH02 MessageEnvelope::ChannelSyncBatch  (backfill rows, edits, cards, deletions, file cards, reactions)

- Dispatch sites:
  - Olm: `node/swarm.rs:7082` `Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, .. }) => {`
  - MLS: `node/swarm.rs:11253` -> `sync_handler::handle_envelope_channel_sync_batch` (`node/sync_handler.rs:3387`)
  - fetch.rs: not handled (Olm: `node/fetch.rs:756` `Ok(_) => None,`; MLS: `node/fetch.rs:542` `_ => None,`).
- Handler: Olm inline (swarm.rs:7082-7285); MLS `handle_envelope_channel_sync_batch` + `upsert_synced_channel_message` (sync_handler.rs:3496) + `repair_wedged_sender` (3574) + `apply_sync_item_extras` (3595).
- Target object: batch `sid`/`cid`; per item `mid` (row identity, global, F8), `s` (claimed author), `file_meta.fid`, `reactions[].p`.
- State changes, per item, in order (Olm line / MLS line):
  1. insert new row: `swarm.rs:7132` / `sync_handler.rs:3512` `store.insert_channel_message(sid, cid, &msg.s, &msg.t, ...)`; edited stamp `7141` / `3521`.
  2. existing row + `edited_at`: `swarm.rs:7147` / `sync_handler.rs:3526` `store.edit_channel_message(mid, &msg.t, edit_ts, msg.sig..., msg.pk...)` (+ event `ChannelMessageEdited` on MLS, 3531).
  3. existing row, no `edited_at`, sig Valid: `swarm.rs:7160-7163` / `sync_handler.rs:3581-3584` `if stored_sender.as_deref() != Some(msg.s.as_str()) {` -> `store.repair_channel_message_sender(mid, &msg.s, is_mine, msg.sig..., msg.pk...)`.
  4. card: `swarm.rs:7179-7184` / `sync_handler.rs:3548-3552` `message_ops::apply_synced_link_preview(&store, true, mid, &msg.t, lp, msg.sig..., msg.pk...)` whose only row check is `node/message_ops.rs:1637` `if row.text != item_text {`.
  5. deletion: `swarm.rs:7196-7201` / `sync_handler.rs:3606-3610` `apply_verified_channel_deletion(...)`; signer taken from the row AFTER steps 2-3: `node/message_ops.rs:120` `let Some(sender) = store.get_channel_message_sender(mid) else {`, `123` `let signer = super::resolver::resolve(&sender);`, write `135` `store.set_channel_message_hidden_verified(...)`.
  6. file card: `swarm.rs:7207-7212` / `sync_handler.rs:3621-3627` `.filter(|fm| file_handler::file_meta_write_allowed(&store, &fm.fid, &fm.sender))` -> `store.insert_file_metadata(...)` + `FileHeaderReceived` event.
  7. reactions: `swarm.rs:7242-7245` / `sync_handler.rs:3650-3653` `sync_reaction_accepted` -> `store.add_reaction(mid, &r.e, &r.p, ...)`.
  8. pagination: `swarm.rs:7256-7261` plaintext `channel_sync_request` to the batch sender; MLS `sync_handler.rs:3438-3454` Olm `ChannelSyncReq`.
  9. events `MessageSyncProgress` (7267), `MessageSyncCompleted` (7277 / 3457) for the batch `sid`.
- Checks before the first state change: ONLY the per-item signature:
  `swarm.rs:7108-7112` / `sync_handler.rs:3486-3490` `check_backfill_signature(&msg.s, "ch", &format!("{sid}:{cid}"), msg.ts, msg.edited_at, &extras, &msg.t, msg.sig..., msg.pk..., ...)`, gate `7115` / `3418` `if !sig_check.is_acceptable() {`. Principal: key == the item's OWN claimed `s`.
  NOT checked (either transport): batch sender is a member of `sid`; batch sender may read `cid` (`channel_readable_by`); `sid` is a server we hold; a request of ours is outstanding for this (sid, cid); item author `msg.s` is a member / may see / may post; mute / slow / media-only (deliberately skipped, `node/message_ops.rs:2506-2508` "Sync backfill intentionally skips these gates"); item `msg.s` equals the EXISTING row's sender (steps 2-5); `file_meta.fid == msg.file_id` (step 6; the guest path does check it, swarm.rs:13239); text length.
- Who can sign: each item by its own claimed author (master key), same payload as A-CH01, `ts = edited_at` when present (`crypto_handler.rs:1871`). The batch as a whole is unsigned (authority = transport sender, unchecked).
- Binding: item -> channel: the v2 context `"{sid}:{cid}"` (a row signed for channel X cannot be placed in Y). Batch sender -> anything: NONE FOUND. Item signer -> EXISTING row it modifies (edit / sender repair / card): NONE FOUND.
- Transport parity: logic identical; differences: MLS emits `ChannelMessageEdited` on step 2 (3531), Olm does not; Olm file-card `is_mine` = `msg.s == local_peer` (7216), MLS uses resolver `is_mine` (3631). Olm sender = any Olm peer (F3); MLS sender = any member of any shared MLS group (F4).
- Freshness / replay: none at batch level. Insert dedup by mid; `edit_channel_message` has no `edited_at` ordering (F8, messages.rs:3181-3203), so an older edit re-applies; reactions re-add after removal (F8).
- Absent fields: `sig`+`pk` both absent -> Absent -> refused; one absent -> Forged. `hidden_sig`/`hidden_pk` absent -> flag dropped (message_ops.rs:113-118). `mid` absent -> inserted without dedup, steps 2-7 skipped. `file_meta.mid`, `file_meta.sender` free text, unsigned.
- Blast radius: rows, re-attributions and deletion proofs are re-served by the victim in its own sync responses, so they propagate to other members; a hidden flag has no undo path (apply is a no-op once hidden+proof, message_ops.rs:110-111).
- Tests: `backfill_rejects_signature_replayed_onto_another_sender` (crypto_handler.rs:3854), `backfill_rejects_unsigned_item` (3893), `backfill_rejects_tampered_text` (3909), `backfill_verifies_v2_edit_and_rejects_extras_tamper` (4428), `synced_link_preview_is_covered_by_the_item_signature` (message_ops.rs:3289), `synced_reaction_requires_its_own_signature` (3409), `synced_channel_deletion_requires_author_proof` (3046), harness `synced_channel_deletion_rejects_unproven_hidden_flags` (test_harness.rs:13536; its forged proof keeps the honest `s`, 13590-13592, so the re-attribution path below is not exercised). Batch-sender membership / readability / row-owner mismatch: none found.
- SUSPICION S1 (existing rows rewritable by ANY item signer). CONFIRMED-BY-READING, both transports.
  (a) Re-attribution: Mallory (any Olm peer, F3) sends `ChannelSyncBatch{sid, cid, messages:[{mid: <Bob's mid>, s: Mallory, t: <Bob's text>, sig: Mallory's own v2 sig}]}`. Signature is Valid for `s`=Mallory, row exists, no `edited_at` -> `repair_channel_message_sender(mid, Mallory, ...)` (swarm.rs:7161 / sync_handler.rs:3582): Bob's message is now Mallory's (and Alice's own messages lose `is_mine`).
  (b) Censorship in the same item: add `hidden_at` + Mallory's own `ch-delete` signature over the row text/extras. Step 5 runs after step 3 and takes the signer from the row (message_ops.rs:120-123), which is now Mallory, so the proof verifies and Bob's message is hidden on Alice, then served onward with its proof.
  (c) Content forgery under the real author's name: item `{mid: Bob's mid, s: Mallory, t: "evil", edited_at: E, sig: Mallory over ts=E}` -> `edit_channel_message` overwrites Bob's text (swarm.rs:7147 / sync_handler.rs:3526); `sender_id` stays Bob (F8 UPDATE does not touch it); only the stored sig/pk become Mallory's.
  (d) Phishing card on someone else's message: item `{mid: Bob's mid, s: Mallory, t: Bob's exact text, edited_at: E, lp: <phishing card>}` -> step 2 is a no-op (`old_text == new_text`, messages.rs:3185) so no repair, then step 4 lands the card (row text matches, message_ops.rs:1637) with Mallory's sig.
  Only the `mid` must be known; the row may be in any server/channel because `channel_message_exists` is global and the batch sid/cid is attacker-chosen (the re-served copy only verifies onward if Mallory used the row's real sid/cid).
- SUSPICION S2 (unsolicited batches from anyone; backfill bypasses moderation). Mallory = stranger with an Olm session (F3), a kicked member, or a muted member. She pushes a batch naming Alice's server S and restricted channel R with items she signed herself; each is inserted (swarm.rs:7132 / sync_handler.rs:3512) with no check on who sent the batch or who authored the items, and without mute/slow/media-only/posting gates. A muted member bypasses the mute by speaking only through sync batches. CONFIRMED-BY-READING.
- SUSPICION S14 (file card blob unbound on the member path, low). `file_meta_write_allowed` returns true when no row exists (`node/file_handler.rs:206-207` `let Ok(Some(existing)) = store.get_file_metadata(file_id) else {` / `return true;`), and `fm.fid` is never compared with the signed `msg.file_id`. Mallory's own valid item can carry `file_meta{fid: <new id>, sender: Bob, mid: <Bob's mid>}`: a metadata row attributed to Bob and a `FileHeaderReceived{sender_id: Bob, message_id: Bob's mid}` event are emitted (swarm.rs:7220 / sync_handler.rs:3634). Write CONFIRMED-BY-READING; what the UI shows is PLAUSIBLE.

### A-CH03 MessageEnvelope::EditMessage (channel)  +  HavenMessage::PublicChannelEdit

- Dispatch sites: Olm `node/swarm.rs:7915`; MLS `node/swarm.rs:10997` -> `message_ops::handle_envelope_edit_message` (`node/message_ops.rs:2620`) with `&sender_master`; plaintext `HavenMessage::PublicChannelEdit` `node/swarm.rs:12945` -> same handler with `resolve(peer_str)` (12947); fetch.rs `node/fetch.rs:739` routes EVERY edit to the DM table (`handle_edit_message` -> `edit_dm_message`, fetch.rs:1075), so a channel edit is a no-op there.
- Target object: `mid` (row); `sid`/`cid` are only used for the mute lookup, the signing context and the event.
- State changes: `store.edit_channel_message` Olm `swarm.rs:7946`, MLS/public `message_ops.rs:2659`; event `ChannelMessageEdited` (7997 / 2671) only when both sid and cid present.
- Checks, in order:
  - Olm: 1. mute on the WIRE sid: `swarm.rs:7920-7922` `message_ops::live_muted_ingest_drop(sid.as_deref().and_then(|s| server_states.get(s)), &peer_str, "edit",` (is_muted collapses device->master, server_state.rs:1445). 2. `swarm.rs:7929` `if sid.is_some() {` else DM branch. 3. `swarm.rs:7930-7931` `let sender = store.get_channel_message_sender(&mid);` / `if sender.as_deref() == Some(&peer_str) {` (row sender vs relay-stamped DEVICE id). 4. `swarm.rs:7939-7942` v2 verify with signer `&peer_str`, context from the wire sid/cid, extras from OUR row.
  - MLS/public: 1. `message_ops.rs:2637` `if live_muted_ingest_drop(server_state, peer_str, "edit") {` where `server_state` came from the WIRE sid (swarm.rs:10998, 12949). 2. `message_ops.rs:2642-2643` `let sender = store.get_channel_message_sender(&mid);` / `if sender.as_deref() == Some(peer_str) {` (row sender vs resolved MASTER). 3. `message_ops.rs:2652-2655` v2 verify, signer `peer_str`, `"ch"`, context `"{sid}:{cid}"` from the wire, extras from our row.
- Who can sign: row author's master over `hollow-msg2:ch:{sid}:{cid}:{author}:{edit_ts}:{mid}:{row extras}:{new_text}`.
- Binding: `message_ops.rs:2643` / `swarm.rs:7931` (row sender == editor) plus the signature. Moderator edit: NOT FOUND (author only).
- Transport parity: Olm compares the row's MASTER sender to the DEVICE `peer_str` (7931) and verifies against the device id (7940), so a multi-device author's Olm edit never applies (fail-closed, functional). Olm with `sid: None` goes to the DM branch; MLS/public ignore `sid` for ownership.
- Freshness / replay: none; `edit_message_in` has no `edited_at` ordering (F8). A relay that saw a plaintext PublicChannelEdit #1 can replay it after #2 and revert the text on every receiver.
- Absent fields: `sig`/`pk` absent -> reject. `sid`/`cid` absent -> MLS still applies the edit (ownership is by row) but with NO mute check and no event; Olm treats it as a DM edit.
- Blast radius: local row; the edited row (with the author's edit sig) re-serves through sync.
- Tests: `backfill_verifies_v2_edit_and_rejects_extras_tamper` (crypto_handler.rs:4428) covers sync items; live non-author edit rejection: none found.
- SUSPICION S7 (mute keyed on the sender-supplied sid). Mallory = muted author in server S. She sends `EditMessage{mid: <her own message in S>, sid: None (or sid: <another server where she is not muted>), ...}` over MLS: `server_state` is None / the wrong server (swarm.rs:10998), the mute check passes (message_ops.rs:2558 `let Some(state) = server_state else { return false; };`), ownership passes by row (2643), and she signs the context she chose, so the edit lands on her S row. CONFIRMED-BY-READING.
- SUSPICION S11 (edit replay, low-med). PublicChannelEdit is plaintext and has no ordering; see Freshness. CONFIRMED-BY-READING.

### A-CH04 MessageEnvelope::DeleteMessage (channel)  +  HavenMessage::PublicChannelDelete

- Dispatch sites: Olm `node/swarm.rs:8032`; MLS `node/swarm.rs:11013` -> `message_ops::handle_envelope_delete_message` (`node/message_ops.rs:2814`); public `node/swarm.rs:12967`; sync batch deletions: A-CH02 step 5; fetch.rs: not handled (fetch.rs:542, 756).
- Target object: `mid`.
- State changes: `store.hide_channel_message` Olm `swarm.rs:8059`, MLS/public `message_ops.rs:2849`; event `ChannelMessageDeleted` Olm `swarm.rs:8102-8108`, MLS `message_ops.rs:2854-2860`.
- Checks, in order: store open; `swarm.rs:8039-8040` / `message_ops.rs:2828-2829` `if sender.as_deref() != Some(...)` (row sender == deleter: device on Olm, master on MLS/public); `swarm.rs:8052-8055` / `message_ops.rs:2842-2845` v2 verify `"ch-delete"` over the row's CURRENT text and extras.
- Who can sign: row author's master over `hollow-msg2:ch-delete:{sid}:{cid}:{author}:{del_ts}:{mid}:{row extras}:{current_text}`.
- Binding: row-owner compare (8040 / 2829). Moderator delete of another member's message: NOT FOUND anywhere (grep `MANAGE_MESSAGES|ModDelete|mod_delete`: no match; `crdt/operations.rs:670-677` defines no message-moderation permission; the local send path hides ANY row locally but signs as the local user, `message_ops.rs:1923-1932`, which receivers reject by the owner check).
- Transport parity: Olm owner check uses the device id -> multi-device Olm deletes never apply (fail-closed). Mute not checked on any delete (by design, message_ops.rs:2555-2556).
- Freshness / replay: hide is terminal; replay is harmless.
- Absent fields: sig/pk absent -> reject. `sid` present, `cid` absent on Olm -> row hidden, then the `DmMessageDeleted` event branch fires (8109-8116).
- Blast radius: hidden row + proof stored, re-served through sync.
- Tests: `synced_channel_deletion_rejects_unproven_hidden_flags` (test_harness.rs:13536), `synced_channel_deletion_requires_author_proof` (message_ops.rs:3046); live non-author delete: none found.
- SUSPICION S12 (event without checks when the store cannot be opened, low). The ownership and signature checks sit inside `if let Ok(store) = crate::storage::MessageStore::open(...)` (swarm.rs:8036 / message_ops.rs:2827) while the `ChannelMessageDeleted` emit is outside it (swarm.rs:8102 / message_ops.rs:2854). If the open fails, any sender's delete for any mid is forwarded to Dart unchecked (UI-only removal). PLAUSIBLE (needs an open failure).
- Note: S1(b) is a working non-author delete through the sync path.

### A-CH05 MessageEnvelope::AddReaction / RemoveReaction (channel)  +  PublicChannelAddReaction / PublicChannelRemoveReaction

- Dispatch sites: Olm add `node/swarm.rs:8118`, remove `8185`; MLS add `11020` -> `message_ops.rs:2866`, remove `11028` -> `message_ops.rs:2962`; public add `swarm.rs:12978`, remove `12989`; sync batch reactions: A-CH02 step 7; fetch.rs: not handled.
- Target object: `mid` + `emoji`; reactor = transport principal.
- State changes: `store.add_reaction` Olm `swarm.rs:8156` (key = raw DEVICE `peer_str` for channels, 8138-8142), MLS/public `message_ops.rs:2899` (key = master); `store.remove_reaction` `swarm.rs:8205` / `message_ops.rs:2981`; events `ChannelReactionAdded/Removed` when sid and cid present.
- Checks, in order:
  - add: emoji shape `swarm.rs:8121` / `message_ops.rs:2883` `valid_reaction_emoji`; mute on the WIRE sid `swarm.rs:8129-8131` / `message_ops.rs:2889`; signature `swarm.rs:8148-8150` / `message_ops.rs:2895` `reaction_sig_rejected(...)` with payload `message_ops.rs:2950` `let payload = format!("{kind}:{mid}:{emoji}:{ts}");` against the resolved master.
  - remove: signature only (`swarm.rs:8197-8199` / `message_ops.rs:2977`).
  NOT checked: reactor is a member of the message's server, can see its channel, the row exists, the row's server == wire sid.
- Who can sign: the reactor's master over `reaction:{mid}:{emoji}:{ts}` / `unreaction:{mid}:{emoji}:{ts}`.
- Binding: reactor key == signer (verify_message_signature derives the peer id from pk, crypto_handler.rs:1731-1736). Reactor -> right to react in the message's channel: NONE FOUND.
- Transport parity: stored reactor key differs (Olm device id, MLS/public master, sync `r.p` as shipped), so a removal on one transport can miss an add stored by another (functional). Per-reactor cap 3 emojis (messages.rs:3474).
- Freshness / replay: NONE FOUND. `add_reaction` is INSERT OR IGNORE with no look at `reaction_removals` (F8): a replayed old add, or a stale sync responder's copy, resurrects a removed reaction.
- Absent fields: sig/pk absent -> reject. `sid` absent -> no mute check, row still written by mid (Olm routes it as a DM reaction keyed by master, 8138-8140).
- Blast radius: reaction rows are re-served in sync (with their signatures) to all readers.
- Tests: `synced_reaction_requires_its_own_signature` (message_ops.rs:3409). Live non-member/invisible-channel reaction rejection: none found.
- SUSPICION S10 (reactions by anyone, and replay). Mallory = stranger with an Olm session (F3), or any room peer via the plaintext public twin (F1), or the relay with its own key: she adds signed reactions to any mid she knows in any channel, including restricted ones; the relay can replay a plaintext `PublicChannelAddReaction` after its removal. S7 also applies (mute dodged by omitting or swapping `sid`, swarm.rs:8129-8131 / swarm.rs:11021). CONFIRMED-BY-READING.

### A-CH06 MessageEnvelope::LinkPreviewSet (channel)  +  HavenMessage::PublicLinkPreviewSet

- Dispatch sites: Olm `node/swarm.rs:8022`; MLS `node/swarm.rs:11005`; public `node/swarm.rs:12956`; all -> `message_ops::handle_envelope_link_preview_set` (`node/message_ops.rs:2692`). fetch.rs: DM only (`node/fetch.rs:742-743` `if sid.is_none()`).
- Target object: `mid`.
- State changes: `message_ops.rs:2788` `store.update_channel_link_preview_and_sig(...)`; event 2802.
- Checks, in order: `message_ops.rs:2709` mute on the WIRE sid; store open; `2721` `let Some(sender) = store.get_channel_message_sender(&mid) else {`; `2725-2726` `let sender_master = super::resolver::resolve(&sender);` / `if !super::resolver::same_identity(&sender_master, peer_str) {` (row author vs transport principal, device-safe); `2778-2781` v2 verify with signer = row author, text = OUR row text, extras from our row + NEW digest.
- Who can sign: row author's master, `"ch"`, context = wire sid:cid.
- Binding: `message_ops.rs:2726` (row author) + signature. Sound on the live path.
- Transport parity: identical handler; `sid` absent switches to the DM branch (2734-2754).
- Freshness / replay: none (an older signed card can be re-applied); low impact because only the author's own cards verify.
- Absent fields: `lp: None` clears the card (signed). sig/pk absent -> reject.
- Tests: `late_link_preview_lands_on_recipient_and_sibling_without_marking_edited` (test_harness.rs:14266), `clearing_a_link_preview_re_signs_and_propagates` (14431) (acceptance). Rejection of a non-author live card: none found.
- SUSPICION: S7 applies to the mute check (2709) only. The live path is otherwise author-bound; the sync path is not (S1(d)).

### A-CH07 HavenMessage::ChannelSyncRequest  +  MessageEnvelope::ChannelSyncReq  (serving stored history)

- Dispatch sites: plaintext `node/swarm.rs:10525`; MLS `node/swarm.rs:11223` -> `sync_handler.rs:3266`; Olm arm ignores it (`node/swarm.rs:9153` then `9162` "Received MLS-only envelope via Olm ... ignoring").
- Target object: (`server_id`, `channel_id`) and the requester.
- State changes: RAM dedup `swarm.rs:10548` `channel_sync_sent.insert(resp_dedup_key, ...)`; outbound Olm-encrypted batch to the requester `swarm.rs:10563` / `sync_handler.rs:3299` `send_encrypted_message(...)`.
- Checks before the first state change: plaintext `swarm.rs:10533-10540` `Some(state) => super::crypto_handler::channel_readable_by(state, peer_str, &channel_id),` / `None => return,`; MLS `sync_handler.rs:3287-3294` same with the leaf `sender_peer_id`. `channel_readable_by` = `crypto_handler.rs:2062-2064` `let master = super::resolver::resolve(requester_peer_id);` / `(state.is_member(&master) || state.is_channel_public(channel_id))` / `&& state.can_see_channel(&master, channel_id)`. Principal: relay-stamped device (plaintext) or MLS leaf credential (MLS), resolved to master.
- Who can sign: unsigned (authority = transport sender). Confidentiality holds because the reply is Olm-encrypted to that same device id, so a relay spoofing `from` gets a batch it cannot decrypt.
- Binding: `channel_readable_by` first on both serving paths: CONFIRMED.
- Transport parity: identical gate.
- Freshness: 2 s per-requester dedup (RAM, 10545).
- Note (relay-visible metadata, by design): every requester sends this plaintext; `sync_handler.rs:536` `sender_timestamps: store.get_per_sender_timestamps(server_id, channel_id)` (per-author latest ts, `storage/messages.rs:2496-2498` `SELECT sender_id, MAX(timestamp) FROM channel_messages ... GROUP BY sender_id`) and `537` gap digest ride in the clear.
- Tests: `restricted_channel_history_and_files_never_reach_a_non_qualifier` (test_harness.rs:20627; injects `ChannelSyncRequest` at 20756).
- SUSPICION: none on the serving side.

### A-CH08 HavenMessage::ChannelSyncProbe  +  MessageEnvelope::ChannelProbe

- Dispatch sites: plaintext `node/swarm.rs:10574`; MLS `node/swarm.rs:11233` -> `sync_handler.rs:3307`; Olm ignored (swarm.rs:9154).
- State changes: outbound `ChannelSyncProbeResponse` (plaintext, swarm.rs:10601-10609) / Olm `ChannelProbeResp` (sync_handler.rs:3342).
- Checks: `swarm.rs:10580-10587` and `sync_handler.rs:3323-3330` `channel_readable_by(...)` first. CONFIRMED.
- Leak on the plaintext twin: the answer (`their_latest`, `msg_count`) goes back in the clear to a readable requester (relay-visible, by design).
- Tests: `restricted_channel_history_and_files_never_reach_a_non_qualifier` (probe injected at test_harness.rs:20749, refusal asserted at 20777).
- SUSPICION: none on the serving side.

### A-CH09 HavenMessage::ChannelSyncProbeResponse  +  MessageEnvelope::ChannelProbeResp  (what a response changes on the receiver)

- Dispatch sites: plaintext `node/swarm.rs:10613`; Olm `node/swarm.rs:9168`; MLS `node/swarm.rs:11243` -> `sync_handler.rs:3352`.
- State changes: RAM `channel_sync_sent.insert(dedup_key, ...)` (swarm.rs:10630, 9180, sync_handler.rs:3376) which suppresses our own sync of that channel for 5 s (10627-10628); outbound plaintext `channel_sync_request(&store, &sid, &cid, true)` to the responder (swarm.rs:10634-10637, 9181-9184, sync_handler.rs:3377-3380); plaintext twin only: `MessageSyncCompleted { server_id }` event (swarm.rs:10642) for an arbitrary server id. No store writes.
- Checks: plaintext: none (no server-known check, no sender check; only the 5 s dedup). Olm: `swarm.rs:9175` `if !server_states.contains_key(&sid) { return; }`. MLS: none (3366-3375). Nobody checks that WE sent a probe, or that the responder may read the channel.
- Who can sign: unsigned.
- Binding: NONE FOUND.
- Transport parity: Olm checks server membership of US only; plaintext and MLS check nothing.
- SUSPICION S9 (probe response pulls restricted-channel metadata out of any member). Mallory = any peer that can reach Alice (room peer, F1/F2, or the relay itself). She sends `ChannelSyncProbeResponse{server_id: S, channel_id: R (restricted), their_latest: i64::MAX, msg_count: u32::MAX}`. Alice (who can see R) answers with a plaintext `ChannelSyncRequest` carrying `sender_timestamps` = every author of R and their latest post time, plus the gap digest (sync_handler.rs:536-537), exactly the metadata the probe RESPONDER side refuses to give her (swarm.rs:10577-10579 comment). She can also keep Alice's real sync of R suppressed by repeating it every 5 s. CONFIRMED-BY-READING.

### A-CH10 HavenMessage::PublicChannelMessage  (plaintext channel message)

- Dispatch sites: WS plaintext `node/swarm.rs:12899` (from any room, F1); fetch.rs `node/fetch.rs:545` (from any 0x05/0x06/0x08 frame in the joined server room, fetch.rs:343-346, which does not pass `server_room` into `try_process_channel_msg`).
- Handler: `message_ops::handle_envelope_channel_message` (swarm.rs:12909-12915); fetch inline.
- Who can send: any peer (plaintext); the relay can inject with any `from` but must hold the key `resolve(from)` resolves to, i.e. a relay-created identity works.
- Checks, in order: `swarm.rs:12900` `if peer_str == local_peer_str { return; }`; `12908` `let sender_master = super::resolver::resolve(peer_str);`; then A-CH01 MLS/public checks (conference guard, signature, moderation only if the sid is known). NOT checked: `state.is_channel_public(&server_id...)` (the channel is never verified to be public in OUR CRDT), membership, `can_see_channel`, `can_post_in_channel`, that the frame arrived in S's room. fetch.rs: signature only (569-574) + `clip_text` (575).
- State changes: A-CH01 (row + card + event); guests only: `FileHeaderReceived` from `file_meta` when `server_states.get(&server_id).is_none() && guest_rooms.contains(&server_id)` and `file_id.as_deref() == Some(fm.fid.as_str())` (12920-12923).
- Binding: NONE FOUND (signature binds author and context only).
- Transport parity: identical to the MLS path in the full node; fetch.rs has no moderation at all.
- Freshness: mid dedup (mid is required on this wire type, `Some(mid.clone())` 12913).
- Tests: `public_channel_message_from_multidevice_sender_attributes_to_master` (test_harness.rs:2283, acceptance). Rejection of a public frame for a non-public channel / non-member: none found.
- SUSPICION S3 (plaintext injection into ANY channel of ANY server). Mallory = stranger who knows server id S (e.g. from an invite link), joins S's room as a guest (F2), and broadcasts `PublicChannelMessage{server_id: S, channel_id: <private or admin-only channel>, ...}` signed with her own key. Every online member stores it in that channel (message_ops.rs:2603) and it is re-served in their syncs; a mobile member whose push-fetch node is in S's room stores it too (fetch.rs:576). Kicked/banned users can do the same. The relay can do it with an identity it creates. CONFIRMED-BY-READING.

### A-CH11 HavenMessage::PublicChannelEdit / PublicLinkPreviewSet / PublicChannelDelete / PublicChannelAddReaction / PublicChannelRemoveReaction

- Dispatch: `node/swarm.rs:12945`, `12956`, `12967`, `12978`, `12989`; each resolves `peer_str` and calls the shared handler (A-CH03, A-CH06, A-CH04, A-CH05). Each starts with `if peer_str == local_peer_str { return; }`.
- Channel verified public in OUR CRDT before storing: NONE FOUND on all five.
- Authority: row authorship + signature for edit / card / delete (sound on the live path); signature only for reactions (S10).
- Replay: plaintext, so the relay holds every frame: S11 (edit revert), S10 (reaction resurrection).
- `server_states.get(&server_id)` is used only for the mute lookup; `server_id` is sender-controlled (S7).

### A-CH12 HavenMessage::PublicChannelListRequest  (serve the public channel list)

- Dispatch: `node/swarm.rs:13002`. Checks: `13004` `if let Some(state) = server_states.get(&server_id) {`; `13006` `.filter(|ch| ch.effective_public())`; responds only when at least one public channel (13013). State changes: outbound plaintext `SendDirect` to the requester (13031-13035) with server name, avatar and banner THUMB (13019-13021). Who may ask: anyone (by design). SUSPICION: none.

### A-CH13 HavenMessage::PublicChannelSyncRequest  (serve public history to guests)

- Dispatch: `node/swarm.rs:13041`. Checks: `13043` known server; `13044` `if !state.is_channel_public(&channel_id) { return; }` (voice excluded via `effective_public`, server_state.rs:1587-1589); 2 s per-requester dedup (13046-13050). State changes: RAM dedup; outbound plaintext `PublicChannelSyncResponse` (13167-13171) with up to 50 rows, reactions, file metadata (no AES key in `SyncFileMetaItem`, types.rs:4002-4024), sender nicknames/display names and avatar thumbs (13138-13156).
- Binding: `is_channel_public` first: CONFIRMED.
- SUSPICION S13 (deleted text served to strangers, low). `storage/messages.rs:2213-2217` (`get_channel_messages_before`) has no `hidden_at IS NULL` filter, and the item carries `t: m.text.clone()` (swarm.rs:13114) next to `hidden_at` (13123). Any guest, and the relay (plaintext), receives the full text of messages the author deleted; only the guest UI hides them. CONFIRMED-BY-READING (whether this is an accepted "evidence must sync" choice for strangers is a policy question; the member-side query documents it at messages.rs:2173-2174).

### A-CH14 HavenMessage::PublicChannelListResponse  (guest side)

- Dispatch: `node/swarm.rs:13178`. Checks: self (13179), `13180` `if !guest_rooms.contains(&server_id) { return; }`, banner thumb size cap `13195` (`> 80_000`). State changes in Rust: event `PublicChannelListReceived` only (13200); no store write. Unsigned: any room peer or the relay can supply server name, avatar and channel list. Dart persistence: NOT VERIFIED (out of Rust scope).
- SUSPICION S17 (low): unauthenticated server identity shown to guests. PLAUSIBLE.

### A-CH15 HavenMessage::PublicChannelSyncResponse  (guest side)

- Dispatch: `node/swarm.rs:13205`. Checks: self, `13207` `guest_rooms` membership; per item `13218` `message_ops::guest_item_accepted` (signer = `resolve(&m.s)`, `message_ops.rs:219-223`); hidden flag only with the author's proof (`13221`, `message_ops.rs:238-261`); reactions `13226` `sync_reaction_accepted`; file card only when `m.file_id.as_deref() == Some(fm.fid.as_str())` (13239). State changes: event only (13274); no store write in Rust.
- Not checked: that the item's author is a member of the server, that the channel is public (guests hold no state). `sender_profiles` (names, avatars) are unsigned and taken verbatim (13270-13273).
- SUSPICION S17 (low): any responder, or the relay, can label a validly signed item with any display name/avatar in the guest view, and serve rows from non-members. PLAUSIBLE.

### A-CH16 HavenMessage::PublicChannelConfigChanged  (guest side)

- Dispatch: `node/swarm.rs:13279`. Checks: self, `13281` `guest_rooms`. State change: event only (13282-13284). Unsigned; the relay can flip a channel's public flag/name in a guest's browser. Dart persistence NOT VERIFIED. SUSPICION: S17 (low).

### A-CH17 HavenMessage::ChannelNotificationHint

- Dispatch: `node/swarm.rs:13323`; not handled in fetch.rs (`_ => None`, 591).
- Checks: `13326` `if super::resolver::same_identity(peer_str, local_peer_str) { return; }` only. Unsigned; no membership, no server-known check, `reply_to_sender` is sender-controlled (13332-13334).
- State changes: event `ChannelNotificationHint` (13335-13337). Dart (`lib/src/core/providers/event_provider.dart:1115-1127`) turns it into an unread entry and, with `has_everyone`, a mention: `final isMentioned = hasEveryone ||` ... `ref.read(unreadProvider.notifier).onChannelMessage(`.
- SUSPICION S15 (low). Mallory = any room peer or the relay: fake unread/mention badges for any server/channel id; `messageId` is recorded in `_processedChannelMessageIds` (event_provider.dart:1124). CONFIRMED-BY-READING (Rust + Dart handler).

### A-CH18 HavenMessage::TypingIndicator  +  MessageEnvelope::Typing

- Dispatch: plaintext `node/swarm.rs:13341`; MLS `node/swarm.rs:11172` -> `social::handle_envelope_typing` (`node/social.rs:1819-1829`, emits unconditionally); Olm ignored (swarm.rs:9151).
- Checks: plaintext `13345` `if super::resolver::is_revoked(peer_str) {` only; MLS none (sid not bound to the group, F4).
- State change: event `TypingStarted` (13356, social.rs:1825). Ephemeral.
- SUSPICION S16 (low): any room peer / relay / member of any shared MLS group can show "X is typing" in any channel id. CONFIRMED-BY-READING.

### A-CH19 MessagePinned / MessageUnpinned consumption (ingest side only)

- These are CRDT ops, admitted by `admit_remote_op` (`node/swarm.rs:6162`) with `crdt/server_state.rs:1345-1347` `CrdtPayload::MessagePinned { .. } | CrdtPayload::MessageUnpinned { .. } => { (sender_perms & Permission::MANAGE_CHANNELS) != 0 }` (op authorisation belongs to the CRDT reviewer).
- Apply: `crdt/server_state.rs:871-876` pushes `message_id` into `pinned_messages[channel_id]`; event `node/swarm.rs:6305-6318`. No channel row is written; no check that `message_id` exists or belongs to `channel_id` (NONE FOUND). Dart `applyPin` (event_provider.dart:1148). No channel-content suspicion from the ingest side.

---

## Suspicion index

- S1 swarm.rs:7146-7172, 7179-7202 / sync_handler.rs:3525-3543, 3548-3552, 3606-3610: sync item's own signer rewrites EXISTING rows (re-attribution, text overwrite, phishing card, then self-signed deletion of someone else's message). HIGH, CONFIRMED-BY-READING.
- S2 swarm.rs:7082-7137 / sync_handler.rs:3387-3431: ChannelSyncBatch accepted from any Olm peer or any MLS group member, unsolicited, for any sid/cid; no batch-sender membership or readability check; backfill skips mute/slow/media/posting. HIGH, CONFIRMED-BY-READING.
- S3 swarm.rs:12899-12915, fetch.rs:545-580: PublicChannelMessage stored for ANY channel with no is_channel_public/membership/visibility check; guests and the relay can post into private channels. HIGH, CONFIRMED-BY-READING.
- S4 swarm.rs:10888-10995 + message_ops.rs:2372-2445: MLS inner sid/cid not bound to the group; no membership/visibility check; restricted-channel and cross-server (incl. conference group) injection. HIGH, CONFIRMED-BY-READING.
- S5 message_ops.rs:964 (send only), no ingest caller of can_post_in_channel: posting restrictions unenforced by receivers on every transport. MED, CONFIRMED-BY-READING.
- S6 swarm.rs:6970-7081, fetch.rs:492-529: Olm live channel message and push-fetch skip mute/slow/media-only. MED, CONFIRMED-BY-READING.
- S7 swarm.rs:7920-7922, 8129-8131; message_ops.rs:2637, 2709, 2889 (state from wire sid at swarm.rs:10998, 11006, 11021, 12949, 12960, 12982): mute bypass by omitting or swapping `sid`. MED, CONFIRMED-BY-READING.
- S8 message_ops.rs:2536-2542: slow mode judged on the sender's own `ts`. MED, CONFIRMED-BY-READING.
- S9 swarm.rs:10613-10637, 9168-9186; sync_handler.rs:3352-3381 (+536-537): unsolicited probe responses make any member disclose per-author watermarks of restricted channels in plaintext and suppress its sync. MED, CONFIRMED-BY-READING.
- S10 swarm.rs:8118-8160, message_ops.rs:2866-2903, storage/messages.rs:3481: reactions from non-members / on invisible channels; removed reactions resurrect on replay. LOW-MED, CONFIRMED-BY-READING.
- S11 storage/messages.rs:3181-3203 (+ swarm.rs:12945): no edit ordering; relay replays an old plaintext edit to revert text. LOW-MED, CONFIRMED-BY-READING.
- S12 swarm.rs:8036/8102-8108, message_ops.rs:2827/2854-2860: delete event emitted without checks when the store fails to open. LOW, PLAUSIBLE.
- S13 swarm.rs:13055-13058, 13114; storage/messages.rs:2213-2217: deleted messages' text served in plaintext to guests/relay. LOW, CONFIRMED-BY-READING.
- S14 swarm.rs:7207-7219, sync_handler.rs:3621-3633, file_handler.rs:206-207: sync file_meta not bound to the signed file_id; file cards attributed to anyone. LOW, write CONFIRMED, UI PLAUSIBLE.
- S15 swarm.rs:13323-13338 (+ event_provider.dart:1115-1127): unauthenticated notification hints create unread/mention badges. LOW, CONFIRMED-BY-READING.
- S16 swarm.rs:13341-13360, 11172-11176: typing indicators unauthenticated / unbound. LOW, CONFIRMED-BY-READING.
- S17 swarm.rs:13178-13202, 13270-13273, 13279-13284: guest-side list/profiles/config unauthenticated. LOW, PLAUSIBLE.
- S18 message_ops.rs:2372-2445 and both sync paths vs swarm.rs:7018 / fetch.rs:524: 4,000-byte text clamp only on Olm live + fetch. LOW, CONFIRMED-BY-READING.

Not found (asked for, looked, absent): moderator delete of another member's message (grep `MANAGE_MESSAGES|ModDelete|mod_delete` in src: no match; operations.rs:670-677); any ingest-side call of `can_post_in_channel` or `can_see_channel` on channel content; any compare of an MLS envelope's inner `sid` with the decrypting group; any check that a ChannelSyncBatch or probe response answers a request we sent.
