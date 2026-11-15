# HOL-SEC-196: A take over's backup could hold a link, and its rollback read through it as root

```
ID:          HOL-SEC-196                 Status: Fixed in 0.14
                                          (3d62ce35, 2026-11-07)
Severity:    Medium                      (Impact M: root-only files on the relay box, such as a TLS
                                          private key or /etc/shadow, land readable by the old relay's
                                          service account; Exploitability M: needs code running as
                                          that account, the internet-facing service a take over
                                          replaces, while the take over runs)
Category:    TOCTOU / Link following by a privileged process
Component:   relay-uws/deploy/lib/adopt.sh (adopt_backup, restore_file, adopt_restore_files;
             new fd_plain, plain_copy, land_file)
Boundary:    TB-10 (the relay process and its host)
Traces to:   R-RS-08 (each service its own account, secrets root only); the setup wizard's
             own rule that root never reads or writes through a link a service account made
             (native.sh account_idle + plain_file)
Attacker:    code execution as the old relay's service account (a compromised relay process)
Found:       2026-11-07 (hostile review of the relay setup wizard, finding M1)
Affected:    the setup wizard's take over since it shipped (relay 0.13.0 build 1 for
             self-hosters, 8350841b)
Fix commit:  3d62ce35 (0.14, 2026-11-07)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

Before it changes anything, a take over copies every file it may replace into a root-only
backup in `/root/hollow-relay-adopt-<stamp>`, so a failure can put the old relay back.
`adopt_backup` checked each path by name (not a link, a regular file, no link on its
path) and then copied it in a separate step with `cp -p --no-dereference`, which copies a
link as a link. Some of these files sit in folders the old relay's account writes (its
report counts, its forwarder data, settings an old guide let it own), and that account's
service still runs during the backup. A file swapped for a link between the check and the
copy left a link in the backup. A rollback, which follows any later failure, restored each
entry with `cat`, so it read the link's target as root and landed those bytes at the old
path, owned by the old account. The same restore set the owner and mode of its temporary
file by name in that account's folder, so a temporary file swapped for a link passed the
change on to the link's target.

## Fix

The backup copies through one open descriptor and checks the file it opened, not the
name: `plain_copy` opens the file once and `fd_plain` reads the open file through
`/proc/self/fd` (a regular file, one name, opened at the expected path, optionally owned
by a named account), then copies from that descriptor. A file that changed in between
stops the take over before anything changed. A file that already has a second name is
refused with the other checks. A rollback restores only the backup's own plain copy
(`land_file`): the backup entry and the new temporary file are both opened once and
checked the same way, the bytes go from one descriptor to the other, owner and mode are
set through the descriptor, and one rename puts it in place. A refused entry is named and
the rollback says which files did not come back.

## Residual risk

Between the name check and the open there is still a short window in which a swapped-in
link would make root open its target (a FIFO, or a device whose open has side effects)
before the descriptor check refuses it. No byte is read or written through it. Idling the
old accounts first would close it, but would stop the old relay without its restart
handoff, so its held messages would be lost.

## Test

Unit (`relay-uws/test/installer/adopt_tests.sh`):
`t_adopt_backup_refuses_an_entry_that_became_a_link` (a link and a hard link swapped in
the moment the copy opens the file; `fd_plain` alone), `t_adopt_rollback_never_lands_a_link_target`
(a backup entry that is a link or a second name, a temporary file swapped at its open and
after its checks). Box (`adopt_box_test.sh race`, real systemd and accounts):
`adopt_backup_refuses_an_entry_that_became_a_link`, the old account swaps its report counts
for a link to a root-only file right after the setup's last check by path.
