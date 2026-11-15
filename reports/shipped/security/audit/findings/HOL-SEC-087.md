# HOL-SEC-087: A blocked friend could still pull our DM history

```
ID:          HOL-SEC-087                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: the blocked friend gets our conversation
                                          with it again, which it once received; Exploitability
                                          H: its client asks on every reconnect)
Category:    DM / Authorization
Component:   rust/hollow_core/src/node/swarm.rs (HavenMessage::DmSyncRequest)
Boundary:    TB-2 (contacts)
Traces to:   C-13; HOL-SEC-036 (the block gaps closed then)
Attacker:    a friend we blocked
Found:       2026-10-02 (phase B re-check, dm A-DM-19 and A-DM-27)
```

## Description

Blocking drops a friend's DMs, requests, edits, reactions and typing before anything is
stored. The catch-up sync responder was missed: a blocked friend's `DmSyncRequest` was
still answered with our whole conversation with it, both directions when it asked so.

## Fix

The responder refuses a request from a blocked identity before it reads the store.

## Test

Harness `authz_a_blocked_friend_pulls_no_dm_history`: a friend that lost a DM gets it back
by its sync, and once blocked gets nothing (failed before the fix); mutation killed.
