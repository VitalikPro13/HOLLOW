# Rust Social Module — Friends, Profiles, Typing, Status

The social module handles friend requests, profile updates, typing indicators, and invisible status broadcasting. All operations persist to SQLCipher via `MessageStore` and communicate with remote peers via WS relay plaintext messages (for DMs and direct peer communication) or MLS broadcast (for server-scoped signals like typing and profiles). This module also handles the MLS-path envelope equivalents for typing and profile updates.

Source file: `rust/hollow_core/src/node/social.rs` (488 lines)

Imports from: `crypto_handler::{peer_is_reachable, send_mls_broadcast, send_message_to_peer, send_raw_to_peer}`, `signaling::SignalingCmd`, `types::*`

---

## Async friending (2026-08-28) — carried bundle, inbox mailbox, anti-downgrade guard

Friend requests can complete with ZERO overlap (both parties offline at different moments). Full design lives in `reports/PENDING_JOINS_ASYNC_FRIENDING.md`; the durable record is memory `project_pending_joins_async_friending`.

- **`FriendRequest` carries** (all `#[serde(default)]`, backward-compatible): a `CarriedBundle` (fresh Olm one-time key + identity key, signed over the domain-separated `hollow-carried-keybundle:` payload, addressed to the recipient MASTER), the sender's `SignedDeviceList`, and a `carried_profile` (signed subset, verified + stored via `store_carried_profile` so the incoming card renders the sender's name/avatar). `FriendAccept` stays a UNIT variant (nothing needs a field there; the enum is INTERNALLY tagged, so `#[serde(default)]` fields can be added when needed, as `FriendReject` shows).
- **Accepter** builds the outbound Olm session from the carried bundle at accept time, glare-gated to run ONLY when the requester is offline and session-less (`live_at_receipt`), then sends one `Encrypted` `FRIEND_HANDSHAKE_SENTINEL` that establishes the requester's inbound session with no visible DM row. `verify_carried_bundle` is its OWN freshness path (`MAX_CARRIED_BUNDLE_AGE_SECS = 7d`, never the live 300s `KEY_EXCHANGE_SKEW_SECS`).
- **Relay inbox mailbox (DEPLOYED):** `handle_send_friend_request` deposits into `inbox:{target_master}` when no device is known; the relay replays it only to a device presenting a master-signed ownership proof on its inbox join, TTL-only (not delete-on-replay) so every sibling collects it. See `security_write_gates.md` §5.
- **Anti-downgrade guard (swarm.rs `FriendRequest` arm, after the carried-bundle store, before `is_mutual`) — FIXES the reported bug:** the TTL-only mailbox re-delivers on every inbox join, so the guard reads `get_friend_row` and refuses to walk a friendship backwards — `accepted` → return (the DM was leaving Recent Conversations / the friend flipping back to Incoming), `declined` → return if `requested_at <= stored`, `pending/incoming` → return if `<= stored` (a strictly-newer request falls through). Carried profile stored before the `FriendRequestReceived` emit.
- **Decline is STICKY end-to-end (FIXED 2026-08-28 evening, fleet-verified on fresh identities):** `handle_reject_friend_request` writes `save_friend(master, "declined", "", original_requested_at)` (never deletes) and calls `send_friend_reject`: the live device fan PLUS a join/send/leave deposit into the REQUESTER's `inbox:{master}`, so a requester that was never online with us learns on its own next boot. `FriendReject` is now `{ requested_at, device_list }` (both `#[serde(default)]`; the enum is internally tagged so both directions stay compatible; pinned by `friend_reject_wire_is_backward_compatible`). Receive side (`FriendReject` arm): ATTRIBUTION FIRST from the carried master-signed device list (`verify_device_list`, sender device listed + un-revoked, ingested via `ingest_device_list`; present-but-bad = DROP, no resolver fallback; absent = legacy `resolve()`), then a MONOTONIC gate: act on `pending/outgoing` when `requested_at == 0 || >= stored`, on `accepted` when `!= 0 && >= stored` (the mutual cross), else log + return without an event. `save_friend` advances `requested_at` by MAX for PENDING rows only; the mutual auto-accept stamps the incoming `requested_at` before accepting so both sides freeze on MAX(ours, theirs). The declined arm of the anti-downgrade guard RE-SENDS the reject once per requester per connection (`reject_resent`, cleared on `Disconnected`), and an incoming `FriendAccept` on a `declined` row is ignored. Memory `project_pending_joins_async_friending`; gate row in `security_write_gates.md`; the harness resolver is process-global, so the decline tests `resolver::forget` the decliner's device before the requester returns.

