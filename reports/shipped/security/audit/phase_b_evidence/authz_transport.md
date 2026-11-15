# Authorisation matrix, area: TRANSPORT PARITY

Push background node (`node/fetch.rs`), iOS NSE (`push_enrich.rs`), channel push (0x09),
gossip (`node/gossip.rs`, `node/gossip_relay.rs`), `node/proxy_tunnel.rs`, and the swarm
pre-dispatch (`WsEvent::Message|DirectMessage`, `WsEvent::BinaryDirect`).

SNAPSHOT WARNING. The tree was being edited while I read it: HEAD `b009e9a0` plus
UNCOMMITTED working-tree edits for HOL-SEC-003 (PreKey identity signature) in `fetch.rs`,
`swarm.rs`, `crypto_handler.rs`, `types.rs`, `olm_manager.rs`, `message_ops.rs`,
`test_harness.rs`. Every line number below was re-grepped against the working tree at the
end of the session. The swarm.rs hunk shifted everything after line 571 by +1 and after
line 6712 by +9 relative to HEAD; if the other session keeps editing, lines will drift again.

All paths are relative to `rust/hollow_core/src/` unless marked otherwise.

---

## 0. Process setup shared by every fetch-node arm

### A-T00 `api::network::start_fetch_node` / `push_enrich::fetch_and_decrypt` (process bootstrap)
- Dispatch sites: FCM/UnifiedPush background isolate via Dart `startFetchNode`
  (`lib/src/core/services/push_notification_service.dart:483` DM, `:797` channel);
  iOS NSE via `hollow_push_fetch_and_decrypt` (`ios/NotificationService/NotificationService.swift:108` DM, `:186` channel).
- Handler: `start_fetch_node` `api/network.rs:2680`; `fetch_and_decrypt` `push_enrich.rs:153`; both call `node::fetch::run_fetch` (`api/network.rs:2828`, `push_enrich.rs:253`).
- Target object: the relay room the push payload names. DM: `fetch_room_code` `node/fetch.rs:154-165` joins `dm_room_code(local_master, resolve(sender_peer_id))`; channel: `Some(s) => s.to_string()` (`fetch.rs:156`), i.e. the raw `server` string from the push payload (relay-controlled).
- State set up before any frame is read:
  - resolver warmed from DB: `node::resolver::warm_from_links(&links);` `api/network.rs:2771`; `seed_self` `:2775`. NSE: `push_enrich.rs:212`, `:215`.
  - auto-download config loaded from settings: `load_auto_download_conf_from_settings(db_path, db_passphrase);` `fetch.rs:72` (fn `fetch.rs:1199-1221`).
  - at-rest key ring: `node::at_rest::init(&db_path, &passphrase)` `api/network.rs:2742` (NSE does NOT call it; `at_rest::ensure_ready` lazily inits, `node/at_rest.rs:87-106`, fails closed).
  - MLS: network.rs restores server group + subgroups (`group_keys.push(crate::crypto::subgroup_id(room, &cid));` `api/network.rs:2801`); NSE restores ONLY `&[room.to_string()]` (`push_enrich.rs:233`), so restricted-channel ciphertext is skipped on iOS (fails closed).
- **Block list is NEVER warmed in the fetch process.** The only warm call in the crate is `super::blocklist::warm(&blocked);` `node/swarm.rs:800` (full-node startup). `start_fetch_node` (`api/network.rs:2680-2864`) and `fetch_and_decrypt` (`push_enrich.rs:153-337`) contain no `blocklist::warm`. `blocklist::is_blocked` reads a process-global set: `blocked().read().map(|s| s.contains(&master))` `node/blocklist.rs:43-46`. The FCM isolate is described as "a fresh process" (`fetch.rs:69`), the NSE is a separate process (`push_enrich.rs:3`).
- Revoked-device set: `resolver::is_revoked` reads RAM `REVOKED` (`node/resolver.rs:146-151`), never warmed in fetch (and not persisted in the full node either).
- Tests: none found for `start_fetch_node`, `run_fetch`, or any fn in `fetch.rs` (`fetch.rs` has 0 `#[test]`; no reference to `fetch::` from `test_harness.rs`). `push_enrich.rs` has two positive-path unit tests (`push_enrich_forked_decrypt_existing_session`, `push_enrich_forked_decrypt_first_contact`).

---

## 1. `node/fetch.rs` ingest arms, compared with the live node

Frame intake in fetch:
- Text frames: every text frame first goes to `handle_kill_frame` (`fetch.rs:110`), then `handle_text_frame` (`fetch.rs:116`).
- Binary frames: `handle_binary_frame` `fetch.rs:313`: `0x06 | 0x05 => parse_direct_frame(&data[1..])` (`:335`), `0x08 => parse_topic_frame(&data[1..])` (`:336`); channel wake → `try_process_channel_msg` (`:344`); DM wake only `else if data[0] == 0x06` → `try_decrypt_dm` (`:349-350`). The frame's room field is discarded (`fetch.rs:425` "The room code is not needed: one room").
- Live counterpart: `ws_client.rs:511-556` maps 0x02→`BinaryDirect`, 0x05→`Message`, 0x06→`DirectMessage`, 0x08→`Message`; text frames only as `ServerMsg` (`ws_client.rs:507`).

### A-T01 relay `kill_signal` text frame (identity wipe)
- Dispatch sites: fetch text frame `fetch.rs:110` → `handle_kill_frame` `fetch.rs:227`; live `WsEvent::KillSignal` `node/swarm.rs:4420` → `destroy::handle_kill_signal` `node/destroy.rs:237`.
- Handler: fetch `handle_kill_frame` `fetch.rs:227-267`; live `handle_kill_signal` `destroy.rs:237-257` → `apply_own_order` `destroy.rs:131`.
- Target object: THIS device / identity; the order names `master_peer_id` and `targets`.
- State changes (fetch): `crate::api::wipe::destroy_data_root(&root);` `fetch.rs:252`; then `kill_ack` sent `fetch.rs:254`. Live: `NetworkEvent::DestroyReceived` emitted `destroy.rs:143-145` (Dart runs the wipe), `KillAck` only on permanent reject `destroy.rs:254-256`.
- Checks before the first state change (identical, both call `judge_own_order` `destroy.rs:100-128`):
  1. `if !verify_destroy_identity(order) { return Verdict::RejectPermanent("bad signature"); }` `destroy.rs:107-109` (signer key).
  2. `if order.master_peer_id != local_master` `destroy.rs:110` (signer must be OUR master).
  3. `if !order.targets.is_empty() && !order.targets.iter().any(|t| t == local_device)` `destroy.rs:113` (device targeting).
  4. link time: `if linked_at > 0 && order.issued_at_ms < linked_at` `destroy.rs:120` (persisted setting).
  5. `if order.issued_at_ms <= last_applied(local_device)` `destroy.rs:123` (RAM stamp).
