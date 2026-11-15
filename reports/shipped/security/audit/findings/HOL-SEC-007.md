# HOL-SEC-007: Any peer could kill another user's node with one profile announce, and a member could name a file outside the data folder

```
ID:          HOL-SEC-007                 Status: Fixed on local main (2026-09-26), retest at release
Severity:    High                        (Impact M-H: the node's event loop dies, so the app shows a live window with no
                                          network until restarted, repeatable on every reconnect; Exploitability H: any peer
                                          sharing any room, including a stranger in the inbox room, or the relay)
Category:    Data validation (remote-triggerable panic; path built from a remote string)
Component:   rust/hollow_core/src/node/swarm.rs :: plaintext ProfileUpdate arm (text caps), recovery TransferPlan arm,
             ShardRequest serving arm (temp name); node/link_handler.rs :: handle_accept_link_push (session id)
Boundary:    TB-2, TB-1
Traces to:   AS-11 availability, C-29; candidates G1..G4, H17
Attacker:    P-03 stranger (any room, the victim's inbox room included), P-05 member, P-01
Found:       2026-09-26, phase B identity and files passes, confirmed by reading and test
```

## Description

Four places cut a remote string with a byte slice: `display_name[..64]` (and
`status`, `about_me`, `twitch_username`) in the plaintext `ProfileUpdate` arm,
`&content_id[..8.min(len)]` in the recovery plan, `&cid[..16.min(len)]` in shard
serving, and `&target_peer[len - 8..]` for the link session id. A byte slice
through a multi-byte UTF-8 character panics; in the swarm event loop that panic
ends the node task, and every later frame goes nowhere. `clip_text` already
existed for message bodies with exactly this comment; the profile caps were
written without it.

The shard-serving arm also used the member-supplied `cid` to name a temp file,
`.stream_shard_{cid}_{i}.tmp`. `store_shard` accepts any cid (the shard file
itself is named by a hash), so a member could store a shard under `\..\..\x`
and ask for it back: on Windows the path collapses lexically out of `files/` and
the shard bytes, which the attacker chose, land there.

## Reproduction

`authz_a_remote_string_never_panics_the_node`: before the fix, a display name
with a multi-byte character across the cut panicked the node.

## Fix

- `crypto_handler::clip_bytes(s, max)`: the one way to cut a remote string, at a
  character boundary; `clip_text` now uses it. Every site above goes through it
  (the link session id takes the last eight CHARACTERS).
- The shard temp name keeps only alphanumerics of the cid.
- Long term (class kill): `clippy::string_slice` and `clippy::indexing_slicing`
  denied in the receive modules (`node/`, `crdt/`, `forwarder/`), ratcheted like
  the design guards, so a new byte slice on remote text cannot land (plan 2.8
  item 8).

## Variants

- Every `[..N]` / `[N..]` on a `String` in the node: the grep behind this finding
  found no other remote-reachable site; `share_handler.rs:1721` slices a registry
  key we minted (64 hex).
- Every format string that turns a remote id into a path: FILE-1 (fixed 0.10.2),
  `parse_id` for stream ids (allowlisted), and this cid.
- Arithmetic panics on remote numbers: `hlc` `counter + 1` (candidate E14).

## Test

`authz_a_remote_string_never_panics_the_node`: failed before the fix (panic),
passes after; 180 profile, vault, shard, recovery and link tests pass.
