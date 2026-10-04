# HOL-SEC-141: Anyone who could reach us in a room learned our IP addresses through the Share lane, even with Always relay on

```
ID:          HOL-SEC-141                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: public and LAN addresses; Exploitability M: a meeting knocker, anyone joining a legacy server room, or a public-channel server via a known device id)
Category:    Data exposure
Component:   rust/hollow_core/src/node/share_handler.rs (holds_a_link_we_serve), swarm.rs
Boundary:    TB-2
Traces to:   phase E+F media C-MEDIA-04; variant of HOL-SEC-040
Attacker:    P-03 stranger
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Share-lane offers were checked only against the block list and answered from a STUN-only
connection.

## Fix

A Share-lane offer is answered only for a peer that proved, in a share's own room, the link
key of a share we hold. The Always-relay subtitle now says that files over 34 MB still go
straight to their recipient.

## Test

`authz_only_a_link_holder_gets_a_share_lane_answer` (failed on the old handler).
