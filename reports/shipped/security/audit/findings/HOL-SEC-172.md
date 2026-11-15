# HOL-SEC-172: A device coming back to a full address could lose its own session to its own login

```
ID:          HOL-SEC-172                 Status: Fixed (2026-10-07, wave 2 of resumable sessions),
                                          relay not yet deployed
Severity:    Low                         (Impact L: the session ends as on expiry, so the device
                                          starts afresh and repairs the gap, and a stranger at the
                                          address can do no more than it could before; it hit real
                                          phones behind a shared address; Exploitability H: no
                                          attacker needed)
Category:    Availability
Component:   relay-uws/src/ws_handler.cpp (.open per-IP lines, handle_auth), session_bounds.h
             (admits, settle_victim)
Boundary:    TB-1 (client <-> relay)
Traces to:   RESUMABLE_SESSIONS_PLAN.md 9.7 Bounds and 11.2 (grace_slot_victim)
Attacker:    none; a neighbour behind the same address (carrier NAT, a shared Wi-Fi)
Found:       2026-10-07 (wave 2 bounds review)
```

## Description

A session in grace keeps its socket's slot under the per-address cap. When a new socket
arrived at a full address, the relay ended the grace session there closest to its end before
the socket had logged in, to make room. The relay could not yet know who was coming: the
device coming back to resume its own session was often the one whose session it ended, so the
resume failed, and when it was not, another device's session ended although the resume was
about to free the returning device's own slot.

## Fix

At a full address a new socket comes in only against a grace slot the address holds, and ends
nobody (`session_bounds::admits`). Once its login is through, its own session resumed or
ended, the address is settled: while still over the cap, the grace session there closest to
its end gives its slot up (`settle_ip_slot`, `settle_victim`). The number of sockets over the
cap never exceeds the grace slots there, so the cap still holds once each login settles.

## Test

`test_relay_live` "bounds: a full address and the grace slots it holds" (the test build caps
an address at three sockets): "a device coming back to its full address resumes its own
session" and "without costing the earlier one its session" failed on the wave 1 `.open`;
a newcomer still takes the oldest grace slot, and an address of live sockets still refuses.
