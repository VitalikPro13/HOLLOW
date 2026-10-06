# Relay Server — uWebSockets C++ Production Relay

The relay is the ONLY infrastructure component in the entire Hollow distributed system. Every text message, CRDT sync op, MLS key exchange, WebRTC signaling offer, file header, typing indicator, and presence event between peers flows through this single C++ process. It runs on an OVH VPS at `relay.anonlisten.com:443` with native OpenSSL TLS. The relay is zero-knowledge — it routes opaque encrypted payloads between authenticated peers without decrypting or inspecting content.

Source: `relay-uws/src/` (6 source files + 2 headers + `json.hpp`)
Build: CMake, C++20, links against uSockets (static), OpenSSL, libsodium, zlib, pthreads
Binary name: `hollow-relay`

---

## Security model after design A-D4 (2026-09-29, HOL-SEC-063..066)

- **Auth v2** (`auth_frame.h`): `auth_hello` gets a per-socket 32-byte nonce
  (`auth_challenge`); the auth frame (`v:2`) signs `hollow-ws-auth2`, the relay's domain
  (`auth_domain(--domain)`: lowercase, no port), the nonce, device, time, mode
  (`full`/`fetch`/`guest`) and SHA-256 of the license key. One attempt per nonce. v1 is
  refused since 0.12 (`ACCEPT_AUTH_V1` = 0, deployed 2026-10-05).
- **Fetch sockets**: rooms in `PerSocketData::fetch_rooms`, never over a full socket's
  slot, no roster/presence, never in `discover_peers`; `leave` passes the socket as
  `expected_ws`; close leaves only its own slots.
- **Inbox rooms**: `WsRoom::owners` = sockets whose device the held roster counts a
  member; `receives_in_room` limits every fan-out, roster, presence, discovery and
  check_peers co-membership to owners; a deposit for the master also goes live to the
  owners.
- **Rosters (design ID-1R, 2026-10-02, HOL-SEC-078)**: an inbox join may carry
  `inbox_roster` (the device's own roster, serde JSON). `inbox_owner_by_roster` parses it
  (`roster::from_json`, strict like serde), refuses one over 256 KiB, past a ceiling or
  for another master, and hands it to `RosterBook::show` (`roster_book.h`): verify (a
  statement the held roster already has skips its signature check), merge into the one
  roster held per master, stamp first sights of pending joins (wall clock, keyed
  `base|device` so a recovery restarts them, HOL-SEC-082), fold, judge.
  `roster.h` mirrors `identity/roster.rs` rule for rule; `test/test_roster.cpp` replays
  the vectors the Rust test `roster_vectors_are_current` writes to
  `test/roster_vectors.json` (regenerate with `HOLLOW_WRITE_ROSTER_VECTORS=1`; change
  both or neither). A shown roster decides its socket's ownership on its own; a plain
  re-join keeps an owner. A change drops every owner the fold stops counting
  (`drop_inbox_owners`, peer_left to the owners left). Registry: `FairShare`, 128 MB,
  charged to the member who last showed it; snapshot codec v7 (JSON + first-sight ages);
  restore takes it as held, unverified. The 0.11 master-signed list (`inbox_proof`,
  `inbox_owner_proved`, version marks) is read only while
  `ACCEPT_DEVICE_LIST_INBOX_PROOF` (off since 0.12) and never for an identity whose
  held roster is protected or for a device it removed. Crypto: `roster_crypto.h`
  (`peer_id_key` = base58 decode, refuses ids over 64 chars; `verify_ed25519_raw`).
- **Rings** (`ring_auth.h`, `ring_evict.h`): control signed by the change key of the
  newest join-lock link (`hollow-ring1`), legacy rooms' topics carry the owner (below),
  unsigned = refresh only once `ACCEPT_UNSIGNED_RING_CONTROL` is off; eviction by the
  address share holding the most bytes, `MAX_RING_FRAME_BYTES` 256 KB, 512 rings per
  server, the heaviest share's least recently used ring at the global cap, per-frame
  retention; snapshot codec v7 (v6 shares, v7 rosters).
- **Fair shares (HOL-SEC-069/070, session 18)**: every table a stranger can fill charges
  each entry to the writer's address share (`share_block`: v4 address or v6 /48, hashed
  by `share_id` = BLAKE2b under `RelayState::share_key`, replaced hourly, never
  persisted) through `FairShare` (`fair_share.h`); a full table evicts from the share
  holding the most. Waiting frames: ONE 512 MB budget over DM + ring frames, each weighed
  with `FRAME_OVERHEAD_BYTES` (1 KB), exact (`OfflineIndex::released(seq)` on every
  removal); the old per-sender key caps are gone. Rings (65,536), join lock chains (128 MB,
  `JoinLocks::record_bytes`), destroy orders, device-list marks and push registrations
  (128 MB, `charge_registrations`) all ride it; per-target slots and a ring's frames evict
  the heaviest share. Subscriptions: 1,024 rooms / 16,384 topics per socket, past it that
  room goes unfiltered. Channel-push throttle: 256 servers per target. Snapshot codec v6
  carries every share.
- **Legacy ring topics (HOL-SEC-071)**: in a 32-hex room a signed control's channels must
  be `{owner}.{channel}` for the owner it is signed for (`ring_auth::in_own_topics`); a
  stop reaches only that owner's topics; `ring_namespace` counts the per-server cap per
  owner. The first-signer binding is gone.
- **Nicknames**: `nickname_proof` holds the master's signature (`nickname_claim_message`
  in validate.h); resolve returns it; unsigned claims only while
  `ACCEPT_UNSIGNED_NICKNAME_CLAIMS`.
- **The 0.11 switches are OFF since 0.12 (deployed 2026-10-05)**: `ACCEPT_AUTH_V1`,
  `ACCEPT_UNSIGNED_RING_CONTROL`, `ACCEPT_UNSIGNED_NICKNAME_CLAIMS`,
  `ACCEPT_DEVICE_LIST_INBOX_PROOF`. Each is `HOLLOW_ACCEPT_<NAME>` (default 0,
  overridable with `-D`); `test/run_live.sh` still builds both settings. The live
  probes on the box (`~/relay-next/relay_probe.py`, `inbox_probe.py`) expect the
  refusals.
- **Live handler tests (session 32)**: `test/run_live.sh` (called last by `run_tests.sh`)
  builds the real relay twice, every switch 1 and every switch 0, listens on 127.0.0.1
  only (`HOLLOW_RELAY_TEST_LOOPBACK`), self-signed cert, random port, and drives it with
  `test/test_relay_live.cpp` (a TLS WebSocket client doing real auth v2): the switches,
  guest refusals, the fetch slot rule, inbox audiences, D1 door rooms, forwarder rooms,
  hidden sockets' channel copies, the catch-up end mark, 192 checks per
  build. Negative checks never sleep (a round trip from each side first); each socket
  connects from its own 127.0.x.y; no push token is ever registered (the sidecar on
  127.0.0.1:3001 is production's). Needs the uWebSockets/uSockets submodules and the
  `openssl` CLI, else it skips. ~25 s plain, ~70 s under `SANITIZE=1`.
- **Client JSON depth cap (C-RP-01, session 34)**: every JSON text a client sends (text
  frames, auth frames, a kill deposit's decoded blob) is parsed only through
  `client_json::parse` (`client_json.h`), which refuses nesting past 32 before nlohmann
  builds anything. nlohmann parses and frees any depth iteratively, but `dump()`, copies
  and `==` recurse per level: one join with a 200,000-deep `inbox_roster` (or a deep
  `subscribe` topics array, copied by a ternary) overflowed the stack, a crash that
  skips the snapshot. Real frames nest 5 deep at most. A new client-JSON parse site uses
  it, never `json::parse`; the roster's size is measured as held
  (`roster::to_json(*shown)`), never by re-dumping client JSON. Tests:
  `test_client_json.cpp`, `test_kill_order.cpp`, live `test_deep_json`.

## Door-proof server rooms (design D1, 2026-10-02, HOL-SEC-091)

- **Locked room** = a 40-hex server id with a join lock record (`room_lock`). Legacy rooms,
  meetings, DM and inbox rooms are unchanged.
- **Proof**: `RelayState::door_key` (X25519, minted at start, RAM only) rides
  `auth_challenge.door_key`; a join's `door_proof` is checked by `door_opens` against the
  newest link's door, bound to `PerSocketData::door_nonce` (the challenge the socket logged
  in with; `auth_nonce` is spent at login). Pure rules in `door_room.h`, unit test
  `test_door_room.cpp` (pinned vector shared with Rust).
- **`Audience`** (`audience()`): `sees` = inbox owners / locked-room provers / everyone;
  `reachable` (directs) = inbox owners / everyone. Every fan-out, discover, check_peers,
  0x09 in-room test and topic catch-up uses it. `shares(pid, other)` = `sees(pid)` and the
  forwarder pairing below: every roster, presence, co-member and broadcast fan-out asks it.
- **0x09 from a hidden socket** (HOL-SEC-127, session 33): `handle_binary_channel_direct`
  takes a channel copy or push only from a socket that `sees` the room.
- **0x0A** = public broadcast, delivered as 0x05; a prover's reaches hidden sockets too.
- **Lock move** (`relock_room` from `handle_lock_put`): who saw keeps it for
  `door_room::GRACE_MS` (60 s); a stored proof that opens the new door (a lock put back)
  proves at once. `sweep_door_grace` (5 s timer) ends graces: peer_left to provers,
  `members [self] proved:false` to the demoted socket.
- No new state in the snapshot: proofs die with the socket, the key with the process.
- **Forwarder rooms** (HOL-SEC-126, session 33, `fwd_room.h`): `fwd:{X}` pairs every member
  with X (the forwarder the name says, compared with the socket's authenticated id) and
  nobody else: X sees and reaches everyone, the others only X (roster, presence,
  check_peers, discover, broadcasts, topics, JSON and binary directs, deposits, 0x09). A
  `fwd:` room keeps no ring. The VPS forwarder's room holds viewers of every server, so
  before this anyone joining it saw who watched forwarded shares and when. Unit test
  `test_fwd_room.cpp`; MockRelay mirrors it (`RelayInner::paired/shares`).
- Live probe: `~/relay-next/door_probe.py [url] [domain]` (24 checks; mind the 10 new
  connections per minute per address when chaining probes).

## Resumable sessions (2026-10-06, RESUMABLE_SESSIONS_PLAN.md section 9)

A device's session outlives its socket: both sides count the stream frames they handled, the relay
keeps every frame it sent until the device acks it, and a socket that dies mid-write costs a resume,
not a loss. Spec: `reports/planned/relay-and-sync/RESUMABLE_SESSIONS_PLAN.md` section 9 (the wire,
binding) and section 11 (as built). Client half: `rust_networking.md`, ws_client.rs. Files:
`session.h` (constants, the counted-frame classification, sid shape and constant-time `sid_equal`,
`Ring`, `Session`), `session_bounds.h` (the hooks seam), `session_snapshot.h` (restart),
`drain.h` (SIGTERM hint), `offline_index.h` (budget charging), `auth_frame.h` (v3), and the session
code in `ws_handler.cpp` (`mint_session`, `resume_session`, `enter_grace`, `end_session`,
`send_stream`, `send_held`, `send_presence`, `adopt_restored_sessions`, `sweep_sessions`, the
`.open`/`.message`/`.close` handlers). Tests: `test_session.cpp`, `test_session_bounds.cpp`,
`test_auth_frame.cpp`, `test_snapshot_codec.cpp`, the live cases in `test_relay_live.cpp`.
`test/session_vectors.json` (v3 auth bytes, session shapes, counted frames) pins `test_session.cpp`
and `test_auth_frame.cpp` to the Rust client's `relay_session.rs` tests.

- **Handshake.** `auth_challenge` always carries `"session":1`. Only a full v3 login has a session:
  `"new"` mints one (`mint_session`: 128 random bits as 32 hex, the socket's challenge kept as the
  session's door nonce, the minting address share), and a sid resumes (`resume_session`) when
  `state.sessions[peer]` holds that sid (`sid_equal`, constant time; another device's sid is
  answered exactly like an unknown one) and `ring.can_resume_from(in_h)` (`acked <= in_h <= sent`).
  Otherwise the same socket gets a fresh session with `resume_failed: "unknown"` or `"bad_h"`.
  Shape rules (`auth_frame.h:session_fields`): full takes `"new"` or a sid, fetch and guest take
  `"none"`, and `"new"` or `"none"` with `in_h` other than 0 is `bad_auth`. A v2 login or `"none"`
  gets a plain `auth_ok` and no session. `auth_ok` and `resumed` advertise `grace_secs` and
  `hb_secs`; the client ignores both.
- **Any non-fetch login ends a session the device still holds** (`handle_auth` calls `end_session`
  before the supersede): v2 full, guest, v3 `"new"`, a `resume_failed`. Its ring hands off as on
  expiry and its grace rooms are let go silently. Fetch sockets never touch sessions.
- **States**: `Live` or `Grace`; gone = erased from `RelayState::sessions` (keyed by the device
  peer id, one per device). `PerSocketData::sid` names the session a socket carries;
  `live_session(state, data)` (same sid, Live, not superseded), `grace_session(peer)`,
  `socket_of(session)`.
- **Presence follows the socket, delivery follows the session.** `enter_grace` (the close handler,
  for a socket whose session is live): the device leaves each room's `peers` now (`peer_left` to
  whoever saw it) and goes into `WsRoom::held`; it leaves `peer_sockets` and `peer_rooms`
  (`go_offline`: offline for push, push debounce reset, license seat released); the session keeps
  its rooms with owner flags and door standing, its subscriptions, nickname, link code and inactive
  flag, and the closing socket's per-IP slot (`hold_ip_slot`; the close handler skips its own
  decrement). A room holding only `held` devices is not erased (`leave_room`). Every fan-out walks
  `peers` (live sockets, `send_stream`) and then `held` (`send_held`, ring only) under the same
  audience gates; topic frames to a grace session pass the session's stored filter. A device whose
  fetch socket holds the room slot while its full session is in grace gets both copies (the
  receiver dedups by message id).
- **Send-site classification** (every relay-to-client write is one of these):
  - `send_stream(ws, bytes, binary, Meta)`: a stream frame. On a live session's socket it enters
    the ring (`ring_in` -> `session_bounds::ring_push`) BEFORE `write_raw`. Every forwarded frame
    (0x02, 0x05, 0x06, 0x08, JSON `msg` and `direct`), buffered and mailbox replays, topic
    catch-ups, counted answers.
  - `send_held(state, peer, ...)`: the same frame for a session in grace: into its ring only.
  - `send_presence(ws, text)`: unasked presence (`peer_joined`, `peer_left`, a door-grace
    `members`): never counted or ringed, and withheld while the session is `inactive`.
  - `send_json(ws, j)`: an answer, counted and ringed (`Meta::answer()`, charged to the receiver's
    own share) unless its type is uncounted (`session::relay_type_counts`), as `kill_signal` is.
  - `write_raw`: the auth answers, `resumed`, `hb_ack`, `ack`, the resume `members`, and the
    `members` answer to a join, which an inactive session gets too (it asked for it).
  - `Meta` carries the sender's address share (`fair_share.h`) and, for the 0x06 kinds
    `offline_buffer` takes (`Kind::Direct`, `DirectImage`, `ChannelCopy`), the kind and room the
    expiry hand-off files the frame under. Everything else is `Kind::Other`.
- **CRITICAL: classify every new send site, and every new JSON type the same way on both sides**
  (`session::relay_type_counts` / `client_type_counts`, `relay_session.rs`, `session_vectors.json`).
  A stream frame written with `write_raw` is never ringed and is lost to a dead socket; a frame one
  side counts and the other does not shifts every later ack and resume by one, silently.
- **Counting on arrival** (`.message`): a stream frame from the device is counted (`count_in`)
  before any handler or gate decides on it; a frame a gate refuses was still handled. Text over
  1 MiB is never parsed but still counts, as does text that does not parse. The relay acks
  `{"type":"ack","h":in_h}` after 16 frames, or 2 s after the first unacked one (the `acks_due`
  queue, popped by `sweep_sessions` on a 250 ms session timer). `hb` is answered at once with
  `hb_ack { h: in_h }` and acks the ring at the `hb`'s own `h`; `hb` on a socket without a session
  gets `hb_ack { h: 0 }`. An `h` out of range acks nothing.
- **The ring** (`session::Ring`): its entries cover `(acked, sent]` exactly once, in order, each a
  real frame or a tombstone run. Per-session caps 8 MiB and 4096 real frames (`enforce`): past them
  the oldest real frame of the sender share holding the most weight (bytes plus 1 KiB per frame)
  becomes a tombstone (`evict_one`, `bury`) and adjacent tombstones merge. A frame over 8 MiB is
  still written live but enters the ring as a tombstone (`push_gap`). A tombstone replays as one
  counted `{"type":"gap","n":N}`, only the part after the client's `in_h`. The rings of one fan-out
  share one buffer (`shared_ptr`). No refusal and no dropped socket: overflow only ever becomes a gap.
- **Resume** (`resume_session`): a grace session gives back its held IP slot (the new socket took
  its own); a session still live on another socket (a make-before-break transfer) marks that socket
  superseded and closes it 1000 `moved`, silently. Re-checks: each inbox it owned stays owned only
  while `still_owner` (the roster book's fold counts the device; no roster held for the identity =
  kept). The socket takes the session's subscriptions and door nonce; a `restored` session takes the
  new challenge instead and answers `reprove: true`. Answers `resumed { h: in_h, gap:
  ring.gap_after(in_h), reprove, grace_secs, hb_secs }`, acks the ring at the client's `in_h`, then
  in order: every waiting `kill_signal`, one `members` per session room (`proved` in locked rooms),
  the ring replay after `in_h`, on `gap` the `inbox:` mailbox of every inbox room it still owns
  (`replay_mailbox_no_delete`; a resume joins nothing, so a deposit that fell into the gap would
  never come back otherwise), and `peer_joined` only in rooms where its presence had gone (a live
  transfer sends none). It also resets the channel-push offline cap for its rooms.
- **Push in grace**: a device in grace is not in `peer_sockets`, so it is offline for push. A 0x04,
  0x08 or JSON `direct` into a grace ring also calls `try_push_notify` (debounced as before), unless
  the device's fetch socket holds the room slot and took the frame live. 0x02 chunks never push. 0x09
  is unchanged: a grace target is not in the room's `peers`, so it buffers and pushes as an offline
  member.
- **Ending** (`end_session`): grace expiry (the `grace_ends` queue, `sweep_sessions`), the client's
  `end` (then close 1000 `end`), table eviction, a per-IP slot taken over, any non-fetch login of the
  device, and a 1008 close (a revoked license) instead of grace. `ring_take_all` then `hand_off`:
  only the binary 0x06 kinds move to `offline_buffer` under their room, each under its own cap there
  (`buffer_offline_msg`, charged again), so the replay on join and push take over. Broadcasts, topic
  frames, 0x02 chunks, JSON answers and JSON `direct` frames do not (topic rings, sync and file asks
  cover them). A grace session then lets go of its rooms (`let_go`: held, owner flag, door standing;
  the room goes with its last peer) and of its nickname and link code (`release_bindings`); a live
  one leaves its socket without a session (`sid` cleared). The held IP slot is freed.
- **`inactive` / `active`**: `inactive` sets the flag (presence withheld by `send_presence`);
  `active` clears it and sends one `members` per room (`send_all_members`). The flag survives grace,
  resume and the snapshot. `end` without a session is ignored.
- **Nickname**: a binding whose holder has a session, live or in grace, is not stale
  (`nickname_binding_is_stale`).
- **The hooks seam, `session_bounds.h`**: every ring mutation, mint and end goes through
  `ring_push`, `ring_ack`, `ring_take_all`, `make_room`, `hold_ip_slot`, `release_ip_slot`,
  `grace_slot_victim`. **CRITICAL: never mutate a `Ring` directly**: the global budget and the
  per-IP counts then drift silently. **Never `ring_push` while iterating a ring**: a push appends
  and may bury entries, which invalidates the deque's iterators (`resume_session` replays the ring
  with `write_raw`, and the gap mailbox replay, which does push, runs after the ring loop). A
  `ring_push` never drops a buffered DM or topic frame itself, because it runs inside loops over
  those buffers (a replay on join, a topic catch-up): such a budget victim waits for the settle
  point, `enforce_buffer_budget` in main.cpp's loop post-handler, or the next deposit.
