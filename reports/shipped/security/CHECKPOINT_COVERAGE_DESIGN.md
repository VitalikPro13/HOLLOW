# Checkpoint coverage: a checkpoint replaces only what its owner folded

Design, revision 2, 2026-11-01; approved and built in 0.14 (56587ca2, track t14-cover,
2026-11-05), with the fix round of code review rev 3 (2026-11-04). EMBARGOED with 0.14
until it ships (local branch `security/0.14`, base `c5d7bcf4`). Section 10 is replaced by
`DEVICE_PROOF_DESIGN.md`. Review of revision 1:
`.team/review/REVIEW_REV1.md` (findings F1 to F13, probes in `probes_fold_tests.rs`).

Scope: design E's owner checkpoint (`crdt/fold.rs`, `crdt/server_state.rs`), every path that
prunes, stores, restores, fingerprints or serves the op log around it, and (new in rev 2)
which device minted an op. It replaces the leave-only special case of commit `24224155`
("option A").

## Changes from revision 1

| Finding | Change |
|---|---|
| Q4 (decision A) | The stamps ARE the coverage: an op is dropped when the base dominates it (section 4). Gone: `seq`, `hollow-crdt2`, the counter and its start skip, coverage ranges, `legacy_ids`, the `seq` store columns, decision 5. |
| F1 (decision B) | Decision 3 kept (today's authority), reframed with what it closes and what it undoes (section 6), plus two mitigations: the owner checkpoints only after digest rounds with two distinct identities, and a device whose own admission a rebuild refuses asks to join again at once. F1(b) (never cover a removal while its author misses an earlier op) dropped: it needed contiguous streams. |
| F2 | Equivocation: the content hash joins the dedup key and the digest id; the lowest hash wins (section 7). |
| F3 | Quotas: an order-independent max-min allocation with a per-author floor; caps sized from the measured standing leader; a quota never deletes a member's row (it parks it); the author's device keeps refused ops in an outbox and offers them again at every base change (section 8). |
| F4 | The dormant set is relative to the base's named PARENT, carried in the checkpoint, kept in the digest and the store but not folded. The 30-day owner hand-back is gone (section 5). |
| F5 and the Q2 sweep | Every arm reclassified (section 4 table): `is_public` clock on both visibility arms, the span window for nickname, Twitch and pledge, admitter and span history and display name on `MemberAdded`, the emote and sticker cap independent of order, join lock links, grants and removals, ban rank, the target side of kicks and bans. |
| F6 | Moot: there is no sequence-less cut and no `legacy_ids`. Under section 10 an op without a device proof is refused after the first 0.14 checkpoint and dominated before it, so it cannot stop compaction. |
| F7 | Mixed servers rewritten with the MLS tug-of-war; the red critical notice is decided (section 12). |
| F8 | `held` takes only authors in `member_record` or named by a held or retained `MemberAdded`, then per-author fairness (section 8). |
| F9 | An admission whose `ask.at` is at or below the target's last own leave is refused (section 6). |
| F10 | Gone with `seq`. |
| F11 | Restore picks the base from the rows; `persist_admitted_ops` runs in one transaction; the prune exemption is keyed on the founding op itself (section 9). |
| F12 | Member-at-its-clock is exempt on Legacy anchors and passes an author with no record (section 6). |
| F13 | Rebuild coalescing flushes before `author_checked` and before a join completion is judged (section 8). |
| Q5 | The join answer finding corrected: it is one targeted `SendDirect` the relay buffers for an absent joiner, not a `~join` ring entry. |
| New | A roster-removed device can still author ops with the master key. Section 10 adds a device proof to every op, the one op-format change. |

## Changes in the build's fix round (code review rev 3, 2026-11-04)

| Finding | Change |
|---|---|
| H1 | A stamp FLOOR (`cp_floor` in the state JSON, `#[serde(default)]`): every op at or below it is decided. Rebasing on an unstamped (0.13) checkpoint sets it to that checkpoint's `covers`; a legacy server's first checkpoint covers what its owner witnessed (its clock) and carries that as the floor. Every descendant carries it, so the first stamped child no longer forgets what `covers` decided. Enforced in dominance and in the apply arm alike; a floor above `covers` makes no base. |
| H2 | Charge TREES, not lineage groups: max-min over the anchor's members (floor kept), then inside each member's tree max-min again between its own ops and each subtree it admitted. Staff kicks, bans, demotions and mutes join admissions and lock moves in the staff-first set; staff is the anchor's moderators and above as the owner's own role changes in the set leave them. |
| H3 + M4 | No hysteresis. The allocation is a pure function of the op set, kept in RAM (`Quota`) so a tail op is judged with the verdict a whole rebuild gives: an author already over its share stays over whatever it adds (a demand at or above the level moves no level), so its op waits in `held`, never a row, with no rebuild; any other tail op rebuilds only when the shares move below what is folded. Within an author the oldest ops come first, up to the first that does not fit. Parked rows are capped per tree at 128 KiB (staff acts against the staff budget, our own admission always kept for the re-ask); a restart deletes rows parked past their time. |
| M5 | No base, still a quota: trees root in the founding state's owner. |
| (new) | The anchor owner's own ops are never charged: it compacts its own log. |
| M-L6 | Writer rule: two witnesses, one a moderator or above, or two whose admissions root in different members of the base other than the owner (the owner answers anyone's join, so an identity it admitted is free). |
| L7 | F8 built: an op waits in `held`, or is charged at all, only from an author the set knows (a record, or an admission held). A live op that only makes a dormant row is persisted. A field write to a channel or label that does not exist at its point is refused (parked, expires) instead of staying undecided forever. |
| AR-11 (decision 11-04) | "Void granted powers only", section 6. |
| (new) Byte bounds | The core had none for CRDT ops (the 64 KiB `MAX_MESSAGE_BYTES` is chat bodies only). Now the door refuses an op whose signed bytes pass 1 MiB, or 16 MiB for a checkpoint (a 512-identity state is about 0.75 MB), whoever signs it: refused, never held, never a base. Anything a checkpoint will carry (review items, waiting entries) fits inside 16 MiB or the checkpoint is no base anywhere. |

## Changes in the final fix round (focused review 4, 2026-11-05)

| Finding | Change |
|---|---|
| HIGH-1 | A refused removal no longer voids: a rebuild records which removals voided something, and a pass in which such a removal did not fold runs again without it (at most 4 passes, section 6). The tail and a rebuild of the same set agree again (`a_refused_removal_leaves_the_tail_and_a_rebuild_equal`). |
| MED-2 | The owner measures a checkpoint's signed size BEFORE signing it (the state's bytes plus one escape per quote and backslash, plus a 16 KiB margin). One that would pass 16 MiB is never signed, and any try that is not kept waits an hour (`cp_retry_at_ms`, RAM only) instead of re-signing every tick. Measured per identity: a current member about 1.26 KB, one that joined and left about 0.95 KB, a ban about 0.37 KB, plus about 8% from escaping. The bound holds a server's whole lifetime of about 15,000 departed identities next to 512 members (or about 40,000 bans). Not trimmed: a departed identity's spans and `asked_at` judge its late ops and keep each ask admitting once (HOL-SEC-092), and its events end the spans the AR-11 voids read. Not raised: every joiner downloads the checkpoint. Past the horizon the owner stops compacting (residual, section 16). |
| MED-3 | Residual (lead decision): a leave carries no list, so a member that left, was admitted again and is then kicked can backdate grants into its older span. AR-11 and section 6 now also say what a kick does not void (acts that grant nothing) and that a checkpoint-decided removal voids late honest grants too. |

## Decisions for Vitalik

Answered 2026-11-01:

1. **Mixed servers: ACCEPTED, with a RED critical status notice for 0.13 at release.**
   Section 12 says what really happens.
2. **Compaction stays owner-only: ACCEPTED.**
3. **Late ops judged by today's authority: KEPT, with the F1 mitigations** (section 6).
4. **Caps: measured from the standing leader's real load, plus the outbox** (section 8).
5. **Clone residual: GONE** with `seq`.

Open:

6. **The removed-device fix (section 10).** It adds a device proof to every 0.14 op. As a
   result, 0.14 replicas refuse proof-less (0.13) ops once the server's first 0.14
   checkpoint exists. This makes the decision-1 freeze start at the owner's upgrade
   instead of never. Pick: build it in this track (about 2.5 builder-days).
7. **What a rebuild does with a once-admitted row it now refuses.** Pick: park it (stored,
   not folded, not in the digest, judged again at every rebuild, 30 days, inside the
   author's quota) rather than delete it. A late admission then still brings the
   member's later ops back.
8. **Fix equivocation in 0.14 (F2).** It exists today (probe
   `probe_equivocation_at_one_clock_splits_replicas`). Pick: yes.

## 1. The problem

The owner's checkpoint carries one clock, `covers`. Every replica treats it as replacing
everything at or below that clock and prunes it. But the owner only saw part of that
history. An op stamped below `covers` that never reached the owner is overwritten on every
replica, and a replica that receives it later refuses it. Examples: a phone that was
offline, a slow sync, a sibling device of the owner. What is lost this way: late leaves,
rejoins, members admitted by other members, role changes, bans. Option A rescued only a
member's own leave. Two owner devices checkpointing at once already lose ops today (probe
`probe_concurrent_owner_checkpoints_lose_an_op_today`).

## 2. Requirements

- **Consensus.** Every replica holding the same ops reaches the same state, the same
  retained set and the same digest entries. This must hold whatever the arrival order or
  batching, across a restart through the production path (`lean_snapshot` +
  `persist_admitted_ops` + `restore_op_log`), and across a prune, a paged whole-log fetch,
  a join snapshot, and whichever checkpoint the replica was on before. Section 10 adds one
  input: the rosters held for authors with a removed device.
- **Authority unchanged or stronger.** Every op is judged by `op_allowed`. The owner and
  the anchor stay fixed. Join snapshots keep only the owner's role (HOL-SEC-093).
  `MemberAdded` needs its `JoinAsk`, and each ask admits once (HOL-SEC-092). Nothing a
  non-owner sends can make the base dominate another author's op. A device its roster
  removed gains nothing from still holding the master key.
- **Compaction only.** Joining, talking, syncing, leaving, role changes and a returning
  device's catch-up all work with the owner offline for months, with no visible
  difference. A late or stale checkpoint never wipes or undoes what members did meanwhile.
- **Bounded and fair.** Every op the base does not dominate sits under a bound that is fair
  per author. This holds for all of them, backdated floods included.
- **Invisible.** Nobody drops out and comes back. No prompts. No wait on the owner. No
  added latency on a normal op.
- **Cost.** No per-op scan that turns quadratic on a junk batch.

## 3. The design on one page

1. Every element of the state carries the clock of its newest write, or a tombstone with
   that clock. Some elements already do (the LWW registers); the build adds the rest.
2. An op is DOMINATED by the base when its whole effect is already decided by the base:
   every element it writes holds a base stamp at or after the op's clock, or the op falls
   outside its target's span window. One exhaustive match per payload decides this, so a
   new variant does not compile until it is classified. An op the owner folded is always
   dominated. An op the owner never saw, but would lose anyway, is dominated too, and that
   is the right answer.
3. The fold runs in this order: the founding op of a self-certifying id, then the base,
   then every op the base does not dominate, in HLC order. Each op is judged by
   `op_allowed` against the state just before it. Dominated ops drop at the door with a
   few map lookups and no rebuild.
4. The base is the greatest checkpoint held, ordered by (generation, op clock, author).
   Ops the base dominates but its parent did not stay dormant: stored and fingerprinted,
   but not folded. A switch to a rival checkpoint of the owner's other device therefore
   loses nothing, whatever path a replica took to get there.
5. Uncovered ops get an order-independent fair share. `held` admits only known authors.
   Equivocations resolve by content hash.
6. Every 0.14 op names its minting device and carries that device's signature. A device
   its author's roster removed cannot checkpoint, delete, or write after its removal.

## 4. Dominance and the stamps (was Q1 and Q2)

**Why not sequence numbers.** Revision 1 put per-device sequence numbers in the op. The
review showed the stamps already carry that weight. An op the owner folded has left its
clock, or a later one, on every element it writes. So "dominated" covers everything a
coverage range covered. It also drops ops that would lose anyway, and it costs no op-format
change, no counter, no store columns and no clone residual. What is given up is the second
safety net: with ranges, a missing stamp was hidden by the coverage. Here a missing stamp
lets an older late op undo a newer write. The mitigation is the property test against a
clone-and-apply oracle in section 14 (U10), which runs over every payload kind.

**Where an uncovered op folds.** On top of the base, in HLC order among the uncovered ops (a
rebase). It cannot fold at its own clock inside the covered history, because that history
is pruned and a joiner never had it.

**What a fold in HLC order sees.** Every op is newer than every stamp it meets. So on a
genesis server and on a tail apply, dominance never fires and no stamp changes a result.
Today's tests keep passing, and the stamps are visible only on a rebase.

**The arms.** "Stamp" is the clock of the newest write to an element; "dominated" is the
rule `is_dominated` applies. One exhaustive `match` in `crdt/dominance.rs` holds it.

| Payload | Elements and merge | Dominated when |
|---|---|---|
| `ServerCreated` | founding | never (kept for proof; judged by its own rule) |
| `ServerCheckpoint` | the base | below the base in the order (refused at the door) |
| `ServerRenamed`, `ServerSettingChanged`, `JoinKeySet`, `RolePermissionsChanged`, `MemberMuted`, `MemberUnmuted`, `ChannelGrantSet`, `ChannelGrantRevoked` | LWW register | register stamp at or after the op. Unmute and revoke keep their tombstone, no prune |
| `MemberBanned`, `MemberUnbanned` | ban register (LWW, tombstone kept) plus presence | ban register stamp at or after the op, and (for a ban) presence already gone at or after it. A ban that ends `true` after its merge always removes presence (a later admission of a banned target is refused anyway) |
| `RoleChanged` | role register | register stamp at or after the op, or the op before the target's current span |
| `NicknameChanged`, `TwitchUsernameChanged`, `StoragePledgeChanged` | per-member register | register stamp at or after the op, OR the op before the target's current span (F5: today `MemberRemoved` deletes these registers, so without the window a late write from before a re-admission comes back) |
| `MemberAdded` | presence (`member_stamp`), span history, admitter, display name | presence stamp at or after the op AND its span is already in the record AND its admitter is recorded with a clock at or before the op AND the display name stamp is at or after it. Span history is always inserted by clock (a superseded admission still records its historical span, so the backfill gate HOL-SEC-048 and member-at-its-clock see it). `note_admitter` writes only into the span that contains the op's clock, never a later one. The display name becomes LWW at the admission clock |
| `MemberRemoved` | presence, span history, join-lock removal mark | presence stamp at or after the op and the span's end already recorded. `note_removal` fires only when the removal changed presence at its clock |
| `ChannelAdded`, `ChannelRemoved` | channel existence with a tombstone | existence stamp or tombstone at or after the op |
| `ChannelRenamed`, `ChannelPostingChanged`, `ChannelSlowModeChanged`, `ChannelMediaOnlyChanged`, `ChannelVoiceChatChanged`, `ChannelPostingLabelsChanged` | one field register each | field stamp at or after the op |
| `ChannelPublicChanged`, `ChannelVisibilityChanged`, `ChannelVisibilityLabelsChanged` | their field plus the `is_public` register (F5: both visibility arms clear `is_public`, so they write its stamp too) | every element it writes stamped at or after the op. A late `public = true` therefore never reopens a channel restricted later (HOL-SEC-094) |
| `ChannelLayoutUpdated` | one LWW register | stamp at or after the op |
| `MessagePinned`, `MessageUnpinned` | per (channel, message) register with tombstone | stamp at or after the op |
| `LabelCreated`, `LabelUpdated`, `LabelDeleted` | per label existence and fields, tombstone | stamps at or after the op |
| `LabelAssigned`, `LabelUnassigned` | per (member, label) register with tombstone | stamp at or after the op, or the op before the member's current span |
| `EmojiAdded`, `EmojiRemoved`, `StickerAdded`, `StickerRemoved` | per key register with tombstone | stamp at or after the op. The cap of 50 becomes order-independent: of the live entries, the 50 with the oldest add clocks show (no refusal at apply, which depended on order) |
| `JoinLock` | links (a chain), door, grants, removal mark | link already held and door stamp at or after it and its grants recorded. `link_allowed` judges a late link against the base's held chain (the base keeps the links). Grants per master keep the 4 newest by clock, never by apply order |
| `ServerDeleted` | the deleted latch | never dominated (monotone). It needs a counted device (section 10) |

`AdminLwwReg` priority still comes from the author's rank at apply time. The reviewer's case
was a moderator lifting a late ban by a since-demoted admin. That case cannot happen: under
decision 3 the demoted admin's late ban is refused outright. A promoted author's late ban
carries its newer, higher rank, so lifting it needs that rank (stricter, never weaker).

## 5. Supersession, forks and the dormant set (was Q4)

**What a checkpoint carries.** `ServerCheckpoint { state, covers }` keeps its shape, so 0.13
still reads it whole. New fields ride inside the state JSON (`#[serde(default)]`, ignored by
0.13): `cp_generation` (the parent's plus one), `cp_parent` (the parent checkpoint's author
and clock), `cp_parent_horizon` (the newest stamp in the parent), and `cp_late` (the ids of
ops dated at or before the parent horizon that the owner held as uncovered under the parent;
at most 64 per author and 8,192 in all). `covers` is written just above the parent's
`covers`, so a 0.13 replica prunes little.

**Order.** The base is the greatest checkpoint held, by (generation, op clock, author). A max
does not depend on arrival order. A checkpoint below the base is refused at the door. A 0.13
checkpoint is generation 0.

**The dormant set (F4), a pure function of (base, op).** An op is dormant when the base
dominates it AND its parent would not have: its clock is after `cp_parent_horizon`, or its
id is in `cp_late`. Dormant ops are stored and in the digest set, so every replica that
syncs holds them, whatever path it took. They are never folded. On a switch to a rival
child of the same parent, or of a descendant of it, every op the old base dominated and the
new one does not is dormant under the old base. It therefore folds at once in the same
rebuild, and nobody flickers. A child stamps everything its parent stamped, so an op the
parent dominated is dominated by every descendant.

**Residual.** A fork two generations deep can lose ops that only the losing lineage
dominated. It takes an owner device writing two checkpoints while cut off from its sibling
for over an hour, with more than 2,000 ops on each side. The revision-1 30-day hand-back is
gone: nothing triggered it.

**The floor.** A child stamps only what changed since its parent. When the parent carried
no stamps (0.13) or no provable history (a legacy server's first checkpoint), the child
also carries the parent's `covers` as `cp_floor`: every op at or below it stays decided
in every descendant, at the door and in the apply arm.

**A stale checkpoint.** An owner device back after months writes a child of the base it
held. Everything members did meanwhile carries newer clocks than its stamps, so none of it
is dominated. It folds on top. U5 and H1 prove it.

## 6. Authority on a rebase (decision 3, F1, F9, F12)

An op the base does not dominate is judged against the state on top of the base, so by
today's authority:

- **What it closes.** A kicked member backdates an admission to just before its kick and
  seats a puppet. A fold from history admits that, and so does today's code (probe
  `probe_a_kicked_member_backdates_an_admission_today`; the `CrdtOpBroadcast` arm does not
  gate the carrier, `swarm.rs` 11062-11090). Today's authority refuses it: the author is not
  a member now. A demoted admin's backdated acts are refused the same way.
- **What it can undo, honestly.** The owner is away. B admits C, then C admits D. Then B
  leaves, and the leave reaches the owner first (`leave_book` hands it straight to the
  owner). The owner's catch-up came from a member lacking B's admission of C: a lagging
  phone, or a member withholding ops (residual L2). The owner checkpoints with B's leave
  but without C's admission. On top of that base, C's admission is refused (B is not a
  member now). So are C's ops and D's admission. The same class: a moderator's ban refused
  because its target was promoted later, an admission refused because the server became
  full or private later.
- **Mitigation (a), the writer rule.** The owner checkpoints only after completed digest
  rounds with two distinct identities (masters other than its own) since its last
  connect: the `crdt_resync` two-identity rule. One of them must be a moderator or above,
  or the two must root (through the earliest admitter of each span) in different members
  of the base other than the owner, or every other member answered. The owner answers
  anyone's join, so an identity it admitted is free and counts for nothing. One
  withholding member and its puppets can no longer decide what the owner saw.
- **Mitigation (c), the silent re-ask.** A rebuild may leave our own identity outside the
  member list with no removal or ban of us in the retained set or in the base's span
  record (a closed span means a real removal). Then each device of ours re-asks to join at
  once, with a fresh `JoinAsk` and no prompt, through the parked-join path. Any online
  member answers it by standing; it never needs the owner. Our self registers (nickname,
  Twitch name, pledge) are written again from local state after the re-admission. In the
  cascade above, C and D each re-ask on their own, and all heal within one join round
  trip.
- **Member at its clock.** Every op's author must hold a span containing the op's clock
  (`from_hlc <= op.hlc < until_hlc`; `until_hlc` is a new `#[serde(default)]` field, a span
  without exact clocks reads its ms). On an in-order fold this is the check `op_allowed`
  already makes. It is skipped on a Legacy anchor, and an author with no record passes
  (F12): such an author is never a current member on an anchored server anyway.
- **F9.** An admission is refused when its `ask.at` is at or below the target's last own
  leave in ms. Both are the target's own clock, so a delayed retry of an old ask never
  re-admits someone who left after asking (probe
  `probe_an_ask_older_than_the_askers_own_leave_readmits_it`).
- **Unchanged.** Each ask admits once (`asked_at`), the ban on admission, the cap, owner
  verify and the Twitch gate. Standing positions never precede the admitter's own.
- **A kicked member's backdated grants (AR-11, decision 2026-11-04: void granted powers
  only).** A kick or ban carries `seen`: 16-byte prefixes of the content hashes of every
  power-granting op of its target the remover folded inside the span it closes
  (admissions, role changes, permission and channel grants, labels given to someone else,
  join lock moves, lifted bans), and the remover's base as (generation, content hash).
  A target op of those kinds dated inside that span is void at its own point in the fold
  unless named, or decided by that base. The span is the one the op sits in: the first
  leave or removal after it ends it (from the record or ahead in the op set). A ban of
  someone who already left closes that last span the same way, only while no admission
  came between the leave and the ban. Where the removal's op is gone (decided by our base, so only
  its span end is in the record), such an op is void too. Rules:
  - The verdict reads the whole op set: a rebuild looks ahead to every kick and ban in it
    (`crdt::voids::Ahead`); a kick folding at the tail rebuilds when it voids an op
    already folded.
  - A removal counts at the op's point only if its author could kick the target there.
  - A removal voids only if it folds at its own point. A rebuild learns that only on
    reaching it, so a pass in which a voiding removal was refused (kicked or demoted
    before it, over its quota, held) runs again without it, at most `VOID_PASSES` (4)
    passes. The tail judges each op by the same verdict, so the tail and a rebuild of
    the same set agree.
  - A removal naming a base this replica does not hold and that is not older than its
    own waits for that base (held), instead of voiding what that base may decide.
  - The list holds at most 1,024 hashes (about 36 KB, inside the 64 KiB op bound); past
    it the newest are named and `before` marks the rest as seen (residual: a backdated
    grant older than the cut survives).
  - A kick or ban from before 0.14 carries no list and voids nothing while its op is in
    the retained set, so the history a server already holds keeps whom its later-kicked
    members admitted. Once a checkpoint decided a removal, of any version, only its span
    end is left, and a grant of the target dated in that span that arrives later is void
    (honest ones too; the admittee re-asks).
  - Ordinary acts (nicknames, a leave) still fold; a joiner whose admission is void asks
    again by the silent re-ask.
  - Residuals (AR-11, accepted): a demotion closes no span, so a demoted admin can still
    backdate a promotion to before its demotion. A kicked member's backdated acts that
    grant nothing (kicks, bans, mutes and demotions of others, channel and label
    removals, renames) still fold inside its span, as they would have while it was a
    member. A leave carries no list, so a member that left, was admitted again and is
    then kicked can backdate grants into its older span (its own leave closed it). A
    removal dropped in one pass that folds in a later one voids nothing, and a chain
    longer than four passes keeps the fourth pass's result.
  - Wire: `MemberRemoved`/`MemberBanned` gain `seen` (`#[serde(default)]`, skipped when
    absent, so an old op keeps its bytes). 0.13 cannot read a 0.14 kick whole and keeps
    it unread (0.14 is the clean break).

