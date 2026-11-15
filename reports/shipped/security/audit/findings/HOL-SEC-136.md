# HOL-SEC-136: A meeting a participant left kept its secrets, SFrame key included, on disk

```
ID:          HOL-SEC-136                 Status: Fixed (2026-10-04, session 34)
Severity:    Low (Impact M: the media and chat keys of meetings the device attended; Exploitability L: needs the unlocked database plus recorded ciphertext)
Category:    Data exposure
Component:   rust/hollow_core/src/node/conference.rs (forget_meeting_group), crypto/mls_manager.rs (forget_unloaded_groups)
Boundary:    TB-4
Traces to:   phase E+F mls C-MLS-06; RFC 9750 sections 8.2.2, 8.3.4
Attacker:    P-09 holder of the device's unlocked data
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Participants never dropped a meeting's group on leave, end or kick, and every persist
rewrote the whole OpenMLS store, so a meeting's epoch and exporter secrets stayed in the
database for good.

## Fix

The group is dropped and persisted on leave, the host's end and a kick notice; at start
every stored group nothing loads is erased (servers whose state failed to read are kept).

## Test

`a_meeting_left_leaves_no_group_secret_on_disk`,
`a_restart_keeps_no_meeting_group_and_every_server_group`,
`a_restore_forgets_the_groups_nothing_loads`.
