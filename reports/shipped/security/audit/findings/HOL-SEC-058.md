# HOL-SEC-058: Screen-share audio played from any open data channel

```
ID:          HOL-SEC-058                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: audio injected into a call's share-audio output,
                                          heard as the sharer's; Exploitability M: a friend or co-member
                                          with an open data channel and a modified client)
Category:    Missing authorization
Component:   lib/src/core/providers/call_provider.dart, voice_channel_provider.dart ::
             onScreenAudioReceived
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-22, C-21; calls inventory (A12 trace)
Attacker:    P-05 / P-06 peer with a data channel
Found:       2026-09-27, design A inventories
```

## Description

Both share-audio callbacks ignored the sender, so any peer holding a data
channel with us could play Opus into the one share-audio renderer.

## Reproduction

Read in both providers; no Dart test drives two data channels yet.

## Fix

A DM call plays share audio only from the call's peer while we watch its share;
a voice channel only from a sharer we asked to watch. Sharers send audio straight
to each watcher, never relayed, so the sender is always the originator.

## Test

test/share_audio_gate_test.dart (2026-09-29): a DM call plays only from the call's
peer, from any of its devices, and nothing while we are not watching its share; a
voice channel plays only from a sharer we watch. The gates are
`acceptsShareAudioFrom` on CallNotifier and VoiceChannelNotifier; a mutation pass put
back no gate, a call ignoring its peer, a call ignoring watching, and a voice channel
accepting anyone, and each failed.
