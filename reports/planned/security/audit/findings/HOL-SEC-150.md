# HOL-SEC-150: Sent videos and some photos carried the sender's location

```
ID:          HOL-SEC-150                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: home GPS and capture details to every recipient; Exploitability: none, it happens on send)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs, file_handler.rs, api/crdt.rs, api/share.rs
Boundary:    TB-2
Traces to:   phase E+F files C-FILES-03
Attacker:    any recipient
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Videos went out byte for byte; HEIC went out as a file with its Exif; the photo conversion
fallback, the vault upload and large-file shares sent original bytes.

## Fix

`media_strip` removes location, camera and time metadata in place without decoding (MP4/MOV,
WebM/MKV, AVI, HEIF/AVIF, JPEG, PNG, WebP) on every send read; media of a covered type that
cannot be parsed is refused with a message.

## Residual risk

Timed GPS tracks in fragmented MP4, subtitle tracks, and TIFF/RAW sent as files keep their
metadata.

## Test

`dm_video_send_strips_location_before_it_leaves`,
`a_photo_the_encoder_cannot_read_still_leaves_without_its_gps`,
`a_large_video_send_is_shared_from_a_cleaned_copy`,
`every_send_read_goes_through_the_strip`, `media_strip` unit tests. Mutation Rust 18/18,
Dart 4/4 with HOL-SEC-149.