- Who can sign: our master key (`verify_destroy_identity`, not re-read here; see crypto agent).
- Binding: `order.master_peer_id != local_master` `destroy.rs:110` plus targets `destroy.rs:113`.
- Transport parity: judge identical. Differences: fetch wipes in-process (`fetch.rs:252`) instead of emitting an event; fetch acks on unparsable blob (`fetch.rs:242-244`) like live (`destroy.rs:246-249`). `last_applied` is per-process RAM (`destroy.rs:29-34`), so the fetch and the app do not share it; freshness then rests on link time.
- Freshness: link-time stamp persisted (`destroy.rs:71-78`); `APPLIED` RAM only (`destroy.rs:24-28`, deliberate).
- Tests: `kill_signal_with_foreign_blob_is_dropped` `test_harness.rs:23841`, `destroy_refuses_signal_older_than_link_time` `:23776` (live path only).
- SUSPICION: none new.

### A-T02 `HavenMessage::Encrypted` (Olm) in the fetch node: session create/teardown
- Dispatch sites: fetch DM wake `fetch.rs:349-350` (0x06) and legacy text `fetch.rs:288-299`; live `swarm.rs:6683` (`handle_incoming_request`).
- Handler: `try_decrypt_dm` `fetch.rs:675` → `olm_decrypt_payload` `fetch.rs:770`.
- Target object: the Olm session keyed by relay-stamped `from` (sender DEVICE id).
- Checks before the first state change, fetch order:
  1. HavenMessage parse `fetch.rs:688-694` (drop + log).
  2. `if crate::node::resolver::same_identity(from, local_peer_id) {` `fetch.rs:700` (drops own siblings).
  3. `if crate::node::blocklist::is_blocked(from) {` `fetch.rs:712` (see A-T00: set is empty in this process).
  4. PreKey only: `identity_key` required `fetch.rs:782-788`; WORKING TREE adds `if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {` `fetch.rs:791` (device-signed identity key + `!key_exchange_device_unauthorized`, `node/crypto_handler.rs:625-634`).
- State changes:
  - PreKey with an existing session that fails: `olm.remove_session(from);` `fetch.rs:800` then `create_inbound_prekey_session` `fetch.rs:801`.
  - new inbound session: `olm.create_inbound_session(from, their_identity, ciphertext)` `fetch.rs:826`; `persist_crypto_state(olm, crypto_store, from);` `fetch.rs:828` (persisted, the app loads it later).
  - normal message: `olm.decrypt(...)`; on failure only logs, NO teardown (`fetch.rs:808-814`).
  - ratchet persisted after each success: `persist_olm_session(olm, crypto_store, &from);` `fetch.rs:353` / `:302`.
- Transport parity:
  - Live pins the identity key and raises a key-change alert after building a session: `super::security_alerts::note_olm_identity_key(` `swarm.rs:6748` and `:6818`. Fetch has NO `note_olm_identity_key` call (grep of `fetch.rs`: none). A session first built by the fetch node is persisted (`fetch.rs:828`) and later used by the app with no pin/alert ever recorded for that key (`note_olm_identity_key` only records on KeyBundle/PreKey, `security_alerts.rs:137-178`).
  - Live PreKey path is also gated by `verify_olm_identity` in the working tree (`swarm.rs:6714`), so parity on the new gate holds.
  - Live normal-message decrypt failure tears down the session (`let teardown_ok = ...` `swarm.rs:6916`, `olm.remove_session(&peer_str);` `swarm.rs:6921`); fetch does not.
  - Fetch's PreKey teardown at `fetch.rs:800` is RAM-only unless a later success for the same `from` is persisted.
- Freshness/replay: Olm ratchet; one-time key consumed by vodozemac (not re-read). NONE FOUND beyond that at this layer.
- Tests: `authz_olm_prekey_relay_cannot_open_a_session_as_another_device` `test_harness.rs:3233` (working tree, live path only). None for fetch.
- SUSPICION (S-02, PLAUSIBLE): fetch builds and persists an inbound Olm session without the identity-key pin/alert the live path records. With HOL-SEC-003's signature gate a relay can no longer mint a session for a KNOWN device, but a first-contact / unknown device (`key_exchange_device_unauthorized` returns false when `master == sender_device`, `crypto_handler.rs:587-589`) still lands silently, and a legitimate key change learned via push is never alerted.

### A-T03 `MessageEnvelope::DirectMessage` (DM row)
- Dispatch sites: fetch `fetch.rs:740` → `handle_direct_message` `fetch.rs:872`; live Olm `swarm.rs:7295`. (DmSyncBatch backfill is a separate arm, not in fetch.)
- Target object: DM conversation `convo = resolve(from)` `fetch.rs:708`; row keyed by `mid`.
- State changes (fetch): `store.insert(convo, msg_text, false, ...)` `fetch.rs:962`; `store.update_link_preview(message_id, &lp_json)` `fetch.rs:977`; if the mid already exists and text is not a sentinel: `store.promote_file_sentinel_to_caption(message_id, msg_text, sig, pk)` `fetch.rs:986`. Returned as a notification line.
- Checks before first write (fetch): A-T02 1-3, then signature REQUIRED: `check_backfill_signature(convo, "dm", local_master, ts, None, extras, text, sig, pk, ...)` `fetch.rs:857`, rejected unless `Valid` (`is_acceptable`, `crypto_handler.rs:1887-1893`, `REQUIRE_SIGNED_BACKFILL = true` `:1865`); pk must derive to signer (`verify_message_signature_cached`, `crypto_handler.rs:1846`). Dedup: `store.dm_message_exists(m)` `fetch.rs:955`.
- Who can sign: sender MASTER over `hollow-msg2:dm:{recipient_master}:{sender_master}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}` (`crypto_handler.rs:233-236`).
- Binding: signer = `convo` (resolved from relay-stamped `from`) `fetch.rs:857`; context = our master. The ROW being modified by the promotion is bound only by `mid`: `"UPDATE messages SET text = ?1, signature = ?2, public_key = ?3 WHERE message_id = ?4 AND text LIKE '[file:%]'"` `storage/messages.rs:1399-1400`. NONE FOUND binding the promoted row to `convo` or to `is_mine = false`.
- Transport parity (live `swarm.rs:7295-7428`):
  - live `if super::resolver::is_revoked(&peer_str) {` `swarm.rs:7311`: fetch has no revoked check (RAM set anyway).
  - live blocklist `swarm.rs:7318` against a warmed set; fetch `fetch.rs:712` against an unwarmed set (A-T00).
  - live handles own-sibling echoes with `convo` (`let convo_peer = match (is_own_device, convo.as_deref())` `swarm.rs:7321`); fetch drops them (`fetch.rs:700`).
  - live on an existing mid: `if already { is_new = false; }` (`swarm.rs:7382-7386`), NO promotion. Fetch promotes (`fetch.rs:980-990`).
  - live always emits `MessageReceived`; fetch returns a `FetchedDm` for a banner.
