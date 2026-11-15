# HOL-SEC-009: Anyone who knew a server's id could post into any of its channels, private and admin-only ones included

```
ID:          HOL-SEC-009                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact M-H: a post under the attacker's own name lands in a private, restricted
                                          or admin-only channel on every online member and on mobile through push, then
                                          spreads through members' own sync; Exploitability H: a stranger needs only the
                                          server id, which every invite link carries, and the relay can do the same)
Category:    Access control (authenticated but not authorised): the post's signature proves its author, never that
             the author may post there
Component:   rust/hollow_core/src/node/swarm.rs :: plaintext PublicChannel* arms, Olm ChannelMessage arm
             rust/hollow_core/src/node/message_ops.rs :: handle_envelope_channel_message, live_channel_moderation_drop
             rust/hollow_core/src/node/fetch.rs :: try_process_channel_msg (push path)
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   C-17, C-18, C-20; candidates C1, C4, C5, C13; authz rows A-CH01, A-CH10, A-CH11
Attacker:    P-03 stranger who knows the server id, P-01 with its own keys, P-05 member (posting and moderation rules)
Found:       2026-09-26, phase B channel and transport passes; confirmed by reading and test 2026-09-27
```

## Description

A public channel carries signed plaintext, so its frames reach whoever is in
the server's room. On receipt the node checked the signature and stored the
post, but never checked that the named channel was public in its own copy of
the server. A stranger who joined the room could sign a post with its own key
for any channel id, and every online member stored it; the push path did the
same for a sleeping phone. Edits, cards, deletions and reactions on the
plaintext arms had the same gap.

The other transports had gaps of their own. No receiver checked that the author
may post in the channel (admin-only channels were enforced only by the sender's
own client). The Olm fallback checked membership but skipped mute, slow mode and
media-only, and the push path checked nothing but the signature, so a muted
member could post by choosing the transport.

## Reproduction

`authz_public_frame_only_for_a_channel_public_here`,
`authz_live_post_needs_a_member_who_can_see_and_post` (crdt/server_state.rs
tests) and `authz_live_channel_post_is_judged_by_our_state`
(node/message_ops.rs tests).

## Fix

- A plaintext public-channel frame, on every arm and on the push path, is taken
  in only for a channel that is public in our own state
  (`message_ops::public_frame_accepted`); a node that holds no state for the
  server takes one only while viewing it as a guest.
- One post gate for every live transport, `live_channel_post_refusal`: a
  current member who can see and post in the channel, not muted, with a file
  where the channel is media-only; slow mode follows it. MLS, public and Olm all
  run the shared ingest (the Olm arm's copy is gone), and the push path applies
  the same gate against our stored state.
- Channel reactions in a server we hold come only from members.
- `channel_ingest_gates_stay_wired` fails if any receive path stops calling
  these gates.

## Variants

- MLS messages naming another server or a restricted channel: HOL-SEC-010.
- Sync backfill deliberately skips the live gate (history may predate a role or
  mute change); who may send a batch is checked (HOL-SEC-004, decision 2), and
  refusing posts whose author was never a member is candidate E4.
- Guests hold no member list, so a guest's preview of a public channel still
  shows any validly signed post; members, who store and re-serve history, now
  refuse it.
- The stored text clamp is 4,000 BYTES while the composer allows 4,000
  CHARACTERS, so the DM path and the push path cut long non-Latin messages and
  break their signature on re-serve (not a security flaw; reported separately,
  candidate C11 stays open for the storage bound).

## Test

The three tests above fail when the old rules are put back (no public check, no
member, visibility or posting check) and pass with the fix. Full suite green.
