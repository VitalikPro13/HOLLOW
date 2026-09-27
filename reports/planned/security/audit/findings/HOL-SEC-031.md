# HOL-SEC-031: A revoked device could read its master's mailbox again after every relay restart

```
ID:          HOL-SEC-031                 Status: Fixed and deployed to the official relay (2026-09-27)
Severity:    Medium                      (Impact M: a revoked sibling reads the friend requests and pending
                                          invitations parked for its old identity; Exploitability M: a revoked
                                          device keeping its last signed device list, and any relay restart,
                                          which every deploy is)
Category:    Security state lost on restart
Component:   relay-uws/src/snapshot_codec.h :: Mark (codec version 3)
             relay-uws/src/snapshot.cpp :: device-list mark capture and restore
Boundary:    TB-1 (client <-> relay)
Traces to:   C-21; candidate I10 (evidence relay:A-02c)
Attacker:    P-07 revoked device
Found:       2026-09-26, phase B relay pass; confirmed by reading 2026-09-27
```

## Description

The relay replays a master's inbox mailbox to a device that presents a
master-signed device list naming it, and keeps the highest list version seen
per master so a revoked device cannot replay the older list that still named
it. Those marks lived in RAM only and were not in the restart snapshot, so
after any restart the revoked device could read the mailbox again until a
current sibling presented a newer list.

## Reproduction

`test/test_snapshot_codec.cpp` (relay unit test: the marks survive a round trip
in order, and a version 2 snapshot from the previous build still decodes).

## Fix

- The marks join the restart snapshot as codec version 3, captured and
  restored in their eviction order. A version 2 snapshot still decodes, so the
  deploy kept every buffer the previous process handed over.

## Test

The round trip fails without the marks in the codec and passes with them; the
v2 fixture decodes. Built and run on the relay host before the deploy, and the
deploy restored the previous process's snapshot.
