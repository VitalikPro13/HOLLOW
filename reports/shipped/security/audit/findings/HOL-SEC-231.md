# HOL-SEC-231: a recovery that drops a moderator's device undoes its moderation in the owner's fold

```
ID:          HOL-SEC-231                 Status: Fixed on feat/phrase-restore-f5
                                          (0.14.3, not released)
Severity:    Medium (Impact: a ban, kick, admission or grant a moderator's
                                          device wrote before the loss stops counting at
                                          the owner and every member that hears of the
                                          moderator's recovery: a banned member is a
                                          member again. Exploitability: no attacker
                                          needed; it follows the moderator's own phrase
                                          recovery on any server with no checkpoint)
Category:    CRDT authority (device proof, the recovery hold)
Component:   rust/hollow_core/src/crdt/hold.rs (recovery_trigger),
             crdt/fold.rs (fold_all), node/sync_handler.rs (settle_lost_devices)
Boundary:    TB-2 (co-members of a server)
Traces to:   DEVICE_PROOF_DESIGN 7, 8.8 ("nothing vanishes"); R-CR-07, R-CR-14
Found:       2026-11-23 (second hostile design review of F5; proven on this branch)
Affected:    0.14.0 to 0.14.2
Fix commit:  feat/phrase-restore-f5 (part A of the F5 design)
Disclosure:  private until 0.14.3 ships
```

## Description

On a phrase-rooted server every op counts only while its author's roster counts the
device that proved it. When a moderator's phrase recovery drops the device that banned
someone, the owner's view stops counting that device, and with no checkpoint carrying
the ban the owner's fold drops it: the ban lifts and the earlier admission stands again.
Section 8.8's hold never formed for it, because the trigger only looked at the base the
owner's devices write. A moderator that recovers on a fresh install never writes the
retire that would endorse its earlier acts (the lost-device settling skips servers it
does not own and first held after the moment it names), so the loss stays.

## Fix

Part A of the F5 design (`reports/planned/security/PHRASE_RESTORE_F5_OWNER_REENTRY.md`,
2.3): when a rebuild drops folded ops whose device the view no longer counts (Uncounted,
never Missing) for an identity other than ours, the replica records those devices and
exactly those ops and keeps counting them until something decides them: that identity's
counted retire of the device, the view counting it again, every recorded op folding on
its own (a retire endorsing it), or the owner's newer base deciding it (part C's early
checkpoints carry the owner's held fold into a base). Nothing the device writes after the
trigger counts.

## Tests

- harness `rev_f5b_a_recovery_dropping_a_moderators_device_keeps_its_ban` (RED on this
  branch before part A per the review; GREEN after)
- unit `crdt::hold::tests::a_moderators_dropped_device_keeps_its_ban_in_the_owners_fold`
