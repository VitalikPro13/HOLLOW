# HOL-SEC-309: Samsung's `sefd` box kept the capture time and country code

```
ID:          HOL-SEC-309                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: the capture time, the country of the
                                          phone's network and a hash of the original path
                                          reach every recipient; Exploitability L: needs a
                                          Samsung phone's video or motion photo)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs (strip_movie, strip_moov, strip_heif)
Boundary:    TB-2
Traces to:   R-AR-11, C-FILES-03
Attacker:    any recipient
Found:       2026-11-24 (track fix-media-strip-308, real Samsung Galaxy S22 Ultra sample)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  5126de3e2
Disclosure:  published with 0.14.3
```

## Description

Samsung phones close their videos, the clips inside their HEIC motion photos and their
HEIC photos with a top-level `sefd` box holding Samsung's extended data (SEF): entries
followed by a `SEFH` directory and a `SEFT` mark. The strip never named the box, so it
left with the file. A real Galaxy S22 Ultra motion photo's clip carries in it the capture
time in milliseconds (`Image_UTC_Data`), the mobile country code of the phone's network
(`MCC_Data`), a hash of the photo's original path (`Original_Path_Hash_Key`), the photo
editor's re-edit data naming an internal file path, and watermark data. ExifTool's
Samsung trailer table lists more entries the same box can carry: a time zone, embedded
preview pictures, audio (Sound & Shot), video, depth maps and dual-camera images.

## Fix

The strip turns every `sefd` box into `free` padding of the same length (type renamed,
body zeroed), as it does for `udta`, `meta`, `uuid` and `gps `: at the top level of a
video, at the top level of a motion photo's `mpvd` clip (the clip is walked as a video),
inside `moov`, and at the top level of a HEIF, the places Samsung writes it. A `sefd`
inside a movie's `udta` or `meta` already went with its parent; one deeper in a track
(`trak`, `mdia`) or inside a HEIF's own `meta` stays. The box's content is never read, so no file is refused that was
not refused before. Padding rather than a zeroed body because the renamed box no longer
tells a reader the file came from a Samsung phone, and every offset, the file id's size
and a share's manifest stay valid. A file without a `sefd` box keeps every byte it kept.

## Test

`media_strip::tests::a_samsung_sef_box_becomes_padding`,
`a_samsung_photo_and_its_clip_lose_their_sef_box`,
`a_forwarded_samsung_file_loses_its_sef_box`, harness
`fms309_a_samsung_video_sent_on_leaves_without_its_sef_box`, and
`strip_answers_as_0_14_did` (digest unchanged). The real S22 Ultra motion photo
(g0ddest/sm_motion_photo, MIT) was checked with a temporary test and not committed: its
SEF data names a real country code and capture time.
