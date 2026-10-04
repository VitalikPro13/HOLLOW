# Phase E+F slice "identity": identity, devices, linking, removal, destroy, duress (WP1)

Session 34, merged phase E (STRIDE, protocol checklist, 13 classes) and phase F (code review).
Code read in the detached worktree `D:/dev/wt/s34-ef` at `aa104d48`. `spake2-0.4.0` and
`zip-2.4.2` read in the cargo registry. Nothing was built or run: every verdict comes from
reading code. Test names cited were checked to exist by `grep` (`fn <name>`).

## Scope

- Processes
  - P1 the Rust identity core: `identity/roster.rs`, `identity/recovery.rs`, `identity/duress.rs`,
    `identity/keys.rs`, `identity/device_key.rs`, `node/roster_book.rs`, `node/destroy.rs`,
    `node/link_handler.rs`, `node/link_pake.rs`, `node/resolver.rs`, `node/security_alerts.rs`,
    `api/roster.rs`, `api/wipe.rs`, `api/identity.rs` (unlock, duress, protection),
    `api/storage.rs` (backup export/import, link stash/import, pending wipe).
  - P2 the Flutter identity UI: `event_provider.dart` (`_selfNuke`, roster events),
    `roster_provider.dart`, `roster_lock.dart`, `device_link_dialog.dart`, `duress_section.dart`,
    `security_section.dart`, `hollow_shell.dart` (unlock, app lock, pending wipe, link cancel),
    `mnemonic_dialog.dart`, `identity_provider.dart`, `security_alert_banner.dart`.
  - P3 the push fetch node and iOS NSE, for kill frames only (`node/fetch.rs` 255-303).
- Data stores: E-11 (`identity.key`, `identity.device`, `identity.duress`, `identity.dpapi`,
  `pending_link.*`, `roster_bootstrap.json`); E-10 identity rows (`device_lists`, `device_links`,
  `revoked_devices`, `roster_pending_seen`, settings `own_removed_*`, `device_linked_at_ms:*`,
  `identity_destroyed*`, `duress_scope`, `duress_notify_friends`, legacy `recovery_mnemonic`);
  E-13 (identity keystore slot, app lock secrets); E-14 logs, as far as a wipe is concerned.
- External interactors: X-1 user, X-2 relay (inbox roster, kill list, link codes), X-3 peers
  (contacts and co-members), X-4 own sibling devices.
- Flows: F-01, F-02, F-03, F-04, F-05, F-06, F-07, F-11, F-12 (and its twin F-12b: a `.hollow`
  backup file restored on Welcome), F-13. threat_model.md defines no F-08..F-10.
- Spec obligations: RFC 9382 (SPAKE2) for the link, RFC 5869 (HKDF) and BIP-39 seed use for
  the recovery key, RFC 8032 strict verification.
- Attack trees AT-1 (silent wipe) and AT-2 (identity takeover), re-walked leaf by leaf.
- Leads: L-05, L-06, L-10, L-11.

## Summary

- STRIDE cells walked: 71 (3 processes x 6, 4 stores x 3, 4 interactors x 2, 11 flows x 3).
- Candidates: 14. High 1 (C-IDENTITY-01), Medium 4 (-02, -03, -04, -05), Low 5 (-06 .. -10),
  Info 4 (-11 .. -14).
- Requirements: 24 (R-IDENTITY-01..24), of which 6 are NOT met today (R-IDENTITY-07, -11, -12,
  -14, -18, -19).
