# HOL-SEC-060: Any holder of a file could answer for it with other bytes

```
ID:          HOL-SEC-060                 Status: Fixed on local main (2026-09-28), retest at release
Severity:    High                        (Impact H: another person's attachment shown under their
                                          signed message with content they never sent; Exploitability
                                          M: a member holding a channel file's key, a holder asked for a
                                          re-pull, or the relay for a guest's public file)
Category:    Missing integrity binding
Component:   rust/hollow_core/src/node/file_handler.rs, swarm.rs, fetch.rs, vault_ops.rs,
             api/storage.rs :: every path that completes a file
Boundary:    TB-2 (peer <-> peer), TB-1 for guests
Traces to:   C-21, C-24; files inventory section 9 (H8 remainder, candidate A30)
Attacker:    P-05 / P-06 member or asked holder; P-01 relay for public-channel guests
Found:       2026-09-27, design A inventories
```

## Description

A message signature bound the file id and nothing about the file's content. The
only check on arriving bytes was AES-GCM under the key of whichever header was
accepted, which proves "someone who held a key" rather than "the author". A channel
member sharing the group key, any holder answering a re-pull under its own key, and
the relay answering a guest's public-file pull could each complete another
person's file with bytes of their choosing. File name and extension were unsigned
too, so a card could be renamed on the way.

## Reproduction

`authz_a_holder_cannot_substitute_a_files_bytes` (node/test_harness.rs).

## Fix

A file sent on 0.12 is named by its content: the id is SHA-256 over the author's
master id, the message id, size, the plaintext SHA-256, name, extension and the
vault video a thumbnail stands for (`node/file_commit.rs`). The message signature
already binds the id, so the author's one signature covers all of it, with no new
payload version and no downgrade: the 64-character id shape obliges every claim to
hash to it. The id also names its author, so no one else can announce a card for it
first. Every header, sync card, public card and guest card is checked against the id
before it writes a row; an unasked header must come from the author's own devices.
Every completion path (stream decrypt, inline image, push fetch, share download,
vault reconstruction) hashes the plaintext and refuses bytes that do not match
before `mark_file_complete`; a wiring test counts those paths.

Files sent before 0.12 carry 32-character random ids and keep the old delivery
gates (AR-13, accepted by Vitalik 2026-09-28).

## Test

Harness `authz_a_holder_cannot_substitute_a_files_bytes`; unit tests in
`node/file_commit.rs` (`a_committed_id_binds_every_field`,
`an_old_id_is_judged_by_the_delivery_gates_alone`,
`only_the_author_announces_its_file_unasked`, `a_card_completes_only_with_its_own_bytes`,
`a_share_download_is_hashed_in_slices`, `vault_bytes_answer_to_the_cards_they_stand_for`,
`every_completion_path_runs_the_gate`) and
`authz_a_synced_card_cannot_relabel_a_committed_file` (node/file_handler.rs). A scripted
mutation pass put each of nine rules back; every one failed its test.