- **Global budget** (`offline_index.h`): ring frames share the one 512 MB `OfflineIndex` budget
  with DM and topic frames (`stamp_session`). A fan-out buffer held by many rings is RAM once, so its
  bytes are charged once, keyed by the buffer pointer, to one holder; every holder pays its own 1 KiB
  overhead, and when the charged holder lets go another holder is reweighed to carry the bytes.
  **CRITICAL: exact only while every frame leaving a ring goes through `forget(budget_seq)`** (an
  ack, the ring caps, the session's end: `session_bounds::detail::forget` is the ring's on-drop). A
  budget victim inside a ring is buried there (`bury_session` -> `Ring::evict_budget_seq`) and the
  device later sees it as a `gap`.
- **Table cap** (`make_room`, from `mint_session`): at most 262,144 sessions. Past it, the address
  share holding the most sessions (the newcomer counted; a tie goes against the newcomer's own
  share) gives one up: a session in grace before a live one, then the one closest to its end. It
  ends as on expiry; a live victim's socket closes 1000 `session_lost`.
- **Per-IP slots**: a grace session keeps its socket's slot under `MAX_CONNS_PER_IP` (34) until
  gone. In `.open` the rate check (10 new per minute) runs first; at the cap, `grace_slot_victim`
  picks the session in grace at that address closest to its end and ends it, so a device coming back
  is not refused by the slot its own session holds; with none, `ip_limit`. `data->ip_key` is set only
  once the slot is taken, so a refused socket gives nothing back on close (the old code decremented a
  slot it never took). Restored sessions hold no slot (addresses are never snapshotted).
- **Grace length**: `--session-grace-secs` (Docker `SESSION_GRACE_SECS`, `SELF_HOSTING.md`
  "Dropped connections"), default 120, held to 30..600 (`parse_grace_secs`, clamped again in
  `setup_ws_handler`). The test-only define `-DHOLLOW_RELAY_TEST_GRACE_SECS=5` (`test/run_live.sh`)
  overrides it so the live tests watch a grace run out. `idleTimeout` is 45: clients beat every
  15 s.
- **Snapshot v9** (`session_snapshot.h`, `SessionRec` in `snapshot_codec.h`): per session the sid,
  peer id, minting share, `inactive` flag, `in_h`, rooms with owner flags, subscriptions, nickname
  (with master and proof) and link code with their expiries, the ring's `sent` and `acked`, and its
  entries (tombstones as runs; real frames as an index into `buffers`, where each fan-out buffer is
  written once, plus binary flag, share, kind, room and the old budget stamp). Not carried: door
  standing, the door nonce, the per-IP slot, ack timers. Restore: `prepare` judges each record
  (shapes, `Ring::restore` coverage, the ring cap per frame) and drops a bad one alone
  (`sessions_dropped`), and caps the table by the heaviest share; the ring frames rejoin the budget
  in old-stamp order, interleaved with DM and topic frames (`snapshot.cpp:apply`); `place` restores a
  nickname or link code only if unexpired and free. `adopt_restored_sessions` (in `setup_ws_handler`)
  puts every one in grace with the timer starting at load, `restored = true` (its resume answers
  `reprove: true`, its locked rooms come back unproved), its rooms `held` with their owner flags.
- **Drain** (`drain.h`, main.cpp's shutdown tick): on SIGTERM, in one loop tick, every live
  session's socket gets `{"type":"reconnect","after_ms":N}` (uncounted, N uniform in 2000..10000 via
  `randombytes_uniform`), then the snapshot, then `app.close()`. Nothing counted is written after
  the snapshot.
- **Close reasons**: the relay closes 1000 `moved` (the session moved to a newer socket),
  `superseded` (another login of the device), `end` (after the client's `end`), `session_lost` (a
  live session evicted by the table cap); a 1008 close (`license_revoked` and the other policy
  closes) ends the session. The client closes 1000 with `suspend`, `drain` or `end`.
- **Nothing about sessions is logged**, not even a count in the snapshot lines.

## config.h — Configuration

### Config struct

All fields have defaults and can be overridden via CLI args:

| Field | Default | CLI Flag | Description |
|-------|---------|----------|-------------|
| `port` | `443` | `--port` | TLS listen port |
| `public_ip` | (empty) | `--public-ip` | DEAD. Parsed and never read; the flag is kept only so old unit files keep starting, and it is out of `print_help` |
| `domain` | `"relay.anonlisten.com"` | `--domain` | The public host clients connect to. `turn_uris()` builds the TURN URIs from it |
| `keys_file` | `"keys.json"` | `--keys-file` | License keys JSON file path |
| `cert_file` | `/etc/letsencrypt/live/relay.anonlisten.com/fullchain.pem` | `--cert-file` | TLS certificate (fullchain) |
| `key_file` | `/etc/letsencrypt/live/relay.anonlisten.com/privkey.pem` | `--key-file` | TLS private key |
| `turn_secret` | (empty) | env `TURN_SECRET` | HMAC secret for TURN credential generation |

### config.h:parse_args()

Reads CLI flags sequentially. `TURN_SECRET` is loaded from the environment variable (not a CLI arg). Returns a `Config` struct. Calls `print_help()` and `exit(0)` on `--help`.

---