- Leads: L-05 = finding (C-IDENTITY-05: a withheld removal never expires and nothing detects a
  split view; ID-1R changes only the inbox). L-06 holds (new device id plus link stamp), with
  residuals in C-IDENTITY-10 and with C-IDENTITY-02/-06 able to turn `authorised` back to the
  master key. L-10 holds for unsolicited prompts (a stranger cannot raise one); hardening
  C-IDENTITY-08, and the reverse direction (a victim typing an attacker's code) is
  C-IDENTITY-01. L-11 holds for phrase-protected identities, with the residuals AR-15, the
  seven-day path (C-IDENTITY-11), C-IDENTITY-02 and C-IDENTITY-06.
- AT-1: every path to the wipe routine, the removal lock and the duress wipe is enumerated
  below with its gate. Duress has no remote trigger.
- Release-relevant: C-IDENTITY-01 (a link snapshot or backup writes files anywhere the user can
  write) is a code-execution path on desktop and a one-line class of fix (`enclosed_name` plus
  an allowlist). C-IDENTITY-02 and -06 are the two ways the pinned recovery key can silently
  stop being pinned.

## Candidates (most severe first)

### C-IDENTITY-01: Whoever shows the link code a victim types, or hands a victim a backup file, writes files anywhere the victim's account can write

- Severity: High (Impact H: arbitrary file write as the user, so code execution on desktop
  through the Startup folder, `~/.config/autostart`, shell rc files or the per-user install
  directory `%LOCALAPPDATA%\Programs\Hollow`; inside the app sandbox on phones; Exploitability M:
  the victim must type the attacker's ten-character code into "Link a device" on a fresh
  install, or restore the attacker's `.hollow` file with the passphrase the attacker gives,
  then nothing else is asked).
- Attacker: P-03 (a stranger running a modified client as the presenter), or anyone who can get
  a crafted `.hollow` file and its passphrase to a new user. A hostile own sibling (P-07) too.
- Confidence: CONFIRMED (both callers and the extraction loop traced; `zip-2.4.2`'s own doc for
  `ZipFile::name()` warns the raw name may be absolute or contain `..`).
- Code: `rust/hollow_core/src/api/storage.rs:1599-1610`
  ```
          let name = entry.name().to_string();
          let out_path = data_dir.join(&name);
  ...
              entry.read_to_end(&mut data).map_err(|e| format!("Failed to read zip entry: {e}"))?;
              std::fs::write(&out_path, &data).map_err(|e| format!("Failed to write {name}: {e}"))?;
  ```
  Reached from `import_pending_link` (`api/storage.rs:1832` `let result = import_snapshot_bytes(&zip_bytes).and_then(|()| {`)
  at the next launch after any link, and from `import_backup` (`api/storage.rs:1725`
  `import_snapshot_bytes(&decrypt_backup_bytes(blob, passphrase)?)`). The only content check is
  that some entry is named `identity.key` (`api/storage.rs:1525-1531`). The link blob is the
  presenter's own bytes under a key the presenter chose (`node/link_handler.rs:350-391`); the
  joiner stashes it unread (`node/file_handler.rs:2504`). `Path::join` with an absolute name
  discards the base; `..` components walk out of it. `entry.read_to_end` has no size cap, so a
  zip bomb exhausts memory at boot (the throwaway identity is already deleted by then,
  `api/storage.rs:1827-1830`). Besides traversal, any in-root name lands too: `identity.duress`,
  `pending_wipe.marker`, `roster_bootstrap.json`, `profiles.json` (in the default root).
- Breaks: C-29 ("Nothing a peer sends can write a file outside Hollow's own folders"), AT-5
  ("a file written outside the data folder"), secure-coding rule 1 in spirit (the presenter is
  authenticated by SPAKE2, which proves only that it showed the code).
- Test: a unit in `api/storage.rs` next to `snapshots_leave_device_secrets_behind_both_ways`:
  build a zip with `identity.key` plus an entry named `../escaped.txt` and one with an absolute
  path under a temp dir, run `import_snapshot_bytes` with `HOLLOW_DATA_DIR` set to a subdir,
  assert nothing exists outside it and the import fails. A harness variant: a presenter node
  whose `export_backup_bytes` is swapped for a crafted blob, joiner imports, same assert.
- Fix: take names only through `entry.enclosed_name()`, accept only an allowlist
  (`identity.key`, `messages.db`, `vault/<hex>`, `files/<id>`), refuse every other entry
  (key files, markers, lock files, `profiles.json`), and cap the total uncompressed size.
  Variants: `api/updater.rs:1038-1050` checks `..` but not absolute names (signed archive, so
  lower risk); `api/archive.rs` and `api/stickers.rs` read fixed names only.

### C-IDENTITY-02: A device whose clock steps back past the newest recovery forgets the recovery for good, and then the master key alone admits devices and orders the wipe there

- Severity: Medium (Impact H: at that device the identity drops to the legacy base, so a
  master-key holder's legacy claim roots its device, its removals lock and erase the owner's
  device, a master-only destroy order is accepted, and a forged recovery key the holder shows
  first is pinned for good; Exploitability L: needs one node start while the device clock reads
  earlier than the newest recovery's `at_ms` minus ten minutes, which a dead RTC battery, a
  dual-boot local-time RTC, a manual clock change or NTP/NITZ spoofing (P-02) can produce,
  plus a master-key holder to use it).
- Attacker: P-08 (removed thief or stolen backup holder) with P-02 or luck; without an attacker
  the same event locks the owner's own device as "waiting to join".
- Confidence: CONFIRMED for the code path (load re-verifies, verification drops future-dated
  phrase statements and clears `r_pub`, start-up saves the result); SUSPECTED for how often the
  trigger happens in the field.
- Code: every stored roster is re-verified against the current clock on every load,
  `rust/hollow_core/src/node/roster_book.rs:31-36`
  ```
  pub(crate) fn load(store: &MessageStore, master: &str) -> Option<Roster> {
      store
          .load_roster(master)
          .ok()
          .flatten()
          .map(|r| r.verified(now_ms()))
  ```
  and verification drops a phrase statement dated past the clock and then clears the pin,
  `rust/hollow_core/src/identity/roster.rs:392`, `402`, `425-427`
  ```
          let fresh = |at: i64| at <= now_ms.saturating_add(MAX_FUTURE_SKEW_MS);
  ...
                      fresh(rec.at_ms)
  ...
              if !out.recoveries.is_empty() || !out.phrase_admits.is_empty() {
                  out.r_pub = self.r_pub.clone();
              }
  ```
  Compaction already kept only the newest recovery (`identity/roster.rs:594-596`) and cleared
  legacy claims and older-base statements, so nothing older survives to fall back on. Every
  node start then persists the stripped roster: `node/roster_book.rs:205-206`
  `let roster = roster.verified(now_ms());` / `let _ = save(store, &roster, &state, &own, &me);`
  (also every `change_own` and every ingest `fold_in`). With `r_pub` empty,
  `node/crypto_handler.rs:1078` `if pinned_r.is_empty() {` returns true (master suffices), and
  `identity/roster.rs:488` `let same_key = out.r_pub.is_empty() || out.r_pub == incoming.r_pub;`
  adopts the first incoming key. A thief pre-deposits a forged-key `RosterNotice` in the
  identity's inbox mailbox (replayed first on connect) and a master-only order on the kill
  list (delivered at auth). The device itself cannot authenticate while its clock is more than
  60 s off (`relay-uws/src/ws_handler.cpp:291-293`), which is why the start-up save matters: the
  strip happens offline and is used once the clock is right again. The same applies to every
  other identity this device holds a roster for (a contact's clock stepping back strips its
  pins for its friends).
- Breaks: C-01 and C-02 (the master key alone again admits devices and orders destruction at
  that device), AR-15's statement that only first contact can be fooled by a forged recovery key.
- Test: unit in `node/roster_book.rs`: `merge_for_test` a genesis roster dated `T`, then call
  the load path at `T - 11 min` (add a `load_at(store, master, now)` used by `load`) and assert
  `r_pub` and the recovery survive and `destroy_order_authorised(master_only_order, ..)` is
  false; then `ensure_own` at the earlier clock and reload at `T + 1 day`: the recovery must
  still be there. Today both fail (`a_far_future_phrase_statement_is_dropped` covers ingest only).
- Fix: judge freshness only on statements arriving from the network, never on what is stored;
  keep the pinned recovery key in its own column that only a phrase statement under the same key
  can set and nothing clears; refuse to merge an incoming `r_pub` for a master whose stored row
  ever had one.

### C-IDENTITY-03: After any wipe on Windows, the debug log beside the executable keeps the session's history, including "Duress code entered"

- Severity: Medium (Impact M: the log names the duress use and the order flows that followed, and
  keeps up to 10 MB of peer ids, master ids, server and room ids of the wiped identity, i.e. its
  social graph; Exploitability H for P-09 with the disk: a plain file read).
- Attacker: P-09 (coercer, border search, forensic lab) after a duress or remote wipe.
- Confidence: CONFIRMED for `hollow_debug.log`; SUSPECTED for `hollow_crash.log` (depends on
  Dart's Windows share mode, not run).
- Code: the Windows log path is the executable's folder, `rust/hollow_core/src/lib.rs:13-17`
  ```
          if cfg!(target_os = "windows") {