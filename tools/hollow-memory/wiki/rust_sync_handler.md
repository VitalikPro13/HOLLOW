# Sync Handler — CRDT Operations and Server Management

Source: `rust/hollow_core/src/node/sync_handler.rs` (2576 lines)

This module contains all server-side CRDT operation handlers for server lifecycle, channel management, member management, roles, labels, permissions, nicknames, storage pledges, message pinning, channel layout, and message sync. Every handler follows a consistent pattern: permission check, create CRDT op, apply locally, persist to SQLCipher, emit NetworkEvent to Dart, broadcast to peers (MLS preferred, plaintext fallback).

## Common Handler Pattern

Nearly every handler in this file follows this sequence:

1. Look up `ServerState` in `server_states` HashMap by `server_id`
2. Check permissions via `state.has_permission()`, `state.can_change_role()`, `state.can_kick()`, or `state.can_ban()`
3. Create a CRDT op via `state.create_op(CrdtPayload::Variant { ... })`
4. Apply locally via `state.apply_op(&op)`
5. Persist: serialize state to JSON, open `MessageStore` (SQLCipher), call `save_server_state()` + `insert_crdt_op()`
6. Emit a `NetworkEvent` via `event_tx` (Dart StreamSink)
7. Broadcast: serialize op to JSON, then either:
   - MLS path: wrap in `MessageEnvelope::CrdtOp { sid, op_json }` and call `sync_handler:send_mls_broadcast()`
   - Plaintext fallback: iterate `state.members`, skip self, check `peer_is_reachable()`, send `HavenMessage::CrdtOpBroadcast`

DB access pattern (repeated in every handler):
```
data_dir = crate::identity::data_dir()
db_path = data_dir.join("messages.db")
passphrase = hex::encode(bundle_keypair.to_protobuf_encoding()[..32])
store = MessageStore::open(&db_path, &passphrase)
```

## Imports and Dependencies

- `crate::crdt::operations::{CrdtPayload, Permission, MemberRole, CrdtOp}`
- `crate::crdt::server_state::ServerState`
- `crate::crypto::{CryptoStore, MlsManager, OlmManager}`
- `crypto_handler::{peer_is_reachable, send_message_to_peer, send_mls_broadcast, send_mls_to_peer, persist_mls_state, send_encrypted_message}`
- `types::*` — NetworkEvent, NodeCommand, HavenMessage, MessageEnvelope, SyncMessageItem, SyncReactionItem, SyncFileMetaItem

## handle_create_server()

`sync_handler.rs:handle_create_server()` — Creates a new server. Called from `swarm.rs` when processing `NodeCommand::CreateServer`.

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `bundle_keypair`, `local_peer_str`, `name`

Flow:
1. Generate random 16-byte server ID via `getrandom::fill()`, hex-encoded (32 chars)
2. Create `ServerState::new(server_id, name, local_peer)` — the creator is automatically the owner
3. Create and apply `CrdtPayload::ServerCreated { name, owner_peer_id }` op
4. Persist state + op to SQLCipher
5. Insert state into `server_states` HashMap
6. Join WS relay room via `WsCommand::JoinRoom { room_code: server_id }`
7. Auto-pledge 512 MB storage for the owner — creates and applies `CrdtPayload::StoragePledgeChanged { peer_id: owner, pledge_bytes: 536870912 }`, re-persists state
8. Create MLS group via `mls_mgr.create_group(&server_id)`, persist MLS state
9. Emit `NetworkEvent::ServerCreated { server_id, name }` to Dart

No broadcast needed — the server has only one member (the creator) at creation time. New members receive full state via SyncResponse when they join.

## handle_create_channel()

`sync_handler.rs:handle_create_channel()` — Creates a channel within an existing server.

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `bundle_keypair`, `local_peer_str`, `server_id`, `name`, `category`, `channel_type`

Returns `bool` — `true` if the caller should skip to next iteration (permission denied or server not found).

Permission: `Permission::MANAGE_CHANNELS`

Channel ID generation: `"{server_id_first_8_chars}-{random_4_bytes_hex}"` — e.g., `"a1b2c3d4-deadbeef"`.

CrdtPayload: `ChannelAdded { channel_id, name, category, channel_type }`

