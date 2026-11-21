# Restore from the recovery phrase on Welcome (0.14.3)

Status: DESIGN revision 2 (the one fix round after hostile review 1, `.team/DESIGN_REVIEW_1.md`),
with Vitalik's decisions of Nov 21. Ready to build test-first. GitHub #155. Base `main`
f6376c44, worktree `~/dev/wt/phrase-restore`. No product code changed. Line numbers are of
f6376c44. EMBARGOED: HOL-SEC-216, 217 and 218 are shipped flaws (section 9); keep this doc
and their finding files off any public branch until 0.14.3 ships.

## 0. Decisions in one screen

1. **Welcome asks ONE question before the phrase: "Could someone else have your old
   device?"** (Vitalik, Nov 21.)
   - **No** (it broke, or it was wiped): a phrase ADMISSION. The new install is admitted by
     the phrase (`hollow-id1-radmit`); every other device keeps counting.
   - **Yes, or I'm not sure**: a phrase RECOVERY with "When did you last have it?", the
     DEVICE_PROOF 8.1/8.4/8.7 path 0.14 built and tested: a new base keeping only this
     install, every other device dropped as lost or stolen since T, owned servers restored
     from member witnesses, the existing restore chooser.
2. **Three shipped flaws are fixed in the same patch** (section 9): HOL-SEC-216 (a removal or
   recovery from a device that held nothing before T rolls back pre-T history; the No branch
   walks straight into it, review D1), HOL-SEC-217 (a restore beside this identity's own
   database speaks with the old device's Olm account; fix = keep the counted old device when
   its key still opens, else a fresh device with the old device's secrets scrubbed; also
   fixes D4), HOL-SEC-218 (an admission dated before the current base counts nowhere; fix =
   date it past every held statement, and a "type the phrase again" lock when the fold drops
   it). HOL-SEC-215 (this design's own: no alert for a phrase-admitted device) is fixed too.
3. **The restore signs into the database directly** (no bootstrap file on this path): after
   the key lands, the FFI opens the store with the master-derived key and calls the SAME
   functions the in-app paths call (`roster_book::admit_by_phrase`; `roster_book::recover` +
   `note_recovery_lost_since`; both inside `settle_owed::TypedChange`). That brings the
   phrase-time stamping (218), the owed settling over a kept database (216) and the held
   `no_wait` with no new code paths.
4. **Typo protection (D2, section 6):** a kept-folder check before landing ("these words
   don't open the earlier data here"), and a "Type my phrase again" retry on the Home card
   that SETS ASIDE the mistaken identity (a relink-shaped move into `<root>-old-<day>`,
   marked as a set-aside) instead of destroying it, offered only while it has no accepted
   friend and belongs to no server.
5. **Servers come back** in the No branch through the existing fresh-install path, whose local
   gate `shared_servers::recovering()` gains a second branch: a Welcome admission into an
   EMPTY database, for 30 days, while our own fold counts this device (D3:
   `state.is_member`). The Yes branch needs no new gate (it is a recovery).
6. **No new wire variant, no relay change, no KAT change.** One local behaviour change on the
   answering side (D7: the friend-accept re-send is keyed per requesting DEVICE); older friends
   get an honest line on the Home card.
7. **Keychain default** after the full phrase on the Windows and macOS OS data root, except
   where a `.locked` pair still needs the profile's keychain slot (then the one-time offer).
8. **The phrase never comes back out of Rust**: the restore FFI returns no mnemonic, Dart
   drops the typed text once the call returns.

## 1. The two branches end to end

### 1.1 Shared start (Dart)

1. Welcome, after Terms, under "Already use Hollow?": rows Link a device, Restore from a
   backup, NEW Use your recovery phrase (`LucideIcons.keyRound`). The comment at
   `welcome_dialog.dart:384-387` goes (the roster admits the device, sync brings data back, a
   foreign database is kept aside).
2. `_phraseStep` inside `WelcomeFrame` (shape of `_restoreStep`, `:537`), the whole step inside
   `SecretScreen` (FLAG_SECURE, iOS cover, HOL-SEC-158):
   - the question "Could someone else have your old device?" as two `HollowListRow` options,
     nothing preselected, Restore disabled until one is picked;
   - Yes only: "When did you last have it?" with the existing `LastHadPicker` and
     `askLostSince` (`device_management_shared.dart:91-140`; T = the EARLIEST moment of the
     answer; "Longer ago, or not sure" = 0);
   - the field (`RecoveryPhraseField`: letters only, `visiblePassword`, no suggestions);
   - the branch's text, ghost Back, filled Restore.
3. Restore runs in the step (`runDialogAction`, errors on the field, text kept). One FFI,
   `welcome_restore(phrase, mode, check_kept) -> RestoreOutcome` (1.2), first with
   `check_kept = true`. A `KeptMatch` or `KeptNoneOpens` outcome lands nothing and shows its
   dialog (6.1); the person's choice calls again with `check_kept = false`, or switches
   profile.
4. On `Restored`: keychain default where eligible (2.3), clear the controller, pop
   `'restored_phrase'` with the branch. Shell: load (no mnemonic, so no phrase dialog), set
   the lock offer due when not locked, start. Yes branch: `askForRestoreChooser(container,
   fresh: true)` once the node runs (the roster lock's path today, `roster_lock.dart:96-117`).

### 1.2 Rust order inside `welcome_restore` (both branches)

1. Normalize (lowercase, single spaces); exactly 24 words; parse with per-word errors
   (`bip39::Error::UnknownWord(i)`, checksum, count). The 24-word check lives in the shared
   `identity/keys.rs::restore_identity_from_mnemonic`, so the in-app restores
   (`key_missing_dialog.dart:250`, `hollow_shell.dart:867/898/1107`) refuse a 12-word wallet
   phrase too.
2. `refuse_while_not_ready()` (D6: BEFORE the kept-folder probe).
3. `check_kept`: the read-only kept-folder check (6.1). Returns without landing anything.
4. `finish_wipe_before_a_new_identity` (existing; refuse if held).
5. A stale `identity.duress` with no `identity.key`: zeroed, then removed (as
   `a_landing_drops_the_old_duress_slot`, `storage.rs:5683`).
6. `land_identity_key(root, master, None, true)` (existing: a foreign database kept aside,
   this identity's own kept database put back, an encrypted key pair set aside as `.locked`).
7. Open the store (`MessageStore::open` with `derive_db_key_public`; an empty one is created
   when none is there). `held` = `roster_book::load(store, master)` merged with any unconsumed
   `roster_bootstrap.json` of this master (as `ensure_own` would merge it). `empty = held is
   None`.
8. The device (HOL-SEC-217, D4; 9.2): KEEP the old device or MINT one. A minted keypair stays
   in memory; the old device's secrets are scrubbed first, its statements are signed next,
   and `identity.device` is written LAST.
9. Sign, inside `settle_owed::TypedChange::begin(store, master, ..)`:
   - No: `admit_by_phrase(master, recovery, device, ..)`, skipped when the device was KEPT (it
     is already counted). Stamped by `phrase_time` = max(now, newest held recovery or
     admission + 1) (HOL-SEC-218).
   - Yes: `recover(master, recovery, device, keep = [], no_wait, ..)`, `no_wait` = the held
     state's, else per open question 1; then `note_recovery_lost_since(store, new_base, T)`.
     Stamped by `phrase_time` too. On an empty store `change_own` starts from
     `Roster::new(master)`; if it does not today, the builder makes it so (test
     `welcome_recovery_into_an_empty_store_signs_a_base_keeping_only_this_device`).
   - `TypedChange::landed` notes the owed settling exactly as `api::roster::changed` does, so
     a kept database's servers held before T settle at the first start
     (`settle_owed::settle_at_start`) and the rest go to the witness desk.
10. Write `welcome_restore = {at_ms, branch, empty, device}` (`app_settings`, this device's
    own; added to `scrub_device_secrets` so no copy carries it) when a device was MINTED. The
    Home card, R2 and the set-aside gate read it.
11. Return `IdentityInfo { mnemonic: None, .. }`. The recovery keypair and seed are
    `Zeroizing` and dropped here.

A crash between steps 8 and 11 leaves either the old device on a fresh Olm account, or a
device the roster does not count, which the roster lock asks to join with the phrase. It
never leaves a new device on the old device's secrets.

### 1.3 No: the admission

| Who | Sees | Via |
|---|---|---|
| This install (F) | Home "Finish restoring" card (No version); no 215 alert about itself | `welcome_restore` mark |
| Our old device, if it ever runs again | Stays a member. Alert "A device was added with your recovery phrase" (HOL-SEC-215); sibling sync brings F everything it holds | `own_room` roster trade, R3 |
| A friend | "New device" warning (R-ID-08) for a verified contact; answers F's re-add at once (already-accepted arm); serves DM history and `SharedServers` once its view counts F | `FriendRequest` carries F's roster |
| A co-member | F placed in our identity; the `already_member` re-entry admits nobody new | `RosterNotice`, the join box's `asker_roster` (8.7 steps 3-4) |
| The relay (ID-1R) | F counted; inbox owners = F and the old device | `show_relay` on connect |

F signs `hollow-id1-join` (its consent) and `hollow-id1-radmit` (R and M over
`{master}:{r_pub}:{at_ms}:{device}`). Nothing else. The old device keeps counting until the
person removes it (Settings, Devices) or recovers.

### 1.4 Yes: the recovery

| Who | Sees | Via |
|---|---|---|
| This install (F) | Home card (Yes version); the restore chooser per owned server ("Checking with members of {server}", points, "I don't know"); "Hollow doesn't know your servers yet" until a friend or invite names one | existing 8.4/8.7 UI |
| Our old device, if it runs | Not counted. Roster lock with the CHANGED copy "Your recovery phrase was used on another device" (D3b); its button admits it again without dropping F | `RosterStatus.dropped_by_recovery` |
| A thief holding the old device | Same lock. It can ask to join (pending); per open question 1 it then joins only if F approves. It no longer owns our inbox or (track R) writes lock links | existing ID-1, track R |
| A friend | "New device" warning for F; sessions to the old device retire (`enforce_device_revocations` on the roster ingest); answers F's re-add | existing |
| A co-member | F placed; on servers we own whose checkpoints only the old device wrote, the floor marks hold (8.8) and the member banner shows only if the server steps back; answers F's witness asks | 8.4, 8.8 |
| The relay | F alone counted; F alone owns `inbox:{master}` | fold of the new base |

F signs its consent and a recovery `hollow-id1-recover` keeping `[F]` (with `:nowait` per open
question 1). T stays local (`recovery_lost_since:{base}`), never signed.

Yes never keeps the old device's key, even when it opens here: "someone else may have it"
covers a copy of this folder, so the recovery always keeps a freshly minted device.

## 2. What is already on the machine

Welcome shows only when `has_identity()` is false (`api/storage.rs:1627`).

| Leftover | Handling | Status |
|---|---|---|
| Pending wipe marker | `finish_wipe_before_a_new_identity` first, refuse if held (`storage.rs:2841`) | exists |
| A landing, a relink, a destroy in this process | `refuse_while_not_ready` (`storage.rs:2823`), now step 2, before any probe (D6) | exists, moved first |
| Another identity's `messages.db` | kept aside as `messages.db.unreadable-*` (`keep_aside_a_database_this_identity_cannot_open`, from `land_staged_key`, `keys.rs:208`) | exists |
| This identity's kept `messages.db.unreadable-*` | put back with its key (`keys.rs:222`) | exists |
| This identity's `messages.db` in the root (key file gone) | No: KEEP the old device when it opens and is counted; else a fresh device and the old device's secrets scrubbed (9.2) | NEW (217, D4) |
| `<root>-old-*` relink or set-aside folders | read-only probe under the phrase's db key: a match offers "Switch to it" (desktop); kept data that does not open warns before landing (all platforms) | NEW (W5, D2) |
| `identity.duress` with no `identity.key` | zeroed and removed before the key lands | NEW, hygiene |
| `identity.key.locked` / `.device.locked` | kept; the keychain default skips this profile so its slot stays (2.3) | NEW guard |
| `pending_link.*` | imported or dropped before Welcome; restore refuses while a landing runs | exists |
| App Lock entries, push registration | cleared when Welcome shows (`clearTracesOfAGoneIdentity`, `destroy_flow.dart:80`) | exists |
| `files/` of a gone identity | orphaned HFE1 files; unreadable to the new identity | exists; cleanup deferred |

### 2.3 Keychain after restore

The person typed all 24 words, which `protect_new_identity_by_default` checks again
(`phrase_is_this_identitys`, `api/identity.rs:1419`). Run it in the step right after
`Restored` (key files only), then clear the field; the toast is
`applyDefaultKeychainProtection`'s (`keychain_protection_dialogs.dart:63`). NEW guard: when
`identity.key.locked` or `identity.device.locked` exists, the default does NOT run:
`switch_to_keychain` (`:1158`) writes a fresh key into the profile's slot (`store_key_at`),
the only key the `.locked` pair opens with. The shell sets `kProtectionOfferDueKey` instead, as
where the default does not apply (phones, Linux, portable, data-dir override); the offer is
`lib/src/ui/dialogs/protection_prompt.dart:28` (C-IDENTITY-15: after the roster gate and the app
lock). The Settings switch over a `.locked` pair keeps today's behaviour (section 13, item 3).

## 3. What comes back, and how

| Item | No (admission) | Yes (recovery) |
|---|---|---|
| Friendship | re-add; the friend's already-accepted arm answers at once (`swarm.rs:14682`) and lands on our outgoing row (HOL-SEC-036); D7 fix for the replay gap (10.1) | same |
| Olm sessions, safety number | new device-signed exchange; safety number unchanged; "new device" warning | same |
| DM history | DM room, `dm_sync_anchor` + gap digest from an empty store | same |
| Servers a re-added friend shares | `SharedServers` answer to a counted device, `start_reentry`, `already_member` arm; needs the R2 gate | existing `recovering()` gate |
| Owned servers | as a member: re-entry; the old device still counts, nothing to settle | witness restore from T (8.4), chooser |
| Servers no friend shares, or on another relay | invite link from a member. An entry on another relay, or one no member answered in 90 s, waits silently and is asked again at the next start (`held_shares` UI deferred) | same |
| MLS | leafless walk by standing, KeyPackage + Welcome | same |
| Channel history, files | members, gated by `channel_readable_by`; files pulled on view | same |
| Own profile | starts empty; the first edit overwrites (deferred) | same |
| Blocks, settings, duress code, push prefs | start fresh (said on screen) | same |
| With a surviving device | sibling sync brings everything | the survivor is dropped: it joins again (lock), then syncs |

**R2 (decision 5).** `recovering()` (`shared_servers.rs:158`) = today's test OR (the
`welcome_restore` mark holds `branch = admit`, `empty = true`, `device = this device`, AND
`now - at_ms < RECOVERY_WINDOW_MS`, AND our own fold says `state.is_member(this device)`). D3:
a removal never drops the admission statement, so the gate reads membership, not the
statement. `restore_flow::register` stays keyed on a RECOVERY (or, after 9.1, on a lost
removal's `lost_restore` rows): an admission dropped nobody. The re-entry admits nobody new
(`review_c2_a_join_answer_serves_no_device_the_view_does_not_count`).

## 4. Abuse and failure

- **Typos.** BIP-39 English list plus checksum (8 bits for 24 words). A non-word or a wrong
  count is refused with its position or count. A checksum-valid wrong phrase (about 1 in 256
  single-word swaps) is a DIFFERENT, empty identity. Signals: kept data here that does not open
  (6.1, before landing); a friend who gets a fresh request instead of accepting (Home card);
  then the set-aside retry (6.2).
- **Duress.** At Welcome no identity and no slot exist; a stale slot goes (step 5). The phrase
  never passes `withTypedSecret`. A set-aside moves the identity's duress slot with its key
  files (6.2).
- **Wrong branch.** No while a thief has the device: the admission case; the old device keeps
  counting until removed, gets the 215 alert (harmless to a thief), and the Home card says to
  remove it if someone else might have it. Yes while the old device was only broken: the old
  device, if revived, sees the lock and joins again by phrase or by F's approval.
- **Thief with the phrase.** The phrase already IS the identity: `recover_with_phrase` from any
  install, the in-app phrase dialogs, or their own build. Welcome removes a detour only.
  Residual as documented (ID-1 section 10).
- **Phone vs desktop.** Same FFI. "Switch to it" is desktop only (phones have no profiles); the
  kept-data warning runs everywhere. iPhone and store Android: re-entered 18+ servers stay
  hidden until a computer allows them (`age_gate::unsettle_at` in `start_reentry`).
- **Clocks.** Admissions and recoveries are stamped on this device's clock (a peer judges them;
  NEVER the relay clock). A clock behind: 9.3. A clock more than 10 minutes ahead: every
  observer drops the statement as future-dated until real time catches up; the existing clock
  banner (warn past 60 s, urgent past 240 s, HOL-SEC-018) is up from the first connect, and the
  9.3 lock covers the moment the fold drops us. Nothing can tell before the network.
- **Rate limits.** None local (256-bit secret, no oracle). Remote steps reuse existing bounds:
  friend-request caps (HOL-SEC-192), `SharedServers` once per asking device per 10 min,
  re-entries 4 per tick, 64 servers, witness asks 64 identities per server.
- **Lost device's push token.** A lost phone keeps getting sealed wakes until removed (No) or
  dropped (Yes).

## 5. UX

All copy is in section 11.

- **Welcome row** as 1.1. Row order Link, Backup, Phrase (review Q5).
- **The step**: question, then (Yes) the time, then the field and the branch text. On a phone
  the step scrolls inside `WelcomeFrame`'s bottom area; the options are full-width rows.
- **Kept data** dialogs (6.1): `showHollowConfirm`.
- **Home "Finish restoring" card** (`home_inbox.dart`), shown while the `welcome_restore`
  mark is within 30 days and the card was not dismissed; one version per branch; the
  wrong-phrase line carries the set-aside button only while 6.2's gate holds.
- **Roster lock** gains two body variants (9.3 "too early", D3b "dropped by a recovery"),
  buttons unchanged.
- **Alerts**: `ownDeviceAddedDetail` (`security_alerts_provider.dart:31`) splits the detail in
  two, so `{device}:phrase` parses with `by = "phrase"`; D2 renders that case with its own text.

## 6. Typo protection (D2)

### 6.1 Before landing: the kept-folder check

`check_kept = true` (1.2 step 3), after `refuse_while_not_ready`:

1. `recovery::kept_aside(root)` (`recovery.rs:821`: `<root>-old-*` folders whose origin mark
   names this root, no profile running in them).
2. For each folder holding `messages.db`, in name order, at most 16:
   `probe(db, phrase_db_key, read_only = true)` (`recovery.rs:121`; never creates or writes).
3. Any `Opens` -> `KeptMatch { path, profile_name }`. Desktop shows "Your data is still here":
   Switch to it = `keepOldDataProfile` then `switchProfileAndRestart(path)`; Restore here
   anyway = call again with `check_kept = false`. Phones skip the dialog and restore (nothing
   to switch to; the folder stays for a destroy).
4. None opens, and at least one folder NOT marked as a set-aside (6.2) holds `identity.key` ->
   `KeptNoneOpens`: "Check your recovery phrase" with Check the words (filled; back to the
   field, text kept) and Restore anyway (ghost). A set-aside folder never raises it.
5. Otherwise land.

### 6.2 After landing: set aside instead of destroy

**Gate** (FFI `may_set_aside_this_identity() -> bool`; checked again inside the setter): the
`welcome_restore` mark exists and is within 30 days, AND no friend row is `accepted`, AND the
store holds no server (no server state, no pending join). Once a friend accepted or a server
holds us, someone else knows this identity: the retry is gone and only Settings' existing
erase remains.

**What "set aside" does on disk** (FFI `set_aside_this_identity()`; Dart then `relaunchApp()`,
a phone closes):

1. While the store is open: re-check the gate, `refuse_while_not_ready()`, then write
   `set_aside.pending` in the root holding the SHA-256 of `identity.key`'s bytes (the
   `mark_link_throwaway` shape, R-ID-10). Nothing moves while this process runs.
2. Next launch, in the start-up step that runs `settle_relink` and the link-throwaway check,
   BEFORE anything reads the identity: `settle_set_aside_at(root)`. When the mark's digest
   equals `identity.key`'s, no wipe is queued and `not_ready` is clear, it runs `relink_at(root,
   now)` (`recovery.rs:548`) with the origin mark extended to `Origin { root,
   #[serde(default)] set_aside: bool }` set true, and writes `set_aside_welcome` instead of
   `relink_welcome`. A digest that does not match drops the mark and moves nothing. The mark
   goes once the relink commits. `set_aside.pending` and `set_aside_welcome` join
   `stays_on_relink` (`recovery.rs:67`) so the move never carries them.
3. `relink_at` moves every root entry that is not `stays_on_relink` into `<root>-old-<day>`:
   the database, `identity.key`, `identity.device`, `identity.duress` and every other
   `identity.*`, the push seal key, the bootstrap. The identity's keychain key goes to that
   folder's own slot first (`keep_key_at`; HOL-SEC-187's group-named calls on macOS). The root
   keeps `profiles.json`, locks, logs and marks, and is at Welcome with no duress slot and a
   free keychain slot.
4. Welcome opens on the phrase step with "The identity those words made is set aside" (reads
   and clears `set_aside_welcome`). The folder is NOT listed as a profile.

**Interactions.**
- `zero_kept_aside` and destroy (`recovery.rs:883`): the set-aside folder is this root's kept
  data, so a later destroy or duress wipe of whatever identity runs here erases it with the
  rest, keys zeroed first (unchanged rule: kept data goes with the identity). The retry itself
  never destroys anything, so the real identity's relinked data survives a typo (the #155 trap
  of D2).
