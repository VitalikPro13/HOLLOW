# HOL-SEC-016: A member who could not see a restricted voice channel could still take a seat in it and be dialed

```
ID:          HOL-SEC-016                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a roster seat in a restricted voice channel, a WebRTC dial from
                                          every participant with ICE candidates (their addresses), and the right to
                                          send participant signals; the audio stays under the channel subgroup's
                                          SFrame key the member does not hold; Exploitability M: a modified client
                                          and plain membership)
Category:    Access control (membership checked, channel visibility not)
Component:   rust/hollow_core/src/node/swarm.rs :: plaintext VoiceChannelJoin arm
             rust/hollow_core/src/node/voice_handler.rs :: handle_envelope_voice_channel_join, voice_join_refusal
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-18, C-21; candidate C12 (evidence media:S-04)
Attacker:    P-05 member without access to the channel
Found:       2026-09-26, phase B media pass; confirmed by reading 2026-09-27
```

## Description

Our own client refuses to join a restricted voice channel we cannot see, but on
receipt a join was checked only for server membership and the channel being a
voice channel. A member with a modified client could announce itself in any
restricted voice channel: every participant added it to the roster and dialed
it, handing it their ICE candidates, and it could then send the signals the
participant check lets through.

## Reproduction

`authz_voice_seat_only_for_a_member_who_can_see_the_channel`
(crdt/server_state.rs tests) and `channel_ingest_gates_stay_wired`
(node/crypto_handler.rs tests, now also covering both join arms).

## Fix

Both join paths, plaintext and MLS, ask one function,
`voice_handler::voice_join_refusal`: a member who can see the channel, and the
channel is a voice channel. Meetings keep their own rule (the sender holds a
leaf in the meeting group).

## Variants

- Voice presence, leave and state frames are unauthenticated plaintext against
  the relay: candidate A11 (class A).
- VC frames over MLS are attributed to the relay's sender id rather than the
  leaf: candidate D9 (class D).

## Test

The wiring guard fails on the old code and passes with the fix; the unit test
pins the rule. Full suite green.
