# HOL-SEC-120: Leaving a voice channel while watching a share kept our forwarding offer

```
ID:          HOL-SEC-120                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact L: a sharer we once watched could use our
                                          upload after we left; Exploitability L: needs a
                                          watch at the moment of leaving and a sharer that
                                          registers afterwards)
Category:    Consent / Media forwarding
Component:   lib/src/core/providers/voice_channel_provider.dart (_teardownCall,
             _cleanupAllScreenShares, onLocalLeft)
Boundary:    TB-3 (server members)
Traces to:   session 31 follow-up b (a peer that left while watching and forwarding a share
             skipped its mesh teardown)
Attacker:    a voice channel member whose share we watched
Found:       2026-10-03 (follow-up b, fleet)
```

## Description

Rust reports our own leave while the leave is still tearing the call down, and the
handler cleared the watched shares before the teardown read them, so the forwarding
offer for each share we watched directly was never withdrawn: our embedded forwarder
kept the expectation and stayed in its room until the app restarted. The same race ran
a second teardown beside the first on every leave (since 2026-06-22), which disposed
native objects twice and, when one of them threw, dropped the call's connections without
closing them, so their watchdogs kept dialing after a rejoin.

## Fix

One call teardown runs at a time and every caller awaits it; the watched shares are read
before its first await; each phase (camera, shares, voice redirect, share audio, the
connections) is guarded so one failure never skips the rest, and the connections are
always closed. A forwarder leg that fails to close no longer stops the next one.

## Residual risk

A connection's watchdog can still act while the connections close, and a restart request
is honoured for a leg that is connected on our side; neither crosses a consent line, both
need a connection seam to test.

## Test

Dart `test/vc_leave_teardown_test.dart` (7 tests; RED before the fix, e.g. "our own left
event landing mid-leave still closes the mesh once": Expected 1, Actual 2), mutation 9/9
killed (`tmp_s32_media_mutate.py`); fleet scenarios vc3_joinshare and vc_directwatch_leave
before and after (no teardown skipped, no rebuild of a connected leg), regress_voice3 PASS.
