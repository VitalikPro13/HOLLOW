# Authorisation matrix evidence: SERVER STATE (CRDT)

Phase B enumeration. Read-only. Every line number below is from a snapshot of
the working tree taken 2026-09-26 19:44 CEDT (copies in
`scratchpad/crdt_snap/`). The tree is DIRTY and another session was editing
it during this pass: `node/swarm.rs` is HEAD+1 for lines 569..6679 and HEAD+9
after ~6717; `node/types.rs` is HEAD+9 after ~1400; `node/crypto_handler.rs`,
`node/message_ops.rs`, `node/test_harness.rs` also differ from HEAD. The
`crdt/*`, `node/sync_handler.rs`, `storage/messages.rs`, `vault/adaptive.rs`,
`node/twitch.rs` files are unchanged vs HEAD. If a line has drifted, search
for the verbatim quote.

Paths are relative to `rust/hollow_core/src/`.

---------------------------------------------------------------------------

## 0. The shared gate and helpers every ingest site relies on

### 0.1 `ServerState::admit_remote_op` (crdt/server_state.rs:522-534)

Order of checks, all on `op` alone (never on the transport sender):

1. crdt/server_state.rs:523 `if op.server_id != self.server_id {` -> `Err(OpReject::WrongServer)` (524)
2. crdt/server_state.rs:526 `op.verify_author()?;` (signer key must derive `op.author`, see 0.2)
3. crdt/server_state.rs:527 `if op.hlc.physical_ms > super::hlc::wall_clock_ms() + super::hlc::MAX_DRIFT_MS {` -> `FutureHlc`; `MAX_DRIFT_MS` = crdt/hlc.rs:18 `pub(crate) const MAX_DRIFT_MS: u64 = 5 * 60 * 1000; // 5 minutes`
4. crdt/server_state.rs:530 `if !self.op_allowed(op) {` -> `NotAllowed`

Not checked here: `op.hlc.actor == op.author` (NONE FOUND anywhere in
admit/op_allowed/apply), `op.hlc.counter` bound, any lower bound / age on
`physical_ms` (an arbitrarily OLD op passes), membership of `op.author`
(except MemberAdded, see B), whether the op was already seen beyond the
in-RAM dedup set (0.5).

### 0.2 `CrdtOp::verify_author` and the signed payload (crdt/operations.rs)

- Signed payload, crdt/operations.rs:80: `"hollow-crdt1:{}:{}:{}:{}:{}:{}",` over
  `self.server_id, self.hlc.physical_ms, self.hlc.counter, self.hlc.actor, self.author, payload_json` (81-86),
  `payload_json = serde_json::to_string(&self.payload).unwrap_or_default()` (78).
- crdt/operations.rs:103 `let auth = self.auth.as_ref().ok_or(OpReject::MissingSignature)?;` (absent `auth` = REJECT; field is `#[serde(default, skip_serializing_if = "Option::is_none")]` at 66-67 purely for parse tolerance).
- crdt/operations.rs:106-110 `let derived = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes)` ... `if derived != self.author { return Err(OpReject::AuthorMismatch); }`
- crdt/operations.rs:112-118 `NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, self.signing_payload().as_bytes())` -> `Ok(true) => Ok(())`, anything else `BadSignature`.
- Who can sign: ANY Ed25519 key whose derived peer_id equals `op.author`. Honest
  authoring uses the MASTER key (crdt/server_state.rs:486-505 `create_op`,
  503 `op.sign(&signer.keypair, &signer.pk_b64);`, installed by
  node/swarm.rs `install_op_signer` from `bundle_keypair`), but ingest does NOT
  require the author to be a master: a DEVICE key signing `author = <device id>`
  verifies (derived == author) and is then given its master's authority by
  `get_role` (0.4). See SUSPICION CRDT-S10.

### 0.3 HLC bound and witness (crdt/hlc.rs)

- Ordering crdt/hlc.rs:31-36 `physical_ms` then `counter` then `actor` (actor is a free string chosen by the author, only covered by the signature).
- `witness` crdt/hlc.rs:103 `if other.physical_ms > wall + MAX_DRIFT_MS {` -> refuses to advance our clock (log only).
- crdt/hlc.rs:114 `self.latest.counter = self.latest.counter.max(other.counter) + 1;` and 121 `self.latest.counter = other.counter + 1;` : unchecked `u32` add on a remote-controlled value (see CRDT-S16).
- Called from apply_op crdt/server_state.rs:609-611 `if let Some(hlc) = &mut self.hlc { hlc.witness(&op.hlc); }` i.e. AFTER admission.

### 0.4 Role / permission helpers used by `op_allowed`

- `op_allowed` prologue crdt/server_state.rs:1308 `let sender_role = self.get_role(&op.author);` and 1309 `let sender_perms = self.get_permissions(&op.author);`
- `get_role` crdt/server_state.rs:1091 `let key = super::resolve_identity(peer_id);` ... 1095 `.unwrap_or(MemberRole::Member)` : an UNKNOWN id (stranger, kicked or banned ex-member whose role entry was removed) is treated as `Member`.
- `resolve_identity` crdt/mod.rs:22-27, installed at node/swarm.rs:807 `crate::crdt::set_identity_resolver(super::resolver::resolve);` -> node/resolver.rs:34-38 process-global map, unknown -> itself. So CRDT authority of a device-id author = authority of whatever master the LOCAL resolver maps it to. Every resolver write is therefore a CRDT-authority write (writers: node/crypto_handler.rs:1445 `super::resolver::update(sender_peer_id, &list.master_peer_id);`, 1472/1526/1659 `update_many`, `seed_self` at 1029/1074/1098/1166/1300/1305/1320/1682, node/swarm.rs:199, 781 `warm_from_links`, api/network.rs:1751/2587/2771/2775; removals `forget` at crypto_handler.rs:1094/1163/1524/1657/3658). Not audited here (identity area).
- `get_permissions` crdt/server_state.rs:1205-1206 `if role == MemberRole::Owner { return Permission::ALL; }`, 1208-1209 `if let Some(reg) = self.role_permissions.get(role.as_str()) { return *reg.read(); }`, 1211 `role.default_permissions()`. Consequence: `role_permissions["member"]` applies to every stranger key too.
- `has_permission` 1226-1228 `self.get_permissions(peer_id) & permission != 0`.
- `author_priority` 1193-1199 (unknown -> 0); only used to stamp the inert `priority` field of LWW registers (crdt/admin_lww.rs:16-17 "inert metadata").
- `can_change_role` 1232-1254:
  - 1234-1236 `if actor_role == MemberRole::Owner { return true; }` (Owner: any target, any role, including Owner and including itself)
  - 1237 `if !self.has_permission(actor, Permission::MANAGE_ROLES) { return false; }`
  - 1242 `if !actor_role.outranks(&target_role) {` (target_role = `get_role(target)`, unknown -> Member)
  - 1246 `if !actor_role.outranks(new_role) {`
  - 1250 `if *new_role == MemberRole::Owner {` -> false (only reached for non-Owner actors)
- `can_kick` 1257-1267 (Owner true; else KICK_MEMBERS and outranks target). NOTE `op_allowed` does NOT call `can_kick`; it re-implements it without the Owner shortcut (see MemberRemoved/Banned/Muted).
- `can_self_toggle_label` 1555-1558 `super::resolve_identity(actor) == super::resolve_identity(target_peer) && self.labels.get(label_id).is_some_and(|l| !l.access)`.
- `current_owner` 510-515 `self.roles.iter().find(|(_, reg)| *reg.read() == MemberRole::Owner)` : HashMap iteration order, so with two Owners the answer is arbitrary per replica.
- `is_member` 1289-1292 (resolver-collapsed `members.contains_key`).

### 0.5 Freshness / dedup machinery shared by every ingest site

- Dedup key crdt/server_state.rs:603-606 `let dedup_key = (op.author.clone(), op.hlc.clone()); if self.op_log_dedup.contains(&dedup_key) { return Ok(()); }` : in-RAM `#[serde(skip)]` set (256).
- Compaction crdt/server_state.rs:1059 `const MAX_OP_LOG: usize = 1000;`, 1062 `self.op_log.drain(..drain_count);`, 1064-1066 dedup cleared and rebuilt from the RETAINED ops only. So an op older than the newest 1000 is no longer recognised as a duplicate.
- Restart: node/swarm.rs:844-851 state JSON is loaded and `state.restore_op_log(ops)` (851) with ops from storage/messages.rs:2003-2011 `... ORDER BY hlc_ms DESC, hlc_counter DESC, author DESC LIMIT 1000` : again only the newest 1000.
- DB `crdt_ops` UNIQUE key storage/messages.rs:607 `UNIQUE(server_id, hlc_ms, hlc_counter, author)` + 1931 `INSERT OR IGNORE`; pruned every 30 min node/swarm.rs:5374 `crdt_store.prune_ops(1000);`.
- There are NO tombstones for set-style removals (MemberRemoved drops the role register, 742; LabelUnassigned retains-out, 996; ChannelRemoved, 709; EmojiRemoved, 1022...). Many payloads are applied by ARRIVAL, not by HLC (listed per variant in B). => CRDT-S5.

