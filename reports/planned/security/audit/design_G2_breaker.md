# G2 relay circuit breaker: design v2

> Archived design v2 of the 0.13 relay circuit breaker, shipped in shadow mode. Later review rounds changed details (numbers in `relay-uws/src/breaker.h`); the code and wiki `security_write_gates` §52 are authoritative. Review files it names stayed in the track worktree.

Answers every item of `.team/G2_REVIEW_1.md` and Vitalii's 10-23 decisions. Kept from v1 (found sound):
work units over CPU time, deterministic session buckets, trip BEFORE `count_in` with the hint through
`write_raw`, 1013 = grace, the device ladder 1m/5m/30m/2h/24h with one level forgotten per 6 quiet
hours, HOL-SEC-069 and AR-36 arithmetic. The OOM work (global buffered bytes, fan-out byte admission,
non-draining receiver close) is track g13w3-oom; section 9 is the seam.

## 0. Changes from v1

1. **Who pays for a fan-out** (H2): the sender pays the deliveries the relay actually makes, walked with
   the SAME predicate the delivery loop uses (so a door room's hidden non-provers cost nothing), with
   at most 8 W per receiving share per frame. Deliveries of a public 0x0A frame to sockets outside the
   room's audience (guests, non-provers) are paid from a per-room outside allowance.
2. **Budgets resized from the 1,536-device reference** (H3): W start 400k / cap 800k / refill 1,000 W/s;
   joins 2,500 / 5,000 / 2 per s; distinct strangers 50k per 10 min; 0x09 = 1 W; the separate
   signature bucket is folded into W (6 W per check already prices its CPU).
3. **No address cooldowns, no address refusals** (H4, decided): the share_block (v4 address, v6 /48)
   only DEGRADES a fresh session's start credit, in three tiers (400k / 100k floor / 24k), told to
   the client in `auth_ok.credit`. Cooldowns exist only per DEVICE.
4. **A tripped session survives its cooldown**: grace = wait + normal grace, held without an IP slot;
   its close and its resume are never charged.
5. **Lifecycle presence charged per ROOM** (M2): 1 W per room per presence pass, 4 W per room per
   resume. Join and leave announcements stay per recipient (with the share cap).
6. **Self-replays uncharged** (M3): offline-buffer replay, mailbox past the mark, grace directs, the
   resume ring replay. Each is bounded by caps that only paying depositors refill. Debt floor -100k.
   Topic catch-up, relock and lock_put are predicted exactly before the frame is admitted.
7. **Socket kinds** (M1): fetch and guest sockets get small fixed buckets and trip by close only, never
   cooling the device; push fetch logs in during a device cooldown; the forwarder is exempt;
   session-less full sockets keep their buckets on the socket.
8. **Client pacing** (H3, new): `ws_client` mirrors the buckets with the published constants and a
   per-frame cost that never undercounts what the relay charges, including the resume resend window.
   The node tells `ws_client` an upper bound on each room's devices (`WsCommand::RoomBound`), because
   hidden, held and fetch receivers are invisible to the client by design (decision 6).
9. **M5 traps fixed**: cooldown and debt refusals happen before any binding (close 1013, not 1008);
   the breaker hint carries `breaker:true` and is honoured past `MAX_DRAIN_WAIT`; the cooldown key is
   a process-lifetime keyed hash; distinct targets use one sketch per minute.
10. No new wire TYPE: `reconnect`, `auth_ok`, `auth_failed` gain optional fields, all uncounted, so
    `session_vectors.json` and both type-count lists stay unchanged. New pinned file:
    `relay-uws/test/breaker_vectors.json` (constants + per-frame cost cases, read by C++ and Rust).

## 1. Units and charging

W per relay action, deterministic, no clocks:

| action | W |
|---|---|
| inbound frame (any, counted or not) | 1 |
| socket write or held-ring push outside a fan-out (answers, `members`, acks) | 1 |
| fan-out delivery (broadcast, topic, join/leave announce, inbox live copies) | 1, at most `SHARE_CAP`=8 per receiving share per frame |
| listed ids in `members` / `discovered_peers` / `check_peers` scan | 1 per 32 ids |
| Ed25519 check | 6 |
| door X25519+HMAC check | 4 |
| offline-buffer deposit (direct to a target not in the room) | 1 |
| 0x09 channel copy (frame + its deposit + its push) | 1 total |
| presence pass (`inactive`/`active`, settled when it runs) | 1 per room walked |
| resume (members per room, came-back announcements, the grace entry before it) | 4 per room held |
| replay of the device's OWN held data (offline buffer, mailbox past `mailbox_mark`, grace directs, ring after `in_h`) | 0 |
| a breaker close and the resume that follows it | 0 |

Bytes are never counted (decided; CAKE keeps volume; fan-out BYTES are the OOM track's admission).

Mechanics. A process-global `breaker::g_work` is bumped by `write_raw`, `send_held`, `buffer_offline_msg`,
`verify_ed25519*` and `door_proof_opens` (the measure build's hook points), so every handler, future
ones included, is charged. Three RAII guards change what the bump does:
- `breaker::Fanout`: inside it a write or held push adds to a per-share tally (the receiver's
  `group`, below) instead of `g_work`; on exit it charges `sum(min(tally, 8))`. Used by `handle_msg`,
  `handle_binary_msg`, `handle_binary_topic_msg`, the join/leave `announce_door_change` and the inbox
  live copies in `handle_binary_direct_msg`.
- `breaker::Uncharged`: bumps go nowhere. Wraps self-replays, `settle_presence`'s announcements (the
  flat per-room charge replaces them), `resume_session`'s writes (flat), `expire_door_grace` (a
  `discover_peers` must not pay for others' door graces), `drop_inbox_owners`'s notices and the whole
  trip/close path.
- `breaker::Scope` (one per inbound frame, outermost only, like `measure::Scope`): charges the
  frame's `g_work` delta to its payer after the handler.

`group` = `hash(process_key, share_block)`, cached in `PerSocketData` at `.open` and copied to the
`Session` on mint/resume (held receivers). Not the hourly `share_id`: the tally only needs a stable
grouping inside one frame. A restored session (no group yet) counts as its own group until it
resumes (overcharges, never under).

## 2. The buckets and their constants (compile-time, not config: self-hosters cannot lower them)

| bucket | payer | start | cap | refill |
|---|---|---|---|---|
| W, full socket (session or session-less) | session, else socket | tier: 400k / 100k / 24k (section 4) | 800k | 1,000 W/s |
| W, fetch socket | socket | 20k | 20k | 200 W/s |
| W, guest socket | socket | 5k | 5k | 50 W/s |
| joins, full | session / socket | 2,500 | 5,000 | 2/s |
| joins, fetch | socket | 2,500 | 2,500 | 2/s |
| joins, guest | socket | 3 rooms already (MAX_GUEST_ROOMS) | 10 | 0.1/s |
| distinct strangers | session / socket | 50,000 per sliding 10 min | | |
| outside allowance (0x0A to non-audience) | `WsRoom` | 50k | 50k | 500 W/s |
| fresh-start pool | share_block | 1.2M | 1.2M | 2,000 W/s |

Debt floor: a W level never goes below -100k (a charge past it is clamped; the next counted frame
trips). The forwarder (`config.forwarder_peer_id`) has no buckets.

### 2.1 The honest reference these come from (H3)

Reference heavy user R: 10 servers of 1,536 devices (512 ids x 3, the MLS cap), 40 servers of 200,
300 friends with 3 devices each. Per-operation costs from the harness (per other device: join 10.8
frames, fresh reconnect 5.1, owner kick 3.1, leave 2.1, mostly carried directs at 2 W) and the code:

| journey | W | joins | distinct strangers |
|---|---|---|---|
| fresh reconnect into one 1,536 server (7.8k directs x 2, catch-up 10 ch x 200, announce 1,536, listing 48) | ~20k | 1 | <= 1,535 |
| R's fresh reconnect (10 big + 40 x ~4.3k + 300 DMs x ~30) | ~380k | ~352 | <= 24k (all offline) |
| owner kick or ban in a big server (4.8k directs x 2 + commit 1,536 + relock 1,536 x 4 + links) | ~17k | | |
| a 30-ban raid response | ~510k | | |
| a post in a full big server (1 broadcast 1,536 + 0x09 per offline device <= 1,536 at 1 W) | <= 3.1k | | |
| sustained heavy chatter: 1 post / 10 s + typing (1 broadcast / 5 s half the time) + background | ~700 W/s | | |
| lock chains re-put after a relay forgot them (50 servers x 256 links x 6) | ~77k | | |
| every room again on a fresh session (client `ROOM_BUDGET_LIMIT`) | | 2,000 | |

Margins: start 400k covers R's whole reconnect at once (1.05x; pacing covers the rest, section 5);
cap 800k = the raid x 1.6; refill = sustained x 1.4; joins start = the client's room limit x 1.25;
distinct = R x 2. A post's break-even is one per 3 s forever (v1: one per 9 s).

## 3. Admission and trip (per inbound frame, before `count_in`)

In `.message`, after parsing a text frame and before `count_in` (binary: before `count_in`), call
`breaker_admit(state, ws, data, frame) -> Plan`:

1. A socket already closing (`PerSocketData::closing`, set by any close path incl. the OOM track's) is
   not judged. The forwarder is not judged.
2. Refill the payer's buckets to now.
3. `Plan.w` = the relay's prediction, exact where the frame's cost is large:
   - broadcast/topic/`msg`: 1 + a dry walk of the room with the delivery predicate (sees/shares,
     subscription filter, held sessions), tallied per group with the cap. 0x0A: the members part is
     the same walk; the outside part is predicted against the room's allowance (section 6);
   - `join`: 2 + 4 if a door proof is shown + ceil(L/32) + the announce walk as if the join becomes
     visible (an upper bound) + 6 per signature of a shown inbox roster;
   - `leave`: 1 + the announce walk;
   - `topic_catchup`: 2 + the ring frames that pass its age filter (counted, not written);
   - `lock_put`: 2 + 6 x links + (if it would move the door) 4 x stored proofs in the room;
   - `lock_get`: 1 + 2 per requested server (<= 256); `check_peers`: 2 + 2,048; `discover_peers`:
     2 + ceil(n/32); directs 2; deposits 2; 0x09: 1; `kill_deposit`: 2 + 6 x (roster sigs + 2) +
     targets; anything else 2.
   `Plan` also carries `recipients` and `frame_bytes` for the OOM admission (section 9).
4. Trip if any holds: the frame is a `join` and joins < 1; it deposits to a new stranger target
   (section 7) and the 10-minute estimate is >= 50,000; or `W - Plan.w < 0` (a level in debt trips
   every counted frame). `hb`, `ack`, `inactive`, `active`, `end` never trip; they are only charged.
5. Not tripped: `count_in`, run the handler inside `breaker::Scope`, charge the ACTUAL work (<= the
   prediction where it was exact; the debt floor bounds the rest), take 1 join for a join.

**Trip** (the frame is NOT counted and NOT handled, so the client's `Outbound::resume` resends exactly
it and what followed):
- full socket with a live session: the device's ladder steps (section 8); wait `A = max(cooldown,
  ceil(-W / 1,000 W/s) + 2 s)`; `s.breaker_until = now + A`, `s.breaker_free = true`; `write_raw`
  `{"type":"reconnect","after_ms":A,"breaker":true}`; `ws->end(1013, "breaker")` under `Uncharged`.
- session-less full socket: same ladder and hint; nothing in flight survives (only the forwarder and
  pre-0.12.1 clients are session-less here, and the forwarder is exempt).
- fetch or guest socket: hint with `after_ms` 30,000 and close 1013; NO ladder step, no cooldown.

The close handler sees 1013 (not 1008), so the session enters grace. For `breaker_until` set:
`grace_until = breaker_until + g_grace_secs`, queued in a separate `long_grace_ends` min-heap (the
`grace_ends` deque assumes one fixed length), and the session holds NO per-IP slot (the closing
socket's slot is freed at once; a 24 h hold of one of 34 slots would starve a CGNAT address). The
session book keeps it in grace for table eviction. The ring keeps taking deliveries (bounded 8 MB /
4,096 with tombstones); DMs still wake the phone; the push fetch reads its grace directs.

## 4. Fresh-start credit per share_block (H4, decided: degrade, never refuse)

Each share_block (v4 address, v6 /48) has a pool (1.2M, refill 2,000 W/s) and a window of fresh FULL
starts in the last 60 s. A fresh full session (or session-less full socket) gets:
- **400k** if the pool holds 400k (drawn from it);
- else **100k** (the floor: an ordinary fresh reconnect, e.g. 3 big servers + 20 mid ones) if the
  window holds fewer than 10 starts (the per-address connection allowance, so a v4 address never
  goes below it);
- else **24k**, and the client paces up at 1,000 W/s.
The tier rides `auth_ok` as `"credit":400000|100000|24000` (quantized: it tells the client only
whether its block's pool is empty, never a level). Resumes take nothing (the session's bucket goes
on); restored sessions start at 400k (a restart is not caused by a client). Fetch and guest sockets
use their fixed starts. Pools live in a 65,536-entry table keyed by `hash(process_key, share_block)`,
evicted by FairShare (heaviest share first) and erased once full and idle, so nothing older than
about 10 minutes names an address; never logged, never snapshotted.

## 5. Client pacing (H3: an honest client never trips)

New pure module `node/relay_pace.rs` (no socket, no clock, tested with instants like
`relay_session.rs`), driven by `ws_client.rs`. Constants are Rust consts pinned against
`breaker_vectors.json`.

**Invariant.** The client keeps a mirror `M` of its W, joins and distinct buckets with `M <= relay
level` at all times. It writes a frame only if `M - cost >= RESERVE` (16k W), with `cost >=` what the
relay predicts and charges for that frame. Then the relay never trips it: `relay - predicted >= M -
cost >= 0`. The reserve absorbs refill skew from network jitter (1,000 W/s x up to 16 s) and the rare
frames whose cost the client can only bound loosely.

**Start.** Pacing is on only when `auth_ok` carries `credit` (a breaker relay); `M = credit` on a fresh
session. A normal resume keeps `M` (refilled by elapsed time) and spends `4 x rooms joined`. A resume
after a breaker trip sets `M = 0` (the relay admits it only at a level >= 0, and charges nothing for it).

**Cost per frame** (`relay_pace::cost(frame, rooms)`, on the rendered wire bytes, so queued commands and
resent frames are priced the same way):
- broadcast (0x03, 0x07, `msg`) into room r: `1 + E(r)`, where `E(r) = max(told(r), bound(r)) + max(8,
  ceil(max(told, bound)/8))`. `told(r)` = the presence count `rooms.audit` holds; `bound(r)` = the
  node's device bound (below), absent = `told(r)`. The 12.5% pad covers a kicked member's devices
  during the 60 s door grace;
- 0x0A: the same (the outside part is the room allowance's, section 6);
- direct (0x02, 0x04, 0x08, `direct`, carried): 2; to an `inbox:` room: 2 + 8 (the owners' live copies);
- 0x09: 1;
- `join`: joins 1; W `2 + 4 + ceil(E/32) + E + 6 x roster sigs`, unknown room `E = 64`; when its
  `members` answer arrives the mirror is corrected down by any excess of `2 + 4 + ceil(L/32) + L` over
  what was spent (a stranger-heavy room larger than guessed);
- `leave`: `1 + E`; `topic_catchup`: 202; `lock_put`: `2 + 6 x links + 4 x E`; `check_peers`: 2,050;
  `discover_peers`: `2 + ceil(E/32)`; `lock_get`: `1 + 2 x servers`; `kill_deposit`: `2 + 6 x (sigs
  + 2) + targets`; anything else: 2;
- `inactive` / `active`: `1 + rooms joined`, `hb` / `ack`: 1. Control frames are spent but never
  wait.
- distinct: a direct or 0x09 to a target not seen in the last 10 minutes counts one; the client stops
  new targets at 40,000 (80% of the relay's 50k: the relay's sketch errs by about 3%, the client
  counts exactly per minute).

**Room bounds.** Hidden, held and fetch receivers are never in presence (decision 6), so `told` alone
undercounts in a big server at night. The node therefore tells `ws_client` an upper bound:
`WsCommand::RoomBound { room_code, devices: u32 }`, handled locally in `enqueue` like `SetDoor` (never
sent to the relay). `node/room_bounds.rs` computes, for every room the node holds: a server room =
sum over members of `max(1, devices_for(member).len())` + our own devices; a DM room = the friend's
devices + ours; our inbox and `roster_book::own_room` = our devices; a `fwd:` room = 1. It sends a
changed value after `ServerUpdated`, after a roster change, and on the existing 30 s tick. Every
receiver of a door room, DM room, inbox or `fwd:` room is a member device, so `bound` covers them.

**Pacing in `ws_client.rs`.**
- `Client.pace: Option<Pacer>`, created in `establish_on` on `Fresh` when the relay sent `credit`,
  kept across resumes, dropped on `lose_session` with the session.
- `pump()`: render the next entry, price it; if the pacer says not yet, keep the rendered frame in
  `self.paced: Option<(Frame, bool)>` (rendering has side effects: `replayed_joins`, `LeftRoom`,
  `last_join_attempt`) and set `pace_at`; `next_deadline` considers `pace_at`; `can_pump` waits for
  it. Nothing behind the held frame moves, so wire order stays program order.
- **Resume resend window.** `establish_on(Resumed)` no longer writes the window in one loop: the
  frames go into `self.resend: VecDeque<Frame>`, written first by `pump` through the pacer and
  WITHOUT `out.record` (they are numbered already), then the reprove joins, then the queue.
- `ServerMsg::Reconnect { after_ms, breaker }`: with `breaker`, `cooldown_until = now + after_ms`,
  NOT capped by `MAX_DRAIN_WAIT`, `refused` untouched, log "The relay paused this connection for N s".
  Without it, today's drain path.
- `auth_failed` with `error:"cooldown"` and `after_ms` becomes `ConnectError::Cooldown(after)`: not
  `refused`, the sid is kept (the relay holds the session for the wait + grace), the next attempt is
  at `cooldown_until`. `backoff_cap` counts the session resumable while `since_suspended < grace +
  cooldown`.
- `nudge()` never starts a connect before `cooldown_until` (focus, push and network included). The
  push fetch uses its own socket and is not affected (section 8).
- `Rooms` exposes `told_count(room)` from the audit's told set; `RoomBound` values live in `Rooms`.

Old clients (no pacing) keep working: the budgets sit above the reference; if one trips, it caps the
hint at 30 s, its login is refused with `cooldown` until the wait ends (each refusal is one connect and
one signature check), and its session is still held, so it resumes.

## 6. Who pays for a fan-out (H2)

- The walk uses the delivery predicate, so the charge is the VISIBLE audience by construction: a door
  room's non-provers, an inbox's non-owners, a `fwd:` room's non-paired members receive no broadcast
  and cost nothing; `peers.size()` is never read.
- Per frame, each receiving group (v4 address or v6 /48) costs at most 8 W, so a stranger who fills
  a room from one /56 (8,700 sockets) adds 8 W to each post, not 8,700.
- 0x0A to sockets that do not see the room (guests, non-provers): paid from the room's outside
  allowance (50k, 500 W/s: 500 guests at a post a second). What the allowance cannot cover is charged
  to the poster at 1 W per group (not 8). A poster that is also the stranger flooder (its own locked
  room full of its own guests) pays linearly: 34 guest sockets per address cost 1 W, so at most 34x
  amplification per address, bounded by its connection slots.
- Amplification bound of the share cap: an attacker's own room of 34 sockets per address costs its
  broadcaster 8 W per address for 34 deliveries, 4.25x at most, still linear in its sockets.

## 7. Distinct strangers (H3, M5)

Counted only for deposits (a direct whose target is not in the frame's room, the empty-room 0x04/0x08
branch, 0x09) whose target is a stranger: no live socket and no session in grace, or one that shares
no room with the sender (checked only on that rare path). Exact set per minute up to 512 targets, then
a HyperLogLog (p = 10, 1 KB) for that minute; ten minute slots, the estimate is the union of the last
ten (sketches merge; a sliding HLL does not exist). Allocated only for a payer that deposited to a
stranger. Keys are `hash(process_key, target)`.

## 8. Device cooldowns, refusals and socket kinds (M1, M5)

- **Ladder** per DEVICE: 1 min, 5 min, 30 min, 2 h, 24 h; one level forgotten per 6 h without a trip
  (computed lazily at lookup). Key `hash(process_key, device_id)` with a key minted at start and
  never rotated (not the hourly share key, which would forget a 24 h cooldown within the hour). Table
  65,536 entries, FairShare by the group of the trip, an entry erased once at level 0 and out of
  cooldown. Never logged, never snapshotted: a restart forgives (and a restored session gets only the
  normal grace, so a device in a long cooldown across a restart comes back fresh).
- **Refusals before binding** (M5): in `handle_auth`, after the signature and license, BEFORE
  `settle_login`, `resume_session`, `end_session` or `mint_session`: a FULL login (fresh or resume) of a
  cooled device gets `{"type":"auth_failed","error":"cooldown","after_ms":remaining}` and `end(1013,
  "cooldown")`. The socket was never the session's socket and is not `authenticated`, so the close
  handler touches no session. A resume of a session whose W is below 0 gets the same frame with
  `after_ms` = time to 0 (AR-36: a resume loop costs at most the refill). A fresh "new" login during
  a cooldown is refused too, so it cannot end the held session.
- **Fetch sockets**: own buckets (section 2); a trip closes only; a cooled device's FETCH login is
  admitted (push keeps working); every replay a fetch socket gets is self-data, uncharged, so a push
  wake that replays the whole mailbox costs it nothing.
- **Guest sockets**: own buckets; trip closes only; their receipt of public frames is the room
  allowance's.
- **Forwarder**: exempt by `config.forwarder_peer_id` (auth binds the id to its key).
- **Session-less full sockets**: buckets on the socket, start from the pool tiers, ladder as a device.

## 9. The seam with the OOM track (H1)

- One `Plan` per inbound frame (section 3) carries `recipients` and `frame_bytes`. The OOM track's
  fan-out admission reads them (`frame_bytes x recipients` against the global buffered-bytes budget)
  in the same pre-check, BEFORE the breaker's W check. Its refusal closes the sender with its own code
  path and is NOT a breaker trip (no ladder step).
- Exactly one close per socket: every close path (breaker trip, OOM sender refusal, OOM non-draining
  receiver close) goes through `close_once(ws, code, reason)`, which sets `PerSocketData::closing`
  and returns false when it was already set. The breaker never judges a closing socket.
- The breaker never closes a receiver and never closes inside a fan-out loop (it only acts in the
  pre-check), so the OOM receiver close and the breaker cannot meet in one loop.
- Later reading of the budget: `breaker_admit` takes the OOM track's `buffered_bytes()` through
  `Plan` and may refuse a frame whose predicted bytes would cross the budget as a breaker trip, if
  the lead wants the two merged; v2 does not, it only leaves the field.

## 10. Provoked answers (M4)

Bytes are not W, and every automatic answer is O(1) frames per request (sync answers are pages: one
frame per ask, `sync_handler.rs`), so a requester pays the same order of W as the answerer. The
remaining asymmetry is reactions to a churning co-member (key exchange, profile, sync): about 10
directs = 20 W per member per churn. A churner is held to 10 connects a minute per address, so A
addresses churning cost each honest member about 200 x A W per minute against a refill of 60k per
minute: 60 addresses eat 20% of one member's refill, and pacing turns even that into delay, never a
trip. No relay discount for in-room directs (it would double an attacker's direct rate per socket);
no new node throttle needed. A harness test measures the reactions per churn and asserts the bound.

## 11. Residuals (stated, not fixed here)

- **Per address flat-out**: 34 sockets x 1,000 W/s ~ 34k W/s, plus fresh-session churn ~ 2k + 10/min
  x 100k ~ 19k W/s: about 0.45 of one relay core per abusive v4 address that stays under every
  human reference. This is the price of budgets that never trip a member of ten big servers; v1's
  smaller numbers tripped them (H3).
- **Many address blocks** (AR-36): each block brings its own pool and slots. A v6 /48 holds 65,536
  /64s, each with its own connection rate; the start tier drops to 24k for a flooding /48, but the
  connection flood itself (TLS, auth checks) is outside G2 (the review's /56 note).
- **Hidden strangers in UNLOCKED rooms** (legacy server ids, conference rooms): sockets the victim
  cannot see and the node cannot bound. The share cap limits each group to 8 W per post and the
  reserve absorbs some; a victim may trip in the extreme, and a trip there is a 1 min pause with the
  session kept. Door rooms, DM rooms, inboxes and `fwd:` rooms have none.
- **Resume cost**: 4 W per room undercounts a resume of 50 big rooms (~77k writes) by about 50x; the
  bound stays the connection rate, as AR-36 accepted.
- Legacy device = master identities: anyone with the master key can trip that device (as supersede).

## 12. Build plan (after "go")

1. `relay-uws/src/breaker.h`, header-only: `Bucket` (refill, clamp, debt floor), `Fanout` tally,
   `Ladder` / `CooldownBook`, `StartPools`, `Distinct` (minute sets + HLL), `Allowance`, `Plan`,
   constants. `test/test_breaker.cpp` + `test/breaker_vectors.json`. Test first, each RED first.
2. `ws_handler.cpp` / `state.h` / `session.h` / `session_bounds.h` / `crypto.cpp`: the hooks of
   section 1, `breaker_admit`, trip, long grace without slot, refusals in `handle_auth`, `credit` in
   `auth_ok`, `closing` + `close_once`.
3. Live relay tests (`test_relay_live.cpp`): an honest burst at the reference does not trip; a flood
   trips and resumes with no frame lost or repeated; a cooled login is refused and the session
   survives; a fetch trip cools nothing; a door room's hidden sockets cost the poster nothing; a
   /56 of sockets costs 8 W per post; guests drain the allowance, not the poster; the trip's own
   presence is uncharged; the forwarder is exempt.
4. Rust: `relay_pace.rs` + tests (cost table against the vectors, invariant `M <= relay` under a
   simulated relay, resend window paced), `ws_client.rs` wiring, `room_bounds.rs`, harness block
   `// g13w3-g2` (bounds follow members x devices; reactions per churn within section 10's bound).
5. Mutation pass over the trip rules, the share cap, the allowance, the free breaker resume, the
   refusal-before-binding, the pacer's reserve and the resend pacing: one test per layer.
6. VPS plain + SANITIZE; fleet journeys (p, q, r, s) against a breaker build with zero trips, then a
   flood that trips; PC nextest for the Rust change.

## 13. Questions for the lead and Vitalii

1. The per-address residual (~0.45 core flat-out per abusive v4 address) is what the 1,536-device
   reference costs. Accept, or lower the reference (for example 5 big servers instead of 10)?
2. Room bounds come from the node. The alternative, the relay reporting each session's level in
   `ack`, was rejected: a sender comparing its own spend with the level learns how many hidden or
   held devices sit in a room, which breaks decision 6 in a DM room.
3. `auth_ok.credit` tells a client whether its address block's pool is empty (one bit about its
   neighbours' fresh logins). Acceptable?
4. The signature bucket is folded into W (6 W per check prices its CPU). Agree?
