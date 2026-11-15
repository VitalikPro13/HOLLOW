# Resumable sessions: bounds, fairness and restart review

Wave 2 of `reports/shipped/relay-and-sync/RESUMABLE_SESSIONS_PLAN.md`, the hostile review
of what section 4 names "a stranger filling rings, a session flood from one address", on the
merged relay at 4dfa2b10. Method: `SECURITY_AUDIT_PLAN.md` sections 2.7 and 3, a hostile
test first for every attack, run on the VM (`relay-uws/test/run_tests.sh`, then
`SANITIZE=1`). Green on the unchanged relay is a recorded non-finding; red is a finding,
fixed and mutation-checked. The handshake, the authority re-checks and the client are
reviewed separately (review-handshake).

Attackers: a stranger with free identities and one address, a few, or an IPv6 /48; a
co-member of a big public server; many clients behind one carrier NAT address; a client that
never acks.

Findings: HOL-SEC-170 to HOL-SEC-172. Two more were found independently and filed first by
the handshake review: HOL-SEC-164 (`active`) and HOL-SEC-165 (owed acks), one fix each.

## Attacks examined

| # | Attack | Test | Verdict |
|---|---|---|---|
| 1.1 | A stranger or co-member floods a device's ring, live or in grace | `test_session` (a flood evicts only the flooder); `test_session_hostile` "a flood into a ring under a short pool buries the flood, not what a friend sent" | Non-finding: the ring evicts the heaviest sender share's oldest frame |
| 1.2 | Adjacent tombstones and `gap` accounting under any mix of pushes, gaps, acks, ring caps, budget burials and hand-offs | `test_session_hostile` "the ring against a model" (60,000 random operations, then 120,000 pushes at a cap of 300 with uneven senders) | Non-finding on 4dfa2b10; kept green through the HOL-SEC-171 rework |
| 1.3 | A frame larger than the ring cap | `test_session_bounds` "a frame bigger than a ring is counted, never charged"; live "sessions: what the ring cannot keep replays as a counted gap" | Non-finding: written live, kept as a one-frame gap |
| 1.4 | A large broadcast fanned out to thousands of rings in grace | `bench/session_cost.cpp` | Memory: one shared buffer, charged once, 1 KiB per ring; over 8 MiB nothing is kept. CPU: HOL-SEC-171 |
| 1.5 | Receivers that never ack (or a big server's phones in grace) holding a sender's frames | `test_session_hostile` "receivers that never ack" | **HOL-SEC-170** (Medium) |
| 2 | Ring traffic pushing other shares' offline DMs and topic frames out of the shared 512 MB budget | the same three checks | **HOL-SEC-170**: rings now have their own pool |
| 3 | `OfflineIndex` shared fan-out buffers keyed by raw pointer: a stale entry and a new buffer at the same address (ABA) | `test_session_hostile` "a buffer at the address a freed one had": placement new forces the same address after each way a ring frame leaves (ack, frame cap, byte cap, the budget's `released`, the session's end), index totals exact both ways | Non-finding on 4dfa2b10 and after. Every exit was enumerated: `Ring::ack`, `enforce`/`evict_one` (on_drop = `forget`), `evict_budget_seq` (the caller forgot first), `take_all` via `ring_take_all` (the only path before `sessions.erase`), the snapshot restore (`place` forgets a skipped ring), the hand-off (copies bytes, stamps anew); a mint never overwrites a held session (every non-fetch login ends it first) |
| 4.1 | Per-IP slots of sessions in grace (`hold_ip_slot`, `release_ip_slot`) | `test_session_bounds` per-IP cases; `test_session_hostile` "the book that spares the caps a walk of the table" | Non-finding |
| 4.2 | The session table cap: heaviest share, grace before live, closest to its end, a tie on the newcomer's share | `test_session_bounds` table cases at 262,144; the book test compares 8,991 choices with a walk | Non-finding (semantics); CPU: HOL-SEC-171 |
| 4.3 | IPv4 vs IPv6 `/48` shares, `ip_limit_key` `/64`, v4-mapped addresses | code read of `address_block` | Non-finding. Residual (pre-existing, phase G): a `/48` holds 65,536 per-IP keys; its sessions are one share, so the table cap ends its own first |
| 4.4 | `grace_slot_victim` at a full address, chosen before the login | live "bounds: a full address and the grace slots it holds" (test build: three sockets an address) | **HOL-SEC-172** (Low): the returning device lost its own session, or cost another device its session |
| 4.5 | Behind one carrier NAT address, a stranger ending other people's grace sessions | the same live case ("a newcomer to a full address gets the slot a session in grace held") | Accepted policy: a newcomer takes the oldest grace slot, at most ten a minute (the rate check), and only once its login is through; before sessions a neighbour could already hold all 34 slots |
| 5 | O(n) work per mint, per socket, per frame at 262,144 sessions or full rings | `bench/session_cost.cpp` | **HOL-SEC-171** (Medium): 45 to 95 ms per mint at a full table, 44 to 91 ms per socket at a full address, 265 us per full ring per frame; after: 1.7 us, 0.03 us, about 2 us |
| 6.1 | Snapshot v9: counts, sizes, a truncated or oversized record | `test_snapshot_codec` v9 cases (a truncated record, bytes after it, a missing buffer, a bad flag, every truncation of the whole) | Non-finding: a bad record is dropped alone, a bad snapshot whole |
| 6.2 | The table cap on restore | `test_session_bounds` "a table past its cap sheds the heaviest share's sessions" | Non-finding (the relay wrote the snapshot; the cap only bites if a build lowers it) |
| 6.3 | Restored sessions hold no per-IP slot: what that allows after a restart | `test_session_hostile` "sessions back from a snapshot and the book" | Non-finding: a restored session never counts against an address and is never another socket's grace slot; it takes a slot only by resuming, so across a deploy an address gains at most one grace window of sessions, within the table cap, which still sees them |
| 6.4 | Ring tombstones, frame room and kind across a restart | `test_session_bounds` snapshot cases; the ring model test restores rings mid-run | Non-finding |
| 6.5 | The restore log line | code read of `restore_from_fdstore` | Observation: "frames live after expiry" counted ring frames too, a session count in a log line (9.7 says none); with the separate pool it counts buffered frames only (fixed with HOL-SEC-170) |
| 7 | Drain: one `reconnect{after_ms}` per session socket in [2000, 10000], nothing counted after the snapshot, `socket_of`'s sid check | live "bounds: on SIGTERM each session socket is told when to come back, then closed" (the client signals the relay itself); `test_session_bounds` drain cases | Non-finding on 4dfa2b10. The close handlers that run after the snapshot write presence only (uncounted) |
| 8.1 | A client that never acks: ring at its caps, the pool, the CPU of a full ring | hostile pool and ring tests, the bench | HOL-SEC-170, HOL-SEC-171 |
| 8.2 | A client that acks wrongly (above what was sent, below its last ack) | live "an ack past what the relay sent acks nothing", "a count below what the device acked is bad_h" | Non-finding |
| 8.3 | `inactive` / `active` in a loop | live "bounds: active tells a session only the presence it was spared"; `RELAY_LIVE_PROBE=active` | Found, same as **HOL-SEC-164** (filed first by the handshake review, its fix kept): 20 toggles from a session in 5,000 rooms made the unchanged relay write 100,000 members frames |
| 8.4 | `end` in a loop | live "sessions: end hands off and closes" | Non-finding: without a session `end` is ignored, with one the socket closes |
| 8.5 | A counted frame between heartbeats, in a loop | `test_session_hostile` "acks owed to a client that beats between frames"; `RELAY_LIVE_PROBE=acks` | Found, same as **HOL-SEC-165** (filed first by the handshake review; the rule now lives in `Session::count_in`): 21.7 MB for 200,000 pairs, 0.6 MB after |
| 9 | Pushes from frames into a ring in grace | live "bounds: frames into a ring in grace wake the phone once per debounce" | Non-finding on 4dfa2b10: seven directs in a burst, one push |

## Probes

Both run against the unchanged relay too (`.wave2/sync_orig.sh` in the review worktree):
`RELAY_LIVE_ONLY=probe RELAY_LIVE_PROBE=active|acks bash run_live.sh`. They print numbers and
check nothing; the tests above are the regression checks.

## Mutation pass

Each rule broken alone, the named tests run on the VM, the file restored by hash: 19 of 19
killed. The rings' pool: holding charged to the sender (M1), no pool enforcement (M2), the
pool burying the holder's oldest frame instead of the heaviest sender's (M3), a bytes victim
dropping its charge without burying the buffer (M4), one budget again (M5). The ring: the
lightest sender evicted (M6), no compaction (M7), a run of tombstones replayed as several
gaps (M9). The book: a tie not on the newcomer (M10), live before grace (M11), a grace, a
resume, an end or a restore not booked (M12 to M14, M16). Acks: one queued per frame after a
heartbeat (M15). Per-IP: no admission against grace slots (M17), no settling (M18). `active`
(the handshake review's `PerSocketData::presence_withheld`, HOL-SEC-164): withheld rooms not
noted (M19), every room sent (M20), each killed by `test_bounds_active` alone.

One mutant survived the first run: no compaction after an ack. Entries only leave a ring on
an ack, so the bound set when frames are buried already holds; the step was removed and the
model test now checks that bound.
