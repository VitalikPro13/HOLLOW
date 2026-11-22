# Device proof: only a device the roster counts writes server history

Design FROZEN, revision 3.5 + build notes (2026-11-05: section 4's vouch-cap item 1 as track
I built it, and the final re-check's build-time list in section 17), 2026-11-04. Built in
0.14 as three tracks: R (5af8f7b7), I (060ca581) and C (11d2619f, dcce6b29). EMBARGOED with
0.14 until it ships (local branch `security/0.14`, base `c5d7bcf4`). It replaces section 10 of
`CHECKPOINT_COVERAGE_DESIGN.md` (rev 2). Reviews:

- `.team/review2/REVIEW_REV2.md` refused that section 10 (C1, C2, C3, H1, H4, H5).
- `.team/devproof-review/REVIEW.md` reviewed revision 1 (C1 to C4, H1 to H4, M1 to M7).
  Probes `probes_devproof_roster.rs`, `probes_devproof_lock.rs`.
- `.team/devproof-review/REVIEW_REV2.md` re-checked revision 2 (N1 to N12) and proposed
  the witness recovery (its section "Question 4"). Probes `probes_rev2_roster.rs`.
- Revision 3's own probes: `.team/devproof3/probes_rev3_roster.rs`, the compaction change
  they ran against (`probes_rev3_roster_compaction.diff`, a standalone copy of
  `identity/roster.rs`) and the logs `rev3_walk.log`, `rev3_best.log`,
  `baseline_probes.log`.
- `.team/devproof-review/REVIEW_REV3.md` re-checked revision 3 (R3-1 to R3-10 and LOW
  items, verdict BUILD WITH CHANGES). Probes `rev3/review3_probes_rev3_tests.rs`, log
  `rev3/review3_probes.log`, crate `rev3/rosterprobe/` with the `REVIEW3_FIX=1` sketch.
- Revision 3.1's probe: `.team/devproof3/rosterprobe31/` (the review's crate plus the
  same rule in the compaction walk and one new test), log `.team/devproof3/rev31_walk.log`.
- `.team/devproof-review/REVIEW_REV31.md` re-checked revision 3.1 (R31-1 to R31-10 and LOW
  items, verdict BUILD WITH CHANGES, and the floor design for the open problem). Probes
  `rev31/review31_probes_tests.rs`, log `rev31/review31_probes.log`; models
  `rev31/model/chooser_model.py`, `floor_model.py`, `floor_trade.py` with their logs.
- Revision 3.2's probe: `.team/devproof3/rosterprobe32/` (the review's crate plus the vouch
  cap of section 4, behind `REVIEW32_VOUCH=1`, script `edit32_vouch.py`), log
  `.team/devproof3/rev32_vouch.log`.
- `.team/devproof-review/RECHECK_REV32.md`, the narrow re-check of revision 3.2 (RC32-1 to
  RC32-12, verdict FIX DESIGN FIRST for section 8.8 and the re-fold trigger). Revision 3.3's
  scratch: `.team/devproof33/` (the rev 3.2 text it started from).
- `.team/devproof-review/RECHECK_REV33.md`, the narrow re-check of revision 3.3 (R33-1 to
  R33-11, verdict FIX DESIGN FIRST for section 8.8's held base and section 8.3's re-fold
  trigger). Revision 3.4's scratch: `.team/devproof34/` (the rev 3.3 text it started from).
- `.team/devproof-review/RECHECK_REV34.md`, the narrow re-check of revision 3.4 (R34-1 to
  R34-12, verdict FIX DESIGN FIRST for `cp_refolded`, the shell and the pre-trigger
  state). Revision 3.5's scratch: `.team/devproof35/` (the rev 3.4 text it started from).

Revision 3.5 closes R34-1 to R34-12 and writes Vitalik's 2026-11-04 answer to item 21,
which replaces the item's option (b) and R34-6: the ONLY access revert that runs without
the owner is "made public" (section 8.3, "Unpublish"). Every product choice is decided
(section 20); revision 3.5 adds no open item. Track R (the relay lock, section 12) is
committed on `security/0.14` (5af8f7b7); R2 is its follow-up (section 12, items 9 and 11).
Track I is building in `~/dev/wt/t14-ident`, with the vouch cap (R31-4, HOL-SEC-189)
first. Track C starts after the checkpoint coverage core (`~/dev/wt/t14-cover`) lands; the
seams in section 11 are named after that worktree's `crdt/fold.rs`, `dominance.rs` and
`members.rs`.

Vitalik's rule for 0.14: close every stolen-device hole, in 0.14, never postponed.

## Changes from revision 3.4

