# HOL-SEC-029: Anyone could cancel or pre-empt the destroy order waiting for a lost device

```
ID:          HOL-SEC-029                 Status: Fixed; relay deployed (2026-09-27), client half on local main
Severity:    High                        (Impact H: the order that wipes a stolen or lost device, parked at the
                                          relay until it connects, replaced by junk the device then acknowledges,
                                          or blocked for a year by one deposit dated far ahead; Exploitability M:
                                          any account and the device id, which room rosters and device lists
                                          show)
Category:    Missing authorization (courier slot ownership); trust in a sender-chosen timestamp
Component:   relay-uws/src/kill_list.h :: KillList
             relay-uws/src/ws_handler.cpp :: handle_kill_deposit, handle_kill_ack, auth delivery
             relay-uws/src/snapshot.cpp :: kill capture
             rust/hollow_core/src/node/destroy.rs :: handle_kill_signal
             rust/hollow_core/src/node/ws_client.rs :: WsCommand::KillAck
Boundary:    TB-1 (client <-> relay)
Traces to:   C-21; candidate I2 (evidence relay:A-12a, identity:S8)
Attacker:    P-02 any account, the thief of the device or anyone helping
Found:       2026-09-26, phase B relay pass; confirmed by reading 2026-09-27
```

## Description

The relay holds one destroy signal per offline device and cannot read it. Any
account could deposit for any device id, and a deposit with a newer issue stamp
replaced the waiting one whoever made it. The device then received the junk,
could not decode it and acknowledged it, which deleted the entry; the genuine
order, deposited once by the issuer, was gone. A deposit dated far in the
future also made every later genuine deposit fail the "strictly newer" test.

## Reproduction

`test/test_kill_list.cpp` (relay unit test, the "I2" block: a stranger's newer
deposit lands beside the genuine order, a future-dated deposit is refused, and
acknowledging the junk by its stamp keeps the order).

## Fix

- Each issuer holds its own slot per target (up to eight issuers per device);
  one issuer never replaces or removes another's signal, and the device is
  handed every signal at auth.
- A stamp more than ten minutes past the relay's clock is refused.
- The client acknowledges the one signal it turned away by its stamp; a bare
  acknowledgment (older clients, and the one sent after a wipe) still clears
  them all. Deployed to the official relay; the client half ships with 0.12.

## Variants

- Eight fresh accounts depositing after the genuine order can still push it out
  of a device's slots, and the global cap evicts the oldest entry of anyone
  (candidate I3). The relay cannot tell an order from junk; design ID-1 (removal
  locks at once, remote destroy needs the phrase) is the real fix.

## Test

The old list's own test asserted the replacement ("a newer deposit overwrites",
by a different issuer); the new test asserts the opposite and passes. Built and
run on the relay host before the deploy. The client's destroy tests pass with
the per-signal acknowledgment.
