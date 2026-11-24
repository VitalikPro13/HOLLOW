# HOL-SEC-306: places a location is kept that the metadata strip never visited

```
ID:          HOL-SEC-306                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, 0.14.3 at Vitalik's choice
Severity:    Low                         (Impact M: a location reaches recipients from the
                                          files that keep one there; Exploitability: none
                                          needed, it happens on send, for a few camera and
                                          dashcam formats)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs (gps_track, strip_isobmff_video,
             strip_moov, strip_heif, strip_segment)
Boundary:    TB-2
Traces to:   R-AR-11, C-FILES-03
Attacker:    any recipient
Found:       2026-11-24 (hostile review of track S7b, pre-existing list; confirmed by the
             S7b builder's test and this track's)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, fourth and fifth commits)
Disclosure:  private until the release
```

## Description

The strip removes the places it knows. Some formats keep a location elsewhere: Google's
camera motion tracks (handler `camm`) carry GPS packets, Novatek dashcams write a `gps ` box
in `moov` or at the top level, and Matroska files can carry attached files (a photo with
its own Exif). All four went out as they were.

## Fix

A `camm` track is treated as a timed-metadata track: removed with its samples, or its
fragments' runs zeroed (HOL-SEC-305). A `gps ` box at the top level, in `moov`, or beside a
HEIF's items becomes `free` padding of the same size. A Matroska attached file becomes a
Void element of the same length unless it is a font. A file counts as a font when its media
type is a font type (`font/*`, `application/x-truetype-font`, `application/vnd.ms-opentype`
and the other legacy names), or when it has no type or `application/octet-stream` and its
name ends in `.ttf`, `.otf`, `.ttc`, `.otc`, `.woff` or `.woff2`. Subtitles need their fonts, and a font holds no
capture details. Pictures and files of any other or unknown type go. A CRC-32 of the
Attachments element goes with them, since it no longer matches. Chapters stay, by Vitalik's
call, because viewers use them to move through the video. A file without these keeps the bytes it
kept before.

Still not removed: subtitle or text tracks some dashcams fill with GPS (they cannot be told
from real subtitles by their container), the GPS blocks a dashcam keeps inside `mdat` (the
`gps ` box that indexes them goes, the blocks stay), and Matroska chapter titles, which a
person may have named after a place.

## Test

`media_strip::tests::other_location_carriers_lose_the_location` (ported from the 0.16
walker's test, each case checked byte for byte: only the carrier's bytes change),
`rev3_mkv::rev3_an_mkv_keeps_its_subtitle_fonts_and_chapters`,
`tests::rev3_an_mkv_image_attachment_is_still_voided` (each font and non-font rule),
`tests::rev3_a_real_mkv_keeps_its_font_and_chapters_and_loses_its_cover` (files ffmpeg wrote),
`a_forwarded_fragment_or_sequence_loses_its_location` (a `camm` file received and sent on),
and `strip_answers_as_0_14_did`.
