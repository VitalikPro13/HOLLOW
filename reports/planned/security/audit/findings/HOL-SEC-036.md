# HOL-SEC-036: Anyone could befriend us with an accept, and a block missed half the DM surface

```
ID:          HOL-SEC-036                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact M-H: a stranger became an accepted friend without our
                                          consent, and a stranger's own request was accepted in our name, which
                                          puts them in our friend list and sends them our profile; a blocked
                                          person still edited, carded, deleted and reacted in our DMs, and a new
                                          device of a blocked person passed the block on a friend request;
                                          Exploitability H: one plaintext frame from anyone in a room with us,
                                          our inbox included)
Category:    Missing authorization (consent); incomplete block enforcement
Component:   rust/hollow_core/src/node/swarm.rs :: FriendAccept, FriendRequest, FriendListSync arms
             rust/hollow_core/src/node/social.rs :: friend_accept_msg, send_friend_accept,
             share_friend_with_siblings
             rust/hollow_core/src/node/message_ops.rs :: live_dm_change, dm_reaction_target_ok
             rust/hollow_core/src/node/types.rs :: HavenMessage::FriendAccept
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-10, C-11; candidates L1, L2, L3 (evidence dm:S-05, S-08, S-19)
Attacker:    P-02 stranger, P-04 blocked person
Found:       2026-09-26, phase B DM pass; confirmed by reading 2026-09-27
```

## Description

A `FriendAccept` was honoured with no friend row at all (unless a removal
tombstone existed), and on a pending incoming row it flipped the request to
accepted: the stranger sent a request and then its own accept. The row-less case
was allowed on purpose for two races (a sibling that had not heard of the
request, and a cold resolver), which left the door open.

On a friend request the block was checked before the carried device list bound a
never-seen device to its master, so a blocked person's new device passed it.
Edits, link cards, deletions and reactions of rows already in our DMs had no
block check at all.

## Reproduction

`authz_a_friend_accept_lands_only_on_a_request_we_sent` (node/test_harness.rs),
`authz_a_blocked_friend_changes_nothing_in_our_dms` (node/message_ops.rs tests),
the L2 guard in `authz_a_carried_list_attributes_only_a_bound_sender`
(node/crypto_handler.rs tests).

## Fix

- An accept lands only on our own pending outgoing row, or re-confirms an
  accepted one; no row, an incoming request, a decline or a removal are left as
  they are.
- The two races it used to cover are closed another way: an accept carries the
  accepter's signed device list (attribution no longer needs a warm resolver),
  and the device that sent the request shares the accepted friendship with its
  own siblings at once; a sibling's share settles a pending row there.
- The friend request arm checks the block again after the carried list binds.
- `live_dm_change` and `dm_reaction_target_ok` drop a blocked sender.

## Variants

- `FriendListSync` rides the plaintext sibling lane, which the relay can forge
  (A9, class A design).
- L6 (a captured KeyRequest can be replayed within the 300 s window, and one-time
  keys are minted without a cooldown) was tried and reverted: honest peers send
  several identical KeyRequests within one second, which a replay rule cannot
  tell apart. Accepted as AR-09 at the time; AR-09 is now CLOSED. The replay
  half is fixed by HOL-SEC-054 (sealed frames carry a nonce and the live-frame
  guard refuses a replayed KeyRequest), the minting half by HOL-SEC-111 (one
  key per requesting device from a bounded slot table, so a flood never pushes
  out a carried key).

## Test

Each test fails with its old rule put back and passes with the fix. The 123
friend, sibling and accept tests all pass, the race fixes of 2026-09-06 included.
Full suite green.
