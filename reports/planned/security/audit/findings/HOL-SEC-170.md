# HOL-SEC-170: Receivers that never ack could make the relay drop other people's waiting messages

```
ID:          HOL-SEC-170                 Status: Fixed (2026-10-07, wave 2 of resumable sessions),
                                          relay not yet deployed
Severity:    Medium                      (Impact M: a busy sender's offline DMs and channel
                                          catch-up frames went first, peer sync still the floor;
                                          Exploitability M: a member of a busy room with a few
                                          dozen free identities on one or two addresses, or
                                          nobody at all once a big server has many phones in grace)
Category:    Denial of service / eviction
Component:   relay-uws/src/offline_index.h (OfflineIndex), session_bounds.h (charge, ring_push),
             session_snapshot.h, snapshot.cpp
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; RESUMABLE_SESSIONS_PLAN.md section 4 ("a stranger filling rings");
             HOL-SEC-070 (same class: a table charged to the wrong party)
Attacker:    P-05 co-member of a busy room, with throwaway identities; P-03 where a room is open
Found:       2026-10-07 (wave 2 bounds review)
```

## Description

Session rings shared the one 512 MB buffer budget with waiting DMs and channel catch-up
frames, and every ring frame was charged to its sender's address share, its bytes once and
1 KiB of holding per ring. How long a ring holds a frame is decided by the receiving device
(it acks, or it never does). So sessions that never ack, or a big server's phones in grace,
piled holding charges onto whoever posted in their rooms: one address's 34 sessions holding
one poster's frames made that poster's share the heaviest in the budget, and the next eviction
dropped the poster's own oldest entries, its DMs waiting for an offline friend and its frames
in a channel's catch-up ring. A real device in grace holding the same frames could also be
buried before the hoarders were.

## Fix

Rings have a pool of their own (256 MiB, `OfflineIndex::rings`), apart from the buffers'
budget, so ring traffic and waiting DMs or catch-up frames never push each other out. In the
pool a frame's bytes are charged to its sender's share (once per fan-out buffer, while any ring
holds it) and its holding to the receiving session's share. Past the pool, the share holding
the most gives way: holding goes as the oldest frame of the heaviest sender in that session's
ring (`Ring::evict_one`), so a flood into a ring buries the flood; bytes go as that buffer from
every ring holding it. A snapshot restore charges rings the same way and holds the pool to its
budget.

## Test

`test_session_hostile` "receivers that never ack" (three checks, RED on 4dfa2b10: the
poster's DMs, its catch-up frames and the real device's frames all went), "the rings' pool
under pressure" (three checks), and `test_session_bounds` "ring frames and the rings' pool".
