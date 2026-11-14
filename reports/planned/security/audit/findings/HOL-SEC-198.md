# HOL-SEC-198: Removing the relay left the take-over backup with the old relay's secrets

```
ID:          HOL-SEC-198                 Status: Fixed on local branch security/0.14
                                          (3d62ce35, 2026-11-07), retest at release
Severity:    Low                         (Impact M: copies of the TLS private key, TURN secret, push
                                          token, DuckDNS token, members-only keys and forwarder identity
                                          stay on a box the person believes is clean; Exploitability L:
                                          root-only, so only whoever later gets root or the disk)
Category:    Secret retention / Misleading assurance
Component:   relay-uws/deploy/lib/manage.sh (manage_uninstall), relay-uws/deploy/lib/adopt.sh
             (new adopt_backups, adopt_backup_erase), relay-uws/deploy/lib/ui.sh (answer key
             remove_backup)
Boundary:    TB-10 (the relay process and its host)
Traces to:   R-RS-08 (secrets root only, nothing kept that the person did not choose)
Attacker:    a later holder of root or of the disk (a sold or reused VPS, a backup image)
Found:       2026-11-07 (hostile review of the relay setup wizard, finding L2)
Affected:    the setup wizard's take over and uninstall since they shipped (relay 0.13.0 build 1
             for self-hosters, 8350841b)
Fix commit:  3d62ce35 (security/0.14, 2026-11-07)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

A take over keeps a root-only backup of every file it replaced in
`/root/hollow-relay-adopt-<stamp>`, including the old relay's secrets. The removal screen
said it removes every service "with their accounts, settings and secrets", but neither
the native nor the Docker uninstall touched that folder or named it, so the secrets
stayed on the box indefinitely.

## Fix

When a take-over backup exists, the removal screen lists it under what is kept and then
asks "Delete the take-over backup?" (recommended yes), naming the folder and the kinds of
secret it holds. Yes zeroes every file in it and deletes the folder before the relay is
removed. No keeps it and the last screen says it still holds the old relay's secrets,
with the command that deletes it. Answer files take `remove_backup=yes|no`.

## Test

Unit (`relay-uws/test/installer/adopt_tests.sh`):
`t_uninstall_names_or_removes_the_take_over_backup` (no backup asks nothing; kept, it is
named with how to delete it; yes deletes it before the relay goes; a declined removal
keeps it; the Docker removal asks the same). Box (`adopt_box_test.sh takeover`, after the
take over): `uninstall_names_or_removes_the_take_over_backup`, a real uninstall names the
folder and deletes it.
