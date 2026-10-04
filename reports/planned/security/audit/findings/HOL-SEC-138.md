# HOL-SEC-138: A kicked or banned member, or a removed device, stayed in the server's voice call

```
ID:          HOL-SEC-138                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: it keeps hearing and seeing the call and its share audio; Exploitability M: a member that ignores its own removal)
Category:    Access control
Component:   rust/hollow_core/src/node/voice_handler.rs (unseat_unqualified, voice_join_refusal), lib/src/core/services/frame_cryptor_service.dart
Boundary:    TB-2
Traces to:   phase E+F media C-MEDIA-01; claims C-14, C-17; server twin of HOL-SEC-123
Attacker:    P-06 removed member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Voice participants were only removed on their own leave or a relay presence change, so a
kick, a ban, the loss of a restricted channel's label or grant, or a roster removal left the
device's peer connections, screen_watch and share audio running at every honest member, and
its old-epoch frames kept decrypting from the key ring.

## Fix

Every remote seat in every server voice call is judged again by `voice_join_refusal` (now
also refusing revoked and bare-master devices) at the loop head; a failing seat leaves the
call as if its device had left, so Dart closes its peer, cryptors and share audio; old key
slots are overwritten with random bytes 15 s after a rotation.

## Test

`authz_a_kicked_member_loses_its_voice_seat_at_every_participant`,
`authz_a_member_who_loses_sight_of_a_voice_channel_loses_its_seat`,
`authz_a_device_its_roster_drops_loses_its_voice_seat`,
`authz_a_voice_seat_is_judged_again_after_it_was_granted`, Dart
`frame_cryptor_keys_test.dart` stale-slot tests. Mutation Rust 5/5, Dart 16/16 (with HOL-
SEC-139..142).
