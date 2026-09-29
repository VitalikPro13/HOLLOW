# HOL-SEC-062: The relay read friend lists, server state, profiles and join requests

```
ID:          HOL-SEC-062                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: server, channel and member details, friend and DM
                                          contact lists, read positions, profiles, post hints and join
                                          requests with their Twitch credentials read by the relay, and a
                                          removed member could answer a joiner; no message content or keys,
                                          and forgery was closed by HOL-SEC-053; Exploitability M: needs
                                          the relay the victim uses, or a removed member with a modified
                                          client. Graded as the candidate rows it closes: A28, J8, J9 Medium)
Category:    Data exposure
Component:   rust/hollow_core/src/node/types.rs :: HavenMessage::lane, node/olm_lane.rs, dm_room.rs,
             share_handler.rs, social.rs :: profile_audience, profile_card.rs, crypto_handler.rs,
             sealed_box.rs, join_lane.rs, join_lock.rs, lock_keeper.rs, swarm.rs, sync_handler.rs;
             crdt/lock_state.rs; relay-uws/src/join_lock.h
Boundary:    TB-1 (client <-> relay), TB-2 (peer <-> peer) for answers to a join
Traces to:   C-24, C-14; candidates A9, A10, A28, A29 (DM typing), I4 (DM rooms), I6 (join ring),
             J8, J9, N1; design A-D1
Attacker:    P-01 malicious relay; P-05 removed member with a modified client (join answers)
Found:       2026-09-26 (phase B: I4, I6, J8, J9), 2026-09-27 (design A inventories); the Olm join
             answer 2026-09-28
```

## Description

The relay read in plaintext everything the design A inventories listed against
claim C-24: every CRDT op (server and channel names, restricted ones included,
roles, bans, members) and whole op logs; profiles and signed device lists,
announced to every room peer, and a full profile to any stranger in a shared room;
an identity's friend list and DM contacts with per-day counts (the sibling lane);
read positions and emote sets; the per-post notification hint (J9); channel and DM
sync watermarks and gap digests (J8); typing, status, voice presence and share
states; file and emote requests, the key in a guest's file header and share
manifests; and every join request in the `~join` ring (device list, Twitch
credential, KeyPackage) with the op log sent back. A DM room was a hash of the two
public master ids, so anyone who knew both found the room, its roster and when
either person came online. Knowing a server's id, which the relay does, was enough
to ask to join, and anyone in the server's room could read an ask and send the
joiner a refusal. Only some profile fields were signed (N1).

While a join was pending, the joiner also took a sync answer over Olm from anyone
it shared a session with, so a member removed from the server could hand it a state
from before the removal with an admission of its own.

## Reproduction

The wiretap tests (`MockRelay::start_wiretap`: no carried message readable in the
clear) `c24_the_sibling_lane_rides_olm`, `c24_server_traffic_rides_mls_or_olm`,
`c24_a_dm_room_is_named_by_the_two_master_keys`, `c24_a_profile_never_rides_in_the_clear`;
`authz_a_join_request_counts_only_in_the_join_box`,
`authz_a_pending_join_takes_its_answer_only_from_its_reply_key`,
`join_lock_a_removed_members_door_neither_reads_nor_answers_a_join` (node/test_harness.rs).

## Fix

- Phases 1 and 2 (`e39ed7cb`). `HavenMessage::lane()` is one exhaustive list of
  where each message may travel: a sealed plaintext frame (`Relay`), one device's
  Olm session (`Carried`, inside `MessageEnvelope::Carried`), the call signal
  envelope, and later `Share` and `Join`. A plaintext copy of anything else is
  dropped before a handler sees it. `olm_lane::carry()` sends from anywhere; the
  sealing stage waits for the carry's frames so wire order stays program order, and
  a carry parked for a session is judged by the time it was written. Carried: the
  own-device lane (friend list sync and request, sibling state requests, read
  markers, personal emotes, sibling server announces, DM sibling sync), the destroy
  fan-out, the CRDT op twin on every path (`MemberAdded` to members, not room
  peers), sync and channel sync requests (J8), the kick notice, typing (a DM dot
  only from a friend), status (friends and co-members only) and the voice twins.
  The post hint rides a new MLS `ChannelHint` over the server group, or a restricted
  channel's subgroup, with an Olm copy for devices without a leaf (J9).
