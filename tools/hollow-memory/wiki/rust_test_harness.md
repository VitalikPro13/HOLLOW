# Multi-Node Test Harness (headless integration testing)

Source: `rust/hollow_core/src/node/test_harness.rs` (`#[cfg(test)]`)
Design + ladder: `reports/MULTINODE_TEST_HARNESS_HANDOFF.md`, `reports/HARNESS_COVERAGE_MAP.md`

## What it is and why it matters

The harness spins up **N real `spawn_node` event loops in ONE process**, each with its own in-memory
keypairs and its own temp SQLCipher DBs, all wired through an in-process `MockRelay`. No sockets, no
TLS, no network. This lets Claude drive a true multi-device scenario (send DMs, join servers, go
offline/online, revoke devices) and **assert on each node's REAL state + NetworkEvents** — the
automated version of the manual Pixel↔VM↔AL live test.

**This is now the PRIMARY testing method for the distributed-logic core.** Green harness → Vitalik
real-tests the platform/media tail → push. Every multi-device state/event bug (the `mine`-inversion,
the master-vs-device routing misses, the Olm glare deadlock) is the kind of bug this catches
instantly and that was previously found only by Vitalik manually copying logs across three devices.

## Coverage line (the rings)

- **Ring 1 (distributed-logic core)** — DMs, sync, friends, profiles, presence, CRDT servers/channels,
  roles, MLS membership, revocation, Olm. **Harness owns this.**
- **Ring 2 (transport-dependent)** — WebRTC media, file/shard P2P, vault, recovery, real relay.
  **Harness owns the CONTROL/SIGNALING plane only**, not the media/data plane.
- **Ring 3 (platform & presentation)** — Flutter UI, FFI, native push/keychain/installer, real relay
  C++. **Out of harness scope** — Vitalik's manual / Tier-2 pass.

When green, the claim is exactly: "the distributed-logic core + control plane behave correctly across
N devices" — NOT "the whole app works." Full map in `reports/HARNESS_COVERAGE_MAP.md`.

## The production seam (behavior-neutral)

- `run_event_loop` takes `db_path`/`db_passphrase` as **parameters** (no longer derives them from the
  process-global `data_dir()`) — THE key unlock so N nodes in one process don't collide on the single
  default `%APPDATA%/Hollow/messages.db`. Production `spawn_node` derives + passes the same values →
  byte-for-byte identical production behavior.
- `#[cfg(test)] spawn_node_mock(...)` — twin of `spawn_node` that SKIPS `spawn_ws_client` +
  `spawn_signaling_task`, returns `(master_id, JoinHandle, ws_cmd_rx, ws_event_tx)` so the broker
  wires the node in. Signaling is a dead channel pair (non-fatal HTTP fallback, never needed for
  DM/room delivery).

## MockRelay — in-process broker

Mirrors the production relay's load-bearing behavior (the relay is a dumb pipe; all crypto/sync/
ordering lives in the nodes):
- `register(peer, cmd_rx, event_tx)` → drives the node's outbound commands, emits `WsEvent::Connected`.
- `set_online(peer, false)` → drops from rooms + broadcasts `PeerLeft` to others **AND sends
  `WsEvent::Disconnected` to the offline node itself** (mirrors the real WS client on socket drop — the
  event loop relies on `Disconnected` to clear `synced_peers`/`key_request_in_flight`/
  `key_bundle_sent_to`; omitting it leaves peers marked already-synced so the `is_new` reconnect guard
  silently suppresses the proactive DmSyncRequest/key-exchange). `set_online(peer, true)` re-emits
  `Connected` → node re-runs its join flow.
- Routes `JoinRoom` (→ `RoomMembers` + `PeerJoined` + replay offline buffer), `LeaveRoom`,
  `SendToRoom`/`SendToRoomTopic` (→ `Message`, no self-echo), `SendDirect`/`SendDirectImage`
  (→ `DirectMessage` if target online+in-room, else BUFFER for replay-on-join — the load-bearing
  peer-fallback path), `SendBinaryDirect`, `DiscoverPeers`, `CheckPeers`.
