# HOL-SEC-033: A carried device list was taken as its master even when it did not bind the sender

```
ID:          HOL-SEC-033                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a revoked device joined a server as its former master and
                                          was seated in the group, planted a key bundle under that master's
                                          name, or declined a request in its name; its revocation was never
                                          enforced on those paths; Exploitability M: a revoked device running a
                                          modified client, replaying its master's older list)
Category:    Missing authorization (attribution without binding)
Component:   rust/hollow_core/src/node/swarm.rs :: ServerJoinRequest, FriendRequest, FriendReject arms
             rust/hollow_core/src/node/crypto_handler.rs :: carried_list_master
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-05; candidate F7 (evidence identity parity notes)
Attacker:    P-07 revoked device
Found:       2026-09-26, phase B identity pass; confirmed by reading 2026-09-27
```

## Description

A join request, a friend request and a decline carry the sender's master-signed
device list. The arms checked only the list they received (the sender listed, not
tombstoned in that list), ingested it, and then attributed the message to
`list.master_peer_id` whatever the ingest decided. A device revoked in a newer
list we already held could replay its master's older list: ingest refused to
bind it, and the arm still treated it as that master. These three arms also
dropped the revocations the ingest reported, so the Olm session and MLS leaf of a
device revoked this way stayed.

## Reproduction

`authz_a_carried_list_attributes_only_a_bound_sender` (node/crypto_handler.rs tests).

## Fix

- `carried_list_master` runs after the ingest and names the list's master only
  when the ingest really bound the sender to it (and the sender is not revoked);
  otherwise the message is dropped.
- All three arms pass the ingest's `newly_revoked` to `enforce_device_revocations`,
  like the profile arm.
- A source guard in the same test keeps all three arms wired.

## Test

The test fails with the old attribution put back and passes with the fix. Full
suite green.
