# HOL-SEC-182: A device removed while it was connecting never learned its removal live

```
ID:          HOL-SEC-182                 Status: Fixed (2026-10-23, wave g13, local commit e34b86d4),
                                          ships with 0.13
Severity:    Low                         (Impact M: a removed device, such as a stolen phone, shows no
                                          lock and does not start its three-day erase until it reconnects;
                                          contacts already refuse it; Exploitability L: the removal has to
                                          land while the device is connecting)
Category:    Access control (a security control not delivered)
Component:   rust/hollow_core/src/node/roster_book.rs (tell_removed_device_in_room), node/swarm.rs
             (PeerJoined, RoomMembers)
Boundary:    TB-3 (own identity and its devices), TB-1
Traces to:   C-03; design ID-1 (HOL-SEC-077)
Attacker:    P-08 holder of the removed device (benefits, does not cause it)
Found:       2026-10-23 (wave g13, while fixing a flaky harness test)
```

## Description

A removal reaches the removed device through a roster notice. When the device was removed
while it was still connecting, the notice was dropped because we did not see the device in
any room yet, and the tombstone we send on first sight went into our inbox just as the
relay took the device out of it. Contacts already refused the device, but it showed no
lock and its erase timer did not start until its next connect, which matters most for a
stolen phone that stays online. Present since design ID-1 (0.12.0).

## Fix

Each time a device our own roster removed arrives in a room we see, from both the join and
the member-list paths, we hand it that roster there, once per arrival. Forwarder rooms and
bare master ids never get it, and nothing beyond the roster that removes it goes to the
device.

## Residual risk

None known.

## Test

Harness `g13w3_a_device_removed_while_connecting_learns_it_when_it_appears`,
`g13w3_a_removed_device_listed_in_a_room_refresh_learns_it`,
`g13w3_only_our_removed_device_hears_the_roster_when_it_appears`,
`g13w3_the_arrival_notice_alone_skips_a_bare_master`. Mutation pass 5/5.
