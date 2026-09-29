# HOL-SEC-072: The relay read meeting knocks, lobby frames and the host

```
ID:          HOL-SEC-072                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: claim C-24 broken for meetings: a knocker's name,
                                          avatar hash and KeyPackage credential (device and master),
                                          the host's name, and the host's master and founding nonce
                                          in every host frame and Welcome; Exploitability H: the
                                          relay reads every frame it routes)
Category:    Information disclosure
Component:   rust/hollow_core/src/node/conference.rs (the meeting lane: seal_meeting, open_meeting,
             MeetingSeal, MEETING_KEYS), types.rs (Lane::Meeting, HavenMessage::MeetingSealed),
             swarm.rs (the relay-frame opener), api/conference.rs, storage/messages.rs
             (conferences.link_key); lib/src/ui/chat/hollow_link_utils.dart,
             core/providers/conference_provider.dart, shell/conference_dashboard.dart,
             dialogs/relay_switch_dialog.dart, deep_link_service.dart, hollow_link_card.dart;
             anonlisten-sites hollow/src/routes/join/+page.svelte
Boundary:    TB-1 (client <-> relay)
Traces to:   C-24 (note 2), HOL-SEC-061
Attacker:    P-01 the relay
Found:       2026-09-28 (A-D1 left-open list), decided 2026-09-29 (Vitalik: a `key=` in meeting links)
```

## Description

A knock carried the knocker's display name, avatar hash and a KeyPackage whose leaf
credential names its device and master, in a frame the relay reads. The lobby frame
carried the host's name and avatar hash, and every host frame (lobby, denial, end, kick)
the host's master, founding nonce and certificate. The meeting Welcome carried the
nonce too, and with it the relay could test every master it knows (they name `inbox:`
rooms) against the meeting id and find the host.

## Reproduction

`c24_a_meeting_shows_the_relay_no_name_and_no_host` (node/test_harness.rs, wiretap):
a whole meeting (knock, lobby, admit, end) with none of the names, the avatar hash, the
nonce or the link key readable, and no meeting frame in the clear.

## Fix

A meeting link carries a key next to the id (`key=`, 32 random bytes as unpadded
URL-safe base64, the shape of a server invite's), minted with the room and kept for its
life (a room made before gets one on its next start, so its old link stops). The knock,
the lobby info, the denial, the end, the kick and the meeting Welcome are the meeting
lane (`Lane::Meeting`; a Welcome is when its server id is a meeting's): they count only
inside `MeetingSealed`, AES-256-GCM under a key derived from the link key and the
meeting id, bound to the meeting's room and the sealing device, and only when what
they hold names that same meeting. A plaintext copy falls to the lane check. The host
keeps the key in the room row and its hosting state, a joiner from the link while it
knocks or sits in the meeting. A link without a key cannot knock ("This meeting link is
from before the update. Ask the host for a new one."), and the join dialog takes a link,
not a bare id. The website's `/join` bounce passes the key (and, fixed on the way, the
server join key its automatic hand-off used to drop).

## Test

The wiretap test above; `authz_a_meeting_frame_counts_only_under_its_link_key` (a
plaintext knock, one under another key, one sealed in one meeting naming another and a
keyless link all stay out of the waiting room; the same knock sealed right counts);
`authz_only_the_host_a_meeting_id_names_runs_its_lobby` and
`authz_a_knock_proves_its_code_only_for_its_own_device` now seal their forged frames
under the link key, so they still reach the host and code gates;
`a_meeting_frame_opens_only_under_its_key_in_its_room_for_its_sender`
(node/conference.rs); Dart `a meeting link carries its key in both forms`. Mutation
pass: the same-meeting check dropped, and the knock sent in the clear, each fail a test.

## Residual

The relay still sees a meeting's room, which devices sit in it, and when (C-24's routing
metadata). Anyone holding the link reads the knocks of others, as any room member could
before; the waiting room, the access code and the MLS add still decide who gets in.
