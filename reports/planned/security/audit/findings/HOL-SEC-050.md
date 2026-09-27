# HOL-SEC-050: Strangers, ex-members and device keys could author server ops

```
ID:          HOL-SEC-050                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: any key holder's self nickname, Twitch name, pledge,
                                          leave and cosmetic label ops were persisted and re-flooded by every
                                          member, and a device revoked where the revocation had not landed
                                          kept its master's full authority; Exploitability M: any key holder
                                          sharing a room, or a stolen device)
Category:    Missing authorization
Component:   rust/hollow_core/src/crdt/server_state.rs :: op_allowed, author_role
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15; candidates E6, E9 (evidence crdt:S7, crdt:S10)
Attacker:    P-03 stranger, P-06 kicked or banned member, P-08 revoked device
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

`op_allowed` read the author's role with a lookup that defaulted to Member for
anyone unknown, and required membership only for `MemberAdded`. The same lookup
resolved a device id to its master through the process-global resolver, so a
device key authored with its master's authority wherever the resolver still
mapped it.

## Reproduction

`authz_ops_need_a_member_author_acting_by_its_own_id` (crdt/server_state.rs
tests).

## Fix

An op's author acts by its own id, never through the resolver (every client
since op signing signs with the master key), and only while it is a current
member. The founding op and a checkpoint have rules of their own.

## Variants

- A stolen device still holds the master key itself (AR-02, design ID-1).

## Test

The test fails with the old lookup put back and passes with the fix. Full suite
green.
