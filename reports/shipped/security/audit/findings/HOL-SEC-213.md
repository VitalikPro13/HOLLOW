# HOL-SEC-213: the TURN port check could take a local program for coturn by its name

```
ID:          HOL-SEC-213                 Status: Fixed in the relay setup of 0.14.2 (2026-11-20)
Severity:    Low                         (Impact L: a UDP listener inside the TURN band is
                                          reported as coturn's, so the check says ok while TURN
                                          can reach it; the firewall rule itself is unchanged;
                                          Exploitability L: a local account on the relay host)
Category:    Spoofable input in a security check
Component:   relay-uws/deploy/turn-port-lock.sh (check: stray listeners)
Boundary:    local accounts on the relay host
Found:       2026-11-20 (builder of track fix-153, while fixing #153)
Affected:    every relay setup since the stray-listener check
Fix commit:  5ebafeac6
```

## Description

The check read the owner of each listener from the first `pid=` on its `ss -p` line. The
program's own name comes first on that line and a local program chooses it, so a name
holding `pid=<coturn's pid>` made the listener pass as coturn's.

## Fix

The pid is taken from the end of the line (`,pid=N,fd=M))`), which the program name cannot
reach; a line in any other shape counts as a stray listener. Tests:
test_turn_port_lock.sh `a_listeners_own_name_cannot_pass_for_coturn` and its box twin.
