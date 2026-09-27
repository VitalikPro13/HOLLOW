# Design D: MLS leaf identity and group authority

Session 8 (2026-09-27, xhigh). Closes candidate class D (lead L-03): D1, D2, D3, D4,
D5, D6, D9, D10, and the relay halves of D7 and HOL-SEC-017. D8 reduces to E7
(class E). Evidence: `phase_b_evidence/authz_server_mls.md` (S-03, S-09, S-12..S-25,
S-27, S-28).

## The problem in one paragraph

An MLS leaf credential is a bare string the leaf's owner chose, signed by a random
MLS key that nothing ties to a Hollow key. Every envelope decrypted from a group is
attributed to that string. No one checks who a commit adds or removes, a Welcome
from anyone replaces a live group before it is even parsed, and three garbage frames
make a member drop its group. So the relay can seat itself in any group by speaking
for a member, a member can seat a leaf in the owner's name, and anyone in the room
can knock a member out of its group at will.

## Principles

1. A leaf proves who it is. Its credential is checked by every receiver from the
   leaf alone, with no lookup that can be missing or stale.
2. Group state changes only on an authenticated MLS event that passes Hollow's own
   rules: a commit we accept, a Welcome we accept, or our own CRDT state (leave,
   kick, delete, lost eligibility). A frame that fails never changes anything.
3. The committer's own checks mirror the receiver's, so an honest coordinator never
   builds a commit that honest members refuse.
4. When our CRDT view might just be behind, a refusal waits and pulls ops instead of
   failing for good; when a rule is broken outright, the frame is dropped.

## 1. Leaf identity (D1, D6, D7, D10)

- The MLS signing key of a device IS its Ed25519 device key. A peer id is the
  device's public key in encoded form, so the leaf's `signature_key` must decode
  from the device id it names. The relay cannot produce a leaf for any device
  whose key it does not hold.
- The credential carries a master certificate:
  `hl1:{device}:{master}:{sig}` where `sig` is the master key's signature over
  `hollow-mls-leaf:{master}:{device}`. Every device holds the master key, so each
  device mints its own. The master's public key decodes from its id the same way.
- A leaf is BOUND when the device id matches its signature key and the certificate
  verifies. It then yields a proven `(device, master)`. Anything else (every leaf
  minted before 0.12) is UNBOUND. A device whose id is its master's (an old install
  that never rotated) is simply its own master.
- Leaf ids stay device ids everywhere (`group_members`), so routing is unchanged.
  Every membership or channel-qualification decision (stale sweep, subgroup
  reconcile, the KeyPackage arm, commit and Welcome rules, subgroup membership)
  uses the proven master instead of `resolver::resolve`. This also makes those
  decisions testable in the harness (the resolver is process-global there).
- Cross-protocol check: every Hollow device and master signature is over an ASCII
  string starting `hollow-`; an MLS signature is over `SignContent`, which starts
  with a length byte below 0x40. Neither can be passed off as the other.

## 2. Existing leaves (the switch to bound leaves)

0.12 is a breaking release (decision 1), so old clients drop out anyway. Groups are
kept, not re-formed.

- From the first start on 0.12 our MLS signer is the device key and new
  KeyPackages and groups are bound. The previous random signer is kept as a
  LEGACY signer, persisted, used for exactly one thing: the commit that rebinds our
  own leaf in place.
- While our own leaf in a group is unbound we neither encrypt nor commit in it.
  Sends fall back to Olm exactly as for a member with no group.
- Each batch tick, for every group where our leaf is unbound: if we are the group
  authority we rebind in place (one self-update commit to the device key and the
  bound credential, broadcast and cached for catch-up); otherwise we send a fresh
  KeyPackage to the authority, which repairs our leaf in one commit.
- Receivers ignore application messages from unbound leaves (they are not decrypt
  failures). A coordinator's stale sweep removes unbound leaves of members who
  never come back.
- Once no group holds our legacy leaf, the legacy signer is deleted.
- An imported sibling DB is still detected as foreign and discarded at startup, as
  today (a certificate naming another device counts as foreign too).

## 3. Commit rules (D2, D6)

Every commit, live or catch-up, is staged, judged, then merged or discarded. Hollow
never sends standalone proposals, so a commit may carry only the committer's own
Add and Remove proposals and its update path.

Refused outright (discarded):
- H1 the sender is not a member leaf (external or new-member commit);
- H2 any proposal other than Add or Remove;
- H3 an added leaf or the committer's new path leaf is unbound;
- H4 the path leaf changes identity. A bound committer keeps its device and master.
  An unbound committer may only REBIND: its path leaf proves the device or master
  its old credential named, and the commit carries no proposals;
- H5 any other commit from an unbound committer;
- H6 an added device we know is revoked;
- in a meeting (`conf:`), a committer other than the identity that admitted us.

