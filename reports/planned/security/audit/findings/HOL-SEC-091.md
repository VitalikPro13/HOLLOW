# HOL-SEC-091: Anyone holding a server id saw who was in its room and when

```
ID:          HOL-SEC-091                 Status: Fixed on local main (2026-10-02), relay
                                          and apps; retest at release
Severity:    Medium                      (Impact M: every member device online, each join
                                          and leave, every broadcast's sender, linkable
                                          across servers and to a master by any public
                                          post; Exploitability H: a server id, which
                                          invites and public links carry)
Category:    Relay / Privacy
Component:   relay-uws/src/ws_handler.cpp (handle_join, every room fan-out),
             relay-uws/src/door_room.h, rust/hollow_core/src/node/door_room.rs,
             ws_client.rs (door proof), swarm.rs
Boundary:    TB-1 (the relay's rooms) / TB-0 (the internet)
Traces to:   no claim yet (decision D1); design
             reports/planned/security/audit/design_D1_door_rooms.md
Attacker:    anyone who learned a server id, with a throwaway identity
Found:       2026-10-02 (phase B re-check, decision D1)
```

## Description

A server's relay room is named by its id. Joining it took nothing but an authenticated
socket, and the relay then handed the joiner the room's roster (every member device
online), told it of every join and leave, fanned it every room broadcast and topic frame
with the sender's device id, and answered its discover and check_peers queries. Nothing
sealed or MLS leaked, but a device id is the same in every room, so a crawler that
collects server ids could follow one device across servers and log when it is online,
and a post in any public channel ties that device to its master.

## Fix

The relay already keeps every 0.12 server's join lock, whose newest door only current
members hold. It now hands out an X25519 key in `auth_challenge`, and a server room join
carries an HMAC under the X25519 secret of that key and the door, bound to the socket's
challenge, the peer, the room, the door and the relay key. In a room whose server has a
lock there, only a socket proving the newest door sees the roster, presence, broadcasts,
topic fan-out and ring catch-up, and is shown to others; anyone else is listed to nobody
and told it sees nothing (`proved: false`). Directs still reach a hidden socket, because
a member chooses whom to address. Public channel traffic rides a new 0x0A frame that a
prover's send also hands to hidden guests.

A lock move keeps everyone who could see for a 60 s grace, so the op handing out the new
door still reaches the members; whoever has not proved it by then drops out, and the
others see it leave. A member that missed the move asks the room (`DoorAsk`); up to three
members who see it and place the asker as a current member's device answer with the door
sealed to its device key (`DoorGrant`), taken only when it is the newest lock of a chain
the asker verified to the owner. A joiner sends its sealed request to the whole room and
waits the full window before parking, since emptiness is no longer visible to it. A guest
browsing public channels reaches, and is answered by, the members it heard there.

## Residual risk (AR)

Someone who joins through an open invite is a member like any other; someone who already
knows a device id can address it and learn from a reply that it is there (in a server
without public channels no hidden peer gets one); a removed member keeps presence for up
to the grace; a lock record evicted under the fair-share budget leaves its room open until
a member puts the chain back; legacy (32-hex) servers and meetings are unchanged.

## Test

Relay unit `test_door_room` (29 checks: the pinned proof, a third computation outside
both codebases, and the prover rules). Rust unit
`door_proof_matches_the_relays_pinned_vector`. Harness
`authz_an_outsider_holding_a_server_id_sees_nobody_in_its_room` (failed on the old relay
rules: the outsider was handed both members and the post's sender),
`authz_a_removed_member_stops_seeing_the_room_once_the_lock_moves`,
`a_member_offline_through_a_lock_move_gets_the_door_and_sees_again`,
`a_joiner_completes_its_join_in_a_room_that_hides_its_members`; mutation pass in
`tmp_d1_mutate.py`.
