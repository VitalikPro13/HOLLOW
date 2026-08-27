# Sync Handler — CRDT Operations and Server Management

Source: `rust/hollow_core/src/node/sync_handler.rs` (~2740 lines after the 2026-07-14 dedup refactor)

This module contains all server-side CRDT operation handlers for server lifecycle, channel management, member management, roles, labels, permissions, nicknames, storage pledges, message pinning, channel layout, and message sync. The shared shape (gate → author → persist → emit → broadcast) lives ONCE in a driver + chunk helpers; each handler keeps only its own gate, payload, event, and side effects.

## Common Handler Pattern (the driver + chunk helpers)

Most simple handlers are one-call wrappers around the shared driver:

```rust
author_broadcast_op(
    server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
    &server_id,
    OpGate::Perm(Permission::MANAGE_CHANNELS),      // or OwnerOrAdmin / CanMute / ManageRolesOutranking / SelfOrPerm / Always
    Some("Permission denied: cannot manage channels"), // None = log-only silent deny (nickname/twitch/layout/pin/unpin)
    CrdtPayload::ChannelPostingChanged { .. },
    &format!("Setting channel {channel_id} posting to {posting}"),  // log label
    NetworkEvent::ServerUpdated { server_id: server_id.clone() },   // prebuilt event
    OpBroadcast::MlsFirst { mls, crypto_store },    // or OpBroadcast::PlaintextWithFan { local_device_id }
    crdt_store,
).await
```

Driver sequence (identical to the old per-handler bodies): (1) `server_states.get_mut` (missing server → `false`, no event), (2) `gate_allows()` — deny returns `true` and emits the `Error` event unless silent, (3) `author_op()` = `create_op` → `apply_op` → `crdt_store.insert_op` + `save_state_snapshot` (CrdtStore actor batches writes; no `MessageStore::open()` for CRDT persistence), (4) send the prebuilt `NetworkEvent`, (5) broadcast.