- Presence accessors: `online_devices()`, `room_devices(room)` — the authoritative presence source
  (like the real relay's `RoomMembers`).
- **Topic rings (pending joins rung 1, 2026-08-29), mirroring the real relay's `topic_buffers`:**
  `SendToRoomTopic` tees a copy into a `(room, topic)` ring ONLY when it was REGISTERED first
  (`SetTopicBuffer`); an unregistered ring silently drops every publish, exactly like production, so
  "the members registered it while they were here" is a real precondition to test and a real thing to
  wait for. `topic_frames(room, topic)` returns every frame currently in the ring, oldest first, as
  `(sender_device, payload)`, unconsumed. `topic_registered(room, topic)` checks registration alone.
  `inject_topic(room, topic, from, data)` writes a frame straight in as if `from` had published it,
  BYPASSING registration and the sender check: it models a HOSTILE publisher, so the tests that use it
  are exactly the ones proving the RECEIVER refuses the frame on its own merits (a tampered carried
  device list, a forged resolution from a non-member), never because the transport happened not to
  carry it. `set_broadcast_deaf(peer_id, bool)` makes a device deaf to `0x03` room broadcasts while it
  keeps receiving presence + direct frames, the silent-loss lever for proving a plaintext CrdtOp twin
  reaches a member with no readable MLS leaf.

## Inspectors — read state the way the UI does (two layers)

The GAP between the two layers is where multi-device bugs hide, so both exist on purpose:
- **UI layer** (master-collapsed, reads through the SAME resolver/CRDT accessors the Dart providers
  use → a green inspector == a green UI for that state): `TestNode::dm_thread`, `dm_unread`, `servers`
  (mirrors `get_joined_servers`: hides tombstoned shells AND non-empty-membership shells we're no
  longer a member of — the left/kicked legacy-shell filter, 2026-07-02), `member_panel` (master-keyed
  role+online via `ServerState::get_role`, the resolver chokepoint), `channel_messages`,
  `online_identities`/`is_online` (presence read from the relay, collapsed via `resolver::resolve`).
- **Raw layer** (device-keyed underlying truth → assert the invariant beneath the UI when it diverges):
  `raw_crdt_member_keys` (should be MASTER ids; a leaked device id = a `canonicalize_members` bug),
  `MockRelay::online_devices`/`room_devices`.
- **Live crypto (async, via `DebugSnapshot`):** `TestNode::mls_members(sid)` (raw device leaves),
  `mls_epoch(sid)`, `olm_status(device)` ("none"/"unconfirmed"/"confirmed"/"absent"), `debug_snapshot()`.
  These round-trip a `#[cfg(test)] NodeCommand::DebugSnapshot { reply: oneshot }` that the event loop
  answers from its LIVE in-memory `mls`/`olm` (owned by the loop, otherwise unreadable). The variant +
  its dispatch arm are `cfg(test)`-gated so they don't exist in release (the command match has no
  wildcard; production build verified clean). Olm enumeration uses a `cfg(test) OlmManager::
  session_peer_ids()`. Reply struct: `types::DebugSnapshotReply`.

## Helpers + serialization

- `spawn_node_with_friends(relay, master_tag, device_tag, friend_masters)` — in-mem keypairs via
  `NativeKeypair::from_secret_bytes(seed_bytes(tag))`, per-node `tempfile::tempdir()` DB, fresh Olm
  account, **pre-seeds accepted friendships BEFORE connect** so the first `Connected` auto-joins the
  DM rooms (same master_tag across nodes = siblings; distinct device_tag = distinct transport id).
- `wait_event(node, timeout, pred)`, `drain_events(node)`, `sleep_ms(ms)`.
- `test_guard()` — takes `resolver::test_lock()` (the ONE process-wide lock shared with every unit
  test that mutates the global resolver map: resolver::tests, crypto_handler election/device-list
  tests, the server_state accessors-hook test) + `resolver::clear_for_test()`. Harness tests run
  SERIALLY from a clean resolver; the shared lock exists because a unit test's links were being wiped
  mid-assert by a parallel test's `clear_all` (a real intermittent failure, 2026-07-02). ANY new test
  touching the global resolver must hold `resolver::test_lock()`. The guard is held across the whole
  async test (intentional; `#[allow(clippy::await_holding_lock)]`).
