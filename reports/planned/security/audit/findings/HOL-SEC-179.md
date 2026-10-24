# HOL-SEC-179: A frame carried to our own sibling device could be lost in a room the sibling had left

```
ID:          HOL-SEC-179                 Status: Fixed (2026-10-23, wave g13, local commit be5f8124),
                                          ships with 0.13
Severity:    Low                         (Impact M: a carried message to our own device, such as a friend
                                          list sync, a removal or a server announce, is silently lost;
                                          Exploitability L: needs the sibling to have just left the first
                                          room both devices shared)
Category:    Availability (misrouting)
Component:   rust/hollow_core/src/node/crypto_handler.rs (ws_room_for_peer), node/olm_lane.rs (deliver)
Boundary:    TB-3 (own identity and its devices)
Traces to:   CLAUDE.md rule "targeted sends route to their deterministic room"
Attacker:    none needed
Found:       2026-10-23 (wave g13, hostile review of the message-store track)
```

## Description

A carried (Olm) frame to one of our own devices was routed to the first room both devices
shared. That could be a DM room the sibling had just left; the relay then parked the frame
for a rejoin that never came. Present in released versions; a faster store in 0.13 made it
show up in 4 to 7 of 16 runs of a sibling test.

## Fix

Our own devices are reached through our own room, else our inbox, never a first-match
room; other targets keep the existing deterministic routes.

## Residual risk

`send_tombstone_if_revoked` still uses the first-match lookup; it is now redundant and is a
follow-up.

## Test

Unit `our_own_device_is_reached_through_our_own_room_then_our_inbox` (node/crypto_handler.rs),
harness `g13w3_a_carry_to_a_sibling_never_rides_a_room_it_left`; the sibling list test that
failed 4 to 7 times in 16 passed 50 of 50. Mutation pass 7/7.
