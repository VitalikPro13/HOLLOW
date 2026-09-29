# HOL-SEC-069: One account could fill the relay's memory and crash it for everyone

```
ID:          HOL-SEC-069                 Status: Fixed and DEPLOYED (relay, 2026-09-29), retest at release
Severity:    High                        (Impact H: the relay runs out of memory and restarts with
                                          every offline message, ring, lock, push token and destroy
                                          order it held lost, since a kill skips the restart snapshot;
                                          Exploitability H: one free identity, no room, no membership)
Category:    Resource exhaustion
Component:   relay-uws/src/join_lock.h :: JoinLocks, ws_handler.cpp :: handle_lock_put,
             handle_subscribe, handle_register_push_token, handle_set_push_prefs,
             handle_set_offline_buffer, try_channel_push_notify; state.h; snapshot_codec.h (v6)
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; the A-D4 residual "sybil churn of the ring cap" (session 17)
Attacker:    P-06 any authenticated socket
Found:       2026-09-29 (session 18, reviewing the A-D4 leftover risks)
```

## Description

Four relay tables had no bound on what one account can make them hold:

- Join lock chains were capped at 100,000 records by count only. A record holds up to
  256 links (about 100 KB), so a full table is near 10 GB on an 8 GB box with no swap,
  and `lock_put` needs no room: any 32-hex id can be filed under any owner, and a
  self-certifying one minted at will.
- Topic subscriptions were kept per socket for any room string and any number of
  topics, so one connection could grow them without end.
- Push tokens, push prefs and the offline opt-in outlive the connection with no count
  bound and no expiry, and identities are free. A token was not even length-checked
  (only the 1 MB frame bounded it), nor was its platform.
- Channel-push throttle entries piled up per target and room for rooms the target never
  joins.

## Reproduction

C++ `test_join_lock` (`the table keeps a byte budget and a flood pays for itself`);
the live probe (`subscription past the cap leaves the room unfiltered`, `an unknown
platform is not registered`), run against the deployed relay.

## Fix

- Join locks: a 128 MB byte budget weighed per record (`JoinLocks::record_bytes`), past
  which the address share holding the most bytes loses its least recently used record
  (HOL-SEC-070); members put a lost chain back on their next connect.
- Subscriptions: at most 1,024 rooms and 16,384 topics per socket, topics up to 128
  bytes and room codes validated. A set past a cap is dropped, which leaves that room
  unfiltered: more frames, never fewer.
- Registrations (push token, push prefs, opt-in): one ledger per identity weighed by
  bytes, a 128 MB budget, the heaviest share's least recently refreshed identity loses
  its registrations (its app sends them again on the next connect). Tokens up to 4 KB,
  platforms `android`, `ios`, `unifiedpush` only; pref server keys must be room codes
  (or the reserved `~dm`), channel keys up to 128 bytes.
- Channel-push throttle: at most 256 servers per target; the entry pushed longest ago
  makes room (at worst that server may push once more).

## Test

The C++ and probe checks above; `test_snapshot_codec` round-trips the registration
shares (v6). All 13 relay suites pass on the VPS (359 checks).

## Residual

CPU: a `lock_put` of a 256-link chain makes the single-threaded relay verify 256
signatures, and nothing bounds how often one connection sends them. That belongs to the
phase G circuit breaker (measure first, `feedback_relay_rules`).