## state.h — Server State

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_CONNS_PER_IP` | 34 | Max simultaneous WS connections per IP |
| `MAX_NEW_CONNS_PER_MIN_PER_IP` | 10 | Max new connections per minute per IP (sliding window) |
| `MAX_GUEST_ROOMS` | 3 | Max rooms a guest can join |
| `GUEST_IDLE_SECS` | 1800 | Guest idle timeout (30 min no binary activity) |
| `GUEST_BINARY_PER_MIN` | 10 | Max 0x03 binary frames per minute for guests |

### Per-IP keying: `ip_limit_key()` (ws_handler.cpp)

ALL per-IP accounting (connection caps) keys through `ip_limit_key(getRemoteAddressAsText())`:
- IPv4 → the dotted-quad address.
- **v4-MAPPED addresses are unmapped first** — the relay listens dual-stack on `[::]:443`, so every IPv4 client arrives as `::ffff:a.b.c.d` (uWS prints uncompressed v6 hex; uSockets does NOT unmap). Truncating those to /64 without unmapping collapses ALL IPv4 users into one `::/64` bucket → MAX_CONNS_PER_IP becomes a global cap (caught live 2026-07-05).
- Real IPv6 → truncated to the **/64 prefix** (`"2001:db8:1:2::/64"`) — one host owns a whole /64, per-address caps are trivially bypassed.
Any future per-IP feature MUST reuse this helper.

### No byte quotas (2026-08-28)

The 10 GiB/day per-IP byte budget (`DAILY_BYTE_BUDGET`, `bytes_today`/`budget_day`, `get_bandwidth`, the `1008 "bandwidth_limit"` close, `sweep_ip_budgets`) was REMOVED end to end. It metered every binary WS frame both ways (so share audio over `0x03`, sync, asset pulls all counted) while never touching TURN, a separate process. Volume fairness now lives BELOW the relay:

- **CAKE on the host NIC** — `tc qdisc replace dev ens16 root cake bandwidth 950mbit besteffort dual-dsthost` (persisted as `hollow-cake.service`). Per-destination-host fair share engages ONLY when egress saturates; an idle line is free to anyone. `besteffort` ignores DSCP so a client cannot jump the queue by marking packets. 950 Mbit sits ~9 percent under the MEASURED raw ceiling (2026-08-28, cake removed, 32 curl streams, NIC counters: 1047 Mbit egress to Cloudflare `__up`, 882 Mbit ingress from `proof.ovh.net`), because the shaper must be the bottleneck for fairness to exist. With cake on, the same test pins at exactly the configured number. The earlier ~830 figure was the download source throttling; never size the shaper from a single-source test or the nominal port. `/server-stats` reports `bandwidth_cap_mbps` = the shaper ceiling.
- **coturn peer lock** — see the TURN section below. The WS relay was already closed by construction (room-membership gated, no exit to the internet); the lock gives TURN the same shape.

Older clients still send `get_bandwidth` every 30 s; it is an unknown command and falls through silently. Rule stays: abuse is bounded by fair share, NEVER by a cap or a silent drop.

### coturn peer lock (2026-08-28)

`/etc/turnserver.conf` on the VPS (backup `turnserver.conf.bak-2026-08-28`; template in `relay-uws/turnserver.conf.example`):

```
denied-peer-ip=0.0.0.0-255.255.255.255
denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
allowed-peer-ip=<relay v4>
allowed-peer-ip=<relay v6, BOTH global addresses>
no-tcp-relay
```

A TURN allocation may only exchange packets with the relay host itself, i.e. another authenticated Hollow client's allocation on the same coturn. Before the lock the live config had NO `denied-peer-ip` at all and TCP relay (RFC 6062) enabled: an open UDP+TCP proxy for anyone holding 1-hour credentials. Calls lose nothing: `relay<->srflx` pairs now fail at CreatePermission (403) and libwebrtc prunes them, ICE settles on `relay<->relay`, same bytes on the line. Verified with `turnutils_uclient -W <secret>` on the VPS: external peer → `channel bind: error 403 (Forbidden IP)`; client-to-client (`-y`) → 20/20; TCP relay (`-T`) → `error 442`. Multi-relay future: every relay's addresses join the allow list (or each relay allows itself + siblings).


### IPv6 (2026-07-05)

Relay serves dual-stack natively (uWS binds `[::]:443` by default). coturn listens on all system addresses both families (`listening-ip` pin removed; `external-ip` removed — public v4 is on-interface, no NAT). DNS: `relay.anonlisten.com` has A + AAAA (`2001:41d0:ab01::4:0:d`, the OVH DHCPv6-stable address). Client code is family-agnostic; libwebrtc gathers v6 ICE automatically. See memory `project_relay_ipv6`.

### PerSocketData (per-connection state)

Attached to every WebSocket via uWebSockets' templated user data. Fields:

| Field | Type | Description |
|-------|------|-------------|
| `peer_id` | `std::string` | Hex-encoded Ed25519 public key, set on auth |
| `authenticated` | `bool` | `false` until auth handshake completes |
| `auth_timer` | `us_timer_t*` | 10-second auth timeout timer, nulled after auth or on close |
| `license_key` | `std::string` | The license key this peer authenticated with (empty if license not required) |
| `is_guest` | `bool` | `true` if auth included `"guest": true` flag. Guests are invisible to members, rate-limited, room-capped |
| `ip_key` | `std::string` | Normalized `ip_limit_key` (v4 addr / v6 /64; stored for decrement on close, never logged) |
| `ip_state` | `IpState*` | Cached pointer into `state.ip_states` for zero-lookup per-frame byte accounting (stable: values survive rehash; entry never erased while `active_count > 0`) |
| `last_binary_activity` | `steady_clock::time_point` | Last 0x03 binary frame timestamp (for guest idle timeout) |
| `binary_frames_this_minute` | `uint32_t` | Guest rate limit counter (reset every 60s) |
| `minute_window_start` | `steady_clock::time_point` | Start of current rate limit window |

### IpState (per-IP connection tracking)

In-memory only — never logged, never persisted. Erased on close once `active_count == 0`.

| Field | Type | Description |
|-------|------|-------------|
| `active_count` | `uint32_t` | Currently open connections from this IP |
| `recent_connects` | `deque<steady_clock::time_point>` | Sliding window of connection timestamps for rate limiting |

### PeerEntry (signaling registration)

Used for HTTP-based peer discovery (bootstrap):

| Field | Type | Description |
|-------|------|-------------|
| `peer_id` | `std::string` | Peer identity |
| `addresses` | `vector<string>` | Network addresses (up to 5) |
| `last_seen` | `uint64_t` | Unix timestamp of last registration |

### WsRoom

```cpp
struct WsRoom {
    std::unordered_map<std::string, SSLWebSocket*> peers;  // peer_id -> ws pointer
};
```

A room is a named group of connected WebSocket peers. Rooms are created implicitly on first join and destroyed when the last peer leaves. The key is the room code string (typically a hex-encoded server ID or DM channel ID).

### ServerStatsCache

Caches `/server-stats` JSON for 5 seconds to avoid re-reading `/proc` on every request:

| Field | Type | Description |
|-------|------|-------------|
| `cached_json` | `string` | Pre-serialized JSON response |
| `fetched_at` | `steady_clock::time_point` | When cache was populated |
| `prev_rx_bytes` / `prev_tx_bytes` | `uint64_t` | Previous sample's network counters |
| `prev_sample_at` | `steady_clock::time_point` | When previous sample was taken |
| `rx_mbps` / `tx_mbps` | `double` | Calculated bandwidth rates |
| `has_prev` | `bool` | Whether a previous sample exists (false on first call) |

`is_fresh()` returns true if cache is less than 5 seconds old.

### RelayState (global server state)

| Field | Type | Description |
|-------|------|-------------|
| `signaling_rooms` | `unordered_map<string, vector<PeerEntry>>` | HTTP signaling: room_code -> registered peers |
| `ws_rooms` | `unordered_map<string, WsRoom>` | WebSocket rooms: room_code -> room with peer map |
| `peer_rooms` | `unordered_map<string, unordered_set<string>>` | Reverse index: peer_id -> set of room codes they're in |
| `peer_sockets` | `unordered_map<string, SSLWebSocket*>` | peer_id -> WebSocket pointer (for license kicks + online count) |
| `ip_states` | `unordered_map<string, IpState>` | Per-IP connection tracking (in-memory only, never logged) |
| `guest_sockets` | `unordered_set<SSLWebSocket*>` | All guest WebSocket pointers (for idle timeout iteration) |
| `guest_count` | `size_t` | Global guest connection counter |
| `license` | `LicenseState` | License key validation state |
| `stats_cache` | `ServerStatsCache` | Cached stats response |

`online_users()` returns `peer_sockets.size() - guest_count` (guests excluded from the count).

### Backpressure

No soft backpressure limit — removed because it silently dropped CRDT sync messages and broke all offline-to-online flows. Hard limit (64 MB) is set via uWebSockets' `.maxBackpressure` in `setup_ws_handler()` as a safety net for dead connections.

### Type alias

```cpp
using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;
```

`true, true` = SSL enabled, server-side. Third template param is the per-socket user data type.

---

## main.cpp — Entry Point

### Initialization sequence

1. **`sodium_init()`** — Initialize libsodium. Fatal exit on failure.
2. **`parse_args()`** — Parse CLI args into `Config` struct.
3. **Banner** — Print port and startup info to stderr.
4. **`RelayState` construction** — Default-constructed (all maps empty).
5. **License loading** — `state.license.load_from_file(config.keys_file)`. Non-fatal if missing (license system disabled).
6. **Signal handlers** — `SIGINT` and `SIGTERM` set `should_shutdown` atomic bool.

### TLS setup

```cpp
auto app = uWS::SSLApp({
    .key_file_name = config.key_file.c_str(),
    .cert_file_name = config.cert_file.c_str(),
    .ssl_prefer_low_memory_usage = 1,
});
```

- `ssl_prefer_low_memory_usage = 1` enables `SSL_MODE_RELEASE_BUFFERS`, which releases read/write buffers when idle — critical for low per-connection memory (contributes to the 13.4 KB/conn figure).

### TLS session resumption

After app creation, the native `SSL_CTX*` is extracted and configured for server-side session caching:

```cpp
SSL_CTX_set_session_cache_mode(ssl_ctx, SSL_SESS_CACHE_SERVER);
SSL_CTX_sess_set_cache_size(ssl_ctx, 20000);
```

Reconnecting clients reuse cached TLS session keys for ~10x faster handshakes. Cache holds 20,000 sessions.

### Handler setup

- `setup_ws_handler(app, state)` — Registers the `/ws` WebSocket endpoint.
- `setup_http_handlers(app, state, config)` — Registers all HTTP routes.

### Listen and timers

On successful bind to `config.port`, three timers are created on the uWS event loop:

| Timer | Interval | Callback | Purpose |
|-------|----------|----------|---------|
| License reload | 30,000 ms | `s->license.try_reload(*s)` | Hot-reload `keys.json`, kick peers with revoked keys |
| Signaling cleanup | 120,000 ms | `cleanup_stale_signaling(*s)` | Remove HTTP signaling entries older than 180s |
| Guest idle | 60,000 ms | Iterate `guest_sockets`, close idle guests | Disconnect guests with >30 min no binary activity |
| Offline buffer sweep | 300,000 ms | `sweep_offline_buffer`, link codes, link guesses, reports save | TTL expiry of every RAM buffer |
| Shutdown check | 1,000 ms | Check `should_shutdown` atomic | Snapshot, then close timers + every socket (see below) |

Timer state pointers are stored via `us_timer_ext()`; the three periodic timers are also recorded in `g_shutdown.timers` so the shutdown tick can close them.

### main.cpp:cleanup_stale_signaling()

Iterates all `signaling_rooms`, removes `PeerEntry` records where `now - last_seen >= 180` seconds. Deletes empty rooms from the map.

### Graceful shutdown (rewritten 2026-09-07)

When `should_shutdown` is true (from SIGINT/SIGTERM), the 1 s shutdown tick, on the loop thread with every buffer intact (`drain::shutdown`):
0. The drain hint `{"type":"reconnect","after_ms":N}` to every live session's socket (see Resumable sessions).
1. `snapshot_to_fdstore(state)` (see `snapshot.cpp` below).
2. Closes the three periodic timers and itself.
3. `app.close()`: the listen socket plus every connection (`us_socket_context_close` on the HTTP and WS contexts). Close handlers run `cleanup_peer` as usual; the snapshot was taken first because they mutate state.
4. `app.run()` returns, reports are saved, the process exits. Measured 0.6 to 1.8 s.

Until 2026-09-30 step 4 hung whenever the push worker had started (any push since boot): the detached worker waits on a condition variable, `exit()` runs the static destructors, and glibc blocks forever destroying a condition variable that has a waiter. So every production restart after the first push was again a 90 s outage ending in SIGKILL (the snapshot, written first, survived). `push_queue.h` now never frees the worker's shared state; `test/test_push_queue.cpp` exits with the worker parked and `run_tests.sh` runs every test under `timeout 120`, so a hang fails. The fleet restart test missed it because the fleet has no phones, so nothing ever pushed.

Until 2026-09-07 step 3 closed only the listen socket. The timers (`fallthrough=0`, counted in `num_polls`) and every open socket kept `us_loop_run` alive, so every restart was a 90 s brownout for new connections ending in systemd's SIGKILL (`State 'stop-sigterm' timed out. Killing.`), and `reports.save_if_dirty()` after `run()` never ran.

Fatal: if the port bind fails, the process calls `exit(1)` immediately.

## snapshot.cpp / snapshot_codec.h / sd_fdstore.h — Restart persistence (2026-09-07)

Everything the relay holds is RAM. A service restart used to empty it: three days of offline DM frames, the topic rings, and every offline phone's push token (RAM-only, never erased on disconnect, re-sent only on app launch). Now the state that an OFFLINE peer cannot re-send rides systemd's file descriptor store across the restart. Memory `project_relay_restart_persistence` has the decisions; this is the shape.

**What is in the snapshot:** `offline_buffer` (room, frame, sender, age, is_image, is_channel, seq), `offline_optin`, `topic_buffers` (key, accepting, retention_secs, registered age, frames), `push_tokens`, `push_prefs`. Not: rooms and sockets, nickname and link-code claims (relay-scoped by design), push debounce counters, `device_list_max_version`, the two files. Since VERSION 9 also every resumable session, which carries its own rooms, subscriptions, nickname and link code (see Resumable sessions).

**`snapshot_codec.h`** (header-only, no uWS, unit test `test/test_snapshot_codec.cpp`): `snapshot::Data` plus `encode`/`decode`. Magic `HRSN`, `VERSION` (9 since 2026-10-06; the header comment lists what each version added), six counted sections (the sixth is the kill list, read only at version 2 or later; a version 1 snapshot decodes with an empty kill list, so a deploy keeps the live buffers), trailer `HRSE`; little-endian fixed-width ints, u32-length strings capped at 64 MB, flags must be 0/1, a count larger than the remaining bytes is refused. `decode` is all-or-nothing: any truncation, bad byte or a version outside the accepted range returns false and leaves the output untouched. Timestamps travel as AGES in seconds; the reader rebuilds `at = now - age`.

**`sd_fdstore.h`** (header-only): `store(fd, name)` sends `FDSTORE=1\nFDNAME=name` with the fd as SCM_RIGHTS over `NOTIFY_SOCKET` (abstract `@` paths handled); `remove(name)` sends `FDSTOREREMOVE=1`; `take(name)` parses `LISTEN_PID`/`LISTEN_FDS`/`LISTEN_FDNAMES`, marks every passed fd close-on-exec, closes the ones not taken, clears the variables. No libsystemd (its dev package is not on the box).

**`snapshot.cpp`:** `snapshot_to_fdstore` = capture → encode → `memfd_create` → write → `remove` (a stale entry would make the store refuse) → `store` → count-only log line. `restore_from_fdstore` (called in `main` before `listen`) = `take` → `remove` BEFORE parsing (a crashing reader cannot loop on the same snapshot) → `lseek(0)` (the store's dup shares the writer's offset) → read → decode → apply → `sweep_offline_buffer` (what aged out in the gap) → `enforce_buffer_budget` (new export of `evict_over_budget`). `apply` places frames first, then re-stamps the OfflineIndex in ascending old-seq order, DM and topic interleaved, and recomputes `buffer_total_bytes` and each ring's `bytes`.

**Unit requirements** (`deploy/hollow-relay.service` and the box): `NotifyAccess=main`, `FileDescriptorStoreMax=1` (without both systemd drops the datagram), `LimitCORE=0`. `FileDescriptorStorePreserve` stays at its default `restart`: the store survives restarts and is cleared on a full `stop`. Host: NO swap (a 2 GB swapfile was live until 2026-09-07) and apport disabled, because the heap and the memfd are ordinary pageable memory and a core dump is the heap on disk. Docker: no fd store, the handoff no-ops.

**Rules:** a new RAM registry an offline peer cannot re-send joins the codec (bump `VERSION`; an old snapshot is then discarded whole, which is intended). Snapshot BEFORE `app.close()`. Log counts, never keys. Memory peak at shutdown ≈ 3x buffered bytes, at restore ≈ 2x; stream-encode from state before a multi-GB budget.

**Proof:** `scripts/fleet_relay_restart.ps1` (two real instances; b closed, a sends a DM and a channel message and closes, relay restarted with nobody connected, b returns alone and sees both). Journal at that restart: `handed to the fd store: 6 DM frames in 2 queues, 4 topic frames in 2 rings, 2 opt-ins` and `restored ... 10 frames live after expiry`.

---

## Hosting: accounts, sandbox, disk (2026-09-30, HOL-SEC-073..075)

Until session 19 the relay, the push sidecar and the forwarder ran as `ubuntu` (passwordless sudo), unsandboxed (9.2 UNSAFE), the relay binary in `~ubuntu/relay-uws/build` writable by the account running it, a certbot hook `chmod 644`-ing every private key, and the TURN secret and push tokens in `Environment=` (any local account reads those with `systemctl show`; a 0600 drop-in hides nothing). Now:

| Service | Account | Program | Settings / secrets | State | Exposure |
|---|---|---|---|---|---|
| hollow-relay | `hollow-relay` | `/usr/local/bin/hollow-relay` (root 0755) | `/etc/hollow-relay/` (0750 root:hollow-relay): `keys.json` 0640, `fullchain.pem` 0644, `privkey.pem` 0640, `relay.env` 0600 root (`TURN_SECRET`, `HOLLOW_PUSH_TOKEN`) | `/var/lib/hollow-relay` (reports) | 1.4 |
| hollow-push | `hollow-push` | `/opt/hollow-push` (root-owned copy of index.js, unifiedpush.js, node_modules) | `/etc/hollow-push/` (0700 root): `service-account.json` (via `LoadCredential=`, `FIREBASE_KEY_PATH=%d/...`), `push.env` (`PUSH_TOKEN`) | none | 1.2 |
| hollow-forwarder | `hollow-fwd` | `/usr/local/bin/hollow-forwarder` | `/etc/hollow-forwarder/forwarder.toml` 0640 root:hollow-fwd | `/var/lib/hollow-forwarder` (key; db = the Olm account only from 0.12, sessions in RAM, C-RP-07; no log file, the old `hollow_debug.log` -> `/dev/null` link is dead) | 1.1 |
| coturn (distro unit) | `turnserver` (in `ssl-cert`) | `/usr/bin/turnserver` | `/etc/turnserver.conf`, LE keys `0640 root:ssl-cert` | none | 1.2 (drop-in `coturn.service.d/hollow-sandbox.conf` = `deploy/coturn-sandbox.conf`) |

The units in the repo ARE the box's units (`deploy/hollow-relay.service`, `deploy/hollow-forwarder.service`, `push-sidecar/hollow-push.service`, no secrets in them). The relay keeps hot-reloading its certificate from its own copy: the certbot deploy hook is `deploy/renewal-hook.sh` (installed as `/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh`), it rewrites the copy with those modes, sets the LE keys `0640 root:ssl-cert` and restarts coturn (which reads its cert only at start). The relay logs `TLS certificate reloaded` within 60 s.

**Deploy (relay):** scp sources to `~/relay-uws/`, build there as `ubuntu`, then `sudo install -m 0755 build/hollow-relay /usr/local/bin/hollow-relay && sudo systemctl restart hollow-relay`. NO `setcap` (the capability is ambient from the unit; a file capability plus the empty bounding set of another unit would refuse to exec). Push: copy the changed JS into `/opt/hollow-push` with `sudo install`, then restart. Forwarder: `sudo install` the binary, restart. After any change on the box: `sudo bash relay-uws/deploy/check-host.sh` must print only `ok`. Since session 34 it also checks the sidecar's `PUSH_TOKEN` (set, and equal to the relay's `HOLLOW_PUSH_TOKEN`), kdump and `/var/crash`, the `/etc/hollow-*` and `/var/lib/hollow-*` modes and owners, coturn's live config (`no-cli`, `log-file=/dev/null`, the peer lock against this host's own addresses, read through `/proc/PID/root` so a container's file counts) and stray `turn_*.log` files. The push unit carries `IPAddressDeny=` for every private range under `unifiedpush.js`'s guard (`IPAddressAllow=localhost` for the relay's calls and the 127.0.0.53 resolver; proven with transient units, the filter works without the BPF framework), and the guard also refuses this machine's own addresses (C-RP-13).

**Sandbox rules learned the hard way:**
- `SystemCallErrorNumber=EPERM`, never the default kill: a SIGSYS is an abnormal exit, which skips the snapshot and loses every buffer.
- No `ProcSubset=pid` on the relay: `/relay-status` reads `/proc/meminfo` and `/proc/net/dev`.
- No `MemoryDenyWriteExecute` for Node (V8 JIT). `AF_NETLINK` is needed by anything that resolves names or lists interfaces (Node, the forwarder, coturn).
- `PrivateUsers=yes` only where no privileged port is bound (a capability inside a user namespace does not reach the host's network namespace).
- The fd store handoff works unchanged: sd_notify over the read-only `/run`, `memfd_create` in `@system-service`, and a memfd written by the old process (even under another uid) is read by the new one through the passed descriptor. Proven by a canary unit on a local port (push token + DM frame handed and restored) before production.
- systemd 255 here has no BPF framework, so `SocketBindAllow`/`RestrictNetworkInterfaces` are unavailable.
- Scripts over SSH: `sudo cmp <(...)` fails (sudo closes the extra fds), and a glob like `/var/lib/x/*` typed as `ubuntu` expands to nothing inside a 0700 directory (the forwarder was down 40 s from exactly that). Wrap both in `sudo sh -c`.

**Disk:** the journal is volatile (1 h), and rsyslog drops `:programname, startswith, "hollow-"` plus `turnserver` (`/etc/rsyslog.d/00-hollow-privacy.conf`); the sidecar needs `SyslogIdentifier=hollow-push` or it logs as `node`. `ufw logging off` (blocked late packets of closed 443 connections carried real client addresses). `kernel.core_pattern=|/bin/false`, no swap. Old leaks were scrubbed on 2026-09-30.

**SSH:** `/etc/ssh/sshd_config.d/10-hollow.conf`: keys only, `AllowUsers ubuntu`, no root, no X11, `MaxAuthTries 3`. Change sshd only with a dead-man revert armed first (`systemd-run --on-active=240` that deletes the drop-in and reloads), prove a fresh login, then stop the timer.

**Removed 2026-09-30:** Xray (8443, closed in ufw), shadowsocks, HAProxy and every file of the July anti-censorship spike, including two stale private-key copies.

**Docker path:** relay container `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, and `net.ipv4.ip_unprivileged_port_start=443` (no `setcap` in the image any more; under `no-new-privileges` a file capability is never granted). coturn needs `cap_add: [NET_BIND_SERVICE]` only because the coturn image marks `turnserver` with that file capability and the kernel refuses to exec it when the bounding set lacks it; `no-new-privileges` still keeps it from being granted (CapEff 0 verified). `coturn-start.sh` writes the TURN secret into a 0600 file in `$RUNTIME_DIRECTORY` or a `mktemp -d` and passes `-c`, never `--static-auth-secret` on the command line (visible in the host's `ps`). Proven on the Linux VM.

---

## crypto.cpp / crypto.h — Cryptographic Operations

### crypto.cpp:verify_ed25519()

Verifies an Ed25519 signature for WebSocket and HTTP authentication.

**Parameters:** `pubkey_b64` (base64-encoded protobuf-wrapped public key), `sig_b64` (base64 signature), `message` (plaintext message that was signed).

**Key format:** The public key is NOT raw 32 bytes. It's a 36-byte protobuf-wrapped key:
- Bytes 0-3: protobuf header `08 01 12 20` (Ed25519 key type tag + 32-byte length prefix)
- Bytes 4-35: raw Ed25519 public key (32 bytes)

This matches the key format used by Hollow's Rust `NativeKeypair` (libp2p-compatible protobuf encoding).

**Process:**
1. Base64-decode `pubkey_b64` into 36 bytes. Reject if length != 36.
2. Validate protobuf header bytes. Reject if wrong.
3. Extract 32-byte Ed25519 key from offset 4.
4. Base64-decode `sig_b64` into 64 bytes. Reject if length != 64.
5. Call `crypto_sign_verify_detached()` (libsodium). Return true on success.

Uses `sodium_base64_VARIANT_ORIGINAL` (standard base64, not URL-safe).

### crypto.cpp:hmac_sha1_base64()

Generates HMAC-SHA1 for TURN credential generation (coturn time-limited credentials protocol).

**Parameters:** `secret` (shared TURN secret), `message` (the username string `"expiry:hollow"`).

**Process:**
1. Compute HMAC-SHA1 using OpenSSL `HMAC()` with `EVP_sha1()`.
2. Base64-encode the 20-byte result using libsodium's `sodium_bin2base64()`.
3. Return the base64 string.

### crypto.cpp:hex_encode()

Converts binary data to lowercase hex string. Used to convert 32-byte binary room IDs from binary WebSocket frames into room code strings for map lookups.

### crypto.cpp:now_unix_secs()

Returns current Unix timestamp in seconds using `std::chrono::system_clock`. Used for timestamp validation, TURN credential expiry, and signaling entry staleness.

---

## reports.cpp / reports.h — User Reports (2026-07-07)

The ONE thing the relay persists about peers — deliberately minimal.

**`ReportsState`** (member of `RelayState` as `state.reports`):

| Field | Type | Description |
|-------|------|-------------|
| `keys` | `unordered_set<string>` | hex `BLAKE2b(key = secret, reporter '\0' target '\0' category)` — dedup only, one report per (reporter, target, category) |
| `secret` | `unsigned char[32]` | Random relay secret in its OWN file `<reports-file>.key` (0600, tmp+fsync+rename, created on first start, never logged); unreadable/unwritable = a key for this run only |
| `counts` | `unordered_map<string, unordered_map<string, uint64_t>>` | target peer_id → category → count (the operator's view) |
| `file_path` | `string` | From `--reports-file` (default `reports.json`; the official unit passes `/var/lib/hollow-relay/reports.json`, its StateDirectory) |
| `dirty` | `bool` | Set by `add()`; cleared on successful save |

- **WS command:** `{"type":"report","target":<peer_id>,"category":<cat>}` → `handle_report()` in ws_handler.cpp (beside `handle_set_offline_buffer`). Guest-guarded; `target` non-empty/≤128/≠self; category allow-list: `spam`, `harassment`, `illegal_content`, `impersonation`. Replies `{"type":"report_ack"}` even on dedup (idempotent from the client's view). NO logging — reporter/target ids are user-identifying.
- **Persistence:** `save_if_dirty()` = nlohmann dump → `.tmp` → `rename()` (atomic); flushed on the 300s sweep timer + after `app.run()` returns (shutdown). `load_from_file()` in main() right after the license load; sets `file_path` even when the file is absent so the first save creates it.
- **Privacy invariant:** who-reported-whom never touches disk or logs; `keys` are KEYED since 2026-09-25 (`BLAKE2b(key = secret, reporter '\0' target '\0' category)`, the old unsalted sha256 let anyone holding the file confirm a guessed "A reported B"), so the file alone confirms nothing (the relay, holding the key, still can). Cap `MAX_REPORT_KEYS` (500k) bounds RAM/disk.
- **File format v2:** `{"version":2,"salt_id":<8-byte keyed hex naming the secret>,"keys":[...],"counts":{...}}`. Load drops `keys` (keeps `counts`, marks dirty so the next flush rewrites) when `version != 2` (legacy unsalted) or `salt_id` differs (lost/replaced key file), logging only the dropped count. Consequence: a repeat of a pre-migration report counts once more. Tests: `relay-uws/test/test_reports.cpp` (g++, needs libsodium).
- **Restart persistence:** the key is a DISK file like `reports.json` itself, loaded at startup; NOT part of the memfd snapshot.
- **Client path:** FFI `report_user(target, category)` (api/network.rs) → `NodeCommand::ReportUser` → swarm arm → `WsCommand::ReportUser` → `send_command` json arm. One-shot: deliberately NOT cached in `track_room_change`, so never re-sent on reconnect.

## license.cpp / license.h — License Key System

### LicenseResult enum

| Value | Meaning |
|-------|---------|
| `Ok` | Key is valid and has been reserved for this peer |
| `NotRequired` | License system is disabled (`enabled = false`) |
| `InvalidKey` | Key not found in the valid key set |
| `KeyInUse` | Key is valid but already held by `MAX_DEVICES_PER_KEY` (5) other peer_ids |
| `KeyRequired` | License system is enabled but no key was provided |

### LicensePool / LicenseState structs

`LicensePool` (`license_pool.h`, header-only, pure, unit-tested by `test/test_license_pool.cpp`) holds the registry; `LicenseState` derives from it and adds the file. Since 2026-09-17 one key admits up to `MAX_DEVICES_PER_KEY = 5` sockets at once: a person's linked devices share one key (the linked device inherits it with the imported database) and the relay keeps a dead socket for up to its 120 s idle timeout, so a cap of one refused every second device and every reconnect that raced its own ghost (issue #86's surprise license prompt).

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | `bool` | Whether license enforcement is active |
| `keys` | `unordered_set<string>` | Set of valid license key strings |
| `holders` | `unordered_map<string, unordered_set<string>>` | license_key -> peer_ids currently holding it |
| `file_path` | `string` | Path to keys.json (saved for reload) |
| `last_mtime` | `time_t` | Last modification time of keys.json (for change detection) |

### keys.json format

```json
{
  "enabled": true,
  "keys": ["key1", "key2", "key3"]
}
```

### license.cpp:load_from_file()

Initial load on startup:
1. Open and read the JSON file.
2. Parse `enabled` boolean (defaults to `false`).
3. Parse `keys` array into the `keys` set.
4. Record `last_mtime` via `stat()` for change detection.
5. Log key count and enabled status to stderr.
6. Returns `false` if file doesn't exist or can't be parsed (non-fatal — license system stays disabled).

### license.cpp:validate_key()

Called during WebSocket auth (`handle_auth()`):
1. If `!enabled`, return `NotRequired` (all peers connect freely).
2. If no key provided (`key == nullptr || key->empty()`), return `KeyRequired`.
3. If key not in `keys` set, return `InvalidKey`.
4. If this peer_id already holds the key, return `Ok` (reconnection).
5. If the key already has `MAX_DEVICES_PER_KEY` holders, return `KeyInUse`.
6. Otherwise, add this peer_id to the key's holders and return `Ok`.

### license.cpp:release_key()

Called when a peer disconnects (`cleanup_peer()`). Removes the peer_id from every key's holder set and drops keys left with no holders.

### license.cpp:try_reload()

Called every 30 seconds by the license reload timer:
1. `stat()` the keys file. If `st_mtime == last_mtime`, return (no change).
2. Re-read and parse the JSON file.
3. Build a new key set.
4. `replace_keys()`: every holder of a key that is NOT in the new set is returned as `peers_to_kick` and forgotten; `enabled` and `keys` are swapped in.
5. Update `last_mtime`.
7. **Active connection revocation:** For each peer to kick, look up their `SSLWebSocket*` in `state.peer_sockets`, send `{"type":"auth_failed","error":"invalid_license_key"}`, and call `ws->end(1008, "license_revoked")`. This triggers the close handler which calls `cleanup_peer()`.

The 30-second reload cycle means key revocation takes at most 30 seconds to take effect on active connections.

---

## ws_handler.cpp / ws_handler.h — WebSocket Handler

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `TIMESTAMP_SKEW_SECS` | 60 | Max allowed clock skew for auth timestamps |
| `MAX_ROOMS_PER_PEER` | 2000 | Maximum rooms a single peer can join |

### ws_handler.cpp:setup_ws_handler() — WebSocket endpoint configuration

Registers the `/ws` endpoint with these settings:

| Setting | Value | Description |
|---------|-------|-------------|
| `.compression` | `uWS::DISABLED` | No per-message compression (content is already encrypted) |
| `.maxPayloadLength` | `64 * 1024 * 1024` (64 MB) | Maximum single message size. NEVER lower — ChannelSyncBatch can exceed 2 MB after MLS+base64. Silently kills connections if exceeded. |
| `.idleTimeout` | `45` seconds | Connection closed if no data (including pings) for 45 s; clients beat every 15 s (see Resumable sessions) |
| `.maxBackpressure` | `64 * 1024 * 1024` (64 MB) | Hard backpressure limit — uWS force-closes truly dead connections at this threshold |
| `.sendPingsAutomatically` | `true` | uWS sends WebSocket pings automatically |

### Connection lifecycle

#### .open handler

When a new WebSocket connects:
1. Initialize `rate_last_refill` to `now`.
2. Create a 10-second one-shot timer (`auth_timer`). If the peer hasn't authenticated within 10 seconds:
   - Detach `auth_timer` pointer from `PerSocketData` BEFORE calling `end()` (prevents double-free since `end()` triggers the close handler).
   - Send `{"type":"auth_failed","error":"Authentication failed"}`.
   - Close with code 1008 reason "auth_timeout".
   - Close the timer.

#### .message handler

1. If `!authenticated`: route to `handle_auth()`. First message MUST be auth.
2. If `TEXT` opcode: reject if >1 MB (silent drop). Route to `handle_text_message()`.
3. If `BINARY` opcode:
   - Dispatch on first byte:
     - `0x01` -> UNHANDLED (removed 2026-08; see below)
     - `0x02` -> `handle_binary_direct()` — peer-to-peer direct via NUL-delimited fields
     - `0x03` -> `handle_binary_msg()` — room broadcast via NUL-delimited room string
     - `0x04` -> `handle_binary_direct_msg()` — peer-to-peer direct via NUL-delimited fields
   - Unknown first bytes are silently ignored.

#### .drain handler

Empty (no-op).

#### .close handler

1. A socket carrying a live session: a 1008 close ends the session (`end_session`); any other close
   starts its grace (`enter_grace`, see Resumable sessions), which keeps the per-IP slot.
2. Otherwise the per-IP slot is given back (only if `ip_key` was set, i.e. the slot was taken).
3. If `auth_timer` is set, close it and null the pointer.
4. A fetch socket leaves only its own slots; a session-less authenticated socket that was not
   superseded calls `cleanup_peer()` to remove it from all rooms and notify peers.

### ws_handler.cpp:handle_auth() — Authentication

Authentication protocol (first message after WebSocket open):

**Expected JSON:**
```json
{
  "type": "auth",
  "peer_id": "<hex-encoded Ed25519 public key>",
  "public_key": "<base64-encoded protobuf-wrapped Ed25519 public key>",
  "timestamp": <unix_seconds>,
  "signature": "<base64-encoded Ed25519 signature>",
  "license_key": "<optional license key string>"
}
```

**Validation steps:**
1. Parse JSON. Reject on parse failure.
2. Check `type == "auth"`. Reject otherwise.
3. Validate `peer_id`, `public_key`, `signature` are non-empty. Reject if any missing.
4. Check timestamp skew: `|now - timestamp| <= 60s`. Reject if too far.
5. **SECURITY — bind `peer_id` to `public_key`:** recompute the peer_id via `derive_peer_id(public_key)` (crypto.cpp) and reject any mismatch. A peer_id is an identity multihash that INLINES the Ed25519 public key, so it is a pure function of that key. Without this check, step 6 proves only that the sender holds the private half of the key they supplied — NOT that they own the peer_id they claim. Anyone could mint a throwaway keypair, sign `hollow-ws-auth:<victim_peer_id>:<ts>` with it, and authenticate AS the victim; since a newer socket for an existing peer_id EVICTS the incumbent, that is a persistent remote deauth of any user (peer_ids are public — broadcast in `peer_joined` + member snapshots). Added 0.8.2 after an external report; the same check also guards both legacy HTTP register/unregister endpoints. **The derivation is duplicated in Rust and C++ and is pinned by matching known-answer tests** (`peer_id_derivation_known_answer` / `relay-uws/test/test_derive_peer_id.cpp`) — silent drift fails auth for EVERY client, so change both or neither.
6. Build signed message: `"hollow-ws-auth:" + peer_id + ":" + timestamp`.
7. Verify Ed25519 signature via `verify_ed25519()`. Reject if invalid.
7. Validate license key via `state.license.validate_key()`. Handle all `LicenseResult` cases:
   - `Ok` / `NotRequired`: continue.
   - `InvalidKey`: send `{"type":"auth_failed","error":"invalid_license_key"}`, close with "bad_license".
   - `KeyInUse`: send `{"type":"auth_failed","error":"license_key_in_use"}`, close with "bad_license".
   - `KeyRequired`: send `{"type":"auth_failed","error":"license_key_required"}`, close with "bad_license".

**On success:**
1. Set `data->peer_id`, `data->authenticated = true`, `data->license_key`.
2. Cancel auth timeout timer.
3. Register peer in `state.peer_rooms[peer_id]` (empty room set) and `state.peer_sockets[peer_id]`.
4. Send `{"type":"auth_ok"}`.

All auth failures send `{"type":"auth_failed","error":"Authentication failed"}` (generic, no information leak) except license-specific errors which have distinct error strings. Close code is always 1008.

### ws_handler.cpp:is_valid_room_code()

Room code validation:
- Not empty, max 128 characters.
- Allowed characters: alphanumeric, `:`, `-`, `_`, `.`.

### ws_handler.cpp:send_json()

Helper: serializes `nlohmann::json` to string and sends as TEXT opcode. No backpressure check (used for control messages).

### ws_handler.cpp:send_to_peer()

The CRITICAL message delivery function. All routed messages go through this:

```cpp
ws->send(data, op);
```

No soft limit — sends unconditionally. `maxBackpressure` (64 MB) is the only safety net for dead connections. Previous soft limit (2 MB) silently dropped CRDT sync responses and broke all offline-to-online flows.

### ws_handler.cpp:handle_join() — Room join

**Input:** `{"type":"join","room":"<room_code>"}`

**Process:**
1. Validate room code via `is_valid_room_code()`.
2. Check peer hasn't exceeded `MAX_ROOMS_PER_PEER` (2000). Error if so.
3. Collect list of existing peer IDs in the room.
4. Add this peer to `ws_rooms[room].peers[peer_id]`.
5. Add room to `peer_rooms[peer_id]`.
6. Send `members` message to the joiner containing ALL peers (including self):
   ```json
   {"type":"members","room":"<room>","peers":["peer1","peer2","self"]}
   ```
7. Send `peer_joined` to every OTHER peer in the room — **but ONLY on a genuine join, not a redundant re-join (2026-07-09).** `handle_join` captures `already_present = ws_room.peers.find(peer_id) != end()` BEFORE the map insert; the `peer_joined` broadcast is gated `&& !already_present`. A client re-joins a room it never left (the PeerLeft "still listed → refreshing membership" path fires a JoinRoom per still-shared room); re-broadcasting `peer_joined` on those re-fires the other side's FULL discovery cascade (profile + key-exchange + sync), looping ~10x in seconds during a fresh friend handshake's room churn — which widened the DM/friend establishment races. The joiner still gets its `members` reply (step 6) for stale-membership reconciliation. **This is the ONLY relay change deployed in the 2026-07 establishment-bug fix pass** (byte-identical binary swap on the OG TLS relay). See `feedback_dm_friend_establishment_bugs_2026_07.md`.
   ```json
   {"type":"peer_joined","room":"<room>","peer_id":"<joiner>"}
   ```

Room creation is implicit — joining a room that doesn't exist creates it.

### ws_handler.cpp:leave_room() — Room leave

Called explicitly via `{"type":"leave","room":"..."}` or implicitly on disconnect.

**Process:**
1. Remove peer from `ws_rooms[room].peers`.
2. If room is now empty, delete it from `ws_rooms`.
3. Remove room from `peer_rooms[peer_id]`.
4. If room still has peers, send `peer_left` to all remaining:
   ```json
   {"type":"peer_left","room":"<room>","peer_id":"<leaver>"}
   ```

**`suppress_peer_left` (2026-08-15).** `leave_room(state, peer, room, expected_ws,
suppress_peer_left)` — when true, step 4 is SKIPPED and `diag.ghost_left_suppressed`
increments instead. Passed `true` from exactly one call site: the `handle_auth`
supersede path, where a NEWER socket for the same `peer_id` is authenticating and
the "leaver" is demonstrably still present. Broadcasting a departure there is a lie
observers act on (it tore down live media branches after an app restart, which is
why the client and forwarder engine both carry presence-flap tolerance).

Two constraints that are easy to break:
- It must be an EXPLICIT flag: the supersede cleanup runs BEFORE
  `peer_sockets[peer_id]` is re-pointed at the new socket, so any "is there a newer
  socket?" inference is false there.
- The room slot is still ERASED — only the broadcast is withheld. A slot left
  pointing at a closed socket is a dangling pointer on every later fan-out; the
  successor's re-join restores presence via `peer_joined`.

Also fixed in `handle_auth` the same day: `peer_rooms[peer_id] = {}` was outside the
`!is_fetch` guard, so a fetch-mode auth wiped a connected full node's room set (its
close then never called `leave_room`, leaving room slots on a freed socket).

### ws_handler.cpp:handle_msg() — Room text broadcast

**Input:** `{"type":"msg","room":"<room>","data":"<payload>"}`

**Process:**
1. Find the room. Return silently if room doesn't exist.
2. Verify the sender is a member of the room. Return silently if not.
3. Broadcast to ALL other peers in the room:
   ```json
   {"type":"msg","room":"<room>","from":"<sender_peer_id>","data":"<payload>"}
   ```

The `data` field contains opaque encrypted content (MLS ciphertext, Olm ciphertext, plaintext HavenMessage JSON — the relay doesn't know or care).

### ws_handler.cpp:handle_direct() — Peer-to-peer text direct

**Input:** `{"type":"direct","room":"<room>","target":"<target_peer_id>","data":"<payload>"}`

**Process:**
1. Find the room. Return silently if not found.
2. Verify sender is in the room. Return silently if not.
3. Find target in the room. Return silently if not found.
4. Send to target only:
   ```json
   {"type":"direct","room":"<room>","from":"<sender_peer_id>","data":"<payload>"}
   ```

Used for: Olm key exchange (DMs), WebRTC signaling offers/answers, friend requests, direct sync probes.

### ws_handler.cpp:handle_text_message() — Text message dispatcher

Parses JSON and dispatches on `type` field:
- `"join"` -> `handle_join()`
- `"leave"` -> `leave_room()`
- `"msg"` -> `handle_msg()`
- `"direct"` -> `handle_direct()`
- `"check_peers"` -> inline handler: accepts `peers` (array of peer IDs), does O(1) hashmap lookups against `peer_sockets`, returns `{"type":"peer_status","online":[...],"active_rooms":[]}`. Used by the 60s client-side peer liveness timer for offline friend self-healing. Deliberately UNTHROTTLED: peer ids are high-entropy (not enumerable blind), the reply only restates what routing already exposes, and a cap would silently degrade the liveness check that heals offline-friend state. **The `rooms` probe was REMOVED 2026-08** (issue #46): it reported whether an arbitrary room code held any peers, and DM room codes are a deterministic function of the two master peer_ids — so anyone holding two peer_ids could ask the relay whether those two people were talking. `active_rooms` is now always `[]`; the field stays on the wire only because `ServerMsg::PeerStatus` needs it to deserialize on older clients (it is `#[serde(default)]` from 0.9.4). Never reintroduce a room-state lookup keyed on a caller-supplied room code.
- `"discover_peers"` -> inline handler: accepts `room`, returns `{"type":"discovered_peers","room":..,"peers":[...]}` listing the room's `ws_rooms` peers (excluding self). Replaces the HTTP `/bootstrap` poll for peer discovery so it rides the live WS connection instead of paying a fresh TLS handshake per request (which could stall under a WS frame burst on the single event loop). Cheap: one map lookup + bounded copy, no blocking I/O. Client side: `WsCommand::DiscoverPeers` / `WsEvent::DiscoveredPeers`. (Since 2026-07 this IS peer discovery — the client's HTTP signaling task was deleted; the relay keeps the HTTP endpoints for old clients.) **MEMBERS ONLY since 2026-08** (issue #46): the requester must be in the room. It previously answered for any room code, making it a roster dump — hand it a deterministic DM room code and it returned exactly who was in that DM. Clients only ever discover in rooms they have already joined (`active_room` + their own server ids), so the gate costs nothing legitimate.
- `"get_turn_credentials"` (2026-07) -> inline handler: HMAC-SHA1 time-limited TURN credentials over the AUTHENTICATED socket — same generation as HTTP `/turn-credentials` (username `{expiry}:hollow`, ttl 3600, 3 URIs) but guest sockets get `{"error":"auth required"}` and no open farmable endpoint is involved. Returns `{"type":"turn_credentials",username,password,ttl,uris[]}`. `setup_ws_handler`/`handle_text_message` now take `const Config&` for `turn_secret`. Client side: `WsCommand::GetTurnCredentials` on connect + 50-min refresh → `NetworkEvent::TurnCredentials` → Dart `iceConfigProvider`.
- `"subscribe"` -> `handle_subscribe()`

Unknown types are silently ignored. Invalid JSON is silently ignored.

### Binary message protocol

Binary messages use a type-byte prefix system for zero-copy routing. Four binary message types exist:

#### Type 0x01 — Binary room broadcast (hash-addressed) — REMOVED 2026-08

**Frame was:** `[0x01][32-byte room hash][payload]`

`handle_binary_broadcast()` is **gone**, and `0x01` is now an unhandled opcode.

It was the one binary handler that never checked room membership at all: it
hex-encoded the caller-supplied 32-byte room hash, looked the room up, and
forwarded the frame verbatim to every peer in it. Anyone authenticated who knew
a room code could therefore inject frames into a room they had never joined.

Nothing sent it. Server broadcasts moved to `0x03` (`handle_binary_msg`, which
is membership-gated) when room codes became NUL-delimited strings; the Rust
client emits only `0x02/0x03/0x04/0x07/0x08/0x09`. Reported publicly via a
semgrep sweep in issue #46. Do not reintroduce a hash-addressed broadcast
without a membership check.

#### Type 0x02 — Binary peer-to-peer direct

**Frame:** `[0x02][room_code\0][target_peer_id\0][payload]`

`handle_binary_direct()`:
1. Parse room code (from offset 1 to first NUL).
2. Parse target peer ID (from after first NUL to second NUL).
3. Extract payload (everything after second NUL).
4. **Rewrite the frame:** Replace the target peer ID with the sender's peer ID, so the receiver knows who sent it:
   ```
   Forwarded: [0x02][room_code\0][sender_peer_id\0][payload]
   ```
5. Route to the target peer only.

Used for: Olm-encrypted DM payloads, WebRTC binary signaling, file stream chunks.

#### Type 0x03 — Binary room broadcast (string-addressed)

**Frame:** `[0x03][room_code\0][payload]`

`handle_binary_msg()`:
1. Parse room code (from offset 1 to NUL).
2. Verify sender is in the room.
3. **Rewrite to type 0x05:** Build forwarded frame:
   ```
   Forwarded: [0x05][room_code\0][sender_peer_id\0][payload]
   ```
4. Broadcast to all other peers in the room.

The type change from 0x03 to 0x05 lets receivers distinguish "this is a forwarded broadcast" from "this is a client-originated broadcast." The sender's peer_id is injected by the relay (cannot be spoofed by the sender).

#### Type 0x04 — Binary peer-to-peer direct (string-addressed)

**Frame:** `[0x04][room_code\0][target_peer_id\0][payload]`

`handle_binary_direct_msg()`:
1. Parse room code (from offset 1 to first NUL).
2. Parse target peer ID.
3. Extract payload.
4. Verify sender is in the room.
5. Verify target is in the room.
6. **Rewrite to type 0x06:** Build forwarded frame:
   ```
   Forwarded: [0x06][room_code\0][sender_peer_id\0][payload]
   ```
7. Route to target peer only.

The type change from 0x04 to 0x06 lets receivers distinguish forwarded direct messages. Sender identity is relay-injected.

### Binary type byte summary

| Client sends | Relay forwards as | Mode | Room addressing |
|-------------|-------------------|------|-----------------|
| `0x01` | — (REMOVED, unhandled) | — | — |
| `0x02` | `0x02` (target->sender rewrite) | Direct | NUL-delimited string |
| `0x03` | `0x05` (type change + sender inject) | Broadcast | NUL-delimited string |
| `0x04` | `0x06` (type change + sender inject) | Direct | NUL-delimited string |
| `0x08` | `0x06` (same as 0x04) | Direct (image) | NUL-delimited string |

Every surviving type rewrites the routing header to inject the AUTHENTICATED sender, so a client cannot forge who a frame came from at the relay layer. (The removed `0x01` was the one exception — it forwarded verbatim.) `0x08` is identical to `0x04` on the wire/forward path — the only difference is the offline buffer tags it `is_image` so it counts against the per-peer image cap (1) instead of the text cap (100). Used for offline inlined-image delivery (see Push notifications section).

### ws_handler.cpp — Binary rate limiting (REMOVED)

Previously used a token bucket algorithm (removed — broke reconnection bursts):
- Bucket capacity: 100 tokens.
- Refill rate: 20 tokens/second.
- Cost: 1 token per binary message.
- On each binary message, calculate elapsed time since last refill, add `elapsed * 20` tokens (capped at 100), then consume 1 token.
- If bucket is empty (0 tokens), the message is silently dropped (no error sent to client).

This limits binary messages to a burst of 100 + sustained 20/second. Text messages have a 1 MB size cap but are NOT rate-limited (text frames are only small JSON commands: join/leave/subscribe, and the reconnection burst is too heavy to cap without breaking sync).

### ws_handler.cpp:cleanup_peer() — Disconnect cleanup

Called from the close handler when an authenticated peer disconnects:
1. `state.license.release_key(peer_id)` — Free the license key.
2. `state.peer_sockets.erase(peer_id)` — Remove from global socket map.
3. Copy the peer's room set (since `leave_room` modifies it during iteration).
4. Call `leave_room()` for each room — removes peer from room, notifies remaining peers with `peer_left`, deletes empty rooms.
5. `state.peer_rooms.erase(peer_id)` — Remove reverse index.

---

## http_handlers.cpp / http_handlers.h — HTTP Endpoints

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_PEERS_PER_ROOM` | 50 | Max signaling peers per room |
| `MAX_ADDRS_PER_PEER` | 5 | Max addresses per peer registration |
| `STALE_THRESHOLD_SECS` | 180 | Entries older than 3 min are stale |
| `TIMESTAMP_SKEW_SECS` | 60 | Max clock skew for signed requests |
| `MAX_BOOTSTRAP_PEERS` | 10 | Max peers returned by bootstrap |

### CORS

All HTTP responses include:
```
Access-Control-Allow-Origin: *
Content-Type: application/json
```

A global OPTIONS handler at `/*` responds with:
```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

### POST /register — Peer registration (signaling)

**Request body:**
```json
{
  "room_code": "<string, max 64 chars>",
  "peer_id": "<string>",
  "addresses": ["addr1", "addr2"],
  "timestamp": <unix_seconds>,
  "public_key": "<base64 protobuf Ed25519 public key>",
  "signature": "<base64 Ed25519 signature>"
}
```

**Signed message format:** `"hollow-register:" + room_code + ":" + peer_id + ":" + addresses_joined + ":" + timestamp`

Where `addresses_joined` is comma-separated (e.g., `"addr1,addr2"`).

**Process:**
1. Validate `room_code` (non-empty, max 64), `addresses` (non-empty), `peer_id`, `public_key`, `signature`.
2. Check timestamp skew (<= 60s).
3. Truncate addresses to 5 entries.
4. Verify Ed25519 signature.
5. Clean stale entries (>= 180s old) from the room.
6. Upsert: if peer already registered, update addresses and timestamp. If new:
   - If room is full (>= 50 peers), evict the oldest entry.
   - Add new entry.
7. Return `{"ok":true,"peers_in_room":<count>}`.

**Error responses:** 400 for validation, 403 for timestamp skew or bad signature.

Uses `res->onData()` streaming pattern for POST body (uWebSockets doesn't buffer POST bodies by default).

### POST /unregister — Peer unregistration (signaling)

**Request body:**
```json
{
  "room_code": "<string>",
  "peer_id": "<string>",
  "timestamp": <unix_seconds>,
  "public_key": "<base64 key>",
  "signature": "<base64 signature>"
}
```

**Signed message format:** `"hollow-unregister:" + room_code + ":" + peer_id + ":" + timestamp`

**Process:**
1. Validate fields, check timestamp, verify signature (same as register).
2. Find the room in `signaling_rooms`.
3. Remove the entry with matching `peer_id`.
4. If the room is now empty, delete it.
5. Return `{"ok":true}`.

### GET /bootstrap/:room_code — Peer discovery

**URL parameter:** `room_code` (max 64 chars).

**Process:**
1. Look up room in `signaling_rooms`.
2. If not found, return `{"peers":[]}`.
3. Iterate entries, skip stale ones (>= 180s old).
4. Return up to `MAX_BOOTSTRAP_PEERS` (10) entries:
   ```json
   {"peers":[{"peer_id":"...","addresses":["..."]}]}
   ```

No authentication required — room codes are unguessable (derived from server/channel IDs).

### GET /health — Health check

Returns: `{"status":"ok","service":"hollow-signaling"}`

No authentication, no state access. Used for uptime monitoring.

### GET /turn-credentials — REMOVED 2026-08

**This route is gone.** It handed valid time-limited TURN credentials to any
unauthenticated caller, so the TURN service was farmable by anyone for free
relay bandwidth against the per-IP daily budget (issue #46). Credentials are
issued ONLY over the authenticated non-guest WebSocket
(`"get_turn_credentials"`), which has been the client path since 0.7.1
(2026-07-03). Do not add an HTTP variant back: there is no caller identity at
the HTTP layer to bind a credential to. `setup_http_handlers` still takes a
`const Config&` (now unused) so the signature stays stable.

The generation itself (unchanged, now WS-only):
1. If `config.turn_secret` is empty, return 503 `{"error":"TURN not configured"}`.
2. Calculate expiry: `now + 3600` (1 hour TTL).
3. Build username: `"<expiry>:hollow"` (coturn time-limited format).
4. Compute password: `HMAC-SHA1(turn_secret, username)` base64-encoded. HMAC-SHA1
   is REQUIRED here by the coturn/TURN REST API spec — semgrep flags it as a
   weak hash, but it cannot be changed unilaterally without breaking TURN auth.
5. Return:
   ```json
   {
     "username": "1714876800:hollow",
     "password": "<base64 HMAC>",
     "ttl": 3600,
     "uris": [
       "turn:relay.anonlisten.com:3478",
       "turn:relay.anonlisten.com:3478?transport=tcp",
       "turns:relay.anonlisten.com:5349"
     ]
   }
   ```

The three TURN URIs cover: UDP (fastest), TCP fallback, and TLS-wrapped (for restrictive networks). The Dart client MUST split these into separate `IceServer` entries due to flutter_webrtc's native `CreateIceServers` limitations.

**The host comes from `--domain`, via `turn_uris()` in `src/turn_uris.h` (0.11.1).** It was a hardcoded `relay.anonlisten.com` string literal until then, so every self-hosted relay handed its own clients the official host's TURN server, which rejects them: TURN had never once worked off relay.anonlisten.com. `turn_host()` strips a trailing `:port` (the WSS port is not the TURN port) while keeping IPv6 brackets, and leaves a bare IPv6 literal alone. Unit tested in `test/test_turn_uris.cpp`.

### GET /server-stats — Server statistics

Returns real-time server resource utilization. Cached for 5 seconds.

**Data sources (Linux-specific):**
- `/proc/meminfo` — `MemTotal` and `MemAvailable` (in KB).
- `/proc/net/dev` — Network interface `ens16` (OVH VPS interface name) rx/tx byte counters.

**Bandwidth calculation:**
- Compares current byte counters with previous sample.
- Calculates Mbps: `(delta_bytes * 8) / (elapsed_seconds * 1,000,000)`.
- Skips calculation if elapsed < 0.5s (uses previous values).

**Response:**
```json
{
  "mem_total_kb": 8167352,
  "mem_used_kb": 1234567,
  "rx_mbps": 12.34,
  "tx_mbps": 5.67,
  "bandwidth_cap_mbps": 1000,
  "online_users": 42
}
```

`bandwidth_cap_mbps` is hardcoded to 1000 (the OVH VPS public bandwidth allocation — OVH lifted the port from 400 Mbps to 1 Gbps for free in Aug 2026 as part of a product-range change; measured 854 Mbps down / 827 Mbps up after the required reboot). It is NOT measured at runtime — `virtio_net` reports no link speed, so bump this constant by hand if the port ever changes again. `online_users` comes from `state.peer_sockets.size() - guest_count` (excludes guest connections).

### GET /relay-status — Relay status for client bootstrap

**Response:**
```json
{
  "license_required": true,
  "version": "0.11.1",
  "turn": true,
  "forwarder": true
}
```

The Dart client checks this endpoint on startup. If `license_required` is true and the user hasn't cached a key, the app shows the license key input dialog.

`version` is `HOLLOW_RELAY_VERSION` in `src/version.h`; it read `"0.1.0"` from the day the endpoint was written until 0.11.1. `turn` is `!turn_secret.empty()` and `forwarder` is `!forwarder_peer_id.empty()`, so both report what this relay is CONFIGURED with, not whether coturn or the forwarder process is actually alive. That is the honest signal the app has: a self-hoster who runs without coturn is told to leave `TURN_SECRET` empty so the two agree. `setup_http_handlers` takes `const Config&` for exactly this (the parameter existed unused before).

---

## Build System (CMakeLists.txt)

**C++20**, C11 for uSockets.

**Dependencies (linked):**
- `uSockets` — Built as a static library from vendored source with `LIBUS_USE_OPENSSL`.
- `ssl` + `crypto` — OpenSSL for TLS and HMAC.
- `sodium` — libsodium for Ed25519 verification and base64.
- `z` — zlib (uWebSockets dependency, even though compression is disabled for the WS endpoint).
- `pthread` — Threading.

**uSockets eventing:** Compiles `epoll_kqueue.c`, `gcd.c`, and `libuv.c` — the correct backend is selected at compile time based on the platform. On Linux (production), epoll is used.

**Source files compiled:**
- `main.cpp`, `crypto.cpp`, `license.cpp`, `http_handlers.cpp`, `ws_handler.cpp`

**Include paths:**
- `uWebSockets/src` — uWebSockets headers
- `uSockets/src` — uSockets headers
- `src` — Project headers (including vendored `json.hpp`)

---

## BENCHMARK.md — Performance Data

### Test environment

OVH VPS: 4 vCPU, 8 GB RAM, Ubuntu. Relay is single-threaded epoll.

### Test methodology

Custom Rust stress test tool (`bench/stress_test/`):
- Each connection: open TLS WebSocket, authenticate with unique Ed25519 keypair, hold idle.
- Ramp: batches of 500, 100 concurrent TLS handshakes.
- Measurement: relay process RSS via `ps -o rss=` at 5-second intervals.
- Client uses `rustls` with shared `ClientConfig` (~28 KB/conn client-side vs ~700 KB with OpenSSL).

### Key results

- **13.4 KB per connection** (stabilized from 15k to 44.6k, perfectly linear).
- **44,600 simultaneous connections** — bottleneck was client-side port exhaustion, NOT relay capacity.
- **0 connection failures, 0 drops.**
- **Single-threaded** — all 44.6k connections on one epoll thread.

### Capacity estimates

| VPS RAM | Max Connections |
|---------|-----------------|
| 8 GB | ~572,000 |
| 12 GB | ~878,000 |
| 16 GB | ~1,183,000 |

Based on 13.4 KB/conn with ~200 MB reserved for OS + relay baseline.

### Memory progression

RSS grows linearly: 45 MB at 1k connections -> 614 MB at 44.6k. No memory cliffs, fragmentation, or degradation.

### System tuning for high connection counts

```bash
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = "1024 65535"
ulimit -n 500000
```

---

## Message flow: complete path of a chat message

1. Sender's Rust `node/` encrypts the message with MLS and sends a binary frame: `[0x03][server_id\0][MLS ciphertext]`.
2. Rust `ws_client.rs` sends this over the WSS connection to `relay.anonlisten.com:443/ws`.
3. Relay's `.message` handler receives it as `BINARY` opcode.
4. First byte is `0x03` -> `handle_binary_msg()`.
6. The NUL-delimited room code (server ID) is read from offset 1.
7. The room is looked up in `ws_rooms`, and the SENDER must be a member of it.
8. The frame is rebuilt as `0x05` with the authenticated sender injected, then forwarded via `send_to_peer()` to every other peer in the room.
9. `send_to_peer()` checks each recipient's `getBufferedAmount()` < 2 MB soft limit.
10. Each recipient's Rust `ws_client.rs` receives the binary frame, strips the type byte and room hash, decrypts with MLS.

---

## Docker self-hosting

Files in `relay-uws/`: `Dockerfile`, `docker-compose.yml`, `.env.example`, `SELF_HOSTING.md` (the single user-facing guide), `keys/`, the hook scripts in `deploy/certbot/` and `deploy/coturn/`, `deploy/harden-host.sh`, plus the systemd unit templates in `deploy/`.

`SELF_HOSTING.md` also has a **Without Docker** section (2026-09-23, issue #33): the relay under systemd with the production unit's `NotifyAccess`/`FileDescriptorStoreMax`/`LimitCORE` lines (so native installs keep restart persistence, which Docker cannot), snap certbot + a `renewal-hooks/deploy` script copying the pair to `/etc/hollow-relay/` (restarts coturn only, never the relay), coturn through the same `coturn-start.sh` with `CERT_DIR=/etc/hollow-relay`, and the push sidecar as a plain Node unit.

Rewritten for 0.11.1. ONE file a self-hoster edits: `.env`. `turnserver.conf.example` is GONE (coturn takes flags only, from `deploy/coturn/coturn-start.sh`), and so are `deploy/hollow-relay-cert-renewed.path`/`.service` (the relay hot-reloads its certificate, so a renewal restarts nothing).

Five services:
- **certbot-init**: one-shot, `network_mode: host`, entrypoint `deploy/certbot/issue.sh`. Everything else that matters depends on it with `condition: service_completed_successfully`, and it runs under `set -eu`, so a failed issuance stops the stack at `docker compose up` instead of parking a healthy-looking certbot next to a crash-looping relay (the pre-0.11.1 bug).
- **certbot-renew**: `renew-loop.sh`, `sleep 12h` forever, then `certbot renew --deploy-hook /hooks/install-certs.sh`. The challenge method is stored in the lineage, so DuckDNS and IP certificates renew the way they were issued with no flags repeated here.
- **duckdns**: `duckdns-updater.sh`. Exits 0 immediately unless `RELAY_HOST` ends in `.duckdns.org` with a token; otherwise pushes `ip=` (empty, so DuckDNS records the caller's address) every 5 minutes.
- **relay**: `--domain ${RELAY_HOST}`, keys and reports paths always passed (an absent `keys.json` is an open relay, so no commented-out YAML), `logging: driver: journald`, healthcheck `curl -fsk https://127.0.0.1/health` (curl added to the runtime stage for it).
- **coturn**: `profiles: [turn]`, host network, `user: "999:999"` so it can read the same certificate copy the relay reads, flags only, peer lock as on production.

Three certificate modes, picked from `RELAY_HOST` by `cert_mode()` in `deploy/certbot/lib.sh`: a `.duckdns.org` name with a token goes DNS-01 through the DuckDNS TXT API (the ONLY mode that works with no port 80, so the only one testable on the NAT'd build VM); an IPv4 or IPv6 literal goes `--standalone --ip-address ... --preferred-profile shortlived` (Let's Encrypt issues IP certificates only under that profile, 6-day lifetime, hence the 12 h renew loop); anything else is a plain `--standalone -d`. `--cert-name relay` pins the lineage to `live/relay/` so no script ever interpolates a hostname into a path. A `RELAY_HOST` carrying a port is REFUSED up front. `OWN_CERT_DIR` short-circuits all of it.

`install_pair()` copies to `<name>.pem.new`, chowns 999:999, then renames, so the relay's reload check never stats a half-written file.

Two traps the first real bring-up found, both fixed:
- **coturn's `--log-file=/dev/null` created a file.** coturn appends a date and rotates unless `--simple-log` is passed, so the flag produced a real `/dev/null_2026-09-10.log` and every TURN session would have landed on the disk. `--simple-log` is now mandatory alongside it.
- **Clearing `CERTBOT_STAGING` kept the staging certificate.** `--keep-until-expiring` sees a valid lineage and skips, so the relay came back up serving an untrusted certificate. `issue.sh` now compares the requested service against `renewal/relay.conf` and runs `certbot delete --cert-name relay` when they differ.

coturn also gained a `depends_on: certbot-init` gate; without it it started before any certificate existed and could not serve `turns:` on 5349.

`deploy/harden-host.sh` is the production host setup as a script (ufw with logging off, volatile journald plus the rsyslog rule that keeps `hollow-*` and coturn lines off the disk, no swap, no core dumps, NTP, fail2ban, unattended-upgrades, key-only SSH with no root login unless root is the invoking account, but ONLY when the invoking user already has an `authorized_keys`). Idempotent, `--print` dry-run. `deploy/check-host.sh` audits a running host (accounts, secrets, key modes, sandbox scores, disk, SSH) and changes nothing.

The relay binary is SSL-only (`uWS::SSLApp`) — cannot run without TLS certs. No `--no-tls` mode exists. This is intentional: every self-hosted relay is TLS-secured by default.

**The container runs as uid/gid 999 (`hollow`), so certbot must hand the certs over.** `USER hollow` arrived with fb05bb7 (2026-08-03, semgrep hardening) and nothing re-tested the cert path: `cp` out of `live/` produces root:root 0600 copies, so the relay could not read its own private key and Docker self-hosting was broken outright until #70/#74 (2026-09-09). The uid is pinned in the Dockerfile precisely so the certbot `chown 999:999` is deterministic.

**License keys mount a DIRECTORY, never the file.** `./keys:/keys:ro` with `--keys-file /keys/keys.json`. A single-file bind mount binds the inode, so any editor that writes-and-renames (vim, `sed -i`, most of them) leaves the container reading an inode that no longer exists: `try_reload`'s mtime check never changes and the 30 s hot reload silently never fires again. `relay-uws/keys/.keep` keeps the directory in the tree, and `keys.json` is gitignored (`.gitignore:124`), so a self-hoster cannot commit their keys by accident.

**No fd store, so no restart persistence on this path.** The snapshot handoff needs `NotifyAccess=main` + `FileDescriptorStoreMax=1` on the unit that owns the relay process, and under compose systemd owns the `docker compose` client instead. Every `docker compose restart relay` therefore empties the offline buffers, topic rings and push tokens. This is exactly why the certificate reload landed in `main.cpp` (60 s timer, mtime compare, pair validated in a scratch `SSL_CTX` before the live one is touched, OpenSSL applies it to NEW connections only): a renewal used to restart the relay every ~60 days and empty everything with it. Core dumps are barred with `ulimits: core: 0` in the compose file, NOT `LimitCORE=` on the unit, which would only bound the compose client and not the relay in the container.

The `deploy/` templates assume the repo cloned at `/opt/HOLLOW` and a `hollow` user in the docker group.

**What is and is not tested.** `turn_uris()` and the snapshot codec have unit tests (`relay-uws/test/`, plain g++ one-liners). The compose stack was brought up end to end on the Linux build VM (2026-09-10) against the real DuckDNS name `hollowtest.duckdns.org`, staging then production: a wrong token makes `certbot-init` exit 1, `docker compose up -d` exit 1 and the relay stay at `created` with `StartedAt` zero; the correct token issues, the relay comes up healthy, and `curl --resolve` reaches it with NO `-k`; a forced renewal is picked up by the running relay (`[main] TLS certificate reloaded`, new serial, `RestartCount=0`, `StartedAt` unchanged); a repeat `up` re-issues nothing; `turnutils_uclient` with relay-computed credentials allocates 20/20 through the peer lock and a wrong password is refused. No-TURN mode was then proven on the same stack: `COMPOSE_PROFILES=` plus an empty `TURN_SECRET` leaves nothing on 3478 or 5349 and `/relay-status` answers `turn:false` while the certificate and the lineage are untouched. The DuckDNS DNS-01 path is the one that mattered there, because the VM is behind NAT and http-01 cannot reach it. On that rig bring the stack up with `docker compose up -d --scale duckdns=0`: `stop duckdns` is too late, the updater fires its first update the moment the service starts and rewrites the hand-set A record to the home public address. Still untested anywhere: the IP-address certificate mode (needs a host with port 80 reachable, which the NAT'd VM is not), `OWN_CERT_DIR`, and `harden-host.sh` applied for real (the VM has no sudo password; `--print` only). CI does not exercise Docker at all.

---

## Error conditions and failure modes

| Condition | Behavior |
|-----------|----------|
| Auth not sent within 10s | `auth_timeout`, connection closed 1008 |
| Invalid auth JSON | `auth_failed`, connection closed 1008 |
| Bad Ed25519 signature | `auth_failed`, connection closed 1008 |
| Timestamp skew > 60s | `auth_failed`, connection closed 1008 |
| License key required but missing | `license_key_required`, connection closed 1008 |
| License key invalid | `invalid_license_key`, connection closed 1008 |
| License key already held by 5 other peers | `license_key_in_use`, connection closed 1008; the client keeps retrying with backoff and keeps its key |
| IP has ≥34 active connections | `ip_limit`, connection closed 1008 (pre-auth) |
| IP opened ≥10 connections in last 60s | `rate_limit`, connection closed 1008 (pre-auth) |
| Guest joins > 3 rooms | `{"type":"error","error":"Guest room limit reached"}` |
| Guest sends 0x04 (SendDirect) | Silently dropped |
| Guest sends >10 binary 0x03 frames/min | Silently dropped |
| Guest idle >30 min (no binary activity) | `guest_idle`, connection closed 1008 |
| Peer joins > 10,000 rooms | `{"type":"error","error":"Too many rooms"}` |
| Invalid room code | `{"type":"error","error":"Invalid room code"}` |
| Message to non-existent room | Silently dropped |
| Message from non-member | Silently dropped |
| Direct to offline target | Buffered (offline_buffer) + FCM push fired |
| Backpressure > 64 MB (hard) | uWebSockets force-closes dead connection |
| No data for 45 s | uWebSockets idle timeout, connection closed; a session goes into grace |
| keys.json removed keys | Affected peers kicked within 30s |
| TLS cert/key missing on startup | Fatal exit |
| Port already in use | Fatal exit |
| libsodium init failure | Fatal exit |

---

## Push notifications & offline message buffer (FCM Tier 2)

The relay is normally a dumb pipe, but to make FCM push notifications deliver real message content it holds offline DMs briefly in RAM.

**State (`RelayState`, state.h):**
- `push_tokens`: `peer_id -> {token, platform}`. Registered via `register_push_token` WS message (`handle_register_push_token`). RAM only, re-registered each app launch.
- `last_push_sent`: `peer_id -> time_point`. Debounce, `PUSH_DEBOUNCE_SECS = 10` (was 30). Throttles FCM call rate only — does NOT drop messages (the buffer keeps them). NOTE: rapid-fire sends within the debounce window suppress later FCM wakes, so some Tier-2 previews won't run until the next un-debounced send — looks flaky under burst testing, fine under normal use.
- `offline_buffer`: `peer_id -> deque<BufferedMsg{room, frame, sender, at, is_image, is_channel}>`. **FAIR-SHARE eviction since 2026-08** (issue #46): when a per-peer cap is hit, `drop_oldest_kind` drops the oldest frame belonging to whichever sender currently occupies the MOST slots of that kind — not the globally oldest. With one sender this is byte-for-byte the old behaviour; under contention a flooder can only evict ITSELF. Without it the per-peer caps bounded RAM but not WHO filled it, so one authenticated peer could buffer 100 frames at any peer_id it knew and evict every genuine message waiting there. **Deliberately NOT a flat per-sender cap and NOT rate limited** — the per-peer caps are legitimately reachable by one sender (500 opted-in), and a per-minute limit would silently drop reconnection bursts and large-server `0x09` fan-out. Both are the message-loss class `feedback_relay_rules` forbids. Each `frame` is a ready-to-send `0x06` direct frame (ciphertext only). **Independent per-peer caps**: baseline `MAX_BUFFERED_MSGS_PER_PEER = 100` (text) and `MAX_BUFFERED_IMAGES_PER_PEER = 1`; **opted-in peers** (message-availability cache, `set_offline_buffer {enabled, retention_secs}` JSON, registry `offline_optin: peer -> retention_secs` clamped 1h..7d, re-sent by ws_client on every reconnect) get `MAX_OPTIN_MSGS_PER_PEER = 500` and `MAX_OPTIN_IMAGES_PER_PEER = 8` with THEIR retention at sweep (images always ≤24h — inlined bytes never ride extended retention). Baseline `OFFLINE_BUFFER_TTL_SECS = 86400` (24h). All buffered bytes count into `buffer_total_bytes` against `MAX_BUFFER_TOTAL_BYTES = 512MB` (oldest-front global eviction, `evict_over_budget`).

**Flow (ws_handler.cpp):**
1. `handle_binary_direct_msg` (0x04 text / **0x08 image**) / `handle_direct` (text): target offline (`peer_sockets` miss) → `buffer_offline_msg(.., is_image)` stores the `0x06` frame → `try_push_notify()` → `notify_push_sidecar()` enqueues `{token, platform, sender}` for the push worker. `buffer_offline_msg` evicts oldest of each kind independently (`count_kind`/`drop_oldest_kind`) so an image burst never pushes out buffered text. **Push delivery uses a SINGLE persistent worker thread + bounded queue (`PUSH_QUEUE_MAX`), NOT a detached thread per push** — `notify_push_sidecar()` enqueues into `PushQueue` (`push_queue.h`), which lazily starts one worker that drains the queue and does the blocking POST to localhost:3001; its shared state is never freed (see Graceful shutdown). The POST carries `X-Push-Token` when `HOLLOW_PUSH_TOKEN` is set (sidecar side: `PUSH_TOKEN`, constant-time compare, 401 on mismatch) — the sidecar holds the Firebase Admin credential, so loopback binding limits reachability but not authorization, and any local process could otherwise push to arbitrary device tokens (issue #46). Unset on either side = open, so the two can be deployed independently. Per-push thread spawning previously caused churn during DM/file-sync bursts (each POST is a blocking connect/send/recv with 2s timeouts). Queue overflow drops oldest (push is best-effort; the DM still delivers via the offline buffer).
2. The peer's FCM fetch node (or full node) later joins the DM room → `handle_join` calls `replay_buffered_msgs()` → sends ALL buffered frames for that room (text + image, both as 0x06), drops delivered entries.
3. `sweep_offline_buffer()` (5-min timer in main.cpp) evicts entries older than 24h.

**Inlined-image delivery (0x08):** An image DM is two wire messages: the text DM (carries only `file_id`) and a separate FileHeader (metadata + AES key) + streamed bytes. The stream is NEVER sent to an offline peer. So for offline images the **sender inlines the AES-encrypted bytes (base64) into the FileHeader's `inline_bytes` field** and sends the Olm-encrypted FileHeader via a **`0x08` SendDirectImage** frame (ws_client.rs `SendDirectImage`, crypto_handler.rs `send_encrypted_image_to_peer` — targets `dm_room_code(local,peer)` DIRECTLY since an offline peer is in no room). The relay buffers it under the image cap. The fetch node (`fetch.rs`) parses `MessageEnvelope::FileHeader`, decrypts the inline bytes, writes `files/{fid}.{ext}`, and **inserts the `messages` row itself** (`[file:{fid}]`, INSERT OR IGNORE) + `insert_file_metadata` + `mark_file_complete` — because the companion text DM is dropped to offline peers. Guests blocked from 0x08.

**Caption (offline captioned image):** sent EXACTLY ONCE via `crypto_handler::send_encrypted_text_to_peer` (a `0x04` SendDirect straight to the DM room, buffered under the TEXT cap, independent of the image cap), AFTER the FileHeader. It is NOT sent via the normal `send_encrypted_message` for an offline image — that helper calls `olm.encrypt()` (advancing+persisting the ratchet) BEFORE checking reachability and then discards the ciphertext if offline, burning a ratchet slot the receiver never sees → a permanent decrypt gap. `file_handler.rs` gates this with `offline_image = !reachable && is_image`. The caption shares the FileHeader's `mid`; `fetch.rs` merges the two entries (real caption text wins over the `[file:...]` sentinel; `promote_file_sentinel_to_caption` updates text+sig+pk when the FileHeader's row won the insert race).

**Signature:** the message-row sig canonically rides on the DirectMessage envelope (the FileHeader handler ignores sig on the online path). For offline images the offline FileHeader carries `sig`/`pk` (captionless: the ONLY sig carrier, signed over `[file:<id>]`); otherwise the row renders "Unsigned".

**Notification render:** NO BigPicture photo preview (removed — decode+downscale on the notif thread was too slow). The image still syncs to the DB; the banner shows a lightweight line — `📷 Image` (captionless) or `📷 <caption>` (caption present, gated on `image_path != null`). iOS: works once APNs is configured (same path).

**Fetch-mode peers** (`is_fetch`, set from `fetch:true` in Auth): excluded from `peer_sockets`, `PeerJoined`, member lists — invisible, so waking via push doesn't show the user online. Buffer replay works for them via `handle_join`.

### Message-availability cache (opt-in offline delivery, 2026-07-04)

Generalizes the push buffer into user-facing offline delivery. **Availability, never authority**: the relay retains the SAME E2EE Ed25519-signed ciphertext it routes; receivers verify + dedup-by-mid + CRDT-merge exactly as if a peer served it; peer sync stays the correctness floor. RAM-only by design (restart = clean slate; nothing seizable persists).

- **DM tier**: `set_offline_buffer {enabled, retention_secs}` (see offline_buffer bullet above). Dart default ON at 3d (`offlineInboxProvider`/`offlineInboxRetentionProvider`, re-applied from `_bootstrap`; ws_client re-registers on reconnect). Delete-on-replay unchanged.
- **Channel rings**: `topic_buffers: room+'\0'+topic -> TopicBuffer{frames(0x08 form + sender), bytes, retention, last_registered}`. Registered additively via `set_topic_buffer {room, channels[], retention_secs}` (member must be in room); idle-expire 7d. **`clear:true` is non-destructive since 2026-08** (issue #46): it sets `accepting=false` and drops `retention_secs` to `OFFLINE_RETENTION_MIN_SECS`, so retained frames age out on the normal sweep instead of being erased on demand, and a drained non-accepting ring is reaped immediately. It used to erase every buffer for the room outright — and since the relay authorizes `clear` by room membership alone (it cannot tell an owner from a member, by design), any single member could destroy the shared catch-up state everyone else depended on. Convention said "Owner/Admin toggle site only"; nothing enforced it. Re-registering re-arms `accepting`. Inbound `0x07` frames tee into registered rings (caps 200 msgs / 1MB per channel). `topic_catchup {room, channel, max_age_secs}` replays to the requester, skipping their own frames (MLS can't decrypt own ciphertext) and frames older than `max_age_secs` (client watermark + 30min lookback via `catchup_watermark_age_secs` — stops SecretReuse noise from cross-session re-replay). With `end: true` (only a member's `~join` read sends it) the replay is followed by `{type: topic_catchup_done, room, channel}`, an empty or missing ring included, so a member just back judges parked asks only after the verdicts behind them (HOL-SEC-121, session 33); a request without `end` never sees that frame, so 0.11 clients are unaffected. Deletion = retention expiry, NEVER delivery ("everyone got it" is unknowable without learning membership).
- **Client wiring** (swarm.rs): CRDT setting `relay_catchup_secs` (Owner/Admin `ServerSettingChanged`; ABSENT = default ON 259200s, explicit "0" = off). Per-channel `relay_catchup_done` gate (cleared on Disconnected); catch-up fires on RoomMembers sweep AND on `SubscribeChannels` (channel open). `register_relay_catchup` re-registers on toggle, connect, channel open, channel create.
- **MLS late-delivery windows** (mls_manager.rs `hollow_join_config`): `out_of_order_tolerance=512`, `maximum_forward_distance=2000`, `max_past_epochs=3`, applied at create/join AND upgraded onto loaded groups via `set_configuration` — OpenMLS defaults (5, 1000, 0) made replayed ring frames permanently undecryptable after newer traffic or an epoch bump.
- **Iron rule**: anything that must reach OFFLINE channel members rides `0x07` topic frames — 0x03 room broadcasts and targeted direct sends are invisible to the rings (channel FileHeaders + file companion messages were both moved to `send_mls_broadcast_topic`).
- **NOT covered**: public channels (0x03, no topic); file BYTES (metadata-only headers; bytes via request-on-open). **OPEN BUG**: channel files still don't render post-catch-up in the real client (harness guard green — see memory `project_relay_availability_cache`).
- **Pending server joins (rung 1, 2026-08-29) reuse this EXACT machinery with ZERO relay changes.** The client treats a server room's join queue as just another topic, `~join` (`JOIN_TOPIC` in `node/types.rs`), registered via the same `set_topic_buffer` call that registers text channels, teed into on `SendToRoomTopic` the same way, and read back via the same `topic_catchup`. This works because the relay validates topic strings for LENGTH only: it has no notion of "channel" versus anything else, so a client-invented topic name is indistinguishable from a real channel id to the C++ side. A parked join request, and a member's resolution of one, are just frames on a ring like any other.

### Channel push (0x09, 2026-06-10)

Server-channel messages reach offline members' phones via SENDER-targeted **0x09 frames** — the relay still never learns membership (the sender picks targets from its CRDT). Frame: `[0x09][room\0][target\0][channel\0][flags:1][payload]`, flags bit0 = mention, payload = the SAME MLS-group/public wire bytes the room broadcast carried (empty = push trigger only, Olm-legacy servers). `handle_binary_channel_direct`: sender must be in the room; buffers whenever the target is **NOT IN THE SERVER ROOM** (2026-07-04 fix — the old FULLY-offline full-return silently dropped copies during the auth→join race and the ~70s ghost-socket window after a hard quit) → `buffer_offline_msg(.., is_channel=true)` (third independent cap `MAX_BUFFERED_CHANNEL_MSGS_PER_PEER = 30`, replayed as 0x06 like everything else); push (`try_channel_push_notify`) only when fully offline.

`try_channel_push_notify` filters BEFORE contacting the sidecar (iOS alert pushes can't be suppressed after delivery):
1. **Prefs registry** `push_prefs: peer -> server -> ServerPushPref{level, channels{cid->level}}` — set via the `set_push_prefs` text message (RAM only, replaced wholesale, re-sent by the app on every reconnect; defensive caps 256 servers / 1024 channels). Channel override beats server level; unregistered = "all" (old clients keep working). Guests rejected; 0x09 also guest-blocked.
2. **Throttles** (state.h): non-mention `CHANNEL_PUSH_DEBOUNCE_SECS = 120` per (peer,server) + `CHANNEL_PUSH_MAX_WHILE_OFFLINE = 3` (counter in `channel_push_state`, reset when the full non-fetch app rejoins THAT server room in `handle_join`; deliberately NOT cleared on disconnect — that's the point of the cap); mention `CHANNEL_PUSH_MENTION_DEBOUNCE_SECS = 10`; `CHANNEL_PUSH_MIN_GAP_SECS = 5` per-peer floor across all servers (`last_channel_push_any`).

Sidecar payload gains `{server, channel, mention}` → FCM `data:{type:'channel_wake', sender, server, channel, mention:'1'/'0'}` (FCM data values must be strings); iOS `apns-collapse-id = iosCollapseId(server + ':' + channel)` so one banner per channel gets replaced by newer pushes. See `push_notifications.md` (Channel push section) + memory `project_channel_push_notifications.md`.

E2EE preserved — buffer holds ciphertext only (image bytes are AES-encrypted inside the Olm-encrypted FileHeader). Durable delivery still owned by full-node DM-sync; the buffer is latency glue so push previews are accurate. Client side: `rust/hollow_core/src/node/fetch.rs` + `lib/src/core/services/push_notification_service.dart`. See memory `project_push_notification_implementation.md`, `feedback_fcm_image_invisible_bubble.md`.

### Push sidecar payload (`push-sidecar/index.js`, VPS localhost:3001)

Node.js sidecar (Firebase Admin SDK) POST `/push` with `{token, platform, sender}`. Builds the FCM message: `data: {type:'wake', sender}` always (the `sender` peer_id rides here, opaque to Apple/Google). Then per platform:
- **Android:** `android.priority = 'high'`.
- **iOS:** a **VISIBLE ALERT** push — `apns-priority:10`, `apns-push-type:alert`, `aps.alert={title:'Hollow', body:'New message'}`, `sound:'default'`, `mutable-content:1`, `content-available:1`. NOT a pure silent (`content-available`-only) push: iOS throttles/drops silent background pushes by design (≈2–3/hr, "opportunities not guarantees"), so they were unreliable for a messenger. A priority-10 alert is delivered immediately and not throttled. The body is a GENERIC "New message" — zero metadata to Apple. `mutable-content:1` triggers the Notification Service Extension (below); `content-available:1` also wakes the Dart bg handler. (APNs rule: priority must be 5 for pure background, 10 for alert — can't combine priority-10 with a pure `content-available` push.)

### iOS rich notifications — Notification Service Extension (Tier A)

The NSE rewrites the generic banner into the sender's real **name + avatar**. It runs in a SEPARATE process/sandbox and CANNOT read the app's private encrypted DB, so:

- **App Group** `group.com.anonlisten.hollow` shared between Runner + the extension (entitlements on both; capability enabled on both App IDs in the Apple portal).
- **Push-hints cache** (`lib/src/core/services/push_hints_cache.dart`): the main app (unlocked, has the DB key) writes a small `{peerId: {name, avatar}}` map to `<AppGroupRoot>/push_hints/hints.json` plus per-friend `<peerId>.img` avatar PNGs. `PushHintsCache.scheduleWrite(friendIds)` is debounced (1.5s) and iOS-gated; hooked into `friendsProvider.loadAll()` (covers startup + every friend mutation) and `event_provider` `ProfileUpdated`. The App Group container path is resolved via the `hollow/app_group` MethodChannel in `AppDelegate.swift` (`getApplicationDocumentsDirectory()` is the PRIVATE sandbox, NOT the group container).
- **Extension** (`ios/NotificationService/NotificationService.swift`): reads `userInfo["sender"]` → reads `hints.json` → sets `title` = name, `body` = "Sent you a message", attaches the avatar (copied to a tmp `.png` for `UNNotificationAttachment`). `serviceExtensionTimeWillExpire` delivers the best attempt; any miss (no App Group, missing/corrupt cache, unknown sender) falls through to the original generic banner — never drops a push.
- **CRITICAL — writer/reader path must match exactly:** both use `push_hints/hints.json` with NO `hollow/` prefix; a mismatch silently degrades to the generic banner (the NSE fails gracefully so it looks like "no hint"). See `feedback_app_group_path_match.md`.
- **Message TEXT/IMAGE preview in the banner = Tier B, deferred** — it needs decryption, which means migrating the iOS data dir into the App Group + a Rust C-ABI linked into the NSE. Tier A ships name+avatar only; body stays generic.

iOS build/config: classic non-UIScene AppDelegate + firebase pinned below the iOS-SDK-v12 break (`firebase_core ^3.15.2`, `firebase_messaging ^15.2.10`) keeps the iOS 13 floor. See memory `project_push_notification_implementation.md`, `feedback_ios_xcode26_toolchain.md`.

---

## Join lock chains (`join_lock.h`, 2026-09-28)

`lock_get {locks:[{server, owner}]}` answers one `lock_chain {server, owner, links}` per entry (empty when none; guests refused). `lock_put {server, owner, links}` offers a chain or next links; the answer is `lock_chain` with the chain held afterwards and `put: true` when the submitted newest lock is now the relay's (guests and fetch sockets refused). Rules in `join_lock::relay_put`, verification via libsodium (`verify_ed25519`, `derive_peer_id`, `genesis_server_id`). Records keyed by server id (40-hex) or server|owner; at most 256 links, 100,000 records, least recently used evicted. Rides the restart snapshot (codec v4, `Lock{key, links_json}`). Test: `test/test_join_lock.cpp` (a signed vector pinned with the Rust test). Deployed 2026-09-29; older clients never send these.

## Security properties

- **Zero-knowledge routing:** The relay never decrypts message content. All payloads are opaque bytes.
- **Authenticated connections:** Every WebSocket connection requires a valid Ed25519 signature over a timestamped challenge. No anonymous connections.
- **No metadata logging (source-enforced, 2026-06-23):** NO log statement in the relay prints a peer_id, room, push target/sender, channel, server, or push token. The entire `[push]` family (buffer/replay/send-push/token-register/prefs/channel-push/direct-not-in-room) and `[license] Key revoked for peer <id>` were stripped — the relay must not record who-talks-to-whom (a truncated `12D3KooW…` prefix still fingerprints). Only aggregate counts (`Swept N`, `Loaded N key(s)`), config-file paths in parse errors, and `[main]` startup/shutdown banners remain. peer_ids in `state.*` maps / protocol `send_json` responses / signature strings are routing logic, NOT logging. See `feedback_relay_no_metadata_logging.md`.
- **Sender identity injection:** For binary types 0x02/0x03/0x04, the relay replaces/injects the sender's peer_id — peers cannot spoof their identity to the relay.
- **Timestamp anti-replay:** 60-second skew window limits replay attacks on auth and signaling requests.
- **No rate limiting:** Removed — Ed25519 auth + license keys are the DoS protection layer.
- **Room isolation:** Peers can only send to rooms they've joined. Non-members are silently rejected.
- **License revocation:** Active connections can be terminated within 30 seconds by removing their key from `keys.json`.
