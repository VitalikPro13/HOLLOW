# HOL-SEC-114: A member removed while offline never learned it

```
ID:          HOL-SEC-114                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: the removed member keeps a stale copy of the server
                                          and its group, no access granted; Exploitability: none needed)
Category:    Server / Integrity
Component:   rust/hollow_core/src/crdt/sync.rs (removal_notice), node/door_room.rs (speaks_for,
             tell_removal), swarm.rs (SyncRequest arm)
Boundary:    TB-3 (server members)
Traces to:   HOL-SEC-097 residual (section 2 follow-up 3a)
Attacker:    none (an honest kick or ban)
Found:       2026-10-03 (HOL-SEC-097 fix)
```

## Description

A member that was offline when it was kicked or banned never learned it: the sync responder served only current members, and since door-locked rooms a removed member offline through the lock move could only send a door ask, which members refused. It kept the server, its stale state and its MLS group for good.

## Fix

A former member's device that asks by sync or door ask gets the op that ended its membership and the earlier membership and rank ops its own fold needs to admit it, so its own fold drops it and the existing self-eviction runs. It never gets an op stamped after the removal, an identity the log never shows as a member gets nothing, a bare master id or a revoked or disowned device speaks for no one, and on the door path it never gets a door and is told at most once per ten minutes per answering member.

## Residual risk

A checkpoint that covers the removal prunes it, so that member is still not told; on a legacy (32-hex) server only while its admission is inside the log cap; with a full member cap the remover's own admission can fail in the removed member's fold. A former member asking for the door learns that up to three members are online, once per ten minutes per answerer.

## Test

Harness `authz_a_member_kicked_while_away_learns_it_when_it_asks_for_the_door` (failed before: "B kept a server it was kicked from while it was away"), `authz_a_member_banned_while_away_learns_it_from_its_sync` (failed before; a never-member asking by sync and door gets nothing); unit `authz_a_former_member_is_told_its_removal_and_the_rank_behind_it_only`, `authz_no_removal_notice_for_a_stranger_or_a_member`, `a_removal_after_a_checkpoint_is_still_told`, `authz_a_bare_master_or_revoked_device_speaks_for_no_one`, `a_former_member_asking_for_the_door_is_told_its_removal_once`; mutation 11/11 killed.
