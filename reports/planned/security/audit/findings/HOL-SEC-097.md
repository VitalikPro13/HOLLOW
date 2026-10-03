# HOL-SEC-097: A kick notice made a member drop a server with no removal behind it

```
ID:          HOL-SEC-097                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a member loses the server on its own devices while every replica still lists it;
                                          Exploitability M: any member with kick rights who outranks it)
Category:    Server / Authorization
Component:   rust/hollow_core/src/node/swarm.rs (HavenMessage::MemberKickBroadcast,
             apply_remote_crdt_op, leave_evicted_server), sync_handler.rs (carry_kick_notice)
Boundary:    TB-3 (server members)
Traces to:   C-16; phase B re-check crdt A-09, server_mls A-06
Attacker:    P-05 a moderator
Found:       2026-10-02 (phase B re-check)
```

## Description

The kicked member acted on a bare notice: it checked only that the sender could kick and outranked it, then deleted the server, its MLS group and its rows. Nothing tied the notice to a signed removal, and the kicker skipped the target when it sent the removal op, so the target never had one. A moderator could silently eject a member that every other replica still listed. A ban of our own identity heard as an op, on the other hand, never tore anything down.

## Fix

The notice now carries the removal or ban op itself (a required field; an old bare notice no longer parses). The op enters through the one remote ingest, which judges its author, and the member leaves only when its own state no longer lists it and no join of its own is pending. A removal from before a rejoin folds before the rejoin, so the old seal-time check is gone. A ban of our identity now tears the server down like a removal, through one teardown helper.

## Residual risk

A member that is offline during the kick still never hears of it (follow-up).

## Test

Harness `authz_a_kick_notice_without_its_removal_op_is_ignored` (failed before: "a kick notice with no removal behind it took M out of the server"), `authz_a_kick_from_before_a_rejoin_is_ignored` (reworked for the new rule), `a_ban_of_us_heard_as_an_op_leaves_the_server`, control `a_kick_or_ban_carrying_its_op_still_lands`; mutation 3/3 killed.
