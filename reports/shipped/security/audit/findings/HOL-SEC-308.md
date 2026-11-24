# HOL-SEC-308: a HEIC motion photo's clip kept its location

```
ID:          HOL-SEC-308                 Status: Fixed (track fix-media-strip-308, 2026-11-24),
                                          embargoed, 0.14.3
Severity:    Low                         (Impact M: the clip's place and capture time reach
                                          every recipient; Exploitability L: needs a phone
                                          that records location into the clip)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs (strip_heif, strip_movie)
Boundary:    TB-2
Traces to:   R-AR-11, C-FILES-03
Attacker:    any recipient
Found:       2026-11-24 (track fix-media-strip, made sample)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-308, on fix/media-strip-267-269)
Disclosure:  private until the release
```

## Description

A motion photo taken as HEIC (Samsung Galaxy, Google Pixel) keeps its short clip, a
whole MP4 file, in a top-level `mpvd` box. The HEIF strip removed the picture's Exif
and XMP items but left the `mpvd` box as it was, so the clip went out with its movie
user data: Android writes the place a video was taken into `udta/©xyz`, beside the
capture times in its movie and track headers. A real Samsung Galaxy S22 Ultra motion
photo's clip carries that `©xyz` box.

A JPEG motion photo (Pixel `MVIMG` or Motion Photo, Samsung's `MotionPhoto_Data`
trailer) keeps its clip after the picture's end marker. Every send path already
dropped it: the photo path converts the JPEG to WebP (the decode keeps only pixels),
and the JPEG strip used on its fallback, by large-file shares and by vault uploads ends
the file at the first end-of-image marker, with the XMP naming the clip.

## Fix

The HEIF strip walks every top-level `mpvd` box's body as a movie of its own, with
offsets counted from the clip's start, exactly as a video file is walked (times zeroed;
`udta`, `meta`, `uuid` and `gps ` boxes freed; timed-metadata tracks removed with their
samples, fragments' runs zeroed), charging the file's one budget. A clip that does not
parse refuses the file. Every other byte stays: the photo's items strip as before and
the file keeps its length. A HEIC or JPEG without a clip keeps every byte it kept.

## Test

`media_strip::tests::a_heic_motion_photo_clip_loses_its_location`,
`a_real_heic_motion_photo_strips_its_clip_as_a_video` (androidx/media's Apache-2.0
`sample_MP.heic`), `a_motion_clip_that_does_not_parse_is_refused`,
`a_motion_clip_shares_the_photos_budget`, `a_jpeg_motion_photo_leaves_as_its_still_alone`,
`a_photo_without_a_clip_strips_as_before`, `a_forwarded_motion_photo_loses_its_clips_location`,
harness `fms308_a_motion_photo_sent_on_leaves_without_its_clips_location`, and
`strip_answers_as_0_14_did` (digest unchanged).
