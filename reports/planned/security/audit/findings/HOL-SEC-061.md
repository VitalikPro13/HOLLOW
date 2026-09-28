# HOL-SEC-061: Anyone in a meeting's room could run its lobby and admit the knocker

```
ID:          HOL-SEC-061                 Status: Fixed on local main (2026-09-28), retest at release
Severity:    High                        (Impact H: a stranger becomes the meeting's committer and
                                          SFrame source for a knocker, or denies, ends and kicks for
                                          the host; Exploitability M: any identity that joins the
                                          meeting's relay room, the relay included)
Category:    Missing authorization
Component:   rust/hollow_core/src/node/conference.rs, swarm.rs (conference arms and MlsWelcome),
             node/mls_authority.rs :: judge_welcome, lib/src/core/providers/conference_provider.dart
Boundary:    TB-2 (peer <-> peer), TB-1 (client <-> relay)
Traces to:   C-22, C-25; server_mls inventory S-26, S-29..S-32 (candidates A15, A16, A27)
Attacker:    P-05 / P-06 any identity in the room; P-01 relay with an identity of its own
Found:       2026-09-26 (phase B), re-confirmed 2026-09-27 in the design A inventories
```

## Description

A meeting id was 32 random characters that named nobody. While a knock was
pending the knocker accepted a Welcome from any bound leaf, so any identity in the
room could build the meeting group around the knocker's broadcast KeyPackage and
become its committer and SFrame source. Lobby info, denial, end and kick frames
were taken from any sender, and the Dart lobby trusted whoever last claimed to be
host. The knock carried the access code as a hash anyone who saw it could replay
under their own identity.

## Reproduction

`authz_only_the_host_a_meeting_id_names_runs_its_lobby`,
`authz_a_knock_proves_its_code_only_for_its_own_device` (node/test_harness.rs).

## Fix

A meeting id is now 40 hex characters of SHA-256 over the host's master and a
founding nonce the host keeps. Every host frame (lobby info, denial, end, kick)
carries the master, the nonce and the host device's MLS leaf certificate, and is
dropped unless the id hashes from them and the certificate binds the device that
sealed the frame. The admitting Welcome carries the nonce and counts only from a
leaf of that master. Rust hands Dart the proven host, and Dart keeps the first one.
A knock proves the access code with an HMAC over the meeting id and the knocking
device, keyed by an Argon2id derivation of the code, so a proof lifted from another
knock opens nothing. A refused or unreadable Welcome spends the knocker's
KeyPackage, so the knocker knocks again at once with a fresh one.

Rooms made before 0.12 cannot be started, and their links are refused with a
message to ask for a new one (Vitalik, 2026-09-28: no migration).

## Test

The two harness tests above (the rogue replays the host's own proof, offers its
own, builds a substitute group around the knocker's KeyPackage and lifts a knock
proof); unit tests `a_meeting_id_names_its_host`,
`a_host_frame_proves_its_host_only_from_the_hosts_device`,
`a_knock_proof_holds_only_for_its_device_meeting_and_code` (node/conference.rs),
`a_meeting_welcome_counts_only_from_the_host_its_id_names` and `welcome_rules`
(node/mls_authority.rs). A scripted mutation pass put each of eleven rules back;
every one failed its test.
