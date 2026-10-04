# HOL-SEC-133: A member that missed one removal commit kept encrypting server content to the removed member

```
ID:          HOL-SEC-133                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H: a removed member reads what is sent after its removal, restricted channels included; Exploitability L/M: needs the removed member to still receive the room's frames (a hostile relay, a legacy room, the 60 s door grace) and a member that missed the commit, which a relay forces by dropping one frame)
Category:    Access control / Withheld revocation
Component:   rust/hollow_core/src/node/crypto_handler.rs (send_mls_broadcast_in, send_mls_broadcast_topic, sweep_unseated_leaves)
Boundary:    TB-1, TB-2
Traces to:   phase E+F mls C-MLS-02; RFC 9750 section 8.4.2; class 4
Attacker:    P-01 relay colluding with P-06 removed member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The removal is one unbuffered room broadcast. A member that missed it learned the kick from
the carried CRDT op, but no MLS send path compared the group's leaves with the CRDT, so it
kept encrypting to the removed leaf; three kept past epochs hid the stale sender from
everyone. A leaver's own leaf was also never removed.

## Fix

Every MLS send refuses to encrypt while the group holds a bound leaf our view no longer
seats and falls back to the Olm path to current members; the committer queues those leaves
for removal each tick and every other member sends an epoch probe so the withheld commit is
fetched.

## Test

`authz_a_member_that_missed_a_removal_commit_never_encrypts_to_the_removed_leaf` (failed:
the removed member read the post), `a_member_that_leaves_loses_its_leaf_at_once`.
