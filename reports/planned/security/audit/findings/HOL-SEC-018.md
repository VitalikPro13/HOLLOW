# HOL-SEC-018: A member could pin a post below everything that followed it and post past slow mode

```
ID:          HOL-SEC-018                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: a post that stays at the bottom of a channel or DM until its
                                          date passes, and bursts that slow mode should have refused; Exploitability
                                          M: a modified client and membership or friendship)
Category:    Trust in a sender-chosen value (the signed timestamp)
Component:   rust/hollow_core/src/node/crypto_handler.rs :: message_ts_fits, verify_message_signature_v2,
             check_backfill_signature
             rust/hollow_core/src/node/message_ops.rs :: live_channel_moderation_drop, SlowModeClock
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; candidate C7 (evidence channel:S8); decision 2b
Attacker:    P-05 member, P-04 friend, each with a modified client
Found:       2026-09-26, phase B channel pass; confirmed by reading 2026-09-27
```

## Description

A message's timestamp is chosen and signed by its sender, and history is
ordered by it. Nothing bounded it, so a post dated in the future sorted below
every later message until that time came. Slow mode compared a post with the
sender's earlier posts by the same signed timestamps, so a sender who spaced
its stamps a window apart, forward or back, could post as fast as it liked.
Judging slow mode by the receiver's clock alone would have dropped honest
posts the relay replays after a reconnect.

## Reproduction

`message_dated_past_our_clock_never_verifies` (node/crypto_handler.rs tests)
and `slow_mode_judges_fresh_posts_by_our_clock` (node/message_ops.rs tests).

## Fix

- A message dated more than ten minutes past our clock fails verification,
  live, pushed or synced (`BackfillSig::FutureDated`), DMs included. Relay auth
  already holds every connected client's clock to 60 seconds, so no honest
  message comes near the bound.
- Slow mode judges a fresh post (dated inside the window) by when it reached
  us, per sender and channel, so future stamps no longer space a burst; an
  older post, such as a relay-ring replay, is still judged by its own stamp
  against stored history, and a second copy of the same post is not a
  violation.

## Variants

- A sender can still backdate posts; they land up in history where they were
  dated, not at the bottom.
- The push path drains buffered frames, all replays, and keeps judging them by
  their stamps.

## Test

Both tests fail with the old rules (the future-dated message verifies; the
spaced second post is stored) and pass with the fix. Full suite green.
