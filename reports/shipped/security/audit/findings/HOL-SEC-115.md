# HOL-SEC-115: A friend removal reached only the device it happened on

```
ID:          HOL-SEC-115                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: a removed friend kept friend access on our other devices:
                                          full profile, DMs, rings; Exploitability L: nothing beyond our
                                          owning a second device)
Category:    Multi-device / Privacy
Component:   rust/hollow_core/src/node/social.rs (handle_remove_friend, friend_removals,
             take_sibling_removals), swarm.rs (FriendRemove, FriendListSync arms),
             crypto_handler.rs (send_friend_list_to_sibling), types.rs (FriendRemoval)
Boundary:    TB-4 (own devices)
Traces to:   HOL-SEC-113 residual (section 2 follow-up 3b)
Attacker:    none (the removed friend keeps what it had)
Found:       2026-10-03 (HOL-SEC-113 fix)
```

## Description

Removing a friend changed only the device it happened on: our other devices kept the person as an accepted friend, and a removal the friend sent reached only our devices online at that moment. The sibling friend list carried accepted friends only, so a device that missed a removal never caught up.

## Fix

Removals ride the sibling friend list in their own field (who, and when the friendship ended), sent to our online devices at once, on a friend's removal as well as ours, and carried in every sibling sync, so a device that was away catches up when it returns. A device takes them only from a roster-counted, unrevoked device of ours, holds the stamp to the frame, and ends only a friendship or request made before the removal, so a re-add since outlives a late copy.

## Residual risk

A sibling never tells the friend itself; delivery to the friend stays with the device that removed them. A legacy tombstone (no time) is never shared.

## Test

Harness `authz_a_removal_reaches_an_online_sibling_and_never_undoes_a_readd` (failed before: "an online sibling kept the friend we removed"), `a_removal_reaches_a_sibling_that_was_away`, `authz_only_our_own_device_tells_us_a_friendship_ended`; unit `a_siblings_removal_ends_only_what_was_made_before_it`; mutation 11/11 killed.
