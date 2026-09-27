# HOL-SEC-019: An Olm peer could grow a server's op log without bound through a fallback nobody sends

```
ID:          HOL-SEC-019                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: an op log that grows with every replayed copy, a database
                                          write and a UI event per copy, and a plaintext reply holding the op
                                          log; Exploitability M: an Olm session with the victim and one signed
                                          op of the server, which the plaintext twin puts on the wire)
Category:    Resource consumption; dead ingest path with weaker rules
Component:   rust/hollow_core/src/node/swarm.rs :: Olm CrdtOp, SyncReq and SyncResp arms (removed)
             rust/hollow_core/src/crdt/server_state.rs :: apply_op
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; candidate E13 (evidence crdt:S14)
Attacker:    P-04 friend or any peer holding an Olm session, P-05 member
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

Server ops travel over MLS and a plaintext twin; no client sends them over
Olm. The Olm dispatch still had three CRDT arms. The `CrdtOp` arm ran the
admission gate and `apply_op`, which already records a new op and ignores a
duplicate, then pushed the op into the log a second time, so every re-sent
copy of one validly signed op grew the log, wrote the database and raised an
event. The `SyncReq` arm answered any Olm peer with the op log of any server
we hold, in plaintext.

While fixing it: every caller judged "this op was new" by the op log's length,
which cannot grow at the 1,000-op compaction cap, and every restart restores
the log at exactly that cap. On a server past 1,000 ops a remote op was
applied in memory but never persisted, shown or passed on. Not a security
flaw, fixed with it.

## Reproduction

`authz_olm_carries_no_crdt_ingest` (node/crypto_handler.rs tests) and
`a_full_op_log_still_counts_new_ops` (crdt/sync.rs tests).

## Fix

- The three Olm arms join the "MLS-only envelope via Olm" arm and are
  ignored.
- `apply_op` returns whether the op was new and entered the log, and every
  caller (MLS arm, plaintext twin, sync merge) persists, emits and re-floods
  on that. An op older than the whole retained window reports "not new", so
  two nodes never re-flood it to each other.

## Variants

- A plaintext `SyncRequest` still returns the op log to anyone who knows the
  server id: candidate A10, to be moved into Olm/MLS with class A (decision 1).
- An op older than the retained window still re-applies: candidate E3, the
  class E design.

## Test

The newness test fails with the length check (the new op at the cap counts
as not new) and passes with the fix. The wiring guard fails while any of the
three Olm arms has its own ingest. Full suite green.