- Kept-data profiles: a folder a profile runs in is `in_use` and never kept aside; the
  set-aside folder stays unlisted until its phrase is typed again and the person picks Switch
  to it (desktop), which lists and runs it.
- Duress slot: moves with the identity (an `identity.*` file), so it can neither wipe the next
  identity nor stay behind; R1's stale-slot drop stays as the belt.
- The typo identity's friend requests stay at the friends as requests from a stranger until
  declined or expired (24 h relay buffer); nothing else of it exists anywhere.
- Each set-aside makes a new `-old-<day>[-n]` folder; the probe caps at 16.

## 7. Scope for 0.14.3

**Build (one builder-secure track, Rust first, then Dart):**

| Id | Change | Where |
|---|---|---|
| S216 | HOL-SEC-216 fix (9.1) | `sync_handler.rs` (`settle_lost_devices`, `merge_rival_settlings`), `restore_flow.rs`, `swarm.rs` RevokeDevice + RosterChanged arms, `settle_owed.rs` |
| S217 | HOL-SEC-217 + D4 (9.2): keep-or-mint, `MessageStore::forget_device_secrets` | `identity/keys.rs`, `storage/messages.rs` |
| S218 | HOL-SEC-218 (9.3): phrase-time stamping in the restore; `RosterStatus.too_early`; lock copy | `identity/keys.rs`, `api/roster.rs`, `roster_lock.dart`, `roster_provider.dart` |
| R1 | `welcome_restore(phrase, mode, check_kept)` (1.2); 24 words in the shared restore; per-word errors; no mnemonic; stale duress; `welcome_restore` mark | `api/identity.rs`, `identity/keys.rs` |
| R2 | `recovering()` second branch gated on `is_member` (D3); FFI `welcome_restore_state()` for the card | `shared_servers.rs`, `api/roster.rs` |
| R3 | HOL-SEC-215 alert (8.1) | `roster_book.rs`, `security_alerts.rs` |
| R4 | kept-folder check and warning (6.1) | `api/recovery.rs` |
| R5 | set-aside (6.2): gate, mark, launch step, `Origin.set_aside` | `api/identity.rs`, `api/recovery.rs`, the start-up in `hollow_shell.dart` |
| R6 | D7: the accept re-send keyed per requesting device (10.1) | `swarm.rs` ~14684 and the decline arm |
| D1 | Welcome row and question step, `'restored_phrase'`; keychain default with the `.locked` guard; lock offer due; delete dead `IdentityNotifier.restoreFromMnemonic` (`identity_provider.dart:68`) and the stale `'restored_mnemonic'` comment (`hollow_shell.dart:1225`); `RecoveryPhraseField` hint says 24 words | `welcome_dialog.dart`, `hollow_shell.dart`, `identity_provider.dart`, `recovery_phrase_dialogs.dart` |
| D2 | Home card per branch with the set-aside retry; alert text for `{device}:phrase` | `home_inbox.dart`, alerts UI |
| D3b | roster lock body for a device a recovery left out (`RosterStatus.dropped_by_recovery`) | `api/roster.rs`, `roster_lock.dart`; copy only, can slip to 0.14.4 without risk |

