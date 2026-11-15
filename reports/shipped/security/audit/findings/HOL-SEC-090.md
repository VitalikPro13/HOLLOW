# HOL-SEC-090: Every server member learned who sat in a restricted voice channel

```
ID:          HOL-SEC-090                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: who joined, left, muted, shared or
                                          recorded in a voice channel the member cannot see;
                                          Exploitability H: any member, no action needed)
Category:    Voice / Privacy
Component:   rust/hollow_core/src/node/voice_handler.rs (broadcast_vc_presence,
             broadcast_vc_state_signal)
Boundary:    TB-4 (server members)
Traces to:   C-18; HOL-SEC-040 (J3, the rejoin re-announce)
Attacker:    a server member who cannot see the channel
Found:       2026-10-02 (phase B re-check, media A-MED-03 note; decision D4)
```

## Description

Voice channel presence (join, leave) and state (mute, screen, camera, recording) went to
the whole server: over the server-wide MLS group and as an Olm copy to every member. For a
restricted voice channel this told members who cannot see the channel who was talking in
it and when. The re-announce after a reconnect already checked visibility; the broadcasts
did not.

## Fix

A restricted voice channel's presence and state ride its own MLS subgroup, which only its
viewers hold, and the Olm copy goes only to members who can see the channel.

## Test

Unit `restricted_voice_presence_reaches_only_its_viewers` (failed before the fix: the plain
member got both signals and the server group carried them); mutation pass 2/2.
