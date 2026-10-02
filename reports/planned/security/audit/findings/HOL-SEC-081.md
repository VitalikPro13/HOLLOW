# HOL-SEC-081: Destroying a device dropped the devices it had linked

```
ID:          HOL-SEC-081                 Status: Fixed on local main (2026-10-02), retest at release
Severity:    Low                         (Impact M: the person's other devices stop counting as
                                          theirs and must ask to join again; Exploitability L: the
                                          person does it to themselves, no attacker involved)
Category:    Identity / Availability
Component:   rust/hollow_core/src/node/roster_book.rs (remove_self), node/destroy.rs
Boundary:    TB-3 (own identity and its devices)
Traces to:   C-03; HOL-SEC-077 (design ID-1)
Attacker:    none (a defect in the destroy flow)
Found:       2026-10-02 (session 25)
```

## Description

The destroy scope that wipes this device and removes it from the identity signed a removal
that kept none of the devices it had vouched for. Under the fold, every vouch a removed
device made then counts for nothing, so a laptop linked from that phone stopped being one
of the person's devices at every contact, and on its next start asked to join again.

## Fix

The self-removal keeps every current member the device vouched for, as a removal made from
another device does.

## Test

Unit `removing_itself_keeps_the_devices_it_linked`; mutation pass.