FRB codegen: yes (R1, R2, R4, R5, S218, D3b). No new crate. No relay, no KAT, no wire variant.
Persisted: `app_settings` keys `welcome_restore`, `lost_restore:{server}`; root files
`set_aside.pending`, `set_aside_welcome`; `Origin.set_aside` with `#[serde(default)]`.
Gate row: wiki `security_write_gates` new section 80 (the restore's store writes, the
`welcome_restore` mark and its `recovering()` reach, `lost_restore` rows, the set-aside move,
the 215 alert).

**Deferred (after 0.14.3), with why:**
- `held_shares` UI (dead code since C2): needs a new screen and the one-dialog relay-switch
  rules (`relay_switch_dialog`, never auto-switch). The Home card names the case instead.
- Our own profile fetched back from a holder (signed `hollow-profile2`, verifiable): a new
  ask/answer pair, a wire change.
- Blocks back (only a sibling holds them): a new sync path.
- Cleaning orphaned `files/`: a whole-store sweep with its own review.
- A relay "does this identity exist" query for typo detection: a new wire op that tells the
  relay who is restoring; the kept-folder check and the friend signal cover most typos.
- A member-server DR for a remover that held nothing before T (9.1 residual): member-server
  witnesses are a protocol addition.
- The Settings keychain switch over a `.locked` pair (section 13, item 3).

