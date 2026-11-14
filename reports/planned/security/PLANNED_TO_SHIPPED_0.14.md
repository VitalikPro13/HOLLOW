# Planned to shipped at 0.14: every planned document and its move

Checklist for the 0.14 release day, written 2026-11-05 on `security/0.14` at `56587ca2` and
brought up to date on 2026-11-14 at `89d3a85d` (EMBARGOED with the branch). It lists every
document under `reports/planned/` with its status and what happens to it at the release. **Nothing has been moved.** The lead moves on release day, in one pass with every
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
| `planned/relay-and-sync/SCALE_PROBE_2026_10.md` | Measurement, baseline 18484f7e (2026-10-17); its fixes shipped in 0.12.2 and 0.13 (HOL-SEC-184, -185) | the G1 reruns ran 2026-11-08 (no drops, no breaker trip; memory `reference_g1_scale_run_procedure`), but their column is not written into the file yet | Write the rerun column, then move to `shipped/relay-and-sync/`. |
| `planned/ui-and-accessibility/DIALOG_REDESIGNS_BEFORE.md` | Shipped | the five redesigns replaced these screens in the design language plan (b9b92478, 2026-09-26), released in 0.12.0 | Move to `shipped/ui-and-accessibility/`. Not embargoed, no references; it has no README row today. |
| `planned/security/SECURITY_AUDIT_PLAN.md` | Living | the method and the program; phases A to G done, the external audit next | Decision Q1 below. |
| `planned/security/SECURITY_AUDIT_2026_10.md` and `.pdf` | Shipped (describes 0.13.0) | committed for 0.13 (358f2b58 "Publish 0.13.0 and correct the audit records"); the 0.14 addendum folds in first | Vitalii read the 0.13 report (2026-11-07); he reads the 0.14 addendum next. Fold in `SECURITY_AUDIT_2026_10_ADDENDUM_0.14.md` (HOL-SEC-187 to 206), rebuild the PDF (`scripts/build_audit_report.sh`), then move both to `shipped/security/`. |
| `planned/security/CHECKPOINT_COVERAGE_DESIGN.md` | Committed | 56587ca2 (t14-cover, 2026-11-05) | Move to `shipped/security/` with 0.14. Fix the status line (it still says "Design for approval"). |
| `planned/security/HOL_SEC_187_KEYCHAIN_DESIGN.md` | Committed | design 2fc4dc44 (2026-10-31), build b8b64d15 (2026-11-01) | Move to `shipped/security/` with 0.14, after the retest on the notarized 0.14 build (signed on the release Mac, run on the mini). Fix the status line ("No product code is written until Vitalik approves"). |
| `planned/security/HOL_SEC_187_KEYCHAIN_DESIGN_REVIEW.md` | Committed | 2fc4dc44 | Moves with the design. |
| `planned/security/DEVICE_PROOF_DESIGN.md` | Committed: track R 5af8f7b7, track I 060ca581, track C 11d2619f and dcce6b29 (the design itself came in with track C) | rev 3.5, frozen 2026-11-04, with build notes | Move to `shipped/security/` with 0.14. Fix its status line to name the three tracks. |
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
| `findings/HOL-SEC-187` to `-206` | Committed | security/0.14 (the addendum names each commit) |
| `claims.md`, `threat_model.md`, `authz_matrix.md`, `accepted_risks.md`, `coverage.md`, `candidate_findings.md`, `whitepaper_claims_check.md`, `rs_*_review.md` | Living record | kept current per release |
| `phase_b_evidence/`, `phase_b_recheck/`, `phase_ef/`, `mutation_passes/` | Evidence, complete for 0.13; `phase_ef/crdt.md`, `public_channels.md`, `backfill.md` added for 0.14 | |
| `requirements.md` (new, 0.14) | Living | written for the OSTIF application, current to 89d3a85d |

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
2. Fold the addendum into `SECURITY_AUDIT_2026_10.md`, rebuild the PDF, Vitalii reads it.
3. Q1 and Q2 are answered (section 5).
4. One `git mv` pass for every row marked "Move", then the reference fixes of section 3 and
   the README rows, in the release commit (memory `feedback_small_fixes_ride_release_commit`).
5. Delete this checklist and the addendum file once folded (the report and the README rows
   are the record).

## 5. Decisions (Vitalii, 2026-11-05)

- **Q1. `audit/` and `SECURITY_AUDIT_PLAN.md` move to `shipped/security/` at 0.14**, before
  the 0.14 advisories publish and before the OSTIF application sends links, so no published
  link ever breaks.
- **Q2. The root `README.md` link to the PDF** is updated to the moved path in the same
  release commit.
