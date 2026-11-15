# HOL-SEC-117: A planted or wrong vault shard blocked a download for good

```
ID:          HOL-SEC-117                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: a vault file another member can no longer rebuild;
                                          Exploitability M: a server member)
Category:    Vault / Availability
Component:   rust/hollow_core/src/vault/pipeline.rs (VaultManifest.shard_hashes),
             node/vault_ops.rs (shard_bytes_refused, gather_vault_shards, drop_unpinned_shards,
             ShardAsks pull book), file_handler.rs, swarm.rs (shard arms)
Boundary:    TB-3 (server members)
Traces to:   HOL-SEC-105 residual, phase B re-check files A-V1, A-V6, A-V11
Attacker:    a server member
Found:       2026-10-02 (phase B re-check)
```

## Description

Held vault shards are never replaced and their key is global, so a first copy planted by any member (an unasked ShardStore or ShardMigrate), or a wrong answer from a holder we asked, refused the real shard; every later rebuild failed its content check and nothing removed the bad copy.

## Fix

The creator's manifest pins each stored shard's SHA-256 (the content id under replication), and every shard write refuses bytes the manifest contradicts. A download deletes, through vault_ops, each held copy the manifest contradicts, and after a failed rebuild the copies nothing vouches for, then pulls afresh: never again from a holder whose answer was refused, at most three times on its own per request. Replicated content with no local copy is now pulled instead of failing.

## Residual risk

Older erasure manifests carry no hashes, so a bad holder cannot be named and can use up the three automatic pulls; since session 32 a failed rebuild of such a manifest keeps the copies at indices our placement names (the ones we hold for others), which also keeps a bad copy at one of our own indices until the person retries. The first manifest for a content id still wins (pre-existing): the manifest is unsigned and the content id names no author, so a member who lands a manifest before the creator's sets the hashes, and its false hashes make that receiver refuse genuine copies of that one content id (availability only). Binding the content id into the file's own commitment would close it (a protocol change, about one session).

Closed in session 32: an unasked ShardStore registered first no longer drops the asked holder's stream (the answer we asked for takes the slot), and while we pull a content id an unasked copy lands only as the bytes the manifest pins. Tests `the_holder_we_asked_wins_over_unasked_stores_of_a_shard`, `a_failed_legacy_rebuild_keeps_the_copies_we_hold_for_others`, `a_pull_waits_only_for_its_own_content`; mutation 14/14 killed (`tmp_s32_files_mutate.py`).

## Test

Harness `a_planted_vault_shard_is_dropped_and_the_real_one_pulled` (failed before: "a planted first copy blocked the download"), `a_holder_that_answers_with_a_wrong_shard_is_not_asked_again`; unit `a_shard_must_be_the_one_its_manifest_names`, `a_rebuild_deletes_the_copies_its_manifest_refutes`, `a_refuted_holder_is_skipped_and_fresh_pulls_are_capped`, `a_manifest_pins_every_shard_it_places`; mutation 19/19 killed.
