# Authorisation matrix evidence: DIRECT MESSAGES, FRIENDS, OLM SESSIONS

Basis: every `path:line` below is for the COMMITTED tree, `HEAD = b009e9a0`
(`rust/hollow_core/src/...` unless a path says otherwise). I re-checked the
anchors with `git show HEAD:<path>`.

WORKING-TREE WARNING: while I was reading, another session edited
`crypto/olm_manager.rs`, `forwarder/signaling.rs`, `node/crypto_handler.rs`,
`node/fetch.rs`, `node/forwarder_client.rs`, `node/message_ops.rs`, `node/swarm.rs`,
`node/test_harness.rs` and `node/types.rs` (uncommitted). The edits are an
in-progress fix for HOL-SEC-003 (the PreKey identity-key hole, A-DM-03 below), and
there is an untracked `reports/planned/security/audit/findings/HOL-SEC-003.md`.
Because of this, working-tree line numbers are shifted: `swarm.rs` by +1 after 570
and +9 after about 6712, `message_ops.rs` by -9 after 715, `types.rs` by +9 after
1416, `test_harness.rs` by +182 after 3225. Anything marked "WT" is uncommitted
and still changing.

Principals, as the brief uses them: `peer_str` = the sender DEVICE id the relay
stamped (`from`). `resolve(x)` = master via `node/resolver.rs:34`. An unknown or
forgotten id resolves to ITSELF (`resolver.rs:36`
`map.get(peer_id).cloned().unwrap_or_else(|| peer_id.to_string())`).
`local_peer_str == master_peer_str` (`swarm.rs:570`
`let master_peer_str = local_peer_str.clone();`).

Common dispatch (applies to every `HavenMessage` arm below): relay binary opcodes
0x05 room broadcast, 0x06 direct and 0x08 topic broadcast become
`WsEvent::Message`/`DirectMessage` (`node/ws_client.rs:521-551`) with a
relay-supplied `from`. They all reach ONE arm, `swarm.rs:4560`
`WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } => {`.
That arm applies a per-`from` token bucket (`swarm.rs:4576-4596`), intercepts
only the recovery and share variants (`4600-4881`), then calls
`handle_incoming_request(..., &from, ...)` (`swarm.rs:4887`, `4920`
`&local_peer_str, &from, is_invisible,`). There is NO per-variant transport
filter, so any variant in this file can arrive as a room broadcast (0x05/0x08) as
well as a direct send. The only other caller of `handle_incoming_request`
(`swarm.rs:2920`, WebRTC gossip) passes only
`HavenMessage::CrdtOpBroadcast { server_id, op_json }` (`swarm.rs:2966`). No
WebRTC data-channel path delivers any variant in this file.

---

## SUSPICIONS (summary; detail in each section)

| # | file:line | one-liner | confidence |
|---|---|---|---|
| S-01 | swarm.rs:6697-6874 (and fetch.rs:773-823) | Inbound PreKey: the frame's `identity_key` is bound to `peer_str` by NOTHING; relay-minted identity key becomes "Bob's" session → DM read + full history via spoofed plaintext DmSyncRequest (HOL-SEC-003; WT fix in progress) | CONFIRMED-BY-READING (HEAD) |
| S-02 | swarm.rs:10716-10725 + S-01 | Same hole as the sibling device → spoofed plaintext `DmSiblingSyncRequest` pulls ALL conversations | CONFIRMED-BY-READING (HEAD) |
| S-03 | swarm.rs:6718-6728, 6880-6912, fetch.rs:782-787 | Unauthenticated session teardown: a garbage PreKey (HEAD) or garbage type-1 frame with spoofed `from` drops our Olm session with that device (type-1 path is NOT covered by the WT fix) | CONFIRMED-BY-READING |
| S-04 | swarm.rs:9412-9439 | Legacy raw-text fallback emits an UNSIGNED `MessageReceived` with no blocklist or revocation check (bypasses the DM signature rule and the block list); Dart notifies (event_provider.dart:360-420) | CONFIRMED-BY-READING (Rust); Dart rendering PLAUSIBLE |
| S-05 | swarm.rs:12387-12405 | FriendAccept with NO row and NO tombstone creates an "accepted" friend; with a "pending incoming" row it flips to accepted with no user consent. Stranger-reachable (inbox) and room-broadcastable (one 0x05 frame to a server room) | CONFIRMED-BY-READING |
| S-06 | swarm.rs:12531-12567, 12432-12529 | FriendRemove / FriendReject are unsigned plaintext; authority = relay-stamped `from`; relay can forge or replay an unfriend (FriendRemove has no stamp at all) | CONFIRMED-BY-READING |
| S-07 | swarm.rs:12268-12314 | Mutual auto-accept keys on relay-stamped `from`: relay forges a plaintext FriendRequest from Bob → Alice auto-accepts and sends FriendAccept → Bob's pending-incoming row flips to accepted (S-05) with no human accept on Bob's side | CONFIRMED-BY-READING |
| S-08 | swarm.rs:12125 before 12154 | Blocklist runs BEFORE the carried device-list ingest: a blocked master's never-seen device resolves to itself, passes, is then bound to the blocked master and a FriendRequestReceived is emitted | CONFIRMED-BY-READING |
| S-09 | swarm.rs:7544-7549 → messages.rs:3175/3201 | DmSyncBatch edits ANY DM row by `mid` (any conversation, sent or received). The signer is the batch sender, never the row author. Only the mid is needed (extras come from the item) | CONFIRMED-BY-READING |
| S-10 | swarm.rs:7959-7985 | Live DM EditMessage: `is_mine==Some(false)` on ANY row; signer = `resolve(peer_str)`, never the row's `peer_id`. Mallory edits Bob's row in Alice-Bob (needs mid + row extras) | CONFIRMED-BY-READING |
| S-11 | fetch.rs:1038-1086 | Push fetch-node edit has NO `is_mine` check: can overwrite our OWN outgoing rows too (parity gap vs swarm.rs:7961) | CONFIRMED-BY-READING |
| S-12 | swarm.rs:8067-8098 vs message_ops.rs:163-175 | Live DM DeleteMessage signer = `resolve(peer_str)` (unbound); the sync twin derives signer from the ROW (bound). Parity gap | CONFIRMED-BY-READING |
| S-13 | swarm.rs:8138-8160, message_ops.rs:2895-2902 | DM AddReaction (Olm, and MLS with `sid=None`) attaches to ANY `mid`, including CHANNEL messages (shared `message_reactions` table), skipping the channel mute gate (`live_muted_ingest_drop(None,..)` = false) | CONFIRMED-BY-READING |
| S-14 | message_ops.rs:2734-2794, fetch.rs:1004-1028 | DM LinkPreviewSet (Olm/MLS/fetch) attaches a card to ANY received DM row by mid and REPLACES its signature/pk with the attacker's (needs mid + text + extras) | CONFIRMED-BY-READING |
| S-15 | swarm.rs:7569-7574 → message_ops.rs:1622-1651 | DmSyncBatch grafts a card + swaps signature on ANY row by mid when the item text equals the row text (combined with S-09, only the mid is needed) | CONFIRMED-BY-READING |
| S-16 | swarm.rs:7603-7614 | DmSyncBatch `file_meta` owner check uses the ITEM-claimed `fm.sender`, not `peer_str` (live FileHeader uses `peer_str`, swarm.rs:8326) → relabel any known file_id's name/mime/size/thumb | CONFIRMED-BY-READING |
| S-17 | fetch.rs:967-979 → messages.rs:1399-1400 | Fetch node promotes ANY `[file:..]` row by mid to the attacker's caption text + signature (any conversation) | CONFIRMED-BY-READING |
| S-18 | crypto_handler.rs:586-590 + resolver.rs:119-123 | Revoked (forgotten) devices resolve to themselves and pass `key_exchange_device_unauthorized`; only DirectMessage (swarm.rs:7302) and TypingIndicator (13345) check `is_revoked`. A revoked sibling that knows every mid can re-key and drive S-09..S-15 | CONFIRMED-BY-READING (chain) |
| S-19 | see A-DM-27 table | Blocklist missing on Edit/Delete/React/Unreact/LP (DM), FriendAccept/Reject/Remove, Typing, Status, raw-text fallback, SessionAck, key exchange, MLS DM-shaped twins | CONFIRMED-BY-READING |
| S-20 | swarm.rs:11005-11034, 11172-11176 vs 11505-11510 | MLS rejects DM-only envelopes but accepts DM-shaped (`sid=None`) LinkPreviewSet, AddReaction, RemoveReaction and Typing from any server member | CONFIRMED-BY-READING |
| S-21 | swarm.rs:6546, 6556 | KeyRequest OTK minting has no cooldown when no session exists, and a captured KeyRequest replays for 300 s; OTK churn can rotate out carried-bundle OTKs | PLAUSIBLE (low) |
| S-22 | swarm.rs:10778-10784 → Dart voice_channel_provider.dart:1361-1380 | Plaintext PeerDisconnecting (relay-spoofable) makes Dart close that peer's VC PeerConnection and end a not-yet-connected call | CONFIRMED-BY-READING (Rust+Dart lines read); low (relay DoS) |
| S-23 | swarm.rs:13973-13979 | PeerExchange from a gossip neighbour inserts arbitrary peer ids (no membership check) into `known_peers` | PLAUSIBLE (low) |

