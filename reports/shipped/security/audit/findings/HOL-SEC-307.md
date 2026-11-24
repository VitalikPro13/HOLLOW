# HOL-SEC-307: a HEIF-branded file never had its movie walked

```
ID:          HOL-SEC-307                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, 0.14.3 at Vitalik's choice
Severity:    Low                         (Impact M: a HEIF image sequence's movie user data
                                          and timed GPS track reach every recipient;
                                          Exploitability L: few files carry both)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs (strip_heif)
Boundary:    TB-2
Traces to:   R-AR-11, C-FILES-03
Attacker:    any recipient
Found:       2026-11-24 (hostile review of track S7b, pre-existing list)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, fourth commit)
Disclosure:  private until the release
```

## Description

A photo whose `ftyp` names a HEIF brand is cleaned by the HEIF strip, which removes the
Exif and XMP items and top-level `udta` and `uuid` boxes. A HEIF image sequence (brands
`msf1`, `heis`, `avis`) also holds a movie, with tracks and user data of its own, and the
HEIF strip never walked it.

## Fix

When such a file holds a `moov`, the HEIF strip walks it exactly as the video strip does
(times zeroed; `udta`, `meta` and `uuid` boxes freed; timed-metadata tracks removed with
their samples, or their fragments' runs zeroed per HOL-SEC-305), before it strips the
items. A HEIF without a movie keeps every byte it kept before.

## Test

`media_strip::tests::a_heif_with_a_movie_loses_the_movies_location`,
`a_forwarded_fragment_or_sequence_loses_its_location`, and `strip_answers_as_0_14_did`.
