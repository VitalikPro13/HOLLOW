# HOL-SEC-022: A friend or server member could replace or empty a file someone else sent

```
ID:          HOL-SEC-022                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: the bytes behind another person's attachment replaced with
                                          the attacker's, even after download, or truncated to nothing, and then
                                          served onward to anyone who asks us for the file; Exploitability M: a
                                          friend or a server member who has seen the file id)
Category:    Missing authorization (object ownership); dead protocol message
Component:   rust/hollow_core/src/node/file_handler.rs :: file_header_refused, file_bytes_on_disk,
             handle_envelope_file_header
             rust/hollow_core/src/node/swarm.rs :: Olm FileHeader arm, PublicFileHeader arm
             rust/hollow_core/src/node/fetch.rs :: handle_file_header
             rust/hollow_core/src/node/types.rs :: MessageEnvelope (FileChunk removed)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-12, C-17; candidates H1, H2, H3, H4, H5, H6, H7, H18 (evidence files:F1-1..F1-6, F2-1, F2-2, F5-1)
Attacker:    P-04 friend, P-05 server member, P-03 room peer (guest pulls)
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

A FileHeader registers the key a file's bytes decrypt under, and may carry the
bytes inline. The owner guard protected only the file card's metadata: the key
registration and the inline write accepted any sender, so a peer naming another
person's file id delivered bytes of its own under that card. The MLS header
path and the push path did not even skip a file already on disk. A header also
consumed our explicit-pull receipt and our pending ask before any check, and
handed Dart the attacker's share reference, which starts a share download for
that card.

A `FileChunk` envelope, which no client sends, wrote chunks for any file id with
no check at all; the stored chunk count of a normally received file is 0, so a
single chunk marked the file complete as an empty file.

A guest's public-file receipt recorded only the server, so any room peer could
answer the pull with a file of its own.

## Reproduction

`authz_file_header_delivers_only_for_its_owner` and `file_header_gate_stays_wired`
(node/file_handler.rs tests), `retired_file_chunk_is_refused_at_parse`
(node/types.rs tests).

## Fix

- One gate, `file_header_refused`, runs first on every header arm (Olm, MLS,
  push, guest): a header for a file we hold a card for must come from the
  card's owner (any of its devices) or from the holder we asked for it (the
  pull's asked set, or the decrypt-fail retry's target); a channel header must
  come from a current member who can read the channel. Receipts and asks are
  consumed only after it.
- A file whose bytes are on disk is never delivered again (`file_bytes_on_disk`
  on every arm); only a DM header inlines bytes.
- Dart is handed a share reference only from the card's owner.
- `FileChunk` is gone with its handlers; a frame of it fails to parse.
- A guest pull records the peer asked, and only that peer's answer counts.

## Variants

- A holder we asked, and every member for a channel file (they all hold its
  key), can still serve different bytes under the id: the signed message names
  the file id, not a hash of its content. Needs a content hash in the signed
  message; logged for the class A work.
- The first header for an id we have never seen creates its card, the owner
  guard's rule.

## Test

The header test fails with the gate disabled (a member registers a key for
Bob's file, a non-member one in the channel, and a completed file takes a new
key) and passes with it. The parse test fails while the type exists. Full suite
green.
