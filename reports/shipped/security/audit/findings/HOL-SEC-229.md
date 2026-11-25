# HOL-SEC-229: a recovery asked the person to approve the device it had just cut off

```
ID:          HOL-SEC-229                 Status: Fixed in 0.14.3
Severity:    Medium                      (Impact M: one tap re-admits a device the
                                          person just said someone else may hold, and
                                          the prompt tells them it is a restored backup
                                          of theirs; Exploitability M: needs that
                                          device, which asks again by itself after
                                          every recovery, and the person's tap)
Category:    Identity authority (user-confirmed approval)
Component:   rust/hollow_core/src/node/roster_book.rs (fold_in_store,
             own_changes, announce_own_state, recover), node/swarm.rs
             (RevokeDevice), lib/src/ui/shell/roster_lock.dart
             (showPendingDeviceDialog), lib/src/ui/shell/hollow_shell.dart,
             lib/src/ui/settings/devices_section.dart
Boundary:    TB-1 (the person's own devices)
Traces to:   design ID-1 sections 4 and 8; R-ID-19
Found:       2026-11-23 (phrase-restore clean macOS fleet, Yes flow, and the
             Android No flow)
Affected:    0.12.0 to 0.14.2 (the in-app "Remove devices with your recovery
             phrase"); the Welcome restore (unreleased, 0.14.3)
Fix commit:  447cfab46, f75f41bb2, 611b3979f
Disclosure:  published with 0.14.3
```

## Description

A phrase recovery starts a new base that keeps the devices the person picked and
cuts off every other one, treated as lost or stolen since a moment the person names.
A device the recovery cut off learns it (R-ID-18) and, since anyone holding the master
key may ask to join, at once signs a pending join in the new base
(`roster_book::ingest` sets `asks_again` for any device of ours that is not a member,
not removed and not already waiting, a former member included).

The recovered device then raised the same pop-up a restored backup gets: "A device
wants to join. Device X was restored from a backup of your identity and asks to join.
If it's yours, approve it." It came back on every start, and the device list named the
device "Restored from a backup" with an Approve button beside it. That copy is false
(it was not restored from anything) and it invites approving the very device the
person had just answered "someone else could have it" about. Approve vouches for it
and it is a member again.