Held, not refused, while our CRDT may be behind (kept 60 s, the committer's op log
pulled once, retried every batch tick):
- S1 the committer's master is not a current member, or is banned (subgroup: cannot
  see the channel);
- S2 an added master is not a current member, or is banned (subgroup: cannot see
  the channel);
- S3 a removed leaf is not removable. Removable means one of: (a) the committer's
  own master, (b) unbound, (c) its master is no longer a member, is banned, or
  (subgroup) cannot see the channel, (d) its device is revoked, (e) the same commit
  adds a bound leaf for the same device (a repair).

Committer side: the batch timer builds ONE commit per group per tick holding every
removal and every add (OpenMLS allows a remove and an add of the same key in one
commit). A current member's leaf is removed only as part of a repair, when that
device's fresh KeyPackage is in the same commit. The epoch-hint fallback and the
escalated SFrame heal stop queueing bare removals; they ask for a KeyPackage and
the repair happens when it arrives. Kick, ban, leave, revocation and the stale
sweep keep committing plain removals (rules a, c, d). The coordinator filters its
queue with the same rules before it commits. A join or a repair now costs one epoch
(it could cost two).

## 4. Welcome rules (D3)

- A Welcome is staged first (OpenMLS `JoinBuilder::replace_old_group`), so nothing
  replaces our group until it has passed.
- Refused outright: the group id is not the key it was addressed to; any leaf is
  unbound; our own leaf is not our device; a leaf of a revoked device; a Welcome
  that would REPLACE a group we hold without our having asked for one (a
  KeyPackage we sent for that group key within the bootstrap window, the eviction
  grace, or an answered KeyPackage request).
- Held up to 60 s and retried each tick: the sender's master is not a current
  member or is banned (subgroup: cannot see the channel); a leaf of a banned master.
- A meeting Welcome needs a pending knock for that meeting; its sender becomes the
  meeting's authority for later commits (above). Pinning the host from the invite
  itself belongs to class A (A15/A16).

## 5. Failures never drop a group (D4)

- A decrypt failure never drops a group. A frame that does not parse, names another
  group, fails its signature, or comes from an unbound leaf is ignored outright.
  Anything else (wrong epoch, cannot decrypt) keeps today's message and op sync
  requests and sends a throttled epoch probe.
- A commit that fails to process never drops a group either; it probes.
- Probes carry a short digest of our epoch authenticator. An authority at the same
  epoch whose digest differs treats the prober as forked and asks it for a
  KeyPackage, so the repair and its Welcome bring it back. A forged probe can only
  cost its target one repair (a relay-level nuisance that class A closes by
  signing probes).
- The escalated SFrame heal on a non-authority keeps its group and sends its
  KeyPackage instead of dropping first.

## 6. KeyPackage requests (D5)

Answered only when we are a member of the server (not while our own join is
pending), the requester's device belongs to a current member (proven by its leaf in
our copy of the group, else by our device lists), we qualify for a requested
subgroup, and we have not answered for that group in the last 10 s. Never for a
meeting. Answering counts as asking, so the Welcome that follows is accepted.

## 7. Voice frames over MLS (D9)

`VoiceChannel*` envelopes decrypted from a group are dropped unless the leaf's
device is the relay-stamped sender they are attributed to.

## 8. Left for other classes

- Plaintext `ServerDeleteBroadcast` / `MemberKickBroadcast` (S-08, S-11), forged
  join resolutions (S-05..S-07), unsigned probes (S-20), meeting lobby and host
  frames (S-26, S-29..S-32): class A (device-signed or moved into Olm/MLS).
- Who may admit a member at all (`MemberAdded` authority, E7) and the joiner's
  starting state (E1/E2): class E. MLS follows the CRDT membership it is given.
- A stolen device minting certificates for new device ids of the same master: ID-1.

## 9. Tests (harness first; each fails with its old rule put back)

- mls_manager units: bound credential round trip; a forged certificate, a leaf key
  that is not the device key and a legacy credential all read as unbound; rebind of
  a legacy leaf in place; one commit that repairs a leaf.
- `commit_verdict` matrix (pure function, every H and S row).
- Harness, with a hostile member that holds real keys (its MLS state loaded from
  its own DB): `authz_member_cannot_seat_a_leaf_in_another_name`,
  `authz_commit_adding_an_outsider_or_evicting_a_member_is_refused`,
  `authz_welcome_never_replaces_a_group_unasked`,
  `authz_garbage_mls_frames_never_drop_a_group`,
  `authz_key_package_request_needs_a_member`,
  `authz_voice_frames_over_mls_come_from_their_leaf`,
  `same_epoch_fork_heals_through_the_probe`.
- Existing MLS harness tests keep passing, with epoch expectations lowered where a
  repair now costs one epoch.