Broadcast modes:
- **`OpBroadcast::MlsFirst`** → `broadcast_op_mls_first()`: MLS `MessageEnvelope::CrdtOp` via `send_mls_broadcast` when the group exists, then ALWAYS also the plaintext `CrdtOpBroadcast` twin via `broadcast_crdt_op_to_members` (idempotent — op_log dedups, receivers re-validate; a skewed-epoch MLS receiver silently drops ciphertext with no recovery, the plaintext copy guarantees convergence). Siblings converge for free (room broadcast hits their sockets).
- **`OpBroadcast::PlaintextWithFan`** → `broadcast_op_plaintext_with_fan()`: plaintext member broadcast + `fan_to_own_siblings` (the master-keyed member broadcast excludes the actor's identity, so plaintext-only ops must fan to our OWN online siblings, EXCLUDING the acting device `local_device_id`). Used by role/nickname/twitch/layout/pin/unpin/pledge.

Handlers with extra duties stay custom but use the chunk helpers directly: `deny()`, `author_op()`, `broadcast_op_mls_first()` (create_server, create_channel, change_role, emote_op, delete_server) — and kick/ban/leave use `other_member_targets()` (collect BEFORE apply_op removes the member), `broadcast_removal_op(targets, skip)` (skip = the kicked/banned identity, which gets `MemberKickBroadcast` instead; `None` for leave so siblings apply the self-removal), and `mls_remove_identity_and_broadcast()` (all leaves of an identity + `broadcast_mls_commit`; kick/ban emit the SFrame epoch event, leave drops the group on failure).

Handler signatures use the `pub(crate)` type aliases from `types.rs` (`ServerStates`, `WsCmdTx`, `WsRoomPeers`, `GossipOverlays`, `EventTx`) — added both for readability and to keep the thin wrappers under Sonar's CPD 100-token window (see memory `sonar-cpd-dedup-technique`).

Server tombstone: `CrdtPayload::ServerDeleted` (Step 9D) marks `ServerState.deleted` + drains membership but keeps the shell/op_log; see `handle_delete_server`. Owner-authorship of a `ServerDeleted` op is validated at every ingest (the `allowed` matches + a pre-merge filter in both sync-response paths).

## Imports and Dependencies

- `crate::crdt::operations::{CrdtPayload, Permission, MemberRole, CrdtOp}`
- `crate::crdt::server_state::ServerState`
- `crate::crypto::{CryptoStore, MlsManager, OlmManager}`
- `crypto_handler::{peer_is_reachable, send_message_to_peer, send_mls_broadcast, persist_mls_state, send_encrypted_message}`
- `types::*` — NetworkEvent, NodeCommand, HavenMessage, MessageEnvelope, SyncMessageItem, SyncReactionItem, SyncFileMetaItem

## handle_create_server()

`sync_handler.rs:handle_create_server()` — Creates a new server. Called from `swarm.rs` when processing `NodeCommand::CreateServer`.

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `bundle_keypair`, `local_peer_str`, `local_device_id`, `name`

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
10. **Multi-device (Step 9D): announce the new server to our OWN online siblings** via `fan_to_own_siblings(... HavenMessage::SiblingServerAnnounce { server_id })`. The server room is brand-new and siblings aren't in it, so this is the only way they learn it exists. Each sibling runs a same-identity join fast-path (see `ServerJoinRequest` in `rust_swarm_dispatch`) → gets the snapshot + its own MLS leaf. No-op for a sole single-device install.

No broadcast to OTHER members needed — the server has only one identity (the creator) at creation. New members receive full state via SyncResponse when they join.

## handle_create_channel()

`sync_handler.rs:handle_create_channel()` — Creates a channel within an existing server.

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `bundle_keypair`, `local_peer_str`, `server_id`, `channel_id`, `name`, `category`, `channel_type`

Returns `bool` — `true` if the caller should skip to next iteration (permission denied or server not found).

Permission: `Permission::MANAGE_CHANNELS`

Channel ID: arrives WITH the command; the handler never mints one. `node::types::new_channel_id()` builds it (`"{server_id_first_8_chars}-{random_4_bytes_hex}"`, e.g. `"a1b2c3d4-deadbeef"`) and the FFI calls it so it can return the real id to Dart.

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

`sync_handler.rs:handle_delete_server()` — Deletes a server. Owner-only. **CRDT-op-only tombstone (Step 9D)** — deletion is a replicable `CrdtPayload::ServerDeleted`, NOT the old one-shot, so an OFFLINE member reconciles it on reconnect (the old one-shot was missed forever).

Parameters: `server_states`, `mls`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `sig_cmd_tx`, `bundle_keypair`, `local_peer_str`, `local_device_id`, `server_id`

Permission: `Permission::MANAGE_SERVER` (checked via `state.has_permission()`)

Flow:
1. Permission check — error message says "only the owner can delete the server"
2. Create + apply `CrdtPayload::ServerDeleted { deleted_at }` — sets `ServerState.deleted`, drains members/roles/channels, but KEEPS the shell + op_log
3. Persist: `save_state` + `insert_op` (mandatory — `op_log` is `#[serde(skip_serializing)]`, so without `insert_op` the owner stops serving the tombstone after restart)
4. Fan the op to remaining members (MLS-first `MessageEnvelope::CrdtOp`, plaintext `CrdtOpBroadcast` fallback) AND to our OWN siblings (`fan_to_own_siblings`)
5. Tear down our local MLS group, but **KEEP the CRDT tombstone shell + signaling registration** so we keep serving the tombstone to reconnecting peers (no `server_states.remove` / `delete_server`)
6. Emit `NetworkEvent::ServerDeleted { server_id }`

The bespoke one-shot `ServerDeleteBroadcast` / MLS `ServerDelete` SEND is removed; their receivers were converted to apply a tombstone (rollout safety for a pre-9D peer). Tombstoned servers are hidden from `get_joined_servers` (and harness `servers()`). **Owner-author of a `ServerDeleted` op is validated at EVERY ingest** (the `CrdtOpBroadcast`/`handle_envelope_crdt_op` `allowed` matches + a filter before `merge_ops` in BOTH `SyncResponse` and `handle_envelope_sync_resp`, checked against the receiver's own role map — never the relayer). Reconnect self-heal: a synced op that sets `is_deleted()` emits `ServerDeleted`; a plain kick (self no longer in members after merge) or ban emits `MemberLeft`.

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
7. Spawn a **4-second** `NodeCommand::RetryPendingJoin { server_id }` task, then the 15-second `NodeCommand::CheckPendingJoinTimeout { server_id }` task. Members serve a join through their elected coordinator (one responder instead of N), and that election reads each member's OWN presence view — so a coordinator whose socket just died is elected by everyone and answers for nobody. `handle_retry_pending_join()` re-asks every peer in the room; members recognise the repeat and all serve it, so the failure mode is the old fan-out rather than a 15s `ServerJoinFailed`. No-op once the join has completed.

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
   - `MessageEnvelope::MemberKick { sid }` via Olm (`send_encrypted_message()`), PLUS plaintext `HavenMessage::MemberKickBroadcast` as redundancy

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
- `LabelCreated { label_id, name, color, access }` — requires `MANAGE_ROLES`
- `LabelDeleted { label_id }` — requires `MANAGE_ROLES`
- `LabelUpdated { label_id, name, color, access: Option<bool> }` — requires `MANAGE_ROLES` (`access: None` preserves the stored flag)
- `LabelAssigned` / `LabelUnassigned { peer_id, label_id }` — self-toggle allowed ONLY for an existing COSMETIC label, otherwise `MANAGE_ROLES`

Self-toggle logic (issue #32 lockdown — access labels gate channels, so self-assign would be privilege escalation): the gate is `state.can_self_toggle_label(local_peer, peer_id, label_id)` — same-identity AND the label exists AND `!access` (unknown ids fail closed). `op_allowed` uses the SAME helper at ingest so the two gates cannot drift.

Emits: `NetworkEvent::ServerUpdated { server_id }`

Standard broadcast pattern.

## handle_set_channel_public()

`sync_handler.rs:handle_set_channel_public()` — Toggles whether a channel uses public (plaintext) or private (MLS-encrypted) message transport.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelPublicChanged { channel_id, is_public }`

Emits: `NetworkEvent::ServerUpdated { server_id }`

Standard broadcast pattern (MLS with plaintext fallback). When `is_public` is true, future messages in this channel are Ed25519-signed plaintext broadcasts instead of MLS-encrypted. Existing messages are not re-encrypted.

## handle_set_channel_visibility()

`sync_handler.rs:handle_set_channel_visibility()` — Sets channel visibility mode.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelVisibilityChanged { channel_id, visibility }` — `visibility` is a String ("everyone" | "moderator" | "admin").

Emits: `NetworkEvent::ServerUpdated { server_id }`

**Per-channel MLS subgroups (Option B, 2026-06-22):** channel visibility is now CRYPTOGRAPHICALLY enforced for restricted text channels. When a channel becomes restricted (`channel_uses_subgroup` true) the handler does NOT itself build the subgroup — it applies the CRDT op + emits ServerUpdated, and the swarm.rs `SetChannelVisibility` arm calls `crypto_handler::reconcile_subgroups_for_server(... Some(channel_id))` (coordinator-gated) to create + populate the subgroup (pulling qualifying members' KeyPackages). When a channel becomes `Everyone` again, this handler tears the subgroup down locally (`mls.remove_group(subgroup_id)`). The reconciler also runs on `handle_change_role` (role shifts who qualifies), on the label command arms (Assign/Unassign/Delete/Update — labels can gate channels, `only_channel = None`), on the grant/visibility-labels command arms (`Some(cid)`), on received CRDT ops in `handle_envelope_crdt_op` / `handle_incoming_request` (RoleChanged/ChannelVisibilityChanged/MemberRemoved/MemberBanned + the #32 set: ChannelVisibilityLabelsChanged/ChannelGrantSet/ChannelGrantRevoked/Label*), and on the 30s `grant_sweep_timer` when a grant expires. Kick/ban/leave drop the identity from all subgroups (`remove_identity_from_subgroups`). See `project_per_channel_mls_subgroups` + `project_channel_access_labels_grants` memories.

**Issue #32 pairing:** picking a plain tier while `visibility_labels` is non-empty makes this handler ALSO author a `ChannelVisibilityLabelsChanged{[]}` clearing op (the UI presents tier + labels as ONE selector).

## handle_set_channel_visibility_labels() / handle_set_channel_posting_labels()

Issue #32. Set (empty vec = clear) the label gate. When the gate turns ON, a plain `ChannelVisibilityChanged{"admin"}` (resp. `ChannelPostingChanged{"admin"}`) stamp is authored FIRST — pre-#32 clients drop the unknown labels op but honor the stamp, so the channel fails closed. Both ops come from one node's HLC in sequence, so replicas converge regardless of arrival order. Permission `MANAGE_CHANNELS`; visibility variant mirrors the subgroup teardown hook; posting never affects subgrouping (no reconcile).

## handle_grant_channel_access() / handle_revoke_channel_access()

Issue #32. `ChannelGrantSet { channel_id, peer_id, expires_at }` / `ChannelGrantRevoked`. Authoring-side friendly validation (channel exists, target is a member — stricter than ingest is the safe asymmetry). Permission `MANAGE_CHANNELS`; standard `author_broadcast_op` MlsFirst; the swarm arms reconcile the channel's subgroup afterwards.

## handle_set_channel_posting()

`sync_handler.rs:handle_set_channel_posting()` — Sets who can post in a channel.

Permission: `Permission::MANAGE_CHANNELS`

CrdtPayload: `ChannelPostingChanged { channel_id, posting }` — `posting` is a String ("everyone" | "moderator" | "admin").

Emits: `NetworkEvent::ServerUpdated { server_id }`

Posting is enforced send-side (`can_post_in_channel` at the send gates) — not at ingest, by design. Clears `posting_labels` (authors the empty-labels op) when a plain tier is picked while a label gate was set.

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

## handle_mute_member() / handle_unmute_member()

`sync_handler.rs:handle_mute_member()` — Server-wide mute (read-only member). Parameters: `server_id`, `peer_id` (normalized to MASTER via `resolver::resolve` before the op), `expires_at` (epoch ms; `u64::MAX` = permanent).

Permission: `state.can_mute(&local_peer, &target)` — same hierarchy as kick/ban (KICK_MEMBERS + actor outranks target). Unmute requires KICK_MEMBERS only.

CrdtPayload: `MemberMuted { peer_id, expires_at }` / `MemberUnmuted { peer_id }` — stored in `ServerState.muted_members: HashMap<String, AdminLwwReg<u64>>` (master-keyed). Expiry is LAZY: `is_muted(peer, now_ms)` compares against the wall clock — no timers anywhere. `MemberUnmuted` writes 0 then retain-prunes (mirrors the MemberUnbanned sweep).

Emits: `NetworkEvent::ServerUpdated`. Standard broadcast pattern (MLS + plaintext CrdtOpBroadcast).

Enforcement: send-side in `message_ops::handle_send_channel_message` + `file_handler::handle_send_file`; receive-side (LIVE path only, never sync backfill) in `message_ops::handle_envelope_channel_message` + both FileHeader ingest paths. See memory `project_moderation_trio`.

## handle_set_channel_slow_mode() / handle_set_channel_media_only()

`sync_handler.rs` — Both are one-call wrappers over `author_broadcast_op` (MANAGE_CHANNELS gate → op → persist → ServerUpdated → MLS-first broadcast); the old shared `handle_channel_moderation_change()` body was absorbed into the driver.

CrdtPayload: `ChannelSlowModeChanged { channel_id, seconds }` (u32, 0 = off) / `ChannelMediaOnlyChanged { channel_id, media_only }` — stored as `ChannelInfo.slow_mode` / `ChannelInfo.media_only`.

Slow mode: minimum seconds between messages per member; Moderator+ (and Owner) are EXEMPT (`ServerState::bypasses_slow_mode`). Send-side gate uses `MessageStore::latest_own_channel_ts` (is_mine=1); receive-side gate (live path only) uses `channel_sender_has_msg_in_range` on signed timestamps. Message edits are never gated.

Media-only: only image/GIF/video attachments allowed (`img || vthumb.is_some() || mime.starts_with("video/")`); captions ride the file message row; standalone text and other file types rejected at send + dropped at live ingest. The channel file-send path also runs `can_post_in_channel` here (gap closed 2026-07 — it historically skipped posting permission).

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
3. `build_channel_sync_batch(&store, sid, cid, since, &sender_ts)` — the SHARED responder helper (also used by `handle_envelope_channel_sync_req` and swarm.rs's plaintext `ChannelSyncRequest` arm): per-sender query when watermarks exist else legacy single-timestamp (limit 200), `channel_sync_items()` packs `SyncMessageItem`s with reactions (`load_reactions_for_sync`) + file metadata (`get_file_metadata_batch`, one `IN (...)` query) + link previews, stamps `total` + `has_more`, returns the ready `MessageEnvelope::ChannelSyncBatch` + item count. `channel_sync_items` is the channel twin of swarm's `build_dm_sync_items`; both return `SyncPage { items, truncated }` and **every responder must OR `truncated` into its `has_more`** (see `rust_types.md` § Sync Batches for the preview budget and the `MIN_ITEMS_BEFORE_TRUNCATION` floor that keeps pagination live).
4. Send via `send_encrypted_message()` (Olm)
5. If send fails again, emit `NetworkEvent::MessageSyncFailed { server_id, error: "Retry after re-key also failed" }`

## handle_envelope_crdt_op()

`sync_handler.rs:handle_envelope_crdt_op()` — Processes incoming CRDT ops received via MLS `MessageEnvelope::CrdtOp`.

This is the **receiver-side** permission validation for all CRDT operations. Every op received from another peer is checked here before being applied.

Parameters: `server_states`, `bundle_keypair`, `event_tx`, `sid`, `op_json`

Flow:
1. Deserialize `CrdtOp` from `op_json`
2. **`state.op_allowed(&op)`** — the ingest permission matrix now lives ONCE as a method on `ServerState` (`crdt/server_state.rs`), shared verbatim with the plaintext `CrdtOpBroadcast` ingest in swarm.rs so the two can never drift. Override-aware (`get_permissions`, honoring `RolePermissionsChanged`), validates `op.author` (the creator), never the transport sender.

| CrdtPayload variant | Permission required (in `op_allowed`) |
|---|---|
| `ChannelAdded`, `ChannelRemoved`, `ChannelRenamed`, `ChannelLayoutUpdated` | `MANAGE_CHANNELS` |
| `RoleChanged { peer_id, role }` | `state.can_change_role(&op.author, peer_id, role)` |
| `ServerRenamed`, `ServerSettingChanged` | Owner or Admin |
| `MemberRemoved { peer_id }` | Self-removal (`peer_id == op.author`, voluntary leave) always allowed; otherwise `KICK_MEMBERS` + must outrank target |
| `MemberAdded` | Must be a current member (`is_member`, resolver-aware) |
| `NicknameChanged` / `TwitchUsernameChanged` / `StoragePledgeChanged { peer_id }` | Self or Owner/Admin |
| `MessagePinned`, `MessageUnpinned` | `MANAGE_CHANNELS` |
| `RolePermissionsChanged { role }` | `MANAGE_ROLES` + must outrank target role |
| `MemberBanned` / `MemberMuted { peer_id }` | `KICK_MEMBERS` + must outrank target |
| `MemberUnbanned` / `MemberUnmuted` | `KICK_MEMBERS` |
| `ChannelVisibilityChanged`, `ChannelPostingChanged`, `ChannelPublicChanged`, `ChannelSlowModeChanged`, `ChannelMediaOnlyChanged` | `MANAGE_CHANNELS` |
| `LabelCreated`, `LabelDeleted`, `LabelUpdated` | `MANAGE_ROLES` |
| `LabelAssigned { peer_id }`, `LabelUnassigned { peer_id }` | Self or `MANAGE_ROLES` |
| `EmojiAdded` (+ name/hash validation) / `EmojiRemoved` | `MANAGE_EMOTES` |
| `ServerDeleted` | Owner only (tombstone) |
| `ServerCreated` | Always allowed |

3. If not allowed: log `[HOLLOW-SECURITY] REJECTED MLS CrdtOp from {author}` and return
4. Apply op: `state.apply_op(&op)`; check if actually new (op_log length before/after)
5. If new: persist state + op via CrdtStore, then `emit_crdt_apply_event()` emits the NetworkEvent per payload type (extracted helper; the plaintext twin in swarm.rs keeps its own richer match — self-eviction teardown, MLS teardown on delete):

**CRITICAL**: Specific payload variants are explicitly listed to emit `NetworkEvent::ServerUpdated` (not the `_ =>` wildcard which emits `SyncCompleted`). The `ServerUpdated` Dart handler invalidates `myPermissionsProvider`, `myRoleProvider`, and `serverMembersProvider`. New CrdtPayload variants that affect permissions/channels/labels MUST be added to the explicit match arms, not left to fall into `_ =>`.

Event mapping:
- `ChannelAdded` -> `NetworkEvent::ChannelAdded`
- `ChannelRemoved` -> `NetworkEvent::ChannelRemoved`
- `MemberAdded` -> `NetworkEvent::MemberJoined`
- `MemberRemoved` -> `NetworkEvent::MemberLeft`
- `RoleChanged` -> `NetworkEvent::RoleChanged`
- `ServerSettingChanged`, `ServerRenamed`, `RolePermissionsChanged`, `MemberBanned`, `MemberUnbanned`, `ChannelVisibilityChanged`, `ChannelPostingChanged`, `ChannelPublicChanged`, all Label variants -> `NetworkEvent::ServerUpdated`
- Everything else (`_ =>`) -> `NetworkEvent::SyncCompleted { ops_applied: 1 }`

## handle_envelope_server_delete()

`sync_handler.rs:handle_envelope_server_delete()` — **Legacy** receiver for `MessageEnvelope::ServerDelete` via MLS (a pre-9D peer may still send it; new senders route deletion through the `ServerDeleted` CRDT op). Converted to a TOMBSTONE (Step 9D), not a hard-delete.

Permission: Sender must be Owner. Checked via `state.get_role(sender_peer_id) == MemberRole::Owner`.

If sender is not owner: logs `[HOLLOW-SECURITY] REJECTED MLS ServerDelete` and returns.

Flow on valid owner deletion (if not already deleted):
1. Synthesize + apply a local `CrdtPayload::ServerDeleted { deleted_at }` op (sets `deleted`, drains members, keeps shell)
2. Persist: `insert_op` + `save_state` (keep the shell to relay the tombstone onward)
3. Remove our local MLS group + persist
4. Emit `NetworkEvent::ServerDeleted`

The plaintext `HavenMessage::ServerDeleteBroadcast` receiver (in `swarm.rs`) does the same tombstone conversion.

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
4. Send via Olm (`send_encrypted_message`) + `SendDirect` to the requesting peer

## handle_envelope_sync_resp()

`sync_handler.rs:handle_envelope_sync_resp()` — Processes incoming `MessageEnvelope::SyncResp` via MLS. Applies received CRDT ops.

Flow:
1. Deserialize `Vec<CrdtOp>` from `ops_json`
2. **Persist every incoming op with matching `server_id` via `crdt_store.insert_op()`** (INSERT OR IGNORE, idempotent). CRITICAL: `op_log` is `#[serde(skip_serializing)]` — the state JSON alone loses history on restart; without per-op persistence a member serves near-empty op logs to future joiners. ALL THREE sync-merge sites do this (this MLS path, plus the plaintext `SyncResponse` and Olm `SyncResp` handlers in swarm.rs).
3. Merge via `crate::crdt::sync::merge_ops(state, &incoming_ops)` — takes a slice; SKIPS ops that fail `apply_op` (one foreign op must not abort the merge); returns count of newly applied ops
4. If any applied: persist state to SQLCipher
5. Emit `NetworkEvent::SyncCompleted { server_id, ops_applied }`

## handle_envelope_channel_sync_req()

`sync_handler.rs:handle_envelope_channel_sync_req()` — Processes incoming `MessageEnvelope::ChannelSyncReq` via MLS. Responds with channel messages.

Parameters: `sid`, `cid`, `since_timestamp`, `sender_timestamps: HashMap<String, i64>`

Flow:
1. Guard: server must exist in `server_states`
2. `build_channel_sync_batch()` (shared responder helper — see `flush_pending_sync_requests`)
3. Skip if the batch is empty; else send via `send_encrypted_message` to the requesting peer

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

The entire batch is wrapped in a SQLite transaction (`begin_transaction()`/`commit_transaction()`) for 10-50x faster ingest vs individual autocommits. Signature verification (`verify_sync_item_sig`, skips edited items) uses `verify_message_signature_cached()` with a `HashMap<String, Vec<u8>>` pk cache to avoid redundant PeerId derivation across messages from the same sender.

The per-item work is split into helpers: `upsert_synced_channel_message()` (insert / edit / `repair_wedged_sender`) and `apply_sync_item_extras()` (hidden flag, file metadata, reactions). Both are deliberately **synchronous and RETURN the `NetworkEvent`s to emit** — an async helper taking `&MessageStore` would hold the reference across an await and un-Send the event-loop future (rusqlite `Connection` is `!Sync`; see memory `rusqlite Connection is !Sync`).

Flow per message in batch:
1. Insert via `store.insert_channel_message()` — returns 1 if new (deduplication by message_id). `is_mine = resolver::same_identity(&msg.s, local_peer)` (multi-device: any of our own devices is ours).
1b. **Multi-device self-heal (existing row).** If the message already exists, is not an edit, and carries a signature: when that signature VERIFIES (`check_backfill_signature` over the canonical v2 `hollow-msg2:ch:{sid}:{cid}:{s}:{ts}:...` payload — it binds the PeerId to the pubkey, so the synced copy is provably from `msg.s`; since 0.8.5 only a `Valid` verdict reaches this point at all) AND the locally stored sender (`store.get_channel_message_sender(mid)`) differs from `msg.s`, repair the row via `store.repair_channel_message_sender(mid, &msg.s, is_mine, sig, pk)`. This converges a row that was stored under a sender DEVICE id before the device→master resolve fix (the "12D3KooW… + unverified signature" bubble): `insert_channel_message` is `INSERT OR IGNORE` and the `already_exists` skip means the correct copy could never overwrite the corrupt one, so this UPDATE is the only path. No event is emitted (the corrected sender renders on the next `loadHistory`; faking a `ChannelMessageEdited` would wrongly mark it edited and not move the in-memory senderId). Safe — repair only ever replaces an attribution with a cryptographically verified one. The plaintext `ChannelSyncBatch` handler in `swarm.rs` does the same, reusing its existing `verify_message_signature_cached` result.
2. If `hidden_at` is set: apply via `message_ops::apply_verified_channel_deletion()` — REJECT-ABSENT (0.8.4): honored only when the item's `hidden_sig`/`hidden_pk` verify as the row author's `"ch-delete"` proof; a verified apply goes through `store.set_channel_message_hidden_verified()` (also stores the proof for onward serving)
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
| `ServerUpdated` | `handle_rename_server`, `handle_update_server_setting`, `handle_unban_member`, `handle_label_op`, `handle_set_channel_visibility`, `handle_set_channel_posting`, `handle_set_channel_public`, `handle_change_role_permissions`, `handle_set_storage_pledge`, `handle_update_channel_layout`, `handle_envelope_crdt_op` (for settings/rename/permissions/ban/label/public variants) |
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

Both routes live in two shared helpers — never hand-roll a broadcast:

**`broadcast_op_mls_first()`** (default, `OpBroadcast::MlsFirst`): MLS `MessageEnvelope::CrdtOp` via `send_mls_broadcast()` when the group exists, then ALWAYS ALSO the plaintext `HavenMessage::CrdtOpBroadcast` twin via `broadcast_crdt_op_to_members()`. The plaintext copy is unconditional — NOT an on-error fallback — because a receiver at a skewed MLS epoch silently drops the ciphertext with no recovery (common after mobile micro-disconnects); it's idempotent (op_log dedups, receivers re-validate via `op_allowed`). `broadcast_crdt_op_to_members` prefers the gossip mesh (`flood_crdt_op`) and falls back to the per-identity relay fan-out.

**`broadcast_op_plaintext_with_fan()`** (`OpBroadcast::PlaintextWithFan`): plaintext member broadcast + `fan_to_own_siblings` for ops with no MLS path — `handle_change_role`, nickname, twitch, layout, pin/unpin, storage pledge.

`handle_create_server()` — no broadcast (single member at creation; siblings get `SiblingServerAnnounce`).
