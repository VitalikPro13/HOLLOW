# Scale Probe, October 2026 (G1)

**Status 2026-10-17: baseline measured on main (18484f7e).** Measurement only, no product
behaviour changed. The 0.12.2 fixes rerun the same three commands (section 6) and add a
second column to every table.

The question: how large can a Hollow server get? The answer sets two things: the member
cap of an MLS server (beyond it a server converts to the planned community mode with a
shared community key), and the thresholds of the phase G relay circuit breaker, which must
never trip on what an honest member of a big server does.

Three probes, each a reusable tool:

- **a. Real node logic** (`scaling_benchmark_mls_fanout` in `node/test_harness.rs`): real
  event loops on the in-process relay, every frame metered by wire kind and by phase (join,
  message, reconnect, leave, kick), at 5 to 100 members.
- **b. MLS alone** (`crypto/mls_scale_probe.rs`): the real `MlsManager` (our ciphersuite,
  bound `hl1` device credentials, leaf stamp extension, ratchet tree extension, past-epoch
  window) at 1k, 10k and 100k leaves.
- **c. Relay alone** (`relay-uws/bench/scale_probe`): protocol-speaking clients (auth v3 with sessions, as `ws_client` logs in today)
  against the real C++ relay built on the Mac.

## 1. Summary

1. **Joins are linear in frames now.** The 2026-08 run counted about 2 x N^2 sends per
   join; the commit broadcast (tier 1) fixed that. A join costs about 21 node sends and 28
   relay deliveries per other online member, flat from 9 to 100 members.
2. **Four quadratic culprits remain, and none of them is MLS cryptography:**
   - **Leave and kick are N^2 in frames.** Every member that receives the leave or kick
     op re-forwards it to every other member (`node/swarm.rs:7215-7231`) whenever the WebRTC
     mesh cannot carry it, which is always in the harness and often in the field. About
     N x (N-1) carried frames per leave, kick or ban.
   - **Joins and reconnects are N^2 in bytes.** Every first contact exchanges a
     `SyncRequest` whose CRDT state vector has one entry per op author
     (`crdt/sync.rs:21`), and every member authors a storage pledge on joining
     (`node/swarm.rs:10167-10208`), so the vector grows with the server. 2N requests of
     about 270 bytes per member each: about 535 x N^2 bytes per join or reconnect.
   - **Peer discovery is N^2 in bytes, every 30 seconds.** Every device asks the relay for
     the full peer list of every server it is in on a 30 second timer (`node/swarm.rs:6095-6103`,
     answered whole at `relay-uws/src/ws_handler.cpp:3037-3068`): N answers of N ids.
   - **An MLS remove commit is O(N) bytes, broadcast to N.** Only the authority ever
     commits, so the ratchet tree stays mostly blank and every remove's update path encrypts
     to almost every leaf: 87 bytes per member per remove.
   - **Presence and lock moves are O(N) per change on the relay** (part c): about 2N frames
     and 13 us x N of relay CPU per presence change, and every lock move (kick, ban,
     demotion) makes every member join again and receive the full member list, N x N ids.
3. **The per-member CPU wall is an OpenMLS storage setting, not MLS.** Encrypting or
   decrypting one application message costs every member 63 ms at 1k members and 0.61 s at
   10k, linear in N. The cause is the three-epoch late-delivery window
   (`MAX_PAST_EPOCHS`, `crypto/mls_manager.rs:29`): OpenMLS rewrites the past epochs'
   member lists into storage on every message. With no past epochs the same message costs
   0.3 to 6 ms up to 10k members on bare OpenMLS. On top, every send serializes and saves
   the whole MLS state (`node/crypto_handler.rs:1490`, called at `:2591` and `:2666`): 5 MB
   per sent message at 1k, 50 MB at 10k.
4. **Steady-state messaging is unchanged and linear:** 2 relay frames per post, 2
   deliveries and about 1.45 KB of relay egress per other online member.
5. **Recommended MLS member cap:** about **300 to 500** on today's code, **2,000 to
   5,000** once the five fixes in section 5 land, and community mode above 5,000 (section 5).

## 2. Part a: real node logic

