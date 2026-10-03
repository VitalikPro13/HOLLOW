# HOL-SEC-110: Voice channel SDP and ICE over Olm had no signal rate limit

```
ID:          HOL-SEC-110                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: signal floods inside a voice channel limited only by the general frame bucket;
                                          Exploitability M: a voice channel participant)
Category:    Media / Availability
Component:   rust/hollow_core/src/node/voice_handler.rs (is_vc_signal), swarm.rs (Olm and MLS
             guard arms), types.rs (VC_SIGNAL_RATE_BURST)
Boundary:    TB-3
Traces to:   phase B re-check media (VC rate)
Attacker:    a voice channel participant
Found:       2026-10-02 (phase B re-check)
```

## Description

Only the MLS arm charged voice channel signals to the per-sender VC bucket, but targeted SDP, ICE, screen, renegotiation and leg-restart signals always ride Olm, so they were limited only by the general WS bucket.

## Fix

One predicate, `is_vc_signal`, feeds both the MLS guard and a new Olm guard. The burst is raised from 30 to 50 so an honest join's ICE trickle from a machine with many network adapters still fits; the refill stays 10 per second.

## Test

Harness `authz_a_vc_signal_flood_over_olm_is_rate_limited` (failed before: 80 of 80 reached the app); unit `is_vc_signal_covers_every_voice_channel_envelope`; mutation killed.
