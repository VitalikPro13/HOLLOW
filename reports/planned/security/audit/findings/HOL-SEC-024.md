# HOL-SEC-024: A server member could overwrite, relink and delete vault content, and make a download write outside its folder

```
ID:          HOL-SEC-024                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: any vault file replaced by the attacker's own bytes on every
                                          member who downloads it, another person's file card pointed at
                                          attacker content, shard placements of another server wiped, and a
                                          one-click download that created or overwrote a file anywhere the user
                                          can write; Exploitability M: membership of a server with six or more
                                          members, or of any server we share for the placement wipe)
Category:    Missing authorization (object ownership); path traversal; missing integrity check
Component:   rust/hollow_core/src/node/vault_ops.rs :: shard_write_refused, shard_serve_refused,
             handle_shard_delete, ingest_vault_manifest
             rust/hollow_core/src/node/swarm.rs :: Olm and MLS vault arms
             rust/hollow_core/src/vault/pipeline.rs :: reconstruct_file, cache_path
             rust/hollow_core/src/vault/content_store.rs :: delete_placements, placement_target,
             manifest_home
             rust/hollow_core/src/node/types.rs :: MessageEnvelope (four shard variants removed)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-12, C-17; candidates H10, H11, H12, H14, H15, H22 (evidence files:V1-1..V11-1, F7-3)
Attacker:    P-05 server member
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

Vault shards are written by position (content id and index), and every write
path took any member's bytes over what we held, recording a hash of the new
bytes; a shard response did not even need membership or a request of ours, and
could clear the per-shard hash check for the real response. Every member holds
a vault file's key, so a member could encrypt its own bytes under it, and the
rebuilt file was never compared with its content id. A manifest from anyone
replaced any manifest, key included, and relinked any message's file card to a
content id of the sender's choosing; that content id and the file name's
extension then named the cache file a download wrote, unsanitized. A shard
delete from an admin of any shared server removed the placement records of
content in another server, and the MLS copy of the delete ignored permission
overrides. Any Olm peer could mark our placements confirmed. Four shard
envelope types had no sender and one buffered chunks without bound.

## Reproduction

`authz_shard_write_needs_a_member_and_a_shard_we_lack`,
`authz_vault_manifest_lands_only_from_its_creator` and `vault_gates_stay_wired`
(node/vault_ops.rs tests), `a_key_holder_cannot_rebuild_other_content` and
`cache_path_stays_inside_the_cache` (vault/pipeline.rs tests),
`delete_placement_test` (vault/content_store.rs tests).

## Fix

- One gate for every shard write, `shard_write_refused`: a current member of
  the server, a shard we do not hold yet, inside our pledge. A pending stream is
  never replaced by a second registration.
- The rebuilt ciphertext must hash to the content id before it is decrypted,
  so shards from any holder or key holder that do not rebuild exactly the file
  are refused.
- A manifest lands only from the member it names as creator, never over another
  creator's manifest, only with a well-formed content id, and relinks only file
  cards that creator sent. Cache file names keep only alphanumerics.
- `handle_shard_delete` is the one delete rule for both transports: a member
  with Manage Server (override-aware), and placements are deleted only in the
  server named.
- A placement is confirmed only by the peer it was placed on. Shard requests are
  served under `shard_serve_refused` (HOL-SEC-025). Vault envelopes other than
  deletes and manifests ride Olm only; the MLS copies are ignored. The chunked
  shard and probe envelopes are gone.

## Variants

- A member can still store unsolicited shards up to our pledge (or without
  limit when the pledge is unset), by design of the vault: members hold shards
  for each other.

## Test

Each test fails with its rule removed (the reconstruction test decrypts the
forged file, the cache path leaves the folder, the manifest lands from another
creator) and passes with it. Full suite green.