**Compatibility.** 0.14.x friends answer re-adds and `SharedServers`; 0.14.x members answer
`already_member` re-entries, the leafless walk and witness asks; the deployed relay folds phrase
admissions and recoveries since 0.12. A 0.14.3 device restoring meets a 0.14.0 world with no
change on their side. The D7 fix helps only when the FRIEND runs 0.14.3 (10.1 says what an
older friend does).

## 8. HOL-SEC-215 (Low, this design's own)

### 8.1 Fix R3

`vouched_by_a_sibling` (`roster_book.rs:1590-1617`) becomes `added_by_another`: besides vouched
devices, a device newly a member since `prev` whose root in the new base is a phrase admission
or a recovery's `keep`, that is not this device, never an upgrade admission, never before this
device was a member (`prev.is_member(local)`). Detail `{device}:phrase`. Requirement row
R-ID-14 (10.3). Finding file `HOL-SEC-215.md`.

## 9. The shipped flaws fixed with it

### 9.1 HOL-SEC-216 (Medium): settling from records that start after T

**Flaw.** `settle_lost_devices` (`sync_handler.rs:3053`) settles every held server from this
device's own records (`restore_for(T)`, `op_seen_ms`) without checking that this device held it
before T. A device that first held a server after T (a phrase-admitted F, a sibling linked
after T, a server re-entered after T) has no restore point before T, so an owned server settles
back to the founding op and a member server gets a DR with no kept ops and no `restore`: what
the lost device did before T (owner renames, channels, roles, admissions) stops counting. The
recovery path picks servers by `held_before(store, state, at)` against the recovery's time
(`restore_flow.rs:33-55`), not T, so a server first held between T and the recovery has the
same fault.

