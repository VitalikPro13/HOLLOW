# Planned to shipped at 0.14: every planned document and its move

Checklist for the 0.14 release day, written 2026-11-05 on `security/0.14` at `56587ca2` and
brought up to date on 2026-11-14 at `89d3a85d` and filled in on 2026-11-15 at `ad38a14e`
(EMBARGOED with the branch). It lists every document under `reports/planned/` with its
status and what happens to it at the release. **Nothing has been moved yet**, and every
step that can run before the move is done (section 4). The lead moves on release day, in one pass with every
reference fixed (memory `feedback_reports_folder_layout`: `git mv`, then `grep -r` over the
repo, `tools/hollow-memory/wiki`, the memory directory and `~/.claude/skills`, then the
`reports/README.md` row).

Status words: **Shipped** (in a released version), **Committed** (on `security/0.14`,
ships with 0.14), **Planned** (nothing built), **Living** (kept current, no single ship).

## 1. Every planned document

| Document | Status | Shipped in / commit | Release-day action |
|---|---|---|---|
| `planned/relay-and-sync/MEDIA_NODE_SWARM_PLAN.md` | Planned | nothing built ("after 0.13 and once real traffic asks for it") | Stays. |
| `planned/relay-and-sync/MULTI_RELAY_CLIENT_PLAN.md` | Planned | nothing built | Stays. |
| `planned/relay-and-sync/STORAGE_NODES_PLAN.md` | Planned | nothing built | Stays. |
| `planned/relay-and-sync/SCALE_PROBE_2026_10.md` | Measurement, baseline 18484f7e (2026-10-17); its fixes shipped in 0.12.2 and 0.13 (HOL-SEC-184, -185) | the G1 reruns ran 2026-11-08 (no drops, no breaker trip; memory `reference_g1_scale_run_procedure`), but their column is not written into the file yet | Rerun written as section 9 (2026-11-15, from the 2026-11-08 logs). Move to `shipped/relay-and-sync/`. |
| `planned/ui-and-accessibility/DIALOG_REDESIGNS_BEFORE.md` | Shipped | the five redesigns replaced these screens in the design language plan (b9b92478, 2026-09-26), released in 0.12.0 | Move to `shipped/ui-and-accessibility/`. Not embargoed, no references; it has no README row today. |
| `planned/security/SECURITY_AUDIT_PLAN.md` | Living | the method and the program; phases A to G done, the external audit next | Decision Q1 below. |
| `planned/security/SECURITY_AUDIT_2026_10.md` and `.pdf` | Committed: ONE edition as of 0.14 (revised 2026-11-15); the 0.13 edition is public with the 0.13.0 release (358f2b58) | the addendum is folded in and deleted (2026-11-15): one report, updated totals, findings 187 to 206 in sections 4 and 5, accepted risks and open items as of 0.14, the PDF rebuilt | Vitalii reads the revised edition. Then move both to `shipped/security/`. |
| `planned/security/CHECKPOINT_COVERAGE_DESIGN.md` | Committed | 56587ca2 (t14-cover, 2026-11-05) | Status line fixed (2026-11-15). Move to `shipped/security/` with 0.14. |
| `planned/security/HOL_SEC_187_KEYCHAIN_DESIGN.md` | Committed | design 2fc4dc44 (2026-10-31), build b8b64d15 (2026-11-01), 6fec99e7 (2026-11-14), re-key b887e706 (2026-11-15) | The signed proof by hand PASSED on 2026-11-15 (notarized build of b887e706, signed on the old iMac, run on the mini; design section 6). The automated signed job never ran and is removed from the workflow. Status line fixed (2026-11-15). Move to `shipped/security/` with 0.14. |
| `planned/security/HOL_SEC_187_KEYCHAIN_DESIGN_REVIEW.md` | Committed | 2fc4dc44 | Moves with the design. |
| `planned/security/DEVICE_PROOF_DESIGN.md` | Committed: track R 5af8f7b7, track I 060ca581, track C 11d2619f and dcce6b29 (the design itself came in with track C) | rev 3.5 of 2026-11-04, with build notes | Status line names the three tracks (2026-11-15). Move to `shipped/security/` with 0.14. |
| `planned/security/audit/` (the whole folder) | Mixed: designs shipped, findings fixed, evidence complete | see section 2 | Decision Q1 below. |

