# HOL-SEC-302: the metadata strip held about 24 bytes for every sample of a GPS track

```
ID:          HOL-SEC-302                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, 0.14.3 at session A's choice
Severity:    Low                         (Impact L: sending one crafted video takes about 24
                                          times its size in memory, enough to end the app on
                                          a phone; Exploitability L: the user has to send or
                                          pass on a crafted video someone gave them)
Category:    Denial of service (memory amplification on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (sample_tables, SampleTables::walk,
             strip_trak)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-04, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-24 (builder of track fix-media-strip, while fixing HOL-SEC-267..269)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, second commit)
Disclosure:  private until the release
```

## Description

A timed GPS track is removed with its samples, which the strip finds through the track's
sample tables. A table that gives every sample one fixed size names up to one sample per
byte of the file in eight bytes, and the strip spread it into a list of eight bytes per
sample, then held the place of every sample (sixteen more) before zeroing any. A video of
one-byte samples cost about 24 times its own size.

## Fix

A fixed size stays one number, and the samples are zeroed as the tables are walked, so
nothing is held per sample. What the strip keeps is the tables it reads (at most about
twice their size in the file). The tables are read before any byte is zeroed, so every
answer and every output byte is the one 0.14 gave.

## Test

`media_strip::tests::a_fixed_size_sample_table_is_walked_without_holding_it` (a 4 MiB track
of one-byte samples strips holding under a quarter of the file's size, counted per thread),
`an_mp4_loses_its_location_and_keeps_every_offset`, and `strip_answers_as_0_14_did`.