## handle_send_friend_request()

`social.rs:handle_send_friend_request(event_tx, ws_cmd_tx, ws_room_peers, sig_cmd_tx, pending_friend_requests, local_peer_str, peer_id_str, db_path, db_passphrase)`

Called when the local user sends a friend request (`NodeCommand::SendFriendRequest`) or after a nickname is resolved (`NodeCommand::SendFriendRequestByNickname` → relay resolve → this function).

**Self-request guard:** If `peer_id_str == local_peer_str`, emits `NetworkEvent::Error` with "Cannot send a friend request to yourself" and returns early.

Steps:
1. **Persist as pending outgoing:** Opens `MessageStore`, calls `store.save_friend(peer_id, "pending", "outgoing", now)`.
2. **Register DM room:** Computes the deterministic DM room code via `dm_room_code(local_peer, peer_id)` (SHA-256 hash of sorted peer IDs with "dm-" prefix). Registers the room with signaling (`SignalingCmd::SetRoom` + `SignalingCmd::Bootstrap`) and joins the WS relay room (`WsCommand::JoinRoom`). This enables peer discovery even before the request is accepted.
3. **Join target's inbox room:** Joins `"inbox:{peer_id}"` on the WS relay. Every peer auto-joins their own inbox room on startup, so this is the reliable way to reach any peer regardless of shared servers.
4. **Send or queue (device-targeted, 2026-07-02):** Builds concrete DEVICE targets via `friend_device_targets(ws_room_peers, peer_id, master)` — the literal id, resolver-known devices, and any room peer resolving to the master, ALL gated on EXACT room membership (never identity-wide `peer_is_reachable`: a bare master admitted by an identity-wide check is a silently-dropped send). Non-empty → sends `HavenMessage::FriendRequest { requested_at: now }` to each device + leaves the target inbox. Empty → inserts into `pending_friend_requests: HashMap<String, i64>` (peer_id -> requested_at timestamp); drained when the peer appears via `PeerJoined`/`RoomMembers` in swarm.rs (the drain targets the concrete device that appeared).
5. **Emit event:** Sends `NetworkEvent::FriendRequestReceived { peer_id }` to Dart so the UI shows the outgoing request immediately.

### Friend Request by Nickname (two-step)

`NodeCommand::SendFriendRequestByNickname { nickname }` in swarm.rs stores `pending_nickname_resolve = Some(nickname)` and sends `WsCommand::ResolveNickname` to the relay. When the relay responds with `WsEvent::NicknameResolved { peer_id, master_id }`, swarm.rs calls `handle_send_friend_request()` with `master_id` when non-empty (2026-07-16: the claim carries the claimer's MASTER through the relay — `claim_nickname` sends a `"master"` field, `nickname_resolved` returns `"master_id"` — because the bound `peer_id` is the claimer's WS-auth DEVICE id, whose `inbox:{device}` room nobody listens on; a stranger's cold resolver couldn't collapse it and the request queued forever). Empty `master_id` (old relay) falls back to `resolver::resolve(peer_id)`. The relay-reported master is used ONLY as the friend-request target string — NEVER fed into the resolver (resolver mappings come only from master-signed device lists). If resolution fails (`WsEvent::NicknameError`), emits `NetworkEvent::NicknameResolveFailed`, which event_provider surfaces as an error toast.

### DM Room Code

