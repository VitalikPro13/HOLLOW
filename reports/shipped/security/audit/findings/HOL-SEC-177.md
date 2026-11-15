# HOL-SEC-177: One identity's roster could lift another identity's removal of a device

```
ID:          HOL-SEC-177                 Status: Fixed (2026-10-23, wave g13, local commit 10dac6d6),
                                          ships with 0.13
Severity:    Low                         (Impact M: a device one identity removed counts again when it
                                          consents into another identity, or a genuine device is refused,
                                          depending on which roster saved last; gates that check only the
                                          revoked flag lose a layer; Exploitability L: needs a removed
                                          device's holder to join it to a second identity)
Category:    Access control (revocation keyed too coarsely)
Component:   rust/hollow_core/src/node/resolver.rs (point_resolver, back_ids, clear_revoked_devices),
             storage/messages.rs (revoked_marks, revoked_devices)
Boundary:    TB-3 (own identity and its devices), TB-2
Traces to:   C-01, C-03, C-04; design ID-1 (HOL-SEC-077)
Attacker:    P-08 holder of a removed device
Found:       2026-10-22 (wave g13, track c-roster, outside its scope; confirmed by its reviewer)
```

## Description

The resolver kept one revoked flag per device id. When a roster was folded, the resolver
lifted the revocation of every device that roster counted, whichever identity had removed
it. A device removed from identity O that then consented into identity X therefore lost its
refusal the moment X's roster saved, and the flag flipped back and forth with whichever of
the two rosters saved last. Present since design ID-1 (0.12.0).

## Fix

Revocations are kept per (master, device) in a new `revoked_marks` table. Each master lifts
only its own removals, while the global check still refuses a key that any held roster
removed. The old `revoked_devices` table is still written alongside until 0.14, so a
downgrade, a restore on 0.12.x or a link to a 0.12.x device keeps every enforced revocation,
and a failed copy never loses one.

## Residual risk

None known; the dual write ends in 0.14.

## Test

Unit `g13c_a_lifting_by_one_master_leaves_anothers_removal` (node/resolver.rs); harness
`g13w3_a_removed_device_joining_another_identity_stays_refused_for_its_old_one`; migration
units `g13w3_revoked_devices_survive_the_move_to_per_master_marks`,
`g13w3_a_failed_copy_keeps_the_old_revocations` (storage/messages.rs). Mutation passes 9/10
(one equivalent) and 8/8 in the fix round.
