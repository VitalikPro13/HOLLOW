# HOL-SEC-011: A member or friend could make every receiver store a message of any size, and long non-Latin messages were cut and lost their signature

```
ID:          HOL-SEC-011                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L-M: a message of many megabytes is stored by every member, served
                                          on in sync and rendered by every client that opens the channel; a long
                                          non-Latin message fails its own signature once re-served; Exploitability M:
                                          needs a modified client and membership or friendship)
Category:    Input validation (no size bound on remote content); integrity (content clipped after verification)
Component:   rust/hollow_core/src/node/crypto_handler.rs :: MAX_MESSAGE_BYTES, verify_message_signature_v2,
             check_backfill_signature
             rust/hollow_core/src/node/swarm.rs :: live DM arm; node/fetch.rs :: push DM, edit, channel paths
             rust/hollow_core/src/node/conference.rs :: handle_inbound_chat
             lib/src/core/message_limits.dart, the composer and both edit fields
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-09; candidate C11 (evidence channel:S18)
Attacker:    P-05 member of a server, P-04 friend, each with a modified client
Found:       2026-09-26, phase B channel pass; confirmed by reading 2026-09-27
```

## Description

Nothing bounded the size of a message body on the live channel paths, the
channel and DM sync paths, edits, or meeting chat. A member with a modified
client could post a text of many megabytes (the relay frame limit is 64 MB)
that every member stored, served on through sync and tried to render.

The live DM and push paths did the opposite: they clipped the text to 4,000
BYTES after checking its signature. The composer allows 4,000 CHARACTERS, which
is up to about 16,000 bytes in Cyrillic, CJK or emoji, so ordinary long
messages were cut. The clipped row no longer matched its signature, so every
device it was later served to refused it, and the recipient's own copy was not
the text the sender signed.

## Reproduction

`message_over_the_size_limit_never_verifies` (node/crypto_handler.rs tests),
`oversized_message_is_dropped_whole_on_every_path` (node/message_ops.rs tests)
and `push_dm_is_stored_whole_or_dropped_never_clipped` (node/fetch.rs tests).

## Fix

- One protocol limit, `MAX_MESSAGE_BYTES` = 64 KiB, the same number as Dart's
  `kMaxMessageBytes`. The composer still allows 4,000 characters; only emote
  walls, long ZWJ emoji runs and combining-mark text can reach 64 KiB.
- `verify_message_signature_v2` fails a longer body, so every signed receive
  path (live, push, sync, edits) drops it whole. `check_backfill_signature`
  reports it as its own verdict, `Oversized`, so the log does not call it a
  forgery. Meeting chat, which is not signed, checks the limit itself.
- Nothing clips any more: `clip_text` is gone.
- The sender refuses such a body at the FFI (send, edit, file caption, meeting
  chat); the composer and both edit fields stop typing and cut a paste at the
  limit, counting an emote as its full wire token; all three send paths refuse
  a longer composer text with a toast (the picker can still insert past it).
- Relay: no change. The topic ring is bounded by bytes (1 MB per channel), DM
  and 0x09 buffers by count with a 512 MB global budget, and senders never
  clipped, so the relay already carried whole messages.

## Variants

- A legacy row longer than 64 KiB (possible only for our own sent messages
  before this fix) is refused by peers when served, and reads as unverified in
  the archive viewer.
- Profile fields have the same shape: the plaintext `ProfileUpdate` arm clips
  them to 64/96/256 BYTES while the UI allows 32/48/128 CHARACTERS, so an emoji
  or CJK display name can be cut, and a cut after the signature check would
  make the relayed profile fail verification. To check with class N.

## Test

The three tests fail with the size rule removed (the live channel path stores
an oversized post, the push path clips an 8,000-byte Cyrillic DM) and pass with
the fix. Full suite green.
