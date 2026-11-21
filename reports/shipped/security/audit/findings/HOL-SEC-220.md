# HOL-SEC-220: a members-only relay whose keys.json did not read at boot ran open

```
ID:          HOL-SEC-220                 Status: Fixed (relay, track fix-153c, 2026-11-21),
                                          embargoed, rides the release
Severity:    Medium                      (Impact M: anyone reaches a relay its operator
                                          limited to key holders, and stays connected after
                                          the file is fixed; Exploitability L: needs the
                                          operator's keys.json to be unreadable when the
                                          relay starts, by a typo or the wrong permissions)
Category:    Fail-open configuration / Stale authorization
Component:   relay-uws/src/license.cpp (load_from_file, try_reload),
             relay-uws/src/license_pool.h (validate, replace_keys), main.cpp
Boundary:    TB-4 (relay host and its operator)
Traces to:   R-RS-23
Attacker:    anyone who can reach the relay
Found:       2026-11-21 (hostile review 1 of fix/153-license-seats, item 1)
Affected:    every relay with access keys, through 0.14.2
Fix commit:  pending (fix/153-license-seats)
Disclosure:  private until the release
```

## Description

A keys.json that was there but did not read at boot (bad JSON, a field of the wrong type,
a file the relay's account could not open) left the access-key gate off: `load_from_file`
returned false without turning it on, and main.cpp logged "license system disabled". The
relay then let everyone in. Once the operator fixed the file, the reload turned the gate on
but closed only the sockets holding a seat of a key that had gone; sockets let in while the
gate was off held no seat, so they stayed connected without a key, as did their sessions
in grace.

## Fix

A keys.json that is there but does not read at boot shuts the gate (`refuse_unread`): every
login is refused with `keys_unreadable` and close 1013, a code no client takes as final, so
clients keep retrying, and the log says the file does not read. The first reload that reads
the file lifts it. A reload that turns the gate on closes every socket the open gate let in
(`LicensePool::keyless`, `license_key_required`, close 1008 `license_required`, which also
ends its session), and every session in grace whose last login the new file does not admit
ends (`end_unlicensed_grace`). A reload that turns the gate off closes nobody. check-host
fails on a keys.json the relay cannot read (`--check-keys`, and the relay account's read
permission).

Tests: relay unit `test_license_pool` ("an unread keys file refuses every login, with a key
or without", "turning the gate on closes (or seats) the sockets it let in keyless", "the
gate back on ends the socket whose key the file dropped meanwhile"); live variant
`license_unread` (`test_license_unread`) and variant `license`
(`license_gate_on_ends_the_keyless`, `license_gate_off_kicks_nobody`) and variant
`license_grace` (`test_license_grace`, sessions in grace across reloads); `run_live.sh`
"--check-keys fails only a keys file that does not read".
