# Design A inventory: the relay (auth, rooms, rings, relay-originated messages)

Evidence for design session A. Read against the working tree of 2026-09-27
(HEAD a71e72fa plus uncommitted edits). Every line number below was re-read in
this pass; `phase_b_evidence/authz_relay.md` was used for hints only and its line
numbers are stale.

CAUTION: `node/swarm.rs` was being edited by another session DURING this pass
(uncommitted frame-seal wiring, see E.18). Its numbers here were refreshed at the
end of the pass (+2 from line ~570, +24 from line ~4578 versus HEAD) and may drift
again; the quoted text is the stable anchor. All other files did not move.

Attackers: **P-01** = a fully malicious relay operator (any relay the client
talks to). **S** = a stranger or ordinary client on an HONEST relay who knows a
server id, a master id or a device id. "Fresh keypair" = any identity: the relay
has no registration, so S can always authenticate as a new full (non-guest) peer.

Paths: `relay/` = `relay-uws/src/`, `node/` = `rust/hollow_core/src/node/`,
`lib/` = `lib/src/`.

---------------------------------------------------------------------------

## A. Auth handshake (A17)

### A.1 What the client signs
- Device key, not master: node/swarm.rs:470-473 `spawn_ws_client( ws_relay_url, device_peer_id.clone(), ws_proto, ws_pub_b64, license_key, false, ...`
- Timestamp = client wall clock, seconds: node/ws_client.rs:698-701 `let timestamp = std::time::SystemTime::now() ... .as_secs();`
- Signed string: node/ws_client.rs:703 `let sign_payload = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);`
- Frame: node/ws_client.rs:710-717 `ClientMsg::Auth { peer_id, public_key, timestamp, signature: sig_b64, license_key, fetch }`; serde shape node/ws_client.rs:245-254 (`fetch` omitted when false, `license_key` omitted when None). No `guest` field: the Rust client is never a relay guest.
- Sent immediately after the WS upgrade; the relay sends nothing first (relay/ws_handler.cpp:2448-2492 `.open` only arms the 10 s auth timer `}, 10000, 0);`). No server challenge, no nonce.
- Domain tag: the literal prefix `hollow-ws-auth:`. Other device/master signers seen use distinct prefixes (`hollow-sibling:` node/crypto_handler.rs:951, `hollow-devices:` relay/device_list.cpp:27, MLS labelled content). A full scan of every device-key signer for a peer-controlled raw payload: UNTRACED.
- Relay binding: NONE. The relay URL/domain is not in the signed string.
- NOT covered by the signature: `fetch`, `guest`, `license_key` (relay/auth_frame.h:56-58 parses them as independent fields; relay/ws_handler.cpp:221 signs only peer_id and timestamp).

### A.2 Where the relay verifies
- Pre-auth parse never throws, 16 KiB cap: relay/auth_frame.h:29 `MAX_AUTH_FRAME_BYTES = 16 * 1024;`, :33 `nlohmann::json::parse(message, nullptr, /*allow_exceptions=*/false);`; dispatched only while unauthenticated relay/ws_handler.cpp:2499-2505 inside `try`.
- Window: relay/ws_handler.cpp:24 `TIMESTAMP_SKEW_SECS = 60;`, :193-194 `uint64_t diff = (now > timestamp) ? (now - timestamp) : (timestamp - now); if (diff > TIMESTAMP_SKEW_SECS) {`. Symmetric, so one frame is acceptable for about 120 s of relay wall-clock.
- peer_id bound to key: relay/ws_handler.cpp:214-215 `std::string derived_peer_id = derive_peer_id(public_key); if (derived_peer_id.empty() || derived_peer_id != peer_id) {`
- Signature: relay/ws_handler.cpp:221-222 `std::string signed_msg = "hollow-ws-auth:" + peer_id + ":" + std::to_string(timestamp); if (!verify_ed25519(public_key, signature, signed_msg)) {` (libsodium, relay/crypto.cpp:38 `return crypto_sign_verify_detached(`).
- License outcome oracle (documented as accepted): relay/ws_handler.cpp:236-253.
- No replay cache of any kind: nothing between :221 and `data->authenticated = true;` (:257) records the signature or timestamp.
- Supersede: a non-fetch auth for a peer_id evicts the live socket, silently: relay/ws_handler.cpp:291-309 `if (!data->is_fetch) { auto existing = state.peer_sockets.find(peer_id); ... cleanup_peer(state, peer_id, ghost, /*suppress_peer_left=*/true); ghost->end(1000, "superseded");`
- A fetch auth supersedes nothing and is not registered in `peer_sockets` (same block, gated on `!data->is_fetch`).
- Parked kill signals delivered right after `auth_ok`: relay/ws_handler.cpp:326-330 `if (const auto* kills = state.kill_list.find(peer_id)) { for (...) send_json(ws, {{"type", "kill_signal"}, {"blob", kill.blob}, {"issued_at_ms", kill.issued_at_ms}});`

### A.3 Client side of the reply
- Waits 5 s for ONE frame: node/ws_client.rs:723 `tokio::time::timeout(Duration::from_secs(5), read.next())`.
- node/ws_client.rs:731-738 `Ok(ServerMsg::AuthOk) => ... Ok(ServerMsg::AuthFailed { error }) => { Err(error) } _ => Err(format!("Auth rejected: {text}"))` (feeds D).
- Nothing authenticates the relay to the client beyond TLS to the configured domain (webpki roots). No relay-signed statement exists anywhere in the protocol.

