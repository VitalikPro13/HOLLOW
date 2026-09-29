# HOL-SEC-067: The recovery pool's token rode in the room name the relay reads

```
ID:          HOL-SEC-067                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: the relay, or anyone it tells, joins a dead
                                          server's recovery pool and reads or steers its shard
                                          inventories and transfer plans; Exploitability M: needs the
                                          relay, which read the token in every join)
Category:    Data exposure
Component:   rust/hollow_core/src/node/recovery_pool.rs, vault_ops.rs, types.rs (RecoverySealed,
             Lane::Recovery), swarm.rs (pool interception and sends), api/crdt.rs
Boundary:    TB-1 (client <-> relay)
Traces to:   C-24, C-25; candidate A24; files inventory (recovery pool)
Attacker:    P-01 malicious relay
Found:       2026-09-27 (design A inventory)
```

## Description

A recovery pool gathers the ex-members of a deleted server to rebuild its vault. Its
authority is an invite token, but the room was named `recovery:{server}:{token}`, so the
relay read the token on every join, and the pool's frames (vault manifest ids, shard
inventories, transfer plans) rode in the clear. The token was 8 random bytes.

## Reproduction

`authz_a_recovery_frame_counts_only_with_the_pool_token`,
`c24_a_recovery_pool_shows_the_relay_neither_its_token_nor_its_frames` (node/test_harness.rs).

## Fix

The room is named by 32 hex characters of SHA-256 over a domain tag, the server id and
the token. Every pool frame rides `RecoverySealed`, AES-256-GCM under a key HMAC-derived
from the token and bound to the server, with the room and the sending device as
associated data; a new `Lane::Recovery` keeps the inner types off every other lane, and
a frame that does not open, or holds anything but pool traffic, is dropped before any
handler. The token is 32 random bytes, since the relay now sees a hash of it. There is
no membership gate (the pool exists for ex-members). Old room names are abandoned.

## Test

The two harness tests above (a plaintext frame, one under another token, one sealed for
another device; then the real token joins and stops the pool; the wiretap finds neither
the token, the server id nor a clear pool frame), the updated
`authz_recovery_frames_count_only_from_the_pool_room`, and
`recovery_pool::tests::a_pool_frame_opens_only_under_its_token_in_its_room_for_its_sender`.
Mutation pass: seven rules put back, each failing a test.

## Residual

The pool keys our own entry by master and everyone else's by device, so on installs
where the two differ transfer plans never match us (found, not fixed, not security).
The 0x02 shard stream header still shows the content id (routing, HOL-SEC-062).
