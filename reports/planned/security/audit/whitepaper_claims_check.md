# Whitepaper claims vs code (0.13)

Appendix to the 0.13 security report. Close-out item of the audit plan
(`SECURITY_AUDIT_PLAN.md`, phase G close-out): `WHITEPAPER.md` security claims
re-checked against `claims.md` and against the code.

- **Scope:** local branch `security/0.13`, commit `28d188df` (tree
  relay `relay-uws/src` and client `rust/hollow_core/src`
  plus `lib/` where a claim lives in Dart.
- **Date:** 2026-10-24.
- **Method:** `WHITEPAPER.md` read whole. Every security-relevant statement, and
  every claim C-01 to C-37 of `claims.md`, was located with code search, floored
  with Grep, and checked by reading the lines cited below. The 0.13 changes named
  in the wiki rows of `security_write_gates.md` §47 to §50 and in the wave g13
  0.13 change list were each checked in code for text they make stale. No tests were
  run for this check; the evidence is the code as written at `28d188df`.
  Accepted risks are named by their `accepted_risks.md` row.
- **Verdicts:** *Holds* (the code does what the text says), *Holds with a
  residual* (true, with a known limit named by its AR row), *Stale* (the text
  describes older behaviour), *Overclaims* (the text promises more than the code
  does). Every Stale and Overclaims row was edited in `WHITEPAPER.md` to make it
  true; the column "Action" says how.

Paths below are relative to the repository root. `hc/` is
`rust/hollow_core/src/`, `relay/` is `relay-uws/src/`.

## 1. Whitepaper statements

| Section | Claim (short quote) | Verdict | Evidence | Action |
|---|---|---|---|---|
| 1.1 | "without the relay ever learning that two connections belong to the same person" | Overclaims | The relay sees which device ids join `inbox:{master}` and holds each roster (`relay/roster_book.h`); WP 3.1 and C-24 already say so | Reworded: the relay can tell which device ids belong to one person but reads nothing they send |
| 3 (intro) | "without the relay ever learning that two connections belong to the same human" | Overclaims | as above | Same rewording |
| 3.1 | "The device key drives identity only at the transport layer" | Stale (0.12) | Device key seals every relay frame (`hc/node/frame_auth.rs:175`), signs Olm key exchange (`hc/node/crypto_handler.rs:693`), is the MLS leaf signer (`hc/crypto/mls_manager.rs:632`), signs roster statements (`hc/identity/roster.rs`) | Lists what the device key signs; content, server ops and profiles stay master-keyed |
| 2.3 | "Argon2id (65536 iterations, 3 parallelism, 32-byte output)" | Stale (misdescribed) | `argon2::Params::new(65536, 3, 1, Some(32))` = 64 MiB memory, 3 iterations, 1 lane (`hc/identity/encryption.rs:109`) | Parameters corrected |
| 2.3 | Duress slot always present, both slots derived, wipe shows nothing | Holds | `hc/identity/duress.rs:88`, `:121` (dummy slot); C-07 | none |
| 2.3 | Remote destroy signed by the recovery key, judged against link time and applied stamp | Holds with a residual | `hc/node/destroy.rs:145` (`judge_own_order`); AR-18 | none |
| 2.4 | Content files at rest are per-file AES-256-GCM | Holds | `hc/node/at_rest.rs:271` (`read_all`) and the module's gates | none |
| 2.5 | Backup Argon2id with 64 MB memory | Holds | `hc/api/storage.rs:2247`, `:2311` | none |
| 2.6 | New PIN has at least six digits; on-phone pacing | Holds with a residual | `lib/src/core/services/app_lock_service.dart:10` (`kMinPinDigits = 6`); AR-24 | none |
| 3.2 | Roster fold, removals a union, master key admits nothing | Holds with a residual | `hc/identity/roster.rs:797` (`fold`), `hc/node/resolver.rs:95` (`is_bare_master`); AR-15, AR-19 (mutual removal) | none |
| 3.4 | SPAKE2 link, one guess per code, landing as one set | Holds | `hc/node/link_pake.rs:124`-`146`, `hc/api/storage.rs:2109` (`land_snapshot`), `:2589` (`refuse_while_not_ready`) | none |
| 3.5 | DM room name only its two parties can compute | Holds | `hc/node/dm_room.rs:47` | none |
| 3.6 | Removal reaches contacts through DM roster digests, 35-day re-ask, 10 s hold | Holds with a residual | `hc/node/roster_reach.rs:620` (`hold_for_stale_roster`); AR-29 residuals (no cross-contact comparison, a relay can drop blind) | none |
| 3.6 | Removed device locks and erases after three days | Holds | `lib/src/ui/shell/roster_lock.dart:58`-`83`; 0.13 adds a re-send when the removed device appears in a room (`hc/node/roster_book.rs:420`) | none |
| 3.6 | "The phrase can also turn the wait off" | Overclaims (ambiguous: reads as "admits at once") | `no_wait` means a restored backup never joins by waiting (`hc/identity/roster.rs:86`) | Says the seven-day path is turned off, so a backup joins only by approval or the phrase |
| 4.3 | Frame leaves only after its session save; stale sessions pruned after 7 days | Holds | `hc/node/crypto_handler.rs:828` (`olm_frame`), `hc/node/swarm.rs:6435` | none |
| 5.2 | Subgroup coordinator "the lowest-id online member who both still qualifies and already holds the subgroup" | Stale (0.12 owner first, 0.13 standing) | `hc/node/crypto_handler.rs:2058`-`2090` (`elect_subgroup_coordinator`) | Owner while online, otherwise chosen as in 5.3 |
| 5.2.1 | "Each leaf's credential is the bare device peer ID" | Stale (0.12, design D) | Bound credential `hl1:{device}:{master}:{master_signature}` (`hc/node/mls_authority.rs:64`), signer = device key (`hc/crypto/mls_manager.rs:632`), unbound adds refused (`hc/node/mls_authority.rs:76`) | Describes the bound leaf and that unbound leaves are ignored |
| 5.2.1 | Linked sibling "inherits the source device's MLS signing material ... clears and regenerates"; legacy leaf "never re-keyed" | Stale (0.12) | Backup carries no MLS identity and landing scrubs device secrets (`hc/api/storage.rs:2109`); a pre-0.12 leaf is rebound to the device key (`hc/crypto/mls_manager.rs:1509`) | Rewritten to the 0.12 behaviour |
| 5.3 | "the online member with the lexicographically lowest peer ID ... acts as coordinator" | Stale (0.13) | Owner first (`hc/node/crypto_handler.rs:1825`), standing where every leaf runs 0.13 (`hc/node/standing.rs:91`, `:158`), old rule in mixed groups (`:149`) | Owner, then standing (role, membership position, id), lowest id only in mixed groups |
| 5.3.1 | KeyPackage to "lowest online peer, excluding self" | Stale | as 5.3 | Refers to 5.3 |
| 5.4 | Three past epochs, 512 skipped keys | Holds | `hc/crypto/mls_manager.rs:22`-`30`, `hc/crypto/mls_past.rs:21` | none |
| 5.4 | "Members do not yet refresh their own leaf keys ... Scheduled self-updates are planned" | Stale (0.13, AR-25) | Turns handed by the committer, path-only commit judged and broadcast by it (`hc/node/mls_turns.rs:382`-`497`, `:290`); at most once a day per leaf, at most 48 a day per group, fewer above 512 leaves (`:67`-`79`); only an on-screen device takes a turn (`our_turn`, wiki §48); meetings skipped (`:410`); a pre-0.13 leaf never answers a turn | Rewritten to exactly this, with the residual (rarely online device, 0.12.2 device, large server) |
| 5.6 | Every relay frame signed by the sending device, fixed lanes | Holds | `hc/node/frame_auth.rs:175`, `:211`; `hc/node/types.rs:4488` (`lane`) | none |
| 6.3 | DM camera video and gossip audio have no SFrame layer | Holds with a residual | AR-35 (0.14: SFrame on both) | none |
| 6.4 | "The TURN server sees only SFrame ciphertext" | Overclaims | 6.3's two paths are DTLS-SRTP only | Says ciphertext, SFrame inside DTLS-SRTP or DTLS-SRTP alone on those paths |
| 6.4 | Screen shares stream only on a watch request | Holds | `hc/node/voice_handler.rs:524`; `lib/src/core/providers/voice_channel_provider.dart:359` | none |
| 9.7 | MLS coordinator "(lowest peer ID)" | Stale | as 5.3 | Refers to 5.3 |
| 10.1 | HLC `actor` = "peer ID"; "Monotonically increasing per actor" | Stale (0.13 lanes) | Actor = author's master (`hc/crdt/operations.rs:123`); per-device counter lanes (`hc/crdt/hlc.rs:45`-`55`, `:173`-`179`) | Actor is the master; monotonic per device, siblings mint in their own lanes |
| 10.1, 10.6, 23.1 | Drift bound 5 minutes | Holds | `hc/crdt/hlc.rs:18`, `:138` | none |
| 10.2, 10.6 | Ops signed, author bound to key, unsigned refused | Holds | `hc/crdt/operations.rs:98`-`130`; `hc/crdt/fold.rs:172` (`ingest_remote`); `hc/crdt/server_state.rs:1806` (`op_allowed`) | none |
| 10.5 | "Each sends a state vector" | Stale (0.13 range digest) | `hc/crdt/digest.rs:1`-`29`, `hc/node/op_sync.rs:1`-`11` (vector only for older builds) | Steps 1 and 2 describe the salted range digest; the vector for pre-0.13 peers |
| 10.5 | Server delete honoured only from the owner | Holds | `hc/crdt/server_state.rs:1931` | none |
| 11.5 | "the `author` field is verified against the actual sender's peer ID" | Stale (contradicts 10.2) | `hc/crdt/operations.rs:112`-`130` | Author must match the signing key, never the relayer |
| 11.5 | Every serving path asks the channel ladder | Holds | `hc/node/crypto_handler.rs:1696` (`channel_readable_by`) | none |
| 11.6 | Voice channels never public | Holds | `hc/crdt/server_state.rs:227` (`effective_public`) | none |
| 11.7 | Receivers enforce mutes, posting and media-only on live traffic | Holds with a residual | `hc/node/message_ops.rs:2735`, `:1722`; AR-19 (slow mode by signed time) | none |
| 12.1 | Relay has "no knowledge of ... application state" | Overclaims | Relay holds rosters, join locks, kill orders, push registrations, nickname claims (12.7) | Says the only application state it holds is what 12.7 lists |
| 12.2 | v1 auth payload `hollow-ws-auth:{peer_id}:{ts}`, ±60 s | Stale (0.12; v1 code deleted in 0.13) | `relay/auth_frame.h:18`-`27`, `:160`-`180`; nonce and domain check `relay/ws_handler.cpp:513`-`600`; client `hc/node/ws_client.rs:2547` | Rewritten: `auth_hello`, nonce, signed v2/v3 payload, peer id derived from key, no timestamp judgment, v1 refused |
| 12.3 | DM room = "deterministic hash of both peer IDs" | Stale (0.12) | `hc/node/dm_room.rs:47` | Keyed hash only the two parties compute |
| 12.3 | 10,000 rooms per peer, 64 MB binary, 1 MB text | Holds | `relay/ws_handler.cpp:32`, `:4298`, `:4397` | none |
| 12.5 | "No application-level rate limiting" | Stale (0.13 breaker, shadow) | `relay/breaker.h:16`-`34` (shadow by default, 1013 close plus resume when enforced) | Adds the shadow-mode circuit breaker, which drops nothing |
| 12.5 | "nothing is counted or recorded" | Overclaims (0.13) | The breaker counts work units (`relay/breaker.h`) | "no volume is counted or recorded" |
| 12.5 | Eviction "of whichever sender currently occupies the most slots" | Stale (0.12, HOL-SEC-070) | Heaviest hashed address share (`relay/ws_handler.cpp:2218`-`2222`) | Address share |
| 12.5 | "Hard backpressure: 64 MB per connection" | Stale (0.13 send budget) | `relay/send_budget.h:15`-`60`, `:93`-`103`; `relay/ws_handler.cpp:4249`-`4265` | Adds the whole-relay budget charged to the non-reading socket's share and the two-minute stall close |
| 12.6 | TURN credentials only over the authenticated WebSocket | Holds | `relay/http_handlers.cpp:37`-`43` | none |
| 12.6 | "The only traffic the TURN server can carry is Hollow client to Hollow client" | Overclaims before 0.13 (AR-32); true with the port lock | `relay-uws/deploy/turn-port-lock.sh:1`-`30`, `hollow-turn-port-lock.service` | Adds a "Port lock" bullet; the sentence now depends on it and names the forwarder |
| 12.7 | What the relay sees (table) | Overclaims (omission) | Join lock chains (`relay/join_lock.h:14`-`19`, `relay/door_room.h`), nickname claims (`relay/ws_handler.cpp:2658`) were missing | Two rows added |
| 12.9 | Stats fields; no opt-out | Stale (0.13) | `relay/server_stats.h:11`-`37`, `relay/config.h:32`, `:91`; client hides the count when absent (`lib/src/ui/settings/network_section.dart:268`) | Lists the counters and `PUBLIC_STATS=off` |
| 12.10 | `/register`, `/unregister`, `/bootstrap` endpoints | Stale (removed before 0.12) | `relay/http_handlers.cpp:21`-`33` | Says they are removed |
| 12.12 | Nickname claim within five minutes; resolver refuses older than eleven | Holds | `relay/ws_handler.cpp:2658`; `hc/node/nick_claim.rs:16` | none |
| 12.13 | "A global byte budget ... with oldest-first eviction" | Stale (0.12) | `relay/state.h:104`-`107` | Heaviest address share loses its oldest frame |
| 12.13 | Join ring holds "what the relay already routed in plaintext"; "anyone holding the room's invite can read the ring"; Twitch proof "stripped from the parked copy" | Stale (0.12 join lock) | Request sealed to door and invite key (`hc/node/join_lane.rs:1`-`11`, `:103`-`118`), resolution sealed (`hc/node/sync_handler.rs:1667`-`1700`), parked copy keeps `twitch_proof_json` (`hc/node/join_lane.rs:108`) | Rewritten: sealed copies, readers are current join-key holders, a follow credential may ride |
| 12.13 | Member cap applied at admission | Holds | `hc/node/member_cap.rs:12`, `:21` (512 identities, admission only, advisory per wiki §47) | none |
| 12.14 | Report key "in its own owner-only file" | Stale (0.13, AR-32) | `relay/reports.h:30`-`64`, `relay/reports.cpp:76`-`120` | Key in memory only, handed over in memory, new after a reboot |
| 12.15 | Grace 120 s (30 to 600), 8 MiB and 4,096 frames | Holds | `relay/session.h:29`-`35` | none |
| 12.15 | "A session in grace keeps its connection slot" | Stale (0.13, AR-36) | `relay/session_bounds.h:237`-`265`, `relay/state.h:41` | Adds the half-grace takeover rule, three a minute per address |
| 13.1 | Wake block sealed to the device | Holds with a residual | `hc/crypto/push_seal.rs:373`; `push-sidecar/fcm.js:4`-`7`; AR-26 residuals | none |
| 13.2 | Offline DM buffer 100 messages, 1 image, 24 h | Holds | `relay/state.h:55`-`60` | none |
| 15.1 | Signing v2/v3, album shape-checked | Holds | `hc/node/crypto_handler.rs:374` (`sign_message_versioned`) | none |
| 12.14, 23.1 | Blocks enforced at ingest, master-keyed | Holds with a residual | `hc/node/blocklist.rs:41`; AR-31 | none |
| 16.3 | Archive format 2 domain tag | Holds (clarified) | `hc/archive/loader.rs:347`; exports stay format 1 (`hc/archive/types.rs:5`); AR-35 | Adds "0.13 opens both formats and still writes format 1" |
| 22 | Relay auth "timestamp-bound, ±60s" | Stale | as 12.2 | Row says domain and one-use nonce |
| 23.1 | Link previews make no recipient request | Holds | `hc/node/link_preview.rs:5` | none |
| 23.1 | Resource exhaustion "64 MB hard backpressure" | Stale | as 12.5 | Names the per-connection and whole-relay budget |
| 23.1 | Privilege escalation "verified against the actual sender" | Stale | as 11.5 | Author bound to the signing key |
| 23.1 | Stolen device: "A backup file restored elsewhere waits until one of your devices approves it" | Overclaims | Seven quiet days admit it unless `no_wait` (3.6, AR-15) | Adds the seven-day path and its switch |
| 23.4 | Signed manifest, no downgrade, signed feeds | Holds with a residual | `hc/api/updater.rs:96`, `:171`, `:208`; `lib/src/core/providers/updater_provider.dart:177`-`190`; AR-21, AR-22 | none |
| 23.4 | Flatpak repository GPG-signed | Holds (not re-run) | `scripts/publish_flatpak_repo.sh:10` | none |
| 24 | "MLS post-compromise recovery ... Periodic self-update commits are planned" | Stale (0.13) | as 5.4 | States what 0.13 gives and its limits |

## 2. claims.md promises

| Claim | Short quote | Verdict | Evidence | Action |
|---|---|---|---|---|
| C-01 | Only a current device or the phrase changes my devices | Holds with a residual | `hc/identity/roster.rs:797`; `hc/node/resolver.rs:95`; AR-15, AR-19, AR-34 | none |
| C-02 | Nothing another identity sends can wipe my devices | Holds with a residual | `hc/node/destroy.rs:145`; relay courier `relay/kill_order.h`; AR-18 | none |
| C-03 | A removed device stops getting anything, locks, erases in three days | Holds with a residual | `hc/node/roster_reach.rs:620`; `hc/node/roster_book.rs:420` (0.13: told on arrival); `lib/src/ui/shell/roster_lock.dart:58`; AR-29 | none |
| C-04 | A replayed roster never brings back a removed device | Holds with a residual | `hc/identity/roster.rs:797` (union of removals); AR-15 | none |
| C-05 | Linking hands the identity only to the confirmed device; one relay guess | Holds | `hc/node/link_pake.rs:124`-`146`; `hc/api/storage.rs:2109` | none |
| C-06 | A copied identity file is useless without machine or password | Holds | `hc/identity/encryption.rs:109`; "no protection" mode excluded by design | WP 2.3 parameters corrected |
| C-07 | Duress destroys, shows nothing, costs the same | Holds | `hc/identity/duress.rs:88`, `:121`; both slots derived (CLAUDE.md, wiki §13) | none |
| C-08 | Only the two people read a DM | Holds with a residual | `hc/node/crypto_handler.rs:828`; `hc/node/dm_room.rs:47`; AR-04 (traffic analysis) | none |
| C-09 | A shown message was signed by that master over exactly what is shown | Holds | `hc/node/crypto_handler.rs:374`; `hc/node/message_ops.rs:1722` | none |
| C-10 | The relay cannot insert itself into a key exchange | Holds with a residual | `hc/node/crypto_handler.rs:687`, `:693`; AR-04 (TOFU) | none |
| C-11 | Safety numbers verify the person; new-device warning | Holds | `hc/crypto/safety_number.rs:80` | none |
| C-12 | Friend accept only answers a request I sent | Holds | `FriendAccept` arm `hc/node/swarm.rs:13218`, lands only on our pending outgoing row of that request or newer (`:13375`); 0.13 removal stamps `hc/node/social.rs:204` (wiki §50) | none |
| C-13 | Blocked identity dropped before store or notify | Holds with a residual | `hc/node/blocklist.rs:41`; AR-31 | none |
| C-14 | Removed or banned member cannot read later content | Holds with a residual | Removal commit judged and merged (`hc/node/mls_authority.rs:70`); AR-16 (room visibility for 60 s, not content); AR-25 narrowed by 0.13 self-updates | none |
| C-15 | Only role holders change server state; false author rejected | Holds with a residual | `hc/crdt/operations.rs:98`-`130`; `hc/crdt/fold.rs:172`; `hc/crdt/server_state.rs:1806`; AR-10, AR-11, AR-12 | WP 11.5 and 23.1 reworded |
| C-16 | Only the owner deletes a server | Holds | `hc/crdt/server_state.rs:1931` | none |
| C-17 | Nobody posts, edits or reacts as someone else; mutes enforced by receivers | Holds with a residual | `hc/node/message_ops.rs:2735`, `:1722`; AR-19 (slow mode) | none |
| C-18 | Restricted channel content reaches only those allowed | Holds | `hc/node/crypto_handler.rs:1696`; subgroups (WP 5.2) | none |
| C-19 | Nobody adds to a group without the admission rules | Holds with a residual | `hc/node/mls_authority.rs:40`, `:70`-`106`; AR-15 (meetings), AR-35 (legacy rebind until 0.14) | WP 5.2.1 now describes the bound leaf |
| C-20 | Public channel messages signed and unforgeable | Holds with a residual | `hc/crdt/server_state.rs:227`; `hc/node/crypto_handler.rs:374`; AR-17 (guest previews) | none |
| C-21 | Media readable only by participants | Holds with a residual | `hc/crypto/mls_manager.rs:2139` (`export_secret`); WP 6.3; AR-35 (two DTLS-only paths), AR-03 | WP 6.4 TURN sentence corrected |
| C-22 | My screen share streams only to people who asked | Holds | `hc/node/voice_handler.rs:524`; `lib/src/core/providers/voice_channel_provider.dart:359` | none |
| C-23 | Withdrawn | n/a | AR-03 | none |
| C-24 | A malicious relay sees routing metadata only | Holds with a residual | `hc/node/types.rs:4488` (`lane`); `hc/node/frame_auth.rs:175`, `:211`; `hc/node/join_lane.rs:1`-`11`; AR-04 | WP 1.1, 3, 12.1, 12.7, 12.13 reworded |
| C-25 | A malicious relay can delay or drop, never forge | Holds with a residual | Signatures on every listed object (frame seals, CRDT ops, rosters, accepts, kill orders); AR-29 (withholding) | WP 12.2 updated |
| C-26 | Push providers never receive content; wake block sealed | Holds with a residual | `hc/crypto/push_seal.rs:373`; `push-sidecar/fcm.js:4`-`7`; AR-26 residuals | none |
| C-27 | Reading a link preview makes no request to the site | Holds | `hc/node/link_preview.rs:5` | none |
| C-28 | An invite link never reveals the server id to the website | Holds | `lib/src/ui/chat/hollow_link_utils.dart:14` (fragment link) | none |
| C-29 | Nothing a peer sends writes outside Hollow's folders | Holds | `hc/node/share_handler.rs:304` (`safe_file_name`); `hc/api/storage.rs:2109` | none |
| C-30 | Files E2EE in transit and unreadable at rest without the identity | Holds | `hc/node/at_rest.rs:271`; `hc/node/file_commit.rs:43`, `:161` | none |
| C-31 | An asset shown for a hash is exactly those bytes; unsolicited dropped | Holds with a residual | `hc/node/assets.rs:5`; AR-05; 0.13 pure-Rust pre-check before Skia (`hc/node/image_gate.rs:1`-`6`) closes AR-28's decoder exposure | none |
| C-32 | Support and Twitch credentials issued by the pinned root, not transferable | Holds with a residual | `hc/node/support_creds.rs:642`; AR-23 | none |
| C-33 | Only signed updates, no downgrade | Holds with a residual | `hc/api/updater.rs:171`; `lib/src/core/providers/updater_provider.dart:182`; AR-21, AR-22 | none |
| C-34 | Flatpak accepts only bundles signed by Hollow's key | Holds (not re-run) | `scripts/publish_flatpak_repo.sh:10` | none |
| C-35 | App Lock hides content and notifications until unlock | Holds with a residual | `lib/src/core/providers/system_notification_provider.dart:480`, `:492`; AR-33 | none |
| C-36 | Argon2id per PIN guess, six-digit minimum | Holds with a residual | `lib/src/core/services/app_lock_service.dart:10`; `hc/identity/encryption.rs:109`; AR-24 | none |
| C-37 | Logs never hold content, keys, codes or passphrases | Holds | `hc/lib.rs:154`-`175` (redaction); relay log filter checked in the regression pass | none |

## 3. Counts

- Whitepaper statements: 70 rows. Holds 25, Holds with a residual 9,
  Stale 27, Overclaims 9. All 36 Stale and Overclaims rows were edited (30
  edits, some covering several rows).
- claims.md: 37 rows. Holds 15, Holds with a residual 21, withdrawn 1. None
  Stale or Overclaimed at `28d188df`.

## 4. Edits made to WHITEPAPER.md

1. 1.1 Design goals, multi-device bullet: the relay can tell which device ids belong to one person.
2. 3 intro: same.
3. 3.1: what the device key signs since 0.12.
4. 2.3: Argon2id parameters (64 MiB, 3 iterations, 1 lane).
5. 5.2: subgroup coordinator is the owner, else chosen as in 5.3.
6. 5.2.1: bound leaf credential; linked devices get no MLS signing material; pre-0.12 leaves rebind.
7. 5.3: coordinator by owner, then standing, lowest id only in mixed groups.
8. 5.3.1: coordinator reference.
9. 5.4: self-update turns since 0.13 and what they leave.
10. 9.7: MLS coordinator reference.
11. 10.1: HLC actor is the master; per-device lanes.
12. 10.5: range digest, vector only for pre-0.13 peers.
13. 11.5: CRDT author bound to the signing key.
14. 12.1: the relay's application state is what 12.7 lists.
15. 12.2: v2/v3 challenge login; v1 refused.
16. 12.3: DM room is a keyed hash only the parties compute.
17. 12.5: shadow circuit breaker; "no volume is counted"; eviction by address share; send budget.
18. 12.6: port lock bullet; the "only traffic" sentence tied to it.
19. 12.7: rows for join locks and nickname claims.
20. 12.9: counters listed; `PUBLIC_STATS=off`.
21. 12.10: HTTP discovery endpoints removed.
22. 12.13: global budget evicts by address share; join ring copies sealed, follow credential may ride.
23. 12.14: report key in memory only.
24. 12.15: grace slot takeover rule.
25. 6.4: TURN sees only ciphertext, SFrame or DTLS-SRTP alone on the 6.3 paths.
26. 3.6: the phrase turns the seven-day path off (no ambiguity).
27. 16.3: 0.13 reads both archive formats, writes format 1.
28. 22: relay auth row.
29. 23.1: resource exhaustion, privilege escalation, stolen device rows.
30. 24: MLS post-compromise bullet.
31. 5.4: receiver epoch-rate rule (AR-27), added by the lead after this check.
32. 7.3: image check before display; HEIC and AVIF stay file cards (AR-28), added by the lead after this check.

## 5. Mismatches not fixed

1. **Version header.** Line 3 still reads `Version 0.12.2` while the text now
   describes 0.13. Left for the release step, as asked.
2. **AR-27, the receiver epoch-rate rule, is not described.** No text was
   stale, so nothing was added. 5.4 could gain one sentence: receivers refuse a
   commit past 3 counted commits per identity in 12 epochs where every device
   runs 0.13 (`hc/crypto/mls_rate.rs:183`, wiki §48). Lead's call.
3. **AR-28, the pure-Rust image pre-check, is not described.** No stale text. A
   sentence in 7.3 or 10.7 would state it (`hc/node/image_gate.rs`). Receivers
   now refuse formats the check cannot decode (HEIC and AVIF among them); 7.3
   says images become WebP on send, but whether every send path and quality tier
   converts HEIC was not verified here.
4. **Designs D and E are under-described, not over-described.** 5 never says
   commits are staged and judged before merge (only 5.3.3 hints at it), and 10.5
   says a joiner "adopts the snapshot" without saying a member's snapshot keeps
   only the owner's role (HOL-SEC-093) or that state folds from a provable
   anchor. 1.1 still says server state has "no authoritative source", while
   design E fixes the owner. These under-claim; a fuller rewrite of 10 is a
   documentation task, not a correction.
5. **Accepted-risk and claims files lag 0.13.** `accepted_risks.md` AR-25,
   AR-27 and AR-28 still read "Accepted until 0.12.x"; claims.md "What we do not
   promise" still says leaf keys are not refreshed on a schedule (AR-25). Both
   files are outside this task's scope; they need the close-out update.
6. **Other id-ordered elections stay grindable.** 9.7 (vault coordinator,
   2nd-lowest id) and 9.8 (recovery pool, lowest id) describe the code as it is;
   the 0.13 design review lists `vault/placement.rs` and `door_room::first_to_answer` as
   out of the standing change. The text is true; whether to promise more is a
   design decision.
7. **The circuit breaker is in shadow mode.** 12.5 now says so. When enforcement
   is switched on (0.14 at the latest), 12.5 and 23.1 need the enforced
   behaviour.
8. **TURN port lock depends on the deployment.** 12.6 says the official relay
   runs it and the setup wizard installs it. A hand-built or Docker relay whose
   lock failed at boot stays unlocked until `check-host.sh` or the next start
   (AR-32 residual); the text does not promise more than that, but a self-hoster
   might read it as automatic.
9. **AR-35 replay guard, presence digest, member cap, per-(master, device)
   revocation, friend re-add stamps.** Checked; none of them makes existing text
   false, and none is described in detail. No edit.
