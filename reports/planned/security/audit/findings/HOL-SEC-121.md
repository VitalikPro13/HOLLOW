# HOL-SEC-121: A member back from away answered a removed joiner's old parked ask

```
ID:          HOL-SEC-121                 Status: OPEN (found 2026-10-03, fix designed, not built)
Severity:    Low                         (Impact L: a removed joiner briefly re-admitted on one
                                          stale member, which seals it a snapshot older than its
                                          removal and tells it the member is online;
                                          Exploitability L: happens on its own, nobody chooses
                                          the stale member)
Category:    Authorisation / Server joins
Component:   rust/hollow_core/src/node/swarm.rs (the `~join` ring catch-up and the parked-ask
             arm), node/sync_handler.rs (join resolution), MLS parked KeyPackage seating
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

## Fix (designed, not built)

Hold a parked ask read from a ring catch-up until that catch-up and the first sync with a
member who sees the room have landed, then judge it again (`join_resolutions`, the
joiner's `left_at`, its membership spans); seat a parked ask's KeyPackage only once its
admission survived that sync. Alternative: the relay marks the end of a catch-up.

## Test

Harness `authz_a_member_back_from_away_gives_a_kicked_joiners_old_ask_nothing`, marked
`#[ignore]` until the fix lands (RED: `a member back from away answered a kicked joiner's
old ask: ["join_sealed", "key_request"]`).
