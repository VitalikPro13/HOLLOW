# Large-Server MLS Scaling — Investigation & Proof (July 2026)

> **STATUS 2026-07-06 (evening): TIERS 1–3 IMPLEMENTED** — see §7 below for
> what landed and the measured before/after. Tier 4 (relay sharding) remains
> the documented infra plan.
>
> Original investigation status:
> Question raised: does a 50k-member server need MLS disabled (plaintext-over-
> relay-TLS) past ~1k to survive? **Answer: NO.** The bottleneck is not MLS and
> not encryption — it is **O(N) fan-out at two single points** (the relay's
> per-message egress, and the coordinator's per-device commit/welcome loop).
> Both are fixable while keeping full E2EE. A plaintext auto-downgrade would
> silently break the core privacy promise and is **rejected** as the answer;
> explicit, labeled public channels remain the honest option for genuinely
> public communities.
>
> Proven with a new instrumented harness benchmark
> (`scaling_benchmark_mls_fanout`, `#[ignore]`) that meters real relay egress
> on the real join/commit/message code and extrapolates from the measured slope.

Triggered by: "if we had MLS on a 50k server, wouldn't performance drain? Should
we cap MLS at 1k and go plaintext after?" — plus the follow-up instinct that the
real problem is *a single coordinator*, and that a reachability-aware gossip mesh
could carry the load instead.

Method: four parallel read-only code-mapping agents (relay, gossip, WebRTC
reachability, MLS coordinator), then a harness benchmark that MEASURES the
fan-out slope rather than estimating it.

---

## 1. The measured result (harness benchmark)

`cargo test --lib scaling_benchmark_mls_fanout -- --ignored --nocapture`

The benchmark drives the **real** `spawn_node` event loops through the **real**
`JoinServer → KeyPackage → 2s batch-commit → Welcome` MLS handshake and a
**real** MLS-encrypted channel send, metering every frame the in-process
`MockRelay` delivers (relay egress) and every targeted `SendDirect` the
coordinator issues. Measured at 5 / 9 / 13 total members:

| members | 1 channel msg: relay deliveries | per other-member | sender broadcast cmds |
|--------:|--------------------------------:|-----------------:|----------------------:|
|       5 |                              10 |             2.50 |                     2 |
|       9 |                              18 |             2.25 |                     2 |
|      13 |                              30 |             2.50 |                     2 |

**Two facts, both confirmed:**

1. **Sender/coordinator work per message is O(1)** — `broadcast_cmds` stays at 2
   regardless of size (one message broadcast + one CRDT ack/op frame). The node
   hands the relay ~one frame; it does NOT loop over members. Good.
2. **Relay egress per message is O(N)** — deliveries grow linearly, slope ≈ **2.5
   relay copies per other online member** (the ~2.5× vs 1× is the message frame
   plus its CRDT-op/ack companion traffic; the shape is what matters and it is
   dead-linear).

### Extrapolation from the measured slope (2.5 deliveries/other-member, 2 KB frame, 400 Mbps = 50 MB/s relay uplink)

| members | relay deliveries/msg | egress/msg | 1 hot channel saturates the relay at |
|--------:|---------------------:|-----------:|-------------------------------------:|
|   1,000 |               ~2,498 |    ~4.9 MB |                           ~10.2 msg/s |
|  10,000 |              ~24,998 |   ~48.8 MB |                            ~1.0 msg/s |
|  50,000 |             ~124,998 |  ~244.1 MB |                            ~0.2 msg/s |

**A 50k-member hot channel is bandwidth-dead — one post consumes ~244 MB of
relay egress and the channel tops out around one message every five seconds —
long before MLS crypto cost is anywhere near relevant.** This is the whole
finding in one line: **the wall is relay fan-out bandwidth, not MLS.**

### The second O(N): coordinator commit/welcome fan-out (the join path)

Same benchmark, `SendDirect` commands issued per round of joins: **161 → 550 →
904**. These are the coordinator's per-member, per-device targeted commit +
welcome + sync frames — all issued from **one member's home machine**, serially,
in the batch-timer arm of a single event loop. (Absolute values include some
Olm-glare retry churn from the rapid staggered spawn — the harness logs
`MAC tag mismatch` handshake noise — so treat the join figures as
order-of-magnitude, not a precise constant. The per-message egress slope above
is the clean, trustworthy number.)

The critical detail (from the MLS-coordinator code map): **the commit bytes are
byte-identical for every recipient.** MLS commits are a single shared message.
So this O(N) coordinator loop is *not* fundamental to MLS — it is an
implementation choice. It could be a single `SendToRoom` broadcast exactly like
chat already is.

---

## 2. Why it breaks — the two single points of O(N)

Confirmed against source by the four code-mapping agents:

### (a) Relay egress — O(N) per message. `relay-uws/src/ws_handler.cpp`
Every room/topic broadcast handler iterates the room's peer map and calls
`send_to_peer()` once per recipient — an explicit per-peer loop, no uWS pub/sub
multicast, no shared-buffer send.
- Topic-published channel messages (0x07→0x08): `ws_handler.cpp:1262-1274`
- Binary room broadcast (0x03→0x05): `ws_handler.cpp:1109-1113`
- MLS envelope broadcast (0x01): `ws_handler.cpp:1027-1031`

One inbound frame → up to N−1 outbound copies, **all egress from one relay on a
400 Mbps pipe.** RAM is NOT the constraint (50k conns ≈ 670 MB against a
~572k-conn / 8 GB ceiling from `BENCHMARK.md`; the per-channel availability
cache is 512 MB-capped and does not multiply by member count). **Egress
bandwidth is the binding constraint at 50k.**

### (b) Coordinator commit/welcome — O(N) per membership change. `swarm.rs`
The mls_batch_timer (2s, adaptive to 5s/10s under load) commits, then loops over
`state.members.keys()`, expands each to online devices, and issues one
`SendDirect` per device: add path `swarm.rs:3867-3886`, remove path
`swarm.rs:3782-3794`, welcomes `swarm.rs:3848`, plus a per-added-peer
per-channel `ChannelSyncRequest` (`swarm.rs:3903-3919`). Exactly **one node**
does all of this (`elect_server_coordinator`, owner-preferred; non-coordinators
drop KeyPackages, `swarm.rs:9489-9502`). At 50k, every join/leave is thousands
of targeted frames from a residential machine.

Normal chat already avoids this: `send_mls_broadcast` → single `SendToRoom`
(`crypto_handler.rs:1610-1634`). **Commits simply don't use the broadcast
primitive that chat already uses.**

---

## 3. What we already have (assets, not greenfield)

The instinct that "we already have the pieces" is correct:

- **Gossip overlay** (`gossip.rs`, `gossip_relay.rs`): a working per-server
  partial-mesh flood with **TTL=4** and **broadcast-id dedup**, activating at
  ≥6 members, 6–12 neighbors/server, 50 data-channels global cap. Today it
  carries only **file bytes**. Because CRDT ops are **idempotent and
  self-validating** (op_log dedups; receiver re-checks author+permission), they
  are **safe to flood over this mesh by construction.** Reliability backbone
  today = the relay-announced pull model (a peer that misses a gossiped item
  times out at 30s and pulls it directly), so the relay stays as the
  completeness backstop even when bulk traffic moves to the mesh.

- **Reachability detection — already computed, then discarded.**
  `webrtc_service.dart:_logIceRoute` (923-960) already classifies every live
  connection as `host`/`srflx` (direct/STUN/LAN) vs `relay` (TURN) via
  `getStats()` — and only writes it to `hollow_debug.log`. It is never returned
  to Rust and never reaches the overlay scorer (`PeerScore.composite`,
  `gossip.rs:90`, which weights latency/uptime/bandwidth/shard-overlap but NOT
  reachability). Wiring it in is ~1 FFI report + 1 `PeerScore` field + a
  selection/rotation bias.

- **Per-channel MLS subgroups** already spread load *across* channels (each
  restricted channel = own group + own elected coordinator). No sharding
  *within* one large group exists.

---

## 4. Recommended direction — scale the logic, keep E2EE

Ordered by leverage-per-risk. **None of these disable encryption.**

### Tier 1 — Commit broadcast (low effort, high impact, low risk)
Route `MlsCommit`/`MlsWelcome-to-existing-members` through `SendToRoom` (0x03)
like chat, instead of the per-device `SendDirect` loop at `swarm.rs:3883`/`3792`.
The bytes are already identical per recipient. Kills bottleneck (b): coordinator
per-commit network work goes O(N) → O(1). Welcomes to *new* joiners stay
targeted (each Welcome is unique, carries the ratchet tree). **Measure the join
`SendDirect` count before/after with the benchmark to confirm the drop.**

### Tier 2 — Gossip-flood CRDT ops over the mesh (medium effort, low risk)
Add a small-message gossip payload type (no "control op" type byte exists yet:
`webrtc_service.dart:23-29`) and flood CRDT ops over the existing TTL+dedup
mesh, keeping the relay's per-channel ring ONLY as the offline/late-join
backstop. Offloads steady-state CRDT traffic off the relay's O(N) egress.
Idempotency makes duplicates harmless. **MLS commits are riskier to gossip**
(epoch ordering + must-reach-everyone-exactly-once) — keep commits on the
relay broadcast from Tier 1 for now; revisit only if Tier-1 broadcast proves
insufficient.

### Tier 3 — Reachability-aware overlay (medium effort, low risk)
Capture the `_logIceRoute` route type, report it to Rust
(mirror `webrtc_ping_report`), add `is_direct` to `PeerScore`, and bias neighbor
selection/rotation toward directly-reachable (STUN/host/IPv6) peers so the mesh
actually offloads instead of leaning on TURN. Route is only known post-connect,
so implement as a **rotation bias** (the 300s rotation loop already exists), not
an initial-selection guarantee. Direct-IPv6 falls out for free once the family
is recorded.

### Tier 4 — Relay/bandwidth horizontal sharding (high effort, infra)
Already the documented forward plan (`project_scaling_plan`,
`project_relay_bandwidth_enforcement` — Hetzner split). The real ceiling is a
single relay's uplink, not its RAM; spreading a hot server's fan-out across
multiple relays is the ultimate lever for the truly-massive case. Tiers 1–3
push that ceiling far enough that this is only needed at the extreme.

### Explicitly rejected
- **Silent plaintext auto-downgrade past 1k.** Relay TLS is transport-only — the
  relay operator sees plaintext. A member who joined a "private encrypted
  server" would broadcast plaintext at member #1001 with no notice. This breaks
  Hollow's core promise invisibly. If a community is genuinely public, that is a
  **product choice made explicitly up front** via the existing public-channel
  path (plaintext + Ed25519-signed, clearly labeled) — not an automatic
  security regression forced by a bandwidth limit we can engineer around.

---

## 5. Harness instrumentation added (this session)

`node/test_harness.rs`:
- `RelayMeter` struct + `MockRelay::reset_meter()` / `meter()` — counts inbound
  command types (send_direct/send_to_room/send_topic cmds) and, crucially,
  **outbound deliveries** (real relay egress), split into broadcast vs direct,
  weighted by bytes. Zero overhead when disabled (`meter: None`), so it does not
  touch the normal fast suite.
- `broadcast_except` / `deliver_direct` now return the delivered-frame count so
  the meter reflects true egress (respecting online + in-room filtering).
- `scaling_benchmark_mls_fanout` (`#[ignore]`) — the benchmark above. Run
  explicitly; never part of `cargo test --lib`'s default set.

This instrumentation is reusable: any future fan-out change (Tier 1–3) can be
verified by re-running the benchmark and reading the before/after slope.

---

## 6. Bottom line (original investigation)

- MLS is **not** the scaling wall. Encryption cost is O(log N) tree ops per
  member — negligible next to bandwidth.
- The wall is **O(N) fan-out at two single points**: relay egress per message,
  and the coordinator's per-device commit loop. Both measured, both linear,
  both fixable **without touching E2EE**.
- The plaintext downgrade solves the wrong problem (and breaks the privacy
  promise silently). The right answer is: **broadcast commits like chat, flood
  CRDT ops over the reachability-aware gossip mesh, and shard relay bandwidth
  for the extreme case** — i.e. scale the *logic*, not weaken the *crypto*.
- Next concrete step: implement **Tier 1 (commit broadcast)** and re-run the
  benchmark to confirm the join `SendDirect` count collapses.

---

## 7. Implementation (landed 2026-07-06, same day)

### Tier 1 — Commit broadcast ✅
Every MLS commit fan-out now rides ONE `SendToRoom` (0x03) frame via
`crypto_handler::broadcast_mls_commit()` instead of a per-device `SendDirect`
loop. Converted sites: both `mls_batch_timer` phases (`swarm.rs`), kick / leave
/ ban (`sync_handler.rs`), and `remove_identity_from_subgroups`
(`crypto_handler.rs`). The commit-path `fan_to_own_siblings` calls were removed
— siblings sit in the room and get the broadcast.

Safety piece: `HavenMessage::MlsCommit` gained a `#[serde(default)] epoch`
field (POST-merge epoch). The receiver skips commits whose epoch it has
already reached — a broadcast also lands on fresh joiners (already at that
epoch via their Welcome) and duplicates, and without the guard each of those
would error into the drop-group + re-bootstrap path. A kicked identity that
does try to re-bootstrap is refused by the existing MlsKeyPackage non-member
check (L6). Legacy senders without the field behave exactly as before.

**Measured** (same benchmark): join-round `SendDirect` 161/550/904 →
**162/482/774** at 5/9/13 members (the gap grows with N — the removed loop was
the O(N) part; the remainder is pairwise Olm/sync spread across the joiners,
not coordinator-concentrated). Per-message slope **2.5 → 2.0**
deliveries/other-member (the epoch guard also killed spurious re-bootstrap
churn). Full suite 390/390 green.

### Tier 2 — CRDT ops flood the WebRTC mesh ✅
New small-message gossip frame: type byte **0x04** on 'hollow-data' carrying
`GossipCrdtOp { broadcast_id, server_id, ttl, op_json }` (`gossip.rs`).
- **Origin**: `broadcast_crdt_op_to_members` (sync_handler) now tries
  `gossip_relay::flood_crdt_op()` first — targets =
  `overlay.connected_relay_targets()` (neighbors whose data channel is LIVE,
  per `PeerScore.connected_since`). Falls back to the historical per-identity
  relay fan-out when the mesh can't carry it (small server / channels dialing
  / op > 15 KB / event channel full). The MLS twin (single SendToRoom) is
  unchanged.
