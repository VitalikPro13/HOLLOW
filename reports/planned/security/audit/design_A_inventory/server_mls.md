# Design A inventory: server, CRDT, MLS, join, conference and channel-control frames

Read-only evidence, 2026-09-27, HEAD `a71e72fa`. Every `node/swarm.rs` line below was re-checked
against `git show HEAD:` (the working tree gained an UNCOMMITTED, untracked `node/frame_auth.rs` plus a
sealing stage in `node/swarm.rs:569-571` / `:4576-4596` while this was being written; that in-flight
work is NOT evaluated here, everything describes HEAD). `node/sync_handler.rs` differs from HEAD only
at `:1843-1846` (no line shift). Rust paths are relative to `rust/hollow_core/src/`, relay paths to the
repo root. Attacker P-01 = a malicious relay: stamps any `from`, replays, re-routes, drops, reorders.

---

## Cross-cutting facts (cited by the sections as F1..F9)

- **F1. `from` is relay-stamped; room and opcode are discarded.** `node/ws_client.rs:523-535`
  (0x05 → `WsEvent::Message`, 0x06 → `WsEvent::DirectMessage`), `:537-551` (0x08 topic: the topic
  string is skipped, `let after_topic = &after_room[topic_end + 1..];`, and the frame becomes an
  ordinary `WsEvent::Message`). Dispatch `node/swarm.rs:4576`
  `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } =>` passes only
  `&local_peer_str, &from, is_invisible,` (`:4933`) into `handle_incoming_request` (`:6620`); `room` is
  used only by the recovery-pool gate (`:4627`). No arm in this area knows the room, the opcode, or
  whether the frame is a live copy or a ring/buffer replay.
- **F2. No self or shape check on `from`.** `handle_incoming_request` goes straight to
  `match request {` (`node/swarm.rs:6689`). A relay may deliver a frame to device D claiming
  `from = D` or `from = D's master`. The only pre-dispatch gate is a token bucket keyed on the
  relay-stamped `from` (`:4592-4612`, `RATE_LIMIT_BURST: u32 = 100`, `RATE_LIMIT_REFILL: u32 = 20`
  at `:1171-1172`), which P-01 bypasses by rotating `from`.
- **F3. Device → master collapse.** `get_role` / `is_member` resolve the id first
  (`crdt/server_state.rs:1328-1336` `let key = super::resolve_identity(peer_id);`, `:1540-1543`);
  an unknown id resolves to itself and gets role `Member` (`:1335` `.unwrap_or(MemberRole::Member)`).
  Device ids and their master are public (signed device lists ride plaintext `ProfileUpdate` and
  `ServerJoinRequest`; bound MLS KeyPackages carry `hl1:{device}:{master}:{sig}`).
- **F4. Plaintext send helpers.** `send_message_to_peer` = 0x04 SendDirect into the FIRST room that
  lists the target (`node/crypto_handler.rs:2987-2999`, `ws_room_for_peer` `:2671-2681`);
  `send_message_to_peer_in_room` = 0x04 into an explicit room (`:3021-3033`); `send_raw_to_identity`
  = 0x04 to every online device of a master (`:3623-3647`); `SendToRoomTopic` = 0x07, `SendToRoom`
  = 0x03, `SendDirect` = 0x04 (`node/ws_client.rs:1031-1071`), `SendChannelDirect` = 0x09 (`:1007-1030`).
- **F5. Honest-relay lateness.** A 0x04 whose target is not in the room is buffered and replayed on
  that device's next join of the room: `relay-uws/src/ws_handler.cpp:1750-1766`
  (`buffer_offline_msg(target_str, room_str, ...)`), TTL `relay-uws/src/state.h:39`
  `OFFLINE_BUFFER_TTL_SECS = 86400;  // 24 hours`, per-recipient opt-in 1 h..7 d (`state.h:68-69`).
  Topic rings: retention clamped 1 h..7 d (`ws_handler.cpp:1343-1344`), server default 3 days
  (`crdt/server_state.rs:1393-1398` `.unwrap_or(3 * 86400)`), replayed on `TopicCatchup`
  (`node/sync_handler.rs:817-857`, `node/swarm.rs:4006-4021`). 0x03 is never buffered. P-01 ignores
  every TTL.
- **F6. Design E (CRDT).** Remote ops enter only via `ServerState::ingest_remote`
  (`crdt/fold.rs:160-225`): `stateless_check` (op server id, author signature, future bound,
  `:229-238`), dedup by `(author, hlc)` (`:173-178`), then `op_allowed` at the op's fold point.
  BUT `create_op` signs with OUR master key (`crdt/server_state.rs:645-664`
  `op.sign(&signer.keypair, &signer.pk_b64);`) and `apply_op` applies without judging
  (`:753-771`); any receive arm that does `create_op` + `apply_op` mints a genuine op in our name.
- **F7. Design D (MLS).** A bound leaf = credential `hl1:{device}:{master}:{sig}`, master signature
  over `hollow-mls-leaf:{master}:{device}` and the leaf signature key must be the key inlined in the
  device id (`crypto/mls_manager.rs:99-108`, `:121-144`). The certificate is static (no group, no
  expiry, no revocation inside it). Commits and Welcomes are judged before merge
  (`node/mls_authority.rs:51-109`, `:113-145`). MLS wire format is OpenMLS's default
  `PURE_CIPHERTEXT_WIRE_FORMAT_POLICY` (`openmls-0.9.0/src/group/mls_group/config.rs:642-645`, not
  overridden in `crypto/mls_manager.rs:33-41`): commits and application messages are ciphertext,
  KeyPackages are plaintext.
- **F8. Push fetch node.** `node/fetch.rs` handles only `MlsChannelMessage` and
  `PublicChannelMessage` (`:484-637`), read from 0x05/0x06/0x08 with the topic dropped
  (`:347-352`). `push_enrich.rs:184` (iOS NSE) reuses `fetch::run_fetch`. No other in-scope variant
  is handled outside `node/swarm.rs` / `node/conference.rs` / `node/sync_handler.rs` /
  `node/crypto_handler.rs` / `node/message_ops.rs`; `node/embedded_forwarder.rs` and `api/` build or
  handle none of them (grep).
- **F9. Tests.** `node/test_harness.rs` has no test injecting a forged `ServerDeleteBroadcast`,
  `MemberKickBroadcast`, `SiblingServerAnnounce`, `ServerJoinRejected`, `MlsEpochProbe`,
  `StatusUpdate` or conference control frame (grep: the only hit is a positive
  `ConferenceLobbyInfo` match at `:13629`).

---

### SyncRequest (`sync_request`)