**The leave scenarios as ordinary ops:**

- A late own leave behind the checkpoint closes the span at its clock.
- A rejoin the checkpoint missed opens a new span on a newer ask.
- A leave and a rejoin both missed fold in clock order, and M ends a member. (Option A's
  fix round asserts the opposite; that expectation flips back.)
- A leave missed, with a re-admission on a newer ask after it in the base: the leave is
  dominated and M stays.
- A duplicate admission on the same ask: no presence stamp, so the leave applies.
- A backdated own-leave flood: the earliest leave inside the span applies and every later
  one is refused. Leaves before the span are refused outright.

## 7. Equivocation (F2)

Two different ops at one (author, clock) split replicas today, and the digest cannot see
it: dedup keys on (author, clock) at the door (`fold.rs` 206-211), and digest ids hash only
that pair (`digest.rs` 131, 215).

- **Fix.** The dedup map stores SHA-256 of the op's signed bytes. When an op arrives at a
  held key with a different hash, keep the lower hash, at the door and in `fold_in`'s
  `dedup_by`, and log the equivocation.
- **Digest.** The digest id becomes `hash(author, clock, content hash)`, so two replicas
  holding different ops at one key see a differing range and trade both.
- **Scope.** The lane fix for honest siblings (HOL-SEC-174) stays.

