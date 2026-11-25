# HOL-SEC-211: A member on another relay could grow an island of the server the owner never sees

```
ID:          HOL-SEC-211                 Status: Fixed in 0.14.2
Severity:    Medium                      (Impact M: people the owner never admitted and
                                          cannot see or remove read and post in a copy of
                                          the server with real members, and their admission
                                          lands in the owner's own copy once the member
                                          returns; Exploitability M: any member who switches
                                          relays and a relay that takes the server's lock,
                                          which any socket can arrange by showing the
                                          owner's roster, or a relay of the member's own)
Category:    Authorization / Missing binding
Component:   rust/hollow_core/src/node/home_relay.rs (new),
             rust/hollow_core/src/node/relay_denial.rs (the Elsewhere mark),
             rust/hollow_core/src/crdt/server_state.rs (op_allowed, home_relay),
             rust/hollow_core/src/node/sync_handler.rs (author_home_relays),
             rust/hollow_core/src/node/swarm.rs (load, loop turn, join completion)
Boundary:    TB-2 (other members of a server), TB-3 (the relay)
Traces to:   GitHub issue #151; MULTI_RELAY_CLIENT_PLAN.md section 2 ("a server lives on
             one relay") and section 13; CLAUDE.md "server joins = the JOIN LOCK"
Attacker:    a member of the server, with a stock client, on a relay of their choosing
Found:       2026-11-20 (issue #151, proven in the harness before the fix)
Affected:    every release with the join lock (0.12 to 0.14.1)
Fix commit:  f0b54bf3a
Disclosure:  published with 0.14.2
```

## Description

Nothing bound a server to a relay. A member who switched relays kept the server, and its
lock keeper put the server's join lock on the new relay as it does on a relay that forgot
it. The relay takes a lock put only from devices its fold of the owner's roster counts,
but any socket may show it that roster (every co-member holds it), and a relay the member
runs need not check at all. With the lock there, an invite the member made (stamped with
the new relay) let a stranger seal its ask; the member admitted it, seated it in MLS as
the standing leader on that relay, and the two talked. The owner, on the server's real
relay, saw none of it: its kick of the stranger never reached the other relay, and when
the member came back, its signed admission folded into the owner's state like any other.

Harness proof before the fix: `i151_a_server_with_no_home_relay_behaves_as_before` (now
the legacy case: the lock goes up on relay B, S is admitted by M, seated in MLS, messages
flow both ways, M's admission lands in the owner's fold on return, the owner's kick never
reaches B).

## Fix

A server names its home relay in an owner-signed op: the existing `ServerSettingChanged`
with the key `home_relay` (`HOME_RELAY_KEY`), LWW by HLC like every setting, judged by
`op_allowed` as owner only and only in the one canonical form (`home_relay::canonical`:
lowercase host, `:port` only when not 443; Dart's `normalizeRelayHost` agrees on shared
vectors). A setting rather than a new `CrdtPayload` variant, so a 0.14.1 replica folds it
as an ordinary setting and no older client meets an op it cannot read.

- `ServerState::home_relay()` counts the register only when the anchor owner's own op
  wrote it (`reg.hlc().actor == anchor_owner`). A 0.14.1 owner folds an admin's
  `home_relay` as an ordinary MANAGE_SERVER setting and its checkpoint carries it, and a
  legacy join snapshot is unsigned; either reads as no home, so the owner names it again
  (review finding, tests `review_a_0141_owner_checkpoint_carries_no_admin_home_relay`,
  `a_snapshots_home_relay_counts_only_from_the_owner`).
- The home is set once: a new server names its owner's relay at creation; an older one
  gets it from its owner's lowest caught-up, on-screen device the first time it runs
  0.14.2 (the same gate as a missing join key, `sets_missing_join_key`). Nothing in
  0.14.2 changes it: when the owner switches relays, their servers stay where they live
  and the owner is told so before switching. A safe move needs a client that keeps a
  listening presence on the old relay (members there must hear the move, and members
  offline at the move must learn it before serving), which is the multi-relay client's
  work (MULTI_RELAY_CLIENT_PLAN.md section 13, with the acceptance tests the review
  wrote).
- A device whose relay is not the server's home marks the server `Elsewhere` in the
  denylist's gate (`relay_denial::Denials`), at load before any join, on every loop turn,
  and for a joiner at the moment its join answer is folded (`home_relay::settle`). From
  then on nothing scoped to the server leaves through that relay (the sealing stage's
  `Denials::pass`): no room join, no lock put or read, no join answer, no Welcome or
  KeyPackage, no commit (the group is frozen), no ring write, no file served (the
  `FileRequest` arm's `relay_denial::denied`). The node emits `ServerElsewhere { relay,
  owned }` whenever the relay a server lives on changes, and Dart shows the server
  read-only with one notice and the existing relay switch dialog.
- Invites stamp the server's home relay (`server_home_relay` FFI in `serverInviteLinkFor`),
  wherever the inviter is connected.
- Checked and needing no gate: the push fetch node joins only its own inbox and sends
  only kill-order acks; an open WebRTC data channel serves a file only through the same
  `FileRequest` arm.

## What remains

A member with a modified client, or one still on 0.14.1, can still admit people on
another relay, and can leave the home relay op out of what it hands a joiner (the joiner
learns the home only from the answer, so nothing pre-join is trustworthy: the invite's
relay is the inviter's word). Those admissions reach the owner's copy when that member
returns and are judged by the fold as any member's admission is; the owner's answer is to
remove them. The relay is not a defence here: an attacker's own relay skips any check.

Reproduction: harness `i151_a_member_on_another_relay_serves_nothing_for_the_server`,
`i151_a_joiner_answered_on_another_relay_stops_at_the_home_it_learns`,
`i151_only_the_owner_names_the_home_relay`,
`i151_the_owner_names_a_missing_home_and_servers_follow_the_owner`; unit
`op_allowed_ingest_matrix` (home relay rows), `home_relay::tests::one_form_for_every_spelling_of_a_relay`.