- Tests set `HOLLOW_DATA_DIR` to a throwaway tempdir so no stray global-data-dir path touches the
  developer's real `~/.hollow` DB.

## Build ladder (all DONE 2026-06-19)

rung1 inspectors ✅ → rung2 servers+channels+MLS ✅ → rung3 device revocation ✅ → ring-2 control plane
(1:1 call signals, voice channels, file transfer, recovery pool) ✅. Ring 1 fully self-verifiable; the
coverable ring-2 control plane is covered. Coverage line in `reports/HARNESS_COVERAGE_MAP.md`.

**KEY DISCOVERY (file transfer):** the WS-relay binary-streaming fallback works fully in-process —
`stream_to_peer` falls back to `ws_stream_send` (→ `SendBinaryDirect`, which the MockRelay routes
in-room) when there's no WebRTC peer. So file/shard BYTES actually transfer + decrypt + land on disk in
the harness — the data plane over the RELAY path is coverable; only the WebRTC-data-channel-specific
path is out of scope. Inspectors: `TestNode::file_meta(file_id)` (StoredFile row), `missing_file_ids()`.

**Server-join + MLS handshake (rung 2) sequence** (2-node, owner O + joiner J; room code == server_id;
default channel == `{server_id[..8]}-general`, non-public): J `JoinServer` → JoinRoom → relay
`RoomMembers` → J sends `ServerJoinRequest` direct to O → O adds `MemberAdded{J_master}` CRDT op, sends
`ServerStateSnapshot` + `SyncResponse` + `KeyRequest` direct → J adopts snapshot, completes join
(`ServerJoined`), sends `MlsKeyPackage` direct to O → O queues it, **the 2s `mls_batch_timer` fires** →
O `add_members_batch` → `MlsWelcome` direct to J (+ `MlsCommit` to existing leaves) → J `join_from_welcome`
forms its group. **Both leaves at the same epoch.** Then `SendChannelMessage` (non-public) → MLS-encrypt
→ `SendToRoomTopic` (mock treats as room broadcast) → receiver `mls.decrypt` → `ChannelMessageReceived`.
Owner is always the MLS coordinator in 2-node. **Sleep ≥~4-5s after JoinServer** so the batch timer
ticks AFTER the KeyPackage is queued (Welcome only goes out post-queue).

## Testing BACKFILL specifically (2026-08-03)

"Peer goes offline, sender acts, peer returns" does **not** test sync backfill — at least three paths independently rescue that peer, so the scenario passes with a broken backfill. This was caught the hard way while testing the link-preview backfill fix: the first test passed before the fix existed.

The rescuers: the sender's `pending_messages` queue (offline-but-has-session devices get queued, and attach handlers rewrite queued envelopes in place); the MockRelay's per-device offline buffer (`relay.buffered_count(dev)`, replayed on reconnect); and topic catch-up replay from `topic_buffers`.

Use a peer for whom backfill is the ONLY vehicle:
- `backfilled_member_gets_link_preview_through_channel_sync` — a member who JOINS AFTER the content exists. Nothing was ever addressed, queued or broadcast to them.
- `freshly_linked_device_backfills_dm_link_previews_from_its_sibling` — a device that did not exist at send time (`spawn_node_full` with a pre-seeded source-only device list). Seed it into `resolver::seed_self` only AFTER the activity, or the sender queues for it.

Both also assert the synced row VERIFIES against the digest of the card it now holds — the row a peer stores is the row it re-serves, so a row that cannot reproduce its own signed digest silently stops replicating. See [[feedback-backfill-test-isolation]].

## Pending server joins (rung 1, 2026-08-29)

A join into an all-offline server PARKS instead of failing (see `rust_sync_handler.md` /
`rust_swarm_event_loop.md`). Nine new tests, eight in `node/test_harness.rs` plus a wire-pin unit test
in `node/crypto_handler.rs`:

