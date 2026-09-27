# HOL-SEC-059: The push fetch node cleared every parked destroy order

```
ID:          HOL-SEC-059                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact H: a lost or stolen phone's pending destroy order
                                          erased before it ran; Exploitability M: anyone can deposit a
                                          junk order for a device id, and the phone's next push wake
                                          answers it)
Category:    Logic error (residual of HOL-SEC-029)
Component:   rust/hollow_core/src/node/fetch.rs :: handle_kill_frame
Boundary:    TB-1 (client <-> relay)
Traces to:   C-02, C-03; relay inventory E.2
Attacker:    P-06 anyone authenticated to the relay
Found:       2026-09-27, design A inventories
```

## Description

The fetch node answered an undecodable or permanently refused order with a bare
`kill_ack`, which the relay treats as "delete every order parked for me". The full
node already acked such an order by its own stamp.

## Reproduction

`a_junk_kill_deposit_is_acked_alone` (node/fetch.rs tests).

## Fix

A junk or refused order is acked by its own stamp; a bare ack follows only a
wipe, as in the full node.

## Test

The test fails with the old rule put back and passes with the fix.
