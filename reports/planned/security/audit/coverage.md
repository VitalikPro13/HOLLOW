# Coverage of the Hollow security audit, 2026-09-26 to 2026-10-24

This document lists what each work package of the audit examined, what it found, what it
examined and found sound, and what it did not examine. It is the `coverage.md` the audit plan
requires before the audit can close (`reports/planned/security/SECURITY_AUDIT_PLAN.md` section 3
artifact table and section 6 exit criteria), in the style of a Cure53 work-package note,
including "areas examined that yielded no findings". It is an appendix of the final report
`SECURITY_AUDIT_2026_10.md`.

## Scope and how to read this

- **Scope commit.** `41080e0d` on `main` ("Add a setup wizard for self-hosted
 relays"). Earlier phases ran on the branches that became the 0.12.0 release (2026-10-05),
 0.12.1 (2026-10-16) and 0.12.2 (2026-10-20); the 0.13 wave ran on `security/0.13` from
 `faf97c4b` (Release 0.12.2+1).
- **Period.** 2026-09-26 (plan and phase A) to 2026-10-24 (merged-tree suites and fleets of the
 0.13 wave).
- **Who.** An internal review: the project owner set every policy, and AI agents enumerated
 code, wrote tests and acted as hostile reviewers (plan section 3, "the policy is decided by us,
 the evidence is gathered with help"). No independent human team took part. The final report is
 labelled an internal security review, never a third-party audit.
- **Each section** gives what was examined, how, what it found (HOL-SEC ids, briefly), what it
 examined that yielded no finding, and what it did not examine. Every statement cites its
 source. "No record" means the sources read hold nothing on that point.
- **Finding files.** `audit/findings/` holds 168 files: HOL-SEC-001 to 165 and 170 to 172.
 Numbers 166 to 169 were never used. Severities in the file headers: 8 Critical, 30 High,
 71 Medium, 57 Low, 2 Info (HOL-SEC-002 reads "High, possibly Critical" and is counted High).
 Findings from the 0.13 wave are described by what they are, since the final report numbers
 them.

Source keys used below. Paths are relative to the repository root unless noted.

| Key | Source |
|---|---|
| PLAN | `reports/planned/security/SECURITY_AUDIT_PLAN.md` |
| CLAIMS, TM, AR | `audit/claims.md`, `audit/threat_model.md`, `audit/accepted_risks.md` (all under `reports/planned/security/`) |
| MATRIX, CAND | `audit/authz_matrix.md`, `audit/candidate_findings.md` |
| EV, RC | `audit/phase_b_evidence/authz_<area>.md`, `audit/phase_b_recheck/recheck_<area>.md` |
| EF/x, DISP | `audit/phase_ef/<slice>.md`, `audit/phase_ef/dispositions.md` |
| MUT | `audit/mutation_passes/README.md` and the scripts beside it |
| RS-H, RS-B | `audit/rs_handshake_review.md`, `audit/rs_bounds_review.md` |
| SCALE | `reports/planned/relay-and-sync/SCALE_PROBE_2026_10.md` section 8 |

## Method in one table

| Activity | What it produced | Source |
|---|---|---|
| Research and method | Digest of eight published messenger audits, STRIDE, LINDDUN GO, ASVS/MASVS, RFC 9420/9750/9605, Olm and Sesame; the method, the work packages, secure-coding rules v0 | PLAN sections 0-5 |
| Phase A | 37 claims (C-01 to C-37, C-23 withdrawn), 12 attacker profiles (P-01 to P-12), 11 assets, 10 trust boundaries, flows F-01 to F-96, attack trees AT-1 to AT-6, the accepted-risk register | CLAIMS, TM sections 1-6, AR |
| Phase B evidence | Nine read-only enumeration passes, about 275 sections and 200 suspicions with `path:line` and verbatim quotes, grouped into candidate classes A to P | EV, CAND, MATRIX "How the rows were built" |
| Phase B re-check | Ten read-only passes at `d16deefe` (2026-10-02) re-checked every section against the code of the day; every FIXED held; leftovers became HOL-SEC-083 to 117 | RC, MATRIX |
| Phase B rebuild | Six passes at `1bac467f` (2026-10-03) rewrote the matrix: 346 rows, 1,737 citations checked by script (quote on its line), 0 wrong; the lead re-read every OPEN row and ten sampled FIXED rows | MATRIX |
| Designs | D (MLS leaves), E (CRDT fold), A (sealed frames, lanes), ID-1 (roster, phrase root, SPAKE2 link), ID-1R (relay rosters), D1 (door-proof rooms), the join lock | `audit/design_*.md`, PLAN state of play |
| Phase H | Relay host hardening (accounts, sandboxes, secrets, logs) | PLAN state of play session 19, HOL-SEC-073 to 075 |
| Phases E and F, merged | Eight read-only slices at `aa104d48` (2026-10-04): STRIDE per element, the 13 bug classes of PLAN 2.2, protocol checklists, LINDDUN GO on relay and push; 443 STRIDE cells, every candidate dispositioned | EF/*, DISP |
| Hostile reviews | Resumable sessions (handshake, bounds) and every 0.13 track (design review, code review, narrow re-review) | RS-H, RS-B |
| Tests | Every fix with a test that failed first; 210 distinct `authz_*` and 10 `c24_*` (wiretap) test functions in `rust/hollow_core/src` at the scope commit (grep count) | finding files, MATRIX "Guard tests" |
| Mutation passes | One mutation at a time, named tests expected to fail, file restored by hash | MUT, finding files, per track |
| Fleet and phones | Throwaway-identity journeys on Windows, macOS, Linux, iOS Simulators, Android emulators | `reports/shipped/security/REGRESSION_PASS_0.12.md` |
| Relay suites | `relay-uws/test/run_tests.sh` plain and with `SANITIZE=1` (ASan, UBSan) on the VPS before every deploy, and in CI job "Relay C++" | CLAUDE.md, `.github/workflows/ci.yml:350-372` |
| Fuzzing | Nine relay libFuzzer targets; one Rust cargo-fuzz target for the image check | commit `22116aa5`, `relay-uws/fuzz/`, `rust/hollow_core/fuzz/` |
| Scale probes | G1 rerun on the merged 0.13 tree | SCALE |

Attacker profiles (TM section 1) are applied with one standing rule: every peer attacker runs a
client of its own making, holds valid keys and signs correctly, so the question is always
whether the signer is allowed.

## WP1. Identity, devices, linking, revocation, destroy, duress

**Examined.** The Rust identity core (`identity/roster.rs`, `recovery.rs`, `duress.rs`, `keys.rs`,
`device_key.rs`, `platform_keystore.rs`, `node/roster_book.rs`, `node/destroy.rs`,
`node/link_handler.rs`, `node/link_pake.rs`, `node/resolver.rs`, `node/security_alerts.rs`,
`api/roster.rs`, `api/wipe.rs`, `api/identity.rs`, `api/storage.rs`); the Flutter identity UI
(roster, roster lock, link dialog, duress and security sections, unlock and app lock shell,
backup and destroy flows); the push fetch node for kill frames; stores E-10, E-11, E-13, E-14;
flows F-01 to F-07, F-11 to F-13 and the `.hollow` restore; `spake2-0.4.0` and `zip-2.4.2` in the
cargo registry; the relay's mirror of the roster fold (`relay-uws/src/roster.h`). Attackers P-01,
P-03, P-04, P-07, P-08, P-09. Leads L-04, L-05, L-06, L-10, L-11. Attack trees AT-1 (every path
to a wipe) and AT-2 (identity takeover). Sources: EF/identity, EF/identity_part2, EV/identity,
RC/identity, MATRIX identity (35 rows) and new:10-14, 21-26.

**How.** Phase B matrix walk and re-check; designs ID-1 and ID-1R with their mutation passes
(`tmp_id1_mutate.py`, `tmp_id1r_mutate.py`; ID-1R 13 of 14 rules killed, the last an equivalent
mutant, PLAN session 25); 117 roster vectors shared by Rust and the relay's C++ mirror; phase E+F
slice (71 STRIDE cells, protocol checklist RFC 9382, RFC 5869, BIP-39, RFC 8032); fleet journeys
for linking, removal and destroy (PLAN sessions 22, 25, 26).

**Found.** HOL-SEC-001 (a foreign device list wiped devices), 002 (the relay could decrypt
device-link snapshots), 005, 006, 029, 031 to 034, 059, 076, 077 (a stolen device held the
identity for good), 078 to 083, 096, 112, 113, 115, 125, 129 (link snapshot, backup or archive
wrote files anywhere), 130, 152, 153, 154, 157, 162. Residuals accepted as AR-15, AR-18, AR-19
(identity part), AR-34 (later fixed in 0.12.1). The 0.13 wave added three items (see "Phase G"):
revocations kept per (master, device), a device removed while connecting now learns it, and
removals carried inside DMs.

**Examined, no finding.**
- Matrix rows with the binding present on every transport (`V`): `LinkDeclined` and
 `LinkSnapshotAck` (identity:A-23/A-24), every path that ends in a wipe (A-34), `ProfileRelay`
 (A-44), the signed profile card store (N-04), `LinkPake`, `LinkPakeReply`, `LinkSealed`,
 `RosterNotice`, the roster statements Consent, Recovery, PhraseAdmit, Vouch, Pending,
 LegacyClaim and Removal, and `roster_book::ingest` (new:10-14, 21-26). MATRIX.
- L-06 (destroy replay) holds: a new install always runs a new device id, the first start stamps
 the link time, older orders are refused, and copies within a session are refused by the RAM
 stamp (EF/identity_part2 "Leads"; tests `destroy_refuses_signal_older_than_link_time`,
 `destroy_identity_signature_and_freshness_rules`).
- L-10 holds for unsolicited prompts: "Add this device?" appears only after a hello opened under
 the SPAKE2 keys, one handshake per code (EF/identity_part2 "Leads").
- L-11 holds for phrase-protected identities: the master key alone admits nobody
 (`the_master_key_alone_admits_nobody_once_protected`,
 `authz_a_stolen_backup_is_never_a_member_until_approved`).
- L-04: every Ed25519 check is `verify_strict` (EF/olm "L-04").
- AT-1: every path to the wipe routine, the removal lock and the duress wipe is enumerated with
 its gate; duress has no remote trigger (EF/identity summary, EF/identity_part2 "AT-1").
- C-LOCAL-08 (crash between wipe steps): no finding, the marker is the first fallible step
 (DISP).

**Not examined.** Nothing was built or run in the phase E+F slice; test names were checked to
exist, not to pass at that tree (EF/identity header). No formal model of the roster (PLAN
section 2.8 item 9 and decision 3 defer it; no record that one was built). The harness shares
one process-wide resolver, so device-to-master attribution across processes is not covered
there (CLAUDE.md "Multi-node harness").

## WP2. DMs, Olm key exchange and sessions, friend requests and accepts, blocklist

**Examined.** `crypto/olm_manager.rs`, the KeyRequest, KeyBundle and Encrypted arms of
`node/swarm.rs`, `node/crypto_handler.rs`, `node/olm_lane.rs`, `node/frame_auth.rs`,
`node/dm_room.rs`, DM fan-out in `node/message_ops.rs`, `node/fetch.rs` and `push_enrich.rs`,
the forwarder as an Olm responder, the Olm tables and RAM caches, vodozemac 0.9.0 and
ed25519-dalek 2.2.0 in the registry. Flows F-20 to F-26, the frame seal on every relay frame and
DM room membership. Attackers P-01, P-03, P-04, P-06. Leads L-02, L-04. Sources: EF/olm,
EV/dm, RC/dm, MATRIX dm (30 rows) and new:1-3.

**How.** Phase B matrix walk and re-check; design A (sealed frames, lanes, DM room names from the
masters' X25519 agreement) with `c24_*` wiretap tests on the mock relay; phase E+F slice (57
STRIDE cells, Olm, X3DH, Double Ratchet and Sesame checklists); mutation passes `tmp_s31_olm`,
`tmp_s33_olm` (19/19) and `tmp_s31_friends` (MUT).

**Found.** HOL-SEC-003 (the relay could open an Olm session as any device), 008, 013, 036 (a
stranger befriended us with an accept), 038, 039, 053 and 054 (relay-stamped sender, replays),
057, 062, 087, 089, 111, 143 (a sync responder made a signed message read as a shorter text),
144, 145, 161. AR-19 (Olm half, closed in session 33 with persisted read marks), AR-30 (fixed in
0.12.1), AR-31 accepted. The 0.13 wave fixed a friend re-add that lost to the removal it
replaced, and persisted the live-frame replay guard (AR-35 item 1).

**Examined, no finding.**
- Matrix `V` rows: one-time key publication (dm:A-DM-06), `SessionAck` (A-DM-08),
 `DirectMessage` (A-DM-13), DM `RemoveReaction` (A-DM-17), `StatusUpdate` (A-DM-22),
 `AutoDownloadPref` (A-DM-26), `frame_auth::open`, the plaintext lane drop and
 `MessageEnvelope::Carried` (new:1-3). MATRIX.
- L-02 (vodozemac non-contributory DH) holds: every non-ephemeral key input is signed and
 verified before session creation on every path (EF/olm "L-02").
- L-04 holds: every Ed25519 check is strict, and no signature bytes serve as an id, dedup key or
 replay key (EF/olm "L-04").
- The Olm half of AR-19 matches the code as described (EF/olm "AR-19").

**Not examined.** No formal model of the Olm and device-list layer (PLAN 2.8 item 9). The Olm
library itself was read for L-02 only; its audit is upstream (Least Authority, 2022, PLAN 2.9).

## WP3. Servers, CRDT authority, roles, MLS groups and subgroups, conferences, joins

**Examined.** CRDT ingest and the fold (`crdt/fold.rs`, `crdt/anchor.rs`, `admit_remote_op`,
`op_allowed`), every `CrdtPayload` variant (60 crdt matrix rows), channel content (21 rows),
server joins and MLS (26 rows); `crypto/mls_manager.rs`, `node/mls_authority.rs`, the MLS
ingress arms of `node/swarm.rs`, the committer, `node/conference.rs`, the CryptoStore actor and
OpenMLS's in-RAM state; openmls 0.9.0, tls_codec 0.5.0 and openmls_basic_credential 0.6.0 in the
registry. Flows F-30 to F-37. Attackers P-01, P-03, P-05, P-06, P-07. Leads L-03, L-08. Sources:
EV/crdt, EV/channel, EV/server_mls, RC (same areas), MATRIX, EF/mls, `audit/design_D_mls_authority.md`,
`audit/design_E_crdt_authority.md`, `audit/design_D1_door_rooms.md`.

**How.** Phase B matrix walk, re-check and rebuild; designs D, E, D1 and the join lock, each
with harness tests that failed first; phase E+F MLS slice (63 STRIDE cells, every RFC 9420 and
RFC 9750 obligation on the application); mutation passes `tmp_s32_crdt`, `tmp_s32_kick`,
`tmp_s31_kick`, `tmp_d1`, `tmp_d3` (31/31), `tmp_s32_conf`, `tmp_s33_conf` (17/17),
`tmp_s33_join` (35/35) (MUT).

**Found.** CRDT and channels: HOL-SEC-004, 009, 010, 012, 014, 015, 018 to 021, 046 to 052
(design E: a joiner took its state from whoever answered, replay past the op window, never-member
backfill), 055, 056, 088, 092 to 095, 097 to 101, 118, 119, 121. MLS: HOL-SEC-017, 041 (Critical:
an MLS seat proved nothing about its holder), 042 to 044, 084, 124, 131 (Welcomes would fail once
a leaf was 84 days old), 132 to 135, 137. Conferences: HOL-SEC-061, 072, 123, 134, 136. Door
rooms and joins: HOL-SEC-091, 092, 121, 127. Accepted: AR-10, 11, 12, 16, 17; AR-25 partly
fixed and AR-27 fixed for all-0.13 groups in 0.13 (AR rows). The 0.13
wave found and fixed: siblings could mint the same CRDT op id (silent divergence, live in 0.12.2),
the state-vector sync lost ops for good (live in 0.12.2), stand-in MLS leaders chosen by the
lowest (grindable) id, and a ring replay that kept a joiner from ever taking its MLS seat; it
also built AR-25 self-update turns and the AR-27 receiver epoch cap (see "Phase G").

**Examined, no finding.**
- Matrix `V` rows (16 crdt, 2 channel): `CrdtOp` over MLS (crdt:A-03), transport facts (0.6),
 `ServerRenamed`, `MessagePinned`, `LabelCreated`, `LabelDeleted`, `LabelAssigned`,
 `LabelUnassigned`, `ChannelGrantSet`, `MemberMuted`, `EmojiAdded`, `EmojiRemoved`,
 `StickerAdded`, `StickerRemoved`, `JoinKeySet`, `JoinLock`; `ChannelSyncRequest` serving
 history (channel:A-CH07) and pin and unpin ingest (A-CH19); `ServerCheckpoint`, `JoinSealed`,
 `MeetingSealed` (new:4, 5, 18-20). MATRIX.
- L-03 (credential validation at every RFC 9420 entry point) holds at Add by KeyPackage frame,
 Add by parked join, Add by meeting knock, adds in a received commit, Update on the commit path,
 every proposal type, external commits, the Welcome tree, the application-message sender and
 catch-up; two gaps were filed (C-MLS-01, C-MLS-03, now HOL-SEC-132, 135). EF/mls "Leads".
- L-08 holds for atomicity (the whole OpenMLS store is one snapshot in one statement, so disk
 never holds a torn group) and for allocation from peer input (`tls_codec` caps preallocation at
 4096 bytes; ratchet, catch-up and cache bounds listed). EF/mls "Leads".
- Info notes, not findings: padding 0, the MLS signer stored with the device secret, past-epoch
 senders classified by certificate, the legacy rebind (AR-35, removal in 0.14), the probe digest
 visible to the relay. EF/mls "Info".

**Not examined.** The phase E+F pass had no slice for CRDT ops, public channels or the
backfill responders: flows F-30, F-34 and F-35 appear in no `phase_ef` file (grep), and TM
section 7 still lists the STRIDE walk as "to do". Their coverage is the phase B matrix (crdt,
channel rows) and design E. In the MLS slice nothing was run; C-MLS-04 rested on OpenMLS source
until its fix; RFC section numbers were cited from memory; the push fetch's single-writer guard
was taken from a code comment; relay behaviour after a kick was taken from AR-16 and design D1,
not re-read (EF/mls "What I could not check"). No formal model.

## WP4. Relay C++, opcode gates, rings, availability cache, snapshot, auth, kill list

**Examined.** `relay-uws/src` handlers (59 relay matrix rows plus new:27-32 for `auth_hello`,
auth v2, `lock_get`, `lock_put`, `inbox_roster`, `lock_chain`, the door challenge), the restart
snapshot, rings and the offline buffer, fair-share tables, the kill list, the session layer of
resumable sessions, the relay host. Flows F-50 to F-53. Attacker P-01 against clients, and P-03
to P-05 against the relay (strangers with free identities, one or many addresses, carrier NAT,
co-members of a big server). Sources: EV/relay, RC/relay, RC/relay_partB, MATRIX relay,
EF/relay_push, RS-H, RS-B, `audit/design_ID1R_relay_rosters.md`, `audit/design_D1_door_rooms.md`.

**How.** Phase B matrix walk and re-check; a live relay test that drives the real
`ws_handler.cpp` (`test_relay_live`, both builds of the release-day switches, MATRIX "Guard
tests"); relay suites plain and under ASan and UBSan on the VPS before every deploy (the first
sanitized run caught a use-after-free in the kill-list eviction, PLAN session 18); relay mutation
passes `tmp_s32_relay`, `tmp_s33_relay` (21/21 on Linux plus 15/15 with `--mock`),
`tmp_s33_join_relay` (5/5); the resumable-sessions reviews (a hostile test first for every case;
handshake relay mutations 22 of 24 killed, client 3 of 4; bounds 19 of 19); phase H; the 0.13
fuzzing and G2 work.

**Found.** HOL-SEC-028 (Critical: one malformed frame from anyone stopped the relay), 029, 030,
031, 063 to 066, 069 to 071, 078, 091, 096, 126, 127, 128 (High: one join frame crashed the
relay), 164, 165, 170 to 172. Phase H: HOL-SEC-073 (the relay, push sender and forwarder ran as an
account with passwordless sudo), 074, 075. Accepted: AR-01, AR-06, AR-08, AR-14, AR-16, AR-18,
AR-32 (closed in 0.13), AR-36 (partly fixed in 0.13). The 0.13 wave found a raw NUL in client JSON
(Low), held bytes that could exhaust the box's memory, and closed the four 0.11 compatibility
switches (see "Phase G").

**Examined, no finding.**
- Matrix `V` rows (17): JSON `leave`, `subscribe`, push token register and unregister,
 `set_push_prefs`, `set_offline_buffer`, `get_turn_credentials`, binary 0x02, opcodes 0x00,
 0x01 and unknown ones, self-hosted license keys, the HTTP endpoints, the restart snapshot,
 client events Connected, LeftRoom and the room budget events, the door challenge and
 `DoorStatus`; plus new:27-32 (auth v2, lock get and put, `inbox_roster`, the lock chain
 reply, the auth challenge). MATRIX.
- Resumable sessions, bounds (RS-B "Attacks examined"): ring floods evict only the flooder (1.1);
 tombstones and gap accounting against a model under 60,000 random operations (1.2); frames
 larger than a ring (1.3); the `OfflineIndex` buffer address reuse with every exit path
 enumerated (3); per-IP grace slots (4.1); table-cap eviction order (4.2); IPv4 and IPv6 /48
 shares and v4-mapped addresses (4.3); snapshot v9 records, truncation and the table cap on
 restore (6.1-6.4); drain on SIGTERM (7); wrong acks (8.2); `end` in a loop (8.4); pushes during
 grace (9).
- Resumable sessions, handshake (RS-H): session ids compared in constant time and drawn from
 libsodium's CSPRNG; ownership on resume needs a current roster record; a door moved during
 grace is judged by the session's own door nonce; after a restart every locked room needs a
 fresh proof; kill signals come first; nothing about sessions is logged; client JSON only
 through `client_json::parse` and pre-auth frames only through `parse_auth_frame`.
- L-09 holds as AR-01 (EF/relay_push "Leads").
- The 0.13 fuzzing found no memory-safety or undefined-behaviour report in relay code in about
 1.36 billion executions over nine targets (commit `22116aa5`).

**Not examined.** The harness does not run the relay C++ (CLAUDE.md "Multi-node harness"); relay
logic is covered by its own suites. No penetration test of the deployed box: the phase E+F slice
did not log into production, so coturn's live `/etc/turnserver.conf` and kdump were taken from the
repo (EF/relay_push "Could not check"); `check-host.sh` is the box check (CLAUDE.md).
Uncovered C++ judge rules after the 0.13 mutation pass: the plan pricing of `lock_put` junk
proofs and of a non-member leave (survivors C6, C9), owed before the breaker's enforce
switch. uWebSockets itself was not reviewed (it is on OSS-Fuzz, PLAN 2.8 item 6).

## WP5. Updater, manifest signing, release pipeline, flatpak repo

**Examined.** `api/updater.rs`, the updater, news and status providers and widgets, the generated
update and relaunch scripts, the update host, CDN and flatpak repo, flows F-70 to F-73, the
release scripts, the installers (Inno, APK, Linux tarball and flatpak, macOS) and
`.github/workflows`. Attacker P-10 (hostile update host, CDN, flatpak repo, network path or a PR
author). Claims C-33, C-34. Source: EF/distribution (38 STRIDE cells, TUF attack list, SLSA).

**How.** One read-only phase E+F slice; fixes with tests (HOL-SEC-146, 147); feeds signed in
0.12.2 (CLAUDE.md "release feeds are signed").

**Found.** HOL-SEC-146 (links someone else chose opened with any scheme), 147 (news posts fetched
remote images; a manifest version reached file names and update scripts). Accepted: AR-21 (no
manifest expiry, no OS code-signature check), AR-22 (Android release key), AR-35 item 7 (no build
provenance; SLSA L1 provenance script added in 0.13, commit `46898ff4`, unsigned).

**Examined, no finding.** The manifest is verified with `verify_strict` against a baked-in key
before Dart sees a byte; every download is SHA-256-pinned against the signed manifest; non-https
is refused; only a strictly newer `latest` reads as an update. The committed historical manifests
verify under the current key, so they could serve a freeze but not a forgery (EF/distribution
"Summary", "Notes for the lead").

**Not examined.** The `hollow://` feed link was traced statically, not driven at runtime; no
hostile signing key was minted to drive the Windows `update.bat`; the flatpak GPG enforcement and
the Android certificate were confirmed from code and memory, not re-run (EF/distribution "Notes
for the lead"). The self-hosted relay setup wizard and its signed `relay.json` feed (commit
`41080e0d`, inside the scope commit) have no audit or hostile-review record in the sources read;
the commit message notes the first real `relay.json` publish still waits for approval.

## WP6. Push, FCM, UnifiedPush, iOS NSE, channel push

**Examined.** The push sidecar (`push-sidecar/index.js`, `unifiedpush.js`, `fcm.js`), the push
extension (Android background isolate, UnifiedPush entry, iOS `NotificationService.swift` with
`push_enrich.rs`, `node/fetch.rs`, the iOS hints cache), channel push (0x09), push prefs and
tokens on the relay. Flows F-36, F-53, F-60. Attackers P-01, P-11. Sources: EF/relay_push (79
STRIDE cells across relay and push, LINDDUN GO "relay (P-01) and push providers (P-11)"),
EV/transport, RC/transport, MATRIX transport (24 rows).

**How.** Phase B matrix walk (transport, push fetch); phase E+F slice with LINDDUN GO; the
0.12.2 sealed-wake work (AR-26 row); fleet and phone runs.

**Found.** HOL-SEC-035 (the push path ignored blocks, key changes, mentions and the wake's
sender), 059, 086, 107, 155, 156, 158, 160. AR-26 (wake payloads readable by Google and Apple)
closed in 0.12.2 by RFC 8291 sealing; AR-33 (Firebase fallback, lock-screen previews) partly
fixed in 0.12.1.

**Examined, no finding.** Matrix `V` rows: what the fetch node does not handle (device lists,
CRDT, KeyRequest, friend flows, syncs, channel edits; transport:A-T-NF), `GossipCrdtOp` over a
data channel (A-T14), frames that bypass `handle_incoming_request` (A-T21). The K3 deferral still
matches the code: Android names nobody for an unknown sender
(`authz_an_empty_wake_names_only_a_sender_we_know`). F-53 holds (push token registration);
F-50 answered (inbox rooms show owners only, D1 hides locked rooms, DM rooms are HMAC names).
AR-14, AR-16 and AR-18 unchanged by the slice. EF/relay_push "Leads".

**Not examined.** The iOS stranger-wake suppression waits for Apple's notification filtering
entitlement (requested 2026-09-27): matrix rows transport:A-T10, relay:A-22 and relay:A-24 stay
DEFERRED (MATRIX "Still open after phase B", MEMORY.md). `web-push` 3.6.7 internals were not in
the tree; iOS backup inclusion of the App Group needed a device (EF/relay_push "Could not
check"). The push parsers in `fetch.rs`, `push_enrich.rs` and the sidecar's `parseToken` are
listed as fuzz targets and were not fuzzed (EF/relay_push "Fuzz targets").

## WP7. Files, at-rest encryption, asset rail, `.hollowpack`, support credentials, link previews

**Examined.** File, vault, share, asset, preview and credential handlers in the Rust core; HFE1
content files at rest; ffmpeg as a helper; the Skia image codec; third-party fetchers (FxEmbed,
TikTok, Klipy, FFZ, IGDB proxies); the shop's Ko-fi webhook and redeem path. Flows F-80 to F-86.
Attackers P-03 to P-05, P-10, P-12. Sources: EV/files, RC/files, MATRIX files (35 rows),
EF/files (31 STRIDE cells; phase B authorisation rows cited, not redone).

**How.** Phase B matrix walk and re-check; design A item A-D2 (self-certifying file ids,
`node/file_commit.rs`); phase E+F slice; mutation passes `tmp_s31_vault`, `tmp_s31_dartfile`,
`tmp_s32_files` (MUT); the 0.13 image check with its own fuzz target.

**Found.** HOL-SEC-022 to 027, 060 (any holder could answer for a file with other bytes), 067,
085, 102 to 106, 116, 117, 122, 148 (link previews fetched loopback and LAN addresses on the
sender), 149 (ffmpeg decoded received media with no tap), 150 (location metadata in sent media),
151, 163 (iOS save let a sender's file name replace sandbox files). Accepted: AR-05, AR-06,
AR-13, AR-20, AR-23, AR-35 (share manifest, fixed in 0.13); AR-28 closed in 0.13. The 0.13
image-check track found a panic in `image-webp` 0.2.4 that reached the event loop through a
stranger's friend-request thumbnail (see "Phase G").

**Examined, no finding.**
- Matrix `V` rows: `FileRequest` serving key and bytes (files:A-F3), `FileUnavailable` (A-F4),
 `RecoveryShardReceived` (A-R5), `ShareManifestRequest` (A-S1), `ShareChunkRequest` and
 `ShareChunkResponse` (A-S4, A-S5), `EmoteAssets` (A-E2). MATRIX.
- F-86, the HOL-SEC-002 variant search: no file, share or vault key is ever sent where the relay
 can read it (EF/files "F-86").
- The embed and GIF proxy bases are user-configured, https-only with a host; showcase fetches
 are host-pinned to the Hollow CDN; vault paths sanitise server and shard ids before any join
 (EF/files "Notes / non-findings").
- The at-rest half of L-12 (E-12) holds (EF/files "Leads").

**Not examined.** Of the seven fuzz targets EF/files ranks, only the pure-Rust image check got
one in 0.13; the bundled ffmpeg parsers, Skia's codec, `hollowpack::verify_pack`, libwebp via
`webp_animation`, the `image` crate decoders behind `load_bounded`, `vault/erasure.rs::unpack_shard`
and `link_preview::parse_og_metadata` were not fuzzed (EF/files "Phase-G fuzz targets"). Skia
still decodes an image after the Rust check passes it; the check bounds what reaches Skia, it
does not replace Skia's decoder (commit `a7263f6b`).

## WP8. Local, SQLCipher, keystore, app lock, logs, deep links, clipboard, notifications

**Examined.** The Flutter UI, the Rust core at process level and the push extensions; stores
E-10 to E-14; flows F-90 to F-96 (FFI, core to storage, the loopback media server, deep links,
notifications, clipboard and screenshots, support logs, helper processes); boundaries TB-4,
TB-8, TB-9. Attacker P-09 (a device holder, a disk copy, another local process or OS user, a web
page or app handing Hollow a link), P-11 (Apple holding an OS backup). Checklist OWASP MASVS v2
L2. Leads L-07, L-12. Source: EF/local (58 STRIDE cells, 40 requirements).

**How.** One read-only phase E+F slice; fixes with tests; the 0.12.2 hardware-wrapped App Lock
(AR-24 row); App Lock and wipe journeys on the fleet and iOS.

**Found.** HOL-SEC-129 (archive and backup extraction wrote outside Hollow's folders), 155 (App
Lock showed notification content and a reply box; a link opened above the lock), 156 (a wipe left
files, log lines and the push registration), 157, 158 (iOS backups carried data and keys; the
phrase in screenshots and the clipboard), 159 (short PINs and backup passphrases), 163. AR-24
(narrowed in 0.12.2), AR-33, AR-04.

**Examined, no finding.** No authorisation decision lives only in Dart (C-LOCAL-14); helper
process arguments are not built from remote input (C-LOCAL-15); Android backup and device
transfer are off (C-LOCAL-16); no remote-triggered panic in the local parsers walked
(C-LOCAL-21); the wipe marker resumes safely (C-LOCAL-08); L-12 holds, the loopback server's four
gates are sound, with two Info residuals (C-LOCAL-12, -13). EF/local, DISP.

**Not examined.** Runtime mobile behaviour (whether the deep-link confirm paints above the mobile
lock cover, the iOS app-switcher snapshot, the App Group backup default) was read in source only;
no test was run in the slice (EF/local "What I could not check"). There is still no hardware
attempt counter for the App Lock PIN, by platform design (AR-24).

## WP9. Media, SFrame keys and nonces, forwarder lane, call signalling

**Examined.** Media signalling (`node/voice_handler.rs`, `node/call_book.rs`, the CallSignal and
VoiceChannel arms, the Dart call and voice providers), the SFrame layer (`frame_cryptor_service.dart`
over libwebrtc's FrameCryptor and key provider), the standalone and embedded media forwarder,
`screen_audio_capturer` and ffmpeg on peer media, SFrame key material in RAM, TURN. The libwebrtc
frame cryptor was read in the desktop build tree (webrtc-sdk m144, our two patches leave it
unmodified) and cross-checked against the `m144_release` head. Attackers P-01, P-05, P-06, P-10.
Leads L-01. Sources: EF/media (46 STRIDE cells, RFC 9605 checklist), EV/media, RC/media, MATRIX
media (16 rows).

**How.** Phase B matrix walk; phase E+F slice; mutation pass `tmp_s32_media` (MUT); voice and
call fleet runs (mixed iPhone and Android calls).

**Found.** HOL-SEC-016, 037, 040, 045, 058, 090, 108, 109, 110, 120, 126 (anyone could see who
used a media forwarder), 138 (a kicked member stayed in the voice call), 139 (undecryptable
frames pinned a receiver's CPU), 140 (a share passed the forwarder before encryption), 141 (the
Share lane leaked IP addresses with Always relay on), 142. Accepted: AR-03 (members can forge
each other's frames, RFC 9605 7.2), AR-14, AR-35 (1:1 camera video and gossip-forwarded audio
carry no SFrame layer, only DTLS-SRTP; SFrame there is on the 0.14 list).

**Examined, no finding.**
- L-01 (SFrame nonce uniqueness): SAFE, no fix required (EF/media "L-01").
- AR-03: the code allows less than the accepted risk says (mesh attribution is per connection,
 so forging needs a forwarding role) (EF/media "Summary").
- Matrix `V` rows: plaintext `Call*` refused (media:A-MED-02), `fwd_*` at an embedded forwarder
 (A-MED-10), client-bound forwarder answers (A-MED-11). MATRIX.
- Info observations I-1 to I-6 (no candidate): forwarder replay and header visibility, an SQLCipher
 open on the event loop, two upstream libwebrtc traps, helpers parse peer media unsandboxed, TURN
 credentials are a shared bearer token, a dead IV seed (harmless under L-01) (EF/media "Info").

**Not examined.** Nothing was built or run in the slice; the CPU cost was computed, not measured;
the mobile libwebrtc binaries (Android 144.7559.01, iOS and macOS 144.7559.09) were not
source-verified file by file; str0m's VP8 descriptor parser and the shipped ffmpeg were not
reviewed; coturn's config came from the repo (EF/media "What I could not check"). The forked
`flutter_webrtc` and our patched libwebrtc build were examined only for the frame cryptor, and
`screen_audio_capturer` was not fuzzed. The multi-node harness does not cover media or native code
(CLAUDE.md).

## Cross-cutting designs

These designs closed whole candidate classes rather than single rows. Each design file states
its rules and residuals; the plan's state of play records the sessions.

| Design | Examined | Result | Source |
|---|---|---|---|
| D, MLS leaf authority | Leaf credentials, commit and Welcome judging, fork repair | HOL-SEC-041 to 045; residual AR-27 | `audit/design_D_mls_authority.md`, PLAN session 8 |
| E, CRDT state authority | Anchors, the HLC fold, membership records | HOL-SEC-046 to 052; AR-10 to AR-12 | `audit/design_E_crdt_authority.md`, PLAN session 9 |
| A, frame authority | Every message type's lane, sealing, replay rules; five inventories (`design_A_inventory/`) | HOL-SEC-053 to 062, 072; claim C-24 reworded | `audit/design_A_frame_authority.md`, PLAN sessions 10-17 |
| Join lock | Door and change keys, answers judged against a later lock read | Relay half deployed 2026-09-29 | PLAN session 16 |
| ID-1 | The phrase as root, the roster, SPAKE2 linking | HOL-SEC-002, 076, 077; AR-02 closed, AR-15 | `audit/design_ID1_identity_authority.md`, PLAN sessions 20-22 |
| ID-1R | The relay folds rosters, owner-only inboxes | HOL-SEC-078 to 082 | `audit/design_ID1R_relay_rosters.md`, PLAN sessions 25-26 |
| D1, door-proof rooms | Server rooms visible only to door provers | HOL-SEC-091, 127; AR-16 | `audit/design_D1_door_rooms.md` |
| G, MLS turns (0.13) | Self-update cadence and the receiver epoch rule | AR-25 partly fixed, AR-27 fixed for all-0.13 groups | `audit/design_G_mls_turns.md` (archived design; code and wiki `security_write_gates` section 48 win) |
| G, standing (0.13) | A stand-in MLS authority nobody can grind | Built with review changes | `audit/design_G_standing.md` (wiki section 51) |
| G2, circuit breaker (0.13) | Per-session work budgets, shipped in shadow | Enforce switch in 0.14 | `audit/design_G2_breaker.md` (wiki section 52) |

## Phase G, the 0.13 wave (2026-10-22 to 10-24)

Each track went through a design review where needed, a hostile code review, a fix round,
mutations, the full Rust suite on the PC and a fleet run. Merged-tree results on
`c4e2f7f5`: Rust nextest 2749 of 2758 (7 keystore tests that fail over ssh, 2 load flakes
passing alone), Flutter 2767 with 0 failures, analyze 0 errors, Windows fleet 28 of 28,
every iOS phone scenario and the mixed iPhone and Android pass 10 of 10 in both roles.
`41080e0d` changes no relay C++ or relay test file. The
whole 0.13 relay was deployed on 2026-10-23.

| Track | Examined | Found | Examined, no finding or judged sound | Source |
|---|---|---|---|---|
| Relay fuzzing | `parse_auth_frame`, the binary opcode parsers (moved into `binary_frame.h`), client JSON, `ring_auth`, join-lock links, rosters, kill orders, the snapshot codec, crypto inputs: nine libFuzzer targets with ASan and UBSan | Low: client JSON with a raw NUL was judged as a different value than the client's serde reads; now refused, with regression inputs | About 1.36 billion executions, no memory-safety or UB report in relay code; the parser extraction is byte-identical to the old inline code (exhaustive test up to 9 bytes), no membership gate moved | commit `22116aa5` |
| Image check (AR-28) | Every peer image path into Flutter: rail blobs, attachments, profile stills, push avatars, server icons, guest events, overlay and showcase images, sticker import | A crafted WebP in a stranger's friend-request thumbnail panicked `image-webp` 0.2.4 during re-encoding and ended the event loop task (remote crash in 0.12.2). The new `image_check` cargo-fuzz target also hit an `image-webp` panic (`yuv.rs`), which the check now counts as a refusal | HEIC and AVIF never drawn as images (they stay file cards); 34 of 35 mutations killed, the last a double layer | commit `a7263f6b` |
| HLC lanes | CRDT op ids across sibling devices | Siblings could mint the same op id, so replicas diverged for good (live in 0.12.2) | 15 of 15 mutations, round 2 20 of 20 | commit `6b612cb0` |
| Range-digest sync | Op sync between members | The state vector lost an author's older ops for good (live in 0.12.2); receivers re-forwarded ops N x (N-1) times. Review: an unchecked digest range let a member freeze the event loop (fixed before merge) | 20 of 20 mutations | commit `98b4d842` |
| Presence digest and cap | Peer discovery every 30 s, member cap | A cost, not a security bug: one discovery round at 5k members took 30.4 s of relay CPU and 4.13 GB (now 1.02 s, 1.71 MB); servers admit at most 512 identities | Rust mutations 14 of 15 (one redundant), relay 9 of 9 | commit `70f7f10e` |
| MLS cost | Past-epoch window, whole-store saves | Review: the committer's past copy kept a staged commit's secrets (fixed before merge) | 32 of 32 mutations after the fix round | commit `f6e04a02` |
| AR-25 and AR-27 | Self-update turns, receiver epoch cap | Several review HIGHs in the design and the code (tally parsing, KeyPackage planting), fixed before merge | Voice fleet with SFrame key per epoch: zero heal or decrypt failures | commit `af7196db` |
| Switches removal | The four 0.11 relay compatibility switches | Code deleted; seven live refusal tests fail on the old relay | VPS plain and SAN green | commit `6265b545` |
| AR-32 and AR-36 | TURN reach to the relay host, the report key on disk, public stats, grace-slot takeovers, mailbox re-reads | AR-32 closed; AR-36 partly fixed | Item 7 (members only for changed rooms) judged unsafe to build: presence frames are uncounted, so the relay cannot know what reached a dying socket; kept accepted. Relay mutations 26 of 27 (one equivalent), TURN lock 18 of 18 | commit `5cd8e92f` |
| Roster leftovers | Removals carried inside DMs, push-stored removals, sibling echo hold, new-device alert | Review: a cross-identity un-revoke (a device id's revoked flag followed whichever roster saved last); fixed in `10dac6d6` | 39 of 41 mutations, fix round 17 of 18 | commits `24eeed19`, `10dac6d6` |
| Message-store pool | SQLCipher opens on the event loop | Same-millisecond seals made a receiver treat a second link card as a replay; a send to our own device took a room the sibling had left | 13 of 13, then 7 of 7 mutations | commit `5d5d9116` |
| AR-35 | Replay guard across restarts, share manifests, archive format 2, provenance | A share manifest's size was not tied to its chunk count (sparse file reported complete) | 27 of 27 mutations; residuals in the AR-35 row | commit `46898ff4` |
| Ring bucket | Ring replay against per-sender receive buckets | A busy channel's ring replay starved the owner's direct frames, so a joiner never took its MLS seat (live in 0.12.2) | 6 of 6, then 8 of 8 mutations | commit `892f0dcc` |
| Sync cost | Channel history asks and page queries | Opening a channel asked every member device; per-page cost grew with history; review: an unsolicited page kept every ask alive (fixed) | 21 of 21 mutations after the fix round | commit `e87391e0` |
| OOM send budget and G2 breaker | Bytes uWebSockets holds past backpressure; per-session work | Held frames could take several GB and an OOM kill loses the snapshot; reviews found a malformed-message crash path, a per-payer table that grew without bound and an O(members x links) stall in the new code, all fixed before merge | Honest fleet peaks small (119 frames/s, 7 joins, 36 verifies); enforced-mode fleet runs showed 0 honest trips, a flood tripped; VPS plain and SAN 46 of 46, 0 sanitizer output; relay mutations 29 of 32, survivor S7 argued sound, C6 and C9 not equivalent (tests owed) | commit `986a4d75` |
| Stand-in authority | Who leads an MLS group while the owner is away | Leaders were the lowest master id by string sort, which anyone can grind | 12 of 12 mutations; Windows fleet a, b, c pass; a PC test failure proved to be a test race | commit `eb7ed684` |
| Removed device in a room | A device removed while connecting | It never learned its removal until its next connect | 5 of 5 mutations | commit `60438a4a` |
| Friend re-add | Re-add after a removal | A re-add made shortly after a removal could be undone (wall-clock stamp older than the removal's seal) | 21 of 21 mutations; a reviewer's frame-time rule was rejected (per-copy seals, behind clocks) | commit `c4e2f7f5` |
| G1 rerun | Join, message, reconnect, leave and kick, idle, MLS and relay costs on the merged tree | One regression risk: the digest ask fell back to the full vector under load (fixed in `fbd2b957`); cap stays 512 identities | Leave and kick 34x fewer frames, reconnect sync requests 15x smaller, idle 15x less, MLS 100x faster at 1k; three timing results marked void or unexplained (SCALE 8.5) | SCALE 8.1-8.7 |
| Storage measurement | DB size per message, first sync of a new member | Channel-open asks fanned to every member device; per-page cost was quadratic; a `UNIQUE(...,text)` index drops an identical same-millisecond message with a different id (0.14) | 1.7 KB per message, first sync takes the whole history | - |

Fixed in the same commit, not a separate finding: `announce_door_change` sent presence to the device's
own fetch sockets; since `986a4d75` it skips fetch and guest sockets
(`relay-uws/src/ws_handler.cpp`, the `!d->is_fetch` check in that function).

## Exit criteria against the record

| Criterion (PLAN section 6) | State in the record |
|---|---|
| Every DFD element walked through its STRIDE cells; LINDDUN GO on relay and push | 443 cells in eight phase E+F slices; LINDDUN GO done in EF/relay_push. Flows F-30, F-34, F-35 (CRDT ops, public channels, backfill responders) had no E+F slice; TM section 7 still says "to do" |
| Every matrix row has verified code evidence and an `authz_*` test per wrong principal | 346 rows, 0 OPEN, 3 DEFERRED (K3), every row with a guard test column. Most rows are agent-verified with mechanically checked citations; the lead re-read OPEN rows and ten sampled FIXED rows (MATRIX). Per-principal completeness is not recorded per row |
| Every requirement traces to a test | Requirements exist per slice (R-IDENTITY, R-OLM, R-MLS, R-RP, R-DIST, R-FILES, R-LOCAL, R-MEDIA), written at `aa104d48` with some NOT MET at the time. There is no consolidated `requirements.md` (PLAN artifact table) and no record re-checking each R-* at the scope commit |
| Every finding fixed and retested, or accepted | Finding headers read "Fixed" or "Fixed... retest at release"; HOL-SEC-015 and 017 read "Fixed" since the close-out (their rest closed by HOL-SEC-062 and 041, as CAND and PLAN record). Retest dates per finding are not filled in |
| Every finding has a variant-analysis section | 51 of 168 finding files mention variants (grep). PLAN phase D (variant analysis as its own session) has no separate record |
| `coverage.md` lists each work package | This file |
| Tooling items 1-5 of PLAN 2.8 run in CI | 1 and 2: CI job "Supply Chain" runs cargo-deny 0.20.2, osv-scanner 2.5.1, gitleaks 8.30.1 over the whole history and zizmor 1.30.1 (`ci.yml:285-347`). 3: the harness runs in nextest. 4 (proptest state machines): no record, `proptest` is not a dependency. 5: relay fuzzing runs nightly on the Mac mini by decision, not in public CI (crash inputs stay private); the Rust envelope parsers are not fuzzed |

## Not covered and known gaps

- **No independent team and no outside audit yet.** The work was done by the owner with AI agents
 as enumerators, builders and hostile reviewers. An external audit with the support of OSTIF
 is planned.
- **No formal protocol model.** Verifpal or Tamarin on the roster, destroy orders and a
 relay-controlling attacker was deferred until the device design froze (PLAN 2.8 item 9,
 decision 3); no record that it was done.
- **No penetration test of the deployed relay box.** Host state is checked by `check-host.sh`;
 the slices read repo config, not the live box (EF/relay_push "Could not check").
- **The harness covers neither the relay C++ nor media and native code, nor device-to-master
 attribution across processes** (one process-wide resolver) (CLAUDE.md "Multi-node harness").
 The relay has its own suites; media and native code rely on fleet runs.
- **Media and native code only in part.** The forked `flutter_webrtc` and our libwebrtc build
 were read for the frame cryptor only; mobile WebRTC binaries were not verified file by file;
 `screen_audio_capturer`, ffmpeg and Skia were not fuzzed (EF/media, EF/files).
- **Rust parsers not fuzzed**, except the image check: the serde envelopes, `parse_ops_tolerant`,
 `fetch.rs` frame parsing, `hollowpack`, vault shards and the link-preview parser (PLAN 2.8
 item 5, EF/files, EF/relay_push).
- **No property-based tests** of the authorisation cores (PLAN 2.8 item 4); no record.
- **Static rules and lint ratchets** (PLAN 2.8 items 7, 8): no record in the audit; an earlier
 Semgrep pass (issue 46) and SonarQube Cloud predate it.
- **Phase E+F slices ran nothing.** Every slice was read-only; their "met with a test" verdicts
 mean the test exists, not that it passed at that tree (EF/local, EF/identity headers).
- **CRDT and channel STRIDE.** Covered by the phase B matrix and design E only (see WP3).
- **Open accepted risks.** `AR` holds the current state of every row. Among them: no
 per-message relay limits (AR-01, AR-06; the G2 breaker runs in shadow until the 0.14 enforce
 switch), member frame forgery in calls (AR-03), the first-contact and legacy residuals of the
 identity designs (AR-10 to AR-19), and the residuals of AR-25, AR-27 (mixed-version groups and
 meetings), AR-33, AR-35 and AR-36.
- **iOS stranger wakes** wait on Apple's filtering entitlement (K3).
- **0.14 list** of known compatibility paths still in 0.13: vector sync, the old discovery
 answer, the ring-1 switch, the MLS legacy rebind, SFrame on 1:1 camera and gossip audio, archive
 format 2 writes, the `revoked_devices` dual write, the hidden-sender broadcast limits and the
 breaker enforce switch.

## Timeline

| Dates | Phase | Main output |
|---|---|---|
| 2026-09-26 | Research, method, phase A | PLAN; claims, threat model, AR register; HOL-SEC-001, 002 |
| 2026-09-26 to 09-29 | Phase B evidence and class fixes | HOL-SEC-003 to 072; designs D, E, A, join lock; relay deploys |
| 2026-09-30 | Phase H | HOL-SEC-073 to 075 |
| 2026-09-30 to 10-02 | ID-1, ID-1R, first regression pass | HOL-SEC-002, 076 to 082; fleet 28 of 28, phones 9 of 9 |
| 2026-10-02 to 10-04 | Phase B re-check, rebuild, close | HOL-SEC-083 to 127; 346 matrix rows, 0 OPEN |
| 2026-10-04 | Phases E and F, merged | HOL-SEC-128 to 162; AR-21 to AR-35; DISP |
| 2026-10-05 | Final regression pass, 0.12.0 released | - |
| 2026-10-06 to 10-07 | Scanner triage; resumable-sessions reviews | HOL-SEC-163, 164, 165, 170 to 172; AR-36 |
| 2026-10-08 to 10-20 | 0.12.1 and 0.12.2 | AR-24 narrowed, AR-26 and AR-29 closed, AR-30 and AR-34 fixed, AR-33 in part |
| 2026-10-22 to 10-24 | Phase G, the 0.13 wave | 26 commits `22116aa5` to `41080e0d`; relay deployed 10-23; merged-tree suites and fleets 10-24 |
