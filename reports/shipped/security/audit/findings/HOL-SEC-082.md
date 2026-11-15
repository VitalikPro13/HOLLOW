# HOL-SEC-082: A recovery did not restart a restored backup's seven days

```
ID:          HOL-SEC-082                 Status: Fixed on local main (2026-10-02), relay deployed,
                                          retest at release
Severity:    High                        (Impact H: a backup the phrase cut off joins again at
                                          once, at every contact and the relay; Exploitability M:
                                          needs a backup that already joined by waiting, then its
                                          node only has to restart)
Category:    Identity / Authorization
Component:   rust/hollow_core/src/node/roster_book.rs (fold, stamp_pending),
             storage/messages.rs (roster_pending_seen), relay-uws/src/roster_book.h
Boundary:    TB-3 (own identity and its devices), TB-1 (relay)
Traces to:   C-03, C-04; HOL-SEC-077 (design ID-1), HOL-SEC-078 (design ID-1R)
Attacker:    someone holding a backup and its passphrase
Found:       2026-10-02 (session 26, driving the backup-wait toggle on screen)
```

## Description

Design ID-1 counts a pending join once it was first seen at least seven days ago in the
current base. The apps and the relay kept that first sight per device instead, across
bases. A restored backup that joined by seven quiet days and was then left out by a
recovery (Settings > Security, "Remove devices with your recovery phrase") asks to join the
new base at its next start, and its old first sight made the new ask count at once. The
recovery that was meant to take the identity back from it was undone.

## Fix

The first sight of a pending join is kept per base, in the apps (`roster_pending_seen`,
keyed by master, base and device; stamps of older bases are dropped) and at the relay
(`RosterBook::seen_key`). A recovery starts every waiting device's seven days over.

## Test

Unit `authz_a_backup_left_out_by_a_recovery_waits_again_in_the_new_base` (failed before
the fix); relay vector `a-recovery-restarts-the-clock` replayed by `test_roster`, which the
old relay code fails; harness `a_waiting_backup_asks_again_when_the_wait_is_turned_off`;
mutation pass on each part.