**Setup.** Owner plus members, all strangers to each other (no friendships, the realistic
shape of a big server), one device each, on the in-process `MockRelay`. Each size is grown
by batched joins (4 at a time, unmetered), then one phase at a time is metered from a
settled start to a settled end: a 10 second idle window, one join, one message from the
owner and one from a member, one fresh reconnect of a member (`SessionLost`, then
`Connected`), one leave, a second join, one kick. Frames are tallied where the relay hands
them to a socket, by wire kind; encrypted frames are named by the plaintext the sender put
inside (Olm `carried/<type>`, MLS envelope `t`).

Two corrections are applied to every table below and kept apart in the CSV:

- **Background** kinds that tick on timers whatever the phase does (`peer_exchange` gossip,
  `discover_peers` and its answers) are left out of the phase tables and reported in 2.6.
- **Mock-only presence.** On a join lock move every member proves the new door by joining
  the room again. The mock relay re-announces each of those re-joins (`peer_joined` to
  everyone, N^2 frames); the real relay suppresses a re-join of a socket that already saw
  the room (`already_present`, `relay-uws/src/ws_handler.cpp:986-1000`). Those frames are
  removed from the leave and kick tables. The `members` reply each re-joiner gets (N ids)
  is real and stays.

"Node sends" are frames the nodes handed the relay; "relay deliveries" are frames the
relay copied to sockets (egress); "busiest device" sums, over kinds, the most any one
device sent of that kind, an upper bound on what one socket did.

### 2.1 Join (one new member into N-1 seated members)

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 107 | 128 | 128,648 | 32.0 | 69 | 4.5 |
| 9 | 187 | 240 | 291,392 | 30.0 | 117 | 4.3 |
| 13 | 266 | 351 | 476,354 | 29.2 | 160 | 63.1 |
| 20 | 430 | 568 | 840,202 | 29.9 | 253 | 64.0 |
| 30 | 630 | 842 | 1,425,206 | 29.0 | 352 | 63.7 |
| 50 | 1036 | 1392 | 2,911,887 | 28.4 | 561 | 65.9 |
| 75 | 1532 | 2067 | 5,224,342 | 27.9 | 859 | 63.8 |
| 100 | 2036 | 2930 | 8,264,375 | 29.6 | 1092 | 63.9 |

Fitted exponents for N = 9 to 100: sends 0.99, deliveries 1.03, bytes 1.38

The second join at each size (`join2`):

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 107 | 131 | 141,769 | 32.8 | 67 | 0.8 |
| 9 | 187 | 243 | 304,825 | 30.4 | 117 | 3.6 |
| 13 | 266 | 354 | 489,679 | 29.5 | 163 | 64.0 |
| 20 | 392 | 533 | 835,123 | 28.1 | 229 | 62.3 |
| 30 | 572 | 787 | 1,402,929 | 27.1 | 329 | 62.3 |
| 50 | 932 | 1291 | 2,812,383 | 26.3 | 513 | 65.0 |
| 75 | 1385 | 1923 | 5,115,533 | 26.0 | 731 | 62.4 |
| 100 | 1838 | 2735 | 8,126,277 | 27.6 | 993 | 63.8 |

Fitted exponents for N = 9 to 100: sends 0.95, deliveries 0.99, bytes 1.35

The join stays busy for about 60 seconds at 13 members and up (the settle column); frames
in that window are part of the count.

| kind (N = 75) | frames | bytes | shape |
|---|---:|---:|---|
| `session_ack`, `key_request`, `key_bundle` (Olm key exchange with every member) | 588 | 313 KB | 8 per member |
| `carried/profile_update` | 222 | 469 KB | 3 per member |
| `carried/sync_request` | 150 | 3.09 MB | 2 per member, **20.6 KB each, growing with N** |
| `carried/sync_response` | 150 | 159 KB | 2 per member |
| `join_sealed` broadcasts | 2 sends, 146 deliveries | 229 KB at N = 50 | 1 per member each |
| `mls_commit` (add) | 1 send | 33 KB at N = 50 | 1 per member |

**Culprit: the `SyncRequest` state vector.** Both ends of every new pair send one: each
member to the joiner on `PeerJoined` (`node/swarm.rs:4161-4176`) and the joiner to each
member once their session confirms (`node/swarm.rs:4743-4757`). The body is a
`StateVector` with one entry per op author (`crdt/sync.rs:21-38`), and every member
authors one op on joining, its storage pledge (`node/swarm.rs:10167-10208`), so the
vector has about N entries of about 275 bytes on the wire. Frames grow as N^1.0, bytes as
N^1.87.

