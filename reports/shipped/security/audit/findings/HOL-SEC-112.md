# HOL-SEC-112: A friend request from before a removal came back

```
ID:          HOL-SEC-112                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a removed friend reappears as a pending request, or as a friend when our own request was out;
                                          Exploitability L: needs a held-back genuine request or a removed device's own key)
Category:    Contacts / Authorization
Component:   rust/hollow_core/src/node/swarm.rs (FriendRequest arm, FriendRemove arm),
             social.rs (note_removal, older_than_removal)
Boundary:    TB-2 (contacts)
Traces to:   phase B re-check dm A-DM-09, identity FriendRequest rows
Attacker:    a relay or mailbox holding a request back; a removed device
Found:       2026-10-02 (phase B re-check)
```

## Description

A friend request had no bound against a later end of the friendship: a request the relay or the inbox mailbox held back came back as a pending request, or as a friendship when our own request was out. A roster-less request from a device its identity had removed landed under its own device id.

## Fix

The arm refuses a revoked sender, caps the request's stamp at its seal, and drops a request made before the friendship last ended; the end is now recorded as a time (our clock for our removal, the remover's seal for theirs, never moving back). A newer re-request still lands.

## Residual risk

A friend whose clock runs more than five minutes behind loses a re-request sent right after a removal; a later one lands.

## Test

Harness `authz_a_friend_request_from_before_a_removal_never_returns` (legs failed before: "a request from before the removal was shown"); unit `a_removal_bounds_only_what_was_made_before_it`; mutation killed.
