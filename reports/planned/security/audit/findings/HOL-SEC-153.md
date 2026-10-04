# HOL-SEC-153: During the legacy window a forged recovery key could lock the owner's own devices out of their phrase

```
ID:          HOL-SEC-153                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H: the owner's real phrase refused for good at that device; Exploitability L: a master-key holder acting before the owner confirms the phrase on 0.12)
Category:    Access control
Component:   rust/hollow_core/src/node/roster_book.rs (heard_for_own, stored_phrase_key)
Boundary:    TB-3
Traces to:   phase E+F identity part 2 C-IDENTITY-06; AR-15
Attacker:    P-08 master-key holder
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

While an identity was still legacy, the first recovery key any master-key holder published
was pinned by the owner's own devices too, so the owner's real phrase was then refused and
the stored legacy phrase later erased.

## Fix

A device that still holds its identity's legacy stored phrase drops any recovery key that
phrase does not derive, on ingest and at start-up.

## Residual risk

Contacts, the relay and a 0.12-linked device of a legacy identity still pin the first key
they see during the legacy window (AR-15's first-contact case).

## Test

`authz_a_recovery_key_from_the_network_never_locks_out_our_own_phrase` (failed: a forged key
admitted its device).