### 2.2 Message

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 2 | 8 | 5,768 | 2.0 | 2 | 0.2 |
| 9 | 2 | 16 | 11,536 | 2.0 | 2 | 0.2 |
| 13 | 2 | 24 | 17,352 | 2.0 | 2 | 0.0 |
| 20 | 2 | 38 | 27,474 | 2.0 | 2 | 0.2 |
| 30 | 2 | 58 | 41,934 | 2.0 | 2 | 2.8 |
| 50 | 2 | 98 | 70,854 | 2.0 | 2 | 0.2 |
| 75 | 2 | 148 | 107,004 | 2.0 | 2 | 0.3 |
| 100 | 2 | 198 | 143,154 | 2.0 | 2 | 0.2 |

Fitted exponents for N = 9 to 100: sends 0.00, deliveries 1.04, bytes 1.04

A post by the owner is identical.

Two broadcast frames per post (`ch` and `ch_hint`), two deliveries per other member,
about 845 plus 601 bytes per member. Sender work is O(1). Unchanged since July.

### 2.3 Reconnect (one member's device drops its session and comes back)

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 51 | 63 | 56,643 | 15.8 | 30 | 4.6 |
| 9 | 94 | 121 | 145,674 | 15.1 | 52 | 4.2 |
| 13 | 134 | 176 | 260,690 | 14.7 | 72 | 3.4 |
| 20 | 204 | 270 | 501,723 | 14.2 | 107 | 1.8 |
| 30 | 304 | 403 | 939,854 | 13.9 | 157 | 5.8 |
| 50 | 504 | 666 | 2,103,959 | 13.6 | 257 | 2.1 |
| 75 | 754 | 994 | 3,955,447 | 13.4 | 382 | 3.4 |
| 100 | 1076 | 1576 | 6,538,079 | 15.9 | 507 | 3.8 |

Fitted exponents for N = 9 to 100: sends 1.00, deliveries 1.03, bytes 1.57

Every pair redoes the first-contact sync: per other member about 2 `sync_request`, 2
`sync_response`, 2 `dm_sync_req` (to members it has no DM with), 2 `profile_update`, 1
`ch_sync_req` and its answer. Frames are linear (about 10 sends by all nodes, 5 by the
reconnecting device, per other member); bytes grow as N^1.55 because of the same
state vector (3.03 MB of the 4.05 MB at N = 75).

### 2.4 Leave and kick

Leave:

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 43 | 49 | 47,994 | 12.2 | 20 | 1.9 |
| 9 | 111 | 133 | 145,198 | 16.6 | 32 | 1.8 |
| 13 | 210 | 248 | 284,129 | 20.7 | 44 | 0.3 |
| 20 | 472 | 538 | 631,167 | 28.3 | 66 | 2.0 |
| 30 | 991 | 1097 | 1,339,362 | 37.8 | 95 | 3.0 |
| 50 | 2662 | 2848 | 3,569,145 | 58.1 | 156 | 5.3 |
| 75 | 5812 | 6098 | 7,879,620 | 82.4 | 232 | 3.2 |
| 100 | 10298 | 10684 | 14,191,859 | 107.9 | 339 | 3.4 |

Fitted exponents for N = 9 to 100: sends 1.89, deliveries 1.82, bytes 1.90

Kick:

| members | node sends | relay deliveries | relay egress bytes | deliveries per other member | busiest device sends (upper bound) | settle s |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 39 | 46 | 45,534 | 11.5 | 20 | 2.9 |
| 9 | 103 | 126 | 138,574 | 15.8 | 32 | 2.2 |
| 13 | 200 | 239 | 274,930 | 19.9 | 45 | 1.8 |
| 20 | 445 | 512 | 615,298 | 26.9 | 66 | 2.2 |
| 30 | 965 | 1072 | 1,326,628 | 37.0 | 96 | 5.2 |
| 50 | 2613 | 2800 | 3,576,220 | 57.1 | 161 | 1.8 |
| 75 | 5818 | 6105 | 8,011,290 | 82.5 | 251 | 2.8 |
| 100 | 10305 | 10693 | 14,406,446 | 108.0 | 357 | 4.1 |

