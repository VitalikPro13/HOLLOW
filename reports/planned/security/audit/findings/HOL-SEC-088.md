# HOL-SEC-088: A refused server op still moved our clock

```
ID:          HOL-SEC-088                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: our next server ops for that server were
                                          dated up to five minutes ahead; Exploitability M: any
                                          peer that can hand us a self-signed op for a server
                                          we hold)
Category:    CRDT / Integrity
Component:   rust/hollow_core/src/crdt/fold.rs (ingest_remote)
Boundary:    TB-4 (server members), TB-2 (any Olm peer)
Traces to:   C-15; HOL-SEC-020 (the clock bound)
Attacker:    anyone who is not a member, with any key
Found:       2026-10-02 (phase B re-check, crdt row 0.3)
```

## Description

The fold advanced our hybrid logical clock from every op that passed the stateless checks
(signature, server id, the five-minute future bound), before asking whether its author
may write anything. A stranger's correctly signed op, dated just inside the bound, was
refused and still pushed our clock forward, so our own next ops carried its time.

## Fix

Only the ops the fold admits move the clock.

## Test

Unit `authz_only_an_admitted_op_moves_our_clock` (failed before the fix); mutation pass
2/2.
