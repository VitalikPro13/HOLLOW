# HOL-SEC-205: A received sticker pack was unpacked with no size limit as soon as its card showed

```
ID:          HOL-SEC-205                 Status: Fixed in 0.14
                                          (89d3a85d, 2026-11-14)
Severity:    High                        (Impact M-H: every member who views the conversation
                                          runs out of memory and the app aborts, again on every
                                          open while the attachment stays; nothing is read or
                                          written; Exploitability H: anyone who may post a file
                                          in a DM or channel, no click from the victim)
Category:    Resource exhaustion / Data validation (decompression without a budget)
Component:   rust/hollow_core/src/api/stickers.rs (read_pack_manifest, import_sticker_pack),
             rust/hollow_core/src/api/archive.rs (import_server_shards),
             lib/src/ui/chat/sticker_pack_card.dart (preview on every card build)
Boundary:    TB-2 (peer and peer), TB-3 (server members)
Traces to:   CLAUDE.md zip rule (enclosed_name + allowlist + size budget, HOL-SEC-129)
Attacker:    any friend or server member who can send a file
Found:       2026-11-14 (hostile review of track t14-deps, finding 1)
Affected:    every release with sticker packs, from 0.10.0-beta (603853b5, 2026-08-01)
             through 0.13.0 (the pack card); the shards import in every release through 0.13.0
Fix commit:  89d3a85d (0.14, 2026-11-14)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

The chat card for a received `.hollow-pack` reads the pack's manifest as soon as the
file is on disk, before anyone taps Add. The manifest was read whole, with no limit on
what it inflated to, and the import read each sticker the same way before checking it.
A small pack could therefore inflate about a thousand times in the viewer's memory. The
`.hollow-shards` import had the same gap for its manifest and its shards, on a file the
person picks. The earlier hostile replay of these importers never reached the entry
checks, because every fixture lacked a manifest.

## Fix

Every entry is read under a cap of its own and one budget for the whole zip, counting
the bytes it really inflates to (`Read::take`, `zip_budget::UnpackBudget`), never the
size its header claims; a refused entry still pays for what it inflated. Sticker packs:
the file is at most the budget plus 1 MiB (checked before it is read), the manifest
128 KiB, each sticker 512 KiB (the asset rail's sticker cap), all of it 128 KiB plus
120 full stickers; past the budget the rest of the pack is reported rejected. Shard
bundles are judged whole before anything is stored: manifest 16 MiB, each shard no
larger than the bundle itself (ciphertext does not inflate), all of it
max(64 MiB, 4 x the bundle's size). Before the zip reader parses anything, the
file's index is walked from its tail (`zip_budget::index_refused`): the end record
must close the file, and it may list at most 128 entries for a pack and 65536 for a
bundle, each record no longer than a Hollow container writes, since the reader
allocates a record for every entry the index declares (the hostile review measured a
61 MiB pack listing 1.25 million entries at about 480 MiB). The card reads one pack at
a time and each pack file once per run; it remembers a refusal of the file, reads again
after any other failure only when a card next opens, and shows "Can't open this pack"
without an Add button. A sweep of
every zip reader found the snapshot, archive viewer and `.hollowpack` readers already
bounded and the updater reading only a zip its signed manifest names.

## Test

`a_pack_whose_manifest_unpacks_past_its_cap_is_refused`,
`a_pack_stops_unpacking_once_its_budget_is_spent`,
`a_pack_file_past_its_size_is_refused_before_it_is_read`,
`review_t14_a_pack_listing_far_more_entries_than_a_pack_holds_is_refused` (with a peak-RSS
check), `a_pack_whose_index_lists_more_entries_than_a_pack_holds_is_refused`,
`a_bundle_listing_more_entries_than_a_bundle_holds_is_refused`,
`an_index_is_counted_before_anything_parses_it`,
`a_bundle_whose_manifest_unpacks_past_its_cap_is_refused`,
`a_shard_that_unpacks_past_its_bundle_refuses_the_bundle`,
`shards_together_stop_at_the_bundle_budget` (all failed on the old code);
`a_blob_that_inflates_past_the_sticker_cap_costs_only_the_cap`, `a_real_pack_still_imports`,
`a_real_bundle_from_our_own_export_still_imports`, the `zip_budget` unit tests, the `.hollowpack` sweep tests
`a_manifest_that_unpacks_past_its_cap_is_refused` and
`a_file_that_inflates_past_its_cap_is_refused_before_it_is_hashed`, and the widget test
"a pack that cannot be read shows a calm state and is read once", "a failure that is not
the file is read again on the next open" and "packs are read one at a time". Mutation
passes: 14 of 14 Rust and 2 of 2 Dart mutants killed, then 14 of 14 and 3 of 3 for the
review fix round.

## Residual risk

None known. A pack inside its budget still costs the viewer up to that budget, about
60 MiB, while its card reads it, and a bundle up to its own.