- Phase E (`c54bcbe9`). A DM room is `hex(HMAC-SHA256(X25519(our master, their
  master), "hollow-dm-room1" | lo | hi))[..16]` (`node/dm_room.rs`): every device of
  the two identities can compute it and nobody else can. `DmSyncRequest` is carried.
- Phase F (`c54bcbe9`). File requests and their answers, the guest's file header,
  emote requests and assets and the auto-download advert are carried. Share control
  rides `ShareSealed`, AES-256-GCM under a key derived from the link key and bound to
  the root hash, opened only in that share's room as that share's control
  (`Lane::Share`); Olm would not do, since a relay can join a share room as a peer.
- Phase D (`73591cbe`). Profile announces, pulls and relays and a new card are
  carried. `social::profile_audience` decides every announce: the full profile to
  our own devices, friends and co-members; a card (name and avatar, `hollow-card1`,
  signed by the master) to either side of a pending friend request; nothing to
  anyone else or to a revoked device (A28, decided by Vitalik). Admitted meeting
  participants get each other's card over the meeting's MLS group, and a joiner
  shows its card to the members it asks. A friend request's card is sealed to its
  target under a key only the two masters derive. `hollow-profile2`
  signs all eleven profile fields and every ingest path requires it (N1); a card
  must name its sender's own master.
- Phase C (`daa9917f`). The join request, snapshot, refusal and resolution count
  only inside `JoinSealed` boxes (`Lane::Join`; `node/sealed_box.rs`: X25519,
  HKDF-SHA256, AES-256-GCM). A request is sealed to the members with a reply key of
  the joiner's own, every answer to that reply key, each box bound to the server and
  the devices at both ends. The `~join` ring holds only boxes, member sync answers
  ride Olm, and invite links carry `key=`, so a server id alone no longer asks.
- Reply-key answers (`54aef252`). A sync answer for a server we are still joining
  counts only from our reply key, never over Olm.
- The join lock (`7b3cb37f`). Phase C's join key never changed, so a removed member
  would have kept reading requests and answering them. Each server now has a door
  key every member holds and a change key only its owner, admins and mods hold,
  under one number; the relay keeps the chain of public halves as a notice board and
  takes a new link only when the current change key signed it. A kick, ban or
  demotion moves the lock at once, a voluntary leave when an owner, admin or mod is
  next online. A request is sealed to the newest door and the invite key together;
  every answer is sealed from the member's newest door, and the joiner judges it
  against a lock read it asked for after the answer arrived, so an answer from a
  door that moved is never read. A refusal no longer ends a join, and the joiner's
  card rides inside the sealed request. The relay half (`lock_get`, `lock_put`,
  snapshot codec v4) was deployed on 2026-09-29, ahead of any 0.12 client.

Found on the way, not security: at first contact Olm glare crossed sessions and
lost what was sent in that window (fixed in `3eccd2f6`), and a mutual friend request
whose accept landed first froze a different stamp on each side (fixed in `4dbb504b`).

