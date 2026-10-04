# HOL-SEC-140: A screen share could pass through the forwarder before it was encrypted

```
ID:          HOL-SEC-140                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: the relay operator's forwarder sees the share in the clear; Exploitability M: depends on timing at the share's start)
Category:    Crypto / Data exposure
Component:   lib/src/core/providers/voice_channel_provider.dart (forwarderMayCarry)
Boundary:    TB-1
Traces to:   phase E+F media C-MEDIA-03; claim C-21
Attacker:    P-01 relay operator
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Nothing on the forwarder routing, ingest or egress path checked that the share's cryptor
held a key, and a keyless viewer rendered whatever the forwarder sent.

## Fix

Forwarder routing and every ingest and egress entry wait for a keyed cryptor; a keyless
share takes direct legs and a keyless viewer refuses a forwarder.

## Test

Dart `forwarder_sframe_gate_test`.