### A.4 Can a captured frame be replayed?
- Capture: TLS terminates at the relay process (native TLS), so only the operator of a relay the victim connects to (P-01) sees the frame. S on an honest relay cannot capture one.
- Same relay, within the window: YES (no cache). Pointless for that relay's own operator, who already controls it.
- ANOTHER relay, within the window: YES. The signed string names no relay and every relay accepts any keypair (license keys only on self-hosted relays; the key rides the same captured frame, unsigned).
- When a victim talks to a second relay today: after accepting a relay switch from an invite (lib/ui/dialogs/relay_switch_dialog.dart:30-48, "NEVER switches on its own", then restart), or a self-hosted setup. Every reconnect mints a fresh frame, so an operator of relay B holds a steady supply for as long as the victim stays on B.
- Effects on relay A of a replayed frame (all keyed to the victim DEVICE id):
  - non-fetch replay: evicts the victim's live socket (A.2 supersede); the victim's 1 s reconnect evicts it back. Flap, not persistence.
  - `fetch:true` replay (flag unsigned): coexists with the live victim indefinitely (not in `peer_sockets`, supersedes nothing, emits no `peer_joined`, relay/ws_handler.cpp:543).
    - Its `join` overwrites the victim's room slot: relay/ws_handler.cpp:524 `ws_room.peers[data->peer_id] = ws;`. From then on 0x02/0x04/0x05/0x08 addressed to the victim device in that room go to the attacker socket, silently. When the attacker closes, `leave_room(..., expected_ws=attacker)` erases the slot (relay/ws_handler.cpp:595-607) and the victim is no longer in the room at the relay, with no `peer_left` (fetch = invisible, :605 + :629).
    - Its `leave` is forced (`leave_room(state, data->peer_id, j.value("room", ""))`, relay/ws_handler.cpp:2218, `expected_ws` null) and removes whichever socket holds the slot, broadcasting `peer_left` for the victim.
    - Drains the victim device's offline buffer: `replay_buffered_msgs` deletes on delivery (relay/ws_handler.cpp:997-1009).
    - Opens the victim master's inbox mailbox with the (public) signed device list (relay/ws_handler.cpp:451-483; check (c) is only "socket authenticated as a listed device").
    - Reads and ACKs the victim device's parked kill signals: `kill_ack` without a stamp clears all (relay/kill_list.h:91-98), so a stolen device's pending destroy order can be deleted.
    - Registers/unregisters the victim's push token, replaces push prefs wholesale (relay/ws_handler.cpp:1263 `state.push_prefs[data->peer_id] = std::move(prefs);`), toggles its offline opt-in, claims nicknames and link codes, sends any frame with relay-stamped `from` = victim device.
- Window arithmetic: the 60 s only bounds the START; an authenticated socket then lives as long as it answers pings (`idleTimeout = 120`, relay/ws_handler.cpp:2444).

---------------------------------------------------------------------------

## B. Room joins (I4)

### B.1 What a join requires at the relay
- Name shape only: relay/ws_handler.cpp:121-129 `if (room.empty() || room.size() > 128) return false; ... c != ':' && c != '-' && c != '_' && c != '.'`
- Count only: relay/ws_handler.cpp:25 `MAX_ROOMS_PER_PEER = 10000;`, :497 `size_t max_rooms = data->is_guest ? MAX_GUEST_ROOMS : MAX_ROOMS_PER_PEER;` (guests 3, relay/state.h:25).
- No proof for any prefix. `inbox_proof` gates only the mailbox replay, never the join: relay/ws_handler.cpp:577-579 `if (inbox_proof) { maybe_replay_inbox_mailbox(ws, data, room, *inbox_proof, state); }`.
- Join and leave are unthrottled; a socket can cycle joins freely.

### B.2 What any joiner LEARNS / RECEIVES (relay side)
- Roster on every join (redundant ones too): relay/ws_handler.cpp:534-539 `{"type", "members"}, {"room", room}, {"peers", all_peers}`; excludes guests and fetch sockets (:506-510, :531).
- Presence stream: `peer_joined` / `peer_left` for every later non-guest, non-fetch change (:543-555, :629-643). Fetch sockets DO receive them (:551 filters guests only).
- `discover_peers` (membership required) returns EVERY socket in the room, guests and fetch sockets included: relay/ws_handler.cpp:2285-2289 `for (const auto& [pid, sock] : rit->second.peers) { if (pid != data->peer_id) peers.push_back(pid);`. A fetch socket in a DM or server room is a phone woken by a push: push-timing leak.
- `check_peers` answers for co-members of any shared room (relay/ws_handler.cpp:2244-2256 `if (!co_members.count(peer_id)) continue;`); joining a room makes its members co-members.
- All live 0x03 (as 0x05) and 0x07 (as 0x08) traffic of the room: fan-out loops relay/ws_handler.cpp:1683-1687 and :1871-1883. A socket with no `subscribe` is a wildcard (:1876-1878 `No subscriptions for this room ... send everything`).
- Offline-buffer replay only for frames addressed to the joiner's OWN id (relay/ws_handler.cpp:571 `replay_buffered_msgs(ws, data->peer_id, room, ...)`).
- Every "sender must be in the room" gate (0x02 :1631, 0x03 :1667, 0x04 :1748, 0x07 :1822, 0x09 :1492, `set_topic_buffer` :1316, `topic_catchup` :1381) therefore reduces to "knows the room name".
- SILENT observer: authenticate a fresh keypair with `fetch:true`. It gets the roster and the presence stream and can read rings (C.2), but is absent from `members` and never triggers `peer_joined`, so members' clients never see it.

