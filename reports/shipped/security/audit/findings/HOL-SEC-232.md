# HOL-SEC-232: a recovery stored while the node was down opened no hold at the next start

```
ID:          HOL-SEC-232                 Status: Fixed in 0.14.3
Severity:    Medium (Impact: a member that takes the owner's recovery roster while its
                                          app is stopped restarts straight into the
                                          step-back: members, seats and MLS leaves of
                                          the dropped device's admissions go, with no
                                          hold, no floor mark and no banner.
                                          Exploitability: no attacker needed; the push
                                          fetch keeps roster removals while the app is
                                          closed)
Category:    CRDT authority (the recovery hold)
Component:   rust/hollow_core/src/crdt/fold.rs (restore_classified),
             node/swarm.rs (server load)
Boundary:    TB-2 (co-members of a server)
Traces to:   DEVICE_PROOF_DESIGN 8.8 item 1; R-CR-07, R-CR-14
Found:       2026-11-23 (second hostile design review of F5; proven on this branch)
Affected:    0.14.0 to 0.14.2
Fix commit:  5c1667636
Disclosure:  published with 0.14.3
```

## Description

Section 8.8's trigger ran only inside a live rebuild. A roster stored while the node was
down (the push fetch's `ingest_stored` keeps removals, or a crash between the roster save
and the rebuild) meets the saved rows only in the start-up restore, which refolded under
the new view and installed the step-back directly.

## Fix

A restart that refolds now judges both triggers against what the saved rows folded: the
8.8 trigger against the base the saved state folded on (the folded checkpoint its
`checkpoint_hlc` names), and part A's against the rows saved as folded. A recovery it
opens is saved with the start-up delta; the floor mark follows on the next tick, as for
any recovery loaded without its round.

## Tests

- harness `rev_f5b_a_recovery_stored_while_the_node_is_down_still_opens_the_hold` (RED
  on this branch before the fix per the review; GREEN after)
- unit `crdt::hold::tests::a_recovery_stored_while_the_node_was_down_opens_the_hold_at_restart`