### 0.6 Transport facts used below

- Plaintext `HavenMessage` from the relay: node/swarm.rs:4561 `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } =>`, 4571 `serde_json::from_str::<HavenMessage>(&text)`, then 4888 `handle_incoming_request(` with `peer_str = from` (relay-stamped). No per-variant "must have arrived encrypted" gate in `handle_incoming_request` prologue (node/swarm.rs:6437-6506 goes straight to `match request {`). Under P-01 the relay can inject ANY HavenMessage below with ANY `from`.
- Outbound CRDT ops are sent in plaintext too: node/sync_handler.rs:87-91 `HavenMessage::CrdtOpBroadcast {...}` -> `broadcast_raw_to_members` (SendDirect), and node/swarm.rs:6192-6203 re-flood. So the relay holds a corpus of every signed op it relayed.
- WebRTC mesh: node/swarm.rs:2910 `NodeCommand::WebRtcGossipOpReceived { sender_peer_id, payload } =>` -> 2915 `accept_gossip_op` (node/gossip_relay.rs:108-122, dedup by `broadcast_id` only) -> 2967 `HavenMessage::CrdtOpBroadcast { server_id, op_json },` into `handle_incoming_request` (same arm as A-01).
- Push background node (`node/fetch.rs`): grep for `CrdtOp|SyncResponse|ServerStateSnapshot|server_state|crdt` in node/fetch.rs: NOT FOUND. No CRDT ingest there.
- Relay topic 0x07: CRDT ops ride a topic ring ONLY inside `ServerJoinResolved` on `~join` (node/sync_handler.rs:1204-1217 `SendToRoomTopic { ... topic: super::types::JOIN_TOPIC ...}` carrying `op_json`). Ordinary op broadcasts are SendDirect (sync_handler.rs:43-63, 87-91). See A-07.

---------------------------------------------------------------------------

## A. Ingest sites

### A-01 HavenMessage::CrdtOpBroadcast (apply one remotely authored op)

- Dispatch sites:
  - plaintext HavenMessage arm node/swarm.rs:9877 `HavenMessage::CrdtOpBroadcast { server_id, op_json } =>` -> 9879 `apply_remote_crdt_op(`
  - WebRTC data channel gossip node/swarm.rs:2910-2967 (same arm, see 0.6)
  - relay topic 0x07 `~join` ring: via ServerJoinResolved node/swarm.rs:10419 `apply_remote_crdt_op(` (A-07)
  - gossip re-flood of accepted ops: node/swarm.rs:6189 `if super::gossip_relay::flood_crdt_op(` / 6201 `send_raw_to_peer(ws_cmd_tx, ws_room_peers, &dev, crdt_data.clone());`
- Handler: `apply_remote_crdt_op` node/swarm.rs:6120.
- Target object: `server_id` (envelope) + everything the payload names (B).
- State changes, in order:
  1. node/swarm.rs:6175 `let _ = state.apply_op(&op);` (all B side effects)
  2. node/swarm.rs:6180 `let _ = store.save_server_state(&server_id, &json);` and 6181 `let _ = store.insert_crdt_op(&op);` (only if `state.op_log.len() > was_len`, 6177; note `MessageStore::open` on the event loop at 6179)
  3. re-flood to mesh or to every member device 6189-6203
  4. events: ChannelAdded/Removed/Renamed, MemberJoined, MemberLeft or ServerDeleted (6238-6258), ServerDeleted + MLS `mls_mgr.remove_group(&server_id)` for `ServerDeleted` (6260-6270), RoleChanged, PublicChannelConfigChanged + `WsCommand::SendToRoom` to the server room (6320-6351)
  5. self-eviction durable teardown node/swarm.rs:6245-6247 `let self_evicted = super::resolver::same_identity(peer_id, &local_peer_str) && !pending_server_joins.contains_key(&server_id) && !state.is_member(&local_peer_str);` -> 6364-6388: `server_states.remove(&server_id);` (6369), `store.delete_server_state(&server_id)` (6371, deletes state AND all crdt_ops rows, storage/messages.rs:1915-1922), MLS group + subgroups removed, `WsCommand::LeaveRoom` (6385)
  6. subgroup reconcile + `auto_leave_invisible_voice_channels` (6393-6431) for Role/Visibility/Member/Label/Grant ops.
- Checks before the first state change, in order:
  1. node/swarm.rs:6145 `if !server_states.contains_key(&server_id) {` (we hold the server)
  2. node/swarm.rs:6150 strict parse `serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json)`
  3. node/swarm.rs:6154 `if op.author != peer_str {` : LOG ONLY ("don't reject")
  4. node/swarm.rs:6163 `if let Err(reason) = state.admit_remote_op(&op) {` -> return. Principal: `op.author` + signer key (0.1). The transport sender (`peer_str`, relay-stamped) is NOT a principal here.
- Who can sign: any key deriving `op.author` (0.2).
- Binding: per payload, `op_allowed` arm (B). Transport sender binding: NONE (by design).
- Transport parity: see A-02/A-03 differences. This is the richest path (events, teardown, reconcile).
- Freshness / replay: only the RAM dedup window (0.5). A relayed/re-injected copy of any op older than the newest 1000 is re-applied if `op_allowed` still passes for its author TODAY. Survives restart: no (restart reloads newest 1000).
- Absent fields: `auth` absent -> MissingSignature reject (operations.rs:103). Unknown payload variant -> strict parse at 6150 fails -> silently dropped (no tolerance on this path, unlike sync).
- Blast radius: propagates (each receiver re-floods once, 6177-6203); self-eviction teardown is irreversible locally.
- Tests (rejection): node/test_harness.rs:22044 `crdt_forged_author_op_is_rejected_on_every_ingest_path` (plaintext broadcast + SyncResponse batch, forged author / unsigned / second ServerCreated vs an ESTABLISHED member), 22162 `crdt_future_hlc_op_is_rejected_and_owner_can_still_rename`, 22246 `crdt_signed_op_relayed_by_another_member_is_accepted` (positive), 12733 `banner_write_rejected_without_manage_server`, 7592 `access_label_self_assign_locked`. Unit: crdt/server_state.rs:1705 `op_allowed_ingest_matrix`, 3327/3346/3366/3384 `admit_remote_rejects_*`, 3423 `server_created_on_owned_server_is_rejected`, 3251 `op_for_wrong_server_rejected`. No test of replay after compaction (crdt/server_state.rs:3187 `op_log_dedup_survives_compaction` only re-applies an op created AFTER compaction).
- SUSPICION: CRDT-S5, CRDT-S6, CRDT-S7, CRDT-S10 (all apply here).

### A-02 MessageEnvelope::CrdtOp over Olm (fallback)

- Dispatch: node/swarm.rs:9076 `Ok(MessageEnvelope::CrdtOp { sid, op_json, .. }) => {` inside the Olm-decrypted envelope match of `HavenMessage::Encrypted`.
- Handler: inline.
- Target: `sid` (envelope) + payload.
- State changes, in order: node/swarm.rs:9087 `} else if let Ok(()) = state.apply_op(&op) {`, 9088 `state.op_log.push(op.clone());`, 9091-9092 `store.save_server_state(&sid, &json)` / `store.insert_crdt_op(&op)`, 9095 `NetworkEvent::SyncCompleted`.
- Checks before first state change: 9077 strict parse; 9078 `if let Some(state) = server_states.get_mut(&sid)`; 9082 `if let Err(reason) = state.admit_remote_op(&op) {` (principal op.author). The Olm-authenticated sender device (`peer_str`) is not consulted.
- Who can sign / Binding: as A-01.
- Transport parity vs A-01 (differences):
  - 9088 pushes the op AGAIN after `apply_op` already inserted it (crdt/server_state.rs:1055 `self.op_log.insert(insert_pos, op.clone());`), and pushes even when `apply_op` returned `Ok(())` early on a duplicate (crdt/server_state.rs:604-605). -> CRDT-S14.
  - persists and emits `SyncCompleted` unconditionally (no `was_len` newness gate).
  - NO per-payload events, NO self-eviction teardown, NO MLS group removal on `ServerDeleted`, NO subgroup reconcile / voice auto-leave, NO re-flood.
- Freshness: as A-01 (dedup window), but duplicates still grow op_log (S14).
- Tests: none found for the Olm CrdtOp path (grep of test_harness for `MessageEnvelope::CrdtOp` via Olm: NOT FOUND).
- SUSPICION: CRDT-S14 (CONFIRMED-BY-READING).

### A-03 MessageEnvelope::CrdtOp over MLS