`types.rs:dm_room_code(peer_a, peer_b) -> String` — deterministic room name for any peer pair. Sorts the two peer IDs lexicographically, concatenates as `"dm-{sorted[0]}-{sorted[1]}"`, then SHA-256 hashes the result. Output is the hex-encoded hash. Both peers compute the same room code independently.

---

## handle_accept_friend_request()

`social.rs:handle_accept_friend_request(event_tx, ws_cmd_tx, ws_room_peers, sig_cmd_tx, bundle_keypair, local_peer_str, peer_id_str)`

Called when the local user accepts an incoming friend request (`NodeCommand::AcceptFriendRequest`).

Steps:
1. **Persist as accepted:** Opens MessageStore, calls `store.save_friend(peer_id, "accepted", "", now)`. The direction field is cleared since both sides are now friends.
2. **Send acceptance:** If peer is reachable, sends `HavenMessage::FriendAccept` via `send_message_to_peer()`. No payload beyond the message type — the sender's identity is implicit from the WS relay framing.
3. **Register DM room:** Same `dm_room_code` + signaling registration + WS relay join as in send. This ensures the DM channel is set up for future messaging.
4. **Emit event:** `NetworkEvent::FriendRequestAccepted { peer_id }`.

---

## handle_reject_friend_request()

`social.rs:handle_reject_friend_request(event_tx, ws_cmd_tx, ws_room_peers, bundle_keypair, peer_id_str)`

Called when the local user rejects an incoming friend request (`NodeCommand::RejectFriendRequest`).

Steps:
1. **CLEAR `pending_friend_requests` + `pending_friend_accepts` for both master and peer_id (2026-07-09).** Rejecting supersedes our OWN queued outbound intents. Without this, on a MUTUAL request (both sides requested) our still-queued outbound request drained on the peer's next appearance → the peer accepted → the pair became friends BEHIND THE USER'S BACK (the reject/accept race). Mirrors `handle_remove_friend`'s cancellation; the two maps were threaded into the handler for this.
2. **Tombstone, not delete (2026-08-28):** folds any device-stranded row up to the master, reads the ORIGINAL `requested_at`, then `save_friend(master, "declined", "", original_requested_at)`. The tombstone is what the anti-downgrade guard measures mailbox re-deliveries against; a later re-add overwrites it (upsert).
3. **Notify the requester on EVERY leg (`send_friend_reject`, 2026-08-28):** `FriendReject { requested_at: original, device_list: our SignedDeviceList }` fanned to `friend_device_targets()` AND deposited into the requester's `inbox:{master}` (join, send, leave). No longer best-effort: an offline requester collects it from its own mailbox on its next boot.
4. **Emit event:** `NetworkEvent::FriendRequestRejected { peer_id }`.

**Mutual-request auto-converge (2026-07-09):** the FriendRequest RECEIVE arm (swarm.rs) checks, before saving "pending incoming", whether we already hold a pending-OUTGOING request to this master (`pending_friend_requests` OR DB `direction=outgoing` via `get_friend_status_direction`). If so → treat the inbound request as an implicit accept → `handle_accept_friend_request` (idempotent, both sides converge). Removes the confusing reject prompt on a mutual pair. See `feedback_dm_friend_establishment_bugs_2026_07.md`.

Note: No DM room registration — rejecting does not create a DM channel.

---

## handle_remove_friend()

`social.rs:handle_remove_friend(event_tx, ws_cmd_tx, ws_room_peers, bundle_keypair, peer_id_str)`

Called when the local user removes an existing friend (`NodeCommand::RemoveFriend`).

Steps:
1. **Remove from DB:** Opens MessageStore, calls `store.remove_friend(peer_id)`.
2. **Notify peer:** If reachable, sends `HavenMessage::FriendRemove`.
3. **Emit event:** `NetworkEvent::FriendRemoved { peer_id }`.

Note: Does not leave the DM WS relay room or deregister the signaling room. The DM room persists — conversations remain accessible even after unfriending. The friend status change only affects the UI's friend list.

---

## Incoming Friend HavenMessages (swarm.rs)

