# Phase E+F slice "identity", part 2 (WP1)

Session 34. Part 1 (`phase_ef/identity.md`) holds the scope, C-IDENTITY-01 and C-IDENTITY-02
and was cut off at the start of C-IDENTITY-03. This file redoes the rest of the analysis and
holds everything part 1 lost: C-IDENTITY-03 onward, the leads, AT-1, AT-2, the 13 classes,
the STRIDE grid and the requirements. Code read in the detached worktree `D:/dev/wt/s34-ef` at
`aa104d48`; `spake2-0.4.0` read in the cargo registry; `relay-uws/src/roster.h` read only to
confirm the relay mirrors the fold. Nothing was built or run. Test names were checked to exist
with `grep "fn <name>"`.

## Scope

As part 1: P1 the Rust identity core (`identity/roster.rs`, `identity/recovery.rs`,
`identity/duress.rs`, `identity/keys.rs`, `identity/device_key.rs`, `identity/platform_keystore.rs`,
`node/roster_book.rs`, `node/destroy.rs`, `node/link_handler.rs`, `node/link_pake.rs`,
`node/security_alerts.rs`, `api/roster.rs`, `api/wipe.rs`, `api/identity.rs`, `api/storage.rs`
backup, link stash and pending wipe, `lib.rs` log); P2 the Flutter identity UI
(`event_provider.dart`, `roster_provider.dart`, `roster_lock.dart`, `device_link_dialog.dart`,
`duress_section.dart`, `security_section.dart`, `hollow_shell.dart`, `backup_section.dart`,
`profile_locations_card.dart`, `destroy_flow.dart`, `main.dart` crash log); P3 the push fetch
node for kill frames (`node/fetch.rs`). Stores E-10 (identity rows), E-11 (key files and stashes),
E-13 (keystore), E-14 (logs). Interactors X-1..X-4. Flows F-01..F-07, F-11, F-12, F-12b (a
`.hollow` restore), F-13. Specs: RFC 9382, RFC 5869, BIP-39, RFC 8032. Leads L-05, L-06, L-10,
L-11.

## Summary

- STRIDE cells walked: 71 (3 processes x 6, 4 stores x 3, 4 interactors x 2, 11 flows x 3).
- Candidates in this file: 14, C-IDENTITY-03..-16. With part 1 the slice has 16:
  High 2 (-01, -04), Medium 5 (-02, -03, -05, -06, -07), Low 5 (-08..-12), Info 4 (-13..-16).
- Requirements: 28 (R-IDENTITY-01..28), 10 NOT met today (04, 06, 07, 11, 16, 17, 18, 21, 23, 24).
  This list replaces part 1's lost one; its numbers are not part 1's.
- Leads: L-05 finding (C-IDENTITY-05). L-06 holds, residuals C-IDENTITY-10, -11 and -02.
  L-10 holds for unsolicited prompts, hardening C-IDENTITY-08 and -09, reverse direction -01.
  L-11 holds for phrase-protected identities, residuals AR-15, AR-19, C-IDENTITY-02, -04, -06, -14.
- New since part 1's summary, and the one to read first: **C-IDENTITY-04**. A device restored
  from a stolen backup that the owner REFUSES still gains the power to remove every device of
  the identity once seven days pass on each observer's clock, and it can do so again after
  every recovery. Interim mitigation without a code change: turn the seven-day wait off
  (Settings > Security > Advanced, `no_wait`).
- Mapping to part 1's lost numbering, where it can be told: -03 is part 1's -03 (completed);
  -05 is part 1's -05 (L-05); -08 is very likely part 1's -08 (L-10 hardening); -10 is very
  likely part 1's -10 (L-06 residual); -11 is probably part 1's -06 (a Low that turns
  `authorised` back to the master key); -14 is part 1's -11 (the seven-day path). -04, -06, -07,
  -09, -12, -13, -15, -16 could not be matched and are numbered as found.

## Candidates (most severe first)

### C-IDENTITY-04: A master-key holder whose restored device the owner refused still removes every device of the identity after seven days

- Requirement not met: a refused join ends the join (design ID-1 section 8, "a pending join is
  refused by one current device"; the dialog promises "refuse it and it never gets your
  messages", `lib/src/ui/shell/roster_lock.dart:274-276`). C-01, C-02 (removal is the lock
  that precedes erasure).
- Code: maturity ignores removals, and a matured device is "rooted", so its removals count even
  after it was refused. `rust/hollow_core/src/identity/roster.rs:701-712`
  ```
  let matured: BTreeSet<String> = pendings
  ...
                  !no_wait
                      && first_seen(&p.device)
                          .is_some_and(|seen| seen.saturating_add(PENDING_MATURITY_MS) <= now_ms)
  ...
  let mut rooted: BTreeSet<String> = roots.union(&matured).cloned().collect();
  ```
  and `roster.rs:730-734`
  ```
  for r in self.removals.iter().filter(|r| r.base == base && rooted.contains(&r.by)) {
  ...
      removed.entry(r.device.clone()).or_insert_with(|| r.by.clone());
  ```
  Compaction keeps a pending device's removals because pending devices have standing
  (`roster.rs:562` `(1, self.pendings.iter()...`). The relay mirrors the same rule
  (`relay-uws/src/roster.h:548-570`).
- Fails when: anyone holding the master key (any stolen backup plus its passphrase, any device
  ever lost) signs a pending join for a fresh device and that device's removals of the owner's
  devices, in the current base. The owner refuses it at once. Seven days after each observer
  first saw the ask, the refused device is rooted, its removals count, and every owner device is
  removed at every contact, at the relay and at the owner's own devices (applied at the next
  roster ingest or start, which any later `RosterNotice` triggers): they lock
  (`DeviceRemoved`, `node/roster_book.rs:736-746`) and erase after three days
  (`roster_lock.dart:65-70`) unless the phrase is typed. The master key cannot be rotated, so
  the same holder can repeat it in every new base. With `no_wait` on, nothing matures and the
  path is closed.
- Attacker: P-08 (any past master-key holder). Severity: High (Impact H: the whole identity cut
  off everywhere and its devices erased unless the phrase is at hand within three days, repeatable;
  Exploitability M: needs the master key, then only waiting). Confidence: CONFIRMED (fold, the
  removal loop, compaction and the lock traced; the mirror in `roster.h` read).
- Existing tests miss it: `a_pending_join_matures_on_the_observers_clock_unless_refused` checks
  that the refused device is not a member, not that its removals are void;
  `a_removal_counts_only_from_a_rooted_device` folds with no first sight, so nothing matures.
- Test: unit `authz_a_refused_join_never_gains_removals_by_waiting` in `identity/roster.rs`:
  genesis owner O; pending B with consent; removal of O by B and of B by O; fold with
  `first_seen = NOW - PENDING_MATURITY_MS`; assert O is a member and B removed. Same case as a
  vector in `roster_vectors.rs` for `test_roster.cpp`.
