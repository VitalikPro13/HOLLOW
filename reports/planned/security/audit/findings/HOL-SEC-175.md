# HOL-SEC-175: The CRDT sync state vector could lose a server op for good

```
ID:          HOL-SEC-175                 Status: Fixed (2026-10-22, wave g13, local commit cd87c801),
                                          ships with 0.13
Severity:    Medium                      (Impact M: an op such as a ban, a role change or a channel edit
                                          never reaches a replica that missed it, so that replica judges
                                          later ops against a different state; Exploitability M: happens on
                                          its own with sibling devices and expired held ops)
Category:    Integrity (lost update in sync)
Component:   rust/hollow_core/src/crdt/digest.rs (new), crdt/sync.rs, node/op_sync.rs, node/swarm.rs
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15; design E
Attacker:    none needed
Found:       2026-10-22 (wave g13, track s1a, from the G1 scale probe; confirmed by a failing test)
```

## Description

A sync request carried a state vector, which named for each op author the newest op the
asker held. The responder sent only ops newer than that entry. An author's op that was older
than the newest op of that author the asker already held was therefore never sent again.
Sibling devices of one identity hit this (their ops interleave under one author), and so did
an op the asker had held back for authority and then expired while a later op of the same
author landed. The op was lost on that replica for good. The vector also grew with the
number of authors, about 535 bytes per author per request.

## Fix

`crdt/digest.rs` replaces the vector with salted range fingerprints over fold time (a count
and a keyed sum of op ids per range). Mismatched ranges split within a budget of 256
sub-ranges, so any missing op is found wherever it sits. Malformed asks go unanswered and
malformed replies close the ask; non-members get only the removal notice. 0.12.2 peers are
still served by the vector. At 50 members a sync ask drops from 14.5 KB to 1.7 KB.

## Residual risk

A 0.12.2 peer keeps the old vector until 0.14 removes it.

## Test

`sibling_op_older_than_the_vector_tip_still_syncs` and
`held_op_expired_after_a_later_op_still_syncs` (crdt/digest/tests.rs; both failed on the
vector), `digest_random_sets_converge`, `digest_finds_an_old_hole_in_a_long_log`; harness
`g13_reconnect_converges_with_an_out_of_order_op`, `g13_old_requester_is_served_by_vector`.
Mutation pass 20/20.