Fitted exponents for N = 9 to 100: sends 1.92, deliveries 1.85, bytes 1.93

**Culprit: the receive-side re-forward of a CRDT op** (`node/swarm.rs:7209-7231`). When a
node ingests a new op from `CrdtOpBroadcast`, it forwards it to every online device of
every member unless the WebRTC gossip mesh took it (`flood_crdt_op` returned 0). Removal
ops ride Olm only, with no MLS copy (`broadcast_removal_op`, `node/sync_handler.rs:374-393`,
called by leave `:2652`, kick `:2440` and ban `:2731`), so every member ingests the op as
new and forwards it: `carried/crdt_op` on leave was 22, 78, 165, 392, 880, 2460, 5561,
9918 at 5 to 100 members, that is N x (N-1). With a live mesh the forward is degree-bounded; without one
(phones, a mesh still dialing, an op over 15 KB) it is N^2. A ban takes the same path (not measured).

Two smaller N^2-byte terms ride the same events: the remove commit (2.5) is broadcast to
N, and every member re-joins the room to prove the moved door and receives a `members`
list of N ids.

### 2.5 MLS remove commit in the field

The leave and kick `mls_commit` bytes grow as N^1.8 in the harness: one broadcast of a
commit whose size is O(N), see part b.

### 2.6 Background (idle, 10 seconds)

| members | frames per 10 s | bytes per 10 s | of which `discovered_peers` bytes |
|---:|---:|---:|---:|
| 12 | 56 | 16 KB | 2.7 KB |
| 49 | 78 | 54 KB | 41 KB |
| 74 | 160 | 158 KB | 131 KB |
| 99 | 224 | 201 KB | 153 KB |

**Culprit: periodic peer discovery** (`node/swarm.rs:6095-6103`, the 30 second
`rebootstrap_timer`). Every device asks for the peer list of its active room and of every
server it is in; the relay answers with every visible id (`ws_handler.cpp:3037-3068`,
about 55 bytes each). Per server: N asks and N x N ids every 30 seconds. The gossip
`peer_exchange` is degree-bounded (6 neighbours) and linear. A 10 second window samples a 30 second timer
unevenly; the model (N x N x 55 bytes per 30 s, 180 KB per 10 s at 99 members) matches.

## 3. Part b: MLS alone

**Setup.** One owner `MlsManager` creates the group and grows it by batched adds of 1,000
real bound KeyPackages (`generate_key_package_for`, stamped). At each size a fresh observer
joins by Welcome and then processes everything after: an add of 50, an add of 1, two
removes in a row, one 512-byte application message. Times are one Apple M4 core, debug
build with dependencies at opt-level 2, the machine shared with the other probes.

| metric | 1,000 | 10,000 | 100,000 |
|---|---:|---:|---:|
| KeyPackage | 503 B | 503 B | 503 B |
| add 1: commit | 691 B | 691 B | 691 B |
| add 1: Welcome (ratchet tree included) | 402 KB | 4.03 MB | 40.2 MB |
| add 1: Welcome as base64, share of 64 MiB | 0.8% | 8.0% | 80% |
| add 1: owner builds the commit | 0.08 s | 1.9 s | 20.2 s |
| member joins from the Welcome | 0.12 s | 1.6 s | 122.6 s |
| add 50: commit | 25 KB | 25 KB | 25 KB |
| add 50: Welcome | 428 KB | 4.05 MB | 40.2 MB |
| add 50: owner builds | 0.14 s | 2.2 s | 22.8 s |
| add 50: member processes | 0.08 s | 0.74 s | 6.7 s |
| add 1: member processes | 0.11 s | 1.2 s | 11.0 s |
| remove 1: commit | 87 KB | 825 KB | 8.2 MB |
| remove 1: owner builds | 0.21 s | 2.9 s | 27.9 s |
| remove 1: member processes | 0.17 s | 2.1 s | 16.8 s |
| second remove: commit | 87 KB | 825 KB | 8.2 MB |
| 512 B message: ciphertext | 663 B | 663 B | 663 B |
| 512 B message: encrypt | 63 ms | 0.61 s | 6.1 s |
| 512 B message: decrypt | 63 ms | 0.61 s | 6.0 s |
| persisted MLS state, member | 5.2 MB | 49.5 MB | 490 MB |
| persisted MLS state, owner | 5.2 MB | 49.5 MB | 490 MB |
| growth to this size, owner time | 0.6 s | 26 s | 1,877 s (batches of 5,000) |

