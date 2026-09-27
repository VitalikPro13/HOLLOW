# HOL-SEC-027: A replayed share manifest stopped a seeder, and an early Have allocated half a gigabyte

```
ID:          HOL-SEC-027                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: a seeder stops serving and a download loses its progress
                                          until restarted; memory spent per forged sender before a manifest
                                          arrives; Exploitability M: anyone in the share's room, and the relay,
                                          which sees every manifest in the clear)
Category:    Replay; uncontrolled resource consumption
Component:   rust/hollow_core/src/node/share_handler.rs :: handle_envelope_share_manifest_response,
             handle_envelope_share_have
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   candidate H19 (evidence files:S-2, S-3)
Attacker:    P-03 room peer, P-01 relay
Found:       2026-09-26, phase B files pass; confirmed by reading 2026-09-27
```

## Description

A share manifest is content-addressed, so any copy of the real one verifies. A
share that already held its manifest took it again and reset its have-bitmap,
so a seeder stopped serving and a download lost its progress. Before a manifest
arrived, a Have naming four billion chunks allocated a bitmap of half a
gigabyte for each sender.

## Reproduction

`a_share_takes_its_manifest_once_and_haves_only_against_it`
(node/share_handler.rs tests).

## Fix

- A share takes its manifest once; a second copy changes nothing.
- A Have is taken only against a known manifest's chunk count; peers re-send
  theirs every ten seconds, so none is lost for long.

## Test

The test fails with the old rule (a replayed manifest resets the seeder) and
passes with the fix. Full suite green.
