# HOL-SEC-181: A removal stamped ahead of a later re-add ended the re-added friendship on some devices

```
ID:          HOL-SEC-181                 Status: Fixed (2026-10-23, wave g13, local commit c4e2f7f5),
                                          ships with 0.13
Severity:    Low                         (Impact M: a friendship re-added after a removal ends again, on
                                          some of our devices and not others, or on one side only;
                                          Exploitability L: needs a removal and a re-add close together with
                                          a clock difference between the devices involved, or a late copy of
                                          the removal)
Category:    Integrity (ordering across devices)
Component:   rust/hollow_core/src/node/social.rs (readd_stamp, friend_removals, accept marks),
             node/frame_auth.rs (change_stamp_ms), node/swarm.rs (FriendRemove, FriendListSync arms),
             node/types.rs (FriendRemove.at, FriendListEntry.accepted_at, FriendRemoval.theirs)
Boundary:    TB-2 (contacts), TB-3 (own devices)
Traces to:   C-12; HOL-SEC-112, HOL-SEC-113, HOL-SEC-115
Attacker:    none needed
Found:       2026-10-23 (wave g13, track readd, from a harness test that failed on the merged tree)
```

## Description

A friend request was stamped by the device's wall clock, and receivers compared that stamp
with the seal time of the removal it followed. When the removal's seal ran ahead of the
re-add's stamp (a device clock ahead within the allowed skew, or the seal clock of another
device), the re-add was judged older than the removal. Late copies of the old
`FriendRemove`, and our own devices re-sharing its tombstone (HOL-SEC-115), then ended the
new friendship the same way, on some devices and not others. The class is present in
released versions since the removal tombstones of 0.12.0; the strictly rising seal clock
of HOL-SEC-180 made it fail every time in the harness, which is how it was found.

## Fix

- Friend requests and accepts are stamped from the seal sequence, past any removal we hold
  for that person, capped at the stamp ceiling (`social::readd_stamp`).
- A `FriendRemove` names the friendship it ends (`at`, a new optional field), so a copy that
  ends an earlier friendship is ignored; 0.12.2 devices ignore the field and behave as
  before.
- Our devices tell each other a friendship's request stamp and our accept apart, and
  whether the friend or we ended it, so one device never keeps a friendship the friend
  ended; a tombstone that a newer friendship outlived is still shared, clamped below that
  row, so an away sibling still ends what we ended.

## Residual risk

A bare `FriendRemove` from a pre-0.13 sender keeps the seal rule; a re-add capped at the
ceiling can still lose to a tombstone stamped far ahead (re-add lost, asymmetric); a
stranger's `FriendRemove` with no row still makes a tombstone (follow-up).

## Test

Harness `authz_a_removal_reaches_an_online_sibling_and_never_undoes_a_readd`,
`a_late_copy_of_the_friends_removal_never_ends_our_readd`,
`a_removal_names_the_friendship_it_ends_whatever_the_seal_clock`,
`a_removal_reaches_an_away_sibling_while_we_ask_again`; unit
`a_readd_outlives_the_tombstone_it_supersedes` (node/social.rs). Mutation pass 21/21 after
three review rounds.
