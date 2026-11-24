# HOL-SEC-305: a fragmented video sent its GPS track's samples untouched

```
ID:          HOL-SEC-305                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, 0.14.3 at Vitalik's choice
Severity:    Medium                      (Impact M: the sender's GPS trace reaches every
                                          recipient; Exploitability: none needed, it happens
                                          on send for any fragmented video with a timed GPS
                                          track)
Category:    Privacy
Component:   rust/hollow_core/src/node/media_strip.rs (strip_isobmff_video,
             fragment_tracks, strip_fragments, fragment_runs)
Boundary:    TB-2
Traces to:   R-AR-11, C-FILES-03
Attacker:    any recipient
Found:       2026-11-24 (hostile review of track S7b, pre-existing list)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, fourth commit)
Disclosure:  private until the release
```

## Description

A timed-metadata track is where cameras and phones keep a GPS trace, and the strip removes
it with its samples. In a fragmented MP4 or MOV the samples sit in the `moof` runs that
follow the movie header, and the strip did not walk those: it cleared the track's user
data and times but sent its samples as they were.

## Fix

In a file with fragments, the strip reads which tracks are timed metadata (handler `meta`)
and their `trex` default sample sizes before it changes anything. For every `moof` (read
from a copy) it walks each track fragment's runs as ISO/IEC 14496-12 places them: the base
is the `tfhd` base offset, else the `moof` when the fragment says so, else the end of the
previous track fragment's data (the `moof` for the first); a run starts at the base plus its
data offset, else where the previous run of the fragment ended; its samples lie end to end,
sized by the run's records, else the `tfhd` default, else the `trex` default. Every run of
a timed-metadata track (`meta`, or `camm` per HOL-SEC-306) is zeroed, charged to the file's budget (HOL-SEC-269). A run whose
place or size cannot be known, or a `tfhd` or `trun` longer than its box, refuses the file.
The track itself stays, as in 0.14; a movie without a timed-metadata track keeps every
byte it kept before.

## Test

`media_strip::tests::a_fragmented_movie_loses_its_gps_samples` (each way of naming the
place, a missing size refused, a run longer than its box refused, a movie without such a
track unchanged), `a_forwarded_fragment_or_sequence_loses_its_location` (a received file
sent on), and `strip_answers_as_0_14_did`.
