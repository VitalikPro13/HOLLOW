# HOL-SEC-206: Importing a shards bundle could replace a vault file's key or store shards no manifest names

```
ID:          HOL-SEC-206                 Status: Fixed in 0.14
                                          (89d3a85d, 2026-11-14)
Severity:    Medium                      (Impact H: a held vault file's manifest (its key,
                                          name and content id) is replaced, so the file a
                                          member recovers is someone else's bytes, and junk
                                          shards take the place of real ones; Exploitability L:
                                          the person must choose to import a .hollow-shards
                                          file the attacker gave them)
Category:    Authorization / Write gate bypass
Component:   rust/hollow_core/src/api/archive.rs (import_server_shards)
Boundary:    TB-4 (files from other people)
Traces to:   CLAUDE.md "Vault writes/serves/deletes/manifests ONLY via the vault_ops gates";
             wiki security_write_gates §14
Attacker:    anyone who can hand the person a file
Found:       2026-11-14 (track t14-zipbomb, HOL-SEC-205 sweep)
Affected:    every release with the evidence recovery pool (shard export and import,
             e63446bf, 2026-04-13) through 0.13.0
Fix commit:  89d3a85d (0.14, 2026-11-14)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

`import_server_shards` wrote every manifest a bundle carried with `INSERT OR REPLACE` and
stored every shard for whatever server the bundle named. It used neither the live
manifest gate (`vault_ops::ingest_vault_manifest`: creator only, never over another
creator's manifest) nor the one shard-write gate (`shard_write_refused`,
`shard_bytes_refused`), so a bundle could replace a held manifest, plant manifests in a
server's vault for restricted channels or non-members, and store shards that do not hash
to anything their manifest names, for servers the person is not in.

## Fix

A bundle names no sender, so it is judged against what the device holds. For a server we
hold and are a member of, a manifest only fills, in one `INSERT OR IGNORE`
(`ContentStore::fill_manifest`), counted only when a row was added: never over one we
hold, its creator a current member who sent the file card we hold for its message (no
card, no manifest), its channel one of the server's that we may read and not restricted,
its content id well formed; it relinks no file card. For a server we no longer hold (the
ex-member case bundles exist for) no manifest is added at all. A shard lands only under
the server its held manifest names: a member's through `shard_write_refused` (pledge,
never over a held shard), and every one through `shard_bytes_refused` with the
unasked-copy rule, so only the bytes the held manifest pins are stored; sizes and
erasure parameters come from the held manifest.

## Test

`a_bundle_for_a_server_we_do_not_hold_stores_nothing`,
`a_bundle_never_replaces_a_held_vault_manifest`,
`a_bundle_shard_that_does_not_hash_to_its_manifest_is_not_stored`,
`a_bundle_manifest_is_judged_like_a_live_one` (all failed on the old code);
`a_bundle_shard_its_manifest_does_not_pin_is_not_stored`,
`a_bundle_shard_lands_only_under_the_server_its_manifest_names`,
`a_bundle_stays_inside_our_storage_pledge`,
`an_ex_members_bundle_restores_only_the_shards_of_manifests_it_holds`,
`review_t14_a_bundle_manifest_cannot_squat_another_creators_content`,
`a_fill_never_replaces_a_manifest_that_landed_first`, and the control
`a_real_bundle_from_our_own_export_still_imports`. Mutation pass: 11 of 12 killed; the
survivor is equivalent.

## Residual risk

An ex-member's bundle restores only the shards of manifests the device still holds; a
vault file whose manifest never reached this device cannot come back from a bundle.
