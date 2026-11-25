# HOL-SEC-267: the GIF metadata strip panicked on a kept block cut short

```
ID:          HOL-SEC-267                 Status: Fixed in 0.14.3
Severity:    Low                         (Impact L: the send, vault upload or large-file
                                          share of that one file fails with a panic instead
                                          of a refusal; Exploitability L: the user has to
                                          send or pass on a crafted GIF someone gave them)
Category:    Denial of service (panic on peer-supplied bytes)
Component:   rust/hollow_core/src/node/image_convert.rs (strip_gif_metadata,
             copy_gif_extension, copy_gif_application_extension), node/media_strip.rs
             (strip_image)
Boundary:    TB-2 (a peer's file on our device)
Traces to:   R-RB-03, C-FILES-03
Attacker:    anyone who can send the user a file
Found:       2026-11-23 (builder of track S7b, session B)
Affected:    every client since the strip shipped (HOL-SEC-150), through 0.14.2
Fix commit:  ef8fd4e64
Disclosure:  published with 0.14.3
```

## Description

Before a GIF leaves, its metadata strip copies the blocks it keeps (unknown extensions and
the NETSCAPE loop count) and drops comments and other application blocks. The kept blocks
were copied by slicing up to the end their sub-blocks claimed, with no check that the end
was inside the file, so a GIF whose last kept block claimed more bytes than were left
panicked. The strip runs on every photo the user sends, including a file received from
someone else and sent on, a vault upload and a large-file share.

## Fix

`strip_gif_metadata` returns a `Result`: a kept block that runs past the end of the file
refuses the file (`media_strip::REFUSED` for the sender), never a panic. A dropped block
cut short ends the copy where it always did, and every whole GIF strips to the same bytes.

## Test

`media_strip::tests::a_kept_gif_block_past_the_end_is_refused`,
`a_forwarded_crafted_file_is_refused_or_cleaned_in_time` (a received file sent on), harness
`fms_a_crafted_file_sent_on_is_refused_or_cleaned_in_time` (a received file kept at rest,
sent on through `SendFile`; the node sends the next file),
`file_handler::tests::a_gif_the_strip_refuses_is_not_sent` (the photo path), and
`strip_answers_as_0_14_did` (whole and damaged GIFs get 0.14's answer, a 0.14 panic
counting as a refusal).
