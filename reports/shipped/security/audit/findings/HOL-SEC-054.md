# HOL-SEC-054: Frames the relay held back or replayed were acted on again

```
ID:          HOL-SEC-054                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a call invite rang a day late, a repeated Olm frame
                                          tore a working session down, an old removal ended a new
                                          friendship, an old kick threw out a member who had rejoined,
                                          an old join request re-admitted someone who had left, a
                                          replayed KeyRequest minted keys; Exploitability M: needs the
                                          relay the victim uses)
Category:    Replay
Component:   rust/hollow_core/src/node/types.rs :: HavenMessage::live_only, MessageEnvelope::live_only
             node/frame_auth.rs :: ReplayGuard; crypto/olm_manager.rs :: already_decrypted
             node/swarm.rs (FriendRemove, FriendAccept, ServerJoinRequest, ServerJoinRejected,
             ServerJoinResolved, MemberKickBroadcast arms); node/sync_handler.rs ::
             kick_predates_membership; crdt/server_state.rs :: member_since, left_at
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25, C-12, C-15; candidates A14, A7, L6 (was AR-09), S-05..S-07 of server_mls
Attacker:    P-01 malicious relay
Found:       2026-09-27, design A inventories
```

## Description

Frames carried no send time the receiver could trust, so a frame the relay held
back or delivered again looked fresh. Signals inside Olm were protected from
replay by the ratchet but not from delay. A genuine Olm frame delivered twice
failed its spent message key, and that failure tore the session down.

## Reproduction

`authz_a_live_frame_is_taken_once_and_only_while_fresh`,
`authz_a_call_invite_held_back_by_the_relay_never_rings`,
`authz_a_replayed_olm_frame_leaves_the_session_alone`,
`authz_a_removal_older_than_the_friendship_is_ignored`,
`authz_a_join_request_from_before_a_leave_never_readmits`,
`authz_a_kick_from_before_a_rejoin_is_ignored` (node/test_harness.rs).

## Fix

- Every message type is classed in one exhaustive list: live-only frames older
  than 300 s are refused, and a nonce seen from that sender inside the window is
  refused. This also closes L6: honest same-second KeyRequests now differ by
  nonce, so a replay guard no longer confuses them.
- Signals carried inside Olm or MLS (calls, voice, forwarder, typing, sync
  requests) are judged by the seal's time.
- A session remembers the ciphertexts it decrypted and drops a repeat before any
  teardown path.
- Late-deliverable frames are bounded by the seal's time: a removal sealed
  before the friendship, an accept sealed before our request, a kick sealed
  before our membership, and a join request sealed before the joiner last left
  are refused. A rejection must name the pending ask exactly; a resolution may
  not name an ask after its own seal. KeyPackages are live-only.

## Test

Each test fails with its old rule put back and passes with the fix.