Notes on the numbers:

- **Sizes are exact and deterministic; times are indicative.** Phones are 3 to 5 times
  slower.
- **At 100k nothing breaks, everything is slow.** The owner needs 20 s to build even a
  one-member add (OpenMLS walks the whole tree), a new member needs 123 s to open its
  Welcome (superlinear: 1.6 s at 10k), every member needs 7 to 19 s per commit and 6 s per
  application message, and keeps 490 MB of state for that one server. The 100k group took
  31 minutes to build with 5,000 adds per commit.
- **Add commits are constant** (691 bytes; 25 KB for 50 adds): they carry no update path.
- **Remove commits are O(N)**: 87 bytes per member, twice in a row. Membership commits come
  from one coordinator (the owner preferred) and members never send a self-update, so
  no member fills its path, the tree stays blank above the leaves, and the remover's update path must
  encrypt to the resolution of every copath node, which is almost every leaf. A tree whose
  members update their own leaves now and then would bring this down to O(log N).
- **The Welcome is O(N)**: about 403 bytes per member, the ratchet tree it carries. Base64
  on the wire adds a third. Against the relay's 64 MiB `maxPayloadLength` the Welcome fits
  at 100k (53.6 MB as base64, 80% of the limit) and stops fitting at about 125k members.
- **Application messages are O(N) per member** (63 ms at 1k, 0.61 s at 10k).
  `mls_scale_probe_message_cost` builds the same group on bare OpenMLS:

| leaves | credential | `max_past_epochs` 0 | `max_past_epochs` 3 | stored bytes, 0 / 3 |
|---:|---:|---:|---:|---:|
| 1,000 | 8 B | 0.4 ms | 4.9 ms | 0.96 / 1.17 MB |
| 1,000 | 200 B (our size) | 0.3 ms | 10.6 ms | 1.54 / 2.03 MB |
| 4,000 | 8 B | 1.0 ms | 84 ms | 3.8 / 7.5 MB |
| 4,000 | 200 B (our size) | 1.0 ms | 246 ms | 6.1 / 15.0 MB |
| 10,000 | 8 B | 5.5 ms | 271 ms | 9.8 / 21.3 MB |
| 10,000 | 200 B (our size) | 3.7 ms | 560 ms | 15.6 / 42.6 MB |

  Mean of 5 messages each; a run under heavier load measured up to 4 times these, the
  ratio between the columns held.

  The late-delivery window (`MAX_PAST_EPOCHS = 3`, `crypto/mls_manager.rs:29`) keeps each
  past epoch's member list in the message-secrets store, and OpenMLS writes that store
  back on every message, so cost follows N (and worse). Without the window the message
  costs a few ms at any size measured. The wrapper adds the full state save on every
  send (`persist_mls_state`, `node/crypto_handler.rs:1490`, from `send_mls_broadcast_in`
  `:2591` and `send_mls_broadcast_topic` `:2666`), which serializes every group of every
  server the device is in: 5 MB at a 1k server, 50 MB at 10k, per sent message.
- **Per-member state is about 5 KB per member** (the persisted blob, three past epochs
  included): 5 MB at 1k, 50 MB at 10k, 490 MB at 100k, per server, per device.

## 4. Part c: relay alone

**Setup.** The production C++ relay, built on the Mac by a bench-only script
(`relay-uws/bench/macos/build.sh`: the same sources as `CMakeLists.txt` at -O2, the
existing loopback test knobs, and a force-included shim, `macos_shim.h`, that makes the
Linux-only `memfd_create` fail cleanly so restart persistence is simply off). No product
code changed. Native TLS with a self-signed certificate. The load tool
(`relay-uws/bench/scale_probe`, Rust) opens real sessions (TLS, `auth_hello`, nonce,
Ed25519 signature over the auth message, as `ws_client` does), acks the stream and sends
heartbeats like the app, joins one unlocked room and drives one scenario. It counts
egress on the client side by frame kind; relay CPU time and RSS are sampled from the
relay process twice a second. It refuses any host but 127.0.0.1. One relay core
(the relay is single-threaded) on the M4; a VPS core is slower.

