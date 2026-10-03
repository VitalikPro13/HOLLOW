# HOL-SEC-104: A streamed vault shard bypassed our storage pledge

```
ID:          HOL-SEC-104                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: more vault data stored than we pledged;
                                          Exploitability M: a server member)
Category:    Vault / Availability
Component:   rust/hollow_core/src/node/vault_ops.rs (pledge_refused), file_handler.rs
             (handle_shard_stream_complete), swarm.rs
Boundary:    TB-3 (server members)
Traces to:   phase B re-check files A-V1
Attacker:    a server member
Found:       2026-10-02 (phase B re-check)
```

## Description

A shard store that arrived as a stream was judged against our pledge as one byte and stored at completion without a second look.

## Fix

The stream snapshots our pledge when it registers, and completion re-judges the real size with the same `pledge_refused` rule before storing.

## Test

Unit `pledge_refused_counts_the_real_size`; wiring scan `vault_gates_stay_wired`; mutation killed.
