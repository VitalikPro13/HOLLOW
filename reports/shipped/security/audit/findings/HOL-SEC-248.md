# HOL-SEC-248: a removed device could end a friendship

```
ID:          HOL-SEC-248                 Status: Fixed in 0.14.2
                                          (track sec-244, 2026-11-21)
Severity:    Low                         (Impact L: a friendship of the identity ends on the
                                          friend's devices until one side adds the other
                                          again; Exploitability L: needs a device the
                                          identity's roster removed, which keeps its key)
Category:    Authorization (a removed device's write)
Component:   rust/hollow_core/src/node/swarm.rs (FriendRemove and FriendReject arms),
             node/social.rs (removal_sender_refused)
Boundary:    TB-1 (the person's own devices, and contacts)
Traces to:   C-12; R-CH-14
Attacker:    the holder of a device its owner removed from the roster
Found:       2026-11-21 (session B, review of the HOL-SEC-244 track)
Affected:    every release with device removal, through 0.14.1
Fix commit:  12cea33b6 (0.14.2)
Disclosure:  with the 0.14.2 release
```

## Description

A friend request and our own devices' friend lists were already refused from a device any
roster removed. The live `FriendRemove` arm had no such check, and neither had
`FriendReject`, which ends an accepted friendship when two requests cross. A device its
owner had removed, still resolving to that owner, could so end the owner's friendships on
the friend's side.

## Fix

Every live arm that can end a friendship asks `social::removal_sender_refused` first: a
device any roster removed, or a master id no roster counts as a device, is refused before
anything is written. A friendship ends only by a removal or a reject from a device the
friend's roster still counts.

## Test

Harness `sec248_a_removed_device_cannot_end_a_friendship_live`,
`sec248_a_removed_device_cannot_end_a_friendship_by_a_reject` (each with a control in which
a counted device ends it); unit
`social::tests::a_removal_from_a_removed_device_or_a_bare_master_is_refused` (each clause
alone).
