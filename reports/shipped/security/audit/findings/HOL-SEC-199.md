# HOL-SEC-199: The setup's certbot ran as root from packages nobody pinned

```
ID:          HOL-SEC-199                 Status: Fixed in 0.14
                                          (3d62ce35, 2026-11-07)
Severity:    Low                         (Impact H: code that runs as root twice a day on the relay
                                          box; Exploitability L: needs a malicious release of one of
                                          certbot's dependencies on PyPI, or a hostile index or
                                          mirror, at the moment a box installs; only IP address
                                          certificates on a box without snap use this path)
Category:    Supply chain / Unpinned dependencies / Missing sandbox
Component:   relay-uws/deploy/lib/native.sh (certbot_install; new certbot_venv_make,
             certbot_venv_current, certbot_renew_units), relay-uws/deploy/certbot-requirements.txt
             (new), relay-uws/deploy/hollow-certbot-renew.service, relay-uws/deploy/check-host.sh
Boundary:    TB-5 (Hollow and its distribution), TB-10 (the relay process and its host)
Traces to:   R-RS-08 (every service sandboxed, check-host checks it)
Attacker:    P-10 hostile infrastructure (a package index or a compromised dependency release)
Found:       2026-11-07 (hostile review of the relay setup wizard, finding L3)
Affected:    the setup wizard since it shipped (relay 0.13.0 build 1 for self-hosters, 8350841b),
             IP address mode on Debian or any box without snap
Fix commit:  3d62ce35 (0.14, 2026-11-07)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

For IP address certificates on a box without snap, the setup made a Python environment in
`/opt/hollow-certbot` and ran `pip install certbot==5.8.0`. Only certbot was pinned: every
dependency resolved to whatever the package index served that day, unchecked, and pip
could build a source package with build tools it fetched unchecked too. That environment
runs as root twice a day from `hollow-certbot-renew.service`, which had no sandbox, and
`check-host.sh` did not look at it, so a box that installed a bad dependency showed only
ok. An environment an older setup made stayed as it was across updates.

## Fix

The setup ships `deploy/certbot-requirements.txt`: certbot, acme and every dependency
pinned to one version with their sha256 hashes (resolved for Python 3.10 to 3.13, every
platform). The environment installs with `--require-hashes --no-deps --only-binary :all:`
from that file alone, so pip refuses any other file, resolves nothing and builds nothing,
and the setup checks that certbot then starts. It records the file's hash in the
environment; one an older setup made, without that record, is made again on the next
settings run or update, and the old one is put back if that fails. The renewal unit runs
in a sandbox certbot and its deploy hook tolerate (no new privileges, read-only system
except certbot's folders and the relay's and TURN's key copies, no home, private temp
and devices, a system call filter that answers EPERM, and a capability bound of
chown, DAC override, fowner and binding port 80). `check-host.sh` checks those lines,
that only root can change the environment, and that its packages came from the file
beside it.

## Test

Unit (`relay-uws/test/installer/run_tests.sh`): `t_certbot_venv_installs_only_hashed_requirements`
(every requirement pinned with a hash, pip's flags, an older environment made again, a
current one kept, the unit's sandbox lines). Box (`systemd_box_test.sh`, Ubuntu 24.04 and
Debian 12): `certbot_venv_installs_only_hashed_requirements`, a real install from PyPI
holds only the pinned packages, a renewal, the deploy hook and a port 80 listener each run
in the sandbox, check-host prints only ok, an environment without the record and a
weakened sandbox each fail check-host.
