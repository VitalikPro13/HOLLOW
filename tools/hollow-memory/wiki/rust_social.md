# Rust Social Module — Friends, Profiles, Typing, Status

The social module handles friend requests, profile updates, typing indicators, and invisible status broadcasting. All operations persist to SQLCipher via `MessageStore` and communicate with remote peers via WS relay plaintext messages (for DMs and direct peer communication) or MLS broadcast (for server-scoped signals like typing and profiles). This module also handles the MLS-path envelope equivalents for typing and profile updates.

Source file: `rust/hollow_core/src/node/social.rs` (488 lines)

Imports from: `crypto_handler::{peer_is_reachable, send_mls_broadcast, send_message_to_peer}`, `signaling::SignalingCmd`, `types::*`

---

## handle_send_friend_request()

`social.rs:handle_send_friend_request(event_tx, ws_cmd_tx, ws_room_peers, sig_cmd_tx, pending_friend_requests, bundle_keypair, local_peer_str, peer_id_str)`

Called when the local user sends a friend request (`NodeCommand::SendFriendRequest`).

Steps:
1. **Persist as pending outgoing:** Opens `MessageStore` from `~/.hollow/messages.db` (passphrase derived from first 32 bytes of keypair protobuf encoding, hex-encoded), calls `store.save_friend(peer_id, "pending", "outgoing", now)`.
2. **Register DM room:** Computes the deterministic DM room code via `dm_room_code(local_peer, peer_id)` (SHA-256 hash of sorted peer IDs with "dm-" prefix). Registers the room with signaling (`SignalingCmd::SetRoom` + `SignalingCmd::Bootstrap`) and joins the WS relay room (`WsCommand::JoinRoom`). This enables peer discovery even before the request is accepted.
3. **Join target's inbox room:** Joins `"inbox:{peer_id}"` on the WS relay. Every peer auto-joins their own inbox room on startup, so this is the reliable way to reach any peer regardless of shared servers.
4. **Send or queue:** If the target peer is already reachable (in any shared WS room), sends `HavenMessage::FriendRequest { requested_at: now }` immediately via `send_message_to_peer()`. If not reachable, inserts into `pending_friend_requests: HashMap<String, i64>` (peer_id -> requested_at timestamp). Pending requests are drained when the peer appears via `PeerJoined` or `RoomMembers` events in swarm.rs.
5. **Emit event:** Sends `NetworkEvent::FriendRequestReceived { peer_id }` to Dart so the UI shows the outgoing request immediately.

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
1. **Remove from DB:** Opens MessageStore, calls `store.remove_friend(peer_id)`. The friend record is deleted entirely, not set to "rejected".
2. **Notify peer:** If reachable, sends `HavenMessage::FriendReject`.
3. **Emit event:** `NetworkEvent::FriendRequestRejected { peer_id }`.

Note: No DM room registration — rejecting does not create a DM channel. No signaling cmd involvement.

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
1. Persists as `save_friend(peer_str, "pending", "incoming", requested_at)` in MessageStore
2. Registers the DM room code via signaling (`SetRoom` + `Bootstrap`) for future peer discovery
3. Emits `NetworkEvent::FriendRequestReceived { peer_id }`

### HavenMessage::FriendAccept
1. Updates to `save_friend(peer_str, "accepted", "", now)` in MessageStore
2. Registers DM room code via signaling
3. Emits `NetworkEvent::FriendRequestAccepted { peer_id }`

### HavenMessage::FriendReject
1. Calls `remove_friend(peer_str)` in MessageStore
2. Emits `NetworkEvent::FriendRequestRejected { peer_id }`

### HavenMessage::FriendRemove
1. Calls `remove_friend(peer_str)` in MessageStore
2. Emits `NetworkEvent::FriendRemoved { peer_id }`

### Pending Friend Request Drain

When a peer becomes reachable (`PeerJoined` or `RoomMembers` events in swarm.rs), the node checks `pending_friend_requests` for any queued requests to that peer. If found, sends `HavenMessage::FriendRequest { requested_at }` and removes from the pending map. This handles the case where the friend request was initiated before the peer was online.

---

## handle_send_typing_indicator()

`social.rs:handle_send_typing_indicator(ws_cmd_tx, ws_room_peers, mls, server_states, bundle_keypair, local_peer_str, server_id, channel_id)`

Called when the local user types in a chat (`NodeCommand::SendTypingIndicator`). Supports two modes:

### DM typing (server_id is empty)
When `server_id.is_empty()`, the `channel_id` field is repurposed as the target peer ID. Sends `HavenMessage::TypingIndicator { server_id: "", channel_id: peer_id }` directly to the peer if reachable. No MLS involved — DMs use Olm sessions, but typing indicators are plaintext for simplicity (they reveal no content).

### Channel typing (server_id is non-empty)
1. **MLS path:** If the server has an active MLS group, constructs `MessageEnvelope::Typing { sid, cid }` and broadcasts via `send_mls_broadcast()`. This is the preferred path — the typing indicator is encrypted within the server's MLS group.
2. **Plaintext fallback:** If MLS is unavailable, sends `HavenMessage::TypingIndicator { server_id, channel_id }` individually to every reachable server member (except self). Iterates `server_states[server_id].members.keys()`.