## 8. Bounds and fairness (F3, F8, F13)

| Table | Bound | Over it |
|---|---|---|
| Uncovered retained ops | Per server: 128 MiB, shared by max-min allocation over the whole uncovered set (a pure function of the set: each author gets min(its demand, a level chosen so the total fits)), with a floor of 128 ops / 128 KiB per author that always fits | an author over its share keeps its oldest ops by clock; the rest are PARKED (decision 7), never deleted, and judged again at every rebuild |
| The author's own refused ops | outbox on the author's device, 4,096 ops | offered again on every base change |
| `held` (256, 10 min) | only authors in `member_record` or named by a held or retained `MemberAdded` (F8: identities are free, so per-author fairness alone fails) | evicts from the author holding the most, never index 0 |
| Dormant set | one generation | rotated at the next base |
| `cp_late` | 64 per author, 8,192 in all | ops past it are not dormant: lost only on a rival switch |
| Rebuilds | late live ops of a server fold in one rebuild per 250 ms tick | `author_checked` and a join completion flush the pending batch first (F13) |

**As built (fix round).** The allocation is a pure function of the op set, kept in RAM so
a tail op gets the verdict a rebuild gives (the hysteresis of the first build split
replicas at the bound). Charge trees root in the anchor's members (the base, else the
founding owner); max-min with the floor over the trees, then max-min inside each tree
between a member's own ops and each subtree it admitted, so puppets split their
admitter's share. Within an author the oldest ops come first up to the first that does
not fit, so an author over its share stays over whatever it adds and costs no rebuild;
its tail op waits in `held` (256, ten minutes), never as a row. Staff admissions, lock
moves, kicks, bans, mutes and demotions come first up to 64 MiB, oldest first; the owner's
own ops are never charged. Parked rows are capped at 128 KiB per tree. Cost: while the
uncovered set is past the budget, a tail op of an author still under its share costs one
rebuild when it moves another author's share below what is folded.