Emits: `NetworkEvent::ChannelAdded { server_id, channel_id, name, channel_type }`

Broadcasts via MLS `MessageEnvelope::CrdtOp` or plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_remove_channel()

`sync_handler.rs:handle_remove_channel()` — Removes a channel from a server.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelRemoved { channel_id }`

Emits: `NetworkEvent::ChannelRemoved { server_id, channel_id }`

Standard broadcast pattern (MLS or plaintext fallback).

## handle_rename_server()

`sync_handler.rs:handle_rename_server()` — Renames a server.

Permission: `Permission::MANAGE_SERVER`

CrdtPayload: `ServerRenamed { new_name }`

Emits: `NetworkEvent::ServerUpdated { server_id }` — triggers Dart-side provider invalidation for `myPermissionsProvider`, `myRoleProvider`, `serverMembersProvider`.

Standard broadcast pattern.

## handle_rename_channel()

`sync_handler.rs:handle_rename_channel()` — Renames a channel within a server.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelRenamed { channel_id, new_name }`

Emits: `NetworkEvent::ChannelRenamed { server_id, channel_id, new_name }`

Standard broadcast pattern.

## handle_update_server_setting()

`sync_handler.rs:handle_update_server_setting()` — Updates a key-value server setting.

Parameters include `key: String` and `value: String` — generic settings store.

No explicit permission check in the handler (relies on caller-side validation or the CRDT op validation in `handle_envelope_crdt_op`).

CrdtPayload: `ServerSettingChanged { key, value }`

Emits: `NetworkEvent::ServerUpdated { server_id }`

Standard broadcast pattern.

## handle_delete_server()

`sync_handler.rs:handle_delete_server()` — Deletes a server entirely. Owner-only.

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `sig_cmd_tx`, `bundle_keypair`, `local_peer_str`, `server_id`

Permission: `Permission::MANAGE_SERVER` (checked via `state.has_permission()`)

Flow:
1. Permission check — error message says "only the owner can delete the server"
2. Broadcast deletion to all members BEFORE removing local state:
   - MLS path: `MessageEnvelope::ServerDelete { sid }`
   - Plaintext fallback: `HavenMessage::ServerDeleteBroadcast { server_id }`
3. Remove from `server_states` HashMap
4. Clean up MLS group: `mls_mgr.remove_group(&server_id)` + persist
5. Unregister from signaling room: `SignalingCmd::Unregister { room_code }`
6. Delete from SQLCipher: `store.delete_server_state(&server_id)`
7. Emit `NetworkEvent::ServerDeleted { server_id }`

## handle_join_server()

`sync_handler.rs:handle_join_server()` — Initiates joining a server by ID.

Parameters: `pending_server_joins`, `mls`, `ws_cmd_tx`, `ws_room_peers`, `sig_cmd_tx`, `cmd_tx`, `server_id`, `twitch_proof_json`

Flow:
1. Insert into `pending_server_joins` HashMap: `server_id -> Option<twitch_proof_json>`
2. Register with signaling: `SignalingCmd::SetRoom` + `SignalingCmd::Bootstrap` for the server_id room
3. Generate MLS KeyPackage via `mls.generate_key_package()` (base64-encoded, stored in `_mls_kp_b64` but not used directly here — sent with join request)
4. Join WS relay room: `WsCommand::JoinRoom { room_code: server_id }`
5. Send `HavenMessage::ServerJoinRequest { server_id, twitch_proof_json }` to all peers already visible in the WS room
6. If no peers found yet, the `PeerJoined`/`RoomMembers` handler in `swarm.rs` will pick up `pending_server_joins` and send the request later
7. Spawn 15-second timeout task: sends `NodeCommand::CheckPendingJoinTimeout { server_id }` after delay

The actual join completion happens in `swarm.rs` when a `ServerJoinResponse` is received — that handler applies the full `ServerState`, creates CRDT ops, and adds the member to the MLS group.

## handle_change_role()

`sync_handler.rs:handle_change_role()` — Changes a member's power role.

Parameters include `peer_id` (target) and `new_role` (string).

Permission: `state.can_change_role(&local_peer, &peer_id, &new_member_role)` — tier-gated, can only change roles of members below your own rank.

