# HOL-SEC-043: A Welcome from anyone replaced a working encryption group

```
ID:          HOL-SEC-043                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: a member could move another member into a group of its own
                                          making, whose voice keys and messages it controls, and anyone in the
                                          room could cut a meeting participant out with a Welcome that never
                                          parsed; KeyPackages were minted and stored for anyone who asked;
                                          Exploitability M)
Category:    Missing authorization; state change before validation
Component:   rust/hollow_core/src/crypto/mls_manager.rs :: join_from_welcome_judged
             rust/hollow_core/src/node/mls_authority.rs :: welcome_verdict, asked_for_leaf
             rust/hollow_core/src/node/swarm.rs :: MlsWelcome arm, MlsKeyPackageRequest arm
             rust/hollow_core/src/node/crypto_handler.rs :: may_repair_our_leaf
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-09, C-19; candidates D3, D5; lead L-03
Attacker:    P-05 member with a modified client, P-01 relay operator, P-03 room peer
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

The Welcome handler removed the group we held before it even parsed the
Welcome, then joined whatever group the Welcome described. Nothing checked the
sender, whether we had asked, or the group it named. A KeyPackage, which is all
such a Welcome needs, was minted, stored and sent to anyone who requested one.

## Reproduction

`authz_a_welcome_never_replaces_a_group_unasked` and
`authz_key_package_requests_need_a_member_who_may_repair` (node/test_harness.rs),
`a_refused_welcome_replaces_nothing` (crypto/mls_manager.rs).

## Fix

- A Welcome is staged first (OpenMLS `replace_old_group`), so nothing replaces
  our group until it passes.
- Refused: a group id other than the one addressed, any unbound leaf, our own
  leaf not being this device, a revoked device, and replacing a group we hold
  without having asked. Asking means a KeyPackage we pushed, an eviction whose
  repair we await, our own join, or a KeyPackage request we answered for that
  same sender.
- Held and retried: a sender, or a leaf's master, we do not know as a member or
  know as banned. A meeting Welcome needs our pending knock, and its sender
  becomes the meeting's only committer.
- KeyPackage requests are answered only for a server we belong to (never a
  meeting, never during our own join), only to a current member, for a subgroup
  only if we qualify, at most once per group every 10 seconds, and while we hold
  a leaf only to someone entitled to repair it: the owner, the member our own
  election names to answer our catch-up, or the subgroup's coordinator.

## Variants

- A member can still Welcome a member that holds no group into a group of real
  members it built; the member could read those messages anyway (decision D3,
  2026-09-27).
- The elected authority is trusted to coordinate and could do the same.
- Pinning a meeting's host from the invite, and the other meeting lobby frames,
  are class A.

## Test

The Welcome test fails with the old handler, and with an answered request
vouching for any sender; the request test fails with the gate removed. Full
suite green.