- Fix: a pending join named by a removal whose signer is rooted without maturity (roots and their
  vouch closure) never matures; mirror it in `roster.h` and regenerate `roster_vectors.json`.

### C-IDENTITY-03: After any wipe on Windows, the debug log beside the executable keeps the session's history, including "Duress code entered"

- Requirement not met: C-07 ("destroys local data and shows nothing"), C-02's wipe promise, the
  wipe's own entry list (`api/wipe.rs:23` names `"hollow_debug.log"` under the data root).
- Code: on Windows the log is not under the data root, `rust/hollow_core/src/lib.rs:13-16`
  ```
  if cfg!(target_os = "windows") {
      return std::env::current_exe()
          .ok()
          .and_then(|p| p.parent().map(|d| d.join("hollow_debug.log")))
  ```
  while the wipe removes `root.join(name)` (`api/wipe.rs:72-73`). The duress path writes a line
  before wiping, `api/wipe.rs:172` `hollow_log!("[HOLLOW-DESTROY] Duress code entered");`, and Dart
  writes raw errors there, `lib/src/core/friendly_error.dart:65`
  `.logFromDart(message: '[friendlyError] ${error.runtimeType}: $raw')`.
- Fails when: any wipe (duress, remote destroy, removal erase, profile erase) on Windows. The
  installed path is `%LOCALAPPDATA%\Programs\Hollow\hollow_debug.log`, shared by every profile and
  by the next identity; a portable copy keeps it beside the exe, outside `hollow_data`. It holds
  up to 10 MB (`lib.rs:44`) of peer ids, master ids, server and room ids (the social graph) and
  the duress line. Elsewhere the file is unlinked, not overwritten, so the duress line stays in
  free blocks.
- Related, SUSPECTED: `hollow_crash.log` is opened by Dart before the boot wipe runs
  (`lib/main.dart:69`, `:243`); if Dart's Windows open lacks `FILE_SHARE_DELETE`, both
  `destroy_data_root` and `perform_pending_wipe` fail to remove it, and the boot wipe still
  removes its marker (`api/storage.rs:1899`, `:1903`). `hollow_crash.log.old` is not in
  `WIPE_ENTRIES` and survives until the next launch's boot wipe.
- Attacker: P-09 after a duress or remote wipe. Severity: Medium (Impact M, Exploitability H for a
  disk holder). Confidence: CONFIRMED for the debug log and the duress line; SUSPECTED for the
  crash log (share mode not checked).
- Test: unit `the_debug_log_lives_where_the_wipe_reaches` (the log path starts with
  `identity::data_dir()` on every target) and `a_duress_wipe_writes_no_line_about_it`.
- Fix: keep the Windows log under the data root (per profile); log nothing on the duress path;
  have Dart close or truncate its crash log before a wipe; add `hollow_crash.log.old` to
  `WIPE_ENTRIES`.

### C-IDENTITY-05: A removal that never reaches a contact keeps working forever, and nothing notices two parties holding different rosters (L-05)

- Requirement not met: C-03 ("a removed device stops getting anything at once"), class 3 and
  class 4 of plan 2.2.
- Code: a plain removal is told only to the removed device, the relay and the peers present at
  that moment, `node/sync_handler.rs:2075-2081`
  ```
  let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
  ...
      super::social::send_own_profile_to_peer(
  ```
  unlike pending asks and phrase changes, which `fan_out` into every friend's DM room and every
  server room (`node/roster_book.rs:512-553`). Rosters carry no expiry and no digest travels in
  encrypted envelopes (no `roster_digest` or age anywhere in `identity/` or `node/`).
