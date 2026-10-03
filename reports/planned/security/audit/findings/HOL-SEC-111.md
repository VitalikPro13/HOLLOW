# HOL-SEC-111: A key request from anyone minted a fresh one-time key

```
ID:          HOL-SEC-111                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: friend accepts pushed back to a live key exchange, a full account write per request;
                                          Exploitability H: any device id, which costs nothing)
Category:    Olm / Availability
Component:   rust/hollow_core/src/crypto/olm_manager.rs (key_for_requester, key slots),
             swarm.rs (KeyRequest arm), forwarder/signaling.rs, Cargo.toml (vodozemac low-level-api)
Boundary:    TB-1 / TB-2
Traces to:   phase B re-check dm A-DM-01; candidate L6 (AR-09 CLOSED by HOL-SEC-054)
Attacker:    P-02 any account
Found:       2026-10-02 (phase B re-check)
```

## Description

A signed KeyRequest from a device we had never met minted a new one-time key every time, with no cap per requester or in total. The account keeps 5000 keys and drops the oldest, usually the key our own friend request carries.

## Fix

Each requesting device holds one slot whose key is re-sent until that device spends it; a device that keys us another way loses its unused key; the table holds 256 slots, drops the oldest with its key, never re-sends a key the account dropped, and is saved with the account so a restart orphans nothing. The forwarder uses the same helper.

## Test

Unit `a_key_request_flood_never_spends_a_carried_key` (failed before: the carried key was spent), `one_requester_holds_one_key_across_repeats`, `key_request_slots_survive_a_restart`; harness `authz_one_device_holds_one_of_our_one_time_keys` (failed before: 50 keys for one device); mutation 9/9 killed.