Key detail on CRDT priority: Uses the **author's** (local user's) role priority, not the target role's priority. This ensures demotions work correctly — an Owner (priority 3) demoting an Admin (priority 2) to Member sends priority 3, which beats the existing priority 2 in the AdminLwwReg (Last-Writer-Wins Register).

```rust
let author_role = state.get_role(&local_peer);
let op = state.create_op(CrdtPayload::RoleChanged {
    peer_id, role: new_member_role, priority: author_role.priority(),
});
```

CrdtPayload: `RoleChanged { peer_id, role, priority }`

Emits: `NetworkEvent::RoleChanged { server_id, peer_id, new_role }`

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast` (does NOT use MLS envelope for role changes — iterates members directly).

## handle_kick_member()

`sync_handler.rs:handle_kick_member()` — Kicks a member from a server.

Permission: `state.can_kick(&local_peer, &peer_id)` — tier-gated.

Critical ordering: Collects broadcast targets BEFORE `apply_op()` removes the member from `state.members`.

```rust
let broadcast_targets: Vec<String> = state.members.keys()
    .filter(|m| *m != &local_peer)
    .cloned()
    .collect();
let _ = state.apply_op(&op);
```

CrdtPayload: `MemberRemoved { peer_id }`

Emits: `NetworkEvent::MemberLeft { server_id, peer_id }`

Two-phase notification:
1. CRDT op broadcast to remaining members (excluding kicked peer)
2. Kick notification to the kicked peer specifically:
   - MLS: `MessageEnvelope::MemberKick { sid }` via `send_mls_to_peer()`, PLUS plaintext `HavenMessage::MemberKickBroadcast` as redundancy
   - No MLS: plaintext `HavenMessage::MemberKickBroadcast` only

MLS cleanup after kick:
1. `mls_mgr.remove_member(&server_id, &peer_id)` — generates commit bytes
2. `mls_mgr.merge_pending_commit(&server_id)` — applies commit locally
3. `persist_mls_state()`
4. Export SFrame key for voice channel key rotation: `mls_mgr.export_secret(&server_id, "sframe", b"", 32)`
5. Emit `NetworkEvent::MlsEpochChanged { server_id, epoch, sframe_key }`
6. Broadcast MLS commit (base64) to remaining members via `HavenMessage::MlsCommit`

## handle_leave_server()

`sync_handler.rs:handle_leave_server()` — Self-removal from a server.

Guard: **Owner cannot leave** — must delete or transfer ownership first. Returns error `NetworkEvent::Error` with message.

Flow:
1. Check role is not Owner
2. Create `CrdtPayload::MemberRemoved { peer_id: local_peer }` (same payload as kick)
3. Collect broadcast targets before `apply_op()`
4. Persist state with self removed
5. Broadcast CRDT op to remaining members
6. MLS self-removal: `mls_mgr.remove_member(&server_id, &local_peer)`, merge commit, broadcast MLS commit to remaining members. On MLS removal failure, falls back to `mls_mgr.remove_group(&server_id)` (force-drops the group locally)
7. Remove from `server_states` HashMap
8. Unregister from signaling: `SignalingCmd::Unregister`
9. Leave WS relay room: `WsCommand::LeaveRoom`
10. Delete server state from SQLCipher
11. Emit `NetworkEvent::ServerDeleted { server_id }` — same event as deletion, Dart side handles identically (server disappears from UI)

## handle_ban_member()

`sync_handler.rs:handle_ban_member()` — Bans a member from a server (removal + ban list).

Permission: `state.can_ban(&local_peer, &peer_id)` — tier-gated.

Same ordering as kick: collects broadcast targets before `apply_op()`.

CrdtPayload: `MemberBanned { peer_id }` — different from `MemberRemoved`, adds the peer to the server's ban list so they cannot rejoin.

Emits: `NetworkEvent::MemberLeft { server_id, peer_id }` — same event as kick/leave.

Notification to banned peer: `HavenMessage::MemberKickBroadcast` (same message as kick — the ban distinction is server-side only).

MLS cleanup: identical to kick — `remove_member()`, `merge_pending_commit()`, epoch rotation, SFrame key export, commit broadcast.

## handle_unban_member()

`sync_handler.rs:handle_unban_member()` — Removes a member from the server's ban list.

Permission: `Permission::KICK_MEMBERS` — same permission that gates kick/ban.

CrdtPayload: `MemberUnbanned { peer_id }`

Emits: `NetworkEvent::ServerUpdated { server_id }` — NOT `MemberJoined` (unbanning does not re-add the member, they must rejoin).

Standard broadcast pattern (MLS or plaintext fallback).

## handle_label_op()

`sync_handler.rs:handle_label_op()` — Unified handler for all label CRDT operations.

Parameters include a raw `CrdtPayload` (the specific label variant) rather than separate handlers per operation.

Handles these CrdtPayload variants:
- `LabelCreated { label_id, name, color, icon, position }` — requires `MANAGE_ROLES`
- `LabelDeleted { label_id }` — requires `MANAGE_ROLES`
- `LabelUpdated { label_id, name, color, icon, position }` — requires `MANAGE_ROLES`
- `LabelAssigned { peer_id, label_id }` — self-assign allowed, otherwise requires `MANAGE_ROLES`
- `LabelUnassigned { peer_id, label_id }` — self-unassign allowed, otherwise requires `MANAGE_ROLES`

Self-toggle logic:
```rust
let is_self_toggle = match &payload {
    CrdtPayload::LabelAssigned { peer_id, .. }
    | CrdtPayload::LabelUnassigned { peer_id, .. } => peer_id == &local_peer,
    _ => false,
};
if !is_self_toggle && !state.has_permission(&local_peer, Permission::MANAGE_ROLES) {
    // denied
}
```

Emits: `NetworkEvent::ServerUpdated { server_id }`

Standard broadcast pattern.

## handle_set_channel_visibility()

`sync_handler.rs:handle_set_channel_visibility()` — Sets channel visibility mode.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelVisibilityChanged { channel_id, visibility }` — `visibility` is a String (e.g., "public", "moderator_only", "admin_only").

