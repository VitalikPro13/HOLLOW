# HOL-SEC-301: a WebP of many EXIF chunks made the metadata strip run for hours

```
ID:          HOL-SEC-301                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: the send of that file never finishes and
                                          holds a blocking thread and a core for hours;
                                          Exploitability L: the user has to send or pass on
                                          a crafted WebP someone gave them)
Category:    Denial of service (algorithmic complexity on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (exif_orientation, strip_webp)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-04, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-24 (builder of track fix-media-strip, while fixing HOL-SEC-267..269)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  d2cd7ae47
Disclosure:  published with 0.14.3
```

## Description

The WebP strip reads the orientation out of every EXIF chunk. Each read walked as many IFD
entries as the chunk's TIFF header claimed (up to 65,535), even past the end of the chunk,
where no entry can match. A chunk of 16 bytes could claim tens of thousands of entries, so
a few megabytes of such chunks cost billions of steps. The strip runs on every photo the
user sends, including a file received from someone else and sent on, a vault upload and a
large-file share.

## Fix

`exif_orientation` stops at the first entry that does not fit in the block. Entries past
the end never matched, so every answer is the one 0.14 gave; a chunk now costs what it
holds.

## Test

`media_strip::tests::a_webp_of_many_exif_chunks_takes_one_pass` (500,000 chunks under 20 s;
an orientation behind an overstated count is still found),
`a_forwarded_crafted_file_is_refused_or_cleaned_in_time` (a received file sent on), harness
`fms_a_crafted_file_sent_on_is_refused_or_cleaned_in_time` (the photo path through
`SendFile`), and `strip_answers_as_0_14_did` (JPEG and WebP fixtures cut and changed at
every byte get 0.14's answer).
