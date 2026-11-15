# HOL-SEC-089: A frame that failed to decrypt made us send its sender what we hold

```
ID:          HOL-SEC-089                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: our state vector and per-channel sync
                                          marks for that server, metadata only; Exploitability
                                          H: anyone in the server's room, which needs only the
                                          server id)
Category:    MLS / Privacy
Component:   rust/hollow_core/src/node/swarm.rs (MlsChannelMessage, a stale decrypt),
             crypto_handler.rs (sync_partner)
Boundary:    TB-4 (server members), TB-1 (relay)
Traces to:   C-14, C-18, C-24; HOL-SEC-044 (stale frames never drop a group)
Attacker:    a stranger in the server's room, or the relay
Found:       2026-10-02 (phase B re-check, server_mls A-15)
```

## Description

When an MLS frame failed to decrypt in a way that may mean we are behind, we asked its
sender over Olm to sync: a channel sync for every channel we follow and an op-log sync
carrying our state vector. The sender was never checked, and any device in the room can
replay a member's ciphertext with another epoch, so a stranger learned which ops and
messages we hold, and started an Olm session with us to receive it.

## Fix

The requests go only to a device of a current member, and a channel's request only to a
member who can read that channel (`crypto_handler::sync_partner`).

## Test

Harness `authz_a_frame_that_fails_to_decrypt_asks_only_a_member_to_sync`: a member's frame
from another epoch gets both requests, a stranger's gets none (failed before the fix);
mutation pass 3/3.
