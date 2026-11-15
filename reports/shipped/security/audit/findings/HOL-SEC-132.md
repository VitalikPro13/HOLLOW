# HOL-SEC-132: A member could repeatedly evict another member from a server's encryption group with that member's old KeyPackage

```
ID:          HOL-SEC-132                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: the victim loses live server traffic and every member loses an epoch per cycle, voice included; Exploitability H: plain membership and a modified client)
Category:    Access control / Replay
Component:   rust/hollow_core/src/node/mls_authority.rs (removable, repairs, plan_membership), crypto/mls_manager.rs
Boundary:    TB-2
Traces to:   phase E+F mls C-MLS-01; design D principle 2; variant of HOL-SEC-042
Attacker:    P-05 member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Receivers accepted removing a current member's leaf whenever the same commit re-added that
device, with any KeyPackage of it. Every member sees members' KeyPackages (Add proposals,
the join box), and the victim cannot open the Welcome for a spent package, so it was evicted
again and again. Variant: one held-commit slot per group let a member's held commit
overwrite a genuine one.

## Fix

Server KeyPackages carry a stamp (a tag of their group and their mint time) in the leaf's
application id; a re-add counts as a repair only with a KeyPackage minted for this group
after the leaf it replaces, judged identically by every receiver and by the committer's
planner. Held commits get one slot per committer (cap 8). A victim re-added with a package
it no longer holds asks again at once.

## Residual risk

A member can still force epochs with a commit that only updates its own leaf: AR-27.

## Test

`authz_a_member_cannot_evict_a_member_with_its_old_key_package` (failed: the owner moved off
its epoch), `a_spent_or_foreign_key_package_repairs_nothing`,
`a_held_commit_survives_another_committers_held_commit`,
`an_eviction_says_whether_its_welcome_can_be_opened`. Mutation 15/15 (with HOL-SEC-133,
-131).
