# HOL-SEC-123: Meetings took a device its identity's roster no longer counts

```
ID:          HOL-SEC-123                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Medium                      (Impact M: inside a meeting the device acts as that
                                          identity and can run the host's lobby; Exploitability
                                          L: needs the identity's master key, and the link key
                                          for host frames)
Category:    Authorisation / Identity (design ID-1, G1 class)
Component:   rust/hollow_core/src/node/conference.rs (verified_host, seat_of, seated,
             handle_inbound_chat), node/swarm.rs (knock, admit_peer, the meeting voice join
             guard)
Boundary:    TB-6 (device keys vs the identity)
Traces to:   phase B matrix server_mls A-17..A-22 (session 32)
Attacker:    a holder of an identity's master key whose device that identity's roster does
             not count (a removed device, a restored backup never admitted)
Found:       2026-10-03 (matrix rebuild)
```

## Description

Design ID-1 made the roster, not the master key, decide which devices speak for an
identity, and HOL-SEC-083 applied that everywhere a device is attributed to its master,
except in meetings. `verified_host` took any device the host master's certificate bound,
so a master-key holder with the meeting link could deny, set the lobby banner, end the
meeting or kick through a device it minted, at guests holding the host's roster; the
knock, the host's admit and meeting chat never asked the roster either, so such a device
could knock as that identity, be seated and speak.

## Fix

One rule, `mls_authority::refused` (revoked, or a roster we hold disowns it), now applies
to host frames (`verified_host`), the knock (`seat_of`) and again at `admit_peer`,
meeting chat and cards, and the meeting voice join (`conference::seated`). Where we hold
no roster for the identity the certificate still decides (AR-15, first contact).

## Residual risk

A device the roster stops counting while a meeting runs is never taken out of the
meeting's MLS group: the removal is queued, but the batch tick skips groups that have no
server state (`conf:` groups), so it keeps the group key and can decrypt media and chat
until it is kicked or the meeting restarts; guests drop what it says.

## Test

Harness `authz_a_device_the_hosts_roster_leaves_out_runs_no_lobby` (RED: "a device the
host's roster leaves out ran the knocker's lobby"),
`authz_a_device_its_roster_leaves_out_never_joins_or_speaks_in_a_meeting` (RED: "a device
its roster does not count reached the waiting room"); unit
`a_host_frame_counts_only_from_a_device_the_hosts_roster_counts`,
`a_meeting_seat_needs_a_leaf_its_masters_roster_counts`; mutation 7/7 killed
(`tmp_s32_conf_mutate.py`).
