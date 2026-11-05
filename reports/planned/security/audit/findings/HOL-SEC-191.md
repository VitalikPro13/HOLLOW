# HOL-SEC-191: The Windows screen share's voice redirect found voices by the track id their sender chose

```
ID:          HOL-SEC-191                 Status: Fixed on local branch security/0.14
                                          (track t14-redir, 2026-11-04), retest at release
Severity:    Medium                      (Impact M: during an entire-screen share with
                                          audio a participant could get our microphone
                                          played back to us and its own voice mixed into
                                          the shared audio, or keep another member's voice
                                          out of the redirect; with no attacker, deafen and
                                          the volume sliders did nothing during a share and
                                          a deafened listener heard everyone after it;
                                          Exploitability M: any participant of a 1:1 call
                                          or voice channel, with a modified client, while
                                          the target shares the entire screen on Windows)
Category:    Access control (object lookup by a peer-chosen name); state not restored
Component:   packages/flutter_webrtc/common/cpp/src/flutter_voice_redirect.cc and the
             voiceRedirectStart/Stop dispatch in flutter_webrtc.cc; the fork's
             Helper.voiceRedirectStart; voice_service.dart, voice_channel_service.dart,
             call_provider.dart and voice_channel_provider.dart
Boundary:    TB-2 (peer and peer)
Traces to:   C-21 (participants only); HOL-SEC-190 (same lookup, volume path)
Attacker:    a participant of the call or voice channel
Found:       2026-11-04 (hostile review of HOL-SEC-190, finding 1)
Affected:    every Windows release since 0.10.0 through 0.13.0
```

## Description

During an entire-screen share with audio on Windows, received voices play from a child
process the share capture leaves out, so the people watching do not hear the call twice.
The app chose which voices to move by their track ids, and native code resolved each id
with the global lookup that checks our local tracks first and then every connection. A
received track's id is whatever the sending peer wrote in its SDP. A participant that named
its voice after our microphone got our microphone sent to the child (we heard ourselves)
while its real voice stayed in hollow.exe and was captured into the shared audio; naming
another member's voice left one voice out of the redirect.

The redirect also ignored the listener's volume. The child took the voice before the track
volume, so deafen and the sliders did nothing during a share; an un-deafen during a share
set full volume on the muted in-process copy, so voices played twice and leaked into the
share; and stopping the share set every redirected voice to full volume without anyone
re-applying deafen or the sliders, so a deafened listener heard everyone after the share
while the UI still said deafened.

## Fix

The redirect names each voice by (local connection id, receiver id) and carries the volume
it should play at (`VoiceService`/`VoiceChannelService.startVoiceRedirect`,
`Helper.voiceRedirectStart` taking receivers). Native looks only among that connection's
receivers, never at a local track or another connection, and skips an unknown one. The
child-bound PCM is scaled by the wanted volume and dropped at 0. While a voice is
redirected, `setVolume` updates the redirect's volume and keeps hollow.exe's own playout at
0. Stop gives each voice back at its wanted volume, and the services apply the wanted
volume again after it. A voice that arrives during the share joins the redirect at its
wanted volume, including one that arrives while the redirect is still arming (held, then
sent once the child is up). Track operations go through the audio op queue. Each connection
taps at most 16 voices and the redirect at most 256; a voice over either cap stays silent in
hollow.exe, so one peer can only shut out its own voices, and voices of closed connections
are dropped. A render child that dies during a share is never replaced before the share
stops (the capturer excludes only the first child's pid), so from then on every voice stays
silent in hollow.exe, and the writer thread is joined before it is ever started again (an
assignment over a live std::thread ended the process). A stop that lands while the redirect
arms takes it back once the arm returns, and an arm that does not start leaves no voice
silent.

## Residual risk

A receiver id is also chosen by the far side when that side made the offer, so it is only
unique within one connection; the redirect re-attaches every receiver under a name. Between
the share starting and the audio op queue running the attach, a voice can still play in
hollow.exe for a moment. If the render child dies during a share the listener hears no
voices until the share stops; nothing reaches the share.

## Test

`test/remote_receiver_volume_test.dart`: group "1:1 call" ("the share redirect names the
connection and every audio receiver at the call volume", "after the share the call plays at
the volume it was turned to", "a voice that arrives during the share joins the redirect",
"no redirect outlives its call", "a voice that arrives while the redirect arms joins it",
"a call that ends while the redirect arms redirects nothing after it", "a voice named in the arm is not sent again when its track event lands during the arm", "an arm that does not
start leaves no voice redirected") and guards "voice_redirect_resolves_only_named_receivers",
"a redirected voice keeps the volume the listener chose", "a render child lost mid-share is
never replaced or restarted over", "one connection cannot take every redirect slot";
`test/gossip_forward_service_test.dart` group "share voice redirect" (each leg and receiver
at its member volume, deafened listener redirects silent and stays deafened after the share,
a voice arriving during the share joins at its member volume, a voice arriving while the
redirect arms joins it, an arm that does not start, a session closing during the arm, no
redirect outlives the session); `test/vc_leave_teardown_test.dart` ("a share stopped while
the voice redirect arms leaves nothing armed", "an arm that ends while the stop finishes
leaves nothing armed").