---

### A-DM-01 HavenMessage::KeyRequest  (tears down our Olm session with the sender device, mints and publishes a fresh one-time key)

- Dispatch sites:
  - Plaintext HavenMessage arm `swarm.rs:6507` `HavenMessage::KeyRequest { to, ts, sig, pk } => {` (common dispatch above; room broadcast possible).
  - fetch.rs: NOT handled (`fetch.rs:759` `_ => None,` in `try_decrypt_dm`).
  - No Olm/MLS envelope twin (it is a HavenMessage only). No gossip, no data channel.
- Handler: inline in `handle_incoming_request`, `swarm.rs:6507-6568`.
- Target object: our Olm session keyed by `peer_str` (the frame names the recipient device in `to`).
- State changes, in order:
  1. `swarm.rs:6553` `olm.remove_session(peer_str);` (only when `olm.has_session(peer_str)`, 6549, and not (confirmed AND inside the cooldown), 6546).
  2. `swarm.rs:6554` `decrypt_fail_cooldown.insert(peer_str.to_string(), now);`
  3. `swarm.rs:6556` `let otk = olm.generate_one_time_key();` (`crypto/olm_manager.rs:70-80`: `generate_one_time_keys(1)` + `mark_keys_as_published()`).
  4. `swarm.rs:6559` `crypto_store.save_account(pickle);`, `6561` `persist_crypto_state(olm, crypto_store, peer_str);`
  5. `swarm.rs:6562` `key_bundle_sent_to.insert(peer_str.to_string());` (RAM, drives glare at 6619).
  6. Outbound: `swarm.rs:6563-6566` `send_message_to_peer(... signed_key_bundle(device_keypair, device_peer_id, peer_str, identity_key, otk))`, a PLAINTEXT HavenMessage (`crypto_handler.rs:2794` `let json = serde_json::to_string(&msg)`).
  - Note: the removal is RAM-only. `persist_crypto_state` saves a session only if one exists (`crypto_handler.rs:2772` `if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {`), so the old pickle stays in the DB and comes back after a restart.
- Checks before the first state change, in order:
  1. `swarm.rs:6513` `let payload = key_request_signing_payload(peer_str, device_peer_id, ts.unwrap_or(0));` then `verify_key_exchange` (6514):
     - `crypto_handler.rs:552` `if sig.is_none() && pk.is_none() {` → Unsigned.
     - `crypto_handler.rs:558` `Some(t) if t == expected_recipient => {}`: `to` must equal OUR device.
     - `crypto_handler.rs:564` `Some(t) if (key_exchange_now() - t).abs() <= KEY_EXCHANGE_SKEW_SECS => {}` (300 s, `crypto_handler.rs:423`).
     - `crypto_handler.rs:570` `if !verify_message_signature(sender_device, sig, pk, payload) {`. Inside it, `crypto_handler.rs:1734` `if derived_pid != sender_peer_str {`: the pk must derive to `peer_str`. Principal: the signer key == the relay-stamped sender DEVICE.
  2. `swarm.rs:6523` `if REQUIRE_SIGNED_KEY_EXCHANGE {` rejects Unsigned (`crypto_handler.rs:537` `= true`).
  3. `swarm.rs:6531` `if key_exchange_device_unauthorized(peer_str) {` → `crypto_handler.rs:587` `if master == sender_device {` → `return false` (unknown or forgotten device PASSES), else `592` `!super::resolver::devices_for(&master)...any(|d| d == sender_device)`. Principal: sender device vs resolver state.
  4. Cooldown `swarm.rs:6546` `if olm.has_confirmed_session(peer_str) && !cooldown_ok {` (5 s, 6543). This only applies to a CONFIRMED session.
