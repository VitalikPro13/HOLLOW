# HOL-SEC-144: One friend request let a stranger watch our devices come and go, and blocking did not stop queued DMs

```
ID:          HOL-SEC-144                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: presence of every device, after a decline too; Exploitability H: any identity that can send a request)
Category:    Data exposure / Metadata
Component:   rust/hollow_core/src/node/social.rs (holds_dm_room), swarm.rs, message_ops.rs (take_queued)
Boundary:    TB-1, TB-2
Traces to:   phase E+F olm C-OLM-02; class 13; same exposure HOL-SEC-064 fixed for the inbox
Attacker:    P-03 stranger
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The target joined the DM room as soon as any request arrived and rejoined it on every
connect for every friend row, declined ones included; the relay shows a DM room's presence
to everyone in it. Separately, a block did not cancel DMs still in the resend queue, which
went out when the blocked person next connected.

## Fix

A DM room is joined only for an accepted, unblocked friend or our own pending outgoing
request, and left on decline, cancel, removal and block (rejoined on unblock); the card a
requester sees before an accept rides a sealed mailbox `FriendCard`; a block drops queued
DMs to that identity.

## Residual risk

Copies the relay already parked before a block still replay on the friend's next join (needs
a relay-side purge). Avatar bytes on pending requests now arrive only after an accept.

## Test

`authz_a_friend_request_never_shows_the_stranger_our_devices`,
`authz_a_block_takes_our_devices_out_of_the_friends_dm_room`,
`authz_a_cancelled_request_leaves_its_dm_room`,
`authz_a_removal_takes_both_sides_out_of_the_dm_room`,
`authz_a_block_drops_dms_still_queued_for_the_blocked_friend`.

Found while proving it: a friend request reached only the target devices the requester
could see at that moment (a mailbox copy went out only when it saw none), so a device out
of view never heard it; the new DM-room rule made that subset smaller and a re-add test
flaky. Every request now also goes to the target's inbox (a device that took the live copy
drops the second as a duplicate), and a removal heard from a sibling leaves the DM room
too. Tests `a_friend_request_reaches_the_target_devices_the_requester_cannot_see` (failed
before), `authz_a_removal_reaches_an_online_sibling_and_never_undoes_a_readd` (20/20 in a
loop, was 2 of 6 failing). Mutation 2/2.
