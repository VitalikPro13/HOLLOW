# HOL-SEC-116: The Dart data channel receiver trusted every stream's size and sender

```
ID:          HOL-SEC-116                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: the receiver's disk filled, or another peer's transfer
                                          spoiled; Exploitability M: a friend or co-member, on the Share
                                          lane any link holder)
Category:    Files / Availability
Component:   lib/src/core/services/webrtc_service.dart (receive path, sendFile),
             lib/src/core/services/rtc_stream_intake.dart
Boundary:    TB-2 (direct peers)
Traces to:   HOL-SEC-102 residual (section 2 follow-up 3c)
Attacker:    a data channel peer
Found:       2026-10-03 (HOL-SEC-102 fix)
```

## Description

The Dart data channel file receiver opened a temp file for any declared size and any number of streams, appended continuation frames for a transfer id from any connection, let another connection's first frame replace a live transfer, and wrote past the declared size; a size of 2^63 or more read negative and completed at once.

## Fix

A first frame is judged before any temp file exists: its size must fit the ceiling Rust's WS stream lane uses (file, shard or share chunk), and it may not carry more than it declares. A stream is extended only by the connection, lane included, that opened it, another connection cannot take an id over until it idles 10 s, and bytes past the declared size discard it. Each connection keeps at most 16 open streams and pays with its own stalest; past 128 in all the heaviest sender pays. Our own senders run at most 8 streams per connection.

## Residual risk

A co-member who knows a file id can open it first and trickle frames to hold it (the WS lane has the same 10 s rule). Refusals are silent, so a refused header waits for the file-ask retry.

## Test

`test/rtc_stream_intake_test.dart`: "a stream declaring past the send limit is refused before it opens", "a continuation from another connection never touches the stream", "another connection's first frame cannot replace a live stream", "bytes past the declared size fail the stream", "a sender keeps at most its share and pays with its own stalest" (all failed before); a source pin keeps the ceilings equal to Rust's; mutation 15/15 killed.
