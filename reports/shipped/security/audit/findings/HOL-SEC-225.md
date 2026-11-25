# HOL-SEC-225: a floor mark named the op held at its base's key

```
ID:          HOL-SEC-225                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: during an owner recovery a member's
                                          floor mark names the wrong checkpoint or falls
                                          back to its stale base, so the floor it holds
                                          may be older or missing; Exploitability L: needs
                                          the dropped owner device's key and the master key
                                          to sign a variant at a checkpoint's clock)
Category:    Authority of replicated state
Component:   rust/hollow_core/src/crdt/fold.rs (ServerState::floor_pick),
             rust/hollow_core/src/crdt/hold.rs (end_floor_round, mark_after_restart)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 8.8 item 1; R-CR-14
Found:       2026-11-22 (phrase-restore, the HOL-SEC-224 sweep of content_of callers)
Affected:    0.14.0 to 0.14.2 (the device proof track)
Fix commit:  0a6e396a9
Disclosure:  published with 0.14.3
```

## Description

Same class as HOL-SEC-224. `content_of(op)` returns the content id of the op HELD at
`op`'s author and clock, which is `op`'s own id only when `op` is the held copy. Three
floor-round paths applied it to ops that need not be held:

- `floor_pick` matched the picked base against the peers' answered `floor_base`s with
  `content_of`. Where this replica held a variant at an answered checkpoint's key (an op
  the dropped owner device signed at the same clock), the answer read as the variant, the
  match missed, and the pick fell back to the stale pre-trigger base.
- `end_floor_round` hashed B, which may be such an answer, with `content_of`, so the
  mark could name the variant.
- `mark_after_restart` hashed the recorded `base_op` with `content_of`. After a restart
  the base may no longer be held (a checkpoint held only in RAM is gone), and a variant
  that arrives at its key since then is what the mark named; a mark naming a
  non-checkpoint is dropped, so no floor held.

## Fix

The three paths use the op's own `content_hash()`. For a held op both values are equal,
so nothing else changes (the `late` check in `floor_pick` only meets held ops and is
switched for clarity, an equivalent change).

Tests (units in `crdt::hold::tests`):
- `a_floor_pick_matches_an_answered_checkpoint_by_its_own_content`: a stale member holds
  the owner phone's rename at cp1's clock (content id above cp1's), the round's answer
  carries cp1; the mark names cp1 and `floor_b` is cp1. Without the fix the mark named
  the stale base.
- `a_floor_mark_after_restart_names_the_recorded_base_by_its_own_content`: an unsigned
  member records cp1 at the trigger, holds it in RAM only, restarts from its stored rows,
  then receives a variant at cp1's key; the mark made after the restart names cp1. Without
  the fix no mark stood.

## Related call sites (sweep)

The remaining `content_of` callers (`current_print`, `open_round`, `base_by_hash`,
`hold.rs` test helpers) read ops from `op_log` or `stored`, whose key map holds exactly
their own ids.
