# HOL-SEC-139: Any call participant or the forwarder could pin a receiver's CPU with frames that fail to decrypt

```
ID:          HOL-SEC-139                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: a CPU core and unbounded memory on the receiver; Exploitability H: any participant or the forwarder)
Category:    Availability
Component:   lib/src/core/services/frame_cryptor_service.dart
Boundary:    TB-2
Traces to:   phase E+F media C-MEDIA-02
Attacker:    P-05 call participant, the forwarder
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The frame cryptor ran its key ratchet on every frame that failed to decrypt (window 16,
PBKDF2 with 100,000 iterations per step, with no early exit), and the per-frame queue had no
limit. Hollow never ratchets keys.

## Fix

`ratchetWindowSize: 0`, so a failed frame costs one AES-GCM open.

## Test

Dart "a frame that fails to decrypt is never ratcheted".
