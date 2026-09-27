# HOL-SEC-015: Anyone in a server's room could fake typing and unread or mention badges in any channel

```
ID:          HOL-SEC-015                 Status: Partly fixed on local main (2026-09-27): forgery by non-posters
                                          closed; the plaintext exposure of the hint is candidate J9
Severity:    Low                         (Impact L: "X is typing", unread counts and mention badges for any channel,
                                          including ones the victim cannot open; Exploitability H: needs only the
                                          server id, which every invite link carries)
Category:    Unauthenticated signal; missing authorisation (sender and receiver never checked against the channel)
Component:   rust/hollow_core/src/node/swarm.rs :: ChannelNotificationHint, TypingIndicator, MLS Typing arms
             rust/hollow_core/src/node/message_ops.rs :: channel_signal_accepted
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   C-17, C-18; candidate C10 (evidence channel:S15, S16, transport:S-13), L3 (typing half)
Attacker:    P-03 stranger who knows the server id, P-05 member without access to the channel
Found:       2026-09-26, phase B channel and transport passes; confirmed by reading 2026-09-27
```

## Description

After a channel post the sender broadcasts a plaintext notification hint to the
whole server room, so members not subscribed to that channel can badge it.
Typing rides MLS, with a plaintext copy for members who hold no leaf yet. On
receipt neither was checked against the server: a stranger in the room, or a
member who cannot see a channel, could make every member show typing, unread
counts and mention badges for any channel id, and a member was badged for
restricted channels it cannot open. Typing from a blocked identity was shown.

## Reproduction

`authz_channel_signals_only_from_a_poster_about_a_channel_we_see`
(crdt/server_state.rs tests) and `channel_ingest_gates_stay_wired`
(node/crypto_handler.rs tests, now also covering the three signal arms).

## Fix

One gate for live channel signals, `message_ops::channel_signal_accepted`: the
sender must pass the live post gate for that channel (member, can see, can
post, not muted) and we must be able to see it. The plaintext hint, plaintext
typing and MLS typing arms all call it; plaintext typing from a blocked
identity is dropped. Meeting typing still passes on group membership, since a
meeting holds no server state.

## Variants

- The hint is still plaintext to the whole room, so the relay and anyone holding
  the server id learn that a channel had a post, which member names it
  mentioned and whether it pinged everyone, restricted channels included. The
  relay can also still forge a hint or typing in a member's name. Both move
  into MLS with the class A work: candidate J9.
- The push path's mention flag is chosen by the sender: candidate C14.

## Test

The wiring guard fails on the old code (no gate in the three arms) and passes
with the fix; the unit test pins the gate's rules. Full suite green.