What the relay still reads is routing, which claim C-24 leaves to it: device ids,
room names and who is in them (every device of an identity joins its
`inbox:{master}` room, so the relay can group one person's devices), sizes and
timing; the 0x02 stream header's transfer id (the committed file id); a share room's
root hash; data-channel SDP (`Rtc*`, `RtcShare*`); a friend request's signed device
list and key bundle; KeyPackages, KeyPackage requests and epoch probes, which name
the server and a subgroup's channel id; and the lock chain's public halves, so it
sees when a lock moves. A relay can withhold a lock chain, and joins then wait, but
it cannot forge one. Accepted by Vitalik (2026-09-28): a member who leaves on its
own with a modified client that kept the door can read requests and answer them
until an owner, admin or mod is next online (its stale "you're in" is overtaken as
soon as a real member answers), and insiders can misbehave while they are members.

Still open, outside the six phases: a meeting knock carries the knocker's display
name and avatar hash, and the lobby frame the host's, in the clear in the meeting's
room; the recovery pool's frames (manifest ids, shard inventories, plans) stay with
A24 (A-D5).

## Test

Harness (node/test_harness.rs): the wiretap tests `c24_the_sibling_lane_rides_olm`,
`c24_a_plaintext_copy_of_an_olm_only_message_is_dropped`, `c24_server_traffic_rides_mls_or_olm`,
`c24_a_restricted_channel_hint_rides_its_subgroup`, `c24_a_dm_room_is_named_by_the_two_master_keys`,
`c24_file_and_asset_traffic_rides_olm`, `c24_share_control_opens_only_with_the_link_key`,
`c24_a_profile_never_rides_in_the_clear`, and wiretaps on `parked_join_completes_with_zero_overlap`
and `file_request_gate_refuses_stranger_and_serves_guest_public`;
`authz_a_dm_typing_dot_shows_only_from_a_friend`, `authz_a_full_profile_goes_only_to_someone_we_know`,
`authz_a_card_or_a_relayed_profile_speaks_only_for_its_owner`,
`authz_a_join_request_counts_only_in_the_join_box`, `authz_only_a_member_is_served_the_op_log`
(extended: a member is served over Olm, never in the clear),
`authz_a_pending_join_takes_its_answer_only_from_its_reply_key`; the cards
`friend_request_carries_a_sealed_card`, `meeting_participants_see_each_others_card_once_admitted`,
`a_joiner_shows_its_card_to_the_members_it_asks`, `a_meeting_card_claiming_another_master_is_not_stored`;
the join lock `join_lock_a_removed_members_door_neither_reads_nor_answers_a_join`,
`join_lock_a_lock_read_before_a_removal_is_read_again_before_an_answer_counts`,
`join_lock_an_answer_from_a_door_that_moved_is_answered_again`,
`join_lock_moves_after_a_leave_and_a_leavers_refusal_never_ends_the_join`,
`join_lock_a_stale_admission_is_overtaken_by_the_real_one`, `join_lock_a_demoted_mod_loses_the_change_key`,
`join_lock_a_member_puts_the_chain_back_on_a_relay_that_forgot_it`,
`join_lock_the_owner_resets_a_rogue_mods_fork`, `join_lock_a_joiner_seals_only_to_a_chain_its_owner_signed`,
`join_lock_the_card_rides_inside_the_request`. Tests that injected carried or join
traffic in the clear now send it through a node's own session (`carry_as`,
`TestCarry`) or seal it (`sealed_to_members`, `sealed_to_joiner`), since a plaintext
injection would pass without reaching its rule.

Unit: `dm_room` (seven, the card pair key included), `share_handler::share_control_opens_only_with_the_link_key`,
`profile_card::a_sealed_card_naming_another_master_is_refused`,
`crypto_handler::profile_payload_is_collision_resistant` and
`card_and_profile_signatures_do_not_stand_in_for_each_other`, `sealed_box` (eight),
`join_lane` (four), `join_lock` (eight), the CRDT matrix
(`the_join_key_lands_converges_and_rides_a_checkpoint`,
`a_join_lock_op_is_judged_by_who_may_move_the_lock`), and the C++
`relay-uws/test/test_join_lock.cpp` (36 checks on the same pinned signed vector) with
the snapshot codec round trip.

Scripted mutation passes put each rule back one at a time and every one failed its
test: each rule of phases 1 and 2, eleven for phases E and F, eleven for phase D,
sixteen for phase C, the reply-key rule, twenty for the join lock. The full suite
passed 1097 of 1097 twice after the join lock.
