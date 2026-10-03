# HOL-SEC-102: A stream could declare any size and get a temp file for it

```
ID:          HOL-SEC-102                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: the receiver's disk filled by streams nobody asked for;
                                          Exploitability M: any peer that shares a room)
Category:    Files / Availability
Component:   rust/hollow_core/src/node/ws_stream_transfer.rs (ws_stream_receive),
             file_handler.rs (stream_ceiling), swarm.rs
Boundary:    TB-1 (relay peers)
Traces to:   phase B re-check files A-F7
Attacker:    a room peer
Found:       2026-10-02 (phase B re-check)
```

## Description

The WS stream lane trusted the total size a stream declared and opened a temp file for it; only the number of open streams per sender was capped.

## Fix

Every new stream must fit a ceiling set by what we expect of it before a temp file exists: its own sender's file header size plus the GCM tag, unlimited only for our own fresh explicit pull, otherwise the 34 MiB send limit; a shard fits the send limit plus its header; a share chunk never rides this lane; a device-link snapshot comes only from the device that offered it.

## Residual risk

The Dart WebRTC twin (`webrtc_service.dart`) still has no ceiling and no sender check on continuations (follow-up).

## Test

Unit `a_stream_cannot_declare_past_its_ceiling` (failed before: "a stream declaring past the send limit was opened"), `a_stream_ceiling_follows_the_header_the_ask_or_the_link`; mutation killed.