### B.3 Room names in use (formation in the client) and who can compute them

| Room | Formed at | Guessable from | S learns / receives by joining |
|---|---|---|---|
| `inbox:{master}` | node/swarm.rs:3122 `let inbox_room = format!("inbox:{}", local_peer_str);` (own); node/social.rs:558 `format!("inbox:{}", peer_id_str)` (request target); node/social.rs:297-307 deposit | the master id (profiles, member lists, friend requests, nickname resolve) | roster of the owner's ONLINE devices (device ids), their presence; ALSO every requester currently holding a pending request to that master (they "STAY while the request is pending", node/social.rs:295). Owner's cascade toward S (B.4). Mailbox NOT replayed without proof. |
| DM room | node/types.rs:43-50 `let combined = format!("dm-{}-{}", sorted[0], sorted[1]); let hash = Sha256::digest(...); hex::encode(&hash[..16])` | both master ids | whether both parties' devices sit in their DM room right now (every friend's DM room is joined on connect, node/swarm.rs:3179-3185) = friendship + presence oracle. This voids the removed `active_rooms` probe (relay/ws_handler.cpp:2259-2265 comment) because the join roster answers the same question. Both parties' cascades toward S. |
| server room = server id | node/swarm.rs:3163-3167 (members), :3172-3176 (pending joins), :3190-3193 (in-app guest browse; the Rust client auths as a FULL socket, no guest flag) | invite link (fragment), any current or FORMER member (kicked/banned keep the id) | full roster; all 0x03: `ChannelNotificationHint` plaintext per post (B.5), `PublicChannelMessage`, `PublicChannelConfigChanged`, `MlsChannelMessage` wrappers, `MlsCommit` (0x03, node/crypto_handler.rs:3084-3087; OpenMLS 0.9 default is `PURE_CIPHERTEXT_WIRE_FORMAT_POLICY`, openmls config.rs:642-644, so commit content is encrypted); all 0x07 channel traffic; ring reads and writes (C). |
| `~join` | TOPIC inside the server room, not a room: node/types.rs:791 `pub(crate) const JOIN_TOPIC: &str = "~join";` | server id | the join ring (C.3). |
| `link:{CODE}` | node/link_handler.rs:89-91 `format!("link:{}", code.to_uppercase())` | 6 chars over `'ABCDEFGHJKMNPQRSTUVWXYZ23456789'` (lib/core/providers/device_link_sync_provider.dart:130), 31^6 | roster = code liveness + the populated device id, bypassing the RELAY-5 resolve throttle (relay/ws_handler.cpp:2107-2126 throttles `resolve_link_code` only). Then a `LinkSnapshotRequest` passes node/link_handler.rs:73-86 `link_request_allowed` (room membership). Known I8 / HOL-SEC-002. |
| `fwd:{id}` | node/swarm.rs:2715-2719 `format!("fwd:{forwarder_peer_id}")`; node/embedded_forwarder.rs:68-70 `format!("fwd:{}", self.device_peer_id)` | VPS forwarder id (relay-advertised to any socket, relay/ws_handler.cpp:2361-2363); a peer forwarder's device id | roster = who is currently using that forwarder (sharers and viewers of live streams). An embedded forwarder runs the Olm path for any joiner (node/swarm.rs:3336-3344). |
| `conf:{id}` | node/conference.rs:35-43 `format!("{CONF_SID_PREFIX}{conf_id}")`, join :264 | meeting link | roster; every `ConferenceJoinRequest` knock, broadcast on 0x03 in plaintext with `display_name`, `avatar_hash`, KeyPackage and `access_hash` (node/conference.rs:264-272). See B.5. |
| `share:{root}` | node/share_handler.rs:32, :48 `format!("{SHARE_ROOM_PREFIX}{}", self.root_hash_hex())` | share link root hash | roster; `broadcast_have` bitmaps on join (node/swarm.rs:3377-3382). Share content protection: UNTRACED. |
| `recovery:{sid}:{token}` | node/vault_ops.rs:696, :746; node/recovery_pool.rs:240-241 | recovery invite link (`hollow://recovery?server=..&token=..`, node/vault_ops.rs:712) | recovery frames (plaintext; client now requires `room == pool.room_code()`, node/swarm.rs:4651). Token entropy: UNTRACED. |
| any name | node/swarm.rs:1276-1284 `NodeCommand::JoinRoom` from Dart | n/a | n/a |

