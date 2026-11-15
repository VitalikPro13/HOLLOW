# HOL-SEC-048: A member could backfill posts signed by someone who was never in the server

```
ID:          HOL-SEC-048                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: posts by an outsider verified, showed as Verified in the
                                          Message Proof and spread server-wide through every receiver's own
                                          sync; Exploitability M: a current member who can read the channel)
Category:    Missing authorization (history)
Component:   rust/hollow_core/src/crdt/server_state.rs :: member_record, was_member_at
             rust/hollow_core/src/crdt/fold.rs :: checkpoint_json
             rust/hollow_core/src/node/crypto_handler.rs :: backfill_author_allowed
             rust/hollow_core/src/node/swarm.rs :: ChannelSyncBatch (Olm and MLS arms)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15, C-17; candidate E4 (decision 2a)
Attacker:    P-05 member with a modified client
Found:       2026-09-26, decision 2 follow-up; confirmed by reading 2026-09-27
```

## Description

Backfill accepted any correctly signed post from a current member who can read
the channel. The server state kept only current members and a capped op log, so
nothing could say whether a post's author had ever been a member.

## Reproduction

`authz_backfill_refuses_a_post_by_someone_never_a_member` (node/test_harness.rs)
and `the_membership_record_spans_admission_to_removal` (crdt/fold.rs tests).

## Fix

- Every server state keeps a membership record: per master, the spans it was a
  member, opened by its admission (or the founding op) and closed by its removal
  or ban, carried by every checkpoint.
- An existing server's first checkpoint seeds the record from the owner's own
  knowledge: every current member from the start, and every author of a channel
  post the owner holds as a former member up to the checkpoint.
- Both channel backfill arms drop an item whose author was not a member at the
  item's time, with 10 minutes of slack for clocks. A legacy-anchored server is
  not judged until its checkpoint gives it a record.

## Variants

- A former member can still backdate a post into a span it really was a member
  for, and have a current member backfill it: the post is its own, signed by it.

## Test

Each test fails with its old rule put back and passes with the fix. Full suite
green.
