# HOL-SEC-222: a removed device could found a held server a second time

```
ID:          HOL-SEC-222                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore)
Severity:    Low                         (Impact M: a device the roster removed rewrites a
                                          server's founding op on every replica that folds
                                          it from genesis, its name and founding clock
                                          included, past its removal; Exploitability L:
                                          needs the master key a lost or stolen device holds)
Category:    Authorization (a removed device's write)
Component:   rust/hollow_core/src/crdt/verdict.rs (clause_exempt),
             rust/hollow_core/src/crdt/fold.rs (fold_remote)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 7, 8.3; R-CR-07
Found:       2026-11-22 (phrase-restore, while fixing HOL-SEC-221)
Affected:    0.14.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

Past the cut only an op from a device the author's roster counts folds, but the founding op
is exempt from that device clause: it anchors its server whichever device wrote it, and
that device may have been retired or lost since. The exemption covered every
`ServerCreated` op, not only the one a replica already held. A device the roster removed
still holds the master key, so it could sign another founding op of the same id: the same
owner and nonce (so the same self-certifying id), any name, any clock. Replicas stored it
like any other op and served it in sync. A replica that folds the server from genesis takes
the founding op with the lowest clock, so one clocked before the real founding op replaced
it there: the server took its name, and the real founding op stopped folding. Checkpointed
replicas kept their state from the base, but still held and passed on the second op.

## Fix

The replica founds the server on one founding op per self-certifying id, and the choice
depends only on which ops it holds and on its view of the owner's roster, never on the
order they arrived in (`ServerState::founding_kept`, crdt/fold.rs). Of the ops founding the
id (copies at one key collapse as the dedup collapses them), a counted device's ranks
first, then one from a device the view lists (counted or removed), then the earliest
clock, then the content id. One clocked after a counted op of the owner's own is refuted:
no honest op predates its founding op, and only the owner's counted ops judge this, so a
member's backdated op cannot refute the real one. The fold founds on the first; it keeps
at most one other per listed device (four in all, never a refuted one) as stored rows, so
a change of view chooses again at the next rebuild without anything sent. The same
choice runs at the door (`fold_remote` -> `founded_once`: what would not be kept is
refused unstored, and a batch that changes what is kept refolds), in every rebuild's plan,
and in the settling (`founding_stand`, which folds no other founding op).

The first version of this fix kept whichever founding op a replica held first. Review
showed that depended on arrival order: a replica that took a later-clocked founding op
first (a new sibling syncing from a stolen device, say) kept it after the real one
arrived, seated the owner at its clock, refused the owner's older ops, and kept it past
the device's removal. The canonical choice above replaces it.

Residual (decided 2026-11-22): the real founding op and a second one the founding device
itself signs differ in nothing a replica can weigh while that device is uncounted and no
counted retire endorses the real op: same master, same device, same id. Then the one with
the earlier clock founds, so the device, or another listed device holding the master key,
can change the founding name, and only where nothing renamed the server since. It can
never refuse an owner op, since an earlier founding op only seats the owner earlier.
Planned follow-up (0.15 list): for new servers the founding nonce also commits to the
founding clock and a hash of the name, so the id certifies the whole founding op.

Tests: `a_second_founding_op_from_a_removed_device_founds_nothing` (the founder's replica,
one folding from genesis, a fresh one handed both; a worse one is refused at the door
unstored), `two_replicas_with_the_same_founding_ops_found_the_same_server` (the review's
case: a counted device's later-clocked op arrives first on one replica),
`a_view_change_chooses_the_founding_op_again_without_sync`,
`the_founding_ops_kept_are_one_per_listed_device_and_capped`,
`an_unlisted_devices_founding_op_never_founds`,
`a_later_founding_op_is_refuted_by_an_earlier_counted_op_of_the_owner`,
`only_a_counted_op_of_the_owner_refutes_a_founding_op` (a member's counted op and a removed
device's owner op refute nothing), `same_key_founding_copies_found_the_same_one_in_any_order`,
`a_legacy_founding_op_still_founds_a_fresh_replica` (legacy ids untouched), harness
`pr222_a_lost_founders_second_founding_op_changes_only_the_founding_name` (the residual on
two replicas, through a "not sure" settling and a restart). The first version's tests
failed before it; the review's test failed at the first version ("forged first: founded on
the later-clocked op") and passes now.