### B.4 What our client does when S appears in a room we share
Triggered by relay presence alone (PeerJoined node/swarm.rs:3308-3754; RoomMembers :3890-4400), no membership or relationship check unless stated:
- Inserts S into routing: node/swarm.rs:3310 `ws_room_peers.entry(room.clone()).or_default().insert(peer_id.clone());`
- `PeerDiscovered` to Dart: :3456-3461, :4092-4097.
- Light profile incl. our signed device list: :3549-3555 (`if is_new`), :4060-4074 (first RoomMembers, every listed peer), :4103-4108. A `ProfileRequest` from anyone is answered with FULL blobs: node/swarm.rs:13317-13325 `social::send_own_profile_full_to_peer(`.
- Olm key exchange + queued drain: :3593-3607, :4252-4266 (`ensure_olm_session_and_drain`). Where that session leads (WebRTC dials) per phase B B-04c: not re-traced here, UNTRACED.
- `DmSyncRequest` to S: :3686-3704, :4268-4289.
- In our own inbox: sibling challenge to S (:3573-3587, :4230-4247). A peer the resolver already maps to us gets `on_verified_sibling` (node/swarm.rs:179-345), which may auto-request a link snapshot with the master id as passphrase (:338-343), relevant under P-01 (E.3).
- Pending server join: `ServerJoinRequest` (joiner's device list, `requested_at`, Twitch proof) to ANY peer in that server room: :3710-3726, :4365-4382.
- Vault rebalance scheduled: :3384-3386.
- Already gated (fixed since phase B): VC re-announce only to members who can see the channel (:3416-3420 `!s.is_member(&peer_id) || !s.can_see_channel(&peer_id, vc_cid)`); gossip neighbour only for members (:3441-3442 `is_member`).

### B.5 New observations (not in the candidate list as written)
1. **Per-post metadata in plaintext to the whole server room.** node/message_ops.rs:897-913 `// Broadcast notification hint via SendToRoom (reaches all room members, even unsubscribed).` `HavenMessage::ChannelNotificationHint { server_id, channel_id, message_id, has_everyone, mentioned_names, is_reply, reply_to_sender }` then `WsCommand::SendToRoom`. No public/restricted branch at this send site (it follows both arms at :845-880). Receiver-side gating (node/swarm.rs:12636-12655 `channel_signal_accepted`) does not stop a room joiner from reading it. S with the server id learns, per post: channel id, message id, sender device (relay `from`), mentioned display names, reply author master.
2. **MemberAdded plaintext twin goes to every room peer, not every member.** node/swarm.rs:9611-9622 `if let Some(room_peers) = ws_room_peers.get(&server_id) { ... for other_str in room_peers.iter() { ... send_raw_to_peer(` (comment :9600 "Targets come from `ws_room_peers`, not `state.members`"). Contrast node/sync_handler.rs:22-33 `broadcast_raw_to_members` (iterates `state.members`). S in the server room receives the signed op.
3. **Conference access code is a replayable bearer.** node/conference.rs:52-58 `derive_access_hash` = sha256("{conf_id}:{code}"), no joiner binding; knock broadcast to the room :264-272; host check :333-341 `if &access_hash != expected {`. Any conf-room joiner copies a legitimate knock's `access_hash` into its own knock (its own bound KeyPackage passes :318-328) and, with the waiting room off, is admitted (:352-356). Offline brute force of short codes is also possible.
4. Inbox roster exposes other pending requesters (table row 1).
5. DM-room roster restores the friendship oracle the `active_rooms` removal meant to close (table row 2).
6. `discover_peers` exposes fetch sockets (B.2).

---------------------------------------------------------------------------

## C. Ring retention opt-in (I5) and ring reads (I6)

### C.1 Commands, who may send them
- Register / refresh / extend: `{"type":"set_topic_buffer","room":R,"channels":[..],"retention_secs":N}`. relay/ws_handler.cpp:1311 `if (data->is_guest) return;`, :1315-1316 `// Must actually be in the room ... if (rit == state.ws_rooms.end() || !rit->second.peers.count(data->peer_id)) return;`. Retention clamped to [3600, 604800] (:1342-1344). Existing ring: `it->second.retention_secs = retention;  // latest registrar wins` (:1361), `accepting = true; // re-arm a cleared buffer` (:1363). Any room member, fetch sockets included. Channel strings are free text up to 128 bytes (:1351), so S can register rings for any topic name in any room it joined.
- Extension is RETROACTIVE: the sweep compares each held frame's age to the ring's current `retention_secs` (relay/ws_handler.cpp:1053-1055 `if (age >= tb.retention_secs) {`).
- Clear: `{"type":"set_topic_buffer","room":R,"clear":true}` stops intake and drops retention to the floor for EVERY ring of the room: :1332-1336 `tb.accepting = false; tb.retention_secs = OFFLINE_RETENTION_MIN_SECS;`. Any room member. Held frames age out within 1 h.
- Idle expiry: a ring nobody re-registers for 7 days is dropped (relay/state.h:78, relay/ws_handler.cpp:1072-1078).
- Honest client behaviour: registration when the CRDT `relay_catchup_secs > 0`, always including `~join` (node/sync_handler.rs:735-764); clear only at the Owner/Admin toggle. The relay cannot tell an owner from S.
- Per-peer DM opt-in `set_offline_buffer` (relay/ws_handler.cpp:1270-1281) is keyed by the caller's own id: self-only, not an S surface.

### C.2 Who may read / write
- Read: `topic_catchup {room, channel, max_age_secs}` relay/ws_handler.cpp:1374-1398. Gate: not guest (:1376) and room member (:1380-1381). Replays every held frame except the caller's own (:1392), deletes nothing.
- Write: any non-guest room member's 0x07 tees into a registered, accepting ring (relay/ws_handler.cpp:1843-1853). Guests refused 0x07 (:2530).
- Channel ids needed for `topic_catchup` are handed to S by the plaintext hint (B.5 item 1); `~join` is a constant.

### C.3 What a ring holds in plaintext
- Frame form: `[0x08][room\0][topic\0][sender\0][payload]` stored whole (relay/ws_handler.cpp:1828-1838, :1851) with the relay arrival time (`TopicFrame.at`, relay/state.h:309). So every ring is a 1 h..7 d log of sender DEVICE ids and times, even when the payload is ciphertext.
- `~join` ring, parked request (node/sync_handler.rs:1216-1244): `HavenMessage::ServerJoinRequest { server_id, twitch_proof_json, nsfw_confirmed, requested_at, device_list, parked: true, key_package }` as plain JSON on `SendToRoomTopic`. `device_list` = joiner master id, pubkey, device ids, revoked ids, version; `key_package` = MLS KeyPackage (leaf credential binds device to master).
- `~join` ring, resolution (node/sync_handler.rs:1250-1275): `ServerJoinResolved { server_id, joiner_master, requested_at, admitted, reason, op_json }`; `op_json` is the signed MemberAdded CRDT op (node/swarm.rs:9601-9603, :9748-9751).
- Channel rings: `MlsChannelMessage { server_id, body, channel_id }` (node/crypto_handler.rs:2771-2783; body = MLS ciphertext, wrapper plaintext) or `PublicChannelMessage` in full plaintext (node/message_ops.rs:1066-1084, by design).

### C.4 New observations on rings
1. **One frame flushes a ring (residual of I7 "FIXED").** Eviction loop relay/ws_handler.cpp:1858-1866 `while (!tb.frames.empty() && (tb.frames.size() > MAX_TOPIC_BUFFER_MSGS || tb.bytes > MAX_TOPIC_BUFFER_BYTES)) { auto victim = tb.frames.begin() + ring_victim(tb.frames);` with relay/ring_evict.h:17-19 (victim = oldest frame of the sender holding the most). A single frame just under `MAX_TOPIC_BUFFER_BYTES` (1 MB, relay/state.h:75; `maxPayloadLength` is 64 MB, relay/ws_handler.cpp:2443) forces eviction until only it remains: every other sender's frames go first, ties resolve to the oldest. A frame over 1 MB empties the ring outright. Sybils (one frame each) flush it too, since ties pick the oldest. The "a flooder evicts only itself" property holds only for one sender posting many small frames.
2. **Relay-wide ring registration cap is exhaustible by one socket.** relay/state.h:77 `MAX_TOPIC_BUFFERS_TOTAL = 65536;`, relay/ws_handler.cpp:1354-1355 `if (it == state.topic_buffers.end()) { if (state.topic_buffers.size() >= MAX_TOPIC_BUFFERS_TOTAL) break;`. No per-room or per-peer cap; 128 channels per call (:1349) and calls repeat freely inside one self-made room. At the cap, every NEW registration (a new server, a new channel, a newly enabled `~join`) silently fails; the attacker keeps its entries alive by re-registering inside the 7-day idle window. Rings survive restarts via the snapshot.
3. Retroactive extension (C.1) lets S hold a server's already-retained ciphertext log for up to 7 days after the owner chose 1 h.

---------------------------------------------------------------------------

## D. A18: "license_key" in a relay reply stops the client

- node/ws_client.rs:735-738: `AuthFailed { error }` returns the relay-chosen string; ANY other text returns `Err(format!("Auth rejected: {text}"))`.
- node/ws_client.rs:618-627:
  `if e.contains("license_key_in_use") { ... LicenseError ... }` (keeps retrying)
  `} else if e.contains("license_key") || e.contains("license key") { hollow_log!("[HOLLOW-WS] License error ... not retrying"); let _ = event_tx.send(WsEvent::LicenseError { reason: e }); return; }`
  The `return` ends the ws_client task for good (no reconnect until the node is restarted).
- Swarm forwards it: node/swarm.rs:4443-4446 `NetworkEvent::LicenseError { reason }`.
- Dart: lib/ui/shell/hollow_shell.dart:350-384. For anything but the exact string `license_key_in_use`: `ref.read(nodeProvider.notifier).stop(); await ref.read(licenseKeyProvider.notifier).clearKey();` then `showLicenseKeyDialog`. Cancel leaves the node stopped.
- VPS forwarder: rust/hollow_core/src/forwarder/signaling.rs:82-84 `if e.contains("license") { return Err(format!("relay refused auth: {e}")); }` (broader substring).
- Fetch node: `connect_and_auth` error just ends that fetch (node/fetch.rs:90-93, `?`).
- What P-01 can do: one auth reply containing `license_key` (any JSON, even `{"type":"x","y":"license_key"}`) takes the client offline until the user restarts or types a key, and wipes the user's stored access key for a self-hosted relay. The prompt asks for a key that is then sent to this same relay.
- Related: the stored key is ONE global setting (lib/core/providers/license_key_provider.dart:4 `const _kLicenseKeySettingKey = 'license_key';`), sent unsigned in every auth frame to whichever relay is configured. No clear on relay switch was found in lib/ui/dialogs/relay_switch_dialog.dart; whether another path clears it: UNTRACED. If none does, a relay switch hands relay A's access key to relay B.

---------------------------------------------------------------------------

## E. Relay-originated messages the client acts on

Full node parse: node/ws_client.rs:508-511 `serde_json::from_str::<ServerMsg>(&text)` then `handle_server_message` (:1220-1324). `ServerMsg` = node/ws_client.rs:266-303. Unknown types and missing required fields fail to parse and are ignored.

Cross-cutting (P-01):
- `room` in members/peer_joined/peer_left/discovered_peers is never checked against the rooms we joined: node/ws_client.rs:1222-1241 passes them through; node/swarm.rs:3310, :3925 `ws_room_peers.insert(room.clone(), room_set);`, :4477 insert for any room string.
- `from` on binary frames is relay-stamped and unvalidated: node/ws_client.rs:1207-1215 `parse_binary_relay_frame`, :544 (0x08). It becomes `peer_str` for every HavenMessage arm; unsigned arms take it as the sender's identity (phase B 0.3 still holds).

### E.1 `auth_ok` / `auth_failed`
Only read during `connect_and_auth` (A.3); mid-session copies ignored (node/ws_client.rs:1320). P-01: D.

### E.2 `kill_signal {blob, issued_at_ms}`
- Full node: node/ws_client.rs:1310-1315 -> node/swarm.rs:4436-4442 -> node/destroy.rs:247-268: undecodable blob acked with THAT stamp (`KillAck { issued_at_ms: Some(issued_at_ms) }`, :257-262); decodable judged against our master (`apply_own_order`), acked only on `RejectPermanent`.
- Fetch node: node/fetch.rs:236-281. Acks BARE (`serde_json::json!({ "type": "kill_ack" })`, :254) on an undecodable blob (:256-258) and on `RejectPermanent` (:270-273). The relay treats a bare ack as "delete every signal for me" (relay/kill_list.h:89-98). S deposits junk for a device (any authenticated peer, relay/ws_handler.cpp:1191-1223); the device's next push wake bare-acks it and the relay also drops a genuine order the fetch node could not judge (`RejectTransient`, not acked, :274-277) or had not read yet. Residual of HOL-SEC-029 (per-signal ack is only in the full node).
- Per-signal ack matches the stamp only, not the issuer: relay/kill_list.h:102-104 `remove_if(target, [&](const Entry& e) { return e.issued_at_ms == issued_at_ms; });`. Junk carrying the genuine order's stamp takes the genuine one with it. Whether S can learn a genuine stamp: UNTRACED.
- Per-target issuer cap evicts the oldest entry REGARDLESS of issuer: relay/kill_list.h:154-156 `if (... it->second.size() >= MAX_ISSUERS_PER_TARGET) { evict_oldest_at(target); }` (8 issuers, :30). Eight fresh keypairs evict a genuine order (known I3).
- P-01: withhold, delay or replay orders; cannot forge (judged against our master).

### E.3 `members {room, peers}` -> `RoomMembers`
- node/swarm.rs:3890-4400. Replaces the room's routing set (:3925); `vanished` peers get `PeerDisconnected` and are dropped from the conference call roster (:3945-3967); ring catch-up + `~join` read (:3997-4023); profile to every listed peer, key exchange, `DmSyncRequest`, `SyncRequest` for shared servers, `ProfileRequestFor` up to 10 offline members, MLS KeyPackage mint when our group is missing (throttled by `mls_bootstrap_requested`, :4201-4220), pending join request (:4365-4382), queued friend request/removal/accept drains (:4299-4360).
- P-01: invent members for any room (including rooms we never joined) to trigger all of the above toward chosen ids; drop real members to fake departures. Listing a real sibling device in our inbox triggers `on_verified_sibling` (:4230-4240), which on a near-empty device auto-requests a link snapshot keyed by the master id (node/swarm.rs:331-343; known embargoed lk2).
- Fwd rooms: Olm session with every listed peer (:4044-4055).

### E.4 `peer_joined {room, peer_id}` -> `PeerJoined`
node/swarm.rs:3308-3754 (B.4 cascade). P-01 can inject any id into any room; honest relay sends it for every non-guest, non-fetch joiner.

### E.5 `peer_left {room, peer_id}` -> `PeerLeft`
node/swarm.rs:3766-3888: routing purge, fwd `peer_gone` (:3779-3781), sibling challenge dropped, share and recovery-pool member removal (:3803-3823), conference roster drop (:3795-3801), `VoiceChannelLeft` + participant removal for that server's voice channels (:3840-3865), `PeerDisconnected` or a re-join of still-listed rooms (:3868-3887). P-01: kick any peer out of our VC state / call roster; drive re-join churn.

### E.6 `error {error}`
node/ws_client.rs:1262-1277: only `"Too many rooms"` acts: removes the LAST join attempt from the reconnect re-join set and emits `RoomCapHit`. P-01: make the client forget a room it joined (share, fwd, conf, recovery and link rooms are re-joined only from that set; the Connected arm re-joins inbox, servers, DMs, guest rooms itself, node/swarm.rs:3121-3202).

### E.7 `peer_status {online, active_rooms}` -> `PeerStatus`
node/swarm.rs:4454-4471: for each `online` id, `JoinRoom(dm_room_code(local, resolve(id)))` + `JoinRoom(inbox:{local})`; `active_rooms` ignored. P-01: make us join the DM room computed with any chosen id (we then sit where that id can find us).

### E.8 `discovered_peers {room, peers}` -> `DiscoveredPeers`
node/swarm.rs:4472-4495: adds every id to `ws_room_peers[room]` (any room string) and sends a signed `KeyRequest` to each without a confirmed session. P-01: key-exchange initiation toward arbitrary ids; the request is device-signed and recipient-bound.

### E.9 `turn_credentials {username, password, ttl, uris, error}`
node/ws_client.rs:1242-1251 -> node/swarm.rs:4540-4548 (`embedded_fwd.note_turn_uris(&uris)`, then `NetworkEvent::TurnCredentials`) -> lib/core/providers/ice_config_provider.dart:89-101 `setTurnCredentials`: only `if (uris.isEmpty) return;`, every URI becomes an ICE server with the given credentials (:49-56). No host check against the relay domain. With "Always relay calls" on, TURN is the ONLY path (:67-78 `'iceTransportPolicy': 'relay'`). P-01: route every call's media through a TURN host of its choosing (a third party then sees the user's address and traffic shape; media content stays DTLS-SRTP + SFrame), or supply junk to make Always-relay calls fail closed. The embedded forwarder also takes these URIs as its STUN source.

