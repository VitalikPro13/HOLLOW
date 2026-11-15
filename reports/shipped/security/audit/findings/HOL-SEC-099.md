# HOL-SEC-099: Rust took any string as a server id

```
ID:          HOL-SEC-099                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: defense in depth: `S#chan` read as a channel subgroup and `conf:` started a server join for a meeting id;
                                          Exploitability M: a link, a sibling's announce, or an MLS frame naming such an id)
Category:    Input validation
Component:   rust/hollow_core/src/crdt/anchor.rs (valid_server_id), api/crdt.rs (join_server,
             request_public_channels), node/sync_handler.rs (joinable_server_id),
             swarm.rs (frame dispatch, SiblingServerAnnounce), mls_authority.rs (names_a_group), fetch.rs
Boundary:    TB-1 / TB-3
Traces to:   phase B re-check crdt B-05 (second half)
Attacker:    a member, a sibling, or anyone handing out a link
Found:       2026-10-02 (phase B re-check)
```

## Description

Only the Dart link parser checked a server id's shape. A join, a guest browse, a sibling's server announce and every inbound MLS frame took any string, so `S#chan` built the group key of the channel subgroup (S, chan) and a `conf:` id could start a server join and a server state for a meeting.

## Fix

A server id is 40 lowercase hex (self-certifying) or 32 (legacy), as the relay already requires. The FFI join and browse, the join handler (also "request again") and the sibling announce refuse anything else; every inbound MLS frame, relay, meeting lane or carried, is checked once at frame dispatch and in the push fetch, admitting a server id or a pinned meeting id with a well-formed channel id.

## Residual risk

A DM room code is also 32 hex, so it passes the shape check (it is secret). Dart accepts uppercase hex ids, which Rust now refuses; before, such a join parked and nobody could answer it.

## Test

Unit `a_server_id_is_32_or_40_lowercase_hex`, `an_mls_frame_names_a_group_only_by_real_ids`, `mls_frames_are_shape_checked_before_dispatch`, `a_join_or_browse_needs_a_server_id`; harness `join_with_a_malformed_server_id_starts_nothing` (failed before: "a malformed id joined a room"); mutation killed.
