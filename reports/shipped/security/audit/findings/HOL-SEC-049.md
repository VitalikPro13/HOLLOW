# HOL-SEC-049: Any member could admit anyone past a ban, a private server or the Twitch gate

```
ID:          HOL-SEC-049                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a banned identity back in, or anyone into a private,
                                          full, owner-verified or Twitch-gated server, as a full member on
                                          every replica; Exploitability M: plain membership and a modified
                                          client)
Category:    Missing authorization
Component:   rust/hollow_core/src/crdt/server_state.rs :: op_allowed, admission_allowed
             rust/hollow_core/src/crdt/operations.rs :: CrdtPayload::MemberAdded (follow)
             rust/hollow_core/src/node/twitch.rs :: follow_credential_admits_at
             rust/hollow_core/src/node/swarm.rs :: ServerJoinRequest (admitter)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15, C-19; candidate E7 (evidence crdt:S8, server_mls:S-02); D8's CRDT half
Attacker:    P-05 member with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

`MemberAdded` was admitted at ingest when its author was a member. The ban
list, the private flag, the member cap, owner-verify and the Twitch follow gate
ran only on the honest admitter's join path, so a modified client skipped them
and every member applied the result.

## Reproduction

`authz_a_member_cannot_admit_past_the_join_gates` (node/test_harness.rs) and
`authz_member_added_rechecks_the_join_gates` (crdt/server_state.rs tests).

## Fix

Any member may still admit (decision 4, so joins work with the owner offline),
but every member re-checks the gates on the op at its own point in the fold: the
target is not banned, the server is not private, the cap is not reached,
owner-verify admits only through the owner, and a Twitch-gated server needs the
joiner's follow credential, which the admitter now copies into the op and every
member verifies offline at the op's own time. The admitter authors the op
through the same rule.

## Variants

- A member can still admit a real joiner of an open server without asking the
  others; that is what an open server is.

## Test

Each test fails with the member-only rule put back and passes with the fix.
Full suite green.