### 4.1 Connections

| sockets | relay CPU to connect them | per connection | relay RSS |
|---:|---:|---:|---:|
| 1,000 | 0.23 s | 230 us | 34 MB |
| 10,000 | 1.8 s | 180 us | 256 MB |
| 30,000 | 9.7 s | 324 us | 751 MB |
| 50,000 | 11 to 14 s | 220 to 275 us | 1.04 GB |

About 20 to 25 KB of relay RAM per connected device. The Mac stopped at about 55k sockets
from one loopback address (source ports).

### 4.2 Presence

| scenario | N | frames | egress | relay CPU |
|---|---:|---:|---:|---:|
| one join into a visible room | 1,000 | 1,027 | 170 KB | 4.5 ms |
| one join into a visible room | 10,000 | 10,202 | 1.69 MB | 68 ms |
| join storm (all N join at once) | 1,000 | 0.50 M | 84 MB | 2.0 s |
| join storm | 2,000 | 2.0 M | 336 MB | 8.2 s |
| join storm | 5,000 | 12.5 M | 2.1 GB | 58 s |
| join storm | 10,000 | 50.3 M | 8.4 GB | 336 s |
| every member re-joins a room it holds (door move, refresh) | 1,000 | | 55 MB | 0.23 s |
| every member re-joins a room it holds | 5,000 | | 1.38 GB | 5.5 s |

| presence churn | N | changes/s asked | relay CPU per change | ceiling on one core |
|---|---:|---:|---:|---:|
| leave and re-join | 1,000 | 10 and 50 | 10 to 14 ms | about 75 changes/s |
| inactive and active (app hidden and shown) | 1,000 | 10 and 50 | 12 to 14 ms | about 75 changes/s |
| leave and re-join | 10,000 | 10 and 50 | 131 ms | about 7.6 changes/s |
| inactive and active | 10,000 | 10 and 50 | 131 to 141 ms | about 7.6 changes/s |

Every presence change costs about 2N frames (a `peer_left` or `peer_joined` to everyone,
and the `members` answer), and each join is one synchronous loop over the room: a join
into 50k stalls the event loop for about 0.34 s. A storm is N^2/2 frames. The quadratic
here is not one bad client: it is N members each doing something normal. **A phone that
goes to the background about every 30 minutes makes a 10k room produce about 5.5 changes
per second, close to the core's ceiling of 7.6.**

### 4.3 Broadcasts (0x03) and topic sends (0x07)

| N | posts/s | deliveries | relay CPU | per delivery | median latency |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 10 | 103 k | 0.65 s | 6.3 us | 2 ms |
| 1,000 | 100 | 1.02 M | 6.2 s | 6.0 us | 2 ms |
| 1,000 | 300 | 3.06 M | 17.4 s | 5.7 us | 4.2 s (saturated) |
| 10,000 | 10 | 1.01 M | 9.2 s | 9.1 us | 65 ms |
| 10,000 | 30 | 3.02 M | 24.6 s | 8.1 us | 4.2 s (saturated) |
| 30,000 | 1 | 330 k | 3.5 s | 10.6 us | 131 ms |
| 50,000 | 1 | 550 k | 11.6 s | 21 us | 2.1 s |

2 KB payloads. Topic sends cost the same within 10%. The M4 core saturates at about 155k
deliveries/s at 1k members, 109k/s at 10k and 76k/s at 30k (the per-delivery cost grows as
the socket working set leaves the cache). On the VPS the 1 Gbps port caps first, at about
60k deliveries/s of 2 KB; presence stays CPU-bound. At 50k members the single client
process on the same Mac could not keep up above 1 post/s (the relay reported
backpressure drops), so 50k numbers are a floor.

### 4.4 What a door-proof (D1) room adds

Not driven by the tool (the room was unlocked); from measured crypto times and the code:

- each join with a proof adds one X25519 and HMAC check, 45 us on the M4;
- each delivery adds one door lookup per recipient, tens of nanoseconds next to the 6 us
  TLS write;
