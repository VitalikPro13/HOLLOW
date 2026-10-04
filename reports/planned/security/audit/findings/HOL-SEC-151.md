# HOL-SEC-151: Peer thumbnails reached Flutter's image decoder unchecked

```
ID:          HOL-SEC-151                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H if the decoder has a memory bug; Exploitability M: any peer who can send a file card or link card)
Category:    Attack surface
Component:   rust/hollow_core/src/node/image_convert.rs (reencode_peer_thumb, peer_thumb_for_display), api/network.rs, api/storage.rs, file_handler.rs
Boundary:    TB-2
Traces to:   phase E+F files C-FILES-04
Attacker:    P-04 friend, P-05 member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

File-card blur thumbs and video posters and link-card thumbs were decoded by Skia when a
message painted, bypassing the Rust header check.

## Fix

A header thumb must be a small WebP at ingest, and every peer thumb crossing into Dart is
decoded by pure-Rust `image-webp` and re-encoded by our own encoder, or dropped (at the FFI
crossing, since the stored bytes sit inside their author's signature).

## Residual risk

Asset-rail blobs and auto-downloaded images still reach Skia: AR-28.

## Test

`a_peer_thumb_is_reencoded_or_dropped`, `a_card_thumb_reaches_dart_only_reencoded`,
`a_file_header_thumb_reaches_dart_only_reencoded`,
`a_stored_file_thumb_reaches_dart_only_reencoded`,
`a_header_thumb_must_be_a_placeholder_sized_webp`.
