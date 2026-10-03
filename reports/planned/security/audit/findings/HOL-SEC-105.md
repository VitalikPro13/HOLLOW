# HOL-SEC-105: An unasked shard answer blocked a vault download for good

```
ID:          HOL-SEC-105                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact: vault content we can no longer rebuild;
                                          Exploitability M: a server member)
Category:    Vault / Integrity
Component:   rust/hollow_core/src/node/vault_ops.rs (ShardAsks), swarm.rs (ShardResponse arm,
             ShardRequest send sites), file_handler.rs (shard stream completion)
Boundary:    TB-3 (server members)
Traces to:   phase B re-check files A-V6
Attacker:    a server member
Found:       2026-10-02 (phase B re-check)
```

## Description

Any member could answer a shard pull we never made. A held shard is never replaced, so a planted shard refused the genuine one, every later rebuild failed its content check, and nothing removed the bad shard.

## Fix

Every shard pull records the device asked (bounded, five-minute life); an answer is taken once and only from that device, before anything else in the arm, and a streamed answer must come from it.

## Residual risk

Shard stores and migrations are unasked by design, so a member can still plant a first copy, and a holder we did ask can return bad bytes that block the rebuild; deleting a shard on a failed rebuild is a follow-up.

## Test

Unit `an_unasked_shard_response_is_dropped` (failed before: "an answer nobody asked for was taken"); wiring scan `vault_gates_stay_wired`; mutation killed.