Shipped: the in-app recovery (`api::roster::recover_with_phrase`, Settings, Security)
has run this path since 0.12.0. Harness
`pr_c_an_inapp_recovery_is_not_prompted_to_approve_the_device_it_cut_off` reproduces
it on the 0.14.2 logic (`own_changes` emits `PendingDeviceAsking` for every new
pending device; `roster_lock.dart` shows the approval pop-up for it). The Welcome
restore (#155, unreleased) shows the same, fleet evidence
`.team/fleet/combined/hol_sec_229_z_join_prompt_for_cut_off_l.png`.

## Fix

The device that signs a recovery records, per base, which devices it cut off
(`recovery_cut_off:{base}`: the members the base before counted that the recovery does
not keep, with those an earlier recovery cut off and this one does not take back). A
device of the identity records the same when the new base reaches it, inside the
roster fold's own transaction: a record it cannot read or write fails the fold, so a
kill between taking the base and writing the record cannot happen (a later fold sees
no base move and would never write it).

Every move that cuts a member, and every recovery that drops devices as lost, also
marks the base: any device asking to join that the record does not name may be one
of the old ones. The master key signs a join ask for any key, so the person's devices
cannot tell a key the thief made, an old device their roster missed (an empty
install, a stale roster, a sibling-vouched device not yet folded) and a real backup
apart. A move that cuts nothing (choosing whether backups wait, confirming the phrase
an old version stored) adds no mark and keeps the earlier one, since the key it
guards against never rotates; the mark names the newest recovery that cut a device.

- No device asking in a marked base, or named by its record, is presented as a
  restored backup. Where waiting cannot let it in (backups need approval, which a
  Welcome recovery on an empty install always signs), no pop-up appears for it, at
  once or at any start. Where it could join by seven quiet days, a warning names it
  as cut off (or as maybe one of the old devices) and offers only Refuse ("Later"
  leaves it); the approval pop-up never shows for it, and one already open closes.
- An unreadable record reads as "maybe" (no pop-up, the warning copy on its row). An
  unreadable roster status in the app shows nothing and leaves the ask queued for the
  next read: only a status saying the device was not cut off opens the Approve
  variant.
- The device list names it for what it is ("Your recovery phrase cut it off on
  {date}. Approve it only if you have it with you.", or "...cut off your old devices
  on {date}. It may be one of them, or a copy someone else has.").
- Re-admission stays possible, but only by a deliberate act: Approve on its row in
  Settings, Devices, on a device that belongs, or the recovery phrase typed on the
  cut-off device itself (its lock says both, and names Settings, under Devices). A
  person who answered "I'm not sure" may find the old device in a drawer, so the way
  back is not closed; it is never a pop-up.
- Refusing such a device (a Retire removal of a device our roster does not count as
  a member) mints no retire and starts no retire round, at once or late. Before, the
  first mint was refused only because `retire_allowed` needs the device stated
  (`states_device`) and the retire was authored before the removal; the round's late
  mint runs after the removal states it.

The fold, the relay and contacts are unchanged: what the person sees changes, never
who counts.

Tests:
- harness `pr_c_a_recovered_device_is_not_prompted_to_approve_the_device_it_cut_off`
  (Welcome recovery on an empty install, at once and after a restart),
  `pr_c_an_inapp_recovery_is_not_prompted_to_approve_the_device_it_cut_off` (the
  shipped in-app path). Both red before the fix.
- unit `roster_book::tests::a_recovery_records_the_devices_it_cut_off`,
  `a_kept_device_records_what_a_recovery_elsewhere_cut_off`,
  `a_cut_off_device_still_warns_where_it_can_join_by_waiting`.
- review round (Nov 23): unit
  `rev229_a_fresh_key_after_a_lost_recovery_is_not_offered_as_a_backup` and
  `rev229_b_a_kept_device_that_missed_the_after_step_still_never_prompts` (both red
  before), `rev229_c_a_kept_device_that_cannot_record_the_cut_refuses_the_base`,
  `rev229_d_the_maybe_mark_names_the_newest_recovery_that_cut_a_device`,
  `rev229_e_a_device_past_the_cut_off_cap_still_reads_as_maybe`,
  `rev229_f_an_unreadable_record_offers_no_asker_as_a_backup`; harness
  `rev229_refusing_a_device_a_recovery_cut_off_never_endorses_what_it_wrote_after_t`;
  widget "an unreadable roster never offers Approve for a device that may be cut off"
  (red before).
- unit `api::roster::tests::roster_status_names_a_device_the_in_app_recovery_cut_off`
  (through the shipped `recover_with_phrase` FFI).
- widget `pending_device_dialog_test.dart`: "a device a recovery cut off (ours/maybe)
  is never offered as restored from a backup", "a cut-off device (ours/maybe) that can
  join by waiting is only warned of, never offered approval", "an open approval ask
  closes once the device turns out cut off".

Real app (macOS fleet, test relay, throwaway fixtures, Nov 23): after a Welcome Yes
recovery z shows no pop-up for the cut-off l and w, its Devices page names both as
possibly cut off, and Approve there lets l back in (it then deleted the throwaway
server): `.team/fleet/combined/r229_hol_sec_229_before_after.png`,
`r229_pr4_cleanup_flow.png` (scratch, not merged).

Residual: what holds after the fix. On a device that held the identity when a
recovery cut devices off (the typist, and every device that folds the new base),
no device asking in that base or a later one is offered for approval in a pop-up,
whatever key it uses. The record is local and never sent: a device that joins the
identity AFTER the recovery has it only through the link snapshot (the database
rides it); a device that never held the base before the recovery (prev members
empty) records nothing and treats askers as backups. A device the record does not
name reads as "maybe" even when it is a real backup restored later, which the person
approves from the Devices page. The record holds at most 512 devices; one left out
reads "maybe". None of this changes who counts: the seven-day path still admits a
cut-off device nobody refuses where the phrase left that path on, which is why the
warning stays there.
