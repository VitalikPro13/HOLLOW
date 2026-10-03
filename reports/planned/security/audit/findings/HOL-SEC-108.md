# HOL-SEC-108: Data channel answers paired with our offer by connection id alone

```
ID:          HOL-SEC-108                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: another identity answering our data channel offer, its early ICE flushed into our connection;
                                          Exploitability L: needs the relay plus an identity of its own; the channel's payloads keep their own end-to-end crypto)
Category:    Media / Authentication
Component:   lib/src/core/services/rtc_signal_pairing.dart (new), webrtc_service.dart
Boundary:    TB-1 (relay)
Traces to:   phase B re-check media A-MED-08; HOL-SEC-037 (call ids)
Attacker:    P-01 the relay running its own identity
Found:       2026-10-02 (phase B re-check)
```

## Description

An answer or ICE candidate was paired with our offer by conn_id, falling back across every peer, and conn_id came from a non-secure random source and rides a frame the relay reads. Early ICE was queued by conn_id alone and flushed into the answerer's new connection.

## Fix

A signal pairs only with a connection of the same identity as its sender (the dialled peer or one of its devices); a cold link map fails closed and the dial times out and redials. Early ICE is queued per identity and conn_id, and conn ids come from `Random.secure()`.

## Test

Dart `test/rtc_signal_pairing_test.dart`: "an answer from another identity carrying our offer conn_id is not paired", "another identity's queued ICE is never flushed into our PC", "connection ids come from a secure random source" (all failed before); mutation killed.
