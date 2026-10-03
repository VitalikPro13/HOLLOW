# HOL-SEC-106: A recovery plan's content id reached a temp path unchecked

```
ID:          HOL-SEC-106                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a shard temp file named from a sender-chosen string;
                                          Exploitability L: needs the recovery pool's token)
Category:    Vault / Path handling
Component:   rust/hollow_core/src/node/vault_ops.rs (shard_write_refused), swarm.rs
             (recovery plan arm)
Boundary:    TB-3
Traces to:   phase B re-check files A-R4; rule safe_file_name
Attacker:    a recovery pool member
Found:       2026-10-02 (phase B re-check)
```

## Description

The recovery plan built a temp file name from the first bytes of each assignment's content id, and shard writes never checked a content id's shape.

## Fix

Shard writes refuse anything but a content id (64 lowercase hex), the plan skips assignments without one, and the temp is named from the hashed shard key.

## Test

Unit `authz_shard_write_needs_a_member_and_a_shard_we_lack` (extended with a path-shaped id); mutation killed.