- **Receive**: Dart hands `0x04` frames to `webrtc_gossip_op_received()` FFI →
  `accept_gossip_op()` (size cap + broadcast-id dedup) → re-enters
  `handle_incoming_request` as a synthetic `CrdtOpBroadcast`, so the op runs
  the EXACT same author-permission matrix, op_log dedup, persistence, and UI
  events as a relay op.
- **Propagation**: bounded by **op-newness** — the forward step only fires
  when the op grew the local op_log, so each node re-floods a given op at most
  once (≤ degree sends), only after validation. No TTL bookkeeping needed;
  `ttl` stays on the wire as a reserved bound.
- **Bonus fix**: the receiver-side forward loop in the `CrdtOpBroadcast` arm
  (every receiving node re-forwarding to ALL members' devices = O(N²)
  network-wide) is now mesh-first with the same relay fallback.
- Privacy side-effect: on mesh-active servers the relay no longer sees
  plaintext CRDT op JSON at all.
- Harness note: nodes without WebRTC (all harness tests) always take the
  relay fallback — behavior unchanged there by construction.

### Tier 3 — Reachability-aware overlay ✅
`_logIceRoute` (webrtc_service.dart) now reports its existing host/srflx/relay
classification to Rust via new `webrtc_route_report(peer_id, is_direct)` FFI
(mirrors `webrtc_ping_report`). `PeerScore` gained
`is_direct: Option<bool>`; `composite()` adds a reachability term
(direct +0.15 / unmeasured +0.075 / TURN +0.0) whose spread clears the
rotation's 10% improvement margin, so the 300s rotation drifts the mesh toward
directly-reachable peers. Unit-tested (`test_peer_score_reachability_ordering`,
`test_connected_relay_targets_filters_live_channels`).

### Not covered by the harness (manual pass)
Live mesh flooding end-to-end (real data channels), the 0x04 frame on real
devices, and the route-report → rotation bias need a 2+ machine check — the
harness has no WebRTC. Everything relay-path-shaped is harness-verified.
