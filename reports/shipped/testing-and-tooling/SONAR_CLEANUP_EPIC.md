# Sonar Cleanup Epic — Close-Out

**Status: CLOSED 2026-07-15.** SonarQube Cloud CI went live (see memory `reference_sonarqube_cloud`),
the first pass fixed all 19 bugs and wired honest coverage, and five follow-up sessions worked the
deferred backlog to completion. This document replaces the untracked `tmp_nextSession.txt` scratch
file as the durable record.

**DONE criteria (met):** quality gate green on new code permanently; overall complexity findings
trending down every session; duplication < ~5% real (after parity/test exclusions); coverage number
honest and stable.

**Numbers (epic start → last confirmed):** Reliability issues 111 → 0 · code smells 680+ → 625
(pre-item-5/7 push; the ~47 item-5 S3776 + item-7 findings drop after the next analysis) ·
duplication 7.1% → 5.4% · coverage 88.2% (Codecov-parity, scoped to the unit-verifiable Rust core) ·
gate GREEN on dev + main.

---

## Item summary

| # | Item | Outcome |
|---|------|---------|
| 1 | `storage/messages.rs` dedup (27.7%) | DONE 07-14. 5353→4682 lines, dup →5.7%. Gate-trip lesson recorded in `feedback_sonar_cpd_dedup_technique`. |
| 2 | `sync_handler.rs` dedup+complexity (33.7%, 13×S3776) | DONE 07-14. 3388→~2740 lines, dup →3.3%. `author_broadcast_op` driver replaced 19 twin handlers; `ServerState::op_allowed` killed the ingest twin-drift. |
| 3 | Chat panes (channel/DM/mobile) | DONE 07-15. All 31 findings across 3 surfaces; `chat_pane_shared.dart` created and adopted by all panes + mobile. Sonar-confirmed 0 open issues on the panes. |
| 4 | Archive viewers (4 near-copies) | DONE 07-14. Shared core in `ui/archive/shared/`; 6200→2613 lines; 3 latent bugs found+fixed in spot-check. |
| 5 | Services mid-tier (8 files, 47×S3776) | DONE 07-15 via 8 parallel agents. Includes the VC dead-mic root-cause hunt (NOT a refactor regression — see `feedback_vc_join_double_announce_race`). |
| 6 | Architectural accepts (3 dispatchers) | DONE 07-14, Vitalik accepted in Sonar UI. Accepts are PER-BRANCH — re-check main after the next dev→main merge. |
| 7 | `user_settings_dialog.dart` split | DONE 07-15 (below). Long-tail leftovers stay opportunistic (below). |
| 7b | S7112 const constructors (all 111 Reliability) | DONE 07-14. `prefer_const_constructors` enabled + `dart fix`. |
| 8 | Flaky revocation harness test | DONE 07-15 (below). |
| 9 | CI polish (concurrency group) | DONE 07-14. |

## Session 2026-07-15 #3 (closing session)

### Latent-bug sweep — all 11 agent-flagged bugs fixed
All pre-existing, flagged by the item-5 refactor agents:

- **share_handler.rs** — manifest-timeout removal now sends `LeaveRoom` (socket no longer stays
  subscribed to dead share rooms); seed budget no longer burns ~256 KiB/chunk on skipped or
  relay-only chunks (skip hoisted above the charge — also kills a wasted disk-read+encrypt per
  chunk — and read/stage failures refund); `finalize_completed_download` derives the hidden flag
  from the persisted share row's `server_id` instead of defaulting `false` (a hidden channel file
  can no longer surface + auto-seed via the registry-miss race).
- **message_ops.rs / swarm.rs** — subgroup bootstrap now also requested on edit/delete/reaction
  sends (edit-only clients no longer stay on Olm fallback forever); **moderation gates added to
  edit and add-reaction** on send AND live ingest, both MLS and Olm-fallback paths (policy below);
  `handle_envelope_channel_message` logs store-open-failure drops instead of vanishing them.
- **Slow-mode gates off the event loop** — the three sync SQLCipher opens (message_ops send gate,
  file_handler file-send gate, live-ingest window check) now run via a shared
  `latest_own_channel_ts_blocking()` `spawn_blocking` helper; gate order and Mod+ short-circuit
  unchanged.
- **file_handler.rs vault** — a transient `load_manifest` failure re-registers the pending vault
  download (retryable); a genuinely absent manifest emits `VaultDownloadFailed` so the UI unblocks.
- **Dart services** — the two fire-and-forget ICE-candidate FFI calls got `.catchError((_) {})`;
  `dismissPeerNotification` now filters by `_dmGroupKey` (any live channel notification used to
  keep the empty DM bundle header stuck in the Android tray); DM `setSframeKey` switched to
  `rotateKey(0, key)` (VC-service parity, updates live cryptor indices).

