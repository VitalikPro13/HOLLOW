# HOL-SEC-217: a phrase restore beside its own database kept the old device's Olm account

```
ID:          HOL-SEC-217                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore, S217)
Severity:    Low                         (Impact M: two devices encrypting from the same
                                          Olm chains reuse message keys where the relay
                                          sees the ciphertext, and share one-time keys;
                                          Exploitability L: needs the original device
                                          still running beside a restored copy of its data)
Category:    Key reuse across devices
Component:   rust/hollow_core/src/identity/keys.rs (restore_identity_from_mnemonic),
             crypto/olm_manager.rs (load)
Boundary:    TB-1 (the relay and the network path)
Traces to:   AR-30, HOL-SEC-076, R-ID-15 (new)
Found:       2026-11-21 (phrase restore design 8.3; confirmed by the hostile review)
Affected:    0.12.0 through 0.14.2
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

A phrase restore keeps this identity's database and mints a new device, but the database kept
the old device's Olm account and sessions, read marks, replay nonces and MLS rows. MLS mints a
new credential at start; Olm took the old account as its own. When the original device still
ran (a keychain-bound copy of its data restored through the "Identity locked" screen), both
devices encrypted from the same chains. The same code overwrote the device key when only the
master key file was lost, so the old device stayed counted with no key anywhere.

## Fix

The restore keeps the old device whole only when its key opens here, it is not the master, the
held roster counts it, and the database's MLS credential names it; a recovery typed because
someone else may hold a device never keeps it. Any other restore mints a device after
`MessageStore::forget_device_secrets` drops the old device's Olm account, sessions, floors,
read marks, nonces and MLS rows (history and clears stay), and writes the new device key last.
Tests: `a_restore_that_mints_a_device_beside_its_own_database_starts_a_fresh_olm_account`,
`a_restore_over_a_lost_key_file_keeps_its_counted_device`,
`a_restore_never_keeps_a_device_its_roster_does_not_count`,
`a_restore_never_keeps_the_master_as_its_device`,
`a_restore_never_keeps_a_device_the_databases_mls_credential_does_not_name`,
`a_recovery_restore_always_mints_a_device`, `forget_device_secrets_keeps_history_and_clears`.
