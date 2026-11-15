# HOL-SEC-044: Any frame that failed to process made a member drop its encryption group

```
ID:          HOL-SEC-044                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M, availability: anyone able to send into a server room, the
                                          relay included, could knock a member out of the group again and again,
                                          forcing a re-key for everyone, and cut a meeting participant out for
                                          good; Exploitability H: a few bytes of garbage)
Category:    Denial of service; state change on unauthenticated input
Component:   rust/hollow_core/src/node/crypto_handler.rs :: handle_mls_commit_frame, handle_epoch_hint
             rust/hollow_core/src/node/swarm.rs :: MlsChannelMessage arm
             rust/hollow_core/src/node/voice_handler.rs :: escalated SFrame heal
             rust/hollow_core/src/crypto/mls_manager.rs :: decrypt_fresh, epoch_auth_digest
Boundary:    TB-1 (relay), TB-2 (peer <-> peer)
Traces to:   C-19; candidate D4 (evidence S-18, S-21, S-24)
Attacker:    P-01 relay operator, P-03 room peer
Found:       2026-09-26, phase B server/MLS pass; confirmed by reading 2026-09-27
```

## Description

A commit that failed to process, including one with no epoch or plain garbage,
made the receiver drop its group and ask to be added again. So did three
undecryptable channel frames spread over three seconds. None of these frames
needed a key to send.

## Reproduction

`authz_garbage_mls_frames_never_drop_a_group` and
`a_same_epoch_fork_heals_through_the_probe` (node/test_harness.rs),
`the_epoch_digest_tells_forks_apart` (crypto/mls_manager.rs).

## Fix

- A group changes only on an authenticated MLS event that passes our rules: a
  commit we accept, a Welcome we accept, or our own CRDT state.
- A frame that does not parse, names another group or comes from an unbound
  leaf is ignored. Any other decrypt failure, and any commit that fails, keeps
  the existing sync requests and sends a throttled epoch probe.
- Probes carry a short digest of the epoch authenticator. When the member that
  answers our catch-ups sees our epoch equal to its own but the digest
  different, we hold a fork; it asks us for a KeyPackage and repairs us in one
  commit.
- The escalated SFrame heal keeps the group and asks for a repair.

## Variants

- The relay can forge a probe from a member and cost it one repair (S-20);
  signing probes is class A.
- The relay can still withhold commits; members then catch up by probe.

## Test

The garbage test fails with the drop-on-failure rule put back; the fork test
fails with fork detection turned off. Full suite green.
