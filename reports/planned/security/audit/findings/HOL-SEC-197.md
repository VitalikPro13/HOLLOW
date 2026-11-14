# HOL-SEC-197: A take over copied the old relay's state by name while the old services ran

```
ID:          HOL-SEC-197                 Status: Fixed on local branch security/0.14
                                          (3d62ce35, 2026-11-07), retest at release
Severity:    Low                         (Impact M: a root-only file lands as the new relay's report
                                          counts or the forwarder's identity, readable by that
                                          service; Exploitability L: needs code running as the old
                                          account, a report file or forwarder data kept outside the
                                          setup's own folders, and a swap in a short window; a hard
                                          link also needs protected_hardlinks off)
Category:    TOCTOU / Link following by a privileged process
Component:   relay-uws/deploy/lib/adopt.sh (adopt_native_stage; new adopt_stage_copy,
             adopt_backup_owner)
Boundary:    TB-10 (the relay process and its host)
Traces to:   R-RS-08; same class as HOL-SEC-196
Attacker:    code execution as the old relay's or the old forwarder's service account
Found:       2026-11-07 (hostile review of the relay setup wizard, finding L1)
Affected:    the setup wizard's take over since it shipped (relay 0.13.0 build 1 for
             self-hosters, 8350841b)
Fix commit:  3d62ce35 (security/0.14, 2026-11-07)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

When the old relay kept its report counts, or the old forwarder its identity, somewhere
other than the setup's own `/var/lib` folders, `adopt_native_stage` checked the old file
with `plain_read` and then copied it as root with `install`, which follows a link. The old
services stop only later in the take over, so their account could swap the file for a link
between the check and the copy. `plain_read` also did not check the link count, so a hard
link to another file passed on a box without protected_hardlinks.

## Fix

The stage no longer reads the old files at all. It installs the copy the backup already
took through `plain_copy` (HOL-SEC-196), from the root-only backup folder, with
`land_file`. It carries a file only when the backup saw it owned by root or by the old
service's own account (the relay unit's `User=` for the report counts, the forwarder
unit's for its identity), and only when the backup holds it.

## Test

Unit (`relay-uws/test/installer/adopt_tests.sh`):
`t_adopt_stage_copies_only_the_old_accounts_own_plain_file` (the old path swapped for a
link after the backup, another account's file, a file the backup does not hold, a backup
entry that is a link, and the stage reading the old path by name). Box
(`adopt_box_test.sh stagerace`): `adopt_stage_copies_only_the_old_accounts_own_plain_file`,
the old account swaps its report counts for a link to a root-only file the moment the
stage copies them.