1. **Send.** Plaintext 0x04 first-match (F4) to every device of a shared-server member on presence:
   `node/swarm.rs:3610-3626` (PeerJoined; comment `:3614-3615` "Always use plaintext for
   post-reconnection SyncReq"), `:4161-4174` (RoomMembers), `:6586-6594` (after a Welcome, to the
   Welcome's frame sender), `:10864-10883` (MLS decrypt `Stale`, to the relay-stamped `peer_str`),
   `node/crypto_handler.rs:3189-3201` (held commit, to `frame_sender`). MLS twin
   `MessageEnvelope::SyncReq` is never constructed (grep: only the handler).
2. **Receive.** `node/swarm.rs:8817-8853`. MLS twin `:10544-10551` → `node/sync_handler.rs:3253-3286`.
   Olm twin ignored `node/swarm.rs:8561-8577` ("MLS-only envelope via Olm ... ignoring").
3. **Effect.** Serves `crdt_sync::compute_delta(&state.op_log, &their_vector)` as a plaintext
   `SyncResponse` to `peer_str` (`:8823-8833`). The `mls_epoch` hint runs `handle_epoch_hint`
   (`:8845-8851`, `direct_probe = false`): if we are the elected responder and the sender is behind or
   forked, sends `MlsCommitCatchup` or `MlsKeyPackageRequest` to the sender
   (`node/crypto_handler.rs:3511-3560`); if the sender is ahead, probes the authority (`:3561-3565`).
4. **Authorisation.** Serving: only `if let Some(state) = server_states.get(&server_id)` (`:8821`).
   NOTHING checks the requester: not membership, not the relay `from`, not channel visibility of the
   ops served. Epoch service: `state.members.keys().any(|m| same_identity(m, from_peer))`
   (`node/crypto_handler.rs:3497`) on the relay `from`, plus election (`:3516-3521`) and a 10 s
   cooldown per (group, master) (`:3522-3527`, `EPOCH_HINT_COOLDOWN` `:3357`).
5. **Timing.** Live; can land up to 24 h late via F5 if the target left the first-match room.
6. **Replay.** Pure read, answered every time; a cross-room copy is indistinguishable (F1). The epoch
   leg is bounded only by the 10 s cooldown.
7. **Sessions.** Members normally share an MLS group and Olm sessions; plaintext is deliberate
   (epoch skew). The MLS twin has no sender.
8. **Metadata.** Request: server id, full state vector (every op author and its latest HLC = who
   administers the server and when), MLS epoch. Response: the whole signed op log in plaintext
   (members, roles, nicknames, every channel name including restricted ones, labels, grants, bans,
   mutes, settings incl. `server_avatar` and the Twitch gate, `MemberAdded.follow` credentials).
   P-01 can pull it for any server id from any member by stamping any `from` (candidate A10 still
   open).

### SyncResponse (`sync_response`)

1. **Send.** Plaintext: responder `node/swarm.rs:8827-8833` (first-match); join serving `:9705-9716`
   (`send_message_to_peer_in_room(ws_cmd_tx, &server_id, &peer_str, ...)`, all ops, into the server
   room so an absent parked joiner gets it from the relay buffer). MLS twin `SyncResp` is built only
   by `handle_envelope_sync_req` and sent over Olm (`node/sync_handler.rs:3274-3282`), where the Olm
   arm ignores it (`node/swarm.rs:8563`): dead.
2. **Receive.** `node/swarm.rs:8906-9244`. MLS twin `:10553-10559` → `node/sync_handler.rs:3289-3332`.
3. **Effect.** Pending join: builds an ownerless skeleton (`:8923-8932`). Ingest through
   `merge_ops_with` → `ingest_remote` (`crdt/sync.rs:80-94`); `insert_crdt_op` per admitted op
   (`:8948-8955`); `save_server_state` (`:8981-8985`). If a join is pending it COMPLETES
   (`:8987-9182`): deletes the pending row, emits `PendingJoinUpdated`, drops our MLS group for the id
   (`:9008-9014` "Dropping stale MLS group for {server_id} on rejoin", `mls_mgr.remove_group`),
   `JoinRoom`, `NetworkEvent::ServerJoined`, `ProfileRequestFor` x10, authors and broadcasts an
   auto-pledge op in our name (`:9052-9098`), KeyRequests, mints and sends a KeyPackage
   (`:9135-9181`). Offline reconciliation: tombstone → drop MLS group + `ServerDeleted`; ban or kick
   of us → `server_states.remove`, `delete_server_state`, drop groups, `LeaveRoom` (`:9187-9233`).
4. **Authorisation.** Sender unchecked. Gate `is_known || is_pending_join` (`:8912-8917`). Each op:
   F6. Completion condition `(report.applied > 0 || pending) && (!pending || Legacy || is_member(local))`
   (`:8967-8970`): for a Legacy (32-hex) server ANY batch with one parseable op, even a deduped
   replay, completes a pending join; an anchored server needs our own admission op to be admitted.
5. **Timing.** Live, or from the relay buffer for an absent joiner (F5; parked joins complete days
   later).
6. **Replay.** Ops dedup (F6). An undeduped op older than the log tail (e.g. a pre-checkpoint op)
   forces a full `fold_in` rebuild each time (`crdt/fold.rs:203-209`, `:274-321`); a Legacy replica
   judges replayed ops against its CURRENT state (`apply_in_arrival`, `:242-270`), so an op already
   capped out of the 1000-op legacy log can apply again (e.g. an old `MemberAdded` after a leave).
   The completion side effects are NOT bound to a request nonce: any copy that lands while a
   pending join exists completes it (see SiblingServerAnnounce for how P-01 creates one).
7. **Sessions.** A joiner has no Olm session with the responder yet (KeyRequest is sent only after
   admission, `:9731-9740`); members do and hold MLS.
8. **Metadata.** As SyncRequest (whole op log).

### ServerStateSnapshot (`srv_snapshot`)

1. **Send.** Join serving, Legacy servers only: `node/swarm.rs:9694-9703`
   (`legacy.then(|| serde_json::to_string(&state).ok())`, server room, relay-buffered).
2. **Receive.** `node/swarm.rs:8855-8904` only.
3. **Effect.** Wholesale replacement: `server_states.insert(server_id, snap)` (`:8898`) after
   `save_server_state` (`:8893-8897`); the DB row is reloaded at startup (`node/swarm.rs:841`
   `store.load_all_servers()`) even if the join never completes. Clamps future HLCs (`:8881`),
   canonicalizes members (`:8887`).
4. **Authorisation.** A pending join must exist (`:8859`); the held state must still be Legacy
   (`:8864`); `accept_join_snapshot` (`crdt/fold.rs:137-156`): refused for a self-certifying id,
   server id must match, with an invite pin the owner must equal it, WITHOUT a pin it is trust on
   first use (comment `:132-135` "residual R1") and the snapshot's owner becomes the pin (`:153`).
   The sender is never checked.
5. **Timing.** Any time a pending join exists (parked: days); buffered for absent joiners.
6. **Replay.** No nonce (`requested_at` not carried); last one wins while pending.
7. **Sessions.** None between joiner and admitter.
8. **Metadata.** Full `ServerState` JSON in plaintext.
   Note: a pending join created by `SiblingServerAnnounce` carries `owner_pin: None`
   (`node/swarm.rs:10179-10183` `..Default::default()`), including for a server we already hold, so
   P-01 can REPLACE an existing Legacy server's state with one it owns; later genuine owner
   checkpoints are then refused (`crdt/server_state.rs:1750-1754`, anchor owner mismatch).
   CONFIRMED-BY-READING for the Rust steps.

### CrdtOpBroadcast (`crdt_op`)

1. **Send.** Plaintext twin sent UNCONDITIONALLY next to the MLS copy: `node/sync_handler.rs:74-92`
   (`broadcast_crdt_op_to_members`, 0x04 per member device unless the WebRTC gossip mesh took it),
   `:138-160`, `:166-186` (+ own-sibling fan), `:344-364` (removal ops), `:1149-1165` (server delete),
   `node/swarm.rs:9081-9097` (auto-pledge), `:9578-9599` (MemberAdded to room peers), `:6247-6262`
   (every receiver re-floods each NEW admitted op once). Also carried in `ServerJoinResolved.op_json`
   (~join ring) and injected from the WebRTC gossip mesh (`node/swarm.rs:2970`, not relay).
2. **Receive.** `node/swarm.rs:9246-9256` → `apply_remote_crdt_op` `:6182-6492`. MLS twin
   `MessageEnvelope::CrdtOp` `:10386-10480` → `node/sync_handler.rs:3028-3055`. Olm twin ignored
   `node/swarm.rs:8561`.
3. **Effect.** Ingest, persist (`:6226-6233`), re-flood, UI events per payload, self-eviction durable
   teardown (`:6419-6446`: `server_states.remove`, `delete_server_state`, drop MLS groups, `LeaveRoom`),
   `ServerDeleted` drops the MLS group (`:6318-6329`), `ChannelPublicChanged` re-broadcasts
   `PublicChannelConfigChanged` into the room (`:6378-6410`), subgroup reconcile + voice auto-leave
   (`:6451-6489`).
4. **Authorisation.** F6 on the op's author; relay `from` deliberately unused (`:6213-6218` "Log
   author mismatch but don't reject"). Server id is inside the signed op.
5. **Timing.** Live 0x04 (F5 buffering), plus the ~join ring inside `ServerJoinResolved` (days).
6. **Replay.** Dedup by `(author, hlc)`; out-of-order old ops trigger a rebuild (`ServerUpdated`
   event + `save_server_state` each time, `:6226-6239`); Legacy anchor re-judges against current
   state (see SyncResponse). Cross-server replay refused (`WrongServer`).
7. **Sessions.** MLS group normally exists; plaintext is the deliberate epoch-skew fallback.
8. **Metadata.** Every server op in plaintext (as SyncRequest).

### ServerJoinRequest (`join_request`)

1. **Send.** Live copies, plaintext first-match 0x04 (may land in a DM room): `node/sync_handler.rs:1488-1506`
   (`handle_join_server`, to every peer of the server room), `:1548-1574` (4 s retry),
   `node/swarm.rs:3706-3725` (PeerJoined), `:4360-4380` (RoomMembers), `:10185-10196`
   (`SiblingServerAnnounce` answer, `device_list: None`, `requested_at: 0`). Parked copy: 0x07 into the
   server room's `~join` topic, `node/sync_handler.rs:1216-1243` (`parked: true`, carries the
   joiner's `key_package`), re-deposited every 12 h (`node/swarm.rs:4028-4037`,
   `REDEPOSIT_INTERVAL_MS` `node/types.rs:784`).
