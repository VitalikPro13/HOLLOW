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
Fix commit:  pending (fix/media-strip-267-269, fourth commit)
Disclosure:  private until the release
```

## Description

The strip removes the places it knows. Some formats keep a location elsewhere: Google's
camera motion tracks (handler `camm`) carry GPS packets, Novatek dashcams write a `gps ` box
in `moov` or at the top level, and Matroska files can carry Attachments (a photo with its
own Exif) and Chapters (which may name a place). All five went out as they were.

## Fix

A `camm` track is treated as a timed-metadata track: removed with its samples, or its
fragments' runs zeroed (HOL-SEC-305). A `gps ` box at the top level, in `moov`, or beside a
HEIF's items becomes `free` padding of the same size. Matroska Attachments and Chapters
become Void elements of the same length, like Tags. A file without these keeps the bytes it
kept before.

Still not removed: subtitle or text tracks some dashcams fill with GPS (they cannot be told
from real subtitles by their container), and GPS blocks a dashcam keeps inside `mdat`
(the `gps ` box that indexes them goes).

## Test

`media_strip::tests::other_location_carriers_lose_the_location` (ported from the 0.16
walker's test, each case checked byte for byte: only the carrier's bytes change),
`a_forwarded_fragment_or_sequence_loses_its_location` (a `camm` file received and sent on),
and `strip_answers_as_0_14_did`.