**Fix.**
1. `restore_flow::held_before(store, state, t)` is the one predicate: a first fold
   (`first_folds`) or a stored op (`op_first_seen_ms`) strictly before `t`.
2. `held_before_recovery` filters by `held_before(.., t_ms)` (T, not the recovery's `at`).
3. `settle_lost_devices` returns `Settled { done, to_restore }`. Per server, before any write,
   when `!held_before(store, state, state.lost_t(t_ms))`:
   - owned (`current_owner == us`): nothing written; `(sid, T)` into `to_restore`;
   - member only: nothing written (no DR from records that start after T);
   - one log line `[HOLLOW-CRDT] {sid} first held here after T: not settled from our records`.
4. The callers (RevokeDevice Lost arm `swarm.rs:1918`, RosterChanged arm `swarm.rs:2032`,
   `settle_owed::settle_at_start` `settle_owed.rs:208`) write each `to_restore` entry as the
   setting `lost_restore:{sid} = T` (the older T wins; never in a copy: added to
   `scrub_device_secrets` and `forget_device_secrets`).
5. `restore_flow::register` (`restore_flow.rs:59`) gains a second source: every
   `lost_restore:*` row of a server we own with no `done_key` -> `desk.recover(sid, T)`; its
   `held_before` test compares against T. The row goes when the restore writes `done_key`.
   Bounded by the servers we own.
6. `merge_rival_settlings` (`sync_handler.rs` ~3135) skips a server this device did not hold
   before the merged T (a sibling that held it merges).

**Residual (documented, not new):** on a member server first held after T, the dropped
device's ops that no checkpoint covers stop counting at members (the cut counts only counted
devices), as today's recovery does for servers it did not hold. Deferred (section 7).

**Tests** (10.4): the reviewer's harness probe ported, RED today,
`pr216_a_device_that_held_nothing_before_t_keeps_what_the_lost_device_did_before_t`; the
recovery branch `pr216_a_recovery_typed_on_a_device_that_joined_after_t_keeps_the_owners_history`;
the member branch `pr216_a_member_server_first_held_after_t_gets_no_retire_from_the_remover`;
`pr216_an_owned_server_first_held_after_t_goes_to_the_witnesses_and_survives_a_restart`; unit
`restore_flow::tests::held_before_judges_against_t_not_the_recovery` and
`sync_handler::tests::a_rival_merge_never_runs_on_a_server_held_only_after_t`. Controls that
stay green: `w3c1_a_lost_laptop_settles_back_to_what_it_did_before_t`,
`w3c1c_a_fresh_install_restores_from_what_members_folded_before_t`,
`w3c1r_a_lost_removal_stopped_before_its_settling_settles_at_the_next_start`.

### 9.2 HOL-SEC-217 (Low): a restore beside its own database speaks with the old device's Olm account

**Flaw.** `restore_identity_from_mnemonic` (`keys.rs:360-394`) keeps this identity's database and
mints a new device, but the database keeps `olm_account`, `olm_sessions`,
`olm_session_floors`, `olm_read_marks`, `live_frame_nonces` and the MLS rows. `OlmManager::load`
(`olm_manager.rs:220`) has no owner check; MLS re-mints a foreign credential
(`swarm.rs:1083-1117`), Olm does not. With the original device still running (a keychain-bound
copy restored through "Identity locked", `hollow_shell.dart:841-875`), both encrypt from the
same chains: message-key reuse the relay can see (AR-30 class) and shared one-time keys. D4
(same code): restoring over this identity's own database when only the key file was lost
overwrites `identity.device`, so the old device stays counted for good with no key anywhere.

