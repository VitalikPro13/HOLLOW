# HOL-SEC-122: Anyone in the room could open an unlimited stream for a file we pulled

```
ID:          HOL-SEC-122                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact L: disk filled at relay speed while our pull
                                          receipt is fresh, the asked holder held off for 10 s;
                                          Exploitability M: any device in a room with us that
                                          knows the file id)
Category:    Availability / File streams
Component:   rust/hollow_core/src/node/file_handler.rs (stream_ceiling)
Boundary:    TB-3 (server members), TB-2 (contacts)
Traces to:   phase B matrix files A-F7, transport A-T20 (HOL-SEC-102 residual)
Attacker:    any device in a room with us that knows the file id
Found:       2026-10-03 (matrix rebuild)
```

## Description

HOL-SEC-102 capped every stream at what we expect of it, except an explicit pull: while
our receipt for a file id was fresh (up to 300 s), a stream for that id got no ceiling
at all, whoever opened it. Any device in a room with us that knew the id could open it
first, write without bound until we disconnected, and keep the id from the holder we
asked. The unit test pinned the hole (a device never asked got `u64::MAX`).

## Fix

The unlimited ceiling now goes only to a stream from a device our ask names
(`pending_file_asks[id].asked`) or, for a guest pull, from the peer the guest asked;
anyone else gets the send limit.

## Residual risk

Any device in the room can still open a stream for that id of up to the send limit
(34 MB) and, by trickling frames, keep it from the holder we asked for the 10 s
takeover-idle window; letting the asked device take an id over at once would close it.

## Test

Unit `a_stream_ceiling_follows_the_header_the_ask_or_the_link` (node/file_handler.rs
tests; RED: `a device we never asked opened an unlimited stream for a file we pull,
left: 18446744073709551615, right: 35651600`); mutation 4/4 killed
(`tmp_s32_files_mutate.py`).