All incoming friend messages are processed directly in `swarm.rs:handle_incoming_request()`, not delegated to social.rs:

### HavenMessage::FriendRequest { requested_at }
0. BLOCK GUARD (after the self-guard): `blocklist::is_blocked(peer_str)` → silent drop — no pending row, no room join, no event. This is the anti-spam surface blocking exists for.
1. Persists as `save_friend(peer_str, "pending", "incoming", requested_at)` in MessageStore
2. Registers the DM room code via signaling (`SetRoom` + `Bootstrap`) for future peer discovery
3. Emits `NetworkEvent::FriendRequestReceived { peer_id }`

### User blocking (node/blocklist.rs, 2026-07-07)
Local block list, MASTER-keyed, enforced at ingest. Process-global `RwLock<HashSet<String>>` mirroring the SQLCipher `blocked_peers` table (same shape as the resolver's REVOKED set), warmed at node startup beside `resolver::warm_from_links`. `is_blocked(peer_id)` collapses device→master via the resolver — a blocked person can't sidestep from a second device.

Guards drop-before-store+emit at: FriendRequest (above), the pending-FriendAccept drains (PeerJoined + RoomMembers arms), DirectMessage (live, beside the revoked guard; own-sibling echoes exempt), DmSyncBatch, DM FileHeader (`sid.is_none()` only — channel files hide in UI), CallInvite + RtcOffer (initiation points; other call signals are inert without them), and `fetch.rs::try_decrypt_dm` (offline relay replay).

FFI is direct (no NodeCommand): `block_peer`/`unblock_peer`/`load_blocked_peers` in api/storage.rs persist then update the global set. Channel messages from blocked masters stay stored but are hidden in Dart (`blockedUsersProvider`), so unblock restores history. HARNESS CAVEAT: the set is process-global — all harness nodes share it; call `blocklist::clear_for_test()` and never assert a third node still receives from a blocked peer.

### HavenMessage::FriendAccept
1. Updates to `save_friend(peer_str, "accepted", "", now)` in MessageStore
2. Registers DM room code via signaling
3. Emits `NetworkEvent::FriendRequestAccepted { peer_id }`

### HavenMessage::FriendReject { requested_at, device_list }
1. **Attribution:** with a carried list, `verify_device_list` + sender device in `devices` and not in `revoked` + `ingest_device_list`, master taken FROM THE LIST; a present-but-bad list DROPS the frame (no resolver fallback). No list = `resolve(peer_str)`.
2. **Monotonic gate** (`security_write_gates.md`): read `get_friend_row(master)` once; act only on `("pending","outgoing",stored)` with `requested_at == 0 || >= stored`, or `("accepted",_,stored)` with `!= 0 && >= stored`. Anything else logs "answers no live request" and returns with NO event.
3. When acting: `remove_friend` (master + legacy device key), clear `pending_friend_requests` + `pending_friend_accepts` under both keys (stops the reconnect re-deposit), `LeaveRoom inbox:{master}`, emit `NetworkEvent::FriendRequestRejected { peer_id: master }` once.

### HavenMessage::FriendRemove
1. Resolves `master = resolve(peer_str)` (the remover sends from a DEVICE id; friendships key on MASTER) and `remove_friend(master)` (+ `remove_friend(peer_str)` for any legacy device-stranded row).
2. **CLEARS `pending_friend_accepts` + `pending_friend_requests` for both `master` and `peer_str` (2026-06-23).** Without this, a stale `pending_friend_accepts[master]` (we accepted them earlier; also re-seeded from accepted-friends at every startup) survives the removal → on a later RE-ADD the pending-accepts drain AUTO-SENDS a FriendAccept with NO consent and no Incoming-tab entry (asymmetric: they re-friend us, we show nothing). The two maps are threaded into `handle_incoming_request` specifically for this. (The send-side `handle_remove_friend` already cleared them.)
3. Emits `NetworkEvent::FriendRemoved { peer_id: master }`.

### Pending Friend Request / Removal / Accept Drains

When a peer becomes reachable (`PeerJoined` or `RoomMembers` events in swarm.rs), the node drains `pending_friend_requests` (sends the queued `FriendRequest`), `pending_friend_removals` (sends the queued `FriendRemove`), and `pending_friend_accepts` (re-sends `FriendAccept`). Each matches by resolving the joining DEVICE → MASTER. All are one-shot (`.remove()`). **These drains run OUTSIDE the `is_new` guard (2026-06-23) in BOTH PeerJoined and RoomMembers** — RoomMembers fires for a peer ALREADY present when WE join/reconnect, so for an already-synced peer `is_new=false` and the drain was being SKIPPED. That stranded the queued FriendRequest of a RE-ADD to an online ex-friend (the peer never saw the new request). The fix made the friendship require fresh consent again; see `feedback_friend_readd_online_auto_accept.md`.

**Mapping-learned FriendRequest drain (2026-07-09) — fixes "friend request needs a restart".** The presence-event drains match a queued request (keyed by target MASTER) to a joining DEVICE via `resolver::resolve`. A FRESH requester that hasn't ingested the target's device list resolves the target's device to ITSELF (cold resolver → identity), so the drain NO-OPS while cold — the request sits queued and the target only sees it after RE-JOINING a shared room (a restart) once the mapping is finally known. FIX: the ProfileUpdate handler (swarm.rs, right after `ingest_device_list`) now ALSO drains `pending_friend_requests` — the mapping-learned moment — re-firing any queued request whose target resolves to the sender's now-known master to `friend_device_targets`, then leaving `inbox:{master}`. See `feedback_dm_friend_establishment_bugs_2026_07.md`.

---

## handle_send_typing_indicator()

`social.rs:handle_send_typing_indicator(ws_cmd_tx, ws_room_peers, mls, server_states, bundle_keypair, local_peer_str, server_id, channel_id)`

Called when the local user types in a chat (`NodeCommand::SendTypingIndicator`). Supports two modes:

### DM typing (server_id is empty)
When `server_id.is_empty()`, the `channel_id` field carries the recipient's MASTER id. **Multi-device (fixed 2026-06-15):** the master authenticates as NO socket — only its device peer_ids do — so sending `HavenMessage::TypingIndicator` to the bare master is silently dropped (`send_message_to_peer` finds no room). Instead it **fans out to the recipient's DEVICES**: target set = `resolver::devices_for(master)` UNION every peer in the DM room (`dm_room_code(local_master, recipient_master)`) that resolves to that master, sending to each reachable device. Single-device recipient → falls back to the master id itself. Logs `[HOLLOW-TYPING] DM typing → master …: sent to N device(s)`. No MLS — typing is plaintext (reveals no content). Receive side resolves the sender device→master and keys DM typing on the master (`event_provider`).

### Channel typing (server_id is non-empty)
1. **MLS path:** If the server has an active MLS group, constructs `MessageEnvelope::Typing { sid, cid }` and broadcasts via `send_mls_broadcast()`. This is the preferred path — the typing indicator is encrypted within the server's MLS group.
2. **Plaintext fallback:** If MLS is unavailable, serializes `HavenMessage::TypingIndicator` once and sends pre-serialized bytes via `send_raw_to_peer()` to every reachable server member (except self).

---

## handle_set_invisible()

`social.rs:handle_set_invisible(ws_cmd_tx, ws_room_peers, local_peer_str, invisible, is_invisible)`

Called when the local user toggles invisible mode (`NodeCommand::SetInvisible`).

Steps:
1. Updates the `is_invisible: &mut bool` flag in swarm state
2. Determines status string: `"invisible"` if true, `"online"` if false
3. Constructs `HavenMessage::StatusUpdate { status }`, serializes once, and broadcasts pre-serialized bytes via `send_raw_to_peer()` to every unique connected peer across all WS rooms. Uses a `HashSet<String>` (`sent_to`) to deduplicate peers that appear in multiple rooms.

The `is_invisible` flag is also read by `send_own_profile_to_peer()` and `handle_update_profile()` — both include it in the `ProfileUpdate` message so newly connecting peers learn the invisible status immediately.

---

## handle_update_profile()

`social.rs:handle_update_profile(event_tx, ws_cmd_tx, ws_room_peers, mls, server_states, bundle_keypair, local_peer_str, display_name, status, about_me, avatar_bytes, banner_bytes, is_invisible)`

Called when the local user updates their profile (`NodeCommand::UpdateProfile`). This is the most complex social handler due to the hybrid MLS+plaintext broadcast strategy.

### Avatar/Banner Encoding

The `avatar_bytes` and `banner_bytes` parameters use `Option<Vec<u8>>` with three-state semantics:
- `None` = no change (encoded as empty string `""` in messages)
- `Some(empty vec)` = clear the field (encoded as `"CLEAR"`)
- `Some(data)` = new image data (encoded as base64 string)

### Steps

1. **Persist own profile:** Opens MessageStore, calls `store.save_profile(local_peer, display_name, status, about_me, now, avatar_bytes, banner_bytes)`. The timestamp `updated_at` is the current Unix time in milliseconds.

2. **MLS broadcast to servers:** Constructs `MessageEnvelope::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible, avatar_hash, banner_hash }` — this user-initiated path is the one place blobs still ride a broadcast; hashes are computed from the STORED row post-save (the params use None = "unchanged"). Iterates all `server_states` and for each server with an active MLS group, calls `send_mls_broadcast()`. Tracks which peer IDs were reached via MLS in `mls_reached: HashSet<String>`.

3. **Plaintext fallback for remaining peers:** Constructs `HavenMessage::ProfileUpdate` with the same fields. Serializes once via `serde_json::to_vec()`, then sends pre-serialized bytes to each peer via `send_raw_to_peer()` (NOT `send_message_to_peer()`). This avoids O(N) deep clones and re-serializations of the potentially 200KB+ avatar/banner payload. Covers DM peers and peers in servers where MLS is not yet established.

4. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id: local_peer }` so Dart refreshes the local profile UI.

Logging: Outputs the count of plaintext recipients vs MLS-reached peers for debugging broadcast coverage.

---

## send_own_profile_to_peer() — LIGHT announce (2026-07-06)

`social.rs:send_own_profile_to_peer(ws_cmd_tx, ws_room_peers, local_peer_str, master_keypair, device_peer_id, target_peer, is_invisible, db_path, db_passphrase)`

Sends the local user's profile to a specific peer. Called proactively in swarm.rs when:
- A new peer joins a WS room (`PeerJoined` event) / appears in `RoomMembers`
- First RoomMembers after connect (broadcast to room peers)
- Sibling merges, revocation tombstone pushes, friend request/accept handshakes

**LIGHT by default (bandwidth-critical invariant):** the message carries display name / status / about / `updated_at` / device_list / `is_invisible`, with `avatar_b64`/`banner_b64` sent as EMPTY strings ("no change" under `save_profile`'s COALESCE) plus `avatar_hash`/`banner_hash` (hex SHA-256 via `profile_blob_hash()`, empty = no blob). A receiver whose cached blobs don't match the hashes pulls the full profile once via `ProfileRequest`. Before this, every reconnect re-shipped full avatar+banner base64 to every peer — counted against the relay per-IP byte budget in BOTH directions, the "File Usage jumps ~6 MB on every restart" leak (see memory `feedback_profile_light_announce_bandwidth_leak`).

`send_own_profile_full_to_peer()` is the blob-carrying variant — used ONLY by the `HavenMessage::ProfileRequest` response arm in swarm.rs (the pull half of the protocol). Never use it on an announce path.

### maybe_request_full_profile()

`social.rs:maybe_request_full_profile(ws_cmd_tx, ws_room_peers, sender_peer_id, profile_master, avatar_b64, banner_b64, avatar_hash, banner_hash, local_device_peer_id, db_path, db_passphrase)`

Receive-side staleness check, called by BOTH incoming ProfileUpdate handlers after `save_incoming_profile`. Fires a single `ProfileRequest` to the sender when: the update was light (both b64 fields empty), at least one incoming hash is non-empty, and it differs from the SHA-256 of our cached blob for that master. Deduped by a process-global 10-minute cooldown map keyed `{local_device}:{master}` (keyed by local device so harness nodes in one process don't share buckets). An empty incoming hash while we cache a blob is NOT treated as stale — blob clears propagate only via the live full `handle_update_profile` broadcast (pre-existing behavior, preserved).

---

## handle_profile_request_for()

`social.rs:handle_profile_request_for(ws_cmd_tx, ws_room_peers, requester_peer, target_peer_id, db_path, db_passphrase)`

Handles `ProfileRequestFor` — looks up an offline peer's cached profile in local DB and sends it back as `ProfileRelay` (avatar included, no banner). Called when an online peer asks us for a third peer's profile.

## handle_profile_relay()

`social.rs:handle_profile_relay(event_tx, server_states, source_peer_id, display_name, status, about_me, updated_at, avatar_b64, twitch_username, db_path, db_passphrase)`

Handles incoming `ProfileRelay`. Truncates fields (64/96/256 char limits), decodes avatar (max 1 MB, no banner), saves profile only if `updated_at` is newer than existing. Updates member display names in `server_states`, emits `ProfileUpdated`.

---

## Incoming Typing Handlers

### handle_envelope_typing() (MLS path)

`social.rs:handle_envelope_typing(event_tx, sender_peer_id, sid, cid)`

Processes `MessageEnvelope::Typing` received via MLS decryption. Simply emits `NetworkEvent::TypingStarted { peer_id: sender_peer_id, server_id: sid, channel_id: cid }` to Dart. No validation beyond MLS group membership (which is implicit in successful MLS decryption).

### HavenMessage::TypingIndicator (plaintext, swarm.rs)

Processed directly in `swarm.rs:handle_incoming_request()`. Logs `[HOLLOW-TYPING] Received from {peer} …` then emits `NetworkEvent::TypingStarted { peer_id, server_id, channel_id }` where `peer_id` is the sender's DEVICE id. No additional validation — any connected peer can send typing indicators. Dart `event_provider` resolves the device→master via `deviceLinkProvider.identityOf` and keys DM typing on the master (matching the chat view's `typingProvider[widget.peerId]` lookup). For DM typing, `server_id` is empty.

---

## Incoming Profile Update Handlers

### handle_envelope_profile_update() (MLS path)

`social.rs:handle_envelope_profile_update(event_tx, server_states, bundle_keypair, sender_peer_id, display_name, status, about_me, updated_at, avatar_b64, banner_b64)`

Processes `MessageEnvelope::ProfileUpdate` received via MLS decryption.

Steps:
1. **Decode avatar/banner:** Empty string = no change (None). `"CLEAR"` = clear signal (Some(empty vec)). Otherwise, base64-decode with a 2 MB size limit per field (rejects payloads > 2,000,000 bytes after decoding).
2. **Persist profile:** Opens MessageStore, calls `save_incoming_profile(...)` (master-keyed, empty-profile guard).
3. **Staleness pull:** calls `maybe_request_full_profile()` — a light update whose `avatar_hash`/`banner_hash` doesn't match our cached blobs triggers ONE `ProfileRequest` to the sender (10-min cooldown).
4. **Update server member display names:** Iterates ALL server states and updates `member.display_name` for this peer in every server's member list. This is a local-only update (not a CRDT operation) — it just keeps the in-memory display names fresh for the UI.
5. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id: sender_peer_id }`.