## 2. Inside `planned/security/audit/`

| Item | Status | Shipped in |
|---|---|---|
| `design_A_frame_authority.md` + `design_A_inventory/` | Shipped | 0.12.0 |
| `design_D_mls_authority.md` | Shipped | 0.12.0 |
| `design_D1_door_rooms.md` | Shipped | 0.12.0 (relay deployed ahead) |
| `design_E_crdt_authority.md` | Shipped; section 3's `covers` rule superseded by checkpoint coverage | 0.12.0; superseded part in 0.14 (56587ca2) |
| `design_ID1_identity_authority.md` | Shipped | 0.12.0 |
| `design_ID1R_relay_rosters.md` | Shipped | 0.12.0 (relay 2026-10-02) |
| `design_G_mls_turns.md` | Shipped | 0.13.0 |
| `design_G_standing.md` | Shipped; extended to every anchored server | 0.13.0; c0410f9d in 0.14 |
| `design_G2_breaker.md` | Shipped in SHADOW; enforces in 0.14 | relay 2026-10-23; enforce by default in 4ccb0a10 (track t14-relay) |
| `findings/HOL-SEC-001` to `-186` | Fixed | 0.12.0 to 0.13 (report section 4) |
| `findings/HOL-SEC-187` to `-206` | Committed | 0.14 (report section 4 names each commit); headers carry shipped wording (2026-11-15); HOL-SEC-187 brought up to the re-key and its signed proof on 2026-11-15 |
| `claims.md`, `threat_model.md`, `authz_matrix.md`, `accepted_risks.md`, `coverage.md`, `candidate_findings.md`, `whitepaper_claims_check.md`, `rs_*_review.md` | Living record | kept current per release |
| `phase_b_evidence/`, `phase_b_recheck/`, `phase_ef/`, `mutation_passes/` | Evidence, complete for 0.13; `phase_ef/crdt.md`, `public_channels.md`, `backfill.md` added for 0.14 | |
| `requirements.md` (new, 0.14) | Living | written for external reviewers, current to ad38a14e |

## 3. References to fix when each document moves

Found with `grep -r` on 2026-11-05; run the grep again on release day, since later tracks cite these documents too. Many references use a bare file name (for example
`design_E_crdt_authority.md` or `audit/findings/HOL-SEC-091.md`); grep for the bare name too.

| Document | Repo references | Outside the repo |
|---|---|---|
| `SECURITY_AUDIT_2026_10.md` / `.pdf` | root `README.md` line 92 (public link to the PDF), `scripts/build_audit_report.sh` (default source path) | memory `project_security_audit_plan_2026_09.md` |
| `SECURITY_AUDIT_PLAN.md` | `reports/README.md`, `shipped/relay-and-sync/RESUMABLE_SESSIONS_PLAN.md`, `SECURITY_AUDIT_2026_10.md`, `audit/coverage.md` | memory `project_security_audit_plan_2026_09.md` |
| `audit/` folder | `.gitleaksignore`, wiki `security_write_gates.md`, `rust/hollow_core/src/node/mls_authority.rs`, `reports/README.md`, `SECURITY_AUDIT_PLAN.md`, `SECURITY_AUDIT_2026_10.md`, four files inside `audit/` | memory: `project_mls_leaf_binding`, `project_frame_seal_design_a`, `project_security_audit_plan_2026_09`, `project_join_lock`, `feedback_security_finding_style`, `project_link_snapshot_relay_decrypt`, `project_crdt_fold_design_e`, `project_door_rooms_d1`, `project_id1r_relay_rosters`, `project_identity_authority_recovery_phrase` |
| `CHECKPOINT_COVERAGE_DESIGN.md` | wiki `security_write_gates.md` section 59, `rust/hollow_core/src/crdt/fold.rs` module doc | memory `project_014_wave_plan.md` |
| `HOL_SEC_187_KEYCHAIN_DESIGN*.md` | wiki `security_write_gates.md` section 43b | memory `project_hol_sec_187_keychain_design.md` |
| `DEVICE_PROOF_DESIGN.md` | wiki `security_write_gates.md` sections 56, 61, 63 and 64 and the track C code; cited by name (no path) in `identity/roster.rs`, `identity/roster_vectors.rs`, `storage/messages.rs`, `node/types.rs`, `node/roster_book.rs`, `api/roster.rs`, `lib/src/rust/api/roster.dart`, `lib/src/ui/dialogs/recovery_phrase_dialogs.dart`, `lib/src/ui/settings/device_management_shared.dart`, `test/relay_device_lock_test.dart`, `test/widget/device_removal_dialog_test.dart`, wiki section 56 | memory `project_014_wave_plan.md` |
| `SCALE_PROBE_2026_10.md` | `reports/README.md`, `rust/hollow_core/src/crdt/digest.rs`, `SECURITY_AUDIT_2026_10.md`, `audit/coverage.md` | memory `project_large_server_mls_scaling.md` |

