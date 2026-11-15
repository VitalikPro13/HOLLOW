# g13-s3: MLS self-update cadence (AR-25) + receiver epoch-rate rule (AR-27)

> Archived design of the 0.13 track (AR-25, AR-27). The code and wiki `security_write_gates` §48 are authoritative where the review fix rounds changed it.

Builder s3, wave g13, base faf97c4b. Design v2: the hostile review folded in (v1 kept as
`DESIGN_v1.md`). Review finding numbers in brackets [R1]..[R11].

## 0. What the code does today (checked, not assumed)

- Commits come from whoever holds a queue in swarm Phase 2 (`swarm.rs:5845`): in practice
  the owner-first coordinator (`elect_server_coordinator`), plus the sibling re-adder
  (`MlsKeyPackage` arm), Phase 1 rebinds, founders, meeting hosts. The committer merges its
  own commit right after broadcasting. Nobody but a rebinding legacy leaf ever sends a
  path-only commit (`self_update_commit` is `#[cfg(test)]`; `rebind_own_leaf` comes from an
  UNBOUND committer and replaces the leaf's extensions).
- Concurrent commits at one epoch are resolved only after the fact: a receiver at the wire
  epoch SKIPS the second commit silently, the fork surfaces on the next probe, and **the
  branch the authority's acting device holds stays**; everyone on the other branch is
  repaired (one O(N) Welcome each). If the AUTHORITY loses a relay race, the whole group is
  repaired. **This root problem stays open** (section 4); this track only avoids feeding it.
- 0.12.2's judge accepts a commit from a bound member whose path leaf keeps the same
  `(device, master)` and that carries no proposals; it refuses any proposal other than
  Add/Remove. OpenMLS 0.9 accepts an unknown leaf extension listed in the leaf's own
  capabilities, and a path leaf may change capabilities and extensions.
- Any member can force epochs three ways: a path-only commit; repairs of its own siblings;
  fresh KeyPackages sent to the coordinator (it commits a remove + re-add every 2 s tick).
- Catch-up: `COMMIT_CACHE_CAP = 8`, RAM only; a member further behind than the cache gets a
  KeyPackage request and a full repair [R4].
- Costs (SCALE_PROBE 3, 5): ~0.12 ms x N per commit per member on desktop, 3-5x on a phone;
  a path commit in today's blank tree is 87 B x N broadcast to N; a Welcome 403 B x N.

## 1. AR-25: self-updates on turns, relayed through the committer

### 1.1 Shape

Members refresh with an ordinary path-only commit (fresh path secrets encrypted to everyone
but the committer: a copy of the old leaf state derives nothing after it). Re-add-by-repair
(Welcome per refresh, member drops its group, tree stays blank) and by-reference Update
proposals (new catch-up surface, refused by 0.12.2) were rejected.

N independent committers would race the authority (section 0), so members commit only on a
turn, and **the committer broadcasts their commit itself**. That gives one broadcaster per
group: the committer decides inside its own event loop whether epoch E is taken by the
member's commit or by its own, never both, with no lease timing to get wrong [R6].

- **The committer**: the device that would commit membership now (owner-first
  `elect_server_coordinator` over all leaves, or `elect_subgroup_coordinator`; within the
  identity the device for which `we_commit_for_our_identity` holds; only on a tick where
  `MlsTurn::take()` is true; and eligible per section 2.5). A device that has just become
  the committer waits one lease length (10 s) before committing or handing turns [R6].
- **Turn**: on a tick with no membership work queued, the committer may send ONE
  `MlsUpdateTurn { server_id, channel_id, epoch, nonce }` (random u64 nonce) to the chosen
  device and opens a lease (10 s). During the lease it commits nothing in that group.
- **Member**: accepts a turn only from the device ITS OWN election names as the committer,
  else declines [R3]; drops every stashed turn on any session transition (Suspended,
  Resumed, SessionLost, Connected) [R6]; acts on its next batch tick only if `MlsTurn::take()`
  holds, it is at exactly `epoch`, its leaf is bound, nothing of that group is held, and the
  receiver rule would accept the commit. It then STAGES a path-only commit (new HPKE key,
  same credential and device key, `application_id` mint stamp carried over, tally updated
  per 2.3) WITHOUT merging, and sends it to the committer only:
  `MlsUpdateTurnCommit { server_id, channel_id, epoch, nonce, commit }`. Otherwise it sends
  `MlsUpdateTurnDeclined { server_id, channel_id, epoch, nonce }`.
- **Committer, on the turn commit**: only from the turn's holder, for the open lease's nonce
  and epoch, while it is still the committer and still at that epoch. It processes and judges
  it like any received commit (a refused one is simply not relayed), merges, caches and
  broadcasts it with `broadcast_mls_commit`, emits `MlsEpochChanged`. A late one (lease over,
  epoch moved, nonce unknown) is dropped unrelayed. Declines count only from the holder for
  that nonce [R3].
- **Member, after sending**: when the room broadcast of its own commit bytes arrives it merges
  its pending commit (persist, `MlsEpochChanged`); when any other commit for that epoch
  arrives, or 30 s pass, it clears the pending commit. If it cleared a commit that was in fact
  relayed (it missed the broadcast), its next catch-up fails on its own commit and costs it one
  repair; only that member, rare.
- Variants: `live_only() = true`, `Lane::Relay` (as `MlsEpochProbe`), one dispatch fn in
  `crypto_handler`, wire pins in `types.rs`. 0.12.2 drops all three as unknown (1.4).

### 1.2 Cadence, cost, who is due

    B(N) = clamp(24_576 / N, 4, 48)      self-update commits per group per day
    I(N) = 24 h / B(N)                    at most one turn per group per I(N)
    P(N) = max(24 h, N x I(N))            each leaf once per P(N)

| leaves | leaf period | commits/day | desktop CPU/day per member | phone (x5) | relay egress/day, blank tree | filled tree |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 24 h | 10 | <0.1 s | <0.5 s | <1 MB | <1 MB |
| 100 | 50 h | 48 | ~0.6 s | ~3 s | ~42 MB | ~7 MB |
| 512 | 10.7 d | 48 | ~3 s | ~15 s | ~1.1 GB | ~40 MB |
| 2,048 | 171 d | 12 | ~3 s | ~15 s | ~4.4 GB | ~0.2 GB |
| 4,096 | 683 d | 6 | ~3 s | ~15 s | ~8.8 GB | ~0.4 GB |

(Blank tree: 87 B x N per path commit broadcast to N; filled: ~1.5 KB x N. Phones also
persist the whole state per commit: ~10 MB at 2048 until s2's incremental persistence.)
Constants in one place; a `cfg(debug_assertions)` override `HOLLOW_MLS_CADENCE_SCALE` lets
harness and fleet shorten them.

**Catch-up depth [R4]**: 48 commits a day against an 8-commit cache turns every phone that
sleeps a few hours into a full repair. The cache becomes a byte budget per group: up to 64
commits or 16 MB, whichever is less (RAM; ~2.9 MB at 512 blank, 11 MB at 2048 blank).
Persisting it across restarts is a REQUEST to s2 (section 6), not built here.

**Who is due**, from the tree so every committer agrees: freshness = the tally's
`refreshed_day` (day granularity, 2.3) else the KeyPackage mint stamp, both clamped to
<= now [R9, R11]. Candidates: leaves whose device the committer sees online and visible
(hidden devices are not in `ws_room_peers`), skipping any device that declined or let a turn
lapse (P(N)/4) and any device granted a turn within P(N) (committer-side RAM record) [R9],
and any whose master the turn would put at its cap with less than one entry of headroom
[R11]. Oldest freshness first, ties by device id. Pre-0.13 leaves get no priority [R11].

### 1.3 Subgroups, meetings, multi-device

Subgroups: own committer, own N, own turns. Meetings: no self-updates (only the pinned host
commits; meetings are short and RAM-only); PCS for a guest = knock again (section 3).
Multi-device: a leaf is a device, each device gets its own turn; turns are serialized by the
committer, so one-committer-per-identity does not apply to them.

### 1.4 Compatibility (AR-25)

0.12.2 receivers accept a 0.13 self-update (bound committer, same identity, no proposals;
the extra extension is listed in the leaf). A 0.12.2 committer drops turns, so nobody
self-updates in its groups (deliberate). A 0.12.2 member handed a turn drops it; the lease
lapses and the device is skipped. Not breaking.

## 2. AR-27: the receiver epoch-rate rule (v2)

### 2.1 Principle

Judged only on the pre-commit ratchet tree, the commit, and the anchored owner (fixed by
design E): identical for every member on a chain, live or catch-up, old member or joiner.
No clock, presence, roster or CRDT lag in the refusal. The history lives in the committer's
own leaf, because a joiner knows no past commits. **No per-receiver memory**: the v1 RAM
refusal record is gone [R1]; what it protected is now a pure function of the tree (2.5).

### 2.2 Definitions

- `TALLY`: private-use leaf extension `0xF5A1`, listed in every 0.13 leaf's capabilities:
  `version u8 = 1 | refreshed_day u32 BE | n u8 | n x epoch u64 BE (newest first)`.
- **capable leaf**: lists `TALLY` in its capabilities and carries one that parses. G counts
  unbound leaves as not capable [R11].
- **T(M)**: read ONLY from M's leaves whose `leaf_node_source` is `Commit` (lists in
  KeyPackage leaves are ignored, never judged) [R7]. Among them the list with the greatest
  head wins, ties by lowest leaf index [R7]. A chosen list that is malformed, longer than X,
  not strictly decreasing, or holds an entry >= E reads as **"M is capped at E"** (fails
  closed for M only) [R7]. Arithmetic saturating [R7].
- **G(M)**: every bound leaf in the pre-commit tree whose certified master is not M is
  capable (all receivers outside M's identity run 0.13).
- **uncounted commit** [R5]: it carries at least one Add of a device NOT seated in the
  pre-commit tree whose certified master is not M, or at least one Remove of a leaf whose
  master is not M and whose device the same commit does not re-add. **Every other commit is
  counted**: path-only, own-device adds/removes/repairs, and repairs of ANOTHER master's
  device (remove + re-add). A Remove that is view-dependent (revoked, non-member) is
  classified leniently as uncounted; if our view cannot justify it, the existing S3 rule
  holds it, as today, so classification never depends on our view.
- **capped(M, E)**: `|T(M)| = X` and `T(M)[X-1] + Y > E` (saturating), or T(M) fails as
  above. X = 3, Y = 12.

### 2.3 Rules (new, first in `commit_verdict`)

Skipped entirely for meetings and for unbound committers (the rebind) [R11], and for the
OWNER, who is exempt from all of them [R2]. Otherwise, for a committer of master M at epoch E,
only when G(M):

- **C1, counted commits need an honest tally**: the commit must carry a path, its path leaf
  must be capable, and the path leaf's list must be exactly `([E] ++ T(M))[..X]`. Else
  REFUSE. (Covers a pre-0.13 leaf's path-only commit, v1's C2.)
- **C2, uncounted commits cannot rewrite the tally**: if the path leaf is capable its list
  must equal T(M). Else REFUSE. An incapable path leaf on an uncounted commit is allowed
  (a 0.12.2 device's kick, ban, leave, revocation or stale-sweep removal) [R2].
- **C3, the cap**: a counted commit with `capped(M, E)` is REFUSED.

Honest committers evaluate the same function on the tree they commit on, and wait instead
[principle 3 of design D]: a capped stand-in coordinator lets the next eligible master
commit (2.5); the committer side applies C3 to repairs of a master at its cap, i.e. an
honest coordinator does not repair a device of a capped master until its window passes, so
a repair cannot reset a flooder's tally early [R5].

### 2.4 Why it cannot fork honest members

- Same inputs for every member on the chain; the rule runs before the CRDT holds.
- Under G(M) every receiver outside M's identity runs 0.13; M's own siblings may disagree,
  which forks M's identity alone. When G(M) is false nothing new is refused, matching 0.12.2.
- Owner exempt from everything: a mixed-version owner (0.13 desktop, 0.12.2 phone acting as
  its lowest online device) is never refused, so the whole-group fork in [R2] cannot happen.
- A non-owner 0.12.2 device under G(M) never makes a counted commit honestly: nobody hands it
  KeyPackages (every other member runs 0.13 and does not elect an ineligible master, 2.5),
  and its own siblings never target their own identity (`server_bootstrap_target` excludes
  it). Its uncounted removals are allowed (C2). So no honest 0.12.2 commit is refused.

### 2.5 Authority eligibility, a pure function of the tree [R1]

`ineligible(M, tree at our epoch E)` = M is not the owner AND G(M) AND (capped(M, E) OR M
holds a bound leaf that is not capable). Fed into, filtering candidates before the existing
presence election:
- the committer election (`elect_coordinator`, `elect_server_coordinator`,
  `elect_subgroup_coordinator`) and `server_bootstrap_target` where we hold the group: if
  every candidate is ineligible, fall back to the unfiltered choice (it can still make
  uncounted commits; counted ones are refused anyway);
- `group_authority` / `epoch_catchup_responder` (catch-up service, the fork winner via
  `is_authoritys_acting_device`) and `may_repair_our_leaf`: NEVER an ineligible master, no
  fallback. So no honest member defers to a capped flooder's fork, answers its KeyPackage
  request, or accepts its Welcome (a replacing Welcome needs `asked_for_leaf`, which needs
  an answered request or our own push to an eligible target), and a spent catch-up served by
  it asks no repair (`repair_after_spent_catchup` only trusts the elected responder).

A flooder sending its 4th counted commit inside the window is capped in every honest tree
(the three accepted entries are in its leaf), so all honest members refuse it AND stop
treating it as authority at the same epoch, restarted or not, caught up or not.

Residuals (documented, not fixed here):
- A leafless joiner has no tree to judge: a capped flooder elected by presence can Welcome it
  onto the flooder's fork; it is repaired back when it next probes an eligible authority.
- A flooder never repaired regains eligibility after Y honest epochs and, if it is then the
  lowest-id stand-in, the existing presence fork rule can side with its stale fork. The
  non-grindable stand-in authority is the lead's design D follow-up.
- After an honest repair of a flooder's only leaf, its tally restarts (KeyPackage lists are
  ignored): at most X counted commits per (Y epochs + one honest repair, which waits for the
  window).
- Accomplice cycle: a second admitted identity links a device and it is revoked, 2 uncounted
  epochs per cycle; bounded by roster changes and visible.
- A dormant pre-0.13 leaf of another master, or a sybil keeping one, keeps G false (option B).

### 2.6 Option C vs option B

**C (compatible, recommended for 0.13)**: the rules above. **B (breaking, when 0.12.2
retires)**: an owner-signed CRDT switch, then removal of pre-0.13 leaves (S3 rule f, held
until the receiver's CRDT has the switch), then a `RequiredCapabilities{TALLY}` lock in a
second commit (OpenMLS checks the requirement against removed leaves too). Afterwards G is
always true. A 0.12.2 device in a switched server keeps reading through Olm copies, its posts
become unreliable, voice breaks, no leaf until it updates. B changes no rule of C.

Fit: C v2 fits this wave (rules in `commit_verdict`, `CommitFacts` gains the tally inputs,
eligibility is one helper threaded into six existing election sites). If the second review
finds more, fallback as the lead proposed: ship turns + section 3 bounds now, receiver rule
with B.

## 3. Forced re-keys through an honest committer

- **Coordinator budget per requesting master**: KeyPackage-driven leaf changes for one master
  (adds or repairs of its devices) commit freely 3 per 10 min, then one per backoff doubling
  1 min -> 30 min, reset after 30 min quiet; over-budget KeyPackages stay queued (newest per
  device wins); a capped master's repairs wait for its window (2.3).
- **Meeting host**: a seated device knocking again is re-seated at most once per backoff (30 s
  doubling to 10 min, reset after 10 min quiet), the knock waiting in `pending`; admissions
  without a waiting room batch per tick into one commit, at most 6 admission commits a minute.

## 4. Open and out of scope

- **Root problem**: the fork rule sides with the authority by presence, so an authority that
  loses a relay race (or a hostile one) repairs the whole group. Turns avoid adding races; the
  non-grindable authority is the lead's design D follow-up.
- F1 (v1) withdrawn as written [R10]: a responder can trigger our probe at will, and it would
  break honest asks (SFrame heal, subgroup reconcile, PeerJoined asks). Counting repairs of
  others (2.2) removes its flood angle; the rest goes with the design D follow-up.
- F2 (LOW): an old unused pre-0.13 KeyPackage of another member's unseated device lets a
  committer add a pre-0.13 leaf and turn G off; closed by option B.

## 5. Tests (harness first; each fails without its rule)

Harness, end of `node/test_harness.rs` under `// g13-s3`, cadence shortened:
1. `g13s3_turns_refresh_every_leaf_once_without_a_fork` (zero Welcomes after setup).
2. `g13s3_concurrent_self_updates_at_one_epoch_converge` (no turns, `hold_broadcasts`, both
   orders; no group dropped, owner never repaired).
3. `g13s3_a_turn_commit_and_the_committers_add_never_share_an_epoch`.
4. `g13s3_a_turn_from_a_device_that_is_not_our_committer_is_declined`, and a decline from a
   non-holder does not end the lease.
5. `g13s3_a_late_turn_commit_is_dropped_unrelayed` (lease over or epoch moved).
6. `g13s3_a_flooding_member_is_capped_while_honest_members_converge`.
7. `g13s3_a_capped_stand_in_authority_cannot_repair_honest_members_onto_its_chain`, including a
   member restarted between the refusal and the probe (no RAM state).
8. `g13s3_repairs_of_another_masters_device_count_against_the_committer`.
9. `g13s3_a_mixed_version_owner_is_never_refused`; `g13s3_a_pre_013_uncounted_removal_passes`.
10. `g13s3_a_backgrounded_device_takes_no_turn` (hidden / socket down; stashed turn dropped).
11. `g13s3_a_leaf_copy_stops_decrypting_after_the_victims_self_update`.
12. `g13s3_a_member_away_for_a_day_of_cadence_catches_up_without_a_repair`.
13. `g13s3_subgroup_leaves_refresh_under_the_subgroup_coordinator`.
14. `g13s3_key_packages_in_a_loop_get_bounded_repairs`; meeting re-knock and knock batching.

Units: `TALLY` codec and every malformed form; T(M) (Commit-sourced only, tie-break, future
entry fails closed); C1-C3 matrix incl. G false, owner, meeting, unbound committer, counted
vs uncounted; eligibility; cadence formula; a 0.12.2-judge compatibility test written before
any judge change. Mutation pass per rule and per layer (receiver rule, committer mirror,
election filter). Fleet m + n: voice call stays up with SFrame across a turn's epoch change.

## 6. Files and requests

Mine: `node/mls_authority.rs`, `node/crypto_handler.rs`, `node/swarm.rs`, `node/types.rs`,
`node/conference.rs`, `node/test_harness.rs`. Shared with s2, kept tight:
`crypto/mls_manager.rs` (TALLY on KeyPackages and new groups, staged self-update builder,
`CommitFacts` tally inputs, commit-cache byte budget). No persistence, FFI or relay change.
**Request to s2**: persist the commit cache (or its last day) with the group state, so a
restart does not cost every lagging member a repair.

## 7. v2.1: second review folded in (these override sections 1-3 where they differ)

- **F, relay order**: the committer stages and judges the turn commit (a Hold counts as a
  refusal, never kept), BROADCASTS it, then merges and persists, never merging first (a
  committer dying between merge and broadcast would sit alone at E+1 as authority). It
  relays only on a tick-free path while `MlsTurn` allows (backgrounded or socket down: drop).
  Our own relayed commit surfaces as `OwnPendingCommit` on the live AND catch-up paths and
  merges the pending commit. No 30 s pending clear: the pending commit stays until our echo
  or another commit (OpenMLS clears it then); we clear it early only when we must commit
  ourselves and the turn is older than lease + slack (after a restart, counted from start).
- **A, repairs charged to the target**: a KeyPackage-driven repair of master N's device
  counts against N, not the committer. The committer's path leaf carries, for each master N
  it repairs in that commit, `([E] ++ T(N))[..X]` (a "carried" entry keyed by N's master id);
  every receiver checks it against the pre-commit tree. T(N) reads N's own Commit-written
  leaves AND carried entries for N in any Commit-written leaf (greatest head wins, same
  tie-break, same fail-closed). Carried entries whose head + Y <= E are pruned by the next
  path leaf that writes them, so a leaf holds at most about Y of them. Removes the
  tally-reset residual: a repaired flooder keeps its history. C3 then applies to the target:
  a repair of a capped master's device is refused; honest committers wait for its window.
  The committer itself is charged only for commits that touch its own leaves or carry no
  proposals.
- **B, committer election filter**: the committer election and `server_bootstrap_target`
  filter ONLY on capped(M), and only for a master whose every leaf is capable (never on
  "holds an incapable leaf", which would let a 0.12.2 lowest master elect itself while 0.13
  members elect another: two committers). The full predicate (capped OR holds an incapable
  leaf) stays on the catch-up responder and `may_repair_our_leaf`. Section 2.4's claim is
  corrected: a 0.12.2 master can still be a committer by presence; its counted commits under
  G are refused only where they touch its own leaves (C1), and it gets no KeyPackage-driven
  repairs of others charged to itself (A).
- **C, fork winner stays presence-only**: `is_authoritys_acting_device` is not filtered
  (both forks must name the same acting device or the fork never heals). The flooder case
  stays covered by the filtered `may_repair_our_leaf`, `asked_for_leaf` on replacing
  Welcomes, and the filtered responder in `repair_after_spent_catchup`.
- **D, counting**: a commit is COUNTED for the committer if ANY item touches its own leaves
  or the commit carries no proposals; each repaired foreign master is charged per A. An
  incapable path leaf is allowed only when the commit touches none of M's leaves and charges
  nobody. Honest capped committers split counted items out of a batch and commit the rest.
- **E, KeyPackage forwarding**: a member that is not the (filtered) coordinator forwards a
  KeyPackage it received to the coordinator its election names (the package is signed by the
  joiner's device, so forwarding is safe) instead of dropping it. A subgroup's election uses
  the subgroup's own tree when held, unfiltered otherwise.
- **G, catch-up depth by role**: 64 commits / 16 MB only on devices that can serve (desktop,
  foreground, electable); phones keep 8 commits / 2 MB. `MlsCommitCatchup` is sent in frames
  of at most 4 commits, and the receiver yields to the event loop between commits.
- **H**: section 2.4 text: a 0.12.2 sibling's `sibling_readd` fast path makes a counted
  commit (identity-local, contained to that identity's own fork).
- **I**: residual wording: a joiner on a flooder's fork is in practice pulled back only by
  the owner; a group with no eligible responder logs it once.

## 8. Build notes (what the code does where it differs from the text above)

- The member recognises its own relayed self-update by its exact bytes and build epoch
  (`MlsManager::own_staged`): OpenMLS 0.9 surfaces our own PRIVATE commit as
  `OwnPrivateMessage` (undecryptable to its author), not `OwnPendingCommit`.
- The turn holder checks the turn's sender once, when the turn arrives; the stale-turn
  window is covered by the 4 s age bound and the committer's own relay checks (still the
  committer, same epoch, `MlsTurn::live`). A lapsed lease is expired by the committer's
  batch tick, the only place it ends without a commit or a decline.
- A capped committer: `crypto_handler::fit_coordinator` replaces the elected master by the
  lowest fit online master (our own election always counts us online, so filtering the
  member list alone is not enough), and the elected device forwards the KeyPackage there
  (`MlsKeyPackageForward`).
- The committer's tally is derived inside `MlsManager::commit_membership` for every commit
  with a path or a charge, so kicks, leaves, sibling re-adds and Phase 2 all state it.
- Merge points for s2 (`max_past_epochs(0)` + `crypto/mls_past.rs`): (1) the `own_staged`
  branch of `process_commit_judged_then` calls `group.merge_pending_commit` directly; (2) the
  relayed turn commit merges in `process_commit_judged_then`'s Accept branch after
  `before_merge`; (3) `merge_own_self_update` goes through `merge_pending_commit`. Each must
  capture the past epoch the way s2's merge does.
- Follow-up (s2 finding): commits leave before their merge is saved. The relay order here
  (judge, broadcast, merge, persist) keeps the committer from sitting alone at a new epoch;
  s2's `WsCommand::AfterMlsSave` would send after the save. The two hazards differ (behind
  after a crash vs. alone as authority after a crash); worth one decision for every commit
  path, test `a_commit_leaves_only_after_its_merge_is_saved`.

## 9. Fix round (builder s3-2, after the hostile code review)

- H1: `MAX_CARRIED` 32 -> 1024 with a u16 count (a whole-group repair fits in one leaf); `Tally::checked` makes `expected_tally` never derive a tally that does not decode; the committer side (`over_cap_devices`) defers repairs past the bound (`mls_rate::carried_overflow`) and repairs of a master whose history is unreadable, the owner's too, wherever G holds.
- H2: `prior_carried` takes the committer's earlier carried entries only from a commit-written leaf, drops entries naming its own master or out of order (shared by committer and receiver).
- L5: `commit_membership` commits nothing when G holds and no honest tally can be derived (was: restate the old tally).
- M1: a turn from our own identity's committing device (a sibling, not us) is taken.
- M2/L2: `TurnBook::close_turn` requires the lease not run out; a held commit of the group drops a turn commit.
- M3: `may_repair_our_leaf`'s subgroup clause filters unfit masters.
- M4: knocks on an open meeting queue (one place per knocker, 64, 2 min) and are seated on the batch tick, all due in ONE commit, at most 6 such commits a minute; a knocker blocked meanwhile is dropped.
- L1: owner exemption via `crypto_handler::is_anchor_owner` (anchored owner). L3: rebind declares the tally, history unchanged. L4: KeyPackage forward dedup per local device; replay residual in the wiki row.
- Residuals: a committer can write any carried entries while G is false; they count once G turns true (bounded to 12 epochs; option B closes it). A master whose own commit-written tally is unreadable cannot be repaired by anyone while G holds (only reachable by that master writing it while G was false).
