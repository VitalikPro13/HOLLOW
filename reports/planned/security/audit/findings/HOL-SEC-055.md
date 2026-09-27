# HOL-SEC-055: Any holder of a server id was served the whole op log

```
ID:          HOL-SEC-055                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: members, roles, bans, restricted channel names,
                                          grants and Twitch credentials of any server; Exploitability H:
                                          anyone with the id, an invite holder or a former member, with a
                                          modified client)
Category:    Missing authorization
Component:   rust/hollow_core/src/node/swarm.rs :: SyncRequest arm
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-18, C-24; candidate A10 (authorization half)
Attacker:    P-06 stranger or former member
Found:       2026-09-26, phase B; confirmed by reading 2026-09-27
```

## Description

The `SyncRequest` responder served the op-log delta to any requester for a
server it held, without asking who the requester was.

## Reproduction

`authz_only_a_member_is_served_the_op_log` (node/test_harness.rs).

## Fix

The op log goes only to a current member. A deleted server has no members left,
so anyone asking gets only the owner's deletion op, which is all a reconnecting
former member needs. Moving the log out of plaintext is decision A-D1.

## Test

The test fails with the old rule put back (both layers of the gate removed
together) and passes with the fix.
