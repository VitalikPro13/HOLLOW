# HOL-SEC-173: A crafted WebP thumbnail in a stranger's friend-request card stopped the receiver's node

```
ID:          HOL-SEC-173                 Status: Fixed (2026-10-22, wave g13, local commit 09028880),
                                          ships with 0.13
Severity:    High                        (Impact M-H: the node's event loop task ends, so the app keeps a
                                          live window with no network until it is restarted, and the
                                          attacker can repeat it; Exploitability H: any identity that can
                                          send a friend request, no relationship needed)
Category:    Data validation (remote-triggerable panic in a third-party decoder)
Component:   rust/hollow_core/src/node/image_convert.rs (reencode_peer_thumb, without_unwinding),
             node/image_check.rs (new), node/image_gate.rs (new), node/swarm.rs (FriendRequest card)
Boundary:    TB-2 (peer <-> peer)
Traces to:   AS-11 (availability); AR-28; same class as HOL-SEC-007; AT-5 (parsers of peer bytes)
Attacker:    P-03 stranger who knows a master id
Found:       2026-10-22 (wave g13, track i-image-check, by fuzzing the new image check)
```

## Description

Since 0.12.0 a pending friend request carries a sealed card with a small WebP thumbnail, and
the receiver re-encodes every peer thumbnail through the pure-Rust `image-webp` decoder
before Dart sees it (HOL-SEC-151). `image-webp` 0.2.4, the newest release, panics on some
malformed WebP inputs. The re-encode ran without catching the panic, so a crafted thumbnail
in a stranger's friend request unwound the task that was decoding it, which is the node's
event loop. Every later frame then went nowhere, as in HOL-SEC-007. Released versions 0.12.0
to 0.12.2 are affected.

## Fix

- Every decode of peer bytes runs inside `without_unwinding`, which turns a decoder panic
  into a refusal, never an unwind (the thumbnail re-encode, sending-side decodes, animation
  frames).
- `node/image_check.rs` fully decodes every frame of PNG, APNG, JPEG, GIF and WebP within
  side, pixel, frame, memory and time budgets before any native decoder (Skia and its
  libwebp) sees peer bytes; anything else is refused. `node/image_gate.rs` runs the check
  off the event loop and is the only way peer image bytes cross to Dart. This also closes
  AR-28. HEIC and AVIF photos are never drawn as images; they travel as plain file cards until the sender converts them.

## Residual risk

`image-webp` itself still panics on these inputs; the panic is contained. The upstream
report is held until 0.13 ships (reported upstream after release).

## Test

`a_webp_that_panics_the_decoder_is_refused_not_unwound` (node/image_convert.rs, eight
fixture inputs that panic the decoder), `a_decoder_panic_is_a_refusal` and
`mutated_corpus_never_panics_or_hangs` (node/image_check.rs); the cargo-fuzz target
`rust/hollow_core/fuzz/fuzz_targets/image_check.rs`. Mutation pass 34/35 (one rule enforced
in two layers, each tested alone), 22/22 in the fix round. Fleet proof on macOS, the iOS
Simulator and the Android emulator.