**Fix** (in the shared restore, so the in-app paths get it too):
1. **KEEP** the old device when ALL hold: the mode is No (or an in-app restore);
   `identity.device` is in the root after the landing (an encrypted one was set aside as
   `.locked`, so this is a plaintext key) and decodes; its id is not the master (G1, R-ID-04);
   the held roster (1.2 step 7) folds it as a member (not removed, not pending); and the
   store's MLS identity, when present, carries a credential naming that device
   (`hl1:{device}:{master}:{sig}`, read as `classify_leaf` reads it). Then nothing is minted
   or signed, the Olm and MLS state stays (it IS this device's), and no `welcome_restore`
   mark is written: the device simply gets its master key back. No worse than today: a
   plaintext `identity.device` that opens already clones the device for whoever copies the
   folder, phrase or not.
2. Otherwise **MINT**: new keypair in memory; `MessageStore::forget_device_secrets()` (NEW,
   narrower than `scrub_device_secrets`, `messages.rs:5256`: `secure_delete`, then DELETE
   `olm_account`, `olm_sessions`, `olm_session_floors`, `olm_read_marks`, `live_frame_nonces`,
   `mls_identity`, `mls_storage`, `recovery_mnemonic`, `retire_held:*`, `settle_owed:*`,
   `lost_restore:*`, the per-device `age_gate_*` keys, `age_consent:*`, `image_verdicts`; it
   KEEPS the history, channel floors and clears, since this is the same database on the same
   machine; then `VACUUM`), BEFORE the new statements and the key file. Yes always mints.
3. Order: scrub, sign, write `identity.device` last (1.2).

**Tests:** RED today
`identity::keys::tests::a_restore_that_mints_a_device_beside_its_own_database_starts_a_fresh_olm_account`
(the reviewer's probe ported; also asserts the MLS rows, nonces and read marks are gone) and
`a_restore_over_a_lost_key_file_keeps_its_counted_device` (D4); guards
`a_restore_never_keeps_a_device_its_roster_does_not_count`,
`a_restore_never_keeps_the_master_as_its_device`,
`a_restore_never_keeps_a_device_the_databases_mls_credential_does_not_name`,
`a_recovery_restore_always_mints_a_device`, `forget_device_secrets_keeps_history_and_clears`.

### 9.3 HOL-SEC-218 (Low): an admission dated before the current base counts nowhere

**Flaw.** A phrase admission roots only when `at_ms > base.at` (`roster.rs:855`; the rule stays:
it is what lets a recovery cut off admissions older than itself). The restore dates the
admission `now_ms()` on the restoring machine (`keys.rs:384`). A clock behind, or a recovery
signed by a device a few minutes ahead (inside the 10-minute skew window), leaves the new
device a non-member at every contact and the relay while it looks like a member locally until
it learns the real roster; then the roster lock tells it, wrongly, that it was "restored from a
backup".

**Fix.**
1. The restore signs through `admit_by_phrase` / `recover` (1.2 step 9), which stamp
   `phrase_time` (`roster_book.rs:801`): max(now, newest held recovery or admission + 1). A
   restore beside a held roster can no longer date itself before it.
2. `RosterStatus` gains `too_early: Option<String>` (`"admit"` or `"recover"`): this device is
   not a member, and the roster holds a phrase admission naming it, or a recovery keeping it,
   dated at or before the current base. `RosterGate.fromStatus` maps it to a third kind; the
   lock says "Type your recovery phrase again" with the clock line, and its button runs
   `join_with_phrase` (admit) or `recover_with_phrase(keep: [], lost_since: the stored T)`
   (recover), both stamped by `phrase_time` after the base now held.
3. Never the relay clock (CLAUDE.md: anything a peer judges).

**Tests:** the reviewer's probe kept as a pinned guard of the rule
`identity::roster::tests::an_admission_dated_before_the_current_base_never_roots` (asserts NOT a
member); RED today `a_restore_beside_a_held_roster_dates_its_admission_after_its_newest_statement`
and `roster_status_says_too_early_for_an_admission_the_base_outdated`; harness
`pr218_a_restore_on_a_clock_behind_asks_for_the_phrase_again_and_then_counts` (F restored with
its clock 5 minutes behind a recovery; B trades F our roster; F's status says too early;
`join_with_phrase` on F; B and the relay count F); widget "the roster lock asks for the phrase
again when the admission came too early".

## 10. Rules, rows and tests

### 10.1 D7: the accept re-send

`answer_resent` (`swarm.rs:1220`, used at `:14684` and in the decline arm, cleared at `:4227`) is
keyed by requester MASTER, so the first replay of the lost device's buffered request on a socket
uses up the answer F's re-add needs. Fix R6: a map `(requester master, requester device) ->
highest requested_at answered`; an answer goes again when the pair is new or the `requested_at`
is strictly newer; cleared on disconnect as today; at most 4096 entries (only accepted or
declined friends reach it; at the cap it clears). Harness test, RED today:
`pr_an_accepted_friend_answers_the_new_device_after_a_replay_of_the_old_devices_request`.
Older friends (0.14.0 to 0.14.2): the gap needs a request from the lost device still inside the
relay's 24-hour buffer, and clears at the friend's first reconnect after that. The Home card
says "If a request still shows as sent, your friend gets it the next time they open Hollow."

### 10.2 Owner moderation (review Q4)

No new code (RESET_GRACE `lock_keeper.rs:665-683`; the relay takes a reset from any counted
owner device; `missing_grants` hands the change key to every counted owner device, the lost D
included). Harness `pr_a_phrase_restored_owner_still_moderates_its_server` asserts that F's
kick of C lands at B AND that D still holds a grant (an admission keeps D's lock power until D
is removed, which is why the No card says to remove it).

### 10.3 Requirement rows (drafts; they land in `requirements.md` with the build)

- **R-CR-12 (changed):** "A device restores a server it owns from member witnesses, never from
  its own records, when it first held that server at or after the moment the person last had
  the lost device: a fresh install after a recovery, and any device making a lost-or-stolen
  removal. The restore takes only a checkpoint two member identities folded before that
  moment, along one line; two lines are offered as ambiguous, never picked." Enforced in:
  `node/witness.rs` (`judge`), `node/restore_flow.rs` (`register`, `held_before`),
  `sync_handler::settle_lost_devices`. Proven by: today's list plus
  `pr216_a_device_that_held_nothing_before_t_keeps_what_the_lost_device_did_before_t`,
  `pr216_an_owned_server_first_held_after_t_goes_to_the_witnesses_and_survives_a_restart`,
  `held_before_judges_against_t_not_the_recovery`. Claims C-03, C-15.
- **R-ID-11 (changed):** append "A device that held a server only from the moment I last had the
  lost device, or later, settles nothing there from its own records and writes no retire for
  it." Enforced in: adds `sync_handler::settle_lost_devices`, `merge_rival_settlings`,
  `restore_flow::held_before_recovery`. Proven by: adds
  `pr216_a_recovery_typed_on_a_device_that_joined_after_t_keeps_the_owners_history`,
  `pr216_a_member_server_first_held_after_t_gets_no_retire_from_the_remover`,
  `a_rival_merge_never_runs_on_a_server_held_only_after_t`. Claims C-01, C-03.
- **R-ID-14 (new, 215):** "A device my phrase adds on another machine, by an admission or by a
  recovery keeping it, raises a warning on my other devices; the device itself and an upgrade
  admission raise none." Enforced in: `roster_book::added_by_another`, `security_alerts`.
  Proven by: `a_device_the_phrase_admits_alerts_our_other_devices`,
  `a_device_a_recovery_keeps_alerts_our_other_devices`,
  `the_device_the_phrase_admitted_alerts_nothing_about_itself`,
  `an_upgrade_admission_still_alerts_nothing`, harness
  `pr_the_phrase_alert_reaches_a_sibling_that_was_hidden`. Claims C-01.
- **R-ID-15 (new, 217):** "A phrase restore never speaks with another device's Olm or MLS state:
  it keeps the old device whole only when that device's key opens here, my roster counts it and
  the database's MLS credential names it; any other restore mints a device after dropping the
  old device's sessions, keys and nonces." Enforced in:
  `identity/keys.rs::restore_identity_from_mnemonic`, `MessageStore::forget_device_secrets`.
  Proven by: the 9.2 tests. Claims C-02.
- **R-ID-16 (new, 218):** "A phrase admission or recovery is dated after every statement this
  device holds, never by the relay's clock, and a device the base outdated says so and asks
  for the phrase again." Enforced in: `roster_book::phrase_time`, `api::roster::roster_status`.
  Proven by: the 9.3 tests. Claims C-01.
- R-CR-13 keeps its text; its test list adds the 216 controls.

### 10.4 Tests (test-first; RED line recorded per test)

Rust unit:
- `api::identity::tests::welcome_restore_refuses_a_phrase_that_is_not_24_words`
- `identity::keys::tests::every_phrase_restore_refuses_a_12_word_phrase` (the shared restore, so
  the in-app paths too)
- `api::identity::tests::welcome_restore_names_the_word_that_is_not_in_the_list`
- `api::identity::tests::welcome_restore_refuses_a_phrase_that_fails_its_checksum`
- `api::identity::tests::a_phrase_restore_hands_no_phrase_back`
- `api::identity::tests::welcome_restore_refuses_while_not_ready_before_probing_kept_data` (D6)
- `identity::keys::tests::a_welcome_restore_drops_a_gone_identitys_duress_slot` (zeroed before
  unlink; peek through a hard link as in `storage.rs:5683`)
- `identity::keys::tests::welcome_recovery_into_an_empty_store_signs_a_base_keeping_only_this_device`
- `api::identity::tests::the_keychain_default_skips_a_profile_whose_locked_pair_needs_its_slot`
- `api::identity::tests::welcome_restore_writes_its_mark_only_when_it_mints`
- `api::recovery::tests::kept_data_check_finds_only_this_identitys_folder`
- `api::recovery::tests::kept_data_check_never_changes_a_kept_folder` (hash before and after)
- `api::recovery::tests::kept_data_that_does_not_open_warns_and_a_set_aside_folder_never_does`
- `api::recovery::tests::set_aside_moves_the_typo_identity_and_erases_nothing` (the real
  identity's relinked folder byte-identical after; the root at Welcome; no duress slot left)
- `api::recovery::tests::a_set_aside_mark_for_another_key_moves_nothing`
- `api::recovery::tests::a_destroy_after_a_set_aside_erases_the_set_aside_folder_too` (pins
  the documented rule)
- `api::identity::tests::set_aside_is_refused_once_a_friend_accepted_or_a_server_holds_us`
- `shared_servers::tests::recovering_counts_a_fresh_phrase_restore_for_thirty_days` (not on day
  31, not for `empty = false`, not for another device)
- `shared_servers::tests::recovering_stops_once_the_restored_device_is_removed` (D3)
- R3: `a_device_the_phrase_admits_alerts_our_other_devices` (RED today),
  `a_device_a_recovery_keeps_alerts_our_other_devices`,
  `the_device_the_phrase_admitted_alerts_nothing_about_itself`,
  `an_upgrade_admission_still_alerts_nothing`
- `api::roster::tests::roster_status_says_dropped_by_recovery_for_a_device_the_base_left_out`
  (D3b)
- The 216, 217 and 218 unit tests of section 9.

Harness (end of `test_harness.rs`, block `// pr-phrase-restore`; every No case on an ADMISSION
from the real restore, never `sign_recovery`; every Yes case on the real Welcome recovery):
- `pr_a_phrase_restored_device_gets_its_server_back_through_a_re_added_friend`: A1 in B's server
  and friends; A1 gone; F restored into an empty store; F re-adds B; no prompt at B; F
  `ServerJoined`, holds an MLS leaf, an F post lands at B; B still counts A1.
- `pr_a_re_added_friend_serves_the_dm_history`: B records `new_device` for F.
- `pr_the_surviving_device_is_alerted_and_syncs_the_restored_one`: A1 alive; A1 records
  `own_device_added` with `phrase`; F gets B's friendship and the server from A1.
- `pr_the_phrase_alert_reaches_a_sibling_that_was_hidden`: A1 hidden while F is admitted; it
  records the alert on its return.
- `pr_a_phrase_restored_owner_still_moderates_its_server` (10.2).
- `pr_a_wrong_phrase_is_a_new_request_and_learns_no_servers` (negative).
- `pr_a_fresh_restore_never_asks_after_its_window` (negative).
- `pr_the_relay_hands_the_inbox_to_a_phrase_restored_device`.
- `pr_a_welcome_recovery_drops_the_old_device_and_restores_owned_servers_from_witnesses` (Yes,
  empty store: the relay counts F alone, A1 is uncounted at B, F's chooser gets B's witness).
- `pr_a_welcome_recovery_beside_its_own_database_settles_what_it_held_before_t` (Yes over a
  kept database: the owed settling runs at the first start).
- `pr_an_accepted_friend_answers_the_new_device_after_a_replay_of_the_old_devices_request` (D7).
- `pr_a_share_nobody_answered_is_asked_again_at_the_next_start` (the held entry; the UI half
  is deferred).
- The 216 and 218 harness tests of section 9.

Widget (`test/widget/welcome_phrase_restore_test.dart`): the row after Terms on phone and
desktop; with nothing picked Restore stays disabled; Yes shows the time answers, No does not;
Back returns; count, word and checksum errors on the field with the text kept; a success pops
`'restored_phrase'` with its branch; the step sits in `SecretScreen`; the kept-data match
offers both buttons (desktop) and the warning offers Check the words and Restore anyway.
`restore_progress_card_test` for both card versions, the set-aside button only when allowed;
the alert text for `{device}:phrase`; the two new lock bodies. `design_language_guard_test`
stays green.

Mutation pass (one runner job; every rule in every layer that enforces it): 216 the
`held_before` test in `settle_lost_devices`, in `held_before_recovery` (T versus at), in
`register`'s second source, in `merge_rival_settlings`; 217 each KEEP condition (opens, not
master, counted, MLS names it, mode), the scrub, the scrub-before-key order; 218 `phrase_time`
in the restore, `too_early`; R2 the fresh branch, `empty`, the 30 days, `is_member`; R3 the
filter (phrase-rooted, not self, not upgrade, member before); R1 the 24 words, the duress drop,
`refuse_while_not_ready` before the probe; R4 the read-only open, the set-aside exemption; R5
the gate (friend, server, window), the digest match; R6 the per-device key. The relay mirrors
none of them.

