# HOL-SEC-095: A guest stored public posts unjudged and showed names any member chose

```
ID:          HOL-SEC-095                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: rows written into a guest's database that
                                          outlived the preview, and a post shown under a name
                                          the answering member picked; Exploitability M: any
                                          member, or any device in a legacy server's room)
Category:    Integrity / Spoofing
Component:   rust/hollow_core/src/node/guest_view.rs (new), node/swarm.rs (public frame arms,
             guest sync answer), node/profile_card.rs :: cards_for_guest, guest_sender,
             keep_card; storage :: signed_cards, guest_store_path
Boundary:    TB-4 (server members to a non-member)
Traces to:   C-16; decision D6 (2026-10-02); phase B re-check channel A-CH10, A-CH15 (S17)
Attacker:    P-05 member, or a device in a legacy server's room
Found:       2026-09-26 (phase B), confirmed 2026-10-02
```

## Description

A guest browsing a server's public channels ran each live post through the member ingest
with no server state, so no member or posting rule applied, and the post was written to
its database. The rows stayed after the guest left and were served on if it later
joined. Separately, the member answering a guest's history request named each post's
author with whatever display name and avatar it chose, and the guest showed them.

## Fix

A guest's posts live in a store held in memory only for as long as it browses
(`guest_view`): edits, deletes and reactions still apply to them, nothing reaches the
guest's database, and leaving a room forgets its posts. A guest shows an author only by
the author's own master-signed card, with an avatar only when its bytes hash to the
card's; anything else shows no name. Members keep each co-member's card from its profile
updates, which now carry it, and hand those cards to guests within an avatar budget.

## Variants

- The server name, avatar, banner and channel list a guest sees still come from whichever
  member answers, unauthenticated (accepted, AR-17).
- A guest no longer sees server nicknames: they are server state a guest cannot check.

## Test

Unit `a_guest_store_lives_in_memory_only_while_held`,
`authz_a_guest_shows_only_what_the_senders_card_signs`,
`a_member_hands_a_guest_only_signed_cards`; harness
`authz_a_guest_keeps_public_posts_in_memory_only` (failed before the fix: "a guest stored
a public post") and `authz_a_guest_shows_an_author_only_by_its_own_card`; mutation pass
in the session notes.
