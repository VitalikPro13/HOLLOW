# HOL-SEC-227: a device away at an in-app phrase recovery never learned it

```
ID:          HOL-SEC-227                 Status: Fixed in 0.14.3
Severity:    Medium                      (Impact M: a lost or stolen device the
                                          person recovered the identity from keeps
                                          running unlocked and never starts its erase;
                                          contacts and the relay that hold the recovery
                                          already refuse what it sends; Exploitability
                                          L: needs that device to be offline past its
                                          relay session's grace when the recovery runs)
Category:    Identity authority
Component:   rust/hollow_core/src/node/roster_book.rs (tell_removed_device_in_room),
             rust/hollow_core/src/node/swarm.rs (PeerJoined, RoomMembers, SessionLost)
Boundary:    TB-1 (the person's own devices)
Traces to:   design ID-1; R-ID-18
Found:       2026-11-22 (phrase-restore review, after the fleet's bug B)
Affected:    0.14.0 to 0.14.2
Fix commit:  556dbcc5c, 0d028ac75
Disclosure:  published with 0.14.3
```

## Description

A phrase recovery typed into the app while the node runs (`recover_with_phrase`) starts
a new base that leaves out every device the person did not keep. The node fans the new
roster out live, and the relay's fold of it demotes the left-out devices from the inbox.
A left-out device that was offline past its session's grace missed both: the live
notice reached no ring it reads, the relay drops an inbox owner without telling it, and
the mailbox replays only to members.

The one path meant for a device that missed its own change, the arrival hand-off
(`tell_removed_device_in_room`), told only devices our roster had removed
(`is_revoked`, `state.removed`). A recovery names no removal, so the hand-off never
fired for a device it left out. That device never showed the lock and never started
its three-day erase, however long it stayed online beside the recovering device.

## Fix

In our own room (`own_room`, which only holders of the master key can name) a device
our roster does not count is handed the roster as a `RosterNotice` when it appears
(`PeerJoined`, or a `RoomMembers` listing). Never ourselves, a bare master, a device
we count, a device we place with another identity, another identity's master id or a
device another identity removed. The removed-device path is unchanged.

Since anyone with the master key can mint device ids and join that room, this branch
is bounded: it is judged on the resolver before the store is read, a device is told
once per roster revision (again once our relay session is lost or ten minutes pass),
and a node hands at most eight such rosters a minute.

Tests:
- harness `hol_sec_227_an_inapp_recovery_reaches_a_device_away_past_its_grace_on_return`:
  W is away past its grace while D recovers and fans out; once W is back, D hands it
  the roster in our own room and W learns the phrase left it out. Red with the 0.14.2
  hand-off.
- harness `pr_b_a_device_offline_at_an_in_app_recovery_learns_it_on_its_return`: the
  same with D still placing W while it fans out; red with the left-out branch gone.
- harness `pr_b_old_devices_learn_a_welcome_recovery_online_and_on_their_return`: the
  Welcome recovery case (signed before the node starts, so nothing fans it out).
- harness `pr_b_the_own_room_hand_off_skips_another_identitys_device` (who never hears
  it) and `pr_b_the_own_room_hand_off_is_bounded_for_fresh_and_churning_ids` (the bound);
  unit `roster_book::tests::the_hand_off_budget_tells_once_per_revision_and_refills_by_the_minute`.
