# HOL-SEC-051: An admin could demote, ban or mute the owner through a device id

```
ID:          HOL-SEC-051                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact H: the owner, or a higher-ranked member, demoted, banned or
                                          muted on the replicas affected; Exploitability L: needs a replica
                                          that has not yet learned the victim's device list)
Category:    Authorization bypass (identity folding)
Component:   rust/hollow_core/src/crdt/server_state.rs :: canonicalize_members
             rust/hollow_core/src/node/swarm.rs :: startup load, SyncResponse
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15, C-17; candidate E8 (evidence crdt:S9)
Attacker:    P-05 admin or moderator with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

A role, ban or mute op naming a device id the receiver could not resolve yet was
judged against that id's rank, which read as Member, and stored under the device
id. When the receiver later learned the device belonged to the owner, the fold
of device-keyed registers into their master merged it by timestamp.

## Reproduction

`authz_device_registers_never_demote_ban_or_mute_the_owner_or_a_moderator`
(crdt/server_state.rs tests).

## Fix

- Anchored servers never fold device-keyed registers: their ops are master-keyed
  from the first one, and a register under a device id is simply never read.
- On a legacy server the fold only adopts: a role, ban or mute register lands on
  a master with none of its own, never on the owner, never carries Owner, and a
  ban or mute never lands on a Moderator or above.

## Test

The test fails with the merge put back and passes with the fix. Full suite
green.