- **a lock move is the expensive part:** `relock_room` (`relay-uws/src/ws_handler.cpp:1715-1739`)
  re-checks every member's proof in one loop (about 0.45 s stall at 10k, 4.5 s at 100k),
  then every client's `SetDoor` makes it join again (`node/ws_client.rs:976`), and each
  re-join returns a full `members` list (4.2). One kick, ban or demotion in a 10k door room
  is about 23 s of relay CPU and 5.5 GB of egress.

### 4.5 For the phase G breaker

- An honest client joins every room again at connect: 50 servers and a few hundred DM
  rooms is about 250 joins, and every lock move on any of its servers adds one more join
  per server. A per-connection join budget must allow several hundred joins a minute.
- A reconnect into a server of N makes the reconnecting device send about 5 N frames to
  about N distinct devices (part a, 2.3): into 50 servers of 200 members that is about
  50,000 frames to 10,000 distinct targets, all honest. Until the sync digest is fixed the
  same reconnect also draws about 540 B x N^2 per server.
- The big-room costs (presence churn, lock moves, discovery) come from many members each
  doing one normal thing. No per-connection counter sees them, so a breaker cannot protect
  against them; only the protocol changes in section 5 can.

## 5. Extrapolation and the MLS member cap

**Assumptions.** Every member online with one device (the worst case for fan-out;
multiply by the online fraction and by devices per member for real servers). The relay's
practical uplink is about 107 MB/s (854 Mbps measured on the 1 Gbps port). Per-operation
models fitted from part a at N = 9 to 100:

| operation | relay frames | relay egress bytes |
|---|---|---|
| post one message | 2 sends, 2(N-1) deliveries | 1.45 KB x N |
| join | 21 N sends, 28 N deliveries | 29 KB x N + 535 B x N^2 |
| reconnect (one device) | 10 N sends (5 N by that device), 14 N deliveries | 13 KB x N + 530 B x N^2 |
| leave, kick or ban | N^2 carried frames | about 1.4 KB x N^2 |
| discovery, per server | N asks per 30 s | 55 B x N^2 per 30 s |
| MLS remove commit, per member | | 87 B x N, broadcast to N |

| members | post: egress | post: msgs/s to saturate relay | join or reconnect: egress | leave or kick: frames, egress | discovery: egress | MLS per message per member (today) | MLS state per server |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 1.45 MB | 74 | 0.56 GB | 1.0 M, 1.4 GB | 1.8 MB/s | 63 ms | 5 MB |
| 5,000 | 7.3 MB | 15 | 13.5 GB | 25 M, 35 GB | 46 MB/s | about 0.3 s | 25 MB |
| 10,000 | 14.5 MB | 7.4 | 54 GB | 100 M, 140 GB | 183 MB/s | 0.61 s | 50 MB |
| 100,000 | 145 MB | 0.7 | 5.4 TB | 10 G, 14 TB | 18 GB/s | 6.1 s | 490 MB |

Read it as: at 10k members today one reconnect moves more bytes than the relay sends in
eight minutes, and discovery alone wants more than the relay's uplink.

**What sets the cap today.** Members of a busy server reconnect all day (phones). Take one
reconnect per member per hour: the reconnect term alone is 530 B x N^3 per hour, about
4 MB/s at 300 members, 19 MB/s at 500, 150 MB/s at 1,000, past the relay's uplink. MLS CPU
agrees: at 500 members every member spends about 30 ms (a phone 100 ms or more) on every
message, so a channel at a few posts per second costs phones a third of a core. **Cap today:
300 to 500 members.**

**After five fixes** (each a contained change to code named above): a constant-size sync
digest instead of the per-author vector, no relay re-forward of an op its author already
fanned out, peer discovery by delta or not on a timer, no past-epoch window in OpenMLS
storage (or a window that does not copy the member list) and a state save that is not the
whole store per send. What remains is MLS itself and relay fan-out:

- every member processes every commit: 1 to 2 s per commit at 10k on a desktop core, 5 to
  10 s on a phone; a server of 10k with 1% daily churn has 100 commits a day plus every
  repair;
- every remove commit costs 87 B x N^2 of relay egress (8.7 GB at 10k, 0.2 GB at 1,500);
- every member keeps 1.5 to 5 KB per member per server (16 to 50 MB at 10k; the bare
  OpenMLS store without past epochs is the low end);