### E.10 `media_forwarder {peer_id, online, error}` (J5)
node/ws_client.rs:1252-1261 -> node/swarm.rs:4549-4553 -> lib/core/providers/forwarder_info_provider.dart:34-36 stores it as-is. Used as the infra forwarder rung (lib/core/providers/voice_channel_provider.dart:2486-2487 pick, :2529-2533 spread) and as the ONLY forwarder an Always-relay viewer accepts: :3217-3225 `if (ref.read(alwaysRelayCallsProvider)) { final advertised = ref.read(forwarderInfoProvider).peerId; if (advertised.isEmpty || forwarder != advertised) {`. Relay side: one static configured id (relay/ws_handler.cpp:2358-2363). P-01: name any device (a member's, its own) as "the operator forwarder"; privacy-bound viewers then open their media leg to it (client legs carry zero ICE servers per CLAUDE.md, so the leg exposes the viewer's address). `online` is also relay-asserted.

### E.11 `nickname_claimed` / `nickname_released` / `nickname_error` / `nickname_resolved`
node/swarm.rs:4496-4537. Claimed/released: UI events. Error: fails the pending resolve if the nickname matches, else a claim failure. Resolved: F.

### E.12 `link_code_claimed` / `link_code_released` / `link_code_error` / `link_code_resolved`
node/swarm.rs:4555-4577. Released clears our claimed code (`link_handler::note_link_code_released()`, so later link requests from the link room are refused: safe direction). Resolved, if it matches `pending_link_resolve`: node/link_handler.rs:131-147 records the relay-named peer as asked (`note_snapshot_asked(peer_id)`) and sends it `LinkSnapshotRequest`. P-01 picks the peer whose snapshot we will accept and import (known B-14a); the relay also knows the code, which is the snapshot passphrase (known lk2).

