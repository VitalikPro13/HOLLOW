# HOL-SEC-026: Any peer we shared a room with could join, steer or stop our recovery pool

```
ID:          HOL-SEC-026                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a stranger enters the pool, steers the coordinator's plan
                                          and makes us stream the shards we hold to a peer it names, or ends the
                                          pool with one frame; Exploitability M: any room we share, such as a DM
                                          room or a server room)
Category:    Missing authorization (message origin); dead protocol message
Component:   rust/hollow_core/src/node/swarm.rs :: recovery-pool interception
             rust/hollow_core/src/node/types.rs :: HavenMessage (RecoveryManifestSync removed)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-12; candidate H16 (evidence files:R-1..R-7)
Attacker:    P-03 peer sharing any room with us
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

Recovery-pool frames were taken from any room, never compared with the pool's
own room. A peer in a DM room or a server room could send a hello or welcome and
join the pool's member set (and the coordinator election), send a transfer plan
that made us stream every shard we hold for the pool's server to a peer of its
choosing, or stop the pool. A manifest-sync frame, which no client sends,
overwrote the pool's per-file metadata.

## Reproduction

`authz_recovery_frames_count_only_from_the_pool_room` (node/test_harness.rs).

## Fix

- A recovery frame counts only when it arrives in the pool's own room.
- A transfer plan counts only from the elected coordinator (the lowest id
  among pool members), and we stream a shard only to a pool member.
- `RecoveryManifestSync` is gone.

## Variants

- The pool's token is its relay room name, so the relay (and anyone holding the
  recovery link) can still enter the pool: the HOL-SEC-002 class, part of that
  design.

## Test

The harness test fails with the room check removed (a hello from a DM room joins
the pool and a stop from it ends the pool) and passes with it; a stop from the
pool room still ends the pool. Full suite green.