---

## handle_set_invisible()

`social.rs:handle_set_invisible(ws_cmd_tx, ws_room_peers, local_peer_str, invisible, is_invisible)`

Called when the local user toggles invisible mode (`NodeCommand::SetInvisible`).

Steps:
1. Updates the `is_invisible: &mut bool` flag in swarm state
2. Determines status string: `"invisible"` if true, `"online"` if false
3. Constructs `HavenMessage::StatusUpdate { status }` and broadcasts to every unique connected peer across all WS rooms. Uses a `HashSet<String>` (`sent_to`) to deduplicate peers that appear in multiple rooms.

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

2. **MLS broadcast to servers:** Constructs `MessageEnvelope::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible }`. Iterates all `server_states` and for each server with an active MLS group, calls `send_mls_broadcast()`. Tracks which peer IDs were reached via MLS in `mls_reached: HashSet<String>`.

3. **Plaintext fallback for remaining peers:** Constructs `HavenMessage::ProfileUpdate` with the same fields. Collects all unique peers across all WS rooms, then sends to each peer NOT already reached via MLS and NOT self. This covers DM peers and peers in servers where MLS is not yet established.

4. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id: local_peer }` so Dart refreshes the local profile UI.

Logging: Outputs the count of plaintext recipients vs MLS-reached peers for debugging broadcast coverage.

---

## send_own_profile_to_peer()

`social.rs:send_own_profile_to_peer(ws_cmd_tx, ws_room_peers, bundle_keypair, local_peer_str, target_peer, is_invisible)`

Sends the local user's current profile to a specific peer. Called proactively in swarm.rs when:
- A new peer joins a WS room (`PeerJoined` event)
- A new peer appears in a room member list (`RoomMembers` event)

Steps:
1. Opens MessageStore, loads own profile via `store.load_profile(local_peer_str)`
2. If a profile exists, encodes avatar/banner bytes as base64 strings
3. Sends `HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible }` to the target peer

This ensures every peer receives the local user's profile data as soon as connectivity is established, without waiting for a profile change. The `is_invisible` flag is included so the receiving peer knows the sender's visibility status from the first message.

---

## Incoming Typing Handlers

### handle_envelope_typing() (MLS path)

`social.rs:handle_envelope_typing(event_tx, sender_peer_id, sid, cid)`

Processes `MessageEnvelope::Typing` received via MLS decryption. Simply emits `NetworkEvent::TypingStarted { peer_id: sender_peer_id, server_id: sid, channel_id: cid }` to Dart. No validation beyond MLS group membership (which is implicit in successful MLS decryption).

### HavenMessage::TypingIndicator (plaintext, swarm.rs)

Processed directly in `swarm.rs:handle_incoming_request()`. Emits `NetworkEvent::TypingStarted { peer_id, server_id, channel_id }`. No additional validation — any connected peer can send typing indicators. For DM typing, `server_id` is empty and `channel_id` is the sender's peer ID.

---

## Incoming Profile Update Handlers

### handle_envelope_profile_update() (MLS path)

`social.rs:handle_envelope_profile_update(event_tx, server_states, bundle_keypair, sender_peer_id, display_name, status, about_me, updated_at, avatar_b64, banner_b64)`

Processes `MessageEnvelope::ProfileUpdate` received via MLS decryption.

Steps:
1. **Decode avatar/banner:** Empty string = no change (None). `"CLEAR"` = clear signal (Some(empty vec)). Otherwise, base64-decode with a 2 MB size limit per field (rejects payloads > 2,000,000 bytes after decoding).
2. **Persist profile:** Opens MessageStore, calls `save_profile(sender_peer_id, display_name, status, about_me, updated_at, avatar_bytes, banner_bytes)`.
3. **Update server member display names:** Iterates ALL server states and updates `member.display_name` for this peer in every server's member list. This is a local-only update (not a CRDT operation) — it just keeps the in-memory display names fresh for the UI.
4. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id: sender_peer_id }`.

### HavenMessage::ProfileUpdate (plaintext, swarm.rs)

Processed directly in `swarm.rs:handle_incoming_request()`. More detailed than the MLS path:

1. **Invisible flag handling:** If `is_invisible` is true, immediately emits `NetworkEvent::PeerStatusChanged { peer_id, status: "invisible" }` so the UI treats the peer as offline.
2. **Field truncation (security):** Truncates display_name to 64 chars, status to 96 chars, about_me to 256 chars. These limits are slightly above the UI's input limits (32/48/128) as a safety backstop against malicious peers.
3. **Avatar/banner decoding:** Same base64 decode with three-state semantics, but with a 1 MB limit for avatars (to allow GIF support) and standard base64 error handling for banners. The MLS path uses 2 MB limit; the plaintext path uses 1 MB — a minor discrepancy.
4. **Persist and update display names:** Same as MLS path — saves to MessageStore and updates in-memory server member display names.
5. **Emit event:** `NetworkEvent::ProfileUpdated { peer_id }`.

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
