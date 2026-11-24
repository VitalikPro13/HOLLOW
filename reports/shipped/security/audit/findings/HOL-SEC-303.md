# HOL-SEC-303: the metadata strip's box lists held five times the file

```
ID:          HOL-SEC-303                 Status: Fixed (track fix-media-strip, 2026-11-24),
                                          embargoed, rides 0.14.3
Severity:    Low                         (Impact L: sending one crafted video or HEIC takes
                                          about five times its size in memory, enough to end
                                          the app on a phone; Exploitability L: the user has
                                          to send or pass on a crafted file someone gave them)
Category:    Denial of service (memory amplification on peer-supplied bytes)
Component:   rust/hollow_core/src/node/media_strip.rs (boxes, walk_boxes, Boxes)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-04, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-24 (hostile review of fix/media-strip-267-269, outside its lines)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  pending (fix/media-strip-267-269, third commit)
Disclosure:  private until the release
```

## Description

The MP4 and HEIF strips list the boxes of each level before they act on them. Each entry
took 40 bytes, and a box can be as small as 8, so a file of empty boxes held five times
its size in lists; the vectors also grew by doubling.

## Fix

A list keeps each box's start, kind and header length (13 bytes) and finds its end at the
next box's start. The boxes are counted first, so each list is allocated exactly once. A
list is now at most about 1.6 times the bytes it covers, and the lists that are alive at
once cover nested ranges. The boxes and every answer are unchanged.

## Test

`media_strip::tests::rev_a_box_list_holds_at_most_twice_the_file` (found by the review),
`a_box_list_takes_the_room_it_holds` (a count past a power of two),
`a_box_with_a_64_bit_size_keeps_its_header`, and `strip_answers_as_0_14_did`.