| Finding | Change | Section |
|---|---|---|
| R34-1 (`cp_refolded` entries and answers were unsigned checkpoint fields: a stolen owner device could write entries under an honest sibling's `by`, list another master's writes, keep its own "Keep all" past the settling and back-date `opened`) | An entry carries `sig`, by `by`'s device key over (server, member, device, dr, r, at, opened, below, review, unpublished) under `hollow-refold1`; an answer carries its own `sig` by `answered.by` under `hollow-refold-answer1`. A failed signature voids the entry (it suppresses, shows and applies nothing) or the answer (the entry reads as unanswered). `RefoldPin` pins the DR op beside R. Display and confirm re-check the pinned DR, trigger clauses 2 and 3 on the current view, and every item: `stamp.actor` = member, `counter % LANES` = `lane_of(device)`, no `OpRef` of the DR, a kind `refold_class` can list. Clause 1 is not re-run (the line moves past 64 generations; the signature binds the writer to its own judgment). A settling keeps R's entries, never the current base's (D35-1 below), so a dropped device's post-T answer goes with it. Retire re-signs entries and answers in one owner checkpoint before the removal is published | 8.3, 8.5, 11, 15 |
| D35-1 (found while closing R34-1) | A settling folds from R, so a re-fold or a confirm an honest owner device wrote after R was checkpoint content the settling dropped, while the inherited entry still suppressed a second re-fold: the member's stolen device's writes came back for good. The settling now carries R's `cp_refolded` entries, and re-folds in the same checkpoint every pair the current base had an entry for and R lacks, whose DR it holds or pins; answers after R are not re-applied, so those reviews open again. `RefoldPin` keeps an entry's DR for 30 days of owner clock after `opened`. Test `a_settling_reruns_a_post_r_refold_and_reopens_its_answer` | 8.3, 14, 17, 18 |
| R34-2 (the shell lost the room at once and never learned the settling) | The shell counts as our membership at `door_room::sync`, `door_room::on_status` (and so its `DoorAsk`) and the `LockChain` arm's `on_chain` record of the relay chain (which `on_grant` checks a grant against; nothing is authored, `tick_one` stays gated). It sends a throttled, backed-off direct sync ask (`send_room_for_peer`) to the owner's devices and to devices of SEAT masters. The settler sends the settling and a `DoorGrant` directly to every master that is a member in the settling's state and was not in its pre-settling base. The shell keeps Leave (local teardown at once). Harness extended with D1 on and the puppet moving the lock | 8.3, 8.8, 18, A |
| R34-3 (a member that heard of the recovery late folded the thief's post-notice ops under the previous view, so SEAT could name a post-notice identity) | `floor_pending` records, per group (the server group and each subgroup), the masters holding a bound leaf at the trigger. SEAT for a new seat in the server group = those masters plus pre-trigger members whose current span's admitting op this replica holds and whose proof's device the NEW view counts (D34-1's honest admission stays seated); in a subgroup, only a master that held a leaf there at the trigger, with access by R34-9's rule. KEEP is unchanged. Standing, placement and `answer_ask` read the server group's SEAT | 8.8, 11, 15, 17, 18 |
| R34-4 (a lane twin the stolen device vouched blocked its own re-fold) | Clause 3 compares `lane_of(device)` only with devices the owner device's view COUNTS for that author | 8.3, 14, 17, 18 |
| R34-5 ("past 8, the oldest closes as kept" let any member erase a real review) | Nothing closes by count. Every re-fold the trigger allows writes its entry at once with its AUTO and Unpublish reverts; an unanswered entry is LISTED or WAITING (no items until it ranks in, then walked and signed by the lister). At most 8 listed, one per DR author identity, by the author's standing in the base, so a higher-standing author's entry sends a lower one back to waiting, never to closed. At most 256 unanswered per server; past it the lowest-ranked drops (its reverts stand), which only a 256-identity flood reaches. Not the re-check's "the new re-fold waits unwritten": its DR is dominated and gone by the next checkpoint, and Unpublish must not wait. An entry with nothing to list or put back is written answered | 8.3, 14, 18 |
| R34-6 (item 21 (b): "narrows" was undefined and gave a demoted mod an automatic lock-out) | Superseded by Vitalik's decision 21 (below): no computed narrowing. The only automatic access revert is Unpublish; every other access write is REVIEW | 8.3, 20 |
| Decision 21 (Vitalik, 2026-11-04) | Unpublish: a channel the base shows effectively public, whose winning `public` stamp is the dropped lane's, later than the DR's `posts_until_ms` (T on the member's clock), and that the ordinary revert of its `public` unit leaves not effectively public, goes back to not public in the re-fold itself, whatever the author's role and whatever the review slots, and the owner's list shows it as already undone with "Put back". Checked against the access ladder: `can_see_channel_at`, `can_post_in_channel_at` and `channel_backfill_allowed_from` never read the flag, and `channel_readable_by` reads it only for a non-member, so it removes no member's access; only guests' reads and plaintext sending stop | 8.3, 17, 18, 20, A |
| R34-7 (undoing a deletion could bring a channel back unrestricted after an honest restriction) | Undoing a channel's deletion brings it back visible and postable by admins only (`AdminPlus`, no label gates, not public) at the base's access sub-stamps; undoing an access label's deletion brings back none of the assignments the deletion stripped. The item says so | 8.3, A |
| R34-8 (a membership undo re-opened a span over a later honest rejoin and restored a mod role silently) | A membership item is skipped when that member has any event newer than the listed one; a ban unit when either part changed. A re-opened span comes back as `Member`, or as R's role only where the item names it ("comes back as {role}") | 8.3, A |
| R34-9 (ambiguous subgroup clause) | KEEP protects an existing subgroup leaf when its master can see the channel in the current fold, else in the pre-trigger state if a member there (a revocation there wins), else in B if B-only. Accepting a subgroup leaf follows R34-3. Section 17: KEEP through B at a stale replica lacks members admitted above every checkpoint, which harms only that replica's fork | 8.8, 17 |
| R34-10 (`refold_class` details) | AUTO settings are an allowlist (`server_avatar`, `server_banner`, `description`, `is_nsfw`, `max_file_size_mb`, `relay_catchup_secs`, `voice_text_chat`); every other key is REVIEW. `ServerCreated`, `ServerCheckpoint`, `JoinKeySet`, `JoinLock`, `ServerDeleted`, `DeviceRetired`, `FloorMark` and `SettleSign` are Excluded. `may_write_now` = `op_allowed` on the base for a synthetic op by the author at the checkpoint clock that writes R's value; no shared table is claimed | 8.3, 11, 18 |
| R34-11 (class 3 sweep missed sites) | Classed: `handle_epoch_hint`'s member gate, the `MlsCommitCatchup` arm, both gates of the `MlsKeyPackageRequest` arm, the Olm reconcile sweep's relationship gate and the `SyncResponse` arm's digest `learn` read KEEP; the core's silent re-ask (`silent_reasks`, `refused_own_admission`) sends nothing while the hold is not `Out` or the server is a shell | 8.8, 18 |
| R34-12 (wording) | "Keep all" keeps the items shown; items past the first 256 open as the continuation list (`below`). A person's answer stored while this device's base showed the entry unanswered still applies after a 30-day close lands; the UI says "Closed after 30 days" for a timeout. Item 21's "restores a revoked grant" was wrong; the item is replaced, and the list says "{name} was given access to #{channel}. Undoing takes it back." | 8.3, 20, A |

## Changes from revision 3.3

| Finding | Change | Section |
|---|---|---|
| R33-1 (a puppet's answered floor base became the replica's held base, so the hold could seat an identity a post-notice thief checkpoint named) | `floor_pending` keeps what this replica held at the trigger and never moves; B lives in its own column (`floor_b`) and serves only the `FloorMark` and its `FloorPin`. The hold has two sets: KEEP (members of the pre-trigger state or of B: never unseated, never in `stale_leaves`, never `removable`) and SEAT (members of the pre-trigger state only: an added leaf, a Welcome leaf, a KeyPackage sender and a subgroup's `can_see_channel` are accepted only from the current fold or SEAT; a committer or Welcome sender from either set). Standing, `frame_auth::placement` and `data_channel_peer_known` read the pre-trigger state. An answerer's `floor_base` is its own pre-trigger base, never its B, so a steer does not spread through honest answerers. Section 17's RC32-2 residual extended | 8.8, 9, 11, 14, 15, 17 |
| D34-1 (found while closing R33-1) | Revision 3.3's held base was the base CHECKPOINT's content, so a member admitted by an op folded above that checkpoint lost its seat in a step back. The pre-trigger record is this replica's whole folded state at the trigger (local, never served). Harness `t14d_a_member_admitted_after_the_last_checkpoint_keeps_its_seat_through_a_step_back` | 8.8, 18 |
| R33-2 (a DR naming a still-counted device re-folded it for free, and a ground key in the same lane repeated it) | The re-fold also needs this owner device's view of the DR author's roster to NOT count `device`, and `lane_of(device)` to differ from the lane of every other device in that author's statements | 8.3, 18 |
| R33-3 (the re-fold edited derived spans, so the next event re-applied what it reverted) | The membership part of a revert removes the dropped lane's `Admit`, `Leave` and `Remove` events from `member_events` and re-derives through `record_event`'s own path (`ServerState::rederive`), never editing a span; the span bullets are restated as consequences of `derive` | 8.3, 11 |
| R33-4 (in a floorless recovery the sync paths gated on fold membership) | Class 3 of the hold gains the CRDT sync-ask loops (`PeerJoined`, `RoomMembers`, the op_sync follow-ups, `CrdtResync::tick` and `paged`), the `SyncRequest` responder's two gates, `on_verified_sibling`'s re-announce and the `SiblingStateSyncRequest` answer. Harness `t14d_a_floorless_member_offline_at_the_settling_gets_it_from_a_co_member` | 8.8, 18 |
| R33-5 and decision 20 (the re-fold's blast radius: roles, grants, restrictions and the public flag, third parties' admissions, not once per device) | Decided by Vitalik (2026-11-04): option (c). After R33-2's trigger, a re-fold reverts on its own only elements the DR's author could still write with its current role. Moderation, roles, another member's registers, channel access and the public flag, join gates, existence (deletions and creations) and membership events (admissions it answered) are always LISTED to the owner and reverted only on the owner's confirm. The list rides the checkpoint (`cp_refolded.review`) with R pinned (`RefoldPin`), so every owner device shows it and the first answer that lands is the one answer. Declined or unanswered items stay as they are; an open list closes as kept after 30 days. Copy in appendix A | 8.3, 11, 14, 15, 17, 20, A |
| R33-6 (an honest settle mark could be charged to the thief's co-signature and evicted first) | A settle mark is charged to its LIGHTEST counted signer, so it is evicted only when every counted signer it has is over its share | 7, 14 |
| R33-7 (`cp_refolded` entries had no provenance and a thief could pre-write them) | Each entry carries its writer `by`, drops by `cp_endorsed`'s rules 3 and 4 and is re-signed on retire as 8.5 does; it suppresses a re-fold only while its `by` is counted and, where the named DR is held here, that DR is a counted DR for the same pair. Not the re-check's "the DR must be held here": that re-lists what the owner declined whenever a second sibling's DR arrives at an owner device that never held the first | 8.3, 15 |
| R33-8 ("strangers cannot use the path" was false) | Corrected: a free identity named in a checkpoint the thief fabricates can mark it. It can only kill the floor, never become it (`keep(held)` keeps the fork pair). Section 17's killed floor says so | 8.8, 17 |
| R33-9 (in a floorless recovery the stolen owner device keeps the door and ring control) | Stated in section 17: until F moves the lock, on a server F never reaches for good; content stays sealed because its leaf is swept | 17 |
| R33-10 (reverting an existence stamp lost newer honest sub-stamps) | Reverting a channel's or label's existence (now a listed item) also resets its sub-stamps to R's and folds the held ops on each; `twitch_usernames` and the other per-member registers named; R must be `cp_stamped`, else its `covers` is every element's stamp | 8.3 |
| R33-11 (a puppet mod's kick during a recovery tore the member down for good) | During a recovery, a kick or ban by anyone but the owner's counted device ends the hold for us but keeps the server SHELL (listed, read-only, no seat) until the recovery ends; then the fold decides: a member again is re-seated by the leafless path, a removed one tears down as today | 8.8, 17, 18, A |
| Estimates | Removed from sections 0, 8.3 and 19 (Vitalik's rule): section 19 names the split by scope only | 0, 8.3, 19 |

## Changes from revision 3.2

| Finding | Change | Section |
|---|---|---|
| RC32-1 (the hold seated any identity a thief checkpoint named) | The hold set is the members of THIS replica's own `floor_pending` base only (a local row, with its content), never of received pins; minus masters banned or removed by an op first stored after the trigger. `GroupRules::Server` gains `held`: removals of a held master are refused, adds, committers and Welcome leaves are accepted only for a member of the current fold or of the held base, and a subgroup reads `can_see_channel` in the held base | 8.8, 11 |
| RC32-2 (the trigger's round let a post-notice thief checkpoint become B) | B is the previous view's pick over the checkpoints this replica stored before its trigger plus the `floor_base` each answerer returns (its own recorded base); a checkpoint first stored after the trigger whose writer the new view drops is never a candidate otherwise. New `SyncResponse.floor_base` | 8.8, 9, 15 |
| RC32-3 (every member retire re-folded 30 days; a member could undo others' bans and admissions) | Decided by Vitalik (2026-11-04): a re-fold starts only on a DR with `restore` set and on the base's line, and reverts ONLY the base's state elements whose winning stamp is the DR author's, in `lane_of(dropped device)`, newer than the restore checkpoint's and not named by the DR; every other element stays as the base has it. `cp_refolded` (member, device, DR id) is copied forward, so sibling owner devices do not re-fold | 8.3, 11, 14, 15, 17, 20 |
| RC32-4 (the SettleMark's wire form was undefined; co-signatures and the parent pin never travelled) | Each settling signature is its own owner-authored op, `CrdtPayload::SettleSign`, so the digest, `served_log`, dedup and 0.13's unread keep carry it per (settling id, signing device); the pinned parent is its own served row, `SettlePin`. Better than a synthetic digest entry: no new sync field, and the existing op transport already proves convergence | 7, 8.5, 11, 15 |
| RC32-5 (the hold missed the SyncResponse teardown, voice auto-leave and more) | One predicate, `recovery_hold(server, master)`. The sites are named by function in three classes (teardown, seats, liveness reads), with the Grep floor and LSP sweep the build repeats | 8.8, 11 |
| RC32-6 (a removed sibling's mark displaced the member's; marks had no ingest path) | `FloorMark` is classified before the door and `op_allowed`; stored only when its author is a member of the named checkpoint and the checkpoint op is held or arrives with it; up to 4 marks per identity, counted first then lowest; 512 authors per server | 8.8, 10, 14 |
| RC32-7 (0.13 never steps back; its committers split the MLS group from 0.14 members under the hold) | Decided by Vitalik (2026-11-04): accepted as a residual. Section 16 rewritten, section 17 entry, harness case `t14d_a_013_committer_during_a_recovery`, a line for the RED 0.13 notice. No merge of 0.13 committers' removals | 16, 17, 18, A |
| RC32-8 (in a step back the lowest master id leads, so a puppet can grind it) | While a server is in recovery with no floor, standing reads tiers and positions from the held base's state | 8.8 |
| RC32-9 (a counted thief fabricates a parent of any generation; 32 such marks pushed out honest ones) | Section 7's sentence corrected; settle marks evict per signing device, the heaviest signer first, as `trim_kept` does per author | 7, 14 |
| RC32-10 (vouch cap idempotence) | Being built by track I in `~/dev/wt/t14-ident` (HOL-SEC-189): the vouch cap ships with its own walk (reference `walk_valid` in `.team/devproof3/rosterprobe32/`), sorts first every vouch that made a walk-alive signer valid at its turn, with the property test `compaction_is_idempotent_under_a_vouch_flood` and the flood and idempotence cases in `roster_vectors.json` | 4, 18, 19 |
| RC32-11 (a killed floor on a server F never reaches is permanent) | Said so: permanently, unless F reaches it | 8.8, 17 |
| RC32-12 (mods' kicks and bans fail in a floorless state) | The hold ends in a floorless state only by a leave or by the owner's kick or ban; said so | 8.8, 17 |
| t14-lock finisher (lead, 2026-11-04) | Section 12 item 3: when the relay refuses the remover's move ahead of the removal, the remover acts at once only if the relay's newest link was made by a device its own identity removed; any other newer link waits for its holder's grant, and a mark dies with its offer | 12 |
| t14-lock finisher (lead, 2026-11-04) | The `lock_put` breaker plan prices `SIG_W` per link, but a 0.14 link costs two verifies (`dev` and change); fix `2 * SIG_W * n` in `ws_handler.cpp`, `relay_pace.rs` and `breaker_vectors.json` together, a track R2 item | 12, 17, 19 |

## Changes from revision 3.1

| Finding | Change |
|---|---|
| R31-1 (a puppet-named intermediate checkpoint shadows the honest one) | Continuity's second clause holds for EVERY older checkpoint on X's lineage that any counted witness named, not only the nearest. Model `chooser_model.py`: thief picks 289 of 20,000 under the rev 3.1 rule, 0 under this one. The dated list therefore shows more often, and appendix A presents it as a normal screen. Section 8.4 |
| R31-2 (members step back, lose MLS leaves and tear servers down during every recovery) | New section 8.8: FLOOR MARKS. A member that sees its base lose eligibility syncs with two identities, then signs a `FloorMark` naming the base it held; the oldest named checkpoint is the floor when every named one lies on one line, else there is no floor. Floor-only checkpoints endorse nothing; any counted settling overrides; 32 contents and 64 MiB per server, the fork pair kept. "I don't know" becomes an explicit rollback settling. Separately, a recovery in progress never evicts members or MLS leaves (`sweep_unseated_leaves`, the self-eviction and rebuild teardown paths). Decided by Vitalik, 2026-11-01 |
| R31-3 (the thief makes an honest sibling a "vouchee after T") | Only devices outside the valid closure computed without the dropped devices are removed with them; the first-seen test applies only to those; a dropped device's vouch for a device with another valid path is ignored. Section 8.6 |
| R31-4 (a removed device's vouch flood uncounts an honest device; SHIPPING code) | The vouch cap ranks vouches by their signer's validity under the walk first, then signer rank, and each device's tree vouch comes from its best VALID voucher. Rust and `roster.h`, vectors regenerated. Probe GREEN with the change, 46 of 47 roster tests (`probe3_a_...` superseded as before), `.team/devproof3/rev32_vouch.log`. A track I item, HOL-SEC-189 (embargoed). Section 4 |
| R31-5 (retiring the device that settled lifts the confinement) | The settling id hashes the stamp without `device` and `sig`; a mark is keyed by that id, holds any number of signatures (8 kept) and counts if any signer is counted. Retire co-signs held stamps, lost or stolen those first seen before T. A mark counts only when its generation is its parent's plus one, and the mark row pins that parent. Sections 7, 8.5 |
| R31-6 (retire re-signed only held DRs) | Retire also re-signs every `cp_endorsed` and `cp_posts_until` entry of the base signed by the retired device (lost or stolen: entries whose carrying base was first folded before T). Section 8.5 |
| R31-7 (a join box over 16 KiB was refused) | The box carries only the subset of the roster that places the asking device, omitted when it does not fit; a box is never refused for it; every join box pads to fixed size buckets. Section 8.7 |
| R31-8 (a stranger's `RosterNotice` in a room fills the book) | A `RosterNotice` that arrives through a server room is kept only if its master is in that server's authority set held here; elsewhere only for our own master, friends and pending friends and the existing first-party paths under their own bounds. Closes section 21's unbounded book rows. Sections 8.7, 9 |
| R31-9 (F's first member list can come from the stolen device) | F's ask list is the union of every answerer's state and every friend's `SharedServers` entry, which now names the member identities the friend holds for that server; members named by friends are asked first. Section 8.7 |
| R31-10 (the re-fold was one-shot and compared clocks) | A re-fold is done only once it lies on the base's line, and runs again otherwise. T is judged only on the member's clock: the member's DR names its own restore checkpoint and the ops it folded before T; the owner never compares T with its own `seen_ms`. A member's DR cannot make the owner re-fold past 30 days. Section 8.3 |
| LOW | Seeded first-fold records show "before the 0.14 update" (section 8.4); phrase recovery on a fresh install starts with every other device unticked (section 8.6); F re-asks `SharedServers` when each friend device arrives, answers padded to a fixed size (section 8.7); continuity false positives are expected and shown as the normal list (section 8.4, appendix A) |
| Decisions | Revision 3.1's six PENDING items are written as decided (Vitalik, 2026-11-01); floor marks decided (Vitalik, 2026-11-01). Section 20 |

## Changes from revision 3

| Finding | Change |
|---|---|
| R3-1 (a removed thief's puppet un-counts the honest device) | A signer is alive in the walk only if no earlier alive signer removed it AND it is still in the valid closure at its turn (HOL-SEC-080's keep rule included). The compaction walk uses the same rule per tier, so tier 0 still equals `authority()`. Both review probes go into I3; a new probe shows the compaction layer needs the rule on its own (I15). Section 4 |
| R3-2 (one honest witness did not break a puppet line) | Continuity breaks on the nearest older checkpoint ANY counted witness named, candidate or not; at least 2 supporters must be members of it. The clear-answer screen names the supporters and F waits a bounded window for more answers first (window decided 2026-11-01: 30 s). Section 8.4 |
| R3-3 (settling confinement not monotone) | A `SettleMark` row per counted settling (a small device-signed `SettleStamp`, in the digest set, never folded) and `cp_settled` in every 0.14 checkpoint, copied and checked like `cp_cut`. "On the line" reads `cp_settled`, never `cp_lineage`. Section 7 |
| R3-4 (no first-fold record right after the upgrade) | The migration seeds `cp_seen` for the held base and parent at 0 and sets `seen_ms = 0` on existing rows. Sections 7, 11 |
| R3-5 (a thief's linked puppet device stays counted) | On lost or stolen, vouchees of the dropped device first seen after T are removed with it, listed by name, no toggle (decided 2026-11-01; narrowed by R31-3); older ones are listed with "Remove them too" on. Every removed vouchee joins `cp_settles.devices`. Section 8.6 |
| R3-6 (endorsements not inherited, not traceable) | `cp_endorsed` entries carry the DR id and signer device; inherited from the base minus what the checkpoint dominates; an entry whose signer the writer does not count drops; a settling drops entries signed by, or naming ops of, a dropped device unless its own records saw the op before T. Rule 2 of eligibility reads the carried entries. Section 8.2 |
| R3-7 (witnesses compare different clocks) | The ask carries an AGE (`now_F - T`), each witness answers with the age of its first fold; dates on the chooser come from those ages on F's clock. Section 8.4 |
| R3-8 (chooser gaps) | Two continuous candidates not on one line are ambiguous; "Longer ago, or not sure" on a fresh install is "I don't know"; F asks every member named in any checkpoint content it received (64 per server); an answerer that no longer holds R says `base_unknown` and F sends R. Sections 8.1, 8.4, 9 |
| R3-9 (relay lock counts by ID-1's fold) | Written as track R's follow-up: the relay judges lock writes with the walk (`roster.h` `authority()`), inbox ownership keeps ID-1 (decided 2026-11-01: yes, R2). Seam named. Section 12 |
| R3-10 (a member's lost-or-stolen DR cannot undo what an owner checkpoint folded) | Both written: the residual (section 17) and the owner re-fold by its own `seen_ms` (section 8.3). Decided 2026-11-01: the re-fold (revised by R31-10). |
| LOW | `roster_seen` rows live 30 days after their statement drops; 0.13 contacts re-trade flooded rosters (section 16); a 0.14 owner on a 0.13 relay is warned (section 12); one witness per identity prefers the oldest when its devices disagree (section 8.4) |
| Decision 2 | 30 days everywhere it applies (sections 7, 8.3, 17); the own-kept bound re-sized for 30 days of a standing leader (sections 7, 14) |
| Fresh-install owner gap (REVIEW_REV3 last part) | New section 8.7: an invite or a re-added friend gives the first server id; the join ask carries F's roster; F's `RosterNotice` reaches the room as a hidden sender; F asks members iteratively; the recovery screen says to ask a member for an invite |
| Section 20 | All seven rev 3 decisions moved to Answered; four new open items plus two smaller ones, all decided 2026-11-01 |

## Changes from revision 2

| Finding | Change |
|---|---|
| N1 (H2's key regresses HOL-SEC-079) | The rev 2 order key is gone. The general removal pool stays ordered by signer rank, as today. Outside it, ONE reserved slot per removed standing target, at most 32, holds the removal the signer-rank walk counted first for that target. Literal "best-ranked signer" fails a probe (a signer the walk voids can hold the slot); the walk's choice passes it. The largest roster is 231,705 bytes, under the 262,144 limit. `roster.h` and `roster_vectors.json` change with it. Section 4 |
| N2 (freeze wording) | Counted is empty when the walk leaves no device alive, not "when the best-ranked device removed itself". A thief that does it picks the frozen base until any device ranked above it signs one removal. Section 7 |
| N3 (lost or stolen resurrects what the device removed) | Lost or stolen re-signs every counting removal by the dropped device that the remover first saw before T, and none it saw later. A new local first-seen record for our own identity's removals. Retiring re-signs all of them, as in rev 2. Section 8.5 |
| N4 (equal-depth id lottery) | Stated as a residual with its remedy (the phrase). Section 17 |
| N5 (settling keeps thief checkpoints; honest devices checkpoint on top of them) | Settling is T-based: the state is the newest checkpoint the remover folded before T, plus every op not by the dropped device, plus the dropped device's ops the remover received before T. Descent only grants eligibility, never content. A settling checkpoint confines eligibility to its own line, and it carries the owner's roster, so a child the thief races onto it is ineligible wherever the settling is held. Sections 7, 8.3 |
| N6 (a deep step back deletes members' honest ops) | Each author keeps its own ops until a checkpoint it has held for 7 days dominates them, and they fold again (so the digest re-offers them) after any step back. Section 7. Decision 2 (answered) made it 30 days |
| N7 (`cp_retired` drops still-needed endorsements) | A checkpoint carries `cp_endorsed` (the refs of endorsed ops it does not dominate) and `cp_posts_until`, next to `cp_retired`. Section 8.2 |
| N8 (step 3 reads "retained") | Step 3 reads owner `DeviceRetired` ops HELD in any row kind. A base never needs an endorsement it made redundant. Section 10 |
| N9 (post cut clock backdatable or a bypass) | The post cut clock is `cp_cut`: the clock of the first 0.14 checkpoint in the BASE's lineage, copied unchanged into every child and checked. Lost or stolen writes `posts_until_ms = T`. Section 13 |
| N10 (responders refuse a newly linked device) | A sync ask carries the asker identity's roster when the responder may not know it, or when the responder answered `roster_needed`. Section 9 |
| N11, N12 (relay) | Track R's brief. Section 12 records them; their mechanism lands with track R |
| H1 wording | "Held", never "retained", for endorsements. Section 10 |
| H4 (one timed-out answer) | A rebuild that ran on the 10 s timeout with one identity runs again when a second identity answers. Section 9 |
| Vitalik 2026-11-01 (option c) | "When did you last have it?" on lost or stolen and on every recovery (section 8.1). A device that holds the server settles from its own records (8.3). A fresh install asks members for signed witnesses and takes the newest continuous candidate; ambiguity is a choice of dated restore points with members' names, nothing preselected, "I don't know" = rev 2's rollback (8.4). Restore points and first-fold records (section 7). Posts dated before T stay |
| Found while matching the core | The core's first checkpoint of a server with no base is generation 0 (`checkpoint_json`), so "generation >= 1" cannot mark a 0.14 checkpoint. The marker is `cp_stamped`. Section 7 |
| Rev 2 open decision 1 | Superseded by the witness recovery |

## 0. Summary

- A 0.14 op carries a DEVICE proof next to the master signature (section 6). Its HLC
  counter must sit in that device's lane. The op's identity is its master-signed bytes
  (`CrdtOp::content_hash`, already so in the core).
- A device counts for server authority only if the author's roster counts it under a
  pure verdict (section 4): the phrase's roots, the vouch closure, and removals walked in
  signer-rank order. There is no maturity and no first-sight clock.
- After the CUT, a monotone fact of held ops, an op from a device that is not counted
  folds only when the base already dominates it (section 7).
- Removing a device asks "retiring" or "lost or stolen". Retiring keeps what the remover
  folded. Lost or stolen, and every phrase recovery, ask "When did you last have it?" (T)
  and keep only what predates T (section 8).
- A person whose only device was stolen recovers each server from what members witnessed
  before T (section 8.4), after finding its servers and members through an invite or a
  re-added friend (section 8.7).
- While a recovery is in progress, members keep the server as they held it when they heard
  of the recovery (floor marks), and no member or MLS leaf is evicted (section 8.8).
- A member's lost or stolen device: an owner device reverts that device's own writes, on
  its own only what the member could still write itself and any channel it made public
  after T, everything else only on the owner's confirm (section 8.3).
- The owner's key comes from the founding commit, else the book (section 5).
- Rosters travel member to member inside `op_sync`, in Olm (section 9).
- The relay's join lock stops being a master-key authority (section 12, track R,
  building).
- Channel posts get the same device proof against backfill laundering (section 13).

Build: three tracks plus a track R follow-up; track R itself is committed (section 19).
Decisions: section 20 (all decided).

## 1. The problem

A `CrdtOp` names only its master author and carries the master signature
(`crdt/operations.rs` 61-71). Every device of an identity holds the master key. ID-1 made
the ROSTER the authority over which devices are an identity's, but no server op, no relay
lock and no channel post consults it:

- Ops: `apply_remote_crdt_op` only logs a carrier that is not the author (`node/swarm.rs`
  7676-7690); `handle_envelope_crdt_op` validates the author, never the sender
  (`node/sync_handler.rs` ~3990); `checkpoint_allowed` checks only the anchor owner; digest
  and page answers re-serve an admitted op by its author alone.
- The relay's join lock takes any owner-signed base past its tip as a reset, signed by the
  master key alone; a base at `MAX_N` freezes it; grants are sealed to the master's X25519
  key; the lock never moves on a device removal.
- Channel posts are master-signed, so backfill from a stale replica launders a removed
  device's posts.

So a stolen device, once its roster removed it, can still write a `ServerCheckpoint` of
any state, a `ServerDeleted`, kicks and role changes, freeze or steal the relay's lock,
prove the door, and post as the identity through backfill. AR-02 closed the roster only.

## 2. Requirements

1. **Consensus.** Two replicas holding the same ops and the same roster statements reach
   the same state, retained set and digest, in any arrival order and across a restart.
   One stated exception: an author whose recovery key a master-key holder forged and
   showed some replicas first (AR-15, section 17).
2. **Retiring loses nothing.** An op from a counted device is judged as today. Retiring a
   device, linking one and an owner away for months lose nothing the remover folded.
3. **Lost or stolen keeps what predates T.** What the dropped device did after the moment
   the person last had it stops counting. What it did before, as the remover (or the
   members' witnesses) folded it, stays.
4. **Uncounted devices write nothing undominated after the cut.** That covers a removed
   device, a minted key, a pending join, an unvouched backup that waited out seven days,
   the bare master and a stripped proof.
5. **The owner can be away for months.** No rule here waits on the owner.
6. **The relay changes only where it is a master-key authority today** (the join lock),
   plus the roster compaction it mirrors. It deploys before clients. Rosters travel
   member to member.
7. **Bounded and fair.** Every new table a stranger can fill is bounded and charged to the
   author it concerns (identities are free).
8. **A clean interface to the core** (section 11).

## 3. The design on one page

1. `CrdtOp.dev = Some(DevProof { device, sig })`: the device key over `hollow-crdt-dev1:`
   plus the unchanged `hollow-crdt1` payload.
2. The proof verifies when the signature checks under the key `device` names and
   `hlc.counter % LANES == lane_of(device)`. A failed proof is treated as absent; it never
   makes an op worse.
3. Each op gets a VERDICT: `Counted` (the proof verifies and the author's view counts the
   device, or an endorsement names the op), `Uncounted`, `Missing` (no statements under
   the key that judges this author) or `ProofLess`.
4. The CUT is in force once the replica holds any owner-signed `cp_stamped` checkpoint,
   eligible or not, or a founding op that commits to a key. From then on `op_allowed`
   admits only `Counted` ops; the core drops dominated ops before `op_allowed`.
5. Evaluation is stratified (section 10): owner key, owner view, owner endorsements and
   settlings, checkpoint eligibility, base, member views, fold.
6. Removing a device (section 8):
   - retire: `DeviceRetired` names the ops the remover folded from it;
   - lost or stolen, or a recovery: the person gives T. An owner device that holds the
     server writes a SETTLING checkpoint from its own records; a fresh install takes
     members' witnesses; members' own devices write a `DeviceRetired` limited to T, and an
     owner device reverts what that device wrote inside owner checkpoints (on its own only
     what the member may still write and a channel it made public after T, the rest on the
     owner's confirm).
7. While a recovery is in progress, members sign floor marks naming the base they held;
   the oldest, when all lie on one line, stays eligible until a settling, and no member or
   MLS leaf is evicted meanwhile (section 8.8).
8. `op_sync` trades roster digests and statements with at least two identities
   (section 9).
9. The relay lock and the door move on every device removal (section 12).

## 4. Who counts: a pure verdict (C2, C3, H2, H5, N1, N2)

**The function.** `Roster::authority()` works on the statements verified without a clock
(`reverified()`). It returns `{ key, base, counted, removed, digest }`:

- Roots are the current base's roots exactly as `scope` finds them: `keep`, later phrase
  admissions, or legacy claims in a legacy base.
- No pending join matures and `first_seen` is never read, so the signer set is the
  `founded` closure (roster.rs 867), which is tier 0 of `ranked(false)`.
- **The walk** (C3, R3-1). Candidate removals: in the base, signed by a founded device, of
  a founded device or a consented pending one. Group them by signer and take the signers
  in rank order `(tier, depth, id)`. At its turn a signer is ALIVE only if both hold:
  1. no removal counted for a strictly earlier signer removed it; and
  2. it is in the VALID CLOSURE as it stands at that turn: the roots, plus every device
     vouched by a valid voucher that no removal counted so far removed, or that every
     removal counted so far of that voucher keeps (`keep_vouched`, HOL-SEC-080).
  All removals of an alive signer count, its self-removal included. Ranks never tie (the
  id is part of the rank).
- Then the valid closure as `fold` does it, over every counted removal: a removed
  voucher's vouches count only where every counted removal of it keeps them.

Why clause 2 (R3-1): the founded closure ignores removals, so a removed thief that vouches
a puppet (it holds the master key and signs the puppet's consent) makes a founded signer
nobody removed. Without clause 2 the puppet walks, its removal of the phone counts, and
`counted` goes empty (the freeze of section 7, picked by the thief). When the remover
outranks the thief (the only case in which the remover wins at all), every puppet ranks
below the remover too: depth grows by one per vouch, and a puppet's only vouchers are the
thief and other puppets. So the removal that voids the puppet's voucher is counted before
the puppet's turn. Probes `review3_a_removed_thiefs_puppet_cannot_uncount_the_device_that_removed_the_thief`
and `review3_a_puppet_two_levels_under_a_removed_thief_cannot_remove_the_root` are RED
under revision 3's walk and GREEN with clause 2 (`.team/devproof3/rev31_walk.log`).
- `counted` = valid minus removed. `digest` = `Roster::digest()`.

The result is a function of the statements alone. ID-1's own `fold` (contacts, DMs, the
relay's inbox) is unchanged: there a mutual removal still removes both until the phrase
settles it (probe `rev3_d3_...` asserts both).

**Why rank and not time.** Removals carry no time. A static rank makes a mutual removal
deterministic: the device closer to the phrase wins. A stolen device that ranks ABOVE the
honest one (it is the genesis root and the phone was linked from it) wins for server
authority until the phrase recovery drops it. Between equal-depth siblings, the lower id
wins (N4, section 17).

**When nothing counts (N2).** `counted` is empty when the walk leaves no device alive. A
deep thief can do that: it removes every device above it and then itself. Any device
ranked above it undoes it with one removal, because that device walks first (probe
`rev3_n2_...`). Until then the freeze of section 7 applies and the thief's last base
stands.

**Compaction: reserved slots (N1, replaces rev 2's H2 key).** Today `compacted()` keeps the
96 removals whose signers rank best. A root device that floods junk removals pushes out
the phone's removal of it (H2). Rev 2's fix ranked a removal by its target, which let a
thief flood removals OF the root and push out the root's removal of the thief (N1).
Revision 3:

1. The general pool stays exactly as today: removals by standing signers, ordered by
   signer rank, `MAX_REMOVALS = 96`.
2. Outside it, the walk runs over every held removal (signers and targets standing, the
   pending tier included). For each target it removed, the removal that removed it first is
   RESERVED. The walk takes clause 2 above too (R3-1), judged per tier: a tier-0 signer's
   valid closure grows from the roots only, so tier 0 is exactly `authority()`'s walk; a
   pending-tier signer's grows from the roots plus the consented pending joins.
3. At most `MAX_RESERVED = 32` reserved slots, the shallowest targets first. A walk-first
   removal past the 32 competes in the general pool.
4. `within_caps` (Rust and `roster.h`, the relay refuses a roster over it) becomes
   `removals <= MAX_REMOVALS + MAX_RESERVED`.

Why the walk's first removal and not "the removal by its best-ranked signer": the best
signer can be one the walk voids. A removed sibling X that ranks just above the honest H
signs a removal of C and floods; X's removal holds C's slot, X's flood pushes H's out of
the general pool, and C counts again. Probe
`rev3_n1_a_voided_best_signer_does_not_hold_the_reserved_slot` passes with the walk and
fails with the literal reading (`rev3_best.log`).

What the probes show (standalone copy, `rev3_walk.log`):

- `probe4_the_new_key_keeps_the_phones_removal_of_a_flooding_root`,
  `probe4_a_thief_floods_removals_of_the_root_and_the_roots_removal_of_it_falls_out`,
  `probe4_a_thiefs_puppets_each_remove_the_root_once_and_the_roots_removal_falls_out`:
  all pass.
- `rev3_n1_compaction_is_idempotent_and_keeps_the_walk`: below the reserved cap,
  compaction is idempotent and `authority()` over the compacted roster equals it over
  every statement uncapped.
- Revision 3.1 (`.team/devproof3/rosterprobe31/`, `rev31_walk.log`):
  `rev31_the_compaction_walk_ignores_a_removed_thiefs_puppet`. A removed thief's puppet
  that ranks before an honest device H removes H and floods junk. With clause 2 only in
  `authority()`, the compaction walk still counts the puppet, H's removal of C is not
  walk-first, the flood pushes it out of the general pool, and C counts again. RED with
  clause 2 in `authority()` alone, RED with it in compaction alone (the uncapped check),
  GREEN with both. With both: 45 of 46 roster tests pass; the one failure is
  `probe3_a_...`, which asserts ID-1's fold and is superseded by `rev3_d3`. Swapping in the
  literal best signer still fails I6 (the I6 mutation stays killed).
- The 30 existing roster tests pass. Two assert `removals.len() == MAX_REMOVALS` or `<=`
  it and change to the new cap (`the_largest_roster_fits_on_the_wire`,
  `authz_a_members_flood_never_displaces_a_signer_closer_to_the_phrase`).
- Wire bound (`rev3_n1_the_largest_roster_with_reserved_slots_fits_on_the_wire`): every
  cap full, 128 removals with 16-entry keeps, 231,705 bytes of 262,144. With 96 reserved
  slots it was 305,303 bytes; that is why the cap is 32.

What it does not do: a merge can drop a removal that only became walk-first in the union
(a replica compacted a flood before it held the removal that voids the flooder). The
digest then differs, and the trade (section 9) hands both sides the union, where the walk
is exact again. 0.13 clients never call `within_caps`; a 0.13 relay refuses a roster over
96 removals (only a flooded roster), so the relay deploy carries this change (section 19).

**Compaction: the vouch cap ranks by validity (R31-4, a bug in SHIPPING code).** Today
`compacted()` (main `identity/roster.rs` 734-747, relay `roster.h` ~375-385) keeps each
standing device's first vouch by signer rank as its tree vouch, then the rest by signer
rank, `take(MAX_VOUCHES)`. Removals play no part. A removed device T that ranks before an
honest voucher A signs a vouch for H (A's vouchee), so T's vouch becomes H's tree vouch, and
floods 128 junk vouches. A's vouch of H falls out of the cap, and H is valid only through
void T: H stops counting under `authority()`, in ID-1's `fold` (contacts, DMs) and in the
relay's inbox fold. Revision 3.2:

1. Before capping vouches, run the compaction walk of item 2 above over every held
   statement (uncapped), and the valid closure over its counted removals, seeded with the
   roots plus the consented pending joins (the pending tier, so nothing standing is judged
   by a narrower seed than its own tier).
2. A vouch is VALID when its signer is in that closure and either no counted removal
   removed the signer or every counted removal of it keeps this vouchee (`keep_vouched`).
3. Vouches sort by (valid first, signer rank, the vouch). Each standing device's tree vouch
   is its first vouch in that order, so it comes from its best VALID voucher; the rest
   follow in the same order; `take(MAX_VOUCHES)`.

Probe: `review31_a_removed_devices_vouch_flood_never_uncounts_a_device_another_voucher_holds`
is RED on the rev 3.1 compaction and GREEN with this rule; 46 of 47 roster tests pass with
it, the one failure being `probe3_a_...`, superseded by `rev3_d3` as before
(`.team/devproof3/rosterprobe32/`, `rev32_vouch.log`). The relay's `roster.h` mirrors it
and `roster_vectors.json` gains the flood case. Because the code ships today (contacts and
the relay's inbox fold lose H as well), this item is HOL-SEC-189 and stays
embargoed until the 0.14 release. A 0.13 contact compacts the old way, so for a roster with
a removed device's vouch flood the AR-29 digests differ and re-trade, as for the removal
flood (section 16).

**Building order and idempotence (RC32-10, track I).** The vouch cap ships with its own walk:
rule 1 runs the per-tier walk of item 2, which is a later track I item, so the vouch cap
carries that walk with it (reference implementation `walk_valid` in
`.team/devproof3/rosterprobe32/src/identity/roster.rs`, with `edit32_vouch.py`; the C++
mirror in `roster.h` follows the same function). Rule 3's sort reads validity at each
signer's TURN of the walk, not the final validity: every vouch that made a walk-alive signer
valid at its turn sorts first, so a flood ranked before a voucher that a later counted
removal voids without keep cannot cut it, and compaction stays idempotent. Track I builds
this in `~/dev/wt/t14-ident` (`removal_walk`, `Voids`), with the property test
`compaction_is_idempotent_under_a_vouch_flood` (`compacted(compacted(r)) == compacted(r)`
and `authority()` equal to the uncapped roster's) and the flood and idempotence cases in
`roster_vectors.json` (I21).

**Build note: item 1 as built (track I, 060ca581; HOL-SEC-189 review F1 and F2).** Item 1
above reads as one walk over every standing signer. The build splits it, and this is the
rule of record (`Roster::cap_judge`, `roster.h` mirrors it):

- **Only the tier-0 walk voids vouches.** The walk whose counted removals void a vouch
  (rule 2's validity) takes only removals whose signer is tier 0 of standing (a root's
  closure). A pending-tier signer may be a join the master key alone made, so letting its
  removals void vouches let a master-key pending join plus a junk flood uncount an honest
  linked device (F1).
- **The pending tier seeds, it never voids.** The valid closure is seeded with the roots
  plus the consented pending joins (so nothing standing is judged from a narrower seed than
  its own tier), and the reserved-slot walk of the compaction list's item 2 still runs over
  every standing signer, the pending tier included: a reserved slot only keeps more.
- **Standing over the best `MAX_CONSENTS`.** Standing is ranked over the consents the cap
  keeps (`capped_standing`): past `MAX_CONSENTS` standing devices, only the best ranked keep
  theirs and the rest rank again without the others, so a merge of two rosters judges what
  its compacted self judges (F2: an uncapped consent union broke RC32-10's idempotence
  under a junk flood).

`authority()` itself is unchanged by this note: its signers are tier 0 of `ranked(false)`
(no pending tier), and its walk is clause 1 and clause 2 of section 4 over those.

**Retire and lost or stolen re-sign removals.** Section 8.5.

**What the verdict decides:**

| Device | Counted? | Why |
|---|---|---|
| Linked device | yes, at once | the presenter vouches (HOL-SEC-002) |
| Genesis device, phrase-admitted device | yes | a root |
| Device vouched by a counted device | yes | vouch closure |
| Removed device | no | the walk |
| A removed device that removes the device that removed it | stays removed, its removal does not count | the walk |
| A device a removed device vouched (a puppet), unless the removal kept it | no, and its removals do not count | the walk's clause 2 (R3-1) |
| A fresh key a master-key holder minted (C2) | no | no root, no counted vouch |
| The thief after a phrase recovery (C2) | no | not in `keep` (probe `rev3_d2_...`) |
| Pending join, restored backup in its seven days | no | no maturity (decision 3) |
| Backup that matured by waiting, unvouched | no | the same |
| The bare master id (G1) | only if the statements count it as a device | otherwise `Uncounted` |
| Device of a legacy identity | yes with a legacy claim | the master key signs claims (section 17) |

**Decision 3 framed (M7).** Pending and waited-in devices author no server ops. The person
who notices is one whose ONLY device is a restored backup with nothing to approve it: for
contacts it is a member after seven quiet days; for servers it stays read-only until the
person types the recovery phrase once (`admit_by_phrase`), which makes it a root at once.
The app says so where a server action is refused (appendix A).

## 5. Which recovery key judges an author (C1)

Unchanged from rev 2.

- No pins in checkpoints.
- **Owner of a server founded on 0.14:** when the founder's roster has a recovery key, the
  founding nonce is 64 hex: 32 random hex followed by
  `hex(SHA-256("hollow-server-rk1:{owner}:{r_pub}")[..16])`. The id hashes the nonce
  (`anchor::derive_server_id`), so it commits to the key. The relay and 0.13 accept it
  (at most 64 hex, `join_lock.h` 98-104, `node/join_lock.rs` 84). A legacy founder keeps
  32 hex. The verdict takes the first statements it holds whose `r_pub` matches the hash
  (book, `server_rosters`, or a checkpoint's `cp_roster`, section 8.3).
- **Everyone else, and the owner of an older server:** the `r_pub` this replica's book
  pinned at first sight (AR-15), else its first `server_rosters` row's. A held
  `cp_roster` never picks this key, it only merges under it (`authority::judge_held`):
  anyone holding the owner master key writes a checkpoint, eligible or not, so a
  backdated one's roster under a fresh recovery key would otherwise choose who judges the
  owner at a replica with no row yet (track C review, part A). No statements for the
  author: `Missing`.

## 6. The proof (H1)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevProof {
    pub device: String,   // device peer id; its Ed25519 key derives from it
    pub sig: String,      // base64, over "hollow-crdt-dev1:" + CrdtOp::signing_payload()
}
// CrdtOp gains:
#[serde(default, skip_serializing_if = "Option::is_none")]
pub dev: Option<Box<DevProof>>,
```

- **Minting.** `create_op` signs with the master, then the DEVICE key. `OpSigner` gains the
  device keypair; `install_op_signer` (swarm.rs 7426) passes it at its three node sites and
  `found_on` too. Each site already runs `Hlc::for_device`, so the lane matches.
- **Verifying (stateless, at the door).** The signature checks under `key_of(device)`, the
  id has peer-id shape, and `hlc.counter % LANES == lane_of(device)` (`crdt/hlc.rs` 70). A
  failure makes the copy proof-less.
- **Content id.** `CrdtOp::content_hash()` = SHA-256 of `signing_payload()`, which never
  includes `dev`. Dedup, the equivocation tie-break, the base order and the digest id
  already use it in the core.
- **The best proof wins.** One stored copy per (author, clock, content id). A copy whose
  proof ranks higher (`Counted` > `Uncounted`/`Missing` > `ProofLess`, ties to the lower
  device id) replaces the stored proof in RAM and in `crdt_ops` (the core's row write
  becomes an upsert of `op_json` when the rank rises).
- **Lane grinding.** A ground key with an honest lane re-proofs an honest op as
  `Uncounted`; it loses to the honest copy wherever both are held; a replica holding only
  the ground copy parks it until the digest brings the honest one.
- **Equivocation.** Variants at one (author, clock) rank by verdict, then by the lowest
  content id.
- **0.13 strips proofs** on re-serialize. The op parks at 0.14 replicas until a proofed
  copy arrives through the digest.

## 7. The cut, the one rule, eligibility, and what a step back needs

**The cut is monotone.** It is in force once the replica HOLDS either:

- any owner-master-signed `ServerCheckpoint` whose state has `cp_stamped` (the 0.14 shape;
  `cp_generation` is 0 for the first checkpoint of a server that had none, so it cannot be
  the marker), eligible or not;
- a founding op with a committing 64 hex nonce.

The core drops a checkpoint at or below the base's parent. So one row survives for the cut:
of every owner-signed stamped checkpoint the base order would drop, the one with the lowest
(clock, content id) is kept as a `CutMark` row, stored and in the compared digest set, never
folded. A minimum does not depend on arrival order. Before the cut, ops are judged as today.

**The rule.** After the cut, `op_allowed` begins with
`if self.cut && self.verdict(op) != Counted { return false }`. The core drops dominated ops
at the door first (`fold.rs` `door` and `plan`), so an undominated op from a device that is
not counted never folds, whatever its date.

**What is parked (H3).** A refused op is parked only if the same `op_allowed` admits it with
the device clause skipped, and its author has a `member_record` span. Anything else is
dropped unstored. Parked ops use the core's one parked state (`RowKind::Parked`, 30 days,
`PARK_MS`), inside the author's quota group, and are judged again at every rebuild, which a
change of that author's verdict triggers.

*Build note (lead decision 11-05).* A refused op whose rules refusal a roster may still end is
kept as the core keeps a refused op (a row it was: parked; else held), never dropped: its
device reads `Missing` or `Uncounted`, its author is known, and either an op that could admit
others (an admission, a role grant, an unban, a label, a channel, a setting) was skipped
before it for a roster, or it is the replica's own admission (the silent re-ask of the F1
cascade reads it), at most one parked own admission per server. A refusal for a missing proof
stays dropped (the proven copy comes by the digest).

**Eligibility (H1, N5, R3-3, R3-6).** A `cp_stamped` owner checkpoint is ELIGIBLE when:

1. its writer device is `Counted` in the owner's view; or
2. a held owner `DeviceRetired` that is itself `Counted` names it, or an eligible
   checkpoint's `cp_endorsed` carries an entry naming it whose DR signer is `Counted`
   (retire, and its carry, section 8.2); or
3. its content id is in `cp_lineage` of an eligible checkpoint (descent); or
4. it is the FLOOR of section 8.8, or an ancestor of it (R31-2), with the confinement
   stated there;

and, when the replica holds a counted settle mark (below), it is ON THE LINE of the
greatest one: its `cp_settled` names that mark, or it is that settling or one of its
ancestors (the mark's pinned parent and that parent's `cp_lineage`). Rules 2 and 3 read
other eligible checkpoints, so eligibility is the least set closed under them, computed
over held checkpoints before the base is chosen (descent already works this way); it never
reads the base. Rule 4 is computed after rules 1 to 3 (section 10, step 4). Two counted
marks whose settlings lie on different lines: the greater in base order confines
eligibility, and the owner device that holds both settles again on top of it with both
dropped-device sets and the earlier T (section 8.3).

**Settle marks (R3-3, R31-5).** Revision 3 applied the line rule "when the replica holds a
settling", but the core drops a checkpoint at or below the base's parent, so two
generations later some replicas held the settling and some did not, and the `cp_lineage`
test expired after 64 generations. The line rule is a fact of held marks, like the cut:

- A settling checkpoint carries `cp_settles.stamp`, a `SettleStamp { server, parent,
  generation, devices, t_ms, sigs }`. The SETTLING ID is SHA-256 of
  `hollow-settle-id1\n` and the five fields before `sigs`, with no signer in it (R31-5).
  Each entry of `sigs` is `{ device, sig }`, a DEVICE key over `hollow-settle1\n` and the
  settling id, so a stamp verifies without the checkpoint's state, and another device can
  add its signature to the same settling without changing its id.
- **Each signature is its own op (RC32-4).** `CrdtPayload::SettleSign { stamp }` is
  authored by the owner master with the signing device's proof (`dev`, section 6), and its
  `stamp` carries exactly one entry in `sigs`, whose `device` is the op's `dev.device`. The
  settling's writer publishes one with the settling checkpoint; every co-signer (section
  8.5) publishes its own. So the signatures ride the ordinary op transport: the digest
  compares them by op id at their own fold position, they are in `served_log`, deduped by
  content id, charged to the owner's quota group, and 0.13 keeps them as unread (bounded per
  author). Revision 3.2 merged signatures into one row the digest had no entry for, so two
  replicas holding different signature sets compared equal and never traded (RC32-4).
  The review proposed a synthetic digest entry per (settling id, device); an op gives the
  same per-signature entry with no new sync field and no new digest code.
- **Ingest.** `plan` classifies `SettleSign` before the door and before `op_allowed` (it is
  never folded, `apply_payload` writes nothing, `ServerUpdated` in both match blocks). It
  is stored as a `RowKind::SettleSign` row only when the author is the server's owner (section
  5), the one signature verifies over the settling id, `stamp.server` is this server, and
  the parent checkpoint op the stamp names is held or arrives with it; otherwise it drops
  unstored. Of two `SettleSign` ops for the same (settling id, device), the lower
  (ms, counter, content id) is kept, so replicas converge on one row per pair. Every answer
  and every live send that carries a `SettleSign` carries its parent op too.
- **The pin.** The parent op is kept as a `RowKind::SettlePin` row (one stored copy per
  content id, exempt from the core's drop at or below the base's parent), in `served_log`
  and in the digest by its own op id, and evicted with the last `SettleSign` naming it. A
  replica that got the signatures after the core dropped the settling therefore still holds
  the parent that counting clause 2 reads.
- **The mark** of a settling id is the set of held `SettleSign` rows with that id (at most
  8 signatures: counted signers first, then by device id). Kept when the core drops the
  settling checkpoint itself.
- A mark COUNTS when (section 10, step 3):
  1. at least one of its signers is `Counted` in the owner's view; and
  2. its pinned parent verifies as a base (`base_of`, owner-signed, its content id is the
     stamp's `parent`), and the stamp's `generation` is the parent's generation plus one.
  The second clause ties a mark to a parent that verifies as a base. It does NOT stop a
  counted device from minting a stamp of any generation: that device's identity holds the
  owner master key, so it can sign a parent checkpoint of any generation itself, and
  `base_of` does not check that parent's own parent (RC32-9). What ends such marks is the
  removal: once the device is uncounted, a mark only it signed stops counting at every
  replica that holds the removal, and the eviction below charges marks per signing device,
  so one device's flood cannot push out other signers' marks.
- Retiring the device that signed a settling keeps the mark counting: retire co-signs every
  held stamp the retired device signed, and lost or stolen co-signs those first seen before
  T (section 8.5). The retire's sync round runs first, so the remover holds every signature
  the server's replicas hold (they are ops in the digest set). The review also offered "a
  counted owner DR naming the settling"; co-signing covers the same case with no new DR
  field.
- Bound: at most 32 settling ids per server, 8 signatures each, about 1 KB per signature
  plus the pinned parent. Past 32: marks with no counted signer go first; then each mark is
  charged to its LIGHTEST counted signer (of its counted signers, the one that signed the
  fewest held marks, ties by device id), and the device charged the most marks loses one
  first, as `trim_kept` charges authors in `crdt_resync` (RC32-9); within one device, the
  smallest (generation, settling id) first; the charges are recomputed after each eviction.
  So a mark goes only when every counted signer it has is over its share (R33-6): a stolen
  device that co-signs the honest settling at a replica still counting it (the inner
  signature covers only the settling id) never drags that mark into its own 32 jumped
  marks.
  Pinned parents count toward a 32 MiB per-server budget, inside the core's per-device
  ceiling, evicted with their marks. Each choice is a function of the held marks and
  statements, so two replicas that traded digests hold the same marks. A thief's puppets
  can fill slots only while counted, and any replica that holds the honest settling also
  holds the removal (its `cp_roster`) that uncounts them, so their marks go first there.

The core's own rule stays as well: the parent must be held at generation minus one
(`plan`'s `eligible`). A generation-0 checkpoint of 0.13 is eligible as today, below any
0.14 one.

Descent gives eligibility, never content. A thief checkpoint written after T stays in an
honest lineage as an ancestor, but the settling checkpoint's state replaces what it
decided (section 8.3). That is what closes N5: the honest phone that checkpointed on top of
the thief's base while nobody knew does no harm once the person says when they last had
the laptop.

**The freeze (N2).** When the owner's view counts no device, no owner checkpoint loses
eligibility through the device rule:

- after a self-removal, checkpoints by a device that removed ITSELF stay eligible (the
  removal names its own signer, so this is pure). If a thief emptied the walk (section 4),
  it picked that base; any device above it ends the freeze with one removal;
- for `Missing`, the rebuild waits for the owner's roster and the state stays at its last
  fold.

**`cp_lineage`, `cp_cut` and `cp_settled`.** Every 0.14 checkpoint carries:

- `cp_lineage`: the content ids of its last 64 ancestors, nearest first. `cp_lineage[0]`
  equals `cp_parent`, and where the parent is held, the rest equals the parent's
  `cp_lineage[..63]`. A mismatch makes the checkpoint no base (`base_of`).
- `cp_cut`: the clock of the first `cp_stamped` checkpoint of its lineage (its own clock if
  its parent is not stamped or it has none), else copied unchanged from the parent and
  checked the same way. Section 13 reads it.
- `cp_settled` (R3-3): the stamp id of the newest settling on its line. A settling sets it
  to its own stamp id; every other checkpoint copies its parent's (empty before the first
  settling). Where the parent is held, a mismatch makes the checkpoint no base (`base_of`),
  as for `cp_cut`. A child the thief races onto a chain after a settling copies an older
  `cp_settled` or forges the new one; the first is off the line, the second is a child of
  the settling and its writer is uncounted wherever the settling's `cp_roster` is held.

**First-fold records and restore points.** Each replica, per server:

- `cp_seen(server, content id, first_fold_ms)`: when this replica first folded each owner
  checkpoint as its base. Local, never synced, kept for the base's lineage (64) and the
  restore points.
- RESTORE points: stored rows (`RowKind::Restore`, never folded, never in the digest, served
  only to a witness ask, section 8.4). Of the checkpoints this replica folded as its base,
  it keeps the content of the newest and the oldest first folded in each window: the last
  day, 1 to 7 days, 7 to 30 days, and older. That is at most 8 rows, inside the per-device
  ceiling. A thief that checkpoints hourly fills only the newest windows, and only with
  checkpoints folded after T.
- Every op row gains `seen_ms`, when this replica first stored it (local, additive column,
  never updated).
- **The upgrade (R3-4).** The 0.14 migration seeds `cp_seen` for the held base and its
  parent with `first_fold_ms = 0`, and sets `seen_ms = 0` on every existing op row. Both
  read as "before any T", so a lost or stolen removal in the first days after the upgrade
  restores the pre-upgrade base plus everything held, never the founding op. The cost is
  stated in section 17: for a T before the upgrade, nothing tells what the device did
  between T and the upgrade, and it stays.

**Authors keep their own ops (N6, decision 2).** A step back to an older checkpoint must
not lose what members did. Each replica keeps every op authored by its own identity as a
`RowKind::Own` row (stored, not folded, not in the digest) for as long as the checkpoints
that dominate it were first folded here less than 30 days ago (decision 2). When a base
change leaves such an op undominated, the core's `plan` classifies it `Fold`: it folds, it
enters the retained set, and the digest re-offers it to every replica that stepped back
too.

Bound, re-checked for 30 days: the standing leader authors almost every admission and
join-lock move, and a `JoinLock` op with its sealed grants weighs several KB (checkpoint
design section 8). A busy server at the 512-identity cap with a few hundred joins, leaves,
lock moves and moderation ops a day gives the leader on the order of 5,000 to 10,000 ops a
month, so rev 3's 4,096 ops and 16 MiB was below an honest leader's month. Revision 3.1:
**16,384 ops and 64 MiB per server**, inside the core's per-device ceiling; over it, the ops
whose dominating checkpoint was first folded longest ago go first. The build measures the
leader's 30 days on the checkpoint design's busy-server fleet run and raises the bound if an
honest leader can reach it. These rows live only on the author's own devices.

**The honest cost.** A retired device's op that the remover had not folded when it wrote
the list, and that no checkpoint dominates, is refused. So is everything a lost or stolen
device did after T, and what it did before T that the remover never received. Members heal
admissions by the core's silent re-ask (`refused_own_admission`). Anything else shows: a
nickname or channel rename that had only half spread reverts.

## 8. Removing a device

### 8.1 The question, and T

One dialog (AR-34; `lib/src/ui/settings/device_management_shared.dart`, `removeDeviceFlow`
90-125, `RemoveDeviceDialog`) with two options, nothing preselected, Remove disabled until
one is picked: "I'm retiring this device" and "It was lost or stolen". Picking lost or
stolen asks "When did you last have it?". Copy: appendix A.

T is the EARLIEST moment of the answer, so a vague answer undoes more, never less:

| Answer | T |
|---|---|
| Less than an hour ago | now minus 1 hour |
| Earlier today | local midnight today |
| Yesterday | local midnight yesterday |
| In the last 7 days | now minus 7 days |
| In the last 30 days | now minus 30 days |
| Pick a date and time | that moment |
| Longer ago, or not sure | the first-fold time of the oldest restore point held, per server; on a fresh install, which holds none, 0, and every server's outcome is "I don't know" without a chooser (R3-8; T = 0 for posts too, decided 2026-11-01, section 20) |

- A phrase recovery asks the same question once for every device it does not keep
  ("When did you last have your other devices?"). It never asks retire or lost: every
  dropped device is lost or stolen.
- The devices the dropped device added are handled by section 8.6 (R3-5) with the same T.
- FFI: `revoke_device(device_peer_id, mode: RemoveMode)` with
  `RemoveMode::{Retire, Lost { t_ms }}` (`api/network.rs` 1868, FRB codegen);
  `NodeCommand::RevokeDevice` carries it. The recovery FFI gains `t_ms`.

### 8.2 Retiring: `DeviceRetired`

```rust
CrdtPayload::DeviceRetired {
    device: String,     // the device that stops counting
    ops: Vec<OpRef>,    // at most 256, sorted by (ms, c, h)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    posts_until_ms: Option<i64>,  // section 13
    #[serde(default, skip_serializing_if = "Option::is_none")]
    restore: Option<String>,      // a member's lost-or-stolen DR only: its restore checkpoint
                                  // (section 8.3, R31-10); it endorses nothing
}
pub struct OpRef { pub ms: u64, pub c: u32, pub h: String }  // the op's HLC and content id
```

Order of steps on the remover, per server where the device has ops:

1. One `op_sync` round with two distinct member identities (M4).
2. `DeviceRetired` chunks naming every op of that device the remover FOLDED and the base
   does not dominate (the base and its parent included, if that device wrote them).
   Parked, held, own-kept or unread ops are never listed (C2). `posts_until_ms` = the
   newest timestamp among that device's posts the remover holds.
3. If our identity is a mod or above there, move the lock (section 12).
4. Re-sign the device's counting removals (8.5), then sign and publish the removal.

Validity and effect:

- The `DeviceRetired`'s own verdict must be `Counted`; `device` must appear in the
  author's statements; every named op must have `op.author` = the DR's author. Endorsement
  is direct only: a DR from a device that is itself only endorsed endorses nothing.
- A named op whose proof verifies for that device and whose content id and HLC match reads
  as `Counted`. A named owner checkpoint is eligible.
- `apply_payload` writes no state field except the carried sets below. It never gates a
  role.

**Carried endorsements (N7, M1, R3-6).** Every 0.14 checkpoint state carries:

- `cp_retired`: the ids of the `DeviceRetired` ops its writer folded since its parent. A DR
  is dominated when the base or its parent lists it.
- `cp_endorsed: Vec<Endorsement>` with `Endorsement { dr, by, device, refs }`: the DR's
  content id, the DR's signer device, the retired device, and the refs of ops it names
  (owner checkpoints included) that this checkpoint does NOT dominate.
  *Build note:* an entry also carries `author`, the DR's author identity, since rule 3 and
  the readers judge `by` for that identity and a ref names an op of it.
- `cp_posts_until: Vec<PostsUntil>` with `PostsUntil { device, until_ms, dr, by }`: the
  newest post window per device and the DR (or settling) that set it.
  *Build note:* an entry also carries `author`, as an `Endorsement` does, so rule 3 judges
  `by` for that identity.

The writer builds both carried sets by four rules:

1. **Inherit** the entries of its base, minus refs this checkpoint dominates.
2. **Add** entries from every DR it holds and counts that the base does not carry.
3. **Drop** every entry whose `by` its view does not count: a removed signer's
   endorsements end with it.
4. **A settling** (section 8.3) also drops every entry whose `by` is a dropped device, and
   every ref to an op BY a dropped device unless the settler's own records hold that op
   with `seen_ms < T`; it sets `until_ms = T` for each dropped device.

At most 4,096 refs (past it the oldest by clock go, and those ops need a fresh endorsement
or a proof) and 16 post windows per author identity, 4,096 in all (the smallest go first).

Readers: an op that an entry of the base names reads as `Counted` when its proof verifies
for `device` and the entry's `by` is `Counted` in the reader's view (section 10, step 6).
Eligibility rule 2 reads the entries of eligible checkpoints (section 7). So a replica whose
base dropped a DR as dominated still reads its endorsements and post window from the base,
across any number of generations, and an op it names that arrives later folds there too. A
base never needs an endorsement it made redundant: an op it dominates drops at the door
before the verdict is asked.

Why provenance (R3-6): revision 3 wrote refs only from DRs the writer held, so a writer
whose base already listed the DR carried nothing, and the endorsement was gone one
generation later. Copying the parent's set alone would let any counted owner device (a
thief before its removal) write arbitrary refs, including content ids of ops it signs later
(the id excludes `dev`), and a settling or a witness-picked base would carry them on. Rule 3
ends a removed signer's entries; rule 4 ends every entry that would let a dropped device's
unseen op count. What remains is a counted owner device writing entries it attributes to
another signer, which is the ID-1 model (a counted device may write any checkpoint), and
lost or stolen removes it.

### 8.3 Lost or stolen, on a device that holds the server

**For a server our identity OWNS**, an owner device that holds it writes a SETTLING
checkpoint. Order:

1. One `op_sync` round with two distinct member identities, with the base reference set to
   the restore point R below, so answerers send what R does not dominate (members' own-kept
   ops included). An answerer that no longer holds R answers `base_unknown`, and the asker
   sends R's content with its next ask to that answerer (R3-8, section 9).
2. If our identity is a mod or above, move the lock (section 12).
3. Sign the removal (and the re-signed removals of 8.5) into our roster locally.
4. Write the settling checkpoint, one owner op:
   - **R** = the newest checkpoint whose content this device holds (base, parent, restore
     rows) with `first_fold_ms < T`, else the founding op or generation 0.
   - **State** = the core's fold of R as the base plus every op this device holds or got in
     step 1, judged by the ordinary rules, except that an op proofed by a dropped device
     counts only if its `seen_ms < T` here. The founding op of a server a dropped device
     founded is the exception (HOL-SEC-221): the one first stored here always counts, since
     R stands on it or names its owner; any other founding op of the id keeps the rule.
   - **Shape** = a child of our CURRENT base (generation plus one, `cp_parent` and
     `cp_lineage` from it, `cp_cut` from it), so it is the greatest eligible checkpoint and
     every checkpoint on its line stays eligible by descent.
   - **Carries** `cp_settles: { devices, t_ms, stamp }` (the `SettleStamp`, section 7),
     `cp_settled` = its own stamp id, and `cp_roster`: our identity's compacted roster,
     which holds the new removal. Every replica that holds the settling also holds the
     removal (merged into its view at ingest; each statement verifies alone), so a child the
     stolen device races onto the settling is ineligible there, and its settle mark keeps
     the confinement after the checkpoint itself is dropped.
   - `devices` = the dropped device plus every vouchee removed with it (section 8.6).
   - The carried sets by rule 4 of section 8.2: `until_ms = T` for each dropped device, no
     entry signed by one, no ref to its ops this device did not see before T.
5. Publish the roster change (`announce_roster_change`, `show_relay`, the server room
   notice, section 9), and send the settling with a `DoorGrant` of the moved door
   directly to every master that is a member in the settling's state and was not in the
   pre-settling base (a shell, section 8.8, R34-2). F's settling (section 8.4) does the
   same.

What it keeps and drops:

- Everything the server decided before T, from the checkpoint content this device folded
  before T. A checkpoint the stolen device wrote before T stays: that was the owner's own
  device then (ID-1's model).
- Everything other members and our kept devices did, before and after T.
- The dropped device's ops this device received before T.
- Not: anything the dropped device wrote after T, or before T but never received here.
- An honest sibling's ordinary checkpoint written on top of a thief base before it knew is
  superseded: it is not on the settling's line (section 7), and its own ops are own-kept on
  that sibling and fold again.

Restore granularity: R can be up to one window older than T. Ops in between come back from
their authors' own-kept rows (30 days, decision 2) and from every replica's retained and
dormant rows; for a T more than 30 days back, an op only a dropped checkpoint covered and
every author has already let go is lost (section 17).

Two settlings at once (two siblings removing two devices): the greater one confines
eligibility (section 7). The owner device that holds both writes a new settling as a child
of the winner, with both device sets and R taken before the earlier T.

**For a server our identity is only a member of**, our remaining device writes a
`DeviceRetired { device, ops, posts_until_ms: Some(T), restore }` after the sync round,
where `ops` are the dropped device's ops it FOLDED with `seen_ms < T` and `restore`
(R31-10) is the content id of the newest checkpoint this device first folded before T (its
own `cp_seen` and restore rows, the same choice a witness makes). That is not blind: it is
this device's own fold, dated by its own clock. Vouchees removed with it (section 8.6) get
the same DR, one per device.

**What a member's DR cannot undo (R3-10, decided 2026-11-01: the owner re-fold).** The DR
reaches only ops nothing dominates. A stolen mod device's kicks, bans and role changes
after T that an owner checkpoint folded before the member noticed sit inside the base and
never reach a verdict. The owner re-fold covers them:

Revision 3.2 re-folded the WHOLE state from R, which let any member roll a server back:
every member retire set `posts_until_ms` and so triggered it, an absent `restore` took the
deepest reach, and a re-fold from R undid every op that checkpoints after R had dominated
and that only their authors' own-kept rows still held, so a ban by an offline mod or an
admission by an offline admitter was undone (RC32-3). Revision 3.3, decided by Vitalik
(2026-11-04): a re-fold reverts ONLY what the member's own dropped device did. Revision 3.4
makes sure that device really is gone (R33-2), and, decided by Vitalik (2026-11-04, item
20, option (c)), reverts on its own only what the member could still write itself; the
rest waits for the owner. Revision 3.5, decided by Vitalik (2026-11-04, item 21): the one
access revert that does not wait is a channel the dropped device made public after T
(Unpublish, below).

- **Trigger.** An owner device holds a counted member DR with `restore` set (a member's
  lost-or-stolen DR, never a retire), and all of these hold:
  1. `restore` is the base or in the base's `cp_lineage`;
  2. this owner device's view of the DR author's roster (`server_rosters` merged with the
     book, the function step 6 of section 10 uses) does NOT count `device` (R33-2). The
     verdict is roster-only (section 4), so a DR uncounts nothing by itself; a DR naming a
     device its member still counts re-folds nothing;
  3. `lane_of(device)` differs from `lane_of` of every other device this owner device's
     view COUNTS for that author (R34-4). A removed device shares only writes that are
     being dropped anyway. Revision 3.4 compared every device in the author's statements,
     so a ground key the stolen device vouched into its own lane (about 2^24 key
     generations) blocked the re-fold of the very device it stole;
  4. no entry of the base's `cp_refolded` SUPPRESSES the pair (the DR's author, the DR's
     `device`) (below, R33-7).

  Otherwise nothing is re-folded; the DR still refuses the dropped device's undominated ops
  as every DR does. The next owner checkpoint this owner device writes is then a RE-FOLD.
- **T is read only on the member's clock (R31-10).** The member named its own restore
  checkpoint and its own before-T ops; the owner device never compares T with its own
  `cp_seen` or `seen_ms`, since the two clocks can differ by hours (R3-7's skew). The one
  comparison with T, Unpublish's, sets the dropped lane's own HLC time against the DR's
  `posts_until_ms`, both from the member's devices.
- **R** = the checkpoint the DR's `restore` names, when this owner device holds its
  content; otherwise the nearest older checkpoint on the base's `cp_lineage` whose content
  it holds. R is never older than the oldest checkpoint of the base's lineage that this
  owner device first folded within the last 30 days (both times on the owner's clock);
  an older `restore` is clamped to that one. R must be `cp_stamped`; a 0.13-shaped R (no
  `Stamps`) gives every element R holds the stamp `covers` (R33-10).
- **The dropped lane's writes.** Two kinds, both limited to stamps `s` with `s.actor` = the
  DR's author and `s.counter % LANES == lane_of(DR.device)` (`crdt/hlc.rs`), whose
  (`s.physical_ms`, `s.counter`) is no `OpRef` the DR names:
  - ELEMENTS: every stamped element of the base's state whose winning stamp is such an `s`
    and newer than R's stamp for the same element (or R lacks the element). The stamped
    elements are every `AdminLwwReg` (name, roles, nicknames, `twitch_usernames`, storage
    pledges, settings, role permissions, bans, mutes, channel grants, the join secret) and
    every field of the core's `Stamps` (a channel's `created`, `exist` and each channel
    field, pins, a label's `created`, `exist` and `fields`, label assignments, emotes,
    stickers, layout).
  - MEMBERSHIP EVENTS (R33-3): every `member_events` event (an `Admit` it answered, a
    `Remove` it made by a kick or a ban, the author's own `Leave`) whose `at` is such an
    `s` and that R's record for that member does not hold (`members::holds`). Spans and
    `members` are DERIVED from these events (`crdt/members.rs` `derive`;
    `ServerState::record_event`), so membership is reverted only through the events, never
    by editing a span.
- **Classes (decision 20, option (c); decision 21).** Each write is classed by one pure
  function, `refold_class(author, write, base, r, dr) -> Auto | Unpublish | Review`. A unit
  test pins every `CrdtPayload` arm and every `Stamps` field to a class or to Excluded by
  an exhaustive match, as `dominance.rs` does, so a new variant or field fails to compile
  until it is classed. One write is one unit: a ban (its register and its `Remove` event),
  a channel's or label's existence with its sub-stamps, and a channel's `public` unit
  (`public`, `set`, `set_vis`, `set_labels`, which one `ChannelPublicChanged` writes
  together).
  - EXCLUDED (no state element a re-fold could revert): `ServerCreated`, `ServerCheckpoint`,
    `JoinKeySet` and `ServerDeleted` (owner-only, so never a member's stamp), `JoinLock`
    (the lock moves on its own at every removal, section 12), and the 0.14 variants
    `DeviceRetired`, `FloorMark` and `SettleSign` (never folded) (R34-10).
  - REVIEW, whatever the author's role (the kinds the decision names):
    1. membership: every membership event above (admissions it answered, kicks, the
       `Remove` of a ban, the author's own leave);
    2. moderation: `banned_members`, `muted_members`, for any member;
    3. roles: `roles` of any member, the author's own included, and `role_permissions`;
    4. another member's registers: `nicknames`, `twitch_usernames`, `storage_pledges` and
       label assignments (`Stamps.assigned`) of any member other than the author;
    5. access: `channel_grants`; a channel's `visibility`, `vis_labels`, `posting` and
       `post_labels` stamps and its `public` unit unless it is Unpublish; a label's
       `fields` (they hold its `access` flag); any assignment of an access label, the
       author's own included. So a revert never reopens a restricted channel as public,
       never lifts a restriction and never opens joins without the owner;
    6. existence: a channel's, label's, emote's or sticker's `created` or `exist` stamp,
       either way (a revert that deletes something or brings it back);
    7. settings: every `settings` key outside the AUTO allowlist below, the join gates
       (`is_private`, `max_members`, every `twitch_*` key) among them, and any key a later
       build adds (R34-10: `setting_allowed_for` ends in `_ => MANAGE_SERVER`, so a
       permission match would class a future access setting AUTO).
  - UNPUBLISH (decision 21), the only access revert that runs without the owner: a
    channel's `public` unit when all of these hold:
    1. the base shows the channel effectively public (`ChannelInfo::effective_public`);
    2. its winning `public` stamp is a dropped-lane stamp `s` as above, with
       `s.physical_ms > DR.posts_until_ms` (T, on the member's own clock). A stamp at or
       before T is REVIEW: a thief that backdates lands on the list, never in an automatic
       revert of what the member did before T;
    3. the ordinary revert of the unit (R's values and stamps, then the held ops on it,
       minus the dropped device's ops the DR does not name) leaves the channel not
       effectively public. Otherwise R already had it public and nothing this device holds
       turned it off, so as far as this replica can tell the dropped lane did not turn it
       on, and the unit is REVIEW. (Every visibility write also raises the `public` stamp,
       `close_if_restricted`, so the lane's winning `public` stamp can come from a
       visibility write on a channel that was already public; this clause judges by the
       result, not by the op kind.)
    No role condition and no review slot: Unpublish removes no member's access (below), so
    it gives the author nothing and need not wait for anyone.
  - AUTO: a setting on the allowlist (`server_avatar`, `server_banner`, `description`,
    `is_nsfw`, `max_file_size_mb`, `relay_catchup_secs`, `voice_text_chat`), the server
    name, a channel's `name`, `slow`, `media` and `voice`, pins, the layout, the author's
    own nickname, Twitch name and storage pledge and its own toggle of a cosmetic label,
    each only while `may_write_now` holds: `op_allowed` on the base passes a synthetic op
    by the author, at the re-fold checkpoint's clock, that writes R's value of that element
    (`op_allowed` is a match with predicates, not a table, so the class calls it rather
    than sharing a table; R34-10). A revert there gives the author nothing it could not
    write again itself. Every write that fails `may_write_now` is REVIEW. The role is read
    in the base, which the dropped lane cannot have raised: no member changes its own role
    (`role_change_allowed` needs the actor to outrank the target) or its own role's
    permissions (`RolePermissionsChanged` only below the author's role).
- **What the re-fold checkpoint does.** It reverts every AUTO and every UNPUBLISH write at
  once: the element is set to R's value and stamp (absent when R lacks it), and then every
  op this device holds or gets in an `op_sync` round based at R that targets the element is
  folded on top by the core's ordinary rules, except the dropped device's ops the DR does
  not name. Every REVIEW write stays exactly as the base has it. The checkpoint writes the
  pair's `cp_refolded` entry (below) with the REVIEW items and the Unpublish record, and
  pins R and the DR.
- **How a revert applies** (an AUTO or Unpublish one at the re-fold, a REVIEW one on the
  owner's confirm):
  - a register or a `Stamps` field: as above;
  - membership events (R33-3): the events are removed from the member's record and the
    record is re-derived through the same path `record_event` takes, factored out of it as
    `ServerState::rederive(master, events, at)`: spans by `derive`, the `members` map,
    `join_lock.note_removal` when a span closes, and the clause that voids what a member
    held before a later span start. Consequences of `derive`: an admission only those
    events opened is gone (R's record stands); a span a removed `Remove` closed is open
    again. A re-opened span's role comes back as `Member`, or as R's role where R dates one
    above `Member` inside that span AND the item names it ("comes back as {role}", R34-8);
    its other per-member registers (nickname, Twitch name, pledge), which the removal
    cleared, take R's values where R dates them inside that span. Because every later
    event re-derives from the same event list, the next admission or removal of that
    member keeps the revert (R33-3). A membership item is skipped (it stays) when that
    member's record holds any event newer than the listed one, so an undone kick never
    re-opens an old span over an honest rejoin; a ban unit is skipped when either its
    register or its `Remove` event changed (R34-8);
  - existence (R33-10, R34-7): reverting a channel's or label's existence restores R's
    whole entry (`ChannelInfo`, `LabelInfo`) and resets every sub-stamp of it to R's, then
    folds every held op on each sub-element, so a newer honest rename held anywhere lands
    again instead of reading as dominated. Access fields are the exception. Undoing a
    channel's DELETION brings it back with `visibility` and `posting` at `AdminPlus`, no
    label gates and not public; each access sub-stamp (`visibility`, `vis_labels`,
    `posting`, `post_labels`, `public`, `set`, `set_vis`, `set_labels`) stays at the
    base's, and no held op is folded onto those fields. `ChannelRemoved` keeps the
    sub-stamps but drops the values (`server_state.rs`, its apply arm), so an honest
    restriction written after R is gone by the time of the confirm and the newest honest
    access cannot be known; the most restrictive value exposes nothing. The item says the
    channel comes back for admins only, the owner opens it again by hand, and its subgroup
    is reconciled as for any restriction. Undoing an ACCESS label's deletion brings the
    label back with none of the assignments the deletion stripped (`LabelDeleted` writes
    each strip at its own stamp, so they belong to that write); a cosmetic label's come
    back as R had them. Where R lacks the entry (undoing a creation), it is removed with
    its sub-stamps.
- **Unpublish and the access ladder (decision 21).** Checked against `crdt/server_state.rs`
  and the node's readers of `is_channel_public` and `effective_public` (t14-cover
  b68d97cf): `can_see_channel_at` and `can_post_in_channel_at` never read the flag;
  `channel_backfill_allowed_from` and `sync_partner` need membership; `channel_readable_by`
  reads the flag only to let a NON-member read. An effectively public channel is
  unrestricted (`effective_public` requires `!restricted()`), and Unpublish touches no
  visibility, posting, label or grant field, so the channel has no subgroup before or
  after (`reconcile_subgroups_for_server` acts only on restricted channels), and every
  member gets the same see, post and read answer as before. What stops:
  - guests' reads: the public list (`PublicChannelListRequest`, `RequestPublicChannels`),
    `PublicChannelSyncRequest`, the public half of the `FileRequest` arm's gate, and the
    route kept for hidden guests in `run_event_loop` (`note_heard`);
  - plaintext sending: posts, edits and file headers (the `is_channel_public` branches of
    `message_ops` and `file_handler`) go through MLS in the server group, which every
    member already holds. A member's plaintext post still in flight from a replica that
    has not folded the re-fold is refused live where it has (`public_frame_accepted`) and
    arrives by channel sync.
  The writing owner device tells guests the channel closed through the path
  `tell_guests_if_closed` takes after a visibility change.
- **The owner's review (decision 20).** Each re-fold writes one `cp_refolded` entry for the
  pair (shape below). An entry is UNANSWERED (listed or waiting) or ANSWERED.
  - **Items.** `review`: one item per REVIEW write, `{ key, stamp }` (the element or event,
    and the dropped lane's stamp on it), at most 256, the newest first; past 256 the entry
    carries the newest 256, and when it is answered the answering checkpoint writes a
    continuation entry for the same pair with `below` = the oldest listed stamp, listing
    the next 256 older than `below`. `unpublished`: one record per Unpublish revert, `{
    channel, stamp }` (the dropped lane's `public` stamp it reverted), at most 64.
  - **Listed or waiting, never closed by count (R34-5).** Unanswered entries rank by their
    author's standing in the base (role tier, then `MemberSpan.admitted` position, then
    id; a master that is not a member ranks after every member), then by `dr` clock. At
    most 8 entries are LISTED per server, one per DR author identity; the rest WAIT. A
    waiting entry carries no `review` items and no `opened`; when it ranks into the 8, the
    writing owner device walks the dropped lane (R by the rule above, the pinned DR) and
    lists what still carries the lane's stamp, sets `opened` to its checkpoint clock and
    signs the entry as its `by` (a walk that finds nothing to list, with no Unpublish
    record, answers the entry instead). A listed entry that a higher-standing author's entry ranks
    out goes back to waiting the same way (items dropped, `opened` cleared, re-signed). So
    a flood of reviews by fresh identities never closes, displaces or delays an
    established member's review, and the AUTO and Unpublish reverts of every entry ran at
    its re-fold whatever its rank. At most 256 unanswered entries per server: past that,
    the lowest-ranked unanswered entry is dropped, or not written when it is the new one
    (its reverts stand, its REVIEW writes stay as the base has them, and its pair is not
    re-folded again while it would rank there); only a flood of 256 member identities
    reaches it, and it drops the flood's own lowest first. An entry with no REVIEW item
    and no Unpublish record is written already answered (it suppresses and lists
    nothing).
  - **Pins.** R's checkpoint op and the DR op are kept as `RowKind::RefoldPin` rows, like a
    `SettlePin`: one stored copy per content id, in `served_log` and the digest, exempt from
    the core's drop at or below the base's parent. R is kept while an unanswered entry
    names it; the DR while its entry is unanswered and for 30 days of owner clock after the
    entry's `at` (the settling needs it, D35-1, below). So every owner device, not only the
    one that re-folded, can check and apply the list.
  - **What every owner device checks before it shows or applies an entry (R34-1).** The
    entry's `sig` verifies under `by`'s device key and `by` is a device of the owner that
    this device's view counts; the pinned DR's content id is `dr`, its author is `member`,
    its `device` is `device`, its verdict here is `Counted` and it has `restore`; trigger
    clauses 2 and 3 hold in the current view. Clause 1 is not re-run: the base's line moves
    on (`cp_lineage` keeps 64 generations), and the signature binds the writer to the
    judgment it made when it wrote the entry. Each item must have `stamp.actor` = `member`,
    `stamp.counter % LANES` = `lane_of(device)`, no `OpRef` of the DR, a key of a kind
    `refold_class` can list (never an Excluded one), and still be the winning stamp of its
    element or event; an Unpublish record must name a channel whose `public` stamp is still
    the one the revert left. An entry that fails is void (it shows, applies and suppresses
    nothing); an item that fails is neither shown nor applied.
  - **The list.** Every owner device whose base carries a listed entry shows it to the
    owner (appendix A): a notice in the server for the owner only, and the list in the
    server's settings, grouped by kind, one toggle per item, nothing preselected (as on
    every recovery choice), with "Select all". Unpublish records come first, under "Already
    undone", each with a "Put back" toggle, off. An item whose undo opens something (lifts
    a restriction, opens joins, gives back a role above member) says what it opens. Two
    buttons: "Apply selected" (disabled until a toggle is on) and "Keep all"; closing the
    screen answers nothing.
  - **Confirm.** The answering device stores its answer locally (`refold_answer`: the pair,
    the DR id, `below`, the chosen items and put-backs; a `server_blobs` row that a restart
    reads back and that goes with the server, never served) and asks for a checkpoint turn
    at once; its next owner checkpoint applies the chosen items on top of the current base,
    each re-checked as above (an item someone changed since is skipped and stays), and a
    chosen Put back as `ChannelPublicChanged { true }` would apply at the checkpoint's own
    clock (skipped when the channel is now restricted or its `public` stamp is no longer
    the one the Unpublish left). It then sets the entry's `answered = { by, undone, kept,
    put_back, timeout: false, sig }`, signed by the answering device (`sig` below), and
    empties `review` and `unpublished`. A local answer applies to the entry whether it is
    listed or waiting at the turn, since every item carries its own key and stamp. A
    confirm that loses a tie runs again at the next turn, as a re-fold does, until the
    base's entry is answered.
  - **One answer for every owner device.** The list and its answer ride the checkpoint, so
    every owner device shows the same list, and the first answered entry that lands on the
    base is the answer. An owner device that answered too drops its local answer once the
    base's entry carries a person's answer and shows "Answered on {device}" (appendix A).
  - **Declined ("Keep all").** The entry is answered with nothing undone and nothing put
    back. The items shown stay as the base has them and are never listed again; when the
    re-fold had more than 256 items, the ones not yet shown open as the continuation entry
    (R34-12). Unpublished channels stay not public. The pins go once no unanswered entry
    needs them.
  - **Never answered.** Nothing on the list is reverted, and every owner device keeps
    showing it. An item leaves the list as soon as its element or event carries another
    stamp. A listed entry closes as kept, as a decline would, once the writing owner
    device's checkpoint clock is 30 days past its `opened` (both owner clocks, both signed):
    the writer sets `answered = { by, timeout: true, sig }`. A waiting entry never times
    out. A person's answer that an owner device stored while its base showed the entry
    unanswered still applies after a timeout close lands: it replaces the timeout answer
    once, never another person's answer (owner intent beats the timeout, R34-12). The UI
    says "Closed after 30 days" for a timeout and "Answered on {device}" for a person.
  - While an entry is unanswered, its REVIEW writes stand; a channel the dropped device
    made public after T is not public already (Unpublish), one it made public at or before
    T stays public until the owner answers.
- **What stays.** Every other element, exactly as the base has it: other members' and
  other devices' writes, bans, kicks and admissions, whether or not their ops are still
  held anywhere. Without the owner, a member can revert only what its own dropped device's
  lane wrote and it could still write itself now, plus a channel that lane made public
  after T; never another master's moderation, never anyone's admission or seat, never any
  other change to a channel's access or existence.
- **Shape (R33-7, R34-1).** An ordinary owner checkpoint, a child of the current base, with
  no `cp_settles` (the owner lost no device, so nothing is confined). It carries
  `cp_refolded`: the parent's entries plus `Refolded { member, device, dr, r, at, opened,
  below, review, unpublished, by, sig, answered }`. `by` is the writing owner device, `at`
  the re-fold checkpoint's clock, `r` R's content id. `sig` is `by`'s device key over
  `hollow-refold1\n` + the canonical JSON of (server, member, device, dr, r, at, opened,
  below, review, unpublished); `answered.sig` is `answered.by`'s device key over
  `hollow-refold-answer1\n` + (server, member, device, dr, below, undone, kept, put_back,
  timeout). An entry whose `sig` fails is void and dropped on inheritance; an answer whose
  `sig` fails is void, and the entry reads as unanswered. Every 0.14 checkpoint inherits
  its parent's entries by section 8.2's rules: copied (a confirm, a listing or a timeout
  updates its entry), an entry or answer whose `by` the writer's view does not count drops
  (rule 3; a dropped answer re-opens its entry). Retiring an owner device re-signs its
  entries and answers with the remover as `by` (section 8.5), so an honest retire never
  re-opens a review the owner answered. At most 1,024 entries: past that, answered entries
  go first, the oldest DR clock first.
- **A settling and `cp_refolded` (D35-1).** A settling's state is R's fold (above), so a
  re-fold or a confirm written after R is checkpoint content the settling does not hold.
  Its `cp_refolded` is therefore R's entries, never the current base's: rule 3 applies, and
  R's entries and answers signed by a dropped device are re-signed by the remover (R was
  first folded before T, so they predate the theft, as section 8.5 does for
  `cp_endorsed`). For every pair the current base has an entry for and R lacks, the
  settling re-folds that pair in the same checkpoint when the trigger holds and it holds
  or pins the DR, so the member's stolen device's writes never come back, even for one
  generation. Answers written after R are not re-applied: those reviews open again, and a
  stolen owner device's "Keep all" after T is gone with them (R34-1). A pair whose DR this
  device no longer holds or pins keeps R's state until the member's devices serve the DR
  again (section 17).
- **Suppression (R33-7, R34-1).** A `cp_refolded` entry stops a re-fold for (member,
  device) only when its `sig` verifies, its `by` is a device of the owner counted in this
  owner device's view, and, if this device holds the DR the entry's `dr` names, that DR is
  a counted DR for the same pair. With the signature a stolen owner device can write
  entries only under its own `by`, and those end with its removal (rule 3, and the
  settling keeps only R's); before it, that device holds the owner key, ID-1's model. An
  entry naming another pair's DR, or an uncounted one, suppresses nothing. The first
  re-fold per pair wins (Vitalik 2026-11-04), and its entry, unanswered or answered, stops
  a second one, so a second sibling's DR never re-lists what the owner declined. The
  writer asks the same of the entries it carries: one that suppresses nothing (its DR no
  longer counts here) is REPLACED by the new trigger's entry, never skipped, else the pair
  stays due forever.
- **Rate.** Members' DRs cause re-fold checkpoints, so a trigger makes one due at most
  once per hour after the base's newest suppressing entry (`at`); an owner's answer and a
  listed entry's timeout are not limited. Without it a member removed the device that
  signed its first DR and sent more DRs for the same device, each forcing about two full
  owner checkpoints to every member past the hourly gap (track C review, part A).
- **Retried until it lands (R31-10).** It can lose a same-generation tie to a sibling's
  ordinary checkpoint. The re-fold for (member identity, dropped device) is done once the
  base's `cp_refolded` holds that pair with a valid entry; until then this owner device
  re-folds again at its next checkpoint turn, on top of whatever base won.

Nothing waits on it (requirement 5): until an owner device is online, what an owner
checkpoint folded stays, and until the owner answers, what the list holds stays
(section 17).
Tests: `a_stolen_mods_post_t_ban_inside_an_owner_checkpoint_is_refolded` (now through the
owner's confirm), `a_refold_that_loses_a_tie_runs_again`,
`a_refold_reads_t_only_on_the_members_clock`, `a_members_refold_never_reaches_past_30_days`,
`a_member_retire_never_refolds`, `a_dr_without_restore_or_off_the_line_never_refolds`,
`a_dr_naming_a_still_counted_device_never_refolds` (R33-2),
`a_dr_whose_lane_collides_with_a_sibling_never_refolds` (R33-2),
`a_lane_twin_vouched_by_the_stolen_device_never_blocks_its_refold` (R34-4),
`a_refold_never_undoes_another_masters_ban_or_admission`,
`a_refold_reverts_only_the_dropped_devices_lane` (with a later event for the same member
after the confirm, R33-3), `a_reverted_existence_resets_its_sub_stamps_and_refolds_held_ops`
(R33-10), `undoing_a_deletion_brings_access_back_at_its_most_restrictive` (R34-7),
`a_sibling_owner_device_never_refolds_a_pair_in_cp_refolded`,
`a_fabricated_or_uncounted_cp_refolded_entry_suppresses_nothing` (R33-7),
`a_cp_refolded_entry_attributed_to_another_owner_device_suppresses_nothing` (R34-1),
`a_settling_reruns_a_post_r_refold_and_reopens_its_answer` (D35-1),
`review_a_second_dr_after_the_first_signer_is_removed_never_keeps_a_refold_due`,
`an_entry_whose_dr_no_longer_counts_is_replaced_once_past_the_gap` and
`an_owner_answer_survives_a_restart_until_a_checkpoint_carries_it` (track C review, part A),
and the decision 20 and
21 sets of C47 (section 18).

A phrase recovery on an existing device that holds servers does the same for every dropped
device, with the one T.

### 8.4 Lost or stolen with no device that holds the server: witnesses

A person whose only device was stolen recovers by phrase on a fresh install F. F holds no
copy of the servers it owns, and every checkpoint was written by the stolen device, so none
is eligible by its writer. The members' records are the evidence: what the thief does after
T cannot change when an honest member first folded a checkpoint, and a content hash cannot
make a thief checkpoint an ancestor of an honest one.

**Reaching members.** F learns its servers, their member identities and those members'
rosters by section 8.7. For each server it owns, F sends a witness ask to every member
identity on its list: the union of every join answerer's state and every friend's
`SharedServers` entry for that server (R31-9, section 8.7), then every member identity named
in any checkpoint content a witness sent, since the thief may have kicked honest members
after T (R3-8). At most 64 identities per server, in this order: F's contacts who share the
server, members a friend's entry names, then the rest by how many sources name them; F
iterates until no new identity is named or the 64 are asked.

**The ask** rides `SyncRequest` (Carried): `witness: Option<WitnessAsk { nonce, t_age_ms }>`
plus F's roster (section 9, N10). `t_age_ms = now_F - T` is an AGE, never a date (R3-7):
each witness measures it on its own clock, so a member whose clock runs hours behind still
names a checkpoint it folded before T. A responder answers only an asker DEVICE that its
view, after merging that roster, counts for the server's OWNER identity; once per (server,
asker device) per 10 minutes.

**The witness** rides `SyncResponse`:

```rust
pub struct CpWitness {
    pub server: String,
    pub asker: String,         // the asking device: an answer is never replayed to another
    pub nonce: String,         // the ask's nonce: an answer serves that ask only
    pub t_age_ms: i64,         // the age of T the ask named
    pub cp: String,            // content id, empty = none held before T
    pub folded_age_ms: i64,    // the witness's now minus its first fold of `cp`; -1 = before
                               // the 0.14 update (a seeded record, section 7)
    pub by: String,            // the witness device
    pub sig: String,           // the device key over "hollow-cp-witness2\n" + the fields above
}
```

The witness computes `T_w = now_w - t_age_ms` and names the newest checkpoint whose content
it still holds (base, parent, restore rows) with `first_fold_ms < T_w`, and its op rides
along. F dates it `now_F - folded_age_ms` at receipt; a checkpoint's own HLC is never shown
(the thief picks it). A witness whose record of `cp` is the upgrade's seed
(`first_fold_ms = 0`, section 7) sends `folded_age_ms = -1`, and F shows "before the 0.14
update" instead of a date (LOW). The responder attaches its own identity's roster when F's
ask names it as unknown.

**F's judgment**, per server:

1. A witness counts only if its signature verifies, its `nonce` and `t_age_ms` are F's ask,
   `by` is counted for an identity M in F's view, and M is a member in the state of the
   checkpoint X it names. One witness per identity: of M's devices' witnesses, the one
   naming the greatest X in base order, unless two of them name checkpoints that are not on
   one line or whose folded ages differ by more than 10 minutes, and then the one naming
   the oldest X (LOW).
2. Contents: each distinct X is checked as a base (`base_of`, owner from section 5,
   `cp_lineage`, `cp_cut` and `cp_settled` consistent). At most 16 distinct contents and
   64 MiB per server: the ones named by F's contacts first, then by how many identities
   name them, then the newest.
3. SUPPORTERS of X: identities that are members of X and whose own witness is X or a
   checkpoint whose `cp_lineage` holds X.
4. CANDIDATES: checkpoints with at least 2 supporters.
5. CONTINUOUS (R3-2, R31-1): a candidate X is continuous only if both hold:
   - every checkpoint any counted witness named lies on X's line (it is X, an ancestor of X
     by `cp_lineage`, or a checkpoint whose `cp_lineage` holds X); and
   - for EVERY older checkpoint P on X's lineage that ANY counted witness named (candidate
     or not), at least 2 of X's supporters are members of P. With no such P this clause
     holds.
   Revision 3.1 checked only the nearest such P. A thief that writes Y (puppets admitted)
   on the honest Ch and X_t on Y, with one puppet naming Y and two naming X_t, then made
   X_t continuous with P = Y, and with two or more honest witnesses on Ch step 6 picked
   the newer X_t (`.team/devproof-review/rev31/model/chooser_model.py`: rev 3.1 picks a
   thief checkpoint in 289 of 20,000 fuzzed worlds, this rule in 0).
6. If every continuous candidate lies on one line, the newest is the PICK. Any two
   continuous candidates not on one line, whether their lineages are disjoint or they are
   sibling forks of one ancestor, make the choice AMBIGUOUS (R3-8).
7. THE WAIT (R3-2). F shows a pick only after every asked identity answered, or after a
   bounded window: W after a pick first exists, restarted by each new counted witness, at
   most 2 minutes after the first ask round. Until then it shows progress. A witness that
   arrives later, before the person taps Restore, re-runs steps 1 to 6 and the screen
   follows. W = 30 s (decided 2026-11-01), so a recovery waits at most 2 minutes for
   answers.

Why the thief does not win:

- Puppets the thief admits after T are never members of a checkpoint written before T, and
  an honest member's witness names a checkpoint folded before T.
- ONE honest witness blocks a puppet line (R3-2, R31-1). A thief checkpoint descending
  from the honest one has that honest checkpoint (or an older one the member named) on its
  lineage, and the puppets are not members of it; since continuity checks every named
  checkpoint on the lineage, an intermediate checkpoint the puppets name cannot stand in
  for it. A fork rooted on an older ancestor, and a
  lineage written from nothing, leave the honest checkpoint off their line, so they are
  not continuous either. The screen then falls to the list of named restore points
  (decision 1).
- The same off-line clause lets a single puppet that names a fork turn an honest pick into
  that list. Puppets can force the person to choose; they never make their own line the
  pick past one honest witness.
- Two members colluding with the thief can make a thief checkpoint continuous (section
  17).
- With NO honest member answering inside the window, two puppets make a pick whose
  supporters the person does not know. That is why the screen names every supporter and
  offers "Choose another point" (section 17).
- Honest false positives are expected and more frequent with R31-1: an honest stale member
  naming an older checkpoint whose current supporters joined later, or a stale member on a
  losing honest sibling, turns the pick into the dated list. That is the fail-safe answer,
  and appendix A presents the list as a normal screen, never as an alarm.

**What the person sees** (appendix A). A pick: "restore it as it was on {date}", naming the
members who confirmed it, with "Choose another point". Ambiguous, no candidate, or no
continuous candidate (decision 1, answered): every witnessed restore point, dated, each with
the names of the members who named it, nothing preselected, plus "I don't know".

**"I don't know"** is rev 2's rollback, written as an explicit ROLLBACK SETTLING (R31-2,
section 8.8) so that it overrides any floor and stays a consensus object. F runs the
two-identity round, then writes a settling checkpoint: a child of F's current base (the
floor, when F holds one), with R = the newest checkpoint a kept device wrote, else
generation 0 or the founding op; state = the fold of R plus every op it got, the dropped
devices uncounted; `cp_settles`, `cp_settled`, `cp_roster` and the carried sets as for any
settling. Every replica then folds R's state on the settling's line; own-kept ops (section
7) fold again on top.

**The settling.** F fetches X (it already has the content) and runs an `op_sync` round with
the base reference X against two identities (an answerer that dropped X answers
`base_unknown` and F sends X, section 9). It then writes the settling checkpoint as one
owner op:

- a child of X, with `cp_settles` (its `SettleStamp`), `cp_settled` and `cp_roster` (the
  recovery);
- state = the fold of X plus every op it got, with the dropped devices uncounted;
- the carried sets by rule 4 of section 8.2 (F holds no records, so no ref to a dropped
  device's op survives unless X's own carried entries name it from a counted signer).

It sends X with it, since replicas may have dropped X and the core needs the parent held.
From then on it is the ordinary consensus object: the greatest eligible checkpoint by a
counted writer, and the thief's later checkpoints are off the line its settle mark holds.
The relay lock follows section 8.7, step 7.

### 8.5 Re-signing what the dropped device signed (N3, C3, R31-5, R31-6)

Under the walk, once the remover removes device A, a removal A once signed counts only if A
walks before the remover. A device A removed a year ago would count again.

- **Retire**: the remover re-signs, as its own removal with the same `keep_vouched`, every
  counting removal A signed.
- **Lost or stolen**: it re-signs only those it FIRST SAW before T. A local record,
  `roster_seen(statement digest, first_seen_ms)`, kept for our own identity's removals and
  vouches (R3-5), written on every merge, and kept 30 days after its statement drops from
  the roster, so a removal that comes back through a merge keeps its first sight (LOW). A
  removal A signed after T was the thief's and is not re-signed.
- **Endorsements** follow the same split (R3-6, rule 3 of section 8.2 ends a removed
  signer's entries). Retiring A re-signs, as DRs of the remover naming the same ops (on the
  retire answer the remover takes A's word for ops it may not have folded itself; that is
  what retiring means):
  - every counted `DeviceRetired` A signed that the remover holds; and
  - every `cp_endorsed` entry with `by = A` and every `cp_posts_until` entry with `by = A`
    in the remover's base (R31-6): a DR the base lists in `cp_retired` is dominated and may
    be gone, and its endorsement lives only in those entries, which readers count only
    while `by` is `Counted`. Each entry becomes one DR naming the entry's device, its refs
    and its window (`posts_until_ms = until_ms`), chunked at 256 refs.
  Lost or stolen re-signs only the DRs it first saw before T, and only the carried entries
  whose carrying base this device first folded before T (`cp_seen`).
- **Settling stamps** (R31-5, RC32-4, section 7): retiring A publishes a `SettleSign` of
  the remover's device for every held mark A signed; lost or stolen only for those first
  seen before T (`roster_seen` gains stamp rows on the same terms). The settling id does not
  change, so the `cp_settled` already copied into descendants still names it.
- **Re-fold entries and answers** (R33-7, R34-1, section 8.3): they are checkpoint content,
  signed by their `by` device. Retiring an owner device A writes one owner checkpoint that
  re-signs every `cp_refolded` entry and answer with `by = A` as the remover's. Lost or
  stolen is the settling's: it carries R's entries and re-signs A's among them (R was first
  folded before T).
- All of these are written before the removal is published (section 8.2, step 4). A
  sibling owner device that learns of the removal before the re-signing checkpoint and
  writes one of its own drops A's entries there (rule 3) if its checkpoint wins the tie;
  the pair then re-folds once more: what the owner undid no longer carries the dropped
  lane's stamp and is not listed again, what it kept is listed again once (section 17).
- **Phrase recovery** starts a new base with an explicit `keep`; old removals do not carry
  over and nothing needs re-signing. A kept device re-signs the dropped devices' DRs it
  first saw before T.

### 8.6 Vouchees (R3-5, R31-3)

`remove()` keeps the removed device's current vouchees by default (roster_book.rs 497). A
thief that links a minted "Desktop" before the person notices would keep it counted after
"lost or stolen", and the settling would keep that device's ops and let it write owner
checkpoints. Revision 3.2:

- **Which devices are vouchees here (R31-3).** The stolen device holds its own device key,
  and a `Vouch` is signed by the voucher alone (`sign_vouch`, roster.rs 423), so the thief
  can sign `vouch(H)` for any honest sibling H after T. Only a device that DEPENDS on the
  dropped devices is handled here: one outside the valid closure computed with the dropped
  devices left out (every device the roots and the remaining devices vouch, by section 4's
  closure). A dropped device's vouch for a device with another valid path is ignored: that
  device is not listed, not removed and not asked about.
- **Retire**: the dialog lists the vouchees with "Remove them too", off (retiring means the
  device was not misused). Retiring endorses nothing for vouchees the person chose to
  remove.
- **Lost or stolen** (decided 2026-11-01): a dependent vouchee whose vouch this device
  first saw after T (`roster_seen`) is removed with the dropped device, with no toggle; the
  dialog names those devices before Remove is enabled, so a person who sees one of their
  own devices there can pick a later time. A T earlier than needed also removes an honest
  device linked only from the stolen one in between (it locks and erases in 3 days unless
  the phrase is typed); a device the thief vouched that another device also holds is never
  affected (R31-3).
- Older dependent vouchees: listed with "Remove them too" ON.
- The removal's `keep_vouched` names only the vouchees kept, so the others leave every view
  at once (HOL-SEC-080), and each removed vouchee also gets its own signed removal so it
  learns, locks, and moves the lock (section 12). The remover never removes itself.
- Every removed vouchee joins `cp_settles.devices` and the member DRs (section 8.3) with the
  same T.
- **Phrase recovery**: the keep list on the recovery screen starts with devices first seen
  after T unticked. A fresh install holds no `roster_seen`, so there every device other than
  F starts unticked (LOW).

### 8.7 A fresh install finds its servers and members (the owner gap)

On a fresh install F that recovered by phrase nothing reaches a server today:
`announce_phrase_change` (roster_book.rs 724-771) reaches only our own room and mailbox,
because `server_states` and the friends table are empty; server announces to our own
devices come only from siblings; and door rooms (D1) hide a server's roster from a socket
with no grant, which F does not have. The witness protocol needs member identities, their
rosters and Olm sessions, so F gets them in this order. No step gives F authority: each
only lets members judge F's device by F's roster, which the phrase signed.

1. **F's roster first.** F shows the relay its roster on connect (`show_relay`). The
   relay's fold of our master counts F alone, so the stolen device loses our inbox and
   (track R) writes no new owner lock link.
2. **The first server id**, either way:
   - **An invite** from any member, the ordinary link (`key=`, `owner=`, the relay). The
     join lock is the one channel that works for a device that knows nothing, and it is
     unchanged: F verifies the chain itself (`verify_chain` is stateless; the relay judged
     each link's device against its fold, and F's shown roster stops new links from the
     stolen device), seals the request to the newest door and the invite key, and judges
     answers against a lock read asked after they arrive.
   - **A re-added friend.** F re-adds a friend by its id, as anyone does. Once the
     friendship is accepted (it lands on F's outgoing row, HOL-SEC-036), F sends
     `SharedServers { ask: true }` into `dm_room_code`, lane `Carried`. The friend's device
     answers once per (asker device, 10 minutes) and only when its view counts the asking
     device for our master (from the friend request's roster or a `RosterNotice` in the DM
     room): `SharedServers { ask: false, servers }`, at most 64 entries `{ server_id, owner,
     join_key, relay, members }`, only servers whose state lists our master as a member,
     owned ones first. `members` (R31-9) lists up to 64 member identities the friend's
     state holds for that server, by standing order (role tier, fold position, id). That
     tells the asker's identity nothing it cannot see as a member (it owns or belongs to
     each listed server), and tells a device the friend does not count (a minted key, the
     removed thief) nothing. F starts the ordinary join for each entry, as from an invite.
     The relay never reads it.
   - `SharedServers` is `live_only`, so F re-asks each time a friend device arrives in the
     DM room until that device has answered (LOW). An answer is always 4 frames of 16
     entries, each padded to the size of 16 full entries, so the relay learns nothing from
     its size (LOW).
3. **F's roster into each server room, as a hidden sender.** As soon as F learns a server
   id it joins the room and sends its `RosterNotice` there (`roster_book::fan_out` takes
   the servers F is recovering, not only `server_states`). A device without a door grant
   CAN send it: the relay's broadcast fan-out checks only each recipient's sight
   (`fanout_reaches`, ws_handler.cpp; D1's `DoorAsk` and join requests rely on the same),
   so every prover hears it on today's relay. With track D's hidden-sender reach
   (`HIDDEN_REACH = 3`, `door_room.h` in `~/dev/wt/w2-d`) three provers hear each frame,
   picked afresh per frame; F sends it three times, 10 s apart. Members take it as today
   (first-party, each statement verifies alone, into the book), so their resolver places
   F, and the roster trade (section 9) carries it to every other member because the owner
   is in every authority set. The join ask carries it too (step 4), so neither path is
   load-bearing alone. Track D must keep a hidden sender's `RosterNotice` reaching provers
   (a reach limit, never a refusal). A member keeps a `RosterNotice` that arrives through a
   server room only if its master is in that server's authority set held there (R31-8,
   section 9); the owner always is, so F's notice is kept, and a stranger's stores
   nothing.
4. **The join ask carries the part of F's roster that places F (R31-7).** The sealed join
   request gains `asker_roster: Option<Roster>` (`#[serde(default)]`, inside the sealed box,
   lane `Join`, so the relay reads nothing). It holds only `Roster::placing_subset(device)`
   (track I): the current recovery, its `keep`, the vouch chain from a root to the asking
   device and the consents on that chain, each statement verifying alone. A full roster can
   reach 231,705 bytes (section 4), so an honest multi-device joiner with a long roster
   would otherwise not fit. When even the subset does not fit the box's largest bucket, it
   is omitted and the member falls back to `roster_needed` and the room `RosterNotice`; a
   join box is NEVER refused for its roster. Every 0.14 join box, recovering or not, is
   padded to the next of three fixed sizes (2, 8 and 32 KiB), so the relay cannot spot a
   recovering joiner by size. A member merges the subset into what it holds and judges by
   the union, so a subset that leaves out a removal proves nothing the member's other
   statements contradict (the roster trade of section 9 brings the rest). The answering
   member judges the asker device (section 9, responders) and, since our master is already
   a member, sends the server state again with no second admission (the `already_member`
   arm, swarm.rs ~11183). That state may be the thief's: F uses it only as one source of
   member identities (step 6), never as the restore.
5. **The door.** With F's roster in its book, a member answers F's `DoorAsk`
   (`door_room::answer_ask`: `speaks_for` places F, and our master is a member), and F
   proves the newest door. Nothing below waits on it: a hidden F reaches devices by
   directs into the room, which D1 delivers to hidden sockets too.
6. **Rosters, sessions, witnesses, iterated.** Until the lock moves, the stolen device
   still proves the door and can answer F's join with a state whose members are puppets
   (R31-9). So F's member list for a server is the UNION of every join answerer's state and
   every friend's `SharedServers` entry for it, and F asks in the order of section 8.4:
   contacts sharing the server, members a friend names, then the rest. F asks for those
   identities' rosters (`rosters_wanted`, 64 per ask, into `server_rosters`; from a friend
   and from any answerer), opens Olm sessions as a joiner opens them with co-members today,
   and sends the witness asks (section 8.4). Each checkpoint content a witness sends names
   members; F asks the ones it has not asked (roster first, then the witness ask), up to 64
   identities per server, until no new identity appears.
7. **The lock.** If the join-answer state shows another identity at mod or above, its lock
   keeper moves the lock when it ingests F's recovery (track R item 3; a recovery that drops
   a device counts as its removal for `note_removal`, section 12, item 9) and grants by its
   own state. If our identity is the only mod or above, F resets the lock itself (a counted
   owner device's reset, track R), granting only F, so the stolen device loses the door and
   the change key at once; after the settling F moves it again with grants for the settled
   state's mods. Between the two moves those mods hold no change key, so their kicks wait
   for the settling (decided 2026-11-01, section 20).
8. **MLS** follows the ordinary leafless path (the owner asks members by standing for a
   seat). The witness protocol rides Olm and never waits on it.

**When F knows no server**, the recovery screen says so: ask a member of your server for an
invite link, or add your friends again (appendix A). Until F reaches a server, its members
keep it running (requirement 5). Once a member holds the recovery, the stolen device's
checkpoints there lose eligibility by their writer, and the members keep the server as they
held it when they heard of the recovery (the floor, section 8.8) until F reaches it and
settles; no member or MLS leaf is evicted meanwhile.

### 8.8 While a recovery is in progress: floor marks and the hold (R31-2)

**Decided by Vitalik, 2026-11-01.** When a server's only checkpoint writer is dropped by a
recovery, every member records the server as it held it at that moment, and the members
together keep the OLDEST of those records as a frozen floor that nobody can move forward,
so nothing vanishes and the stolen device can add nothing after members learn of the
recovery. The cost: on a server the owner never gets back to, whatever the thief changed
between the theft and the moment members heard of the recovery stays (the owner's restore
fixes it where the owner does reach the server), and an active thief with planted accounts
can still force a full step back, but never its own version.

**The problem.** It fires during EVERY recovery, not only on servers F never reaches.
Section 8.7 step 3 sends F's `RosterNotice` into each server room as soon as F learns the
id, and section 9's trade carries it to every member, minutes before F has any witness.
From then until the settling, a member whose checkpoints were all written by the dropped
device sees every one lose eligibility by rule 1, and its base steps back to generation 0
or the founding op. That is destructive, not a display gap:

- Members missing from `state.members` lose their MLS leaves. The batch tick queues a
  remove for every bound leaf whose master fails `GroupRules::membership`
  (`node/mls_authority.rs`: `membership`, `unseated`; `crypto_handler.rs`:
  `sweep_unseated_leaves` through `unseated_leaves_in`, called from `run_event_loop`'s
  batch tick), and the committer commits it (the batch tick's `plan_membership` call).
- A member whose own admission disappears is torn down locally, by several arms (listed by
  function under the hold below). Main has no server auto-rejoin, and the core worktree's
  silent re-ask (`refused_own_admission`) needs an admitter with authority in the NEW state
  (`server_state.rs`), which in a founding-op state only the owner has. A settling that
  arrives later does not undo either.

Two parts close it: FLOOR MARKS keep the members' base, and THE HOLD keeps every member's
seat and server even when no floor forms.

**Floor marks.**

1. **Trigger (local).** A device of a member identity M other than the owner ingests an
   owner view (section 10, step 2) under which its current base is no longer eligible by
   rules 1 to 3 of section 7 and lies on the line of no counted settle mark it holds. It
   then:
   - records `floor_pending(server, base content id, trigger_ms, base op, held state,
     leaves)`, a local row that survives a restart and is never served: the base's
     checkpoint op (the PRE-TRIGGER BASE), the PRE-TRIGGER STATE, this replica's whole
     folded state at that moment (the base plus every op folded on it), and the TRIGGER
     LEAVES: for the server group and for each of its subgroups, the certified masters
     (`group_leaves`) holding a bound leaf there at that moment (R34-3). None of them ever
     moves (R33-1), not even on a later trigger while the server is still in recovery;
   - keeps judging that server under the PREVIOUS owner view (held in RAM) for one
     two-identity `op_sync` round (H4: two identities or the 10 s bound); the rebuild the
     new view triggers for that server waits for the round;
   - after the round, writes nothing if it now holds a counted settle mark whose line holds
     its base, or its base is eligible again by rules 1 to 3;
   - otherwise picks B (below), signs a `FloorMark` naming B, pins B's content as a
     `FloorPin` row, records B in the row's own column `floor_b` (used for the mark, the
     pin and the hold's KEEP set only), and only then rebuilds under the new view. After a
     restart mid-round, B is the pre-trigger base. Revision 3.3 moved the row to B and read
     the hold from it, so a B a puppet answered became the replica's held base and could
     seat whoever that checkpoint named (R33-1).
   **Which checkpoints B may be (RC32-2).** The stolen device sees the `RosterNotice` as soon
   as members do, and under the previous view it is still counted, so a checkpoint X_t it
   writes at notice would be eligible in every member's round and the round would fetch it
   everywhere: every honest mark would name X_t. So during the round:
   - a checkpoint this replica first stored (`seen_ms`) after `trigger_ms`, whose writer the
     NEW view does not count, is never a candidate for B, unless an answerer returned it as
     its `floor_base`;
   - every answer of the round carries the answerer's `floor_base` (section 9): the
     PRE-TRIGGER BASE of its own `floor_pending` row when it holds one, else its current
     base (the roster trade of that same exchange may just have triggered it, and then that
     is the base it recorded). Never its B: an honest answerer that returned a B a puppet
     had steered would pass the steer on (R33-1);
   - B = the previous view's pick, by the core's base order, over the eligible checkpoints
     this replica stored before `trigger_ms` plus the answered `floor_base`s that verify as a
     base (`base_of`) and are eligible under the previous view.
   A stale member still catches up through honest answerers' bases. A post-notice thief
   checkpoint becomes a member's B only if an answerer had folded it before its own trigger,
   or if the answerer is a puppet, and then it moves only that member's mark and KEEP set,
   never what the hold seats (below); the round asks answerers in standing order of the
   member's own pre-trigger state (as standing reads it during the hold, below), so members
   who were there before the theft answer first. The floor is the minimum over every
   member's mark, so such a mark moves the floor only if every marking member got the same
   post-notice checkpoint.
   The round comes first so that a member back from months away marks the newest base it
   can learn, not its stale one (the floor is a minimum, so one stale mark would drag every
   member back months). A device marks at most once per (server, owner roster digest).
   Every member marks even when it already holds a floor: honest marks are what bound the
   floor, and a floor of puppet marks alone could name a checkpoint written after notice.
2. **Form.** `CrdtPayload::FloorMark { cp }`, authored by M (master signature) with the
   signing device's proof (`dev`, section 6), so it rides `op_sync`, the digest, dedup and
   M's quota group like any op. The variant tag inside `hollow-crdt1` separates its domain
   from every other signed object. It is never folded: `apply_payload` writes nothing, and
   it emits `ServerUpdated` in both match blocks. The named checkpoint op is kept as
   `RowKind::FloorPin` (stored, in the digest set and `served_log`, never folded, exempt
   from the core's drop at or below the base's parent). Every answer and every live send
   that carries a `FloorMark` carries its pinned checkpoint op too. 0.13 replicas read the
   variant as unread and keep it only from a member of THEIR state (`crdt_resync`'s
   `vouched`, bounded per author), so a 0.13 replica that followed the thief drops the marks
   of members the thief kicked (section 16).
   **Ingest (RC32-6).** In a stepped-back state M is usually not a member, so `op_allowed`
   would refuse the mark, and section 7 drops a refused op that cannot park; the door would
   also drop it as dominated. So `plan` classifies `FloorMark` BEFORE the door and before
   `op_allowed`, and stores it as `RowKind::FloorMark` only when:
   - its master signature verifies and M is a member in the named checkpoint's content;
   - that checkpoint op is held (as a pin, the base or any checkpoint row) or arrives in the
     same answer or send, and verifies by `base_of`;
   otherwise it drops unstored. A free identity CAN use the path (R33-8): the thief names
   it in an owner-signed checkpoint it fabricates and ships that checkpoint with the
   identity's mark, which counts under the identity's own roster. It can only kill the
   floor, never become it: the fabricated checkpoint is either a descendant of an honest
   mark's checkpoint (the minimum stays the honest one) or off its line (the one-line rule
   ends the floor, and `keep(held)` keeps the fork pair, so the fabricated line is never
   the floor). Killing the floor is already accepted (section 17), and the per-server
   author cap below holds either way.
3. **Held facts.** Per member identity per server, at most 4 marks, ranked: marks whose
   verdict is `Counted` first, then the lowest named (generation, content id), then the
   mark's content id. M's CHOSEN mark is the first counted one of those; with none counted,
   M has no chosen mark. Choosing before counting, as revision 3.2 did, let anyone holding
   M's master key (a device M removed, or the stolen one) mint a ground device key, sign an
   uncounted mark naming M's oldest checkpoint, and displace M's honest mark everywhere.
   Keeping 4 lets a replica whose roster view lags still hold the counted one after the
   roster trade. A sibling's newer counted mark never raises the chosen one. Per server at
   most 512 authors. The floor (item 5) is decided over EVERY author's chosen mark before
   this bound or item 7's cuts anything, and the bounds keep that decision's EVIDENCE
   first: the lowest counted pair off one line, else the oldest counted checkpoint (the
   floor), for each one author naming it as its chosen mark (one this replica knows
   first). Past that, authors rank by (a member of this replica's base, its parent or its
   pre-trigger state, has a counted mark, its chosen or best mark names a checkpoint in the
   `FloorPin` keep set of item 7, author id) and the tail drops, so a rebuild from what is
   kept decides as the full set did. Never by the generation a mark names: revision 3.5
   ranked low generations first, so a thief holding the owner key wrote a low-generation
   checkpoint seating 512 free identities, their counted marks filled every slot, the
   honest mark that ended that floor dropped and the fabricated checkpoint became the
   floor (track C review, part A).
4. **Counted mark** (pure, section 10, step 4b): M's chosen mark counts when its verdict
   is `Counted` (the proof verifies and M's view counts the device); M is not the owner
   (the owner settles); M is a member in the named checkpoint's content (its pin verifies
   by `base_of`); and the named checkpoint is not eligible by rules 1 to 3 (step 4a).
5. **The floor.** N = the distinct checkpoints the counted marks name, every author's,
   before item 3's or item 7's bound cuts anything. If every pair in N
   lies on one line by `cp_lineage` (one is the other or in its `cp_lineage`), the FLOOR F0
   is the oldest of them, and F0 and its ancestors are eligible by rule 4. Otherwise there
   is no floor, which is revision 3.1's step back, under the hold below. Two named
   checkpoints more than 64 generations apart are not on one line by `cp_lineage`, so a
   very stale mark ends the floor instead of dragging it (fail closed).
6. **Confinement.** A checkpoint that is eligible only through rule 4:
   - makes no other checkpoint eligible by rule 2 (its `cp_endorsed` names nothing into
     eligibility);
   - while it is the base, its `cp_endorsed` and `cp_posts_until` entries endorse no op and
     open no post window for the OWNER's devices (section 10, step 6; section 13). The
     dropped device wrote that checkpoint, so entries it attributed to a counted sibling
     would otherwise let a precomputed later checkpoint or op of the dropped device count.
     Honest owner endorsements carried there wait for the settling (those ops park); a
     held counted owner DR still endorses at step 3;
   - extends nothing downward: a descendant of F0 by an uncounted writer stays ineligible
     (rule 1 fails, and descent flows only to ancestors);
   - yields to any counted settle mark: with one held, F0 is eligible only on its line
     (an ancestor of the settling), as for every rule of section 7. A counted writer's
     ordinary checkpoint wins by the core's order as usual.
7. **Bound.** At most 32 distinct named checkpoints and 64 MiB of pins per server, inside
   the core's per-device ceiling; marks charged to their author's quota group. Over the
   bound the held set becomes `keep(held)`: first item 3's evidence (the counted pair off
   one line, else the floor), then, if N is not one line, the lowest pair (in (generation,
   content id) order) that is not on one line, then the lowest of the rest up to 32. Marks
   naming an evicted checkpoint go with its pin, and a pin goes with the last kept mark
   naming it. Without the evidence first, uncounted marks on low-generation siblings of a
   fabricated root pushed out the honest checkpoint and its mark. Every
   mark and pin of a server drops once the replica holds a counted settle mark, or a
   checkpoint eligible by rules 1 to 3 (not by rule 4) that is or descends from every named
   checkpoint by `cp_lineage`. Each of these is a function of the held set and the
   statements.
8. **"I don't know" on F** is an explicit rollback settling (section 8.4), so decision 3's
   meaning stays a consensus object and the floor never silently replaces it.

**Convergence.** The floor is a pure function of held counted marks, pins and statements,
all in the digest set, and eviction is a deterministic function of the held set, so two
replicas that traded digests hold `keep(union)` and compute one floor. Model
`.team/devproof-review/rev31/model/floor_trade.py`: 4 replicas with partial deliveries and
evictions in random orders, then trades: 0 split floors in 30,000 worlds at K = 2, 3 and 32.
Without trades a small K is order-dependent (`floor_model.log`: 1,612 at K = 2, 311 at
K = 3, 0 at K = 32), which is why the bound is 32 and why marks stay in the digest set.

**Safety.** At a replica that holds one honest mark naming c_h, the floor is either none or
c_h or an ancestor of it. A checkpoint written later cannot be an ancestor of c_h, because
c_h's content id commits to its `cp_lineage`. So nothing the thief writes after the first
honest mark is ever the floor there. Model: 0 unsafe floors in 30,000 worlds with puppets,
split views before notice, forks and lineages from nothing, at every K; honest marks alone
on one line always give the floor (11,036 of 11,036).

**What the thief can still do.**
- Kill the floor: one mark on a fork, by a pre-notice puppet or by a free identity named in
  a checkpoint the thief fabricates (R33-8), or different checkpoints fed to different
  members before notice. That falls back to the step back under the hold. It never gets
  its own version adopted, because the one-line rule fails closed.
- Drag the floor older, only to a checkpoint its puppets are members of, which is toward T.
- A thief checkpoint written after notice is a member's B only if an answerer had folded it
  before its own trigger, or a puppet answerer returned it (item 1, RC32-2); it is the floor
  only if every member that marked got it one of those ways.
- Keep the seats of puppets it admitted BEFORE a member's trigger in what that member
  folded: they are members of its pre-trigger state (the hold, below). For a member that
  hears of the recovery late, that window reaches past notice: a pre-notice puppet can
  answer its first sync and withhold F's statements, so it folds the thief's post-notice
  admissions under the previous view (R34-3). Those identities keep what they held there
  at the trigger, never more: the hold seats anew only masters that held a bound leaf in
  that group at the trigger, or whose admitting op the NEW view counts (SEAT, below). It
  cannot seat anyone new through the hold (RC32-1), not even at a member whose B it
  steered through a puppet answerer (R33-1): B only keeps seats, it never grants one.

**Rejected variants.** "Checkpoints dated before T" fails because the checkpoint clock is
the thief's (a backdated child of the newest pre-T checkpoint). "Each member's own base"
fails consensus; floor marks make it a held fact. A maximum or a majority over marks lets
free puppet identities pick, so only the minimum works. Marks of "the newest base first
folded before T" would undo post-T changes, but a stale member's honest mark then drags
everyone back months; notice time with a sync round first avoids that. A floor that
restores the pre-T state with no owner present does not exist: only the person knows T.

**The hold: a recovery in progress never evicts members or MLS leaves.** It applies with
or without a floor (a killed floor still steps back).

- A server is IN RECOVERY at a replica from the trigger of item 1 until a counted settle
  mark's line holds its base, or its base is eligible by rule 1 or 2. The state is kept
  with `floor_pending`, so it survives a restart. No clock ends it: on a server F never
  reaches, it lasts permanently (RC32-11).
- **What the hold reads.** The PRE-TRIGGER STATE of this replica's OWN `floor_pending` row:
  what this replica held when it heard of the recovery, recorded at the trigger and never
  moved (R33-1), decoded once and kept in RAM next to the row. It is the whole fold at the
  trigger, not only the base checkpoint's content: revision 3.3 read the checkpoint, so a
  member admitted by an op folded above it, and not yet in any checkpoint, lost its seat in
  a step back (D34-1). B's content (`floor_b`) is kept in RAM too, for the KEEP set only.
- **Two sets** (R33-1, R34-3, R34-9). Both exclude masters the current fold bans, and
  masters that an op this replica first stored after `trigger_ms`, admitted by the current
  fold, removed (kick, ban, leave):
  - KEEP (protects an existing seat): the members of the pre-trigger state and the members
    of B. For an existing SUBGROUP leaf, its master must also see the channel: in the
    current fold; else in the pre-trigger state if it is a member there (a revocation
    there wins); else in B if only B names it (R34-9);
  - SEAT (accepts a NEW seat), per group:
    - the server group: the pre-trigger members among the masters of the server group's
      trigger leaves, plus the pre-trigger members whose current span's admitting op this
      replica holds and whose proof's device the NEW view counts (D34-1's honest admission
      above the last checkpoint stays seatable; a post-notice admission by the stolen
      device is not);
    - a subgroup: only a pre-trigger member among that subgroup's trigger leaves (a
      re-seat of a leaf it held there at the trigger), with the channel access KEEP asks.
  So SEAT is inside KEEP for every group.
  KEEP only protects; SEAT also admits. B is a checkpoint a puppet answerer can steer
  (item 1), so its members are never removed here (a stale member's newer co-members are in
  B, and removing them would split the member from its own server) but never newly seated
  here either. The pre-trigger state can be steered too, at a member that hears of the
  recovery late (R34-3: a pre-notice puppet answers its first sync and withholds F's
  statements), so it decides only what KEEP protects; SEAT adds no one the replica did not
  already hold a leaf for, except through an admission the new view counts. Never the
  members of a pin received from others or of another member's mark (RC32-1): a counted
  mark needs only a counted device of a member of the content it names, and the thief
  writes that content with the owner key. When a floor forms, the current fold is F0's,
  whose members are current members anyway, and F0 is bounded by honest marks.
- **One predicate**, `recovery_hold(server, channel, master) -> Hold` (`channel` None for
  the server group), with `Hold::{Out, Keep, Seat}` (`Seat` implies `Keep`): `Out` when
  the server is not in recovery here or `master` is in neither set for that group. Every
  site below asks it, or reads `held` from the same place, and names the level it needs.
- While a server is in recovery, three classes of sites change (named by function as of
  `security/0.14` ef4f4ac2; the build first repeats the sweep: Grep floor on
  `is_member(local`, `is_member(&local`, `is_member(peer`, `is_member(us`,
  `is_member(&device`, `members.keys().any(`, `leave_evicted_server`, `delete_server`,
  `remove_group`, `LeaveRoom`, `GroupRules::Server {`, plus LSP references on
  `ServerState::is_member` and `GroupRules::membership`, and every site found gets one of
  the three classes, RC32-5, R33-4):
  1. **Seats.** `GroupRules::Server` gains `held: Option<&Held>` (both sets, the
     pre-trigger state, B's content and the trigger leaves), filled at every place it is
     built: `unseated_leaves_in` (hence `sweep_unseated_leaves`),
     `reconcile_subgroups_for_server` (its `stale_leaves`), the batch tick's
     `plan_membership` call in `run_event_loop`, `judge_commit` (hence `commit_verdict` and
     `removable`), `judge_welcome` (hence `welcome_verdict`) and the live `MlsKeyPackage`
     arm of `handle_incoming_request_inner`. With `held` set:
     - a leaf whose master is in KEEP (for a subgroup, with KEEP's channel access) is never
       `unseated`, never in `stale_leaves` and never `removable`, except by the existing
       clauses (`refused`, the committer's own identity, a repair in the same commit);
     - an added leaf, every Welcome leaf and a KeyPackage sender are accepted only for a
       member of the current fold (as today, with `can_see_channel` in the fold for a
       subgroup) or of that group's SEAT; nobody else, so the hold never seats an identity
       this replica did not hold a leaf for at its trigger, except one an admission the new
       view counts let in (R34-3);
     - a committer and a Welcome sender are accepted from the current fold, SEAT or KEEP:
       an identity nobody seated holds no leaf to commit with.
  2. **Teardown of our own server.** While `recovery_hold(server, None, our master)` is
     not `Out`, nothing tears the server down: `leave_evicted_server` itself (a second
     layer) and every caller, namely the `evicted` arm of `take_resync_page`, the
     `MemberKickBroadcast` arm and the `MlsChannelMessage` arm (self-eviction through an
     MLS-carried op) of `handle_incoming_request_inner`; the `MemberRemoved` and
     `MemberBanned` self-eviction arms of `apply_remote_crdt_op_inner` (`delete_server`
     plus `ServerDeleted`); and the `SyncResponse` arm of `handle_incoming_request_inner`,
     whose `kicked_now` and `banned_now` branch tears down inline (`server_states.remove`,
     `delete_server`, `remove_group` for the server and every subgroup, `LeaveRoom`). That
     last arm is the one a stepped-back sync answer runs through. A kick, ban or leave
     naming us that this replica first stored after `trigger_ms` and that the current fold
     admits takes us out of both sets; one re-folding from before the trigger does not.
     **What happens then (R33-11).** Our own leave, or a kick or ban whose op is the
     owner's with a `Counted` device, tears down as today. Any other kick or ban (in a
     floor state, a mod the floor's checkpoint names, possibly a pre-notice puppet promoted
     there) leaves the server as a SHELL until the recovery ends: our MLS groups for it are
     dropped (the others' commits remove our leaf anyway), but the `server_states` entry,
     the server row and the room stay, and the server is listed read-only with the shell
     banner (appendix A). It serves nothing. A shell must reach the settling by itself
     (R34-2): the kick moved the lock at once, under D1 the relay soon hides us, every
     co-member's own hold excludes us (the kick is post-trigger there too), and our ask
     loops take their peers from presence. So:
     - the shell reads as our membership at `door_room::sync` and `door_room::on_status`
       (it keeps proving the newest door it holds and, hidden, sends its `DoorAsk`), and
       at the `LockChain` arm of `run_event_loop` for `lock_keeper::on_chain`'s record of
       the relay's chain only, which `door_room::on_grant` checks a grant against; nothing
       is authored there and `tick_one` stays gated on the fold (no lock move from a
       shell);
     - while a shell, the device sends a direct `SyncRequest` (`send_room_for_peer`, heard
       routes, which reach a hidden device) to the owner's devices and to devices of
       masters in the server group's SEAT, at most 8 devices a round by standing, first
       after 30 s, then backing off by doubling to 30 minutes, reset by a lock move or a
       roster notice for the owner. Responders serve it once their own fold re-admits us
       (the `SyncRequest` gates of class 3);
     - the settler (section 8.3 or 8.4) sends its settling checkpoint op and a `DoorGrant`
       of the door it moved to, directly (`send_room_for_peer`), to every device of each
       master that is a member in the settling's state and was not in its pre-settling
       base;
     - the shell keeps Leave: the person's own leave tears it down locally at once.
     When the recovery ends here, the fold decides: still removed tears down as today; a
     member again (the settling refused the kick) is a leafless member, which the ordinary
     path re-seats (`walk_leaf_ask`). Revision 3.3 tore the member down for good and no
     auto-rejoin brought it back; revision 3.4's shell lost the room at once and heard
     nothing.
  3. **Liveness reads of our own membership.** While `recovery_hold(server, None, our
     master)` is not `Out` (or the server is a shell, where named), these read us as a
     member and judge channels in the pre-trigger state:
     - `auto_leave_invisible_voice_channels` (a channel absent from the stepped-back state
       is judged by the pre-trigger state, with its `can_see_channel`);
     - `door_room::sync` and `door_room::on_status` (we keep proving the newest door the
       pre-trigger state's join lock names, or the one we were granted; a shell too);
     - `door_room::answer_ask` (answered only for an asker whose master is in the server
       group's SEAT or the fold);
     - `sync_handler::repair_after_gap` and `repair_after_drops`,
       `announce_server_to_own_devices` and `send_personal_emotes_to_sibling`;
     - `frame_auth::placement` and `voice_handler::data_channel_peer_known` (a co-member
       placed when both masters are in the server group's SEAT or the fold, R33-1);
     - the MLS heal and Olm gates (R34-11), each reading the peer's master in KEEP or the
       fold and ours in KEEP: `crypto_handler::handle_epoch_hint`'s member gate, the
       `MlsCommitCatchup` arm of `handle_incoming_request_inner` (the commits it carries
       are still judged by `judge_commit` with `held`), both gates of its
       `MlsKeyPackageRequest` arm (we answer only while our master is in KEEP, with KEEP's
       channel access for a subgroup, and only to a requester in KEEP or the fold, since a
       committer may come from either), the relationship gate of the Olm reconcile sweep in
       `run_event_loop` (the carried Olm twin and sync fallbacks need sessions with held
       members), and the `SyncResponse` arm's digest `learn`;
     - the core's silent re-ask (the batch tick's `silent_reasks` loop over
       `refused_own_admission`, t14-cover M2) sends NOTHING while `recovery_hold(server,
       None, our master)` is not `Out` or the server is a shell: in a stepped-back state it
       would seal a join ask to a door the stolen owner device holds (R34-11);
     - the CRDT sync paths (R33-4). Asker side: the sync-ask loop of `run_event_loop`'s
       `WsEvent::PeerJoined` arm (`state.members.keys().any(same_identity)`), the
       sync-ask loop of its `WsEvent::RoomMembers` arm (`state.is_member(pid_str)`), the
       batch tick's op_sync follow-ups in `run_event_loop` (`Silent::Again`'s
       `is_member(&device)` and the `joined` follow-up's `is_member(&local_peer_str)` and
       `is_member(d)`), and `CrdtResync::tick` and `CrdtResync::paged` (`is_member(us)`):
       our master in KEEP (or a shell), the peer's master in KEEP or the fold. Responder
       side: the `SyncRequest` arm of `handle_incoming_request_inner`, both its
       `heard_request` gate and its serve gate (`is_member(peer_str)`): the asker's master
       in KEEP or the fold (a shell is never served). Without these, in a founding-op state
       only an owner device could ask or answer, and a member offline when F's settling
       went out got it only when online at the same time as an owner device;
     - the sibling re-announce: both loops of `on_verified_sibling` and the
       `SiblingStateSyncRequest` arm of `handle_incoming_request_inner`
       (`is_member(local_peer_str)`): our master in KEEP, so a device linked during the
       recovery still learns the server.
     The lock keeper (`lock_keeper::on_connected`, `tick`, `tick_one`) does NOT: no lock
     move is made from a stepped-back state or a shell; the lock waits for the settling or
     F's reset (section 8.7, step 7; the stolen owner device keeps the door meanwhile,
     section 17). Its `on_chain` record of the relay's chain at the `LockChain` arm does
     read the hold and the shell, since `door_room::on_grant` checks every grant against
     it; with no flight of ours in progress it authors nothing.
- **Standing during a recovery (RC32-8, R33-1).** With no floor, every non-member reads
  `Pos::Max` in a founding-op state and the lowest master id would lead, so a puppet with a
  ground id became committer, catch-up responder and repairer. While a server is in
  recovery with no floor, every standing read for it (`standing::positions`,
  `rank_masters`, `first_by_standing`, hence `elect_by_rule` and every leader role of the
  standing rule) reads tiers and positions from the PRE-TRIGGER state, over the server
  group's SEAT; a master outside it ranks after every seated one. With a floor the current
  fold is F0's and standing reads it as usual. Two members' pre-trigger states can
  differ, so they can elect different leaders for a while; that is the fork case
  standing already resolves (probes carry the digest, the authority's fork stays).
- The server stays in the list. When there is no floor, members see the banner of
  appendix A.
- The hold grants no authority. It gates local seat removal, teardown and the liveness
  reads above, and admits to a seat only masters that held a leaf in that group at this
  replica's trigger or whose admission the new view counts; CRDT state, `op_allowed` and
  every authority check read the fold as it is.

Tests: `a_floor_keeps_the_members_base_when_the_only_writer_is_dropped`,
`a_floor_never_moves_past_an_honest_mark`, `a_puppet_mark_on_a_fork_falls_back_to_the_step_back`,
`floor_marks_converge_after_a_digest_trade`, `a_settling_overrides_the_floor`,
`floor_only_checkpoints_endorse_nothing`, `a_floor_mark_waits_for_the_round_and_names_the_newest_base`,
`floor_marks_are_bounded_and_keep_the_fork_pair`, `i_dont_know_writes_a_rollback_settling`,
`a_checkpoint_the_dropped_device_writes_after_notice_is_never_the_floor` (RC32-2),
`a_removed_sibling_cannot_displace_a_members_floor_mark` (RC32-6),
`a_floor_mark_from_a_non_member_of_its_checkpoint_or_without_its_pin_is_not_stored` (RC32-6),
`a_free_identity_named_in_a_fabricated_checkpoint_only_kills_the_floor` (R33-8),
`review_a_puppet_flood_on_a_fabricated_low_checkpoint_never_becomes_the_floor`,
`known_puppets_never_push_out_the_honest_mark_that_ends_a_fabricated_floor`,
`free_identities_never_push_out_a_known_members_mark` and
`low_generation_siblings_never_evict_the_honest_checkpoint_that_ends_a_fabricated_floor`
(track C review, part A),
`a_thief_checkpoint_after_notice_seats_no_new_identity_during_the_hold` (RC32-1, unit on
`GroupRules` and harness),
`a_puppet_floor_base_never_seats_an_identity_the_pre_trigger_base_lacks` (R33-1),
`a_held_subgroup_reads_the_pre_trigger_states_channel_access` (RC32-1, R33-1),
`keep_protects_a_subgroup_leaf_by_the_fold_then_the_pre_trigger_state_then_b` (R34-9),
`a_late_member_steered_by_a_puppet_sync_seats_no_post_notice_identity` (R34-3),
`the_mls_heal_gates_read_keep_during_a_recovery` and
`no_silent_reask_during_a_recovery_or_in_a_shell` (R34-11),
`standing_during_a_recovery_reads_the_pre_trigger_state` (RC32-8, R33-1); harness
`t14d_a_recovery_in_progress_never_evicts_members_or_mls_leaves` (RED on revision 3.1),
`t14d_a_stepped_back_sync_answer_never_tears_the_server_down` (RC32-5, the `SyncResponse`
arm), `t14d_a_member_in_a_voice_channel_stays_through_a_step_back` (RC32-5, voice
auto-leave), `t14d_a_server_the_owner_never_reaches_keeps_its_members_and_channels`,
`t14d_a_member_admitted_after_the_last_checkpoint_keeps_its_seat_through_a_step_back`
(D34-1), `t14d_a_floorless_member_offline_at_the_settling_gets_it_from_a_co_member`
(R33-4), `t14d_a_puppet_mods_kick_during_a_recovery_keeps_the_shell_until_the_settling`
(R33-11, extended for R34-2 with D1 on and the puppet moving the lock) and
`t14d_a_late_member_steered_by_a_puppet_sync_seats_no_post_notice_identity` (R34-3).

## 9. Rosters reach every co-member (H3, H4, N10)

**In the `op_sync` round, rosters before ops.**

- `OpDigest.rs: Option<Vec<String>>`: 16 bucket fingerprints (8 hex each), each a salted
  hash over the sorted entries of the server's AUTHORITY SET in that bucket. An entry is
  (master, required key, `Roster::digest()` or `none`). The authority set is the owner plus
  the authors of retained, parked, held and own-kept ops.
- `DigestReply.rd: Vec<(String, String)>`: the answerer's (master, digest) pairs for the
  differing buckets, at most 512.
- `SyncRequest.rosters_wanted: Vec<String>` (at most 64) and `SyncResponse.rosters:
  Vec<Roster>` (each at most `MAX_ROSTER_BYTES`, 1 MiB per answer). Both ride the sync
  messages' own lane, `Carried`. No new `HavenMessage` variant here (section 8.7 adds
  `SharedServers`).
- **A base the answerer dropped (R3-8).** When an ask's base reference (`OpDigest.base`) is
  a restore point or witnessed checkpoint the answerer no longer holds, it cannot judge
  what that base does not dominate. It answers `base_unknown: true` (a new `SyncResponse`
  flag), and the asker's next ask to it carries `base_content`: that checkpoint op, one
  per ask, sent only after a `base_unknown`. The answerer checks it as a base (`base_of`)
  before using it, and never stores or folds it.
- **The asker's own roster (N10).** `SyncRequest.asker_roster: Option<Roster>` is attached
  when our roster changed since our last ask to that identity, on a witness ask, and after
  a responder answered `roster_needed: true` (a new `SyncResponse` flag it sets when it
  cannot place the asker device). The responder verifies it alone and keeps it only if the
  master is a member identity of that server (its authority set), then judges the asker
  device again. A newly linked device therefore syncs on its second ask at the latest.
- **A floor base (RC32-2, section 8.8).** `SyncResponse.floor_base: Option<CrdtOp>`: for a
  server in recovery at the answerer, the pre-trigger base op of its own `floor_pending`
  row, never its `floor_b` (R33-1); otherwise, when the asker's ask is a floor round (a flag on the ask, set only by a device
  whose server is in recovery), the answerer's current base. One checkpoint per answer,
  inside the answer's own size; the asker checks it by `base_of` and uses it only as a
  candidate for B, never stores or folds it unless it becomes B. Answered only to an asker
  device the responder counts (responders, below).
- **Two identities (H4).** The rebuild a roster trade can trigger, and every "fetch first"
  step (owner checkpoints, retire lists, settlings), waits for answers from two distinct
  member identities or the 10 s bound. A rebuild that ran on the timeout with one identity
  runs again when a second identity's answer arrives.
- **Fetch on `Uncounted` too.** A live op whose verdict is `Missing` or `Uncounted` parks
  and sends one `rosters_wanted` ask to its carrier and one to another member, each at most
  once per (server, master) per 10 minutes.
- **The join answer carries rosters (build note, 2026-11-06).** A joiner that is nobody's
  friend holds no roster of whoever admits it, and has no Olm session to send a
  `rosters_wanted` ask on, so every op of its join answer would read `Missing` and its
  admission would park for good. The join answer's `SyncResponse.rosters` therefore holds the
  owner's and each sent op author's roster as the answerer's view holds them (authority set
  only, 256 KiB). The joiner keeps them only while that join is pending and the sender is not
  yet a member of its state, through `server_rosters`' own keep rules (the anchor owner
  before the fold, the authors it parked after), refolds once when one changed a view, and
  asks only for what that refold still refuses.
- **The answerer** sends a roster only for a master in its own authority set for that
  server, and only to an asker device its view counts for a member identity there.
- **Responders check the asker device.** Every sync and page responder (`op_sync`,
  `crdt_resync::serve`, the join answer, the `SyncRequest` arm of
  `handle_incoming_request_inner`)
  refuses an asker device its view does not count, with `roster_needed` set.

**Where co-member rosters live (H3).** A roster a co-member delivers (in an answer, an ask,
or a checkpoint's `cp_roster`) never enters the global book, the resolver or DMs. It goes
to `server_rosters(master, r_pub, json, last_needed_ms)`: each statement verifies alone;
kept only for a master in this replica's authority set of that server; bytes charged to
that author's quota group; aged out 30 days after the master leaves every authority set
held here. The view merges a `server_rosters` entry with the book's roster under the same
key; the book's key wins when they differ, except for an owner whose founding commit names
the other key.

**Removal notices.** `announce_roster_change` (sync_handler.rs 2500) also sends a
`RosterNotice` into each server room, live only; a socket the room hides still reaches its
provers (section 8.7, step 3). A `RosterNotice` is the identity's own device speaking and
keeps today's handling (the book); only a roster one member delivers about another stays
in `server_rosters`. Offline members learn in their next round, or from the settling's
`cp_roster`.

**Who may fill the book (R31-8).** A `RosterNotice` that arrives through a server room is
kept only if its master is in that server's authority set held here (the owner always is);
otherwise it is dropped and stores nothing. Anywhere else a notice is kept only for our own
master, a master with a friend row (pending either way included), or an existing
first-party path that needs a stranger's roster (a knock in a meeting we host, a pending
link), each under that path's own bound; the build lists every `RosterNotice` arm first
(Grep floor plus LSP references) and gives each one of these rules. Without this, section
8.7 step 3 made a hidden sender's notice load-bearing while a notice from a device in its
own fresh roster was kept as a first sight with no bound, so a stranger who minted
identities could fill every prover's book (section 21's open note, now closed). Track I,
`roster_book.rs`.

## 10. Stratified evaluation, the verdict as an input, restart (H1, H5, N8)

**The order.** Each step reads only what the steps before it produced:

1. **The owner's key.** The founding commit, else the book. Never a checkpoint.
2. **The owner's view.** `authority()` over the owner's statements under that key: book,
   `server_rosters` and every held `cp_roster` (statements are facts once held; holding
   one never depends on eligibility).
3. **Owner endorsements and settlings.** Owner `DeviceRetired` ops HELD in any row kind
   whose own verdict under step 2 is `Counted`, and held settle marks (the `SettleSign`
   rows of one settling id) that count (section 7: a counted signer, and the generation
   one above the `SettlePin` parent; the mark, never the checkpoint, so a dropped settling
   still confines).
4. **Checkpoint eligibility**, in three parts:
   - 4a. Rules 1 to 3 of section 7 with the settling line, from steps 2 and 3, plus the
     core's parent rule. Rules 2 and 3 read eligible checkpoints' own `cp_endorsed` and
     `cp_lineage`: a least fixed point over held checkpoints, never over the base.
   - 4b. Each identity's chosen mark (counted first, section 8.8 item 3), counted floor
     marks and the floor (section 8.8). A mark's verdict is its author's
     view of its device, which reads only that author's statements (the same function step
     6 uses, computed early); the "not eligible by rules 1 to 3" clause reads 4a. The floor
     and the drop of dominated marks read only these and the pins.
   - 4c. Rule 4: the floor and its ancestors join the eligible set, marked floor-only
     unless 4a already made them eligible, under the settling line. Floor-only checkpoints
     feed no rule 2, so 4a does not need to run again.
5. **The base.** The core's order over eligible checkpoints.
6. **Member views and the cut.** Every other author's verdict; member `DeviceRetired`
   endorsements (they name only that member's own ops, never a checkpoint, so they never
   feed steps 3 to 5); the base's `cp_endorsed` entries whose `by` is `Counted`, except
   that a floor-only base endorses no op of the owner's devices (section 8.8).
7. **The fold** (core), with the verdict clause in `op_allowed`.

There is no fixpoint: each candidate base is judged by facts fixed before the base is
chosen.

**The input.** `ServerState.authority: Arc<AuthorityView>` is never persisted and never in a
checkpoint. The node sets it before every ingest, every `author_checked` and every restore.
It is built from this replica's own store; the process-global resolver is never read.
`AuthorityView::digest_for(authors)` joins `retained_print`, so a restore whose view changed
refolds once. Rosters load before `restore_op_log` (swarm.rs 983 before 1053, kept and
tested). After a roster ingest, the servers whose authority set holds that master are
marked for the core's coalesced rebuild, at most once per 10 s per server, and only when
that master's verdict entry changed.

**Harness.** Each node builds its view from its OWN store.
`roster_book::ignore_for_test(db_path, master)` (a `cfg(test)` set like `FAIL_COMMIT`)
makes one node refuse every roster of that master, in the book and in `server_rosters`.
Transport gates (MLS seats, Olm first contact) still use the shared resolver, so harness
tests of "never held the roster" assert CRDT state, not transport refusals.

## 11. Interface to the checkpoint core (`~/dev/wt/t14-cover`)

Each item is a seam that is a no-op until track C lands:

1. `CrdtOp.dev` and the stateless proof check in `stateless_check`. `content_hash()` already
   excludes it.
2. `fn verdict(&self, op) -> Verdict`, `Counted` by default, read in `op_allowed`'s first
   clause, in eligibility and in the equivocation rank (`fold_remote`, `plan`'s dedup).
3. `plan()`'s `eligible` closure gains section 7's device rule, the carried endorsement of
   rule 2, the settling line by `cp_settled` and the greatest counted mark, and rule 4 (the
   floor, steps 4a to 4c of section 10, with the floor-only flag on the chosen base);
   `base_of` checks `cp_lineage`, `cp_cut` and `cp_settled`.
4. `RowKind` gains `CutMark`, `SettleSign` (one signature of a settling, an op),
   `SettlePin` (the stamp's parent), `FloorMark`, `FloorPin`, `RefoldPin` (a re-fold's R
   while its review is open), `Restore` and `Own` (stored, never folded); `CutMark`,
   `SettleSign`, `SettlePin`, `FloorMark`, `FloorPin` and `RefoldPin` are in `served_log`
   and the digest, evicted only by their own `keep` rules; `Restore` is served
   only to a witness ask; `Own` is reclassified as `Fold` when the base stops dominating it.
   `CrdtPayload::SettleSign` and `CrdtPayload::FloorMark` are new variants (`ServerUpdated`
   in both match blocks, never folded), classified by `plan` BEFORE the door and
   `op_allowed` with their own store conditions (sections 7 and 8.8, RC32-4, RC32-6), each
   arm in `dominance.rs`'s exhaustive match as never dominated, and each answer or send
   that carries one also carries its pinned checkpoint op.
5. Parked: the existing `RowKind::Parked`, entered only under section 7's two conditions.
6. `checkpoint_json` writes `cp_lineage`, `cp_cut`, `cp_settled`, `cp_retired`, and
   `cp_endorsed` and `cp_posts_until` by section 8.2's four rules; a new
   `settling_json(restore, dropped, t_ms)` writes `cp_settles` with its `SettleStamp`,
   `cp_roster`, and rule 4; the rollback settling of "I don't know" is the same call with
   R = the newest kept-device checkpoint or the founding op. `refold_json(restore,
   member_dr)` (the owner re-fold, RC32-3, R33-2, decisions 20 and 21) starts from the
   BASE's state, classes the dropped lane's writes by `refold_class` (Excluded, Auto,
   Unpublish, Review; `may_write_now` calls `op_allowed` on a synthetic op, R34-10),
   reverts the AUTO and UNPUBLISH ones to R's and folds the held ops on them, writes the
   pair's signed `cp_refolded` entry (listed or waiting by standing, R34-5) and pins R and
   the DR; `confirm_json(entry, chosen, put_back)` re-checks every item (R34-1), applies
   the owner's chosen items and put-backs on the current base and writes the signed
   answer. Both revert membership through `ServerState::rederive` (factored out of
   `record_event`, R33-3, with R34-8's skip and role cap) and existence with its
   sub-stamps (R33-10; access at its most restrictive, R34-7). `cp_refolded` entries
   carry `by` and `sig` and are inherited by section 8.2's rules 1 and 3; a settling
   carries R's and re-folds the pairs R lacks (D35-1); the re-fold or the confirm is done
   once the base's entry holds it.
7. `DeviceRetired`'s arm in `crdt/dominance.rs` (dominated when the base or its parent
   lists it in `cp_retired`) and in both `ServerUpdated` match blocks.
8. `retained_print` includes `AuthorityView::digest_for`.
9. `mark_authority_changed(server)` joins the coalescing tick, with the two-identity wait
   and its re-run.
10. `DeviceRetired` ranks first in its author's quota group (`allocate`).
11. `persist_op_delta` writes `seen_ms` once; `cp_seen`, `roster_seen` and `refold_answer`
    (an owner's answer until its checkpoint lands) are new small tables (additive
    migrations). The migration seeds `cp_seen` for the held base and
    parent at 0 and sets `seen_ms = 0` on existing rows (R3-4), tested on a copy of a 0.13
    database.
12. `checkpoint_witnessed` (writer rule a) also requires the roster trade of those rounds.
13. `OpDigest.base` accepts a restore point or a witnessed checkpoint as the reference
    (sections 8.3, 8.4), with `base_unknown` and `base_content` (section 9).
14. The floor trigger (section 8.8): `floor_pending` (a local table with `trigger_ms`, the
    pre-trigger base op, the pre-trigger state, the trigger leaves per group and the
    `floor_b` column; all but `floor_b` never move, R33-1, D34-1, R34-3), the previous
    owner view kept in RAM for one round, the
    deferred rebuild, B's candidate filter by `seen_ms` against `trigger_ms`, and
    `SyncResponse.floor_base` (the pre-trigger base).

Node seams outside the core (track C): `SharedServers` (a `HavenMessage` variant, lane
`Carried`, `live_only() = true`, both `match` arms of `lane()` and `live_only()`, entries
with `members`, fixed-size frames); the join box's `asker_roster` from
`Roster::placing_subset` and the box padding; `roster_book::fan_out` over the servers F is
recovering; the witness iteration over the union list and the chooser state (section 8.7);
THE HOLD (section 8.8): `recovery_hold` with its `Keep` and `Seat` levels, the pre-trigger
state and B kept in RAM beside `floor_pending`, `GroupRules::Server.held` at every place it
is built, the teardown sites with the shell (R33-11) and its door, chain record, direct
sync asks and Leave (R34-2), the settler's direct settling and door grant, the liveness
reads incl. the sync paths (R33-4) and the MLS heal and Olm gates (R34-11), all three
classes named by function in section 8.8, the silent re-ask gate, and the standing read
over the pre-trigger state; the owner's review (section 8.3): the FFI
`refold_reviews(server_id)` and `answer_refold_review(server_id, member, device, below,
chosen, put_back)` (FRB codegen), the notice and the review screen.

## 12. The relay's join lock (C4, M5): track R, COMMITTED

Status: committed on `security/0.14` (5af8f7b7) from `~/dev/wt/t14-lock` (track R). This
section is the spec of record; items 1 to 8 are unchanged since revision 3. Its brief
also carries N11 and N12, below. Items 9 and 10 are revision 3.1's follow-up for it (R3-9
as R2, decided; LOW); item 3's last sentence and item 11 come from the t14-lock finisher
(revision 3.3).

Today the lock is a master-key authority in four places: owner-signed bases, the `MAX_N`
ceiling, grants sealed to the master, and no move on a device removal. Every fix mirrors
byte for byte between `node/join_lock.rs` and `relay-uws/src/join_lock.h`, with the pinned
vectors in `test/test_join_lock.cpp` and the Rust test, changed in one commit.

1. **Owner bases are device-signed.** An owner-signed `LockLink` gains `dev: { device, sig }`
   (`#[serde(default)]`, `has_dev` on the relay). `sig` is the device key over
   `hollow-lock-dev1\n` plus the unchanged link payload.
   - The relay takes an owner base only if the device's key derives the id and its
     `RosterBook` fold for the owner master counts the device (ID-1R's fold, `roster.h`).
   - A relay holding no roster for the owner refuses the base. An owner device shows its
     roster on every connect (`show_relay`), so that costs an honest owner nothing.
   - Clients verifying a chain check the device signature, and the device against the
     owner's roster wherever they hold it.
   - The relay's fold is ID-1's, so a matured backup counts there (ID-1R's inbox rule). A
     mutual removal removes both there, and the lock stays put until the phrase settles it.
2. **Reset jumps are bounded.** An owner base is a reset only if `n <= tip.n + RESET_STEP`,
   `RESET_STEP = 2^20`. Probe `probe3_a_master_key_holder_freezes_the_relay_lock_at_max_n`
   then passes. A chain held near `MAX_N` is still extended by any valid base.
3. **Any device removal of a member identity moves the lock (M5).** The door changes, so a
   removed device of ANY member stops being a D1 prover; a removal of a mod-or-above
   identity's device also changes the change key. The remover moves it itself if its
   identity is a mod or above (before the removal leaves, section 8); otherwise the lock
   keeper (`lock_keeper.rs`, by standing) once a roster ingest shows a member device
   removed. `note_removal` gains this fourth trigger (local, roster driven; the fold is
   unchanged). The move that settles a removal is one made after no MLS group of the server
   (main and subgroups) still lists the removed leaf, judged per device, since the door
   rides the group; the remover's move ahead of the removal guards the relay's tip only and
   leaves the removal due (t14-lock review M1). When the relay refuses that move ahead of
   the removal, the remover acts at once only if the relay's newest link was made by a
   device its own identity removed; any other newer link waits for its holder's grant, and
   a mark dies with its offer.
4. **Grants are sealed per counted device.** `JoinLock.grants` keys become DEVICE ids, each
   sealed to `peer_x25519(device)`, for every device the mover's view counts for each owner,
   admin and mod, at most 8 per identity, best rank first. `open_grant` takes the device
   keypair; the core's "4 newest grants per master" becomes per device; `lock_state.rs`
   follows. A removed device never receives a new change key or door.
5. **The race the remover order closes.** Moving BEFORE publishing the removal makes the
   honest link the relay's tip when the removed device learns. One case cannot be ordered:
   a mod or admin recovering by phrase on a fresh install while its stolen device holds the
   change key; the owner's next device-signed reset settles it.
6. **Ring control** is signed by the change key (`ring_auth`) and moves with the lock.
7. **N11** (in track R's brief): a stolen mod device can extend the lock ahead of time and
   seal the change key to itself; after its removal only an owner reset recovers, which
   stalls while the owner is away. Built: a link whose `dev` names a device the relay's fold
   no longer counts is dead, and a counted device of the OWNER, or of the dead link's own
   identity, may extend an older held lock past every dead link (a sibling of the stolen
   device recovers). A link without `dev` is never dead, and another identity's older change
   key (an ex-mod's) forks nothing (t14-lock review H1).
8. **N12** (in track R's brief): a tip already at `MAX_N` stays frozen (locks frozen before
   0.14), and a member can force lock moves by linking and removing its own devices.

9. **Track R follow-up R2 (R3-9): lock writes judged by the walk. Decided 2026-11-01:
   yes.** Track R judges a link's device by ID-1R's fold: the
   `LockCounted counted` closure in the lock put arm of `ws_handler.cpp` (t14-lock, ~1832)
   calls `state.roster_book.fold(...).is_member(device)`, and the Rust model
   `join_lock::relay_put` takes the same `counted`. There a mutual removal removes both, so
   after the first move every later owner move or device-signed reset is refused until the
   phrase, M5's moves stall where the owner is the only mod or above, and removed member
   devices keep the door. The follow-up gives that closure `roster::authority(held)` from
   `roster.h` (the walk track I builds for the reserved slots, R3-1 included, mirrored from
   Rust `authority()` and pinned by `roster_vectors.json`) for lock puts only; inbox
   ownership keeps ID-1's fold. Clients judging a chain and the lock keeper choosing grant
   devices use `authority()` the same way. `authority()` has no maturity, so a matured
   unvouched backup writes no owner lock link (decision 3). It costs one more walk per lock
   put (at most 128 removals); the relay's walk includes the vouch cap of section 4
   (R31-4), which lands in the same `roster.h` change. Same follow-up: a recovery that drops a device the previous base
   counted triggers `note_removal` like a removal (section 8.7, step 7). Test:
   `t14d_after_a_mutual_removal_the_owner_still_moves_the_lock`. About 1 day, after track
   I's `roster.h` walk lands.
10. **A 0.13 relay** (self-hosted, not updated) gives a 0.14 owner no lock protection. The
    relay's version is known to the app, so an owner whose server sits on an older relay
    sees a warning (LOW, appendix A).
11. **Track R2 item: the lock put's breaker price (t14-lock finisher, 2026-11-04).** The
    breaker plan for `lock_put` charges `SIG_W` per link, but a 0.14 link costs two
    signature verifies (`dev` and the change key). Fix: charge `2 * SIG_W * n` for `n`
    links, in `ws_handler.cpp`'s `plan_text` (its `lock_put` arm), the client mirror
    `relay_pace.rs` (its `lock_put` cost) and
    `breaker_vectors.json`, in one change (CLAUDE.md: the breaker and its client mirror
    change together). Until then a lock put is charged half its verify work. The breaker
    runs in SHADOW today and its enforce switch is planned for 0.14 (`SECURITY_AUDIT_2026_10.md`
    section 6.2), so this item ships no later than the relay deploy that flips it
    (section 17). Test: the regenerated
    `breaker_vectors.json` case for a 0.14 chain, replayed by Rust and the relay.

**Deploy order.** The relay deploys before the clients (official and self-hosted). A 0.13
owner's unsigned base reset is refused by a 0.14 relay. 0.13 links (no `dev`) keep extending
a chain only until its first link carrying `dev`; after that a new link needs a counted
device. That first 0.14 move also cuts off every 0.13 MEMBER, not only the mods: the `dev`
field makes the `JoinLock` op unreadable to a 0.13 build (UNREAD), so a 0.13 member holds no
newer door, loses the D1 room view (roster, presence, broadcasts, rings) and answers no joins
on that server; a 0.13 mod also cannot open a device-keyed grant and loses the change key.
Vitalik accepted this on 2026-11-02 under the RED 0.13 status notice, which tells 0.13 users
they stop seeing servers whose lock a 0.14 device has moved (accepted risk AR-38). A link
without `dev` is never dead (N11 below): only a link whose proof names a device the relay no
longer counts gives way, and only to the owner or that device's own identity. The same relay
deploy must carry track I's `roster.h` compaction change (section 4), since a 0.14 client's
roster can then exceed the old `within_caps`.

## 13. Channel posts (M6, N9)

Channel and public channel posts are master-signed (`crypto_handler::sign_message_versioned`,
374). A removed device's posts are refused live by members holding the roster
(`mls_authority::refused`), but a stale replica serves them in backfill
(`sync_handler::ingest_synced_channel_item`, 4176) and in the public channel sync response
(swarm.rs 14295).

- **The proof.** Every 0.14 post carries `dev: { device, sig }`, the device key over
  `hollow-msg-dev1:` plus the post's exact signed payload, on the wire and stored with the
  row (a `dev_json` column, additive migration). Sync answers serve it back.
- **The gate, at every backfill and sync ingest, and live (a 0.13 member's proof-less live
  post or edit dated after the cut is refused too; decided 2026-11-06).** After the server's
  cut, a post is refused unless one holds:
  1. its proof verifies for a device the author's view counts;
  2. the base's `cp_posts_until[device]`, or a held counted `DeviceRetired` for that device,
     is at or above the post's timestamp;
  3. the post is dated before the base's `cp_cut` (N9: one clock per lineage, copied and
     checked, so neither a rival early checkpoint nor a late one moves it).
- **Retire** writes the newest date of what that device proved that the remover holds:
  its posts and edits and every change proof below, each at the date the gate judged it
  (decided 2026-11-06).
  **Lost or stolen** writes T: posts dated before T keep arriving by backfill, later ones do
  not (decided 2026-11-01).
- **Changes riding a post (decided 2026-11-06, close all in 0.14).** A deletion, a link
  card, a reaction (added or removed) and a file card's metadata each carry their own device
  proof and pass the same gate at the later of the post's date and the change's own.
- **Residual.** Rules 2 and 3 compare a date the author picks: a stolen device can still
  insert posts, or changes to posts, dated before T or before the cut through a stale
  replica. That is content at an old date, not authority.

*Build notes (builders 14 and 15, `node/post_proof.rs`):* a proof covers one version of a
post (`post_proof::Version`). The post's proof signs `hollow-msg-dev1:` + the SHA-256 of the
length-prefixed (sid, cid, sender, ts, edit date empty, mid, reply_to, file_id, order_us,
album, text); an edit's signs `hollow-edit-dev1:` + the same digest with its own date and its
new text. The text is the one the master signature covers; the card is not bound, so a
preview re-sign keeps the proof. Edits carry their proof on `EditMessage.dev` and
`PublicChannelEdit.dev` and pass the same gate at max(post date, edit date), live and in
backfill (a synced item with `edited_at` is its edit). Storage is two columns, `dev_device`
and `dev_sig`, holding the proof of the version the row holds: a post's first verifying
proof, replaced by each applied edit's verified proof or cleared by an edit without one. The
gate runs live, in backfill (`backfill_filter`) and on the public answer we SERVE (a guest
holds no view to judge with); push fetch keeps the proof and judges nothing, and applies no
channel edits. Rule 2's windows are what the next checkpoint would carry
(`carried_posts_until`); the current owner's are skipped while a floor holds. Rule 3 needs a
stamped base (`cp_cut`, else its own clock). A retire's window is the newest date of the
posts, edits and changes that device proved (`newest_post_of_device`, each change at the
later of its post's date and its own). The gate reads the author's roster through the view's
source when the view holds no entry for it (`PostGate`, REVIEW-C F2): posts come from every
member, the authority set holds only authors of held ops, and a checkpoint compacts a quiet
member out of it. When the source holds no roster of that member either (`Missing`), the
refusal asks one device of ANOTHER member identity for it (never the author's: whoever holds
the author's master key could mint the roster that counts it), once per (server, member)
per 10 minutes; only that device's answer may keep the roster outside the authority set, and
its landing catches up each refused channel once (decided 2026-11-06; the authority set does
not grow). A synced item naming a post we hold must carry the held row's date and
slots (`item_matches_row`, REVIEW-C F1): an edit's master signature does not cover the
post's date, so the date the gate judges is the row's. A row holding no proof takes one
that proves the version it holds when it arrives again, live or by backfill (L1).

*Change proofs (builder fixC, 2026-11-06):* `post_proof::Change` signs `hollow-del-dev1`,
`hollow-react-dev1` (add or remove), `hollow-card-dev1` or `hollow-filemeta-dev1` + the
SHA-256 of the length-prefixed (sid, cid, signer master, mid, change date, kind fields):
the deletion's `hidden_at`; the emoji and add or remove with the reaction's date; the card's
digest (empty = cleared) with the date the device signs (`CardProof.at`, a card has no other
date); for a file card, `file_meta_digest` (file id, mime, image flag, width, height, SHA-256
of the thumbnail: what the file id does not commit to) at the post's date. Wire:
`dev` on `DeleteMessage`, `AddReaction`, `RemoveReaction`, `LinkPreviewSet` and their
`Public*` twins, `FileHeaderPayload.meta_dev`; sync items carry `hidden_dev`, `lp_dev`,
`SyncReactionItem.dev`, `SyncFileMetaItem.dev` (all serde default). Storage (additive):
`message_deletions.dev`, `channel_messages.lp_dev`, `message_reactions.dev`, `files.meta_dev`
(JSON), kept only when the proof verifies for what the row holds, served back
(`attach_change_proofs`). The gate runs live (the delete, reaction, card and file header
arms, judged at the later of the held post's date and the change's own; a live card also at
its frame's seal time), in backfill and on the public answer we serve (`filter_page`: a
refused change is stripped, the post stays; a stripped card leaves the digest its post's
signature names). A synced card lands only past the row's card or edit date by its proof's
date, and a card or file card a proof holds is never replaced by a proof-less one. Cards
received live or by sync are bounded (`link_preview::card_within_bounds`: our own fetch's
title and description caps, 4 KiB fields, 512 KiB thumbnail). Push fetch stores only.

## 14. Bounds

| Table | Bound | Over it |
|---|---|---|
| `dev` per op or post | 1 proof, about 150 bytes | a worse copy never replaces a better one |
| Roster removals | 96 general by signer rank + 32 reserved walk-first, shallowest targets first; 231,705 bytes worst case of 262,144 | the general pool's rule |
| `roster_seen` | our own identity's removals, vouches and settling stamps in the compacted roster or held marks | a dropped statement's row is deleted 30 days later |
| Roster vouches | 128, valid vouchers first, then signer rank; each device's tree vouch from its best valid voucher (R31-4) | the order's tail |
| `DeviceRetired` | 256 refs per op, ranked first in the author's quota group, at most 64 undominated per author | that author's own oldest park |
| `cp_retired` | the DR ids since the parent | bounded by the line above |
| `cp_endorsed` | 4,096 refs, each entry with its DR id and signer | oldest by clock go |
| `cp_posts_until` | 16 per author identity, 4,096 in all, each with its DR id and signer | smallest values go |
| `SettleSign` (settle marks) | one op per (settling id, signing device), the lower (ms, counter, id) kept; at most 8 per settling id, 32 settling ids per server, about 1 KB each | marks with no counted signer first; then each mark charged to its lightest counted signer, the device charged the most loses its smallest (generation, settling id) first (RC32-9, R33-6) |
| `SettlePin` | one stored copy per parent content id, 32 MiB per server | evicted with the last `SettleSign` naming it |
| `FloorMark` | stored only from a member of the named checkpoint with that checkpoint held; at most 4 per member identity (counted first, then the lowest named), 512 authors per server, in the author's quota group | per identity the order's tail; past 512 authors, by (counted, names a kept pin, lowest named, id) (RC32-6) |
| `FloorPin` | 32 distinct named checkpoints, 64 MiB per server | `keep`: one line = the 32 lowest; else the lowest fork pair plus the lowest rest; all drop under a counted settling or a dominating rule 1 to 3 checkpoint |
| `floor_pending` | one local row per server in recovery: `trigger_ms`, the pre-trigger base op, the pre-trigger state (one server state), the trigger leaves (masters per group, at most the MLS cap each) and `floor_b` | cleared when the recovery ends |
| `floor_base` | one checkpoint op per sync answer, inside the answer's size | not sent |
| `cp_refolded` | 1,024 entries per checkpoint, inherited by rules 1 and 3 of section 8.2 (a settling carries R's, D35-1); at most 256 unanswered, of which 8 listed (one per DR author identity, by standing) and the rest waiting with no items; 256 review items and 64 Unpublish records per entry | answered entries first, the oldest DR clock first; nothing closes by count: a listed entry ranked out goes back to waiting; past 256 unanswered the lowest-ranked is dropped or not written; past 256 items, the rest follow in a continuation entry (`below`) once this one is answered |
| `RefoldPin` | one stored copy per content id: R while an unanswered entry names it, the DR while its entry is unanswered and for 30 days of owner clock after the entry's `at`; 64 MiB of its own per server, inside the core's per-device ceiling | R pins of the lowest-ranked entries first (the re-fold then takes the nearest older held checkpoint as R), then DR pins of answered entries, oldest `at` first |
| `refold_answer` | one local row per unanswered entry answered on this device | dropped when the base's entry carries a person's answer |
| `cp_lineage` | 64 ids (4 KB) | fixed |
| `cp_roster` | one roster, `MAX_ROSTER_BYTES`, settling checkpoints only | the roster's own caps |
| `CutMark` | 1 row per server | the minimum (clock, id) |
| Restore points | 8 contents per server, inside the per-device ceiling | per-window newest and oldest |
| `cp_seen` | lineage (64) plus restore points per server | rotated with them |
| Own-kept ops | 16,384 ops, 64 MiB per server, 30 days (measured on the busy-server run) | those whose dominating checkpoint was first folded longest ago |
| Parked ops | `op_allowed`-passing ops of `member_record` authors, the core's quota, 30 days | the core's rules |
| `server_rosters` | masters in this replica's authority sets, and members whose roster we asked after a refused post, bytes in the author's group, 30 days after the last need | the author reads as `Missing` |
| `rd`, `rosters_wanted`, `asker_roster` | 512 pairs, 64 masters, 1 MiB answer, one roster per ask | the next round continues |
| Witness asks | 64 identities per server from the union list incl. those named in received contents: contacts sharing the server, then members friends name, then most-named; answers once per (server, asker device) per 10 min | dropped |
| Witness wait | W = 30 s after a pick first exists, restarted per witness, 2 min after the first round at most | shown |
| `base_content` | one checkpoint per ask, only after `base_unknown` | the next ask |
| `SharedServers` | 64 servers per answer, 64 member ids per server, always 4 frames of 16 entries padded to one size; once per (asker device) per 10 min, counted askers only; F re-asks per arriving friend device | dropped |
| Join box `asker_roster` | the placing subset only; every join box padded to 2, 8 or 32 KiB | the subset is omitted, the box is never refused |
| Room `RosterNotice` in the book | masters in that server's authority set only (elsewhere: own, friend rows, first-party paths under their own bounds) | dropped, nothing stored |
| Re-fold reach | only a DR with `restore` on the base's line, whose device the owner's view does not count and whose lane no device that view counts for that member shares; only that device's lane; on its own only what its member may still write and Unpublish (after T), the rest on the owner's confirm; R at most the oldest base-line checkpoint the owner first folded within 30 days; once per (member, device) | no re-fold; that checkpoint; listed |
| A hidden F's `RosterNotice` per server room | 3 frames, 10 s apart | none |
| Witness contents | 16 distinct, 64 MiB per server | contacts' first, then most named, then newest |
| Missing or uncounted roster asks | once per (server, master) per 10 min, two carriers (a refused post's: one device of another identity, 64 queued per server, 16 channels per ask) | dropped |
| View-triggered rebuilds | once per 10 s per server | coalesced |
| Lock grants | 8 devices per owner, admin or mod identity | best rank first |
| Relay reset step | `tip.n + 2^20` | refused |
| Per-device total | the core's ceiling across servers covers parked, own-kept, restore, `server_rosters`, floor and settle pin rows | the core's rule |

## 15. Data formats

| Item | Where | Format | Old readers |
|---|---|---|---|
| `DevProof` | `CrdtOp.dev` | `{device, sig}` over `hollow-crdt-dev1:` + `hollow-crdt1` payload | 0.13 ignores and strips it |
| `DeviceRetired { device, ops, posts_until_ms, restore }` | `CrdtPayload` | `OpRef {ms, c, h}` sorted, at most 256; `restore` `#[serde(default)]`, a member's lost-or-stolen restore checkpoint | 0.13: unread, kept |
| `FloorMark { cp }` | `CrdtPayload`, member-authored, device proof, never folded, classified before the door | a checkpoint content id; travels with its pinned checkpoint op | 0.13: unread, kept only from a member of its own state |
| `SettleSign { stamp }` | `CrdtPayload`, owner-authored, device proof, never folded, classified before the door | a `SettleStamp` with exactly one signature, by the op's `dev.device`; travels with the stamp's parent op | 0.13: unread, kept |
| `cp_lineage`, `cp_cut`, `cp_retired`, `cp_endorsed`, `cp_posts_until` | 0.14 checkpoint state | `#[serde(default)]` | ignored |
| `cp_settles {devices, t_ms, stamp}`, `cp_roster` | settling checkpoint state | `#[serde(default)]`; `SettleStamp {server, parent, generation, devices, t_ms, sigs}`, settling id = SHA-256 of `hollow-settle-id1\n` + the fields before `sigs`; each sig a device key over `hollow-settle1\n` + the id | ignored |
| `cp_settled` | 0.14 checkpoint state | `#[serde(default)]`, a settling id | ignored |
| `cp_refolded` | 0.14 checkpoint state, inherited from the parent (a settling: R's) | `#[serde(default)]`, `Vec<Refolded { member, device, dr, r, at, opened, below, review, unpublished, by, sig, answered }>`, at most 1,024; `review: Vec<{ key, stamp }>` at most 256, `unpublished: Vec<{ channel, stamp }>` at most 64, `opened` and `below` optional, `answered: Option<{ by, undone, kept, put_back, timeout, sig }>`, each `#[serde(default)]`; `sig` = `by`'s device key over `hollow-refold1\n` + canonical JSON of (server, member, device, dr, r, at, opened, below, review, unpublished); `answered.sig` = `answered.by`'s device key over `hollow-refold-answer1\n` + (server, member, device, dr, below, undone, kept, put_back, timeout); a failed `sig` voids the entry, a failed `answered.sig` voids the answer | ignored |
| `Endorsement {dr, by, device, refs}`, `PostsUntil {device, until_ms, dr, by}` | `cp_endorsed`, `cp_posts_until` | `#[serde(default)]` | ignored |
| founding nonce | `ServerCreated.nonce` | 32 random hex + 32 hex of `SHA-256("hollow-server-rk1:{owner}:{r_pub}")` | hashed as before |
| `OpDigest.rs`, `DigestReply.rd`, `SyncRequest.rosters_wanted`, `asker_roster`, `witness {nonce, t_age_ms}`, `base_content`, the floor-round flag, `SyncResponse.rosters`, `roster_needed`, `base_unknown`, `witness`, `floor_base` | sync, `Carried` | sections 8.4, 8.8, 9 | ignored |
| `CpWitness` | `SyncResponse.witness` | device-signed, `hollow-cp-witness2\n`, ages not dates, `folded_age_ms = -1` = before the 0.14 update | ignored |
| `SharedServers {ask, servers}` | new `HavenMessage`, lane `Carried`, `live_only` | entries `{server_id, owner, join_key, relay, members}`, at most 64, members at most 64; fixed-size frames | 0.13: unknown variant, dropped |
| join box `asker_roster` | sealed join request | `#[serde(default)]`, the placing subset; the box padded to 2, 8 or 32 KiB | ignored |
| `server_rosters`, `cp_seen`, `roster_seen`, `floor_pending` (`trigger_ms`, the pre-trigger base op and state, the trigger leaves per group, `floor_b`), `refold_answer` (pair, DR id, `below`, chosen items, put-backs, the base it was made on) | new tables | local | none |
| `seen_ms` | `crdt_ops` column | local, set once | none |
| `CutMark`, `SettleSign`, `SettlePin`, `FloorMark`, `FloorPin`, `RefoldPin`, `Restore`, `Own` | `crdt_ops` row kinds | the core's row-kind column | none |
| proof upsert | the core's row write | `ON CONFLICT ... DO UPDATE` when the rank rises | none |
| `LockLink.dev`, device-keyed `JoinLock.grants` | section 12 | track R | 0.13 opens no grant |
| post `dev` | channel and public posts, `dev_json` | `{device, sig}` over `hollow-msg-dev1:` + the signed payload | ignored |
| roster compaction | `compacted()`, `within_caps` | general 96 by signer rank + 32 reserved walk-first; vouches valid-first (R31-4) | relay mirrors; vectors regenerated; 0.13 contacts re-trade flooded rosters |

`read_op`'s `Shape` (operations.rs 158-167) gains `dev`; `UnreadOp` keeps the raw JSON, so an
unread op keeps its proof.

## 16. Mixed servers and versions

- **Before the cut** nothing changes: 0.14 ops verify at 0.13, 0.13 ops fold at 0.14.
- **After the cut** a 0.13 member's ops are proof-less and park on 0.14 replicas, its own
  leave included (REVIEW_REV2 F7). The RED notice says "leave and rejoin after updating".
- **A 0.13 relayer strips proofs**: one digest round, never an op.
- **0.13 and the relay lock**: section 12. A `JoinLock` op whose change key a 0.13 mod sealed
  to a MASTER (no device in the grant key) keeps today's handling before the cut; after it
  only device-filed grants stand (t14-lock R1; build decision 2026-11-05, lead).
- **0.13 posts** carry no proof and are refused after the cut unless dated before `cp_cut`,
  in backfill and LIVE alike (decided 2026-11-06: 0.14 is a clean break), and so are a 0.13
  member's edits, deletions, reactions and link cards dated after the cut. The RED notice
  says "update to keep posting" (appendix A).
- **0.13 witnesses**: a 0.13 member answers no witness ask and keeps no restore points, so a
  fresh-install recovery counts only 0.14 members.
- **0.13 relays and rosters**: a roster with more than 96 removals fails a 0.13 relay's
  `within_caps`; only a flooded roster gets there. A 0.14 owner whose server's relay is
  0.13 gets no lock protection and is warned (section 12, item 10).
- **0.13 contacts and flooded rosters** (LOW): a 0.13 contact compacts a roster with
  reserved slots back to 96 removals, so its AR-29 digest never matches and the two views
  re-trade on every DM, for flooded rosters only, within AR-29's own jitter, until the
  contact updates. The same holds for a roster carrying a removed device's vouch flood,
  which 0.14 caps by validity (R31-4).
- **0.13 members during a stolen-device recovery (RC32-7; accepted as a residual by
  Vitalik, 2026-11-04).** Revision 3.2 said a 0.13 member steps back as before; it does
  not. 0.13's CRDT fold reads no roster and has no device verdict, so the stolen device's
  owner-signed checkpoints stay valid there, before and after the recovery, and a 0.13
  member follows the thief's line. It never steps back and never tears down because of the
  recovery (only if that line kicks it). It writes no `FloorMark`, and keeps an unread
  `FloorMark` or `SettleSign` only from a member of ITS state (`crdt_resync`'s `vouched`),
  so it drops the marks of members the thief kicked; floors form from 0.14 members only.
  0.14 standing never elects a 0.13 device as leader (core design section 12), but 0.13
  members elect one of their own, and that committer commits what the thief's line says:
  - removals of members the thief kicked after notice: 0.14 receivers HOLD them (under the
    hold those members are not `removable`), the held commit lapses, and only a repair of
    their own leaf moves them past it;
  - adds of the thief's puppets: 0.14 receivers hold them too (not in SEAT).
  So for the length of the recovery the server's MLS group, and each subgroup, splits into
  the 0.13 members' epochs and the 0.14 members' epochs. CRDT ops still cross (the carried
  Olm twin, judged by each side's fold), but chat between the two sides stops: content
  rides MLS, plus the Olm copy only to leafless devices. 0.14 members' seats and server
  are kept. The split ends when the 0.13 member updates: its 0.14 node judges the thief's
  line as every 0.14 replica does and is re-seated by the ordinary fork repair. A 0.14
  replica does NOT merge a 0.13 committer's removals: that would let the thief's line
  evict honest members through any 0.13 member (decided, section 20). The RED 0.13 notice
  gains one line (appendix A). Harness: `t14d_a_013_committer_during_a_recovery`
  (section 18).

## 17. Residuals

- **Forged keys (AR-15).** An author whose recovery key a master-key holder forged and
  showed some replicas first is judged under different keys by different replicas. The
  founding commit removes this for the owner of a 0.14 server. The owner's devices see the
  conflict alert.
- **Legacy identities** (no recovery key yet): the master key signs legacy claims, so the
  proof protects nothing until the phrase signs a recovery.
- **A stolen device that outranks the honest one** (the genesis root) wins a mutual removal
  for server authority until the phrase recovery.
- **Equal-depth siblings (N4).** Once the genesis device is retired, every device may sit at
  depth 1, and a mutual removal goes to the lower id. A thief has even odds. The phrase
  recovery is the remedy; the dialog cannot tell the person who won, so a removal that does
  not take effect for servers shows as "Not removed for servers yet. Use your recovery
  phrase" (appendix A).
- **What predates T stays.** Everything a stolen device did before T, as the remover or the
  witnesses folded it, is kept (ID-1's model). A wrong T (later than the theft) keeps what
  the thief did in between.
- **Restore granularity.** A settling starts from a restore point up to one window older
  than T. For a T more than 30 days back, an op only a dropped checkpoint covered and every
  author has let go is lost (decision 2).
- **A T before the 0.14 upgrade (R3-4).** The upgrade seeds every first-fold record at 0,
  so for a T before it, what the device did between T and the upgrade stays.
- **Small servers and fresh installs.** With fewer than two other member identities
  answering, there is no candidate, and the person picks from the named restore points
  (decision 1).
- **No honest member online in the window.** Two puppets the thief admitted after T make a
  pick on a fresh install when no honest member answers within the wait (section 8.4, step
  7). The screen names the supporters, and a later honest witness re-runs the judgment
  until the person taps Restore.
- **A disjoint or forked fake lineage** with one honest witness makes the fresh-install
  choice the list of named restore points, and the person decides.
- **Two members colluding with the thief** can make a thief checkpoint continuous.
- **A stolen member device's moves that an owner checkpoint folded (R3-10).** They stay
  only until an owner device is next online and re-folds (section 8.3), and the re-fold
  reaches back at most 30 days of the owner's own first folds; a T older than that keeps
  what lies between. A member DR with no `restore` (the member's device held no checkpoint
  from before T) or one off the base's line re-folds nothing, and those moves stay. So does
  a DR naming a device the member's roster still counts, or one whose lane a device that
  roster still counts shares (R33-2, R34-4): the member must remove the device before its
  moves are undone, and a lane collision with a live device (one in 2^24 per device pair)
  leaves them for the owner to undo by hand. A removed device in the same lane blocks
  nothing.
- **What a re-fold resets (RC32-3).** An element the dropped device wrote last goes back to
  R's value, then the held ops on it fold again; an honest write to that element between R
  and the dropped device's write, whose op no replica holds any more, is lost with it.
- **What waits for the owner (decision 20, option (c); decision 21).** Everything the
  dropped device's lane wrote that its member could not write again itself now, and every
  moderation, role, access, join gate, existence and membership write whatever the
  member's role, stays as the base has it until an owner device's owner confirms it on the
  list: a ban or kick the stolen device made, a joiner it admitted, a channel it made
  private, a restriction it lifted, a grant it gave, a server it opened to joins. Declined
  or unanswered for 30 days after it is listed, it stays for good; the owner can still
  change each by hand. The one exception is a channel it made public after T, which is not
  public again at once (Unpublish); one it made public at or before T stays public until
  the owner answers, because the member's own clock dates the write before the moment it
  last had the device. A grant the stolen device gave a puppet, or a restriction it
  lifted, keeps letting those in read until the owner answers, for up to 30 days after it
  is listed (decided, item 21).
- **Unpublish can surprise the owner.** A channel the member's device made public after T
  on purpose, or one whose honest "public" write no device holds as an op any more and a
  dropped-lane visibility write out-stamped, is not public after the re-fold; the list
  shows it under "Already undone" with "Put back", and guests lose it until then. No
  member loses access either way.
- **A flood of reviews.** 256 member identities, each reporting a reviewable device, push
  the lowest-standing unanswered entry out (its reverts stand, its REVIEW writes stay);
  fewer only make lower-standing reviews wait. Nothing closes an entry by count, and an
  established member's entry outranks every fresh identity's.
- **A settling and post-R re-folds (D35-1).** A settling re-folds every pair the current
  base had an entry for and R lacks, but answers written after R are not carried: those
  reviews open again and the owner answers them again. A pair whose DR this owner device
  neither holds nor pins (more than 30 days after its re-fold, or pins evicted) keeps R's
  state until the member's devices serve the DR again.
- **A retire racing a sibling's checkpoint.** If a sibling owner device writes a checkpoint
  after it learns of a retire and before the remover's re-signing checkpoint lands, and
  wins the tie, the retired device's `cp_refolded` entries drop there and their pairs
  re-fold once more: items the owner kept are listed again once (section 8.5).
- **What a member reverts without the owner (decision 20, decision 21).** Only what its
  own dropped device's lane wrote and it may still write itself with its current role
  (the server name, channel names, slow mode, media-only, pins, layout, the allowlisted
  settings, its own nickname, Twitch name, pledge and cosmetic labels), plus Unpublish,
  once per (member, device). A member that declares its own live-until-now device lost to
  undo such writes gains nothing it could not do by hand; Unpublish takes from guests
  only, never from a member, and the owner can put it back. A former mod can no longer
  revert its own bans, kicks or admissions: they are listed, and the owner decides.
- **An owner that selects everything.** "Select all" undoes every listed write, including a
  former mod's honest kicks if the DR was the mod's trick. The list names each item and
  what its undo opens (appendix A); nothing is preselected. An undone deletion brings a
  channel back for admins only, and an undone kick brings the member back as `Member`
  unless the item names its old role (R34-7, R34-8).
- **Endorsements a counted owner device attributes to another signer** (section 8.2) stand
  until a lost-or-stolen settling drops them; retiring trusts the retired device.
- **A T earlier than needed** also removes honest devices linked ONLY from the stolen one
  after T (section 8.6; a device another device also vouches is never affected, R31-3),
  and undoes more server changes; the person can remove again with a later T only before
  the removal is published.
- **A server the recovered owner has not reached yet** (sections 8.7, 8.8): members keep
  the floor, the server as they held it when they heard of the recovery. What the thief
  changed between T and that notice stays there until F reaches it and settles.
- **A post-notice thief checkpoint through a puppet answerer (RC32-2).** A member whose
  floor round reaches puppet answerers can take the thief's post-notice checkpoint as its B
  and mark it. The floor is the minimum over all members' marks, so it stays honest while
  one member marked a pre-notice base; if every member's round met only puppets or
  answerers that had folded it before their own trigger, it is the floor. At that member
  such a B moves only its mark and its KEEP set: the members it names are never removed
  there, but none is seated, given a Welcome leaf or a subgroup through it (R33-1), and
  standing and placement still read the member's own pre-trigger state.
- **A killed floor.** One mark on a fork, by a pre-notice puppet or by a free identity the
  thief names in a checkpoint it fabricates (R33-8), or different checkpoints fed to
  different members before notice, ends the floor, and members step back as revision 3.1 did until
  F settles, and permanently on a server F never reaches (RC32-11): channels and roles only
  those checkpoints held are missing meanwhile (the banner of appendix A says why). No one
  but the owner is a member in that state, so `live_channel_post_refusal` refuses every
  post there. The hold keeps every member's seat and server, so a settling restores
  everything, and it reaches a member that was offline when it went out through any
  co-member, not only an owner device (R33-4). The thief never gets its own version
  adopted.
- **The stolen owner device keeps the door in a floorless recovery (R33-9).** No lock move
  is made from a stepped-back state, so until F moves the lock, the stolen owner device
  still holds the current door and change key: it stays a D1 prover (roster, presence and
  ring view of the room) and keeps ring control (`ring_auth`). On a server F never
  reaches, that lasts for good. Content stays sealed: its MLS leaf is `refused` and swept
  (the hold never protects a refused leaf), and its CRDT ops are refused by the cut.
- **The hold keeps seats it cannot judge.** While a server is in recovery, every member of
  this replica's OWN pre-trigger state keeps its MLS seat, including puppets a thief
  admitted in what this replica folded before its trigger, and so does every member of its
  B (R33-1). For a member that hears of the recovery late, "before its trigger" includes
  what a pre-notice puppet steered it to fold after notice (R34-3): an identity seated
  there before the trigger keeps that seat, but the hold seats no one new except masters
  that held a leaf in that group at the trigger or whose admission the new view counts.
  KEEP through B is B's checkpoint content only, so at a stale replica it lacks members
  admitted above every checkpoint; their leaves can be swept there, which splits only that
  stale replica's own fork until it catches up (R34-9). It
  ends for a member at the settling, or by a kick, ban or leave this replica first stored
  after its trigger; in a floorless state mods hold no role, so only the member's own
  leave or the owner's kick or ban ends it there (RC32-12).
- **A floor-state mod's kick during a recovery (R33-11, R34-2).** In a floor state, a mod
  the floor's checkpoint names (a pre-notice puppet the thief promoted, possibly) can kick
  or ban a member after notice, and the current fold admits it. The member loses its seat
  and becomes a shell (section 8.8) until the recovery ends; it reaches the settling by
  its own direct asks and the settler's direct send, and a member the settling keeps is
  re-seated. Its chat there stops meanwhile, and under D1 it sees no roster or presence
  of that room until the settler's door grant.
- **0.13 members split from 0.14 members during a recovery (RC32-7, decided 2026-11-04).**
  A 0.13 member follows the thief's line, and its committer's removals and puppet adds are
  held by 0.14 members, so the MLS group and its subgroups split and chat between the two
  sides stops until the 0.13 member updates (section 16). 0.14 members keep their seats
  and the server. The RED 0.13 notice says so (appendix A).
- **Compaction merge order** (section 4): a replica can transiently hold a compacted roster
  missing a walk-first removal; the next roster trade restores it.
- **Transient admission at a stale replica** until its next two-identity round.
- **A join subset that leaves out a removal** (section 8.7, step 4) places the device only
  at a member holding nothing newer about that roster, until the roster trade.
- **A mod or admin recovering by phrase on a fresh install** races its stolen device for the
  lock; the owner's next device-signed reset settles it.
- **Backdated posts** before T or before the cut (section 13).
- **A lock put under-priced until track R2 item 11** (section 12): the breaker charges one
  signature per link where a 0.14 link costs two. While the breaker is in SHADOW it only
  measures low; item 11 ships no later than the deploy that turns enforcement on.
- **Before the cut** nothing changes, under the RED notice.

### 17.1 Build-time list (final re-check of revision 3.5, `RECHECK_REV35.md`, verdict BUILD)

No realistic HIGH. Each item is either built as written here ("to build" until its build step lands) or carried as the residual
named. Track C1 owns M1, M2, L1 to L4, L6, L8 to L11; track C2 owns L5 (the shell's copy) and
L7 is shared (C1 keeps the shell out of every membership read, C2's door code reads it).

- **Build notes, step 3 (builder 4, 2026-11-05).** (a) `cp_settles` holds the
  `SettleStamp` alone: its `devices` and `t_ms` are the stamp's own fields. (b) Decided by the lead
  (2026-11-05): a member's lost-or-stolen `DeviceRetired` never vouches for what the thief
  did. It names, and so endorses, only ops of the dropped device that the remover first
  stored before T (`seen_ms < T`), never one first stored at or after T. `seen_ms` dates
  the CONTENT a row holds (`crdt_ops.content_h`): an equivocation that replaces a row at
  its key is first stored when it arrives, while a proof added to the same content keeps
  the date. A retire of a device retired normally keeps endorsing what it names. "It
  endorses nothing" in 8.2 is read as: its `restore` makes no checkpoint eligible. (c) "First seen before T" for co-signing a mark (8.5) reads the `SettleSign`
  row's own `seen_ms`, the same local first-store record `roster_seen` keeps for
  statements. (d) A server with no checkpoint yet gets an ordinary owner checkpoint first
  (from the view after the removal), so the settling has a parent its mark can pin and R
  is the founding op. (e) Built 2026-11-06: the lost removal's two-identity round with the base
  reference R (`ask_retire_round` with T: `CrdtResync::sync_ask_on_base`, the stolen device
  never asked, the same `RetireRounds` hold as M4 with T saved across a restart, no late
  re-mint); it runs before the lock move and the local removal, so the settling (owner) and
  the lost retires (member) are written from what the round brought. The order of step 5
  is built too (lead decision 11-05: settling and marks before the published removal).
  (f) The retire round (M4) asks up to 3 identities per server (one device each) plus the
  retiring device itself, and waits for 2 (or every one asked).
- **M1 (D35-1), to build (settling, build step 3).** A settling carries every post-R answer whose `answered.by` the
  settling still counts, each item re-checked as at confirm (R34-1). Without it an owner's
  ordinary later device loss (T after the folding checkpoint, before the answer) re-applied a
  stolen member device's undone kick and re-admitted an undone puppet. Answers by a device
  the settling drops are not carried (they re-open, as D35-1 stated).
- **M2 (R34-3), residual.** SEAT reads trigger leaves from this replica's own MLS tree. An
  honest late member whose tree lags its CRDT holds every catch-up commit or Welcome adding
  a master the dropped owner device admitted after its last merged epoch, so it cannot read
  the server group until the recovery ends (never, where F never reaches).
- **L1, residual.** Subgroup SEAT has no counted-grant escape: a member granted access just
  before the trigger, not yet in the subgroup, waits for the end of the recovery.
- **L2, residual (deliberate).** A waiting entry never times out, so while 8
  higher-standing authors are listed its REVIEW writes stand. A timeout would close it as
  kept, which makes the same writes stand for good without the owner ever seeing them;
  waiting keeps the list's promise that the owner sees it once a slot frees.
- **L3, to build (owner re-fold review list, build step 7).** Past 1,024 entries, answered entries are evicted by standing (the
  lowest-standing DR author first, then the oldest DR clock), as unanswered ones are, never
  by DR clock alone.
- **L4, to build (witnesses, build step 5).** F's settling (section 8.4) names the witnessed base it replaces as its
  pre-settling base for the direct send, and the direct settling plus `DoorGrant` fan-out is
  paced through `frame_budget`.
- **L5 (C2).** On a server whose recovery never ends here, the shell's banner points to
  Leave (its 30-minute direct asks stay, bounded per server).
- **L6, to build (settling, build step 3).** The settler's `DoorGrant` goes to `devices_for(master)` (roster-counted
  devices), never a removed device.
- **L7, to build (shells, with the hold, build step 6).** `door_room::answer_ask`'s own-membership gate never reads a shell as
  membership: a kicked member answers no `DoorAsk`.
- **L8, to build (shells, with the hold, build step 6).** A server turning into a shell clears the lock keeper's `in_flight`, so a
  shell never authors a `JoinLock` from `on_chain`.
- **L9, residual.** Unpublish compares HLC `physical_ms` with T; a peer's drift (up to
  `MAX_DRIFT_MS`) can put an honest "made public" just after T. Put back covers it.
- **L10, to build (owner re-fold review list, build step 7).** On a non-private server, a puppet re-admitted after its own leave evades
  the undo of its admission; the review item offers a kick by hand instead of nothing.
- **L11, deliberate.** The answer signature binds (pair, dr, below), not the entry instance
  (`r`, `at`), so an honest device's stored `refold_answer` also applies to the settling's
  re-run entry. That matches the owner's intent and is kept.

## 18. Tests

Every probe from all four reviews is ported and must pass under revision 3.5. The roster
ones run green on the standalone copy (`.team/devproof3/rev31_walk.log`, and with the vouch
cap `.team/devproof3/rev32_vouch.log`; `probe3_a_...` stays superseded by `rev3_d3`). The
review's chooser and floor models are ported as property tests (C15, C40).

**Unit, track I (identity, `roster.rs`, `roster_book.rs`):**

| Id | Test | Proves |
|---|---|---|
| I1 | `authority_ignores_first_sight_and_maturity` | H5 |
| I2 | `a_minted_key_and_a_recovered_away_thief_never_count` (incl. `probe2_a_recovery_forgets_that_the_thief_was_removed` restated as `rev3_d2`: the predicate is counted, so its original "named removed" assert is superseded) | C2 |
| I3 | `a_removed_device_cannot_uncount_the_device_that_removed_it` (`probe3_a_...` restated for `authority()` as `rev3_d3`; ID-1's fold still removes both; the tie `rev3_n4`; R3-1's `review3_a_removed_thiefs_puppet_cannot_uncount_the_device_that_removed_the_thief` and `review3_a_puppet_two_levels_under_a_removed_thief_cannot_remove_the_root`, each RED without clause 2) | C3, N4, R3-1 |
| I4 | `a_device_never_floods_out_a_removal_of_itself` (`probe3_a_stolen_root_device_...` = `rev3_d4`, `probe4_the_new_key_keeps_...`) | H2 |
| I5 | `a_thief_flood_never_pushes_out_the_roots_removal_of_it` (`probe4_a_thief_floods_...`, `probe4_a_thiefs_puppets_...`) | N1 |
| I6 | `a_voided_best_signer_does_not_hold_the_reserved_slot` (`rev3_n1`, RED under the literal reading) | N1 |
| I7 | `compaction_is_idempotent_and_keeps_the_walk` | N1 |
| I8 | `the_largest_roster_with_reserved_slots_fits_on_the_wire`; `the_largest_roster_fits_on_the_wire` and `authz_a_members_flood_never_displaces_a_signer_closer_to_the_phrase` with the new cap | N1 |
| I9 | `roster_vectors.json` regenerated (`HOLLOW_WRITE_ROSTER_VECTORS=1`) with a reserved-slot case and a voided-signer case; the relay replays them | N1 mirror |
| I10 | `lost_or_stolen_re_signs_only_removals_first_seen_before_t`; `lost_or_stolen_drops_devices_the_thief_linked_after_t` (named in the dialog, older dependent vouchees listed ON, `keep_vouched` excludes the removed ones); `lost_or_stolen_never_removes_a_device_the_thief_vouched_after_t_that_another_device_holds` (RED with the rev 3.1 first-seen test alone); `a_roster_seen_row_outlives_its_statement_for_30_days` | N3, R3-5, R31-3, LOW |
| I11 | `retiring_re_signs_every_removal_of_the_retired_device` | C3 |
| I12 | `the_bare_master_counts_only_where_its_statements_do` | G1 |
| I13 | `a_deep_thief_that_empties_the_walk_is_undone_by_the_root` (`rev3_n2`) | N2 |
| I14 | `co_member_rosters_never_reach_the_book_and_age_out` | H3 |
| I15 | `the_compaction_walk_ignores_a_removed_thiefs_puppet` (`rev31_...`: RED with clause 2 only in `authority()`, GREEN with it in both) and the same case in `roster_vectors.json` for `roster.h` | R3-1, compaction layer |
| I16 | recovery screen widget test: "Longer ago, or not sure" on a fresh install = "I don't know" for every server, T = 0; the pick screen names supporters; the dated list is the normal "choose a restore point" screen; "before the 0.14 update" for a seeded record; on a fresh install every other device starts unticked; "ask a member for an invite" when no server is known; the member banner while a server steps back | R3-8, 8.7, R31-1, R31-2, LOW |
| I17 | `a_removed_devices_vouch_flood_never_uncounts_a_device_another_voucher_holds` (`review31_...`, RED on the rev 3.1 and the shipping compaction; asserts `authority()`, ID-1's `fold` and the kept vouch), the same case in `roster_vectors.json` for `roster.h` | R31-4 (shipping, HOL-SEC-189) |
| I18 | `a_strangers_roster_notice_in_a_server_room_stores_nothing`; `a_roster_notice_from_a_master_we_know_nothing_of_stores_nothing`; `the_owners_roster_notice_in_its_room_is_kept` | R31-8 |
| I19 | `the_placing_subset_places_the_device_and_fits_the_box` (and a member holding a removal the subset omits still refuses the device) | R31-7 |
| I20 | `lost_or_stolen_co_signs_settling_stamps_first_seen_before_t` and `retiring_co_signs_every_stamp_of_the_retired_device` (`roster_seen` stamp rows; each co-signature a `SettleSign` op) | R31-5, RC32-4 |
| I21 | property test `compaction_is_idempotent_under_a_vouch_flood` (`compacted(compacted(r)) == compacted(r)`, `authority()` equal to the uncapped roster's, with an honest removal without keep ranked after a flood), and the flood and idempotence cases in `roster_vectors.json` for `roster.h`; track I, `~/dev/wt/t14-ident` | RC32-10, HOL-SEC-189 |

**Unit, track C (CRDT):**

| Id | Test | Proves |
|---|---|---|
| C1 | `a_proof_binds_the_lane_and_never_the_identity` | H1 |
| C2 | `the_best_proof_wins_at_the_door_in_the_log_and_in_the_store` | H1 |
| C3 | `equivocation_ranks_by_verdict_before_hash` | H1 |
| C4 | `after_the_cut_an_uncounted_op_folds_only_if_dominated` (removed, minted, pending, bare, `Missing`, proof-less, each backdated) | C3 |
| C5 | `the_cut_stays_on_when_the_base_steps_back` (`CutMark` minimum, any order) | C3, cp_stamped marker |
| C6 | `only_an_op_the_rules_would_admit_from_a_known_author_parks` | H3 |
| C7 | `evaluation_is_stratified` (bases that would invalidate each other; a member DR naming a checkpoint is ignored; step 3 reads a DR held as dormant) | H1, N8 |
| C8 | `a_device_retired_keeps_exactly_what_its_writer_folded` | C1, C2 |
| C9 | `an_endorsement_outlives_the_device_retired_it_came_from` (base lists the DR; the named op arrives later and folds; `cp_endorsed`) | N7 |
| C10 | `a_settling_checkpoint_keeps_what_predates_t` (thief checkpoint after T, an honest sibling's checkpoint on top of it, the dropped device's ops seen before and after T, members' ops after T) | N5 |
| C11 | `a_child_raced_onto_a_settling_is_never_eligible` (`cp_roster` alone teaches the removal) | N5 race |
| C12 | `the_greater_of_two_settlings_confines_eligibility` | settlings |
| C13 | `restore_points_keep_the_newest_and_oldest_per_window` (hourly thief checkpoints) | restore |
| C14 | `an_author_keeps_its_own_ops_until_a_30_day_old_checkpoint_covers_them` (and they fold again after a step back; the 16,384-op bound) | N6, decision 2 |
| C15 | `witnesses_pick_the_newest_continuous_checkpoint` (honest line; a thief descendant with puppets; a fork from an older ancestor; one colluding member; heavy member turnover); `witnesses_one_honest_member_blocks_a_puppet_line` (one honest witness naming the pre-T checkpoint, two puppets on a descendant, on a fork, on a disjoint lineage); `witnesses_an_intermediate_puppet_checkpoint_cannot_shadow_the_honest_one` (Ch, Y, X_t with 1, 2 and 3 honest witnesses; RED under the nearest-P rule); property test `the_chooser_never_picks_a_post_t_checkpoint_past_one_honest_witness` (the model's fuzz, 20,000 worlds) | 8.4, R3-2, R31-1 |
| C16 | `a_disjoint_lineage_makes_the_choice_ambiguous` | 8.4 |
| C17 | `a_witness_counts_only_from_a_member_of_the_checkpoint_it_names` (and one per identity) | 8.4 |
| C18 | `witness_asks_are_bounded_and_refused_to_an_uncounted_asker` | 8.4 |
| C19 | `the_post_cut_clock_is_the_lineages_first_stamped_checkpoint` (a rival early and a late checkpoint move nothing; a child with another `cp_cut` is no base) | N9 |
| C20 | `a_lost_devices_posts_before_t_arrive_and_after_t_do_not` (backfill and public sync, each alone) | M6, N9 |
| C21 | `an_ask_carrying_its_roster_is_served_to_a_newly_linked_device` | N10 |
| C22 | `a_timed_out_rebuild_runs_again_when_a_second_identity_answers` | H4 |
| C23 | `a_self_removed_owner_freezes_the_base` | freeze |
| C24 | `the_committing_nonce_fits_the_relays_shape_and_derives_the_id` | section 5 |
| C25 | `a_responder_serves_no_uncounted_asker_device` | H4 |
| C26 | `lineage_and_cut_mismatches_make_no_base` (and `cp_settled`) | section 7 |
| C27 | `a_settling_confines_eligibility_after_it_is_dropped_and_past_64_generations` (settle marks only (`SettleSign` rows), any arrival order, the 32 bound with puppet marks; ancestors read from the pinned parent) | R3-3 |
| C28 | `a_lost_device_removed_right_after_the_upgrade_restores_the_pre_upgrade_base` (migration on a copy of a 0.13 store) | R3-4 |
| C29 | `an_endorsement_survives_two_checkpoint_generations` (and eligibility rule 2 through a carried entry) | R3-6 |
| C30 | `a_settling_drops_endorsements_signed_by_the_dropped_device` (and refs to its ops not seen before T; an entry whose signer is uncounted drops on inheritance) | R3-6 |
| C31 | `a_witness_with_a_slow_clock_names_a_checkpoint_before_t` (ages; chooser dates from ages) | R3-7 |
| C32 | `continuous_candidates_on_sibling_forks_are_ambiguous` | R3-8 |
| C33 | `an_answerer_that_dropped_the_base_says_so_and_judges_the_sent_one` | R3-8 |
| C34 | `the_pick_waits_for_more_witnesses_and_a_late_one_re_judges` | R3-2 |
| C35 | `a_stolen_mods_post_t_ban_inside_an_owner_checkpoint_is_refolded`; `a_refold_that_loses_a_tie_runs_again`; `a_refold_reads_t_only_on_the_members_clock` (owner clock hours off; the DR's `restore` decides); `a_members_refold_never_reaches_past_30_days`; `a_member_retire_never_refolds` (RED on revision 3.2); `a_dr_without_restore_or_off_the_line_never_refolds`; `a_refold_never_undoes_another_masters_ban_or_admission` (an offline mod's ban and an offline admitter's admission after R, held only in the base; RED on revision 3.2); `a_refold_reverts_only_the_dropped_devices_lane` (a sibling lane of the same member, an LWW register, a channel `Stamps` field, a member span's `admitted` and `until_hlc`, a DR-named op that stays); `a_sibling_owner_device_never_refolds_a_pair_in_cp_refolded` (and `cp_refolded` is inherited by every child); `a_dr_naming_a_still_counted_device_never_refolds` (RED on revision 3.3); `a_dr_whose_lane_collides_with_a_sibling_never_refolds` (a ground key in a live sibling's lane; RED on revision 3.3); `a_refold_reverts_only_the_dropped_devices_lane` extended (after the owner confirms a kick's undo, a later admission and a later removal of that member arrive, and the revert holds; RED with a span edit instead of `rederive`); `a_reverted_existence_resets_its_sub_stamps_and_refolds_held_ops` (an honest rename after R, held as an op; RED with the existence stamp reverted alone); `a_refold_from_a_0_13_shaped_r_uses_covers`; `a_fabricated_or_uncounted_cp_refolded_entry_suppresses_nothing` (an entry whose `by` is uncounted, one a settling drops, one naming another pair's DR held here; RED on revision 3.3); `a_second_siblings_dr_never_relists_what_the_owner_declined`; `retiring_an_owner_device_re_signs_its_cp_refolded_entries` (entries and answers, in one checkpoint before the removal is published); `a_lane_twin_vouched_by_the_stolen_device_never_blocks_its_refold` (a ground key in the stolen device's lane, vouched by it and removed with it; RED on revision 3.4); `undoing_a_deletion_brings_access_back_at_its_most_restrictive` (an honest admin restricts the channel after R, the stolen device deletes it, the owner confirms the undo weeks later: `AdminPlus`, no label gates, not public, the base's access sub-stamps, `channel_readable_by` refuses a plain member; an access label's undone deletion restores no stripped assignment; RED with R's values); `a_membership_undo_skips_a_member_with_a_newer_event` (kicked by the stolen device, rejoined through an honest `Admit`, the owner confirms the kick's undo: nothing changes; a ban unit with its register changed since is skipped too; RED on revision 3.4); `a_reopened_span_comes_back_as_member_unless_the_item_names_the_role` (R's role Moderator: the item says "comes back as Moderator" and the confirm restores it; with the role cap removed and the item silent, RED); `a_settling_reruns_a_post_r_refold_and_reopens_its_answer` (an honest owner sibling re-folds and the owner answers after R; the owner then settles a stolen owner device with that R: the member device's writes stay reverted in the settling itself, the review opens again; RED with the current base's `cp_refolded` inherited) | R3-10, R31-10, RC32-3, R33-2, R33-3, R33-7, R33-10, R34-4, R34-7, R34-8, D35-1 |
| C36 | `shared_servers_answers_only_a_counted_device_once_and_only_shared_servers` (lane `Carried`, `live_only`, the 64 bounds, `members` by standing, fixed frame sizes, re-ask on a friend device's arrival) | 8.7, R31-9, LOW |
| C37 | `a_retired_signers_endorsements_survive_its_retirement` (and a lost one's after-T DRs do not); `retiring_the_signer_of_a_carried_endorsement_keeps_the_endorsed_ops` (the DR is gone, only the base's `cp_endorsed` and `cp_posts_until` carry it) | R3-6, 8.5, R31-6 |
| C38 | `retiring_the_device_that_settled_keeps_the_settling_line`; `two_signers_of_one_settling_share_one_mark` (one settling id, merged signatures, `cp_settled` unchanged); `a_stamp_with_a_jumped_generation_never_counts` (no pinned parent, or generation not parent plus one); `a_co_signature_reaches_a_replica_that_held_only_the_retired_signers_mark` (two replicas, different signature sets, one digest trade; RED with signatures merged into one undigested row); `a_settle_pin_reaches_a_replica_after_the_core_dropped_the_settling`; `settle_marks_evict_the_heaviest_signing_device_first` (32 jumped-generation marks of one counted device push out no other signer's mark); `an_honest_mark_co_signed_by_the_stolen_device_is_never_evicted_first` (at a replica still counting the stolen device, which co-signs the honest settling and sorts first; RED with first-signer charging) | R31-5, RC32-4, RC32-9, R33-6 |
| C39 | `a_floor_keeps_the_members_base_when_the_only_writer_is_dropped`; `a_floor_never_moves_past_an_honest_mark`; `a_puppet_mark_on_a_fork_falls_back_to_the_step_back`; `a_settling_overrides_the_floor`; `floor_only_checkpoints_endorse_nothing` (no rule 2, no owner-op endorsement or post window); `a_floor_mark_waits_for_the_round_and_names_the_newest_base`; `a_mark_from_the_owner_or_a_non_member_never_counts`; `a_checkpoint_the_dropped_device_writes_after_notice_is_never_the_floor` (X_t written at notice, every member's round; RED on revision 3.2; a stale member still marks the newer honest base an answerer returns) | R31-2, RC32-2 |
| C44 | `a_removed_sibling_cannot_displace_a_members_floor_mark` (an uncounted mark naming M's oldest checkpoint; RED on revision 3.2's lowest-first choice); `a_floor_mark_from_a_non_member_of_its_checkpoint_or_without_its_pin_is_not_stored` (classified before the door and `op_allowed`, in a stepped-back state); `floor_marks_keep_four_per_identity_and_512_authors`; `a_free_identity_named_in_a_fabricated_checkpoint_only_kills_the_floor` (the mark is stored, the floor dies or stays honest, never the fabricated one) | RC32-6, R33-8 |
| C45 | `a_thief_checkpoint_after_notice_seats_no_new_identity_during_the_hold` (unit on `GroupRules::Server.held`: an add, a committer, a Welcome leaf and a KeyPackage sender named only by a received pin are held; RED on revision 3.2's pin-based set); `a_puppet_floor_base_never_seats_an_identity_the_pre_trigger_base_lacks` (B = a post-notice X_t a puppet answered, naming a fresh Z with a restricted channel's access: Z's add, Welcome leaf, KeyPackage and subgroup are held, Z never leads by standing, its frames are not placed; RED on revision 3.3, which held from B); `a_stale_members_newer_co_members_in_b_are_never_removed` (members only B names keep their leaves; RED with KEEP narrowed to SEAT); `an_honest_answerer_never_passes_on_a_steered_b` (its `floor_base` is its pre-trigger base; RED returning B); `a_held_subgroup_reads_the_pre_trigger_states_channel_access`; `a_post_trigger_kick_or_ban_ends_the_hold_and_a_refolded_old_one_does_not`; `only_the_owners_kick_or_our_leave_tears_down_during_a_recovery` (a floor-state mod's kick leaves the shell; RED on revision 3.3); `a_late_member_steered_by_a_puppet_sync_seats_no_post_notice_identity` (a member offline at notice; a pre-notice puppet answers its first sync and withholds F's statements; it folds the stolen device's post-notice admission of Z and its grants under the previous view; after its trigger Z's add, Welcome leaf, KeyPackage and subgroup add are held, while a member an honest mod admitted above the last checkpoint is still seated; RED on revision 3.4's SEAT = pre-trigger members); `keep_protects_a_subgroup_leaf_by_the_fold_then_the_pre_trigger_state_then_b` (a B-only co-member's subgroup leaf is kept at a stale replica; a member whose access an op revoked just before the trigger loses its subgroup leaf; RED with either reading of revision 3.4); `the_mls_heal_gates_read_keep_during_a_recovery` (`handle_epoch_hint`, `MlsCommitCatchup`, both `MlsKeyPackageRequest` gates, the Olm reconcile relationship gate and the digest `learn`, each in a stepped-back state); `no_silent_reask_during_a_recovery_or_in_a_shell` (`refused_own_admission` true in a stepped-back state: no `JoinServer`; RED on t14-cover's M2 alone) | RC32-1, RC32-12, R33-1, R33-11, R34-3, R34-9, R34-11 |
| C46 | `standing_during_a_recovery_reads_the_pre_trigger_state` (a ground-id puppet with the lowest id never leads, nor one only B names; with a floor, standing reads the fold) | RC32-8, R33-1 |
| C47 | Decision 20, option (c): `refold_class_covers_every_element_kind` (exhaustive over `CrdtPayload` and every `Stamps` field: `ServerCreated`, `ServerCheckpoint`, `JoinKeySet`, `JoinLock`, `ServerDeleted`, `DeviceRetired`, `FloorMark` and `SettleSign` Excluded); `refold_class_autos_only_allowlisted_setting_keys` (each allowlisted key AUTO for a still-permitted author; `is_private`, `max_members`, a `twitch_*` key and an unknown key REVIEW; RED with `setting_allowed_for`'s match); `may_write_now_is_op_allowed_on_a_synthetic_op` (a role or override change that `op_allowed` reads moves the class); `a_refold_reverts_on_its_own_only_what_the_author_may_still_write` (a still-admin's channel rename and slow mode revert at once; a demoted mod's rename is listed); `moderation_roles_access_existence_and_admissions_always_wait_for_the_owner` (a ban, a mute, a role on another member and on the author, a grant given and one revoked, a channel made private, a restriction lifted, a label's access flag, a channel deleted and one created, a joiner it admitted, its own leave: none reverts until confirmed, whatever the author's role; RED on revision 3.3); `a_refold_never_reopens_a_channel_or_opens_joins_without_the_owner` (`visibility`, `vis_labels`, `is_private`, `max_members`, a revoked grant); `the_owners_confirm_applies_only_the_chosen_items_and_skips_changed_ones`; `keep_all_keeps_the_items_shown_and_the_rest_continue` (a 300-item re-fold: "Keep all" on the first 256, the next 44 open as the continuation, no second re-fold lists the first 256); `an_unanswered_review_closes_as_kept_after_30_days_of_owner_clock` (shown "Closed after 30 days"); `a_local_answer_made_before_a_timeout_close_still_applies` (R34-12; a second person's answer never replaces the first); `the_first_answer_to_land_is_the_answer_on_every_owner_device` (two owner devices answer differently; one landing order each way); `an_owner_device_without_r_applies_a_review_through_the_refold_pin`; `rederive_after_removing_events_equals_a_record_built_without_them` (property test over random event lists: spans, `members`, roles of a re-opened span, `join_lock` removals). R34-1: `a_cp_refolded_entry_attributed_to_another_owner_device_suppresses_nothing` (a stolen owner device writes an entry with `by` = the honest sibling: its `sig` fails, it suppresses, shows and applies nothing; RED on revision 3.4); `a_review_item_outside_the_dropped_lane_is_never_shown_or_applied` (a forged or stale item naming an honest mod's ban, another lane of the member, a DR-named op, an Excluded kind; RED on revision 3.4); `a_stolen_owner_devices_keep_all_reopens_at_the_settling` (its signed "Keep all" after T is gone with the settling); `an_entry_or_answer_with_a_bad_signature_is_void`; `a_back_dated_opened_fails_the_signature`. R34-5: `a_review_flood_never_closes_another_members_review` (12 fresh identities each report a reviewable device: an established member's listed entry stays listed and is never answered by count; the fresh ones wait; RED on revision 3.4); `a_higher_standing_authors_review_sends_a_lower_one_back_to_waiting` (and it lists again, re-walked, once it ranks back in); `one_listed_review_per_author_identity`; `past_256_unanswered_the_lowest_ranked_is_dropped_and_its_reverts_stand`; `an_entry_with_nothing_to_list_is_written_answered`. Decision 21: `a_channel_made_public_after_t_is_unpublished_at_once` (whatever the author's role, also from a waiting entry; RED with Unpublish classed REVIEW); `a_channel_made_public_at_or_before_t_waits_for_the_owner` (the thief's backdated stamp too); `unpublish_needs_the_ordinary_revert_to_end_public` (R public and nothing held turned it off: REVIEW; an honest held `public` op re-lands: REVIEW); `unpublish_removes_no_members_access` (property test over random states: for every member and channel `can_see_channel_at`, `can_post_in_channel_at`, `channel_readable_by` and `channel_backfill_allowed_from` agree before and after; only a non-member's `channel_readable_by` falls; no subgroup changes); `put_back_makes_the_channel_public_again_and_skips_a_changed_one` (restricted since, or another `public` write since: skipped); `every_other_access_revert_waits_for_the_owner` (visibility, labels, a grant, a join gate, each after T: listed, not reverted) | decisions 20 and 21, R33-3, R33-5, R34-1, R34-5, R34-10, R34-12 |
| C40 | `floor_marks_converge_after_a_digest_trade` (property test porting `floor_trade.py`: 4 replicas, partial deliveries, random eviction orders, K = 2, 3, 32) and `floor_marks_are_bounded_and_keep_the_fork_pair` (`floor_model.py`'s safety and liveness counts) | R31-2 |
| C41 | `i_dont_know_writes_a_rollback_settling` (it overrides a floor; every replica folds R's state on its line) | R31-2 |
| C42 | `a_joiner_with_a_flooded_roster_still_joins` (subset in the box; subset omitted when over; never refused) and `join_boxes_pad_to_fixed_sizes` | R31-7 |
| C43 | `a_seeded_first_fold_answers_before_the_upgrade` (`folded_age_ms = -1`) | LOW |

**Unit, track R:** L1 `an_owner_base_needs_a_counted_device` (Rust and `test_join_lock.cpp`,
pinned vector); L2 `a_reset_jump_past_the_step_is_refused`
(`probe3_a_master_key_holder_freezes_the_relay_lock_at_max_n` passes); L3
`grants_open_only_for_a_counted_device`; N11 and N12 tests as track R names them.

**Harness**, at the end of `test_harness.rs` under `// t14-devproof`:

- `t14d_retiring_the_laptop_that_wrote_every_checkpoint_keeps_the_server` (C1).
- `t14d_a_standing_leaders_retired_phone_keeps_its_admissions` (C1, M4).
- `t14d_a_stolen_owner_laptop_rolls_back_to_t` (lost or stolen, T 3 days back, the honest
  phone auto-checkpointed on the thief's base, a member offline throughout) (N5).
- `t14d_a_thief_racing_a_child_onto_the_settling_loses` (N5 race).
- `t14d_members_honest_ops_come_back_after_a_step_back` (N6).
- `t14d_a_single_device_owner_recovers_from_members_witnesses` (fresh install, 8.4).
- `t14d_a_thiefs_puppets_cannot_win_the_witness_count` (8.4).
- `t14d_a_disjoint_fake_lineage_asks_the_person` (8.4, the chooser state).
- `t14d_i_dont_know_rolls_back_like_revision_2` (8.4).
- `t14d_a_removed_thief_removing_the_phone_changes_nothing` (C3).
- `t14d_a_fresh_device_key_the_roster_never_named_authors_nothing` (C2: checkpoint, delete,
  kick, role change via MLS, Olm and a laundering co-member).
- `t14d_a_phrase_recovery_keeps_the_thief_out_of_the_server` (C2).
- `t14d_a_removed_device_backdating_below_its_removal_changes_nothing` (C3).
- `t14d_a_stripped_proof_after_the_cut_changes_nothing` (C3).
- `t14d_a_stripped_or_reproofed_copy_never_censors_the_honest_op` (H1).
- `t14d_a_co_member_who_is_not_a_friend_learns_the_removal_through_sync` (H4,
  `ignore_for_test`).
- `t14d_one_withholding_answerer_cannot_keep_a_replica_stale` (H4, with the re-run).
- `t14d_an_offline_member_learns_the_removal_before_folding_the_thiefs_ops` (H4).
- `t14d_a_newly_linked_device_syncs_from_a_responder_that_never_saw_it` (N10).
- `t14d_a_matured_backup_nobody_vouched_authors_nothing` (H5, M7).
- `t14d_the_bare_master_authors_nothing_after_the_cut` (G1).
- `t14c_a_removed_owner_device_cannot_checkpoint_or_delete` (core rev 2 H8).
- `t14d_a_0_13_member_strips_proofs_and_0_14_members_still_converge` (mixed).
- `t14d_a_removed_device_loses_the_door_and_the_change_key` (C4, M5; track R).
- `t14d_a_removed_owner_device_cannot_reset_the_relay_lock` (C4; track R).
- `t14d_a_removed_devices_posts_do_not_arrive_by_backfill` and
  `t14d_a_lost_members_posts_before_t_stay` (M6, N9).
- `t14d_three_replicas_with_different_first_sights_agree_once_rosters_traded` (consensus).
- `t14d_two_puppets_and_one_offline_member_never_restore_the_thiefs_state` (R3-2: the
  honest member answers late, inside the window; and a second run where it answers after
  the pick showed but before Restore).
- `t14d_a_returning_sibling_on_the_thiefs_chain_never_splits_replicas` (R3-3).
- `t14d_a_puppet_device_linked_by_the_thief_keeps_nothing_after_settling` (R3-5).
- `t14d_a_member_the_thief_kicked_is_still_asked_for_a_witness` (R3-8).
- `t14d_after_a_mutual_removal_the_owner_still_moves_the_lock` (R3-9; track R follow-up).
- `t14d_a_fresh_install_owner_with_only_an_invite_finds_its_members_and_witnesses` (8.7:
  join answer, `asker_roster`, door ask, iterated asks, settling).
- `t14d_a_fresh_install_owner_learns_its_servers_from_a_re_added_friend` (8.7:
  `SharedServers`, a minted key gets nothing, only shared servers listed).
- `t14d_a_hidden_owners_roster_notice_reaches_provers_and_spreads_by_the_trade` (8.7 step 3,
  with the mock relay's hidden-sender reach set to 3).
- `t14d_a_recovery_in_progress_never_evicts_members_or_mls_leaves` (R31-2, RED on revision
  3.1: the owner's only device wrote every checkpoint, F's recovery reaches members, a
  puppet mark on a fork kills the floor; no MLS remove commit, no `ServerDeleted`, no
  teardown on any member; a second run with the floor keeps the base; after F's settling
  every replica agrees). Each layer alone: the sweep with the teardown gate removed, and
  the teardown with the membership gate removed, must each fail.
- `t14d_a_server_the_owner_never_reaches_keeps_its_members_and_channels` (R31-2: members
  hold the floor for the length of the run; the stolen device's later checkpoints change
  nothing).
- `t14d_a_thief_answering_the_fresh_install_join_cannot_hide_honest_members` (R31-9: the
  stolen device answers F's join with a puppet state; a friend's `SharedServers` names the
  honest members; F asks them first and settles on the honest checkpoint).
- `t14d_a_stepped_back_sync_answer_never_tears_the_server_down` (RC32-5: the step back
  arrives in a `SyncResponse`; no `delete_server`, no `remove_group`, no `LeaveRoom`, the
  server stays listed; RED on revision 3.2, whose hold missed that arm).
- `t14d_a_member_in_a_voice_channel_stays_through_a_step_back` (RC32-5: a channel absent
  from the stepped-back state; the member stays in voice).
- `t14d_a_thief_checkpoint_after_notice_seats_no_new_identity` (RC32-1: the stolen device
  writes a checkpoint naming a banned identity and a fresh one after notice, a puppet
  signs a mark on it and a pre-notice puppet holding a leaf commits their adds; no 0.14
  member merges the add).
- `t14d_a_member_retire_never_rolls_the_server_back` (RC32-3: a member retires a device;
  the owner's next checkpoint is ordinary, and an offline mod's ban stays).
- `t14d_a_013_committer_during_a_recovery` (RC32-7, the accepted split, with a 0.13-shaped
  node as in `t14d_a_0_13_member_strips_proofs_and_0_14_members_still_converge`: the 0.13
  member follows the thief's line and its committer removes a member the thief kicked and
  adds a puppet; every 0.14 member holds both commits, keeps its seat and the server, and
  no 0.14 member applies the removal; the two sides' MLS epochs differ (asserted as the
  residual); after the 0.13 node restarts as 0.14 it judges the thief's line out and is
  re-seated).
- `t14d_a_puppet_floor_base_seats_no_new_identity` (R33-1: a member's round reaches only a
  puppet answerer, which returns a post-notice X_t naming a fresh identity with access to a
  restricted channel; a pre-notice puppet holding a leaf commits its add; the member's B is
  X_t, yet no 0.14 member merges the add or seats the identity in the subgroup; RED on
  revision 3.3).
- `t14d_a_member_admitted_after_the_last_checkpoint_keeps_its_seat_through_a_step_back`
  (D34-1: a mod admits a member, no checkpoint follows, the floor dies; the member keeps
  its leaf and server everywhere; RED with the hold reading the base checkpoint).
- `t14d_a_floorless_member_offline_at_the_settling_gets_it_from_a_co_member` (R33-4: a
  floorless recovery, member A offline while F settles, every owner device offline when A
  returns, the ring expired; A gets the settling from member B; and a device A links during
  the recovery learns the server from its sibling; each gate alone RED).
- `t14d_a_puppet_mods_kick_during_a_recovery_keeps_the_shell_until_the_settling` (R33-11:
  a floor whose checkpoint made a puppet a mod; the puppet kicks a member after notice;
  the member keeps the shell, no `delete_server`; F's settling refuses the kick and the
  member is re-seated; a second run where the settling keeps the kick tears down. R34-2:
  run with D1 on and the puppet moving the lock at the kick; the shell is hidden by the
  relay, gets the settling and the door grant by the settler's direct send in one run and
  by its own backed-off direct ask to an owner device in another (the settler's direct
  send turned off), proves the new door and is re-seated; a third run where the person
  taps Leave tears the shell down at once. RED on revision 3.4).
- `t14d_a_late_member_steered_by_a_puppet_sync_seats_no_post_notice_identity` (R34-3: a
  member offline at notice reconnects to a pre-notice puppet only, folds the stolen
  device's post-notice admission of Z, then learns the removal by a roster trade; a
  pre-notice puppet leaf commits Z's add and a subgroup add for Z; the member holds both
  commits and Z never reads its posts; RED on revision 3.4).
- `t14d_a_stolen_members_public_channel_closes_at_once_and_the_owner_can_put_it_back`
  (decision 21: a member's stolen mod device makes a channel public after T and lifts a
  restriction on another; the member declares it lost; on the owner's re-fold the first
  channel is not public on every replica and a guest's sync is refused, every member still
  reads and posts there through MLS, the lifted restriction waits on the list; the owner
  puts the channel back on one device and it is public again everywhere).
- `t14d_a_stolen_mods_ban_waits_for_the_owner_and_undoes_on_confirm` (decision 20: a
  member's stolen mod device bans a member and renames a channel inside an owner
  checkpoint; the member is demoted, then declares the device lost; the owner's re-fold
  reverts nothing on its own (the author lost MANAGE_CHANNELS), lists both on both owner
  devices; the owner confirms the ban's undo on one device; the banned member is back on
  every replica, the rename stays, the other owner device shows the list as answered).

**Relay** (VPS runner): `test/run_tests.sh` and `SANITIZE=1` for `test_join_lock.cpp` and the
regenerated roster vectors (reserved slot, voided signer, the new `within_caps`). Live: a
device-signed reset taken, an unsigned or uncounted reset refused, a jump refused, a roster
with 128 removals shown and folded.

**Platform proof (track I's UI):** the remove dialog (both choices, every T answer, the
vouchee toggle) and the recovery screen (the T question, the restore chooser in all three
states) driven on the Windows fleet, an iOS Simulator and an Android emulator, before and
after in one image.

**Platform proof (track C's UI, decisions 20 and 21, R33-11, R34-2):** the owner's review
(the notice, "Already undone" with "Put back", the grouped list with nothing preselected,
"Select all", what each undo opens incl. "comes back as {role}" and "for admins only",
"Apply selected", "Keep all", "Answered on {device}" and "Closed after 30 days" on a second
owner device) and the shell banner of a member kicked during a recovery with its Leave
button, on the same three platforms, before and after in one image; widget test
`refold_review_starts_with_nothing_selected_and_names_what_each_undo_opens`.

**Mutation targets**, each in every layer that enforces it:

- Roster: `authority()` with a real `first_seen`; the walk's dead-signer rule; "walk
  ignores founding" (drop clause 2) in `authority()` (I3 must fail) and in the compaction
  walk (I15 must fail), Rust and `roster.h` each; the per-tier seeds of clause 2 in
  compaction; reserved by walk (swap in the literal best signer: I6 must fail); the
  reserved order by target rank; `within_caps` (Rust and relay); "vouch cap ignores
  removals" (drop the validity key: I17 must fail, Rust and `roster.h` each); the tree
  vouch from the best VALID voucher; retire re-signing; the before-T filter of N3; the
  after-T vouchee removal; the closure test of R31-3 (remove it: I10's R31-3 test must
  fail); the 30-day `roster_seen` keep; the room `RosterNotice` authority-set gate and the
  book gate elsewhere (I18); the placing subset (I19).
- Proof: lane check, signature check, `dev` outside the content id; best-proof rank at the
  door, in the log and in the upsert; equivocation rank.
- Cut and verdict: the verdict clause (tail path, `fold_all`, `author_checked`); the
  `cp_stamped` marker and `CutMark` minimum; both park conditions.
- Base: stratification order (held owner DRs only); eligibility by descent through
  `cp_lineage`; rule 2 through a carried entry; the settling line by `cp_settled` and the
  greatest counted settle mark; the mark bound's eviction order; the parent rule; the
  freeze (self-removal only); `cp_lineage`, `cp_cut` and `cp_settled` checks.
- Settle marks (R31-5): the signer-free settling id (put `device` back in: C38's
  two-signer test must fail); any counted signer counts; the generation-equals-parent-plus-
  one check and the parent pin (C38's jumped-generation test); retire and lost co-signing
  stamps (I20, C38).
- Floor (R31-2): the one-line rule (take the minimum without it: the fork test must fail);
  the minimum (take the maximum: `a_floor_never_moves_past_an_honest_mark` must fail);
  each counted-mark clause (verdict, not the owner, member of the content, not eligible by
  rules 1 to 3); one mark per identity, the lowest; both confinement clauses (no rule 2;
  no owner-op endorsement or post window) each alone; the settling override; `keep`'s
  fork pair (keep the 32 lowest only: C40 must fail at K = 2 and 3); the drop under a
  counted settling; the sync round before the mark; the rollback settling of "I don't
  know".
- The hold (R31-2, RC32-1, RC32-5, RC32-8), each layer alone: `GroupRules::Server.held`
  in removals (the harness test's sweep half must fail) and in adds (widen it to members of
  received pins: C45 and `t14d_a_thief_checkpoint_after_notice_seats_no_new_identity` must
  fail); the pre-trigger state's `can_see_channel` for subgroups; the teardown gate in each
  teardown site by function, `leave_evicted_server` itself and the inline `SyncResponse`
  branch each alone (`t14d_a_stepped_back_sync_answer_never_tears_the_server_down` must
  fail); the voice auto-leave read; the two sets' minus-banned and minus-removed clauses
  and their first-stored-after-trigger test (a ban during recovery must still evict; an old
  re-folded kick must not); standing over the pre-trigger state (C46).
- The hold's two sets (R33-1, D34-1), each alone: SEAT widened to KEEP (C45's
  `a_puppet_floor_base_...` and `t14d_a_puppet_floor_base_seats_no_new_identity` must
  fail); KEEP narrowed to SEAT (`a_stale_members_newer_co_members_in_b_are_never_removed`
  must fail); the pre-trigger state replaced by the base checkpoint's content (the D34-1
  harness test must fail); `floor_base` returning B (`an_honest_answerer_never_passes_on_a_steered_b`
  must fail); `floor_pending` moved to B (C45's R33-1 test must fail); the subgroup read of
  the pre-trigger state, never B's.
- The sync paths under the hold (R33-4), each gate alone: the `PeerJoined` and
  `RoomMembers` ask loops, the op_sync follow-ups, `CrdtResync::tick` and `paged`, the
  `SyncRequest` responder's two gates, `on_verified_sibling` and the
  `SiblingStateSyncRequest` arm (the R33-4 harness test must fail for each).
- The shell (R33-11): the owner-author check (accept any kick: C45's
  `only_the_owners_kick_...` must fail); the shell's teardown on a removal the settling
  keeps.
- The floor round (RC32-2): the post-trigger candidate filter (drop it: C39's after-notice
  test must fail); answered `floor_base`s taken only after `base_of` and the previous
  view's eligibility.
- Floor mark ingest (RC32-6): classification before the door and `op_allowed` (move it
  after: C44's stepped-back test must fail); the member-of-checkpoint and pin-held store
  clauses each alone; counted-first choice (lowest-first: C44's displacement test must
  fail); the 4 per identity and 512 author caps.
- Settle signatures (RC32-4, RC32-9, R33-6): `SettleSign` as an op in the digest (merge
  into one undigested row: C38's co-signature test must fail); `SettlePin` in
  `served_log`; the lower-op dedup per (settling id, device); eviction per signing device
  (smallest generation only: C38's eviction test must fail); the lightest-signer charge
  (first signer instead: C38's R33-6 test must fail).
- `DeviceRetired`: author match, device match, folded-only listing, no chains,
  `cp_retired` dominance, each of the four carry rules, the write order.
- Settling: `seen_ms < T`, the restore choice before T, `cp_roster` merge, child of the
  current base, the stamp and `cp_settled`, rule 4; the upgrade seed at 0.
- Restore and retention: the per-window keep, the 30-day own-op rule, re-fold after a step
  back.
- Witnesses: the member-of-X rule, one per identity (and the oldest on disagreement), the
  2-supporter threshold, continuity's off-line clause and its witnessed-P clause over EVERY
  named older checkpoint (nearest only: C15's intermediate test must fail), sibling forks
  ambiguous, ages instead of dates, the pre-upgrade sentinel, the wait, iteration over
  named members, the asker device check, `base_unknown`.
- Fresh install: `SharedServers` counted-asker gate, shared-only filter and `members`; the
  union member list and its ask order (the R31-9 harness test); the join box
  `asker_roster` check and never-refuse; `fan_out` over recovering servers.
- Retire carry (R31-6): re-signing from `cp_endorsed` and `cp_posts_until` (C37).
- Re-fold (R31-10, RC32-3): the member-clock T (C35), the 30-day reach, the retry until
  `cp_refolded` holds the pair; the `restore.is_some()` trigger (drop it:
  `a_member_retire_never_refolds` must fail); the on-line test for `restore`; the lane
  clause and the actor clause each alone (`a_refold_reverts_only_the_dropped_devices_lane`
  and `a_refold_never_undoes_another_masters_ban_or_admission` must fail); the DR-named
  exemption; `cp_refolded` inheritance and the once-per-pair check.
- Re-fold trigger and provenance (R33-2, R33-7): the uncounted-device clause and the
  lane-collision clause each alone (their C35 tests must fail); the entry's `by` drop on
  inheritance, the counted-`by` and same-pair-DR suppression clauses, and the retire
  re-sign, each alone.
- Re-fold mechanics (R33-3, R33-10): `rederive` replaced by a span edit (the extended C35
  test must fail); the re-opened span's R registers; the sub-stamp reset with existence
  (its C35 test must fail); the `covers` stamp for a 0.13-shaped R.
- Decision 20 (C47 and the harness test): each REVIEW class alone moved to AUTO
  (membership, moderation, roles, another member's registers, access, existence, settings
  outside the allowlist: the matching C47 assert must fail); the settings allowlist
  replaced by `setting_allowed_for`'s match; `may_write_now` replaced by "always AUTO" and
  by "always REVIEW" (both C47 role tests must fail); the confirm's skip of changed items;
  the first-answer-wins check (`the_first_answer_...` must fail); the 30-day close as kept
  and the local answer that outlives it; the `RefoldPin` keep of R and of the DR.
- Decision 21: Unpublish moved to REVIEW (`a_channel_made_public_after_t_...` must fail);
  each of its three clauses alone (effective public in the base; the stamp after T: drop
  it and `a_channel_made_public_at_or_before_t_...` must fail; the ordinary revert ending
  public: drop it and `unpublish_needs_the_ordinary_revert_...` must fail); Unpublish
  gated on a free slot (the waiting-entry case must fail); Put back's changed-since skip.
- `cp_refolded` provenance (R34-1, D35-1), each layer alone: the entry `sig` check (accept
  any: `a_cp_refolded_entry_attributed_...` must fail), the answer `sig` check, the item
  actor, lane, DR-named and kind checks at display and at confirm each alone
  (`a_review_item_outside_the_dropped_lane_...` must fail for each), the pinned-DR check;
  the settling's R entries (inherit the base's instead: `a_settling_reruns_...` and
  `a_stolen_owner_devices_keep_all_...` must fail) and its same-checkpoint re-run.
- Review slots (R34-5): close the oldest past 8 instead of waiting
  (`a_review_flood_...` must fail); rank by `dr` clock instead of standing
  (`a_higher_standing_authors_...` must fail); one listed per identity; the 256 drop
  order.
- Re-fold mechanics (R34-7, R34-8): the most restrictive access on an undone deletion
  (restore R's values: its C35 test must fail); the stripped assignments of an access
  label; the newer-event skip; the role cap.
- Re-fold trigger (R34-4): compare the lane with every device in the statements
  (`a_lane_twin_...` must fail).
- The hold (R34-2, R34-3, R34-9, R34-11), each alone: SEAT back to the pre-trigger
  members (`a_late_member_steered_...`, unit and harness, must fail); the admitted-by-a-
  counted-device clause dropped (the D34-1 harness test must fail); the subgroup SEAT
  widened past the trigger leaves; each step of R34-9's KEEP ladder; the shell's door,
  chain record, direct ask and the settler's direct send, each alone (the extended R33-11
  harness runs must fail); each R34-11 gate back to fold membership; the silent re-ask
  gate (`no_silent_reask_...` must fail).
- Rosters: `server_rosters` isolation; the two-identity wait and its re-run; the responder
  device check; `asker_roster` kept only for member identities; the view digest in
  `retained_print`.
- Relay lock: track R's list (device-signed base, `RESET_STEP`, per-device grants, the
  removal trigger, the refused-move rule of item 3), Rust and C++ each; R2's lock put price
  `2 * SIG_W * n` in `plan_text` and `relay_pace.rs` each (back to `SIG_W * n`: the
  regenerated `breaker_vectors.json` case must fail on both sides).
- Posts: the gate in backfill and public sync each alone; `cp_cut`; `cp_posts_until`.

## 19. Build split

Estimates are left out (Vitalik's rule). Each track has its own hostile review and one fix
round.

| Track | Owns | When |
|---|---|---|
| **R: relay lock** (`builder-secure`, committed on `security/0.14` 5af8f7b7 from `~/dev/wt/t14-lock`) | section 12 items 1 to 8 incl. N11 and N12: `node/join_lock.rs`, `relay-uws/src/join_lock.h`, `ws_handler.cpp` put arm, `test_join_lock.cpp`, `lock_keeper.rs`, `lock_state.rs` grants, relay tests and SANITIZE on the VPS, relay deploy | done; the relay deploys before any client, and that deploy carries track I's `roster.h` |
| **R2: lock by the walk** (follow-up, decided 2026-11-01) | section 12 items 9 to 11: the `LockCounted` closure on `roster::authority`, the Rust model, the lock keeper's grant devices and the recovery trigger, the lock put price `2 * SIG_W * n` (`plan_text`, `relay_pace.rs`, `breaker_vectors.json`), the tests, VPS run | after I's `roster.h` walk; same relay deploy if it is ready, else the next |
| **I: identity** (`builder-secure`, BUILDING in `~/dev/wt/t14-ident`) | FIRST the vouch cap (R31-4, HOL-SEC-189, a shipping bug, embargoed) with its own walk and RC32-10's turn-time sort and idempotence property test, in `roster.rs` and `roster.h`; then `roster.rs` (`authority()`, the walk with clause 2, reserved slots with clause 2 per tier, `within_caps`, `placing_subset`), `relay-uws/src/roster.h` + `roster_vectors.json` (VPS runner), `roster_book.rs` (re-signing, `roster_seen` for removals, vouches and stamps with the 30-day keep, the before-T filter, the dependent-vouchee closure and after-T removal, `server_rosters`, the `RosterNotice` book gates, `ignore_for_test`), both dialogs, the T question, the vouchee naming, the restore chooser UI (named supporters, the wait, the list as a normal screen, "before the 0.14 update", "ask a member for an invite"), the member banner, the 0.13-relay warning, FFI + codegen, copy via `sepia`, fleet proof | now, in parallel with R; `roster.h` lands in R's relay deploy |
| **C: CRDT authority** (`builder-secure`) | `DevProof`, verdict, cut + `CutMark`, park, stratified eligibility (4a to 4c), `DeviceRetired` + carried sets with provenance and the retire carry re-sign, `cp_lineage`/`cp_cut`/`cp_settled`, settling (T, `seen_ms`, restore points, `cp_seen`, `cp_roster`, `SettleSign` ops and `SettlePin` with lightest-signer eviction, the upgrade seed), own-op retention, the witness protocol (every-P continuity), FLOOR MARKS (the round's candidate filter, `floor_base` = the pre-trigger base, ingest before the door) and THE HOLD (section 8.8: `floor_pending` with the fixed pre-trigger state, the trigger leaves per group and `floor_b`, `recovery_hold` with KEEP (R34-9's subgroup ladder) and per-group SEAT (R34-3), `GroupRules::Server.held` in `mls_authority.rs` and its builders, the teardown sites with the shell and its door, chain record, direct sync asks and Leave (R34-2), the liveness reads incl. the sync paths, the sibling re-announce and the MLS heal and Olm gates (R34-11), the silent re-ask gate in the core's batch tick, standing over the pre-trigger state), the fresh-install path (union list, `SharedServers.members`, the join box subset and padding), the roster trade + `asker_roster` + `base_unknown` + responders + re-run, the owner re-fold (the trigger with R33-2 and R34-4, `refold_class` with Excluded, the settings allowlist, Unpublish and `may_write_now` through `op_allowed`, `rederive` with R34-8's skip and role cap, existence with sub-stamps and R34-7's most restrictive access, signed `cp_refolded` entries and answers with listed and waiting entries by standing, the settling's R entries and same-checkpoint re-run (D35-1), `RefoldPin` for R and the DR, `refold_answer`, the confirm with Put back and the timeout rule, the guests' closed notice, the settler's direct settling and door grant, the FFI, the review screen and the shell banner with copy via `sepia` and fleet proof), committing nonce, channel post proof and gate, tests and wiki rows | after the core lands; uses I's `authority()` and `placing_subset` |

Inside C, in build order: proof and store upsert; verdict, cut, park and stratification;
`DeviceRetired` and carried sets with provenance, with the retire carry re-sign (R31-6);
settling with restore points, first-fold records, settle marks as `SettleSign` ops with
`SettlePin` and lightest-signer eviction (R31-5, RC32-4, RC32-9, R33-6), `cp_settled` and
the upgrade seed; own-op retention; witnesses (ages, every-P continuity and its property
test, the pre-upgrade sentinel, the wait, iteration, `base_unknown`); floor marks
(trigger with the fixed pre-trigger record, form, counting, the floor, confinement,
`keep`, the rollback settling, the two property tests, the round's candidate filter and
`floor_base`, ingest before the door with the per-identity and author caps); the hold
(`recovery_hold` with its two levels, `GroupRules::Server.held` at every builder, the
teardown sites with the shell, the liveness reads and sync paths after the sweep, standing
over the pre-trigger state, the harness tests); the fresh-install path (`SharedServers`
with `members` and fixed frames, the union list, the join box subset and padding,
`fan_out`, the door, the lock moves, its harness tests); roster trade, responders, N10,
H4; the owner re-fold (the trigger with R33-2 and R34-4, `refold_class` with Excluded,
the allowlist and Unpublish, the element walk over every stamped kind and the member
events through `rederive`, the member-clock T, the 30-day reach, signed `cp_refolded`
entries and answers with the display and confirm checks, listed and waiting entries by
standing, the settling's R entries and re-run, `RefoldPin`, the confirm with Put back and
its convergence, the FFI and the review screen); channel posts; tests (incl.
`t14d_a_013_committer_during_a_recovery`), mutation pass, PC suite and wiki.

Wiki `security_write_gates.md`: one new section for this design with rows for the proof,
`DeviceRetired` (incl. `restore`), the settling checkpoint, `SettleSign` and `SettlePin`,
`FloorMark` (ingest before the door) and `FloorPin`, `floor_base`, the re-fold (its
trigger, `refold_class` and the AUTO/Unpublish/REVIEW split), `cp_refolded` (signed
entries and answers, review, answer, the settling's R entries) and `RefoldPin`, the hold
(`recovery_hold`, KEEP and per-group SEAT, its three site classes, the shell and the
settler's direct send), witness answers, `base_content`, `asker_roster` (sync and join box),
`SharedServers` and `server_rosters`, and the room `RosterNotice` gate; §17 and §21 get
pointers. The vouch cap gets its HOL-SEC-189 row with the shipped-issue note.

## 20. Decisions

Answered by Vitalik (2026-11-01, binding):

1. Build all of this in 0.14, never postponed.
2. The removal dialog asks "I'm retiring this device" or "It was lost or stolen". Retiring
   endorses only what the remover folded, after a sync round. Lost or stolen, and every
   phrase recovery, endorse nothing blindly.
3. Stolen-device recovery is option (c): T on lost or stolen and on every recovery; the
   multi-device settling from the remover's records; members' witnesses on a fresh install,
   at least 2 supporters, the newest continuous candidate, dated restore points with
   members' names when ambiguous, nothing preselected, "I don't know" = rev 2's rollback;
   the new device writes the settling as one owner op. Posts dated before T stay.

Answered by Vitalik (2026-11-01, revision 3's seven, all as recommended):

4. **Small server on a fresh install:** (b), show the witnessed restore points with their
   date and the member who named each, nothing preselected, plus "I don't know". (With
   R3-2 the same list is shown whenever there is no continuous candidate.)
5. **Members keep their own ops 30 days** (sections 7, 8.3, 17; bound re-sized in sections
   7 and 14).
6. **Pending and waited-in devices author no server ops;** typing the phrase once makes a
   restored backup a root.
7. **Servers founded on 0.14 commit to the owner's recovery key in their id.**
8. **Legacy owners get a non-blocking phrase prompt** at their first 0.14 start.
9. **0.13 mods lose the change key** after the first 0.14 lock move, under the RED notice.
10. **One T per recovery,** the earliest moment the person is sure of.

Answered by Vitalik (2026-11-01, revision 3.1's six, all as recommended; written into the
body as decided):

11. **The wait before a fresh-install pick (R3-2):** W = 30 s after a pick first exists,
    restarted by each new answer, at most 2 minutes from the first ask; the screen names
    every member who confirmed it and offers "Choose another point" (section 8.4).
12. **Devices the stolen device added after T are removed with it, named, no toggle
    (R3-5).** Revision 3.2 narrows "added" to devices that depend on the dropped device
    (R31-3, section 8.6), which this decision covers: a device another device also vouches
    is never removed.
13. **The relay judges invite-lock changes by the roster walk (R3-9):** track R follow-up
    R2 (section 12, item 9).
14. **A member's stolen mod device: the owner re-fold (R3-10, option (b)).** Revision 3.2
    keeps the decision and changes how T is read (R31-10): the member names its own restore
    checkpoint and before-T ops, the owner never compares T with its own clock, a member's
    report re-folds at most 30 days back, and a re-fold that loses a tie runs again
    (section 8.3).
15. **A recovered single-device owner that is the only mod resets the lock at once** and
    moves it again after the restore (section 8.7, step 7).
16. **"Longer ago, or not sure" on a fresh install sets T = 0** (section 8.1), posts
    included.

Answered by Vitalik (2026-11-01, revision 3.2):

17. **Floor marks (R31-2, section 8.8).** When a server's only checkpoint writer is dropped
    by a recovery, every member records the server as it held it at that moment, and the
    members together keep the OLDEST of those records as a frozen floor that nobody can
    move forward, so nothing vanishes and the stolen device can add nothing after members
    learn of the recovery. The cost: on a server the owner never gets back to, whatever the
    thief changed between the theft and the moment members heard of the recovery stays
    (the owner's restore fixes it where the owner does reach the server), and an active
    thief with planted accounts can still force a full step back, but never its own
    version. With it, "I don't know" is an explicit rollback settling. The hold (no member
    or MLS leaf evicted while a recovery is in progress) is part of the same section and
    applies with or without a floor.

Answered by Vitalik (2026-11-04, revision 3.3):

18. **The re-fold reverts only the member's own dropped device (RC32-3, section 8.3).** A
    restore after a lost or stolen device reverts ONLY that member's own ops: the state
    elements whose HLC actor is the DR's member and whose lane is `lane_of(dropped)`, after
    the restore point; everything else stays as the base has it. It triggers only on
    `restore.is_some()`; an absent restore, or one off the base's line, re-folds nothing.
    `cp_refolded` is carried forward so sibling owner devices do not roll back again. Not
    the mod-or-above fallback the re-check offered. Item 20 decides which of those reverts
    run on their own.
19. **The 0.13 and 0.14 MLS split during a stolen-device recovery on a mixed server is an
    accepted residual (RC32-7, sections 16, 17).** 0.14 members never merge a 0.13
    committer's removals; the RED 0.13 notice says to update (appendix A); harness
    `t14d_a_013_committer_during_a_recovery`.

Answered by Vitalik (2026-11-04, revision 3.3's open item; replaces its option (a)):

20. **What a re-fold reverts on its own: option (c) (R33-5, section 8.3).** After R33-2's
    trigger (the DR's device is uncounted in the owner device's view and its lane is its
    own), a re-fold reverts automatically only the dropped lane's writes that the DR's
    author could still write with its CURRENT role in the base. Every write it can no
    longer write by role is LISTED to the owner and reverted only on the owner's confirm;
    the re-fold always runs on an owner device. The design reads the kinds the decision
    names as always listed, whatever the author's role: moderation (bans, mutes, kicks),
    roles (on anyone, the author included) and role permissions, another member's
    registers, channel access and the public flag (a revert never reopens a restricted
    channel as public without the owner), the join gates, existence (deletions, and
    creations whose undo deletes), and membership events (admissions it answered, its own
    leave). The list rides the checkpoint (`cp_refolded.review`, R pinned as `RefoldPin`):
    every owner device shows it, nothing preselected, and the first answer that lands is
    the answer everywhere. Declined ("Keep all"), the writes stay and are never listed
    again; unanswered, they stay, and the list closes as kept after 30 days of owner clock.
    Copy in appendix A. Item 21 adds the one access revert that does not wait (a channel
    made public after T); revision 3.5 lists by standing and never closes a list by count
    (R34-5).

Answered by Vitalik (2026-11-04, revision 3.4's open item; replaces its option (b) and
the re-check's R34-6):

21. **The only automatic access revert is "made public" (section 8.3, Unpublish).** A
    channel whose effective public flag the dropped device's lane turned on, with that
    write's stamp later than the report's T (`posts_until_ms`), goes back to not public at
    once in the re-fold, whatever the member's role and whether or not its review is
    listed yet, and the owner's list shows it as already undone with "Put back". Nothing
    else about access reverts automatically: every other access change (visibility,
    label gates and a label's access flag, grants given or taken back, the join gates)
    waits for the owner's confirm. Checked against the access ladder (section 8.3): the
    flag decides only what non-members (guests) may read and whether posts go out as
    plaintext, so the revert removes no member's access. A "made public" write dated at or
    before T is listed like any other access change.

The vouch cap's number is HOL-SEC-189 (R31-4), embargoed.

Revision 3.5 adds no open decision.

## 21. Notes outside this scope

- **How a fresh install that recovered by phrase learns the servers it owns and their
  member identities**: answered by section 8.7 (revision 3.1).
- **The step back at members before the person restores**: answered by section 8.8
  (floor marks and the hold, revision 3.2, decided).
- **Master-signed plaintext surfaces** other than posts (`PublicFileHeader`, profile cards)
  were not checked for a refusal of a removed sender device. A reviewer should confirm each
  arm refuses `resolver::is_revoked(from)` or a device proof.
- **Roster rows a stranger fills in the global book**: closed by section 9's book gates
  (R31-8, track I). The build's sweep of every `RosterNotice` arm may find a first-party
  path not named there; each gets its own bound before it keeps a stranger's roster.
- **Floor marks and very large servers.** One mark per member identity is fine at the
  512-identity MLS cap. Community mode above the cap (memory `project_large_server_mls_scaling`)
  should re-check the per-server mark count and the 32-content bound when it is designed.
- **The core's generation 0** for the first checkpoint of a server with no base is fine for
  the core, but any reader that takes `cp_generation >= 1` as "0.14" is wrong; this design
  uses `cp_stamped`.

## Appendix A. User-facing copy (plain text, for the `sepia` pass)

Sentence case, no em dashes, no colon in place of one. Nothing here is final until `sepia`.

**Remove device dialog**

- Title: Remove {device name}?
- Option: I'm retiring this device
  - Under it: You replaced it, sold it after wiping it, or no longer use it. What it did in
    your servers stays.
- Option: It was lost or stolen
  - Under it: Changes it made in your servers after you last had it are undone.
- Shown after picking lost or stolen. Question: When did you last have it?
  - Less than an hour ago
  - Earlier today
  - Yesterday
  - In the last 7 days
  - In the last 30 days
  - Pick a date and time
  - Longer ago, or not sure
  - Under the list: If you are not sure, pick an earlier time. Changes your other devices
    and other members made stay either way.
- Retiring, when it added devices. Toggle, off: Also remove the devices it added.
- Lost or stolen, when it added devices after the chosen time. Shown above the button, no
  toggle: These devices are removed too, because it added them after {date and time}.
  {device names}. If one of them is yours, pick a later time.
- Lost or stolen, when it added devices before the chosen time. Toggle, on: Also remove the
  devices it added earlier. They are treated the same way.
- Button: Remove (disabled until a choice is made)
- After removing, retiring: {device name} is removed. What it did in your servers stays.
- After removing, lost or stolen: {device name} is removed. Changes it made in your servers
  after {date and time} are being undone.
- When the removal does not take effect for servers (a device closer to your recovery
  phrase removed this one first): Not removed for servers yet. Use your recovery phrase to
  take your account back.

**Recovery screen**

- Question: When did you last have your other devices?
  - Under it: Devices you don't keep are treated as lost or stolen. Changes they made in
    your servers after this time are undone.
  - The same answers as above.
- Keep list on a new device (every other device starts unticked): Tick the devices that
  are still yours. The others are treated as lost or stolen.
- Progress, per server: Checking with members of {server}
- Still waiting for answers (the wait, section 8.4): Waiting a little longer for more
  members of {server} to answer
- One clear answer: {server} can be restored as it was on {date}. Confirmed by {name},
  {name} and {count} others.
  - Under it: If you don't know these people, choose another point.
  - Buttons: Restore, Choose another point
- Restore points (no single clear answer; a normal screen, shown often, never worded as an
  alarm): Choose how to restore {server}. Members remember it at these points. Pick the one
  you recognize.
  - Each item: {date}. Named by {name}, {name} and {count} others
  - An item a member first saw before the 0.14 update: Before the 0.14 update. Named by
    {name}
  - Last item: I don't know
  - Under "I don't know": Hollow goes back to the last state your kept devices saved.
    Changes made after that may be lost.
  - Button: Restore (disabled until a choice is made)
- Too few members answered (decision 1): Only {name} could confirm how {server} looked.
  Pick it if you recognize it.
- Nobody reachable: No members of {server} are online. Hollow will ask again when they
  are.
- No server known yet (section 8.7): Hollow doesn't know your servers yet. Ask someone in a
  server you own or joined for an invite link, or add your friends again. Hollow then
  checks with the members how each server looked before you lost your devices.

**For members of a server whose owner is restoring it** (section 8.8, shown only while the
server has stepped back, never while a floor holds it)

- Banner: The owner of {server} is restoring it after losing a device. Some channels and
  roles may be missing until then. Nothing is deleted.

**For the owner, after a member reports a lost or stolen device** (section 8.3, decisions
20 and 21; on every owner device until answered)

- Notice in the server, owner only: {member} reported a lost device. Some changes it made
  in {server} need your decision.
  - Button: Review
- Review screen title: Changes from {member}'s lost device
  - Under the title: Hollow already undid what {member} can still change on their own.
    These changes need you, because {member} can't make them now or because they change
    who can see, post or join. Nothing else changes until you choose.
  - Added when Hollow closed a channel: Channels the lost device made public after
    {member} last had it are already closed to people outside {server}.
  - Under that: If you don't answer within 30 days, these changes stay.
- Group headings: Already undone. Members removed or banned. People it let in. Roles.
  Mutes. Who can see or post. Joining the server. Channels, labels, emotes and stickers.
  Other changes.
- Already undone, each with a Put back toggle, off at first:
  - #{channel} was made public. Hollow made it not public again, so people outside
    {server} can't read it. Members still can.
    - Toggle: Put back
    - Second line, when on: Anyone, including people outside {server}, can then read new
      posts there.
- Items, each with a toggle, nothing selected at first:
  - {name} was banned. Undoing lifts the ban and brings {name} back.
    - When {name} had a role above member: Undoing lifts the ban and brings {name} back as
      {role}.
  - {name} was removed. Undoing brings {name} back.
    - When {name} had a role above member: Undoing brings {name} back as {role}.
  - {name} was muted. Undoing lifts the mute.
  - {name} joined. Undoing removes {name} from {server}. To keep someone out, ban them.
  - {member} left {server}. Undoing brings {member} back.
  - {name} became {role}. Undoing makes {name} {old role} again.
  - What {role} can do was changed. Undoing puts back what {role} could do before.
  - {name}'s nickname was changed. Undoing puts back the earlier one.
  - #{channel} stopped being public. Undoing makes it public again.
    - Second line: Anyone, including people outside {server}, can then read new posts
      there.
  - #{channel} was made public. Undoing makes it not public, so people outside {server}
    can't read it. Members still can.
  - Who can see or post in #{channel} was changed. Undoing puts back the earlier rules.
    - Second line, when the earlier rules let more people in: More people can then see
      #{channel}.
  - {name} lost access to #{channel}. Undoing gives {name} access again.
  - {name} was given access to #{channel}. Undoing takes it back.
  - {server} was made private, or its member limit or Twitch rules changed. Undoing puts
    back the earlier rules.
    - Second line, when those let more people join: More people can then join {server}.
  - #{channel} was deleted. Undoing brings #{channel} back for admins only. You can open
    it to others again afterwards.
  - #{channel} was created. Undoing deletes #{channel}.
  - The {label} label was changed. Undoing puts it back as it was.
  - The {label} label was deleted. Undoing brings it back. When it controls access, nobody
    has it until you give it again.
  - :{emote}: was removed. Undoing brings it back. (And: was added. Undoing removes it.)
- More items than shown: {count} more changes come up after you answer these.
- More reports than shown (in the server's settings, under the lists): {count} more
  members reported lost devices. Their changes come up after you answer these.
- Control: Select all
- Buttons: Apply selected (disabled until a toggle is on), Keep all
- After Apply selected: The changes you picked are done in {server}.
  - An item someone changed since: {item}. Someone changed this since, so it stays.
- After Keep all: These changes stay in {server}. Channels Hollow closed stay closed.
- On another owner device once answered: Answered on {device name}.
- When nobody answered in 30 days: Closed after 30 days. These changes stayed.

**For a member removed while the owner restores a server** (section 8.8, R33-11)

- Banner: {name} removed you from {server} while the owner is restoring it. You can't
  chat here for now. When the owner finishes, this is either undone or final.
  - Button: Leave {server}

**Elsewhere**

- Where a server action is refused for a device waiting for approval: Type your recovery
  phrase once to make changes in servers.
- In-app hint for a member on 0.13 (from the core design): Using an old version of Hollow.
- One more line for the RED 0.13 status notice (section 16, RC32-7): If the owner of a
  server you're in is restoring it after losing a device, you can't chat there with
  members who have updated until you update too.
- Owner whose server's relay is older than 0.14 (section 12, item 10): This server's relay
  needs an update before it can keep removed devices out of your invite lock. Ask the
  person who runs it to update.