- Freshness: mid dedup (persisted). Signature has no timestamp window (backfill rule).
- Absent fields: `sig`/`pk` absent → `Absent` → rejected (`crypto_handler.rs:1929-1931`, `:1891`). `mid` absent → no dedup (`fetch.rs:954-956` `.unwrap_or(false)`), promotion skipped.
- Blast radius: local rows; notification shown.
- Tests: live `blocked_peer_dm_and_friend_request_dropped` `test_harness.rs:11537`. None for fetch.
- SUSPICION (S-01, CONFIRMED-BY-READING): blocked sender bypass via push. Mallory (blocked stranger/friend) DMs Alice while Alice's app is killed; the relay buffers and pushes; the fetch process has an empty block list (`swarm.rs:800` is the only warm), so `fetch.rs:712` passes and the row is stored (`fetch.rs:962`) and a banner is shown. Dart does not re-check (`push_notification_service.dart:296-365` has no block check; only `_dmPushMuted` `:369-376`). iOS NSE likewise (`push_enrich.rs:153-337`).
- SUSPICION (S-03, CONFIRMED-BY-READING): caption promotion rewrites ANY sentinel row by mid. Mallory (a friend Alice sent a captionless image to; the sender row text is `format!("[file:{}]", file_id)` `node/file_handler.rs:797-798`, persisted by `persist_sent_dm_row` `:816-820`, `is_mine` true) sends, while Alice is offline, a signed DirectMessage reusing that `mid` with arbitrary text. Fetch: `dm_message_exists` true → `promote_file_sentinel_to_caption` (`fetch.rs:986`) overwrites Alice's OWN outgoing row text + sig/pk (SQL `messages.rs:1399-1400` has no peer or is_mine filter). Live never promotes, so this is fetch-only.

### A-T04 `MessageEnvelope::EditMessage` (DM edit)
- Dispatch sites: fetch `fetch.rs:743-744` → `handle_edit_message` `fetch.rs:1051`; live Olm `swarm.rs:7924`; live MLS twin via `message_ops::handle_envelope_edit_message` (channel only).
- Target object: DM row by `mid`.
- State changes (fetch): `store.edit_dm_message(&mid, &new_text, ts, sig, pk)` `fetch.rs:1088` → `edit_message_in` SQL `UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4, updated_at = ?2 WHERE message_id = ?5` `storage/messages.rs:3201`; fallback `store.set_dm_message_edited_at(&mid, ts)` `fetch.rs:1097`. Also returned as a banner line.
- Checks (fetch): A-T02 1-3; signature required over the row's extras: `fetch_dm_sig_rejected(convo, local_master, ts, &new_text, ...)` `fetch.rs:1080` (signer = resolved sender master, context = our master; extras from our stored row `fetch.rs:1066-1079`).
- Binding: NONE FOUND between the edited row and the editor in fetch: no `get_dm_message_is_mine`, no `get_dm_message_peer` check (`fetch.rs:1051-1112`).
- Transport parity: live requires `if is_mine == Some(false) || (is_mine == Some(true) && is_sibling) {` `swarm.rs:7970` before verifying and writing. Fetch has no is_mine gate. (Both lack a check that the row's `peer_id` equals the editor's master; live only requires `is_mine == Some(false)`.)
- Freshness: none beyond the signature; an old valid edit can be replayed (edit_message_in only refuses identical text, `messages.rs:3185-3187`).
- Tests: none found for fetch; none found rejecting a DM edit of an `is_mine` row on the live path.
- SUSPICION (S-04, CONFIRMED-BY-READING): friend edits the victim's OWN message via push. Mallory received Alice's DM (so she knows `mid`, `reply_to`, `file_id`, `order_us`, `album`, preview digest), signs an EditMessage with her own master over those extras (payload `crypto_handler.rs:233-236`), sends it while Alice is offline. Fetch verifies signer = Mallory (`fetch.rs:1080`) and runs `edit_dm_message` (`fetch.rs:1088`) on Alice's `is_mine = true` row. Live would reject at `swarm.rs:7970`.
- SUSPICION (S-05, PLAUSIBLE, both transports): neither path binds a DM edit to the row's conversation; a friend who knows another conversation's row fields (mid + extras) could edit a row from Bob (`is_mine = false`). Needs knowledge of Bob's row, so low.

### A-T05 `MessageEnvelope::LinkPreviewSet` (DM card attach)
- Dispatch sites: fetch `fetch.rs:746-752` (`if sid.is_none()`) → `handle_link_preview_set` `fetch.rs:1003`; live `swarm.rs:8031` → `message_ops::handle_envelope_link_preview_set` `message_ops.rs:2683`.
- State change: `store.update_link_preview_and_sig(&mid, lp_json, sig, pk)` `fetch.rs:1041` (SQL `WHERE message_id = ?4` `messages.rs:1474-1475`).
- Checks (fetch): `if store.get_dm_message_is_mine(&mid) != Some(false) { return None; }` `fetch.rs:1017`; signature over OUR row's text and extras with the new digest `fetch.rs:1033`.
- Binding: signer = resolved sender; row bound by mid + is_mine=false + the sender must have signed the row's exact text (so he must know it). No row-peer check (same as live `message_ops.rs:2730-2746`).
- Transport parity: equivalent, except fetch ignores sibling echoes (dropped earlier) and ignores channel card sets (`if sid.is_none()`).
- Tests: `late_link_preview_lands_on_recipient_and_sibling_without_marking_edited` `test_harness.rs:14300` (live, positive). No rejection test found.
- SUSPICION: none new.

### A-T06 `MessageEnvelope::FileHeader` (inline image, DM)
- Dispatch sites: fetch `fetch.rs:753` → `handle_file_header` `fetch.rs:1116`; live Olm `swarm.rs:8241`; live MLS `file_handler::handle_envelope_file_header` (`file_handler.rs:2758`, not compared in depth).
- Target object: file id `p.fid`, extension `p.ext`, message id `p.mid`.
- State changes (fetch), in order:
  1. gated branch: `persist_inline_image(... None ...)` `fetch.rs:1132` (row + metadata, no bytes).
  2. `crate::node::at_rest::write_all(&disk_path, &plaintext)` `fetch.rs:1167` with `disk_path = final_file_path(&p.fid, &p.ext)` `fetch.rs:1166`. `write_all` replaces whatever is there: "Encrypt `plaintext` to `path`, replacing whatever is there." `node/at_rest.rs:373-375`.
  3. `persist_inline_image(... Some(&disk_str) ...)` `fetch.rs:1174` → DM row insert if sentinel sig verifies (`fetch.rs:1269-1283`), metadata only `if crate::node::file_handler::file_meta_write_allowed(&store, &p.fid, convo)` `fetch.rs:1287`, then UNCONDITIONALLY `let _ = store.mark_file_complete(&p.fid, disk_str);` `fetch.rs:1298-1300` (SQL `UPDATE files SET completed_at = ?1, disk_path = ?2 WHERE file_id = ?3` `messages.rs:5286`).