`parked_join_completes_with_zero_overlap`, `parked_join_rejection_reaches_an_offline_joiner`,
`late_member_does_not_reserve_a_parked_join`, `parked_join_redeposit_is_interval_bounded`,
`parked_join_with_a_bad_carried_device_list_is_dropped`, `discarded_parked_join_ignores_a_late_answer`,
`parked_twitch_gated_join_waits_for_co_presence_and_leaks_no_proof`,
`parked_nsfw_join_asks_for_consent_once_then_completes` (all `node/test_harness.rs`), and
`crypto_handler::tests::server_join_wire_is_backward_compatible` (the wire pin: asserts every new
`#[serde(default)]` field on `ServerJoinRequest`/`ServerJoinRejected` plus the new `ServerJoinResolved`
variant round-trips, and that a pre-rung-1 payload with none of the new fields still deserializes).
`parked_join_completes_with_zero_overlap` is honesty-proved: stub out the deposit and "A must admit B
from the ring" fails.

`join_fails_when_every_member_is_offline_then_succeeds_on_retry` was DELETED, since it asserted the
exact behaviour rung 1 replaces (a 15s failure), so it could not coexist with the new one.

**Two load-only races cost a round each, both "queued is not landed":** a node emits its event
(`ServerJoinParked`, or applies `MemberAdded`) the INSTANT the frame is queued on `ws_cmd_tx`; the mock
relay drains that queue on its own task. A test that (a) took the node offline right after the event
lost the still-queued deposit (`handle_command` drops everything from an offline node, exactly like a
dead socket), or (b) read the ring ONCE right after a node-state `wait_until`, failed 2/2 under the
16-way parallel run and passed alone. **Rule now baked into the harness:** after a NODE-state wait, an
assertion on RELAY state is itself a `wait_until`, see `expect_ring_request` / `expect_ring_resolution`
/ `expect_ring_parked_request` above; the mock inspector is a mutex read, so polling it is free.
`expect_relay_drained` is the companion barrier for a NEGATIVE assertion ("nothing was published"),
which only means something once nothing from the handler under test is still in flight: it joins a
throwaway `barrier:{device}:{tag}` room and waits for the relay to confirm membership, since a node's
outbound commands ride one unbounded channel drained by one relay task, in order.

**Sleep budget raised 566s to 572s** for exactly one new sleep that has no pollable signal (an ABSENCE
proof: "the deposit never happens", which cannot be waited FOR). `reject_cancels_own_queued_request_no_refriend`
/ `readd_while_online_requires_fresh_consent` are PRE-EXISTING fixed-sleep flakes, proven failing at
HEAD before this work, unrelated to it.

Fleet cross-check (real app, real relay, zero overlap between the two peers until the very end):
`scripts/fleet_pending_join.ps1`, see `fleet_probe.md`.

## Current tests (13)

Step 9C/9D added 6 more (2026-06-19), each negative-tested where it guards a fix:
- `sibling_recovers_own_channel_messages_from_present_member` (9C/C3) — a fresh-joining sibling recovers its
  OWN identity's channel history from a present member (verify-only: no code needed); also asserts `order_us`
  survives send→A→backfill→sibling with strictly increasing order (9C/C4).
- `moderation_action_converges_on_actor_sibling_without_restart` (9C/C2) — B role-changes then kicks V; B's
  sibling C reflects both WITHOUT restart (sibling moderation fan-out); also asserts a nickname change (with V
  online relaying).
- `sibling_nickname_fans_directly_with_no_relayer` (9D GAP-A) — M's two devices ALONE in a server; a nickname
  change reaches the sibling ONLY via the direct `fan_to_own_siblings` (no other member to re-gossip).
- `linked_sibling_resolves_both_devices_at_startup` (9C/C5) — a freshly-linked sibling resolves BOTH its own
  device + the imported source device → master at startup (so "Your devices" shows two).
- `offline_member_reconciles_server_deletion_on_reconnect` (9D tombstone) — member offline when owner deletes;
  on reconnect the deleted server is GONE (tombstone+grow-only-sync path; the MockRelay doesn't queue the
  removed one-shot). Faithfully negative-tested (owner hard-delete → member keeps server → fails).
