# HOL-SEC-171: Session bounds walked whole tables on hot paths, so full rings or a full table could stall the relay

```
ID:          HOL-SEC-171                 Status: Fixed (2026-10-07, wave 2 of resumable sessions),
                                          relay not yet deployed
Severity:    Medium                      (Impact M: the relay's one thread stalls for everyone
                                          while it lasts, nothing is lost; Exploitability H for
                                          full rings: one address, free identities, its own room;
                                          L for the table: some thousands of address blocks)
Category:    Denial of service / CPU
Component:   relay-uws/src/session.h (Ring::evict_one, Book), session_bounds.h (make_room,
             grace_slot_victim), state.h (RelayState::session_book)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; RESUMABLE_SESSIONS_PLAN.md section 4 ("a session flood from one address")
Attacker:    any authenticated socket; for the table, an attacker holding many address blocks
Found:       2026-10-07 (wave 2 bounds review, measured with relay-uws/bench/session_cost.cpp)
```

## Description

Three bound checks were linear in what they bound and ran once per frame or per login:

- A ring at its frame cap chose its eviction by hashing every entry, about 265 us per ring on
  the VM, so one frame fanned out to 100 rings at their cap took 26 ms of the relay's thread.
  Sessions that never ack fill their rings with frames their owner sends into its own room.
- At a full session table (262,144) every mint walked the table to find the heaviest share:
  45 to 95 ms per login.
- At an address holding its 34 slots, every new socket walked the table for a grace slot:
  44 to 91 ms per socket.

## Fix

The ring keeps, per sender share, its weight and its frames oldest first, so the heaviest
share's oldest frame is found in logarithmic time; a tombstone merges with a neighbour only
where that moves few entries and runs are compacted in amortized time, and a replay sends each
run of tombstones as one gap either way. A `Book` beside the session table keeps sessions by
share (grace before live, oldest grace first) and grace slots by address, updated at every
mint, grace, resume and end (`make_room`, `hold_ip_slot`, `release_ip_slot`,
`ring_take_all`, the snapshot restore) and rebuilt from the table only if the two disagree.
Measured after: 1.7 us per mint at a full table, 0.03 us per socket at a full address, about
2 us per full ring per frame, 1.5 us when burying from the middle.

## Test

`test_session_hostile` "the ring against a model" (180,000 operations against a reference
model, tombstones bounded) and "the book that spares the caps a walk of the table" (30,000
random mints, graces, resumes and ends, every choice equal to a walk of the table, and the book
in step without a rebuild); `relay-uws/bench/session_cost.cpp` for the numbers.

## Residual

Address-based fairness cannot tell apart many addresses held by one attacker (phase G).
