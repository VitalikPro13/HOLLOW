# HOL-SEC-165: A client could grow the relay's ack timer queue by one entry per heartbeat

```
ID:          HOL-SEC-165                 Status: Fixed in the wave 2 worktree (2026-10-07),
                                          retest at the sessions relay deploy
Severity:    Low                         (Impact L: memory held for 2 s per entry, about 100 bytes
                                          each, bounded only by how fast the relay reads one
                                          socket; tens of MB at most; Exploitability H: any
                                          session)
Category:    Relay / Resource exhaustion
Component:   relay-uws/src/ws_handler.cpp (count_in, sweep_sessions), relay-uws/src/state.h
             (RelayState::acks_due)
Boundary:    TB-1
Traces to:   AS-11; RESUMABLE_SESSIONS_PLAN.md section 9.4 (acks); the relay rule that every
             table a stranger can fill is bounded
Attacker:    any client with a session
Found:       2026-10-07 (wave 2 review of the resume handshake)
```

## Description

The relay acks a session's frames after 16 of them or 2 s after the first one it has not
acked, through a queue of ack deadlines. Each time the unacked count went from 0 to 1 it
queued another deadline, and an `hb` (or a 16-frame ack) sets the count back to 0 without
taking the queued deadline out. A client alternating one counted frame and one `hb` queued
one entry per pair, each kept for 2 s: one socket grew the queue by 9.5 MB in 1.8 s on the
VM.

## Fix

A frame queues a deadline only when the session has none still to come. A window that an
`hb` or a 16-frame ack closed early keeps the deadline already queued, so the next ack can
come earlier than 2 s after its first frame, never later. A session has at most two entries
at once (one past due awaiting the 250 ms sweep, one to come), so the queue is bounded by
the session table.

## Test

Relay live `test_relay_live` section "handshake review: a reset ack window never queues a
second timer" (`hs_one_ack_timer`): "the ack comes by the first frame's deadline" failed on
the old code (the ack came about 3.5 s after the first frame). Measurement probe (not in the
suite): 9.5 MB for 91,712 (frame, `hb`) pairs before, 4.8 MB for 219,072 pairs after, the
rest being the socket's own send buffer of `hb_ack` answers. Mutation pass: 1 of 1 killed.

## Also found

Found independently by the wave 2 bounds review (`rs_bounds_review.md` 8.5): 200,000 (frame,
`hb`) pairs in 0.65 s grew the relay by 21.7 MB before, 0.6 MB after (`RELAY_LIVE_PROBE=acks`).
The rule now lives in `Session::count_in(now)`, which `count_in` calls, unit-tested by
`test_session_hostile` "acks owed to a client that beats between frames".
