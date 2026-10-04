# HOL-SEC-137: A crash or a burst could lose or bloat MLS state

```
ID:          HOL-SEC-137                 Status: Fixed (2026-10-04, session 34)
Severity:    Low (availability and at-rest hygiene)
Category:    Availability
Component:   rust/hollow_core/src/crypto/store.rs, node/swarm.rs, node/crypto_handler.rs
Boundary:    TB-4
Traces to:   phase E+F mls C-MLS-08 (lead L-08 residuals)
Attacker:    none, or a member forcing churn
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Minted KeyPackages that never became a Welcome were never deleted, so their private keys
accumulated in every rewritten store; a frame lost to a crash rollback was dropped as a
replay with no sync; the persistence queue held a full copy of the store per send.

## Fix

Unused KeyPackages are dropped once superseded for 120 s or after 10 minutes (a parked
join's never); a replay from a member asks it for a channel sync (once per 5 s); the store
actor writes only the newest queued MLS snapshot per batch.

## Test

`unused_key_packages_are_dropped_when_stale`,
`a_replayed_channel_frame_from_a_member_asks_it_for_the_channel`,
`queued_mls_snapshots_coalesce_to_the_newest`.
