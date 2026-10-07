# HOL-SEC-164: One small frame made the relay walk every room a session holds

```
ID:          HOL-SEC-164                 Status: Fixed in the wave 2 worktree (2026-10-07),
                                          retest at the sessions relay deploy
Severity:    High                        (Impact H: the relay's one event loop stalls for every
                                          user while it lasts, and a burst of these frames read
                                          in one go holds it long enough for idle timeouts to
                                          drop every socket; Exploitability H: one free identity,
                                          no membership, rooms named by the attacker)
Category:    Relay / Availability
Component:   relay-uws/src/ws_handler.cpp (handle_session_control `active`, send_presence),
             relay-uws/src/state.h (PerSocketData)
Boundary:    TB-1
Traces to:   AS-11 (relay availability); RESUMABLE_SESSIONS_PLAN.md section 9.7
             (`inactive` / `active`); wave 1 of resumable sessions
Attacker:    P-03 stranger with a throwaway identity
Found:       2026-10-07 (wave 2 review of the resume handshake)
```

## Description

`{"type":"active"}`, new with resumable sessions, answered with one fresh `members` for
every room the session held, whether or not any presence had been withheld, and a client
may send it as often as it likes. A session may hold 10,000 rooms of names it picks, so
each 20-byte frame cost the relay about 54 ms of its single event loop (release build, VM
measurement), some ten thousand times a join. Every other per-frame path either touches
one room or bounds its scan (`check_peers`).

## Fix

The relay notes, per socket, each room whose presence it withholds from an inactive
session (`send_presence` names the room), and `active` answers with one `members` for those
rooms alone, then forgets them. A leave takes its room out, so the set never outgrows the
socket's rooms. An `active` with nothing withheld costs nothing; the work it can cause is
the presence the relay would have sent anyway. A resume still sends one `members` per room
(presence is re-read there), which costs a new connection and so stays under the
per-address connection rate.

This narrows section 9.7 ("`active` sends one fresh `members` per room") to the rooms whose
presence was withheld, which is also what the pinned client semantics ask for (no duplicate
`members` burst when nothing changed).

## Variants

The other session controls (`hb`, `ack`, `inactive`) are constant work, and `end` ends the
session. A resume and a socket's close are O(rooms), once per connection (see the residual
in `rs_handshake_review.md`). Joins touch one room, topic catch-ups are bounded by the ring
caps, `check_peers` by its scan budget.

## Test

Relay live `test_relay_live` section "handshake review: active answers only for presence it
withheld" (`hs_active_costs_what_was_withheld`): "active with nothing withheld sends no
members", "nor does a toggle with nothing in between" and "active sends members for the one
room whose presence it withheld" failed on the old handler (40 `members` for 40 rooms).
Measurement probe (not in the suite): 54.10 ms of relay CPU per `active` at 10,000 rooms
before, 0.00 ms after. Mutation pass: 4 of 5 killed, the survivor (a leave no longer
dropping its room from the set) changes no frame on the wire and only bounds memory.

## Also found

Found independently by the wave 2 bounds review (`rs_bounds_review.md` 8.3): 20 toggles
from a session in 5,000 rooms made the unchanged relay write 100,000 `members` frames while
another socket's round trip waited 211 ms (`RELAY_LIVE_PROBE=active`). Its live checks stay
in the suite beside these: `test_bounds_active`.
