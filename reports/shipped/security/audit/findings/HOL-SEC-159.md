# HOL-SEC-159: A 4-digit App Lock PIN and a backup passphrase of any length fell quickly to an offline search

```
ID:          HOL-SEC-159                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H: the identity; Exploitability M: a copy of the data folder or a backup file)
Category:    Authentication
Component:   rust/hollow_core/src/api/identity.rs (refuse_short_pin), api/storage.rs (export_backup), security_section.dart, backup_section.dart
Boundary:    TB-4
Traces to:   phase E+F local C-LOCAL-04 (lead L-07), identity C-IDENTITY-12; claim C-36
Attacker:    P-09 holder of a data copy
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The App Lock PIN could be 4 digits behind Argon2id alone, and a .hollow backup holding the
master key and all history could be sealed with any passphrase.

## Fix

New PINs need 6 digits in Rust and Dart, old shorter PINs keep unlocking and are asked once
to upgrade; backup export needs 12 characters, import is unchanged.

## Residual risk

Offline guessing of a 6-digit PIN without hardware attempt limits: AR-24.

## Test

`a_new_pin_needs_six_digits`, `an_old_four_digit_pin_still_unlocks`,
`a_backup_needs_a_long_passphrase_and_an_old_short_one_still_opens`,
`security_dialogs_test`, `backup_passphrase_test.dart`.
