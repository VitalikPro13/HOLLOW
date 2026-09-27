# Design E: CRDT state authority

Session 9 (2026-09-27, xhigh). Closes candidate class E: E1, E2, E3, E4, E5, E6, E7,
E8, E9, E11, E12, E15 (E10, E13, E14 were fixed in session 6). Evidence:
`phase_b_evidence/authz_crdt.md` (CRDT-S1, S2, S5..S10, S12, S13, S18). CRDT-S3, S4,
S15 and S17 are class A (A2, A3, A10, A5) and wait for that design.

## The problem in one paragraph

A server's state is whatever order its ops happened to arrive in, each op judged
against whatever state the receiver held at that moment, and the op log keeps only the
newest 1000. So the relay picks outcomes by reordering frames (E5), replays an old op
once it has left the window and brings removed state back (E3, E15), and replicas that
saw the same ops can admit different ones. A joiner has no anchor at all: it adopts the
state the first answerer hands it, owner included (E1), or takes the first founding op
it sees (E2). Authority rules have holes of their own: strangers author ops (E6), any
member adds anyone past every join gate (E7), a device id stands in for its master
(E8, E9), moderation edges skip rank (E11), and ownership can be minted, dropped or
reset (E12). Nothing records who was ever a member, so backfill cannot refuse posts
signed by a never-member (E4).

## Decisions (Vitalik, 2026-09-27)

1. The owner is fixed for the life of the server. Nobody demotes, kicks, bans, mutes or
   renames the owner, nobody is made owner, and moderation edits (nickname, Twitch name,
   pledge, unmute) reach only lower ranks. A transfer, if it ever comes, is its own
   signed op.
2. Existing servers keep joining while their owner has not run 0.12: the joiner trusts
   the member that answers, as today. Once the owner's checkpoint lands, everyone
   rebuilds on it.
3. Invite links to existing servers carry the owner's id (`owner=`). Old links keep
   working with the weaker trust.
4. Any member may still admit a joiner (owner-offline joins keep working), and every
   member re-checks the join gates on the `MemberAdded` op itself.

## Principles

1. A server's state is a pure function of the set of signed ops it holds: the ops are
   folded in HLC order and each is judged against the state just before it. Arrival
   order, the relay's timing and the answering member change nothing.
2. The fold starts from an anchor the joiner can prove without trusting whoever
   answered: the founding op of a self-certifying id, or a checkpoint signed by the
   pinned owner.
3. Authority comes from the signing key and the fold, never from the process-global
   resolver, and a signature proves who, never may.
4. The same predicate gates authoring and ingest, so an honest client never authors an
   op honest peers refuse.

## 1. Anchors: who owns a server, provably

- **New servers (0.12+)** get a self-certifying id: the first 40 hex characters of
  `SHA-256("hollow-server1:{owner}:{nonce}")`, with a 16-byte random nonce that rides
  the founding `ServerCreated` op (new field, absent = not self-certifying). A 40-hex id
  can only be founded by the key that hashes to it. Its length tells a joiner which rule
  applies, so a hostile answerer cannot downgrade it by leaving the founding op out.
  Existing ids are 32 hex characters and random.
- **Existing servers** have no founding op a joiner can trust (their history predates
  op signing, which landed 2026-09-03, and was capped at 1000). The owner's 0.12 client
  signs a **checkpoint**: a `ServerCheckpoint` op carrying the full state. Every member
  who receives it rebases onto it (see 3). New invite links for a 32-hex id carry
  `owner=<master>`; a joiner with that pin accepts only a checkpoint and a snapshot
  whose owner is the pin. Old links and a server whose owner has not updated stay
  trust-on-first-use (residual R1).
- The anchor owner is recorded on the state (`owner_pin`): the pin from the link, the
  founder of a 40-hex id, or the owner of the first checkpoint or snapshot a joiner
  accepted. Owner fixed (decision 1) means it never changes afterwards.

## 2. The fold

- **Retained history.** Ops are no longer capped for anchored servers: the op log holds
  every admitted op since the anchor (the founding op of a 40-hex id is kept forever,
  since it is the proof). The DB keeps them all; rows older than the latest checkpoint
  are pruned when it lands. Legacy-anchored servers keep today's 1000 cap until their
  checkpoint arrives.
- **Ingest.** Every remote op passes the stateless checks (server id, author signature,
  clock bound) and dedup. Then:
  - newer than the log's tail: judged against the current state and applied at the tail
    (the common live case, same cost as today);
  - older than the tail, or several out of order in one batch: inserted and the state
    is REBUILT, folding every retained op in HLC order from the anchor.
  Ops refused only for authority wait in a small held pool (256 per server, 10 minutes)
  and are re-judged at the next rebuild, so an op that raced ahead of the role grant or
  `MemberAdded` it depends on still lands. A rebuild emits `ServerUpdated`.
- **What this closes.** Plain assignments become last-writer-wins by HLC for free
  (E5). An old op already in the log is a duplicate, and one older than the anchor
  folds before a checkpoint that overwrites it (E3, E15). Two replicas holding the
  same ops hold the same state.
- **Legacy mode** (32-hex id, no checkpoint yet) keeps incremental apply, now with the
  author and target rules of section 4 and the held pool, so it is no worse than today
  while it lasts.

