# HOL-SEC-180: Two frames sealed in the same millisecond tied, so the second was taken as a replay

```
ID:          HOL-SEC-180                 Status: Fixed (2026-10-23, wave g13, local commit be5f8124),
                                          ships with 0.13
Severity:    Low                         (Impact L: a genuine frame, such as a second link card, refused as
                                          a replay of the first; Exploitability M: happens on its own when a
                                          device seals two frames within one millisecond)
Category:    Integrity (ordering)
Component:   rust/hollow_core/src/node/frame_auth.rs (seal_stamp_ms), node/olm_lane.rs (carried stamps),
             storage (local card attach)
Boundary:    TB-1, TB-2
Traces to:   HOL-SEC-053, HOL-SEC-068 (seal time orders cards)
Attacker:    none needed
Found:       2026-10-23 (wave g13, while proving the message-store track)
```

## Description

Receivers order some changes by their frame's seal time (link cards since HOL-SEC-068).
Seal stamps came from the wall clock in milliseconds, so two frames a device sealed in the
same millisecond carried equal stamps, and a receiver took the second link card as a
replay of the first. Present in released versions, rare until 0.13 made the send path
faster.

## Fix

A device's seal stamps and carried stamps rise strictly per process, at most 500 ms ahead
of its clock, and a local card attach lands after the row's newest stamp.

## Residual risk

The seal clock can step back across a restart (documented); the receiver's stamp ceiling
still bounds it.

## Test

`frames_sealed_within_one_millisecond_carry_increasing_stamps`,
`a_seal_stamp_runs_at_most_the_lead_ahead_and_never_back` (node/frame_auth.rs),
`carried_stamps_strictly_increase_within_a_millisecond` (node/olm_lane.rs), harness
`g13w3_our_newest_card_lands_on_our_row_over_a_card_stamped_ahead`; the authz card test
that regressed passes 25 of 25. Mutation pass 7/7.
