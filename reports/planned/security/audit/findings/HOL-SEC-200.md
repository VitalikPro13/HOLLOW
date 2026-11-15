# HOL-SEC-200: Olm pickles left session and account secrets in freed memory on every save

```
ID:          HOL-SEC-200                 Status: Fixed in 0.14
                                          (a6cdf8c4, 2026-11-07)
Severity:    Low                         (Impact M: root and chain keys, skipped
                                          message keys and the account's identity and
                                          one-time secret keys outlive their use in
                                          freed heap, weakening forward secrecy;
                                          Exploitability L: needs a memory disclosure,
                                          a core dump or a swapped page of the device)
Category:    Crypto / Key material lifetime
Component:   rust/hollow_core/src/crypto/olm_manager.rs (pickle serialization,
             from_pickles, take_newer), crypto/store.rs (CryptoStoreCmd, read_newer),
             storage/messages.rs (Olm rows), node/crypto_handler.rs (olm_frame,
             persist_*), push_enrich.rs, crash_dumps.rs (new)
Boundary:    TB-4
Traces to:   RUSTSEC-2026-0451 (GHSA-v27v-f96q-qhjq), the same material in vodozemac's
             own copies; AR-30 (a session is saved after every step)
Attacker:    P-09 physical holder of a device (its memory, a crash dump or swap), or
             any process that reads this one's memory
Found:       2026-11-07 (hostile review of the vodozemac 0.9 -> 0.11.2 upgrade)
Affected:    every release through 0.13.0
Fix commit:  a6cdf8c4 (0.14, 2026-11-07)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

Each Olm encrypt and decrypt saves the session (AR-30), and account changes save the
account. The save serialized the pickle into a plain `String`, grown by doubling, and
the account went through a `serde_json::Value` tree first. That string crossed the
CryptoStore channel to the SQL bind, and every load read the rows back into plain
strings. None of these buffers, nor the copies left behind when a buffer grew, were
wiped before they were freed. Nothing kept core dumps from carrying the heap. Upgrading
vodozemac wiped only vodozemac's own copies.

## Fix

Pickles are `Zeroizing<String>` (`olm_manager::Pickle`) from serialization through the
store channel to the bind, and every read of an Olm row returns one, wiped once it is
unpickled. Serialization measures the JSON first, then writes it into a buffer of
exactly that size, and a write past it fails instead of growing. The account row is
written straight from vodozemac's pickle with the slot table flattened in, and read back
as two typed views; no JSON value tree holds a secret. Each process entry (the app's
init, node start, the push fetch, the iOS extension, the forwarder) sets RLIMIT_CORE to
zero on Unix and keeps the heap out of Windows Error Reporting dumps.
`hollow_crash.log` is unaffected.

## Residual risk

SQLite copies a bound value into its own memory and the page cache holds the decrypted
page; SQLCipher wipes those only with `cipher_memory_security`, which stays off for its
cost. Copies on the stack during (de)serialization are not wiped. Linux keeps the
process dumpable: xdg-desktop-portal and PipeWire identify a flatpak client by
/proc/PID/root, which a non-dumpable process denies them, so a crash handler that
ignores RLIMIT_CORE can still collect a core. MLS saves: HOL-SEC-201. The SQLite and
SQLCipher copies are accepted risk AR-44.

## Test

`a_saved_pickle_is_wiped_when_dropped_and_never_outgrew_its_buffer`,
`pickles_read_back_from_the_store_are_wiped_on_drop`,
`a_process_that_holds_secrets_writes_no_core_dump_with_its_heap`.
