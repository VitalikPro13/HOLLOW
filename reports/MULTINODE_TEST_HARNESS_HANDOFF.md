# Multi-Node Test Harness — Handoff & Continuation Plan (Step 9B-i)

**Status:** ✅ RUNGS 1 + 2 DONE (2026-06-19). Glare fix + inspectors committed (`82eefdc`). Rung 2
(servers + channels + MLS + the `DebugSnapshot` live-crypto inspector) GREEN: `server_join_forms_mls
_and_channel_message_decrypts` drives owner-creates-server → joiner-joins → MLS group forms across
both device leaves at the same epoch → owner's MLS-encrypted channel message decrypts on the joiner,
asserted through every inspector layer (member panel UI + raw CRDT master-keys + raw MLS device-leaves
+ live MLS epoch + Olm status + decrypted channel row). Full suite 340/340, clippy clean, production
build clean (cfg(test) gating verified). Next: rung 3 (device lifecycle: link sibling, revoke, ghost
cutoff) + ring-2 control plane (call/VC signal routing, file-request handshake, shard assignment).

**Below: the original Fix B handoff, kept for history.**

**Status (Fix B, historical):** ✅ FIRST TEST GREEN. The Olm KeyBundle glare deadlock (Fix B) is fixed
and a mock-fidelity gap (offline node never got `WsEvent::Disconnected`) was closed. The
`peer_fallback_recovers_own_sends_correct_direction` test passes. Regression-guard verified
(reverting the `mine`-inversion fix makes the test fail on the
wrong sides + sig-verify, then re-applying passes). **NOT committed** yet. The scaffold is now the
working foundation for testing the entire app — next is expanding the test set (§4 step 8).

### What changed this session (the two fixes)
1. **Production glare fix** (`swarm.rs` KeyBundle arm, ~line 4034): the tiebreaker now compares
   `device_peer_id > peer_str` (was `local_peer_str > peer_str`). `local_peer_str` is our MASTER;
   `peer_str` is the remote DEVICE id — comparing master-vs-device is NOT antisymmetric, so under
   near-simultaneous delivery BOTH peers could be "higher" and both defer → permanent deadlock
   (only the 30s sweep broke it). Olm sessions live on SOCKETS, and all `key_bundle_sent_to` /
   `key_request_in_flight` / KeyRequest targets are already device-keyed, so `device_peer_id`
   (our own device id, already threaded into the fn) is the consistent id to compare. This is also
   a latent PRODUCTION reliability fix for two multi-device peers whose KeyBundles cross.
2. **Mock fidelity** (`test_harness.rs` `set_online(false)`): now sends `WsEvent::Disconnected` to
   the node being taken offline, mirroring the real WS client when its socket drops. The event loop
   relies on `Disconnected` to clear `synced_peers`/`key_request_in_flight`/`key_bundle_sent_to`;
   without it the reconnecting node kept every peer marked already-synced, so the `is_new` guard
   suppressed the proactive reconnect DmSyncRequest{both_directions} and the backfill never fired.

---

## 0. The Point (why this exists — read first)

The whole multi-device epic has been: write code → Vitalik live-tests on 3 real devices
(Pixel↔VM↔AL) → copies logs → explains the symptom → Claude diagnoses → repeat. Slow, and it
leans entirely on Vitalik's manual testing. Every bug this epic hit (the `mine`-inversion bug, the
master-vs-device routing misses, presence/typing/encrypted-status bugs) was a **state/event bug
that surfaced in the UI but lives in Rust** — and would have been caught instantly by an automated
test that drives real nodes and inspects their real state.

**The goal: a headless harness where Claude spins up N real nodes in one process, drives them
(send DMs, join servers, go offline/online, revoke devices…), and asserts on each node's real DB +
NetworkEvents — no devices, no relay, no log-copying.** Claude runs `cargo test`, sees the failure
itself, fixes, re-runs. This is the autonomous "test my own work" loop. The UI is a thin
projection of Rust state (online dots = `peersProvider` from Rust; `is_mine` direction = DB rows;
encrypted status = Olm session state), so **testing the Rust state IS testing what the UI shows** —
no screenshots needed for the things that actually break in multi-device.

