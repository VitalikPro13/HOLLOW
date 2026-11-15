# HOL-SEC-038: Profile avatars were not checked against their signature, and stale or long profiles misbehaved

```
ID:          HOL-SEC-038                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: the relay replaced a contact's avatar with any picture; a
                                          replayed older profile renamed a member in every server we share and
                                          cleared their avatar; a 32-character CJK or emoji name was cut and then
                                          failed its signature everywhere; Exploitability M: the relay sees
                                          plaintext profile replies and can replay any profile)
Category:    Integrity (unsigned bytes); replay; input handling
Component:   rust/hollow_core/src/node/social.rs :: save_incoming_profile, profile_text_oversized,
             handle_envelope_profile_update, handle_profile_relay, store_carried_profile
             rust/hollow_core/src/storage/messages.rs :: save_profile
             rust/hollow_core/src/node/swarm.rs :: ProfileUpdate arm
             rust/hollow_core/src/api/network.rs :: update_profile
             lib/src/core/message_limits.dart, lib/src/ui/settings/pages/profile_page.dart
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-13; candidates N1, N2, N3 (evidence identity:S11, S12)
Attacker:    P-01 relay, P-05 server member
Found:       2026-09-26, phase B identity pass; confirmed by reading 2026-09-27
```

## Description

The profile signature covers the avatar by hash, but a plaintext full profile's
avatar bytes were stored without comparing them to it. `save_profile` returned
success when its freshness rule refused a stale row, so the caller rewrote member
display names from the replay, and the explicit avatar and banner clears ran
anyway. The plaintext arm cut profile text at 64/96/256 bytes before verifying,
under the editor's 32/48/128 characters, so non-Latin names failed; the MLS arm
had no limit.

## Reproduction

`authz_an_incoming_profile_keeps_only_what_its_owner_signed`,
`authz_profile_text_is_refused_whole_at_one_limit` (node/social.rs tests).

## Fix

- Avatar bytes that do not hash to the signed hash are dropped and the stored
  still is kept.
- `save_profile` reports whether the row was written; a refused stale profile
  touches nothing, clears included, and reports itself unsaved.
- One limit per field, four bytes per editor character (128/192/512 bytes, 64 for
  Twitch), in Rust and Dart. Every receive path refuses a longer profile whole,
  the sender refuses to publish one, and the editor stops at it.

## Variants

- Banner bytes, the showcase board and assets, the frame and the animations are
  outside the profile signature by design; signing them is class A work.

## Test

Each part fails with its old rule put back and passes with the fix. Full suites green.
