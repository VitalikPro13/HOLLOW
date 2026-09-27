# HOL-SEC-023: Any peer in a shared room could write into another sender's file stream, and fill our disk

```
ID:          HOL-SEC-023                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a download in progress corrupted or taken over, and temp
                                          files written without bound until we disconnect; Exploitability M: any
                                          peer in any room we share, which includes anyone who knows a server id)
Category:    Missing authorization (stream ownership); uncontrolled resource consumption
Component:   rust/hollow_core/src/node/ws_stream_transfer.rs :: ws_stream_receive, WsTransferState
             rust/hollow_core/src/node/file_asks.rs :: dispatch_one
             rust/hollow_core/src/node/file_handler.rs :: handle_completed_stream, handle_request_file
             rust/hollow_core/src/node/swarm.rs :: startup temp sweep
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   C-12; candidates H8, H9 (evidence files:F7-1, F7-2)
Attacker:    P-03 room peer, P-01 relay
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

A stream's receive state was keyed by its id alone. Any peer could append
continuation frames to another sender's stream, or open the same id again and
have its frames appended as a resume. A first frame for an unknown id created a
temp file with any declared size, and frames were written past that size;
nothing bounded how many streams a peer held open, share-chunk temps were never
deleted, and no sweep removed receive temps left by a previous run.

## Reproduction

`a_stream_belongs_to_the_peer_that_opened_it` (node/ws_stream_transfer.rs tests).

## Fix

- A stream belongs to the device that opened it: another device's frames for
  that id are dropped while it is live, and may take the id over only after it
  has been idle 10 seconds (the next holder after one that stalled).
- A stream that writes past its declared size is dropped with its temp; one
  peer holds at most 16 open streams, all peers 128.
- A resume offset is asked only of the device already streaming the file.
- Share-chunk temps are deleted, and the startup sweep removes `.ws_recv_`
  temps.

## Variants

- Every member holds a channel file's key, so a member that becomes the
  streaming holder can deliver other bytes: HOL-SEC-022's content-hash variant.

## Test

The test fails with the ownership check removed (another peer's frames are
appended and the stream completes with them) and passes with it. Full suite
green.
