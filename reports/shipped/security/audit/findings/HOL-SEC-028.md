# HOL-SEC-028: One malformed frame from anyone on the internet stopped the relay and emptied its buffers

```
ID:          HOL-SEC-028                 Status: Fixed and deployed to the official relay (2026-09-27)
Severity:    Critical                    (Impact H: the relay process ends; every offline buffer, catch-up ring,
                                          parked destroy signal and push token is lost, because only a clean
                                          shutdown takes the restart snapshot; repeatable at will;
                                          Exploitability H: no account, no key, one frame before auth)
Category:    Uncaught exception on untrusted input (availability)
Component:   relay-uws/src/auth_frame.h :: parse_auth_frame
             relay-uws/src/ws_handler.cpp :: handle_auth, message dispatch
Boundary:    TB-1 (client <-> relay)
Traces to:   C-26; candidate I1 (evidence relay:A-01a, A-01c)
Attacker:    P-02 anyone on the internet
Found:       2026-09-26, phase B relay pass; confirmed by reading 2026-09-27
```

## Description

The auth frame was read with a JSON accessor that throws when a field has an
unexpected type. The authenticated path already caught that, but the pre-auth
path did not, and an exception unwinding into the WebSocket library's C frames
ends the process. A field of the wrong type in the very first frame, from a
socket that had proven nothing, stopped the relay. The restart snapshot is
taken only on a clean shutdown, so every RAM registry went with it. Pre-auth
frames were also parsed at any size up to the 64 MB payload limit.

## Reproduction

`test/test_auth_frame.cpp` (relay unit test: every wrong-typed field, a
non-object, non-JSON and an oversized frame are refused without throwing).

## Fix

- `parse_auth_frame` reads the auth frame with type-checked accessors only; a
  field of the wrong type makes the frame invalid. A pre-auth frame over 16 KiB
  is refused before parsing.
- The auth call and the binary dispatch are wrapped like the text dispatch was,
  so no client input can unwind into the library.
- Deployed to the official relay the same day (decision 4); the restart handed
  every buffer over through the snapshot.

## Variants

- The auth signature is not bound to the relay it is sent to (candidate A17),
  class A.

## Test

The unit test drives the new parser. Six of the frames it refuses made the old
accessor throw (a number for a string, a string or null for a flag, an object
or array for a string); the old code coerced a negative or fractional
timestamp silently, which the new parser refuses too. Built and run on the
relay host before the deploy.
