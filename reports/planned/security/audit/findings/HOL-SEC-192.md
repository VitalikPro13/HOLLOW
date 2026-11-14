# HOL-SEC-192: A stranger's friend requests and join asks were kept without a bound

```
ID:          HOL-SEC-192                 Status: Fixed on local branch security/0.14
                                          (track t14-flood, 2026-11-04), retest at release
Severity:    Medium                      (Impact M: unbounded growth of the friends table,
                                          the roster book, settings rows and the card store,
                                          a request list full of junk, and a pending row that
                                          lets that identity's later roster notices through;
                                          Exploitability H: identities are free, a request
                                          needs only our master id, a join ask only an
                                          invite link, a public one included)
Category:    Resource exhaustion / Unbounded state from a stranger
Component:   rust/hollow_core/src/node/swarm.rs (FriendRequest, FriendAccept, FriendReject
             and ServerJoinRequest arms), social.rs (incoming_request_has_room,
             answer_meets_our_row), join_verdict.rs and join_stash.rs (new)
Boundary:    TB-1, TB-2
Traces to:   track I (t14-ident) review of A/B; shipped in 0.13
Attacker:    P-03 stranger (any identity that knows our master id or holds an invite link)
Found:       2026-11-04 (hostile review of track I, probe on main 8350841b)
Affected:    unbounded pending incoming requests in every release through 0.13.0; the
             roster, card and key-bundle writes since 0.12.0
Fix commit:  d42cad43 (security/0.14, 2026-11-05)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

An incoming friend request stored the requester's roster (a first sight in our roster
book), its carried key bundle (a settings row), its sealed card and a pending incoming row
before any bound; only outgoing requests were capped. A friend accept or decline that met
no request of ours still stored its roster before being dropped. A join ask, sealed to the
server's door and invite key, stored the asker's roster and card before any gate but
"server known", on every member that opened it, the ones that left the join to the
coordinator included. A stranger minting identities grew each of those stores without
limit; the reviewer's probe left 48 pending rows and 48 rosters from 48 minted identities.

## Fix

The bound runs before anything is written, the roster first. A new incoming request needs
room in the pending incoming requests: 64 in all, of which requesters who share no server
with us hold at most 32, so a stranger flood never crowds out a co-member; a full share
refuses the newcomer (every requester weighs one row; the relay mailbox hands the request
back on our next inbox join). A requester we already hold a row for passes, except a new
request past our decline; a removal deletes the row on both sides once delivered, so a
re-add after one is a new request. An accept or decline keeps nothing unless it meets our
pending outgoing request or a friendship, looked up under the claimed master, the sending
device and each device whose own consent to that master the roster carries (a request
sent while our resolver was cold is filed under the device we asked). A join ask is
attributed without a write
(`roster_book::carried_member`) and keeps the asker's roster and card only when the shared
verdict (`join_verdict::verdict`: ban, private, full, Twitch, owner-verify, consent, the
same function the answer uses) would admit it and, for a newcomer, its own ask verifies.
A banned asker's own signed ask also keeps, so the members see who was refused; the ban
list bounds those. An ask still waiting for Twitch or adult-content consent keeps nothing.
Only a member that answers writes: every member reading a parked ask, and for a live ask
the one member elected to answer (or any member when the asker is already a member). A
member that steps aside holds the roster and card in RAM (`join_stash`: bounded per ask,
in count and in bytes, the server the ask came through as the share, gone after ten
minutes) and lands them only once the asker's admission has folded into its own state,
so it still places an admitted joiner for the MLS add and an ask nobody admits leaves
nothing. On a public server the member cap is the bound.

## Residual risk

A flood of up to 32 junk requests fills the strangers' share until the person declines or
blocks them; an honest stranger's request waits in the relay mailbox meanwhile. Minted
identities that join a public server become co-members and may use the rest of the total
(bounded by the member cap), so they can fill all 64: co-members are not strangers. A
sustained stranger flood refills each slot of the strangers' share as soon as the person
declines or blocks one, so an honest stranger's request may keep waiting in the relay
mailbox for as long as the flood lasts. A flood through one server's invite can push an
honest joiner's held ask out of that server's share of the join stash; that member then
places the joiner later, once the joiner's roster reaches it another way. Follow-up (not
built): an optional "N requests were dropped" hint in the requests list. The
`ProfileCard` and `ProfileUpdate` arms also ingest a
roster before any relationship check; that is HOL-SEC-193, not changed here.

## Test

Harness `review_ab_incoming_friend_requests_from_minted_identities_stay_bounded` (the
first review's probe), `t14f_review_live_asks_a_member_steps_aside_from_keep_nothing_until_admitted`
(the second review's probe: live asks addressed to a member that is not the coordinator),
`t14f_a_co_members_request_lands_past_a_stranger_flood`,
`t14f_a_strangers_accept_or_decline_keeps_no_roster`, `a_join_ask_flood_keeps_no_roster_rows`,
`t14f_a_public_server_keeps_rosters_only_for_the_joiners_it_admits`,
`t14f_a_member_who_did_not_answer_still_places_the_joiner`, `join_lock_the_card_rides_inside_the_request`,
`a_joiner_shows_its_card_to_the_members_it_asks`; units
`social::tests::t14f_incoming_requests_hold_a_total_and_a_stranger_share`,
`social::tests::t14f_an_answer_from_another_device_meets_a_request_filed_under_the_first`,
`join_stash::tests::t14f_a_held_ask_lands_only_once_admitted`,
`join_stash::tests::t14f_a_held_ask_weighs_at_most_its_entry_cap`,
`join_stash::tests::t14f_a_flood_through_one_server_keeps_the_others_asks`.
