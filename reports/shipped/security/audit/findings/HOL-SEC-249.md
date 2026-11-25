# HOL-SEC-249: a channel push wake spent the keys of group messages it did not show

```
ID:          HOL-SEC-249                 Status: Fixed in 0.14.2
                                          (track sec-244, 2026-11-21)
Severity:    Low                         (Impact L: a channel message the wake read but did
                                          not show, such as a hint, a server op or a file
                                          header, no longer decrypts from the app's own
                                          copy; Exploitability: none needed, it happens on a
                                          channel push wake)
Category:    Availability (lost delivery)
Component:   rust/hollow_core/src/node/fetch.rs (try_process_channel_msg, save_posts_read,
             run_fetch)
Boundary:    TB-1 (content from other people)
Traces to:   C-13, C-17; R-PU-08
Attacker:    none needed
Found:       2026-11-21 (session B, review of the HOL-SEC-244 track)
Affected:    every release with channel push wakes, through 0.14.1
Fix commit:  b2225d7ea (0.14.2)
Disclosure:  with the 0.14.2 release
```

## Description

A channel push fetch decrypts every group message it meets to learn what it is, and then
saved the MLS group state. For a message it did not show, that save had already used the
message's key, so the app's own copy of the same ciphertext (the channel ring, a resumed
session's ring) could no longer be decrypted.

## Fix

The fetch drops the copy of the group state that read every frame, unsaved. A copy fresh
from disk decrypts only the posts the fetch stored and is saved. Anything else it read
leaves the group state as it found it: no key used, no epoch moved, no past epoch kept. A
post's key is spent once its row is stored, as before; any other key stays until the app
reads its own copy, inside the existing window of skipped keys.

## Test

Harness `sec249_the_app_still_reads_its_ring_copies_after_a_channel_wake` (an edit, a
reaction and a deletion still open from the ring after a wake that read them and stored a
post; red with the old save).