**The staff budget with the owner away.** Measured from real signed ops (test
`three_months_of_an_honest_admin_fit_the_shipping_budget`): an admin answering every join
of a busy 512-identity server (60 admissions and 60 lock moves a day) writes 26.2 MiB of
staff-first ops in 90 days with 16 grants a lock move, 80.6 MiB with 64 (0.14 lock links
seal one grant per staff DEVICE and name the device that made the link). The 64 MiB staff
budget therefore lasts about 220 days, or about 71 at 64 grants a move, without a
checkpoint. Past it, staff acts count against the admin's own share like anyone's: joins
slow to the admin's fair share under a flood, never stop. The owner's next checkpoint
resets it. Accepted as the shipping number (Vitalik, 2026-11-05): 16 grants
fit the quarter, 64 grants fit two months, and the 64 MiB staff budget is not raised.

**Why the numbers.** The standing leader authors almost every admission and every
join-lock move, and a `JoinLock` op with up to 64 sealed grants weighs several KB.
Revision 1's fixed 4,096-op cap per author sat below its own honest leader load (F3b), so a
max-min share replaces it: the leader gets everything the budget has left. The floor times
the member cap stays at half the budget (512 x 128 KiB = 64 MiB of 128 MiB), so 500 puppets
at the floor still leave the leader 64 MiB. The build measures a real busy server before
fixing the floor and the budget: a fleet run of throwaway identities with joins, leaves and
moderation, plus the `SCALE_PROBE_2026_10` numbers.

