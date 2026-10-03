# HOL-SEC-125: The bare master id came back into room presence through discovery

```
ID:          HOL-SEC-125                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact L: the bare master id is listed in our room
                                          presence and sent our signed KeyRequest; its frames
                                          stay dropped; Exploitability L: needs the master key)
Category:    Authorisation / Identity (HOL-SEC-083 gap)
Component:   rust/hollow_core/src/node/swarm.rs (WsEvent::DiscoveredPeers arm)
Boundary:    TB-6 (device keys vs the identity)
Traces to:   phase B matrix relay B-12 (session 32), HOL-SEC-083
Attacker:    a holder of an identity's master key logged in as the bare master id
Found:       2026-10-03 (matrix rebuild)
```

## Description

HOL-SEC-083 keeps a bare master id out of room presence: the PeerJoined and RoomMembers
arms filter through `bare_presence.admits`. The DiscoveredPeers arm did not, so every
discovery tick put the bare master id back into `ws_room_peers` and sent it our signed
KeyRequest.

## Fix

The DiscoveredPeers arm filters through `bare_presence.admits` like the other two, and
the wiring guard covers it.

## Residual risk

None known.

## Test

`bare_master_gates_stay_wired` (node/roster_book.rs tests, extended; RED: "swarm.rs:
WsEvent::DiscoveredPeers ... no longer asks bare_presence.admits(p)"); mutation killed
(`tmp_s32_conf_mutate.py`).