### E.13 `kill_deposited {stored}`
node/ws_client.rs:1316-1319: log only.

### E.14 Ignored by the full node
`push_token_registered` (relay/ws_handler.cpp:1173), `report_ack` (:1299), JSON `msg` (:1531-1536) and `direct` (:1582-1587): no `ServerMsg` variant, dropped at parse. Push-token state is fire-and-forget, so a relay lying about it changes nothing client-side.

### E.15 Binary frames
node/ws_client.rs:513-557: `0x02` -> `BinaryDirect` (stream chunks, node/swarm.rs:4402-4435), `0x05` and `0x08` -> `Message`, `0x06` -> `DirectMessage` (node/swarm.rs:4578ff, per-`from` rate limit :4616). The arrival `room` is dropped before the HavenMessage handler except by the frame seal (E.18) and the recovery-pool interception (:4651). P-01: any `from`, any content.

### E.16 Fetch node (push isolate) text frames
node/fetch.rs:283-321: `members`, `peer_joined` logged; JSON `direct`/`msg` decrypted as a DM from the relay-stated `from` (:302-318); `kill_signal` via E.2. Binary 0x05/0x06/0x08 per node/fetch.rs:327-360 (:349 `0x06 | 0x05 => parse_direct_frame(&data[1..]),`). The room it joins comes from the push payload's `sender` (DM wake, node/fetch.rs:168-178) or server (channel wake, membership-checked :70-76).

