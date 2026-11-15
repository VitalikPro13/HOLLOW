# HOL-SEC-040: Being in a room with us was enough for a data channel, a gossip seat and our voice presence

```
ID:          HOL-SEC-040                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M, privacy: our IP addresses in the data channel's ICE
                                          candidates to anyone who could join a room with us, our inbox included;
                                          a non-member of a server became a gossip neighbour, got a data channel
                                          and the CRDT op flood, and learned which voice channel we sat in;
                                          Exploitability H: joining a room needs only its name, and an inbox
                                          name is the public master id)
Category:    Information disclosure; missing authorization (room presence taken as membership)
Component:   rust/hollow_core/src/node/voice_handler.rs :: data_channel_peer_allowed,
             handle_webrtc_send_signal
             rust/hollow_core/src/node/swarm.rs :: RtcOffer arm, PeerJoined and RoomMembers gossip
             feeds, PeerExchange arm, voice presence re-announce
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-24; candidates J1, J2, J3, J6 (evidence relay:12, 13, 14, dm:S-23, transport:S-14)
Attacker:    P-02 stranger, P-03 room peer
Found:       2026-09-26, phase B relay and transport passes; confirmed by reading 2026-09-27
```

## Description

Joining any room we sat in made us key-exchange with the joiner, and a finished
key exchange made the app open a WebRTC data channel to it. We also answered any
offer that was not from a blocked person. A server room's joiners were added to
the gossip overlay whether or not they were members, a neighbour's peer exchange
could name anyone, and our voice presence was re-announced to every joiner.

## Reproduction

`authz_room_presence_alone_opens_no_channel_to_us` (node/voice_handler.rs tests).

## Fix

- `data_channel_peer_allowed`: a general data channel is dialled or answered only
  with our own devices, accepted friends and people we share a server with, never
  a blocked person. Share links keep their own lane.
- The gossip overlay takes only CRDT members, from room presence and from a
  neighbour's peer exchange.
- Our voice presence is re-announced only to a member who can see that channel.
- A source guard in the same test keeps each gate wired.

## Variants

- J5 (the relay names the media forwarder an "Always relay calls" viewer accepts)
  and J7 (a nickname claim's master id is self-reported) need signed bindings;
  both go to the class A design.
- A stranger can still complete an Olm key exchange; it opens nothing by itself.

## Test

The test fails with the old open rule put back and passes with the fix. Full
suite green.
