# HOL-SEC-269: crafted MP4 and HEIF tables made the metadata strip run for hours

```
ID:          HOL-SEC-269                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: the send of that file never finishes and
                                          holds a blocking thread and a core for hours;
                                          Exploitability L: the user has to send or pass on
                                          a crafted video or HEIC someone gave them)
Category:    Denial of service (algorithmic complexity on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (SampleTables::walk, item_extents,
             strip_trak, strip_heif)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-03, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-23 (builder of track S7b, session B)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  ef8fd4e64, 73f9d9e06
Disclosure:  published with 0.14.3
```

## Description

Two table walks in the strip cost the product of two sizes a file chooses:

- A timed GPS track is found through its sample tables. A run of chunks with no samples
  still visited every chunk it named, and runs may name the same chunks again, so a few
  megabytes of runs and chunk offsets cost billions of steps.
- A HEIF's Exif and XMP items are found through `iloc`. An extent written with no fields
  takes no bytes, so each item could list 65,535 of them for free; and every extent looked
  its item up in the list of metadata items, so many items times many extents cost the
  same again.

## Fix

A run of empty chunks costs one step: it reads no sample and only has to name chunks the
offset table holds. An item whose extents have no fields costs one step: it is refused if
it is a metadata item, as before, and skipped otherwise. Each item looks itself up once,
in a set. These answers are 0.14's for every file, whole or damaged.

Samples and extents may also lie over each other, and each one was zeroed in full: an
8 MiB file could ask for terabytes of zeroing. One file now zeroes at most twice its
length plus 4 KiB (`Budget`, charged by every sample and extent before it is zeroed);
past that the file is refused. Honest metadata never overlaps, so it covers the file at
most once.

## Test

`media_strip::tests::crafted_tables_take_one_pass` (150,000 runs over 150,000 chunks;
50,000 items of 65,535 empty extents; 60,000 Exif items against 262,140 extents and
against 300,000 items; each under 20 s, and the refusals 0.14 gave), `a_forwarded_crafted_file_is_refused_or_cleaned_in_time`
(a received file sent on), harness
`fms_a_crafted_file_sent_on_is_refused_or_cleaned_in_time` (a received file kept at rest,
sent on through `SendFile`; the node sends the next file), `metadata_may_cover_the_file_at_most_twice`,
`rev_a_metadata_track_whose_chunks_share_an_offset_takes_one_pass`,
`rev_a_heic_whose_exif_extents_overlap_takes_one_pass` (found by the hostile review), and
`strip_answers_as_0_14_did`.