- the Welcome stays under 64 MiB until about 125k members, not a constraint below that;
- presence is relay CPU, not MLS: every change costs about 2N frames and 13 us x N of one
  relay core (part c), so a visible room of 10k tops out near 7.6 changes a second, about
  what 10k phones produce by going to the background now and then. A server above about
  5,000 needs lighter presence whatever its encryption.

**Recommended range: MLS up to 2,000 to 5,000 members after the fixes**, with the low end
for servers that are mostly phones. Above 5,000, community mode (one shared community key,
no tree, no per-member commit work) together with presence that is not broadcast on every
change. Until the fixes land, cap at **500**. The relay itself is not the limit at these
sizes: 50k sockets fit in about 1 GB, and one relay core delivers about 100k frames a
second.

## 6. Rerun

Each part is one command, run from the worktree root.

```bash
# a. Real node logic (52 minutes for the full ladder on the M4 mini)
cd rust/hollow_core && HOLLOW_SCALE_SIZES=5,9,13,20,30,50,75,100 \
  HOLLOW_SCALE_OUT=/tmp/g1_harness.csv \
  cargo test --lib node::test_harness::scaling_benchmark_mls_fanout -- --ignored --nocapture --exact
# Optional: HOLLOW_SCALE_FRIENDS=owner (every member the owner's friend, the 2026-08 shape),
# HOLLOW_SCALE_BATCH (growth joins at once, default 4), HOLLOW_SCALE_QUIET_MS (default 4000),
# HOLLOW_SCALE_MAX_SECS (default 240).

# b. MLS alone (1k and 10k: 2 minutes; 100k alone: 37 minutes)
cd rust/hollow_core && HOLLOW_MLS_SIZES=1000,10000 HOLLOW_MLS_BATCH=1000 \
  HOLLOW_MLS_OUT=/tmp/mls_probe.csv \
  cargo test --lib crypto::mls_scale_probe::mls_scale_probe -- --ignored --nocapture --exact
cd rust/hollow_core && HOLLOW_MLS_SIZES=100000 HOLLOW_MLS_BATCH=5000 \
  HOLLOW_MLS_OUT=/tmp/mls_probe_100k.csv \
  cargo test --lib crypto::mls_scale_probe::mls_scale_probe -- --ignored --nocapture --exact
cd rust/hollow_core && HOLLOW_MLS_SIZES=1000,4000,10000 \
  cargo test --lib crypto::mls_scale_probe::mls_scale_probe_message_cost -- --ignored --nocapture --exact

# c. Relay alone
bash relay-uws/bench/run_scale_probe.sh joinone,churn,bcast,topic 1000 --extra 20 \
  --churn rejoin,toggle --churn-rates 10,50 --rates 1,10,100,300 --secs 10
bash relay-uws/bench/run_scale_probe.sh storm 2000            # also 5000
bash relay-uws/bench/run_scale_probe.sh joinone,churn,bcast,topic 10000 --extra 20 \
  --churn rejoin,toggle --churn-rates 10,50 --rates 1,10,30 --secs 10 --storm-cap-secs 2400
bash relay-uws/bench/run_scale_probe.sh bcast,topic 30000 --fill hidden --rates 1,10 --secs 10
bash relay-uws/bench/run_scale_probe.sh bcast,topic 50000 --fill hidden --rates 1,3 --secs 10 --conc 256
bash relay-uws/bench/run_scale_probe.sh rejoin_all 1000       # also 5000
# Each starts a fresh relay on 127.0.0.1 (built once by bench/macos/build.sh, which needs
# brew openssl@3 and libsodium), writes one JSON line per phase to $OUT
# (default .team/relay/results.jsonl) and kills the relay by pid.
```

The harness CSV has one row per phase, size and wire kind (`cmds`, `deliveries`,
`bytes_out`, how many devices sent it and the most one device sent), plus the relay route
of every command. The tables above come from it with the background and mock-only kinds
taken out.

## 7. Limits of this probe

- The harness has no WebRTC, so the CRDT gossip mesh never carries an op; the leave and
  kick N^2 is the no-mesh case, which is every phone and every mesh still dialing.
- One device per member and everyone online. Multi-device members multiply the Olm pairs,
  `sync_request` count and fan-out by their device count.
- The mock relay is not the C++ relay: it does not model per-socket send buffers,
  backpressure or CPU. Part c measures those.
- Times in part b are a shared M4 core; sizes are exact.
