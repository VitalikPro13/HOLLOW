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

Older erasure manifests carry no hashes: a failed rebuild deletes every participating copy (a genuine one we held for others too) and a bad holder cannot be named, so it can use up the three automatic pulls. The first manifest for a content id still wins (pre-existing), so a member who lands a manifest before the creator's sets the hashes. An unasked ShardStore registered first for a shard still makes the asked holder's stream drop until the person retries.

## Test

Harness `a_planted_vault_shard_is_dropped_and_the_real_one_pulled` (failed before: "a planted first copy blocked the download"), `a_holder_that_answers_with_a_wrong_shard_is_not_asked_again`; unit `a_shard_must_be_the_one_its_manifest_names`, `a_rebuild_deletes_the_copies_its_manifest_refutes`, `a_refuted_holder_is_skipped_and_fresh_pulls_are_capped`, `a_manifest_pins_every_shard_it_places`; mutation 19/19 killed.
