# HOL-SEC-190: A received voice's volume was looked up by the track id its sender chose

```
ID:          HOL-SEC-190                 Status: Fixed on local branch security/0.14
                                          (track t14-vol, 2026-11-04), retest at release
Severity:    Medium                      (Impact M: a participant could keep playing for a
                                          listener who deafened or muted them, or turn another
                                          member up or down at that listener; Exploitability M:
                                          any participant of a 1:1 call or voice channel, with a
                                          modified client)
Category:    Access control (object lookup by a peer-chosen name)
Component:   packages/flutter_webrtc native setVolume (Android MethodCallHandlerImpl,
             Apple FlutterWebRTCPlugin.m, Windows/Linux flutter_webrtc.cc);
             lib/src/core/services/remote_track_volume.dart and its callers in
             voice_channel_service.dart and voice_service.dart
Boundary:    TB-2 (peer and peer)
Traces to:   C-21 (participants only); feedback_remote_track_volume_not_found (#97)
Attacker:    a participant of the call or voice channel
Found:       2026-11-01 (wave 2 track w2-e, confirmed on main 8350841b on 2026-11-04)
Affected:    every release with calls or voice channels through 0.13.0
```

## Description

Deafen, the member volume slider and the 1:1 call volume named a received voice by its
track id. A received track's id is whatever the sending peer wrote in its SDP. Native code
resolved that id against local tracks first and then against every connection: Android
dropped the connection id the app passed and walked every connection in hash order, Apple
checked local tracks before the named connection, and Windows and Linux fell back to a global
search when the named connection had no match. A participant could therefore name its voice
after the listener's own microphone (so deafen and mute changed the microphone and the voice
kept playing) or after another member's voice (so the listener's slider for one member moved
the other). The member slider also stopped after a leg's first audio receiver, so a second
audio section escaped it on every platform, and a receiver the peer opened after deafen or a
volume change started at full volume.

## Fix

Volume is set only by (local connection id, receiver id): `setRemoteReceiverVolume` in Dart,
`Helper.setReceiverVolume` in the fork. Native looks only among that connection's receivers
(Android through the transceivers `onTrack` handed over, since a `getReceivers()` list is
disposed by the next such call), never a local track and never another connection, and
reports an error when nothing matches. Deafen and both sliders cover every audio receiver of
a leg except accepted gossip forwards, a receiver opened later takes the wanted volume in
`onTrack`, a voice-channel slider moved while deafened is only recorded, and a 1:1 call's
remembered volume ends with the call. The meter loopback silences its copy the same way.

## Residual risk

Gossip forwards (shipped off) still take the forwarder's leg volume under deafen; they never
take the forwarder's slider. The Windows entire-screen anti-echo redirect
(`flutter_voice_redirect.cc`) still resolves track ids through the global `MediaTrackForId`;
it is reported to the lead as its own finding.

## Test

`test/remote_receiver_volume_test.dart` ("the call volume names the connection and every
audio receiver", "a voice that arrives after the call was turned down takes that volume",
"the next call starts at full volume", and source guards that the Android, Apple and
Windows/Linux lookups never reach local tracks, other connections or a disposable receiver
list, and that lib/ never sets a volume by track); `test/gossip_forward_service_test.dart`
group "receiver-keyed volume" (a member volume names its leg and receiver, covers every
voice on the leg, deafen reaches every leg when two legs carry the same track id, a voice
arriving while deafened or turned down takes that volume, a slider moved while deafened keeps
the member silent). Mutation pass 18 of 18 killed (three Dart layers, the fork call and each native lookup and dispatch arm).
