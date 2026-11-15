# HOL-SEC-109: The standalone forwarder took unsealed and replayed frames

```
ID:          HOL-SEC-109                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: replayed key requests forcing re-keys at the forwarder;
                                          Exploitability M: any relay peer, or the relay)
Category:    Relay frames / Authentication
Component:   rust/hollow_core/src/forwarder/signaling.rs (Sealing::admit, open_envelope)
Boundary:    TB-1
Traces to:   phase B re-check media A-MED-09; HOL-SEC-053, HOL-SEC-054
Attacker:    P-01 / P-02
Found:       2026-10-02 (phase B re-check)
```

## Description

The forwarder accepted unsealed frames from any sender it had not yet seen seal since it started, answered them unsealed, and checked neither seal time nor nonce, unlike the main node.

## Fix

The forwarder judges frames as the main node does, with the same `frame_auth` code: sealed frames only, never its own id, a live-only message only while fresh and once, a carried envelope judged by its frame's time, and every reply sealed. Pre-0.12 clients are refused, as decided for HOL-SEC-053.

## Test

Unit `fwd_refuses_an_unsealed_frame_from_a_first_contact`, `fwd_takes_a_key_request_once_and_only_while_fresh`, `fwd_acts_on_a_stream_signal_only_while_its_frame_is_fresh`, `fwd_answers_every_peer_sealed` (all failed before); mutation killed.