**Relay = in-process mock** (Vitalik-locked). The relay is a dumb pipe (room routing + offline
buffer); all crypto/sync/ordering lives in the nodes. A faithful ~200-line Rust mock lets every
real node behave exactly as in production with zero network. (A small live-smoke suite against the
real relay can come later, only to verify the relay's own C++ — out of scope here.)

Full background: `project_multinode_test_harness` memory, tracker §9B-i.

---

## 1. What's BUILT and WORKING (the hard 80%)

All in the **uncommitted working tree**. Files:

### Production seam (behavior-neutral, all 338 existing tests still pass)
- **`rust/hollow_core/src/node/swarm.rs`:**
  - `run_event_loop` now takes `db_path: String, db_passphrase: String` as **parameters** instead
    of deriving them internally from the process-global `data_dir()`. THIS WAS THE KEY UNLOCK —
    previously every node in one process opened the SAME default DB (`%APPDATA%/Hollow/messages.db`),
    colliding. Production `spawn_node` derives them exactly as before (one level up) and passes them
    in → byte-for-byte identical production behavior.
  - New `#[cfg(test)] pub(crate) async fn spawn_node_mock(...)` — mirrors `spawn_node` but SKIPS the
    real `spawn_ws_client` + `spawn_signaling_task`; returns
    `(master_peer_id, JoinHandle, ws_cmd_rx, ws_event_tx)` so the broker wires the node in.
    Signaling is a dead channel pair (event side never fires; signaling is a non-fatal HTTP
    fallback, DM/room delivery never needs it).
- **`rust/hollow_core/src/node/mod.rs`:** added `#[cfg(test)] mod test_harness;`.

### The harness (`rust/hollow_core/src/node/test_harness.rs`, NEW, `#[cfg(test)]`)
- **`MockRelay`** — in-process broker. Holds `conns` (device_id → event sink + online flag),
  `rooms` (room → device set), `offline` (target → buffered msgs). Faithfully mirrors the relay:
  - `register(peer, cmd_rx, event_tx)` → drives the node's outbound commands on a task, emits
    `WsEvent::Connected`.
  - `set_online(peer, bool)` → simulate disconnect (drop from rooms + broadcast `PeerLeft`) /
    reconnect (re-emit `Connected` → node re-joins).
  - Routes `JoinRoom` (→ `RoomMembers` to joiner + `PeerJoined` to others + replay offline buffer),
    `LeaveRoom`, `SendToRoom` (→ `Message`, no self-echo), `SendDirect`/`SendDirectImage`
    (→ `DirectMessage` if target online+in-room, else BUFFER for replay-on-join — the load-bearing
    peer-fallback path), `SendBinaryDirect`, `DiscoverPeers`, `CheckPeers`. Everything else no-op.
- **`TestNode`** — `{ master_id, device_id, cmd_tx, event_rx, db_path, passphrase, _join, _tmp }`
  with `.store()` to open the node's DB for assertions.
- **Helpers:** `spawn_node_with_friends(relay, master_tag, device_tag, friend_masters)` (in-memory
  keypairs via `from_secret_bytes(seed_bytes(tag))`, per-node `tempfile::tempdir()` DB, fresh Olm
  account, **pre-seeds accepted friendships BEFORE connect so the first `Connected` auto-joins the
  DM rooms**, registers with broker), `wait_event`, `drain_events`, `sleep_ms`.
- **The test:** `peer_fallback_recovers_own_sends_correct_direction` — A (single-device friend,
  device==master), B + C (share master M, two devices). Pre-seed resolver
  (`seed_self(M, [B_dev, C_dev])` so B knows it's multi-device + collapse works). Befriend A↔M.
  B offline; C sends 3 DMs to A + A replies 3; C offline; B online; B fires
  `DmSyncRequest{both_directions}`; assert B recovers all 6 on the CORRECT sides (own C-sends
  `is_mine=true`, A-sends `is_mine=false`) + correct order. This is the exact inversion regression
  from the 2026-06-18 session.

### PROVEN working in the test runs
- Nodes spawn, each opens its OWN isolated tempdir DB (verified distinct paths).
- Friendships seed + persist; nodes auto-join inbox + shared DM rooms (broker logged the joins).
- Key material (KeyRequest/KeyBundle) flows through the broker (60 direct deliveries observed).
- Each node's OWN sends persist correctly with `is_mine=true`.
- Production untouched: **338 lib tests pass**, the production build is clean, clippy clean.

---

## 2. THE BLOCKER — Olm KeyBundle glare deadlock (this is Fix B)

### Symptom
Across-node encrypted DMs never decrypt. In the test, A ends with only its own 3 sends, C with only
its own 3 — neither receives the other's. No Olm session ever forms between any pair.

### Root cause (diagnosed, high-confidence)
Every KeyBundle handler invocation logs `[HOLLOW-CRYPTO] KeyBundle glare with <peer> — we're
higher, deferring to their PreKey`. For a pair, only ONE peer can be "higher" — yet BOTH log it
about each other, so **both defer and no one creates the session → deadlock.**

The glare tiebreaker (`swarm.rs` ~line 4034, `HavenMessage::KeyBundle` arm):
```rust
} else if key_bundle_sent_to.remove(peer_str) && local_peer_str > peer_str {
    // "we're higher, defer"
```
`local_peer_str` is **this node's MASTER id**. The incoming KeyBundle's `peer_str` is the **sender's
DEVICE id** (the relay/broker reports device ids). So:
- A↔C: A compares `A_master` vs `C_device`; C compares `C_master` vs `A_device`. These are
  comparisons between DIFFERENT pairs of strings, so the ordering is **not antisymmetric** — both
  sides can satisfy `local > peer` simultaneously → both defer → deadlock.

In production this is **masked by real network timing** (one KeyBundle usually arrives before the
other side has sent/marked its own, so the symmetric `key_bundle_sent_to` glare condition rarely
trips both ways) + the 30s reconciliation sweep eventually retries. The mock delivers
near-simultaneously, which **exposes a latent real glare bug** — i.e. the harness is already doing
its job (surfacing a bug a human would almost never catch).

### Fix B (do this next session — production fix, scope is whatever it takes)
The glare tiebreaker must compare **consistent, resolved identities on both sides** so the ordering
is antisymmetric (exactly one peer is "higher"). Options to evaluate:
1. **Compare resolved MASTERS on both ends:** `resolver::resolve(local) vs resolver::resolve(peer)`
   — but a peer's device→master may not be warm yet at first contact; and two devices of the SAME
   master (siblings) would tie (resolve to the same master). Need a device-level tiebreaker for the
   sibling case (e.g. fall back to raw device-id comparison when masters are equal).
2. **Always compare the same KIND of id on both ends:** decide the tiebreaker on the pair of
   DEVICE ids (the ids the relay actually reports + that authenticate sockets). The local side
   knows its own device id (`device_peer_id`, already threaded into the event loop); the remote
   device id is `peer_str`. So `device_peer_id vs peer_str` is antisymmetric and unambiguous. This
   is likely the cleanest fix — the glare is fundamentally about which SOCKET creates the outbound
   session, and sockets are device-keyed.
   - **Caveat:** verify every site that sets/reads `key_bundle_sent_to` and the KeyRequest/KeyBundle
     send targets uses ids consistently (device vs master). The proactive RoomMembers key exchange,
     the KeyRequest responder, and the SessionAck path must all agree on the comparison id.
3. Re-audit the WHOLE Olm glare + proactive-exchange interaction for the multi-device (device≠master)
   case — this bug means it was only ever exercised with device==master (keystone) in real life,
   where master-vs-device comparison happened to be self-consistent. Now that devices ≠ masters are
   the norm, the comparison must be made id-kind-consistent everywhere.

**Verification for Fix B:** the harness test is the verifier. After the fix, sessions form
(look for `Created outbound (unconfirmed) session` + a SessionAck round-trip), DMs decrypt, and
`peer_fallback_recovers_own_sends_correct_direction` goes green. ALSO re-run the full suite (must
stay green) and ideally live-test once on real devices that plain + multi-device DMs still key
correctly (the glare path is load-bearing for first-contact key exchange).

### Important nuance
This glare bug may ALSO be a latent production bug (two multi-device peers whose KeyBundles happen
to cross simultaneously could deadlock until the 30s sweep). Fixing it improves real reliability,
not just the test. Treat Fix B as a real product fix with its own care, not a test-only hack.

---

## 3. Secondary noise (NOT the blocker, but tidy up)
- **SQLCipher `hmac check failed for pgno=1`** (~8 per run, clustered at startup near
  `Created new MLS identity`). Likely benign first-open probes of not-yet-created tables. The test
  sets `HOLLOW_DATA_DIR` to a throwaway tempdir so no stray global-data-dir path can touch the
  developer's real `~/.hollow` DB. Confirm these are harmless (or silence them) once sessions work.
- A few leftover `[HARNESS]` `eprintln!` diagnostics in the test (A/B/C db paths, "A holds",
  "C holds") — keep while debugging Fix B, remove before commit.

---

## 4. Continuation checklist (next session)
1. Re-read this file + `project_multinode_test_harness` memory + tracker §9B-i.
2. Implement **Fix B** (recommend option 2: device-id-consistent glare tiebreaker; audit all
   `key_bundle_sent_to` / KeyRequest / KeyBundle / SessionAck sites for id-kind consistency).
3. Run `cargo test --lib test_harness -- --nocapture`; iterate until sessions form + DMs decrypt +
   the test asserts pass (own-sends `is_mine=true`, friend-sends `is_mine=false`, correct order).
4. Sanity-check the test guards the bug: temporarily revert the `mine`-inversion fix
   (`is_mine = msg.mine` instead of `!msg.mine` on the friend path in the `DmSyncBatch` receiver,
   `swarm.rs`) → test must FAIL on wrong sides → re-apply → passes.
5. Remove `[HARNESS]` debug eprintlns. Run full `cargo test --lib` (all green) + `cargo clippy`.
6. If desired, live-test once that real-device DM keying still works (glare path changed).
7. Commit: production glare fix + harness, with a message covering both.
8. THEN expand: more tests on this scaffold (sibling backfill, server channel cross-device decrypt,
   revocation cutoff, single-device no-op guards) — the foundation for testing the whole app.

---

## 5. Key file references
- `rust/hollow_core/src/node/swarm.rs` — `spawn_node` (~67), `spawn_node_mock` (~143, cfg(test)),
  `run_event_loop` (~188, now takes db_path/db_passphrase), the KeyBundle glare arm (~4029).
- `rust/hollow_core/src/node/test_harness.rs` — MockRelay + helpers + the test (NEW, cfg(test)).
- `rust/hollow_core/src/node/mod.rs` — `#[cfg(test)] mod test_harness;`.
- `rust/hollow_core/src/node/crypto_handler.rs` — `send_message_to_peer` (SendDirect),
  `send_encrypted_message` (SendDirect), `ws_room_for_peer`, the proactive key-exchange senders.
- `rust/hollow_core/src/node/resolver.rs` — `resolve`/`same_identity`/`devices_for`/`seed_self`/
  `clear_for_test` (the process-global map; harness serializes via its own `HARNESS_GUARD`).
- `rust/hollow_core/src/identity/native_identity.rs` — `from_secret_bytes` (in-memory test keypairs).
- `rust/hollow_core/src/crypto/store.rs`, `node/crdt_store.rs` — `open(db_path, passphrase)`.
- Cross-refs: `project_multinode_test_harness`, `feedback_multidevice_targeting_sweep`,
  `feedback_olm_session_self_heal`, `feedback_mls_patterns` memories.
