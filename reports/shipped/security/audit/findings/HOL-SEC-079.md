# HOL-SEC-079: Statements from anyone could push a removal or a vouch out of a roster

```
ID:          HOL-SEC-079                 Status: Fixed on local main (2026-10-02), retest at release
Severity:    High                        (Impact H: a removed device counts again at every contact
                                          that takes the roster, or a linked device stops counting;
                                          Exploitability H: one roster notice from anyone who shares
                                          a room with the victim's contacts, no key of the victim's)
Category:    Authorization / Identity
Component:   rust/hollow_core/src/identity/roster.rs (compacted, verified)
Boundary:    TB-2 (peer and peer), TB-3 (own identity and its devices)
Traces to:   C-01, C-04; HOL-SEC-077 (design ID-1)
Attacker:    P-03 (stranger who knows an id), P-05 (server member), P-08
Found:       2026-10-02 (session 25, while mirroring the fold on the relay for ID-1R)
```

## Description

A roster keeps vouches and removals up to a ceiling per kind, and kept the first ones in
statement order when there were more. Verification checked each statement's signature
but not whether its signer stood anywhere in the roster, so a statement signed by any key
at all survived until the ceiling cut. Since a roster is folded from whatever its carrier
sends, and a roster notice is accepted from any sender, statements ordered ahead of a real
removal or a real vouch pushed it past the ceiling: a removed device became a member again
wherever the roster landed, or a linked device stopped being one.

## Fix

Compaction ranks every device with an admission path in the current base (the phrase's
roots first, then devices growing from pending joins, each by its distance in vouches from
a root) and keeps a vouch or a removal only when its signer has standing. What stays is
ordered by its signer's rank before the ceilings cut, so a flood pushes out only what sits
as deep as its signer or deeper, and each standing device's best vouch is kept first, so
compacting is stable. The ceilings fit the largest roster under the 256 KiB wire limit
(about 198 KB at worst). The relay mirrors the same rules.

## Test

Units `authz_a_strangers_flood_pushes_no_statement_out`,
`authz_a_members_flood_never_displaces_a_signer_closer_to_the_phrase`,
`authz_signer_rank_decides_what_a_full_roster_keeps`,
`a_deep_device_keeps_its_only_vouch_in_a_full_roster`,
`authz_pending_joins_never_displace_the_phrases_devices`, `compaction_is_stable`,
`the_largest_roster_fits_on_the_wire`, `roster_vectors_are_current`; mutation pass
(`tmp_id1r_mutate.py`).

## Residual

A member that is not removed can still flood its own base and push out devices deeper than
itself, which it could also simply remove; the recovery phrase ends it, since a new base
gives that member no standing (AR-15).