## 3. Checkpoints

- `ServerCheckpoint { state, covers }`: the owner's full materialized state as JSON
  (the op log, clock and signer excluded), signed like any op. `covers` is the newest
  clock that state reflects (its log's tail, or a later register stamp). Admitted only
  from the anchor owner, only if it parses as this server, names that owner as its
  only Owner, is not deleted, covers no later than its own clock, and covers more
  than the current checkpoint.
- The fold places it at `covers`, not at its own clock, and applying it REPLACES the
  materialized state: every op up to `covers` is overwritten (late arrivals
  included), every op after it folds on top. So an owner back from days away signs
  its old view, and what members did meanwhile survives. Accepted cost: an op older
  than `covers` that the owner had not seen is lost everywhere (deterministic, rare).
- The owner's client writes one when a server it owns is still legacy (the migration,
  once, at start), and when an anchored log grows past 2000 ops (compaction), at most
  once an hour per server.
- The first checkpoint of an existing server seeds the membership record (5).

## 4. Author and target rules (one predicate, `op_allowed`)

- **E6** every op needs an author who is a current member (by its own id), except the
  founding op and a checkpoint, which have rules of their own.
- **E9** author authority is read by the author's own id, never through the resolver.
  Every client since op signing signs with the master key; a device key has no role.
- **E7** `MemberAdded` (any member may author it, decision 4) is refused when the target
  is banned, the server is private, the member cap is reached, owner-verify is on and
  the author is not the owner, or Twitch gating is on and the op does not carry a
  follow credential that verifies for the target at the op's own time. The admitter
  copies the joiner's credential into the op (`follow`, new field).
- **E11** unban needs the banner's rank or more (the ban register keeps it); unmute
  needs to outrank the target and the muter's rank; nickname, Twitch name and pledge
  of others need Owner or Admin AND outranking the target; `RolePermissionsChanged`
  takes only admin, moderator or member and grants only bits the author holds.
- **E12** nobody becomes Owner through `RoleChanged`; nothing demotes, removes, kicks,
  bans, mutes or edits the Owner; a founding op lands only on an ownerless state and
  only for the anchor (the hash for 40-hex, the pin for 32-hex).
- **Authoring** goes through the same predicate: `author_op` builds the op and refuses
  it when `op_allowed` does, before anything is applied or sent.
- **E8** anchored servers never run `canonicalize_members` (their ops are master-keyed
  from the start, and a device-keyed register is simply never read). On legacy servers
  the fold of device-keyed registers only ADOPTS: a role, ban or mute register never
  overwrites the master's, never lands on the Owner, and a ban or mute never lands on a
  Moderator or above.

## 5. Membership record (E4)

- `member_record`: per master, the time spans it was a member, opened by `MemberAdded`
  (and the founding op) and closed by `MemberRemoved`/`MemberBanned`, kept in the
  materialized state and carried by every checkpoint.
- An existing server's first checkpoint seeds it from the owner's own knowledge:
  current members from the start of time, and every author of a channel post the
  owner's database holds, as a former member up to the checkpoint (the owner vouches
  for history it has).
- Channel backfill then refuses an item whose author (master) was not a member at the
  item's time, 10 minutes of slack each side. Legacy-anchored servers skip the check
  until their checkpoint (the record would be empty).

## 6. Joins

- The joiner's pending join carries the invite pin. A 40-hex id ignores snapshots and
  builds from the ops alone; its join completes only when its own `MemberAdded` is
  admitted in the fold. A 32-hex id adopts a snapshot only if its owner is the pin
  (when there is one), and rebases onto a checkpoint the moment the ops carry one.
- The admitter sends a snapshot only for a legacy-anchored server.

## Tests (each must fail with the old rule put back)

- Unit (crdt): order independence of the fold across shuffled deliveries; replay of an
  old op past 1000 later ops; founding op only for the hashing key; checkpoint only
  from the anchor owner, and ops before it ignored; the E6/E7/E9/E11/E12 matrix;
  canonicalization never demotes, bans or mutes the Owner or a Moderator+.
- Harness (hostile member loaded with real keys): a joiner of a 40-hex server handed a
  forged snapshot and a forged founding op ends with the real owner; a joiner with a
  pin refuses a checkpoint by anyone else; a hostile member's `MemberAdded` of a banned
  identity, and into a private server, is refused by every other member; backfill of a
  never-member's post is refused while a former member's lands.

## Residuals

- R1: a 32-hex server whose owner never runs 0.12, or a join through an old link without
  `owner=`, stays trust-on-first-use (accepted-risk proposal).
- R2: a demoted or removed admin can still backdate ops to before its demotion; the fold
  admits them at that time. No decentralized design without a total order from an
  authority prevents it. Bounded: such ops lose every register a later honest write
  touched. (Accepted-risk proposal.)
- R3: an op older than a checkpoint's `covers` that its owner had not seen is lost
  everywhere.
- R4 (cost, not safety): every op older than the log's tail rebuilds the state, so a
  member flooding backdated ops costs every member CPU per op. The owner's compaction
  checkpoints bound the log; it belongs with AR-01's flood measurement in phase G.
