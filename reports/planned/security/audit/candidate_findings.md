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
| A2 | Tombstone a server locally via `ServerDeleteBroadcast` (and possibly make the owner's device sign a real delete) | crdt:S3, server_mls:S-08 | High | AGENT |
| A3 | Kick any member via `MemberKickBroadcast`; the Olm `MemberKick` is sent but ignored | crdt:S4, server_mls:S-11 | High | AGENT |
| A4 | Forge `ServerJoinRequest` and have anyone admitted whose device list it has seen | server_mls:S-01 | High | AGENT |
| A5 | Forge `ServerJoinResolved` / `ServerJoinRejected` to refuse or freeze a parked join | server_mls:S-05..S-07, crdt:S17 | Medium | AGENT |
| A6 | Spoof a member's `MlsKeyPackage` and obtain a leaf in any server group, private included | server_mls:S-12 | Critical | AGENT |
| A7 | Spoof `MlsEpochProbe` to evict a member's leaves every 10 s | server_mls:S-20 | Medium | AGENT |
| A8 | Forge `FriendRemove` / `FriendReject` (unfriend) and drive the mutual auto-accept | dm:S-06, dm:S-07 | Medium | AGENT |
| A9 | Inject sibling-only plaintext (`FriendListSync`, `PersonalEmoteSync`, `ReadMarkers`, `SiblingServerAnnounce`) as our own device | identity:S9 | High | AGENT |
| A10 | Pull the full op log (private servers included) with a plaintext `SyncRequest` | crdt:S15, server_mls:S-04 | Medium | AGENT |
| A11 | Forge voice presence, leave and mute/recording state | media:S-06..S-08 | Low | PLAUSIBLE |
| A12 | Inject an `RtcAnswer` with its own DTLS fingerprint and sit in the data channel | media:S-10 | High? | AGENT (impact untraced) |
| A13 | Forge `PeerDisconnecting` to drop a voice leg or unconnected call | dm:S-22 | Low | AGENT |
| A14 | Garbage PreKey/normal frame with a spoofed `from` tears down a working Olm session | dm:S-03, transport:S-16 | Medium | AGENT (PreKey half closed by HOL-SEC-003) |
| A15 | Swap a waiting-room knocker's KeyPackage so the host admits the relay | server_mls:S-27 | High | AGENT |
| A16 | Conference lobby/host spoofing (`LobbyInfo`, `Ended`, `Kicked`, `JoinDenied`) | server_mls:S-29..S-32 | Medium | AGENT |
| A17 | Auth signature has no relay binding or nonce: replay to another relay within 60 s | relay:8 | Medium | PLAUSIBLE |
| A18 | A relay reply containing "license_key" stops the reconnect loop for good | relay:22 | Low | AGENT |

## Class B. Message rows change by message id alone

The signature proves who wrote the edit, card or deletion; nothing checks that
the signer authored the ROW it lands on, or that the row is in the conversation
or channel the item names. Class kill: every row mutation goes through one
`authorise_row_mutation(row, signer, context)` that compares the row's author
(device collapsed to master) and the row's context before the write.

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| B1 | Rewrite, re-attribute, card and then delete ANY channel message by id through an unsolicited `ChannelSyncBatch` (Olm and MLS) | channel:S1 | High | FIXED HOL-SEC-004 |
| B2 | Rewrite any DM row by id through a `DmSyncBatch`; graft a card and swap the signature | dm:S-09, dm:S-15 | High | FIXED HOL-SEC-004 (sibling batch too) |
| B3 | Live DM edit: signer never compared to the row's author | dm:S-10, dm:S-05 | High | AGENT |
| B4 | Push-path DM edit has no `is_mine` check: a friend rewrites our own sent rows | dm:S-11, transport:S-04 | High | AGENT |
| B5 | Live DM delete takes its signer from the sender, not the row (sync twin is right) | dm:S-12 | Medium | AGENT |
| B6 | DM `AddReaction` attaches to any id, channel messages included, skipping mute | dm:S-13 | Low | AGENT |
| B7 | DM `LinkPreviewSet` grafts a card onto any received row and swaps its signature | dm:S-14 | Medium | AGENT |
| B8 | Push path promotes any `[file:..]` row by id to the attacker's caption and signature | dm:S-17, transport:S-03 | Medium | AGENT |
| B9 | File metadata owner guard is fed the item's claimed sender, so a sync responder relabels any file card | dm:S-16, files:F1-5, channel:S14 | Medium | Sync half FIXED HOL-SEC-004 (blob bound to the signed `file_id`, owner = verified author); live half AGENT |
| B10 | Edits carry no `edited_at` ordering: a replayed older plaintext edit reverts text | channel:S11 | Low | AGENT |
| B11 | Replayed reaction add resurrects a removed reaction (`reaction_removals` ignored) | channel:S10 | Low | AGENT |

## Class C. Channel content is not checked against membership, channel or group

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| C1 | `PublicChannelMessage` is stored for ANY channel: a stranger posts into private or admin-only channels (live and push) | channel:S3, transport:S-09 | High | AGENT |
| C2 | MLS inner `sid`/`cid` not bound to the decrypting group: a member of any shared group (a conference included) posts into another server or a restricted channel, deletes a real server, joins its voice | channel:S4, server_mls:S-10, transport:S-07, media:S-05 | High | AGENT |
| C3 | `ChannelSyncBatch` accepted unsolicited from anyone, any server, skipping posting gates | channel:S2 | High | Sender half FIXED (decision 2: both arms accept a batch only from a current member who can see the channel, `channel_backfill_allowed_from`, test `authz_channel_backfill_only_from_a_member_who_can_read_it`); author half = candidate E4 (with E1) |
| C4 | `can_post_in_channel` enforced only on the sender's own client | channel:S5 | Medium | AGENT |
| C5 | Olm and push channel paths skip mute, slow mode, media-only | channel:S6, transport:S-08 | Medium | AGENT |
| C6 | Mute check keyed on the sender-supplied `sid`: omit it to bypass | channel:S7 | Medium | AGENT |
| C7 | Slow mode judged on the sender's own signed `ts` | channel:S8 | Low | AGENT |
| C8 | Unsolicited probe responses make a member leak per-author watermarks of restricted channels and suppress its real sync | channel:S9 | Medium | AGENT |
| C9 | `PublicChannelSyncRequest` serves the text of deleted messages to guests and the relay | channel:S13 | Low | AGENT |
| C10 | `ChannelNotificationHint` and typing are unauthenticated (fake badges, typing) | channel:S15, S16, transport:S-13 | Low | AGENT |
| C11 | Text clamp only on two of five paths | channel:S18 | Low | AGENT |
| C12 | A member who cannot see a restricted voice channel still joins it and gets dialed | media:S-04 | Medium | AGENT |
| C13 | Push path stores `PublicChannelMessage` for conference ids (should be RAM only) | transport:S-10 | Low | AGENT |
| C14 | 0x09 mention flag set by the sender bypasses "mentions only" | transport:S-11 | Low | AGENT |

## Class D. MLS credentials and group operations are not authorised (lead L-03)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| D1 | A member gets a leaf whose credential claims any identity, the owner included; no credential validation at Add, Welcome, Update or Commit | server_mls:S-13, A-14 | Critical | AGENT |
| D2 | Commits from any leaf merged with no role or membership check on Add/Remove | server_mls:S-19 | High | AGENT |
| D3 | `MlsWelcome` from anyone drops the live group before validating; group substitution with a KeyPackage requested from the victim | server_mls:S-15, S-16, media:S-13 | High | AGENT |
| D4 | Garbage `MlsCommit`, `MlsCommitCatchup` or 3 garbage `MlsChannelMessage`s drop the victim's group | server_mls:S-18, S-21, S-24 | Medium | AGENT |
| D5 | `MlsKeyPackageRequest` ungated: KeyPackages on demand, persisted storage grows | server_mls:S-22 | Low | AGENT |
| D6 | Subgroup membership decided on `resolve()` of the unvalidated credential | server_mls:S-25 | High | AGENT |
| D7 | Conference chat attributed by a credential the sender chose | server_mls:S-28 | Medium | AGENT |
| D8 | `MlsKeyPackage` has no ban check | server_mls:S-14 | Medium | AGENT |
| D9 | VC frames over MLS attributed to relay `from`, never compared with the leaf | server_mls:S-23, media X-3 | Low | PLAUSIBLE |
| D10 | Parked-join KeyPackage check compares against the relay-stamped sender | server_mls:S-03 | High | AGENT |

## Class E. CRDT state authority

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| E1 | While a join is pending, a `ServerStateSnapshot` from any sender is adopted whole: the joiner can be handed a state where the attacker is Owner | crdt:S1 | High | AGENT (E4 builds on its fix) |
| E2 | The pending-join skeleton has no Owner, so the first `ServerCreated` naming itself wins | crdt:S2 | High | AGENT |
| E3 | Replay after the 1000-op dedup window (restart reloads only the newest 1000): old ops re-apply, deleted registers come back | crdt:S5 | High | PLAUSIBLE reach |
| E4 | No provable record of past membership: a current member backfills channel posts signed by an identity that was NEVER a member; they verify, show as Verified in the Message Proof, and spread server-wide through every receiver's own sync. Fix = keep every signed `MemberAdded`/`MemberRemoved` op forever (exempt from the op-log cap) so "was a member" is provable and never-member authors are refused; built on the E1 fix, since a joiner today trusts whoever sends its starting state | decision 2a, sync_handler/swarm channel batch arms, api/network.rs `verify_message_proof_v2` | High | CONFIRMED (read in session 3); fix with E1 |
| E5 | Several registers apply in arrival order, not HLC: the relay picks each replica's final value | crdt:S6 | Medium | AGENT |
| E6 | Unknown authors count as Member: strangers author self ops everyone persists and re-floods | crdt:S7 | Medium | AGENT |
| E7 | `MemberAdded` at ingest checks only that the author is a member: ban, private, cap, Twitch, owner-verify bypassed | crdt:S8, server_mls:S-02 | Medium | AGENT |
| E8 | Admin targets an Owner device id the replica cannot resolve yet; canonicalisation later demotes, bans or mutes the Owner | crdt:S9 | Medium | PLAUSIBLE |
| E9 | A device key authors with its master's authority through the process-global resolver; a revoked device keeps it where the revocation has not landed | crdt:S10 | Medium | PLAUSIBLE |
| E10 | `ServerSettingChanged` has no key/value validation: an Admin sets `retention_files` to 0 and every member deletes channel files and vault content | crdt:S11 | Medium | AGENT |
| E11 | Unban/unmute check no target; Admin edits the Owner's nickname, pledge, twitch; `RolePermissionsChanged` unbounded; author/ingest gates disagree | crdt:S12 | Low | AGENT |
| E12 | Owner can create co-Owners or remove itself at ingest; an Owner-less server takes `ServerCreated` from anyone | crdt:S13 | Low | AGENT |
| E13 | Olm `CrdtOp` path re-pushes duplicates: unbounded op log | crdt:S14 | Low | AGENT |
| E14 | `hlc.actor` not bound to the author; `counter + 1` unchecked | crdt:S16 | Low | PLAUSIBLE |
| E15 | A replayed founding `ServerCreated` resets the name and replaces the Owner's role register | crdt:S18 | Low | AGENT |

## Class F. Device lists and revocation (variants of HOL-SEC-001)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| F1 | A foreign device list claims another identity's MASTER id (`speaks_for` treats an unbound id as free): friendship with that master moves to the attacker, and at next boot its server membership and role fold into the attacker | identity:S1 | Critical? | AGENT |
| F2 | A foreign list "revokes" a legacy (device == master) contact or any unbound device: DMs dropped, Olm session deleted, MLS leaf removal queued | identity:S2 | High | AGENT |
| F3 | A revoked device signs a higher list and revokes the real ones (they wipe) | identity:S3 | Critical | KNOWN (AR-02, design ID-1); the comment at crypto_handler.rs:879 overclaims |
| F4 | A revoked sibling re-enters through the sibling proof (resolver re-bound before the merge refuses it) and gets friends, servers, DM backfill | identity:S4 | High | AGENT |
| F5 | Revoked devices resolve to themselves, so they pass the key-exchange and HOL-SEC-003 device check | dm:S-18 | High | AGENT |
| F6 | First-come squatting of device ids we have not met yet | identity:S13 | Medium | PLAUSIBLE |
| F7 | `FriendRequest`/`FriendReject`/`ServerJoinRequest` drop `newly_revoked` (no Olm/MLS enforcement) and attribute to `list.master_peer_id` even when the binding was refused | identity parity notes | Medium | AGENT |
| F8 | Destroy-notice replay loop after an identity reappears; any list raises a false "reappeared" alert | identity:S10 | Low | AGENT |

## Class G. Remote panics (a frame kills the node's event loop)

| ID | Where | Evidence | Sev | Status |
|---|---|---|---|---|
| G1 | Plaintext `ProfileUpdate` byte-slices free text (`display_name[..64]`) | identity:S7 | High | AGENT |
| G2 | `&cid[..16]` on a sender string (vault manifest path) | files:V5-2 | High | AGENT |
| G3 | `&content_id[..8]` in the recovery transfer plan | files:R-4b | Medium | AGENT |
| G4 | `link_handler.rs:166` byte-slices the relay-stamped `target_peer` | identity:S15 | Low | AGENT |

## Class H. Files, vault, recovery, share, assets

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| H1 | A `FileHeader` registers its own key for someone else's file id; the stream then replaces the file (MLS: even when complete) | files:F1-1, transport:S-06 | High | AGENT |
| H2 | Inline `FileHeader` bytes written and marked complete outside the owner guard (push path overwrites completed files) | files:F1-2 | High | AGENT |
| H3 | `FileChunk` truncates any known file to empty or replaces it | files:F2-1 | High | AGENT |
| H4 | `FileChunk` writes orphan chunk files for unknown ids without limit | files:F2-2 | Medium | AGENT |
| H5 | Any sender consumes download receipts, decline pins and pending asks before any check | files:F1-3 | Low | AGENT |
| H6 | No membership/post check on the announced `sid:cid` of a channel file | files:F1-4 | Medium | AGENT |
| H7 | `FileHeaderReceived` still carries the attacker's `share_ref` after the guard refused; Dart auto-starts that share | files:F1-6 | Medium | PLAUSIBLE |
| H8 | WS stream state keyed by id alone: any room peer appends to or completes another's transfer | files:F7-1, relay:16, transport:S-18 | Medium | CONFIRMED (read in ws_stream_transfer.rs) |
| H9 | Unsolicited streams write unbounded `.ws_recv_` temps; ShareChunk temps never deleted | files:F7-2 | Medium | AGENT |
| H10 | FILE-3 shard hash check skipped when the registrant sets k = m = 0 | files:F7-3 | Medium | AGENT |
| H11 | Any member overwrites any shard Alice holds; pledge checked on one path only (storage exhaustion) | files:V1-1, V1-2, V11-1 | High | AGENT |
| H12 | `ShardDelete` from an admin of ANY shared server wipes placement records of another server; MLS path ignores overrides and membership | files:V4-1, V4-2 | High | AGENT |
| H13 | Restricted-channel files in 6+ member servers go to the vault: the key manifest reaches the whole server, shards served without `channel_readable_by` | files:V5-1 | High | AGENT |
| H14 | Unsolicited `ShardResponse` stores or overwrites any shard | files:V6-1, V6-2 | High | AGENT |
| H15 | `VaultManifestBroadcast` from anyone replaces any manifest, key included, and relinks any file row | files:V10-1 | High | AGENT |
| H16 | Recovery pool accepts Hello/Welcome/ManifestSync/TransferPlan/Stop from anyone in any room: steer the plan, make us stream shards to a named peer, stop the pool | files:R-1..R-7, relay:15, transport:S-17 | High | AGENT |
| H17 | `.stream_shard_{cid}.tmp` with an unsanitised cid: write outside files/ on Windows | files:V5-3 | High? | PLAUSIBLE |
| H18 | `PublicFileHeader` receipt not tied to the asked peer: substitute a guest's public file | files:F5-1 | Medium | AGENT |
| H19 | Replayed share manifest zeroes a have-bitmap; huge `ShareHave` allocates ~512 MiB | files:S-2, S-3 | Low | AGENT/PLAUSIBLE |
| H20 | `EmoteRequest` answers reveal which blobs we hold; 8 MiB replies at 20/s | files:E-1, E-2 | Low | PLAUSIBLE |
| H21 | Every `FileRequest` re-encrypts and re-streams the whole file (amplification) | files:F3-1 | Low | PLAUSIBLE |
| H22 | Shard assembly holds unbounded RAM for 600 s; placement confirm by any Olm peer | files:V2-1, V3-1 | Low | AGENT |

## Class I. The relay itself (C++)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| I1 | Crash the relay before auth with a wrong-typed JSON field (no snapshot: buffers, kill list, push tokens lost) | relay:1 | Critical (availability) | AGENT |
| I2 | Replace or pre-block a parked destroy order with junk and a huge `issued_at_ms`; the target acks the junk | relay:5, identity:S8 | High | AGENT |
| I3 | Evict every kill-list entry with throwaway identities | relay:6 | Medium | AGENT |
| I4 | Room joins are ungated: `inbox:{master}` and DM rooms become presence and friendship oracles | relay:7 | Medium (privacy) | AGENT |
| I5 | Anyone with a server id turns ring retention on, extends or clears it | relay:9 | Medium | AGENT |
| I6 | Anyone with a server id reads the `~join` ring (plaintext join requests: device list, KeyPackage, Twitch credential) and every channel ring | relay:10 | Medium | AGENT |
| I7 | Ring flush with junk 0x07 frames; guests unthrottled on 0x07 | relay:11 | Medium | AGENT |
| I8 | Link-code guess throttle bypassed by two oracles (`claim` answers "taken", joining `link:{CODE}` returns the roster) | relay:4 | Medium | AGENT |
| I9 | Offline-buffer global backstop evicted by throwaway identities | relay:18 | Low | AGENT |
| I10 | A revoked sibling reads the mailbox again after any relay restart (version marks in RAM only) | relay:19 | Medium | AGENT (documented in code) |
| I11 | Guests deposit and trigger pushes through JSON `direct` | relay:20 | Low | AGENT |
| I12 | Report counts inflated by throwaway identities; push wake-ups by any new identity | relay:21, relay:17 | Low | AGENT |
| I13 | Stale security comments cite a rate limit and a constant that do not exist | relay:24 | Info | AGENT |

## Class J. Reach, presence and metadata

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| J1 | Relay presence alone triggers KeyRequests, then an ungated WebRTC dial to strangers exposes our IP | relay:14 | Medium | PLAUSIBLE |
| J2 | A non-member room joiner becomes a gossip neighbour and receives plaintext CRDT ops | relay:12, transport:S-14 | Medium | AGENT |
| J3 | Plaintext `VoiceChannelJoin` re-announce goes to any joiner of the server room | relay:13 | Low | AGENT |
| J4 | Push payload `server` makes a backgrounded Android node join any room | transport:S-12 | Medium | AGENT |
| J5 | Forwarder id from the relay is the only one an "Always relay calls" viewer accepts: the relay can name a member device and expose the viewer's address | media:S-12 | Low | PLAUSIBLE |
| J6 | `PeerExchange` from a gossip neighbour inserts arbitrary peer ids | dm:S-23 | Low | PLAUSIBLE |
| J7 | Nickname `master_id` chosen by the claimer becomes the friend-request target | relay:23 | Low | AGENT (by design) |

## Class K. Push and background parity

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| K1 | The push fetch node and the iOS NSE never load the block list: blocked senders' DMs are stored and shown | transport:S-01 | Medium | AGENT |
| K2 | A key change first seen through push never raises the alert | transport:S-02 | Low | PLAUSIBLE |

## Class L. Friends, blocklist, DM edges

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| L1 | `FriendAccept` with no row and no tombstone creates an accepted friend; on a pending-incoming row it accepts without consent | dm:S-05 | High | AGENT |
| L2 | A blocked person's never-seen device passes the block check and is then bound to the blocked identity | dm:S-08 | Medium | AGENT |
| L3 | Blocklist missing on edit, delete, react, link preview, friend accept/reject/remove, typing, status, key exchange, raw fallback, MLS twins | dm:S-19 | Medium | AGENT |
| L4 | Legacy raw-text fallback shows an unsigned message with no block or revoked check | dm:S-04, transport:S-15 | Medium | AGENT |
| L5 | MLS accepts DM-shaped `LinkPreviewSet`, reactions and typing from any server member | dm:S-20 | Low | AGENT |
| L6 | OTK minting on `KeyRequest` has no cooldown without a session; a captured request replays for 300 s | dm:S-21 | Low | PLAUSIBLE |

## Class M. Calls

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| M1 | Dart binds call signals by `call_id` only (from `Random()`, not `Random.secure()`): end, answer or re-point someone else's call | media:S-02 | Medium | PLAUSIBLE |
| M2 | Only the blocklist gates ringing (no relationship gate) | media:S-03 | Policy | PLAUSIBLE |
| M3 | The origin guard also accepts origin == receiver on screen_assign / feed_state | media:S-09 | Low | AGENT (hardening) |

## Class N. Profiles

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| N1 | Plaintext `ProfileUpdate` stores avatar bytes without comparing them to the signed hash; banner, showcase, frame, animation unsigned | identity:S11 | Medium | AGENT |
| N2 | `saved` is true when the SQL guard refused a stale profile, so a replayed old profile still rewrites the member display name | identity:S12 | Low | AGENT |

## Class O. Device linking (beyond HOL-SEC-002)

| ID | What an attacker can do | Evidence | Sev | Status |
|---|---|---|---|---|
| O1 | Any sender's `LinkSnapshotKey` + link stream stashes a blob; the next launch deletes identity and DB before decrypting | identity:S5, relay:2 | Critical | FIXED HOL-SEC-005 |
| O2 | Any peer pops the "your other device wants to sync" prompt; Accept sends the full backup encrypted with our public master id | identity:S6 | Critical (one click) | FIXED HOL-SEC-005 |
| O3 | A hostile relay resolves a link code to its own device and hands the linking device an identity of its choosing | relay:3 | Medium | Folded into HOL-SEC-002 (the PAKE redesign) |
| O4 | `hollow_push_decrypt` (exported, unused by Swift) builds first-contact sessions on an unauthenticated key | this session | Info | DELETED (session 3) |
