# HOL-SEC-020: A member could sign server ops whose clock names someone else, or a counter that wraps ours

```
ID:          HOL-SEC-020                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: an op that wins equal-time LWW ties and sits in the dedup set
                                          under another identity's name, and a counter at its ceiling that wraps a
                                          release build's clock below what it witnessed; Exploitability M: a
                                          modified client and membership)
Category:    Trust in a sender-chosen value (the op's clock); integer overflow
Component:   rust/hollow_core/src/crdt/operations.rs :: CrdtOp::verify_author
             rust/hollow_core/src/crdt/hlc.rs :: Hlc::now, Hlc::witness
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; candidate E14 (evidence crdt:S16)
Attacker:    P-05 member with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

An op's clock carries an actor id. Every honest op is stamped by its author's
own clock, but ingest never compared the two, so a member could sign an op
whose clock named the owner: equal-time ties are broken by the actor, and the
dedup key pairs the author with the clock. Witnessing a remote clock added one
to its counter unchecked; a counter at `u32::MAX` panicked a debug build and,
in release, wrapped our clock to a counter below the op it had just seen.

## Reproduction

`admit_remote_rejects_a_clock_naming_another_author` (crdt/server_state.rs
tests) and `a_counter_at_its_ceiling_moves_the_clock_forward` (crdt/hlc.rs
tests).

## Fix

- `verify_author` refuses an op whose clock names anyone but its author
  (`OpReject::ActorMismatch`), on every ingest path.
- The clock steps with `successor`: at the counter's ceiling the millisecond
  moves forward instead, so the clock can neither panic nor fall behind a
  timestamp it has witnessed.

## Variants

- The drift bound still lets a peer move our clock up to five minutes ahead,
  by design (`MAX_DRIFT_MS`).

## Test

Both tests fail with the old code (the foreign clock is admitted; the counter
overflows) and pass with the fix. Full suite green.
