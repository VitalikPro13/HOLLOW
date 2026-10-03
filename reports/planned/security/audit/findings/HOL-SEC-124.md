# HOL-SEC-124: A re-sealed MLS commit or Welcome made us send what we hold

```
ID:          HOL-SEC-124                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact L: metadata, which ops and messages we hold,
                                          restricted channels' marks included; Exploitability
                                          M: whoever re-seals a member's genuine commit or
                                          Welcome, the relay running its own identity included)
Category:    Information disclosure / Sync
Component:   rust/hollow_core/src/node/crypto_handler.rs (mls_sync_partner, the Verdict::Hold
             arm of commit handling), node/swarm.rs (after_welcome_joined)
Boundary:    TB-1 (relay), TB-3 (server members)
Traces to:   phase B matrix server_mls A-10 (session 32); the HOL-SEC-089 class
Attacker:    any device that re-seals a genuine MLS commit or Welcome to us
Found:       2026-10-03 (matrix rebuild)
```

## Description

HOL-SEC-089 limited the sync we send after a stale decrypt to member devices, and kept
the sync after a held commit on the reasoning that a commit comes from a real leaf. The
leaf is real, but the sync went to the device that sealed the frame, which nothing tied
to the leaf: anyone who re-sealed a genuine commit to us was sent our op-log state vector.
The same held after an accepted Welcome, where we sent the frame's sealer our state
vector and a channel sync request for every channel.

## Fix

Both ask `crypto_handler::mls_sync_partner`: the committing (or welcoming) leaf's own
device when its certified master is a current member and the roster does not refuse it,
otherwise the frame's sender only if `sync_partner` admits it; each channel sync only if
that partner can read the channel.

## Residual risk

None known.

## Test

Harness `authz_a_held_commit_asks_only_a_member_to_sync` (RED: "the device that delivered
a held commit was sent what we hold, left: 1 right: 0"),
`authz_a_welcome_asks_only_a_member_to_sync` (RED: "the device that delivered a Welcome
was sent what we hold, left: 2 right: 0"); unit
`authz_mls_syncs_ask_only_a_member_device`; scan `welcome_channel_syncs_stay_gated`;
mutation 7/7 killed (`tmp_s32_conf_mutate.py`).
