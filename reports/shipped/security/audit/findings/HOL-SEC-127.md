# HOL-SEC-127: A socket a locked server room hides still left channel copies and wakes

```
ID:          HOL-SEC-127                 Status: Fixed (2026-10-03, session 33), relay
                                          deployed 2026-10-04 after a canary
Severity:    Low                         (Impact L: junk frames in an offline member's
                                          buffer, bounded by the fair share, and channel
                                          push wakes, bounded by the debounces; the woken
                                          fetch node drops what it cannot verify;
                                          Exploitability M: a server id and a member's
                                          device id)
Category:    Relay / Abuse
Component:   relay-uws/src/ws_handler.cpp (handle_binary_channel_direct); MockRelay's
             copy in rust/hollow_core/src/node/test_harness.rs
Boundary:    TB-1 (the relay's rooms) / TB-0 (the internet)
Traces to:   phase B matrix relay:A-24; HOL-SEC-091 (design D1)
Attacker:    anyone holding a server id, with a throwaway identity
Found:       2026-10-03 (phase B matrix, decided for session 33)
```

## Description

Design D1 hides a door-locked server room from every socket that does not prove the
newest door: such a socket may be anyone who learned the server id. The 0x09 handler
(the targeted channel copy a member sends for each offline member, with its push) only
asked that the sender be in the room, not that it see it, so a hidden socket could still
park channel copies for any member device it could name and fire channel push wakes at
it, while the room hid it from everyone.

## Fix

The relay keeps a channel copy and fires its wake only when the sender sees the room
(`Audience::sees`): a prover in a locked room, as before anyone in an unlocked one.
MockRelay records the copies the relay would keep (`channel_copies_for`) under the same
rule. The other sender checks were swept: 0x03, 0x07 and JSON `msg` from a hidden socket
still reach the provers, and its directs (0x02, 0x04/0x08, JSON `direct`) still reach
their target, as D1 requires (a joiner's request, `DoorAsk`, the `~join` ring); a 0x0A
from it reaches only the provers; there is no inbound 0x06.

## Residual risk

A member that proves the door can still send copies and wakes to any member, which is
what a member's post is; on iOS the wake can show a banner the device cannot suppress
until the notification filtering entitlement arrives (phase G, K3). While
`ACCEPT_UNSIGNED_RING_CONTROL` is on, an unsigned `set_topic_buffer` from a hidden socket
still sets or stops the room's rings (row A-16), until that switch goes off after 0.12.

## Test

Relay live `test_relay_live` section "door rooms (D1): a hidden socket leaves no channel
copy" (5 checks per build; "a hidden socket's is never kept" failed on the old handler in
both builds). Harness `authz_a_socket_the_room_hides_leaves_no_channel_copy` (failed on
MockRelay's copy of the old rule: the hidden socket's copy was kept). Mutation pass
`tmp_s33_relay_mutate.py` ("0x09: a hidden sender" and its MockRelay twin killed).
