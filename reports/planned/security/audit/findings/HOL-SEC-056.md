# HOL-SEC-056: A sibling's server announce reopened a server we already held

```
ID:          HOL-SEC-056                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: our copy of a pre-0.12 server replaced by another
                                          member's snapshot, owner included, and later genuine owner
                                          checkpoints refused; Exploitability M: a hostile member
                                          answering while the routine sibling announce is pending)
Category:    Trust on first use where trust already existed
Component:   rust/hollow_core/src/node/swarm.rs :: SiblingServerAnnounce arm, on_verified_sibling,
             SiblingStateSyncRequest; node/sync_handler.rs :: handle_create_server;
             node/types.rs :: SiblingServerAnnounce
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15, C-19; server_mls inventory (SiblingServerAnnounce, ServerStateSnapshot)
Attacker:    P-05 member with a modified client (P-01 before HOL-SEC-053)
Found:       2026-09-27, design A inventories
```

## Description

A sibling's announce ran the join flow even for a server we held, creating a
pending join with no owner pin. While it was pending, a snapshot from any member
was accepted on trust and pinned its own owner.

## Reproduction

Read in `node/swarm.rs` (the SiblingServerAnnounce arm); the pin itself is
covered by design E's `authz_a_joiner_takes_its_state_only_from_the_servers_anchor`.

## Fix

A server we hold gets only the list refresh the join flow existed for; presence
sync converges its ops. A new server's pending join is pinned to the owner the
announcing device holds as its anchor (new `owner` field).

## Test

Design E's pin test covers the pinned join, and
`authz_a_sibling_announce_for_a_held_server_starts_no_join` (node/test_harness.rs,
session 12) drives a two-device announce for a server already held.
