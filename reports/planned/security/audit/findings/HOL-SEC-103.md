# HOL-SEC-103: Completed streams with no header parked without a limit

```
ID:          HOL-SEC-103                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: the per-sender stream cap bypassed, temp files piling up for minutes;
                                          Exploitability M: any room peer)
Category:    Files / Availability
Component:   rust/hollow_core/src/node/file_handler.rs (park_early_stream)
Boundary:    TB-1 (relay peers)
Traces to:   phase B re-check transport A-T20
Attacker:    a room peer
Found:       2026-10-02 (phase B re-check)
```

## Description

A stream that completed before its file header was parked as an early arrival with no count or byte limit, and the open-stream cap no longer applied to it once complete. The only cleanup was a slow sweep.

## Fix

One helper parks every early stream: a sender keeps at most 16 and pays with its own oldest; past a 272 MiB total the sender holding the most bytes pays its oldest, each entry counting at least 1 MiB, so a flood never evicts another peer's.

## Test

Unit `early_streams_cap_each_sender_and_evict_its_own_oldest` (failed before: a sender kept more than its share); mutation killed.
