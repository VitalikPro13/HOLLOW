# g13w2-f-authority: a stand-in MLS authority nobody can grind (design v2.1)

> Archived design of the 0.13 track (stand-in MLS authority). Built with review changes: R5 dropped, the named forward constrained. The code and wiki `security_write_gates` §51 are authoritative.

Builder g13w2-f-authority, wave g13 wave 2, base 0c0f9956 (security/0.13 tip). DESIGN ONLY.
v1 is kept as `DESIGN_v1.md`; review 1 is `REVIEW_1.md`, the narrow re-review is `REVIEW_2.md` (both
GO WITH CHANGES; round 3 appended to `REVIEW_2.md`: GO, design CLOSED for the build). v2 overrides v1 wherever they differ; **§10 (v2.1) overrides §1-9 wherever they
differ** (§2.2 position, §4.2 silent responders, §4.3 the walk and parked joins, §7 tests, §8 cost). Inputs: lead notes, s3 DESIGN.md v2.1 + fix round, memory project_mls_leaf_binding,
feedback_mls_patterns, feedback_owner_coordinator_mls_recovery, project_crdt_fold_design_e,
project_roles_design, project_join_lock, project_013_014_compat_plan, wiki security_write_gates §37
and §48, the CLAUDE.md MLS section.

## 0. Summary

- **Threat**: while no owner device is online, every MLS leadership role of a server falls to the
  lowest master id by string sort among online members. Master ids are free to grind, so a stranger
  who joins with a ground id becomes the committer, the join answerer, the bootstrap target, the
  catch-up responder, the member allowed to repair everyone's leaf, and the side whose fork
  survives. RED harness test in §9. Severity MEDIUM (confirmed by review): availability and churn,
  not confidentiality.