Real app: Windows fleet (throwaway peers a, b, c): No branch (a owns a server with b; a's root
erased; restore; re-add b; the server and DMs return; b shows the new-device warning); Yes
branch (a's old root kept running as c; restore with Yes; c shows the dropped lock; the chooser
runs); a typo run (wrong phrase, card, set aside, Welcome again, right phrase). Phone layout on
an iOS simulator and an Android emulator. Before and after of Welcome as ONE image.

## 11. All copy (for Vitalik's approval)

Sepia pass done: plain, contractions, sentence case, no em dashes, no colon in place of one.
NEW = new string; CHANGED = replaces the quoted old one; EXISTING = reused as is.

**Welcome row**
- NEW Row title: Use your recovery phrase
- NEW Row subtitle: If you lost your only device

**The step**
- NEW Title: Restore with your recovery phrase
- NEW Question: Could someone else have your old device?
- NEW Option: No
  - NEW Under it: It broke, or you wiped it. If it ever turns on again, it's still yours.
- NEW Option: Yes, or I'm not sure
  - NEW Under it: Hollow cuts off your old device and undoes what it changed in your servers
    after you last had it.
- EXISTING (Yes only): When did you last have it? and its answers (Less than an hour ago,
  Earlier today, Yesterday, In the last 7 days, In the last 30 days, Pick a date and time,
  Longer ago, or not sure)
