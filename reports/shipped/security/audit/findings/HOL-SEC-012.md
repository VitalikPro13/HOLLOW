# HOL-SEC-012: Anyone in a server's room could make a member reveal who posts in any channel, restricted ones included, and stall its sync

```
ID:          HOL-SEC-012                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: the author list and each author's latest post time for any
                                          channel, restricted ones included, sent in the clear to the attacker and
                                          the relay; the member's real sync of that channel is skipped for 5 s per
                                          frame, indefinitely; Exploitability H: needs only the server id, which
                                          every invite link carries, or the relay's position)
Category:    Information disclosure; unauthenticated protocol message (a response nobody asked for)
Component:   rust/hollow_core/src/node/swarm.rs :: ChannelSyncProbe / ChannelSyncProbeResponse arms, Olm
             ChannelProbeResp arm, MLS ChannelProbe / ChannelProbeResp arms
             rust/hollow_core/src/node/sync_handler.rs :: handle_envelope_channel_probe(_resp)
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   C-18, C-24; candidate C8 (evidence channel:S9)
Attacker:    P-03 stranger who knows the server id, P-01 relay
Found:       2026-09-26, phase B channel pass; confirmed by reading and test 2026-09-27
```

## Description

A channel sync probe asked a peer for its newest timestamp and message count in
a channel, and the probe response told the asker to sync. No client has sent a
probe since 0.10 (reconnect sends a sync request directly), but the four
handlers stayed. The plaintext response handler took a response from anyone,
for any channel id, without checking that we had asked: it answered with a
plaintext sync request carrying our per-author watermarks for that channel
(every author we hold and the time of their latest post) and the gap digest,
and stamped the 5 second dedup that also gates our real sync of that channel.

## Reproduction

`restricted_channel_history_and_files_never_reach_a_non_qualifier`
(node/test_harness.rs, the stranger section) and
`retired_channel_probes_are_refused_at_parse` (node/types.rs tests).

## Fix

- The probe and probe-response wire types are gone, plaintext and envelope,
  with their handlers; a frame of either type is refused at parse.
- A decrypted Olm payload that does not parse is dropped (HOL-SEC-013), so the
  retired envelope types cannot reach the user another way.
- The serving gate the stranger section also exercised is covered at unit level:
  `authz_channel_served_only_to_a_member_who_can_read_it`.

## Variants

- The honest sync request still rides plaintext by design, so a member stays
  able to sync at a stale MLS epoch: the relay sees the same per-author
  watermarks for every channel a member syncs on reconnect. Candidate J8, to be
  moved into Olm with the class A work (decision 1).

## Test

The harness test fails with the old response arm put back (the stranger
receives the watermark request) and passes with the fix. Full suite green.
