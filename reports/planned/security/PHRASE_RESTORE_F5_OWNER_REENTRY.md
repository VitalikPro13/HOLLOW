# F5 and HOL-SEC-230: the members a recovery must keep, and the owner's way back (0.14.3)

Status: BUILDING (revision 3 notes below); revision 2 passed review with changes. Branch
`feat/phrase-restore-f5` at 447cfab4 (EMBARGOED, local only). Revision 1 (option B, a
sync re-entry alone) got REDESIGN: it assumed the members' folds still list the members,
and on a server with no checkpoint they do not (HOL-SEC-230, proven below). Builds on
`PHRASE_RESTORE_DESIGN.md` and `DEVICE_PROOF_DESIGN.md` 7, 8.3, 8.4, 8.7, 8.8. Line
numbers are of 447cfab4.

## Build status (revision 3, after the second design review)

Built on `feat/phrase-restore-f5` (5c166763, ade6c0ef): part A with review items 2, 3
(HOL-SEC-231), 4 (HOL-SEC-232), 11 and 13; part C with items 5 and 6; item 1 in the
chooser. Round 2 built part B (`crdt/record.rs`, one `record_scope` for the build, the
receipt check, the trial fold and the settling; item 14 by riding the ops on the digest
sync and only the ids beside the witness). Not built yet: the invite key rule (items 8
and 12), the F5 sync re-entry (3.2, 3.3), the waiting card (item 9), the item 15 rows for
those. `.team/HANDOFF.md` lists the next steps.

One deliberate change from 2.3: part A keeps the FOLD, not only the seats. When a
rebuild stops folding ops whose device the view stopped counting (Uncounted, never
Missing, another identity's), the replica records those (master, device) pairs and
exactly those ops (author, clock, content id) and `verdict` keeps counting them until
something decides the device: its identity's counted retire, the view counting it again,
for the owner's devices a settling on the base's line that drops it (never a base alone,
item 13), for another identity's ops the owner's newer base. Seats alone cannot fix
HOL-SEC-231 (the owner's own fold lifted the moderator's ban) and leave members silent:
a base step-back (8.8) refuses their posts until the settling, a part A hold refuses
nothing it held (item 10). Nothing the device writes after the trigger counts, so the
thief gains no more than before the notice. Parked ops then need no expiry rule (item
11): the kept ops never park while the hold lasts.

Item 6: cadence counts only authority changes (`cadence_op`: not pins, marks, lock moves
or checkpoints) and waits an hour after the base. Authority changes are rare, so the
64-generation lineage spans weeks to months on a normal server, and an honest stale
witness stays on line; a server with hourly admissions rolls it in about three days,
where an off-line witness leaves the dated list (fail-safe).

## 0. In one screen

- **HOL-SEC-230 (shipped, proven).** On a phrase-rooted server the cut is in force from
  the founding op, so every op the owner's founding device D1 proved counts only while
  the owner's roster counts D1. With no checkpoint (they come only past
  `CHECKPOINT_AFTER_OPS` = 2000 ops, `crdt/fold.rs:26`, so almost every server), a
  recovery that drops D1 drops, at every member that hears of it, every admission,
  channel, role and setting D1 wrote, and no 8.8 hold forms (`recovery_trigger` returns
  at `let old = self.base.as_ref()?;`, `crdt/hold.rs:264`). Harness
  `w3c1_a_recovery_on_a_server_without_a_checkpoint_keeps_its_members`, RED on
  v0.14.2-beta and on this branch. The shipped in-app recovery heals it once the kept
  device's settling lands; this branch's Welcome restore cannot (a fresh install stored
  nothing before T, witnesses name no checkpoint, "I don't know" is all it offers).