- NEW (Yes only, under the answers): If you're not sure, pick an earlier time. What your
  friends and other members changed stays either way.
- NEW Field hint: Your 24 words, in order
- NEW Text, No: Hollow brings your identity back on this device. Add your friends again and
  they accept you right away. Most servers you share with them come back on their own, with the
  messages they kept.
- NEW Text, Yes: Hollow brings your identity back on this device and cuts off your old one. Add
  your friends again, and Hollow asks the members of each server you own how it looked before
  you lost your device.
- NEW Text, both: Messages and files that were only on your old device don't come back. Your
  name, picture, settings and blocks start fresh.
- NEW Text, both, small: Still have a device with Hollow? Link this one from it instead. That
  brings everything back.
- NEW Buttons: Back, Restore
- EXISTING Error, count: A recovery phrase is 24 words. This one has {n}.
- NEW Error, unknown word: Word {n} isn't a recovery phrase word. Check how it's spelled.
- NEW Error, checksum: These words aren't a recovery phrase. Check each word and the order.
- NEW Line after a set-aside: The identity those words made is set aside. Type your phrase
  again and check each word.

**Kept data before landing**
- NEW Match, title: Your data is still here
- NEW Match, text: This computer still has your earlier data for this identity, in the profile
  {name}. Switch to it to get everything back.
- NEW Match, buttons: Restore here anyway, Switch to it
- NEW No match, title: Check your recovery phrase
- NEW No match, text: There's earlier Hollow data on this device, and these words don't open it.
  If that data is yours, one of the words is probably wrong.
- NEW No match, buttons: Restore anyway, Check the words

**Home card, No branch**
- NEW Title: Finish restoring your identity
- NEW Add your friends again. They accept you right away, and most servers you share with them
  follow.
- NEW If a request still shows as sent, your friend gets it the next time they open Hollow.
- NEW A server on another relay, or one none of your friends are in, needs an invite link from
  a member.
- NEW If someone else might have your old device, remove it in Settings, under Devices.
- NEW If a friend gets a new friend request from you instead, these words may have made a
  different identity.
- NEW Button (only while allowed): Type my phrase again
- NEW Button: Done

**Home card, Yes branch**
- NEW Title: Finish restoring your identity
- NEW Add your friends again. They accept you right away.
- NEW Hollow asks the members of each server you own how it looked before you lost your device.
  If their answers don't agree, you choose.
- NEW A server on another relay, or one none of your friends are in, needs an invite link from
  a member.
- NEW (only if open question 1 is yes) A device restored from a backup now joins only when you
  approve it. You can change this in Settings, under Security.
- NEW The wrong-phrase line, the Type my phrase again button and Done, as in the No card.

**Set aside**
- NEW Title: Type your phrase again?
- NEW Text: Hollow sets this identity aside and starts over. Nothing is deleted. If these words
  were right after all, type them again.
- NEW Buttons: Cancel, Set aside
- NEW Error: Hollow couldn't set this identity aside. Try again.

**Roster lock**
- NEW (218) Title: Type your recovery phrase again
- NEW (218) Body: Your identity doesn't count this device yet. It changed after you typed your
  phrase here, or this device's clock was behind. Check the date and time, then type the phrase
  again.
- EXISTING (218) Button: Use recovery phrase
- CHANGED (D3b) Title, for a device a recovery left out: Your recovery phrase was used on
  another device (was: Waiting to join your identity)
- CHANGED (D3b) Body: Since {date}, this device isn't part of your identity. If that was you and
  you want to use this device too, type your recovery phrase or approve it on your other
  device. (was: This device was restored from a backup. Approve it on one of your other
  devices, or type your recovery phrase.)

**Own-device alert (HOL-SEC-215)**
- NEW Title: A device was added with your recovery phrase
- NEW Text: If that wasn't you, someone else has your recovery phrase. Go to Settings, under
  Security, and use Remove devices with your recovery phrase. (CHANGED from revision 1, which
  said "under Devices": that row lives under Security.)

**Elsewhere**
- CHANGED `RecoveryPhraseField` hint: Your 24 words, in order (was: The 12 or 24 words, in
  order)

## 12. Open question for Vitalik

1. **Yes branch with nothing held: do backups need approval?** A Welcome recovery on an empty
   install cannot read the identity's backup-wait choice, and the old device (perhaps a
   thief's, holding the master key) asks to join the new base at its next start: with the wait
   on, it joins after seven days unless F refuses it. Recommended: sign the recovery with
   `no_wait` (backups need approval) and say so on the Yes card. A held roster keeps its own
   choice. The 2026-10-02 decision keeps the wait as the default for identities in general;
   this only changes it for a recovery typed because someone else may hold a device.

## 13. Found on the way (for the lead)

1. The restore FFI returns the phrase to Dart (`keys.rs:390`, `api/identity.rs:91`); R1 drops it.
2. `RecoveryPhraseField` hints "The 12 or 24 words" (`recovery_phrase_dialogs.dart:42`); fixed in
   D1.
3. The Settings keychain switch (`switch_to_keychain`, `api/identity.rs:1158`) overwrites the
   profile slot that a `.locked` pair from an earlier phrase restore needs, so that pair never
   opens again. Availability of the person's own old keys, not security. Fix: move the old slot
   key to a `.locked` slot first. Test `the_keychain_switch_keeps_the_slot_a_locked_pair_opens_with`.
   Deferred.
4. Our own profile is not recoverable from the signed copies friends hold (deferred).
5. Revision 1's alert copy pointed at "Settings, under Devices" for "Remove devices with your
   recovery phrase"; that row is under Security (`security_section.dart:1092`). Fixed in 11.
