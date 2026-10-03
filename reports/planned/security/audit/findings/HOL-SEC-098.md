# HOL-SEC-098: A channel id could name the join ring or break every ring of a server

```
ID:          HOL-SEC-098                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: every catch-up ring of the server lost, the join ring included;
                                          Exploitability M: a member with MANAGE_CHANNELS, or the member answering a join snapshot)
Category:    CRDT / Input validation
Component:   rust/hollow_core/src/crdt/mod.rs (valid_channel_id), server_state.rs
             (op_allowed ChannelAdded, rebase_on), fold.rs (accept_join_snapshot)
Boundary:    TB-3 (server members)
Traces to:   C-16; phase B re-check crdt B-05
Attacker:    P-05 a member with channel rights
Found:       2026-10-02 (phase B re-check)
```

## Description

`ChannelAdded` took any string as a channel id. An id of `~join` collided with the server's join ring topic, and an id outside the relay's channel shape (a space, `#`, `:`, a non-ASCII letter, or a long one) made the relay refuse the whole signed ring control, so no catch-up ring was created or extended for that server. A join snapshot or owner checkpoint could carry such a channel too.

## Fix

A channel id is 1 to 64 bytes of `[A-Za-z0-9_-]`, every shape the apps ever minted. `op_allowed` requires it for `ChannelAdded`, which covers our own authoring and every remote ingest; snapshots and checkpoints keep only channels whose id has the shape and matches the entry's own id.

## Residual risk

A state stored before the fix keeps a bad channel until a fold rebuild or an owner checkpoint.

## Test

Unit `authz_channel_added_needs_a_channel_id_shape` (failed before: `"~join" is refused`); mutation killed (op_allowed, snapshot, rebase, inner id, length bound).
