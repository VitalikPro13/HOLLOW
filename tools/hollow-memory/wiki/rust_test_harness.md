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

## Inspectors — read state the way the UI does (two layers)

The GAP between the two layers is where multi-device bugs hide, so both exist on purpose:
- **UI layer** (master-collapsed, reads through the SAME resolver/CRDT accessors the Dart providers
  use → a green inspector == a green UI for that state): `TestNode::dm_thread`, `dm_unread`, `servers`,
  `member_panel` (master-keyed role+online via `ServerState::get_role`, the resolver chokepoint),
  `channel_messages`, `online_identities`/`is_online` (presence read from the relay, collapsed via
  `resolver::resolve`).
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
- `test_guard()` — process-wide `Mutex` + `resolver::clear_for_test()`. The resolver is a process-global
  `OnceLock` map, so harness tests run SERIALLY from a clean resolver. The guard is held across the
  whole async test (intentional; `#[allow(clippy::await_holding_lock)]`).
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

## Current tests (7)

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
Olm confirmation, etc.); a slower instrumented CI runner is a latent flakiness risk — bump the sleeps if
CI flakes, don't assume a logic bug.
