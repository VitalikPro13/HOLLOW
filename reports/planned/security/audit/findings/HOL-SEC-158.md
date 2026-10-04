# HOL-SEC-158: iOS backups carried Hollow's data and keys, and the recovery phrase could be captured on screen and in the clipboard

```
ID:          HOL-SEC-158                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H: identity and history in iCloud or Finder backups unless a password protected them; Exploitability M: whoever reads the backup or the clipboard)
Category:    Data exposure
Component:   ios/Runner/AppDelegate.swift, lib/src/core/services/app_lock_service.dart, privacy_screen.dart, secret_clipboard.dart, android MainActivity.kt
Boundary:    TB-4, TB-6
Traces to:   phase E+F relay_push C-RP-03; local C-LOCAL-09, -10, -17
Attacker:    P-11 backup provider, P-09 device holder
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Hollow's iOS folders were not excluded from device backups and keychain items used a
migrating accessibility class; the phrase screens could land in screenshots and the app-
switcher thumbnail; a copied phrase stayed in the clipboard.

## Fix

The data folders are excluded from backup at every start; keychain items use this-device-
only classes (old items migrated); phrase screens set FLAG_SECURE on Android and a cover on
iOS, and the switcher is covered while App Lock is on; a copied phrase is marked sensitive,
local-only and cleared after 60 s.

## Residual risk

The macOS Rust keychain item keeps its class (the data-protection keychain needs a signing
change); checked on devices in the regression pass.

## Test

`app_lock_keychain_migration_test.dart`, `secret_clipboard_test.dart`.
