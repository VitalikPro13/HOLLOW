# HOL-SEC-070: Throwaway identities could push real entries out of the relay's tables

```
ID:          HOL-SEC-070                 Status: Fixed and DEPLOYED (relay, 2026-09-29), retest at release
Severity:    Medium                      (Impact M: offline messages, catch-up rings, parked joins,
                                          destroy orders for a stolen device and a revoked device's
                                          mailbox bar evicted; nothing becomes readable and peer sync
                                          stays the floor; Exploitability M: tens of free identities
                                          on one address)
Category:    Denial of service / eviction
Component:   relay-uws/src/fair_share.h (new), offline_index.h, kill_list.h, join_lock.h,
             ring_evict.h, ws_handler.cpp (buffer_offline_msg, evict_over_budget, drop_frame,
             create_topic_buffer, the ring tee, inbox_owner_proved, socket_share), state.h,
             snapshot_codec.h (v6), snapshot.cpp, crypto.cpp :: share_id
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; candidates I3, I9 (AR-07); the A-D4 residual "sybil churn of the ring cap"
Attacker:    P-06 any authenticated socket, with as many identities as it likes
Found:       2026-09-26 (I3, I9); 2026-09-29 (session 18, the ring cap and the 512 MB budget)
```

## Description

Every full relay table evicted by age or by identity: the 65,536 rings the idlest first,
the 512 MB of waiting messages the oldest first, the offline buffer's key backstop the
oldest deposit, the destroy-order list the oldest entry, the device-list version marks
first in first out, a target's per-kind slots and a ring's frames the SENDER holding the
most. Identities are free, so a flood from many of them made real entries the oldest,
idlest or lightest and pushed them out: real people's offline messages, a server's
catch-up ring, the destroy order for a stolen device (eight junk issuers filled its
target's slots), and a master's version mark, after which a revoked device could replay
an old device list into the mailbox.

## Reproduction

C++ `test_fair_share`, `test_kill_list` (`junk from throwaway issuers on one address
never pushes out a real order`, `a flood filling the whole list from one address evicts
only itself`), `test_relay_validators` (`OfflineIndex byte budget`), `test_ring_evict`
(`throwaway identities on one address evict only each other`), `test_join_lock`.

## Fix

A share is an address block (a v4 address or a v6 /48), hashed with BLAKE2b under a
key the relay replaces every hour and never persists, so what it keeps past a
connection names no address once its hour is over. Every entry is charged to the share
of the socket that wrote it (`FairShare`), and a full table evicts from the share
holding the most (bytes or entries), its least recently used entry first:

- waiting messages, DM and ring alike, one budget weighing each frame's bytes plus
  1 KB of overhead, exact (every removal path releases its frame); this replaces the
  per-identity key caps (4,096 targets per sender, 65,536 keys), so no real sender
  ever pays for someone else's flood;
- rings (the per-device cap of 2,048 is gone), join lock records, destroy orders
  (per target and list-wide), device-list marks (charged to one of the master's own
  devices once one proves), registrations (HOL-SEC-069);
- a target's per-kind slots and a ring's frames evict the share holding the most.

Nothing refuses and nothing is rate limited: under a flood the flooder only evicts
itself, and real use never reaches the caps. Shares survive a restart (snapshot codec
v6); entries from a pre-v6 snapshot each become a share of their own.

## Test

The C++ tests above; the live probe; the 0.11 and 0.12 logins and a real deploy
restoring every buffer.

## Residual

An attacker holding many address blocks (a botnet, many /48s) can still churn the
caches. It still reads, forges and blocks nothing, and peer sync still catches everyone
up. Phase G's circuit breaker.
