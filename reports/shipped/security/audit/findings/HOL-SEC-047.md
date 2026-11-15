# HOL-SEC-047: The relay could replay old server ops and pick each member's outcome by reordering

```
ID:          HOL-SEC-047                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: a replayed op re-admitted a kicked member, reopened a
                                          closed or restricted channel, restored a removed emote or reset
                                          the server's name; delaying frames chose which of two concurrent
                                          writes won on each member, and which ops a member admitted at all.
                                          Exploitability M: the relay, which carries every op, or any peer
                                          that kept an old signed op)
Category:    Replay; nondeterministic authorization
Component:   rust/hollow_core/src/crdt/fold.rs :: ingest_remote, fold_in
             rust/hollow_core/src/crdt/server_state.rs :: apply_op, apply_payload, log_admitted
             rust/hollow_core/src/storage/messages.rs :: load_ops_for_server, persist_admitted_ops
             rust/hollow_core/src/node/sync_handler.rs :: author_due_checkpoints
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-15, C-25; candidates E3, E5, E15 (evidence crdt:S5, crdt:S6, crdt:S18)
Attacker:    P-01 relay, P-06 formerly trusted peer keeping old ops
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

Each op was judged against whatever state the receiver held when it arrived and
applied in arrival order, and the dedup window held only the newest 1000 ops.
A signed op older than the window applied again, and the set ops (members,
channels, emotes, stickers, pins, labels) are plain inserts and removals, so
removed state came back. Channel visibility, posting, public, slow mode,
media-only and label gates were plain assignments, so the last frame to arrive
won. A replayed founding op reset the server name.

## Reproduction

`authz_fold_state_does_not_depend_on_arrival_order`,
`authz_a_replayed_old_op_never_undoes_a_later_one` and
`a_checkpoint_keeps_what_its_owner_had_not_seen` (crdt/fold.rs tests).

## Fix

- A server's state is a pure function of the signed ops it holds: every retained
  op is folded in HLC order and judged against the state just before it. An op
  newer than the log's tail applies at the tail; anything older rebuilds the
  state from its anchor. Two replicas holding the same ops hold the same state.
- Ops are retained, not capped. An old op is always a duplicate, and one older
  than a checkpoint folds before it and is overwritten.
- The owner's client signs a `ServerCheckpoint` (its full state and the newest
  clock it reflects, `covers`) once for every existing server, the anchor its
  members rebuild on, and again whenever an anchored log passes 2000 ops, at most
  hourly. It sits in the fold at `covers`, so what members did after that point
  folds on top even when the owner never saw it. Rows a checkpoint overwrote are
  pruned; the founding op of a self-certifying id is kept as the owner's proof.
- Ops refused only for authority wait up to 10 minutes (256 per server) for the
  admission or grant they raced ahead of, and are re-judged at the next rebuild.

## Variants

- A server still on the legacy anchor (owner not yet on 0.12) keeps the capped,
  arrival-order behaviour until its checkpoint arrives.
- A demoted admin can still backdate ops to before its demotion (residual R2):
  without a total order from an authority no decentralized design prevents it,
  and such ops lose every register a later honest write touched.
- An op older than a checkpoint's `covers` that its owner had not seen is lost
  everywhere (R3).
- Every out-of-order op rebuilds the state, so a member flooding backdated ops costs
  CPU on every member (R4, with AR-01's flood measurement).

## Test

Each test fails with its old rule put back and passes with the fix. Full suite
green; every harness server now runs on the fold.
