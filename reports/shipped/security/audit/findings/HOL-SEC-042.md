# HOL-SEC-042: Any member could evict members from an encryption group or add anyone to it

```
ID:          HOL-SEC-042                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: any member holding a leaf could remove other members'
                                          leaves, the owner's included, and add leaves for outsiders to a
                                          server group or a restricted channel's subgroup, and every receiver
                                          merged it; Exploitability M: plain membership and a modified client)
Category:    Missing authorization (group operations)
Component:   rust/hollow_core/src/crypto/mls_manager.rs :: process_commit_judged, commit_membership
             rust/hollow_core/src/node/mls_authority.rs :: commit_verdict, plan_membership
             rust/hollow_core/src/node/crypto_handler.rs :: handle_mls_commit_frame
             rust/hollow_core/src/node/swarm.rs :: MLS batch timer
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-09, C-19; candidates D2, D6; lead L-03
Attacker:    P-05 member with a modified client
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

A received commit was processed and merged in one step. Nothing looked at who
committed it, who it added or who it removed, so any member could rewrite the
group's membership for everyone.

## Reproduction

`authz_a_member_cannot_evict_a_member_or_add_an_outsider` (node/test_harness.rs)
and the `commit_verdict` matrix in node/mls_authority.rs.

## Fix

Every commit, live or catch-up, is staged, judged and only then merged.

- Refused: a sender that is not a member leaf, any proposal other than Add and
  Remove, an added or replacement leaf that is unbound, a committer whose leaf
  turns into another identity, a commit from an unbound leaf other than
  rebinding itself, an added device known to be revoked, and in a meeting a
  committer other than the host that admitted us.
- Held while our view may lag, then retried each batch tick for up to 60
  seconds: a committer or added identity we do not know as a member (or as able
  to see a subgroup's channel), and the removal of a current member's leaf.
  Removal is allowed for the committer's own identity, an unbound leaf, a
  non-member, a revoked device, or a device the same commit adds back.
- The committer plans its own commits with the same rules, one commit per
  group per tick, so a leaf repair is one commit instead of two.

## Variants

- Who may admit a member at all (`MemberAdded`, E7) is class E; the group
  follows the membership its CRDT state gives it.
- A member can still remove its own leaves, and a relay can still withhold
  commits.

## Test

The harness test fails with the merge-everything rule put back and passes with
the fix. Full suite green.
