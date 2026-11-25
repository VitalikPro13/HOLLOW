# HOL-SEC-212: the relay host check passed every sudo rule on a host set to another language

```
ID:          HOL-SEC-212                 Status: Fixed in the relay setup of 0.14.2 (2026-11-20)
Severity:    Low                         (Impact M: a service account that may become root
                                          is reported as "cannot become root"; Exploitability
                                          L: needs a host with a non-English locale and a
                                          sudoers rule granting a service account; the check
                                          only reports, it never grants)
Category:    Fail-open check
Component:   relay-uws/deploy/check-host.sh (service accounts)
Boundary:    the relay host's own hardening report
Found:       2026-11-20 (builder of track fix-153, while fixing #153)
Affected:    every relay setup since the service-account check
Fix commit:  5ebafeac6
```

## Description

The check asked `sudo -l -U <account>` and looked for the English words "may run". sudo
translates that line, so on a host whose locale is not English the words never matched and
every account passed, whatever its rules. Output the check could not read at all (for
example sudo refusing with `requiretty`) also passed.

## Fix

Both sudo calls run under `LC_ALL=C`, and any answer without one of the two known lines
("may run the following commands", "is not allowed to run sudo") fails as unreadable, with
stderr read too. Tests: host_check_tests.sh "sudo is asked in the C locale" and the
unreadable-output cases in sudo_matrix_tests.sh (requiretty).
