# HOL-SEC-183: A few addresses could exhaust the relay box's memory with large broadcasts

```
ID:          HOL-SEC-183                 Status: Fixed (2026-10-23, wave g13, local commit 986a4d75),
                                          relay deployed to the official box 2026-10-23
Severity:    High                        (Impact H: the relay is killed for memory and restarts with every
                                          offline message, ring, lock, push token and destroy order lost,
                                          since a kill skips the restart snapshot; Exploitability H: an
                                          estimated two IPv4 addresses and free identities with sockets that
                                          never read, no membership in anyone else's room)
Category:    Resource exhaustion
Component:   relay-uws/src/send_budget.h (new), relay-uws/src/ws_handler.cpp (fan-out, close_once),
             relay-uws/src/breaker.h (new, shadow)
Boundary:    TB-1 (client <-> relay)
Traces to:   AS-11 (availability); same class as HOL-SEC-069
Attacker:    P-03 stranger with throwaway identities on a few addresses
Found:       2026-10-23 (wave g13, phase G2 traffic work, by reading the uWebSockets source; a
             hostile design review then estimated it cheaper)
```

## Description

uWebSockets keeps appending a frame to a socket's send buffer past `maxBackpressure`, and
keeps an inbound frame that spans reads whole. Sockets that never read, in a room where
another socket sends 64 MB broadcasts, therefore held the whole of every frame. The relay
had no bound on those bytes, so about 120 such sockets were estimated to hold 7.7 GB, and
the review estimated 8.4 GB from two IPv4 addresses and a 128 MB upload. The relay box has 8
GB and no swap. Present in every released relay.

## Fix

The relay keeps a send budget for bytes it holds for sockets, a quarter of RAM by default
(`HOLLOW_SEND_BUDGET_BYTES`), charged per socket and per address share (`send_budget.h`). A
box over budget closes sockets of the heaviest address share, oldest first; a sender whose
frame cannot fit is closed with 1013 and a reconnect hint (never 1008), and its session
resumes. Inbound partial frames are charged too. It is a memory-safety bound, not a volume
quota. Every close goes through one guarded helper.

The phase G2 circuit breaker added in the same commit runs in shadow mode only (it counts
what it would trip and closes nothing); it is hardening and not part of this fix.

## Residual risk

Address-based fairness cannot tell apart many address blocks held by one attacker (as
HOL-SEC-070). The breaker's enforce switch waits for 0.14, after the shadow counters show no
honest trips.

## Test

Relay unit `test_send_budget` (for example "the honest 206 MB fan-out passes on an empty
budget", "by closing the heaviest share's oldest socket only"); relay live checks with a
small budget (`RELAY_LIVE_ONLY=oom`), among them `oom_honest_fanout_evicts_nonreaders` ("the
relay's RSS stays bounded by the budget, not by what was sent"),
`oom_cotenant_gives_way_before_sender_trips`, `oom_unbufferable_fanout_refused_once`,
`oom_full_receiver_closed_after_fanout`. Mutation passes 34/35, then 18/18 plus 2/2 live;
29/32 C++ mutants killed on the merged relay (three argued). VPS suites plain and under ASan
and UBSan 46/46 with no sanitizer report.
