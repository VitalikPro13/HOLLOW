# HOL-SEC-302: the metadata strip held about 24 bytes for every sample of a GPS track

```
ID:          HOL-SEC-302                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, 0.14.3 at session A's choice
Severity:    Low                         (Impact L: sending one crafted video takes about 24
                                          times its size in memory, enough to end the app on
                                          a phone; Exploitability L: the user has to send or
                                          pass on a crafted video someone gave them)
Category:    Denial of service (memory amplification on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (sample_tables, table_fits,
             SampleTables::walk, strip_trak, strip_heif, item_extents)
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
no range is held per sample. Each table is read only inside its own box (a count past the
box is refused, where 0.14 read on into other boxes, again for every track) and held at
the width the file wrote it: four bytes for every four of a size or 32-bit offset table,
eight for every twelve of the chunk runs. The tables therefore take at most their own
size, and the tracks' tables never overlap. A HEIF's item extents are counted in one pass
and zeroed in a second over a copy of the table as read, never held as ranges. The
tables are read before any byte is zeroed, so every whole file's answer and output is the
one 0.14 gave; only a table longer than its box is refused now.

## Test

`media_strip::tests::a_fixed_size_sample_table_is_walked_without_holding_it` (a 4 MiB track
of one-byte samples strips holding under a quarter of the file's size, counted per thread),
`a_sample_table_longer_than_its_box_is_refused`, `rev_sample_tables_hold_at_most_twice_the_file`,
`rev_many_metadata_tracks_cost_what_the_file_holds`,
`rev_a_heic_extent_list_holds_at_most_twice_the_file` (found by the hostile review),
`an_mp4_loses_its_location_and_keeps_every_offset`, and `strip_answers_as_0_14_did`.
