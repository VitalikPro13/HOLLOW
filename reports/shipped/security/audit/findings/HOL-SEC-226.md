# HOL-SEC-226: the relay setup read OpenSSH 10.5's password logins as off

```
ID:          HOL-SEC-226                 Status: Fixed in the relay setup of 0.14.3 (2026-11-22)
Severity:    Low                         (Impact L: on Ubuntu 26.10 the setup and check-host
                                          reported SSH password logins as off while sshd took
                                          them, so the setup's advice to turn them off never
                                          showed and check-host passed; nothing was opened;
                                          Exploitability L: password guessing against an
                                          account the operator believed was key-only)
Category:    Fail-open security check
Component:   relay-uws/deploy/lib/host.sh (hollow_sshd_t), deploy/lib/ssh_keys.sh
             (ssh_password_state), deploy/lib/adopt.sh (audit_collect),
             deploy/check-host.sh (SSH)
Boundary:    TB-4 (relay host and its operator)
Traces to:   R-RS-08
Found:       2026-11-21 (builder of track fix-153d, box tests on Ubuntu 26.10)
Affected:    every relay setup on OpenSSH 10.5 or newer (Ubuntu 26.10), through 0.14.2
Fix commit:  6694bc357
```

## Description

OpenSSH 10.5 prints the keywords of `sshd -T` as `sshd_config` spells them
(`PasswordAuthentication yes`), where every earlier release printed them in lower case.
The setup and check-host matched the lower-case lines only, so no line matched, and an
answer that named nothing counted as "password logins off" and "no root password login".
The SSH port list read from the same output missed `Port` too.

check-host's root login line also passed when `sshd -T` printed nothing at all, for
example when sshd could not read its settings.

## Fix

Every reader goes through `hollow_sshd_t`, which lowers each keyword and fails when sshd
cannot answer; the password state is then `unknown`, never `off`. check-host lowers the
keywords the same way and fails closed: no output fails the SSH section, and root's login
passes only for a PermitRootLogin value sshd printed and the check knows to be safe (`no`,
`prohibit-password`, `without-password`, `forced-commands-only`).

Tests: `run_tests.sh` `t_ssh_ports` (`sshd_settings_read_in_any_case`, the OpenSSH 10.5
fixture `fixtures/sshd/openssh-10.5-ubuntu-26.10.txt`), `safety_tests.sh` (the take-over
audit's password and root lines on the same fixture), `host_check_tests.sh` `t_host_ssh`
(`an_sshd_that_cannot_say_fails_closed`, a missing or unknown PermitRootLogin fails), and
`systemd_box_test.sh` (`hollow_sshd_t -C` in a real box).
