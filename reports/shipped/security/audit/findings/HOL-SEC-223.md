# HOL-SEC-223: a "not sure" settling undid the owner's home relay

```
ID:          HOL-SEC-223                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore)
Severity:    Low                         (Impact L: for a short time the server names no
                                          home relay, so HOL-SEC-211's rule is off there;
                                          Exploitability L: needs the owner's own removal
                                          of the device that named the home)
Category:    Availability of a security setting
Component:   rust/hollow_core/src/crdt/settle.rs (settling_input)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 8.3; R-CR-13, R-CR-18
Found:       2026-11-22 (phrase-restore, while fixing HOL-SEC-222)
Affected:    0.14.2 (the home relay setting came with it)
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

A settling keeps a dropped device's op only when this device stored it before T. The
owner's device that creates a server names its home relay at once (HOL-SEC-211), so on a
server the lost device founded, the home op is that device's too. A "not sure" settling
(T is the first fold of the oldest restore point held here) drops it like everything else
the device did there, and the settled server names no home until an owner device names it
again on its next batch tick. Meanwhile a member on another relay is not told the server
lives elsewhere.

## Fix

The settling keeps the owner's op naming the relay this device dials as the server's home
(`ServerState::home_stand`, `Settling.home` from `ws_client::relay_home()`), whoever wrote
it and whenever it was stored here. Of several naming that relay, a counted device's
first, then the earliest clock, then the content id. A home op naming any other relay
keeps the ordinary rule, so a home a lost device named elsewhere, earlier or later, never
outlasts the settling; with no relay known, none is kept and the owner names it again as
before.

Tests: unit `a_settling_keeps_only_the_home_op_naming_the_relay_this_device_dials` (kept
for the relay dialled, none for another relay or none dialled, though the lost device
named another relay earlier), harness `pr222_a_not_sure_settling_keeps_the_home_relay`
(the lost founder named the home; with owners naming no home meanwhile, the settling's
base and the state still name it). Both fail without the fix (the home reads missing).