- Who can sign: sender DEVICE key; payload `crypto_handler.rs:457` `format!("hollow-keyrequest:{sender_device}:{recipient_device}:{ts}")`.
- Binding: signer is `peer_str` (1734) and the session torn down is `peer_str`'s own (6553). Bound (a device can only reset its own session).
- Transport parity: one site.
- Freshness / replay: ±300 s timestamp only. There is no nonce and no seen-set, so a captured frame replays unlimited times inside its window, limited only by the per-`from` WS bucket (4576) and, with a confirmed session, the 5 s cooldown. RAM only; nothing survives a restart. (The WT test `authz_olm_prekey_relay_cannot_open_a_session_as_another_device`, WT test_harness.rs:3294-3300, uses exactly this replay as its first step.)
- Absent fields: `to/ts/sig/pk` are all `Option` + `#[serde(default)]` (`types.rs:1382-1394`). All absent = Unsigned = REJECT. A signature present with `to`/`ts` absent = Invalid = REJECT.
- Blast radius: local session loss (re-keys) plus one OTK published in the clear. Not irreversible.
- Tests: unit `crypto_handler.rs:3608` `key_exchange_rejects_device_outside_signed_list`, `3596` `signed_key_request_is_forward_compatible` (names; they test the helpers, not the swarm arm). No test for replay rejection (none exists; replay is accepted).
- SUSPICION:
  - S-18 (revoked device exemption): revocation calls `resolver::forget` (`crypto_handler.rs:1033` `super::resolver::forget(target_device);`, `1102`, `1463` `forget_many`, `1596`), after which `resolve(dev)==dev`, and `crypto_handler.rs:587-590` returns "not unauthorized". A revoked device can therefore run a fresh key exchange with anyone. CONFIRMED-BY-READING.
  - S-21 (low): with no session for `peer_str`, every verified KeyRequest mints an OTK (6556) with no cooldown. Any stranger can mint unlimited device identities (first contact passes 587), and the relay can replay one captured request. The published OTKs rotate older unused OTKs out of the account (vodozemac's bound is library behaviour, not verified in repo code), which can orphan carried-bundle OTKs sitting in mailboxes. PLAUSIBLE.
  - No blocklist check (S-19).

### A-DM-02 HavenMessage::KeyBundle  (builds an outbound Olm session to the sender device from its signed Curve25519 keys)

- Dispatch sites: plaintext arm `swarm.rs:6570` `HavenMessage::KeyBundle { identity_key, one_time_key, to, ts, sig, pk } => {`. Not handled in fetch.rs (`759`). No envelope twin.
- Handler: inline, `swarm.rs:6570-6680`.
- Target: new outbound session keyed `peer_str`, and our Olm key pin for `peer_str`.
- State changes, in order:
  1. `swarm.rs:6611-6614` `super::security_alerts::note_olm_identity_key(event_tx, db_path, db_passphrase, master_peer_str, &super::resolver::resolve(peer_str), peer_str, &identity_key)`. This writes the pin (`security_alerts.rs:165` / `175` `let _ = store.set_olm_key_pin(device_peer_id, identity_key);`) and, on change, an alert record (`168` `KIND_KEY_CHANGED`). Runs even if no session is built.
  2. `swarm.rs:6618` / `6637` `key_bundle_sent_to.remove(peer_str)`, `6635` / `6646` `key_request_in_flight.insert(...)`.
  3. `swarm.rs:6638` `match olm.create_outbound_session(peer_str, &identity_key, &one_time_key) {` (only if `!olm.has_session(peer_str)` 6616 and not glare-deferred 6619). This overwrites via `olm_manager.rs:99` `self.sessions.insert(peer_id.to_string(), session);`.
  4. `6641` persist; outbound `6649-6654` encrypted SessionAck; `6656-6664` drains `pending_messages` for `peer_str`; `6666` `flush_pending_sync_requests`.
- Checks before the first state change: `swarm.rs:6579-6584` rebuilds `key_bundle_signing_payload(peer_str, device_peer_id, &identity_key, &one_time_key, ts.unwrap_or(0))` and calls `verify_key_exchange` (same four checks as A-DM-01); `6591-6596` Unsigned rejected; `6601` `if key_exchange_device_unauthorized(peer_str) {`. Principal: signer key == sender device; device in its master's list (or unknown).
- Who can sign: sender DEVICE key; `crypto_handler.rs:442` `"hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}"`.
- Binding: signature binds `identity_key`+`one_time_key` to `peer_str` (1734), and the session is stored under `peer_str` (6638). Bound.
- Note: an UNSOLICITED bundle is accepted. No check that we sent a KeyRequest to `peer_str` gates 6638, so any device can plant an outbound session keyed to its own id. Not cross-principal.
- Transport parity: one site.
- Freshness: ±300 s only. A replayed bundle while we hold no session builds a session on a possibly consumed OTK (DoS only).
- Absent fields: as A-DM-01 (`types.rs:1403-1414`); `identity_key`/`one_time_key` are required strings.
- Blast radius: local session, pin row in DB.
- Tests (unit, names): `crypto_handler.rs:3459` `signed_key_bundle_verifies_for_intended_recipient`, `3481` `substituted_olm_keys_are_rejected`, `3503` `bundle_signed_by_impostor_is_rejected`, `3522` `bundle_reflected_at_third_party_is_rejected`, `3540` `stale_bundle_is_rejected`, `3565` `unsigned_bundle_is_reported_as_unsigned`, `3608` `key_exchange_rejects_device_outside_signed_list`.
- SUSPICION: S-18 applies (6601 uses the same exemption). No blocklist.

### A-DM-03 HavenMessage::Encrypted, PreKey path (message_type 0)  (creates or REPLACES our inbound Olm session for `peer_str` from an attacker-supplied identity key)

- Dispatch sites:
  - Live: `swarm.rs:6682` `HavenMessage::Encrypted { message_type, body, identity_key } => {`, PreKey branch `6697` `let plaintext = if message_type == 0 {`.
  - fetch.rs (push background node): `fetch.rs:717-732` → `olm_decrypt_payload` `fetch.rs:765-803` → `create_inbound_prekey_session` `806-823`. Reached from 0x06 frames only on a DM wake (`fetch.rs:349` `} else if data[0] == 0x06 {`) and the legacy text frame (`288` `"direct" | "msg" => {`).
  - MLS: n/a. Room broadcast (0x05/0x08) also reaches the live arm.
- Handler: inline `swarm.rs:6697-6874`; `crypto/olm_manager.rs:106-132` `create_inbound_session`.
- Target object: our Olm session keyed `peer_str` (relay-stamped), built on the frame's `identity_key`.
- State changes, in order (HEAD):
  - Existing session (`6712` `let had_existing_session = olm.has_session(&peer_str);`):
    1. `6718` `match olm.try_decrypt_prekey_with_existing(&peer_str, &ciphertext) {` (ratchet state).
    2. On failure: `6728` `olm.remove_session(&peer_str);` BEFORE the new session is known to be valid.
    3. `6729` `olm.create_inbound_session(&peer_str, their_identity, &ciphertext)` → `olm_manager.rs:128` `self.sessions.insert(peer_id.to_string(), session);`
    4. Emit `6731` `SessionEstablished`; pin `6739-6743` `note_olm_identity_key(...)`; outbound encrypted SessionAck `6746-6750`; drain `pending_messages` `6751-6758`; `flush_pending_sync_requests` `6759`.
    5. If both paths fail: `6783-6788` sends a KeyRequest; `6791` `persist_crypto_state` (does not save a removed session).
  - No existing session: `6799` `match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {`, emit `6801`, pin `6809-6813`, SessionAck `6816-6820`, drain `6821-6828`, outbound `DmSyncRequest` via `request_dm_resync_after_rekey` `6833-6836`, flush `6837`.
  - Then `6956` `persist_olm_session(olm, crypto_store, &peer_str);` and envelope dispatch (A-DM-04).
- Checks before the first state change (HEAD): only `6698-6709` (identity_key must be present, `None => { ... "missing identity_key — dropped" ... return;`) and base64 decode `6683-6695`. vodozemac internally requires the frame key to match the key inside the PreKey message and one of OUR published OTKs (library behaviour, not repo code). NOTHING checks the frame's `identity_key` against `peer_str`'s Ed25519 device key, its device list, a signed bundle, or the existing pin. The pin (`security_alerts.rs:152-177`) runs AFTER the session is built and only records an alert: `161` `Some(ref pinned) if pinned == identity_key => {}`, `162-172` on change: moves the pin and `record(... KIND_KEY_CHANGED ...)`, `173-176` first contact: `None => { let _ = store.set_olm_key_pin(device_peer_id, identity_key); }` (silent).
- Answers to the brief's questions:
  - What binds the frame's `identity_key` to `peer_str`? NONE FOUND (HEAD).
  - Is the requester's Olm identity key signed anywhere? KeyRequest payload: no (`crypto_handler.rs:457`). Device list: no; its payload is peer ids only (`crypto_handler.rs:733` `"hollow-devices:{master_peer_id}:{version}:{}:{}"`). Carried bundle: YES for the REQUESTER's key in async friending only (`crypto_handler.rs:623`, A-DM-05). The live KeyBundle signs only the RESPONDER's key (`442`). So the INITIATOR's key (the one inside every PreKey) is unsigned on every path in HEAD, and so is the accepter's key in the carried-bundle path.
- Who can sign: n/a (HEAD); authority = relay-stamped transport sender + possession of one of our OTKs. OTKs are published in the clear (A-DM-06).
- Binding: NONE FOUND.
- Transport parity: fetch.rs `773-793` has the same gap, and additionally NO pin/alert (`806-823` never calls `note_olm_identity_key`) and persists the session (`815` `persist_crypto_state(olm, crypto_store, from);`), which the full app later loads.
- Freshness / replay: OTK single use (library); no timestamp; no nonce.
- Absent fields: `identity_key: Option<String>` (`types.rs:1421`, HEAD): absent = dropped (6700-6708).
- Blast radius: confidentiality of everything we encrypt to `peer_str` from then on, plus replies to plaintext requests the relay injects in `peer_str`'s name (A-DM-19). The session is persisted (6956), so it survives a restart.
- Tests: WT-only (uncommitted) `authz_olm_prekey_relay_cannot_open_a_session_as_another_device` (WT `test_harness.rs:3233`) asserts the attack FAILS. By my reading of HEAD nothing blocks it, so it should fail on HEAD (not run, per brief). No committed rejection test.
- WT in-progress fix (uncommitted, in flux): `types.rs` WT 1416-1431 adds `identity_sig`/`identity_pk`. `crypto_handler.rs` WT 605 `olm_identity_signing_payload` = `"hollow-olm-identity:{sender_device}:{identity_key}"`, WT 625 `verify_olm_identity` = signature by `sender_device` AND `!key_exchange_device_unauthorized(sender_device)`. It is called at WT `swarm.rs:6714` before `had_existing_session`, and at WT `fetch.rs:791`. Caveat: it reuses the S-18 exemption (an unknown or forgotten device passes), and it does not touch the type-1 teardown (S-03).
- SUSPICION:
  - S-01 (CONFIRMED-BY-READING, HEAD). Mallory = hostile relay (P-01); Alice = victim; Bob = friend.
    1. The relay replays a KeyRequest Bob sent to Alice less than 300 s earlier (A-DM-01). Alice drops her session (6553) and publishes a KeyBundle with a fresh OTK (6556-6566), which the relay reads and drops.
    2. The relay crafts a PreKey on that OTK with its OWN identity key and injects `Encrypted{message_type:0, identity_key: relay_key}` with `from = Bob's device`. Alice builds the inbound session (6799), emits SessionEstablished, and sends SessionAck plus queued DMs to it.
    3. The relay injects plaintext `DmSyncRequest{since_timestamp:0, both_directions:true}` from Bob. Alice serves the whole Alice-Bob history (10686-10710) encrypted under the relay's session (`send_dm_sync_reply`, `swarm.rs:5942-5947`).
    Also: `CallSignal` over this session is accepted as Bob (`swarm.rs:9059-9063`). The only visible sign is a "key changed" alert, and only if Bob's device key was pinned before.
  - S-02 (CONFIRMED-BY-READING, HEAD): the same attack with `from = Alice's own sibling device` (in `resolver`/`devices_for`), then plaintext `DmSiblingSyncRequest`, which is gated only by `swarm.rs:10720` `if !super::resolver::same_identity(peer_str, local_peer_str) {`. It serves EVERY conversation (`10730` `let convos = store.get_dm_peer_ids();`, `10764-10773`).
  - S-03 (CONFIRMED-BY-READING): with a session present, ANY undecryptable PreKey from a spoofed `from` removes the session at `6728` before trying the new one. fetch.rs has the same at `787` `olm.remove_session(from);`.

### A-DM-04 HavenMessage::Encrypted, normal path (message_type ≠ 0), FRIEND_HANDSHAKE_SENTINEL, legacy raw-text fallback

- Dispatch sites: live `swarm.rs:6875-6953`; fetch `fetch.rs:794-801`.
- State changes:
  - Success: `6880` `olm.decrypt(...)` (ratchet); if `was_unconfirmed` (`6879`): `6884` clear in-flight, emit `6885` SessionEstablished, `6890` outbound DmSyncRequest. `6956` persist ratchet.
  - Failure: `6912` `olm.remove_session(&peer_str);` (5 s throttle `6907-6911`), `6913` persist, `6916` emit `Error`, `6924-6931` emit `MessageSyncFailed` for every server where `state.is_member(peer_str)`, `6939-6948` outbound signed KeyRequest (2 s throttle).
  - Sentinel: `6964` `if text == social::FRIEND_HANDSHAKE_SENTINEL {` → `6966` `return;` (no state beyond the session already made).
  - Envelope dispatch `6969`; on a parse `Err`: `9412-9439` emits `NetworkEvent::MessageReceived { from_peer: peer_str.to_string(), ... signature: None, public_key: None, ... }` (`9425-9438`).
- Checks: authentication = possession of the Olm session keyed `peer_str` (see A-DM-03 for who can create it). No blocklist and no `is_revoked` check anywhere between `6682` and `6969`, nor in `9412-9439`.
- Who signs: nobody. The fallback is explicitly "No signature available" (`9419-9420`).
- Binding: for the fallback, text is attributed to `peer_str` (raw device), and Dart collapses it via `identityOf` (`lib/src/core/providers/event_provider.dart:364`).
- Transport parity: fetch has no raw-text fallback (`fetch.rs:752-755` drops on `Err`), and the fetch blocklist runs at `fetch.rs:712` before decrypt. The live path has neither check for the fallback.
- Freshness: Olm ratchet (library).
- Blast radius: the fallback shows a notification-bearing bubble (Dart `event_provider.dart:365-371` `receiveMessage(...)`, `411-420` `notifyDm(...)`). No block filter in the Dart lines I read (`event_provider.dart:360-420`; `chat_provider.dart:60` `receiveMessage` signature only).
- Tests: none found for the fallback.
- SUSPICION:
  - S-03 (type-1 teardown): relay injects a garbage `Encrypted{message_type:1}` from Bob → Alice drops her Bob session (`6912`), emits `MessageSyncFailed` for shared servers, and re-keys. Unauthenticated; every 5 s. Not covered by the WT fix. CONFIRMED-BY-READING (relay DoS class).
  - S-04: any holder of an Olm session with us (a blocked friend; a revoked device that re-keyed via S-18; on HEAD the relay via S-01) sends non-JSON plaintext → UNSIGNED DM bubble + OS notification that bypasses the "unsigned DM is DROPPED" rule (7317-7357) and the block list. CONFIRMED-BY-READING (Rust); Dart rendering PLAUSIBLE.

### A-DM-05 Carried bundle (FriendRequest) session bootstrap and the FRIEND_HANDSHAKE_SENTINEL establisher

- Requester side (mint): `social.rs:96-106` reuses a cached bundle for up to `MAX_CARRIED_BUNDLE_AGE_SECS` (7 days, `crypto_handler.rs:605`); otherwise `social.rs:111` `let one_time_key = olm.generate_one_time_key();`, `117-119` `signed_carried_bundle(device_keypair, device_peer_id, target_master, identity_key, one_time_key)`. Payload `crypto_handler.rs:623` `"hollow-carried-keybundle:{sender_device}:{recipient_master}:{identity_key}:{one_time_key}:{ts}"`, signed by the DEVICE key (`642`). Sent in PLAINTEXT (`HavenMessage::FriendRequest`) and deposited to `inbox:{target_master}` (`social.rs:307-311`).
- Accepter at receive: `swarm.rs:12166` `if let (Some(bundle), Some(list)) = (carried_bundle.as_ref(), device_list.as_ref()) {` → `12167` `verify_carried_bundle(master_peer_str, list, bundle)` → `crypto_handler.rs:674-712`:
  - signature under a pk that derives to the named device (`680-687`);
  - `verify_device_list(list)` (`690`);
  - the device is not revoked (`693`) and is in `list.devices` (`696`);
  - `701` `if b.to_master != our_master {`;
  - age at most 7 days (`707`) and no more than 300 s in the future (`710`).
  If it verifies, the store write is `12180` `let key = social::in_bundle_key(&list.master_peer_id);`, `12185` `store.save_setting(&key, &json);` (KV `friendreq_in:{master}`, never deleted, `social.rs:60-65`).
- Accepter at accept (`social.rs:576-759`): `659-661` re-verify, then `672` `if reachable || rec.live_at_receipt {` skip; `691` `if olm.has_session(&device) {` skip; else `694-696` `olm.create_outbound_session(&device, &rec.bundle.identity_key, &rec.bundle.one_time_key)` and `703-706` send `FRIEND_HANDSHAKE_SENTINEL` encrypted (a PreKey to the requester).
- Requester receives that PreKey: A-DM-03 path. The ACCEPTER's identity key rides the PreKey frame unsigned (HEAD); then `swarm.rs:6964-6966` returns.
- Binding: requester key → requester device → requester master (signature + list). Accepter key → accepter device: NONE FOUND (HEAD).
- SUSPICION: the relay reads the requester's carried OTK in the plaintext FriendRequest (mailbox-buffered for days) and can pre-empt the accepter with its own PreKey `from = accepter device` (S-01 variant). PLAUSIBLE on HEAD; closed by the WT change if it lands.

### A-DM-06 One-time key publication (every `generate_one_time_key` call site)

- `swarm.rs:6556`: KeyRequest response. Published in `HavenMessage::KeyBundle` JSON, plaintext to the relay (`crypto_handler.rs:2794-2799` SendDirect of the serialised HavenMessage). Relay-visible: YES.
- `social.rs:111`: carried bundle inside a plaintext `FriendRequest`, deposited to `inbox:{target}` (`social.rs:307-311`), re-used across re-sends for up to 7 days. Relay-visible: YES (and buffered). Cap: `MAX_OUTSTANDING_FRIEND_REQUESTS = 32` (`social.rs:31`).
- `forwarder/signaling.rs:376`: forwarder lane (out of scope; listed for completeness).
- (test-only sites in `olm_manager.rs`, `push_enrich.rs`.)

### A-DM-07 Who can make us DROP an existing Olm session (`remove_session` / overwrite)

| Site | Trigger | Authentication | Principal able to trigger |
|---|---|---|---|
| `swarm.rs:6553` | KeyRequest | device-signed, ±300 s, device in its list or unknown | the device itself; relay by REPLAY within 300 s |
| `swarm.rs:6728` | PreKey undecryptable on existing session | NONE (HEAD); WT adds `verify_olm_identity` first | relay (spoofed `from`) |
| `swarm.rs:6912` | type-1 decrypt failure | NONE | relay (spoofed `from`) |
| `swarm.rs:6729`/`6799` via `olm_manager.rs:128` insert | successful inbound PreKey replaces the map entry | none on HEAD (S-01) | relay holding one of our OTKs |
| `swarm.rs:6638` via `olm_manager.rs:99` | outbound from KeyBundle | only when `!has_session` (6616) | n/a |
| `swarm.rs:5269` | `prune_stale_sessions(7 days)` | local timer | none (local) |
| `swarm.rs:6067`+`6070` `crypto_store.delete_session` | `enforce_device_revocations` | driven by device-list ingest (callers `swarm.rs:1416`, `1464`, `11200`, `13408`; other agent) | whoever can get a revocation ingested |
| `fetch.rs:787` | PreKey undecryptable (push node) | NONE (HEAD); WT adds check | relay |
| `forwarder/signaling.rs:373`, `402` | forwarder | out of scope | |

### A-DM-08 MessageEnvelope::SessionAck  (confirms our outbound session with `peer_str`)

- Dispatch sites: Olm envelope `swarm.rs:9040` `Ok(MessageEnvelope::SessionAck) => {`. MLS: ignored (`swarm.rs:11505-11510` "DM-only envelopes should never arrive via MLS"). fetch.rs: ignored (`fetch.rs:756` `Ok(_) => None,`).
- State changes: `9047` `olm.mark_session_bidirectional(&peer_str);` (`olm_manager.rs:240-242`), `9048` `key_request_in_flight.remove(peer_str);`, emit `9050` `SessionEstablished` if it was unconfirmed.
- Checks: only that it decrypted under the Olm session keyed `peer_str`.
- Who can sign: unsigned (authority = Olm session holder).
- Binding: session keyed `peer_str` ↔ state keyed `peer_str`. Bound, to whoever holds the session (see S-01).
- Freshness: Olm ratchet. Absent fields: none (unit variant, `types.rs:3362`).
- Blast radius: UI "secure session" state only.
- Tests: none found. SUSPICION: none of its own (no blocklist; harmless).

### A-DM-09 HavenMessage::FriendRequest  (creates or refreshes a pending-incoming friend row, stores a carried bundle and profile, joins a DM room, pushes our profile, or AUTO-ACCEPTS if we requested them)

- Dispatch sites: plaintext arm `swarm.rs:12111`; direct, `inbox:{us}` mailbox, or room broadcast. Not in fetch.rs.
- Target object: the friend row keyed `resolve(peer_str)` (after ingest); KV `friendreq_in:{list.master_peer_id}`.
- State changes, in order:
  1. `12154-12158` `crypto_handler::ingest_device_list(...)` (resolver + device store writes; other agent).
  2. `12185` `store.save_setting(&key, &json)` (carried bundle).
  3. Possible outbound decline re-send `12223-12230`.
  4. `12254-12260` `social::store_carried_profile(...)` (profile write, gated on signature and `source_master == sender_master`, `social.rs:205-211`, `226-242`) and emit `ProfileUpdated`.
  5. Mutual: `12289-12292` clear RAM queues, `12300-12302` `store.save_friend(&req_master_early, "pending", "outgoing", requested_at)`, `12304-12312` `social::handle_accept_friend_request(...)` → `social.rs:618` `store.save_friend(&master, "accepted", "", now);`, sends FriendAccept (`social.rs:725-728`), may build an Olm session from the carried bundle (`694-706`), emits FriendRequestAccepted (`756`).
  6. Otherwise `12323` `migrate_friend_to_master`, `12325` `store.save_friend(&master, "pending", "incoming", requested_at);`, `12338-12340` JoinRoom `dm_room_code(local, req_master)`, `12348-12353` push our profile + device list to `peer_str`, `12355` emit `FriendRequestReceived`.
- Checks before the first state change, in order:
  1. `12116` `if super::resolver::same_identity(peer_str, master_peer_str) {` return.
  2. `12125` `if super::blocklist::is_blocked(peer_str) {` return. Principal: `resolve(peer_str)`, which is the RAW device when the resolver is cold (`blocklist.rs:42`).
  3. If `device_list` is present: `12143` `verify_device_list(list)`, `12145` `device_list_binds_sender(list, peer_str)` (other agent's area), else DROP.
  4. Dedup / anti-downgrade on the existing row (`12209`, `12216`, `12237`) keyed `req_master_early = resolve(peer_str)` (`12161`).
- Who can sign: the frame is unsigned (authority = relay-stamped `from`). The carried parts are signed (list by master, bundle by device, profile by master).
- Binding: the row is keyed by `resolve(peer_str)`; `requested_at` is sender-chosen with no bound.
- Transport parity: one site.
- Freshness: `requested_at` compared to the stored row (`12216`, `12237`); a strictly newer stamp always resurfaces a declined request (by design: "A strictly NEWER requested_at is a genuine re-add").
- Absent fields: `carried_bundle`, `device_list`, `carried_profile` are all Option (`types.rs:1854-1871`). No list = no ingest, row keyed by `resolve(peer_str)` (legacy accepted). The bundle requires the list (`12166`).
- Blast radius: local row + outbound profile push; the mutual path propagates acceptance to the peer.
- Tests (names): `blocked_peer_dm_and_friend_request_dropped` (test_harness.rs:11341), `blocked_sender_mailbox_request_dropped` (17111), `friend_request_between_strangers_does_not_merge` (8479, row-keying, not rejection). Unit: `crypto_handler.rs:5247` `carried_list_binds_the_sending_device`, `5321` `verify_carried_bundle_accepts_valid_and_rejects_tampered`.
- SUSPICION:
  - S-08: `12125` runs BEFORE `12154`. For a blocked master Bob sending from a device Alice has never ingested, `is_blocked(newDev)` resolves `newDev → newDev` (not in the blocked set), passes; then the ingest binds `newDev → Bob` (`crypto_handler.rs:1465-1468` `super::resolver::update_many(&stored.master_peer_id, ...)`), and the row (`12325`) and `FriendRequestReceived` (`12355`) are made for blocked Bob. No second block check after ingest. CONFIRMED-BY-READING.
  - S-07: the mutual path (`12268-12281`) trusts relay-stamped `from`. The relay forges a bare plaintext FriendRequest from Bob to Alice while Alice has a pending OUTGOING request to Bob → Alice auto-accepts and sends FriendAccept to Bob → on Bob's node the FriendAccept arm flips Bob's "pending incoming" row to accepted (S-05) with no human accept by Bob. CONFIRMED-BY-READING.

### A-DM-10 HavenMessage::FriendAccept  (marks the sender's master as an ACCEPTED friend)

- Dispatch sites: plaintext arm `swarm.rs:12360`; direct, DM-room, inbox mailbox, room broadcast. Not in fetch.rs.
- Target: friend row keyed `master = resolve(peer_str)` (`12365`).
- State changes, in order:
  1. `12369` `store.migrate_friend_to_master(peer_str, &master);` (BEFORE the declined check; benign re-key).
  2. `12405` `let _ = store.save_friend(&master, "accepted", "", now);`. `save_friend` INSERTS when no row exists (`storage/messages.rs:3776-3778` `INSERT INTO friends ... ON CONFLICT(peer_id) DO UPDATE SET`).
  3. `12420-12425` push our profile + device list to `peer_str`.
  4. `12427` emit `FriendRequestAccepted`.
  Downstream: accepted rows seed `pending_friend_accepts` at every start (`swarm.rs:1107-1110`), which makes us auto-send FriendAccept back; they also replicate to our siblings via `FriendListSync` (`swarm.rs:258-273`, `crypto_handler.rs:1638-1639` `if sender_peer_id != local_device_peer_id && !is_revoked(sender_peer_id) {` / `if let Ok(friends) = store.load_friends(Some("accepted")) {`).
- Checks before `12405`, in order:
  1. `12377` status `== Some("declined")` → return.
  2. `12387-12400`: if a row exists, `12389` `if let Some(stamp) = requested_at && stamp < stored {` return; if NO row, `12395` `if store.load_setting(&social::removed_key(&master)).ok().flatten().is_some() {` return.
  NO check of the row's status/direction (a "pending incoming" row passes), NO check that a row exists at all (no row + no tombstone passes), no blocklist.
- Who can sign: unsigned (authority = relay-stamped `from`).
- Binding: the accept is bound to the sender's own friendship only. It is NOT bound to any request WE made: NONE FOUND.
- Transport parity: one site.
- Freshness: `requested_at` vs the stored row only when both are present; `None` is honoured ("a bare stamp is a pre-0.11.1 sender and passes", `12383-12386`).
- Absent fields: `requested_at: Option<i64>` (`types.rs:1880`); absent = accepted as legacy.
- Blast radius: persistent, replicates to siblings, and triggers auto-accept back to the sender on the next start.
- Tests (names): `stale_friend_accept_replayed_after_readd_is_dropped` (test_harness.rs:9320), `friend_accept_survives_mailbox_redelivery` (16444, positive). No test for a consent-less accept.
- SUSPICION S-05 (CONFIRMED-BY-READING). Mallory = stranger:
  - (a) Mallory sends FriendRequest (→ Alice's row "pending incoming", `12325`), then FriendAccept → `12405` sets it to "accepted" without Alice clicking Accept.
  - (b) If Alice has no row for Mallory and never removed her, a bare FriendAccept alone creates an accepted friend.
  Reachability: the inbox is "stranger-reachable" (comment `12140`; the depositor joins `inbox:{target}`, `social.rs:307-311`), or Mallory broadcasts one FriendAccept to a shared server room (0x05, common dispatch). Every member without a row or tombstone for Mallory then marks her accepted. No blocklist check either (a blocked Mallory with no row or tombstone can become a friend; Rust `block_peer` writes only `blocked_peers`, `api/storage.rs:671-681`, `storage/messages.rs:4031-4043`).

### A-DM-11 HavenMessage::FriendReject  (deletes our outgoing request, or the accepted friendship, for the sender's master)

- Dispatch sites: plaintext arm `swarm.rs:12432`. Not in fetch.rs.
- Target: row keyed by `master` = `list.master_peer_id` if a list is carried (`12467`), else `resolve(peer_str)` (`12471`).
- State changes: `12462-12466` `ingest_device_list` (other agent); `12503` `store.remove_friend(&master);` and `12505` `remove_friend(peer_str)`; RAM queues `12512-12517`; `12522-12524` LeaveRoom `inbox:{master}`; emit `12526` `FriendRequestRejected`.
- Checks before `12462`: if a list is present, `12446` `verify_device_list(list)`, `12448` `list.devices.iter().any(|d| d == peer_str)`, `12450` not revoked (inline, not `device_list_binds_sender`, a parity difference with `12145`). Before `12503`: `12492-12496` `acts_on` = pending/outgoing with `requested_at == 0 || requested_at >= stored`, or accepted with `requested_at != 0 && requested_at >= stored`.
- Who can sign: unsigned. The device list is a standalone replayable statement; it attributes `peer_str` to a master but does not authenticate the reject.
- Binding: the sender's own relationship only (via `from`).
- Freshness: `requested_at` compared to the row (a relay-chosen `i64::MAX` passes `>= stored`).
- Absent fields: `requested_at` default 0 → only a pending/outgoing row is acted on; `device_list` absent → resolver.
- Blast radius: deletes an accepted friendship (the "mutual race" arm, `12494`), local.
- Tests (names): `stale_reject_never_deletes_an_accepted_friendship` (17680), `friend_reject_with_bad_carried_list_is_dropped` (17792).
- SUSPICION S-06: relay forges `FriendReject{requested_at: i64::MAX}` from Bob (no list) → `12494` true for an accepted row → friendship deleted on Alice's side. CONFIRMED-BY-READING (relay power). No blocklist.

### A-DM-12 HavenMessage::FriendRemove  (unfriends and writes a removal tombstone)

- Dispatch sites: plaintext arm `swarm.rs:12531`. Sent plaintext (`swarm.rs:3503-3506` `send_message_to_peer(&ws_cmd_tx, &ws_room_peers, &peer_id, HavenMessage::FriendRemove,)`). Not in fetch.rs.
- Target: `master = resolve(peer_str)` (`12535`).
- State changes: `12540` `store.save_setting(&social::removed_key(&master), "1");` (tombstone, which later refuses bare accepts at `12395`), `12541` `store.remove_friend(&master);`, `12543` `remove_friend(&peer_str)`; RAM `12553-12558`; emit `12564` `FriendRemoved`.
- Checks: NONE before `12540`.
- Who can sign: unsigned; authority = relay-stamped `from`.
- Binding: the sender's own relationship only.
- Freshness: NONE FOUND (unit variant, `types.rs:1901`; no stamp; FriendAccept got a stamp for the same parked-copy problem, FriendRemove did not).
- Absent fields: n/a.
- Blast radius: persistent unfriend plus a tombstone; local only.
- Tests: none found for rejection.
- SUSPICION S-06: relay forges or replays FriendRemove from Bob → Alice drops Bob and tombstones him. A copy parked at the relay from an OLD removal also re-removes a later re-add. CONFIRMED-BY-READING (relay power).

### A-DM-13 MessageEnvelope::DirectMessage  (inserts a DM row, emits MessageReceived)

- Dispatch sites:
  - Olm envelope `swarm.rs:7286` `Ok(MessageEnvelope::DirectMessage { inner }) => {`.
  - fetch.rs `736-737` → `handle_direct_message` `859-914` → `persist_direct_message` `920-982`.
  - MLS: rejected (`swarm.rs:11505` "DM-only envelopes should never arrive via MLS").
  - Sync backfill: see DmSyncBatch (A-DM-20).
- Target: the row lands in `convo_peer` = `resolve(peer_str)` (`7314`), or, for our own sibling only, the sender-chosen `convo` (`7312-7313` `(true, Some(c)) => c.to_string(),`).
- State changes: `7379-7383` `store.insert(&convo_peer, &msg_text, is_own_device, ts, ...)`; `7392` `store.update_link_preview(message_id, &lp_json)` (only when `is_new`, i.e. the row just inserted); emit `7403-7418` `MessageReceived` (always, `duplicate` flag).
- Checks before the first write, in order:
  1. `7302` `if super::resolver::is_revoked(&peer_str) {` return (device).
  2. `7309` `if !is_own_device && super::blocklist::is_blocked(&peer_str) {` return.
  3. `7350-7357` `verify_message_signature_v2(signer_m, sig, pk, "dm", recipient_m, ts, &extras, &msg_text, ...)`: signer = `convo_peer` (the sender's master) and recipient = our master (`7338`); for a sibling echo, signer = our master and recipient = `convo_peer` (`7336`). The pk must derive to the signer (`crypto_handler.rs:1785`).
  4. `7373-7375` dedup by `mid` across ALL conversations (`storage/messages.rs:1327` `SELECT 1 FROM messages WHERE message_id = ?1`).
- Who can sign: the sender's MASTER key; `crypto_handler.rs:236` `"hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}"` (v3 with album, `233`), with type `dm`, context = recipient master, sender = signer master.
- Binding: the signer must equal `resolve(peer_str)`, which is also the conversation key: `7314` + `7338-7339` `(master_peer_str, &convo_peer)`. Mallory cannot insert into Alice-Bob. Bound.
- Transport parity: fetch has no `is_revoked` check; it drops own-sibling envelopes entirely (`fetch.rs:700`); its blocklist runs before decrypt (`712`); the signature check is equivalent (`fetch.rs:844-846` `check_backfill_signature(convo, "dm", local_master, ts, None, ...)`).
- Freshness: `mid` dedup (DB, survives restart); Olm ratchet; no timestamp window.
- Absent fields: `sig/pk` absent → reject (`crypto_handler.rs:1765-1768`). `mid` absent → no mid dedup; the legacy content index applies (`7384`). `ts` default 0 (`types.rs:2789-2790`). `convo` honoured only from our own sibling.
- Blast radius: local row.
- Tests (names): `blocked_peer_dm_and_friend_request_dropped` (11341); unit backfill tests `crypto_handler.rs:3854`, `3893`, `3909`.
- SUSPICION: none for insertion. See S-04 for the unsigned fallback sibling path.

### A-DM-14 MessageEnvelope::EditMessage, DM side (`sid` absent)  (rewrites a DM row's text)

- Dispatch sites:
  - Olm `swarm.rs:7915`, DM branch `7955-7989`.
  - fetch.rs `739-740` → `handle_edit_message` `1038-1096`.
  - MLS `swarm.rs:10997-11003` → `message_ops.rs:2620-2682` (channel-only lookup `2642` `get_channel_message_sender(&mid)`; a DM mid returns None, so no write).
  - Sync: DmSyncBatch edited items (A-DM-20).
- Target: the row named by `mid` (any conversation).
- State changes: `7981-7984` `store.edit_dm_message(&mid, &new_text, ts, sig, pk)` → `storage/messages.rs:3175` `SELECT ... FROM {table} WHERE message_id = ?1`, `3192-3194` history insert, `3201` `UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4 ... WHERE message_id = ?5`; emit `8011-8018` `DmMessageEdited` with `peer_id = dm_event_convo(...)` (`swarm.rs:5869-5884`: `resolve(sender)` unless sibling).
- Checks before the write:
  1. `7920` `live_muted_ingest_drop(sid...)` (None for DM, so `message_ops.rs:2558` returns false).
  2. `7959` `let is_mine = store.get_dm_message_is_mine(&mid);` (`storage/messages.rs:3056` `SELECT is_mine FROM messages WHERE message_id = ?1`, by mid only).
  3. `7961` `if is_mine == Some(false) || (is_mine == Some(true) && is_sibling) {`.
  4. `7965-7972`: signer = `resolve(&peer_str)`, ctx = our master (non-sibling); signer = our master, ctx = `get_dm_message_peer(&mid)` (sibling).
  5. `7974-7980` `verify_message_signature_v2(&signer, sig, pk, "dm", &ctx, ts, &row.as_signed(&mid), &new_text, ...)` with the extras from OUR row (`7973` `RowExtras::load_dm`).
- Who can sign: any master key: the editor's own. The payload is the same `hollow-msg2:dm:...` shape as a message.
- Binding: NONE FOUND between the signer (`resolve(peer_str)`) and the row's author/conversation (`storage/messages.rs:3069` `SELECT peer_id FROM messages WHERE message_id = ?1` is used only for the sibling branch). The sibling branch is bound (signer = us).
- Transport parity: fetch `1038-1086` has NO `is_mine` check at all (only `1067` `fetch_dm_sig_rejected(convo, local_master, ts, &new_text, ...)`); its blocklist is at `fetch.rs:712`, the live path has none. `1084` `set_dm_message_edited_at(&mid, ts)` on any row by mid when not applied.
- Freshness: NONE FOUND (`edit_message_in` has no `edited_at` ordering, `storage/messages.rs:3163-3208`); replay is only possible for the signer.
- Absent fields: `sig/pk` absent → reject; `sid` absent selects the DM branch.
- Blast radius: rewrites another party's message in the victim's DB; the history row keeps the old text (`message_edits`); local.
- Tests: none for a cross-author edit. `crypto_handler.rs:4428` `backfill_verifies_v2_edit_and_rejects_extras_tamper` (unit, backfill helper).
- SUSPICION:
  - S-10: Mallory (Alice's friend, or ANY peer with an Olm session) knows `mid` X of Bob's message in Alice-Bob plus that row's `reply_to/file_id/order_us/lp/album`. She signs `hollow-msg2:dm:{Alice}:{Mallory}:{ts}:{X}:...:{evil}` and sends EditMessage → `7961` passes (`is_mine==Some(false)`) → `7981` rewrites Bob's row. The signature/pk columns become Mallory's. Mid knowledge: a revoked sibling of Alice or Bob (S-18) holds every mid and extra. CONFIRMED-BY-READING.
  - S-11: the fetch node lets the same attacker also rewrite rows with `is_mine=1` (Alice's own sent messages). CONFIRMED-BY-READING.
  - No blocklist (S-19).

### A-DM-15 MessageEnvelope::DeleteMessage, DM side  (hides a DM row)

- Dispatch sites: Olm `swarm.rs:8032`, DM branch `8063-8099`. MLS `swarm.rs:11013-11018` → `message_ops.rs:2814-2862` (channel-only sender check `2828-2832`; a DM mid is rejected). fetch.rs: not handled (`756`). Sync: `hidden_at` in DmSyncBatch (A-DM-20).
- Target: the row named by `mid`.
- State changes: `8095-8098` `store.hide_dm_message(&mid, ts, sig, pk)` → `storage/messages.rs:3301` read text, `3313-3317` `INSERT INTO message_deletions`, `3322` `UPDATE {table} SET hidden_at = ?1, updated_at = ?1 WHERE message_id = ?2`; emit `8110-8115` `DmMessageDeleted`.
- Checks before the write: `8067-8075` `is_mine == Some(false)` or sibling, else reject; `8078-8085` signer = `resolve(&peer_str)` / ctx = our master (non-sibling); `8088-8094` `verify_message_signature_v2(&signer, ..., "dm-delete", &ctx, ts, &row.as_signed(&mid), &current_text, ...)` (extras and CURRENT text from our row).
- Who can sign: the deleter's master key; the payload type is `dm-delete`.
- Binding: NONE FOUND (the signer is never compared to the row author).
- Transport parity: the sync twin `message_ops.rs:163-175` derives the signer FROM THE ROW (`166-168` `let row_peer = super::resolver::resolve(&store.get_dm_message_peer(mid)...)`, `173-174` `(row_peer, local_master.to_string())`). Bound there, unbound live.
- Freshness: none beyond requiring the current text.
- Absent fields: `sig` absent → reject.
- Note: if `MessageStore::open` fails (`8036`), no check runs but `8110-8115` still emits `DmMessageDeleted` (not attacker-controlled).
- Tests (names): `synced_dm_deletion_requires_proof` (13479); unit `message_ops.rs:3102` `synced_dm_deletion_binds_author_direction` (sync path only; the live path has none).
- SUSPICION S-12: Mallory with mid + current text + extras of Bob's row (e.g. a revoked sibling, S-18) hides it in Alice's DB with her own signature. CONFIRMED-BY-READING.

### A-DM-16 MessageEnvelope::AddReaction, DM side  (adds a reaction row keyed by `mid`)

- Dispatch sites: Olm `swarm.rs:8118-8184`. MLS with `sid=None` `swarm.rs:11020-11027` → `message_ops.rs:2866-2914` (stores, emits nothing for DM). fetch.rs: not handled. Sync: DmSyncBatch `reactions` (`swarm.rs:7634-7643`).
- Target: `message_reactions(message_id, emoji, peer_id)`; the table is SHARED by DM and channel rows (`storage/messages.rs:694-703`, `UNIQUE(message_id, emoji, peer_id)`).
- State changes: `8156-8159` `store.add_reaction(&mid, &emoji, &reactor_key, ts, sig, pk)` → `storage/messages.rs:3481` `INSERT OR IGNORE INTO message_reactions ...`; emit `8176-8182` `DmReactionAdded`.
- Checks: `8121` emoji shape; `8129` mute gate (only when `sid` is present); `8148-8153` `reaction_sig_rejected(&resolve(&peer_str), "reaction", &mid, &emoji, ts, ...)` → `message_ops.rs:2950` `let payload = format!("{kind}:{mid}:{emoji}:{ts}");`.
- Who can sign: the reactor's master key over `reaction:{mid}:{emoji}:{ts}`.
- Binding: reactor ↔ signer is bound (`reactor_key = resolve(peer_str)` `8139`). mid ↔ conversation: NONE FOUND.
- Transport parity: MLS stores with reactor `sender_master` and verifies against it (`message_ops.rs:2895`); both skip the mute gate when `sid` is None (`message_ops.rs:2558` `let Some(state) = server_state else { return false; };`).
- Freshness: the UNIQUE triple; no timestamp ordering.
- Tests (names): unit `message_ops.rs:3409` `synced_reaction_requires_its_own_signature` (sync path).
- SUSPICION S-13: Mallory (any Olm peer, or any server member via MLS) sends AddReaction with `sid=None` and the `mid` of (a) Bob's DM row, or (b) ANY channel message. It is stored under that mid. For channels this skips the mute gate and the membership check. The row then replicates through channel sync backfill (`load_reactions_for_sync`, `swarm.rs:5972`, `sync_handler.rs:443`; `sync_reaction_accepted` only checks the reactor's own signature, `message_ops.rs:2923-2935`). CONFIRMED-BY-READING (store + replication read; channel UI rendering PLAUSIBLE).

### A-DM-17 MessageEnvelope::RemoveReaction, DM side

- Dispatch sites: Olm `swarm.rs:8185-8230`; MLS `11028-11034` → `message_ops.rs:2962-2996`.
- State: `8205-8208` `store.remove_reaction(&mid, &emoji, &reactor_key, ...)` → `storage/messages.rs:3502` `DELETE FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3`, then a removal-evidence insert (`3511`); emit `8222`.
- Checks: `8197-8202` signature by `resolve(peer_str)` over `unreaction:{mid}:{emoji}:{ts}`.
- Binding: the reactor can only delete its OWN reaction (`peer_id = reactor_key`). Bound.
- Freshness: none (an old unreaction replays over a newer re-add; only the signer can replay).
- SUSPICION: none beyond no blocklist.

### A-DM-18 MessageEnvelope::LinkPreviewSet, DM side  (attaches or clears a card on a DM row and SWAPS its signature)

- Dispatch sites: Olm `swarm.rs:8022-8031`; MLS `11005-11011`; both → `message_ops.rs:2692-2810`. fetch.rs `742-748` (only `sid.is_none()`) → `handle_link_preview_set` `990-1032`.
- Target: the row by `mid`.
- State changes: `message_ops.rs:2792-2794` `store.update_link_preview_and_sig(&mid, lp_json, sig, pk)` → `storage/messages.rs:1474-1475` `UPDATE {table} SET link_preview_json = ?1, signature = ?2, public_key = ?3 WHERE message_id = ?4`; emit `2806-2808` `DmLinkPreviewUpdated { peer_id: convo_peer ... }`.
- Checks: `2709` mute (channel only); `2737-2742` `is_mine == Some(false)` or sibling; signer/ctx `2750-2754` (`(super::resolver::resolve(peer_str), local_master.to_string(), convo)` for non-sibling); `2778-2784` `verify_message_signature_v2(&signer, ..., msg_type, &ctx, ts, &extras, &row.text, ...)` with our row's text/extras and the NEW lp digest.
- Binding: NONE FOUND between the signer and the row author (the same pattern as the edit).
- Transport parity: fetch `1004` `if store.get_dm_message_is_mine(&mid) != Some(false) {` (no sibling case), signer `convo` (`1020-1022`). MLS delivers the DM branch too (S-20).
- Tests (names): `late_link_preview_lands_on_recipient_and_sibling_without_marking_edited` (positive), no cross-author rejection test.
- SUSPICION S-14: Mallory with mid + text + extras of Bob's row attaches a phishing card to it, and the row's signature becomes Mallory's. CONFIRMED-BY-READING.

### A-DM-19 HavenMessage::DmSyncRequest  (makes us re-serve DM history for the requester's conversation)

- Dispatch sites: PLAINTEXT arm `swarm.rs:10650`; direct or room broadcast. Not in fetch.rs.
- Target: conversation `convo_peer = resolve(peer_str)` (`10658`).
- State changes: none locally. Outbound: `10678-10683` gap batch and `10705-10710` page, via `send_dm_sync_reply` (`swarm.rs:5928-5961`). It encrypts to the Olm session keyed `peer_str` (`5942-5947`), or queues it and sends a KeyRequest (`5950-5960`).
- Checks: NONE (no signature, no friend check, no blocklist, no `is_revoked`).
- Who can sign: unsigned; authority = relay-stamped `from`.
- Binding: served rows are bound to `resolve(peer_str)`: `storage/messages.rs:1636` `WHERE peer_id = ?1 AND is_mine = 1 ...`, `1694` `WHERE peer_id = ?1 AND (timestamp > ?2 ...)` (both directions), `1813` gap `WHERE peer_id = ?1 ...`. A requester only pulls its own conversation. Confidentiality then rests entirely on who holds the `peer_str` Olm session (S-01).
- Freshness: none (idempotent re-serve; amplification only).
- Absent fields: `both_directions` default false (`types.rs:1575-1576`), `gap` None.
- Adjacent: `DmSiblingSyncRequest` (`swarm.rs:10716-10776`) is also plaintext, gated only by `10720` `same_identity`, and serves ALL conversations (S-02).
- Tests: WT-only HOL-SEC-003 test step (WT `test_harness.rs:3353-3359`).
- SUSPICION: S-01/S-02 (confidentiality chain). Serves a blocked peer (low).

### A-DM-20 MessageEnvelope::DmSyncBatch  (backfills DM rows and applies edits, previews, deletions, file metadata and reactions)

- Dispatch sites: Olm `swarm.rs:7420-7682`. MLS rejected (`11506`). fetch.rs ignored (`756`).
- Target: new rows go into `convo_peer = resolve(peer_str)` (`7425`); edits, previews, deletions, file metadata and reactions go to ANY row or file by id.
- Checks before the first write: `7428-7432` `if !same_identity(&peer_str, local_peer_str) && is_blocked(&peer_str) { return; }`. Per item: `7475-7488` `check_backfill_signature(sender_m, "dm", recipient_m, msg.ts, msg.edited_at, &extras, &msg.t, ...)` with `sender_m = convo_peer` if the item is theirs, `local_peer` if ours (`7456-7460`). The extras come from the ITEM (`7467-7474`). No friend check, no `is_revoked`.
- State changes per item, in order:
  1. `7503-7506` `reconcile_dm_by_timestamp(&convo_peer, mid, ...)`: bound, `storage/messages.rs:1295` `WHERE peer_id = ?1 AND timestamp = ?2 AND is_mine = 0 ...`. Emits `7516` `DmMessageEdited`.
  2. `7528-7533` `store.insert(&convo_peer, ...)`: bound to the sender's conversation.
  3. `7539` / `7562` `set_dm_message_edited_at(mid, edit_ts)`: ANY row by mid (`storage/messages.rs:3245`).
  4. `7544-7549` `store.edit_dm_message(mid, &msg.t, edit_ts, sig, pk)` when the mid ALREADY EXISTS anywhere (`7490-7492` `dm_message_exists`, global): ANY row by mid, sent or received. Emits `7551`.
  5. `7569-7574` `apply_synced_link_preview(&store, false, mid, &msg.t, lp, sig, pk)` → `message_ops.rs:1631-1651`: ANY row by mid whose text equals the item text; swaps sig/pk. Emits `7576`.
  6. `7585-7589` `apply_verified_dm_deletion(...)`: BOUND (signer from the row, `message_ops.rs:166-175`).
  7. `7603-7614` `file_meta_write_allowed(&store, &fm.fid, &fm.sender)` → `insert_file_metadata(...)` (an upsert that overwrites name/ext/mime/size/dims/thumb, `storage/messages.rs:5185-5196`). The owner check compares the stored owner with the ITEM-claimed `fm.sender` (`file_handler.rs:209-211`). Emits `7615` `FileHeaderReceived { sender_id: fm.sender ... }`.
  8. `7636-7642` reactions: `sync_reaction_accepted` (the reactor's own signature over the mid) → `add_reaction(mid, &r.e, &r.p, ...)`.
  9. Pagination `7650-7669` sends another DmSyncRequest; emit `7677` `DmSyncCompleted`.
- Who can sign: the item author's master (theirs) or ours (our own messages to them); `hollow-msg2:dm:...`, with `edited_at` as the timestamp for edited items (`crypto_handler.rs:1871`).
- Binding: new rows are bound (`7529` uses `convo_peer`). Edits (4), previews (5), edited_at (3) and file metadata (7): NONE FOUND.
- Transport parity: the only DM backfill site; the channel twin is another agent's. `DmSiblingSyncBatch` is gated `7686`.
- Freshness: mid dedup for inserts; none for edits.
- Absent fields: `mid` absent → new row, no edit; `edited_at` absent → verified against `ts`; `hidden_sig` absent → deletion rejected (`message_ops.rs:157-162`); `file_meta.sender` is unchecked against the transport.
- Tests (names): `synced_dm_deletion_requires_proof` (13479); unit `backfill_rejects_*` (`crypto_handler.rs:3854-3909`), `message_ops.rs:3409`. None for cross-conversation edits.
- SUSPICION:
  - S-09: Mallory (any peer with an Olm session: a friend, a stranger after key exchange, a revoked device) sends `DmSyncBatch{[ {mid: X, mine: true, t: "evil", ts, edited_at: Some(T), sig: Mallory's over hollow-msg2:dm:{Alice}:{Mallory}:{T}:{X}:<her own extras>:evil} ]}`. Then `7482` passes, `7490` finds X (Bob's row, or Alice's own sent row), and `7545` rewrites it. She needs ONLY the mid. CONFIRMED-BY-READING.
  - S-15: the same item with `lp` grafts a card and swaps the signature (`7569-7574`). CONFIRMED-BY-READING.
  - S-16: `file_meta: {fid: F, sender: <F's real owner>, name: "invoice.pdf", mime, thumb, ...}` passes `file_handler.rs:210` `if owner == super::resolver::resolve(incoming_sender) {` and relabels file F (any context whose id Mallory knows, e.g. a channel file). The live FileHeader uses `&peer_str` (`swarm.rs:8326`). CONFIRMED-BY-READING.
  - No `is_revoked` guard (the phantom-chat guard exists only at `7302`).

### A-DM-21 HavenMessage::TypingIndicator (DM: empty server_id) / MessageEnvelope::Typing

- Dispatch sites: plaintext `swarm.rs:13341-13361`. MLS `MessageEnvelope::Typing` `swarm.rs:11172-11176` → `social.rs:1819-1830` (accepts `sid=""`, i.e. DM-shaped, from any server member). Olm: ignored (`swarm.rs:9151`). fetch.rs: no.
- State: emit only `13356` `TypingStarted { peer_id: typist_master, server_id, channel_id }`.
- Checks: `13345` `if super::resolver::is_revoked(peer_str) { return; }`. No blocklist, no friend check, no signature.
- Who can sign: unsigned (relay-stamped `from`).
- Binding: to the sender's own master only.
- SUSPICION: no blocklist (S-19); relay-spoofable (low); MLS DM-shaped typing (S-20).

### A-DM-22 HavenMessage::StatusUpdate

- Dispatch: plaintext `swarm.rs:13363-13369`. State: emit `13365` `PeerStatusChanged { peer_id: peer_str, status }` (free-form string). Checks: NONE. Unsigned. Bound to the sender's own id. Relay-spoofable (can mark Bob "invisible"). No blocklist. Low.

### A-DM-23 HavenMessage::PeerDisconnecting

- Dispatch: plaintext `swarm.rs:10778-10784`. State: emit `10781` `PeerDisconnected { peer_id: peer_str }`. Checks: NONE. Unsigned.
- Dart effect (read): `event_provider.dart:340-347` → `call_provider.dart:1694-1706` (ends a not-yet-connected call with that peer: `await _service.endCall();`), `voice_channel_provider.dart:1361-1380` (removes the peer from VC participants and `await _service?.closePeer(peerId);`).
- SUSPICION S-22: a relay-spoofed PeerDisconnecting tears down Bob's VC link in Alice's client. Relay-only (DoS class). CONFIRMED-BY-READING.

### A-DM-24 HavenMessage::PeerExchange

- Dispatch: plaintext `swarm.rs:13960-13982`. Checks: `13963` size cap; `13969` `if !overlay.neighbors.contains(peer_str) {` return. State: `13975` `overlay.known_peers.insert(p.clone());` and `13976-13978` peer scores. No membership check on the listed ids.
- SUSPICION S-23 (low, PLAUSIBLE): a gossip neighbour (or the relay spoofing one) injects arbitrary ids into the rotation pool (`gossip_relay.rs:126-145` emits `GossipConnect` from rotation).

### A-DM-25 HavenMessage::Ack

- Declared `types.rs:1424-1425` `#[serde(rename = "ack")] Ack,`. No arm anywhere (`grep ::Ack\b`: no hits outside tests); it falls to `swarm.rs:14166` `_ => {}`. fetch.rs `759` `_ => None`. No state change.

### A-DM-26 HavenMessage::AutoDownloadPref

- Dispatch: plaintext `swarm.rs:13371-13378`. State: `13377` `peer_auto_dl.insert(peer_str.to_string(), mb);` (RAM; cleared at `swarm.rs:3255`), clamped `13375`. Effect: `file_handler.rs:1108-1109` `Some(mb) => *mb == 0 || msg.file_size > (*mb as u64) * 1024 * 1024,` makes OUR DM file fan-out to THAT device send metadata only.
- Checks: NONE; unsigned. Bound to the sender device's own entry. The relay can spoof `mb: 0` for Bob, so we stop pushing file bytes to Bob (DoS; the receive gate still enforces). Absent `mb` → 0 (`types.rs:2245-2246`) = "declines everything". Low.

### A-DM-27 Blocklist placement (`blocklist::is_blocked`, which resolves device → master via the resolver, `blocklist.rs:41-47`)

| Arm | is_blocked line | first store write | first emit | Verdict |
|---|---|---|---|---|
| KeyRequest `swarm.rs:6507` | none | 6553/6556-6561 (session, OTK, account) | none | MISSING |
| KeyBundle `6570` | none | 6611 pin write | security alert via 6611 / SessionAck 6651 | MISSING |
| Encrypted PreKey `6697` | none | 6728/6729/6799 session | 6731/6801 SessionEstablished | MISSING |
| Encrypted normal `6875` | none | 6880 ratchet / 6912 remove | 6885 / 6916 | MISSING |
| Raw-text fallback `9412` | none | none (Dart may persist) | 9425 MessageReceived | MISSING (S-04) |
| SessionAck `9040` | none | 9047 | 9050 | MISSING (harmless) |
| DirectMessage `7286` | 7309 (after `is_revoked` 7302) | 7379 | 7403 | BEFORE both (OK) |
| DmSyncBatch `7420` | 7428-7432 | 7441+ | 7516+ | BEFORE both (OK) |
| EditMessage DM `7915` | none | 7981 | 8011 | MISSING |
| LinkPreviewSet DM `8022` → message_ops.rs:2692 | none | message_ops.rs:2792 | 2806 | MISSING |
| DeleteMessage DM `8032` | none | 8095 | 8111 | MISSING |
| AddReaction DM `8118` | none | 8156 | 8176 | MISSING |
| RemoveReaction DM `8185` | none | 8205 | 8222 | MISSING |
| MLS AddReaction/LP/Typing (`sid=None`) `11020`/`11005`/`11172` | none | message_ops.rs:2899 / 2792 | – / 2806 / social.rs:1825 | MISSING |
| DmSyncRequest `10650` | none | none (serves) | none | MISSING (serves a blocked peer) |
| FriendRequest `12111` | 12125 (after self check 12116) | 12154 ingest | 12257/12355 | BEFORE, but S-08 (runs before ingest, so a cold device of a blocked master passes) |
| FriendAccept `12360` | none | 12369/12405 | 12427 | MISSING (S-05) |
| FriendReject `12432` | none | 12462/12503 | 12526 | MISSING |
| FriendRemove `12531` | none | 12540 | 12564 | MISSING |
| TypingIndicator `13341` | none (`is_revoked` 13345 only) | none | 13356 | MISSING |
| StatusUpdate `13363` | none | none | 13365 | MISSING |
| PeerDisconnecting `10778` | none | none | 10781 | MISSING |
| AutoDownloadPref `13371` | none | 13377 (RAM) | none | MISSING (harmless) |
| fetch.rs `try_decrypt_dm` `675` | 712 (after own-sibling skip 700) | 815 session persist / 949 insert / 1075 edit / 1027 LP | returned FetchedDm | BEFORE all fetch writes (OK) |

Cross-cutting blocklist caveat: `is_blocked` keys on `resolve(peer_str)`, so any device the resolver does not map to the blocked master (never-ingested, or revoked-and-`forget`-ed, `resolver.rs:119-123`) is NOT blocked. S-08 is the concrete case.
