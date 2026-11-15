# HOL-SEC-201: MLS saves left group and signing secrets in freed memory on every message

```
ID:          HOL-SEC-201                 Status: Fixed in 0.14
                                          (bc2c4bdc, 2026-11-07)
Severity:    Low                         (Impact M: the device's MLS signing key, each
                                          group's epoch and message secrets, HPKE private
                                          keys, resumption secrets and a staged commit's
                                          path secrets outlive their use in freed heap,
                                          weakening forward secrecy for server traffic;
                                          Exploitability L: needs a memory disclosure,
                                          a core dump or a swapped page of the device)
Category:    Crypto / Key material lifetime
Component:   rust/hollow_core/src/crypto/mls_storage.rs (TrackedStorage, MlsSave),
             crypto/mls_past.rs (capture, pack, unpack, scrub), crypto/mls_manager.rs
             (signer save and load, from_stored), crypto/store.rs (SaveMls),
             storage/messages.rs (MLS rows), crypto/wiped.rs (new)
Boundary:    TB-4
Traces to:   HOL-SEC-200 (the same class for Olm pickles); the MLS twin of AR-30 (every
             MLS step is saved before its frame leaves)
Attacker:    P-09 physical holder of a device (its memory, a crash dump or swap), or
             any process that reads this one's memory
Found:       2026-11-07 (while fixing HOL-SEC-200)
Affected:    every release through 0.13.0
Fix commit:  bc2c4bdc (0.14, 2026-11-07)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

Every MLS encrypt and decrypt moves a group's message secrets, and each step is saved
before its frame leaves. OpenMLS's memory store, which holds every group, serialized each
written row into a buffer grown by doubling, copied it once more, and freed both the growth
copies and the row it replaced without wiping them. Each save then copied the changed rows
into plain buffers, the device's signing key among them, and those crossed the CryptoStore
channel to the SQL bind; every load read the rows and the signer back the same way. Past
epochs, kept for late frames, were scrubbed through a JSON value tree and packed and
unpacked through growing buffers, all freed unwiped. Nothing in this path wiped a secret
before its memory was freed.

## Fix

The rows that hold key material (message and epoch secrets, resumption secrets, group
state, HPKE and signature key pairs, epoch key pairs, KeyPackages, PSKs) are written by
Hollow's store wrapper instead of the memory store, in one pass into a buffer that wipes
each buffer it outgrows; the row each write replaces or deletes is wiped before it is
freed. Tests hold every such write to the memory store's own key and bytes. Save rows, the
signer, every row read back and a pre-0.13 whole-store blob are wiped on drop from the take
through the store channel to the bind and back; rows read from disk move into the store
without a copy, and a row they replace is wiped. The signer is written into a buffer sized
before the first byte and read back through a reader that wipes what it outgrows. Past
epochs are scrubbed in the row's own buffer, packed into buffers sized up front and kept at
their exact size, and unpacked through a buffer that wipes what it outgrows.

## Residual risk

Inside OpenMLS, every read of a row (a group's load at start or when a past epoch opens,
the epoch key pairs at a commit, a KeyPackage at a Welcome) parses it with serde_json,
whose byte arrays grow by doubling and free partial copies unwiped before OpenMLS holds the
secret in its own wiped type. The rows without key material (tree, context, transcript
hash, confirmation tag, join config, own leaf nodes and index, the proposal queue) are
still written by the memory store. The compressor and decompressor that pack past epochs
free their state, up to a 32 KiB window of those rows, unwiped. SQLite copies a bound
value into its own memory and its page cache holds the decrypted page; SQLCipher's
`cipher_memory_security` would wipe them, and stays off: measured with this fix it makes
page reads 8 to 22 times and inserts 4 to 5 times slower on the Mac, and on Windows the
measurement overflowed its stack every time (accepted risk AR-44). Copies on the stack
during (de)serialization are not wiped.

## Test

`mls_save_rows_are_wiped_on_drop`, `a_replaced_or_deleted_secret_row_is_wiped`,
`rows_laid_over_the_store_wipe_what_they_replace`, `a_store_let_go_wipes_every_row`,
`the_signer_reads_back_as_the_crate_reads_it`,
`a_past_copy_is_scrubbed_in_place_as_the_value_tree_scrubbed_it`,
`a_packed_copy_never_outgrew_its_buffers`,
`zeroing_in_place_touches_only_numbers_arrays_hold`, `a_row_of_another_shape_is_not_kept`,
`a_wiping_writer_wipes_every_buffer_it_outgrows`,
`reading_to_the_end_wipes_what_it_outgrows_and_keeps_every_byte`; every MLS test checks
each key-material write against the memory store's own (`verify::same_write_as_theirs`).