- Dispatch: node/swarm.rs:11067 `MessageEnvelope::CrdtOp { sid, op_json } => {` inside `HavenMessage::MlsChannelMessage` after node/swarm.rs:10964 `match mls_mgr.decrypt_fresh(&group_key, &ciphertext) {`; envelope `sid` is independent of `group_key` (the MLS group the frame was decrypted in).
- Handler: node/sync_handler.rs:2957 `handle_envelope_crdt_op`.
- State changes: sync_handler.rs:2980 `let _ = state.apply_op(&op);`, 2982 `crdt_store.insert_op(op.clone());`, 2983 `crdt_store.save_state_snapshot(sid.clone(), state);`, 2984 `emit_crdt_apply_event` (events only; for `ServerDeleted` 3021-3027 comment "MLS group teardown is the plaintext path's job" -> no MLS removal). Then back in swarm.rs: self-eviction teardown 11114-11144 (guarded `!s.is_deleted()`), subgroup reconcile 11146-11160.
- Checks: sync_handler.rs:2966 state exists; 2967 strict parse; 2971 `if let Err(reason) = state.admit_remote_op(&op) {`. Principal op.author. MLS leaf credential (`sender_peer_id`) not consulted.
- Transport parity vs A-01: no re-flood; `ServerDeleted` does not remove the MLS group; `MemberBanned` of self emits nothing special (both paths: A-01 6272-6283 only emits MemberLeft; neither tears down on a live ban).
- Freshness: as A-01.
- Tests: none found specific to the MLS CrdtOp arm rejecting.

### A-04 SyncRequest / SyncReq (serving the op log)

- Dispatch sites:
  - plaintext node/swarm.rs:9457 `HavenMessage::SyncRequest { server_id, state_vector_json, mls_epoch } =>`
  - Olm node/swarm.rs:9103 `Ok(MessageEnvelope::SyncReq { sid, state_vector_json, .. }) => {`
  - MLS node/swarm.rs:11215 -> node/sync_handler.rs:3183 `handle_envelope_sync_req`
- Target: `server_id` and the requester's state vector.
- State changes: none locally (serving); sends: plaintext 9467-9473 `send_message_to_peer(... HavenMessage::SyncResponse {...})`, Olm path ALSO answers in plaintext 9110 `send_message_to_peer(` (comment 9109 "Respond via plaintext"), MLS path answers Olm-encrypted sync_handler.rs:3208 `send_encrypted_message(`. `send_message_to_peer` = plaintext SendDirect node/crypto_handler.rs:2820-2832.
- Checks before serving: plaintext 9461 `if let Some(state) = server_states.get(&server_id) {` only; Olm 9104 `if let Some(state) = server_states.get(&sid)` only; MLS sync_handler.rs:3198 same. Membership of the requester: NONE FOUND on all three. Channel visibility of the ops served (restricted channel names, grants, labels): NONE FOUND (contrast `ChannelSyncRequest` 10534-10549 which calls `channel_readable_by`).
- Who can sign: unsigned (authority = transport sender, and the sender is not checked).
- Binding: NONE FOUND.
- Freshness: n/a (read). Epoch hint side path 9485-9493 -> `handle_epoch_hint` (MLS area).
- Blast radius: confidentiality of the whole server op log (members, roles, nicknames, all channel names incl. restricted ones, labels, grants, mutes/bans, settings incl. Twitch gate config and `server_avatar`), to any room peer and, because the reply is plaintext, to the relay on every honest sync.
- Tests: none found.
- SUSPICION: CRDT-S15.

### A-05 SyncResponse / SyncResp and `merge_ops`

- Dispatch sites:
  - plaintext node/swarm.rs:9540 `HavenMessage::SyncResponse { server_id, ops_json } =>` (also the join path: the admitter sends it at 10320-10330)
  - Olm node/swarm.rs:9121 `Ok(MessageEnvelope::SyncResp { sid, ops_json, .. }) => {`
  - MLS node/swarm.rs:11224 -> node/sync_handler.rs:3219 `handle_envelope_sync_resp`
- Handler core: crdt/sync.rs:82 `merge_ops_with`: 89 `if let Err(reason) = state.admit_remote_op(op) {` -> skip; 99 `on_admitted(op);` (persist hook, BEFORE apply); 101 `if state.apply_op(op).is_err() {`. Ops are processed in the ORDER THE SENDER CHOSE (88 `for op in incoming_ops {`), each admitted against the state as mutated by the previous ops of the same batch.
- Target: server + each op's payload.
- State changes (plaintext arm), in order:
  1. node/swarm.rs:9557-9573 when the server is unknown but a join is pending: a SKELETON state is created: 9562 `let mut s = ServerState::new(server_id.clone(), "".into(), peer_str.to_string());`, 9563 `s.members.remove(peer_str);`, 9564 `s.roles.remove(peer_str);` => ownerless (`current_owner()` = None).
  2. per admitted op: 9593 `let _ = store.insert_crdt_op(op);` then apply.
  3. 9612 `state.canonicalize_members(|id| super::resolver::resolve(id));` (LWW fold of device-keyed registers into master registers, crdt/server_state.rs:397-419, 437-446)
  4. 9616 `store.save_server_state`
  5. join completion 9620 `if let Some(completed) = pending_server_joins.remove(&server_id) {` -> JoinRoom, ServerJoined event, auto pledge op authored (9689 `let min_pledge_bytes = state.min_pledge_mb() * 1024 * 1024;`), KeyRequests, KeyPackage mint/send.
  6. offline reconciliation 9818-9864: `deleted_now` -> MLS group removed; `banned_now || (kicked_now && !pending)` (9835) -> `server_states.remove` (9842), `store.delete_server_state` (9844), MLS groups removed, LeaveRoom. Note 9822 `let pending = pending_server_joins.contains_key(&server_id);` is evaluated AFTER 9620 removed the entry, so it is false on the completing join.
- Checks before the first state change: plaintext 9546-9551 `if !is_known && !is_pending_join { ... return; }`; 9555 tolerant parse (`parse_ops_tolerant`, crdt/operations.rs:350-358); then per op `admit_remote_op`. Sender (`peer_str`) is not a principal and is not checked (neither membership nor "is this the peer we asked"). Olm arm 9122 requires a KNOWN server (no skeleton, no join completion). MLS arm sync_handler.rs:3227 requires a known server.
- Who can sign: each op individually (0.2). The batch itself: unsigned (authority = none; any sender).
- Binding: op-level only. Join completion is bound to NOTHING about the responder: any SyncResponse with >=1 parseable op completes the pending join even when 0 ops were admitted (9606 `Ok(report) if report.applied > 0 || pending_server_joins.contains_key(&server_id) =>`).
- Transport parity: plaintext arm alone builds the skeleton, completes joins, canonicalizes, and tears down on offline kick/ban; Olm arm (9121-9155) and MLS arm (sync_handler.rs:3219-3262) only merge + persist + event (MLS arm emits ServerDeleted if `is_deleted`, 3252-3255; Olm arm does not).
- Freshness: op-level dedup window only (0.5). The sender picks which genuine ops to include and in what ORDER, so it can (a) replay ops outside the victim's window, (b) withhold (e.g. a demotion, a ban), (c) order a since-revoked author's op before the op that revoked it for a replica that lacks the revocation (pending joiner).
- Absent fields: unsigned ops -> rejected individually; unknown variants skipped by the tolerant parse.
- Blast radius: joiner's whole view of the server (persisted); for known servers, replay of set-style ops (CRDT-S5).
- Tests: node/test_harness.rs:22044 (forged ops inside a SyncResponse to an established member, rejected); crdt/sync.rs:304 `merge_ops_rejects_a_forged_op_in_the_batch`. NOT covered: skeleton + hostile ServerCreated (the unit test crdt/server_state.rs:1859-1866 asserts the OPPOSITE: `"an ownerless state must accept a founding op from the peer it names"`), batch reordering, replay after compaction.
- SUSPICION: CRDT-S2 (skeleton takeover), CRDT-S5 (replay), CRDT-S1 (combined with the snapshot).

### A-06 HavenMessage::ServerStateSnapshot (whole-state adoption during a join)