- **New rule ("standing")**: order candidates by role tier (owner, admin, moderator, member), then by
  the effective position of their current membership in the signed fold (the admitting op's full
  HLC, never earlier than the admitter's own position), then by id. Where the gate is ON, only
  masters holding a bound leaf in our tree are candidates.
- **The crux**: a 0.12.2 replica always picks the lowest id, and every site that decides who leads
  must agree across honest replicas, or a server splits until the owner returns. So wherever an
  honest 0.12.2 leaf takes part, 0.13 keeps the old rule. Any "all 0.13" signal is forgeable by
  omission, so a plain version gate is an attacker's off switch.
- **0.13**: one gate per server (ON when every bound leaf declares s3's TALLY capability and the
  replica's anchor is not Legacy) plus a **ratchet**: in an all-0.13 group no leaf without the
  capability enters, the anchored owner's own identity excepted. ON: standing everywhere. OFF:
  byte-for-byte the old rule. Leafless askers walk the standing order and reach the old-rule target
  only last, and a leafless device answers a KeyPackage request only from a master at or above its
  own walk target.
- **Left open in 0.13**: a member holding a pre-0.13 leaf (honest or not) keeps its server OFF
  until 0.14 (squatting residual; no option B opt-in in 0.13, per review answer b).
- **0.14**: no gate, standing everywhere, RequiredCapabilities (option B) instead of the ratchet,
  old-rule code and the probe bit deleted.

### 0.1 Review changes (REVIEW_1.md finding -> where v2 handles it)

| Finding | v2 |
|---|---|
| H1 dual-target ask feeds a ground id | §4.3 rewritten: standing walk only, old-rule target last after the walk is exhausted. Plus "H1b" in §4.3, a second path to the same capture the review did not name: a leafless device answers ANY member's KeyPackage request today and then accepts that requester's Welcome; now gated. `asked_for_leaf` scoping: §4.3 explains why it is not needed. Tests 13, 14 |
| M1 leafless masters ranked | §2.1 candidate rule (ON: bound leaf in our tree, the subgroup's tree for subgroups); §4.2 silent-responder fall-through. Tests 12, 15 |
| M2 backdated admission into a lost span | §2.2 and §2.3 rewritten: `MemberSpan.by` and a recursive effective position. Units 7, 8 |
| M3 owner's own 0.12.2 device stranded | §3 ratchet: the anchored owner's identity is exempt. Test 16 |
| L1 subgroup gate | §3 gate matrix |
| L2 full HLC | §2.2 `MemberSpan.from_hlc` |
| L3 Legacy view in an ON tree | §3: leads nothing |
| L4 `capable` tied to tally v2 decode | §3: gate and ratchet read `declares`; s3's fail-closed cap handles a malformed tally |
| L5 probe bit on Lane::Relay | §3: accepted and documented |
| L6 RED test asserts the Welcome | done: the test also asserts no Welcome from X and no leaf ask reaching X (§9, run 2) |
| door_room answerers | §4.7, in this build (Vitalii decided) |
| R2-H2 silent-responder skip steerable by fake hints | §10.1: every required probe is answered (an `answer` echo), only a missing answer counts, one skip per window, ON only. Test 18 |
| R2-H3 a duplicate `MemberAdded` captures `by` | §10.2: best attribution per span over every admitting op; a duplicate only improves, up to its author. Units 9, 10 |
| R2-H1c parked ring copy leaks the KeyPackage | §10.3: no KeyPackage in the parked copy of a non-Legacy server; seat by the walk; parked no longer counts as asked-for there. Test 19 |
| R2-M4 walk latency | §10.4: `MlsKeyPackageAck`, 8 s step, exact-bytes dedup. Test 20 |
| R2-LOW1 H1b in subgroups | §10.3 |
| R2-LOW2 departed admitter | §10.2 |
| R3-1 the answerer's cooldown counted as silence | §10.1 "round 3, the answerer's cooldown". Test 18 extended |
| R3-2 skips never expire | §10.1 "round 3, skips expire". Unit 14 |
| R3-3 position depends on map order | §10.2 "round 3, a least fixed point". Unit 15 |
| R3 confirmed: `MlsKeyPackageAck` on `Lane::Relay` | §10.4; wiki §49 row at build time |

## 1. The threat today

### 1.1 What the stand-in decides

With no owner device online, `elect_coordinator` / `online_master_identities`
(`crypto_handler.rs:1787-1815`) sort online masters as strings and take the first. Directly or
through a fallback arm that names:

| Role | Function | What the holder can do with it |
|---|---|---|
| Committer of KeyPackage adds/repairs and of removals | `elect_server_coordinator` (KP arm `swarm.rs:12353`, `sweep_unseated_leaves`, `mls_turns::committer_identity`), `fit_coordinator` fallback | Withhold adds; withhold removals (the whole server falls back to O(N) Olm fan-out while a removed leaf is seated); hand turns |
| Join answerer | `swarm.rs:10934` | Sit on a join ask until the repeat ask |
| Bootstrap target | `server_bootstrap_target` (`request_server_leaf`, `send_join_leaf_ask`, `swarm.rs:11683`) | Receive every leaf ask; drop them, or Welcome the asker onto its own fork |
| Catch-up responder | `epoch_catchup_responder` via `group_authority` (`:3451-3540`) | Refuse catch-ups (stale members lose live MLS and voice keys), answer with KeyPackage requests |
| Who may repair our leaf | `may_repair_our_leaf` (`:3480`) | Force repairs (O(N) Welcome each); s3's cap bounds the rate per target |
| Fork winner | `is_authoritys_acting_device` (`:3698`) | Of two forks its own stays |
| Subgroup coordinator | `elect_subgroup_coordinator`, `subgroup_committer`, `founds_on_key_package` | The same inside a restricted channel it can see |
| Vault coordinator | `elect_vault_coordinator` (second) | Plans vault repairs |

Confidentiality holds: commits and Welcomes are judged (design D) and a group that still seats a
removed leaf carries no MLS send.

Also, independent of the owner: `is_mls_coordinator` (`:1903`) is the RAW lowest master. It gates
the `PeerJoined` KeyPackage request (`swarm.rs:4283`) and the revocation removal queue
(`swarm.rs:7205`), so a ground id holds those duties even while the owner is online. Low impact
(owner-first paths repeat both); the build folds them into `elect_server_coordinator`.

### 1.2 RED test

`g13w2f_a_ground_low_id_never_becomes_the_stand_in_committer` (end of `node/test_harness.rs`,
`// g13w2-f-authority`): owner O, admin A admitted first, attacker X joining last with the lowest of
82 seeded ids, O offline, joiner J. Asserts X makes no commit, sends J no Welcome and receives no leaf
ask from J; A commits and Welcomes J. Evidence §9.

## 2. The standing rule

### 2.1 Order and candidates

    standing(state, M) = (tier(M), position(M), M)        ascending = first

- `tier`: 0 owner, 1 Admin, 2 Moderator, 3 Member (`state.get_role`).
- `position`: §2.2.
- `M`: the master id, last tie-break.
- **Candidates**, ON only: masters holding a bound leaf in OUR tree of the group in question (the
  server group, or the subgroup's own tree for subgroup sites when we hold it; CRDT qualifiers only
  when founding a subgroup nobody holds). The owner too: an owner whose online devices hold no leaf
  is not the authority, committer or responder (today probes go to a leafless owner phone and
  nobody answers). OFF: candidates exactly as today (`state.members`, presence).
- Everything else about the candidate sets stays: online only, excluded senders, s3 unfit filters.

### 2.2 Position (fold state; review M2 and L2)

`MemberSpan` gains two `#[serde(default)]` fields, written by `apply_payload` when `MemberAdded`
opens a span: `from_hlc: Option<HlcTimestamp>` (the admitting op's full HLC) and
`by: Option<String>` (that op's author, a master). The founder's span and checkpoint-seeded spans
have `by = None`.

    position(M) = MAX                                if M has no open span
                = MAX                                if span.by = Some(a) and a is not a current member
                = max(from(M), position(a))          if span.by = Some(a)
                = from(M)                            if span.by = None
    from(M)     = span.from_hlc, else (span.from_ms, 0, "") for spans written before 0.13

Computed with a memo per state version, recursion bounded by the member count (a cycle reads MAX).
**Invariant: nobody ranks before the current position of whoever admitted them.** A kicked or
departed admitter takes every admittee's standing with it; a rejoined admitter carries them no
earlier than its new span. Duplicate `MemberAdded` for one joiner: the fold applies the earliest by
HLC, so every replica records the same `by` and `from_hlc`.

### 2.3 Why each input agrees across replicas, and what an attacker can buy

- Role and `member_record` are folded from signed ops in HLC order (design E); replicas holding
  the same ops agree. Lag (seconds, MLS plus the Olm twin) means a transient second committer at
  worst, a fork the fork rule heals once the op lands, as with presence today.
- **Legacy anchor**: a joiner's snapshot strips every role but the owner's (HOL-SEC-093) and
  carries one member's word for `member_record`. Gate OFF there (§3).
- **Role**: only by an owner/admin grant (`can_change_role` at author and ingest). AR-11 (an
  ex-admin backdating grants) now also buys MLS precedence; the lead widens AR-11.
- **Position**: `admission_allowed` judges a `MemberAdded` at its own point in the fold and has no
  time bound (`server_state.rs:1913-1945`), so a member can backdate an admission to any time it
  was a member, including a span it has since lost (v1 missed this, review M2). The recursive
  position makes that worthless: the admittee is never ahead of its admitter's CURRENT position,
  and nowhere if the admitter is gone. A sitting member gains nothing it does not already hold.
- **Residuals**:
  - R1, the legacy cohort: members the owner's first checkpoint seeded from 0 (`by = None`) tie on
    position and fall to id. It is a fixed set in the past; no newcomer enters it.
  - R2: a checkpoint authored by a 0.12.2 owner device re-serializes `member_record` without `by`
    and `from_hlc`, so spans it covers fall back to `from_ms` and a backdated admission older than
    that checkpoint regains its stamp. It needs an owner still on 0.12.2 and a removed admitter;
    AR-11 class, gone in 0.14.
  - R3: two ops never share a full HLC (it carries the device lane), so the id tie-break serves R1
    only.

## 3. The gate (0.13 only)

Gate inputs per server (`MlsManager` caches per group and epoch):

| Group | ON when |
|---|---|
| Server group | our anchor is not Legacy, we hold the group, and every leaf is bound and `declares` TALLY |
| Subgroup we hold | the server gate is ON AND every leaf of the subgroup's own tree is bound and declares TALLY |
| Subgroup nobody holds (founding) | the server gate |
| CRDT duties (join answering, vault) | the server gate; a replica without the server group uses the old rule (duplicates harmless, §4.4) |

- **`declares`, not `capable`** (L4): the gate and the ratchet read whether the leaf lists the TALLY
  capability, never whether its tally decodes, so a later tally layout cannot flip the gate on
  older 0.13 replicas. A declared but undecodable tally is s3's fail-closed cap, not a gate change.
  Wiki note anyway: tally layout frozen at version 2 until 0.14.
- **Legacy view in an ON tree** (L3): a replica whose own anchor is still Legacy while its tree is
  all-declaring leads nothing (no commit, no catch-up service, no KeyPackage requests) and asks by
  the walk (§4.3). It cannot deadlock: an all-declaring tree means the owner's leaf is 0.13 too, and
  a 0.13 owner device authors the first checkpoint on its batch tick, so some replica is anchored.
- **Leafless replicas** lead nothing in that server or its subgroups.
- **Ratchet**: in a group whose pre-commit tree is all-declaring, every leaf a commit writes (each
  add and the path leaf) must declare TALLY, **except leaves certified to the anchored owner's
  master** (`is_anchor_owner`, review M3).
  - Receiver side: `commit_verdict`, before every CRDT hold, judged on the pre-commit tree and the
    commit only; meetings exempt.
  - Committer side: `plan_membership` drops a non-declaring KeyPackage of a non-owner master (log
    once per device and hour) and never stages such a path leaf.
  - Each layer gets its own test. This narrows s3's C2 allowance (an incapable path leaf on an
    uncounted commit) to OFF groups, the only place a 0.12.2 committer exists.
  - The owner exemption: the owner's old device gets a leaf, and its server is OFF while it holds
    one (the old rule, which that device agrees with). Without it the device is everyone's
    owner-first target yet leafless, founds a second copy when it is the owner's only online device
    (`founds_on_key_package`, `may_found_group`), and captures joiners.
- **Flip races**: ON switches on at the commit that refreshes or removes the last non-declaring
  leaf; a commit racing it forks the group into an ON side and an OFF side. `MlsEpochProbe` gains
  `#[serde(default)] standing: bool` (0.12.2 ignores it; no `deny_unknown_fields` in `types.rs`;
  absent = OFF). In `handle_epoch_hint` for a fork:
  - same gate on both ends: that gate's winner;
  - we ON, the prober OFF: the prober's fork loses (we ask its KeyPackage; it accepts because it
    chose us as its responder);
  - we OFF, the prober ON: we do nothing. We cannot check the claim, and yielding would hand any
    liar a fork pull in an OFF group.
  - So members only ever move from OFF to ON. A lie buys nothing: claiming OFF gets the liar's own
    leaf repaired (charged to it by `RepairBudget` and s3's cap), claiming ON gets silence.
  - Residual: an OFF clique whose responders all sit on the OFF side waits until one of them probes
    an ON member or the owner returns. That set would follow the old-rule authority in an OFF group
    anyway.
- **The bit and the relay** (L5): accepted and documented. `MlsEpochProbe` rides `Lane::Relay`
  (`types.rs:4546`), so the relay learns which askers run 0.13 with a gate ON. It already learns the
  version mix from 0.13-only frame types on the same lane (`MlsUpdateTurn*`, `MlsKeyPackageForward`,
  `types.rs:4341-4344`). The build adds a wiki note.
- **Both rules agree whenever the owner is online and holds a leaf** (owner-first in both), so every
  disagreement this design admits heals when the owner returns.

### 3.1 Rejected gates (unchanged from v1)

- Plain "all leaves capable" without a ratchet: any newcomer flips it.
- "All but the old-rule winner's": an honest lowest-id 0.12.2 member forks the group on every
  removal, and two sybils defeat it.
- Per-identity capability: a 0.12.2 sibling still commits by the old rule.
- Answering each asker by its own version's rule: splits a mixed server.
- Relay flags or CRDT version ops: forgeable by omission.

## 4. Every site

ON = standing rule over §2.1's candidates; OFF = today's rule unchanged.

### 4.1 Group-wide

| # | Site | Today | ON |
|---|---|---|---|
| 1 | `elect_coordinator` / `online_master_identities` (`crypto_handler.rs:1787-1815`) | lowest online master | first online leaf-holding master by standing; one `rank_masters` in a new `node/standing.rs` |
| 2 | `elect_server_coordinator` (`:1822`): KP arm `swarm.rs:12353`, join answerer `swarm.rs:10934`, `sweep_unseated_leaves` `:2436`, `mls_turns::committer_identity` `:203` | owner if online and a candidate, else #1 | owner if a leaf-holding candidate, else #1 ON |
| 3 | subgroup KP arm (`swarm.rs:12361`) | lowest online leaf master | #1 ON over the subgroup's leaves |
| 4 | `is_mls_coordinator` (`:1903`): `swarm.rs:4283`, `swarm.rs:7205` | raw lowest, owner ignored | #2 ON |
| 5 | `fit_coordinator` (`:3421`, s3) | lowest fit online | first fit by standing |
| 6 | `elect_subgroup_coordinator` (`:2003`), its callers incl. `voice_handler.rs:1183` | owner, else lowest qualifying online | owner, else first qualifying leaf holder of the subgroup tree by standing; CRDT qualifiers when founding |
| 7 | `subgroup_committer` (`:2381`) | owner, else lowest qualifying leaf holder | owner, else first by standing |
| 8 | `founds_on_key_package` subgroup non-sibling (`mls_authority.rs:485`) | lowest qualifying other than the sender | first by standing (founding: CRDT qualifiers) |
| 9 | `group_authority` (`:3451`) | owner online-or-us, else #1 minus unfit | owner if it holds a leaf, else #1 ON minus unfit, minus silent responders (4.2) |
| 10 | `is_authoritys_acting_device` (`:3698`), fork winner | unfiltered `group_authority`, presence | leaf-holding standing order (fork-independent inputs: CRDT role and position; leaf holding differs between forks only for leaves the forking commits changed), plus the probe-bit rule; no unfit filter (s3 C) |
| 11 | `server_bootstrap_target` (`:1849`) | owner online, else lowest online CRDT member | the walk (4.3) |

### 4.2 Two-party

| # | Site | Today | ON |
|---|---|---|---|
| 12 | `epoch_catchup_responder` (`:3509`): `send_epoch_probe`, `handle_epoch_hint` hint path, `ask_leaf_repair`, `rebind_unbound_leaves` | `group_authority`, else lowest online other than the one behind | same shape, standing order, leaf holders |
| 13 | `may_repair_our_leaf` (`:3480`) | owner, our responder, subgroup coordinator | same, ON versions |
| 14 | `repair_after_spent_catchup` (`:3357`) | our responder | ON responder |

**Silent responders** (review M1): a responder that holds a leaf but answers nothing (hostile, or
wedged) would stall every asker.
- Each device keeps a RAM map per group. A responder we probed is skipped for that group for
  10 min when its answer (catch-up, KeyPackage request or counter-probe) has not come within 15 s.
- The skip applies to OUR elections of #9 (responder use only), #12, #13 and #14, all four at once,
  so asking and accepting stay consistent on our side.
- The answering side needs no change. A direct probe is answered by whoever receives it
  (`direct_probe`), and that member's KeyPackage request passes our #13 because it is now our
  responder.
- The fork winner (#10) does not use the map, because it must be the same on both sides. A winner
  that never answers only means members converge through the responder chain instead: each is
  repaired onto its responder's fork, and responders are themselves ordered by standing. The cost
  is an extra repair, never a split.

### 4.3 Leafless askers (review H1)

Askers: `request_server_leaf`, `send_join_leaf_ask`, the message-triggered bootstrap
(`swarm.rs:11683`), `request_subgroup_bootstrap` without the server group, `rebind_unbound_leaves`.

- **The walk**: in a non-Legacy server the asker orders online CRDT members by standing (owner
  first, then §2.1/§2.2 over the CRDT, the only thing it holds) and sends its KeyPackage to the
  FIRST only. If no Welcome seats it within `MLS_BOOTSTRAP_TIMEOUT` (the existing re-ask timer), the
  next ask goes to the next master in the order (a RAM cursor per group, reset by a seat or after a
  full pass). The old-rule target is asked only after the whole order is exhausted. A Legacy server
  keeps today's single old-rule target.
- **Why it is safe and still reaches the committer**:
  - A target holding the group commits if its own gate and election name it. Otherwise it forwards
    (s3 `forward_key_package`, deduplicated per package) to the coordinator its gate names: in an
    ON group the standing coordinator, in an OFF group the old-rule coordinator, which is that
    group's legitimate leader.
  - A leafless or 0.12.2 target that is not the coordinator drops the package, and the walk moves on
    after the timer.
  - A ground-id X never receives the package unless every master ranked above it failed, or the
    group is OFF and X is its old-rule leader (the status quo the gate preserves).
- **H1b, a second path to the same capture (not in the review)**: the `MlsKeyPackageRequest` arm
  (`swarm.rs:12620-12670`) checks `may_repair_our_leaf` only while we hold a leaf. A leafless device
  answers ANY member, and `note_key_request_answered(requester)` then makes that requester's
  Welcome "asked for" (`mls_authority.rs:288-308`). So X can ask a fresh joiner for its KeyPackage
  directly and Welcome it onto X's own OFF fork: the review's H1 outcome without the dual target.
  - Fix: in a non-Legacy server a leafless device answers a KeyPackage request only from the owner
    or from a master at or above its current walk target in the standing order.
  - In an OFF group the old-rule leader is still reached through the walk target's forward, and the
    push the joiner made counts as asked (`bootstrap_requested`).
- **`asked_for_leaf` scoping**: not part of the fix. After our own push the Welcome may legitimately
  come from whoever our target forwarded to, which we cannot know, so a sender scope would break OFF
  groups. With the walk and the H1b gate, nobody outside our walk target and its forward chain holds
  our KeyPackage, and a Welcome needs it. Test 14 is the hostile-hook check of exactly that.

### 4.4 Local or work-sharing

| # | Site | ON |
|---|---|---|
| 15 | `elect_vault_coordinator` (`:1919`, second in order) | second by standing among leaf holders. Disagreement = duplicate work or one idle tick |
| 16 | join answerer (`swarm.rs:10934`) | #2 ON. Disagreement = two answers (the second `MemberAdded` is a no-op) or none until the repeat ask, which every member serves |

### 4.5 Within one identity (unchanged)

`acting_device`, `we_commit_for_our_identity`, `may_found_group` / `we_found_for_our_identity`,
`mls_turns::committing_device`, `preferred_online_device`, `voice_handler::pick_online_device`,
`file_asks` candidates. They order only one identity's own devices.

### 4.6 Listed only (review: LOW)

`mls_turns::pick_turn` (`:93-115`, device-id tie on the same refresh day), `vault/placement.rs`
(rendezvous hashing over member ids), `lock_state::newest`, `lock_keeper::stagger`,
`crdt_resync::pick`, `recovery_pool::coordinator`.

### 4.7 Same-build item: door answerers (Vitalii decided 10-22: rides this build)

`door_room::first_to_answer` (`door_room.rs:225-236`, `ANSWERERS` = 3) ranks room DEVICES by
SHA-256(asker, device), so one identity with three ground devices fills every answerer slot for a
chosen hidden member. Fix: at most one slot per master, with the ranking salted by a fresh per-ask
nonce the asker sends, so nothing can be ground in advance. Test
`g13w2f_door_answerers_are_three_identities_whatever_their_device_ids`. LOW; in this build.

## 5. Mixed-version story

- **Release day**: every existing leaf is pre-0.13, so the gate is OFF everywhere: identical to
  0.12.2 plus s3.
- **Mixed**: OFF. Safe, not protected.
- **Flip**: the gate turns ON once no non-declaring leaf remains (the owner's own included, since an
  owner's old device keeps the server OFF by choice). That happens through an upgraded device's s3
  turn, any commit of its own, a repair, or a removal. The flip commit comes from the old-rule
  committer; a racing commit is §3's flip race.
- **ON**: standing, ratchet. A non-owner 0.12.2 device asking for a leaf is refused and stays
  leafless:
  - it reads through the Olm copy to leafless devices (complement rule);
  - it posts through `olm_fanout_channel_envelope` to online members, and offline ones backfill by
    sync;
  - it has no voice key and is never a candidate;
  - it answers joins by the old rule (duplicates harmless) and asks the old-rule target, a 0.13
    member that forwards to the standing coordinator, whose ratchet refuses it.
- **0.12.2 replicas never act on a decision they would contradict**: in an ON group none holds a
  leaf except the owner's, and an owner leaf turns the group OFF.

**DECIDED by Vitalii (2026-10-22)**: the ratchet ships in 0.13 WITH the owner exemption; the
squatting residual waits for 0.14; the signed status notice targets only 0.12.2 clients (voice and
live encryption need the update in servers whose members have all updated; copy through the sepia
skill); the door_room answerers fix (§4.7) rides this build.

**Residual (review answer b)**: a member holding a pre-0.13 leaf keeps its server OFF, so an
attacker who keeps such a leaf keeps the old rule there until 0.14.

## 6. 0.14 clean break

- Delete the gate, every OFF branch, the probe bit and the walk's old-rule last resort.
- Replace the ratchet's judge rule by option B's RequiredCapabilities on every server group, owner
  included.
- Fold `is_mls_coordinator` into `elect_server_coordinator`.
- `MemberSpan.by` and `from_hlc` stay (position needs them); R2 disappears with 0.12.2 owners.
- Each shim carries a remove-in-0.14 note.

## 7. Tests the build adds

Harness, end of `node/test_harness.rs` under `// g13w2-f-authority`. These need two new test-only
knobs: a `cfg(test)` knob that makes one node mint KeyPackages and path leaves WITHOUT the TALLY
capability (a 0.12.2-shaped leaf), and a hostile hook that makes a node Welcome any KeyPackage it
receives at once.

1. `g13w2f_a_ground_low_id_never_becomes_the_stand_in_committer` (RED now).
2. `g13w2f_the_stand_in_is_the_highest_role_then_the_earliest_join`: admin over moderator over
   member, the earliest member first; a demotion moves it at once.
3. `g13w2f_a_rejoiner_goes_to_the_back_of_the_line`.
4. `g13w2f_a_ground_id_is_neither_catch_up_responder_nor_repairer`.
5. `g13w2f_a_fork_made_by_a_ground_id_heals_to_the_standing_authority`: `hold_broadcasts`, two
   commits to two halves; nobody ends on X's side.
6. `g13w2f_the_join_answerer_follows_standing`.
7. `g13w2f_a_mixed_group_keeps_the_old_rule_exactly`.
8. `g13w2f_an_all_013_group_refuses_an_incapable_leaf`: the committer layer alone, then the receiver
   layer alone.
9. `g13w2f_the_last_upgrade_turns_standing_on_without_a_fork`.
10. `g13w2f_a_fork_across_the_gate_flip_heals_to_the_013_side`.
11. `g13w2f_the_owner_back_online_leads_under_both_rules`.
12. `g13w2f_a_leafless_owner_device_is_not_the_catch_up_authority`.
13. `g13w2f_review_a_ground_id_never_receives_a_leafless_askers_key_package`: wiretap, no `mls_kp`
    from J reaches X's devices in an ON group, at join and on the Welcome-grace re-ask.
14. `g13w2f_review_a_ground_id_that_welcomes_on_receipt_never_seats_a_joiner`: the hostile hook on
    X, plus X sending J an `MlsKeyPackageRequest` right after the join. J refuses it (H1b) and ends
    at A's epoch digest.
15. `g13w2f_review_a_leafless_admin_is_never_the_catch_up_responder`, and a silent leaf-holding admin
    is skipped after 15 s, the asker served by the next.
16. `g13w2f_review_an_owners_old_device_alone_founds_no_second_lineage`: the owner's 0.12.2-shaped
    device gets a leaf, the group reads OFF, no second copy.
17. `g13w2f_the_walk_reaches_the_committer_past_a_leafless_and_a_silent_target`.

Units (`node/standing.rs`, `crdt`, `mls_authority`):

1. `rank_masters` order matrix: tier, position, id; no open span sorts last.
2. Gate matrix: the subgroup row, a Legacy view, a leafless replica, `declares` against a malformed
   tally.
3. Golden test: every OFF site equals a frozen copy of the 0.12.2 functions over randomized tables.
4. Ratchet matrix: ON/OFF x add/path leaf x declares/not x owner/not; meetings exempt.
5. `MlsEpochProbe` without the field parses as OFF; a 0.12.2-shaped decoder accepts the field.
6. The walk's order and cursor; the H1b gate on the KeyPackage request arm.
7. `a_removed_members_backdated_admission_buys_no_standing` (review M2).
8. Position recursion: a chain through a removed admitter reads MAX; a rejoined admitter carries
   admittees no earlier than its new span; a duplicate `MemberAdded` records the earliest author;
   a `MemberSpan` without the new fields deserializes (old DB rows and old checkpoint JSON).

Mutation pass (one runner job):

- each comparison in `rank_masters`;
- the `by` recursion and both MAX arms;
- each gate conjunct, including the subgroup conjunct, and `declares` against `capable`;
- the ratchet at the receiver and at the committer, separately;
- the owner exemption at each layer;
- the probe-bit rule;
- the walk's first target and its cursor;
- the H1b gate;
- the silent-responder skip;
- the switch at each of the 16 sites.

Fleet:

- a mixed server: one member on 0.12.2, old rule, calls and posts work;
- that member updates and its turn flips the gate;
- a ground-id throwaway joins and leads nothing;
- the owner's old phone rejoins, the server turns OFF and nothing forks.

## 8. Cost

- CPU: `rank_masters` sorts at most the online leaf holders (512) by a memoized key; the gate scans
  `leaf_records` once per group per epoch (s3 builds them already).
- Wire: one optional bool on `MlsEpochProbe`. No new variant.
- Storage: two `#[serde(default)]` fields on `MemberSpan` (state JSON and checkpoints). Additive;
  old rows load (unit 8).
- Relay, FFI, Dart: none.
- Build:
  - `node/standing.rs` (~250 lines);
  - edits at 16 sites in `crypto_handler.rs`, `swarm.rs`, `mls_turns.rs`, `mls_authority.rs` and
    `voice_handler.rs`;
  - the ratchet in `commit_verdict` and `plan_membership`;
  - `MemberSpan` in `crdt/server_state.rs`, and `types.rs`.
  - About 1.5 builder days with the tests, plus 0.25 day for the door answerers if taken.
- Wiki:
  - a §49 row: who may lead a group, the ratchet as a receiver write gate, and the H1b gate on the
    KeyPackage request arm;
  - the tally layout frozen until 0.14.
  - The CLAUDE.md MLS coordinator line is updated at merge.

## 9. RED evidence

Run 1 (v1 test), Mac mini, worktree target (`.team/red_run.log`):

    panicked at src/node/test_harness.rs:54497:5:
    assertion `left == right` failed: the ground id committed 1 time(s) as stand-in authority; the admin committed 0
    test result: FAILED. 0 passed; 1 failed; ... finished in 6.68s

Run 2, the test strengthened per review L6: it also checks that X sends J no Welcome and that no
leaf ask from J reaches X (`.team/red_run2.log`):

    panicked at src/node/test_harness.rs:54503:5:
    the ground id acted as stand-in authority: 1 commit(s), 1 Welcome(s) to the joiner, 2 leaf ask(s) from the joiner; the admin made 0 commit(s), 0 Welcome(s)
    test result: FAILED. 0 passed; 1 failed; ... finished in 6.58s

Both runs fail for the right reason. Today X commits J's add, sends J the Welcome J installs, and
receives two leaf asks from J (which paths sent them is not yet checked); the admin does nothing. The two
asks reaching X are review H1's precondition in today's code.

## 10. v2.1: the narrow re-review folded in (overrides §1-9 where they differ)

### 10.1 Silent responders are judged only on probes that required an answer (R2-H2)

v2's skip could be steered. An honest responder that is already at our epoch and digest sends
nothing (`handle_epoch_hint` answers only `their_epoch < own || forked`, `crypto_handler.rs:3612`).
X feeds us `SyncRequest` hints with a high `mls_epoch` (`swarm.rs:10310-10318`), so we probe our
responder A every 10 s, A stays silent, and every 15 s the skip walks our responder one step down,
until it reaches X.

- `MlsEpochProbe` gains `#[serde(default)] answer: bool`. Our probes (`send_epoch_probe`, and the
  counter-probe "repair ours") carry `answer: false` and REQUIRE an answer. A 0.13 receiver of such
  a probe that would otherwise send nothing (same epoch, same digest, or it is ahead and has nothing
  to serve) echoes its own epoch and digest back as `MlsEpochProbe { answer: true }`. An `answer:
  true` frame is never answered (no ping-pong); `handle_epoch_hint` reads it like any hint.
  0.12.2 reads the echo as a harmless direct probe at an equal epoch and does nothing.
- **Silence** = a probe with `answer: false` sent to a responder whose leaf declares TALLY, and no
  frame back from that identity (echo, catch-up, KeyPackage request, counter-probe) within 15 s. Only
  where our gate is ON (there every leaf holder answers). Hints from others never start a silence
  clock; only our own required probes do.
- **Cap**: at most one skip per group per 10 min window, so even a genuinely wedged chain moves one
  master per window. The skip set clears when the skipped responder sends us anything.
- **Round 3, the answerer's cooldown**: `handle_epoch_hint` drops a probe inside its own
  `EPOCH_HINT_COOLDOWN` (10 s, `crypto_handler.rs:3395`, the return at `:3629`), and our probe
  throttle is also 10 s (`:3746`), so fake hints at that rate would make an honest A drop some of our
  probes, which would count as silence. Two rules: (a) a probe with `answer: false` ALWAYS gets one
  reply: inside the cooldown the receiver sends the echo instead of returning (the echo is cheap and
  serves nothing, so the cooldown still bounds the expensive answers); (b) a silence clock starts
  only on a required probe sent at least 2 x `EPOCH_HINT_COOLDOWN` (20 s) after our previous probe to
  the same responder in that group. Test 18 adds hints timed on the 10 s boundary.
- **Round 3, skips expire**: a skip also EXPIRES 10 min after it was set, not only when the skipped
  responder sends us something. With the one-per-window cap, at most one master is skipped at a
  time, so our responder is never lower than SECOND in standing (among leaf holders, excluding the
  one behind). A relay dropping A's echoes, then B's, then C's cannot walk us down to X over hours.
  Unit 14 `three_successive_silent_responders_never_move_ours_past_the_second_in_standing` (30 min
  of simulated time).
- A fake hint now costs X one probe and one echo per 10 s per group; our responder does not move.
- Test 18 `g13w2f_review_fake_epoch_hints_never_move_our_responder`: X floods higher-epoch hints at
  an up-to-date member for 5 min; its responder stays A; X's `MlsKeyPackageRequest` is still refused.

### 10.2 Position by best attribution (R2-H3, R2-LOW2)

v2 stored ONE admitter per span (the earliest `MemberAdded`). Any member can author a duplicate
`MemberAdded` for M (M's `JoinAsk` is public in the op) at an HLC just before M's honest admission,
inside any span it ever held; `admission_allowed` takes it and the earliest op opens the span, so
`by = X`. X leaves and M and M's admittees fall to MAX; X rejoins and M ties at X's position.

- `MemberSpan` carries, instead of `by`, `#[serde(default)] admitted: Vec<(String, HlcTimestamp)>`:
  for each distinct author of a `MemberAdded` naming M while that span is open (the opening op and
  every later duplicate, which `apply_payload` today ignores beyond `is_member`), the earliest HLC.
  `from_ms` and its meaning for backfill (`was_member_at`) are unchanged, so nothing 0.12.2 reads
  changes. `from_hlc` stays (the opening op's HLC).
- position(M) = MAX without an open span; otherwise the min over `admitted` of
  max(hlc, position(author)), where an author who is not a current member reads MAX; an empty list
  (the founder, checkpoint-seeded spans, spans from before 0.13) reads `from(M)` as in v2.
- **Round 3, a least fixed point, not a recursion**: v2's memoised DFS with cycles reading MAX
  depends on visit order, and `member_record` is a `HashMap` (`server_state.rs:325`), so two
  processes could compute different positions from the same ops. Position is defined as the LEAST
  fixed point of the equation above, a bottleneck shortest path: seed every member with an empty
  list at `from(M)`, every other member at MAX, then settle in increasing order (Dijkstra over the
  key (position, id), or relax until stable over members sorted by id; both reach the unique least
  fixed point). A cycle of admitters reads MAX unless one of its entries has a finite path to a
  seeded member. The result is a pure function of the ops, whatever the map order. Unit 15
  `positions_are_the_same_for_every_insertion_order`: the same ops inserted in all six orders of a
  three-member admission cycle with one outside admitter give identical positions.
- **A duplicate can only improve a position, and never past its author's own.** It never worsens one
  (min). X can lift an accomplice no higher than X itself stands.
- **Ties**: among members at MAX, the member's own `from_hlc` before the id.
- **A departed admitter demotes the members it alone admitted** (R2-LOW2), and their admittees with
  them, to MAX. That is the invariant working, not a bug: an honest member whose only admitter left
  ranks behind every member whose admitter still sits. It loses stand-in duty, nothing else.
- **Size**: one entry per distinct author per span. Every entry is an op that already sits in the
  op log (anchored logs are never count-capped), so a duplicate flood costs no more than the op-log
  flood a member can already cause (design E, R4). A checkpoint carries the lists as the owner holds
  them; after a rebase the checkpoint's lists replace ours, never merged with locally kept entries
  (review 2's instruction). A 0.12.2 owner's checkpoint drops them (R2).
- Units 9 `a_duplicate_backdated_admission_cannot_worsen_a_members_position` and 10
  `a_departed_admitter_demotes_only_what_it_alone_admitted` (with a second, sitting admitter the
  member keeps its place).

### 10.3 Parked joins carry no KeyPackage (R2-H1c, R2-LOW1)

The `~join` ring copy carries `key_package` (`types.rs:1848-1853`, re-deposited at
`swarm.rs:1293-1299`). It is sealed to the door, so every member reads it, and while
`awaiting_mls_after_parked_join` (`swarm.rs:10490`) the joiner accepts a Welcome from ANY sender
(`mls_authority.rs:288-308`): the H1 capture again, through the ring.

- In a non-Legacy server the parked copy carries `key_package: None` (0.12.2 members already handle
  `None`, "a live request carries None"), and `awaiting_parked_join` no longer makes a Welcome
  asked-for there. The admitted joiner seats itself by the walk once online (§4.3, §10.4), exactly
  like a live joiner. A Legacy server keeps today's behaviour.
- Cost: a parked joiner admitted while offline gets its leaf a few seconds after it comes back,
  instead of finding a Welcome waiting.
- With this, review 2 confirms the H1b gate is sound and no other path hands out a KeyPackage; the
  rejection of `asked_for_leaf` sender scoping (§4.3) holds only together with this change.
- **Subgroups** (R2-LOW1): the H1b gate for a subgroup request judges by the subgroup election (#6
  and #13: the owner, the subgroup coordinator, or our subgroup responder), not by the server walk.
- Test 19 `g13w2f_review_a_parked_joiners_key_package_reaches_only_its_walk` (wiretap: the ring copy
  carries none; X's devices never receive J's package; J seats under A).

### 10.4 The walk steps in seconds, not minutes (R2-M4)

A 0.12.2 leaf holder that is not the coordinator drops a package without forwarding, and so does
every leafless member (`mls_authority.rs:500-505`); at `MLS_BOOTSTRAP_TIMEOUT` (60 s) per dead hop
that is a join regression in mixed servers.

- New `HavenMessage::MlsKeyPackageAck { server_id, channel_id, package: String (hex of the first 16
  bytes of SHA-256 of the package), outcome: KpOutcome }`, `KpOutcome` = `Commit | Forwarded |
  Cannot`, `#[serde(default)]` on every field with a default. A 0.13 target answers every
  KeyPackage it receives at once: `Commit` when it queued it, `Forwarded` when it passed it on,
  `Cannot` when it holds no group and will not found one, or refuses it (ratchet, H1b, budget).
  `lane() = Relay` (routing metadata, like `MlsKeyPackageForward`; confirmed in round 3, the relay
  already reads `MlsKeyPackage` and `MlsKeyPackageForward`; record it in the wiki §49 row),
  `live_only() = true`, wire pin in
  `types.rs`, one dispatch arm. 0.12.2 drops the unknown variant, as it drops s3's turn frames.
  Check during the build whether `session_vectors.json` classifies data-frame HavenMessage types
  (it classifies relay JSON types; expected no change).
- The asker advances at once on `Cannot`, and after 8 s with neither an ack nor a Welcome (a 0.12.2
  target never acks). `Commit` and `Forwarded` keep today's `MLS_BOOTSTRAP_TIMEOUT` re-ask.
- **No double seat**: the KeyPackage arm and `forward_key_package` drop a package whose leaf already
  sits in our tree with the same encryption key (the exact package seated it), so a slow 0.12.2
  committer plus a later forward never cost a remove and re-add. Two targets committing the same
  package at one epoch stays impossible: at one epoch only one gate and election names a coordinator,
  and a non-coordinator forwards.
- An ack from anyone but the device we sent to is ignored; a forged `Cannot` only moves us to the
  next target in OUR order, never toward X faster than the order allows.
- Test 20 `g13w2f_review_a_mixed_server_seats_a_joiner_past_two_old_admins_within_20s`, test 17
  extended to assert the step time.

### 10.5 Tests and units added in v2.1

Harness 18-20 above. Units 9-10 above, plus:
11. `MlsEpochProbe` with and without `answer` parses; an `answer: true` probe is never answered;
    a 0.12.2-shaped decoder accepts it.
12. `MlsKeyPackageAck` wire pin, lane and `live_only`; an ack from a device we did not ask is ignored.
13. The KeyPackage arm drops a package that already seats its device.
14. `three_successive_silent_responders_never_move_ours_past_the_second_in_standing` (round 3).
15. `positions_are_the_same_for_every_insertion_order` (round 3).
Mutation pass additions: the echo inside the cooldown, the 20 s spacing before a silence clock, the
skip expiry, the settle order of the fixed point (a DFS-with-MAX replacement must fail unit 15), the echo branch, the "required" flag in the silence clock, the one-skip cap,
the min in best attribution, the MAX arm for a departed author, the parked copy's `None`, the
parked asked-for removal, the 8 s step, `Cannot` advance, the exact-bytes dedup.

### 10.6 Cost (replaces §8's build line)

Adds one wire variant (`MlsKeyPackageAck`) and one more optional bool (`answer`), a per-span
attribution list (bounded by ops already in the log), the parked-copy change in
`sync_handler::deposit_parked_join` and the parked branch of `swarm.rs`, and the ack timers. Build
estimate now about 2 to 2.5 builder days with the tests (door answerers +0.25 day if taken). Still no
relay, FFI or Dart change. Wiki §49 gains rows for the ack and the parked copy.
