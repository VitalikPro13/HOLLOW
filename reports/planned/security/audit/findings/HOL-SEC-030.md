# HOL-SEC-030: Anyone who knew a server id could flush its catch-up rings, and guests could post to them

```
ID:          HOL-SEC-030                 Status: Fixed and deployed to the official relay (2026-09-27)
Severity:    Medium                      (Impact M: every parked join request and catch-up frame of a channel
                                          evicted, so offline members and pending joiners miss them; a guest
                                          socket depositing and waking phones; Exploitability H: the server id,
                                          which every invite link carries)
Category:    Uncontrolled resource consumption (shared buffer); missing guest restriction
Component:   relay-uws/src/ring_evict.h :: ring_victim
             relay-uws/src/ws_handler.cpp :: handle_binary_topic_msg, binary dispatch (guests),
             handle_direct
Boundary:    TB-1 (client <-> relay)
Traces to:   C-26; candidates I7, I11 (evidence relay:A-23a, A-05)
Attacker:    P-03 anyone who knows a server id, P-02 guest socket
Found:       2026-09-26, phase B relay pass; confirmed by reading 2026-09-27
```

## Description

A channel's catch-up ring kept its newest 200 frames first in, first out, and
anyone in the server's room could post to it, so 200 junk frames evicted every
parked join request and catch-up frame. Guest sockets, which only read, were
not limited on topic frames at all, and could deposit into offline buffers and
wake phones through the JSON form of a direct message, which the binary form
already refused them.

## Reproduction

`test/test_ring_evict.cpp` (relay unit test: honest frames survive a flood of a
thousand junk frames into a ring of 200).

## Fix

- A full ring drops the oldest frame of the sender holding the most frames in
  it, so a flooder evicts only itself (the relay rule: reprioritise, never
  refuse). Equal senders keep first-in, first-out order.
- Guest sockets may not send topic frames or JSON direct messages; the web
  viewer sends neither.
- Two relay comments that described a rate limit that does not exist are
  corrected (I13).

## Variants

- Reading the rings (`topic_catchup`) and registering them need only the server
  id, and the join ring carries join requests in the clear (candidates I5, I6):
  the class A work.

## Test

The ring test fails with first-in, first-out eviction and passes with the
fair-share choice. Built and run on the relay host before the deploy.
