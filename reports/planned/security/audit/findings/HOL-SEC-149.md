# HOL-SEC-149: A received video or voice note was decoded by ffmpeg with no tap

```
ID:          HOL-SEC-149                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact H if ffmpeg has a memory bug; Exploitability M: a friend or co-member sends a file)
Category:    Attack surface
Component:   lib/src/ui/chat/video_message_bubble.dart, audio_message_bubble.dart, audio_probe_service.dart
Boundary:    TB-2, TB-8
Traces to:   phase E+F files C-FILES-02; AT-5
Attacker:    P-04 friend, P-05 member
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

The video bubble cut a poster frame with the bundled ffmpeg when it built, and the audio
bubble probed and transcoded anything shaped like a voice note, so peer bytes reached
ffmpeg's demuxers and decoders without interaction.

## Fix

A received video shows the poster its sender shipped until it is opened; a voice note's
duration comes from a Dart Ogg page reader; ffmpeg runs only after a tap, on every platform.

## Test

`a_received_video_is_not_decoded_before_a_tap`,
`a_received_album_tile_is_not_decoded_before_it_opens`,
`a_voice_note_reaches_no_decoder_before_a_tap`.
