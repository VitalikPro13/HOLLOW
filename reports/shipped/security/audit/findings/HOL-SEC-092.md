# HOL-SEC-092: Any member could list anyone as a member of a server

```
ID:          HOL-SEC-092                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: an identity that never asked showed as a
                                          member on every replica, a false association that
                                          also counted against the member cap; Exploitability
                                          M: plain membership and a modified client)
Category:    Missing authorization
Component:   rust/hollow_core/src/crdt/operations.rs :: JoinAsk, CrdtPayload::MemberAdded (ask)
             rust/hollow_core/src/crdt/server_state.rs :: admission_allowed, MemberSpan.asked_at
             rust/hollow_core/src/node/swarm.rs :: ServerJoinRequest (admitter)
             rust/hollow_core/src/node/sync_handler.rs :: handle_join_server, reask_join
Boundary:    TB-4 (server members)
Traces to:   C-15; decision D3 (2026-10-02); phase B re-check server_mls A-01 (PARTIAL)
Attacker:    P-05 member with a modified client
Found:       2026-10-02 (phase B re-check)
```

## Description

`MemberAdded` named its target by id alone. Since HOL-SEC-049 every member re-checks
the join gates on it (ban, private, cap, owner-verify, Twitch), but nothing showed that
the named identity had ever asked to join. A member could list any master id it knew,
and every replica showed that identity as a member of the server.

## Fix

The joiner signs an ask with its master key (`hollow-join-ask1`, the server id, its own
id and the request's `requested_at`), every copy of the request carries it, and the
admitting member copies it into the `MemberAdded` op it authors. Every member refuses a
`MemberAdded` whose ask is missing, is not signed by the target's own key, or names
another server. Each ask admits once: the membership record keeps the `at` of the ask
that opened each span, and a later admission needs a newer ask, so an ask replayed after
the joiner left brings nobody back.

## Variants

- An ask the joiner made but that never admitted it (a request it abandoned, or a second
  ask newer than the one that did) can still admit it later, as an honest member serving
  the parked ring copy would.
- Ops authored before this change carry no ask. Anchored servers from 0.12 development
  builds refuse those admissions on their next rebuild; released servers move onto the
  owner's checkpoint, which carries the membership as it stands.

## Test

Unit `authz_member_added_names_only_someone_who_asked` and harness
`authz_a_member_lists_only_someone_who_asked_to_join` (failed before the fix: "O listed
someone who never asked"); mutation pass in the session notes.