- **The fix, three parts at three places** (section 2):
  - C, OWNER: early checkpoints. The owner checkpoints a cut server soon after the first
    change past the founding op, then at most hourly while it changes. Members then hold
    a base, which the shipped 8.8 hold and floor already protect, so this protects
    0.14.0 to 0.14.2 members too, and the existing chooser gets restore points.
  - A, MEMBER: the hold without a base. `recovery_trigger` records the whole fold as the
    pre-trigger state when no base is held, so KEEP and SEAT keep every seat, server and
    MLS leaf meanwhile, and the dropped device's parked ops stay for the restore.
  - B, WITNESS and F: records. A witness that names no checkpoint before T sends the
    dropped devices' ops it first stored before T; F judges records with the existing
    chooser (a record's line is its subsets) and settles on the chosen one.
- **F5.** With C and the floor, J's entry usually carries a key and today's keyed
  re-entry works. A KEYLESS entry (never checkpointed, a floor the thief killed, a floor
  older than the first key) starts a sync re-entry from the friend device that named it
  (revision 1, narrowed by findings 5 to 8). On those paths F's first key, lock and door
  reach the members inside the SETTLING batch, Carried to every device of the settled
  state's members.
- **The invite key** (findings 3 and 4, Q1). Every settling of a server we own writes a
  fresh `JoinKeySet` (an invite reset) in the same batch unless the key in force passes a
  FOLD rule (set by our master, proven by a device our view counts, stamped after our
  recovery). No device-local row, no tick. Old invite links die after every recovery
  that cuts a device off, the shipped in-app one included.

## 1. HOL-SEC-230 today

Fixture (both trees): owner M with devices D1 and D2 (D2 kept), members J and K, both
admitted by D1's proofs, no checkpoint anywhere. D2 goes away, the phrase drops D1, J and
K learn the new roster, 12 s pass, then D2 takes the recovery (the shipped in-app path).

| | J and K while D2 is away | after D2's settling |
|---|---|---|
| fold | members = [M]; J and K not members | members = 3 (D2 first stored D1's ops before T) |
| hold | `in_recovery=false`, `Hold::Out` for both | none needed |
| MLS | K's leaf gone at J, J's gone at K | both back within 60 s (the walk) |
| server | still held (no teardown arm fired) | held |

`plan` judges each op of a cut server by its device; D1 is uncounted, so its
`MemberAdded`, `ChannelCreated`, role and key ops refuse (parked 30 days, `PARK_MS`, the
owner having a member span). The eligibility rules (section 7) are about checkpoints;
with none held `recovery_trigger` returns `None`, no hold forms, and every site 8.8 lists
acts on the stepped-back fold: the batch tick sweeps "unseated" leaves, voice channels D1
made auto-leave, the sync loops stop asking (`is_member`).

Reachable on 0.14.2: the in-app recovery (`api::roster::recover_with_phrase`, kept device
D2 holding S) saves the roster, then the node settles after a two-identity `op_sync`
round (up to 10 s). A member that learns the roster in that window (the DM `rd` digest
trade, a `RosterNotice`, the own-room hand-off), or while D2 is offline after the save (a
phrase typed with the node stopped settles only at the next start, `w3c1r_*`), steps back
as in the table. On this branch's Welcome restore F has no D1 op stored before T to keep,
so its settling makes the loss permanent.

## 2. The HOL-SEC-230 fix

### 2.1 Why all three parts

| Option (the review's) | Protects 0.14.0 to 0.14.2 members | Fixes a fresh owner's restore | Where it must run |
|---|---|---|---|
| A. Founding-op pre-trigger record | no | no (it only keeps seats while waiting) | each member |
| B. Witness answer of the kept record | no (they send none) | yes, from 0.14.3 witnesses | witnesses and F |
| C. Checkpoint soon after founding | YES: on a base they already form the shipped hold and floor | yes, the existing chooser | the owner device that later goes missing, before the loss |

C alone is not enough. The owner checkpoints only once `checkpoint_witnessed` holds (two
other identities completed digest rounds since its last connect, one a moderator or with
roots in different members, or every other member did). A small server whose owner
admitted everyone and has no moderator checkpoints only when every member synced in one
session, which may never happen; a device lost before it ran 0.14.3 wrote nothing. A
alone keeps seats but the restore still empties the server. B alone leaves old members
evicted meanwhile and never helps a server whose witnesses all run 0.14.2. So C first (it
covers the most, old members included, through reviewed code), A wherever C has not
written a base yet, B so the person still gets the members back there.

The in-app recovery's kept device needs nothing new for the fold (its own `seen_ms`
keeps D1's pre-T ops); it gains the key rotation of section 4.

### 2.2 Part C: early checkpoints (owner)

`checkpoint_due` (fold.rs:805) gains two clauses inside today's gates (owner, not
deleted, `cp_retry_at_ms`, and the caller's `checkpoint_witnessed`, unchanged):
- the cut is in force, no base is held, and the fold holds an op other than the founding
  op (the first checkpoint follows the first admission or change);
- the base is older than `CHECKPOINT_MIN_GAP_MS` (1 h, base clock) and the log past the
  base holds an op that is neither a row kind (`FloorMark`, `SettleSign`, pins) nor a
  `JoinLock` move (an idle server does not checkpoint for lock churn).

The 2000-op, legacy and pre-0.14-base clauses stay. Cost: at most one checkpoint per
active hour per owned server (a small server's state is a few KB; a big one is bounded
by the 16 MiB checkpoint cap, as past 2000 ops today). The witnessed rule (F1 mitigation)
is NOT relaxed: a first checkpoint written without it would let a withholding member
decide what it dominates.

Residual window: D1's ops after the last checkpoint X and before T are still lost in a
fresh-install restore (8.4 folds X with the dropped devices uncounted): at most an hour
of changes plus the witnessed delay. Members admitted then keep their seats meanwhile
(D34-1) and leave the fold at the settling. Question 1.

### 2.3 Part A: the hold without a base (members)

`recovery_trigger` (hold.rs:260) keeps its guards (not in recovery, not settled, we are a
member and not the owner, our master signs). When `self.base` is `None` and the cut is in
force, it triggers when the new plan would no longer fold an owner op the current
`op_log` folds whose proven device the new view does not count:

- `Recovery { base: None, base_op: None, pre: lean_snapshot() (the whole fold, as today),
  removals, leaves: None (filled by `floor::note_trigger_leaves`), dropped }`, where
  `dropped` (new, `#[serde(default)]`) lists the owner devices that lost their count;
- no round, no `FloorMark` (nothing to name); KEEP, SEAT, the shell rule, standing over
  SEAT and every site of 8.8's three classes read it unchanged;
- it ends on a counted settle mark (the kept device's or F's settling, as today), or when
  the owner view counts every device in `dropped` again (a recovery that takes D1 back);
  never by a clock;
- while it lasts, a parked op proven by a device in `dropped` does not expire at
  `PARK_MS` (inside its author's quota group and the core's per-device ceiling): it is
  what part B serves;
- `shared_servers::entries` reads the hold: a server in recovery lists our identity by
  KEEP and names the pre-trigger state's members, with the key the current fold holds
  (none here), so F learns whom to ask.

A changes what the local hold protects, never what the fold admits.

### 2.4 Part B: records (witnesses and F)

**The answer.** In `WitnessDesk::answer`, when `named_before` finds no checkpoint (`cp`
empty), the witness also builds a RECORD: every op it holds (op log, stored and parked
rows) authored by the server's owner, proven by a device its current view does not count
for the owner, with `seen_ms < T_w`, the founding op left out. At most 4,096 ops and
8 MiB, else no record (fail closed to today's answer). `CpWitness` gains `rec: String`
(`#[serde(default)]`, 64 hex, empty = none) = SHA-256 of `hollow-witness-rec1\n`, the
server and the sorted op content ids. A non-empty `rec` is signed under a NEW tag,
`hollow-cp-witness3`, over the v2 fields plus `rec`; an empty one keeps the v2 text, so a
0.14.2 witness verifies as today. `folded_age_ms` = the witness's now minus the newest
`seen_ms` in the record. The ops ride the `SyncResponse` beside the witness.

**F's receipt checks**: every record op verifies (`verify_author`, this server, author =
the owner, a proof whose device F's view does NOT count), the id recomputes, the bounds
hold. Any failure voids that witness (it counts as naming none).

**Judging.** Records are contents for the existing `judge` (witness.rs:577), unchanged.
For a distinct record X: `CpFacts { generation: |X|, hlc: the greatest hlc in X,
lineage: the other named records that are proper subsets of X, members: the members of
F's trial fold of the founding op, X's ops and every op F counts }`. A record and a
checkpoint are never on one line. Then supporters, the 2-supporter candidates, continuity
over every named subset and the one-line pick read as they do for checkpoints:
- honest members that stored the same ops name one record H: a pick, named by them;
- a puppet superset P (H plus puppet admissions): not continuous, since its supporters
  are not members of H, which an honest witness named; H is still the pick. With only
  puppets answering, their pick is the known residual (DEVICE_PROOF section 17: the
  screen names every supporter and offers "Choose another point");
- a stale honest subset S of H: H's supporters need not be members of S, so the dated
  list, the fail-safe answer.
The thief signs any op with any clock, but it cannot make an honest member have stored
before T an op it wrote after T; the witness's own `seen_ms` decides, as `first_fold_ms`
does for a checkpoint.

**The settling.** `SettleOn::Record(X)`: `settling_input` (settle.rs:117) also keeps a
dropped device's op whose content id is in X. The rest is today's rollback-shaped
settling (`author_settling_on` writes the ordinary first checkpoint when no base is held,
then the settling with `cp_settles`, `cp_roster`, the carried sets). Members fold it (F
counted): the settle mark ends their recovery, and the fold lists everyone the record
admitted, 0.14.2 members included where they still hold the server.

**The screen.** A record point is dated by its newest op and named by its supporters, as
a checkpoint point is. No Dart change, no new copy.

### 2.5 What 0.14.0 to 0.14.2 members do when the owner recovers

- Checkpointed before the loss (part C ran on D1, or the log passed 2000 ops): the
  shipped 8.8 hold and floor; F's restore picks from their witnesses as today.
- Never checkpointed, in-app recovery: they step back until the kept device's settling,
  then the fold and MLS seats come back (section 1's table).
- Never checkpointed, Welcome restore: they send no record. If a 0.14.3 member sends one,
  F's settling lists them and they are members again once they fold it. If none does,
  only "I don't know" remains and they need a new invite (question 2).

## 3. F5: the owner re-enters without its old device

### 3.1 Which path

| What J's fold holds | J's entry | F's path |
|---|---|---|
| a floor X (C wrote X before T) holding a key | keyed | today's keyed re-entry (join box to the newest door and key, the `already_member` answer). F's fold takes the floor from the marks and pins it receives (a pure function of held facts), so it lists the members (test 6 asserts this before the settling) |
| no base, part A's hold | keyless | sync re-entry (3.2), then the witness restore with records |
| a killed floor, or a floor older than the first `JoinKeySet` | keyless | sync re-entry, then the witness restore from checkpoints (8.4) |

### 3.2 The sync re-entry (revision 1, with findings 5 to 8)

Trigger (F only; all must hold):
- F is recovering (`shared_servers::recovering`); the answer answers our ask
  (`shared_asks.take_frame`) from a device `asker_ok` counts for an accepted, unblocked
  friend; the entry passes `accepted`'s shape checks. An EMPTY `join_key` now marks it
  `Reentry::Sync` (RAM, never on the wire); a malformed key still drops it.
- Owned servers only (finding 8). A non-genesis entry whose `owner` is not our master is
  dropped. A genesis entry (entries carry no owner for one) is checked at the first
  answer: its founding op must found it for our master, else the re-entry ends there
  (pending removed, room left, the skeleton and its rows dropped, nothing persisted).
- Skip rule (finding 8, narrowed): skip only when we hold the server with a member span
  of ours, or with our own signed leave; a held state with neither re-enters.
- Our relay (another relay is held for the person, as today).

Steps:
1. `start_reentry` with `Reentry::Sync` builds today's `PendingJoin` plus
   `sync_from: Vec<String>` (the friend devices that named it, RAM only) and
   `join_key: None`. It joins the room (for `RosterNotice`); no `request_join_lock`, no
   join box.
2. `op_sync::ask` over `ServerState::skeleton(sid)`, Carried to the first `sync_from`
   device, with our `asker_roster`.
3. The member's `handle_sync_request` runs unchanged (`asker_verdict`, `keeps_peer`, the
   roster ingested only when it counts the sender; under part A's hold KEEP serves, a
   shell never).
4. F's `handle_sync_response`, pending-join branch (swarm.rs:9397): for a sync re-entry
   it takes a `SyncResponse` ONLY from a `sync_from` device (finding 5, Q3); any other
   peer's answer for that server drops before the parse. Every op passes
   `ingest_remote` under F's own view. It completes (`:9502`) only once the fold lists our
   master AND that device's digest round has no range left (`op_sync::answered`), never
   on the founding op alone (finding 5).
5. Retry and lapse: no answer in 15 s asks the next `sync_from` device, at most 6 asks.
   `Joins::lapsed` ends a sync re-entry WITHOUT holding it for the person (finding 7: a
   keyless held share cannot be joined by hand); the next friend arrival asks again.
6. `Joins::offer` (finding 6): an entry for a server already queued or started adds the
   new friend device to its `sync_from` (at most 8, distinct) instead of dropping it.

### 3.3 Where F's key, lock and door reach the members (finding 2)

- Floor path: F's fold lists the members, so the walk (`WalkView::order` reads
  `state.members`), `door_room::answer_ask` (`seats_peer`) and admissions run as today.
- Keyless paths: F's fold lists only us until the settling, and nothing of F's seats
  anyone before it, on purpose: the settling is the first moment F has evidence of who
  the members are. `restore_flow::register` sees a server we own first held after T and
  starts the witness restore (asks go to friends and to every member `entries` (KEEP) or
  a record names). The settling batch, in order: the first checkpoint (no base held), the
  `SettleSign` and settling, the fresh `JoinKeySet` (section 4), the lock reset with
  grants for the settled state's moderators. It goes MLS-first (F has no leaf yet) with
  the Carried twin to every device of every member of the SETTLED state (targets from the
  settled state, never the pre-settling one), and the `DoorGrant` of the new door goes
  directly to those devices (8.3 step 5). F holds an Olm session with every witness from
  the witness exchange; a member without one gets the settling from a co-member's sync
  (R33-4).
- On a keyless path F's lock keeper waits: while F's fold seats no member but us and the
  witness restore for that server is open, `tick_server` mints no owner base, so members
  are not hidden behind a door F cannot grant yet. D1 keeps seeing the room until the
  settling, as in revision 1 until F was back; its lock links are dead at the relay
  already (`join_lock.h` 199-207), so it moves nothing.
- MLS: once members fold the settling, F is a leafless member and the walk seats it.

## 4. The invite key after a recovery (findings 3, 4; Q1)

Rule, judged on the FOLD in every settling we author for a server we own (8.3 in-app,
8.4 witnessed, record, rollback): the key in force (the `JoinKeySet` winner) passes only
when its op is authored by our master, proven by a device our current view counts, and
stamped at or after our roster's newest recovery `at_ms`. Otherwise the settling batch
appends one `JoinKeySet` (what `handle_reset_invite_link` writes: it retires the old key
and moves the lock), minted after our `Hlc` observes `at_ms`.

- Two owner devices (finding 3): the first settling's key reaches the second by sibling
  sync; it is ours, counted and after the recovery, so the second rotates nothing. Two
  settlings at once rotate twice (old links die once more), never in a loop, since each
  later key passes the rule on both.
- No dependency on `sets_missing_join_key` (finding 4): one device writes a settling
  (the one that ran the recovery or the restore, on screen by construction), and its
  batch carries the key. The missing-key tick stays for servers that never had a key.
- A witnessed or record content may carry the pre-T key; the fresh `JoinKeySet` is a
  later op in the same batch and wins the register, so there is no re-check at `done_key`
  and no `rekeyed:{sid}` row (revision 1's row is dropped, with its restore-half test).
- Shipped behaviour change (Q1): the in-app recovery now resets the invite link of every
  server we own when it cuts a device off; R-CR-10 changes in the same diff.

## 5. Why a master-key holder still gets nothing

Revision 1 section 4 holds (counting needs the phrase; `asker_ok`, `asker_verdict`, the
walk, `roster_check` and `is_bare_master` refuse a minted device X and D1). New surfaces:
- Records: an op counts only if it is the owner's, proven by a device F does not count,
  and first stored by the witness before T; supporters and continuity as in 2.4.
- Part A: it protects only seats this replica held at its trigger (SEAT as 8.8) and
  admits nobody, so D1's post-notice ops gain nothing.
- Part C: checkpoints only by the owner's counted devices, through the existing writer
  rule; D1 after its removal writes nothing eligible.
- The sync re-entry: answers only from devices we asked, owned servers only, completion
  only on a caught-up fold that lists us.

## 6. Changes (all `rust/hollow_core/src/`)

| Where | Change |
|---|---|
| `crdt/fold.rs` `checkpoint_due` | part C |
| `crdt/hold.rs` `recovery_trigger`, `Recovery.dropped`, `recovery_ends`; `crdt/fold.rs` park expiry | part A |
| `node/witness.rs` `CpWitness`, `answer`; `node/restore_flow.rs` `checked_contents`, `settle`; `crdt/settle.rs` `SettleOn::Record`, `settling_input` | part B |
| `crdt/settle.rs` `author_settling_on`, its 8.3 caller and `restore_flow::settle` | the key rule, the settled-state fan-out |
| `node/shared_servers.rs` `entries` (KEEP), `accepted`, `Joins::{offer, lapsed}`, `start_reentry` | 3.2 |
| `node/types.rs` `PendingJoin.sync_from` | RAM only |
| `node/swarm.rs` the SharedServers arm, the pending-join `SyncResponse` branch, the sync-ask tick | 3.2 steps 4 and 5, the genesis owner check |
| `node/lock_keeper.rs` `tick_server` | the keyless-path wait |
| wiki `security_write_gates` §63, §64, §80; `audit/requirements.md`; wiki `rust_sync_handler`; WHITEPAPER recovery section | docs in the same diff |

Wire: one `#[serde(default)]` field (`CpWitness.rec`), the record's ops on the existing
witness answer, the signed tag `hollow-cp-witness3`. No new variant, relay change, KAT,
FFI or Dart. Persisted: `Recovery.dropped` (serde default).

## 7. Tests (RED first; harness block `// pr-f5-owner-reentry` at the end)

HOL-SEC-230:
1. `w3c1_a_recovery_on_a_server_without_a_checkpoint_keeps_its_members` (harness, written
   in both trees; RED, section 1). Green by part A; needs a cfg(test) switch keeping part
   C off for its server (an owner still on 0.14.2).
2. `w3c1_an_owner_checkpoints_a_cut_server_soon_after_its_first_admission` (harness, and
   a unit on `checkpoint_due`: the first checkpoint follows J's admission once witnessed,
   then at most hourly while ops arrive, never for lock moves alone). RED today.
3. `pr_a_a_fresh_install_restores_members_from_the_owners_early_checkpoint` (part C on,
   D1 lost after J and K joined: F's restore picks it, J and K stay members). RED today.
4. `pr_a_a_fresh_install_restores_a_server_that_never_checkpointed_from_members_records`
   (part C off: records from J and K, a pick, J, K and D1's channels back). RED today.
5. Units: `hold::tests::a_server_without_a_base_holds_its_members_when_the_owner_device_is_dropped`,
   `hold::tests::a_baseless_hold_never_forms_for_the_owner_a_non_member_or_a_counted_device`,
   `hold::tests::a_baseless_hold_ends_on_a_settle_mark_or_when_the_device_counts_again`,
   `fold::tests::a_dropped_devices_parked_ops_outlive_park_ms_during_a_recovery`,
   `shared_servers::tests::entries_list_keep_members_during_a_hold`,
   `witness::tests::a_witness_with_no_checkpoint_before_t_sends_the_dropped_devices_ops_it_stored_before_t`,
   `witness::tests::a_record_with_a_counted_devices_op_or_a_wrong_id_voids_the_witness`,
   `witness::tests::a_v2_witness_still_verifies_and_a_v3_record_binds_its_id`,
   `witness::tests::one_honest_record_blocks_a_puppet_superset_and_a_stale_subset_lists`,
   `settle::tests::a_record_settling_keeps_only_the_records_ops_of_the_dropped_device`.

F5:
6. `pr_a_welcome_recovery_restarted_before_the_readd_restores_the_owned_server`
   (un-ignored, on a fixture with part C's checkpoint before T): F's fold lists J before
   the settling; then F holds an MLS leaf, posts flow both ways, J's key is F's, the
   relay's newest door is F's and D1 proves none.
7. `pr_f5_a_server_that_never_checkpointed_comes_back_by_sync_and_records` (keyless: sync
   re-entry, records, settling; nobody evicted meanwhile; key, lock and door reach J and
   K in the settling batch; posts both ways).
8. `pr_f5_a_master_key_holders_fresh_device_is_never_re_added` (revision 1 test 2; kills
   the `asker_verdict` and `keeps_peer` mutants).
9. `pr_f5_the_cut_off_device_never_moves_the_key_or_the_lock_back`.
10. `pr_f5_members_admit_again_once_the_owner_is_back` (before the settling a joiner with
    an old link is not admitted; after it a fresh link from J admits; an old-key ask is
    refused as retired).
11. `pr_f5_a_keyed_reentry_still_ends_with_a_key_the_cut_off_device_never_held` (keyed
    order with the settling forced before any missing-key tick; RED today and
    deterministic: a key is present, so nothing rotates).
12. `pr_f5_two_owner_devices_rotate_the_key_once` (finding 3).
13. `w3c1_an_in_app_recovery_resets_each_owned_servers_invite_key_in_its_settling` (Q1;
    RED today).
14. `pr_f5_a_sync_reentry_takes_answers_only_from_the_devices_it_asked` (finding 5, a
    third member's raw Carried answer).
15. `pr_f5_a_sync_reentry_completes_only_once_its_digest_round_is_caught_up` (finding 5).
16. `pr_f5_an_owner_reentry_waits_for_a_friend_and_completes_when_one_returns`.
17. `pr_f5_the_lock_waits_for_the_settling_on_a_server_whose_fold_seats_only_us`.
18. Units `shared_servers::tests::a_keyless_entry_from_a_counted_friend_is_a_sync_reentry`,
    `a_keyless_entry_from_a_device_we_do_not_count_is_dropped`,
    `a_malformed_key_still_drops_the_entry`,
    `a_keyless_entry_for_a_server_another_identity_owns_is_dropped` (finding 8),
    `a_second_friends_entry_adds_its_device_to_the_reentry` (finding 6),
    `a_lapsed_sync_reentry_is_not_held_for_the_person` (finding 7),
    `a_held_state_with_our_span_or_leave_skips_the_entry` (finding 8); harness
    `pr_f5_a_genesis_reentry_founded_for_another_owner_ends_at_the_first_answer`.

Controls that stay green: every `pr_a_`/`pr_b_`/`pr_c_`, `w3c1*`, `t14d_*`, `t14_reset_*`,
`t14c_*`, the join-lock, door-room and floor families, the witness and `shared_servers`
units.

Mutation targets (one runner job, each layer alone): C's two clauses; A (no trigger
without a base; `pre` empty; ends without a settle mark; parked expiry back on);
`entries`' KEEP read; the record build (`seen_ms <` to `<=`; counted devices included;
bound off); each record receipt check; the subset lineage (always or never on line);
`SettleOn::Record`'s keep clause; the key rule (always or never passes; device count
ignored; `at_ms` ignored); the settled-state fan-out (pre-settling targets);
`accepted`'s keyless branch; the `sync_from` answer filter; the caught-up completion; the
owner and genesis checks; the narrowed skip; the `offer` merge; `lapsed`'s hold; the
lock-keeper wait; member-side `asker_verdict` and `keeps_peer`.

## 8. Gate and requirements rows

- `security_write_gates` §63 (the cut and the hold): the baseless trigger, KEEP and SEAT
  from the whole fold, parked rows kept, the end rule. §64 (shared servers): a keyless
  entry's sync re-entry, answers only from asked devices, owned servers only, the
  completion rule. §80 (the restore): records (build, receipt checks, judging,
  `SettleOn::Record`), the key rule in every settling, the settled-state fan-out.
- `requirements.md`: R-CR-10 gains "and a recovery that cuts a device off resets the
  invite key of every server the identity owns in its settling". NEW (CR area): "A
  recovery never evicts a member, seat or MLS leaf meanwhile, checkpoint or not, and a
  fresh install restores the members its members stored before T" (tests 1 to 4). NEW
  (ID area): "A device my recovery kept gets back a server my identity owns through its
  members, never through a door, invite or key from before the recovery, and its
  settling sets a new key" (tests 6 to 18).

## 9. Questions for Vitalik

1. The hour after the last checkpoint (part C): records could also extend a named
   checkpoint ("X plus the dropped device's ops after X stored before T"), closing that
   window, at the cost of a second line rule in the chooser. Recommended: not in 0.14.3;
   the hour is the design's existing "one window" granularity.
2. A server whose witnesses name no point and no record (every member on 0.14.2, the
   owner's device lost before it ran 0.14.3): "I don't know" empties it (only the owner
   stays). Offer it, or keep the server waiting for a member on 0.14.3? Recommended: keep
   waiting (the members still hold it) and say so on the card (copy through Sepia).
