# HOL-SEC-046: A joiner took its whole server state, owner included, from whoever answered

```
ID:          HOL-SEC-046                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: the joiner's persisted view of the server named the
                                          attacker as Owner, so every later honest op from the real owner
                                          and admins was refused there and the attacker's were admitted;
                                          the joiner then served that view to later joiners. Exploitability M:
                                          any member of the server, or the relay, while a join is pending)
Category:    Missing trust anchor
Component:   rust/hollow_core/src/crdt/anchor.rs :: derive_server_id, is_genesis_id
             rust/hollow_core/src/crdt/server_state.rs :: found, op_allowed (founding, checkpoint)
             rust/hollow_core/src/crdt/fold.rs :: accept_join_snapshot, ingest_remote
             rust/hollow_core/src/node/swarm.rs :: ServerStateSnapshot, SyncResponse
             lib/src/ui/chat/hollow_link_utils.dart :: webServerInviteLink, classifyHollowLink
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-15, C-25; candidates E1, E2 (evidence crdt:S1, crdt:S2)
Attacker:    P-01 relay, P-05 member with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

While a join was pending, a `ServerStateSnapshot` from any sender was adopted
whole: owner, roles, members, bans and settings. Nothing tied it to the server's
real owner, because the joiner had nothing to tie it to. Without a snapshot, the
joiner started from an ownerless skeleton and the first founding op naming its
own signer became the owner.

## Reproduction

`authz_a_joiner_takes_its_state_only_from_the_servers_anchor`
(node/test_harness.rs), `authz_a_self_certifying_server_is_founded_only_by_its_key`
and `authz_a_join_snapshot_needs_the_pinned_owner` (crdt/fold.rs tests).

## Fix

- A server founded on 0.12 or later gets a self-certifying id: the first 40 hex
  characters of `SHA-256("hollow-server1:{owner}:{nonce}")`, the nonce riding the
  founding op. Only the key that hashes to the id can found it, and the id's
  length tells a joiner which rule applies, so leaving the founding op out cannot
  downgrade it. Such a joiner ignores snapshots and builds its state from the
  signed ops alone; its join completes only once the fold admitted it.
- An existing server is moved onto a checkpoint its owner signs (HOL-SEC-047).
  Invite links to one carry the owner's id (`owner=`), and a joiner with that pin
  accepts only a snapshot, founding op or checkpoint naming the pinned owner.
- The owner is fixed once anchored (decision 1), so the pin never goes stale.

## Variants

- An existing server whose owner never runs 0.12, or a join through an old link
  without `owner=`, stays trust on first use (residual R1, accepted-risk proposal).
- The `ServerJoinResolved` and plaintext join frames themselves are class A.

## Test

Each test fails with its old rule put back (scripted mutation) and passes with
the fix. Full suite green.