2. **Receive.** `node/swarm.rs:9257-9742` only.
3. **Effect.** Ingests the carried device list (`:9298-9306`, resolver + device store writes,
   revocation enforcement). Gates may send `ServerJoinRejected` + publish a `ServerJoinResolved`
   into the ring and write `join_resolutions` (`:9402-9540`). Admission: `author_checked(MemberAdded)`
   authored and signed by US (`:9549-9556`), persisted (`:9563-9568`), broadcast MLS + plaintext
   (`:9578-9599`), `MemberJoined`. Parked + KeyPackage: may create the MLS group (owner) and queue the
   KeyPackage for the batch commit + Welcome (`:9633-9683`). Always: plaintext `ServerStateSnapshot`
   (Legacy) and the FULL op log to the sender in the server room (`:9694-9716`), ring resolution
   (`:9721-9729`), KeyRequest (`:9731-9740`).
4. **Authorisation.** Server held (`:9263`). Carried list, when present: `verify_device_list`, the
   relay-stamped sender device must be listed and not revoked (`:9281-9311`); absent list →
   `super::resolver::resolve(&peer_str)` (`:9316`). The request itself carries NO signature: nothing
   binds `server_id`, `requested_at`, `nsfw_confirmed`, `twitch_proof_json` or `parked` to the joiner.
   Sibling fast path `same_identity(peer_str, local) && peer_str != local` skips ban/Twitch/owner-verify/
   private/NSFW (`:9324-9325`). Live copies: coordinator election bypassed by a repeat within 12 s
   (`:9369-9396`). Parked: `already_member` return, `join_resolutions` (RAM) max check (`:9340-9350`).
   Receivers re-judge the resulting op (E7 `admission_allowed`, `crdt/server_state.rs:1713-1732`: ban,
   private, cap, owner-verify, Twitch). The parked KeyPackage must be bound to the sender device and
   `member_master` (`:9638`), so P-01 cannot seat its own leaf.
5. **Timing.** Live copies live (F5 buffering); parked copy up to the ring retention (3 d default, up
   to 7 d, re-deposited every 12 h).
6. **Replay.** Live copies have NO freshness: a replayed genuine request (P-01 holds every plaintext
   copy and the signed device list) re-admits a user who has since LEFT, on any non-private server
   where they are not banned. Parked copies are skipped only while `join_resolutions` (RAM, lost on
   restart) or a still-retained ring resolution remembers them.
7. **Sessions.** None: the joiner is a stranger to the admitter (KeyRequest only after admission).
8. **Metadata.** Server id, joiner device + master-signed device list (device↔master link), NSFW
   consent, Twitch follow credential (channel, age bucket, tier bound to the master), request time,
   KeyPackage (credential visible). The reply leaks the whole server state and op log.
   CONFIRMED-BY-READING: P-01 can forge a live request with `from` = victim device and the victim's
   public signed list; the coordinator admits the victim's master against their will (candidate A4).

### ServerJoinRejected (`join_rejected`)

1. **Send.** `node/sync_handler.rs:1389-1412` `send_join_rejection`: 0x04 into the server room to the
   joiner device (relay-buffered), plus a ring `ServerJoinResolved` for non-interactive reasons.
2. **Receive.** `node/swarm.rs:9816-9834` only.
3. **Effect.** `handle_join_refused` (`node/sync_handler.rs:1321-1379`): removes the pending join,
   `LeaveRoom`, deletes or upserts the pending row as "rejected", emits `TwitchJoinRejected` /
   `PendingJoinUpdated`, discards the join KeyPackage.
4. **Authorisation.** NONE on the sender. Only a pending join (`:9821`) and
   `if requested_at != 0 && requested_at != pending.requested_at` (`:9826`): `requested_at: 0`
   ("0 = a pre-nonce client", `node/types.rs:1520`) refuses whatever is pending.
5. **Timing.** Buffered for an absent joiner (F5).
6. **Replay.** Nonce-bound only when non-zero; P-01 sends `requested_at: 0` or copies the nonce from
   the plaintext request/ring.
7. **Sessions.** None (joiner is a stranger).
8. **Metadata.** Server id, reason (includes server name, Twitch channel id/name, member cap).
   Relay alone cancels any pending join (candidate A5 / S-07, still open).

### ServerJoinResolved (`join_resolved`)

1. **Send.** `node/sync_handler.rs:1250-1274` (0x07 into `~join`), from admission (`node/swarm.rs:9721-9729`)
   and rejection (`node/sync_handler.rs:1407-1411`).
2. **Receive.** `node/swarm.rs:9747-9814` only.
3. **Effect.** Joiner side: `handle_join_refused` (as above) when `!admitted` (`:9755-9774`). Member
   side: `join_resolutions` max-wins (`:9793-9799`), carried `op_json` through `apply_remote_crdt_op`
   (`:9804-9813`).
