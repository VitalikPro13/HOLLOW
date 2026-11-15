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

A device that still holds its identity's 0.11 stored phrase drops any recovery key that
phrase does not derive, on ingest and at start-up (session 34). Since session 35 (decision
C) such a device, at its first 0.12 start and before it connects, signs the identity's
first recovery with that phrase: one fixed statement every device of the identity signs
alike, the devices its 0.11 list kept admitted by the phrase and the ones it revoked
removed in that base, so contacts, its other devices and the relay pin the real key first.
A pinned key no longer erases the stored phrase; only the person confirming it, or typing
the phrase on that device, does, and the confirmation signs nothing new when the phrase
already roots the roster.

## Residual risk

Contacts, the relay and linked devices still pin the first key they see for an identity
none of whose devices kept the 0.11 phrase (or whose only such device is missing from its
0.11 list), until the phrase is typed there; and a contact that first hears of the identity
after a master-key holder published a forged key pins that one (AR-15's first-contact case).

## Test

`authz_a_recovery_key_from_the_network_never_locks_out_our_own_phrase` (failed: a forged key
admitted its device), `authz_a_legacy_identity_pins_its_phrase_before_a_forger_can`,
`authz_the_first_start_roots_a_legacy_identity_in_its_stored_phrase`,
`authz_two_legacy_devices_upgrading_apart_meet_in_one_base`,
`confirming_the_stored_phrase_after_the_upgrade_only_erases_it`.
