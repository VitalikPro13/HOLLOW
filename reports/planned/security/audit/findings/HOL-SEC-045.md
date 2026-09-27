# HOL-SEC-045: Encrypted voice signaling was credited to whoever the relay named

```
ID:          HOL-SEC-045                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: the relay could replay a member's voice join, leave or
                                          connection setup as another member's, confusing who is in a call; no
                                          media content; Exploitability H for the relay operator only)
Category:    Spoofing (sender attribution)
Component:   rust/hollow_core/src/node/swarm.rs :: MlsChannelMessage arm, VoiceChannel* envelopes
Boundary:    TB-1 (relay)
Traces to:   C-09; candidate D9 (evidence S-23, media X-3)
Attacker:    P-01 relay operator
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

Voice-channel signaling decrypted from a server group is routed by the device
the relay says sent the frame, which is the right id for a reply. It was never
compared with the leaf that encrypted the frame, so a relay could hand one
member's signaling to another member's slot.

## Reproduction

`authz_voice_frames_over_mls_come_from_their_leaf` (node/test_harness.rs).

## Fix

A `VoiceChannel*` envelope from a group is dropped unless the leaf that
encrypted it is the device the relay named. Honest senders always match: every
leaf is now its own device (HOL-SEC-041).

## Variants

- The plaintext copy of voice presence still takes the relay's word; moving it
  under a device signature is class A.

## Test

The test fails with the comparison removed and passes with it. Full suite
green.
