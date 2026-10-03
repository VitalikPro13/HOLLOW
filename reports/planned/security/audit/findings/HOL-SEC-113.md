# HOL-SEC-113: A sibling that missed a removal brought the friend back

```
ID:          HOL-SEC-113                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a removed friend re-added as accepted on our own devices;
                                          Exploitability L: needs one of our devices offline during the removal)
Category:    Multi-device / Integrity
Component:   rust/hollow_core/src/node/swarm.rs (FriendListSync arm), social.rs
Boundary:    TB-4 (own devices)
Traces to:   phase B re-check identity S14
Attacker:    none (a stale sibling)
Found:       2026-10-02 (phase B re-check)
```

## Description

The removal tombstone was written and never read, so a sibling that missed our removal re-added the friend as accepted through its friend list.

## Fix

The friend list arm skips an entry whose frozen request stamp predates the friendship's recorded end; a genuine re-add carries a newer stamp.

## Residual risk

None; siblings are now told about every removal (HOL-SEC-115), and this refusal still guards a stale list.

## Test

Harness `authz_a_stale_siblings_friend_list_never_brings_back_a_removed_friend` (failed before); mutation killed.
