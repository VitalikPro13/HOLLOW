# HOL-SEC-065: Anyone in a server's room could stretch, stop or flood its catch-up rings

```
ID:          HOL-SEC-065                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: a server's retained ciphertext kept up to a week
                                          after its owner chose an hour, late joiners and parked joins
                                          cut off, every ring flushed by one frame, new servers denied
                                          rings; Exploitability H: anyone who knows a server id can be
                                          in its room)
Category:    Missing authorization
Component:   relay-uws/src/ring_auth.h, ring_evict.h, ws_handler.cpp :: handle_set_topic_buffer,
             create_topic_buffer, erase_topic_buffer, the ring tee and sweep; state.h;
             snapshot_codec.h (v5), snapshot.cpp; rust/hollow_core/src/node/ring_auth.rs,
             lock_keeper.rs :: sign_ring_control, sync_handler.rs :: register_relay_catchup,
             ws_client.rs, swarm.rs (LockChain arm)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-24, C-25; candidates I5, A25, I6 (control half); relay inventory C.1..C.4
Attacker:    P-06 anyone with a server id; P-05 a removed member
Found:       2026-09-26 (phase B: I5, I6), 2026-09-27 (design A inventory C.4: A25)
```

## Description

`set_topic_buffer` was authorised by room membership alone, and anyone can join a
server's room by its id. Anyone could turn a server's rings on, raise their retention
to seven days (retroactively, since the sweep read the ring's current retention), or
stop them. Eviction chose the sender holding the most frames, so one frame just under
the 1 MB ring cap pushed out every other sender's. One socket could fill the relay-wide
65,536 ring registrations, after which no new server got a ring.

## Reproduction

`authz_only_the_servers_authority_changes_its_rings` (node/test_harness.rs).

## Fix

A ring control (create, set retention, stop) counts only when signed by the change key
of the newest join lock the relay holds for the server (HOL-SEC-062): its owner, admins
and mods. The signature covers the room, the owner that keys a legacy id's lock, a time
within ten minutes, the retention, whether it stops, and every channel. The client signs
when it holds that key, and re-registers once the relay takes a new lock of its own, so
a new server's rings appear with its first lock. An unsigned request only keeps
existing rings from idling out. A legacy (32-hex) room's rings are bound to the first
owner whose lock signs for them. A frame keeps the shorter of the retention it arrived
under and the ring's current one. Eviction chooses the sender holding the most bytes,
and a frame over 256 KB is delivered but never ringed. A room may have 512 rings and a
device may create 2,048; past the relay-wide cap the ring idle longest makes room. The
owner binding and each frame's retention survive a restart (snapshot codec v5).

Pre-0.12 members register unsigned until 0.12 ships (`ACCEPT_UNSIGNED_RING_CONTROL`,
turned off on release day).

## Test

The harness test above (a stranger's unsigned stop, its own lock's signed ring and
signed stop all do nothing; the owner's signed registration makes the rings and its
signed stop ends them); the join, parked-join and catch-up tests all run on the signed
rule. Unit: `ring_control_payload_matches_the_relays_pinned_vector`,
`only_the_newest_locks_change_key_signs_ring_control` (node/ring_auth.rs); C++
test_ring_auth.cpp (22 checks, the same pinned vector), test_ring_evict.cpp (byte
fairness and the frame limit), test_snapshot_codec.cpp (v5 round trip, v4 and v3 still
read, mismatched metadata refused). Mutation pass: the client not signing, and the
harness relay taking unsigned control, each fail the harness test.

## Residual

A legacy server's rings can be bound first by someone holding a lock filed under that
id in their own name, taking relay catch-up from that server until the rings idle out.
Sybil devices can still churn the relay-wide cap (AR-01 territory).