- Fails when: a contact is offline at the removal and later meets only the removed device online
  (the owner's devices offline): its stored roster still counts the device and its session to it
  is alive, so its DMs reach the removed device until some later profile exchange with an owner
  device. A hostile relay (P-01) colluding with the removed device makes that window permanent by
  dropping every frame from the owner's members to that contact. Nothing on either side detects it.
- Attacker: P-08 with P-01 for the permanent case; P-08 alone for the window. Severity: Medium
  (Impact H for that contact's DMs; Exploitability L-M). Confidence: CONFIRMED that removals are
  pushed only to present peers and that nothing expires; SUSPECTED how long the honest-relay window
  lasts (the later profile exchange was not traced).
- Test: harness `authz_a_friend_offline_at_a_removal_never_sends_to_the_removed_device`: O removes
  sibling S while friend F is offline; F returns while O is offline and S online; F's DM must not
  reach S.
- Fix: send every removal through `fan_out` (buffered DM-room and topic copies for offline
  contacts); carry a roster digest (base plus a hash of the removal set) inside every Olm and MLS
  envelope so a receiver that sees a digest it cannot reproduce asks for the roster; consider an
  expiry for devices nobody re-confirms (WhatsApp's 35 days).

### C-IDENTITY-06: During the legacy window, the first recovery key any master-key holder publishes is pinned by the owner's own devices, and the owner's phrase is refused there for good

- Requirement not met: "the recovery phrase is the final word" (design ID-1 principle 2); AR-15
  accepts that the legacy master key admits a device, not that the phrase stops working.
- Code: a roster with no pinned key adopts the first incoming one, our own master included,
  `identity/roster.rs:488-490`
  ```
  let same_key = out.r_pub.is_empty() || out.r_pub == incoming.r_pub;
  if same_key && !incoming.r_pub.is_empty() {
      out.r_pub = incoming.r_pub.clone();
  ```
  then the owner's own phrase is refused, `roster.rs:816-817`
  ```
  if !self.r_pub.is_empty() && self.r_pub != r_pub {
      return Err("This identity already has a different recovery phrase.".into());
  ```
  and at the next start the stored copy of the phrase is erased because some key is pinned,
  `node/roster_book.rs:208-209` `if !roster.r_pub.is_empty() {` /
  `let _ = store.delete_setting(STORED_PHRASE);`.
- Fails when: the identity is still legacy (0.12 asks once at first start and allows "Later") and
  someone holding the master key but not the phrase (a 0.12-era backup or link of a still-legacy
  identity, both scrubbed of the phrase) signs a recovery under a key of its own and delivers it as
  a `RosterNotice` (own room, inbox mailbox, each friend's DM room). The owner's devices fall out
  of the new base and ask to join it; `recover_with_phrase`, `join_with_phrase` and the upgrade
  confirmation all fail; contacts pin the same key; the forged key also authorises destroy orders
  for every owner device (`node/crypto_handler.rs:1083`).
- Attacker: P-08 holding a scrubbed backup of a legacy identity. Severity: Medium (Impact H:
  permanent loss of the identity and remote wipe; Exploitability L: legacy window plus master key
  without phrase; a 0.11-era backup carries the phrase itself, which AR-15 already covers).
  Confidence: CONFIRMED (adoption, refusal and the stored-phrase erase traced).
- Test: unit `authz_a_recovery_key_from_the_network_never_locks_out_our_own_phrase` in
  `node/roster_book.rs`: legacy own roster; merge a recovery signed by M and a random R; then
  `recover` with the real phrase must succeed and the stored phrase must survive.
- Fix: at the first 0.12 start sign the identity's first recovery from the phrase 0.11 stored,
  before the node connects (keep the type-it-back prompt as the reminder); while a stored phrase
  exists, refuse any recovery key for our own master that it does not derive; never erase the
  stored phrase because a key learned from the network is pinned.

### C-IDENTITY-07: Turning the app password off and on again leaves Settings showing a duress code that no longer exists

- Requirement not met: C-07 (the duress code works when typed); "a duress slot exists for the
  life of password protection" holds, but the code it showed as set is gone.
- Code: removing the password deletes the slot but not the settings Settings reads,
  `api/identity.rs:361` `let _ = crate::identity::duress::remove();`; setting a password again
  writes a fresh random slot, `identity.rs:254` `let _ = crate::identity::duress::set_dummy();`; the
  status comes from the stale setting, `identity.rs:496` `enabled: !scope.is_empty(),`, and the card
  then shows the old scope with Change and Remove (`duress_section.dart:149-194`).
- Fails when: the person turns the password (or the phone lock) off and on, which both
  `_removePassword`/`_enablePassword` and `_removePhoneLock`/`_enablePhoneLock` offer
  (`security_section.dart:563-580`, `:479-503`). Typed under pressure, the old code then reads
  as a wrong password and nothing is erased.
- Attacker: none needed; the harm lands under P-09 coercion. Severity: Medium (Impact H for a
  duress user; no attacker action). Confidence: CONFIRMED.
- Test: unit `turning_the_password_off_and_on_never_reports_a_dead_duress_code` in the
  `duress_tests` module: set password, set code, remove password, enable password; assert
  `duress_status().enabled == false` or that `duress::probe(code)` opens.
- Fix: clear `duress_scope` and `duress_notify_friends` wherever the slot is removed or replaced
  by a dummy (one helper used by both paths).

### C-IDENTITY-08: The link code screen never says the code must not be read out to anyone, and the confirm prompt names only a device kind (L-10 hardening)

- Requirement: C-05 ("only after I confirm on a device I already hold"), plan 2.2 class 12, the
  Signal QR-phishing lesson.
- Code: `lib/src/ui/dialogs/device_link_dialog.dart:258-259`
  `'On your other (empty) device, choose "Link a device" and enter this code.',` and the prompt,
  `:653-654` `'$who typed your code. Adding it sends it your full history '` where `$who` is "A
  phone" or "A desktop" from the joiner's own hello (`node/link_handler.rs:271-274`).
- Fails when: someone talks the person into reading out the ten characters ("support"); the
  prompt then looks the same as for the person's own phone. SPAKE2 itself is sound: no stranger
  raises the prompt without the code (see L-10).
- Attacker: P-03 by social engineering. Severity: Low. Confidence: CONFIRMED (copy read).
- Test: widget `link_code_screen_warns_never_to_share_the_code`, and the prompt asks "Is the other
  device in your hands right now?".
- Fix: a one-line warning on the code screen ("Nobody from Hollow ever asks for this code") and on
  the prompt; after a failed attempt the joiner should ask for a new code rather than a retry of
  the same one (each retry gives a relay that answered the code another guess, see the checklist).

### C-IDENTITY-09: A member device can add another device and none of the owner's other devices says so; removing the member then keeps that device by default

- Requirement not met: plan 2.2 class 12 ("is everyone told?"); AR-15 accepts that a thief's
  vouchees stay until removed, which assumes the owner can see them.
- Code: own-roster changes raise no alert, `node/security_alerts.rs:95`
  `if master_peer_id == local_master_peer_id {` (return; "the user is the actor"), and Dart only
  refreshes on `DeviceListUpdated` (`event_provider.dart:876-882`). The default removal keeps the
  removed device's vouchees, `node/roster_book.rs:294` `let keep = r.vouched_members_of(target, s);`,
  and the dialog does not mention them (`device_management_shared.dart:78-83`).
- Fails when: a stolen member device vouches for a second device of the thief; the owner removes
  the stolen one from the Devices page; the second device stays a member, unannounced.
- Attacker: P-08 while still a member. Severity: Low. Confidence: CONFIRMED.
- Test: harness `authz_a_device_added_by_another_member_is_announced_on_every_own_device`.
- Fix: an own-identity "new device" alert on every device whose vouch it did not sign; the
  removal dialog lists the devices it keeps and lets the person drop them.

### C-IDENTITY-10: A destroy order dated in the future keeps working against every device the identity links before that date (L-06 residual)

- Requirement not met: rule 8 ("old valid messages must not work twice", restart, reinstall,
  relink); the link stamp only refuses orders OLDER than the device.
- Code: `node/destroy.rs:144-147`
  ```
  if linked_at > 0 && order.issued_at_ms < linked_at {
  ...
  if order.issued_at_ms <= last_applied(local_device) {
  ```
  No upper bound on `issued_at_ms`; orders are dated by the issuing device's clock
  (`api/roster.rs:238`, `node/swarm.rs:1640`). At friends the same order sets a floor that later
  genuine orders never pass (`destroy.rs:205-208`).
- Fails when: an order is issued from a device whose clock runs ahead (or by a legacy master-key
  holder on purpose). Anyone who saw it (the relay, notified friends) can deposit it for any later
  device id, and every device linked before its date accepts it.
- Attacker: P-01 or P-04 replaying, after an issuer clock error or a P-08 legacy holder.
  Severity: Low. Confidence: CONFIRMED.
- Test: unit `a_destroy_order_from_the_future_is_refused` in `node/destroy.rs`.
- Fix: refuse (permanently) an order dated more than `MAX_FUTURE_SKEW_MS` past the receiver's
  clock, on both the own and the friend branch, and in `kill_order.h`.

### C-IDENTITY-11: The destroy judge treats "could not read our roster" as "no recovery key yet", so the master key alone suffices

- Requirement not met: rule 6 ("absent means reject"); C-02.
- Code: `node/destroy.rs:92-97`
  ```
  match super::roster_book::load(store, &order.master_peer_id) {
  ...
      None => destroy_order_authorised(order, "", &Default::default()),
  ```
  where `load` hides read errors, `node/roster_book.rs:32-35` `.load_roster(master)` / `.ok()` /
  `.flatten()`, and an empty key passes, `node/crypto_handler.rs:1078` `if pinned_r.is_empty() {`.
- Fails when: the roster row read fails (a busy database while the push fetch process and the app
  both hold it, a row that no longer deserialises) while a master-only order arrives. For our own
  master a roster always exists after the first 0.12 start, so `None` there is never legitimate
  except for a 0.11 row.
- Attacker: P-08 with the master key, with luck. Severity: Low. Confidence: CONFIRMED for the
  fail-open; SUSPECTED for how often the read fails.
- Test: unit `a_destroy_order_is_never_judged_without_our_roster`: own master, stored row that
  fails to parse; assert `RejectTransient`.
- Fix: `load` returns `Result`; a read error is `RejectTransient`; for our own master only a
  stored 0.11 list means legacy.

### C-IDENTITY-12: A backup passphrase of any length is accepted, and the file carries the plaintext master key and the whole history

- Requirement: C-06 and C-30 (the backup is a copy of the identity file and the database).
- Code: `lib/src/ui/settings/backup_section.dart:164-165`
  `_passphrase.text.trim().isNotEmpty && _repeat.text.trim().isNotEmpty;` and no check in
  `api/storage.rs:1713-1714`; the zip holds the plaintext key, `storage.rs:1469`
  `// Always export the PLAINTEXT keypair`.
- Fails when: a one-word passphrase protects a backup file that leaves the device (cloud drive,
  mail). Argon2id at 64 MiB slows the search but does not save a short passphrase; the file then
  opens all history and, under ID-1, yields a pending device (and C-IDENTITY-04).
- Attacker: P-09 or P-10 holding the file. Severity: Low. Confidence: CONFIRMED.
- Test: widget `a_backup_passphrase_too_short_is_refused` plus a Rust-side minimum in
  `export_backup`.
- Fix: a minimum (for example 12 characters or 4 words) with a strength hint, enforced in Rust.

### C-IDENTITY-13: A duress code typed into a Settings confirmation erases the data but the app keeps running and showing what it holds in memory

- Requirement not met: C-07 ("shows nothing"); the launch and app-lock prompts relaunch to
  Welcome (`hollow_shell.dart:699-705`), these do not.
- Code: `security_section.dart:525` and `:685` call `identity_api.unlockIdentity(password: current)`
  to confirm a password; a duress code wipes there (`api/identity.rs:149-151`) and the dialog
  shows the generic error (`hollow_dialog.dart:227`), with no `clearLocalSecretsAfterDestroy` or
  relaunch; `friendly_error.dart:65` logs the raw "duress".
- Fails when: the code is typed into "Confirm your password" (silent start, biometric). Other
  confirmations (remove password, change password) never probe the duress slot, so prompts differ.
- Attacker: P-09. Severity: Info. Confidence: CONFIRMED for Rust and the Dart call sites.
- Test: widget `a_duress_code_in_a_settings_prompt_ends_the_session`.
- Fix: one shared Dart helper for every `unlockIdentity(password:)` call that treats the duress
  result as the launch path does; no raw error logging for it.

### C-IDENTITY-14: A backup thief becomes a member at every contact that saw nobody refuse it for seven days, including while all owner devices are offline (L-11)

- Requirement: decision 4 of design ID-1 (2026-10-02) keeps the seven-day path; AR-15 does not
  name it.
- Code: maturity runs on each observer's own clock from its first sight,
  `identity/roster.rs:704-706` (quoted under -04); the owner's devices start their own seven days
  only when they first see the ask.
- Fails when: the owner's devices are all offline (lost phone, travel) for seven days after the
  ask reached contacts: contacts then count the thief device and fan DMs to it, before any owner
  device could refuse.
- Attacker: P-08 with a backup and its passphrase. Severity: Info (accepted by decision; record
  it). Confidence: CONFIRMED.
- Test: existing `a_restored_device_matures_at_a_contact_after_seven_quiet_days` shows it.
- Fix: none beyond `no_wait`; add the case to AR-15 in words, and mention `no_wait` on the
  pending dialog.

### C-IDENTITY-15: A linked or restored device starts with its identity and device key in plaintext, whatever protection the source device had

- Requirement: C-06 excludes the "no protection" mode by design, but nothing tells the person the
  new device starts in it.
- Code: `api/storage.rs:1469` (plaintext key in the snapshot), `:1833`
  `std::fs::write(data_dir.join("identity.device"), &device[..])`.
- Severity: Info. Confidence: CONFIRMED. Test: widget check that a first launch after a link or
  restore offers protection. Fix: prompt to set the password or keychain at the first launch
  after a link or restore.

### C-IDENTITY-16: A master-key holder can fill the sixteen pending slots and hide a real restored device's ask

- Code: `identity/roster.rs:614` `sort_cap(&mut self.pendings, MAX_PENDING);` with
  `MAX_PENDING = 16` (`:40`); `Pending` sorts by base, then device id, which the signer chooses.
- Fails when: sixteen pending joins with low-sorting device ids push a real one out at every
  observer and the relay; the owner then has to join with the phrase.
- Attacker: P-08. Severity: Info (availability of one restore path). Confidence: CONFIRMED.
- Test: unit `authz_a_flood_of_pending_joins_never_hides_a_real_ask`.
- Fix: rank pendings by first sight on this observer, or keep the newest pending per consented
  device and cap by signer standing, mirrored in `roster.h`.

## Leads

- **L-05 (withheld revocation): finding, C-IDENTITY-05.** Rosters never expire and carry no
  digest; a plain removal is pushed only to present peers (`sync_handler.rs:2075-2086`). ID-1R
  changed the inbox only (`authz_a_removed_device_loses_the_inbox_at_once`).
- **L-06 (destroy order replay): holds**, with residuals. A new install always runs a new device
  id (`identity/keys.rs:76-79`, `:119-122`; a restore deletes `identity.device`,
  `api/storage.rs:1591-1595`; a link installs the vouched key, `:1833`), the first start stamps
  `device_linked_at_ms:{device}` (`node/swarm.rs:1078`, `node/destroy.rs:80-87`), and older orders
  are refused (`destroy.rs:144`); copies of one order inside a session are refused by the RAM
  stamp (`destroy.rs:147`), deliberately not persisted (`destroy_applied_stamp_does_not_survive_a_restart`);
  friend orders keep a persisted floor (`destroy.rs:203-208`). Residuals: future-dated orders
  (C-IDENTITY-10), the fail-open judge (C-IDENTITY-11), the clock strip (C-IDENTITY-02).
  Tests: `destroy_refuses_signal_older_than_link_time`, `destroy_identity_signature_and_freshness_rules`.
- **L-10 (device linking): holds for unsolicited prompts.** "Add this device?" appears only after
  a hello opened under the SPAKE2 keys (`node/link_handler.rs:260-296`), which needs the four
  secret characters; the code answers one handshake (`:179-183`); the vouch names the key the
  joiner minted. Contacts with a baseline are warned of a new device (`security_alerts.rs:86-109`).
  Hardening C-IDENTITY-08; own devices are not told of another member's vouch (C-IDENTITY-09);
  the reverse direction is C-IDENTITY-01.
- **L-11 (the master key on every device): holds for phrase-protected identities**
  (HOL-SEC-077: the master key alone admits nobody, `the_master_key_alone_admits_nobody_once_protected`,
  `authz_a_stolen_backup_is_never_a_member_until_approved`). Residuals: AR-15 (legacy,
  first contact, relay reboot), AR-19 (mutual removal), C-IDENTITY-02 (clock strips the pin),
  C-IDENTITY-04 (refused pending gains removals), C-IDENTITY-06 (legacy forged key),
  C-IDENTITY-14 (seven days while the owner is offline).

## AT-1: every path to the wipe routine, the removal lock and the duress wipe

The wipe routine is `api/wipe.rs:49` `destroy_data_root` (marker first, keys zeroed then removed,
then content). Every path, with its gate:

1. `api/wipe.rs:94` `destroy_local()` (FFI; Rust adds no gate, the caller is the gate). Callers:
   - a. Dart `event_provider.dart:177` `_selfNuke`, only from `NetworkEvent_DestroyReceived`
     (`event_provider.dart:918-923`), emitted only at `node/destroy.rs:167` on `Verdict::Apply` of
     `judge_own_order` (`destroy.rs:121-152`: master signature `verify_destroy_identity`, own
     master, targets name us, `authorised` = pinned recovery key or a member's phrase
     permission, link time, RAM stamp). Lanes: Olm `MessageEnvelope::DestroyIdentityOrder`
     (`node/swarm.rs:9157-9160`), Carried `HavenMessage::IdentityDestroyed` own branch
     (`swarm.rs:12294-12299` -> `destroy.rs:256-257`), relay `WsEvent::KillSignal`
     (`swarm.rs:4796-4801` -> `destroy.rs:269-291`). Weak spots: C-IDENTITY-02, -10, -11.
   - b. Dart `roster_lock.dart:77` `_erase`, from `_eraseIfDue` (`roster_lock.dart:65-70`: gate is
     `removed` and this device's clock past `wipeAt`) or `_confirmErase` (the person taps Erase
     now and confirms). The gate state comes from the removal lock (below).
   - c. Dart `profile_locations_card.dart:274`, the person erases the running profile; the
     password is asked when the profile is password-protected (`:230-245`).
   - d. Rust `api/wipe.rs:116` `destroy_with_scope`, from Dart `duress_section.dart:302` (Danger
     zone); scope `identity` needs the phrase once protected (`wipe.rs:110-111` ->
     `api/roster.rs:224-231`).
   - e. Rust `api/wipe.rs:182` `run_duress` (the duress wipe, below).
2. `node/fetch.rs:288`, push fetch node, only on `Verdict::Apply` of the same `judge_own_order`
   (`fetch.rs:282-284`).
3. The full-root wipe `api/storage.rs:1875` `perform_pending_wipe`, from `hollow_shell.dart:765` at
   boot when `pending_wipe.marker` exists. Marker writers: every wipe (`wipe.rs:51`),
   `stash_pending_wipe` (`storage.rs:1859`) from `hollow_shell.dart:1112` (backing out of the link
   code entry on a throwaway identity), and any imported zip entry named `pending_wipe.marker`
   (C-IDENTITY-01).

**The removal lock** (`DeviceRemoved` / `RosterGate.removed`, which arms 1b): emitted at
`node/roster_book.rs:427-438` (start and `RosterChanged`) and `:736-746` (ingest), also read by
`api/roster.rs:110-115`. Gate: our fold names us in `removed`, which needs a removal in the
current base, signed under `hollow-id1-remove` and verified strictly (`identity/roster.rs:462-477`),
by a `rooted` signer (`roster.rs:730`). Remote ways to make it true: a member device of ours
(P-07, P-08; AR-19), a refused pending device after seven days (C-IDENTITY-04). A recovery that
leaves us out, a forged legacy key (C-IDENTITY-06) and the clock strip (C-IDENTITY-02) only make
us "pending" (locked, never erased).

**The duress wipe:** no remote trigger. `identity.duress` is read only by `duress::probe`
(`identity/duress.rs:125`), called from `unlock_identity` (`api/identity.rs:144`) and
`change_password` (`:294`, refuses, never wipes); `run_duress` is called only at
`api/identity.rs:150`, after a typed password fails the identity slot and opens the duress slot.
Dart callers that pass a typed secret: `hollow_shell.dart:695` (launch and app lock prompt),
`security_section.dart:525` and `:685` (C-IDENTITY-13); `hollow_shell.dart:576` and `:643` pass a
stored secret, which is the real password.

## AT-2: take over Alice's identity, leaf by leaf

- OR obtain the master key:
  - intercept a device link: closed by HOL-SEC-002 (`link_the_relay_cannot_open_the_snapshot`,
    `authz_a_relay_that_answers_the_code_gets_one_guess`). Residual: the code read out
    (C-IDENTITY-08); a victim typing an attacker's code is C-IDENTITY-01 (file write, not key loss).
  - steal a usable device: the device holds the identity only until the phrase (HOL-SEC-077,
    `authz_the_phrase_takes_the_identity_back_from_a_stolen_device`). Residuals AR-15, AR-19,
    C-IDENTITY-04 (it can keep removing the owner after every recovery through refused pending
    devices), C-IDENTITY-09 (silent vouches kept by default).
  - copy the identity file and break its protection (C-06): Argon2id 64 MiB, t=3, p=1
    (`identity/encryption.rs:102`), keychain mode by DPAPI or Keychain with per-profile slots
    (`platform_keystore.rs:15-45`). Holds. Residuals: plaintext by default and after any link or
    restore (C-IDENTITY-15); desktop passwords have no minimum (WP8, L-07).
  - read it from logs, backups, crash dumps (C-37): no key, phrase or code is logged in scope
    (grep of `hollow_log!` and Dart release logging); backups hold the plaintext key under a
    passphrase of any length (C-IDENTITY-12); logs outlive a wipe but hold ids, not keys
    (C-IDENTITY-03).
- OR learn the phrase: the identity (AR-15, bearer secret by design).
- AND then, with the master key: the roster does not move for a protected identity (HOL-SEC-077)
  except through C-IDENTITY-02 (clock), C-IDENTITY-04 (refused pending, seven days),
  C-IDENTITY-06 (legacy window) and AR-15 (first contact, relay reboot). What it signs (profiles,
  messages, server ops) counts only from a device the roster counts: a non-member device resolves
  to itself (matrix identity:A-40, N-01; HOL-SEC-083 for the bare master id).

## Protocol checklist

| Spec | Obligation | Compliance | Evidence |
|---|---|---|---|
| RFC 9382 s.3.1, s.6 | M and N with unknown discrete log | Met in substance; the crate's constants are python-spake2's hash-derived points, not the RFC's edwards25519 table (Info) | `spake2-0.4.0/src/ed25519.rs:23-45` |
| RFC 9382 s.3.3 | Multiply K by the cofactor h, validate the peer element | Partly: points are decompressed (invalid encodings refused, `ed25519.rs:82-92`) but K is `(Y - N*w)*x` with no cofactor clearing (`lib.rs:389-394`); leaks at most x mod 8 of an ephemeral, no password information (Info) | crate |
| RFC 9382 s.3.2, s.9 | Fresh x/y per run; identities in the transcript | Met: `start_a/start_b` draw OS randomness; identities `hollow-link1:{rv}:joiner/presenter` hashed into the key | `node/link_pake.rs:100-105`, `:126`, `:137`; crate `lib.rs:407-430` |
| RFC 9382 s.4 | Key confirmation before using the key | Met in substance: the presenter sends an HMAC over both messages, checked in constant time before the joiner seals anything; the joiner's confirmation is implicit (its AEAD-sealed hello; one that does not open burns the code) | `link_pake.rs:151-157`, `link_handler.rs:260-283` |
| RFC 9382 s.9 | Limit online guesses | One handshake per code at the presenter (`link_handler.rs:179-183`). A relay that answers the joiner instead gets one guess per joiner attempt; the joiner's failure text invites a retry of the same code (Info, C-IDENTITY-08) | `link_handler.rs:220-229` |
| RFC 9382 s.3.2 | Password through a memory-hard function | n/a: ephemeral 20-bit code, never stored | `link_pake.rs:19` |
| RFC 5869 s.3.1-3.2 | Salt independent of the secret; distinct info per key | Met: link salt = rendezvous, info per direction and confirm; recovery salt `hollow-recovery`, info `hollow-recovery-key1` | `link_pake.rs:107-121`; `identity/recovery.rs:16-25` |
| BIP-39 | Seed = PBKDF2-HMAC-SHA512(mnemonic, "mnemonic"+passphrase, 2048) | Met via the `bip39` crate, empty passphrase; master = seed[0..32], recovery from all 64 bytes; KAT pinned | `native_identity.rs:32-36`; `recovery_key_known_answer` |
| RFC 8032 s.5.1.7 / L-04 | Strict verification where signatures bind authority | Met: roster, destroy, delegation and master signatures use `verify_strict` | `roster.rs:234-240`; `crypto_handler.rs:1056-1062`; `native_identity.rs:188` |

## The 13 classes (plan 2.2), asked of this slice

1. **Authenticated but not authorised.** Every roster statement names the master and its signer
   must have standing; destroy orders need the pinned key or a member's permission. Found: a
   refused pending device still authorises removals after maturity (C-IDENTITY-04); the judge
   fails open on a read error (C-IDENTITY-11).
2. **Infrastructure controls membership.** The relay only routes; membership comes from signed
   statements (identity:A-01). The relay's own fold decides inbox ownership only. The relay can
   still withhold removals indefinitely (C-IDENTITY-05).
3. **Split view.** Nothing detects two parties holding different rosters (C-IDENTITY-05); the
   owner's own devices can diverge in the legacy window (C-IDENTITY-06).
4. **Withheld revocation.** No expiry; plain removals reach only present peers (C-IDENTITY-05).
5. **Identifier confusion.** Every statement carries its own `hollow-id1-*` or `hollow-destroy2`
   tag and the master id (`roster.rs:186-216`, `crypto_handler.rs:941-956`); ids must be Ed25519
   peer ids, which rules out the separators (`roster.rs:228-232`); a bare master id is a device
   only when its roster counts it (HOL-SEC-083). Nothing found.
6. **Channel confusion.** Rosters ride every carrier and fold through one `ingest`
   (identity:1.0, `carried_roster_arms_stay_wired`); destroy orders ride Olm, Carried and the
   kill list into one judge. Nothing found.
7. **Identity misbinding.** The link vouch names the device key the joiner minted, checked at
   import (`a_pending_link_installs_the_device_key_it_was_made_for`); a phrase from another
   identity is refused (`a_phrase_from_another_identity_is_refused`). Nothing found.
8. **Replay.** Rosters are a union per base, old bases compacted away; destroy orders: link stamp
   and RAM stamp, but no future bound (C-IDENTITY-10); link frames are live-only and one handshake
   per code.
9. **Downgrade, absent fields.** `DestroyIdentity.r_pub/sig_r/delegation` and `Roster.r_pub` are
   `#[serde(default)]`; absent means master-only, accepted only while no key is pinned (AR-15,
   AR-18). Ways the pin reads as absent: C-IDENTITY-02, C-IDENTITY-11.
10. **Unauthenticated metadata.** The link hello's `kind` and counts are joiner-chosen and shown on
    the prompt (they inform only, C-IDENTITY-08); `RosterNotice` sender binds nothing by design.
    Destroy `targets` are sorted before verifying. Nothing else found.
11. **State and key lifecycle.** The wipe writes its marker first and the boot wipe removes it
    last (`wipe_routine_is_idempotent_and_marker_resumes`), but a failed removal still clears the
    marker (`storage.rs:1899-1903`, C-IDENTITY-03). Duress settings and slot drift apart
    (C-IDENTITY-07). Note (no candidate): `change_password` writes `identity.key` under the new
    key before re-wrapping `identity.device` (`api/identity.rs:303-321`); a crash between leaves a
    device key the next unlock cannot open. `zero_and_remove` overwrites in place, which flash
    storage does not guarantee (`wipe.rs:37-45`).
12. **Linking and cloning.** Link needs the on-screen confirm; restores wait as pending with a
    prompt. Gaps: refusal is not final (C-IDENTITY-04), own devices are not told of another
    member's vouch (C-IDENTITY-09), the code screen warns of nothing (C-IDENTITY-08), new devices
    start unprotected (C-IDENTITY-15).
13. **What a stranger can trigger.** A stranger cannot raise the link prompt, remove, vouch or
    destroy. It can burn a link code whose rendezvous it learned (DoS), and it can make us store a
    roster for each identity it mints, up to 256 KiB each, delivered through our inbox mailbox
    (`roster_book.rs:678-686` keeps it when its deliverer is one of its members); the aggregate is
    a flood question for phase G (AR-01).

## STRIDE grid

Processes (S, T, R, I, D, E):

| Element | Cell | Verdict |
|---|---|---|
| P1 Rust identity core | S | covered: statements verify alone under their own key (identity:A-01); bare master id G1 (identity:N-01) |
| P1 | T | met: `verify_strict` over tagged payloads (`roster.rs:234-240`); stored roster re-verified at load, which is C-IDENTITY-02 |
| P1 | R | met: removals and vouches carry their signer (`Removal.by`, `Vouch.by`), shown on the lock screen |
| P1 | I | candidate C-IDENTITY-03 (log); rosters in the clear are accepted under C-24 note 2 |
| P1 | D | met for one frame: roster over 256 KiB dropped (`roster_book.rs:599-602`), caps in compaction; candidates C-IDENTITY-04, -16 |
| P1 | E | covered HOL-SEC-077; candidates C-IDENTITY-02, -04, -06, -11 |
| P2 Flutter identity UI | S | met: remover shown by local label or kind only (`roster_lock.dart:121-135`) |
| P2 | T | n/a: Dart makes no authorisation decision for remote input (TB-9); `destroy_local` is callable by any Dart path by design |
| P2 | R | n/a: local person |
| P2 | I | candidates C-IDENTITY-08, -13; lock order behind the app lock covered (security_write_gates s.21) |
| P2 | D | met: erase timer only on `removed` with a date (`roster_lock.dart:65-70`); a device clock jumping forward erases early (own device only, Info) |
| P2 | E | n/a: profile erase challenge is Dart-side but local (TB-9) |
| P3 fetch node | S | covered identity:A-33 (same `judge_own_order`) |
| P3 | T | covered identity:A-33 |
| P3 | R | covered HOL-SEC-096 (acks name issuer and stamp, `fetch.rs:267-274`) |
| P3 | I | n/a: logs refusal reasons only |
| P3 | D | covered: junk acked, transient never acked (`fetch.rs:275-303`) |
| P3 | E | candidate C-IDENTITY-11 |

Data stores (T, I, D):

| Element | Cell | Verdict |
|---|---|---|
| E-10 identity rows | T | covered: written only by `roster_book::save` behind ingest (identity:A-01, A-02); candidate C-IDENTITY-07 (`duress_scope`) |
| E-10 | I | met: SQLCipher under a master-derived key (C-30); backups carry it (C-IDENTITY-12) |
| E-10 | D | candidate C-IDENTITY-16; stranger-minted rosters stored without a cap (class 13, phase G) |
| E-11 key files and stashes | T | candidate C-IDENTITY-01 (part 1), C-IDENTITY-07 (slot replaced) |
| E-11 | I | candidate C-IDENTITY-15; link stash (`pending_link.*`) plaintext until the next launch (`storage.rs:1779-1786`, Info) |
| E-11 | D | candidate C-IDENTITY-01 (`pending_wipe.marker`) |
| E-13 keystore | T | n/a remotely; per-profile slots (`platform_keystore.rs:15-45`) |
| E-13 | I | met by design: the wrapping key is readable to the same OS user (C-06 wording) |
| E-13 | D | Info: a wipe also deletes the shared legacy slot (`platform_keystore.rs:331-345`), which another profile that never healed may still use |
| E-14 logs | T | n/a |
| E-14 | I | candidate C-IDENTITY-03, C-IDENTITY-13 |
| E-14 | D | met: rotation at 10 MB (`lib.rs:44-56`) |

External interactors (S, R):

| Element | Cell | Verdict |
|---|---|---|
| X-1 user | S | accepted: whoever holds an unlocked device acts as the user (AR-04); phrase is a bearer secret (AR-15) |
| X-1 | R | n/a: local erase and destroy keep no record by design |
| X-2 relay | S | covered by the relay slice (auth v2, F-05); answering a link code gets one guess per attempt (checklist) |
| X-2 | R | covered HOL-SEC-096 (kill list acks) |
| X-3 peers | S | covered: device-sealed frames (design A); roster statements verify alone |
| X-3 | R | met: removals and vouches are signed by the acting device |
| X-4 own siblings | S | covered identity:A-11 (sibling = roster member) |
| X-4 | R | candidate C-IDENTITY-09 (a sibling's vouch is not shown) |

Flows (T, I, D):

| Flow | Cell | Verdict |
|---|---|---|
| F-01 roster on carriers | T | covered identity:A-01, 1.0 |
| F-01 | I | accepted: rosters ride in the clear (C-24 note 2, ID-1R) |
| F-01 | D | candidate C-IDENTITY-05; oversized dropped (met) |
| F-02 removal to the removed device | T | met: signed removal, verify_strict |
| F-02 | I | met by design: the removed device learns who removed it |
| F-02 | D | candidates C-IDENTITY-04, -05 |
| F-03 DestroyIdentity | T | covered identity:A-30, A-31 |
| F-03 | I | accepted AR-18 (the relay reads a parked order) |
| F-03 | D | candidates C-IDENTITY-10, -11 |
| F-04 relay kill list | T | covered identity:A-32 |
| F-04 | I | accepted AR-18 |
| F-04 | D | covered HOL-SEC-096 (proven slots); AR-18 eviction residual |
| F-05 relay auth | T | covered by the relay slice (A-D4) |
| F-05 | I | n/a for this slice |
| F-05 | D | interplay only: a clock 60 s off blocks auth, see C-IDENTITY-02 |
| F-06 unlock, duress, app lock | T | candidate C-IDENTITY-07 |
| F-06 | I | candidates C-IDENTITY-03, -13; equal cost met (`duress_both_slots_always_derived`) |
| F-06 | D | class 11 note on `change_password` |
| F-07 sibling sync | T | covered identity:A-11..A-19, N-03 |
| F-07 | I | covered identity:A-14, A-15, A-18 |
| F-07 | D | n/a for this slice |
| F-11 link code claim and resolve | T | covered HOL-SEC-002 |
| F-11 | I | accepted by design: the relay sees the rendezvous part |
| F-11 | D | Info: whoever learns a rendezvous can burn the code |
| F-12 link snapshot | T | met: SPAKE2 plus AEAD per direction (`every_layer_binds_on_its_own`) |
| F-12 | I | met: scrubbed of phrase and Olm/MLS (`snapshots_leave_device_secrets_behind_both_ways`) |
| F-12 | D | candidate C-IDENTITY-01 (zip bomb, part 1) |
| F-12b backup restore | T | candidate C-IDENTITY-01 |
| F-12b | I | candidate C-IDENTITY-12 |
| F-12b | D | candidate C-IDENTITY-01 |
| F-13 link confirm prompt | T | met: raised only from an opened hello (`link_handler.rs:260-296`) |
| F-13 | I | candidate C-IDENTITY-08 |
| F-13 | D | n/a |

## Requirements

| ID | Requirement (testable) | Evidence | Test | Met |
|---|---|---|---|---|
| R-IDENTITY-01 | No peer or relay makes our device count a device for any master unless that device consented and the phrase, a member's vouch or seven quiet days on our clock admits it. | `roster.rs:388-479`, `:684-770` | `a_vouch_admits_only_with_the_devices_consent`, `authz_a_stolen_backup_is_never_a_member_until_approved` | yes |
| R-IDENTITY-02 | A holder of the master key alone admits no device to a phrase-protected identity. | `roster.rs:534-546` | `the_master_key_alone_admits_nobody_once_protected` | yes |
| R-IDENTITY-03 | A stranger, a consent-only device or an unmatured pending device removes nobody. | `roster.rs:730` | `a_removal_counts_only_from_a_rooted_device` | yes |
| R-IDENTITY-04 | A pending device that any current member refused never gains, by waiting, the power to remove a member. | none | no test | NO (C-IDENTITY-04) |
| R-IDENTITY-05 | A replayed older roster or a superseded base never brings back a removed device. | `roster.rs:593-610`, `:736-740` | `authz_a_removed_device_stays_refused_after_a_restart`, `mutual_removal_removes_both_and_a_recovery_settles_it`, `authz_a_removed_device_cannot_bring_a_device_back_through_its_own_removal` | yes |
| R-IDENTITY-06 | Once a recovery key is pinned for a master, nothing stored or received clears it. | `roster.rs:425-427` clears it | `a_far_future_phrase_statement_is_dropped` (ingest only) | NO (C-IDENTITY-02) |
| R-IDENTITY-07 | A recovery key learned from the network never stops our own phrase from recovering our identity. | `roster.rs:816-817` | no test | NO (C-IDENTITY-06) |
| R-IDENTITY-08 | Only an order under the pinned recovery key, or from a member device holding a phrase permission for itself, destroys a protected identity's device remotely. | `crypto_handler.rs:1073-1102` | `authz_a_destroy_order_needs_the_phrase`, `authz_a_destroy_order_needs_the_phrase_once_protected` | yes, residuals -02, -11 |
| R-IDENTITY-09 | An order signed by another master, not naming this device, or with a bad signature never wipes. | `destroy.rs:128-136` | `destroy_identity_signature_and_freshness_rules`, `kill_signal_with_foreign_blob_is_dropped` | yes |
| R-IDENTITY-10 | An order issued before this device joined never wipes it, after a restart, reinstall or link. | `destroy.rs:144`, `swarm.rs:1078` | `destroy_refuses_signal_older_than_link_time` | yes |
| R-IDENTITY-11 | An order dated past the receiver's clock (beyond skew) is refused. | none | no test | NO (C-IDENTITY-10) |
| R-IDENTITY-12 | Junk sharing a genuine order's stamp never removes it from the relay. | `destroy.rs:276-291`, `fetch.rs:267-274` | `authz_turning_away_junk_that_shares_an_orders_stamp_keeps_the_order` | yes |
| R-IDENTITY-13 | A friend-destroy order for an identity we never knew writes nothing; one already applied never applies again. | `destroy.rs:196-208` | `authz_a_friend_destroy_order_applies_once_even_after_the_identity_returns` (no unknown-identity test) | yes, untested half |
| R-IDENTITY-14 | No frame from a peer or the relay reaches the duress slot or `run_duress`. | `api/identity.rs:144-151` only caller | no test (source fact) | yes |
| R-IDENTITY-15 | A wrong password and a duress code cost the same work. | `api/identity.rs:136-155` | `duress_both_slots_always_derived`, `duress_slot_dummy_when_unset_is_indistinguishable_in_size` | yes |
| R-IDENTITY-16 | A duress code that Settings shows as set always opens its slot. | `identity.rs:254`, `:361`, `:496` | no test | NO (C-IDENTITY-07) |
| R-IDENTITY-17 | After any wipe nothing the app wrote about the identity remains where the app writes. | `lib.rs:13-16` | `wipe_routine_is_idempotent_and_marker_resumes` (data root only) | NO (C-IDENTITY-03) |
| R-IDENTITY-18 | A duress code typed at any password prompt ends the session and leaves no line naming it. | `security_section.dart:525`, `:685`; `wipe.rs:172` | no test | NO (C-IDENTITY-13, -03) |
| R-IDENTITY-19 | A relay that answers a link code gets at most one guess per attempt and cannot open the snapshot. | `link_pake.rs`, `link_handler.rs:179-183` | `link_the_relay_cannot_open_the_snapshot`, `authz_a_relay_that_answers_the_code_gets_one_guess`, `every_layer_binds_on_its_own` | yes |
| R-IDENTITY-20 | A link adds a device only after a confirm on the presenter, and only the key the joiner minted. | `link_handler.rs:338-374`, `storage.rs:1814-1835` | `a_pending_link_installs_the_device_key_it_was_made_for`, `authz_link_frames_from_a_stranger_are_refused` | yes |
| R-IDENTITY-21 | Importing a snapshot or backup writes only the expected files inside the data root. | `storage.rs:1599-1610` | no test | NO (C-IDENTITY-01) |
| R-IDENTITY-22 | No backup or snapshot carries the stored phrase or the source's Olm or MLS identity. | `storage.rs:1535-1557`, `:1619-1628` | `snapshots_leave_device_secrets_behind_both_ways` | yes |
| R-IDENTITY-23 | A contact offline at a removal stops sending to the removed device when it returns, and a withheld removal is eventually detected. | `sync_handler.rs:2075-2086` | no test | NO (C-IDENTITY-05) |
| R-IDENTITY-24 | Every own device is told when another member adds a device. | `security_alerts.rs:95` | no test | NO (C-IDENTITY-09) |
| R-IDENTITY-25 | The master key alone never speaks as the bare master id. | `roster_book.rs:771-773` | `authz_the_master_key_alone_never_speaks_as_the_bare_master_id`, `authz_a_master_id_is_a_device_only_while_its_roster_counts_it` | yes |
| R-IDENTITY-26 | The relay lets a socket own our inbox only while the roster it holds counts that device. | `roster_book.rs:120-133` (shows it); relay `roster_book.h` | `authz_the_master_key_alone_never_owns_a_protected_inbox`, `authz_a_removed_device_loses_the_inbox_at_once` | yes |
| R-IDENTITY-27 | No roster FFI call mints an identity. | `api/roster.rs:49-50` | `a_roster_read_never_mints_an_identity` | yes |
| R-IDENTITY-28 | The recovery key comes from the whole seed, needs the phrase of this identity, and is never stored. | `recovery.rs:20-47`; no writer (grep) | `recovery_key_known_answer`, `a_phrase_from_another_identity_is_refused` | yes |