- Checks before the disk write (fetch): A-T02 1-3; `auto_download_allows(p.size, &p.name, &p.ext, &format!("dm:{convo}"), p.voice)` `fetch.rs:1127` (config loaded `fetch.rs:72`); `is_wire_file_id` / `is_wire_ext` `fetch.rs:1155-1156` (`node/file_transfer.rs:83-91`). No owner check before the write; `file_meta_write_allowed` (`file_handler.rs:201-217`) gates only the metadata upsert, AFTER the bytes are on disk.
- Binding: NONE FOUND between the header's sender and the `fid` whose bytes are written / completed.
- Transport parity (live `swarm.rs:8241-8594`):
  - live size cap `if size > max_bytes {` `swarm.rs:8279` (34 MB DM): fetch has none.
  - live `already_complete` loop breaker `swarm.rs:8365-8378`, and the inline write only runs `if !already_complete && share_ref.is_none() {` `swarm.rs:8407`: fetch has neither.
  - live DM blocklist `swarm.rs:8315-8320` (warmed): fetch `fetch.rs:712` (unwarmed).
  - live `sid` → channel context, moderation `if state.is_muted(&peer_str, now_ms) {` `swarm.rs:8293` plus media-only below it: fetch ignores `p.sid` entirely and files every header as `"dm"` (`fetch.rs:1293`).
  - live marks complete `swarm.rs:8493` also without an owner check, but only for a not-yet-complete file.
  - `file_meta_write_allowed` principal: live passes sender DEVICE `&peer_str` (`swarm.rs:8335`), fetch passes resolved MASTER `convo` (`fetch.rs:1287`); the helper resolves both (`file_handler.rs:209-210`), so equivalent.
- Freshness: none for bytes; mid dedup for the row (`fetch.rs:1275`).
- Absent fields: `inline_bytes`/`aes_key`/`aes_nonce` absent → nothing written (`fetch.rs:1123`, `:1148-1150`).
- Blast radius: local file bytes replaced; the victim's view of someone else's attachment changes.
- Tests: `forged_voice_flag_does_not_bypass_auto_download_gate` `test_harness.rs:5005` (live). None for fetch.
- SUSPICION (S-06, CONFIRMED-BY-READING): attachment substitution through push. Mallory (a friend who can DM Alice and who knows a file id Alice holds, e.g. a channel image in a server they share) sends, while Alice is offline, an Olm FileHeader with `fid = X`, the same `ext`, and `inline_bytes` = her own content under her own AES key. Fetch writes it over `final_file_path(X, ext)` (`fetch.rs:1166-1167`) and re-marks X complete (`fetch.rs:1298-1300`); the owner guard only skips the metadata. With a different `ext` the call repoints X's `disk_path` to Mallory's file. Live path is protected for already-complete files by `swarm.rs:8365/8407` but has the same gap for an INCOMPLETE file (e.g. one the auto-download gate declined), `swarm.rs:8477-8494`.