### E.17 VPS forwarder text frames
rust/hollow_core/src/forwarder/signaling.rs:170-209: acts on `members` / `peer_joined` / `peer_left` for its own room only (`in_our_room`, :176-179), `PeerGone` on departures. Operator infrastructure; listed for completeness.

### E.18 In-flight, uncommitted: device-signed relay frames (appeared during this pass)
Not evaluated; recorded so design A starts from the current tree.
- node/frame_auth.rs:3-5 (module doc): "The relay stamps `from` on everything it forwards, and a malicious relay can stamp any id. So every peer payload travels sealed".
- Seal = device signature over `hollow-frame1\0` + room + route + ts_ms + nonce + sha256(body) (node/frame_auth.rs:77-88); `open` checks the route (`*` for room fan-out, our device or master for directs), verifies against the key inlined in `from`, refuses future stamps beyond 300 s (:127-165).
- Sealed commands: `SendToRoom`, `SendToRoomTopic`, `SendDirect`, `SendDirectImage`, non-empty `SendChannelDirect` (node/frame_auth.rs:175-199). NOT `SendBinaryDirect` (0x02 stream chunks) as of this read.
- Wired only into the swarm's Message/DirectMessage arm (node/swarm.rs:571-572 `spawn_sealer`, :4578-4600 `frame_auth::open(&data, &from, &room, delivery, now_ms)`). node/fetch.rs and the forwarder were unchanged when read. Unsealed frames are dropped (`Refusal::Unsealed`), i.e. no pre-0.12 fallback in that arm.
- If it lands as read: E cross-cutting (`from` forgery), E.15 and phase B 0.3 shrink to 0x02 and the fetch node; relay-originated JSON (E.1-E.14), rosters, rings' metadata and every B/C/D/F item are untouched.

