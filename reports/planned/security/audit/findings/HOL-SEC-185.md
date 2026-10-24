# HOL-SEC-185: Opening a channel asked every member device for its history, and each page cost grew with the history

```
ID:          HOL-SEC-185                 Status: Fixed (2026-10-23, wave g13, local commit 2db3c39a),
                                          ships with 0.13
Severity:    Low                         (Impact M: a joiner pulled 2.3 to 3 full copies of a channel's
                                          history, and serving one page of a 100,000-message channel took a
                                          member's event loop about 0.86 s; Exploitability L: needs a long
                                          channel history; any member can ask for pages)
Category:    Uncontrolled resource consumption
Component:   rust/hollow_core/src/node/channel_asks.rs (new), storage/messages.rs (per-sender page
             query), node/sync_handler.rs
Boundary:    TB-2 (peer <-> peer)
Traces to:   AS-11 (availability)
Attacker:    none needed; P-05 member asking for pages
Found:       2026-10-23 (wave g13, storage measurement track)
```

## Description

Opening a channel asked every online device of every member, and each answered with its own
full copy of the history, so a joiner that opened a channel during its first sync took 2.3
to 3 copies. The per-sender page query scanned and sorted the whole channel for every page,
so serving a long history cost roughly its square (0.86 s per page at 100,000 messages from
100 authors). Present in released versions.

## Fix

A channel ask goes to one entitled holder at a time. Only pages that holder was asked for
count, each must end past the last, a holder keeps an ask at most ten minutes, and twenty
seconds of silence hands it on. The first holder differs per process and channel, longest
standing members first, so no member makes itself everyone's source. The page query seeks
per sender on the existing index and stops at the page limit; pages are identical. At
100,000 messages a join takes 55 MB of relay traffic instead of 125 MB, and a page costs
under a millisecond at any depth.

## Residual risk

Three follow-ups are not fixed. A page should be verified before it counts as progress (a
forged-timestamp page can keep an ask for its ten minutes), legacy members need a tier
order, and more than 200 rows in one millisecond need a tie-break cursor.

## Test

Harness `g13w3_opening_a_channel_while_joining_takes_one_copy_of_its_history`,
`g13w3_a_silent_channel_holder_hands_the_ask_to_the_next`,
`g13w3_pages_nobody_asked_for_never_keep_a_channel_ask`; units in node/channel_asks.rs
(`pages_nobody_asked_for_never_keep_an_ask` and others),
`per_sender_pages_serve_exactly_what_the_old_query_served` and
`a_channel_page_costs_the_same_however_long_the_history` (storage/messages.rs). Mutation
passes 22/24 and 21/21 in the fix round.