`reports/README.md` had no row on 2026-11-05 for `CHECKPOINT_COVERAGE_DESIGN.md`, either
`HOL_SEC_187_KEYCHAIN_*` file, `SECURITY_AUDIT_2026_10.md`, `DIALOG_REDESIGNS_BEFORE.md` or
`DEVICE_PROOF_DESIGN.md`: check each on release day and add it in its final folder.

## 4. Release-day order

1. Done: track C committed `DEVICE_PROOF_DESIGN.md` (11d2619f).
2. Done 2026-11-15: the addendum is folded into `SECURITY_AUDIT_2026_10.md`, which is now
   one edition as of 0.14, the PDF rebuilt, and the addendum (`.md` and `.pdf`) deleted.
   Open: Vitalii reads the revised edition.
3. Done: Q1 and Q2 are answered (section 5). The status lines of the three security
   designs and the scale probe's rerun section are written (2026-11-15).
4. One `git mv` pass for every row marked "Move", then the reference fixes of section 3 and
   the README rows, in the release commit (memory `feedback_small_fixes_ride_release_commit`).
5. Delete this checklist (the report and the README rows are the record; the addendum is
   already gone).

## 5. Decisions (Vitalii, 2026-11-05)

- **Q1. `audit/` and `SECURITY_AUDIT_PLAN.md` move to `shipped/security/` at 0.14**, before
  the 0.14 advisories publish and before the OSTIF application sends links, so no published
  link ever breaks.
- **Q2. The root `README.md` link to the PDF** is updated to the moved path in the same
  release commit.

## 6. Still open on 2026-11-15

For Vitalii:

- Read the revised report (one edition as of 0.14; the 0.14 findings are HOL-SEC-187 to
  206 in sections 4 and 5, the changes since 0.13 in section 1).
- DECIDED 2026-11-15: the automated signed keychain job is dropped and removed from
  `release-apple.yml`. The proof is the hand procedure on notarized builds
  (`scripts/macos_keychain_check.sh`, check A, the password case), re-run for any release
  that changes keychain code; the 2026-11-15 hand run on b887e706 is the 0.14 proof.
  Recorded in R-ID-07, the finding, the design and wiki `security_write_gates` §43b.

For the lead, in the release commit:

- The `git mv` pass of section 4 step 4 and the reference fixes of section 3, the default
  source path in `scripts/build_audit_report.sh` and the root `README.md` PDF link among
  them (Q2). Rebuild the PDF after the move if any path inside the report changes.
- Text that becomes public with the move and still names OSTIF or the freeze (left as
  written, since it is a record of its time; the report itself no longer names OSTIF since
  2026-11-15): `SECURITY_AUDIT_PLAN.md` (the OSTIF application
  plan), `HOL_SEC_187_KEYCHAIN_DESIGN_REVIEW.md` (the "frozen tag" in F7 and section 4), and
  `HOLLOW_PLAN.md`'s 0.14 entry. This checklist itself names OSTIF and is deleted at step 5.