### HavenMessage::ProfileUpdate (plaintext, swarm.rs)

Processed directly in `swarm.rs:handle_incoming_request()`. More detailed than the MLS path:

1. **Invisible flag handling:** If `is_invisible` is true, immediately emits `NetworkEvent::PeerStatusChanged { peer_id, status: "invisible" }` so the UI treats the peer as offline.
2. **Field truncation (security):** Truncates display_name to 64 chars, status to 96 chars, about_me to 256 chars. These limits are slightly above the UI's input limits (32/48/128) as a safety backstop against malicious peers.
3. **Avatar/banner decoding:** Same base64 decode with three-state semantics, but with a 1 MB limit for avatars (to allow GIF support) and standard base64 error handling for banners. The MLS path uses 2 MB limit; the plaintext path uses 1 MB — a minor discrepancy.
4. **Persist and update display names:** Same as MLS path — saves to MessageStore and updates in-memory server member display names.
5. **Staleness pull:** same `maybe_request_full_profile()` call as the MLS path (light update + hash mismatch → one deduped `ProfileRequest`).
6. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id }`.

---

## Incoming Status Update Handler (swarm.rs)

### HavenMessage::StatusUpdate { status }

Processed directly in `swarm.rs:handle_incoming_request()`. Emits `NetworkEvent::PeerStatusChanged { peer_id, status }`. The status string is either `"online"` or `"invisible"`. No persistence — status is transient and inferred from connectivity.

---

## Database Access Pattern

All handlers that need persistence follow the same pattern:
1. Get data directory via `crate::identity::data_dir()`
2. Construct DB path as `{data_dir}/messages.db`
3. Derive passphrase from keypair: `hex::encode(bundle_keypair.to_protobuf_encoding()[..32])`
4. Open `MessageStore::open(db_path, passphrase)` — this is SQLCipher-encrypted SQLite
5. Perform operation (`save_friend`, `remove_friend`, `save_profile`, `load_profile`)

The passphrase is derived from the first 32 bytes of the Ed25519 keypair's protobuf encoding. This ties the database encryption to the user's identity — a different keypair cannot decrypt the database.

---

## NetworkEvent Variants Emitted

- `NetworkEvent::FriendRequestReceived { peer_id }` — friend request sent or received
- `NetworkEvent::FriendRequestAccepted { peer_id }` — friend request accepted (by us or by them)
- `NetworkEvent::FriendRequestRejected { peer_id }` — friend request rejected
- `NetworkEvent::FriendRemoved { peer_id }` — friend removed
- `NetworkEvent::NicknameClaimed { nickname }` — temporary nickname successfully claimed on relay
- `NetworkEvent::NicknameReleased` — temporary nickname released
- `NetworkEvent::NicknameClaimFailed { error }` — nickname claim failed (taken/invalid)
- `NetworkEvent::NicknameResolveFailed { nickname, error }` — nickname lookup failed (not_found)
- `NetworkEvent::RelayDisconnected` — WS relay connection lost (resets nickname state)
- `NetworkEvent::TypingStarted { peer_id, server_id, channel_id }` — typing indicator (server_id empty for DMs)
- `NetworkEvent::ProfileUpdated { peer_id }` — profile changed (ours or theirs)
- `NetworkEvent::PeerStatusChanged { peer_id, status }` — invisible/online status change

---

## Broadcast Strategy Summary

| Signal | MLS path | Plaintext fallback | Scope |
|--------|----------|--------------------|-------|
| Friend request/accept/reject/remove | N/A | HavenMessage to peer | 1:1 via inbox room |
| Typing (DM) | N/A | HavenMessage to peer | 1:1 via DM room |
| Typing (channel) | MessageEnvelope::Typing via MLS broadcast | HavenMessage to each member | Server-wide |
| Profile update | MessageEnvelope::ProfileUpdate via MLS broadcast per server | HavenMessage to remaining WS peers | All connected peers |
| Invisible/online status | N/A | HavenMessage::StatusUpdate to all unique WS peers | All connected peers |

---

## State Maps

- `pending_friend_requests: HashMap<String, i64>` — peer_id to requested_at timestamp. Queued when peer is not reachable at send time. Drained on PeerJoined/RoomMembers.
- `is_invisible: bool` — local user's invisible flag. Affects StatusUpdate broadcasts and ProfileUpdate is_invisible field.
