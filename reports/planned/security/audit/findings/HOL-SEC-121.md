# HOL-SEC-121: A member back from away answered a removed joiner's old parked ask

```
ID:          HOL-SEC-121                 Status: FIXED (session 33, 2026-10-03), retest at
                                          release; the relay's end mark deploys with it
Severity:    Low                         (Impact L: a removed joiner briefly re-admitted on one
                                          stale member, which seals it a snapshot older than its
                                          removal and tells it the member is online;
                                          Exploitability L: happens on its own, nobody chooses
                                          the stale member)
Category:    Authorisation / Server joins
Component:   rust/hollow_core/src/node/swarm.rs (the `~join` ring catch-up and the parked-ask
             arm), node/join_hold.rs (new), node/ws_client.rs (`topic_catchup` end mark),
             relay-uws/src/ws_handler.cpp (handle_topic_catchup), MLS parked KeyPackage seating
Boundary:    TB-3 (server members)
Traces to:   session 31 follow-up e ("snapshot + 7 ops" seen after a kick), HOL-SEC-092
Attacker:    none needed; a joiner removed after its admission benefits
Found:       2026-10-03 (follow-up e)
```

## Description

On connect a member reads the server's join ring before its first sync, and the relay
replays the ring oldest first with no end marker, so a parked ask arrives before the
verdict that answered it. A member that was away through both the joiner's admission
and its kick or ban holds no record of either, so the old ask looks fresh: it authors a
`MemberAdded` on the already-used ask, seals its snapshot and op log to the joiner's
reply key, publishes an "admitted" verdict, sends the joiner a KeyRequest, and at the
next batch tick commits the parked KeyPackage into its own stale MLS group. Every other
member's fold refuses that admission (HOL-SEC-092's span rule), the stale member drops
the joiner once its own sync lands, and its commit sits on an epoch the others refuse.
It still breaks "an ask that admitted once gets nothing" and "a banned identity's ask
gets nothing", for as long as the parked copy stays in the ring (3 days).

An owner that re-reads the ring after a reboot gives the old ask nothing (checked:
`authz_a_removed_joiners_parked_ask_read_back_gets_nothing`).

## Fix

A member holds a join ask and later sends it through the same handler, with its sender
and seal time (`node/join_hold.rs`). A parked ask read while the member's own join-ring
replay runs waits for the replay's end, which the relay now marks when asked
(`topic_catchup` with `end`, answered by `topic_catchup_done` behind the last replayed
frame); on a server the member held while it had no socket (at start, or since its last
one died), any ask, parked or live, also waits until a member other than the asker has
answered a sync ask of this connection, unless no such member is in the room. The ask
carries a nonce the answer echoes, so an answer the relay kept from before the member
went away does not count, and a member that asks is answered even when it misses
nothing. Nothing waits longer than 10 s after the relay shows the member the room, and a
parked ask's KeyPackage is queued only by the re-judgment. While the relay does not show
a member the room of such a server (its door is behind: a kick or ban moved the lock
while it was away, or while it missed the move), the member answers no ask for that
server at all. Only a direct reaches a hidden socket and no honest joiner addresses a
member it cannot see, so these asks are dropped rather than held; losing the room
mid-connection drops what waits and makes the server stale again.

## Variants

- A live ask: a member back from away that wins the join election, with the owner
  offline, admitted a banned identity's fresh live ask on state from before the ban (a
  modified client that sealed it to the door it held before the ban, which the stale
  member still opens). The same hold covers it
  (`authz_a_member_back_from_away_admits_no_banned_identitys_live_ask`). The cost is join
  latency: an ask reaching a member in the first seconds after its socket came up waits
  for that member's first sync, at most 10 s.
- An ask that admitted a joiner still in the server: a member back alone gave it a
  second admission. The ring's verdict now counts first
  (`authz_a_member_back_alone_gives_an_answered_ask_nothing`).
- A direct ask to a member the relay hides: a removed member's modified client sends its
  ask, sealed to the door from before its removal, straight to the device of a member
  back from away (or one that missed the lock move), which judged it at once on state
  from before the removal (`authz_a_member_back_hidden_answers_no_direct_ask`,
  `authz_a_member_that_loses_the_room_answers_no_direct_ask`).

## Residual risk

- A member with no other member in the room judges with what the ring gave it. A kick or
  ban moves the join lock, so such a member is hidden from the room and reads no ring
  until a member lets it back in; what is left is a verdict the ring lost while nobody
  was around, which gives an ask that admitted a joiner still in the server a second
  admission every other fold refuses (HOL-SEC-092).
- After the 10 s wait an ask is judged on what the member holds then (a sync slower than
  that, or a relay from before the end mark, which costs every parked ask the full wait).
  The member logs it.
- Another member can answer the sync without the removal; insiders are out of scope.
- More than 200 held asks per server, and asks held when the socket dies, are dropped;
  the next ring read brings them back.
- An ask that reaches a hidden member directly is dropped whoever sent it; an honest
  joiner never addresses one, and its retry or parked copy reaches the members it sees.
- A banned identity's new ask still gets the "banned" refusal, as from any member: it
  tells the identity only what its removal already did, and a parked join's tile needs
  the reason. An ask that admitted once gets nothing at all.

## Test

Harness, RED before the fix (every ask judged on arrival):
`authz_a_member_back_from_away_gives_a_kicked_joiners_old_ask_nothing` ("a member back
from away answered a kicked joiner's old ask: ["key_request", "join_sealed"]"),
`authz_a_member_back_from_away_learns_a_kick_from_its_sync_alone` (the ring lost the
verdict, the member restarted while away),
`authz_a_member_back_from_away_gives_a_banned_joiners_old_ask_nothing`,
`authz_a_member_restarted_while_away_learns_an_admission_from_its_sync` (no lock move, so
the member is shown the room at once; its sync alone shows the joiner already in),
`authz_a_member_back_alone_gives_an_answered_ask_nothing`,
`authz_a_member_back_from_away_admits_no_banned_identitys_live_ask`,
`authz_a_member_back_hidden_answers_no_direct_ask` ("a member back hidden answered a
kicked joiner's direct ask: ["join_sealed", "key_request"]"; then, with the door and the
sync, a third joiner's honest parked ask is still admitted by that member),
`authz_a_member_that_loses_the_room_answers_no_direct_ask` ("a member the relay hides
answered a kicked member's direct ask: ["join_sealed"]"); still working:
`parked_join_read_beside_a_present_member_is_admitted_once` (released by the sync, well
inside the wait), `parked_join_is_judged_when_the_relay_never_marks_the_rings_end`,
`sync_answers_a_member_that_misses_nothing`. Unit `join_hold::tests` (7, among them
`only_a_members_answer_to_an_ask_of_this_connection_counts`: a first build counted any
answer, and under a parallel run the banned test caught an answer the relay had kept
from before the member went away) and
`ws_client::tests::a_catchup_asks_for_its_end_mark_only_when_told`. Relay live checks
`test_catchup_end_mark` (7, `relay-uws/test/test_relay_live.cpp`). Mutation: Rust 35/35,
relay 5/5 killed (`tmp_s33_join_mutate.py`, `tmp_s33_join_relay_mutate.py`).
