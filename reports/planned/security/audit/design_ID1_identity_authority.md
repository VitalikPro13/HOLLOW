# Design ID-1: the recovery phrase as the root of identity authority, and the device link handshake

Session 20 (2026-09-30, xhigh). Builds plan section 8a (agreed 2026-09-26) and fixes
HOL-SEC-002. Closes AR-02, candidates F2 (unbound half), F3, F6, I8, and the
stolen-device half of HOL-SEC-041 (a master certificate naming a device that is not
one of the identity's devices). Decision 10 (device co-signatures) is built here.

## The problem in one paragraph

Every device holds the master key, and today the master key IS the authority over
the device list: any holder of it signs a newer list, which adds any device, revokes
the owner's real devices (they wipe themselves), and issues destroy orders. A stolen
phone keeps the identity for good, and so does anyone holding a `.hollow` backup file:
restoring it mints a device that signs itself into the list with nobody asked. Linking
is worse: the snapshot that carries the master key is encrypted under the link code,
which the client sends to the relay in the clear, or under the public master id.

## Principles

1. Holding the master key proves nothing about which devices are the identity's. It
   still signs messages, profiles and server ops, but a device list change needs a
   current device's own key, or the recovery phrase.
2. Every device is equal; there is no primary. The recovery phrase, which no device
   stores, is the final word: whatever it signs beats every device.
3. A device joins only with its own consent (its key signs the join) and one of: a
   vouch from a current device, the phrase, or seven days with nobody objecting.
4. Removal locks a device at once and erases it after three days unless the phrase is
   typed on it.
5. The relay never holds a secret that opens a link transfer.

## 1. Keys

- **Master** M: unchanged, the first 32 bytes of the BIP-39 seed. Still the identity
  id and still on every device.
- **Recovery** R: an Ed25519 key from `HKDF-SHA256(ikm = the whole 64-byte seed,
  salt = "hollow-recovery", info = "hollow-recovery-key1")`. It exists only while the
  phrase is typed and is zeroized after use; nothing writes it to disk.
  Why M does not reveal R: M's secret is `seed[0..32]`; R depends on all 64 bytes, and
  `seed[32..64]` is the other half of one HMAC-SHA512 output of PBKDF2, which the
  first half does not determine without breaking SHA-512 as a PRF. The phrase itself
  has 256 bits (24 words) or 128 bits (12 words) of entropy, so it cannot be searched.
  Pinned by a known-answer vector.
- **Device** D: unchanged, random per install. A device id is its public key in
  encoded form, so any device signature verifies from the id alone.

## 2. The roster

A person's devices are no longer a master-signed list but a **roster**: a set of
signed statements, each verifiable on its own. Any observer (a friend, a co-member,
one of our own devices) folds the same statements into the same answer. Statements are
never edited; a roster only grows until a recovery starts a new base.

Every signature is over an ASCII string with its own `hollow-id1-*` tag and the master
id, so none can pass as another type (rule 7).

| Statement | Signed by | Payload |
|---|---|---|
| Consent | the device | `hollow-id1-join:{master}:{device}` |
| Recovery | R and M | `hollow-id1-recovery:{master}:{r_pub}:{at_ms}:{sorted keep csv}` |
| Phrase admission | R and M | `hollow-id1-radmit:{master}:{r_pub}:{at_ms}:{device}` |
| Vouch | a current device V | `hollow-id1-admit:{master}:{base}:{device}` |
| Pending join | M | `hollow-id1-pending:{master}:{base}:{device}` |
| Legacy claim | M | `hollow-id1-legacy:{master}:{device}` |
| Removal | a device X | `hollow-id1-remove:{master}:{base}:{device}:{sorted keep_vouched csv}` |

- **Consent** kills squatting (F6) and the rest of HOL-SEC-006's class: no roster can
  name a device whose key did not sign up for that exact master.
- **Base.** A recovery starts a base; its id is the first 32 hex of SHA-256 of its
  payload. Device-signed statements name the base they were made in and count only
  there. An identity with no recovery yet has the base `legacy`.
- **R binding.** M's signature on a recovery or phrase admission binds R to the
  identity; every observer pins the first R it sees for a master and drops any
  statement under another R. New identities publish R at creation.
- **Time.** Only R-signed statements carry a time (`at_ms`), and only the phrase holder
  can write one, so their order is trustworthy. Device statements carry no time.

## 3. The fold

Given the verified statements, the pinned R, the local first-seen time of each pending
join, and now:

1. **Base** = the recovery with the largest `at_ms` (ties: the lowest id; their keep
   sets unite). None = `legacy`.
2. **Roots** = the base's keep set (legacy: every legacy claim), plus every phrase
   admission dated after the base (legacy: every phrase admission).
3. **Rooted** = the closure of the roots under vouches made in this base, plus pending
   joins in this base first seen at least 7 days ago. Removals are ignored here.
4. **Removed** = every device named by a removal in this base whose signer is rooted.
   A removal counts even when its signer is itself removed (see 5).
5. **Members** = the least set containing the roots and the matured pending joins, and
   every device vouched by a member that is not removed, or by a removed device whose
   removals ALL list it in `keep_vouched` (an intersection since ID-1R, HOL-SEC-080);
   minus Removed. Every member must have consent.

Since ID-1R (`design_ID1R_relay_rosters.md`) compaction keeps a vouch or removal only from
a signer with standing and orders what stays by the signer's distance from the phrase
(HOL-SEC-079), and a recovery may turn joining by seven quiet days off (`no_wait`).

Rules that fall out, and why:

- **A removal is final inside its base.** A removed device comes back only through a
  recovery. Removals are a plain union, so the fold is order-free and every observer
  agrees without knowing who acted first.
- **A removed device's later vouches are void.** An honest remover lists in
  `keep_vouched` the members the removed device had added that it keeps (replacing an
  old phone keeps the new one); anything the removed device vouches afterwards is not
  listed, so it counts for nothing. Without this a thief's phone, once removed, could
  keep adding devices.
- **A removed device's removals still count.** Nothing without a trusted clock can tell
  "removed X before being removed" from "after". The cost: a stolen phone can remove the
  owner's devices, and a race where each removes the other removes both. Both end the
  same way: the owner types the phrase.
- **Pending maturity is judged by each observer's own clock**, from when that observer
  first saw the request. A backdated request gains nothing.

## 4. The flows

### Creating an identity

The phrase exists at that moment, so the new device signs its consent and a genesis
recovery keeping only itself. R is pinned by everyone who later meets the identity.

### Linking a device (a vouch)

The populated device P vouches for the new device N after the handshake of section 6.
N's final device key is minted before the transfer, so the vouch names the id N will
run as, and the snapshot carries the vouch. N is a member from its first start.

### Restoring from the phrase

The restored device signs a phrase admission for itself (R + M, dated now) and its
consent. It is a member at once, whatever base is current, since the admission is
dated after it.

### Restoring a `.hollow` backup file

The import mints a fresh device id (as today). On first start the device finds itself
in no statement and publishes a pending join (M-signed, its consent) to its own inbox
(the relay's mailbox holds it for offline devices) and to its friends' DM rooms and its
servers' rooms, so contacts start their seven-day clocks. Every current device shows
"A device restored from a backup wants to join" with Approve (a vouch) and Refuse (a
removal). Nobody answering for seven days lets it in at each observer. The phrase lets
it in at once.

### Removing a device

Any current device signs a removal. Contacts stop sending to the device at once. The
removed device, on learning it, locks: a full screen with who removed it and when, a
countdown to erasure at three days, "Use recovery phrase" and "Erase now". It keeps
its node running so a recovery that keeps it unlocks it again.

### Recovering (the phrase is the final word)

Typing the phrase on any device (a removed one included) and choosing which devices to
keep signs a recovery: a new base whose keep set is exactly those devices. Everything
else stops counting at once, the thief's devices included, and nothing signed in the
old base counts in the new one. New devices then join the new base by the usual three
routes. A device that was dropped but belongs to the owner can be vouched back in.

### Remote destroy

Needs R: `DestroyIdentity` is signed by R (and M, to name the identity), judged against
the pinned R. Wiping the device in hand and duress stay instant and phrase-free. The
duress scope that destroys every device needs a decision (section 9).

## 5. Existing identities (the upgrade)

Old lists carry no consent, and R does not exist until the phrase is typed, so an
identity from before 0.12 runs on the `legacy` base:

- On its first 0.12 start, a device that its own stored 0.11 list names signs a legacy
  claim for itself and its consent, and a removal for every id in that list's revoked
  set (so a revoked device cannot claim its way back in).
- A device that is not in the stored list (a 0.11 backup restored onto a new machine)
  is a pending join like any restored backup.
- Contacts keep their 0.11 device links as a fallback for a master until that master's
  first roster arrives, which replaces them.
- A device that still holds the phrase 0.11 stored signs the identity's first recovery
  itself at that first start, before it connects (session 35, decision C): one fixed
  statement every device of the identity signs alike (dated 2020-01-01, keeping only the
  recovery key's own id), a phrase admission for itself and every device its 0.11 list
  kept, and a removal in that base for every id the list revoked. Devices that upgrade at
  different times with lists out of step therefore meet in one base, and the union of
  admissions and removals decides. From then on legacy claims count for nothing.
- The app still asks, once, to confirm the phrase. The confirmation
  (`confirm_stored_phrase`) only erases the stored copy when the phrase already roots the
  roster, and signs a recovery as before when it does not.

**Residual (legacy only):** for an identity none of whose devices kept the 0.11 phrase,
anyone holding the master key can still sign a legacy claim until the phrase is typed, as
today. Once the identity has a recovery, it is protected.

## 6. The link handshake (HOL-SEC-002)

The code P shows has two parts: a six-character **rendezvous** part the relay sees
(claim and resolve, unchanged relay, one-shot, throttled), and a four-character
**secret** part the relay never sees (20 bits). The two devices run SPAKE2 (RustCrypto
`spake2`, the implementation magic-wormhole uses) keyed by the secret part and bound to
the rendezvous part, then confirm the key both ways (HMAC over the transcript). A relay
that plays the other device gets one guess per link attempt; a wrong guess aborts the
attempt and burns the code.

Everything after the key exchange rides AES-256-GCM under keys derived from it
(HKDF-SHA256, salt = the rendezvous part; one key per direction plus the confirm key;
AAD names the rendezvous and the direction):

1. N sends a hello: the device id it will run as (minted before the handshake), its
   name and platform.
2. P shows "Add this device?" naming "<name> (<platform>)". Accept = P signs the vouch.
3. P exports the snapshot under a fresh random key, which travels inside the channel
   (the offer); the snapshot's roster already holds the vouch.
4. N stashes the blob, the key and its device key, restarts, and imports through the
   unchanged backup pipeline, installing the device key it minted instead of a new one.
   It signs its consent at that first start.

The code answers one handshake: a second device in the room, or a hello that does not
open, burns it. There is no phrase path: nothing in the app reaches it, so it was
deleted rather than fixed.

## 7. What changes where

Code map: two enumeration passes, 2026-09-30 (Rust and Dart), line numbers of HEAD
`62b991fa`.

**Found on the way (fixed in this build):**
- The recovery phrase is STORED: `api/storage.rs` `save_mnemonic` writes it into the
  database as `recovery_mnemonic`; Settings shows it with no password; it rides every
  `.hollow` backup and every link snapshot. ID-1 means nothing while it does.
- A backup or link snapshot carries the source device's Olm account and every Olm session
  (`messages.db` is copied whole; only the MLS identity is cleared on a link import, and
  nothing on a backup import). A restored or linked device runs on another device's Olm
  identity key, and a stolen backup file holds live session state.

**Keys and bootstrap.** `identity/recovery.rs`, `identity/roster.rs`. `generate_new_identity`
writes a genesis roster (`roster_bootstrap.json` beside the key files; the database is not
open yet) and `restore_identity_from_mnemonic` a phrase admission for its new device; the
node imports and deletes the file at start. Nothing stores the phrase.

**Wire.** `SignedDeviceList` becomes `Roster` on every carrier (`ServerJoinRequest`,
`PendingJoin`, `ProfileUpdate` (Olm and MLS), `FriendRequest`, `FriendAccept`,
`FriendReject`, `ProfileCard`, `CarriedRequestRecord`). `DeviceListTombstone` becomes
`RosterNotice` (relay lane): the roster to a removed device, and a pending device's
request to its own inbox, its friends' DM rooms and its servers' rooms. The relay's inbox
proof stays a master-signed list of the current members (`InboxProof`, same JSON) until
ID-1R.

**Storage.** `device_lists.json` holds the roster; `device_links` = the fold's members;
`revoked_devices` = removed; new `roster_pending_seen(master, base, device, first_seen_ms)`
(per base since HOL-SEC-082: a recovery restarts every waiting device's seven days). A 0.11 row
is a fallback: its links stay until that master's first roster replaces them.

**Our own roster at start** (`swarm.rs` startup, where the own list is loaded today):
import a bootstrap file; with no roster, a device named by its own 0.11 list signs a legacy
claim, its consent and a removal for every id the old list revoked; a device the old list
does not name, or one missing from the roster, publishes a pending join; a removed device
reports its removal.

**Ingest** (`ingest_device_list` and `ingest_sibling_device_list` merge into one
`ingest_roster`): verify, merge under the pin, stamp first sight of pending joins, fold
before and after; the resolver holds members only; newly removed members are enforced
(Olm sessions, MLS leaves, recorded marks); a sender is attributed to a master only when it
is a member of the merged roster; a roster for an unknown master is stored only when its
deliverer is a member of it. Our own master: our removal emits `DeviceRemoved`, a new
pending device emits `PendingDeviceAsking`, a restored membership emits `DeviceRestored`.

**The sibling proof goes.** `SiblingProveRequest`/`Response`, the challenge table and
`merge_sibling_device_id` are deleted: an inbox peer is our sibling when our roster says
it is a member, never because it holds the master key. `on_verified_sibling` runs for
members only.

**Membership checks that used "holds the master key":** `classify_leaf` callers (MLS
attribution, KeyPackage arms, commit/Welcome judges, the sibling re-add at
`swarm.rs:11116`), `verify_carried_bundle` (the carried roster merged with ours),
`key_exchange_device_unauthorized` (unchanged: it reads the resolver, which now holds
members only), destroy orders.

**Removal, pending, recovery (Rust).** `revoke_own_device` signs a removal (keeping the
removed device's vouched members); reset = a removal of every other member; scope (b) = a
self-removal, then the local wipe. `SelfRevoked` becomes `DeviceRemoved { by, wipe_at }`;
the node keeps running locked. New FFI: `roster_status`, `approve_device`, `refuse_device`,
`recover_with_phrase(phrase, keep)`, `destroy_everywhere(phrase, notify)`,
`confirm_stored_phrase` (the one-time upgrade), `stored_phrase_for_upgrade`.

**Destroy.** `DestroyIdentity` gains the phrase signature (payload `hollow-destroy2:`) or a
device-signed order carrying a phrase-signed permission for that device
(`hollow-id1-destroy-delegate`). `judge_own_order` and `apply_friend_order` check it
against the pinned recovery key; a legacy identity keeps the master-signed order until its
first recovery. The duress slot grows by the permission (dummy the same size).

**Backups and snapshots.** `build_snapshot_bytes` exports a scrubbed copy of the database:
no `recovery_mnemonic`, no Olm account or sessions, no MLS identity. Every import also
clears them, so every restored device mints its own.

**Link (section 6), as built.** `node/link_pake.rs` (new): `split_code`, SPAKE2 Ed25519
with the identities `hollow-link1:{rv}:joiner|presenter`, the HKDF keys, the presenter's
HMAC confirm (constant-time), the sealed `LinkInner {Hello, Offer}`. `node/link_handler.rs`
(rewritten): `LinkState` lives in the event loop's locals; claim, release, resolve, the
handshake arms (`LinkPake`, `LinkPakeReply`, `LinkSealed`, all Relay lane, live-only),
accept and decline. `LinkSnapshotRequest`, the empty-key `LinkSnapshotKey`,
`RequestLinkSnapshot` and the mnemonic auto-request are deleted. `api/network.rs`:
`claim_link_code(rendezvous, secret)`, `resolve_link_code(code, label, platform)`.
`file_handler.rs` `LinkSnapshotState { passphrase, sender, device }` (zeroized).
`api/storage.rs`: `stash_pending_link` also writes `pending_link.device`;
`import_pending_link` refuses a stash with no usable device key and installs it.
`api/wipe.rs` `KEY_FILES` gains both stash files. The mock relay learns link codes.

**Dart.** Welcome shows the phrase once and asks for a few words back; the upgrade screen
(stored phrase shown once, typed back, then erased; "Later" allowed); Devices page (members,
pending with Approve/Refuse, "Remove devices with your recovery phrase"); the removed-device
lock route (reuses `lock_cover.dart`'s shape) with its countdown, "Use recovery phrase",
"Erase now"; the pending screen; the link dialog's ten-character code and the requester's
name and platform on "Add this device?"; remote destroy and the duress "everywhere" scope
ask for the phrase; Settings' Reveal becomes "Check your recovery phrase".

## 7a. Rules the build forced (sessions 21 and 22)

The harness and the on-screen pass each found a gap in the design above; each rule is
now code and a test.

- **A phrase change rides in the clear.** Contacts holding a device as removed dropped
  its Olm session and refuse its key exchange, so a recovered device could reach nobody.
  `announce_phrase_change` fans the roster out as a `RosterNotice` (own mailbox, every
  friend's DM room, every server room), and a `RosterNotice` is not gated on its sender.
- **Asks go to the DM room, not to devices.** `resolver::devices_for` is empty for a
  single-device identity (device id = master id), so a pending ask sent to its devices
  started nobody's clock. `fan_out` broadcasts into each friend's DM room.
- **Maturity is judged against what was saved.** Folding the old and the new roster at
  the same "now" hides a pending join that matured with time; the ingest compares with
  the saved `device_links`, so a matured device is "added" and warns its contacts.
- **The roster FFI never creates an identity.** Home renders behind Welcome and asked
  for the roster; `load_or_create_identity` then minted a key and Welcome never showed on
  a fresh install. `api/roster.rs` loads an existing identity only.
- **The UI hears when start-up settles our roster.** The shell reads the gate before the
  node asks to join, so a restored device showed no lock until a restart; start-up
  emits `DeviceListUpdated` for our master and the gate re-reads on it.
- **Nothing routes above the app lock.** The roster lock, the join ask and the phrase
  upgrade (which shows the stored phrase) wait until the app lock's cover lifts.
- **A join ask is about a device that still waits.** One settled meanwhile (approved
  elsewhere, or joined with the phrase) is dropped unseen, and an open one closes: its
  Refuse would remove a member.

## 8. Tests

- Unit: every statement's payload and signature (wrong tag, wrong master, wrong base,
  no consent), the fold matrix (roots, vouch closure, removals in both directions,
  keep_vouched, void vouches, pending maturity by first-seen, recovery supersedes,
  phrase admission after a recovery, R pin), R derivation KAT, SPAKE2 channel.
- Harness (hostile, signed correctly as the wrong principal):
  - a node holding only the master key (a stolen backup) is never a member: no DM
    fan-out, no MLS leaf, no Olm-carried authority, no destroy, until approved;
  - a stolen member device removes the owner's devices, the owner recovers with the
    phrase, and the thief's device and everything it vouched stop counting everywhere;
  - a foreign roster naming our device, or another identity's master, binds nothing;
  - a pending join is refused by one current device, and matures after seven days at
    an observer that saw nobody object;
  - a removed device locks, and a recovery that keeps it unlocks it;
  - a destroy order signed by M alone is refused;
  - the relay records every frame of a link and cannot open the snapshot.
- Mutation pass over every new rule.

**As built:** harness `authz_a_stolen_backup_is_never_a_member_until_approved`,
`authz_the_phrase_takes_the_identity_back_from_a_stolen_device`,
`authz_a_destroy_order_needs_the_phrase`,
`a_restored_device_matures_at_a_contact_after_seven_quiet_days`,
`a_restored_device_tells_its_ui_once_it_waits`, `link_the_relay_cannot_open_the_snapshot`,
`authz_a_relay_that_answers_the_code_gets_one_guess`,
`authz_link_frames_from_a_stranger_are_refused`; units in `identity/roster.rs`,
`identity/recovery.rs`, `node/roster_book.rs`, `node/link_pake.rs`
(`every_layer_binds_on_its_own`), `api/storage.rs`
(`snapshots_leave_device_secrets_behind_both_ways`,
`a_pending_link_installs_the_device_key_it_was_made_for`), `api/roster.rs`
(`a_roster_read_never_mints_an_identity`); widget `recovery_phrase_dialogs_test`,
`pending_device_dialog_test`, `hollow_dialog_busy_test`. Mutation pass: 22/22 roster
rules and 9/9 link rules killed (session 21), plus each session-22 fix killed alone.
Seen on screen on throwaway fleet peers (session 22): link end to end, removal and the
phrase lifting it, the app lock before the roster lock, a restored backup waiting,
joining with the phrase, refused, and erased.

## 9. Decisions (Vitalik, 2026-09-30)

1. **The phrase is no longer stored.** New identities see it once and type a few words
   back. Existing users, at their first 0.12 start, see the stored phrase one last time,
   type it back, and it signs the identity's first recovery and is erased. "Later" is
   allowed: the identity stays legacy with a Needs-attention reminder.
2. **The relay's inbox check** is its own item, ID-1R, next session (plan STATE OF PLAY).
3. **The duress "everywhere" scope stays** through a phrase-signed permission for that one
   device, stored inside the duress slot; it dies when the device is removed.
4. **(2026-10-02, ID-1R) The seven-day wait stays the default, and the phrase can turn it
   off** (`no_wait` in the recovery statement; Settings > Security > Advanced). The relay
   counts the seven days too.

Mine, recorded: the ten-character code with the relay unchanged; SPAKE2 from RustCrypto;
the mnemonic link path deleted rather than fixed (nothing reaches it); roster removals as a
plain union (a stolen phone can force the phrase, never win against it).

## 10. Residuals

- **Legacy identities** none of whose devices kept the 0.11 phrase, until the phrase is
  typed: the master key still admits a device (a legacy claim), as before 0.12.
- **First contact with a thief ahead:** someone who meets the identity for the first time
  after a master-key holder published a forged recovery key pins the forged one. Everyone
  who already knew the identity keeps the real one, and the owner's devices see the
  conflict.
- **A phrase holder is the identity.** Whoever else learns the phrase can recover too; the
  newest recovery wins, and so does whoever types it last.
- **The inbox** (closed by ID-1R, HOL-SEC-078) keeps one residual: after the relay box
  reboots, the first roster shown sets the identity's recovery key at that relay.
- **Author time (AR-11)** is untouched: device co-signatures order device statements, not
  server ops.
