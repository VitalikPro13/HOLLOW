# HOL-SEC-174: Two devices of one identity could mint the same server op id, and replicas diverged for good

```
ID:          HOL-SEC-174                 Status: Fixed (2026-10-22, wave g13, local commit 6b612cb0),
                                          ships with 0.13
Severity:    Medium                      (Impact M: one of two genuine writes by the same person's devices
                                          is silently dropped on some replicas, the person's own devices
                                          included, and the replicas never converge again; Exploitability M:
                                          happens on its own when two siblings write in one millisecond, and
                                          a member whose clock runs ahead makes it likely)
Category:    Integrity (identifier collision)
Component:   rust/hollow_core/src/crdt/hlc.rs (lanes, witness), crdt/server_state.rs (create_op),
             crdt/fold.rs (restart witness)
Boundary:    TB-3 (own identity and its devices), TB-2
Traces to:   C-15; design E (crdt/fold.rs)
Attacker:    none needed; P-05 member with a clock ahead makes it likelier
Found:       2026-10-22 (wave g13, hostile review of the sync track)
```

## Description

A CRDT op is identified by its author (the master) and its HLC stamp, and every device of
one identity used the master as the clock actor. Two siblings that minted in the same
millisecond, or that had both witnessed a peer whose clock runs ahead, produced the same
stamp, and dedup kept whichever copy arrived first. Replicas, the user's own devices
included, then held different states for good. A restart could also mint a stamp the
device had already used, since the clock was reseeded from the wall clock without
witnessing its own log. Present since signed CRDT ops (0.11) and live in 0.12.2.

## Fix

- Every stamp a device mints carries a counter in its own lane (derived from SHA-256 of the
  device id, modulo 2^24). The actor stays the master, so 0.12.2 replicas accept the new
  stamps unchanged.
- Witnessing records the newest point seen and only minting steps, so a large sync batch
  cannot push the clock forward.
- On load the clock witnesses the newest admitted op of its own log, and `create_op`
  re-mints any stamp already held.
- Remaining ties break deterministically (chat rows on equal `order_us` by message id,
  equal-stamp profiles, signed cards and sibling block lists).

## Residual risk

None known.

## Test

`siblings_in_one_millisecond_mint_distinct_stamps` (crdt/hlc.rs),
`two_siblings_same_ms_ops_both_survive`, `two_siblings_after_a_peer_ahead_both_survive`,
`a_restarted_clock_sits_above_its_own_log`, `a_stamp_we_already_hold_is_never_minted_again`
(crdt/fold.rs), harness `g13h_siblings_after_a_peer_ahead_converge_on_both_writes`.
Mutation pass 15/15, then 20/20 after the review fix round.