What is lost at the bound: nothing for good. Parked ops stay stored and come back when a
checkpoint frees room. The author's outbox re-offers what other replicas parked or never
received.

## 9. Every path under the new rule (was Q3, F11)

- **Fold order** (`fold_order`, `fold_key`): founding op, then the base, then every other
  op by clock.
- **Prune** (`prune_before_checkpoint` becomes `prune_dominated`): the log keeps the
  founding op (identified as the founding op itself, not by a JSON `LIKE`, F11), the base,
  and what the base does not dominate. Dominated ops become dormant or are deleted.
- **`Ingested`** gains `dropped` (rows to delete: dominated and not dormant) and `parked`.
  The store applies both, so rows equal retained + dormant + parked + founding. Today a
  refused op's row stays and comes back on restart (confirmed by the review).
- **`persist_admitted_ops`**: one transaction: insert admitted, delete dropped, mark parked
  (a `parked_until` column, additive migration). The option A self-leave re-insert goes.
- **`restore_op_log`**: picks the base from the ROWS (the greatest checkpoint held), never
  from the state JSON, since the two are written by separate queued jobs (F11). Classifies
  every row against it, sorts in fold order, and compares the retained set with
  `retained_print` (saved in the state JSON). A mismatch refolds once and saves.
- **Digest** (`digest::entries`, `op_sync`): the compared set is retained + dormant + kept
  unread ops. `OpDigest.base` becomes the asker's base reference (author, clock).
  - The answerer filters by that checkpoint's dominance when it holds it (its base, its
    parent, or a dormant one), else not at all. An unneeded op costs bandwidth, never
    correctness.
  - Checkpoints count at fold ms 0. Ids include the content hash (F2).
  - `kept_checkpoint_covers` goes.
- **Paged whole-log fetch** (`crdt_resync`): `PageCursor` follows the new fold key. Pages
  hold retained and dormant ops; the asker ingests them through `ingest_remote`.
- **Join answer** (`swarm.rs` 11551-11563). Today it sends the whole log in one
  `SyncResponse`: a targeted `SendDirect` into the server room, which the relay buffers for
  an absent joiner (`join_lane.rs` 224-233). Unbounded. It becomes the founding op, the
  base, the joiner's own admission and the newest ops up to 256 KiB. The joiner's paced
  digest catch-up pulls the rest.
- **Join snapshot** (32-hex Legacy servers only): unchanged. It clears the stamps and
  checkpoint fields it cannot vouch for.
- **State vector** (`sync.rs`, 0.12.2 only, deleted by wave 2 track A): not built on.
- **`removal_notice` and `membership_end`** walk the log from the base, which sits first:
  unchanged.