4. **Authorisation.** Joiner side: NONE on the sender, only `joiner_master == local_peer_str &&
   requested_at == pending.requested_at` (`:9756`; the comment `:9766-9768` concedes "a hostile member
   could write one"). Member side: `resolve(&peer_str)` must be a CRDT member (`:9783-9791`), i.e. the
   relay `from`. The carried op: F6.
5. **Timing.** Ring retention (days), re-read on every connect (`node/swarm.rs:4006-4021`).
6. **Replay.** Joiner side exact nonce; the nonce is readable in the parked request. Member side:
   `requested_at: i64::MAX` from any member id freezes that joiner's parked requests on this member
   until restart (and again after restart while the ring holds it) (S-06, still open).
7. **Sessions.** None with the joiner; members share MLS but this rides a relay ring by design.
8. **Metadata.** Server id, joiner master, request time, admitted/reason, the MemberAdded op.

### ServerDeleteBroadcast (`server_delete`)

1. **Send.** NONE in current code (grep: no construction; deletion rides the CRDT `ServerDeleted`
   op, `node/sync_handler.rs:1087-1179`). MLS twin `MessageEnvelope::ServerDelete` likewise has no
   sender outside a test (`node/crypto_handler.rs:6200`).
2. **Receive.** `node/swarm.rs:9835-9877`. MLS twin `:10482-10489` → `node/sync_handler.rs:3173-3212`
   (sender = leaf master, owner only). Olm twin ignored `node/swarm.rs:8564`.
3. **Effect.** `state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms })` + `apply_op`
   (`:9860-9861`), `insert_crdt_op` + `save_server_state` (`:9862-9867`), drop MLS group, emit
   `ServerDeleted`. The op is authored and signed by THIS node's master (F6) and bypasses `op_allowed`.
4. **Authorisation.** `state.get_role(&peer_str) != Owner` → reject (`:9840-9845`). That is the relay
   `from` resolved to a master (F3). No signature, no timestamp, no self check (F2).
5. **Timing.** Live (0x03/0x04) or any time the relay chooses; no legitimate sender exists.
6. **Replay.** Idempotent once `is_deleted()` (`:9855`); no nonce.
7. **Sessions.** Members hold MLS and Olm; the only legitimate lane (CRDT op) is signed.
8. **Metadata.** Server id.
   CONFIRMED-BY-READING, CRITICAL: P-01 sends `ServerDeleteBroadcast{S}` to the OWNER's own device with
   `from` = any owner device id or the owner's master id. `get_role` = Owner, so the owner's node
   mints a genuine owner-signed `ServerDeleted` op, logs and persists it (`apply_op` →
   `log_admitted`, `crdt/server_state.rs:769`), and then serves it to every member through the
   plaintext SyncRequest delta (`node/swarm.rs:8823`), where `op_allowed` admits it
   (`crdt/server_state.rs:1696` `CrdtPayload::ServerDeleted { .. } => role == MemberRole::Owner`).
   Result: the relay alone deletes any server for everyone, irreversibly. Sent to a non-owner member it
   tombstones locally with an op signed by that member (other replicas refuse it; whether a later
   `fold_in` rebuild undoes the local tombstone is UNTRACED).

### MemberKickBroadcast (`member_kick`)

1. **Send.** `node/sync_handler.rs:1672-1683` (kick) and `:1945-1949` (ban): plaintext 0x04 to every
   online device of the target via `send_raw_to_identity`. The kick ALSO sends an Olm
   `MessageEnvelope::MemberKick` (`:1674-1682`) that the Olm receiver ignores (`node/swarm.rs:8565`).
2. **Receive.** `node/swarm.rs:9879-9918`. MLS twin `:10491-10498` → `node/sync_handler.rs:3216-3249`
   (no current MLS sender).
3. **Effect.** `server_states.remove(&server_id)`, `store.delete_server_state` (state + op rows),
   drop the server MLS group, emit `ServerDeleted` (`:9904-9917`). No `LeaveRoom`, subgroups kept, the
   CRDT still lists us.
4. **Authorisation.** Relay `from` resolved: KICK_MEMBERS permission and `sender_role.outranks(&our_role)`
   (`:9884-9897`). No binding to an actual `MemberRemoved`/`MemberBanned` op, no signature, no nonce.
5. **Timing.** Live 0x04, relay-buffered for absent devices (F5).
6. **Replay.** None; a replay after rejoining kicks again.
7. **Sessions.** Kicker and target share MLS and usually Olm; the Olm twin is sent and dropped.
8. **Metadata.** Server id + target device ids (who is being kicked/banned).
   Relay alone makes any lower-ranked member delete a server locally (candidate A3, still open).

### ChannelSyncRequest (`ch_sync_req`)

1. **Send.** Plaintext first-match 0x04: sync coordinator `node/swarm.rs:5355-5381`; after a Welcome
   `:6599-6615`; MLS decrypt `Stale` `:10836-10857`; batch commit `:5121-5140`; on channel open to
   every member device `node/sync_handler.rs:2716-2744`; Olm-batch pagination `node/swarm.rs:7199-7206`.
   Builder `node/sync_handler.rs:582-598`. MLS twin `ChannelSyncReq` is sent only over Olm by the MLS
   batch pagination (`node/sync_handler.rs:3410-3427`) and the Olm arm ignores it
   (`node/swarm.rs:8568`), so that pagination leg is dead (observation).
2. **Receive.** `node/swarm.rs:9920-9965`. MLS twin `:10561-10569` → `node/sync_handler.rs:3336-3373`.
3. **Effect.** DB read, `build_channel_sync_batch` (`node/sync_handler.rs:600-654`), reply
   Olm-encrypted to `peer_str` (`:9958-9962`); on no session `send_encrypted_message` emits
   `MessageSendFailed` (`node/crypto_handler.rs:2853-2859`).
4. **Authorisation.** `channel_readable_by(state, peer_str, &channel_id)` (`:9929`,
   `node/crypto_handler.rs:2222-2230`: member-or-public AND `can_see_channel`) on the relay `from`;
   2 s dedup per (peer, channel) (`:9939-9943`).
5. **Timing.** Live (F5 buffering).
6. **Replay.** Re-served each time outside the 2 s dedup; the answer is Olm to the named device, so a
   spoofed `from` gets no plaintext, only work and ratchet advance.
7. **Sessions.** Requester and responder are members with MLS and usually Olm; plaintext is the
   deliberate epoch-skew path.
8. **Metadata.** Server, channel (restricted included), per-sender watermarks (who posted there, last
   time) and gap digest (candidate J8).

### SiblingServerAnnounce (`sib_server_announce`)

1. **Send.** `node/sync_handler.rs:720-726` (new server, `fan_to_own_siblings` 0x04 first-match);
   `node/swarm.rs:304-320` (`on_verified_sibling`, 0x04 in our own `inbox:` room); `:12055-12069`
   (answer to `SiblingStateSyncRequest`).
2. **Receive.** `node/swarm.rs:10151-10197` only.
3. **Effect.** Inserts `PendingJoin { twitch_proof_json: None, nsfw_confirmed: true, ..Default::default() }`
   (`:10179-10183`, so `owner_pin: None`, `requested_at: 0`) for the named server id, even one we
   already hold (`:10169-10175` "ALWAYS run the inline join flow"), `JoinRoom`, and sends a
   `ServerJoinRequest` to the sender.
4. **Authorisation.** `super::resolver::same_identity(&peer_str, local_peer_str)` (`:10155`), i.e. the
   relay `from` = any of our own device ids or our master id itself (F2, no `!= local` check here).
   Skips if already pending or tombstoned (`:10161-10168`). No signature (a sibling holds our master
   key, but nothing is signed).
5. **Timing.** Live 0x04 (F5 buffering).
6. **Replay.** Unbounded; each copy re-creates the pending join.
7. **Sessions.** Siblings normally share an Olm session; no encrypted twin exists.
8. **Metadata.** Every server id we belong to, sent to our sibling device ids (the relay learns our
   server list; it already sees our room joins).
   CONFIRMED-BY-READING: P-01 stamps `from` = our own id and then (a) for a server it created itself
   (genesis id, it holds the key), serves a SyncResponse with a `MemberAdded` for us: the join
   completes with no user action (`ServerJoined`, room join, auto-pledge op in our name, KeyPackage to
   its "owner"); (b) for a Legacy server we already hold, serves a `ServerStateSnapshot` it owns: our
   state is replaced and pinned to the relay (see ServerStateSnapshot); (c) for any server we hold,
   any replayed op in a SyncResponse completes the fake join and drops our MLS group
   (`node/swarm.rs:9008-9014`). NSFW consent is pre-set to true.

### MlsChannelMessage (`mls_msg`)

1. **Send.** `node/crypto_handler.rs:2685-2712` (`send_mls_broadcast`, 0x03 to the server room: CRDT
   ops, typing, profile, deletes); `:2751-2785` (`send_mls_broadcast_topic`, 0x07 topic = channel id,
   ring-retained when catch-up is on; channel messages, edits, reactions, file headers via
   `node/message_ops.rs:1094-1147`); the same bytes to OFFLINE members as 0x09 with a mention flag
   (`node/message_ops.rs:1187-1241`); `send_mls_to_peer` is dead code (`:2787-2817`).
2. **Receive.** `node/swarm.rs:10201-10898`; push fetch `node/fetch.rs:485-573` (only `ChannelMessage`).
3. **Effect.** Unknown group: mint + send a KeyPackage to the coordinator once per 60 s
   (`:10213-10264`). Decrypted envelope dispatched to the envelope handlers (messages, edits, CRDT ops,
   typing, profiles, sync, vault, voice). `Stale` failure: plaintext `ChannelSyncRequest`s and a
   `SyncRequest` to the relay-stamped `peer_str` plus an epoch probe (`:10830-10895`).
4. **Authorisation.** MLS decryption + bound sender leaf (`Decrypted::UnboundSender` dropped,
   `:10274-10278`); `target` filter (`:10296-10300`); `mls_envelope_fits_group` (envelope must name
   this server/channel, `:10304-10309`, `node/crypto_handler.rs:2721-2739`); voice signals dropped
   unless the leaf device equals the relay `from` (`:10656-10658`). Relay `from` is used for sync
   requests and voice keying only.
5. **Timing.** Live topic/room; ring replay up to retention (F5); 0x09 buffer for the fetch node.
6. **Replay.** `SecretReuseError` → `Decrypted::Replay` → dropped (`crypto/mls_manager.rs:960-962`);
   another group id → `Garbage` (`:963-965`); malformed-in-group → `Stale` → amplification: sync
   requests to whatever `from` P-01 stamps (5 s / 1 s dedup per (group, `from`), `:10837-10867`).
7. **Sessions.** This IS the encrypted lane (MLS); Olm fan-out is the fallback.
8. **Metadata.** Server id, channel id for restricted subgroups (`channel_id: Some`), topic = channel
   id, sender device, size, timing; 0x09 reveals which member devices are offline and whether each was
   mentioned (contradicts the comment at `node/message_ops.rs:1183-1184` "the relay never learns
   membership").

### MlsKeyPackage (`mls_kp`)

1. **Send.** Plaintext 0x04: bootstrap/recovery `node/crypto_handler.rs:2435-2463`, `:2469-2502`,
   `:3341-3351` (rebind), `node/swarm.rs:3659-3675`, `:4196-4218`, `:9148-9181` (after join),
   `:10244-10258` (message for unknown group), `:11279-11292` (answer to a request),
   `node/voice_handler.rs:953-963` (SFrame heal).
2. **Receive.** `node/swarm.rs:10900-11071`, then the batch commit `:5018-5141`.
3. **Effect.** May lazily create the group (`:11036-11045`), queues stale leaves and the SENDER
   device's current leaf for removal (`:11049-11062`), queues the KeyPackage (`:11064-11069`). Next
   tick: one commit (remove + add), Welcome 0x04 to the device (buffered in the server room if absent,
   `:5082-5106`), commit 0x03 broadcast, SFrame rotation event.
4. **Authorisation.** KeyPackage leaf bound (F7) AND `id.device == peer_str` (`:10917-10929`), its
   certified master a CRDT member and not banned (`:10935-10938`), sees the channel for a subgroup
   (`:10939-10944`); coordinator election (`:10976-11034`); `plan_membership` re-checks at commit
   (`node/mls_authority.rs:150-182`). The frame is unsigned but the KeyPackage is signed by the device
   key. P-01 cannot introduce its own leaf under another identity.
5. **Timing.** Live 0x04 (F5).
6. **Replay.** No freshness. A replayed genuine KeyPackage of device D (all are plaintext) with
   `from = D` makes the coordinator remove D's live leaf and re-add the replayed package; if D already
   consumed that package, D is left on a leaf it cannot use until it re-bootstraps. PLAUSIBLE (OpenMLS
   handling of a consumed KeyPackage in a Welcome not traced): relay-driven eviction churn.
7. **Sessions.** Members usually have Olm; the KeyPackage rides plaintext by design (public material).
8. **Metadata.** Device↔master link (credential), server id, and for subgroups WHICH restricted
   channel this member can see.

### MlsWelcome (`mls_welcome`)

1. **Send.** Batch commit `node/swarm.rs:5075-5107` (0x04 first-match, or into the server room by
   name for an absent device, buffered); conferences `node/conference.rs:400-404`.
2. **Receive.** `node/swarm.rs:11073-11139` → `after_welcome_joined` `:6498-6616`.
3. **Effect.** Joins or replaces the group, persists, clears requests; parked join → "ready";
   conference → `pin_committer` to the Welcome's sender master (`:6519-6523`) and
   `NetworkEvent::ConferenceAdmitted` (`:6558-6565`); `MlsEpochChanged` with the new SFrame export;
   plaintext `SyncRequest` + `ChannelSyncRequest`s to the frame's `from` (`:6578-6615`).
4. **Authorisation.** Staged and judged before anything is replaced (`:11087-11120`,
   `node/mls_authority.rs:113-145`): group id matches, our leaf is ours, every leaf bound, none revoked,
   replacing a held group only if we asked (`asked_for_leaf` `:201-219`), server: sender a member and
   no banned leaf. Meeting: `GroupRules::Meeting { host: None }` (`:229-231`) → any bound sender is
   accepted while a knock is pending (`:133-134`). Relay `from` is not used for the verdict.
5. **Timing.** Live, or relay-buffered in the server room for days (parked joins).
6. **Replay.** Our KeyPackage is consumed on success, so a replay fails to process and "clears
   nothing" (`:11132-11136`).
7. **Sessions.** Joiner has no group yet; Welcome is encrypted to the joiner's KeyPackage.
8. **Metadata.** Server/channel id, recipient device, size.
   CONFIRMED-BY-READING (Rust): conference lobby hijack remains open to P-01. The knock's KeyPackage is
   broadcast in plaintext to the conf room (`node/conference.rs:265-272`); P-01 (with any identity of
   its own) builds group `conf:X` with its own bound leaf plus the knocker's package and Welcomes the
   knocker; it is accepted, P-01 is pinned as the meeting's committer, the real host's later Welcome is
   refused (knock cleared, `replaces && !asked`). The SFrame key the knocker uses comes from P-01's
   group. For server groups a substitute Welcome needs a member identity AND the victim in an
   "asked" state (design D residual; PLAUSIBLE, not traced end to end).

### MlsCommit (`mls_commit`)

1. **Send.** Only `broadcast_mls_commit` (`node/crypto_handler.rs:3059-3088`), 0x03 to the server room
   (never buffered), after caching it for catch-up.
2. **Receive.** `node/swarm.rs:11141-11157` → `handle_mls_commit_frame` `node/crypto_handler.rs:3122-3221`.
3. **Effect.** Judged merge (`process_commit_judged`), persist, cache, eviction handling
   (`after_commit_merged` `:3226-3277`), `MlsEpochChanged`; Hold → plaintext `SyncRequest` to
   `frame_sender` (`:3185-3203`); failure → epoch probe, NEVER a group drop (`:3210-3219`).
4. **Authorisation.** `commit_verdict` (`node/mls_authority.rs:51-109`): committer must be a bound
   member leaf; only add/remove proposals; adds bound, not revoked, members; removals only of own,
   unbound, non-member, revoked or re-added leaves; meetings: pinned host only. Relay `from` is only
   logged and used as the Hold sync target.
5. **Timing.** Live only; missed commits come back through `MlsCommitCatchup`.
6. **Replay.** Wire epoch guard skips at/past epochs (`:3151-3157`); an epoch-stripped or re-routed
   replay fails OpenMLS and only triggers a throttled probe.
7. **Sessions.** MLS-authenticated (commit signed by the committer leaf).
8. **Metadata.** Server id, channel id for subgroups (which channels are restricted), epoch, timing of
   membership changes (proposals are ciphertext, F7).

### MlsKeyPackageRequest (`mls_kp_req`)

1. **Send.** `node/crypto_handler.rs:3552-3558` (epoch-hint repair), `:2596-2606` (subgroup
   reconcile), `node/swarm.rs:3645-3658` (PeerJoined, coordinator), `node/voice_handler.rs:935-944`
   (SFrame heal authority). All plaintext 0x04.
2. **Receive.** `node/swarm.rs:11231-11296` only.
3. **Effect.** Mints and persists a KeyPackage (`mint_key_package`, private half stored) and sends it
   plaintext to the sender (`:11279-11289`); records `note_key_request_answered(group, requester_master)`
   (`:11291`), which makes that master's next Welcome "asked" for 120 s.
4. **Authorisation.** Server held, not a meeting, no own join pending, we are a member (`:11244-11251`);
   requester master = the bound leaf in our group whose device equals the relay `from`, else
   `resolve(peer_str)` (`:11252-11255`), must be a member, not banned (`:11256-11259`); subgroup: we
   must see the channel; while we hold a leaf only the owner, our catch-up responder or the subgroup
   coordinator (`may_repair_our_leaf`, `node/crypto_handler.rs:3391-3404`); one answer per group per
   10 s (`KEY_PACKAGE_ANSWER_GAP` `node/swarm.rs:11`). All keyed on the relay `from`.
5. **Timing.** Live (F5).
6. **Replay.** Only the 10 s gap. P-01 stamps `from` = the owner's device: we answer, the package goes to
   the relay in plaintext; replayed to the owner as an `MlsKeyPackage` from our device it forces a
   one-commit repair of our leaf. Every answer grows persisted MLS storage.
7. **Sessions.** Members usually have Olm; this is plaintext by design (stale-epoch path).
8. **Metadata.** Server/channel id: which restricted channel the requester thinks we qualify for.

### MlsEpochProbe (`mls_epoch_probe`)

1. **Send.** `send_epoch_probe` (`node/crypto_handler.rs:3574-3615`), plaintext 0x04 to the group
   authority (VC join, SFrame heal, failed commits, stale decrypts).
2. **Receive.** `node/swarm.rs:11159-11173` → `handle_epoch_hint(..., direct_probe = true)`.
3. **Effect.** Behind: serve cached commits as `MlsCommitCatchup`; cache miss or `epoch_auth` mismatch
   at equal epoch ("forked"): send `MlsKeyPackageRequest` to the prober → its answer becomes a
   remove + re-add commit (`node/crypto_handler.rs:3511-3560`). Ahead: probe our own authority.
4. **Authorisation.** Conference ids skipped (`:3483-3485`); group held; prober `resolve(from)` must be
   a member (`:3497`); direct probes skip the election (`:3517-3521`); 10 s cooldown per (group,
   master) (`:3522-3527`). `epoch` and `epoch_auth` are unsigned.
5. **Timing.** Live (F5).
6. **Replay.** Only the cooldown. P-01 stamps `from` = Bob's device with `epoch: 0` or a wrong
   `epoch_auth`: the owner asks Bob for a KeyPackage and Bob, seeing the owner, answers; one epoch
   bump for the whole group and an SFrame rotation every ~10 s per target. No group is dropped any more
   (S-20 downgraded to churn, still open).
7. **Sessions.** Plaintext by design (the prober's MLS is assumed stale).
8. **Metadata.** Server/channel id, epoch, digest of the epoch authenticator.

### MlsCommitCatchup (`mls_commit_catchup`)

1. **Send.** `node/crypto_handler.rs:3529-3544`, plaintext 0x04 to the stale member.
2. **Receive.** `node/swarm.rs:11175-11229`.
3. **Effect.** Each frame through `handle_mls_commit_frame` (judged), max 16, strictly own+1.
4. **Authorisation.** Sender `same_identity(m, peer_str)` with a CRDT member (`:11179-11185`, relay
   `from`); group held; per-frame judged commit (F7).
5. **Timing.** Live.
6. **Replay.** Epoch chaining: already-applied frames skip, gaps stop, garbage fails without a drop.
7. **Sessions.** Commit bytes are the same ones already broadcast.
8. **Metadata.** Epochs and commit ciphertexts (already seen on 0x03).

### ConferenceJoinRequest (`conf_join_req`)

1. **Send.** `node/conference.rs:236-273` and re-knock `:112-146`: 0x03 `SendToRoom` to `conf:{id}`
   with a fresh KeyPackage each time.
2. **Receive.** `node/swarm.rs:13198-13205` → `node/conference.rs:296-364`.
3. **Effect.** Wrong code → `ConferenceJoinDenied`; else `ConferenceLobbyInfo` to the knocker; waiting
   room off → `admit_peer` (MLS add + Welcome + commit + SFrame rotation, `:369-417`); on → overwrite
   `host_state.pending[sender]` and emit `ConferenceJoinRequestReceived` (`:358-363`).
4. **Authorisation.** Host of an active meeting (`:311`); not ourselves (`:312`, master vs device
   compare); blocklist (`:314`); KeyPackage leaf bound to the relay `from` device (`:321-329`); access
   hash equality (`:333-341`). `display_name` and `avatar_hash` are unsigned.
5. **Timing.** Live.
6. **Replay.** None. `derive_access_hash` is `sha256("{conf_id}:{code}")` (`:52-58`) and rides every
   knock in plaintext, so P-01 can replay it to knock with its own identity (auto-admitted when the
   waiting room is off) and can show the host any display name and avatar hash (S-26 still open;
   S-27 KeyPackage swap closed by binding).
7. **Sessions.** None (joiner is a stranger).
8. **Metadata.** Conf id (the room name), display name, avatar hash, access hash, KeyPackage.

### ConferenceJoinDenied (`conf_join_denied`)

1. **Send.** `node/conference.rs:335-339` (wrong code), `:439-453` (host deny), 0x04 in the conf room
   (relay-buffered if the knocker left).
2. **Receive.** `node/swarm.rs:13206-13209`.
3. **Effect.** `clear_pending_knock` (so a later Welcome is no longer "asked"), event → Dart
   `onDenied` sets `lobbyStatus: denied` (`lib/src/core/providers/conference_provider.dart:578-584`).
4. **Authorisation.** NONE in Rust or Dart (Dart checks only active conf and not host).
5. **Timing.** Live; buffered up to 24 h (F5) despite the module doc "Live-only: nothing rides topic
   rings or the offline buffer" (`node/conference.rs:13-14`).
6. **Replay.** Unbounded.
7. **Sessions.** None.
8. **Metadata.** Conf id, reason.

### ConferenceLobbyInfo (`conf_lobby`)

1. **Send.** `node/conference.rs:345-350`, 0x04 in the conf room.
2. **Receive.** `node/swarm.rs:13210-13214` emits `host_peer_id: peer_str`.
3. **Effect.** Dart `onLobbyInfo` sets `hostPeerId`, `hostName`, `hostAvatarHash` from ANY sender, last
   wins (`conference_provider.dart:559-567`). That value is what `onEnded`/`onKicked` trust. It is not
   reconciled with the Rust-pinned committer (`node/swarm.rs:6519-6523`).
4. **Authorisation.** NONE.
5-6. **Timing / replay.** Live, buffered (F5); unbounded.
7. **Sessions.** None.
8. **Metadata.** Host display name and avatar hash, host device id.

### ConferenceChat (`conf_chat`)

1. **Send.** `node/conference.rs:504-529`, MLS ciphertext, 0x03.
2. **Receive.** `node/swarm.rs:13215-13219` → `node/conference.rs:533-565`.
3. **Effect.** `ConferenceChatMessage` (RAM), attributed to `sender.device` (leaf).
4. **Authorisation.** MLS decrypt under `conf:{id}`; attribution by the bound leaf (F7).
5-6. **Timing / replay.** Live; `decrypt` refuses secret reuse (error path, `:549-555`).
7. **Sessions.** MLS (the group itself may be a P-01 substitute, see MlsWelcome).
8. **Metadata.** Conf id, sizes, timing.

### ConferenceEnded (`conf_ended`)

1. **Send.** `node/conference.rs:218-221`, 0x03.
2. **Receive.** `node/swarm.rs:13220-13227`, comment "Anyone in the room could send this; Dart validates".
3. **Effect.** Dart `onEnded` leaves voice, `conferenceLeave`, clears chat (`conference_provider.dart:588-605`).
4. **Authorisation.** Dart: `sameIdentity(byPeerId, state.hostPeerId ?? own id)`; `hostPeerId` is the
   spoofable LobbyInfo value, so P-01 sends LobbyInfo then Ended (S-31, open).
5-6. **Timing / replay.** Live; unbounded.
7. **Sessions.** Participants share the MLS group; no encrypted twin.
8. **Metadata.** Conf id.

### ConferenceKicked (`conf_kicked`)

1. **Send.** `node/conference.rs:488-489`, 0x04 in the conf room (buffered).
2. **Receive.** `node/swarm.rs:13228-13236`.
3. **Effect.** Dart `onKicked` leaves (`conference_provider.dart:623-641`).
4. **Authorisation.** Dart only; the check is SKIPPED when `hostPeerId` is null or empty (`:626-629`),
   otherwise compared with the spoofable LobbyInfo host (S-32, open).
5-6. **Timing / replay.** Live, buffered; unbounded.
7. **Sessions.** As Ended.
8. **Metadata.** Conf id, target device.

### ChannelNotificationHint (`notif_hint`)

1. **Send.** `node/message_ops.rs:897-914`, 0x03 `SendToRoom` for every channel post, restricted
   channels included.
2. **Receive.** `node/swarm.rs:12612-12637`.
3. **Effect.** `NetworkEvent::ChannelNotificationHint` → Dart unread + mention badge
   (`lib/src/core/providers/event_provider.dart:1084-1126`, `unreadProvider.onChannelMessage(... isMention)`).
4. **Authorisation.** Not our own identity; `channel_signal_accepted(state, &resolve(peer_str), ...)`
   (`:12618-12623`, `node/message_ops.rs:2732-2741`: sender may post in the channel, we may see it) on
   the relay `from`. Unsigned.
5. **Timing.** Live only (0x03).
6. **Replay.** Dart dedups by `message_id` (`event_provider.dart:1106`); P-01 picks fresh ids.
7. **Sessions.** The post itself rides MLS; the hint has no encrypted twin.
8. **Metadata.** Server, channel, message id, `has_everyone`, mentioned display names, replied-to
   author MASTER (candidate J9). P-01 can forge unread/mention badges in any member's name.

### TypingIndicator (`typing`)

1. **Send.** `node/social.rs:940-1028`: DM → 0x04 in the DM room to each recipient device; channel →
   MLS `Typing` plus the plaintext copy to leaf-less member devices (`:1015-1025`).
2. **Receive.** `node/swarm.rs:12639-12669`; MLS twin `:10500-10515`.
3. **Effect.** `NetworkEvent::TypingStarted` (typing dot in a DM thread or channel).
4. **Authorisation.** Not revoked, not blocked (`:12643`); channel: `channel_signal_accepted` on
   `resolve(peer_str)` (`:12650-12659`); DM (empty `server_id`): NOTHING else, no friend check.
5-6. **Timing / replay.** Live; unbounded.
7. **Sessions.** Channel members have MLS (twin exists); DM friends have Olm (no Olm twin).
8. **Metadata.** Who types where and when (DM pair, server/channel).

### StatusUpdate (`status_update`)

1. **Send.** `node/social.rs:1032-1053`: plaintext 0x04 to every peer in every room we share.
2. **Receive.** `node/swarm.rs:12671-12677`.
3. **Effect.** `PeerStatusChanged { peer_id: peer_str, status }` → Dart marks the device invisible or
   online (`event_provider.dart` `invisiblePeersProvider.setInvisible/setOnline`).
4. **Authorisation.** NONE: relay `from`, any status string.
5-6. **Timing / replay.** Live; unbounded.
7. **Sessions.** Friends have Olm, members MLS; the MLS `ProfileUpdate` twin carries `is_invisible`.
8. **Metadata.** Invisible-mode toggles, sent to every co-roomed peer (the relay learns them).

### PublicChannelMessage (`pub_ch_msg`)

1. **Send.** `node/message_ops.rs:846-863` and `node/file_handler.rs:1629-1659` via
   `send_public_channel_msg` (`node/message_ops.rs:1066-1083`): 0x03 AND 0x07 topic (ring-retained),
   plus 0x09 to offline members (`:917-921`).
2. **Receive.** `node/swarm.rs:12141-12192`; push `node/fetch.rs:574-635`.
3. **Effect.** Stores the row (dedup by mid), emits `ChannelMessageReceived`; guest: file card event
   from `file_meta` (`:12169-12191`).
4. **Authorisation.** Not ourselves; `public_frame_accepted` (channel public in OUR state, or viewing
   as guest; `node/message_ops.rs:2747-2761`); v2/v3 signature by the resolved master over
   `"ch"`, `"{sid}:{cid}"`, ts, mid, reply_to, file_id, order_us, lp digest, album, text
   (`:2610-2631`, `node/crypto_handler.rs:267-291`), 10 min future bound; live post gate
   (member, visibility, posting, mute, media-only, slow mode) (`:2638-2726`). `file_meta` is unsigned
   except `fid == file_id`.
5. **Timing.** Live, ring replay (days), 0x09 buffer.
6. **Replay.** Dedup by mid; the signature binds server and channel.
7. **Sessions.** Deliberately plaintext (guests have none).
8. **Metadata.** Full content, author master, server/channel, reply graph, link cards.

### PublicChannelEdit (`pub_ch_edit`)

1-2. `node/message_ops.rs:1379-1385` (0x03 + 0x07); receive `node/swarm.rs:12194-12210` →
   `node/message_ops.rs:2831-2893`.
3. `edit_channel_message` + `ChannelMessageEdited`.
4. Mute gate; row must belong to the resolved signer (`change_may_touch_row`, `:2857-2858`); v2
   signature over the new text with OUR row's extras (`:2863-2871`).
5-6. Live/ring; an older edit is refused (`storage/messages.rs:3292-3297` "an older one replayed ...
   would put back text").
7-8. Plaintext by design; content visible.

### PublicLinkPreviewSet (`pub_lp_set`)

1-2. `node/message_ops.rs:1848-1858`; receive `node/swarm.rs:12212-12228` →
   `node/message_ops.rs:2904-3002`.
3. `update_channel_link_preview_and_sig` + `ChannelLinkPreviewUpdated`.
4. Author = resolved `from`, must own the row; signature over the CURRENT row text with the new card
   digest and the ORIGINAL message `ts` (`:2957-2976`).
5-6. Live/ring. No ordering: `ts` is the original message time, so every card change of a message has
   the same `ts`, and `update_link_preview_and_sig_in` (`storage/messages.rs:1484-1493`) applies any
   verifying copy. P-01 can replay an older card (or clear) to flip a card back while the text is
   unchanged.
7-8. Plaintext by design.

### PublicChannelDelete (`pub_ch_del`)

1-2. `node/message_ops.rs:2063-2068`; receive `node/swarm.rs:12230-12246` →
   `node/message_ops.rs:3007-3053`.
3. `hide_channel_message` + `ChannelMessageDeleted`.
4. Row owner = resolved signer; `"ch-delete"` signature over the current text and extras.
5-6. Live/ring; idempotent.
7-8. Plaintext by design; reveals which message was deleted and when.

### PublicChannelAddReaction / PublicChannelRemoveReaction (`pub_ch_react` / `pub_ch_unreact`)

1-2. `node/message_ops.rs:2228-2233`, `:2388-2393`; receive `node/swarm.rs:12248-12282` →
   `node/message_ops.rs:3138-3191`, `:3240-3273`.
3. `add_reaction` / `remove_reaction` + events.
4. Add: valid emoji, member (when we hold the server), mute gate, signature `reaction:{mid}:{emoji}:{ts}`
   by the resolved master (`:3218-3235`), target in that channel. Remove: signature only.
5. Live/ring (days).
6. Adds signed at or before a recorded removal are refused (`storage/messages.rs:3587-3596`). Removal
   has NO ordering: `DELETE FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3`
   (`:3623-3629`), so P-01 replaying an OLD signed unreaction deletes a LATER re-add.
7-8. Plaintext by design; who reacted with what.

### PublicChannelListRequest (`pub_ch_list_req`)

1. **Send.** `node/swarm.rs:1876-1882` (guest browse) and `:3188-3201` (reconnect), 0x03 to the server
   room.
2. **Receive.** `node/swarm.rs:12286-12323`.
3. **Effect.** Every member replies 0x04 in the server room with name, public channel list, avatar
   and banner thumbnail (`:12306-12320`).
4. **Authorisation.** Not ourselves; by design anyone.
5-6. Live; unbounded (N replies per request).
7. None (guest).
8. Guest's interest in a server id; server name/avatar/public channel names.

### PublicChannelListResponse (`pub_ch_list_resp`)

1. Send: `node/swarm.rs:12306-12320`.
2. Receive: `node/swarm.rs:12462-12487`.
3. `PublicChannelListReceived` (guest browser UI).
4. Only `guest_rooms.contains(&server_id)` (`:12464`) and a banner size cap; NOTHING signs name,
   channels, avatar or banner. P-01 can show a guest any server name, channel list and images.
5-6. Live; unbounded.
7-8. None; public data.

### PublicChannelSyncRequest (`pub_ch_sync_req`)

1. Send: `node/swarm.rs:1977-1985`, 0x03 to the server room.
2. Receive: `node/swarm.rs:12325-12460`.
3. Every member serves up to 50 messages with reactions, file metadata, deletion proofs and
   `sender_profiles` (nickname or display name + avatar thumbnail), 0x04 to the requester.
4. Channel public in our state (`:12328`); 2 s dedup per (peer, channel). By design anyone.
5-6. Live; amplification per member.
7. None.
8. Public content plus unsigned profile names/avatars of posters.

### PublicChannelSyncResponse (`pub_ch_sync_resp`)

1. Send: `node/swarm.rs:12442-12456`.
2. Receive: `node/swarm.rs:12489-12561`.
3. `PublicChannelSyncReceived` (guest view, RAM).
4. `guest_rooms` only; per item: content signature (`node/message_ops.rs:199-232`, absent refused,
   `node/crypto_handler.rs:1957`, `:1983-1989`), hidden-flag proof else stripped, reactions verified,
   `file_meta.fid == file_id`. `sender_profiles` (names, avatars) are unsigned.
5-6. Live. P-01 can withhold items, serve a pre-edit original (it holds every plaintext copy), strip
   a deletion proof so a deleted message reappears for the guest, and attach any display name/avatar.
7-8. None; public content.

### PublicChannelConfigChanged (`pub_ch_config`)

1. **Send.** `node/sync_handler.rs:2597-2610` (author), `node/swarm.rs:6385-6400` and
   `node/sync_handler.rs:3109-3124`: EVERY member that ingests a `ChannelPublicChanged` op re-broadcasts
   0x03, also when a channel is made private (name and category included).
2. **Receive.** `node/swarm.rs:12563-12569`.
3. **Effect.** `PublicChannelConfigChanged` event for guests only.
4. **Authorisation.** `guest_rooms` only; unsigned (the underlying CRDT op is signed but not carried).
5-6. Live; unbounded.
7. None for guests; members hold MLS.
8. Channel name, category, public/private flip.

---

## MessageEnvelope twins (types.rs:3148-3265)

| Twin | Sent over | Received over | Status |
|---|---|---|---|
| `CrdtOp` | MLS (`node/sync_handler.rs:151-156`, `node/swarm.rs:9082-9088`, `:9580-9586`) | MLS `node/swarm.rs:10386`; Olm ignored `:8561` | live, signed op |
| `ServerDelete` | none (test only, `node/crypto_handler.rs:6200`) | MLS `:10482` (owner leaf only); Olm ignored | dead |
| `MemberKick` | Olm (`node/sync_handler.rs:1674-1682`) | MLS `:10491`; Olm IGNORED `:8565` | sent but dropped |
| `Typing` | MLS (`node/social.rs:1009-1014`) | MLS `:10500`; Olm ignored | live |
| `SyncReq` | none | MLS `:10544` | dead |
| `SyncResp` | Olm (reply to dead SyncReq, `node/sync_handler.rs:3274-3282`) | MLS `:10553`; Olm ignored `:8563` | dead |
| `ChannelSyncReq` | Olm (MLS-batch pagination, `node/sync_handler.rs:3416-3426`) | MLS `:10561`; Olm ignored `:8568` | pagination leg dropped |

---

## Relay-originated inputs in this area

JSON `ServerMsg` (`node/ws_client.rs:269-303`) mapped by `handle_server_message` (`:1220-1324`) with no
authentication beyond the TLS socket. Effects in `node/swarm.rs`:

- **`peer_joined`** (`:3306-3753`): adds any id to `ws_room_peers` (`:3308`). For a non-fwd room and a
  new id it runs the discovery cascade to that id: signed profile announce (`:3547-3553`), auto-DL
  pref, sibling challenge if the room is our own inbox (`:3571-3586`), Olm KeyRequest and queued-frame
  drain (`:3591-3605`), for every server where the id resolves to a member: plaintext `SyncRequest`
  with our state vector and MLS epoch (`:3610-3626`), channel-sync fan-out registration (plaintext
  `ChannelSyncRequest`s with per-sender watermarks, `:3628-3641`, dispatched `:5343-5381`),
  `MlsKeyPackageRequest` if we coordinate and it lacks a leaf, or OUR fresh KeyPackage if we lost the
  group (`:3643-3676`); `DmSyncRequest` (`:3684-3702`); queued friend request/removal/accept drains
  (`:3461-3545`); a pending `ServerJoinRequest` carrying our device list (`:3706-3725`); conference
  re-knock with a fresh KeyPackage (`:3347-3349`); gossip neighbour → `GossipConnect` (WebRTC data
  channel) if the id is a member (`:3439-3446`); VC presence re-announce if it may see the channel
  (`:3400-3431`). P-01 can fake a member's presence to harvest all of these and to steer elections.
- **`peer_left`** (`:3764-3887`): removes the id, emits `VoiceChannelLeft` for every voice channel of
  that room (`:3838-3863`), `PeerDisconnected` (`:3870-3874`), drops a conference knocker from the host
  waiting room (`:3793`) and from the conf call roster (`:3796-3799`), gossip neighbour replacement,
  vault rebalance.
- **`members`** (authoritative snapshot, `:3888-4399`): replaces the room set; every vanished id gets
  the `peer_left` treatment (`:3943-3965`) and conference pending entries are swept (`:3915`). It also
  fires relay ring catch-ups (`:3995-4022`), the join-ring re-deposit (`:4024-4037`), the first profile
  broadcast to every listed id (`:4055-4072`), and per listed id the same cascade as `peer_joined`
  plus `ProfileRequestFor` naming up to 10 OFFLINE members of shared servers (`:4130-4159`, reveals
  member ids to whoever answers).
- **Elections read presence only.** `elect_server_coordinator`, `server_bootstrap_target`,
  `group_authority`, `epoch_catchup_responder` use `peer_is_reachable(ws_room_peers, ..)`
  (`node/crypto_handler.rs:2307-2349`, `:3363-3446`). P-01 hides the owner → another member coordinates
  joins and MLS adds; with owner-verify on, members reject Twitch-gated joins as
  `twitch_owner_offline` and publish that refusal into the `~join` ring (`node/swarm.rs:9464-9481`,
  `node/sync_handler.rs:1407-1411`). Offline-member push fan-out also keys on presence
  (`node/message_ops.rs:1202-1210`).
- **`discovered_peers`** (`:4470-4493`): adds ids and sends signed KeyRequests. **`peer_status`**
  (`:4452-4469`): re-joins `dm_room_code(us, resolve(id))` and our inbox for every listed id.
- **Socket close** → `Disconnected` (`:3238-3305`): purges presence, remote voice participants,
  conference waiting rooms, MLS bootstrap/grace/cooldown state, relay catch-up marks.
- **`error` "Too many rooms"** (`node/ws_client.rs:1262-1276`): removes the last-joined room from the
  rejoin set and emits `RoomCapHit`.
- **Ring and buffer replays** arrive as ordinary `WsEvent::Message`/`DirectMessage` (F1); nothing in
  the frame tells a handler that it is a replay, how old it is, or from which room/topic it came. The
  `~join` catch-up is requested with `max_age_secs: 0` ("an old request is exactly the one we want",
  `node/swarm.rs:4016-4020`).
- Out of this area but same class: `SiblingStateSyncRequest` (`node/swarm.rs:12045-12100`) accepts the
  relay `from` = our own id and answers in PLAINTEXT with every server id, our whole accepted friend
  list (`FriendListSync`), personal emotes and read markers.
