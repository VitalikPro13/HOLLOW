# HOL-SEC-068: Future stamps and replays undid read positions, emotes, reactions and link cards

```
ID:          HOL-SEC-068                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Low                         (Impact L: a conversation marked read for good, a personal
                                          emote deleted for good, a later reaction removed or a newer
                                          link card replaced; Exploitability L: needs one of our own
                                          devices for the stamps, the relay replaying a recorded
                                          public frame for the rest)
Category:    Replay / ordering
Component:   rust/hollow_core/src/node/frame_auth.rs :: stamp_ceiling, swarm.rs (ReadMarkers,
             PersonalEmoteSync, FriendListSync arms, pub_ch_unreact, pub_lp_set), message_ops.rs,
             fetch.rs, storage/messages.rs :: remove_reaction, lp_at
Boundary:    TB-1 (client <-> relay), own devices
Traces to:   C-25; candidate A29 (the DM typing half is HOL-SEC-062)
Attacker:    P-01 relay replaying a recorded public frame; a compromised own device (stamps)
Found:       2026-09-27 (design A inventories: dm_identity ReadMarkers and PersonalEmoteSync,
             server_mls PublicChannelRemoveReaction and PublicLinkPreviewSet)
```

## Description

Sibling-lane stamps had no ceiling: a read marker stamped far in the future marked
every present and future message of a conversation read, an emote tombstone with a
huge `added_at` deleted the name for good, and a friendship's stamp decided which
removals looked older. A removal of a reaction deleted the row with no ordering, so a
replayed old public unreaction removed a later re-add. Nothing ordered link cards, so
a replayed older card replaced a newer one.

## Reproduction

`authz_a_sibling_lane_stamp_never_runs_ahead_of_its_frame`,
`authz_a_replayed_public_unreaction_or_card_never_undoes_a_later_one` (node/test_harness.rs);
`storage::messages::tests::authz_an_old_unreaction_never_removes_a_later_re_add`,
`authz_an_older_card_never_replaces_a_newer_one`.

## Fix

One ceiling, `frame_auth::stamp_ceiling`: 300 s past the frame's time (for a carried
message, the earlier of its `at_ms` and the seal). Emote rows past it are refused (their
stamp is a last-write-wins version, so clamping would order differently per device);
read markers and friendship stamps are clamped (the fact still holds). Every unreaction
path goes through `remove_reaction`, which now deletes only a reaction added no later
than the removal (ties go to the removal, matching the add rule), and our own stamps
beat any add or removal already recorded. A live link card applies only when its
frame's seal time is later than the row's last card (`lp_at`, a new column) and its
last edit, on every arm and the push fetch node; signed sync backfill stays unordered.

## Test

The tests above. Mutation pass: three stamp rules and seven reaction and card rules
put back, each failing a test.

## Residual

Remote message timestamps are still unbounded (a far-future message moves our own read
floor), and a stranger's `FriendRequest.requested_at` too; cards through sync backfill
are unordered (an insider serving an older card).