Emits: `NetworkEvent::ServerUpdated { server_id }`

Note: Channel visibility is UI-filtered only. All members still receive all messages via the server-wide MLS group. Per-channel MLS subgroups needed before v1.0 for true enforcement.

## handle_set_channel_posting()

`sync_handler.rs:handle_set_channel_posting()` — Sets who can post in a channel.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelPostingChanged { channel_id, posting }` — `posting` is a String (e.g., "everyone", "moderator_only", "admin_only").

Emits: `NetworkEvent::ServerUpdated { server_id }`

Same UI-only enforcement caveat as visibility.

## handle_change_role_permissions()

`sync_handler.rs:handle_change_role_permissions()` — Modifies the permission bitmask for a power role.

Parameters: `server_id`, `role` (String), `permissions` (u32 bitmask).

Permission: Requires `Permission::MANAGE_ROLES` AND the actor's role must outrank the target role (`actor_role.outranks(&target_role)`). This prevents Moderators from editing Admin permissions, for example.

```rust
let actor_role = state.get_role(&local_peer);
let target_role = MemberRole::from_str(&role);
if !state.has_permission(&local_peer, Permission::MANAGE_ROLES) || !actor_role.outranks(&target_role) {
    // denied
}
```

CrdtPayload: `RolePermissionsChanged { role, permissions }`

Emits: `NetworkEvent::ServerUpdated { server_id }` — triggers Dart-side `myPermissionsProvider` invalidation.

Standard broadcast pattern.

## handle_set_nickname()

`sync_handler.rs:handle_set_nickname()` — Sets a per-server nickname for a member.

Permission: Members can set their own nickname. Setting another member's nickname requires `Permission::MANAGE_ROLES` (Admin+).

CrdtPayload: `NicknameChanged { peer_id, nickname }`

Emits: `NetworkEvent::MemberJoined { server_id, peer_id }` — reuses the MemberJoined event to trigger Dart-side member list refresh (not a true "join" event).

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast` (no MLS wrapper for nickname changes).

## handle_set_twitch_username()

`sync_handler.rs:handle_set_twitch_username()` — Sets the verified Twitch username for a member in a server.

Permission: Same as nickname — self or `Permission::MANAGE_ROLES`.

CrdtPayload: `TwitchUsernameChanged { peer_id, twitch_username }`

Emits: `NetworkEvent::MemberJoined { server_id, peer_id }` — same refresh trick as nickname.

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_request_channel_sync()

