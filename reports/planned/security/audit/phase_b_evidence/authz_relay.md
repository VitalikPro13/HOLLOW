# Authz evidence: THE RELAY (C++) and HOW THE CLIENT TREATS RELAY DATA

Scope: `relay-uws/src/*` (ws_handler.cpp and everything it calls) as a receiving
party, plus `rust/hollow_core/src/node/ws_client.rs` and the `WsEvent` arms in
`node/swarm.rs` (3085..4940). Read-only; every claim carries path:line + a quote.
Paths below are relative to `C:\Users\Jabun\Documents\Coding\HOLLOW\`.
`ws_handler.cpp` = `relay-uws/src/ws_handler.cpp`.

LINE-NUMBER BASIS (the tree was edited by another session while this ran):
- `node/swarm.rs` and `node/crypto_handler.rs` citations match git HEAD b009e9a0
  (spot-checked: `WsEvent::PeerJoined` 3302, `HavenMessage::LinkSnapshotKey` 12874,
  `NodeCommand::AcceptLinkPush` 2178, `HavenMessage::RtcOffer` 13791,
  `send_message_to_peer_in_room` 2821). In the working tree at write time they had
  drifted: swarm.rs +1 for roughly 1000..5200 (PeerJoined 3303, Message arm 4561),
  +9 for the LinkSnapshot arms (12883), +10 for Rtc arms (13800);
  crypto_handler.rs `send_message_to_peer_in_room` 2854. Every citation carries a
  verbatim quote to relocate it.
- `node/test_harness.rs` line numbers are approximate (working tree, moving); use
  the test NAMES.
- relay-uws/*, ws_client.rs, file_handler.rs, sync_handler.rs, social.rs,
  link_handler.rs, destroy.rs, gossip*.rs, ws_stream_transfer.rs, api/storage.rs and
  the Dart files were unmodified in the working tree (git status) and cited as read.

---------------------------------------------------------------------------
## 0. Cross-cutting facts (read these first; many rows depend on them)

### 0.1 The only relay-verified principal is the socket's authenticated peer_id
- Set once in `handle_auth`: ws_handler.cpp:261 `data->peer_id = peer_id;`
  after ws_handler.cpp:219-220 `std::string derived_peer_id = derive_peer_id(public_key);`
  `if (derived_peer_id.empty() || derived_peer_id != peer_id) {` and
  ws_handler.cpp:226-227 `std::string signed_msg = "hollow-ws-auth:" + peer_id + ":" + std::to_string(timestamp);`
  `if (!verify_ed25519(public_key, signature, signed_msg)) {`.
- The relay never learns MASTER vs DEVICE, never learns server membership, owner,
  role, friendship. The only relationship it can check is "is peer X currently in
  room R" (`state.ws_rooms[R].peers`).
- `guest` and `fetch` are SELF-DECLARED flags: ws_handler.cpp:188-189
  `bool guest = j.value("guest", false);` `bool fetch = j.value("fetch", false);`.
  Both only REDUCE what the socket may do or how visible it is; "full" is the
  default for any keypair (a fresh keypair is free to mint).

### 0.2 Room join is ungated: ANY authenticated socket may join ANY room name
`handle_join` (ws_handler.cpp:490-582) checks only:
- shape: ws_handler.cpp:493 `if (!is_valid_room_code(room)) {` where
  ws_handler.cpp:119-127 allows `[A-Za-z0-9:\-_.]{1,128}`
  (`if (room.empty() || room.size() > 128) return false;` / `c != ':' && c != '-' && c != '_' && c != '.'`);
- count: ws_handler.cpp:499-500 `size_t max_rooms = data->is_guest ? MAX_GUEST_ROOMS : MAX_ROOMS_PER_PEER;`
  (`MAX_ROOMS_PER_PEER = 10000` ws_handler.cpp:23, `MAX_GUEST_ROOMS = 3` state.h:25).
Then it adds the socket: ws_handler.cpp:526 `ws_room.peers[data->peer_id] = ws;`
and REPLIES WITH THE ROSTER: ws_handler.cpp:536-541
`{"type", "members"}, {"room", room}, {"peers", all_peers}` (all non-guest,
non-fetch peers, ws_handler.cpp:508-511 `if (!pd->is_guest && !pd->is_fetch) { existing_peers.push_back(pid);`).
A guest or fetch joiner triggers NO `peer_joined` (ws_handler.cpp:545
`if (!data->is_guest && !data->is_fetch && !already_present) {`).
No ownership proof is required for any prefix. The `inbox_proof` only gates the
MAILBOX REPLAY (ws_handler.cpp:579-581), never the join itself.

Consequence: every relay gate phrased "sender must be in the room" (0x02, 0x03,
0x04/0x08 when the room exists, 0x07, 0x09, set_topic_buffer, topic_catchup,
discover_peers, check_peers co-membership) reduces to "the sender knows the room
name". Room names in use and who can compute them:

| Room | Name derivation (client) | Who can compute it | Live traffic / effects of joining |
|---|---|---|---|
| `inbox:{master}` | swarm.rs:3116 `let inbox_room = format!("inbox:{}", local_peer_str);` | anyone with the master id (public: profile cards, friend requests, nickname resolve) | roster of the owner's online devices; PeerJoined cascade at the owner (profile, KeyRequest, sibling challenge) |
| DM room | types.rs:43-49 `let combined = format!("dm-{}-{}", sorted[0], sorted[1]); ... hex::encode(&hash[..16])` | anyone holding both master ids | roster shows whether both friends' devices are online in their DM room |
| server room | swarm.rs:3157-3160 `for server_id in server_states.keys() { ... JoinRoom { room_code: server_id.clone(),` | anyone who ever saw the server id (invites, ex-members) | all 0x03/0x07 room traffic, ring catch-up incl. `~join`, gossip-neighbour admission (B-04) |
| `~join` | NOT a room: a TOPIC inside the server room, types.rs:788 `pub(crate) const JOIN_TOPIC: &str = "~join";` (`~` fails `is_valid_room_code`) | same as server room | ring readable via topic_catchup (A-17) |
| `link:{CODE}` | link_handler.rs:40-41 `format!("link:{}", code.to_uppercase())` | anyone who guesses 6 chars (alphabet 31, device_link_sync_provider.dart:130 `const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';`) | roster = code-liveness oracle (A-10) |
| `fwd:{peer}` | swarm.rs:45-46 `room.starts_with("fwd:")` | public | PeerJoined(fwd) Olm session path (B-04) |
| `conf:{id}` | CLAUDE.md "conf:{id} = WS room" (not re-verified here) | anyone with the conference id | PeerJoined -> reknock (swarm.rs:3343-3345) |
| `share:{root}` | swarm.rs:3371-3372 `room.starts_with("share:")` | anyone with the share root hash | broadcast_have on PeerJoined |
| `recovery:{sid}:{token}` | recovery_pool.rs:240-241 `format!("recovery:{}:{}", self.server_id, self.token)` | invite link holders (token) and the relay | recovery messages (B-08a) |

### 0.3 `from` / sender on every relayed frame is STAMPED by the relay
Relay side (from the authenticated socket, never from the frame):
- JSON msg: ws_handler.cpp:1528 `{"from", data->peer_id},`
- JSON direct: ws_handler.cpp:1576 `{"from", data->peer_id},`; buffered copy ws_handler.cpp:1565 `build_direct_frame(room, data->peer_id, msg_data)`
- 0x02: ws_handler.cpp:1631-1637 `// Build forwarded frame: replace target with sender` ... `forwarded.append(data->peer_id);`
- 0x03 -> 0x05: ws_handler.cpp:1670 `forwarded.append(data->peer_id);`
- 0x04/0x08 -> 0x06: ws_handler.cpp:1771 `build_direct_frame(room_code, data->peer_id, payload)` and buffered ws_handler.cpp:1728 / 1754
- 0x07 -> 0x08: ws_handler.cpp:1826 `forwarded.append(data->peer_id);`
- 0x09 -> buffered 0x06: ws_handler.cpp:1504 `build_direct_frame(room_code, data->peer_id, payload)`
Client side: `from` is parsed from bytes with no validation:
ws_client.rs:1207-1208 `let peer_nul = ...; let from = std::str::from_utf8(&data[peer_start..peer_nul]).ok()?.to_string();`
and for 0x08 ws_client.rs:544 `let from = String::from_utf8_lossy(&after_topic[..sender_end]).to_string();`.
No shape check, no "is this us" check, no binding to a signature before it becomes
`peer_str` for `handle_incoming_request` (swarm.rs:4920 `&local_peer_str, &from, is_invisible,`).
Under P-01 the relay can therefore put ANY string in `from`, including our own
device id or our master id. Every unsigned HavenMessage arm's authority is the relay's word.

### 0.4 The arrival `room` is NOT passed to the HavenMessage handler
- swarm.rs:4560 `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } => {` uses `room` only in log lines (4567, 4936); `handle_incoming_request` receives `peer_str` (4920) but no room.
- swarm.rs:4385 `WsEvent::BinaryDirect { room: _, from, data } => {` discards it.
So "the frame came through server room S" confers nothing downstream (good), but
EXCEPTION: the recovery-pool interception (B-08a) runs in the WsEvent arm itself
with neither room nor sender checked.

### 0.5 Relay unit tests do not cover ws_handler.cpp
`relay-uws/test/` holds test_derive_peer_id, test_kill_list, test_license_pool,
test_relay_validators, test_reports, test_snapshot_codec, test_turn_uris,
test_verify_device_list. None calls handle_auth/handle_join/any handler
(grep for `ws_handler|handle_join|handle_auth` only hits a comment,
test_verify_device_list.cpp:5). The harness `MockRelay` (node/test_harness.rs) is a
Rust mock, not the C++ relay.

---------------------------------------------------------------------------
## PART A: client -> relay (the relay is the receiving party)

### A-01 JSON `auth` (handle_auth: binds socket to peer_id, supersedes, delivers kill signal)
- Dispatch: ws_handler.cpp:2483-2486 `if (!data->authenticated) { handle_auth(ws, data, message, state); return; }` (every frame before auth, text OR binary).
- Handler: `handle_auth`, ws_handler.cpp:165-337.
- Target object: the claimed `peer_id` (ws_handler.cpp:182).
- Checks, in order:
  1. JSON parse in try: ws_handler.cpp:168-174.
  2. type: ws_handler.cpp:176 `if (!j.contains("type") || j["type"] != "auth") {`
  3. fields read with `j.value(...)` OUTSIDE any try: ws_handler.cpp:182-189 (`j.value("peer_id", "")`, `j.value("timestamp", uint64_t(0))`, `j.value("guest", false)` ...).
  4. non-empty: ws_handler.cpp:191.
  5. clock window: ws_handler.cpp:198-199 `uint64_t diff = ...; if (diff > TIMESTAMP_SKEW_SECS) {` with `TIMESTAMP_SKEW_SECS = 60` (ws_handler.cpp:22).
  6. peer_id == derive(pubkey): ws_handler.cpp:219-220 (principal: key holder). derive: crypto.cpp:77-100.
  7. Ed25519 over `"hollow-ws-auth:" + peer_id + ":" + timestamp`: ws_handler.cpp:226-227; verify crypto.cpp:38-43 `crypto_sign_verify_detached(`.
  8. license: ws_handler.cpp:241 `LicenseResult lr = state.license.validate_key(license_key_ptr, peer_id);` -> license_pool.h:29-43.
- State changes after checks: ws_handler.cpp:261-263 peer_id/authenticated/license_key; guest bookkeeping 265-272; ws_handler.cpp:296-322 supersede (non-fetch only): `ghost->getUserData()->superseded = true;` `cleanup_peer(state, peer_id, ghost, /*suppress_peer_left=*/true);` `ghost->end(1000, "superseded");` `state.peer_sockets[peer_id] = ws;` `state.peer_rooms[peer_id] = {};`; kill signal push ws_handler.cpp:329-332 `if (const auto* kill = state.kill_list.find(peer_id)) { send_json(ws, {{"type", "kill_signal"}, {"blob", kill->blob}, ...`.
- Who can sign: the device (or any) Ed25519 key; payload `"hollow-ws-auth:{peer_id}:{timestamp}"` (client ws_client.rs:701 `let sign_payload = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);`).
- Binding: peer_id <- pubkey (ws_handler.cpp:219-220). Binding of the auth to THIS relay / this connection: NONE FOUND (no nonce, no relay domain, no channel binding in the signed string).
- Freshness / replay: only the ±60 s window (ws_handler.cpp:198-199). No nonce, no seen-signature cache: NONE FOUND for replay inside the window. Survives restart trivially (stateless).
- Absent fields: `license_key` absent -> `KeyRequired` only if `enabled` (license_pool.h:30-31); `guest`/`fetch` absent -> false.
- Blast radius: a successful auth as X evicts X's live full socket (supersede) and receives X's pending kill signal and, on joins, X's device-keyed offline buffer (A-02).
- Tests: C++ test_derive_peer_id.cpp (derivation KAT); no handle_auth rejection test found. Harness: `node_emits_relay_connected_on_ws_connect` (test_harness.rs:2418) is positive only.
- SUSPICION A-01a (pre-auth remote crash of the relay): `handle_auth` reads fields with `j.value()` OUTSIDE a try (ws_handler.cpp:182-189); nlohmann `value()` does `return it->template get<ValueType>();` (relay-uws/src/json.hpp:22500, v3.12.0 json.hpp:68-69) which throws `type_error` on a wrong-typed field; the authenticated path is wrapped (ws_handler.cpp:2490-2497 comment: "A field of the wrong JSON type makes value() throw, and an exception unwinding into uSockets' C frames would end the process on one malformed frame from any client.") but the pre-auth call at ws_handler.cpp:2484 is NOT. Exploit: Mallory = anyone on the internet, no key: open WSS, send `{"type":"auth","peer_id":1}` (or `"timestamp":"x"`, `"guest":"x"`). Process terminates; it is not a SIGTERM, so `snapshot_to_fdstore` (main.cpp:199-202, only on `should_shutdown`) never runs and every offline buffer, topic ring, kill-list entry, push token and opt-in is lost; repeatable. CONFIRMED-BY-READING (the unwind-terminates step is the relay's own documented behaviour at 2490-2492).
- SUSPICION A-01b (auth not bound to the relay): the signed string has no relay identity (ws_client.rs:701, ws_handler.cpp:226). A hostile self-hosted relay B that the victim connects to (relay switch / invite from B) receives a signature valid on the official relay A for 60 s; B replays it to A and is authenticated there AS the victim's device: supersedes the victim's live socket on A (ws_handler.cpp:296-313), sends `kill_ack` to delete a destroy order parked for that device (ws_handler.cpp:1227-1229), `unregister_push_token`/`register_push_token` (1170-1185), sets `set_push_prefs` "nothing", joins the victim's rooms and drains its device-keyed offline buffer (replay deletes on delivery, ws_handler.cpp:999-1012). PLAUSIBLE (needs the victim to connect to a hostile relay while still being served by another; becomes structural under the planned multi-relay client).
- SUSPICION A-01c (pre-auth memory): the 1 MB text cap applies only after auth (ws_handler.cpp:2489 `if (message.size() > 1024 * 1024) return;`); pre-auth frames up to `maxPayloadLength = 64 * 1024 * 1024` (ws_handler.cpp:2429) are fully `json::parse`d (ws_handler.cpp:169) by an unauthenticated socket, 34 per IP (state.h:19). PLAUSIBLE DoS, not authz.

### A-02 JSON `join` (+ optional `inbox_proof`; roster, peer_joined, buffer replay, mailbox replay)
- Dispatch: ws_handler.cpp:2195-2202 `if (type == "join") { ... handle_join(ws, data, j.value("room", ""), state, inbox_proof);`
- Handler: `handle_join` ws_handler.cpp:490-582; `maybe_replay_inbox_mailbox` 453-486; `replay_buffered_msgs` 990-1015.
- Target object: room name (free text within `is_valid_room_code`).
- Checks before first state change (ws_handler.cpp:526): room shape (493), room count (498-503). Principal checked: nothing about the room; the socket's own peer_id only as the map key.
- State changes: ws_handler.cpp:526 `ws_room.peers[data->peer_id] = ws;` 529 `state.peer_rooms[data->peer_id].insert(room);` roster reply 536-541; `peer_joined` fan-out 545-556; channel-push cap reset 561-567; device-keyed replay 572-574 `replay_buffered_msgs(ws, data->peer_id, room, !data->is_fetch, state);` (DELETES delivered frames, ws_handler.cpp:1000-1011); mailbox replay 579-581.
- Mailbox gate (inbox_proof), in order: not guest (458 `if (data->is_guest) return;`); prefix (459); strict parse (462 -> 357-397, `MAX_PROOF_IDS = 1024` 373); signature + pubkey->master derivation (463 `if (!verify_signed_device_list(dl)) return;` -> device_list.cpp:49 `if (derive_peer_id(dl.master_pubkey_b64) != dl.master_peer_id) {` and 55-57 `verify_ed25519(... payload)`); room == `inbox:` + master (464); version high-water (469-481 `if (dl.version < vit->second) return; vit->second = dl.version;`); THIS socket's peer_id active in the list (483 `if (!device_list_owns_device(dl, data->peer_id)) return;` -> device_list.cpp:66-71 revoked first, then devices). Principal: signer = master key; holder = relay-authenticated device.
- Signed payload: device_list.cpp:27-34 `"hollow-devices:" + master + ':' + version + ':' + devices_csv + ':' + revoked_csv` (sorted, device_list.cpp:12-13).
- Binding (mailbox -> reader): ws_handler.cpp:464 + 483. Binding (room join -> anything): NONE FOUND (by design, see 0.2).
- Freshness: mailbox proof freshness = version high-water mark; RAM only, not in the snapshot (snapshot.cpp:32-73 captures buffers/optin/topics/push tokens/kills/prefs, not `device_list_max_version`; state.h:372-378 "RAM only: a restart forgets the marks"). Mailbox replay never deletes (ws_handler.cpp:410-423) by design.
- Absent fields: no `inbox_proof` -> plain join (ws_handler.cpp:2199-2201); malformed proof -> silently no replay (357-397).
- Blast radius: join itself propagates presence to every member (peer_joined) and drives the client cascades in B-04/B-07.
- Tests: C++ test_verify_device_list.cpp `rejection_tests()` (155-196: empty list, non-base64 key, master id not derived from key, absent/revoked device, id in both arrays). No test for the version high-water mark or for the join path (grep `max_version` in relay-uws/test: no hits).
- SUSPICION A-02a (every membership gate is "knows the room name"): see 0.2. Mallory = stranger with a fresh keypair: joins `inbox:{AliceMaster}` or `dm_room_code(Alice,Bob)` or a server id, and is thereafter a "member" for 0x02/0x03/0x04/0x07/0x09/topic_catchup/set_topic_buffer/discover_peers/check_peers. CONFIRMED-BY-READING.
- SUSPICION A-02b (silent presence / social-graph oracle; defeats the check_peers and discover_peers hardening): authenticating with `"fetch":true` or `"guest":true` (self-declared, ws_handler.cpp:188-189) and joining `inbox:{M}` returns `members` = M's online devices (ws_handler.cpp:536-541) with NO `peer_joined` to anyone (545). Joining `dm_room_code(A,B)` (deterministic, types.rs:43-49) returns whether A's and B's devices sit in their DM room, i.e. that they are friends and online. The comments at ws_handler.cpp:2214-2227 (check_peers: "it is no longer an oracle for ARBITRARY ids") and 2265-2270 (discover_peers: "Without this the reply was a roster dump for ANY room whose code the caller knew") describe exactly the leak the join reply still provides. CONFIRMED-BY-READING.
- SUSPICION A-02c (revocation of mailbox reads does not survive a relay restart): a revoked sibling replays its last master-signed list after any relay restart and reads the master's inbox mailbox until a live sibling presents a newer list (ws_handler.cpp:449-452 "Known limit: the marks are RAM only"). Documented; CONFIRMED-BY-READING.

### A-03 JSON `leave`
- Dispatch: ws_handler.cpp:2203-2204 `leave_room(state, data->peer_id, j.value("room", ""));`
- Handler: `leave_room` ws_handler.cpp:590-647 (called with `expected_ws = nullptr`, so it erases the slot unconditionally, 597-604 skipped).
- Target: own membership only (key = `data->peer_id`). Cannot touch another peer's slot.
- State: 609 erase, 614 room erase if empty, 619 peer_rooms erase, 631-645 `peer_left` fan-out (unless invisible).
- SUSPICION: none (self-only).

### A-04 JSON `msg` (room broadcast, JSON form)
- Dispatch: ws_handler.cpp:2205-2206. Handler `handle_msg` 1515-1537.
- Check: room exists (1517-1518), sender in room (1520 `if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) {`). Principal: relay socket.
- State: none stored; fan-out to every other room peer incl. guests/fetch (1532-1535) with `from` stamped (1528).
- Client: `ServerMsg` has no `msg` variant (ws_client.rs:267-301), so current clients ignore it (ws_client.rs:507 `if let Ok(server_msg) = serde_json::from_str::<ServerMsg>(&text)`).
- SUSPICION: none beyond A-02a.

### A-05 JSON `direct` (targeted JSON; deposits into the offline buffer + push)
- Dispatch: ws_handler.cpp:2207-2209. Handler `handle_direct` 1539-1581.
- Checks: target shape (1543 `if (!is_peer_id_shape(target)) return;` -> validate.h:36-41), room exists (1545-1546), sender in room (1548).
- State: target not in room -> `buffer_offline_msg(target, room, build_direct_frame(room, data->peer_id, msg_data), state, data->peer_id);` (1564-1566) + `try_push_notify` when the target has no socket (1567-1569); else live `direct` (1573-1580).
- Guest restriction: NONE. The guest filter covers binary 0x04/0x08/0x09 only (ws_handler.cpp:2508 `if (opcode == 0x04 || opcode == 0x08 || opcode == 0x09) return; // no SendDirect for guests`); a guest can deposit + wake pushes via JSON `direct`. Low: a non-guest can do the same, guest-ness is self-declared.
- Client: the buffered copy replays as binary 0x06 -> `WsEvent::DirectMessage` (ws_client.rs:528-533), so JSON `direct` deposits DO reach clients.

### A-06 JSON `check_peers`
- Dispatch/handler inline: ws_handler.cpp:2210-2254.
- Checks: not guest (2230), ≤256 ids (2235), shape (2238), co-membership (2231-2239 `collect_room_co_members(...)` / `if (!co_members.count(peer_id)) continue;`; helper 101-117), then `state.peer_sockets.count(peer_id)` (2240).
- Reply: `peer_status {online, active_rooms: []}` (2252-2254).
- SUSPICION: gate bypassable per A-02a/A-02b (join the target's `inbox:{master}` first). CONFIRMED-BY-READING.

### A-07 JSON `discover_peers`
- Inline ws_handler.cpp:2255-2278. Check: caller in room (2271-2272 `rit->second.peers.count(data->peer_id)`). Reply lists ALL room peers except self (2273-2274), INCLUDING guests and fetch sockets (unlike `members`, 508-511).
- SUSPICION: same bypass as A-06. Note the inconsistency: fetch/guest lurkers are hidden from `members` and `peer_joined` but revealed here (only to someone already in the room).

### A-08 JSON `subscribe`
- ws_handler.cpp:2279-2281 -> `handle_subscribe` 1775-1787. Writes only the caller's own `data->subscriptions` (per socket). No membership check needed (only filters what the caller receives, 1861-1868). No cap on topic count per room (1783-1785). SUSPICION: none (self-only).

### A-09 Nicknames: `claim_nickname` / `release_nickname` / `resolve_nickname`
- Dispatch: ws_handler.cpp:2282-2287.
- claim (1904-1940): not guest (1907); `[a-z0-9_]{3,20}` (74-83, 1909-1913); auto-release own old binding (1916-1919); taken unless stale (1924 `if (state.nickname_to_peer.count(nickname) && !nickname_binding_is_stale(state, nickname)) {`; stale = TTL expired or holder has no socket, 1888-1902); writes 1929-1931; master: 1936-1937 `if (is_peer_id_shape(raw_master) && raw_master.rfind("12D3KooW", 0) == 0) { state.nickname_to_master[nickname] = raw_master; }`.
- Binding of `master` to the claimer: NONE FOUND. The claimer may name ANY master id (shape + prefix only). Comment 1932-1935: "Self-reported MASTER id ... Never used for relay-side routing."
- release (1942-1949): own binding only (keyed by `data->peer_id`).
- resolve (1951-1966): NO guest check, NO throttle; returns `peer_id` (device) and `master_id` (self-reported) for any live nickname.
- Freshness: 10-minute TTL (1874 `NICKNAME_TTL_SECS = 600`), RAM only, dropped on disconnect (cleanup_peer 2381-2388).
- Client use: B-13.
- SUSPICION A-09a: `master_id` is claimer-chosen and relay-returned; see B-13 for what the client does with it (friend row keyed on it). Impact limited to misdirecting the requester's own request. CONFIRMED-BY-READING.

### A-10 Link codes: `claim_link_code` / `release_link_code` / `resolve_link_code`
- Dispatch: ws_handler.cpp:2288-2293.
- claim (1990-2017): not guest (1992); 6 chars `[A-Z0-9]` (1976-1985); auto-release own previous (2001-2006); `taken` reply if held (2008-2011 `if (state.linkcode_to_peer.count(code)) { send_json(ws, {{"type", "link_code_error"}, {"error", "taken"}});`); write 2013-2015.
- resolve (2093-2134): not guest (2096); per-connection AND per-IP guess throttle (2098-2104, 2044-2077; 5 free, then 60 s doubling to 900 s, state.h:137-139); one-shot consume on success (2125-2127); reply `link_code_resolved {code, peer_id}` (2133).
- Binding code -> claimer: the claimer's authenticated peer_id (2013). Binding resolver -> anything: none needed (knowledge of the code is the authority).
- Freshness: 5-min TTL (1988), swept (2138-2152), released on disconnect (cleanup_peer 2390-2396).
- SUSPICION A-10a (the RELAY-5 guess throttle is bypassed by two unthrottled oracles): (1) `claim_link_code` answers `taken` for any live code with no throttle and no failure counting (2008-2011); (2) `join` of `link:{CODE}` returns the roster (the populated device sits in that room: link_handler.rs:51 `let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(code) });`). Mallory enumerates 31^6 ≈ 8.9e8 codes (Dart alphabet) during the 5-min window at relay speed, spending no resolve attempts. With a hit, Mallory joins `link:{CODE}` and sends `LinkSnapshotRequest`; the populated device's user sees the expected "link" prompt (swarm.rs:12865-12871, "The authorization is the human Confirm") and, on accept, the full `.hollow` identity backup is encrypted with the code Mallory knows (swarm.rs:2182-2185) and streamed to Mallory. CONFIRMED-BY-READING for both oracles; exploitation rate PLAUSIBLE.
- Related, known (embargoed lk2): the relay sees the code in `claim_link_code`/`resolve_link_code` JSON and in the room name, so P-01 can decrypt any link snapshot it routes.

### A-11 Push tokens: `register_push_token` / `unregister_push_token`
- Dispatch: ws_handler.cpp:2294-2298.
- register (1170-1177): not guest, non-empty token; `state.push_tokens[data->peer_id] = { token, platform };` (1174). Own entry only. No validation of token/platform content.
- unregister (1181-1185): own entry only (`state.push_tokens.erase(data->peer_id);`).
- Persistence: snapshotted (snapshot.cpp:56) and restored (snapshot.cpp:78).
- Who triggers pushes to a peer: see A-19/A-21/A-22 (any authenticated peer, no relationship).
- SUSPICION: none on ownership (keyed by authenticated id). Cross-relay replay (A-01b) is the only way to touch another peer's token.

### A-12 Kill list: `kill_deposit` / `kill_ack` (destroy orders for offline devices)
- Dispatch: ws_handler.cpp:2299-2302.
- deposit handler `handle_kill_deposit` 1193-1224. Checks: not guest (1195), not fetch (1197), blob string 1..2048 (1199-1202, kill_list.h:22), `issued_at_ms` integer > 0 (1204-1207), targets array ≤16 (1209-1215, kill_list.h:23), each target peer-id shaped (1219). Principal checked: NOTHING about the relationship between depositor and target.
- State: ws_handler.cpp:1220 `state.kill_list.deposit(target, data->peer_id, blob, issued_at_ms, now)`; kill_list.h:59-66: `if (it != entries.end() && issued_at_ms <= it->second.issued_at_ms) return false; insert(target, issuer, blob, issued_at_ms, now);` and insert REPLACES the entry (kill_list.h:103-107), per-issuer cap evicts issuer's own oldest (108), GLOBAL cap evicts the globally oldest entry of ANY issuer (109 `if (entries.size() >= MAX_ENTRIES) evict_oldest();`, MAX_ENTRIES = 10000 kill_list.h:25).
- Delivery: on the target's next auth (ws_handler.cpp:329-332); `find` does not consume (kill_list.h:51-54).
- ack handler 1227-1229 `state.kill_list.ack(data->peer_id);` : removes only the caller's own entry (kill_list.h:77-83). The client acks junk: destroy.rs:246-249 `let Some(order) = decode_kill_blob(blob) else { ... WsCommand::KillAck); return; };` and permanent rejections (destroy.rs:254-256).
- Who can sign: the blob is opaque to the relay; the TARGET verifies (out of scope here). Relay-side authority: unsigned (any authenticated non-guest non-fetch socket).
- Binding depositor -> target: NONE FOUND (by design "courier"), and NO binding that protects an existing entry from a different issuer.
- Freshness: `issued_at_ms` is signer clock but compared only as "strictly newer wins" (kill_list.h:63); entries age out after 365 days (kill_list.h:26, 85-98). Survives restart (snapshot.cpp:57-59, 91-95).
- Blast radius: this is the only relay courier for a destroy order to an OFFLINE device; the issuer deposits once (destroy.rs:346-360, no retry; comment destroy.rs:372-374 "The issuer is seconds from being wiped, so a retry queue could never drain").
- Tests: test_kill_list.cpp:53-67 asserts `"a newer deposit overwrites"` with a DIFFERENT issuer (`kl.deposit(target_id(1), "issuerB", "new", 1001, t0)`), and 93-108 that any issuer's deposit evicts the globally oldest. Harness: `kill_signal_with_foreign_blob_is_dropped` (test_harness.rs:23827), `destroy_scope_c_offline_sibling_wipes_on_next_auth_via_kill_list` (23688). No test of a hostile overwrite suppressing a genuine order.
- SUSPICION A-12a (a stranger can cancel a destroy order for someone else's lost/stolen device): Alice's phone is stolen and offline; Alice issues DestroyIdentity from her laptop, which deposits the signed blob for the phone's device id once. Mallory (the thief's accomplice or anyone; a fresh keypair) sends `kill_deposit {targets:[phone_id], issued_at_ms: 9e18, blob:"x"}`: kill_list.h:63 passes (newer), insert replaces Alice's blob. When the phone next authenticates it gets the junk, `decode_kill_blob` fails and it ACKs (destroy.rs:246-249), deleting the entry; Alice's genuine order is gone. A pre-emptive junk deposit with a huge `issued_at_ms` also makes every later genuine deposit fail the "strictly newer" test for up to a year. The device id is public (room rosters, device lists). CONFIRMED-BY-READING (relay + client ack); other destroy lanes (live Olm/plaintext, device-list tombstone) are out of this scope.
- SUSPICION A-12b (global eviction by Sybils): 157 fresh identities × 64 entries (kill_list.h:24) fill `MAX_ENTRIES = 10000`; each further deposit evicts the globally oldest genuine entry (kill_list.h:109, 123-133). CONFIRMED-BY-READING.

### A-13 `set_push_prefs`
- ws_handler.cpp:2303-2304 -> `handle_set_push_prefs` 1234-1259. Not guest; ≤256 servers, ≤1024 channels each; replaces the CALLER's prefs wholesale (1257 `state.push_prefs[data->peer_id] = std::move(prefs);`). The `~dm` entry (1118-1128) mutes DM wake-ups per sender DEVICE id. Own state only. Snapshotted (snapshot.cpp:60-71).
- SUSPICION: none (self-only). Note `~dm` mute is per sender device id, so a sender with fresh ids is never muted (A-21).

### A-14 `set_offline_buffer` (availability-cache opt-in)
- ws_handler.cpp:2305-2306 -> 1264-1275. Not guest; own entry only (`state.offline_optin[data->peer_id] = retention;`), retention clamped 1 h..7 d (1270-1272). Snapshotted (snapshot.cpp:44). SUSPICION: none (self-only).

### A-15 `report`
- ws_handler.cpp:2307-2308 -> `handle_report` 1282-1295. Not guest; target peer-id shaped and != self (1289); category whitelist (1290-1291); `state.reports.add(data->peer_id, target, category)` (1292) -> reports.cpp:206-215 dedup per keyed fingerprint of (reporter, target, category); counts per target persisted to disk (reports.cpp:174-204).
- Binding reporter -> anything: none; reporter = any authenticated id.
- SUSPICION (low): per-target counts are Sybil-inflatable (one report per fresh identity). No automatic enforcement reads the counts in relay-uws/src (grep: only `reports.add` / `save_if_dirty`), so impact depends on operator use. CONFIRMED-BY-READING for inflation.

### A-16 `set_topic_buffer` (register/clear per-channel rings for a room)
- ws_handler.cpp:2309-2310 -> `handle_set_topic_buffer` 1304-1361.
- Checks: not guest (1305), room shape (1307), caller in room (1309-1310 `if (rit == state.ws_rooms.end() || !rit->second.peers.count(data->peer_id)) return;`). Principal: relay socket membership (free, 0.2). The relay cannot tell owner from member (comment 1318-1320).
- State: clear -> every ring of the room stops accepting and retention drops to 1 h (1326-1331); register -> create/refresh rings, retention "latest registrar wins" (1355), re-arm cleared rings (1357).
- SUSPICION A-16a (server-owner opt-in is not enforced): any stranger who knows the server id can (i) turn relay retention ON for every channel of a server whose owner never opted in (7 days, 1336-1338), then read it back with topic_catchup (A-17); (ii) shorten or stop retention for everyone. Channel ids are visible to any room member from live 0x08 topic headers (1818-1828). CONFIRMED-BY-READING. (Content of MLS channels stays ciphertext; public channels and the `~join` topic are plaintext, see A-17.)

### A-17 `topic_catchup` (replay a room's channel ring; includes the `~join` ring)
- ws_handler.cpp:2311-2312 -> `handle_topic_catchup` 1368-1393.
- Checks: not guest (1370), room/channel non-empty (1373), caller in room (1374-1375). Principal: relay socket membership only.
- State: none (read). Skips the requester's own frames (1386).
- Answer to the brief's question: YES, a socket can read a ring for a room it merely joined; the only gate is 1375 `!rit->second.peers.count(data->peer_id)`.
- What the `~join` ring holds: plaintext `ServerJoinRequest` with `device_list`, `twitch_proof_json`, `key_package` (sync_handler.rs:1166-1183 `HavenMessage::ServerJoinRequest { ... key_package: pending.key_package.clone(), })` ... `SendToRoomTopic { ... topic: super::types::JOIN_TOPIC` ) and `ServerJoinResolved` frames (sync_handler.rs:1204-1215).
- SUSPICION A-17a: any identity that knows a server id reads (and floods, A-23) the server's `~join` ring and every registered channel ring. CONFIRMED-BY-READING. Tests: harness injects tampered/legacy frames into the ring (test_harness.rs:19259, 19275, 19965, 20264) to test the CLIENT's verification; nothing tests who may READ the ring.

### A-18 `get_turn_credentials`
- Inline ws_handler.cpp:2313-2334. Not guest (2320); secret configured (2322). Credential `username = expiry + ":hollow"`, `password = hmac_sha1_base64(config.turn_secret, username)` (2327-2328): NOT bound to the requesting peer. Any authenticated identity (free) gets a 1 h TURN credential. By design (official relay open to all). SUSPICION: none new.

### A-19 `get_media_forwarder`
- Inline ws_handler.cpp:2335-2351. Not guest; returns static `config.forwarder_peer_id` (config.h:20, set only by `--forwarder-peer-id`, config.h:52) and `online` = `peer_sockets.count(...)`.
- "Forwarder registration": NOT FOUND as a relay command. The forwarder is an ordinary authenticated peer; the relay only advertises a startup-configured id. Nothing prevents another identity from joining `fwd:{forwarder_id}` (0.2).

### A-20 Binary 0x02 (targeted binary: WS stream frames: files, shards, link snapshots)
- Dispatch: ws_handler.cpp:2525-2527 -> `handle_binary_direct` 1590-1642.
- Checks: room exists (1615-1616), sender in room (1622), target shape (1627), target in room (1628-1629). No guest restriction (2508 covers 0x04/0x08/0x09 only).
- State: none stored; forwarded to target with `from` = sender (1631-1641).
- SUSPICION: none at the relay beyond A-02a. Client-side consequences in B-09.

### A-21 Binary 0x03 (room broadcast)
- 2528-2530 -> `handle_binary_msg` 1644-1679. Checks: room exists, sender in room (1655-1658). Guests: 10/min (2509-2518). Fan-out to all other room peers incl. guests/fetch (1674-1678), `from` stamped. Nothing stored.
- SUSPICION: none beyond A-02a (a silent fetch/guest lurker receives all room broadcasts).

### A-22 Binary 0x04 / 0x08 (targeted direct; offline deposit + DM push)
- 2531-2538 -> `handle_binary_direct_msg` 1681-1773. Guests refused (2508).
- Checks: target shape (1712). If the room does NOT exist: NO membership check at all, deposit + push (1715-1735; comment 1719-1722 "any authenticated peer can reach this branch with any room code and any target peer_id. That is deliberate"). If the room exists: sender in room (1738), then live delivery or deposit (1740-1772).
- State: `buffer_offline_msg` (905-984): fair-share eviction per target, per-sender key cap 4096 (state.h:106), global key backstop 65,536 that may evict the GLOBALLY oldest deposit for a sender holding <2 targets (offline_index.h:150-156 `return target_count(sender) >= 2 ? Admit::FreeOwnOldest : Admit::FreeGlobalOldest;`, ws_handler.cpp:870-891).
- Push: `try_push_notify` (1130-1168): target has a token, not `~dm`-muted for THIS sender device id (1137), 10 s debounce (1141), 30/h budget (1155-1162). Payload to sidecar `{token, platform, sender}` (693).
- Stale doc: comments claim a rate limit here (1723-1724 "it carries the rate limit AND the per-sender buffer share", 1501 "See OFFLINE_INJECT_PER_MIN") but `OFFLINE_INJECT_PER_MIN` is defined nowhere in relay-uws/src and 893-900 says "there is deliberately NO per-minute rate limit".
- SUSPICION A-22a (wake-up abuse): any identity can wake any device that registered a push token, 30 times an hour, by 0x04 to a non-existent room (1726-1730); per-sender muting cannot stop it because each fresh identity is a new sender. PLAUSIBLE nuisance (what the phone displays for an undecryptable frame is out of scope).
- SUSPICION A-22b (backstop eviction by Sybils): once 65,536 keys are held, a fresh single-target identity's deposit evicts the globally oldest deposit of anyone (ws_handler.cpp:925-927). Availability cache only. CONFIRMED-BY-READING.

### A-23 Binary 0x07 (topic broadcast; tees into the ring)
- 2539-2541 -> `handle_binary_topic_msg` 1789-1870. Checks: room exists, sender in room (1809-1812). NO guest limit (the per-minute guest counter at 2509-2518 applies to 0x03 only). Topic string unchecked (1806).
- State: if a ring `room\0topic` is registered and accepting, append (1833-1855) with FIFO eviction at 200 frames / 1 MB (1845-1852, state.h:74-75); fan-out to wildcard or subscribed peers (1857-1869).
- SUSPICION A-23a (ring flush): any room joiner can push 200 junk frames into the `~join` ring or any channel ring and evict every genuine parked join / catch-up frame; the client already notes the ring is shared ("a joiner that flaps every minute would own it within hours", swarm.rs:4011-4013). CONFIRMED-BY-READING (availability).

### A-24 Binary 0x09 (channel copy for an offline member + channel push)
- 2542-2546 -> `handle_binary_channel_direct` 1448-1513. Guests refused (2508).
- Checks: target shape (1481), sender in the named room (1484-1486). Target membership in the server: NOT checked (the relay cannot know; comment 1444-1445). Target in room -> drop (1495).
- State: deposit as a channel frame (1502-1507) and `try_channel_push_notify` (1399-1440) if the target has no socket; `mention` bit is sender-chosen (1470) and selects the short debounce and bypasses a "mentions" pref (1418, 1427) and the offline cap (1429).
- SUSPICION A-24a: a non-member who knows a server id can send "mention" pushes naming that server to any device with a token (subject to the 5 s / 10 s floors). PLAUSIBLE nuisance.

### A-25 Binary 0x00 / 0x01 / unknown
- 0x00 single byte = guest keepalive, ignored (2500-2502). 0x01 removed (1583-1588, 2522-2524). Unknown opcodes ignored (2547-2548).

### A-26 Socket close / cleanup_peer / supersede
- Close: ws_handler.cpp:2556-2587; shared cleanup only if `data->authenticated && !data->superseded` (2579) and only if the socket still owns the peer (2377-2378 `bool owns_peer = (sock_it == state.peer_sockets.end() || sock_it->second == expected_ws);`). Room slots erased only when they point at the closing socket (leave_room 597-603).
- Observation (not cross-peer): a FETCH socket of peer X joining a room overwrites X's full-node slot (526 `ws_room.peers[data->peer_id] = ws;` without a fetch guard); when the fetch socket closes, leave_room(…, expected_ws = fetch) erases that slot and the room from `peer_rooms[X]` (609, 619), silently detaching X's live full node from that room. Self-inflicted availability bug, same identity only.

### A-27 License keys (self-hosted only)
- license_pool.h:29-43: key must be in the file; up to 5 peer_ids per key (`MAX_DEVICES_PER_KEY = 5`, 23); released on owning-socket cleanup (ws_handler.cpp:2405). Kick on revocation: license.cpp:95-102. Distinguishable results = key validity oracle, documented as accepted (ws_handler.cpp:233-240). No cross-peer effect.

### A-28 HTTP endpoints
- http_handlers.cpp:169-179: `/health`, `/server-stats` (aggregate counters incl. `online_users`, 121-134), `/relay-status` (license_required, version, turn, forwarder flags, 151-156). All unauthenticated, no per-peer data. `/register`, `/bootstrap`, `/turn-credentials` removed (18-31, 38-44).

### A-29 Restart persistence (snapshot)
- Captured on SIGTERM only (main.cpp:199-202 `if (!should_shutdown.load()) return; ... snapshot_to_fdstore(*g_shutdown.state);`): offline buffer, opt-ins, topic rings, push tokens, kill list, push prefs (snapshot.cpp:32-73). NOT captured: nicknames, link codes, link-guess counters, `device_list_max_version` (A-02c), room memberships.
- Any abnormal exit (A-01a) loses all of it.

---------------------------------------------------------------------------
## PART B: client handling of relay data

### B-01 AuthOk / AuthFailed / Error
- Auth reply parsed ONCE in `connect_and_auth` (ws_client.rs:727-740): `Ok(ServerMsg::AuthOk) => ...reunite`, `Ok(ServerMsg::AuthFailed { error }) => Err(error)`, anything else `Err(format!("Auth rejected: {text}"))`. Later AuthOk/AuthFailed frames are ignored (ws_client.rs:1315).
- Relay-supplied error text decides reconnect policy: ws_client.rs:616-625 `if e.contains("license_key_in_use") { ... } else if e.contains("license_key") || e.contains("license key") { ... return; }` -> the WS task ENDS (no reconnect) on any relay reply containing that substring (the whole text is embedded in the `Auth rejected: {text}` branch too).
- `Error` (ws_client.rs:1257-1272): only "Too many rooms" acts: pops `last_join_attempt` from `joined_rooms` and emits RoomCapHit; the relay chooses which join it "refused" by timing.
- E2E impact: none. SUSPICION (P-01 only, low): a hostile relay can permanently stop the client's reconnect loop with one crafted auth reply (ws_client.rs:621-624). CONFIRMED-BY-READING.

### B-02 Connected
- swarm.rs:3092-3232. Because the relay said "connected": GetTurnCredentials (3100), GetMediaForwarder (3104), own inbox join with our master-signed device list as proof (3115-3132), re-deposit of every pending friend request into the target master's mailbox (3138-3155), joins of all server rooms (3157-3161), pending-join rooms (3166-3170), DM rooms for every friend (3171-3183), guest rooms + plaintext PublicChannelListRequest (3184-3197), push token + prefs (3221-3231).
- Nothing here is decided by relay-supplied ids; the room set is local state.

### B-03 Disconnected
- swarm.rs:3234-3301: clears `ws_room_peers`, `synced_peers`, ask tables, `requested_file_receipts`, `peer_auto_dl`, `relay_catchup_done`, `key_request_in_flight`, `key_bundle_sent_to`, `mls_bootstrap_requested`, `mls_welcome_grace`, removes every REMOTE voice participant (3284-3287), clears conference knockers (3291-3293), gossip overlays (3295-3300).
- Relay-triggerable (P-01 drops the socket): liveness/DoS only; the VC participant purge gates later inbound VC signals (comment 3389-3392).

### B-04 PeerJoined { room, peer_id }  (relay presence -> discovery cascade)
- Source: relay `peer_joined` (ws_handler.cpp:546-556), generated for ANY non-guest non-fetch joiner of ANY room (0.2). `peer_id` is the joiner's authenticated id (P-01: any string).
- Handler: swarm.rs:3302-3739. Writes/sends, in order, and the gate on each:
  1. swarm.rs:3304 `ws_room_peers.entry(room.clone()).or_default().insert(peer_id.clone());` (routing table) : no gate.
  2. asset/file ask retries to the joiner (3308-3320) : gate inside callee; for channel asks the only filter is file_asks.rs:555 `FileAskContext::Channel { server_id, .. } => server_id == room,` (any joiner of the server room becomes an asked holder).
  3. fwd room: Olm session + drain (3330-3338) : gate `is_fwd_room`.
  4. conference reknock (3343-3345), recovery inventory send (3348-3367, gate `room == pool.room_code()`), share Have (3371-3376).
  5. VC presence re-announce (3396-3420): for every VC we are in whose server id == room, send PLAINTEXT `VoiceChannelJoin { server_id, channel_id }` to the joiner via `send_message_to_peer_in_room` (crypto_handler.rs:2821-2832 plain `SendDirect` of JSON). Gate: `peer_id != local && != device` only; NO server-membership check of the joiner.
  6. Gossip overlay (3426-3433): `overlay.add_known_peer(&peer_id)` and `GossipConnect { peer_id: new_neighbor }`. Gate: none on membership. gossip.rs:245-249 `if self.neighbors.len() < MIN_GOSSIP_NEIGHBORS && !self.neighbors.contains(peer_id) { self.neighbors.insert(owned.clone()); return Some(owned); }` (MIN = 6, gossip.rs:9). Dart: event_provider.dart:1497-1498 `case NetworkEvent_GossipConnect(:final peerId): ref.read(webRtcProvider.notifier).ensureConnection(peerId);`.
  7. `is_new` block (3439-3690): PeerDiscovered to Dart; friend-request/removal/accept drains keyed by `resolver::resolve(&peer_id)` (3452-3531; accept gated on `holds_accepted_friend` + blocklist, 3522-3524); profile to the joiner (3534-3539, no gate); auto-dl advertise only to own sibling or the DM room counterparty (3544-3550); own-inbox joiner: `on_verified_sibling` only if `resolver::same_identity` else `issue_sibling_challenge` (3557-3572) (room membership is explicitly NOT trusted, comment 3552-3556); Olm KeyRequest to the joiner (3577-3591 -> ensure_olm_session_and_drain swarm.rs:121-133); server SyncRequest/MLS only if `state.members.keys().any(|k| super::resolver::same_identity(&peer_id, k))` (3596-3597); MLS KeyPackageRequest only when `is_mls_coordinator(..., &ws_room_peers)` (3635) i.e. relay presence decides WHO acts; DmSyncRequest to the joiner (3670-3688).
  8. pending server join -> `ServerJoinRequest` (with `twitch_proof_json`, `device_list`) to ANY joiner of that room (3694-3711).
  9. DM co-presence re-key (3728-3737) gate `room == dm_room_code(local, resolve(peer_id))`.
- Does relay presence decide E2E membership / key distribution / authority? MLS/CRDT sync: NO (gated on CRDT members through the resolver, 3597). Who we open Olm sessions and WebRTC with, who becomes a gossip neighbour, who receives our VC presence, profile, and pending join request: YES, relay presence alone.
- SUSPICION B-04a (non-member becomes a gossip neighbour): a stranger who knows a server id (≥6 members, swarm.rs:3956) joins the room and is added to `neighbors` with no CRDT membership check (3426-3433; also RoomMembers 3959-3963). Neighbours are dialled over WebRTC (Dart 1497-1498) and receive `PeerExchange` with the member device list (gossip_relay.rs:184-196). Once the data channel is connected, `flood_crdt_op` sends plaintext signed CRDT ops to connected neighbours and RETURNS before the member broadcast (sync_handler.rs:84-86 `if super::gossip_relay::flood_crdt_op(...) > 0 { return; }`; targets gossip.rs:464-474) : the stranger reads server structure and can withhold ops. CONFIRMED-BY-READING up to the dial; that the WebRTC channel reaches `connected_since` with a non-member is PLAUSIBLE (RtcOffer arm swarm.rs:13791-13811 gates only on blocklist).
- SUSPICION B-04b (voice-channel presence leak): step 5 sends `VoiceChannelJoin{server_id, channel_id}` in plaintext to any socket that joins the server room (3396-3419). Mallory = ex-member/anyone with the server id. CONFIRMED-BY-READING.
- SUSPICION B-04c (sessions + WebRTC with any room joiner): steps 7/`ensure_olm_session_and_drain` KeyRequest any joiner of any shared room (incl. our own inbox); `SessionEstablished` makes Dart dial WebRTC with no gate (event_provider.dart:531-536 `case NetworkEvent_SessionEstablished(:final peerId): ... ensureConnection(peerId);`; webrtc_service.dart:316-340 no friend/member check), exposing host/srflx ICE addresses to a stranger who merely joined `inbox:{our master}`. PLAUSIBLE (did not follow the KeyBundle/SessionAck completion for an unbound stranger device nor the ICE policy).
- Transport parity: RoomMembers (B-07) runs the same cascade for peers already present; DiscoveredPeers (B-12) runs only the KeyRequest leg.
- Tests: `friend_request_between_strangers_does_not_merge` (test_harness.rs:8661) covers the sibling-challenge leg. No test that a non-member room joiner is refused as gossip neighbour / VC re-announce target: none found.

### B-05 PeerLeft { room, peer_id }
- swarm.rs:3750-3873. Removes from `ws_room_peers` (3752-3757); embedded forwarder `peer_gone` for our `fwd:` room (3762-3765); drops sibling challenge (3769); share forget (3773-3775); conference knocker + call tile removal (3779-3785); recovery pool member removal (3787-3807); gossip neighbour removal/replacement (3814-3823); removes the peer from EVERY voice participant set of that server and emits VoiceChannelLeft (3824-3849); PeerDisconnected if in no room, else re-join those rooms (3851-3872).
- Only the relay generates `peer_left` for a departing socket (ws_handler.cpp:632-645); a peer cannot forge it for another peer. P-01 can: VC eviction, call-tile removal, forwarder stream teardown (DoS only, no key or membership change).
- SUSPICION: none beyond P-01 DoS.

### B-06 LeftRoom { room }
- Local, emitted by ws_client on our own leave (ws_client.rs:1169-1177). swarm.rs:3740-3749 purges `ws_room_peers[room]`. Not relay data.

### B-07 RoomMembers { room, peers }  (authoritative roster)
- swarm.rs:3874-4384. Replaces `ws_room_peers[room]` with the relay's list (3909); peers that vanished -> embedded fwd `peer_gone`, conference roster removal, PeerDisconnected (3929-3951); gossip overlay adds EVERY listed peer (3955-3963) and may emit initial neighbours (3964-3971); relay catch-up + `~join` catch-up requests (3981-4008); fwd-room Olm (4028-4039); first-roster profile broadcast to every listed peer (4044-4058); per-peer `is_new` cascade identical in shape to B-04 (4074-4275): profile (4087-4092), ProfileRequest (4105-4113), proxy ProfileRequestFor only for peers `state.is_member(pid_str)` (4121), SyncRequest only for members (4147-4180), MLS KeyPackage only for identity-members (4186-4203), sibling challenge (4214-4231), Olm KeyRequest (4236-4250), DmSyncRequest (4255-4273); friend drains outside `is_new` (4283-4343); ServerJoinRequest to every listed peer if pending (4348-4365); DM re-key (4372-4381).
- Same authority split as B-04. SUSPICION: B-04a (gossip) applies here too (3959-3963); no new ones.

### B-08 Message / DirectMessage { room, from, data }  (all HavenMessage traffic)
- Sources: 0x05 (room broadcast), 0x06 (targeted / replayed buffer / mailbox), 0x08 (topic, incl. ring replay): ws_client.rs:521-552.
- swarm.rs:4560-4939: UTF-8 + HavenMessage parse, per-`from` token bucket (4576-4596), then: recovery interception (4600-4838, see B-08a), share interception (4843-4881), else `handle_incoming_request(..., &local_peer_str, &from, ...)` (4887-4934). `room` not forwarded (0.4). `from` unvalidated (0.3).
- SUSPICION B-08a (recovery pool accepts messages from any room and any sender): while `recovery_pool_state` is Some, `RecoveryStop` from anyone ends the pool (4731-4742, no check); `RecoveryTransferPlan` from anyone makes us stream our shards to the plan's `dest_peer` whenever `assignment.source_peer == local_peer_str` (4761-4833; 4793-4814 `cs.read_shard_unchecked(&pool.server_id, &sk)` then `ws_stream_send(... &pool.room_code(), &assignment.dest_peer, ...)`), and plans are only honoured from the frame, not from the pool's elected coordinator; `RecoveryWelcome` adds `from` as a member (4669-4677). Neither `room == pool.room_code()` nor pool membership of `from` is checked for any of these arms (only RecoveryHello checks `server_id == pool.server_id`, 4613). Mallory = any peer sharing ANY room with the victim during a recovery (a DM friend, a server co-member, a stranger in our inbox) who also joins the recovery room (token in the room name is visible to the relay). Shard confidentiality depends on the vault layer (not checked). CONFIRMED-BY-READING for the missing gates; impact PLAUSIBLE.
- Tests: `recovery_pool_membership_forms` (test_harness.rs:6053) is positive only.

### B-09 BinaryDirect { from, data }  (WS stream frames)
- swarm.rs:4385-4418 -> `ws_stream_receive` (ws_stream_transfer.rs:300-429) -> `handle_completed_stream(completed, &from, ...)` (file_handler.rs:2214-2254).
- Checks: id allowlist only (ws_stream_transfer.rs:315-318, 342-345; `parse_id` 475-483 `b.is_ascii_alphanumeric() || matches!(b, b':' | b'_' | b'-')`). The transfer table is keyed by id ONLY (ws_stream_transfer.rs:321 `let state = pending.get_mut(&id)?;`, 370 `if let Some(state) = pending.get_mut(&id) {`): continuation chunks from ANY sender append to a transfer another peer started. Sender binding: NONE FOUND in the receive layer.
- LinkSnapshot branch: file_handler.rs:2237-2241 -> `handle_link_snapshot_stream` 2261-2320: only `pending_link_snapshots.remove(&link_id)` (2275); `sender_peer` is used only for the ack (2302-2305).
- SUSPICION B-09a (remote identity replacement / destruction via an unsolicited link snapshot; cross-area with HavenMessage::LinkSnapshotKey): (1) `LinkSnapshotKey` from ANY peer registers a pending link with OUR `my_link_code()` (swarm.rs:12874-12881 `link_handler::handle_inbound_link_key(pending_link_snapshots, &link_id, link_handler::my_link_code(),`); no check that we are linking (`pending_link_resolve`) or that the sender is the peer `LinkCodeResolved` named. `my_link_code()` is `""` unless set (link_handler.rs:34-35 `.unwrap_or_default()`), or our MASTER ID after a mnemonic auto-request (swarm.rs:341 `link_handler::set_my_link_code(local_peer_str);`), or the typed code; all attacker-known. (2) A 0x02 stream with that id is accepted from any sender and stashed: file_handler.rs:2289-2290 `crate::api::storage::stash_pending_link(&blob, &state.code)` (api/storage.rs:1727-1733 writes `pending_link.hollow` + `pending_link.code`). (3) On the NEXT launch, hollow_shell.dart:694-695 `if (await storage_api.hasPendingLink()) { await storage_api.importPendingLink(); }` runs `import_pending_link`, which DELETES `identity.key`, `identity.device`, `messages.db` FIRST (api/storage.rs:1753-1759) and then imports the blob (1761). Exploit: Mallory (stranger) joins `inbox:{AliceMaster}` (0.2), sends plaintext `LinkSnapshotKey{link_id:"link_x"}` then a TYPE_LINK stream "link_x" holding a `.hollow` blob encrypted under Argon2id("") (api/storage.rs:1690-1701, empty passphrase not rejected). Alice's next start replaces her identity with Mallory's chosen one; a junk blob instead leaves her with NO identity and NO message DB. P-01 needs no room join. Tests: none found (no `LinkSnapshotKey` in test_harness.rs). CONFIRMED-BY-READING (argon2 accepting an empty password not verified; the destructive delete-before-import holds either way).

### B-10 KillSignal { blob, issued_at_ms }  (up to the destroy.rs hand-off)
- Source: relay at auth (ws_handler.cpp:329-332) from the kill list (A-12). Parsed ws_client.rs:1305-1310 (`#[serde(default)]` on both fields, ws_client.rs:299).
- swarm.rs:4419-4425 -> `destroy::handle_kill_signal(&event_tx, &ws_cmd_tx, &blob, &master_peer_str, &device_peer_id, ...)` (destroy.rs:237-257). Hand-off: undecodable -> KillAck (246-249); `apply_own_order` verdict; permanent rejection -> KillAck (254-256). `issued_at_ms` from the relay is logged only (4420).
- Relay-supplied data trusted for authority: the blob only (verified downstream). The ACK side effect lets a third-party junk deposit erase the genuine entry (A-12a).

### B-11 PeerStatus { online }
- swarm.rs:4437-4454: for each relay-listed id, JoinRoom `dm_room_code(local, resolve(id))` and our inbox. Relay presence decides only which deterministic rooms we (re)join; P-01 can make us join rooms of its choosing up to the 2000 budget (ws_client.rs:305). No E2E effect.

### B-12 DiscoveredPeers { room, peers }
- swarm.rs:4455-4478: inserts every listed id into `ws_room_peers[room]` (4460-4467) and sends a signed KeyRequest to each id lacking a confirmed session (4468-4477). Requested for our active room and every server id on a timer (swarm.rs:5174-5183). Relay reply includes guest/fetch lurkers (A-07). Same authority split as B-04c: relay presence decides whom we key-exchange with; nothing about membership.

### B-13 NicknameResolved { nickname, peer_id, master_id }
- swarm.rs:4493-4520. Gate: only answers to our own pending resolve (4494 `if pending_nickname_resolve.as_deref() == Some(&nickname) {`).
- Target selection: 4505-4509 `let target = if !master_id.is_empty() { master_id } else { super::resolver::resolve(&peer_id) };` -> `social::handle_send_friend_request(..., target, ...)`.
- Is `master_id` trusted to bind a device to a master? NOT FOUND anywhere: the arm only READS the resolver (4508) and the comment 4502-4504 states "NEVER feed it into `resolver`". Inside the callee the resolver is only read (social.rs:449, 465, 498, 505) and the friend row is keyed on it: social.rs:505-514 `let master = super::resolver::resolve(&peer_id_str); ... store.migrate_friend_to_master(&peer_id_str, &master); ... store.save_friend(&master, "pending", "outgoing", now);`, room joins social.rs:521-530, request built for that master (538-541).
- Binding nickname -> identity: NONE (claimer-chosen `master`, A-09). The request is only an Olm-bundled request to whichever master the claimer/relay named; a friendship still needs that master's device to answer.
- SUSPICION (low, by design): the relay or the claimer decides which identity a nickname friend request goes to; the UI must not present the result as "the person who owns nickname X". CONFIRMED-BY-READING.

### B-14 LinkCodeResolved { code, peer_id }
- swarm.rs:4551-4559: acted on only if `pending_link_resolve` matches `code` (4552-4553); then `link_handler::handle_link_code_resolved(&ws_cmd_tx, &ws_room_peers, &peer_id, ...)` sends `LinkSnapshotRequest` to the relay-named `peer_id` (link_handler.rs:80-96).
- What decides the identity we will import: NOT the resolved `peer_id`. The inbound `LinkSnapshotKey` and the stream are accepted from ANY sender (B-09a); nothing compares the snapshot's sender, nor the imported master, to `peer_id`.
- SUSPICION B-14a (P-01 hands a fresh device an identity the relay controls): the relay knows the code (A-10), answers `link_code_resolved` with a peer id it controls, then sends `LinkSnapshotKey` + a snapshot encrypted with that code; the empty device stashes and imports it on restart (api/storage.rs:1745-1761). The user believes they linked to their own account but now uses keys the relay holds. CONFIRMED-BY-READING for the missing sender/identity binding.

### B-15 MediaForwarderInfo { peer_id, online }
- swarm.rs:4532-4536 forwards to Dart; forwarder_info_provider.dart:34-35 `void setInfo({required String peerId, required bool online}) { state = ForwarderInfo(peerId: peerId, online: online);`. No pin, no signature: the relay's static config (A-19) decides which peer id receives forwarded media legs. Media confidentiality rests on SFrame (out of scope). SUSPICION (P-01, low): relay chooses the forwarder identity. CONFIRMED-BY-READING.

### B-16 TurnCredentials { username, password, ttl, uris }
- ws_client.rs:1237-1246; swarm.rs:4523-4531 -> embedded forwarder STUN source (4527) and Dart `NetworkEvent::TurnCredentials` (iceConfigProvider per CLAUDE.md). URIs and creds are relay-chosen, unvalidated. P-01 can point every client's TURN at a server it runs (metadata / DoS; DTLS integrity depends on SDP integrity, and general data-channel SDP rides PLAINTEXT `RtcOffer`/`RtcAnswer` HavenMessage arms, swarm.rs:13791-13825, so P-01 can already MITM those channels by rewriting SDP; out of this scope).

### B-17 RoomBudgetUpdate / RoomCapHit / LicenseError / Connecting
- swarm.rs:4426-4436, 3089-3091: UI events only. No authority.

---------------------------------------------------------------------------
## Answers to the specific questions in the task

- Which room names can ANY authenticated socket join? All of them (0.2): `inbox:*`,
  DM rooms, `link:*`, `fwd:*`, `conf:*`, server rooms, `share:*`, `recovery:*`.
  `~join` is a topic inside the server room, reachable by joining the server room.
  Guests: any 3 rooms. Proof only gates the inbox MAILBOX replay (A-02).
- Can a socket read a ring for a room it merely joined? Yes (A-17, ws_handler.cpp:1374-1375).
- How is `from` produced? Relay-stamped from the authenticated socket at every
  relay site (0.3); the client never validates it and cannot distinguish a relay
  that lies (P-01).
- Relay auth: challenge = none (client-chosen timestamp, ±60 s); peer_id = derive(pubkey)
  (ws_handler.cpp:219-220, crypto.cpp:77-100); signed string lacks relay identity (A-01b);
  pre-auth crash (A-01a). Mailbox ownership proof = master-signed device list +
  device membership + RAM-only version high-water (A-02).
- One peer changing another peer's relay state: kill-list entries (overwrite + global
  eviction, A-12), shared topic rings (register/clear/flush, A-16/A-23), offline
  buffer entries (fair share / global backstop eviction, A-22b), push wake-ups
  (A-22a/A-24a), report counts (A-15). NOT possible: push tokens, push prefs,
  opt-ins, nicknames, link codes, license slots (all keyed by the authenticated id)
  except through A-01b.
- Relay presence / relay ids deciding E2E membership, key distribution, whom we
  encrypt to, authority: CRDT/MLS membership and MLS adds are gated on CRDT members
  via the resolver (swarm.rs:3597, 4148, 4187), NOT on presence. Presence DOES decide:
  whom we Olm key-exchange with (B-04/B-07/B-12), whom we dial WebRTC and pick as
  gossip neighbours (B-04a, then plaintext CRDT ops flow to them), who gets our VC
  presence and pending join requests (B-04b), who acts as MLS coordinator (3635), and
  (via the absent binding) whose link snapshot we import (B-09a/B-14a).
  `NicknameResolved.master_id` is never written to the resolver (B-13).

---------------------------------------------------------------------------
## SUSPICIONS (one line each)

1. A-01a PRE-AUTH RELAY CRASH: `handle_auth` calls `j.value()` outside any try (ws_handler.cpp:182-189, dispatched unguarded at 2484); a wrong-typed field throws (json.hpp:22500) and kills the relay without the SIGTERM snapshot (main.cpp:199-202). CONFIRMED-BY-READING.
2. B-09a REMOTE IDENTITY WIPE/REPLACEMENT: `LinkSnapshotKey` from any sender registers a link with an attacker-known code (swarm.rs:12874-12881, link_handler.rs:34-35), any sender's TYPE_LINK stream is stashed (file_handler.rs:2275, 2289-2290), next launch deletes identity.key+messages.db before importing (hollow_shell.dart:694-695, api/storage.rs:1753-1761). CONFIRMED-BY-READING.
3. B-14a relay-resolved link peer is not bound to the imported snapshot; P-01 can give a linking device a relay-controlled identity (swarm.rs:4551-4559, link_handler.rs:80-96, file_handler.rs:2275). CONFIRMED-BY-READING.
4. A-10a link-code throttle bypass: unthrottled `claim_link_code` "taken" oracle (ws_handler.cpp:2008-2011) and `join link:{CODE}` roster (ws_handler.cpp:536-541) enumerate live codes, then a spoofed LinkSnapshotRequest phishes the full backup (swarm.rs:12865-12871, 2182-2185). CONFIRMED oracles, PLAUSIBLE rate.
5. A-12a kill-list overwrite: any authenticated peer replaces a parked destroy order with junk + huge issued_at_ms (ws_handler.cpp:1220, kill_list.h:63, 103-107); the target then acks the junk (destroy.rs:246-249) and the genuine order is lost. CONFIRMED-BY-READING.
6. A-12b kill-list global eviction by Sybils (kill_list.h:24-25, 109, 123-133). CONFIRMED-BY-READING.
7. A-02a/A-02b room joins are ungated; silent fetch/guest joins return the roster, making `inbox:{master}` and DM rooms a presence/friendship oracle and voiding the check_peers/discover_peers hardening (ws_handler.cpp:490-541, 188-189, 545, 2214-2227, 2265-2270). CONFIRMED-BY-READING.
8. A-01b auth signature not bound to a relay/nonce: a hostile relay replays it to another relay within 60 s to act as the victim device (supersede, kill_ack, push token, buffer drain) (ws_client.rs:701, ws_handler.cpp:198-199, 226). PLAUSIBLE.
9. A-16a server-owner ring opt-in enforced only by room membership: any id with the server id enables/extends/clears retention (ws_handler.cpp:1309-1310, 1326-1357). CONFIRMED-BY-READING.
10. A-17a any id with the server id reads the `~join` ring (plaintext join requests with device list, KeyPackage, twitch proof) and every channel ring (ws_handler.cpp:1374-1375; sync_handler.rs:1166-1183). CONFIRMED-BY-READING.
11. A-23a ring flush: any room joiner evicts parked joins / catch-up frames with 200 junk 0x07 frames; guests unthrottled on 0x07 (ws_handler.cpp:1845-1852, 2509-2518). CONFIRMED-BY-READING.
12. B-04a non-member room joiner becomes a gossip neighbour (no CRDT membership check) and, once connected, receives plaintext CRDT ops that then skip the member broadcast (swarm.rs:3426-3433, 3955-3963; gossip.rs:245-249; sync_handler.rs:84-86). CONFIRMED up to the dial, PLAUSIBLE end to end.
13. B-04b plaintext `VoiceChannelJoin` re-announce to any joiner of the server room, no membership check (swarm.rs:3396-3419). CONFIRMED-BY-READING.
14. B-04c relay presence alone triggers Olm KeyRequests and, via SessionEstablished, ungated WebRTC dials to strangers in our inbox/server rooms (swarm.rs:121-133, 3577-3591; event_provider.dart:531-536; webrtc_service.dart:316-340). PLAUSIBLE (IP exposure).
15. B-08a recovery-pool arms accept RecoveryStop/TransferPlan/Welcome from any sender in any room; a forged plan makes us stream shards to a chosen dest_peer (swarm.rs:4731-4742, 4761-4833, 4669-4677). CONFIRMED missing gates, PLAUSIBLE impact.
16. B-09 WS stream transfers keyed by id only: continuation chunks from any sender append to another sender's transfer (ws_stream_transfer.rs:321, 370). CONFIRMED-BY-READING.
17. A-22a / A-24a push wake-ups to any device with a token by any fresh identity (0x04 to an empty room, 0x09 with sender-chosen mention bit); `~dm` mute is per sender device (ws_handler.cpp:1726-1730, 1137, 1470, 1418-1429). PLAUSIBLE nuisance.
18. A-22b offline-buffer global key backstop lets single-target Sybils evict others' deposits (offline_index.h:150-156, ws_handler.cpp:925-927). CONFIRMED-BY-READING (availability only).
19. A-02c revoked sibling regains mailbox reads after any relay restart (RAM-only version marks, ws_handler.cpp:449-452, snapshot.cpp:32-73). CONFIRMED-BY-READING (documented).
20. A-05 JSON `direct` lets guests deposit + push despite the "no SendDirect for guests" binary filter (ws_handler.cpp:1539-1569 vs 2508). CONFIRMED-BY-READING (low).
21. A-15 report counts Sybil-inflatable (ws_handler.cpp:1282-1295, reports.cpp:206-215). CONFIRMED-BY-READING (low).
22. B-01 a relay reply containing "license_key" permanently stops the client's reconnect loop (ws_client.rs:621-624). CONFIRMED-BY-READING (P-01 DoS, low).
23. B-13 / A-09 nickname `master_id` is claimer-chosen and relay-returned, used as the friend-request target and friend-row key (ws_handler.cpp:1936-1937; swarm.rs:4505-4509; social.rs:505-514); never written to the resolver. CONFIRMED-BY-READING (by design, low).
24. Stale security comments: ws_handler.cpp:1723-1724 and 1501 cite a rate limit / `OFFLINE_INJECT_PER_MIN` that does not exist (contradicted by 893-900). CONFIRMED-BY-READING (doc only).