- **`horizon()`** survives only as `cp_parent_horizon`. `checkpoint_due` reads the base's
  own clock.

## 10. A roster-removed device and the master key (new question)

**It is real, and it is not accepted.** AR-02 is marked CLOSED by design ID-1, and
HOL-SEC-050 lists "a stolen device still holds the master key" as a variant pointing at
AR-02. But ID-1 governs the roster, not server ops. The evidence:

- A `CrdtOp` carries only the master author and the master signature
  (`operations.rs` 61-71). Nothing names the device that minted it.
- Every ingest validates the author, never the carrier, by design. `apply_remote_crdt_op`
  logs a different carrier and goes on (`swarm.rs` 7676-7690);
  `handle_envelope_crdt_op` says so too (`sync_handler.rs` ~3990). `checkpoint_allowed`
  checks only that the author is the anchor owner (`server_state.rs` 2070).
- The removed device still holds the server's door secret (the join lock grants every
  member the door), so it can prove the door and sit in the server room.
- It reaches members three ways:
  - Over MLS, while its leaf is seated. Members that do not hold the owner's roster do not
    see the leaf as refused (`mls_authority::refused` reads the held roster).
  - Through the Olm-carried broadcast. A co-member that cannot place the device takes it
    as first contact (`crypto_handler.rs` 735-745).
  - Through any member that admitted its op: every digest and page answer re-serves ops by
    author alone (laundering).
- So a stolen owner laptop, after its removal, can still sign a `ServerCheckpoint` of any
  state with the highest generation, a `ServerDeleted`, kicks and role changes. Honest
  replicas admit them and serve them on.
- A harness probe is named for the build
  (`t14c_a_removed_owner_device_cannot_checkpoint_or_delete`); it was not run here (a full
  crate build).

**The fix: a device proof in every 0.14 op.**

- **The proof.** `CrdtOp.dev: Option<DevProof { device, sig }>`, `#[serde(default)]`. `sig`
  is the DEVICE key's signature over `hollow-crdt-dev1:` + the op's unchanged `hollow-crdt1`
  signing payload. The master signature stays as it is, so 0.13 still verifies 0.14 ops (it
  ignores the field). The device key derives from the id, so nothing else rides along.
  About 150 bytes per op.
- **Who it judges.** The proof proves which device minted the op. `op_allowed` judges it
  against the author's roster as held. A device the roster REMOVED cannot author:
  - a checkpoint, `ServerDeleted`, `JoinKeySet` or `JoinLock`, whatever its date;
  - any op dated at or after its removal's `at_ms`.
- **The bare master.** A proof whose device IS the bare master counts only where the held
  roster counts it (G1).
- **Laundering.** The device id is inside the op, so a replica holding the removal refuses
  the op whoever relays it.
- **Removed later.** Learning a removal triggers one rebuild. A checkpoint by a now-removed
  device then falls out of the base order, and the dormant set (section 5) makes the step
  back to its parent lossless.
- **Proof-less ops** (0.13 clients, or a thief stripping the proof):
  - before the server's first 0.14 checkpoint, judged as today;
  - after it, refused if dated after that checkpoint's clock, and dominated by its stamps
    if dated before.
  The owner's first 0.14 start writes that checkpoint (`checkpoint_due` is true on a
  generation-0 base), so the cut is a protocol event, not an author-chosen date.