### A-T07 `HavenMessage::MlsChannelMessage` → `MessageEnvelope::ChannelMessage` (channel wake)
- Dispatch sites: fetch channel wake `fetch.rs:344` → `try_process_channel_msg` `fetch.rs:459`, arm `fetch.rs:470`; live `swarm.rs:10893` → `message_ops::handle_envelope_channel_message` `message_ops.rs:2363` (call `swarm.rs:10999`).
- Target object: outer `server_id` + optional outer `channel_id` choose the MLS group (`fetch.rs:473-476`); the row is written to the INNER `sid`/`cid` (`fetch.rs:493-496`, `:525-529`).
- State changes (fetch): MLS ratchet advance `mls_mgr.decrypt(&group_key, &ciphertext)` `fetch.rs:482`, `*mls_dirty = true` `:489` → persisted `fetch.rs:140-143`; row `insert_channel_row` `fetch.rs:525` → `store.insert_channel_message(... false ...)` `fetch.rs:656-657` (is_mine hard-coded false); preview `fetch.rs:665`.
- Checks (fetch), in order: `if !mls_mgr.has_group(&group_key)` `fetch.rs:477`; MLS decrypt (leaf credential = sender device); conference guard `fetch.rs:499`; `sender_master = resolve(&sender)` `fetch.rs:505`; signature required `fetch_channel_sig_rejected` `fetch.rs:518` → `check_backfill_signature(sender_master, "ch", &format!("{sid}:{cid}"), ...)` `fetch.rs:613-616`; mid dedup `fetch.rs:650`.
- Binding: signer = resolved MLS leaf. NONE FOUND binding outer group (`server_id`, `channel_id`) to inner `sid`/`cid` in fetch (`fetch.rs:470-539`) or live (`swarm.rs:10893-11008`, `message_ops.rs:2363-2458`). NONE FOUND for membership of inner `sid`, `can_see_channel`, or post permission on either path.
- Transport parity: live adds `live_channel_moderation_drop` (mute, media-only, slow mode) `message_ops.rs:2417` using `server_states.get(&sid)`; fetch has none (fetch has no ServerState). Live computes `is_mine` via `same_identity`; fetch stores `false`. Live checks `envelope.target()` `swarm.rs:10983` (ChannelMessage has no target, `types.rs:3824-3854`).
- Freshness: MLS generation reuse returns `Ok(None)` (`crypto/mls_manager.rs:542-546`), `decrypt` maps it to Err (`:522-523`); mid dedup persisted.
- Tests: none found for fetch.
- SUSPICION (S-07, CONFIRMED-BY-READING, both transports): cross-channel / cross-server injection by an MLS member. Mallory, a member of server S1 (or of S1's server-wide group but not of restricted channel C), encrypts under the S1 server group a ChannelMessage whose inner `sid`/`cid` names S2 or restricted C, signed with her own key over that context. Both fetch (`fetch.rs:525`) and live (`message_ops.rs:2424`) store it in S2/C attributed to Mallory. Needs verification by the MLS/channel owner; noted here because push parity reproduces it.
- SUSPICION (S-08, CONFIRMED-BY-READING): moderation trio skipped on push. A muted member's (or slow-mode / media-only violating) message delivered to an offline member via 0x09 is stored by fetch without `live_channel_moderation_drop`; the full node never re-checks (mid dedup).

### A-T08 `HavenMessage::PublicChannelMessage` (channel wake, plaintext)
- Dispatch sites: fetch `fetch.rs:545`; live `swarm.rs:12908` → `message_ops::handle_envelope_channel_message` `swarm.rs:12918`.
- Target object: `server_id`, `channel_id` FROM THE PAYLOAD (not the joined room).
- State changes (fetch): `insert_channel_row(... &server_id, &channel_id, &sender_master ...)` `fetch.rs:576`.
- Checks (fetch): `sender_master = resolve(from)` `fetch.rs:555` (relay-stamped device); signature required `fetch.rs:569`; mid dedup `fetch.rs:650`.
- Binding: NONE FOUND. No check that `server_id` equals the wake's `server_room`, that the channel is public, that the server is known, or that the sender is a member / not banned. Live: `if peer_str == local_peer_str { return; }` `swarm.rs:12909` then `handle_envelope_channel_message`, which checks conference sid `message_ops.rs:2387`, signature `:2405`, moderation `:2417`, nothing about public/membership.
- Transport parity: fetch lacks the conference guard on this arm (it is present only on the MLS arm, `fetch.rs:499`; live applies it to both via `message_ops.rs:2387`). Fetch lacks moderation.
- Tests: `public_channel_message_from_multidevice_sender_attributes_to_master` `test_harness.rs:2283` (positive). No rejection test found.
- SUSPICION (S-09, CONFIRMED-BY-READING, both transports; push path is the easier one): non-member injection into any channel. A stranger Mallory (any authed relay user; relay joins are unrestricted, `relay-uws/src/ws_handler.cpp:490-529`) signs a PublicChannelMessage with her own key naming Alice's server S and private channel C. Live: she joins room S and broadcasts; Alice's node stores it (`swarm.rs:12918` → `message_ops.rs:2424`). Push: she joins ANY room X, sends a 0x09 frame targeting Alice's device (A-T10); Alice's fetch joins X, replays, and stores the row in S/C (`fetch.rs:576`). Row is attributed to Mallory, dedup blocks later re-verification, and it may be re-served by Alice's sync responders (PLAUSIBLE, not traced).
- SUSPICION (S-10, CONFIRMED-BY-READING, low): conference sid persisted via push. `PublicChannelMessage` with `server_id = "conf:..."` is stored by fetch (`fetch.rs:545-590`, no `is_conference_sid`), violating "conference chat RAM-only".

### A-T09 legacy text frames `{"type":"direct"|"msg"}`
- Dispatch sites: fetch `fetch.rs:288-305` → `try_decrypt_dm`; live: ignored (`ServerMsg` has no such variant, `ws_client.rs:264-301`; parse failure silently dropped `ws_client.rs:507`). Relay still emits them for client text commands `relay-uws/src/ws_handler.cpp:2205-2208`, `:1525-1536`, `:1573-1580`.
- Parity: fetch-only transport, same trust as binary (relay-stamped `from`). No suspicion beyond A-T02..A-T06.

### Not handled by the fetch node (NOT FOUND in `fetch.rs`)
Searched `fetch.rs` for `device_list`, `is_revoked`, `DestroyIdentityOrder`, `CrdtOp`, `SessionAck`, `KeyRequest`, `KeyBundle`, `FriendRequest`: none. Signed device lists, device-list verification / `device_list_binds_sender`, revocation tombstones, CRDT ops, KeyRequest/KeyBundle, friend flows, DM/channel sync batches, edits/deletes/reactions in channels (`_ => None` `fetch.rs:542`, `Ok(_) => None` `fetch.rs:760`) are all ignored by fetch.

---

## 2. `push_enrich.rs` (iOS NSE)

### A-T11 `hollow_push_fetch_and_decrypt` / `hollow_push_decrypt`
- Dispatch sites: Swift NSE `ios/NotificationService/NotificationService.swift:108` (DM) and `:186-187` (channel, `sender.isEmpty ? server : sender`, `server`).
- Handler: `hollow_push_fetch_and_decrypt` `push_enrich.rs:114` → `fetch_and_decrypt` `:153` → `run_fetch` `:253`. So every A-T01..A-T09 gate and gap applies unchanged on iOS.
- READS: identity file, `messages.db` (Olm account + sessions `push_enrich.rs:193-197`, device links `:211`, MLS identity `:228`, server state + profile for names `:285`, `:300`).
- WRITES: everything `run_fetch` writes (DM/channel rows, file bytes, metadata, Olm sessions `fetch.rs:828`, MLS state `fetch.rs:142`, identity wipe `fetch.rs:252`), plus `crypto_store.save_account` `push_enrich.rs:271-273`.
- Differences from the Android fetch: no at_rest `init` (lazy, fails closed); MLS restored for the server group only (`push_enrich.rs:233`); no block-list warm (same as Android); relay domain comes from the push-hints cache keyed by the relay-supplied `sender` (`NotificationService.swift:105`, `:174-182`).
- Display: channel banner filters by channel only, `arr.filter { ($0["channel_id"] as? String) == channel }` `NotificationService.swift:218`, with a fallback to the LAST channel in the burst `:219-221`; it never checks `server_id == server` (Dart does, `push_notification_service.dart:805`).
- `hollow_push_decrypt` (`push_enrich.rs:30`) is exported but not declared in `ios/NotificationService/HollowPushBridge.h` (only `hollow_push_fetch_and_decrypt` and `hollow_push_string_free`, lines 42-50) and not called from Swift: dead export; it decrypts on a throwaway fork and persists nothing (`push_enrich.rs:341-365`), with no identity-proof gate.
- Tests: two positive unit tests in `push_enrich.rs` (see A-T00).
- SUSPICION: the S-01, S-03, S-04, S-06, S-08, S-09 gaps all apply to the NSE (app force-killed = the NSE is the sole writer, `NotificationService.swift:91-97`).

---

## 3. Channel push (0x09) and hints

### A-T10 0x09 targeted channel frame (sender → relay → offline member)
- Sender build site: `queue_offline_channel_push` `message_ops.rs:1187`, called from the channel send `message_ops.rs:917`; wire bytes are the same public plaintext or MLS ciphertext as the room broadcast (`message_ops.rs:846`). Targets: `server.members` minus reachable, `&& server.can_see_channel(p, channel_id)` `message_ops.rs:1208`; one `WsCommand::SendChannelDirect` per device `message_ops.rs:1232-1238` with `mention: mentioned`. Frame layout `[0x09][room\0][target\0][channel\0][flags:1][payload]` `ws_client.rs:1005-1022`. Only call site found for `SendChannelDirect`: `message_ops.rs:1232`.
- Relay: `handle_binary_channel_direct` `relay-uws/src/ws_handler.cpp:1448-1513`: checks `is_peer_id_shape(target_str)` `:1481`; sender in the named room `:1484-1486`; buffers when target not in room `:1502-1507` under `room_str`; pushes if fully offline `:1509-1511` via `try_channel_push_notify` `:1399-1440` (prefs level default `"all"` for unknown server `:1407-1418`; mention flag from the SENDER's frame `:1470`; debounce `:1424-1431`). Room joins are unrestricted (`handle_join` `ws_handler.cpp:490-529`: code shape and room-count only).
- Receiver: relay replays the buffered frame as 0x06 on join of that room; fetch treats it per A-T07/A-T08; live node treats it as `WsEvent::DirectMessage` (`ws_client.rs:528-533`) → pre-dispatch A-T19.
- Binding: NONE FOUND between the 0x09 room/channel and the payload's server/channel on the receiving side (fetch ignores the frame's room `fetch.rs:425`; payload names its own server `fetch.rs:545-590`).
- SUSPICION (S-11, CONFIRMED-BY-READING, low): mention spoof. `mention` bit is sender-chosen (`ws_handler.cpp:1470`), passed to the push payload (`:1438-1439`) and trusted by Dart (`push_notification_service.dart:680`, `:695`) and the NSE (`NotificationService.swift:143`, `:153`), bypassing a "mentions only" level. Any room member (or a stranger in any room) can do it.

### A-T12 push wake handling (Dart background handler + live-node nudge)
- Entry: `handlePushWake` `push_notification_service.dart:296`; channel → `_handleChannelWake` `:676`.
- DM wake: `sender` from payload (relay-controlled) `:310`; mute check `_dmPushMuted` `:337`, `:369-376`; Android live node → `nudgeLiveDmFetch` `:417` → `nudge_live_dm_fetch` `api/network.rs:2632-2654` (joins `dm_room_code(local_master, resolve(sender))` `:2645-2646`); else fetch `:483`. No block-list check anywhere in the handler.
- Channel wake: `server`, `channel`, `mention` from payload `:677-680`; local level via `getPushChannelMeta` (defaults `'all'` when the server is unknown, `:753`, `:755-761`); Android live node → `_tryLiveChannelNudge(server, channel)` `:706` → `nudgeLiveRoomJoin(roomCode: server)` `:776` → `nudge_live_room_join` `api/network.rs:2660-2672` → `NodeCommand::JoinRoom { room_code }` `swarm.rs:1271-1279`, which does `let _ = event_tx.send(NetworkEvent::RoomCleared).await;` `swarm.rs:1274` when a different room was active, sets `active_room` `:1276`, and joins. Once in the room, `RoomMembers` sends our profile to every new peer: `social::send_own_profile_to_peer(` `swarm.rs:4088` (guarded only by `synced_peers.insert`, `:4086`).
- Binding: NONE FOUND between the payload's `server` and any server we are a member of, on either the nudge (`api/network.rs:2660-2672`) or the Dart side (`push_notification_service.dart:676-716`).
- SUSPICION (S-12, CONFIRMED-BY-READING for the chain; impact PLAUSIBLE): stranger-steered room join on Android. Mallory joins any room X (open), sends a 0x09 frame with `room = X`, `target = Alice's device id`; the relay pushes `{server: X}`. Alice's backgrounded Android node joins X (`swarm.rs:1276-1278`), fires `RoomCleared` (the code comment at `swarm.rs:2708-2710` says this "would wipe the open DM chat"), becomes visible to Mallory as online, and sends Mallory its profile (`swarm.rs:4088`). The DiscoverPeers timer keeps using `active_room` (`swarm.rs:5175-5178`). A hostile relay can do the same with no 0x09 at all.

### A-T13 `HavenMessage::ChannelNotificationHint`
- Dispatch site: live only, `swarm.rs:13332` (plaintext room broadcast built at `message_ops.rs:899`).
- Handler checks: `if super::resolver::same_identity(peer_str, local_peer_str) { return; }` (own siblings) then emits `NetworkEvent::ChannelNotificationHint` `swarm.rs:13344`. Dart `event_provider.dart:1084-1127`: own-identity skip `:1091`, blocked skip `:1095-1099`, channel level `:1107-1110`, then `unreadProvider.onChannelMessage(serverId, channelId, hintMid, false, isMention: isMentioned)` `:1125-1127`.
- Binding: unsigned; NONE FOUND for sender membership or that `server_id` is the room it arrived in.
- SUSPICION (S-13, CONFIRMED-BY-READING, low): any peer in a server room (rooms are open) can inflate unread and @mention badges for any server/channel id (`has_everyone: true`).

---

## 4. Gossip overlay

### A-T14 `GossipCrdtOp` over a WebRTC data channel (type byte 0x04)
- Dispatch sites: Dart data-channel receive `lib/src/core/services/webrtc_service.dart:1213-1219` (ANY data-channel peer, not only overlay neighbours) → FFI `webrtc_gossip_op_received` `api/network.rs:4231` → `NodeCommand::WebRtcGossipOpReceived` `swarm.rs:2910` → `accept_gossip_op` `gossip_relay.rs:108-122` → `handle_incoming_request(..., &sender_peer_id, ..., HavenMessage::CrdtOpBroadcast { server_id, op_json })` `swarm.rs:2921-2967` → arm `swarm.rs:9877` → `apply_remote_crdt_op` `swarm.rs:6120`.
- Who may inject: any peer with a data channel to us; the frame needs no neighbour status. `accept_gossip_op` only size-caps (`gossip_relay.rs:112`) and dedups by `broadcast_id` if an overlay exists (`:116-120`).
- Author authentication preserved: YES. `apply_remote_crdt_op` gates on `if !server_states.contains_key(&server_id)` `swarm.rs:6145` and `state.admit_remote_op(&op)` `swarm.rs:6163` (op.author signature + clock + `op_allowed`; comment `:6158-6160`). `peer_str` (the re-flooder) is used only for a log (`if op.author != peer_str` `:6154`), re-flood exclusion (`flood_crdt_op(..., Some(peer_str))` `:6189-6190`) and echo exclusion (`if dev == peer_str { continue; }` `:6200`). I found no place on this path where the re-flooder is treated as the author.
- Dedup/replay: `broadcast_id` cache RAM 60 s (`gossip.rs:20-21`, `:387-394`, `:405-408`); op newness via op_log length (`swarm.rs:6174-6177`), op persisted `store.insert_crdt_op(&op)` `:6181` (survives restart).
- Tests: `crdt_forged_author_op_is_rejected_on_every_ingest_path` `test_harness.rs:22058` (CrdtOpBroadcast + SyncResponse; not the gossip entry itself); `crdt_signed_op_relayed_by_another_member_is_accepted` `:22260`. `webrtc_broadcast_ttl_is_clamped` `gossip_relay.rs:207-242`.
- SUSPICION: none on authentication.

### A-T15 overlay membership (who becomes a gossip neighbour)
- `RoomMembers` of a server room: `overlay.add_known_peer(pid);` `swarm.rs:3962` for every relay-listed peer (only self excluded `:3961`), `select_initial_neighbors` `:3967` → `GossipConnect` → Dart `ensureConnection(peerId)` `event_provider.dart:1497-1498`.
- `PeerJoined`: `overlay.add_known_peer(&peer_id)` `swarm.rs:3429`.
- `PeerExchange` from a current neighbour: `overlay.known_peers.insert(p.clone());` `swarm.rs:13984` (gate `if !overlay.neighbors.contains(peer_str)` `:13978`, size cap `:13972`).
- Binding: NONE FOUND for `state.is_member(resolve(pid))` on any of the three inserts.
- Flood recipients: `flood_crdt_op` sends to `connected_relay_targets` (`gossip_relay.rs:76`, `gossip.rs:464-475`) = neighbours with a live channel.
- SUSPICION (S-14, CONFIRMED-BY-READING for the missing membership check; impact PLAUSIBLE): a non-member who joins the server's relay room (open) is added as a known peer / neighbour, gets a WebRTC data channel from members, and then receives the server's CRDT ops (plaintext op JSON, `GossipCrdtOp` `gossip.rs:60-66`) and gossip file relays (`GossipRelayFile` to neighbours, `file_handler.rs:2735-2749`; bytes are AES-GCM ciphertext). Relayed PeerExchange lists let a non-member neighbour seed further non-members.

### A-T16 `WebRtcBroadcastReceived` (gossip file relay)
- Dispatch: `swarm.rs:2896-2907` (Dart-supplied `broadcast_id`, `ttl`, `origin_peer_id`, `sender_peer_id`) → `handle_webrtc_broadcast_received` `gossip_relay.rs:10-58` (TTL clamp `:26`, dedup `:31`, relays to `get_relay_targets(Some(&sender_peer_id))` `:33`). File bytes land via `handle_webrtc_transfer_complete` → `handle_completed_stream(request, &sender_peer_id, ...)` `file_handler.rs:2098-2112`; pending relay from MLS `BroadcastMeta` `file_handler.rs:3103-3129`.
- Authentication of relayed bytes: AES-GCM key from the FileHeader (`try_decrypt_file_stream`, `file_handler.rs:2347`); `handle_file_stream_complete` does not compare `sender_peer` to `pfs.sender` (`file_handler.rs:2337-2347`). The re-flooder is used as the early-arrival sender (`file_handler.rs:2340`).
- SUSPICION: none beyond A-T15.

---

## 5. `node/proxy_tunnel.rs`

### A-T17 anti-censorship tunnel
- No remote ingest found. Config comes only from local settings: `set_proxy_config` `api/network.rs:1449-1477`, fed by `ProxyConfigNotifier` from the local DB (`lib/src/core/providers/settings_provider.dart:897-927`). No deep-link/invite path found (grep for `setProxyConfig` in `lib/src`: only `settings_provider.dart:918`).
- It spawns `shoes` with a YAML built by `format!` from those fields (`proxy_tunnel.rs:68-95`, spawn `:143-155`), writes `shoes-client.yaml` and `shoes.pid` in the data dir (`:129-135`, `:221-225`), and at startup kills the PID read back from `shoes.pid` (`sweep_orphan` `:236-246`, `taskkill /PID <pid> /F /T` `:254-259`, `kill -9` `:265-267`).
- Opens nothing on behalf of a remote peer: the SOCKS listener is `127.0.0.1` (`:71`, `:168`).
- SUSPICION: none remote. Local note only: a stale `shoes.pid` whose PID was recycled makes the next start kill an unrelated process tree (`proxy_tunnel.rs:236-260`); not attacker-reachable over the network.

---

## 6. Swarm pre-dispatch

### A-T18 `WsEvent::Message` / `WsEvent::DirectMessage` (`swarm.rs:4561-4940`)
Source: 0x05 room broadcast, 0x06 direct/offline replay, 0x08 topic (`ws_client.rs:521-552`). `room` and `from` are relay-stamped.
Order of decisions before `handle_incoming_request`:
1. UTF-8: `let utf8 = String::from_utf8(data);` `swarm.rs:4566`; failure logged "not UTF-8 ... dropped" `:4568`.
2. Parse: `serde_json::from_str::<HavenMessage>(&text)` `swarm.rs:4571` (internally tagged, `#[serde(tag = "type")]` `types.rs:1373`); failure logged "failed HavenMessage parse — dropped" `:4573` and again "Failed to parse HavenMessage from {from} in {room}" `:4937`. DROPPED, not rendered.
3. Rate limit per relay-stamped `from`: token bucket `swarm.rs:4577-4597`, `RATE_LIMIT_BURST = 100`, `RATE_LIMIT_REFILL = 20` per second (`swarm.rs:1168-1169`); over limit → "Rate limited WS peer" and `continue` `:4595-4596`.
4. Recovery-pool intercept `let is_recovery = matches!(msg, ...)` `swarm.rs:4601-4609`, handled only if `recovery_pool_state` is Some (`:4611`), then `continue; // Don't pass to handle_incoming_request.` `:4838` (see A-T19).
5. Share intercept `let is_share = matches!(msg, ...)` `swarm.rs:4844-4850` → `share_handler::handle_envelope_share_*` (`:4854-4877`), then `continue;` `:4881`.
6. Everything else → `handle_incoming_request(...)` `swarm.rs:4888`, `peer_str = &from` (`:4921`), request `msg` (`:4934`).
- NOT FOUND in this arm: block-list check (blocks live inside individual handlers, e.g. `swarm.rs:7318`, `:8317`, `:12125`-region FriendRequest), any use of `room` for routing or authorisation (only in logs `:4568`, `:4937`), JSON `"type"` routing by string (routing is the serde tag), VC-signal handling (VC signals go through `handle_incoming_request`, which receives `&mut vc_signal_rate_tokens` `:4916`), and any byte-size cap (the frame length is only logged; the relay's `maxPayloadLength` is the bound).
- `handle_incoming_request` itself starts directly with `match request {` `swarm.rs:6507` (fn at `:6437`) (no common gate).
- Envelope parse failure INSIDE Olm (distinct from step 2): in the `Encrypted` arm, a decrypted body that does not parse as `MessageEnvelope` is rendered as a DM: `Err(e) => {` `swarm.rs:9421`, "Legacy raw-text DM (backward compatible). No signature available" `:9428-9429`, `.send(NetworkEvent::MessageReceived { from_peer: peer_str.to_string(), text, ... signature: None, public_key: None, ... })` `:9434-9448`. No block-list, no revoked check, `from_peer` is the raw DEVICE id, not stored in Rust. Fetch DROPS the same case (`fetch.rs:757` "failed MessageEnvelope parse ... dropped").
- SUSPICION (S-15, CONFIRMED-BY-READING): unsigned DM bypass on the live node. Any peer that holds an Olm session with Alice (a blocked friend included: the Olm layer never consults the block list) sends a non-JSON plaintext; Alice's node emits `MessageReceived` with no signature and no block check (`swarm.rs:9421-9448`), defeating both "a DM whose signature does not verify is DROPPED" (`swarm.rs:7326` comment) and the block guard. Transport parity: fetch drops it.
- SUSPICION (S-16, CONFIRMED-BY-READING, availability): garbage normal-type Olm frames still tear down a working session. Relay (P-01) injects `Encrypted { message_type: 1, body: <junk> }` with `from = Bob's device`; `olm.decrypt` fails, `teardown_ok` (5 s throttle) → `olm.remove_session(&peer_str)` `swarm.rs:6916-6921`, forcing a re-handshake. The working-tree HOL-SEC-003 gate covers only `message_type == 0` (`swarm.rs:6714`). Same class as the KeyRequest reset the code signs against (`swarm.rs:6509-6513` comment). Fetch does not tear down (`fetch.rs:808-814`).

### A-T19 recovery-pool intercept (`swarm.rs:4601-4838`)
- Who: any `from` in ANY room (the arm never compares `room` to `pool.room_code()`; `room_code()` = `format!("recovery:{}:{}", self.server_id, self.token)` `node/recovery_pool.rs:240-241`).
- State changes without authentication: `RecoveryHello` adds `from` as a member if `server_id == pool.server_id` (`swarm.rs:4613-4622`); `RecoveryWelcome` adds `from` with no server check (`:4670-4678`); `RecoveryManifestSync` inserts sender-supplied manifest metadata (`:4744-4758` region); `RecoveryStop` sets `recovery_pool_state = None` and leaves the room (`:4732-4739`); `RecoveryTransferPlan` registers pending shard streams for `dest_peer == local_peer_str` (`:4771`) and, for `source_peer == local_peer_str` (`:4794`), reads `cs.read_shard_unchecked(&pool.server_id, &sk)` (`:4796`) and streams it to the plan's `&assignment.dest_peer` via `ws_stream_send` in the pool room (`:4806-4809`).
- Binding: NONE FOUND for sender membership, pool token, or arrival room.
- Tests: `recovery_pool_membership_forms` `test_harness.rs:6053` (positive).
- SUSPICION (S-17, CONFIRMED-BY-READING, bounded): while Alice runs a recovery pool, any peer sharing any room with her (or the relay) can stop it (`:4732-4736`) or push a transfer plan that makes her send shards to a chosen `dest_peer`; delivery still needs `dest_peer` to be in the pool room (relay target check `relay-uws/src/ws_handler.cpp:1628-1629`), and the relay itself can see the token in the room name.

### A-T20 `WsEvent::BinaryDirect` (0x02 stream chunks, `swarm.rs:4386-4418`)
- Order: `ws_stream_receive(&mut pending_ws_transfers, &data)` `swarm.rs:4387`; on completion, `if declined_file_ids.contains(&completed.id)` → delete temp + `FileFailed` `:4393-4402`; else `file_handler::handle_completed_stream(completed, &from, ...)` `:4404-4416`.
- NOT FOUND here: rate limit (the bucket is only in the Message arm), block-list, room check, size cap. `ws_stream_receive` reads `total_size` from the first chunk (`ws_stream_transfer.rs:346`) with no cap, keys reassembly by `id` only (`pending.get_mut(&id)` `:321`, `:370`), not by sender, and writes to `files_dir()/.ws_recv_{id}.tmp` (`:387`) after `parse_id` allowlisting (`:315`, `:342`).
- Downstream sender use: LinkSnapshot kind needs a matching `pending_link_snapshots` entry (`file_handler.rs:2275-2284`) but does not compare `sender_peer` to the expected linking device; it stashes the blob and acks `sender_peer` (`:2290-2306`). File kind relies on AES-GCM (`:2347`); an early arrival stores `sender_peer` (`:2340`).
- SUSPICION (S-18, CONFIRMED-BY-READING, availability): any peer in any shared room can (a) stream an unbounded `total_size` to fill disk, (b) append continuation chunks into another sender's in-flight transfer with the same `id` (corrupting it; GCM then fails), with no rate limit on this arm.

### A-T21 other frames that bypass `handle_incoming_request`
- Relay text `ServerMsg` (`ws_client.rs:264-301`) → `handle_server_message` `ws_client.rs:1215-1319` → `WsEvent::{PeerJoined, PeerLeft, RoomMembers, PeerStatus, DiscoveredPeers, TurnCredentials, MediaForwarderInfo, Nickname*, LinkCode*, KillSignal}`; `Error` "Too many rooms" → `RoomCapHit` (`:1257-1271`); `AuthOk/AuthFailed/KillDeposited` swallowed (`:1311-1315`). All relay-authored (P-01 controls them).
- Unknown binary opcodes (anything but 0x02/0x05/0x06/0x08) dropped: `_ => {}` `ws_client.rs:553`.
- Non-`ServerMsg` text (including relay `{"type":"direct"}` / `{"type":"msg"}`) silently dropped by the live client (`ws_client.rs:507`) but processed by fetch (A-T09).
- In-process sources that call `handle_incoming_request` with a Dart-supplied `peer_str`: `WebRtcGossipOpReceived` `swarm.rs:2910-2968` (A-T14).

---

## SUSPICIONS (summary)

- S-01 CONFIRMED-BY-READING: fetch/NSE never warm the block list (only `node/swarm.rs:800`), so `fetch.rs:712` passes blocked senders; rows stored `fetch.rs:962`, banner shown (Dart `push_notification_service.dart:296-365` has no block check).
- S-02 PLAUSIBLE: fetch builds + persists Olm sessions (`fetch.rs:826-828`) without `note_olm_identity_key` (live `swarm.rs:6748`, `:6818`); key changes first seen via push are never alerted.
- S-03 CONFIRMED-BY-READING: `promote_file_sentinel_to_caption` (`fetch.rs:986`, SQL `storage/messages.rs:1399-1400`) lets a friend overwrite ANY `[file:..]` row by mid, including the victim's own sent row; fetch-only.
- S-04 CONFIRMED-BY-READING: fetch DM edit has no `is_mine` gate (`fetch.rs:1051-1112`; live `swarm.rs:7970`); a friend edits the victim's own message via push.
- S-05 PLAUSIBLE (both): DM edits are not bound to the row's conversation (`swarm.rs:7970`, `fetch.rs:1088`).
- S-06 CONFIRMED-BY-READING: fetch FileHeader overwrites any known file id's bytes and re-marks complete (`fetch.rs:1166-1167`, `:1298-1300`); no `already_complete` (live `swarm.rs:8365`, `:8407`), no size cap (live `:8279`); live has the same gap for incomplete files (`swarm.rs:8477-8494`).
- S-07 CONFIRMED-BY-READING (both): MLS ChannelMessage inner `sid`/`cid` not bound to the outer group (`fetch.rs:470-529`; `swarm.rs:10893-11008`, `message_ops.rs:2363-2458`); cross-server / restricted-channel injection by an MLS member.
- S-08 CONFIRMED-BY-READING: push path skips the moderation trio (`message_ops.rs:2417` has no fetch twin).
- S-09 CONFIRMED-BY-READING (both): PublicChannelMessage has no public/membership/ban/room binding (`fetch.rs:545-590`; `swarm.rs:12908-12918`, `message_ops.rs:2363-2458`); a stranger can inject rows into private channels, via push with only a 0x09 frame (`relay-uws/src/ws_handler.cpp:1448-1513`).
- S-10 CONFIRMED-BY-READING (low): fetch persists PublicChannelMessage for conference sids (no `is_conference_sid` on `fetch.rs:545-590`).
- S-11 CONFIRMED-BY-READING (low): 0x09 `mention` bit is sender-controlled (`ws_handler.cpp:1470`) and trusted by Dart (`push_notification_service.dart:680`, `:695`) and the NSE (`NotificationService.swift:143`).
- S-12 CONFIRMED-BY-READING (chain), PLAUSIBLE (impact): push `server` field steers the Android live node into any room (`push_notification_service.dart:776` → `api/network.rs:2660-2672` → `swarm.rs:1271-1279`), firing `RoomCleared` and sending our profile to that room's peers (`swarm.rs:4086-4093`).
- S-13 CONFIRMED-BY-READING (low): `ChannelNotificationHint` is unsigned and not membership-gated (`swarm.rs:13332-13348`, Dart `event_provider.dart:1084-1127`).
- S-14 CONFIRMED-BY-READING (missing check) / PLAUSIBLE (impact): gossip overlay admits non-members as neighbours (`swarm.rs:3962`, `:3429`, `:13984`), who then receive plaintext CRDT op floods.
- S-15 CONFIRMED-BY-READING: live Olm envelope-parse failure renders an unsigned, unblocked DM (`swarm.rs:9421-9448`); fetch drops it.
- S-16 CONFIRMED-BY-READING: relay-injected junk normal-type Olm frame tears down a working session (`swarm.rs:6916-6921`); HOL-SEC-003's new gate covers PreKeys only (`swarm.rs:6714`).
- S-17 CONFIRMED-BY-READING (bounded): recovery-pool intercept ignores the arrival room and sender membership (`swarm.rs:4601-4838`).
- S-18 CONFIRMED-BY-READING (availability): `BinaryDirect` has no rate limit or size cap, and reassembly is keyed by id not sender (`swarm.rs:4386-4418`, `ws_stream_transfer.rs:321`, `:346`, `:370`).