- Dispatch: plaintext only, node/swarm.rs:9495 `HavenMessage::ServerStateSnapshot { server_id, state_json } =>`. Honest sender: the admitting member, node/swarm.rs:10309-10316 `send_message_to_peer_in_room(... HavenMessage::ServerStateSnapshot { server_id, state_json })` (plaintext, relay-visible, relay-buffered for parked joins).
- Handler: inline.
- Target: the entire `ServerState` for `server_id`.
- State changes, in order: 9509 `snap.set_hlc(Hlc::new(local_peer_str.to_string()));`, 9510 `install_op_signer(&mut snap, bundle_keypair);`, 9515 `let clamped = snap.clamp_future_hlcs(crate::crdt::hlc::wall_clock_ms());`, 9521 `snap.canonicalize_members(|id| super::resolver::resolve(id));`, 9529 `let _ = store.save_server_state(&server_id, &json);`, 9532 `server_states.insert(server_id, snap);` (REPLACES any existing state for that id).
- Checks before the first state change, in order:
  1. 9499 `if !pending_server_joins.contains_key(&server_id) {` -> ignore (principal: none; it is our own pending-join map)
  2. 9503 parse as `ServerState`
  3. 9505 `if snap.server_id != server_id {` -> reject
  That is all. Sender (`peer_str`): NOT checked (not required to be a member, the admitter, the peer we sent the request to, or anyone). Content: NOT checked (roles, owner, members, bans, mutes, settings, channels, labels, grants, `deleted`, op_log is `skip_serializing` so absent). `clamp_future_hlcs` (crdt/server_state.rs:544-584) only pulls LWW register timestamps back to now+5 min; it does not touch VALUES, and `channels`, `members`, `labels`, `label_assignments`, `pinned_messages`, `channel_layout`, `emotes`, `stickers`, `deleted` have no timestamp at all (561-566).