- `server_create_auto_onboards_online_sibling` (9D create) — creator makes a server → its online sibling
  auto-onboards (sees it + decrypts a channel message via its new MLS leaf, formed by the sibling-re-add path).

Plus a deterministic `crypto::mls_manager::tests::keystone_regen_rejoins_owned_group_via_sibling_no_fork`
(unit, not harness) proving the keystone-regen sibling-re-add: friend decrypts the regenerated keystone's
message at the same epoch, no fork (must model remove-then-add — old+new leaf share credential).

The original 7:
- `server_join_forms_mls_and_channel_message_decrypts` — owner creates a server, friend joins, MLS group
  forms across both device leaves at the same epoch, owner's MLS-encrypted channel message decrypts on
  the joiner. Asserts every layer: member panel (UI, master-keyed, online) + raw CRDT master-keys + raw
  MLS device-leaves + live epoch + Olm status + decrypted channel row.
- `device_revocation_cuts_off_and_ghost_fanout_holds` — B revokes sibling C: C emits `SelfRevoked`, B
  emits `DeviceListUpdated`, B drops its Olm session to C, and a friend's later DM reaches live B but NOT
  the revoked-and-dropped C (ghost fan-out guard). Helper `seed_device_list_into_db` persists a real
  master-signed v1 device list (the precondition `revoke_own_device` reads).
- `call_signal_routes_to_friend_device_and_drops_unknown` — a 1:1 call invite maps via the whitelist to
  `CallInvite`, routes master→device to the friend's online device, and an unknown signal type is
  silently dropped.
- `dm_file_transfer_completes_and_decrypts` — full DM file send: FileHeader (Olm) + bytes (relay
  fallback) transfer, decrypt, and land on disk with the original contents; files row complete.
- `voice_channel_join_leave_and_signal_routing` — two server members, one joins a Voice channel (the
  other sees it in participants), a broadcast `audio_state` signal routes, unknown VC signal dropped,
  leave removes the participant. Plaintext fallback (no formed MLS needed).
- `recovery_pool_membership_forms` — initiator opens a pool, joiner joins + broadcasts RecoveryHello,
  initiator registers it as a member.
- `peer_fallback_recovers_own_sends_correct_direction` — A (single-device friend) + B/C (share master
  M). C sends DMs to A while B offline; B reconnects + C offline; B fires `DmSyncRequest{both_directions}`;
  A re-serves B's OWN stranded sends. Asserts (through the inspectors) B recovers all on the CORRECT
  sides (own sends `is_mine=true`, friend's `is_mine=false`), correct order, all signed. Guards the
  2026-06-18 `mine`-inversion regression: reverting `is_mine = !msg.mine` → test fails on wrong sides +
  sig-verify.

## Run

`cargo test --lib test_harness -- --nocapture` (the harness tests). Full suite: `cargo test --lib`.

## CI integration

The harness is CI-gated. `.github/workflows/rust-coverage.yml` (job "Test & Coverage") runs
`cargo llvm-cov --lib` on every push/PR touching `rust/hollow_core/**` — `--lib` EXECUTES the
`#[cfg(test)]` harness tests, so a failing harness test fails the job. The
`--ignore-filename-regex "(...|/node/|...)"` only excludes `node/` from the coverage PERCENTAGE, not
from running. Branch protection requires "Test & Coverage" → the harness gates merges to `main`. No
separate job needed. **Caveat:** the harness tests are timing-sensitive (sleeps for the MLS batch timer,
Olm confirmation, etc.); a slower instrumented CI runner is a latent flakiness risk. **Deflake rule
(2026-07-15, from the `device_revocation_cuts_off_and_ghost_fanout_holds` two-strike flake): don't just
bump flat sleeps — convert them to poll-until-deadline loops (N × 500ms with a 20-30s ceiling, early-exit
on success) on the actual precondition** (e.g. all Olm directions "confirmed" via `olm_status`, tombstone
persisted via the `revoked_devices()` inspector) — flat sleeps proceed even when the precondition hasn't
settled, producing downstream "invalid MAC"-style failures that look like logic bugs. Runtime stays fast
(polls exit early); ceilings only pay out under instrumentation/parallel load.
