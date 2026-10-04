# HOL-SEC-126: Anyone could see who used a media forwarder and when

```
ID:          HOL-SEC-126                 Status: Fixed (2026-10-03, session 33), relay
                                          deployed 2026-10-04 after a canary
Severity:    Medium                      (Impact M: the device id of every sharer and viewer
                                          routed through a forwarder, from every server
                                          using it, each arrival and departure, and a direct
                                          or deposit path to each; Exploitability H: the
                                          VPS forwarder's id is handed to any socket that
                                          asks, `get_media_forwarder`)
Category:    Relay / Privacy
Component:   relay-uws/src/ws_handler.cpp (Audience, handle_join, announce_door_change,
             collect_room_co_members, discover_peers, every broadcast and direct handler,
             the 0x07 ring tee), relay-uws/src/fwd_room.h; MockRelay's copy in
             rust/hollow_core/src/node/test_harness.rs
Boundary:    TB-1 (the relay's rooms) / TB-0 (the internet)
Traces to:   phase B matrix relay:0.2 (residual), A-04, A-06, A-07, A-21, A-23;
             phase_b_evidence/authz_media.md A-MED-12
Attacker:    anyone who knows a forwarder's id, with a throwaway identity
Found:       2026-10-03 (phase B matrix, decided for session 33)
```

## Description

A media forwarder's control plane rides the room `fwd:{X}`, X being the forwarder's
device id. The VPS forwarder serves the sharers and viewers of every server that routes a
stream through it, and its id is advertised to any authenticated socket. The relay
treated the room like any other: every joiner got the roster of everyone using the
forwarder, a presence stream of their arrivals and departures, every broadcast with its
sender, and discover and check_peers answers about them, and could send any of them
directs or leave deposits for them under the room's name. A device id is the same in
every room, so this tied people watching forwarded shares across servers and over time.
Clients also opened an Olm key exchange with every peer that joined a `fwd:` room, so a
stranger joining was answered by each viewer.

## Fix

The relay pairs every member of `fwd:{X}` with X alone (`fwd_room::paired`): X sees and
reaches everyone in the room, any other member sees and reaches only X. `Audience::shares`
carries the rule into the roster on join, peer_joined and peer_left, discover_peers,
check_peers co-membership, the JSON `msg`, 0x03, 0x0A and 0x07 fan-outs; the JSON
`direct`, 0x02, 0x04/0x08 and 0x09 refuse a pair without X, live or deposited, including
a deposit into a `fwd:` room nobody is in yet; a `fwd:` room keeps no ring. No client
needs more: the forwarder lane only ever talks client to forwarder, and the forwarder,
being X, still sees every peer leave. MockRelay applies the same rule, so the harness runs
on it.

## Residual risk

The forwarder itself sees everyone using it, by design (operator infrastructure for the
VPS forwarder, a member who watches the same stream for a peer forwarder). Deposits a
stranger left in a `fwd:` room before the deploy replay once if a relay snapshot carries
them. The id of the VPS forwarder stays public; joining its room shows only the
forwarder.

## Test

Relay live `test_relay_live` section "forwarder rooms: a member meets only the forwarder"
(35 checks per build; on the old handler 18 failed with the release-day switches on and
17 with them off, where no unsigned control opens a ring, among them "a stranger sees the
forwarder and not the viewer", "check_peers tells a member of no other member", "a
member's direct reaches no other member" and "another member's waits for nobody");
relay unit `test_fwd_room` (11 checks; "two members are not" and two more failed on the
old rule). Harness `authz_a_stranger_in_a_forwarder_room_meets_only_the_forwarder`
(failed on the old MockRelay rule: the stranger was shown the viewer), with
`forwarder_room_and_signal_round_trip` and `fwd_room_join_skips_discovery_but_keeps_olm`
still green on the new one. Mutation pass `tmp_s33_relay_mutate.py`: relay 21/21 killed,
MockRelay all killed.
