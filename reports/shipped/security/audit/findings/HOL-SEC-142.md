# HOL-SEC-142: Call keys could reach the debug log, new camera cryptors started on an old key slot, and a sharer could override a viewer's volume

```
ID:          HOL-SEC-142                 Status: Fixed (2026-10-04, session 34)
Severity:    Low
Category:    Crypto / Integrity
Component:   lib/src/core/services/webrtc_native_log.dart, flutter_webrtc_base.cc, frame_cryptor_service.dart, screen_audio_renderer.dart
Boundary:    TB-2, TB-4
Traces to:   phase E+F media C-MEDIA-05, -06, -07; claim C-37
Attacker:    P-05 call participant, P-09 log reader
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

With HOLLOW_WEBRTC_LOG at info or verbose, libwebrtc logged the MLS-exported key and the
derived AES key on every rotation. New voice-channel camera sender cryptors stayed at key
slot 0, which could hold an older epoch's key. A sharer could send in-band control frames
through the share-audio pipe to change the viewer's gain, un-deafening included, and an
oversized packet could desync the pipe.

## Fix

Lines carrying keys are dropped in both log sinks; cryptors get the current key index before
they are enabled; the renderer drops control frames and any length outside the protocol's
range.

## Residual risk

The C++ log filter and the share-audio executable get their check in the release session's
regression pass.

## Test

`webrtc_native_log_test`, Dart "a cryptor made after a rotation starts on the current slot",
`screen_audio_renderer_test`.
