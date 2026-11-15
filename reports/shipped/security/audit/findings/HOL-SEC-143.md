# HOL-SEC-143: Whoever served history could make a signed message read as a shorter text its author never wrote

```
ID:          HOL-SEC-143                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: a member's or friend's signed message altered in other members' history; Exploitability M: a member answering a channel sync, or a friend serving DM sync, for a message whose text contains ':')
Category:    Crypto / Canonicalisation
Component:   rust/hollow_core/src/node/crypto_handler.rs (message_signing_payload_v2, SignedExtras::well_formed)
Boundary:    TB-2
Traces to:   phase E+F olm C-OLM-01; class 10
Attacker:    P-04 friend, P-05 member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The v2/v3 signing payload joins fields with ':' and keeps the text last, but only the album
was shape-checked, and a sync item's `lp_digest` was taken as sent, so a leading part of the
text could move into another field and the signature still verified.

## Fix

Signer and verifier both require every field before the text to be colon-free in its own
shape (ids `[A-Za-z0-9_-]{1,64}`, `lp_digest` 64 lowercase hex, album a UUID); the message-
proof FFI and the Dart proof checker use the same rule. Found on the way: synced edits never
applied because a nested transaction failed; fixed with a savepoint.

## Test

`a_text_chunk_moved_into_another_slot_never_verifies`,
`authz_a_synced_item_cannot_move_text_into_another_slot`,
`authz_a_dm_sync_item_cannot_move_text_into_another_slot`,
`the_signer_refuses_malformed_signed_slots`, `an_edit_inside_an_open_batch_applies`.
Mutation 35/35 with HOL-SEC-144, -145.
