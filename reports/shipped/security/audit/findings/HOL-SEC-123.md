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
             handle_inbound_chat, unseat_refused, drop_leafless_from_call), node/swarm.rs
             (knock, admit_peer, the meeting voice join guard, the event loop's head, the
             MLS batch tick, the MlsCommit arm), node/voice_handler.rs (the MLS voice join)
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

Closed in session 33 (2026-10-03): a device the roster stopped counting while a meeting
ran kept its leaf in the meeting's MLS group, since the batch tick skips groups that have
no server state (`conf:` groups), so it could decrypt the meeting's later epochs. Now the
host takes it out: `conference::unseat_refused` removes every leaf of a meeting it hosts
that holds no seat (`mls_authority::refused`, or unbound) in one commit through
`broadcast_mls_commit`, and rotates the host's own SFrame key. It runs at the event loop's
head once the resolver moves (`conference::SeatWatch`, so on any roster change: a removal,
a revocation, a newer recovery) and on every MLS batch tick; it is idempotent and
device-scoped, so a sibling in the same meeting keeps its seat. Only the host commits:
participants accept the host's commits only, and already drop the device's chat, cards and
voice join (`refused`, `seated`).

The media half, closed the same session: every receiver keeps past SFrame keys in a
16-entry key ring, so a device out of the group stayed audible until its peer connection
closed, and a voice join sealed at its old epoch (which still decrypts for three epochs)
seated it in the call again; a kicked device that ignored `ConferenceKicked` did the same.
Now whenever a meeting commit removes leaves, at the host (`unseat_refused`,
`handle_conference_kick`) and at each participant merging it (the `MlsCommit` arm),
`conference::drop_leafless_from_call` takes every device without a leaf out of the
meeting's call with the `VoiceChannelLeft` a room departure emits, so Dart closes that
peer (`closePeer`: the connection, its renderers and its SFrame cryptor); a device the
commit evicted closes its call to everyone else. The meeting's MLS voice join now asks for
a seat (`conference::seated`) like the plaintext one. Dart needed no change.

What remains: a host that holds no roster for the identity (a stranger's meeting, AR-15)
never learns of the removal, so there the certificate still decides. The harness checks
the events that close the call, not the media plane itself.

## Test

Harness `authz_a_device_the_hosts_roster_leaves_out_runs_no_lobby` (RED: "a device the
host's roster leaves out ran the knocker's lobby"),
`authz_a_device_its_roster_leaves_out_never_joins_or_speaks_in_a_meeting` (RED: "a device
its roster does not count reached the waiting room"); unit
`a_host_frame_counts_only_from_a_device_the_hosts_roster_counts`,
`a_meeting_seat_needs_a_leaf_its_masters_roster_counts`; mutation 7/7 killed
(`tmp_s32_conf_mutate.py`).

The residual (session 33): harness `authz_the_host_unseats_a_device_its_roster_drops_mid_meeting`
(RED: "the host left a device its roster dropped seated in the meeting", then for the call
"the host kept the call open to a device its roster dropped"; the removed device, deaf to
the commit, cannot read the next epoch, its sibling can, the host, the sibling and the
guest each close their call to it once the commit lands, the sibling's call stays, no
participant but the host commits); `authz_a_device_out_of_the_meeting_group_loses_its_call_for_good`
(RED: "the host kept the call open to a kicked device still in the room"; a participant
closes it too, and the kicked device's join sealed at its old epoch seats nothing);
`conference_waiting_room_admits_denies_and_chats` now also checks that the evicted device
closes its call to the host and never reports itself leaving (RED: "a device the kick
evicted kept its call to the host open"); unit
`a_seat_watch_fires_once_per_move_of_the_resolver`, `meeting_seats_follow_the_roster_stay_wired`
(RED: "the loop head no longer sweeps hosted meetings when the resolver moves"). The
removed device in `authz_a_device_its_roster_leaves_out_never_joins_or_speaks_in_a_meeting`
is now deaf to the commit that unseats it, so the guest's own refusal is still what drops
its chat. Mutation 17/17 killed, the two session 32 meeting mutations still killed, and
each trigger alone unseats the device (`tmp_s33_conf_mutate.py`).