- **Consensus with rosters.** The verdict reads the held roster, so two replicas agree once
  they hold the same ops AND the same removal for that author. A replica that lacks the
  roster of an author whose ops it holds asks the relay for that identity's roster fold
  (the ID-1R record, as AR-15's meeting fix proposes). It also takes it from any
  `RosterNotice` the identity's devices send to their servers after a removal: each removal
  shown in the server room once, the remover's own devices included. Until then it may
  admit the removed device's op. Its digest then differs, and when the removal arrives the
  rebuild refuses the op.
- **Residuals.**
  - A removed device can still backdate ordinary ops before its removal time, as any
    honest device could. They are judged by today's authority, dominated by the base where
    the base already decided them, and bounded by the quotas.
  - A replica with no route to the author's roster judges by the master key alone until it
    learns the removal.
- **The deterministic alternative, not picked.** Carry each identity's roster statements
  into the server's own log and fold them there. Today's roster fold reads first-sight
  times and the wall clock (`Roster::fold(first_seen, now_ms)`, 7 quiet days), so it is not
  a pure function of the statements. Making it one is a change to design ID-1.

Cost: about 2.5 builder-days. Mint and verify the proof, the `op_allowed` arm, the
proof-less cut, the relay roster ask for unknown authors, the `RosterNotice` into server
rooms, the rebuild on a removal, and tests. Proof verification adds one Ed25519 verify per
op (batched verify available).

## 11. Owner offline for months

Nothing waits for a checkpoint. Joins are answered by members by standing; leaves land on
any member; admins' role changes fold everywhere; catch-up is the digest. What grows is the
retained log.

**Estimates.** For a busy 512-identity server: 50 to 200 CRDT ops a day, mostly authored by
the standing leader (admissions, join-lock moves), 0.5 to 4 KB each. Over 3 months: 4,500 to
18,000 ops, 3 to 50 MB. The build measures the real numbers (section 8).

| Cost | With the owner away 3 months |
|---|---|
| Log in RAM and `crdt_ops` | the ops above plus the base (about 0.85 MB with stamps, section 15) |
| A new joiner's first sync | the paged join answer (256 KiB) at once, then the rest by paced digest catch-up |
| A returning device | about log2(ops) ranges per ask, then only what it lacks |
| A restart | load and sort the rows, compare the fingerprint, no refold unless it differs |
| A late op | one rebuild per tick |

**Bounds.** Hostile growth is bounded per server by section 8 whether or not the owner is
online. Honest growth is a few tens of MB at most, so owner-only compaction keeps a
months-offline server healthy (decision 2). Options on file, not picked:

- **B. Attested member compaction:** a quorum of members could lie to a joiner. That is an
  authority change.
- **C. Admin compaction by delegation:** an authority change.
- **D. Cleanup of superseded inert writes:** a follow-up if real logs need it.

## 12. Migration and mixed servers (was Q5, F7)

- **A 0.13 log loads.** A persisted scalar `checkpoint_hlc` becomes a generation-0 base. Its
  scalar `covers` dominates every op at or below it (exactly 0.13's rule). A replayed 0.13
  checkpoint is below the base and refused. The stamps of a 0.13 state are missing, so they
  are seeded from the scalar: every element of a generation-0 base reads its stamp as
  `covers`. This is the 0.13 rule, applied once.
- **The owner's first 0.14 start** writes a generation-1 checkpoint with real stamps, which
  also starts the proof-less cut (section 10).
- **A 0.13 replica** verifies 0.14 ops (master signature unchanged) and reads 0.14
  checkpoints as ordinary ones. Their `covers` sits just above the parent's, so it prunes
  little. It may misfold some re-admissions, having no stamps.
- **What really happens in a mixed server.** MLS judges membership from the CRDT: `GroupRules`
  holds non-members, and `removable` lets a commit remove a non-member's leaf
  (`mls_authority.rs` 21-34, 53-59).
  - Before the owner runs 0.14, both versions take each other's ops.
  - Once the owner's first 0.14 checkpoint lands, 0.14 replicas refuse a 0.13 member's
    later ops. A 0.13 standing leader keeps admitting joiners that 0.14 refuses. Its MLS
    commits add their leaves; 0.14 committers remove them as non-members; the 0.13
    committer adds them again. Epochs churn and those joiners flicker in and out for 0.14
    members.
  - A 0.13 owner's kicks and role changes keep working only while the owner itself is on
    0.13 (no 0.14 base exists yet).
- **Mitigations.**
  - **The RED critical status notice** at release (decided). It needs the `sepia` pass.
  - **No 0.13 leaders for 0.14 members.** 0.14 standing never elects a device whose tally
    lacks the 0.14 mark, so 0.14 members never wait on a 0.13 leader.
  - **The in-app hint.** A 0.14 device that refuses a member's op for missing its proof
    shows that member as "using an old version of Hollow". This is new copy and needs
    `sepia`.
- **Option A data.** `late_leaves` in a persisted state is ignored (unknown field). Its
  leaves are ordinary rows.

## 13. Every site that changes (was Q6)

Swept with Grep over the worktree and LSP `findReferences` on the main tree's
`checkpoint_hlc` (26 refs, 7 files) and `horizon` (10 refs, 6 files). LSP does not index the
worktree, so Grep is the floor there.

| Site | What changes |
|---|---|
| `crdt/fold.rs`: `checkpoint_due`, `horizon`, `checkpoint_json`, `accept_join_snapshot`, `ingest_remote`, `fold_remote`, `fold_in`, `hold`, `refold_for_standing` (0.13 one-shot, delete), tests | dominance, base order, dormant, quotas, held, coalescing |
| `crdt/server_state.rs`: fields `checkpoint_hlc`, `late_leaves`, the stamps; `lean_snapshot`, `skeleton`, `clamp_future_hlcs`, `rebase_on`, `reset_materialized` (exhaustive destructures), `restore_op_log`, `close_late_leaves`, `leave_outlives_checkpoint`, `retains`, `log_admitted`, `prune_before_checkpoint`, every `apply_payload` arm, `op_allowed` (member at its clock, F9, device proof), `checkpoint_allowed`, `fold_order`, `retained_under`, `fold_key`, `open_span`, `close_span`, `note_admitter` | the core |
| new `crdt/dominance.rs` | the exhaustive match |
| `crdt/operations.rs`: `CrdtOp` (`dev`), `read_op` | device proof |
| `crdt/lock_state.rs`: `link_allowed`, `apply` (grants by clock), `note_removal` | join lock |
| `crdt/digest.rs`: `entries`, `id_hash` (content hash), `kept_checkpoint_covers`, `OpDigest.base`; `digest/tests.rs` | digest |
| `crdt/sync.rs`: `membership_end`, `decides_rank`, `removal_notice` | read the base first |
| `storage/messages.rs`: `persist_admitted_ops` (transaction, dropped, parked, founding key), schema; test `a_checkpoint_batch_keeps_the_late_leave_it_carries` | store |
| `node/crdt_store.rs`: `PersistAdmitted` | carries dropped and parked |
| `node/sync_handler.rs`: `author_due_checkpoints` (~293-319, writer rule a), persist (~3998), `ServerUpdated` match (~4075), `create_op` callers (device proof) | writer rule, persist |
| `node/swarm.rs`: start restore (~1050), persist sites (~7466, ~7692, ~10726), `apply_remote_crdt_op`, join answer (~11551) | restore, the paged answer |
| `node/op_sync.rs` (~235, ~309), `node/crdt_resync.rs` (`PageCursor::of` ~117, `load` ~261, `serve`, kept filter) | base reference, fold key |
| `node/standing.rs` (0.14 tally mark), `node/roster_book.rs` (`RosterNotice` into server rooms, relay roster ask), the pending-join path (silent re-ask) | sections 6, 10, 12 |
| `node/leave_book.rs`, `join_hold` | no dependency on `covers`; unchanged |
| `node/test_harness.rs` ~41473, ~59005-59061 | checkpoint helper |
| wiki `security_write_gates.md` §17, §54 and a new row for the device proof; `rust_crdt.md` | rewritten |

## 14. Test plan (was Q7)

Unit (fold, dominance, server state, digest, storage). Each fails on today's code, or on its
named mutation:

| Id | Test | Proves |
|---|---|---|
| U1 | `dominance_is_exhaustive_and_exact` (one case per payload: dominated, not dominated, span window) | the match |
| U2 | `a_checkpoint_never_drops_an_op_its_owner_did_not_fold` (own leave, rejoin, member-admitted join, admin role change, moderator ban, channel rename, owner sibling's op) | each survives before, after and on the owner |
| U3 | `uncovered_ops_fold_the_same_in_every_order` (permutations of leave, rejoin, ban, covered unban, re-admission on the same and a newer ask) | order and batching |
| U4 | `a_restart_through_the_store_matches_a_live_replica` (JSON from `lean_snapshot`, rows from an in-memory store in clock order, base taken from the rows, stale fingerprint refolds) | restart |
| U5 | `a_stale_checkpoint_undoes_nothing_members_did` | stale owner |
| U6 | `junk_below_a_checkpoint_stays_bounded` (strangers, non-members, a backdated own-leave flood) | bounds, `dropped` |
| U7 | `a_dominated_replay_is_dropped_without_a_rebuild` | cost |
| U8 | `rival_owner_checkpoints_converge_without_loss` (three owner devices, every order, replicas on different paths; the review's F4 path C1 -> C2a -> C2b vs C1 -> C2b then C2c) | base order, dormant |
| U9 | `nothing_a_member_sends_makes_the_base_drop_another_authors_op` | authority |
| U10 | `rebase_equals_a_clone_and_apply_oracle` (property: random op sets over EVERY payload kind, random owner-seen subsets, random checkpoint points; the oracle folds the full history; equal on every field for op sets where no authority changes; a source scan proves every `CrdtPayload` variant is generated) | the stamps, the lost safety net |
| U11 | `a_late_op_is_judged_by_todays_authority` (since-demoted admin, kicked member's backdated puppet: the review probe, author not yet a member, HOL-SEC-092, HOL-SEC-093, F9 probe) | decision 3, F9 |
| U12 | `equivocation_keeps_the_lowest_hash_everywhere` (the review probe; door, `fold_in`, digest) | F2 |
| U13 | `quota_shares_are_order_independent_and_park_never_delete` (backdated flood, 500 puppets at the floor, an honest leader at measured load, outbox re-offer on a base change) | F3 |
| U14 | `held_admits_only_known_authors_and_evicts_the_heaviest` (the review probe) | F8 |
| U15 | `a_removed_device_cannot_checkpoint_delete_or_write_after_its_removal` (laundered through another carrier, bare master, proof stripped after the first 0.14 base, removal learned late) | section 10 |
| U16 | `a_0_13_log_and_checkpoint_load_and_seed_stamps` | migration |
| U17 | `a_checkpoint_of_512_identities_stays_small` | size |
| U18 | `persist_is_one_transaction_and_keys_the_founding_op` (a channel named "ServerCreated" is pruned) plus a schema migration on a copy of a 0.13 DB | F11 |
| U19 | `digest_entries_agree_across_bases_and_include_the_dormant_set` | digest |
| U20 | `coalesced_rebuilds_flush_before_authoring_and_join_completion` | F13 |
| U21 | `member_at_its_clock_spares_legacy_and_unrecorded_authors` | F12 |

Harness, at the end of `test_harness.rs` under `// t14-cover`:

- H1 `t14c_owner_away_members_admit_and_promote_then_a_stale_checkpoint_keeps_all`
- H2 `t14c_a_late_leave_behind_the_checkpoint_lands_and_survives_a_restart` (replaces
  `a_leave_landing_behind_the_owners_checkpoint_still_closes_the_span`)
- H3 `t14c_a_rejoin_the_checkpoint_never_saw_stays_a_member`
- H4 `t14c_two_owner_devices_checkpoint_at_once_and_nothing_is_lost`
- H5 `t14c_months_without_the_owner` (log past 2,000 ops: joins, leaves, role changes, a
  returning device, a new joiner; the join answer size asserted)
- H6 `t14c_a_members_backdated_flood_hurts_only_itself`
- H7 `t14c_the_f1_cascade_heals_by_silent_re_asks` (B admits C, C admits D, the owner's
  checkpoint misses the admission; C and D are members again with no prompt and no owner)
- H8 `t14c_a_removed_owner_device_cannot_checkpoint_or_delete` (stolen owner laptop
  removed by a sibling; its checkpoint, deletion and kick relayed through a co-member that
  never held the roster)

Mutation targets, each in every layer that enforces it:

- each dominance arm (one mutant per row of section 4);
- the base order key;
- the dormant rule (`cp_parent_horizon`, `cp_late`);
- member at its clock;
- F9;
- the equivocation tie-break (door, `fold_in`, digest);
- the max-min share and the floor;
- park instead of delete;
- the outbox re-offer;
- `held`'s known-author rule and eviction;
- the restore base-from-rows and fingerprint;
- the store transaction and the founding key;
- the digest base filter;
- the device proof (verify, removed device, after-removal date, bare master, the
  proof-less cut);
- writer rule (a);
- the silent re-ask trigger (must not fire after a real removal).

## 15. Size and cost

A 512-identity server with about 2.5 devices each, estimated from today's JSON. The parts:
members 80 KB, roles 95 KB, spans 230 KB, pledges and nicknames 120 KB, channels and the join
lock 40 KB. That is about 0.55 MB today. The stamps add about 200 KB (presence, display name
and per-field clocks) and `cp_late` up to 130 KB under attack: about 0.85 MB in all. U17
asserts the real number.

Per op: one dominance match (a few map lookups), the quota tallies, one device-proof verify.
Rebuilds stay one per batch or tick. Nothing scans per op.

## 16. Risks and residuals

- **A stamp missed on one element.** An older late op undoes a newer write there. Guarded by
  U10's oracle over every payload kind, the exhaustive match, and a source scan.
- **Decision 3 can undo honest acts** whose authority a covered later op removed. This is
  mitigated by writer rule (a) and the silent re-ask (c). A ban of a target promoted later
  stays undone.
- **A fork two generations deep** (section 5).
- **A removed device's backdated pre-removal ops**, and replicas without a route to the
  author's roster (section 10).
- **0.13 members of a 0.14 server** (section 12).
- **Withheld ops (L2)** are unchanged, and narrowed for checkpoints by writer rule (a).
- **Bigger checkpoints**, about 55% larger.
- **A checkpoint past its byte bound.** A server that keeps its records of about 15,000
  departed identities (or about 40,000 bans) next to 512 members reaches 16 MiB. Its owner
  then tries once an hour and signs nothing; the log grows without compaction and the
  quota decides what folds. A later release can compact departed records once their late
  ops are judged some other way.

## 17. Build plan and estimate

About 10 to 12 builder-days, two `builder-secure` tracks in parallel, then one:

1. **Track A (5 days):**
   - base order, dormant set and checkpoint fields;
   - dominance at the door, prune, `dropped` and `parked`;
   - store transaction, restore from rows and fingerprint;
   - digest (base reference, content-hash ids) and `crdt_resync`;
   - equivocation;
   - the paged join answer;
   - migration and stamp seeding;
   - option A deletion;
   - writer rule (a).

   Owns `fold.rs`, `digest.rs`, storage and node.
2. **Track B (3 to 4 days):**
   - the stamps and tombstones;
   - the exhaustive dominance match;
   - every section 4 arm, the join lock included;
   - member at its clock;
   - F9;
   - the U10 oracle.

   Owns `apply_payload`, the state fields, `dominance.rs` and `lock_state.rs`. It is
   invisible on in-order folds, so it merges on its own.
3. **Then (3 days):**
   - the device proof and removed-device rules (section 10, about 2.5 days, of which the
     roster plumbing is half);
   - quotas with the max-min share, the outbox and `held`;
   - the silent re-ask;
   - coalescing;
   - the harness block, the mutation pass, the PC suite and the wiki rows.

A hostile code review follows each track, with one fix round.
