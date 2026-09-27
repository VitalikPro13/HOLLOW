# Phase B candidate findings

Every suspicion the nine enumeration passes raised (2026-09-26), grouped by root
cause so one fix can kill a class. Raw evidence with file:line and quotes:
`phase_b_evidence/authz_<area>.md` (suspicion ids below are `<area>:<id>` from
those files). Line numbers there are HEAD `b009e9a0`, some shifted by the
HOL-SEC-003 working tree; every citation carries a quote to re-find it.

**Status legend.** `FIXED` = finding file, failing test, fix, test passes.
`CONFIRMED` = I read every cited line myself. `AGENT` = the enumerating agent
reports CONFIRMED-BY-READING, not yet re-read by me (it does not count until I
have). `PLAUSIBLE` = the agent could not follow it to the end. `KNOWN` = already
decided (accepted risk or design ID-1).

Severity is provisional (Impact x Exploitability, plan section 2.7) and is
settled in each finding file.

**Decisions taken by Vitalik (2026-09-26):**
1. Class A: EVERY state-changing plaintext message is secured, as a breaking
   change (old clients cannot connect to new ones). Where a session exists the
   message moves into Olm/MLS; what must stay plaintext (friend requests to
   strangers, join requests, public posts) is device-signed.
2. Class C3: backfill is accepted only from a CURRENT member who can read that
   channel. Rows written by former members while they were members stay; rows
   whose author was never a member are refused. (Serving already refuses
   non-members, verified.)
3. Class F: device co-signatures on device-list entries are the real fix for
   HOL-SEC-006 and squatting (F6), designed as part of ID-1.
4. Relay fixes (class I) deploy to the official relay BEFORE the 0.12 client
   release; the pre-auth crash (I1) first.
5. `hollow_push_decrypt` (O4): delete it.

**Decided 2026-09-26 (session 3):**
2b. (2026-09-27, session 5) C7: a post dated more than 10 minutes ahead of our clock is
   refused on every path; slow mode judges fresh posts by our own receive clock and
   older replays (relay ring, sync) by their timestamp.

2c. (2026-09-27, session 5) E10: `retention_files` takes only the values the app
   offers (30d, 90d, 180d, 365d, permanent), refused otherwise at ingest, and only
   the Owner may change it (authoring and ingest alike).

6. (2026-09-27, session 10) EVERYTHING in class A lands in 0.12, done properly, no
   compatibility shims ("cleaner is better"): all of claim C-24 including the
   structural leaks, a signed file content commitment, meeting host pinning, the
   relay items and the smaller ones (design A section 5, plan items 13-16).

