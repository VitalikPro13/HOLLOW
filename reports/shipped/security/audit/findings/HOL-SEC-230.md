# HOL-SEC-230: a recovery on a server with no checkpoint drops every member its lost device admitted

```
ID:          HOL-SEC-230                 Status: Open, fix designed for 0.14.3
                                          (track phrase-restore-f5)
Severity:    Medium (shipped) / High (the 0.14.3 Welcome restore as built)
                                          (Impact: every member, channel, role and
                                          setting the dropped device wrote leaves the
                                          fold at each member that hears of the
                                          recovery, with their MLS leaves; on the
                                          shipped in-app path until the kept device's
                                          settling lands, on a fresh-install restore for
                                          good. Exploitability: no attacker needed; it
                                          follows the owner's own recovery, on most
                                          servers)
Category:    CRDT authority (device proof, the recovery hold)
Component:   rust/hollow_core/src/crdt/hold.rs (recovery_trigger),
             crdt/fold.rs (checkpoint_due, CHECKPOINT_AFTER_OPS),
             node/witness.rs (answer), crdt/settle.rs (settling_input)
Boundary:    TB-2 (co-members of a server)
Traces to:   DEVICE_PROOF_DESIGN 7, 8.4, 8.7 ("no member or MLS leaf is evicted
             meanwhile"), 8.8 ("nothing vanishes"); R-CR-07
Found:       2026-11-23 (hostile design review of F5; proven on v0.14.2-beta)
Affected:    0.14.0 to 0.14.2 (the in-app "Remove devices with your recovery
             phrase"); the Welcome restore (unreleased, 0.14.3)
Fix commit:  pending (feat/phrase-restore-f5)
Disclosure:  private until 0.14.3 ships
```

## Description

On a phrase-rooted server the device-proof cut is in force from the founding op, so an
op counts only while the author's roster counts the device that proved it. A phrase
recovery that drops the owner's founding device therefore uncounts every admission,
channel, role and setting that device wrote, unless a checkpoint carries them.
Checkpoints are written only past 2000 ops, so most servers have none.

Section 8.8's hold, which keeps members' seats, servers and MLS leaves while a recovery
is in progress, forms only when a member's held checkpoint base stops being eligible:
the trigger returns early when no base is held. With no checkpoint, members that hear of
the recovery fold the server back to its founding op: they stop listing each other as
members, the batch tick removes their MLS leaves, voice channels the device made close,
and sync stops asking them.

Shipped: the in-app recovery saves the roster and then settles each owned server after a
sync round of up to 10 s, or at the next start if the node was stopped. A member that
learns the new roster first steps back until the kept device's settling lands; the
settling then restores the fold and the walk re-seats the leaves. On the Welcome restore
(unreleased) the recovering install stored nothing before the moment the person names,
and witnesses name no checkpoint, so the only offer is "I don't know", whose settling
keeps only the owner: the loss is permanent.

## Fix

Three parts (design `reports/planned/security/PHRASE_RESTORE_F5_OWNER_REENTRY.md`,
section 2):

- The owner checkpoints a cut server soon after its first change past the founding op,
  then at most hourly while it changes, under the existing writer rule. Members then hold
  a base that the shipped hold and floor protect, 0.14.0 to 0.14.2 members included.
- With no base held, the trigger records the whole fold as the pre-trigger state, so the
  hold keeps every seat, server and leaf; the dropped device's parked ops stay while it
  lasts.
- A witness that names no checkpoint before the moment the person names sends the
  dropped devices' ops it first stored before it (a signed record); the recovering
  install judges records with the existing chooser (a record's line is its subsets) and
  settles on the chosen one.

## Tests

- harness `w3c1_a_recovery_on_a_server_without_a_checkpoint_keeps_its_members` (RED on
  v0.14.2-beta and on feat/phrase-restore-f5 at 447cfab4:
  `member(J)=false member(K)=false in_recovery=false hold(J)=Out hold(K)=Out members=1`,
  both MLS leaves gone; after the kept device's settling the fold and leaves come back)
- harness `w3c1_an_owner_checkpoints_a_cut_server_soon_after_its_first_admission`,
  `pr_a_a_fresh_install_restores_members_from_the_owners_early_checkpoint`,
  `pr_a_a_fresh_install_restores_a_server_that_never_checkpointed_from_members_records`
- units listed in the design, section 7, item 5
