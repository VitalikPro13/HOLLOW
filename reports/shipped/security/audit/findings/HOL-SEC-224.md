# HOL-SEC-224: a variant at an endorsed op's key read as endorsed

```
ID:          HOL-SEC-224                 Status: Open, fix planned for 0.14.3
                                          (track phrase-restore)
Severity:    Low                         (Impact L: one op a retire kept for a removed
                                          device drops out of the server's history;
                                          Exploitability L: needs the removed device's
                                          key and its identity's master key)
Category:    Authority of replicated state
Component:   rust/hollow_core/src/crdt/verdict.rs (ServerState::is_endorsed)
Boundary:    TB-3 (server members and their replicated state)
Traces to:   DEVICE_PROOF_DESIGN 8.2, 8.3; R-CR-07
Found:       2026-11-22 (phrase-restore, while fixing HOL-SEC-222)
Affected:    0.14.0 to 0.14.2 (the device proof track)
Fix commit:  pending (feat/phrase-restore)
Disclosure:  private until 0.14.3 ships
```

## Description

A retire from a counted device names each op of a removed device it keeps by author,
clock and content id; an op it names reads `Counted`. The check compared the retire's
content id against `content_of(op)`, which returns the id of the op HELD at that author
and clock, not the id of the op being judged. Where the dedup ranks two variants at one
key, it judged an incoming variant proven by the same removed device as endorsed, so a
variant with a lower content id took the endorsed op's place. Once held, the variant no
longer matched the retire and parked, so the key folded nothing and the op the retire
kept was gone from the history.

## Fix

`is_endorsed` compares the retire's content id with the judged op's own
`content_hash()`. For an op that is held both values are equal, so nothing else changes;
a variant now reads as its own proof says (uncounted for a removed device) and never
outranks the endorsed op.

Test: unit `crdt::verdict::tests::a_variant_at_an_endorsed_ops_key_is_not_endorsed` (the
removed phone signs a variant of the op a retire kept, with a lower content id and a
proof that verifies in its lane; the endorsed op keeps its key, the nickname it set
stays, and the variant does not read `Counted`). Without the fix the key folds nothing.

## Related call sites (sweep)

Every `content_of` caller was checked for the same mix-up: the value is right only for an
op held at its key. All callers pass held ops except two, reported for a follow-up:
`ServerState::floor_pick` (crdt/fold.rs) applies it to the peers' answered floor bases,
and the floor mark in `hold.rs` (`close_round`, `mark_after_restart`) applies it to a
recorded `base_op` that may no longer be held. Both should use `content_hash()`.