---------------------------------------------------------------------------

## F. Nickname claims (J7)

- Claim, relay: relay/ws_handler.cpp:1918-1954. Any non-guest socket; nickname lowercased, `[a-z0-9_]{3,20}` (:76-85); binds nickname -> the socket's DEVICE peer_id (:1943); TTL 10 min (:1888, :1945); stale when the holder's socket is gone (:1902-1916). Master: `if (is_peer_id_shape(raw_master) && raw_master.rfind("12D3KooW", 0) == 0) { state.nickname_to_master[nickname] = raw_master; }` (:1950-1952). Self-reported: nothing ties it to the device key or to any signature.
- Claim, client: node/swarm.rs:2150-2158 `ClaimNickname { nickname, master: local_peer_str.to_string() }` (honest clients send their own master).
- Resolve, relay: relay/ws_handler.cpp:1965-1980. No guest check, no throttle, no relationship: returns `peer_id` (claimer device) and `master_id`. Anyone can enumerate the 3..20-char space and learn, per live nickname, the claimer's device id, its claimed master and that it is online right now.
- Resolve, client: node/swarm.rs:2145-2148 sets `pending_nickname_resolve`; node/swarm.rs:4510-4537 on a matching `NicknameResolved`: `let target = if !master_id.is_empty() { master_id } else { super::resolver::resolve(&peer_id) };` then immediately `social::handle_send_friend_request(..., target, ...)`. No confirmation step shows who the target is. `master_id` is never written to the resolver (:4519-4521).
- What the send does with that target (node/social.rs:464-600): self check only (`same_identity`), saves a pending OUTGOING friend row keyed by the target master (:544 `store.save_friend(&master, "pending", "outgoing", now)`), joins `dm_room_code(local, master)` (:552-555) and `inbox:{target}` (:558-561), builds the request carrying our Olm prekey bundle and master-signed device list (:569-572), sends to online devices or deposits in the target's mailbox.
- Who chooses the master: the CLAIMER (unverified, any id with the right prefix), or P-01 (any string; the client does not shape-check it). So a squatter or P-01 decides whose inbox receives our friend request, bundle and device list, and which master our pending row names.

---------------------------------------------------------------------------

## UNTRACED (could not follow to the end in this pass)
- A full scan of device-key signers for a raw, peer-chosen payload that could equal `hollow-ws-auth:{id}:{ts}` (A.1).
- Whether any path clears the stored license key on a relay switch (D).
- Whether S can learn a genuine kill order's `issued_at_ms` (E.2).
- Olm sessions with room strangers leading to WebRTC dials (B.4, phase B B-04c).
- The in-flight frame-seal work (E.18): coverage of 0x02, the fetch node and inbox mailbox deposits.
- Share-room content protection and recovery-token entropy (B.3).
- How a joiner validates a `ServerJoinResolved` read from the ring (C.3; design E territory).

## Ten-line summary
1. Auth signs only `hollow-ws-auth:{device}:{ts}` (±60 s, no nonce, no relay name); `fetch`, `guest` and `license_key` ride unsigned.
2. Any relay operator can replay a captured frame to another relay; as `fetch:true` it coexists invisibly with the live device, hijacks its room slots, drains its buffer and can ack away its kill orders.
3. Room joins need only a well-formed name; a silent `fetch:true` stranger gets the roster, the presence stream and all room broadcasts without ever appearing to members.
4. `inbox:{master}` and DM-room rosters are presence and friendship oracles and also list every stranger with a pending request to that master.
5. Every channel post broadcasts a plaintext `ChannelNotificationHint` (channel id, message id, mention names, reply author) to the whole server room, restricted channels included; ex-members and invite holders read it.
6. The MemberAdded plaintext twin targets every room peer, and a conference `access_hash` is a replayable bearer anyone in the conf room can copy.
7. Ring opt-in, extension (retroactive, to 7 days) and clear are open to any room member; `topic_catchup` lets any member read `~join` (device lists, KeyPackages, Twitch proofs, MemberAdded ops) and channel rings.
8. Ring fair-share eviction is defeated by one frame just under 1 MB, and one socket can exhaust the relay-wide 65,536 ring-registration cap.
9. Any relay reply containing `license_key` stops the node, clears the stored access key and prompts for a new one; the forwarder stops on any `license`.
10. The client trusts relay rosters for rooms it never joined, relay-stamped `from`, unvalidated TURN URIs and a relay-named forwarder (J5), and friends whatever master a nickname resolves to (J7) without confirmation.
