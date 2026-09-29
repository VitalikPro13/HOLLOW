# HOL-SEC-064: A person's inbox room showed strangers their devices and when they were online

```
ID:          HOL-SEC-064                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: which devices a person has and when each is
                                          online, and who else is asking to be their friend, to anyone
                                          who knows their master id; Exploitability H: joining a room
                                          by name)
Category:    Data exposure
Component:   relay-uws/src/ws_handler.cpp :: inbox_owner_proved, receives_in_room, handle_join,
             leave_room, collect_room_co_members, discover_peers, every fan-out, the 0x04 mailbox
             deposit; state.h :: WsRoom::owners; rust/hollow_core/src/node/test_harness.rs (MockRelay)
Boundary:    TB-1 (client <-> relay), TB-2 (stranger <-> person)
Traces to:   C-24 (presence), C-25; candidate I4 (inbox half; the DM-room half is HOL-SEC-062)
Attacker:    P-06 anyone holding a master id (profiles, member lists, friend requests, nicknames)
Found:       2026-09-26 (phase B), re-confirmed 2026-09-27 in the design A inventory (B.3, B.5 item 4)
```

## Description

Everyone asking to be someone's friend joins that person's `inbox:{master}` room and
stays while the request is pending. The relay handed every joiner the room's roster
and a presence stream, so a stranger learned the person's online device ids and when
each came and went, and the person's devices saw every stranger asking. `check_peers`
answered for anyone sharing a room, which the inbox made everyone.

## Reproduction

`authz_an_inbox_shows_its_devices_only_to_each_other` (node/test_harness.rs).

## Fix

A socket that proves on join that it is one of the master's devices (the master-signed
device list the mailbox already required) is an owner of that inbox. Only owners see
each other there: the roster, `peer_joined`, `peer_left`, `discover_peers` and
`check_peers` co-membership, and every broadcast or direct frame in the room reach
owners only; a non-owner sees a roster of itself. A deposit addressed to the master
is kept in the mailbox as before and handed at once to every owner online, since the
depositor no longer learns which devices those are. A socket that proved once stays
an owner through the proof-less re-joins the client makes; a new socket proves again.
The harness relay applies the same rule.

## Test

The harness test above (two devices of one person, two askers: the askers see neither
the devices nor each other, discovery shows them nobody, the owners never hear of them,
and a deposit reaches both owners live and waits in the mailbox), plus the whole
harness suite running on the owner-only relay, friend and sibling flows included.
Mutation pass: an inbox that shows everyone, no live fan-out, and an owner losing its
place on a plain re-join each fail a test.

## Residual

The relay itself still sees which devices join an inbox (routing; HOL-SEC-062).
