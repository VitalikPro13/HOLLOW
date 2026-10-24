# HOL-SEC-178: A busy channel's ring replay starved the owner's direct frames, so a joiner was never seated

```
ID:          HOL-SEC-178                 Status: Fixed (2026-10-23, wave g13, local commit b6fbf2e8),
                                          ships with 0.13
Severity:    Medium                      (Impact M: a new member of a busy server never takes its MLS seat
                                          and never sees history; Exploitability: none needed, any channel
                                          with a few hundred ringed frames does it)
Category:    Availability
Component:   rust/hollow_core/src/node/frame_budget.rs (per-route buckets), node/swarm.rs (drop repair)
Boundary:    TB-1 (client <-> relay), TB-2
Traces to:   AS-11 (availability)
Attacker:    none needed
Found:       2026-10-23 (wave g13, fleet proof of the sync-cost track)
```

## Description

A joiner that opened a channel before its Welcome first received the relay's ring replay,
hundreds of channel frames from the owner that it could not read yet. They emptied the one
receive bucket the joiner keeps per sender, so the owner's direct frames that followed, the
roster among them, were dropped. The joiner could not place the owner's device, its drop
repair found no member to ask, and it never took its MLS seat. Live in 0.12.2 for any busy
channel.

## Fix

Each sender has two buckets, one for frames addressed to us and one for room and topic
broadcasts, ring replays included; the seal binds the route, so a relabelled frame fails
closed. When a flood leaves a device in one of our server rooms unplaced, the repair asks
that device for its profile once, through that server's room; removed devices and bare
master ids are never asked, and an unanswered ask expires.

## Residual risk

Two follow-ups are not fixed. The MLS ring pull should wait until the joiner is seated, and
a co-member's profile should be re-asked by hash.

## Test

Harness `g13w3_a_joiner_past_a_full_ring_still_gets_its_welcome` and
`g13w3_a_repair_asks_an_unplaced_member_device_for_its_profile` (both red before the fix),
unit `a_broadcast_flood_leaves_the_direct_bucket_whole_and_one_repair_waits_for_both`
(node/frame_budget.rs). Mutation passes 6/6 and 8/8; a 250-row fleet journey with a restart
passed.