**Moderation policy decision (edit/delete/reaction):** mute blocks **edit** and **add-reaction**;
**delete** and **remove-reaction** are never blocked (removing your own content is always allowed);
slow mode and media-only apply only to new messages. Enforced send-side + live ingest, never sync
backfill — same doctrine as the trio (`project_moderation_trio`).

### Item 8 — revocation test deflaked
`device_revocation_cuts_off_and_ghost_fanout_holds` had two real races: a flat 5s Olm settle that
proceeded with handshakes still unconfirmed (→ the CI "invalid MAC"), and no wait for friend A to
ingest the revocation tombstone before the after-revoke DM (→ the :1866 flake). Both replaced with
poll-until-deadline (20–30s ceilings, early-exit; still ~8s in practice), plus a new
`revoked_devices()` inspector. No assert weakened. 5/5 isolation passes + 1 under concurrent load.

### Item 7 — user_settings_dialog.dart split
6,406 lines → 19 files: slim dialog shell in `ui/dialogs/user_settings_dialog.dart` (738 lines,
keeps cross-tab state ownership), 12 per-category sections in `ui/settings/`, and shared modules
where the 15.7% dup actually died — most of it was cross-file twins with `mobile_settings_tab.dart`
(incl. a 257-line verify-proof run): `settings_shared.dart`, `verify_proof_section.dart`,
`device_management_shared.dart`, `blocked_users_shared.dart`, `about_shared.dart`,
`components/selector_pill.dart`. Mobile settings net −990 lines by adopting them. All 10 file
findings addressed (7×S3776, 2×S3358, 1×S1128) + mobile's twin S3776s resolved as a bonus.
CPD self-audit: zero ≥100-token runs in new files. One deliberate micro-unification: desktop
proof-import now uses the mobile-style tolerant `withData: true` file pick.

### Verification (combined tree)
`cargo test --lib` **410/410** (full harness, incl. the deflaked test under load) · clippy: no new
warnings on changed files · `flutter analyze` **106 vs 107 baseline** (zero new; one pre-existing
issue lived in deleted duplicate code) · `flutter test test/` **117/117**.

---

## Still pending (carried out of the epic)

**Device re-tests for Vitalik:**
1. **VC mic-at-join re-test — BOTH apps rebuilt (Windows AND Pixel APK; one unfixed side still
   glares):** join VC → mic works immediately, no "wrong state: stable" in crash logs, desktop log
   shows exactly ONE "Creating offer"/"Received SDP offer" per peer pair
   (`feedback_vc_join_double_announce_race`).
2. Item-3 mobile spot-check (one phone pass): DM + channel open/send/reply/edit/delete/reactions/
   long-press sheet/download/pin/search/mention + emote autocomplete/voice message/staged
   file+link/slow mode/typing bar/date separators/unread pill/header/media-only + no-post
   banners/visibility eviction pop. Also desktop panes' typing bar (typingMastersFor move).
3. **Settings dialog click-through** (new after the split): every category renders, profile edit
   state survives tab switches, relay Apply & Restart, verify-proof import, device
   rename/remove/reset, blocked users, licenses page. Plus mobile settings tab (adopted shared
   modules).
4. Moderation quick check: muted member can't edit or react (toast), can still delete.

**Sonar after the next push:** expect ~47 item-5 S3776 + the 10 item-7 findings gone
(Maintainability 625 → ~570); watch the new-code duplication gate (< 3%) — all sessions
self-audited with the CPD technique, but confirm via `api/duplications/show` on changed files.

**Follow-ups flagged, deliberately not fixed:**
- `rebuild_seed_state` (share_handler.rs) hardcodes `hidden: false` on seeder auto-rejoin, and the
  Dart FileHeader handler passes `contextType: 'channel'` unconditionally — only reachable for
  completed+seeding rows, but worth a look now that the finalize race is closed.
- Item-2 leftovers: swarm's plaintext `ChannelSyncBatch` loop vs the public-viewer items builder
  drifted semantically (`is_mine` raw `==` vs resolver; file-meta sender source) — possible latent
  bugs, behavior preserved.
- Coverage config: `rust-coverage.yml` (Codecov) ignore-regex excludes `/node/` but the Sonar one
  doesn't — badge numbers will drift; unify someday.

**Opportunistic backlog (never a dedicated session — gate hygiene only):**
~300 sub-threshold S3776 (chip away when touching a file anyway); `hollow_shell.dart` layout
builders (:1608=24, :1722=46); 3 S3776 concentrated by the archive dedup
(`imported_archive_prep.dart:66`=45, `archive_message_list.dart:385`=25,
`archive_shared_widgets.dart:218`=24); dart:S3358 ×97 + dart:S1192 ×25 (mechanical — batch-fix or
downgrade the rules someday).

**Issue lists:** sonarcloud.io project `VitalikPro13_HOLLOW`, branch `dev`, or
`curl "https://sonarcloud.io/api/issues/search?componentKeys=VitalikPro13_HOLLOW&branch=dev&resolved=false&rules=dart:S3776,rust:S3776&ps=500"`.
