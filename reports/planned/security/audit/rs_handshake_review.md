# Resumable sessions: hostile review of the resume handshake and session authority

Wave 2 of `reports/planned/relay-and-sync/RESUMABLE_SESSIONS_PLAN.md` (section 4: "a security
review of the resume handshake goes through the audit method before the relay deploys").
Reviewed 2026-10-07 against the merged waves 0 and 1 (commit `4dfa2b10`): the relay's
session code in `relay-uws/src/ws_handler.cpp` (`handle_auth`, `mint_session`,
`resume_session`, `enter_grace`, `end_session`, `still_owner`, the send sites, the session
controls), `auth_frame.h`, `session.h`, `session_bounds.h`, and the client's
`node/ws_client.rs` and `node/relay_session.rs`. Bounds, fairness, the snapshot codec and
the OfflineIndex were reviewed separately (review-bounds).

Attacker profiles (threat_model.md): P-03 a stranger who knows a peer id, a malicious
client with its own valid keys, P-07/P-08 a sibling or a removed device, P-01 a hostile
relay (against the client), P-02 a network observer (TLS keeps it out of every case here:
it sees sizes and timing only).

Every case has a hostile test, written before any fix and run against the unchanged code.
GREEN there is a recorded non-finding; RED is a finding. Relay tests are sections of
`relay-uws/test/test_relay_live.cpp` (the `hs_*` functions, run by `run_live.sh` in both
switch builds and under ASan/UBSan) plus `hs_restart`, run by the new `run_restart.sh`
through `fdstore_restart.py`, which plays systemd's fd store so the snapshot really leaves
one relay process and enters the next. Client tests are the `hostile_relay_*` cases in
`rust/hollow_core/src/node/ws_client_wire_tests.rs`.

## Findings

| ID | Severity | What |
|---|---|---|
| HOL-SEC-164 | High | One `active` frame made the relay build a `members` for every room the session holds (54 ms of relay CPU per frame at 10,000 rooms): a stall any client could ask for at will. Fixed: `active` answers only for rooms whose presence was withheld. |
| HOL-SEC-165 | Low | Each frame after an `hb` queued another ack deadline, so a client alternating the two grew the relay's ack queue by one entry per pair. Fixed: one pending deadline per session. |

## 1. Resuming another device's session

| Attack | Test | Verdict |
|---|---|---|
| A sibling of the same identity names the device's sid, signed with its own key | `hs_sids` "a sibling naming the device's sid ... gets a fresh session of its own" | Refused (`unknown`, fresh session of its own). Sessions are looked up by the authenticated peer id, never by sid. |
| Another identity names it | existing "another device's sid is answered exactly the same"; `hs_sids` "a stranger naming it is answered exactly like a guess" | Refused the same way |
| A guessed sid | existing "an unknown sid gets a fresh session on the same socket" | Refused |
| `unknown` tells whether the sid exists | `hs_sids` (answer keys equal for sibling, stranger and guess); reading | No oracle: the answer and the work done depend only on the caller's own session, never on someone else's |
| The attempts cost the owner its session | `hs_sids` "the device still resumes its own session", "with the frame its ring took during grace" | No effect |
| The device's peer id with another key (v3 resume, v2 full, v2 guest, each of which would end its session) | `hs_sids` "a resume claiming the device's id with another key is refused", "so is a v2 full/guest login ..." | Refused at the key binding (`derive_peer_id`) |
| sid compared in constant time | reading: `session::sid_equal` folds every byte with a volatile OR; only the length is compared first, and every sid reaching it was shape-checked to 32 characters | Holds. A mutation to `==` is not observable by a functional test (timing). |
| sid from a CSPRNG | reading: `random_hex(16)` is libsodium `randombytes_buf`, 128 bits | Holds |
| sid logged | grep of every relay log line (two in `ws_handler.cpp`, neither about sessions; the snapshot lines print counts only, no session count) and every `hollow_log!` in `ws_client.rs` / `relay_session.rs`; the relay logs of the live, restart and 90 s runs scanned for any 32-hex value: none | Never logged. Hygiene note for the client owner: `Auth rejected: {text}` logs a relay reply that does not parse, verbatim; only a broken or hostile relay sends one, so no real sid can land there today. |

## 2. Replays, grafts and shapes of the v3 frame

| Attack | Test | Verdict |
|---|---|---|
| A captured resume frame replayed on another socket | `hs_replays_and_shapes` "a resume frame replayed on another socket is refused", "and that socket is closed" | Refused: one challenge per socket, one attempt per challenge |
| Sent on a socket that never asked for a challenge | same, "so is one sent to a socket that never asked" | Refused |
| Signed for another relay's domain; two minutes old; two minutes ahead | same, "refused: signed for another relay / two minutes old / two minutes ahead" | Refused |
| v2/v3 confusion: a v3 frame signed with v2 bytes, a v2 frame signed with v3 bytes | same | Refused (the tags differ: `hollow-ws-auth2` / `hollow-ws-auth3`) |
| A v2 frame carrying `session` and `in_h` | same, "a v2 frame with session fields logs in without any session" | Plain `auth_ok`, no session read from it |
| A sid or a count the signature does not cover | same | Refused: both are signed |
| Shape rules of 9.1 and 11.2 (22 cases: `in_h` as text, negative, fractional, past 64 bits, missing; session missing, null, numeric, uppercase, 31 or 33 characters, non-hex; `"new"` or `"none"` with a count; full asking for `"none"`; fetch or guest asking for `"new"` or a sid; fetch and guest at once; version 4; version as text) | same, "refused by its shape: ..." (each frame signed over exactly what it says, so only the shape rule can refuse it) | Refused, each on its own socket |
| A second auth frame on a logged-in socket | same, "one frame, one attempt ...", "and the socket keeps its session" | Not answered, the session unchanged |
| The refused attempts disturb the session they named | same, "none of them touched the session" | No |
| Fetch and guest sockets with sessions | existing "a fetch socket gets no session", "nor does a guest"; the shape cases above | No sessions |
| The device's fetch socket sending `inactive`, `end`, `hb` | `hs_sids` "its fetch socket's heartbeat names no session", "a fetch socket's inactive mutes nothing", "and its end ends nothing" | No effect: session controls act only on a socket carrying the live session |

## 3. A device removed during grace

| Attack | Test | Verdict |
|---|---|---|
| Removal shown while the session is in grace, then a resume | existing `test_session_inbox_recheck` | Inbox gone; nothing deposited after the removal is in its ring; the owner is not told it came back |
| The same with a gapped ring (the gap replays the mailbox of every inbox the session owns) | `hs_removed_in_grace` "its gapped resume replays no mailbox of the inbox it lost" | No mailbox: the replay asks the re-checked owner flag |
| The removed device shows its own stale roster again after the resume | `hs_removed_in_grace` "its own stale roster, shown again, makes it no owner", "and not the removed device" | Refused: the shown roster is merged into the one held, which carries the removal |
| No roster record keeps ownership on resume (`still_owner`, plan 11.2) | reading; mutation "resume: no inbox re-check" survives (below) | Holds. An owner flag is set only from a shown roster (the book then holds it), every roster change that drops an owner also clears the session's flag (`drop_inbox_owners` walks `owners`, devices in grace included), and a restore brings flags and rosters back together. So "no record" arises only when the book evicted the identity's roster under its fair share; a live socket keeps ownership the same way then, and a removal shown later is folded into a fresh record and drops the device. A cleared flag never comes back through a resume. Re-showing a stale roster to a relay that holds no record is the existing AR-15 residual (the first roster after an eviction or reboot is pinned), not a session path. |
| A removal shown after a relay restart, while the restored session is in grace | `hs_restart` "the inbox the roster took away during grace is gone", "nor did the deposit after its removal" | Gone |
| DM and server rooms on resume | reading | Unchanged by design: the relay never judged those rooms by roster (C-03 holds at the contacts' clients, which stop sending to a removed device), and a resume keeps exactly what a fresh login re-joins |

## 4. Authority that changed during grace

| Attack | Test | Verdict |
|---|---|---|
| The door moved (a kick) while the session sat in grace; ring frames from that room after the change; `peer_joined` on resume | `hs_door_moved_in_grace` (needs a session grace longer than the 60 s door grace, so it runs against a relay built with a 90 s test grace: `RELAY_LIVE_ONLY=door_grace`; against `run_live.sh`'s 5 s grace it skips) | Holds: `relock_room` judges sessions in grace by their own door nonce; within the 60 s door grace the ring takes the room's frames as a live member's socket would (design D1), nothing after; the resume shows the room hidden (`proved:false`, itself alone), the provers are told nothing, the old door proves nothing |
| `reprove:true` after a restart: do unproved locked rooms deliver ring frames or presence before the re-proof? | `hs_restart` (real snapshot handover): "the session resumes and must prove its doors again", "the locked room shows it nothing until it proves", "the locked room's broadcast from before the proof never reached its ring", "the provers are not told it came back", "a proof for the session's first challenge proves nothing now", "one for the resuming socket's challenge proves" | Holds: door standing and the door nonce are never restored, so a restored session in grace is a non-prover |
| Kill signals first (9.2 order) | existing `test_session_doors_and_kills`; `hs_restart` "the waiting kill signal comes first" | Holds, after a restart too |

## 5. Make before break and supersede

| Attack | Test | Verdict |
|---|---|---|
| The old socket after `moved` keeps sending (broadcast, `msg`, direct, join, leave, `end`, `hb`) | `hs_moved_socket` | Acts on nothing: uWebSockets drops data on a socket it is closing, and the session code sees the old socket as superseded |
| A v2 full or guest login ending another device's session | `hs_sids` (another key refused) | Needs that device's key: confirmed |
| The device's own fresh login ends its session | existing `test_session_fresh_over_held` | By design (plan 11.2) |

## 6. Counts and acks from a hostile client

| Attack | Test | Verdict |
|---|---|---|
| `in_h` above what the relay sent, below what the device acked | existing `test_session_counting` | `bad_h`, a fresh session on the same socket |
| `in_h` = 2^64-1 | `hs_hostile_counts` "a count of 2^64-1 is bad_h, nothing worse" | `bad_h` (UBSan clean) |
| `ack` and `hb` with `h` negative, fractional, text, null, missing, 2^64-1, 1e30 | `hs_hostile_counts` "every heartbeat is answered, malformed or not"; existing "an ack past what the relay sent acks nothing" | Ignored, every `hb` answered |
| A client `gap` frame | `hs_hostile_counts` "a gap frame from a client counts as one" | Counts one, as section 9.3 says |
| Counter overflow (C++ and Rust) | reading; `hostile_relay_a_gap_of_2_pow_64_neither_panics_nor_wedges`; UBSan runs | None: C++ counters move one per frame in 64 bits, ring arithmetic sits behind `can_resume_from` and the tombstone invariants; the client's `Inbound` saturates, `Outbound` compares before it subtracts, `Backoff` is checked |
| One frame asking the relay for work over every room (`active`) | `hs_active_costs_what_was_withheld` | **HOL-SEC-164** (RED, fixed) |
| The ack deadline queue grown by alternating frames and `hb` | `hs_one_ack_timer` | **HOL-SEC-165** (RED, fixed) |
| A resume flood re-sending the whole ring | measurement probe (`.wave2/probe.cpp`, release build): 80 ms of relay CPU per resume of a session holding 10,000 rooms (one `members` per room, the ring after `in_h` up to 8 MiB, `peer_joined` where it had gone) | Residual for phase G, not filed: bounded by the per-address connection rate (10 new a minute per v4 address or v6 /64), the same work a fresh login with 10,000 joins causes today, but for about 3 KB of upload instead of about 600 KB. Fewer bytes per unit of relay work is what a churn circuit breaker (phase G) has to weigh; a resume could also answer `members` only for rooms whose presence changed while away (a wire decision for the lead). |

## 7. A hostile relay against the client

| Attack | Test | Verdict |
|---|---|---|
| `resumed{h}` below the relay's own ack | `hostile_relay_a_resume_below_its_own_ack_is_session_lost`; unit `resume_drops_what_h_covers_and_resends_the_rest_in_order` | `SessionLost`, fresh session |
| `resumed{h}` above what the client wrote | existing `an_h_above_what_we_wrote_is_session_lost` | `SessionLost` |
| A `gap` of 2^64-1 | `hostile_relay_a_gap_of_2_pow_64_neither_panics_nor_wedges` | No panic; the count saturates, the next resume is refused, a fresh session carries on |
| `reconnect{after_ms}` abuse | unit `drain_wait` (capped at 30 s); `hostile_relay_a_drain_hint_cannot_outwait_a_nudge` | Capped, and an app nudge resumes at once |
| Auth answers outside the handshake (`resumed`, `auth_ok` with a planted sid, `auth_failed`, a second challenge) | `hostile_relay_answers_outside_the_handshake_change_nothing` | Ignored; the next resume names the sid the handshake gave |
| A `resumed` nobody asked for, a sid of the wrong shape | unit `the_relays_answers_are_judged_by_what_was_asked` | Refused / no session |
| Ring frames replayed from before | harness `authz_a_live_frame_is_taken_once_and_only_while_fresh` (HOL-SEC-054) | Dropped: a replayed frame is byte-identical, so live-only frames fall to the nonce cache within 300 s and to staleness after it, everything else to message-id dedup. The ring gives a hostile relay no replay it lacked. |
| Forcing resends or a lost session | reading | Availability only, within C-25 (a relay may delay or drop) |

## 8. Push during grace

| Attack | Test | Verdict |
|---|---|---|
| A stranger outside the room a session in grace holds sends 0x04, JSON `direct`, 0x02 into it; a guest in the room sends 0x04 and `direct` | `hs_push_reach` "a stranger outside the room it holds, or a guest in it, wakes nothing", "and its ring took none of it" | No wake, nothing ringed |
| Grace widens who can wake a phone | reading; existing `test_session_push_in_grace` | No: a frame into a ring in grace wakes the device only where the same sender, in the room, could already have made the relay buffer and wake it as an offline device (any authenticated peer can deposit for any device id through a room that does not exist); 0x02 never wakes; 0x09 is unchanged (HOL-SEC-127's gate) |

## 8a. A fetch socket woken during grace reads that room's ring DMs (added in wave 2)

A DM for a device in grace waits only in its session ring, so the push isolate (iOS NSE,
Android fetch node) that a wake starts used to find nothing in `offline_buffer` and showed a
banner without text for the first two minutes after the app left. Now the fetch branch of
`handle_join` also writes `replay_grace_directs`: the ring's 0x06 DMs (`Kind::Direct`,
`Kind::DirectImage`) for that room, uncounted and left in the ring.

| Attack | Test | Verdict |
|---|---|---|
| Another device's fetch socket reading the ring | `hs_fetch_reads_grace_dms` "another device's fetch socket reads nothing of it" | Nothing: the ring is looked up by the joining socket's own authenticated peer id, and only while that session is in grace |
| Reading another room's frames, or kinds that are not DMs (broadcast, JSON `direct`, 0x02 chunk, a channel copy replayed into the ring) | same, "nor another room's DM", "nothing else of the ring", "nor a channel copy" | Refused |
| An inbox room without the proof the mailbox replay needs | same, "an inbox it does not prove gives nothing", "one it proves gives its DM" | Only once proved, the same gate as the mailbox |
| Counting or acking through the fetch socket | same, "(the fetch socket is told no count)", "the session still resumes at the same count", "and its ring still replays every frame the fetch socket read" | Nothing counted on either side; the resume still replays everything (receivers dedup by message id and the Olm read mark, as with today's `offline_buffer` replay to a fetch node and the full node) |
| A joined socket re-joining to re-read its own ring | reading | Costs the device's own ring (at most 8 MiB) per join, to itself; the same class as a repeated `topic_catchup` or an inbox re-join replaying the mailbox (phase G) |

## 9. Logging and parse paths

| Check | Verdict |
|---|---|
| Nothing about sessions logged (relay and client) | Holds (section 1) |
| Client JSON only through `client_json::parse` | Holds: one parse site in `.message`; `is_auth_hello` and `parse_auth_frame` parse through it too. `snapshot.cpp` parses only JSON the relay itself wrote. |
| Pre-auth frames only through `parse_auth_frame` / `is_auth_hello` | Holds |

## Mutation pass

Relay (one mutation at a time on a copy of the tree, the named live suites, the file
restored and its hash checked): 22 of 24 killed. Killed: nonce, domain, timestamp and key
binding checks; any sid resumes; any count resumes; the `"new"`-with-a-count shape rule
(first a survivor: the test's signature also failed, so it was re-signed over exactly what
each malformed frame says, and then killed); no `reprove` after a restore; the old door
nonce kept after a restore; `peer_joined` where the device is not seen; the old socket not
superseded on a transfer; the held fan-out without its audience; a direct from outside the
room; the relock not judging sessions in grace; four of the five HOL-SEC-164 rules; the
HOL-SEC-165 rule; the three rules of section 8a. The two survivors:

- "resume: no inbox re-check" (`still_owner` dropped): every path that changes the roster
  fold also clears the session's flag (`drop_inbox_owners`), so the resume's re-check is a
  second layer no path reaches today. Each layer was checked on its own: with only
  `drop_inbox_owners` leaving the flag, the inbox tests still pass (`still_owner` alone
  refuses); with both removed they fail ("without the inbox", "its gapped resume replays no
  mailbox ...", and four more).
- "HOL-SEC-164: leave keeps the room": a left room stays in the withheld set, which changes
  no frame (`active` answers only rooms the session still holds); the erase bounds the
  set's memory, which the wire cannot show.

Client (one mutation at a time, `cargo test hostile_relay`): 3 of 4 killed (a resume below
the relay's own ack taken; a nudge leaving the drain's reconnect time; a gap counted as
one). The survivor, a nudge no longer clearing `drain_at`, is equivalent: `schedule()`
already moved the drain time into `reconnect_at` when the socket dropped.

## Tripped over (other owners)

- `session_bounds::make_room` walks the whole session table on every mint once it is full
  (262,144 entries), and `grace_slot_victim` walks it on every socket opened at an
  address's cap: relay CPU per connection at scale (review-bounds).
- `grace_slot_victim` on a carrier-grade NAT address lets one user's new sockets end other
  users' sessions in grace there (availability only; they fall back to gap repair). By
  design in 11.2; worth a line in the residuals (review-bounds).
- `test_session_push_in_grace` and `hs_push_reach` bind 127.0.0.1:3001; two agents running
  the live suite at once on the shared VM make one of them skip those cases.
