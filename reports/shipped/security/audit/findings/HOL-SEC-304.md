# HOL-SEC-304: a GIF cut inside its header was sent without its metadata removed

```
ID:          HOL-SEC-304                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, rides 0.14.3
Severity:    Info                        (Impact L: a GIF of at most 780 bytes goes out
                                          exactly as it was, whatever its trailing bytes hold;
                                          Exploitability L: only the vault upload sends such
                                          a file, since the photo path's image check refuses
                                          it and Share needs a far larger file)
Category:    Fail-open privacy check
Component:   rust/hollow_core/src/node/image_convert.rs (strip_gif_metadata)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-05, C-FILES-03
Attacker:    none needed (a cut file the user sends)
Found:       2026-11-24 (hostile review of fix/media-strip-267-269, outside its lines)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, third commit)
Disclosure:  private until the release
```

## Description

The GIF strip returned its input unchanged when the file was shorter than the 13-byte
header or its global colour table ran past the end. Every other format refuses a file it
cannot read to the end, so a GIF cut that early was the one cut file that left as it was.

## Fix

A GIF cut inside its header or its colour table is refused (`media_strip::REFUSED` for the
sender). A GIF cut later still ends the copy where it always did.

## Test

`media_strip::tests::a_gif_cut_inside_its_header_is_refused` (cut at 6, 12, 13 and 18
bytes, and a colour table the file does not hold; a whole header and table still strip),
`a_forwarded_crafted_file_is_refused_or_cleaned_in_time` (`cut.gif`, a received file sent
on), and `strip_answers_as_0_14_did`.