- Who may send a snapshot: anyone who can get a plaintext HavenMessage to the joiner's device while its join is pending: the relay with any `from` (P-01), any member of the server (they see the plaintext ServerJoinRequest in the room), any peer sharing a relay room with the joiner. How long: from `handle_join_server` until a SyncResponse completes the join (9620); for a PARKED join that is days (node/types.rs:756-759, `REDEPOSIT_INTERVAL_MS` 12 h, 3-day ring).
- When adopted: immediately, last one wins (9532 insert). After a SyncResponse completes the join, later snapshots are ignored (9499).
- Is its content checked: NO. Is there any trust anchor (expected owner, inviter, server key) in `PendingJoin`? node/types.rs:748-773 fields: `twitch_proof_json, nsfw_confirmed, requested_at, parked, last_deposited_at, device_list, key_package` : NONE FOUND.
- Can a member or the relay hand a joiner a state where the attacker is Owner/Admin: YES. Exploit shape: Alice joins server S. Mallory (relay, or any member) sends `srv_snapshot{S, state_json}` with `roles[Mallory]=Owner`, `roles[realOwner]=Member` (or absent), then `sync_response{S, [any one parseable op]}`. 9606 completes Alice's join on Mallory's state. Every later honest op from the real Owner/Admins is evaluated by Alice's `op_allowed` against Mallory's role map and rejected; Mallory's ops are admitted. Alice persists it (9529/9616), serves it to later joiners when she is the join coordinator (10309 snapshot of her `state`), and Alice's node will act as MLS subgroup coordinator from the poisoned roles (node/crypto_handler.rs:2372 `reconcile_subgroups_for_server` prefers the CRDT Owner). CONFIRMED-BY-READING for the adoption logic.
- Binding: NONE FOUND.
- Transport parity: single site.
- Freshness: none beyond "join pending".
- Absent fields: every `#[serde(default)]` map in ServerState (crdt/server_state.rs:209-250) may be absent -> empty.
- Blast radius: joiner's persisted state; spreads to later joiners through the victim's own join serving; not to established members (their op_allowed rejects the attacker's ops).
- Tests: crdt/server_state.rs:3448 `snapshot_clamp_future_hlcs_bounds_every_register` (clamp only). No test of a hostile/unsolicited snapshot or of role content. NOT FOUND in node/test_harness.rs (grep `ServerStateSnapshot|srv_snapshot`: only 1076 `GetServerStateSnapshot`).
- SUSPICION: CRDT-S1.

### A-07 HavenMessage::ServerJoinResolved (relay topic 0x07 `~join` ring, carries a CrdtOp)

- Dispatch: plaintext / topic-ring replay, node/swarm.rs:10361 `HavenMessage::ServerJoinResolved {`. Published by node/sync_handler.rs:1195-1219 `publish_join_resolution` (SendToRoomTopic `~join`).
- Handler: inline; carried op -> node/swarm.rs:10419 `apply_remote_crdt_op(` (A-01).
- Target: `server_id`, `joiner_master`, `requested_at`; carried `op_json` (any payload; not checked to be a MemberAdded naming `joiner_master`).
- State changes: joiner side 10370 `if joiner_master == local_peer_str && requested_at == pending.requested_at {` -> not admitted -> 10383 `sync_handler::handle_join_refused(` (drops the pending join). Member side: 10411-10413 `join_resolutions.insert(key, requested_at)` (RAM, max-wins), then A-01 for the op.
- Checks: joiner side: NONE on the sender. Member side: 10394 server known; 10397 `let sender_master = super::resolver::resolve(&peer_str);` 10398-10405 `sender_is_member` (principal: relay-stamped sender device resolved to master). The carried op then passes `admit_remote_op` on its author.
- Who can sign: frame unsigned; carried op signed by its author.
- Binding: carried op = op_allowed; the resolution itself: sender membership only (relay-forgeable `from`).
- Freshness: nonce `requested_at` for the joiner side; op replay as 0.5.
- SUSPICION: CRDT-S17 (joiner-side refusal from anyone; low); it is also a third delivery channel for CRDT-S5 replays.
- Tests: harness tests reference it (18135, 18977, 19330, 19683) for positive flows; no rejection test for a non-member sender found.

### A-08 HavenMessage::ServerDeleteBroadcast (legacy delete) and MessageEnvelope::ServerDelete (MLS)  [adjacent to scope]

- Dispatch: plaintext node/swarm.rs:10449 `HavenMessage::ServerDeleteBroadcast { server_id } =>`; MLS node/swarm.rs:11163 -> node/sync_handler.rs:3103 `handle_envelope_server_delete`; Olm: ignored (9158 `Ok(MessageEnvelope::ServerDelete { .. })` in the "MLS-only envelope ... ignoring" arm). No current sender of the plaintext variant (grep: only the receive arm).
- Target: `server_id`.
- State changes (plaintext): 10474 `let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms });` (authored and signed by US), 10475 `let _ = state.apply_op(&op);` (tombstone: crdt/server_state.rs:671-678 `self.deleted = true; self.members.clear(); self.roles.clear(); self.channels.clear(); ...`), 10477 `store.insert_crdt_op(&op)`, 10479 save state, 10483 `mls_mgr.remove_group(&server_id);`, ServerDeleted event. MLS twin sync_handler.rs:3129-3139 same.
- Checks before first state change: plaintext 10455 `let sender_role = state.get_role(&peer_str);` / 10456 `if sender_role != crate::crdt::operations::MemberRole::Owner {` -> reject. Principal: relay-stamped `peer_str` resolved to master. MLS: sync_handler.rs:3113-3116 `s.get_role(sender_peer_id)` where the caller passes `&sender_master` (swarm 11167) resolved from the MLS leaf.
- Who can sign: unsigned (authority = transport sender). The resulting op is signed by the RECEIVER, so no other replica will accept it (ServerDeleted requires an Owner author, 1427), but the local tombstone is permanent ("Monotonic delete-wins", crdt/server_state.rs:246-250; roles cleared => later honest ops fail op_allowed locally).
- Binding: `get_role(&peer_str) == Owner`. Under P-01 the relay chooses `peer_str`.
- Transport parity: MLS twin authenticates the sender via the MLS leaf; plaintext twin trusts the relay's `from`.
- Freshness: NONE FOUND (no nonce/ts), but idempotent after the first (10469 `if !state.is_deleted()`).
- Blast radius: irreversible locally; relay can do it to every member of every server it hosts.
- Tests: none found (grep `ServerDeleteBroadcast` in test_harness: NOT FOUND).
- SUSPICION: CRDT-S3.

### A-09 HavenMessage::MemberKickBroadcast and MessageEnvelope::MemberKick (MLS)  [adjacent to scope]

- Dispatch: plaintext node/swarm.rs:10493 `HavenMessage::MemberKickBroadcast { server_id } =>` (still sent by current clients: node/sync_handler.rs:1612 kick, 1877 ban); MLS node/swarm.rs:11172 -> node/sync_handler.rs:3146 `handle_envelope_member_kick`.
- Target: the RECEIVER itself (no member id in the frame).
- State changes: plaintext 10518 `if server_states.remove(&server_id).is_some() {`, 10520 `store.delete_server_state(&server_id)` (state + ALL crdt_ops rows), 10524 `mls_mgr.remove_group(&server_id);`, ServerDeleted event. MLS twin sync_handler.rs:3169-3177.
- Checks: plaintext 10499 `let sender_role = state.get_role(&peer_str);`, 10501 `let sender_perms = state.get_permissions(&peer_str);`, 10504 `if (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) == 0 {`, 10508 `if !sender_role.outranks(&our_role) {`. Principal: relay-stamped `peer_str`. MLS: sync_handler.rs:3157-3164 on the leaf-resolved master.
- Binding: role/permission of the claimed sender vs our role. Does NOT require that a `MemberRemoved`/`MemberBanned` op for us exists in the CRDT: NONE FOUND.
- Freshness: NONE FOUND.
- Blast radius: local deletion of the server (recoverable by rejoining, the CRDT still lists us).
- Tests: none found.
- SUSPICION: CRDT-S4.

### A-10 State changes that bypass `admit_remote_op`

- Startup reload node/swarm.rs:844 `match serde_json::from_str::<ServerState>(&json) {` + 851 `state.restore_op_log(ops);` (crdt/server_state.rs:472-478: no re-apply, no re-admission; trusts the local SQLCipher DB; a state adopted from a hostile snapshot stays).
- Snapshot adoption A-06 (whole state, no per-op admission).
- `canonicalize_members` folds (node/swarm.rs:857, 9521, 9612): re-keys and LWW-merges role/ban/mute/nickname/pledge/grant registers from a device key into the master key (crdt/server_state.rs:397-419, 437-446) with no authority check. See CRDT-S9.
- Locally synthesized ops on a remote trigger: A-08 (10474), MLS twin (sync_handler.rs:3129).
- Locally authored ops (`author_op` sync_handler.rs:119-130, join admission swarm.rs:10168-10182, auto-pledge 9689-9700): gated by local OpGates, not by admit (by design).
- ServerJoinResolved: NOT a bypass (routes through A-01).

---------------------------------------------------------------------------

## B. Per CrdtPayload variant (crdt/operations.rs:125-345)

Legend. "Arm" = `op_allowed` (crdt/server_state.rs:1307-1439). "Apply" =
`apply_op` (587-1071). "Merge" = HLC LWW (register merge
crdt/admin_lww.rs:74-80 `if other.hlc > self.hlc {`) or ARRIVAL (last applied
wins, no HLC compare) or SET (insert/remove, order dependent). Every variant
inherits the A-sites and 0.5 freshness. "Non-member author" = `get_role`
returns Member for unknown ids (1095), and no arm except MemberAdded requires
`is_member(op.author)`.

### B-01 ServerCreated { name, owner_peer_id }
- Arm 1432-1437: `&op.author == owner_peer_id && self.current_owner().is_none_or(|existing| existing == *owner_peer_id)`.
- Author: must equal the owner it names. Target/state: only legal while the state has NO Owner (or re-sent by the same Owner).
- Apply 614-645: 620-622 `hostile_refound = self.current_owner().is_some_and(|existing| existing != *owner_peer_id)`; if not hostile: 624-628 `self.name = AdminLwwReg::new(` (DIRECT assignment, not merge, so a replayed founding op resets the name), 629-635 `self.members.insert(`, 636-643 `self.roles.insert(` Owner (replaces the register).
- Who can found: on an ownerless state, ANY signer, member or not. Ownerless states arise: (a) the join skeleton (swarm.rs:9562-9564), (b) a snapshot with no Owner, (c) an Owner that self-removed (ingest allows it, B-09) or self-demoted (B-10), (d) `ServerDeleted` (roles cleared, 673).
- SUSPICION: CRDT-S2, CRDT-S13, CRDT-S18.

### B-02 ServerRenamed { new_name }
- Arm 1323-1326: `(sender_perms & Permission::MANAGE_SERVER) != 0`.
- Target: server name. No length bound at ingest (NONE FOUND).
- Apply 647-651: `self.name.merge(&remote);` Merge: LWW.
- Admin (default perms include MANAGE_SERVER, operations.rs:405) may rename.

### B-03 ServerSettingChanged { key, value }
- Arm 1323-1326 (same as B-02): only MANAGE_SERVER. Key allowlist: NONE FOUND. Value validation: NONE FOUND.
- Apply 653-663: `self.settings.entry(key.clone()).or_insert_with(...)`, 662 `entry.merge(&remote);`. Merge: LWW per key.
- Keys with behaviour (consumers): `min_pledge_mb` 1142 (used at swarm.rs:9689 `state.min_pledge_mb() * 1024 * 1024`, unchecked mul), `relay_catchup_secs` 1155, `is_private` 1165, `is_nsfw` 1175, `max_members` 1184, `twitch_verification_enabled`/`twitch_channel_id`/`twitch_channel_name`/`twitch_min_follow_days`/`twitch_require_sub`/`twitch_owner_verify` node/twitch.rs:66-92, `max_file_size_mb` node/file_handler.rs:306/2906, `server_banner` node/assets.rs:104, `server_avatar` swarm.rs:1859/13023 (raw base64 image bytes served to guests), `retention_files` vault/adaptive.rs:73, `retention_messages` / `retention_messages_since` swarm.rs:5431/5439.
- Destructive keys, same bit as a rename: `retention_files` -> swarm.rs:5394-5420: `cs.delete_content` (5401), `crate::node::at_rest::remove(...)` (5418), `cs.mark_file_expired` (5420) on EVERY member's node every 30 min. `parse_retention_days` vault/adaptive.rs:60 `other => other.trim_end_matches('d').parse().ok(),` accepts "0d"/"1d". The forward-only guard for messages (`retention_messages_since`) is itself an attacker-writable key. Message prune: swarm.rs:5442 `let cutoff = now_ts - (days as i64 * 86400);` with `now_ts` in SECONDS (5384 `.as_secs() as i64;`) vs channel message timestamps in MILLISECONDS (node/message_ops.rs:819 `let timestamp = order_us / 1000;`), so `prune_channel_messages_in_range` (storage/messages.rs:2306-2313, `timestamp < ?3`) appears never to match today (PLAUSIBLE; not traced through every insert path). Files use a unit-tolerant query (vault/content_store.rs:804-805 `CASE WHEN created_at > 100000000000 THEN created_at / 1000`), so file deletion is effective.
- SUSPICION: CRDT-S11.

### B-04 ServerDeleted { deleted_at }
- Arm 1427: `CrdtPayload::ServerDeleted { .. } => sender_role == MemberRole::Owner,`.
- Target: whole server. `deleted_at` unused at apply.
- Apply 665-679: 671 `self.deleted = true;` 672-678 clear members, roles, channels, nicknames, twitch_usernames, storage_pledges, label_assignments (NOT settings/bans/mutes/labels/grants). Irreversible (no un-delete, 246-250).
- Live side effects: A-01 6260-6270 MLS group removed + ServerDeleted event; A-03 event only; A-05 plaintext 9823-9834 MLS removal.
- Any Owner (there may be several, B-10) or a device key mapped to an Owner (CRDT-S10). Captured replicas (CRDT-S1/S2): attacker is Owner there.

### B-05 ChannelAdded { channel_id, name, category, channel_type }
- Arm 1311-1316: `(sender_perms & Permission::MANAGE_CHANNELS) != 0`.
- Target: new channel id; `channel_id` grammar NOT validated at ingest (NONE FOUND), although node/types.rs:785 comments that `~` "is not in the channel-id alphabet" for `JOIN_TOPIC` (788).
- Apply 681-706: `self.channels.entry(channel_id.clone()).or_insert_with(` (first add wins; SET).
- SUSPICION: CRDT-S17 (low).

### B-06 ChannelRemoved { channel_id }
- Arm 1311-1316 MANAGE_CHANNELS. No visibility check on the author.
- Apply 708-710 `self.channels.remove(channel_id);` (SET remove, no tombstone; a replayed ChannelAdded with the same id re-creates it).

### B-07 ChannelRenamed { channel_id, new_name }
- Arm 1311-1316 MANAGE_CHANNELS.
- Apply 712-719 `ch.name = new_name.clone();` Merge: ARRIVAL.
- SUSPICION: CRDT-S6.

### B-08 MemberAdded { peer_id, display_name }
- Arm 1335-1339: `self.is_member(&op.author)`. ANY current member may author it (test crdt/server_state.rs:1755 `("alice", CrdtPayload::MemberAdded { peer_id: "carol".into(), ...}, true)`).
- Target check: NONE FOUND. Not checked: `is_banned(peer_id)`, `is_private()`, `max_members()`, Twitch credential, `twitch_owner_verify`, NSFW consent. Those gates exist only in the admitting member's handler (node/swarm.rs:10025 `if !is_sibling && state.is_banned(&member_master) {`, 10120 `if !is_sibling && state.is_private() {`, 10150 `if let Some(max) = state.max_members() {`, Twitch 10041-10078, owner-verify 10081-10109). `is_banned` has only two consumers (swarm.rs:9820, 10025), so a banned-but-re-added member is a full member everywhere else.
- Role given: apply 731-737 `self.roles.entry(peer_id.clone()).or_insert_with(|| AdminLwwReg::new(MemberRole::Member, ...))` : Member ONLY IF no role register exists; a pre-existing register (e.g. RoleChanged on a non-member, B-10) is kept.
- Apply 721-738 members `or_insert_with` (SET add; no tombstone vs MemberRemoved).
- SUSPICION: CRDT-S8, CRDT-S5 (replayed original MemberAdded re-admits a kicked member).

### B-09 MemberRemoved { peer_id }
- Arm 1329-1334: 1330 `let target_role = self.get_role(peer_id);` 1331 `peer_id == &op.author` (raw string compare) `|| ((sender_perms & Permission::KICK_MEMBERS) != 0 && sender_role.outranks(&target_role))`.
- Admin on Owner: `Admin.outranks(Owner)` false -> refused. Admin on Admin: refused (no role outranks itself, operations.rs:420-422). Owner on another Owner: refused (arm does not have can_kick's Owner shortcut). Moderator on Member: allowed. Self-removal: always allowed, INCLUDING the Owner (authoring refuses it: node/sync_handler.rs:1779-1781 `Owner cannot leave`; ingest does not).
- Target resolution: `get_role(peer_id)` resolves a device id to its master; an id the replica cannot resolve reads as Member (see CRDT-S9 for the fold consequence on other register maps).
- Apply 740-746: `self.members.remove(peer_id); self.roles.remove(peer_id); self.nicknames.remove(peer_id); self.twitch_usernames.remove(peer_id); self.storage_pledges.remove(peer_id);` (no tombstone; role register DELETED).
- Live side effects: self-eviction durable teardown on the victim (A-01 6245-6388; A-03 11114-11144; A-05 9835-9864).
- SUSPICION: CRDT-S5 (replay of an old kick re-kicks and tears down the victim's local state; removal of the role register enables a replayed promotion), CRDT-S13 (Owner self-remove).

### B-10 RoleChanged { peer_id, role, priority }
- Arm 1317-1319: `self.can_change_role(&op.author, peer_id, role)` (0.4).
- Can it make someone Owner: yes, but ONLY when the author is Owner (1234-1236 returns true before the 1250 Owner guard). Can it change the Owner's role: only an Owner author (a non-Owner fails 1242 because nobody outranks Owner). An Owner may demote itself or any co-Owner. Admin: may set Member/Moderator on Members/Moderators (1242, 1246); cannot touch Admins/Owners, cannot grant Admin.
- Target not required to be a member: NONE FOUND (a non-member gets a role register; B-08 keeps it on join).
- Apply 829-843: 838-840 `self.roles.entry(peer_id.clone()).or_insert_with(|| AdminLwwReg::new(role.clone(), op.hlc.clone(), *priority));` 842 `entry.merge(&remote);`. Merge: LWW, BUT when the register is absent (after MemberRemoved/MemberBanned deleted it, 742/914) ANY old RoleChanged re-inserts its value.
- `priority` payload field: inert (comment 834-837).
- SUSPICION: CRDT-S5 (replayed old promotion after kick => ex-member regains Admin; since op_allowed never requires membership, that ex-member can then author Admin ops), CRDT-S9 (device-id target), CRDT-S13 (multiple Owners / self-demotion reopens ServerCreated).

### B-11 NicknameChanged { peer_id, nickname }
- Arm 1340-1344: `peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin`.
- Member on another member: refused. Admin on Owner / on another Admin: ALLOWED (no outrank check). Role-based, not permission-based: authoring uses `OpGate::SelfOrPerm(&peer_id, Permission::MANAGE_ROLES)` (node/sync_handler.rs:2604) -> a MANAGE_ROLES override on Moderator authors ops ingest refuses; an Admin whose MANAGE_ROLES was revoked still passes ingest.
- Non-member author: self-nickname allowed (no membership check).
- Apply 845-854 merge LWW.

### B-12 TwitchUsernameChanged { peer_id, twitch_username }
- Arm: same as B-11 (1340-1344). Any member may set its OWN value to anything (self-asserted, unverified); Admin may set anyone's, incl. the Owner's. Authoring gate node/sync_handler.rs:2633 `OpGate::SelfOrPerm(&peer_id, Permission::MANAGE_ROLES)` (same mismatch as B-11).
- Apply 856-863 LWW.
- Consumer: api/crdt.rs:405 `twitch_username: state.get_twitch_username(&m.peer_id),` (MemberFfi); a Dart UI consumer of that member field: NOT FOUND by grep (only profile twitchUsername is used), so impact currently low.

### B-13 ChannelLayoutUpdated { layout_json }
- Arm 1311-1316 MANAGE_CHANNELS.
- Apply 865-869 `if let Ok(layout) = serde_json::from_str::<Vec<ChannelLayoutItem>>(layout_json) { self.channel_layout = layout; }` Merge: ARRIVAL. No size bound.

### B-14 MessagePinned { channel_id, message_id }
- Arm 1345-1348 MANAGE_CHANNELS. Channel existence / author visibility / message existence: NONE FOUND.
- Apply 871-876 push if absent (SET). Event A-01 6306-6311.

### B-15 MessageUnpinned { channel_id, message_id }
- Arm 1345-1348 MANAGE_CHANNELS.
- Apply 878-885 retain-out (SET, no tombstone vs a later re-pin; replayable).

### B-16 StoragePledgeChanged { peer_id, pledge_bytes }
- Arm 1340-1344 (same as B-11): self, or Owner/Admin on anyone. Authoring gate for self is `OpGate::Always` (node/sync_handler.rs:2786).
- Non-member author: self-pledge allowed.
- Apply 887-894 LWW. Consumers: vault placement weights node/vault_ops.rs:240-243 and node/swarm.rs:5491-5493 (restricted to `state.members` candidates), `total_pledged_bytes` crdt/server_state.rs:1136 `self.storage_pledges.values().map(|reg| *reg.read()).sum()` (u64 sum of attacker values; overflow panics in debug builds only).

### B-17 RolePermissionsChanged { role, permissions }
- Arm 1349-1353: 1350 `let target = MemberRole::from_str(role);` 1351-1352 `(sender_perms & Permission::MANAGE_ROLES) != 0 && sender_role.outranks(&target)`.
- Can an Admin grant permissions above its own: YES when the Owner has reduced "admin" below ALL: `permissions` is an unchecked `u32` (no `& sender_perms`, no `& Permission::ALL`: NONE FOUND). With defaults Admin already holds every defined bit (operations.rs:405-411 vs 680-686), so the gap is config-dependent.
- `role` string: not validated; `from_str` maps unknown strings to Member (operations.rs:392-399), so `"Admin"`/`"x"` pass the outrank check as Member and write an unused key.
- `role_permissions["member"]` also governs strangers and ex-members (0.4). An Admin can therefore widen what EVERY key-holder may author.
- Apply 896-903 LWW. Moderator cannot (lacks MANAGE_ROLES by default; test 1770).
- SUSPICION: CRDT-S7, CRDT-S12.

### B-18 LabelCreated { label_id, name, color, access }
- Arm 1390-1394 MANAGE_ROLES.
- Apply 956-965 `self.labels.entry(label_id.clone()).or_insert_with(` (first wins). `access` `#[serde(default)]` -> false when absent (operations.rs:222-223).

### B-19 LabelDeleted { label_id }
- Arm 1390-1394 MANAGE_ROLES.
- Apply 967-972 remove + strip every assignment (SET, no tombstone).

### B-20 LabelUpdated { label_id, name, color, access }
- Arm 1390-1394 MANAGE_ROLES.
- Apply 974-985: 976-977 `label.name = name.clone(); label.color = color.clone();` 981-983 `if let Some(a) = access { label.access = *a; }` (absent = PRESERVE). Merge: ARRIVAL. A replayed or late-delivered `access: Some(false)` turns an access label cosmetic -> self-assignable (B-21) -> channel access.
- SUSPICION: CRDT-S5/S6.

### B-21 LabelAssigned { label_id, peer_id }
- Arm 1395-1402: `self.can_self_toggle_label(&op.author, peer_id, label_id) || (sender_perms & Permission::MANAGE_ROLES) != 0`.
- Self: only EXISTING non-access labels (1557). Others / access labels: MANAGE_ROLES, with NO outrank check and NO check that the author can see the channels the label gates (NONE FOUND): an Admin can assign any access label to anyone, including the Owner or itself.
- Non-member author: self-toggle of cosmetic labels allowed.
- Apply 987-992 push if absent (SET, no tombstone vs LabelUnassigned).
- Live: subgroup reconcile (A-01 6393-6431).
- SUSPICION: CRDT-S5 (replayed old assignment regains restricted access).

### B-22 LabelUnassigned { label_id, peer_id }
- Arm 1395-1402 (same). Apply 994-1001 retain-out (SET).

### B-23 ChannelVisibilityChanged { channel_id, visibility }
- Arm 1380-1389 MANAGE_CHANNELS. Author visibility of the channel: NONE FOUND. Unknown strings map to Everyone at apply (753 `_ => ChannelVisibility::Everyone,`).
- Apply 748-756 `ch.visibility = match visibility.as_str() {` Merge: ARRIVAL (no HLC).
- SUSPICION: CRDT-S5/S6 (relay picks final visibility per replica; replay re-opens a restricted channel).

### B-24 ChannelPostingChanged { channel_id, posting }
- Arm 1380-1389 MANAGE_CHANNELS. Apply 758-766 ARRIVAL, unknown -> Everyone (763).

### B-25 ChannelPublicChanged { channel_id, is_public }
- Arm 1370-1379: MANAGE_CHANNELS `&& self.channels.get(channel_id).map_or(true, |ch| ch.channel_type == ChannelType::Text)`.
- Apply 768-776 `if ch.channel_type == ChannelType::Text { ch.is_public = *is_public; }` Merge: ARRIVAL.
- Live: A-01 6320-6351 and A-03 3034-3063 re-announce `PublicChannelConfigChanged` to the whole server room (`WsCommand::SendToRoom`, 6338).
- Consequence of a flip to public on a replica: that member's sends branch to plaintext `PublicChannelMessage` (CLAUDE.md rule; send path not re-read here).
- SUSPICION: CRDT-S5/S6 (highest-impact instance: a replayed or reordered `is_public: true` makes a now-private channel public on the victim's replica).

### B-26 ChannelVisibilityLabelsChanged { channel_id, labels }
- Arm 1380-1389 MANAGE_CHANNELS. Label ids not checked to exist / be access labels (NONE FOUND; a later LabelDeleted strips assignments, 969-971, so a gate on a deleted id matches nobody via `holds_any_label` 1544-1548).
- Apply 790-794 `ch.visibility_labels = labels.clone();` ARRIVAL.

### B-27 ChannelPostingLabelsChanged { channel_id, labels }
- Arm 1380-1389 MANAGE_CHANNELS. Apply 796-800 ARRIVAL.

### B-28 ChannelGrantSet { channel_id, peer_id, expires_at }
- Arm 1380-1389 MANAGE_CHANNELS only. Not checked: author can see the channel, channel exists, grantee is a member, `expires_at` bound (NONE FOUND). An author holding MANAGE_CHANNELS via an override (e.g. Moderator) can grant ITSELF an admin-only channel.
- Apply 802-810 LWW per (channel, member). Live: subgroup reconcile.

### B-29 ChannelGrantRevoked { channel_id, peer_id }
- Arm 1380-1389 MANAGE_CHANNELS. Apply 812-827 LWW to 0 then prune (823 `per_chan.retain(|_, reg| *reg.read() != 0);`). Pruning deletes the register, so a replayed older GrantSet re-inserts via `or_insert_with` (805) -> CRDT-S5 shape.

### B-30 MemberBanned { peer_id }
- Arm 1354-1358: `(sender_perms & Permission::KICK_MEMBERS) != 0 && sender_role.outranks(&target_role)` with `target_role = self.get_role(peer_id)` (1355).
- Admin on Owner/Admin: refused. Moderator on Member: allowed. Owner on co-Owner: refused. Pre-emptive ban of a non-member: target reads Member -> allowed.
- Apply 905-918: 911 ban register LWW; 913-917 remove member, ROLE register, nickname, twitch, pledge (no tombstone for the role).
- Live: only MemberLeft event when it names our exact local id (6274 `if *peer_id == local_peer {`, raw compare, no teardown); offline reconcile tears down (9835).
- SUSPICION: CRDT-S9 (device-id target), CRDT-S8 (ban not enforced on MemberAdded).

### B-31 MemberUnbanned { peer_id }
- Arm 1359-1361: `(sender_perms & Permission::KICK_MEMBERS) != 0` : NO target/outrank check. A Moderator can lift a ban the Owner placed.
- Apply 920-932 LWW to false, then 931 prune.
- SUSPICION: CRDT-S12.

### B-32 MemberMuted { peer_id, expires_at }
- Arm 1362-1366: KICK_MEMBERS + outranks target (same as ban). `expires_at` unbounded (u64::MAX = permanent by design).
- Apply 934-941 LWW.

### B-33 MemberUnmuted { peer_id }
- Arm 1367-1369: `(sender_perms & Permission::KICK_MEMBERS) != 0` : NO target check. A Moderator muted by an Admin can unmute ITSELF; a Moderator can unmute a member an Admin/Owner muted.
- Apply 943-954 LWW to 0 then 953 prune (register deleted -> older MemberMuted replay re-inserts, CRDT-S5 shape).
- SUSPICION: CRDT-S12.

### B-34 ChannelSlowModeChanged { channel_id, seconds }
- Arm 1380-1389 MANAGE_CHANNELS. Apply 778-782 ARRIVAL.

### B-35 ChannelMediaOnlyChanged { channel_id, media_only }
- Arm 1380-1389 MANAGE_CHANNELS. Apply 784-788 ARRIVAL.

### B-36 EmojiAdded { name, hash, animated }
- Arm 1403-1407: MANAGE_EMOTES `&& super::valid_emote_name(name) && super::valid_emote_hash(hash)` (crdt/mod.rs:62-71).
- Apply 1003-1019: replace on same name (ARRIVAL), new names capped at 50 (1009).

### B-37 EmojiRemoved { name }
- Arm 1408-1410 MANAGE_EMOTES. Apply 1021-1023 remove (SET).

### B-38 StickerAdded { hash, name, pack, animated, w, h }
- Arm 1412-1422: MANAGE_EMOTES, `valid_emote_hash(hash)`, `valid_sticker_label(name)`, `valid_sticker_label(pack)`, `(1..=4096).contains(w)`, `(1..=4096).contains(h)`.
- Apply 1025-1043 replace by hash, new capped at 50.

### B-39 StickerRemoved { hash }
- Arm 1423-1425 MANAGE_EMOTES. Apply 1045-1047 remove.

---------------------------------------------------------------------------

## C. MemberRole ordering and permission defaults

- crdt/operations.rs:363-368 `enum MemberRole { Owner, Admin, Moderator, Member }`; 373-380 priority Owner 3, Admin 2, Moderator 1, Member 0; 420-422 `self.priority() > other.priority()` (strict, so equal roles never outrank each other).
- crdt/operations.rs:392-399 `from_str`: case-sensitive, unknown -> Member.
- Defaults 402-417: Owner `Permission::ALL`; Admin `MANAGE_SERVER | MANAGE_CHANNELS | MANAGE_ROLES | KICK_MEMBERS | SEND_MESSAGES | READ_MESSAGES | MANAGE_EMOTES` (== ALL); Moderator `KICK_MEMBERS | SEND_MESSAGES | READ_MESSAGES`; Member `SEND_MESSAGES | READ_MESSAGES`.
- Bits 670-686 (bit 3 unused).
- FFI `default_role_permissions` api/crdt.rs:1463-1465 `MemberRole::from_str(&role).default_permissions()` (UI mirror only; ingest uses `get_permissions`, override-aware).
- Owner is special-cased in `get_permissions` (1205-1206) and `get_role_permissions` (1216-1218): overrides can never reduce the Owner.

---------------------------------------------------------------------------

## D. SUSPICIONS (consolidated)

CRDT-S1  [HIGH] ServerStateSnapshot is adopted wholesale from ANY sender while
a join is pending; no content, owner, or sender check.
node/swarm.rs:9499/9503/9505/9532. Exploit: Alice asks to join S. Mallory
(P-01 relay injecting with any `from`, or any member/room peer) sends
`srv_snapshot` naming Mallory Owner, then any one-op `sync_response` (9606
completes the join even with 0 ops admitted). Alice's replica is captured:
the real Owner's ops are refused by Alice (Member in the fake role map),
Mallory's are admitted, Alice persists it and re-serves it as join
coordinator (10309). CONFIRMED-BY-READING.

CRDT-S2  [HIGH] Pending-join skeleton is ownerless, and `op_allowed` admits
the FIRST `ServerCreated` from whichever key names itself.
node/swarm.rs:9562-9564 + crdt/server_state.rs:1432-1437 (behaviour asserted
by the unit test at 1859-1866). Exploit: with no snapshot (or with one),
Mallory's SyncResponse puts `ServerCreated{owner: Mallory}` signed by Mallory
first; the real founding op is then refused (`existing != owner`). Same
capture as S1. CONFIRMED-BY-READING.

CRDT-S3  [HIGH under P-01] Plaintext `ServerDeleteBroadcast` authorises on the
relay-stamped sender: node/swarm.rs:10455-10456 `state.get_role(&peer_str)` ==
Owner, then the RECEIVER synthesizes and applies its own `ServerDeleted`
(10474-10483): tombstone, roles/members/channels cleared, MLS group removed,
permanent locally. Exploit: relay injects `server_delete{S}` with `from` = the
Owner's device id to every member; every member's copy of S is destroyed.
No current client sends this variant (receive-only legacy). CONFIRMED-BY-READING.

CRDT-S4  [MED under P-01] Plaintext `MemberKickBroadcast` authorises on the
relay-stamped sender (node/swarm.rs:10499-10508) and deletes the receiver's
server state and MLS group (10518-10524) without any CRDT MemberRemoved/Banned
for the receiver. Exploit: relay injects `member_kick{S}` from the Owner's
device id to each non-owner; each silently loses S. Also a legitimate
Moderator can eject a member locally without a CRDT op. CONFIRMED-BY-READING.

CRDT-S5  [HIGH] Replay of genuine signed ops re-applies security state.
Dedup is an in-RAM set over the newest <=1000 ops (crdt/server_state.rs:1059-1066;
restart loads newest 1000, storage/messages.rs:2010); `admit_remote_op` has no
age bound; `op_allowed` judges the author's CURRENT role; removals have no
tombstones and many fields apply by arrival (B-07, B-13, B-20, B-23..B-27,
B-34, B-35) or re-insert a deleted register (B-10 after 742/914, B-29 after
823, B-33 after 953). The relay has every op in plaintext (0.6) and can
re-inject via CrdtOpBroadcast (9877), SyncResponse for known servers (9540),
or ServerJoinResolved (10419). Exploits: (a) replay an old
`ChannelPublicChanged{c, true}` (Admin/Owner authored) after c went private ->
c public again on the victim -> victim posts plaintext; (b) replay an old
`LabelAssigned(accessLabel, X)` after it was unassigned -> X regains a
restricted channel; (c) X, an Admin later kicked (742 deletes his role
register), replays the Owner's old `RoleChanged{X, Admin}` -> X is Admin again
on that replica without being a member, and op_allowed never requires
membership, so X can then ban/rename/set `retention_files`; (d) replay an old
`MemberRemoved(Bob)` after Bob rejoined -> Bob removed and Bob's own node runs
the durable teardown (6245-6388). State logic CONFIRMED-BY-READING;
reachability PLAUSIBLE (needs the op outside the victim's dedup window: >1000
later ops, which CRDT-S7 lets a stranger force, or a restarted/fresh replica).

CRDT-S6  [MED] Concurrent writes to ARRIVAL-merged fields do not converge; the
last frame delivered wins per replica (e.g. crdt/server_state.rs:750, 760,
772-773, 792, 798, 976-983). A relay that delays one Admin's op behind the
Owner's chooses each replica's final visibility / public flag / access flag,
and the fork is permanent. CONFIRMED-BY-READING.

CRDT-S7  [MED] `op_allowed` requires membership of the author only for
MemberAdded (1338). Unknown authors read as Member (1095) and get
`role_permissions["member"]` (1208-1209). With default perms any key-holder
(stranger, kicked or banned ex-member) can author self NicknameChanged /
TwitchUsernameChanged / StoragePledgeChanged (1343), self MemberRemoved
(1331), cosmetic LabelAssigned (1557); each new op is persisted and
re-flooded by every receiver (6177-6203), and 1000 of them evict older ops
from every dedup window (feeds S5). If the Owner/Admin ever grants a
management bit to "member", every stranger gains it at ingest.
CONFIRMED-BY-READING (delivery to members PLAUSIBLE: needs a shared room).

CRDT-S8  [MED] MemberAdded ingest ignores bans and join policy: any member can
(re-)add a banned peer, or anyone to a private / full / Twitch-gated /
owner-verify server (op_allowed 1335-1339 vs admitter-only gates
node/swarm.rs:10025-10163). `is_banned` is read only at 9820/10025, so the
re-added banned peer is a full member elsewhere. CONFIRMED-BY-READING.

CRDT-S9  [MED, PLAUSIBLE] Device-id targets bypass rank checks, then the fold
applies them to the master. An Admin targets one of the Owner's DEVICE ids
that a replica cannot yet resolve: `get_role(device)` = Member (1095), so
RoleChanged(device -> Member) (1242/1246), MemberBanned(device) (1355-1357)
or MemberMuted(device) pass; the register is stored under the device key
(838, 907, 936). When that replica later learns the device -> master link,
`canonicalize_members` (node/swarm.rs:857/9521/9612) merges the device
register into the master's by HLC (crdt/server_state.rs:410
`Some(existing) => existing.merge(&dev_reg),`, 437/441/442): the Owner ends
Member / banned / muted there. Logic CONFIRMED-BY-READING; needs a replica
that has not ingested the Owner's device list when the op arrives (offline
member, new owner device).

CRDT-S10 [MED, PLAUSIBLE] A DEVICE key can author ops with its master's full
authority: `verify_author` only needs the key to derive `op.author`
(operations.rs:106-110), and `get_role`/`get_permissions` resolve the author
through the process-global resolver (server_state.rs:1091). Honest clients
always sign with the master (`create_op`, 503), so this is legacy-only attack
surface. A stolen-then-revoked device of an Owner keeps Owner power (e.g.
ServerDeleted, retention wipe) on every replica whose resolver still maps it
(forget happens only where the revocation was ingested,
node/crypto_handler.rs:1524/1657).

CRDT-S11 [MED/LOW, policy] `ServerSettingChanged` has no key or value
validation and destructive keys share MANAGE_SERVER with a rename: an Admin
(not only the Owner) can set `retention_files` = "0d" and every member's node
deletes vault content and channel files within 30 min
(node/swarm.rs:5394-5420, vault/adaptive.rs:60). `retention_messages` would do
the same for messages with an attacker-set `retention_messages_since`, but
appears neutralised by a seconds-vs-milliseconds mismatch (5384 vs
message_ops.rs:819) (PLAUSIBLE). Unchecked `min_pledge_mb() * 1024 * 1024`
(swarm.rs:9689) panics in debug builds only. File-deletion path
CONFIRMED-BY-READING.

CRDT-S12 [LOW, policy] Unscoped moderation edges: MemberUnbanned (1359-1361)
and MemberUnmuted (1367-1369) check no target, so a Moderator can lift the
Owner's ban or unmute itself; NicknameChanged/Twitch/Pledge let an Admin
rewrite the Owner's and other Admins' values (1343); RolePermissionsChanged
lets an Admin grant bits it no longer holds and accepts any `role` string
(1350-1352); authoring gates (sync_handler.rs:2604/2633 SelfOrPerm
MANAGE_ROLES) disagree with ingest (role == Owner/Admin), a fork generator.
CONFIRMED-BY-READING.

CRDT-S13 [LOW] Ownership edges: an Owner can mint co-Owners and demote itself
(1234-1236); ingest accepts an Owner's self-MemberRemoved (1331) that
authoring forbids (sync_handler.rs:1779); any of these leaves the state
ownerless, after which ANY signer (member or not) can `ServerCreated` itself
Owner (1432-1437). With two Owners `current_owner()` (511-514) is arbitrary
per replica. CONFIRMED-BY-READING.

CRDT-S14 [LOW] Olm-fallback CrdtOp pushes the op a second time after
`apply_op` inserted it, and also when `apply_op` returned early on a
duplicate: node/swarm.rs:9087-9088 vs crdt/server_state.rs:604-605/1055. Any
peer with an Olm session re-sending one valid op grows the op log without
bound (no compaction on push), breaks its sort order, and triggers a DB write
and SyncCompleted event per frame. CONFIRMED-BY-READING.

CRDT-S15 [LOW/MED, confidentiality] SyncRequest is served with no membership
check on all three transports (node/swarm.rs:9461, 9104;
node/sync_handler.rs:3198), and the plaintext and Olm arms answer in
plaintext (9467, 9110). Any peer in a shared room (and the relay on every
honest sync) gets the full op log: members, roles, restricted channel names,
labels, grants, bans, Twitch gate settings. That includes a peer whose join
to a private server was refused. CONFIRMED-BY-READING.

CRDT-S16 [LOW] HLC: `op.hlc.actor` is not bound to `op.author` (only signed),
so an author picks its LWW tie-break; `counter` is unbounded and
`witness` adds 1 unchecked (crdt/hlc.rs:114, 121): a panic in debug builds,
a wrap in release (no overflow-checks in Cargo.toml `[profile.release]`),
reachable by any admitted op incl. a stranger's self-nickname (S7). PLAUSIBLE.

CRDT-S17 [LOW] `ChannelAdded.channel_id` grammar not validated at ingest
(681-706) although `JOIN_TOPIC` relies on `~` never being a channel id;
ServerJoinResolved's joiner branch (node/swarm.rs:10370-10383) acts on any
sender carrying the right nonce, so the relay or any room peer can refuse a
pending join. Availability only. CONFIRMED-BY-READING.

CRDT-S18 [LOW] A replayed founding `ServerCreated` (same Owner, outside the
dedup window) resets the server name by direct assignment
(crdt/server_state.rs:624-628) and replaces the Owner's role register (636).
CONFIRMED-BY-READING (reachability as S5).
