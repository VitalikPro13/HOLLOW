# HOL-SEC-244: a push fetch spent every frame it does not show

```
ID:          HOL-SEC-244                 Status: Fixed in 0.14.2
                                          (track sec-244, 2026-11-21)
Severity:    Medium                      (Impact M: a deletion, a reaction, a sync page
                                          or another frame a friend sent the
                                          sleeping phone never reaches the app, so a message
                                          the friend deleted stays shown there;
                                          Exploitability: none needed, it happens on any push
                                          wake that meets such a frame)
Category:    Availability (lost delivery)
Component:   rust/hollow_core/src/node/fetch.rs (try_decrypt_dm, the channel wake),
             node/fetch_keep.rs (new), storage/messages/fetch_kept.rs (new),
             node/swarm.rs (the replay)
Boundary:    TB-3 (the relay), TB-1 (content from other people)
Traces to:   C-13, C-17; R-PU-07
Attacker:    none needed
Found:       2026-11-21 (session B, design review of history sync track S3)
Affected:    every release with the background push fetch, through 0.14.1
Fix commit:  fad4026e1, ba51b966e (0.14.2)
Disclosure:  with the 0.14.2 release
```

## Description

The relay lets go of a room's buffered frames once it hands them to a woken phone's
background fetch. The fetch read direct messages, edits, link cards and file headers and
dropped every other frame it met: deletions, reactions, DM sync pages, carried messages
and the Olm copy of a destroy order among them, its own sibling devices' frames, and Olm
frames it could not decrypt. A channel wake did the same with every direct in the server
room that was not a post. None of them reached the app afterwards, and DM catch-up brings
back only what a friend still serves, never its reaction on our message.

## Fix

The fetch keeps every durable frame it does not show (`fetch_keep::durable`: a frame whose
class is not live only) in the encrypted message database, and the app replays each kept
frame through its usual receive path, with every live gate, when it next joins that room.
A row is forgotten only once its replay has returned. A frame the fetch already decrypted
keeps its plaintext, bound to that ciphertext, so it is never decrypted twice; its session
save follows the keep.

Only frames whose seal opened are kept: on a DM wake from a device the roster counts for us
or for the friend, on a channel wake from a member, and never from a removed device or a
blocked identity. The store is bounded: direct-message rooms and server rooms have separate
budgets, each room is one share, a full budget evicts from the heaviest sender in the
heaviest room, and rows go after 30 days or with the friendship, the server or a cleared
history.

A resumed app that took the fetch's newer Olm session restored it deep in the frame
handler, which overran a debug build's worker stack; it now takes the session at the top
of the frame arm (ba51b966e).

## Test

Harness `fetch_keeps_a_durable_carried_frame_for_the_app`,
`sec244_a_resumed_app_replays_what_its_push_fetch_kept`,
`sec244_a_replay_past_the_frame_budget_lands_whole`; unit
`sec244_the_fetch_keeps_a_durable_envelope_it_does_not_show`,
`sec244_the_fetch_keeps_an_unread_durable_frame_as_it_came`,
`sec244_a_channel_wake_keeps_a_members_direct_but_never_a_post`,
`rev244_a_dm_wake_keeps_nothing_from_a_device_no_side_counts`,
`rev244_a_removed_devices_frame_is_never_kept`,
`sec244_a_channel_wake_keeps_nothing_from_a_removed_device`,
`sec244_a_prekey_session_is_saved_only_after_its_frame_is_kept`,
`only_durable_relay_lane_frames_are_kept`, `rev244_one_frame_sybils_evict_a_friends_kept_frames`,
`a_crowd_in_one_room_evicts_only_its_own_room`, `a_server_room_never_evicts_a_dm_room`,
`a_rooms_frames_go_with_the_friendship_the_server_and_the_history`,
`a_kept_frame_is_forgotten_only_after_its_replay`,
`kept_plaintext_opens_only_its_own_frame_inside_its_replay`. Mutation pass: 26 of 26 killed.

## Residual risk

A decrypted Olm frame that cannot be kept (its plaintext and frame over 1 MiB, or turned
away by a full share) still has its key spent; sync is what brings it back.