2a. The author half of decision 2 ("rows whose author was never a member are
   refused") is a real fix, not an accepted risk and not a label: it becomes
   candidate E4 (High), built together with E1. Today `ServerState` keeps only
   current `members` and the op log is capped, so "ever a member" cannot be proven;
   until E4 lands, the sender gate stands alone (a current member who can read the
   channel can still backfill posts signed by a never-member, a stranger or a
   non-reader cannot). A Message Proof "not a member" label was considered and
   DROPPED: only real fixes.

---

## Class A. The relay is trusted to say who sent a plaintext frame

Every plaintext `HavenMessage` is authorised by the relay-stamped `from`. Against
an honest relay that is sound; against P-01 (the threat model's baseline) every
one below is forgeable, which contradicts claim C-25 ("a malicious relay cannot
forge a server change, a friend accept or a destroy order"). One architectural
fix covers the class: state-changing plaintext messages are signed by the sender
device (domain tag, recipient or room, timestamp) or ride Olm/MLS. Decision
needed from Vitalik: which messages move, and the rollout rule.

| ID | What P-01 can do | Evidence | Sev | Status |
|---|---|---|---|---|
| A1 | Open an Olm session as any device, read DMs and pull history | dm:S-01, media:S-01 | Critical | FIXED HOL-SEC-003 |
| A2 | Tombstone a server locally via `ServerDeleteBroadcast` (and possibly make the owner's device sign a real delete) | crdt:S3, server_mls:S-08 | Critical | FIXED HOL-SEC-053 (confirmed: the owner's device signed a real delete; the variant is gone) |
| A3 | Kick any member via `MemberKickBroadcast`; the Olm `MemberKick` is sent but ignored | crdt:S4, server_mls:S-11 | High | FIXED HOL-SEC-053 (sealed), replay HOL-SEC-054 |
| A4 | Forge `ServerJoinRequest` and have anyone admitted whose device list it has seen | server_mls:S-01 | High | FIXED HOL-SEC-053, replay after a leave HOL-SEC-054 |
| A5 | Forge `ServerJoinResolved` / `ServerJoinRejected` to refuse or freeze a parked join | server_mls:S-05..S-07, crdt:S17 | Medium | FIXED HOL-SEC-053 + 054 (exact nonce, no future stamp) |
| A6 | Spoof a member's `MlsKeyPackage` and obtain a leaf in any server group, private included | server_mls:S-12 | Critical | FIXED HOL-SEC-041 (bound leaves), replay churn HOL-SEC-054 |
| A7 | Spoof `MlsEpochProbe` to evict a member's leaves every 10 s | server_mls:S-20 | Medium | FIXED HOL-SEC-044 (no drop) + 053 (sealed) |
| A8 | Forge `FriendRemove` / `FriendReject` (unfriend) and drive the mutual auto-accept | dm:S-06, dm:S-07 | Medium | FIXED HOL-SEC-053, replay HOL-SEC-054 |
| A9 | Inject sibling-only plaintext (`FriendListSync`, `PersonalEmoteSync`, `ReadMarkers`, `SiblingServerAnnounce`) as our own device | identity:S9 | High | FIXED HOL-SEC-053 (sealed + own-device echo refused), HOL-SEC-056; encryption of the lane = decision 6 |
| A10 | Pull the full op log (private servers included) with a plaintext `SyncRequest` | crdt:S15, server_mls:S-04 | Medium | FIXED HOL-SEC-055 (members only); out of plaintext = decision 6 |
| A11 | Forge voice presence, leave and mute/recording state | media:S-06..S-08 | Low | FIXED HOL-SEC-053 (confirmed first) |
| A12 | Inject an `RtcAnswer` with its own DTLS fingerprint and sit in the data channel | media:S-10 | High | FIXED HOL-SEC-053 (traced: screen-share audio was plaintext to the relay); peer half HOL-SEC-058 |
| A13 | Forge `PeerDisconnecting` to drop a voice leg or unconnected call | dm:S-22 | Low | FIXED HOL-SEC-053 (no sender existed; variant removed) |
| A14 | Garbage PreKey/normal frame with a spoofed `from` tears down a working Olm session | dm:S-03, transport:S-16 | Medium | FIXED HOL-SEC-053 (spoofed) + 054 (a replayed genuine frame) |
| A15 | Swap a waiting-room knocker's KeyPackage so the host admits the relay | server_mls:S-27 | High | FIXED HOL-SEC-017/041; host pinning = decision 6 (A-D3) |
| A16 | Conference lobby/host spoofing (`LobbyInfo`, `Ended`, `Kicked`, `JoinDenied`) | server_mls:S-29..S-32 | Medium | CONFIRMED; relay half FIXED HOL-SEC-053; host pinning = decision 6 (A-D3) |
| A17 | Auth signature has no relay binding or nonce: replay to another relay within 60 s | relay:8 | Medium | CONFIRMED (worse: an unsigned `fetch:true` replay sits invisibly beside the device); decision 6 (A-D4) |
| A18 | A relay reply containing "license_key" stops the reconnect loop for good | relay:22 | Low | CONFIRMED (also wipes the stored key); decision 6 (A-D4) |

New in session 10 (design A inventories, `design_A_inventory/`), all decision 6:

| ID | What | Evidence | Sev | Status |
|---|---|---|---|---|
| A19 | Relay-alone server delete through the owner's own device | server_mls inventory | Critical | FIXED HOL-SEC-053 (= A2) |
| A20 | A sibling announce reopened a held server to any member's snapshot | server_mls inventory | High | FIXED HOL-SEC-056 (needs a harness test) |
| A21 | Share audio played from any open data channel | calls inventory | Medium | FIXED HOL-SEC-058 (needs a test) |
| A22 | Full profile and a third-party profile oracle to anyone | dm inventory | Low | FIXED HOL-SEC-057 |
| A23 | Push fetch node bare-acked junk and cleared every parked destroy order | relay inventory E.2 | Medium | FIXED HOL-SEC-059 |
| A24 | Recovery pool authority is its token, which rides the room name the relay sees | files inventory | Medium | OPEN (token-hashed room + token proof) |
| A25 | One ring frame under 1 MB flushes a ring; one socket fills the 65,536 registrations; retention extends retroactively | relay inventory C.4 | Medium | OPEN (A-D4) |
| A26 | TURN URIs not checked against the relay domain | relay inventory E.9 | Low | OPEN (A-D4) |
| A27 | Conference access hash is a replayable bearer | server_mls, relay inventories | Medium | OPEN (A-D3) |
| A28 | Light profile and device list announced to every room peer; a friend request's sender gets our profile | dm inventory | Medium (C-24) | OPEN (A-D1/A-D5) |
| A29 | DM typing has no friend check; sibling-lane stamps unbounded; unreaction and link-card replays | server_mls, dm inventories | Low | OPEN (A-D5) |
| A30 | No file carries a signed content hash (H8 remainder) | files inventory | High | FIXED HOL-SEC-060 (self-certifying file ids; pre-0.12 files = AR-13, accepted) |

## Class B. Message rows change by message id alone

The signature proves who wrote the edit, card or deletion; nothing checks that
the signer authored the ROW it lands on, or that the row is in the conversation
or channel the item names. Class kill (done, HOL-SEC-004 and HOL-SEC-008): every
remote change to an existing row goes through `message_ops::change_may_touch_row`,
which compares the row's author (device collapsed to master) and the row's
context before the write. B10 and B11 (ordering and replay) closed by HOL-SEC-039.

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| B1 | Rewrite, re-attribute, card and then delete ANY channel message by id through an unsolicited `ChannelSyncBatch` (Olm and MLS) | channel:S1 | High | FIXED HOL-SEC-004 |
| B2 | Rewrite any DM row by id through a `DmSyncBatch`; graft a card and swap the signature | dm:S-09, dm:S-15 | High | FIXED HOL-SEC-004 (sibling batch too) |
| B3 | Live DM edit: signer never compared to the row's author | dm:S-10, dm:S-05 | High | FIXED HOL-SEC-008 |
| B4 | Push-path DM edit has no `is_mine` check: a friend rewrites our own sent rows | dm:S-11, transport:S-04 | High | FIXED HOL-SEC-008 |
| B5 | Live DM delete takes its signer from the sender, not the row (sync twin is right) | dm:S-12 | Medium | FIXED HOL-SEC-008 |
| B6 | DM `AddReaction` attaches to any id, channel messages included, skipping mute | dm:S-13 | Low | FIXED HOL-SEC-008 (channel reactions also bound to the channel they name) |
| B7 | DM `LinkPreviewSet` grafts a card onto any received row and swaps its signature | dm:S-14 | Medium | FIXED HOL-SEC-008 |
| B8 | Push path promotes any `[file:..]` row by id to the attacker's caption and signature | dm:S-17, transport:S-03 | Medium | FIXED HOL-SEC-008 |
| B9 | File metadata owner guard is fed the item's claimed sender, so a sync responder relabels any file card | dm:S-16, files:F1-5, channel:S14 | Medium | Sync half FIXED HOL-SEC-004 (blob bound to the signed `file_id`, owner = verified author); live half CONFIRMED sound (the live FileHeader guard takes the transport sender), the bytes around it are H1/H2 |
| B10 | Edits carry no `edited_at` ordering: a replayed older plaintext edit reverts text | channel:S11 | Low | FIXED HOL-SEC-039: an edit applies only when newer than the row's last edit |
| B11 | Replayed reaction add resurrects a removed reaction (`reaction_removals` ignored) | channel:S10 | Low | FIXED HOL-SEC-039: every removal is recorded, and an add signed no later than a recorded removal is refused |

## Class C. Channel content is not checked against membership, channel or group

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| C1 | `PublicChannelMessage` is stored for ANY channel: a stranger posts into private or admin-only channels (live and push) | channel:S3, transport:S-09 | High | FIXED HOL-SEC-009 |
| C2 | MLS inner `sid`/`cid` not bound to the decrypting group: a member of any shared group (a conference included) posts into another server or a restricted channel, deletes a real server, joins its voice | channel:S4, server_mls:S-10, transport:S-07, media:S-05 | High | FIXED HOL-SEC-010 |
| C3 | `ChannelSyncBatch` accepted unsolicited from anyone, any server, skipping posting gates | channel:S2 | High | Sender half FIXED (decision 2: both arms accept a batch only from a current member who can see the channel, `channel_backfill_allowed_from`, test `authz_channel_backfill_only_from_a_member_who_can_read_it`); author half = candidate E4 (with E1) |
| C4 | `can_post_in_channel` enforced only on the sender's own client | channel:S5 | Medium | FIXED HOL-SEC-009 (posting checked at ingest on every live transport) |
| C5 | Olm and push channel paths skip mute, slow mode, media-only | channel:S6, transport:S-08 | Medium | FIXED HOL-SEC-009 (Olm runs the shared ingest; push applies the same gate) |
| C6 | Mute check keyed on the sender-supplied `sid`: omit it to bypass | channel:S7 | Medium | FIXED HOL-SEC-008 (edits, cards, reactions and deletions must name their row's own channel) |
| C7 | Slow mode judged on the sender's own signed `ts` | channel:S8 | Low | FIXED HOL-SEC-018 (decision 2b): a message dated more than 10 minutes past our clock fails verification on every path (`BackfillSig::FutureDated`); slow mode judges fresh posts by our receive clock (`SlowModeClock`), replays by `ts` |
| C8 | Unsolicited probe responses make a member leak per-author watermarks of restricted channels and suppress its real sync | channel:S9 | Medium | FIXED HOL-SEC-012: the probe wire types (plaintext and envelope) had no sender since 0.10 and are deleted with their handlers; the honest plaintext sync request is J8 |
| C9 | `PublicChannelSyncRequest` serves the text of deleted messages to guests and the relay | channel:S13 | Low | FIXED HOL-SEC-014: the guest page query leaves deleted rows out; members keep them (Rat Files) |
| C10 | `ChannelNotificationHint` and typing are unauthenticated (fake badges, typing) | channel:S15, S16, transport:S-13 | Low | Stranger and non-poster half FIXED HOL-SEC-015 (`channel_signal_accepted` on the hint, plaintext typing and MLS typing arms; blocked typists dropped); the plaintext exposure and relay forgery are J9 |
| C11 | Text clamp only on two of five paths | channel:S18 | Low | FIXED HOL-SEC-011: one 64 KiB byte limit in Rust and Dart; every receive path (live, push, sync, edits, meeting chat) drops a longer body whole inside `verify_message_signature_v2` / `check_backfill_signature` (verdict `Oversized`), nothing clips; the sender refuses at the FFI and the composer and edit fields at input. Relay unchanged (rings byte-bounded, senders never clipped) |
| C12 | A member who cannot see a restricted voice channel still joins it and gets dialed | media:S-04 | Medium | FIXED HOL-SEC-016: both voice join paths ask `voice_join_refusal` (member, voice channel, can see it) |
| C13 | Push path stores `PublicChannelMessage` for conference ids (should be RAM only) | transport:S-10 | Low | FIXED HOL-SEC-009 |
| C14 | 0x09 mention flag set by the sender bypasses "mentions only" | transport:S-11 | Low | FIXED HOL-SEC-035: the fetch judges each post's mention itself (`post_mentions_member`, the sender's own rule) and applies the local level; the flag only wakes; no fallback for a mentions-only channel; the iOS extension no longer claims a mention |

## Class D. MLS credentials and group operations are not authorised (lead L-03)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| D1 | A member gets a leaf whose credential claims any identity, the owner included; no credential validation at Add, Welcome, Update or Commit | server_mls:S-13, A-14 | Critical | FIXED HOL-SEC-041 (design D, session 8): the MLS signing key is the device key and the credential carries the master's certificate, so every receiver proves a leaf's device and master from the leaf alone; KeyPackages are seated only when bound to the sending device (member half was HOL-SEC-017) |
| D2 | Commits from any leaf merged with no role or membership check on Add/Remove | server_mls:S-19 | High | FIXED HOL-SEC-042: every commit is staged and judged before merging (`mls_authority::commit_verdict`): refused outright for non-member senders, foreign proposals, unbound or identity-changing leaves, revoked adds; held while our view may lag for unknown members and for evicting a current member unless the same commit re-adds that device. The coordinator plans with the same rules; a repair is one commit |
| D3 | `MlsWelcome` from anyone drops the live group before validating; group substitution with a KeyPackage requested from the victim | server_mls:S-15, S-16, media:S-13 | High | FIXED HOL-SEC-043: Welcomes are staged (`replace_old_group`) and judged before anything is replaced; replacing a held group needs our own request, bound to its sender for an answered KeyPackage request (decision: any member, if asked) |
| D4 | Garbage `MlsCommit`, `MlsCommitCatchup` or 3 garbage `MlsChannelMessage`s drop the victim's group | server_mls:S-18, S-21, S-24 | Medium | FIXED HOL-SEC-044: no failure drops a group; garbage is ignored, other failures probe, and probes carry an epoch-authenticator digest so the answering member repairs a same-epoch fork |
| D5 | `MlsKeyPackageRequest` ungated: KeyPackages on demand, persisted storage grows | server_mls:S-22 | Low | FIXED HOL-SEC-043: KeyPackage requests answered only for our own server, to a current member, for a subgroup only if we qualify, once per group per 10 s, and while we hold a leaf only to the owner, our catch-up responder or the subgroup coordinator |
| D6 | Subgroup membership decided on `resolve()` of the unvalidated credential | server_mls:S-25 | High | FIXED HOL-SEC-041/042: subgroup membership, the stale sweep and reconcile decide on the certified master; subgroup adds need a master that can see the channel |
| D7 | Conference chat attributed by a credential the sender chose | server_mls:S-28 | Medium | FIXED: knocker half HOL-SEC-017, relay half HOL-SEC-041 (a knock's KeyPackage must be bound to the knocking device, so the relay cannot swap its own in; chat is attributed to the proven leaf). Host pinning from the invite and the lobby frames (S-26, S-29..S-32) go to class A |
| D8 | `MlsKeyPackage` has no ban check | server_mls:S-14 | Medium | FIXED at the MLS layer (HOL-SEC-041/042): the KeyPackage arm refuses a banned master, and commits and Welcomes hold on a banned leaf; a `MemberAdded` that bypasses the ban itself stays E7 |
| D9 | VC frames over MLS attributed to relay `from`, never compared with the leaf | server_mls:S-23, media X-3 | Low | FIXED HOL-SEC-045: MLS `VoiceChannel*` envelopes are dropped unless the encrypting leaf is the relay-stamped device |
| D10 | Parked-join KeyPackage check compares against the relay-stamped sender | server_mls:S-03 | High | FIXED HOL-SEC-041: the parked-join KeyPackage must be bound to the attributed device and the joiner's master |

## Class E. CRDT state authority

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| E1 | While a join is pending, a `ServerStateSnapshot` from any sender is adopted whole: the joiner can be handed a state where the attacker is Owner | crdt:S1 | High | FIXED HOL-SEC-046 (design E, session 9): 0.12 servers have self-certifying ids (the founding op's key and nonce hash to the id) and their joiners take no snapshot; existing servers rebase on the owner's signed checkpoint and new invite links pin the owner (`owner=`); a pinned joiner takes only the pinned owner's snapshot, founding op or checkpoint. Residual R1: an existing server whose owner never runs 0.12, or an old link, stays trust on first use |
| E2 | The pending-join skeleton has no Owner, so the first `ServerCreated` naming itself wins | crdt:S2 | High | FIXED HOL-SEC-046: the join skeleton is ownerless and carries the pin; a founding op lands only on an ownerless state and only for the anchor (the hashing key, or the pinned owner) |
| E3 | Replay after the 1000-op dedup window (restart reloads only the newest 1000): old ops re-apply, deleted registers come back | crdt:S5 | High | FIXED HOL-SEC-047: state is a fold of every retained signed op in HLC order, each judged against the state just before it; ops are no longer capped for anchored servers (a checkpoint compacts), so a replay is always a duplicate or folds before the checkpoint that overwrites it |
| E4 | No provable record of past membership: a current member backfills channel posts signed by an identity that was NEVER a member; they verify, show as Verified in the Message Proof, and spread server-wide through every receiver's own sync. Fix = keep every signed `MemberAdded`/`MemberRemoved` op forever (exempt from the op-log cap) so "was a member" is provable and never-member authors are refused; built on the E1 fix, since a joiner today trusts whoever sends its starting state | decision 2a, sync_handler/swarm channel batch arms, api/network.rs `verify_message_proof_v2` | High | FIXED HOL-SEC-048: a membership record (per master, the spans it was a member) kept in the state and every checkpoint, seeded for existing servers by the owner's first checkpoint; both backfill arms drop items whose author was not a member at the item's time (10 min slack) |
| E5 | Several registers apply in arrival order, not HLC: the relay picks each replica's final value | crdt:S6 | Medium | FIXED HOL-SEC-047: the fold makes every field last-writer-wins by HLC and every admission deterministic; two replicas holding the same ops hold the same state |
| E6 | Unknown authors count as Member: strangers author self ops everyone persists and re-floods | crdt:S7 | Medium | FIXED HOL-SEC-050: every op but the founding op and a checkpoint needs an author who is a current member |
| E7 | `MemberAdded` at ingest checks only that the author is a member: ban, private, cap, Twitch, owner-verify bypassed | crdt:S8, server_mls:S-02 | Medium | FIXED HOL-SEC-049 (decision 4): any member may admit, and every member re-checks ban, private, cap, owner-verify and the Twitch follow credential (now carried in the op) at the op's own time |
| E8 | Admin targets an Owner device id the replica cannot resolve yet; canonicalisation later demotes, bans or mutes the Owner | crdt:S9 | Medium | FIXED HOL-SEC-051: anchored servers never fold device-keyed registers; on a legacy server the fold only adopts, never onto the Owner, never Owner, and no ban or mute onto a Moderator+ |
| E9 | A device key authors with its master's authority through the process-global resolver; a revoked device keeps it where the revocation has not landed | crdt:S10 | Medium | FIXED HOL-SEC-050: an author acts by its own id, never through the resolver (clients sign ops with the master key). The stolen device holding the master key itself stays ID-1 |
| E10 | `ServerSettingChanged` has no key/value validation: an Admin sets `retention_files` to 0 and every member deletes channel files and vault content | crdt:S11 | Medium | FIXED HOL-SEC-021 (decision 2c): `setting_change_allowed` is the one rule for authoring and ingest; retention policies and their `_since` stamps from the Owner only, a policy only with an app value, and a reader treats any other value as keep-everything; the settings page shows retention read-only to non-Owners |
| E11 | Unban/unmute check no target; Admin edits the Owner's nickname, pledge, twitch; `RolePermissionsChanged` unbounded; author/ingest gates disagree | crdt:S12 | Low | FIXED HOL-SEC-052: unban/unmute need the setter's rank; nickname/Twitch/pledge of others need Owner or Admin outranking a member; role permissions only for admin/moderator/member and only bits the author holds; authoring runs `op_allowed` (`author_checked`) |
| E12 | Owner can create co-Owners or remove itself at ingest; an Owner-less server takes `ServerCreated` from anyone | crdt:S13 | Low | FIXED HOL-SEC-052 (decision 1): the owner is fixed; nothing makes anyone Owner or demotes, removes, bans, mutes or edits the Owner |
| E13 | Olm `CrdtOp` path re-pushes duplicates: unbounded op log | crdt:S14 | Low | FIXED HOL-SEC-019: the Olm `CrdtOp`, `SyncReq` and `SyncResp` arms had no sender and are ignored; `apply_op` now reports newness, which also fixes a non-security bug (at the 1000-op cap every caller treated a new op as old, so it was never persisted, shown or re-flooded) |
| E14 | `hlc.actor` not bound to the author; `counter + 1` unchecked | crdt:S16 | Low | FIXED HOL-SEC-020: `verify_author` refuses an op whose clock names anyone but its author; the clock steps the millisecond at the counter's ceiling instead of overflowing |
| E15 | A replayed founding `ServerCreated` resets the name and replaces the Owner's role register | crdt:S18 | Low | FIXED HOL-SEC-047: a founding op lands only on an ownerless state, and a replay is a duplicate |

## Class F. Device lists and revocation (variants of HOL-SEC-001)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| F1 | A foreign device list claims another identity's MASTER id (`speaks_for` treats an unbound id as free): friendship with that master moves to the attacker, and at next boot its server membership and role fold into the attacker | identity:S1 | Critical? | FIXED HOL-SEC-006 |
| F2 | A foreign list "revokes" a legacy (device == master) contact or any unbound device: DMs dropped, Olm session deleted, MLS leaf removal queued | identity:S2 | High | Legacy (device == master) half FIXED HOL-SEC-006; unbound-device half = F6 (co-signatures, ID-1) |
| F3 | A revoked device signs a higher list and revokes the real ones (they wipe) | identity:S3 | Critical | KNOWN (AR-02, design ID-1); the comment at crypto_handler.rs:879 overclaims |
| F4 | A revoked sibling re-enters through the sibling proof (resolver re-bound before the merge refuses it) and gets friends, servers, DM backfill | identity:S4 | High | FIXED HOL-SEC-032 (`sibling_proof_refused` first in `on_verified_sibling`) |
| F5 | Revoked devices resolve to themselves, so they pass the key-exchange and HOL-SEC-003 device check | dm:S-18 | High | FIXED HOL-SEC-032 (enforced revocations recorded in `revoked_devices`, warmed at every start; key exchange refuses a revoked device) |
| F6 | First-come squatting of device ids we have not met yet | identity:S13 | Medium | PLAUSIBLE |
| F7 | `FriendRequest`/`FriendReject`/`ServerJoinRequest` drop `newly_revoked` (no Olm/MLS enforcement) and attribute to `list.master_peer_id` even when the binding was refused | identity parity notes | Medium | FIXED HOL-SEC-033 (`carried_list_master` after ingest; all three arms enforce the revocations) |
| F8 | Destroy-notice replay loop after an identity reappears; any list raises a false "reappeared" alert | identity:S10 | Low | FIXED HOL-SEC-034 (a never-cleared floor for friend notices; only a never-seen device counts as the return) |

## Class G. Remote panics (a frame kills the node's event loop)

| ID | Where | Evidence | Sev | Status |
|---|---|---|---|---|
| G1 | Plaintext `ProfileUpdate` byte-slices free text (`display_name[..64]`) | identity:S7 | High | FIXED HOL-SEC-007 |
| G2 | `&cid[..16]` on a sender string (vault manifest path) | files:V5-2 | High | FIXED HOL-SEC-007 |
| G3 | `&content_id[..8]` in the recovery transfer plan | files:R-4b | Medium | FIXED HOL-SEC-007 |
| G4 | `link_handler.rs:166` byte-slices the relay-stamped `target_peer` | identity:S15 | Low | FIXED HOL-SEC-007 |

## Class H. Files, vault, recovery, share, assets

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| H1 | A `FileHeader` registers its own key for someone else's file id; the stream then replaces the file (MLS: even when complete) | files:F1-1, transport:S-06 | High | FIXED HOL-SEC-022: one header gate `file_header_refused` on every arm (owner of the card, or the holder we asked, or first header; channel headers from a member who can read the channel); completed files never re-delivered |
| H2 | Inline `FileHeader` bytes written and marked complete outside the owner guard (push path overwrites completed files) | files:F1-2 | High | FIXED HOL-SEC-022 (inline bytes behind the same gate, DM headers only, push path included) |
| H3 | `FileChunk` truncates any known file to empty or replaces it | files:F2-1 | High | FIXED HOL-SEC-022 (`FileChunk` had no sender: type and handlers deleted, refused at parse) |
| H4 | `FileChunk` writes orphan chunk files for unknown ids without limit | files:F2-2 | Medium | FIXED HOL-SEC-022 (with H3) |
| H5 | Any sender consumes download receipts, decline pins and pending asks before any check | files:F1-3 | Low | FIXED HOL-SEC-022 (receipts and asks consumed only after the gate) |
| H6 | No membership/post check on the announced `sid:cid` of a channel file | files:F1-4 | Medium | FIXED HOL-SEC-022 (Olm channel headers need a member who can read the channel; MLS already bound by HOL-SEC-010) |
| H7 | `FileHeaderReceived` still carries the attacker's `share_ref` after the guard refused; Dart auto-starts that share | files:F1-6 | Medium | FIXED HOL-SEC-022 (Dart gets a share reference only from the card's owner) |
| H8 | WS stream state keyed by id alone: any room peer appends to or completes another's transfer | files:F7-1, relay:16, transport:S-18 | Medium | FIXED HOL-SEC-023: a stream belongs to the device that opened it (takeover only after 10 s idle); the content-substitution half for channel files needs a signed content hash (class A) |
| H9 | Unsolicited streams write unbounded `.ws_recv_` temps; ShareChunk temps never deleted | files:F7-2 | Medium | FIXED HOL-SEC-023: declared size enforced, 16 open streams per peer and 128 in all, share-chunk temps deleted, `.ws_recv_` swept at boot |
| H10 | FILE-3 shard hash check skipped when the registrant sets k = m = 0 | files:F7-3 | Medium | FIXED HOL-SEC-024 (the rebuilt ciphertext must hash to its content id, so the per-shard hash is no longer the only integrity check) |
| H11 | Any member overwrites any shard Alice holds; pledge checked on one path only (storage exhaustion) | files:V1-1, V1-2, V11-1 | High | FIXED HOL-SEC-024: `shard_write_refused` on every write (member, shard not held, pledge) |
| H12 | `ShardDelete` from an admin of ANY shared server wipes placement records of another server; MLS path ignores overrides and membership | files:V4-1, V4-2 | High | FIXED HOL-SEC-024: `handle_shard_delete` for both transports, override-aware, placements deleted only in the server named |
| H13 | Restricted-channel files in 6+ member servers go to the vault: the key manifest reaches the whole server, shards served without `channel_readable_by` | files:V5-1 | High | FIXED HOL-SEC-025: restricted-channel files never enter the vault (Dart, node and send path); `shard_serve_refused` checks the channel |
| H14 | Unsolicited `ShardResponse` stores or overwrites any shard | files:V6-1, V6-2 | High | FIXED HOL-SEC-024 (shard responses pass the write gate and never replace a pending registration) |
| H15 | `VaultManifestBroadcast` from anyone replaces any manifest, key included, and relinks any file row | files:V10-1 | High | FIXED HOL-SEC-024 (`ingest_vault_manifest`: creator only, never over another creator's, well-formed content id, relinks only the creator's cards; the cache path is sanitized, which closed a write outside the cache folder) |
| H16 | Recovery pool accepts Hello/Welcome/ManifestSync/TransferPlan/Stop from anyone in any room: steer the plan, make us stream shards to a named peer, stop the pool | files:R-1..R-7, relay:15, transport:S-17 | High | FIXED HOL-SEC-026: recovery frames only from the pool room, plans only from the coordinator and only to members; `RecoveryManifestSync` deleted. The token-as-room-name half is HOL-SEC-002 class |
| H17 | `.stream_shard_{cid}.tmp` with an unsanitised cid: write outside files/ on Windows | files:V5-3 | High? | FIXED HOL-SEC-007 |
| H18 | `PublicFileHeader` receipt not tied to the asked peer: substitute a guest's public file | files:F5-1 | Medium | FIXED HOL-SEC-022 (the guest receipt names the peer asked) |
| H19 | Replayed share manifest zeroes a have-bitmap; huge `ShareHave` allocates ~512 MiB | files:S-2, S-3 | Low | FIXED HOL-SEC-027: a share takes its manifest once; a Have only against a known manifest |
| H20 | `EmoteRequest` answers reveal which blobs we hold; 8 MiB replies at 20/s | files:E-1, E-2 | Low | ACCEPTED AR-05 (2026-09-27) |
| H21 | Every `FileRequest` re-encrypts and re-streams the whole file (amplification) | files:F3-1 | Low | ACCEPTED AR-06 (2026-09-27) |
| H22 | Shard assembly holds unbounded RAM for 600 s; placement confirm by any Olm peer | files:V2-1, V3-1 | Low | FIXED HOL-SEC-024 (the chunked shard envelopes had no sender and are gone; a placement is confirmed only by the peer it was placed on) |

## Class I. The relay itself (C++)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| I1 | Crash the relay before auth with a wrong-typed JSON field (no snapshot: buffers, kill list, push tokens lost) | relay:1 | Critical (availability) | FIXED + DEPLOYED HOL-SEC-028: `parse_auth_frame` never throws, pre-auth frames capped at 16 KiB, auth and binary dispatch wrapped |
| I2 | Replace or pre-block a parked destroy order with junk and a huge `issued_at_ms`; the target acks the junk | relay:5, identity:S8 | High | FIXED + DEPLOYED HOL-SEC-029: one slot per issuer per target, every slot delivered, future stamps refused, per-signal ack (client half in 0.12) |
| I3 | Evict every kill-list entry with throwaway identities | relay:6 | Medium | OPEN, residual of HOL-SEC-029: Sybil deposits still evict; the relay cannot judge an order. Design ID-1 |
| I4 | Room joins are ungated: `inbox:{master}` and DM rooms become presence and friendship oracles | relay:7 | Medium (privacy) | OPEN, decision 6 (A-D4, session 11): no rosters or presence for non-owners of an inbox, fetch sockets never listed, DM room names from a secret |
| I5 | Anyone with a server id turns ring retention on, extends or clears it | relay:9 | Medium | OPEN, decision 6 (A-D4, session 11): an owner-signed ring opt-in |
| I6 | Anyone with a server id reads the `~join` ring (plaintext join requests: device list, KeyPackage, Twitch credential) and every channel ring | relay:10 | Medium | OPEN, decision 6 (A-D1, session 11): join requests out of the plaintext ring |
| I7 | Ring flush with junk 0x07 frames; guests unthrottled on 0x07 | relay:11 | Medium | FIXED + DEPLOYED HOL-SEC-030: fair-share ring eviction (a flooder evicts itself); guests may not send topic frames |
| I8 | Link-code guess throttle bypassed by two oracles (`claim` answers "taken", joining `link:{CODE}` returns the roster) | relay:4 | Medium | OPEN, folded into HOL-SEC-002 (the link-code redesign) |
| I9 | Offline-buffer global backstop evicted by throwaway identities | relay:18 | Low | ACCEPTED AR-07 (2026-09-27); revisit with the phase G traffic measurement |
| I10 | A revoked sibling reads the mailbox again after any relay restart (version marks in RAM only) | relay:19 | Medium | FIXED + DEPLOYED HOL-SEC-031: the device-list marks ride the restart snapshot (codec version 3) |
| I11 | Guests deposit and trigger pushes through JSON `direct` | relay:20 | Low | FIXED + DEPLOYED HOL-SEC-030 (guests may not send JSON `direct`) |
| I12 | Report counts inflated by throwaway identities; push wake-ups by any new identity | relay:21, relay:17 | Low | Report half ACCEPTED AR-08 (2026-09-27). Push half OPEN as K3: the wake is not silent, the app shows a fallback banner when the fetch finds nothing |
| I13 | Stale security comments cite a rate limit and a constant that do not exist | relay:24 | Info | FIXED + DEPLOYED (comments corrected with HOL-SEC-030) |

## Class J. Reach, presence and metadata

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| J1 | Relay presence alone triggers KeyRequests, then an ungated WebRTC dial to strangers exposes our IP | relay:14 | Medium | FIXED HOL-SEC-040 (`data_channel_peer_allowed` on the dial and on inbound offers: own devices, friends, shared-server members) |
| J2 | A non-member room joiner becomes a gossip neighbour and receives plaintext CRDT ops | relay:12, transport:S-14 | Medium | FIXED HOL-SEC-040 (overlay takes CRDT members only) |
| J3 | Plaintext `VoiceChannelJoin` re-announce goes to any joiner of the server room | relay:13 | Low | FIXED HOL-SEC-040 (only to a member who can see the channel) |
| J4 | Push payload `server` makes a backgrounded Android node join any room | transport:S-12 | Medium | FIXED HOL-SEC-035 (Dart drops a wake for a server we do not hold; the fetch node and the live-node nudge refuse it) |
| J5 | Forwarder id from the relay is the only one an "Always relay calls" viewer accepts: the relay can name a member device and expose the viewer's address | media:S-12 | Low | CONFIRMED (read in session 7); decision 6 (A-D4, session 11): the forwarder pinned per relay |
| J6 | `PeerExchange` from a gossip neighbour inserts arbitrary peer ids | dm:S-23 | Low | FIXED HOL-SEC-040 (members only) |
| J7 | Nickname `master_id` chosen by the claimer becomes the friend-request target | relay:23 | Low | CONFIRMED (read in session 7; also no confirmation before the request goes out); decision 6 (A-D4, session 11): a master-signed claim and a confirmation |
| J8 | Channel sync requests ride plaintext by design (MLS-epoch resilience) with per-author watermarks and the gap digest: the relay learns who posts in which channel and when, restricted channels included | sync_handler::channel_sync_request, swarm.rs reconnect fan-out | Medium (privacy, C-24) | CONFIRMED (read in session 5); decision 6 (A-D1, session 11): into Olm |
| J9 | `ChannelNotificationHint` is plaintext to the whole server room: the relay and anyone with the server id learn that a channel had a post, which member names it mentioned and whether it pinged everyone, restricted channels included; the relay can forge a hint or typing in a member's name | message_ops.rs hint broadcast, swarm.rs hint arm | Medium (privacy, C-18, C-24) | CONFIRMED (read in session 5; relay forgery closed by HOL-SEC-053); decision 6 (A-D1, session 11): into MLS, the subgroup for restricted channels |

## Class K. Push and background parity

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| K1 | The push fetch node and the iOS NSE never load the block list: blocked senders' DMs are stored and shown | transport:S-01 | Medium | FIXED HOL-SEC-035 (`warm_from_store` loads the block list in every process; blocked members' posts never become banners; iOS hints leave blocked friends out) |
| K2 | A key change first seen through push never raises the alert | transport:S-02 | Low | FIXED HOL-SEC-035 (`pin_olm_identity_key` on the fetch path) |
| K3 | Anyone who knows a device id can make the relay wake that phone; an empty wake showed a fallback banner naming the sender | relay:A-22a | Low | FIXED HOL-SEC-035 on Android (`push_sender_known`); iOS residual: the APNs alert shows before the extension runs, needs Apple's filtering entitlement (decision for Vitalik) |

## Class L. Friends, blocklist, DM edges

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| L1 | `FriendAccept` with no row and no tombstone creates an accepted friend; on a pending-incoming row it accepts without consent | dm:S-05 | High | FIXED HOL-SEC-036 (an accept lands only on our pending outgoing row; it carries the accepter's list; siblings learn through `share_friend_with_siblings`) |
| L2 | A blocked person's never-seen device passes the block check and is then bound to the blocked identity | dm:S-08 | Medium | FIXED HOL-SEC-036 (block checked again after the list binds) |
| L3 | Blocklist missing on edit, delete, react, link preview, friend accept/reject/remove, typing, status, key exchange, raw fallback, MLS twins | dm:S-19 | Medium | FIXED HOL-SEC-036 for edits, cards, deletions, reactions and accepts (the rest: typing already gated, reject/remove/status harmless, key exchange opens nothing, raw fallback gone) |
| L4 | Legacy raw-text fallback shows an unsigned message with no block or revoked check | dm:S-04, transport:S-15 | Medium | FIXED HOL-SEC-013: an unparseable decrypted payload is dropped, as on the push path |
| L5 | MLS accepts DM-shaped `LinkPreviewSet`, reactions and typing from any server member | dm:S-20 | Low | FIXED HOL-SEC-008 (cards, reactions) and HOL-SEC-010 (typing) |
| L6 | OTK minting on `KeyRequest` has no cooldown without a session; a captured request replays for 300 s | dm:S-21 | Low | ACCEPTED AR-09 (2026-09-27); a replay rule broke honest session setup and was reverted |

## Class M. Calls

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| M1 | Dart binds call signals by `call_id` only (from `Random()`, not `Random.secure()`): end, answer or re-point someone else's call | media:S-02 | Medium | FIXED HOL-SEC-037 (sender must be the live call's peer; secure call ids; `audio_state` needs its call id) |
| M2 | Only the blocklist gates ringing (no relationship gate) | media:S-03 | Policy | FIXED HOL-SEC-037 (decided 2026-09-27: only an accepted friend or our own device rings us; `call_invite_allowed`) |
| M3 | The origin guard also accepts origin == receiver on screen_assign / feed_state | media:S-09 | Low | FIXED HOL-SEC-037 (assign from the originator only; feed report must name our stream) |

## Class N. Profiles

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| N1 | Plaintext `ProfileUpdate` stores avatar bytes without comparing them to the signed hash; banner, showcase, frame, animation unsigned | identity:S11 | Medium | Avatar half FIXED HOL-SEC-038; relay rewrite of the unsigned fields closed by HOL-SEC-053 (only the owner's devices can send a profile); signing them and moving profiles off plaintext = decision 6 (session 11) |
| N2 | `saved` is true when the SQL guard refused a stale profile, so a replayed old profile still rewrites the member display name | identity:S12 | Low | FIXED HOL-SEC-038 (also stopped a refused profile's avatar clear) |
| N3 | Profile fields clipped in bytes against character UI limits; a cut breaks the signature (variant of HOL-SEC-011) | swarm.rs ProfileUpdate arm | Low | FIXED HOL-SEC-038 (one limit, 4 bytes per character, refused whole everywhere, editor stops at it) |

## Class O. Device linking (beyond HOL-SEC-002)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| O1 | Any sender's `LinkSnapshotKey` + link stream stashes a blob; the next launch deletes identity and DB before decrypting | identity:S5, relay:2 | Critical | FIXED HOL-SEC-005 |
| O2 | Any peer pops the "your other device wants to sync" prompt; Accept sends the full backup encrypted with our public master id | identity:S6 | Critical (one click) | FIXED HOL-SEC-005 |
| O3 | A hostile relay resolves a link code to its own device and hands the linking device an identity of its choosing | relay:3 | Medium | Folded into HOL-SEC-002 (the PAKE redesign) |
| O4 | `hollow_push_decrypt` (exported, unused by Swift) builds first-contact sessions on an unauthenticated key | this session | Info | DELETED (session 3) |
