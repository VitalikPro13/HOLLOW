# HOL-SEC-076: The recovery phrase and the device's Olm and MLS state rode every backup and link snapshot

```
ID:          HOL-SEC-076                 Status: Fixed on local main (2026-10-01), retest at release
Severity:    High                        (Impact H: the phrase is the identity, now and after any
                                          recovery; live Olm state lets the holder read and answer as
                                          the source device; Exploitability M: a backup file and its
                                          passphrase, or, before HOL-SEC-002's fix, a relay position)
Category:    Sensitive data exposure / Key management
Component:   rust/hollow_core/src/api/storage.rs (save_mnemonic, get_mnemonic, build_snapshot_bytes,
             import_backup, import_pending_link); lib/src/ui/settings/security_section.dart (Reveal);
             lib/src/ui/shell/hollow_shell.dart (saveMnemonic at identity creation)
Boundary:    TB-3 (own identity and its devices), files that leave the device
Traces to:   C-05, C-06, C-37; AR-02
Attacker:    P-09 (a holder of a backup file or a device); P-01 for link snapshots before HOL-SEC-002
Found:       2026-09-30 (session 20, while mapping design ID-1)
```

## Description

`save_mnemonic` wrote the 24 words into the database as `recovery_mnemonic` when an
identity was created, and Settings showed them with no password. `messages.db` was
copied whole into every `.hollow` backup and every link snapshot, so each one carried
the phrase, the source device's Olm account and every Olm session; only a link import
cleared the MLS identity, and a backup import cleared nothing. A restored or linked
device ran on another device's Olm identity key, and anyone holding a backup file and
its passphrase held the phrase, which design ID-1 makes the final word on the identity.

## Fix

The phrase is never stored: a new identity shows it once and asks for three of its words
back, then forgets it (`identityProvider.forgetMnemonic`). An identity from before 0.12
shows its stored phrase one last time, has it typed back, signs its first recovery with
it and erases it; "Later" keeps a reminder. Settings checks the phrase, never reveals
it. Snapshots export a scrubbed copy of the database: no `recovery_mnemonic`, no Olm
account or sessions, no MLS identity, and every import clears them as well, so each
restored device mints its own.

## Test

`snapshots_leave_device_secrets_behind_both_ways` (api/storage: neither the export nor
the import keeps the phrase, the Olm account or sessions, or the MLS identity),
`the_bootstrap_is_imported_and_the_stored_phrase_erased` (roster_book),
`dialogs_batch1_test` (the two-step phrase dialog), the session-22 fleet pass (a fresh
identity's phrase shown once and checked, Settings with Check and no Reveal).

## Residual

The person holds the phrase on paper; whoever reads it is the identity (AR-15).
