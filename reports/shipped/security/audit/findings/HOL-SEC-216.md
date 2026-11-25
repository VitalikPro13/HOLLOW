# HOL-SEC-216: a device that first held a server after the moment of loss settled it from its own records

```
ID:          HOL-SEC-216                 Status: Fixed in 0.14.3
Severity:    Medium                      (Impact H: what a lost device did in a server
                                          before the person lost it stops counting:
                                          owner renames, channels, roles, admissions;
                                          Exploitability M: an honest removal or recovery
                                          from a device newer than T, which a Welcome
                                          phrase restore makes common)
Category:    Wrong evidence in an authority decision
Component:   rust/hollow_core/src/node/sync_handler.rs (settle_lost_devices,
             merge_rival_settlings), node/restore_flow.rs (held_before_recovery, register)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 8.3, 8.4; R-CR-12, R-ID-11
Found:       2026-11-21 (hostile review of the phrase restore design)
Affected:    0.14.0 through 0.14.2
Fix commit:  edfce376d
Disclosure:  published with 0.14.3
```

## Description

A lost-or-stolen removal, or a phrase recovery, settles each server from the remover's own
records: its newest checkpoint first folded before T, and the dropped device's ops it saw before
T. The settling never checked that the remover held the server before T. A device that first
held a server after T has no restore point from before T, so an owned server settled back to
its founding state and a member server got a retire keeping none of the dropped device's ops.
The recovery path chose servers by whether this device held them before the recovery's own
time, not before T, so a server first held between the two had the same fault.

## Fix

One predicate, `held_before(store, state, T)`: a first fold or a stored op strictly before T.
`settle_lost_devices` writes nothing for a server that fails it: an owned one goes to the
member witnesses (`lost_restore:{server}` rows that `restore_flow::register` hands to the
witness desk, kept across restarts), a member one gets no retire. The recovery path filters by
T, and a rival-settling merge skips such a server. "Longer ago, or not sure" (T = 0) names no
moment: each server's T is then the oldest restore point this device holds, which its records
reach by definition, so a lost removal still settles every server the remover holds and a
recovery every server held before the recovery itself; only an owned server first held after
the recovery goes to the witnesses (the chooser). Residual: an owned server the witnesses
restore keeps only what a checkpoint from before T holds; the lost device's later ops no
checkpoint covers stop counting at members until the person picks a point.

Tests: `pr216_a_device_that_held_nothing_before_t_keeps_what_the_lost_device_did_before_t`
(the restore survives a restart),
`pr216_a_recovery_typed_on_a_device_that_joined_after_t_settles_nothing_and_asks_the_witnesses`,
`pr216_a_member_server_first_held_after_t_gets_no_retire_from_the_remover`,
`pr216_a_not_sure_recovery_on_a_device_holding_the_server_settles_it`,
`pr216_a_not_sure_lost_removal_settles_from_the_founding_op`,
`held_before_judges_against_t_not_the_recovery`,
`a_not_sure_recovery_still_settles_what_this_device_held_long_before`,
`a_not_sure_recovery_hands_the_witnesses_only_what_it_first_held_after_it`,
`a_rival_merge_never_runs_on_a_server_held_only_after_t`.
