# HOL-SEC-228: a carry to our own devices could miss one that left before delivery

```
ID:          HOL-SEC-228                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: a phone keeps showing age-restricted
                                          servers after a computer of the identity turned
                                          them off (the Apple 1.2 gate), or keeps a server
                                          we left, kicked or banned from, until the two
                                          devices next meet; Exploitability L: no attacker,
                                          the phone has to leave its last room between the
                                          fan-out and delivery, and the computer has to
                                          quit or go offline before the phone returns)
Category:    Availability (own-device delivery of a gate change)
Component:   rust/hollow_core/src/node/olm_lane.rs (carry_to_every_own_device,
             own_device_room, released), node/age_gate.rs
             (share_with_own_devices), node/sync_handler.rs
             (broadcast_removal_op, the leave arm)
Boundary:    TB-1 (the person's own devices)
Traces to:   R-CH-13; wiki security_write_gates sections 36 and 68
Found:       2026-11-22 (the age gate harness test failing under load in the
             nightly suites)
Affected:    0.14.0 to 0.14.2 for the age gate; removal and leave ops since
             0.12.1, when they began to ride this fan-out
Fix commit:  81e9e3bf0, b8b2595af
Disclosure:  published with 0.14.3
```

## Description

Some changes go to every device of our own identity through one fan-out,
`carry_to_every_own_device`: the age gate choice a computer authors for the
identity's phones (`age_gate::share_with_own_devices`), and the removal and leave
ops that drop a server on our own devices at once
(`sync_handler::broadcast_removal_op`, the leave arm). A device not in any room we
see is sent the carry through our inbox, a route fixed at the fan-out, so the relay
holds it for the device's return.

A device the fan-out saw in a room took a different path: it was judged present from
the room peers at the time of the call, but the room was left to be picked when the
node delivered the carry. If the device's last room leave landed in between, the
carry found no room and was parked in the sender's memory until the device came back.
A sender that quit or went offline first never sent it. A phone going away just as
the person turned the age gate off on the computer kept showing age-restricted servers
until the two devices next met and verified each other (`share_with_sibling`); a phone
in the same race kept a server we had left.

## Fix

The present device's route is fixed at the fan-out, as the away devices' already was,
and pinned to a room the device rejoins on every connect (`own_device_room`): our own
room when our view shows the device there, else our inbox, never a server or DM room
we share by chance. The relay keeps a direct for a device gone from a room only while
the sender is still in that room and replays it only when the device rejoins that
same room, so a carry pinned to a room either side was leaving would be lost too. A
device gone by delivery is then held by the relay while we hold an Olm session with
it.

A frame held back because its Olm session save did not land (AR-30) goes back to the
node with its pinned room (`olm_lane::released`), so a relay refusal of that room is
judged as for any carry instead of the frame waiting to leave by another route.
Without a session at delivery, or when the save does not land, the plaintext waits in
our resend queue as before, and the devices trade the age gate choice again when they
next meet.

The harness's mock relay now drops the directs the relay drops (a direct into a held
room from a sender not in it, and one into a room nobody holds for a connected
target), so a product path that sends either fails in tests as it would for real.

Tests:
- unit `olm_lane::tests::an_own_device_that_leaves_before_delivery_still_gets_the_carry`:
  a sibling seen present at the fan-out (in our own room, a server room, our inbox or
  a DM room) and gone by delivery is sent exactly one copy, through our own room when
  it showed there, else our inbox, and nothing waits in our memory.
- unit `olm_lane::tests::a_held_back_frame_for_a_refused_room_is_not_kept` and
  `a_frame_goes_out_only_on_a_landed_save_and_is_handed_back_otherwise` (the held-back
  frame returns with its room).
- harness `agegate_an_off_delivered_after_the_phone_left_still_reaches_it`: the
  computer fans the OFF out while it sees the phone, delivers it only after the phone
  left, then quits; the phone learns the OFF on its return with no computer online.
- harness `agegate_the_desktop_choice_reaches_every_own_device_and_its_lifting_too`
  (the test whose failures under load found this), and
  `md_a_hidden_sibling_drops_a_server_we_leave_at_once` (the removal path).
- harness `mock_relay_drops_the_directs_the_relay_drops` (the mock relay keeps directs
  as the relay does).
