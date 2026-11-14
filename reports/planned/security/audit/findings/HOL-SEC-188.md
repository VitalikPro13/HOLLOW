# HOL-SEC-188: A device its roster removed could still write server history with the master key

```
ID:          HOL-SEC-188                 Status: Fixed on local branch security/0.14 in three
                                          tracks: the relay join lock (5af8f7b7, 2026-11-04),
                                          the roster authority walk (060ca581, 2026-11-05) and
                                          the device proof on server ops and channel posts
                                          (track C: 11d2619f and dcce6b29, 2026-11-07), retest
                                          at release
Severity:    High                        (Impact H: on an owner's identity, any server state
                                          signed as the owner's checkpoint, a server delete, and
                                          every moderation act the identity's role allows, for
                                          good on every replica that folds it; Exploitability M:
                                          needs the key material of a device the person already
                                          removed, which a thief of a phone or laptop holds)
Category:    Authorization / Identity (a signature taken as permission)
Component:   rust/hollow_core/src/crdt/operations.rs (CrdtOp: master signature only),
             crdt/server_state.rs (op_allowed, checkpoint_allowed), node/swarm.rs
             (apply_remote_crdt_op), node/sync_handler.rs (handle_envelope_crdt_op), digest
             and page answers (crdt/digest.rs, node/crdt_resync.rs); relay-uws/src/join_lock.h
             and node/join_lock.rs (owner bases and resets signed by the master key alone);
             channel posts served by backfill (node/sync_handler.rs, node/crypto_handler.rs)
Boundary:    TB-3 (own identity and its devices), TB-2 (peer and peer), TB-1 (relay)
Traces to:   C-01, C-03, C-15, C-16, C-17; AR-02 (closed for the roster only, HOL-SEC-077);
             CHECKPOINT_COVERAGE_DESIGN rev 2 section 10; DEVICE_PROOF_DESIGN rev 3.5 section 1
Attacker:    P-08 (own removed device, stolen and usable)
Found:       2026-11-01 (hostile review rev 2 of the checkpoint coverage design, question
             "can a roster-removed device still author master-signed server ops")
Affected:    every release from 0.12.0 (design ID-1 made the roster the device authority)
             through 0.13.0
Fix commit:  5af8f7b7, 060ca581, 11d2619f, dcce6b29 (security/0.14)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

Design ID-1 made an identity's roster the authority over which devices are its own, but
every device of an identity holds the master key, and nothing that writes server state
asked the roster. A `CrdtOp` named only its master author and carried only the master
signature, so a device the person had removed could still sign any op its identity's role
allowed: an owner's `ServerCheckpoint` of any state, a `ServerDeleted`, kicks, bans and
role changes. Every member admitted those ops, re-served them through digest and page
answers by their author alone, and kept them across checkpoints. The relay's join lock had
the same gap: an owner base or a reset signed by the master key alone moved the lock, so
the removed device could keep the door to the server's room. Channel posts are
master-signed too, so a stale member's backfill could launder the removed device's posts
into everyone's history.

## Fix

Three tracks of one design (`DEVICE_PROOF_DESIGN.md` rev 3.5, approved by Vitalii
2026-11-01 to 2026-11-04):

- **Track R, committed 5af8f7b7.** Every join lock link carries a device proof
  (`hollow-lock-dev1`). The relay takes an owner base, or any link after a proof link, only
  from a device its fold of the identity's rosters counts; a link whose proof names a device
  the fold no longer counts is dead; resets jump at most 2^20 and a frozen lock gives way to
  a counted owner device; removing a device of any member identity moves the lock. Rust
  `join_lock.rs` and relay `join_lock.h` are twins with pinned vectors.
- **Track I, committed 060ca581.** `Roster::authority()` is the one pure verdict on which
  devices count for server authority: the removal walk with reserved slots, so a flood
  cannot push out the removal that keeps a device out, and a removed device can neither
  uncount the device that removed it nor push out its own removal. Removing a device asks
  whether it was retired or lost or stolen and when it was last had.
- **Track C, committed 11d2619f (rules) and dcce6b29 (screens).** Every 0.14 op carries
  `CrdtOp.dev`, the device key over `hollow-crdt-dev1:` plus the unchanged master-signed
  payload, its clock in that device's counter lane; a proof that does not verify is
  stripped at the door. A pure verdict judges each op's device against the author's roster
  under `authority()` (`crdt/authority.rs`, `node/authority_view.rs`). After the cut (the
  first owner checkpoint or founding op that commits to a recovery key) only an op from a
  counted device folds; an op the view cannot place yet parks until the author's roster
  arrives, and one the rules refuse anyway is dropped unstored. A checkpoint from an
  uncounted owner device is no base. Removing a device writes `DeviceRetired` with the
  device's post window; a lost or stolen device is settled back to a restore point from
  before the moment the person last had it, and a fresh install's restore of an owned
  server needs the witnesses of two member identities. Channel posts and edits carry the
  device's proof over the version they hold, deletions, link cards, reactions and file cards
  carry their own, and live delivery, backfill and the public answer a member serves each
  need a counted device, a carried post window or a date before the cut.

## Residual risk

Rules 2 and 3 of the post gate compare a date the author picks, so a removed device can
still place content at an old date through a replica that has not heard of the removal.
A removed device's operations from before the moment the person last had it stay, as the
person chose when removing it. A replica with no route to the author's roster judges its
ops `Missing` and parks them until the roster arrives. A retire written by a remover that
lacks part of the server's history sets the post window from what it holds (AR-41). An
author whose recovery key a master-key holder forged and showed some replicas first is
AR-15. A 0.13 member's posts without a proof are refused past the cut, which the 0.13
status notice says.

## Test

Track R: relay `test_join_lock.cpp` and its Rust twin
`a_pinned_device_chain_verifies_as_the_relay_verifies_it` (`node/join_lock.rs`). Track I:
`authority_ignores_first_sight_and_maturity`, `a_device_never_floods_out_a_removal_of_itself`,
`a_removed_device_cannot_uncount_the_device_that_removed_it`,
`compaction_is_idempotent_under_a_vouch_flood`, `roster_vectors_are_current`. Track C:
`a_device_proof_verifies_only_under_its_key_and_in_its_lane`,
`after_the_cut_only_a_counted_device_writes_and_a_members_op_parks`,
`after_the_cut_an_uncounted_op_the_rules_refuse_too_is_dropped_unstored`,
`after_the_cut_a_checkpoint_by_an_uncounted_owner_device_is_no_base`,
`a_post_after_the_cut_needs_a_counted_device_a_window_or_a_pre_cut_date`,
`a_backfilled_page_keeps_only_posts_a_counted_device_proves`,
`a_page_keeps_only_changes_a_counted_device_proves`,
`a_013_members_proofless_live_post_after_the_cut_is_refused`, and the harness tests
`w3c1_a_removed_device_writes_no_server_history_after_the_cut`,
`t14c_a_removed_devices_changes_are_refused_after_the_cut`,
`w3c1h_an_edit_from_a_removed_device_is_refused_after_the_cut`,
`w3c1h_a_public_answer_serves_only_what_a_counted_device_proves`,
`w3c1_a_lost_laptop_settles_back_to_what_it_did_before_t`,
`w3c1c_a_fresh_install_restores_from_what_members_folded_before_t`. Each fails with the
master signature alone. Mutation passes over track C killed every mutant but those
explained as equivalent (wiki `security_write_gates` sections 63 and 64).