`sync_handler.rs:handle_request_channel_sync()` — On-demand message sync when user opens a channel.

Parameters include `channel_sync_sent: &mut HashMap<String, std::time::Instant>` for deduplication.

Dedup: Skips if the same `"{server_id}:{channel_id}"` key was synced within the last 5 seconds.

Flow:
1. Check dedup key, insert current instant
2. Open MessageStore, query latest channel timestamp via `store.get_latest_channel_timestamp()`
3. Query per-sender timestamps via `store.get_per_sender_timestamps()` — for gap-aware sync
4. Send `HavenMessage::ChannelSyncRequest { server_id, channel_id, since_timestamp, sender_timestamps }` to all online server members

The sync request includes both a global `since_timestamp` and per-sender timestamps, enabling the responder to identify exactly which messages the requester is missing per sender (prevents re-sending messages already received from other sync sources).

## handle_update_channel_layout()

`sync_handler.rs:handle_update_channel_layout()` — Updates the channel ordering/category layout for a server.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelLayoutUpdated { layout_json }` — the layout is stored as a JSON string in the CRDT.

Emits: `NetworkEvent::ServerUpdated { server_id }`

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_pin_message()

`sync_handler.rs:handle_pin_message()` — Pins a message in a channel.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `MessagePinned { channel_id, message_id }`

Emits: `NetworkEvent::MessagePinned { server_id, channel_id, message_id }`

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_unpin_message()

`sync_handler.rs:handle_unpin_message()` — Unpins a message from a channel.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `MessageUnpinned { channel_id, message_id }`

Emits: `NetworkEvent::MessageUnpinned { server_id, channel_id, message_id }`

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_set_storage_pledge()

`sync_handler.rs:handle_set_storage_pledge()` — Sets how much disk space a member pledges to a server's vault.

No explicit permission check — any member can set their own pledge. The `peer_id` in the payload is always `local_peer`.

CrdtPayload: `StoragePledgeChanged { peer_id, pledge_bytes }` — `pledge_bytes` is u64 (bytes).

Emits: `NetworkEvent::ServerUpdated { server_id }`

Broadcasts via plaintext `HavenMessage::CrdtOpBroadcast`.

## handle_check_pending_join_timeout()

`sync_handler.rs:handle_check_pending_join_timeout()` — Called 15 seconds after `handle_join_server()` to check if the join is still pending.

If `pending_server_joins` still contains the `server_id`:
1. Remove from pending map
2. Emit `NetworkEvent::ServerJoinFailed { server_id, reason: "No members responded within 15 seconds" }`
3. Leave WS room: `WsCommand::LeaveRoom { room_code: server_id }`

If already removed (join succeeded), this is a no-op.

## flush_pending_sync_requests()

`sync_handler.rs:flush_pending_sync_requests()` — Retries previously failed channel sync responses after Olm session re-establishment.

Parameters: `pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>` — maps peer_id to list of `(server_id, channel_id, since_timestamp)` tuples.

Called when an Olm session is established with a peer who had pending sync requests that failed due to missing encryption session.

Flow per entry:
1. Emit `NetworkEvent::MessageSyncStarted { server_id, peer_id }`
2. Re-query per-sender timestamps at flush time (DB may have changed since original request)
3. Query messages: `get_channel_messages_since_per_sender()` or `get_channel_messages_since()` (limit 200)
4. Build `SyncMessageItem` list with: sender, text, timestamp, signature, public_key, message_id, edited_at, reply_to, file_id, file_meta, hidden_at, reactions
5. Load reactions via `store.load_reactions_for_sync(&msg_ids)`
6. Load file metadata via `store.get_file_metadata(fid)` for each message with a file_id
7. Count total messages to determine `has_more` flag (true if items >= 200 and total > 200)
8. Wrap in `MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, target: None }`
9. Send via `send_encrypted_message()` (Olm)
10. If send fails again, emit `NetworkEvent::MessageSyncFailed { server_id, error: "Retry after re-key also failed" }`

## handle_envelope_crdt_op()

`sync_handler.rs:handle_envelope_crdt_op()` — Processes incoming CRDT ops received via MLS `MessageEnvelope::CrdtOp`.

This is the **receiver-side** permission validation for all CRDT operations. Every op received from another peer is checked here before being applied.

Parameters: `server_states`, `bundle_keypair`, `event_tx`, `sid`, `op_json`

Flow:
1. Deserialize `CrdtOp` from `op_json`
2. Look up sender's role in server state: `state.get_role(&op.author)`
3. Get sender's permissions: `sender_role.default_permissions()`
4. Permission validation per payload type:

| CrdtPayload variant | Permission required |
|---|---|
| `ChannelAdded`, `ChannelRemoved`, `ChannelRenamed`, `ChannelLayoutUpdated` | `MANAGE_CHANNELS` |
| `RoleChanged { peer_id, role }` | `state.can_change_role(&op.author, peer_id, role)` |
| `ServerRenamed`, `ServerSettingChanged` | Owner or Admin |
| `MemberRemoved { peer_id }` | `KICK_MEMBERS` + must outrank target |
| `MemberAdded` | Must be a current member |
| `NicknameChanged { peer_id }` | Self or Owner/Admin |
| `TwitchUsernameChanged { peer_id }` | Self or Owner/Admin |
| `MessagePinned`, `MessageUnpinned` | `MANAGE_CHANNELS` |
| `StoragePledgeChanged { peer_id }` | Self or Owner/Admin |
| `RolePermissionsChanged { role }` | `MANAGE_ROLES` + must outrank target role |
| `MemberBanned { peer_id }` | `KICK_MEMBERS` + must outrank target |
| `MemberUnbanned` | `KICK_MEMBERS` |
| `ChannelVisibilityChanged`, `ChannelPostingChanged` | `MANAGE_CHANNELS` |
| `LabelCreated`, `LabelDeleted`, `LabelUpdated` | `MANAGE_ROLES` |
| `LabelAssigned { peer_id }`, `LabelUnassigned { peer_id }` | Self or `MANAGE_ROLES` |
| `ServerCreated` | Always allowed |

5. If not allowed: log `[HOLLOW-SECURITY] REJECTED MLS CrdtOp from {author}` and return
6. Apply op: `state.apply_op(&op)`
7. Check if op was actually new (compare op_log length before/after)
8. If new: persist state + op to SQLCipher
9. Emit appropriate NetworkEvent per payload type:

**CRITICAL**: Specific payload variants are explicitly listed to emit `NetworkEvent::ServerUpdated` (not the `_ =>` wildcard which emits `SyncCompleted`). The `ServerUpdated` Dart handler invalidates `myPermissionsProvider`, `myRoleProvider`, and `serverMembersProvider`. New CrdtPayload variants that affect permissions/channels/labels MUST be added to the explicit match arms, not left to fall into `_ =>`.

Event mapping:
- `ChannelAdded` -> `NetworkEvent::ChannelAdded`
- `ChannelRemoved` -> `NetworkEvent::ChannelRemoved`
- `MemberAdded` -> `NetworkEvent::MemberJoined`
- `MemberRemoved` -> `NetworkEvent::MemberLeft`
- `RoleChanged` -> `NetworkEvent::RoleChanged`
- `ServerSettingChanged`, `ServerRenamed`, `RolePermissionsChanged`, `MemberBanned`, `MemberUnbanned`, `ChannelVisibilityChanged`, `ChannelPostingChanged`, all Label variants -> `NetworkEvent::ServerUpdated`
- Everything else (`_ =>`) -> `NetworkEvent::SyncCompleted { ops_applied: 1 }`

## handle_envelope_server_delete()

`sync_handler.rs:handle_envelope_server_delete()` — Processes incoming `MessageEnvelope::ServerDelete` via MLS.

Permission: Sender must be Owner. Checked via `state.get_role(sender_peer_id) == MemberRole::Owner`.

If sender is not owner: logs `[HOLLOW-SECURITY] REJECTED MLS ServerDelete` and returns.

Flow on valid owner deletion:
1. Remove from `server_states`
2. Delete from SQLCipher
3. Remove MLS group + persist
4. Emit `NetworkEvent::ServerDeleted`

## handle_envelope_member_kick()

`sync_handler.rs:handle_envelope_member_kick()` — Processes incoming `MessageEnvelope::MemberKick` via MLS. This is the **receiver side** — the local node is being kicked.

Permission validation: Sender must have `KICK_MEMBERS` permission AND must outrank the local peer.

```rust
let can_kick = if let Some(state) = server_states.get(&sid) {
    let sender_role = state.get_role(sender_peer_id);
    let our_role = state.get_role(local_peer);
    (sender_perms & Permission::KICK_MEMBERS) != 0 && sender_role.outranks(&our_role)
} else { false };
```

If rejected: logs `[HOLLOW-SECURITY] REJECTED MLS MemberKick` and returns.

On valid kick:
1. Remove from `server_states`
2. Delete from SQLCipher
3. Remove MLS group + persist
4. Emit `NetworkEvent::ServerDeleted` — same event as leaving/deletion (server disappears from UI)

## handle_envelope_sync_req()

`sync_handler.rs:handle_envelope_sync_req()` — Processes incoming `MessageEnvelope::SyncReq` via MLS. Responds with missing CRDT ops.

Parameters include `state_vector_json` — the requester's state vector describing what ops they already have.

Flow:
1. Deserialize their `StateVector` from JSON
2. Compute delta via `crate::crdt::sync::compute_delta(&state.op_log, &their_vector)` — finds ops in our log that they're missing
3. If delta is non-empty: serialize ops, wrap in `MessageEnvelope::SyncResp { sid, ops_json, target: None }`
4. Send via MLS (`send_mls_to_peer`); if MLS fails, fall back to Olm (`send_encrypted_message`)

## handle_envelope_sync_resp()

`sync_handler.rs:handle_envelope_sync_resp()` — Processes incoming `MessageEnvelope::SyncResp` via MLS. Applies received CRDT ops.

Flow:
1. Deserialize `Vec<CrdtOp>` from `ops_json`
2. Merge via `crate::crdt::sync::merge_ops(state, incoming_ops)` — returns count of newly applied ops
3. If any applied: persist state to SQLCipher
4. Emit `NetworkEvent::SyncCompleted { server_id, ops_applied }`

## handle_envelope_channel_sync_req()

`sync_handler.rs:handle_envelope_channel_sync_req()` — Processes incoming `MessageEnvelope::ChannelSyncReq` via MLS. Responds with channel messages.

Parameters: `sid`, `cid`, `since_timestamp`, `sender_timestamps: HashMap<String, i64>`

Flow:
1. Guard: server must exist in `server_states`
2. Query messages from DB: uses per-sender timestamps if available, otherwise global `since_timestamp` (limit 200)
3. Build `SyncMessageItem` list with reactions and file metadata
4. Calculate `has_more` flag (items >= 200 and total > 200)
5. Wrap in `MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more, target: None }`
6. Send via MLS to the requesting peer

## handle_envelope_channel_probe()

`sync_handler.rs:handle_envelope_channel_probe()` — Responds to a channel probe with local latest timestamp and message count.

Purpose: Lightweight check to determine if the requester needs a full sync. The probe response lets the requester compare their state against the responder's without transferring any messages.

Flow:
1. Query `our_latest` timestamp and `our_count` from DB
2. Respond with `MessageEnvelope::ChannelProbeResp { sid, cid, their_latest: our_latest, msg_count: our_count, target: None }`
3. Send via MLS; if MLS fails, fall back to Olm

## handle_envelope_channel_probe_resp()

`sync_handler.rs:handle_envelope_channel_probe_resp()` — Processes a channel probe response and triggers sync if needed.

Flow:
1. Dedup check: skip if same channel synced within 5 seconds
2. Query local latest timestamp from DB
3. If `their_latest > our_latest`: we're behind, trigger a sync
4. Insert dedup key, query per-sender timestamps
5. Send `HavenMessage::ChannelSyncRequest` to the responder peer (plaintext, not MLS)

## handle_envelope_channel_sync_batch()

`sync_handler.rs:handle_envelope_channel_sync_batch()` — Processes incoming `MessageEnvelope::ChannelSyncBatch` via MLS. Inserts received messages into local DB.

Flow per message in batch:
1. Insert via `store.insert_channel_message()` — returns 1 if new (deduplication by message_id)
2. If `hidden_at` is set: call `store.set_channel_message_hidden()`
3. If `file_meta` is present: insert via `store.insert_file_metadata()`, emit `NetworkEvent::FileHeaderReceived`
4. If message has reactions: insert each via `store.add_reaction()`

Pagination: If `has_more == Some(true)`:
1. Query updated per-sender timestamps and latest timestamp from DB
2. Send follow-up `MessageEnvelope::ChannelSyncReq` via MLS to request next batch

Completion: When `has_more != Some(true)`, emit `NetworkEvent::MessageSyncCompleted { server_id, new_message_count }`

## Permission Bitmask Reference

Permissions used in this module (from `crate::crdt::operations::Permission`):
- `MANAGE_CHANNELS` — create/remove/rename channels, set visibility/posting, pin/unpin, update layout
- `MANAGE_SERVER` — rename/delete server, change settings
- `MANAGE_ROLES` — change role permissions, manage labels (create/delete/update/assign others)
- `KICK_MEMBERS` — kick, ban, unban members

Tier-gated operations (require outranking the target):
- `handle_change_role()` — `state.can_change_role()`
- `handle_kick_member()` — `state.can_kick()`
- `handle_ban_member()` — `state.can_ban()`
- `handle_change_role_permissions()` — `actor_role.outranks(&target_role)`
- `handle_envelope_crdt_op()` — validates all of the above on the receiver side

## NetworkEvent Emission Summary

| Event | Emitting handlers |
|---|---|
| `ServerCreated` | `handle_create_server` |
| `ServerUpdated` | `handle_rename_server`, `handle_update_server_setting`, `handle_unban_member`, `handle_label_op`, `handle_set_channel_visibility`, `handle_set_channel_posting`, `handle_change_role_permissions`, `handle_set_storage_pledge`, `handle_update_channel_layout`, `handle_envelope_crdt_op` (for settings/rename/permissions/ban/label variants) |
| `ServerDeleted` | `handle_delete_server`, `handle_leave_server`, `handle_envelope_server_delete`, `handle_envelope_member_kick` |
| `ChannelAdded` | `handle_create_channel`, `handle_envelope_crdt_op` |
| `ChannelRemoved` | `handle_remove_channel`, `handle_envelope_crdt_op` |
| `ChannelRenamed` | `handle_rename_channel` |
| `MemberJoined` | `handle_set_nickname`, `handle_set_twitch_username`, `handle_envelope_crdt_op` (MemberAdded) |
| `MemberLeft` | `handle_kick_member`, `handle_ban_member`, `handle_envelope_crdt_op` (MemberRemoved) |
| `RoleChanged` | `handle_change_role`, `handle_envelope_crdt_op` |
| `ServerJoinFailed` | `handle_check_pending_join_timeout` |
| `SyncCompleted` | `handle_envelope_crdt_op` (wildcard `_ =>`), `handle_envelope_sync_resp` |
| `MessageSyncStarted` | `flush_pending_sync_requests` |
| `MessageSyncCompleted` | `handle_envelope_channel_sync_batch` |
| `MessageSyncFailed` | `flush_pending_sync_requests` |
| `MessagePinned` | `handle_pin_message` |
| `MessageUnpinned` | `handle_unpin_message` |
| `MlsEpochChanged` | `handle_kick_member`, `handle_ban_member` |
| `FileHeaderReceived` | `handle_envelope_channel_sync_batch` |
| `Error` | Multiple handlers (permission denied cases) |

## Broadcast Strategy

Two broadcast paths exist throughout the module:

**MLS path** (preferred when MLS group exists): Wrap the CRDT op in `MessageEnvelope::CrdtOp { sid, op_json }` and call `send_mls_broadcast()` — encrypts for the entire MLS group in one operation.

**Plaintext fallback** (when no MLS group or MLS fails): Iterate `state.members.keys()`, skip self, check `peer_is_reachable(ws_room_peers, peer)`, send `HavenMessage::CrdtOpBroadcast { server_id, op_json }` via `send_message_to_peer()`.

Notable exceptions:
- `handle_change_role()` — always uses plaintext broadcast (no MLS wrapper)
- `handle_set_nickname()` / `handle_set_twitch_username()` — always uses plaintext broadcast
- `handle_set_storage_pledge()` — always uses plaintext broadcast
- `handle_update_channel_layout()` / `handle_pin_message()` / `handle_unpin_message()` — always uses plaintext broadcast
- `handle_create_server()` — no broadcast (single member)
