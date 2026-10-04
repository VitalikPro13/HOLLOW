# Phase E+F, slice "local": the device itself (WP8)

Session 34, merged STRIDE + work-package review. Code read in the detached worktree
`D:/dev/wt/s34-ef` at HEAD `aa104d48`. Paths are relative to that worktree unless they name
a package cache. Nothing was built or run. Findings follow the house style: flaw, evidence,
the claim it touches, a fix idea, a test idea. No exploit walkthroughs.

## Scope

- **Attacker:** P-09 in its forms: the holder of a device (locked, or an unlocked OS
  account), a byte copy of the data folder or a disk image, another local process or OS
  user, and a web page or app that hands Hollow a link (X-8). P-03/P-04 appear where a peer
  can place a file the user later opens locally (archive, backup). P-11 is Apple holding an
  OS backup.
- **Elements:** E-01 Flutter UI, E-02 Rust core (process level), E-04 push extension
  (iOS NSE, Android background isolate). Stores E-10 SQLCipher DB, E-11 identity / duress /
  device key files, E-12 HFE1 content files, E-13 OS keystore, E-14 logs.
- **Flows:** F-90 FFI, F-91 core to DB/files/keystore, F-92 loopback media server,
  F-93 deep links, F-94 notifications / clipboard / screenshots, F-95 logs for support,
  F-96 helper processes.
- **Boundaries:** TB-4 (Hollow and the device storage/OS), TB-8 (Hollow and local helpers,
  the loopback server, links from other apps), TB-9 (Rust and Dart).
- **Checklist:** OWASP MASVS v2, L2: STORAGE, CRYPTO, AUTH, NETWORK (local parts),
  PLATFORM, PRIVACY.
- **Leads:** L-07 (App Lock PIN vs offline search), L-12 (loopback media server).
- **Inputs read:** CLAUDE.md, plan 2.2/2.3/2.6/2.7/5/7, threat_model.md, claims.md,
  accepted_risks.md, authz_matrix.md (local rows identity:A-34, transport:A-T00),
  rules_platforms.md, rules_mobile_push.md, rules_files_assets.md, security_write_gates.md
  §6/§8/§12/§13; memories `project_at_rest_file_encryption_plan`,
  `project_identity_protection`, `project_portable_mode`, `project_deep_linking`,
  `project_app_lock_pin_biometric`.

## Summary

- STRIDE cells walked: **58** (3 processes x 6, 5 stores x 3, 7 flows x 3, 2 interactors x 2).
  Met or covered: 31. Candidate: 22. n/a: 5.
- C-LOCAL entries: **23** (C-LOCAL-01..23). Of these, **17 are findings**: High 1,
  Medium 5 (1 SUSPECTED), Low 7 (3 SUSPECTED), Info 4. The other 6 are non-findings,
  accepted risks or by-design notes, kept so the STRIDE cells close.
- Requirements: **40** (R-LOCAL-01..40). ~22 met (16 with a named test, 6 by inspection),
  12 not met (each traced to a finding), the rest met with no test.
- Leads: **L-07 becomes C-LOCAL-04** (the PIN path has no hardware attempt limit; claim
  C-36 is still Undecided, so this is Vitalik's call to promise or accept). **L-12 holds**:
  the loopback server's four gates are sound; two Info residuals.
- Largest item is outside the leads: the "imported archives" viewer, built to open an
  archive another person sends, extracts the archive's attachment files to the names the
  archive itself chooses, with no sanitiser (C-LOCAL-01). The `.hollow` backup import and
  the device-link snapshot import extract the same way.
- App Lock cluster (C-LOCAL-02, 03, 09, 10) has one root cause: the lock is a cover route
  over the Navigator, and surfaces that are not routes under it (OS toasts and their Reply
  action, deep-link dialogs, app-switcher snapshots, the iOS extension) were not placed
  behind it. This is the gap between claim C-35 and the code.
- Wipe cluster (C-LOCAL-05, 06, 08) has another: the wipe is a name allowlist under the
  Rust data root, but Hollow also writes outside it (Windows debug log beside the exe, iOS
  App Group hints and NSE logs, OS temp, OS notification history, `~/Hollow`).

## Candidates

### C-LOCAL-01: an opened archive can write files outside Hollow's folders (CONFIRMED)

- **Severity:** High (Impact H, Exploitability M). **Attacker:** P-03/P-04 (any peer who
  sends a file the victim saves and opens), class 1/data validation.
- **Where:** `rust/hollow_core/src/archive/loader.rs:224` `extract_files_to_temp`, reached
  from `load_archive` (loader.rs:45) and `api/archive.rs:288` `load_archive`, driven by the
  Dart "imported archives" view (`lib/src/ui/archive/imported_archives_view.dart:50`,
  `loadImportedArchive`) and `importedArchiveDataProvider`.
- **Lines (verbatim):**
  ```
  let tmp = std::env::temp_dir().join(format!("hollow-archive-{}", export_timestamp_slug()));
  let _ = std::fs::create_dir_all(&tmp);
  for (name, bytes) in file_data_entries {
      let path = tmp.join(name);
      let _ = std::fs::write(&path, bytes);
  }
  ```
  `name` is the archive's own zip entry name, carried straight from
  `classify_entry` (loader.rs:157, the `files/` arm keeps `rest` as the key). `tmp.join(name)`
  does not confine: a `name` that is absolute or climbs with `..` escapes `tmp`.
- **Why it breaks a claim:** C-29 ("nothing a peer sends can write a file outside Hollow's
  own folders or choose where it lands"). The archive is a peer-authored input; the viewer
  is specifically for archives received from others.
- **Note:** the `zip` crate's `name()` returns the raw name (zip-2.4.2 `src/read.rs:1543`);
  the crate also offers `enclosed_name()` / `mangled_name()`, which this call site does not
  use. `api/updater.rs:1045` and `api/storage.rs:1560` (snapshot import) each have their own
  `..` rejection; this archive path has none. `api/storage.rs` snapshot import
  (`import_snapshot_bytes`, storage.rs:1597) uses `data_dir.join(&name)` with no `..` check
  either, but that path requires the `.hollow` passphrase and overwrites the data root
  wholesale by design (link/backup restore), so its blast radius differs; still worth the
  same guard (tracked as C-LOCAL-06).
- **Fix idea:** route every zip entry name through a sanitiser that rejects absolute paths
  and any non-`Normal` component before `join`, mirroring `safe_file_name()` /
  `final_file_path` and the updater's existing check.
- **Test idea:** a loader unit that feeds an archive whose file entry name is absolute and
  one that climbs with `..`, and asserts nothing lands outside the temp dir
  (`safe_name_blocks_relative_traversal` in share_handler is the model).

### C-LOCAL-02: OS toasts and their Reply action are not behind the app lock (CONFIRMED)

- **Severity:** Medium (Impact M: message content and a send primitive while the device is
  locked; Exploitability M: requires a message to arrive while locked). **Attacker:** P-09.
  Class 13.
- **Where:** `lib/src/core/providers/system_notification_provider.dart:358` `_useNativeToast`
  returns `true` when `appLockedProvider` is set, routing the message to a full OS toast:
  ```
  // Locked is away: the cover hides the in-app card, so the OS toast is the
  // only surface left, exactly as on a phone's lock screen.
  if (ref.read(appLockedProvider)) return true;
  ```
  The toast body is the message preview (`showDm`/`showChannel`,
  `desktop_notification_service.dart:282,321`). On Windows the toast carries an inline
  Reply action (`_showWindows`, desktop_notification_service.dart:441-457) wired to
  `registerReplyHandler` -> `chatProvider.sendMessage` (`hollow_shell.dart:254`), which
  sends "with no window focus needed."
- **Why it breaks a claim:** C-35 ("With App Lock on, no message content, name or
  notification is visible until unlock"). A desktop app lock (the UI cover, node still
  running) deliberately keeps delivering; routing to the OS toast shows sender name and the
  preview on the locked screen, and the Reply action lets a message be sent from the locked
  device. The in-app `NotificationOverlay` is correctly suppressed
  (`notification_overlay.dart:31`); only the OS-toast branch is the leak.
- **Design tension:** CLAUDE.md and the memory call the desktop lock "the phone model"
  (UI lock, node alive), and the code comment treats the OS toast as equivalent to a phone
  lock-screen banner. On a phone the OS enforces lock-screen privacy; on desktop the OS
  toast appears over a Hollow-drawn cover that the OS does not know is a lock. C-35 is a
  per-claim decision for Vitalik: either suppress content toasts while locked (hold them,
  like the mobile tap, and replay on unlock) or narrow C-35 to the phone.
- **Fix idea:** while `appLockedProvider` is set, suppress the content toast (or post a
  contentless "New message in Hollow" one) and drop the Windows Reply action; replay held
  cards on unlock as the mobile tap already does.
- **Test idea:** a widget/unit test that asserts `_useNativeToast` + the toast body carry no
  preview and no Reply action while locked.

### C-LOCAL-03: a deep link opens its dialog over the app lock cover (SUSPECTED)

- **Severity:** Medium (Impact M, Exploitability M). **Attacker:** P-09 with the device
  plus X-8 (another local app or a browser page firing `hollow://`). Class 13.
- **Where:** `lib/src/core/services/deep_link_service.dart:93` `_onUri` gates only on
  `_shellReady` and the navigator existing, never on `appLockedProvider`; `_handle`
  (deep_link_service.dart:103) pushes `showHollowDialog`/`PasteLinkDialog`
  (`:132`) and the join confirm dialogs onto `hollowNavigatorKey`. The roster lock and the
  mobile push tap both gate on `appLockedProvider` (`hollow_shell.dart:504`,
  `mobile_shell.dart:83`), but the deep-link path has no such guard.
- **Why it matters:** a dialog pushed onto the navigator sits under the desktop lock cover
  route (`lock_cover.dart:14`, `opaque: true`), so on desktop the cover hides it and it
  surfaces on unlock, which is acceptable. The risk is mobile, where there is no opaque
  cover route (the mobile lock is `MobileShell` holding taps, `mobile_shell.dart`); a
  `hollow://` link delivered while locked could present its confirm dialog above the lock.
  Marked SUSPECTED: I did not drive a mobile build to confirm the dialog paints above the
  mobile cover.
- **Why it breaks a claim:** C-35 ("nothing appears above the lock screen").
- **Fix idea:** in `_onUri`, buffer into `_pending` while `appLockedProvider` is set and
  flush on unlock, matching `_holdWhileLocked` in mobile_shell.
- **Test idea:** a widget test that fires a `hollow://join` link while locked and asserts no
  route is pushed until unlock.

### C-LOCAL-04: the App Lock PIN has no hardware-enforced attempt limit (CONFIRMED; lead L-07)

- **Severity:** Medium (Impact H if a short PIN is used, Exploitability M: needs the data
  dir copy). **Attacker:** P-09 with a byte copy of the data folder. Class 11/AUTH.
- **Where:** a PIN is fed through the identity password pipeline
  (`api/identity.rs:212` `enable_password_protection` with `require_on_launch: true` for a
  phone PIN, `security_section.dart:601`). The wrapping key is Argon2id m=64 MiB, t=3, p=1
  (`identity/encryption.rs:102`) over the typed secret; the identity file is the only thing
  that must be unwrapped to test a guess (`encryption.rs:149` `decrypt_blob`). The PIN floor
  is 4 digits (`security_section.dart:127`), max 8 (`security_section.dart:194`). The unlock
  dialog has no attempt counter or backoff (`identity_unlock_dialogs.dart` `UnlockDialog`
  carries only a `wrong` flag).
- **Why it matters:** with a copy of `identity.key` the guess space of a 4-digit PIN is
  10^4. Argon2id at 64 MiB per guess is the only brake; there is no secure-element rate
  limit and no lockout. This is exactly the lead's concern: "A 4-6 digit PIN through
  Argon2id alone falls to an offline search." The identity password mode's KDF is the same
  Argon2id, and the SQLCipher key is derived separately as the first 32 bytes of the
  master-key protobuf (`api/storage.rs:68` `derive_db_key`), so the DB is only as protected
  as the identity file, not by an independent KDF.
- **Why it breaks a claim:** C-36 ("Someone holding my locked phone cannot guess my App
  Lock PIN by copying the app's data") is marked **Undecided** in claims.md pending this
  lead. The code does not currently support promising C-36 for a short numeric PIN.
- **Fix idea:** two options for Vitalik. (a) Bind the unlock secret into a
  hardware-backed keystore gate with an attempt limit: iOS `AccessControlFlag.devicePasscode`
  / biometry on the secure-storage item (the `flutter_secure_storage` 10.3.1 Apple options
  expose this, `apple_options.dart` `AccessControlFlag`), Android `AndroidOptions`
  StrongBox/user-auth binding, and accept the PIN only through that gate. (b) Keep the PIN
  for convenience but require a long password as the real at-rest secret, and document C-36
  as not promised for a short PIN (accepted risk). Either way the decision belongs in
  claims.md.
- **Test idea:** none possible in the unit layer for the hardware limit; a guard that the
  secure-storage item is created with the user-auth / passcode access-control flag.

### C-LOCAL-05: a destroy/duress wipe leaves readable files outside the Rust data root (CONFIRMED)

- **Severity:** Medium (Impact M: residual plaintext metadata and content after a wipe the
  user believes was complete; Exploitability M: needs the device afterward). **Attacker:**
  P-09. Class 11, PRIVACY.
- **Where:** `api/wipe.rs:16` `WIPE_ENTRIES` and `:28` `KEY_FILES` are name lists joined onto
  the data root (`destroy_data_root`, wipe.rs:49). The Dart post-wipe step
  (`destroy_flow.dart:11` `clearLocalSecretsAfterDestroy`) clears the OS keystore via
  `AppLockService().clearAll()` and unregisters push, but nothing clears:
  - the Windows debug log, which lives next to the exe, not under the data root
    (`lib.rs:14` `std::env::current_exe()...join("hollow_debug.log")`), while the wipe only
    removes `hollow_debug.log` under the data root (wipe.rs:22);
  - the iOS NSE metrics log and heartbeat under `<AppGroup>/push_diag/`
    (`NotificationService.swift` `log`, `ios_data_dir_migration.dart:78`), and the App Group
    push-hints cache `<AppGroup>/push_hints/hints.json` plus per-friend `*.img`
    (`push_hints_cache.dart:76`), all the PARENT of the data dir, which the wipe never walks;
  - the Dart push line cache `push_lines.json` and `push_debug.log`, written under a
    `hollow/` subdir of the app documents dir (`push_notification_service.dart:40,265`);
  - OS notification history / delivered banners (no `cancelAll` on wipe);
  - OS temp artefacts (see C-LOCAL-07).
- **Why it matters:** the wipe's own contract (`project_at_rest_file_encryption_plan`,
  security_write_gates §13: "ONE wipe routine... destroy keys first... unlink dirs") is
  understood by the user as "wipe = files dead." Push hints carry friend display names and
  avatars in the clear; logs carry ids, server names, channel names and file names (see
  C-LOCAL-11). These survive a wipe.
- **Why it breaks a claim:** supports C-02/C-07 (duress/destroy leaves nothing the holder
  can read) and C-37 (logs). The master keys are gone, so SQLCipher and HFE1 content are
  cryptographically dead; the leak is the plaintext-by-design side files.
- **Fix idea:** extend the wipe to the App Group container parent on iOS, the exe-adjacent
  log on Windows, the documents `hollow/` push caches, and a `flutter_local_notifications`
  `cancelAll()` + `removeAllDeliveredNotifications`. Enumerate once in `WIPE_ENTRIES` plus a
  Dart-side companion list.
- **Test idea:** extend `wipe_routine_is_idempotent_and_marker_resumes` (wipe.rs:212) to
  seed an exe-adjacent log and an App-Group-style sibling and assert both are gone; a Dart
  test that the post-destroy flow calls `cancelAll`.

### C-LOCAL-06: the backup/link snapshot import does not sanitise zip entry names (CONFIRMED)

- **Severity:** Medium (Impact H if reached, Exploitability L: needs the `.hollow`
  passphrase or a completed link handshake). **Attacker:** P-04 who can hand a crafted
  `.hollow` file plus its passphrase, or a malicious link presenter. Class 1.
- **Where:** `api/storage.rs:1597` `import_snapshot_bytes`:
  ```
  let name = entry.name().to_string();
  let out_path = data_dir.join(&name);
  ```
  No `..`/absolute check (unlike the updater, `api/updater.rs:1048`). This path is gated by
  the AES-GCM passphrase (the link code via SPAKE2, or the user's backup passphrase) and is
  meant to replace the data root wholesale, so it is far less exposed than C-LOCAL-01, but a
  crafted entry name still writes outside the data root.
- **Why it breaks a claim:** C-29. The link snapshot in particular comes from a device the
  user is pairing with, not necessarily one they fully trust yet.
- **Fix idea:** the same sanitiser as C-LOCAL-01, applied before `data_dir.join`.
- **Test idea:** a unit feeding a snapshot zip with a climbing entry name, asserting the
  write stays under the data root.

### C-LOCAL-07: plaintext temp files from paste, save-as and video thumbnails are not cleaned or encrypted (CONFIRMED)

- **Severity:** Low (Impact M, Exploitability M). **Attacker:** P-09 / another local user.
  Class 11, STORAGE.
- **Where:**
  - Clipboard image paste writes the bytes to the OS temp dir and never deletes them
    (`chat_input_shortcuts.dart:124-130`, `Directory.systemTemp`, no cleanup;
    `onPasteImage` just stages the path).
  - Save-as on a phone writes decrypted bytes to `getTemporaryDirectory()` then hands them to
    the save sheet; this one deletes in a `finally` (`export_to_file.dart:45-58`) and
    `backup_section.dart:_exportOnPhone` stages under the data root and removes via AtRest
    (`backup_section.dart:79,113`) — those two are fine.
  - Video send stages a thumbnail under `Directory.systemTemp.createTemp` and (in the arm I
    read) does not delete it (`file_transfer_provider.dart:421`).
  - Desktop notification avatars and the tray icon are written to `systemTemp` unencrypted
    (`desktop_notification_service.dart:234,385,425`, `tray_service.dart:149`) — avatars are
    low-sensitivity but are a copy outside the encrypted store.
- **Why it matters:** `project_at_rest_file_encryption_plan` already lists "recording in
  progress is plaintext in temp/" as a known residual and the boot sweep empties
  `data_dir()/temp` (`at_rest.rs:605` `wipe_temp_dir`), but these OS-temp writes are outside
  `data_dir()/temp`, so neither the sweep nor the wipe reaches them.
- **Why it breaks a claim:** C-30 ("content files at rest are unreadable without the
  identity") in spirit; these are content copies at rest in the clear.
- **Fix idea:** paste and video-thumbnail temps should stage under `data_dir()/temp` (swept
  at boot and removed on wipe) or be deleted in a `finally`; the save-as pattern already
  shows the right shape.
- **Test idea:** a unit asserting the paste/thumbnail stage path is under the data root, or
  that the file is removed after the send completes.

### C-LOCAL-08: a crash between wipe steps can leave an identity that still loads (SUSPECTED)

- **Severity:** Low (Impact M, Exploitability L). Class 11.
- **Where:** `destroy_data_root` (wipe.rs:49) writes the marker first, then removes key
  files, then the DB, then content; `load_or_create_identity` refuses to mint a new identity
  while the marker is present (`identity/keys.rs:183`), and `perform_pending_wipe`
  (storage.rs:1875) finishes the job at next launch. The window I could not fully rule out:
  the marker is written, but if `stash` of the marker itself fails (disk full), the process
  continues and partially removes keys, leaving `identity.key` gone but content and DB
  present, with no marker to resume. The code treats the marker write as fatal
  (`?` at wipe.rs:51), so this is narrow. Marked SUSPECTED: I did not construct the failure.
- **Fix idea:** none needed if the marker write is truly the first fallible step; worth a
  one-line confirmation that nothing destructive precedes it (it does not today).
- **Test idea:** the existing `wipe_routine_is_idempotent_and_marker_resumes` already covers
  the marker-resumes path; add a case where the DB is replaced after the key step (it
  already does) — effectively covered.

### C-LOCAL-09: the iOS app-switcher snapshot and screenshots are not blocked on sensitive screens (SUSPECTED)

- **Severity:** Low (Impact M: the recovery phrase or chat visible in the app-switcher
  thumbnail / a screenshot; Exploitability M). **Attacker:** P-09. Class 13, PLATFORM.
- **Where:** no `FLAG_SECURE` on Android (`MainActivity.kt` sets no
  `WindowManager.LayoutParams.FLAG_SECURE`; grep for `FLAG_SECURE` across the repo returns
  nothing), and no iOS `applicationWillResignActive` blur / snapshot cover in
  `AppDelegate.swift`. The recovery phrase is shown in `mnemonic_dialog.dart`
  (`RecoveryPhraseGrid`, mnemonic_dialog.dart:224) and the phrase-upgrade dialog; both are
  in a `SelectionArea` with a Copy button, with no screenshot guard.
- **Why it matters:** MASVS-STORAGE-2 (sensitive data not in the app-switcher snapshot) and
  the general principle that the recovery phrase screen is the most sensitive in the app.
  The App Lock cover does not help here: the OS snapshot is taken on background, which is
  also when the mobile lock arms, but the snapshot captures the frame before the cover.
  Marked SUSPECTED: Flutter's default behaviour and whether the mobile cover is up at
  snapshot time need a device check.
- **Why it breaks a claim:** C-35 (nothing visible until unlock) and the recovery phrase's
  own secrecy.
- **Fix idea:** `FLAG_SECURE` on the Android activity (at least while the phrase dialog or
  a chat is shown), and an iOS snapshot cover view on `sceneWillResignActive`.
- **Test idea:** device-level, not unit; note it for the fleet/mini pass.

### C-LOCAL-10: the recovery phrase and chat text are copied to the OS clipboard with no auto-clear (CONFIRMED)

- **Severity:** Low (Impact M, Exploitability M: another local app reads the clipboard).
  **Attacker:** P-09 / X-8. Class 13, PRIVACY.
- **Where:** the phrase Copy button writes the mnemonic to the clipboard with no timed clear
  (`mnemonic_dialog.dart:152` `Clipboard.setData(ClipboardData(text: widget.mnemonic))`);
  the same pattern copies message text, master ids, server ids, redeem codes, safety hashes
  and invite links across the UI (26 sites, e.g. `chat_pane.dart:1667`,
  `redeem_code_dialog.dart:257`). On Android 12+ the OS shows a clipboard-access toast but
  does not clear; other apps and the clipboard history can read it.
- **Why it matters:** the recovery phrase is the identity root (`project_identity_authority`).
  A clipboard copy of it persists until overwritten and is readable by any app with
  clipboard access (and cloud clipboard sync where enabled).
- **Fix idea:** for the phrase specifically, either drop the Copy button (the dialog already
  pushes "write it down") or clear the clipboard after a short delay and mark the item
  sensitive (`ClipboardData` has no sensitivity flag in Flutter; Android
  `ClipDescription.EXTRA_IS_SENSITIVE` needs a platform channel).
- **Test idea:** a widget test asserting the phrase dialog schedules a clipboard clear, or a
  design-guard that the phrase dialog has no Copy button.

### C-LOCAL-11: logs record names, ids, server/channel names and file names (CONFIRMED)

- **Severity:** Low (Impact M, Exploitability M: the debug-log export is user-shareable for
  support). **Attacker:** P-09, and the support channel the user sends logs to. Class 13,
  PRIVACY.
- **Where:** `hollow_log!` writes to `hollow_debug.log` (`lib.rs:64`). Log sites record:
  profile display name (`swarm.rs:13252` `ProfileUpdate from {peer_str}: name={display_name}`),
  server and channel names (`api/network.rs:671,677,683,698`,
  `sync_handler.rs:710,939`), file names (`swarm.rs:8573`, `file_handler.rs:3078`
  `FileHeader received: {fid} ({name}, ...`), vault file names (`vault_ops.rs:252`), peer and
  master ids throughout, and `nickname` claims (`ws_client.rs:1602,1615`). The debug-log
  export button concatenates the tail of `hollow_debug.log` and the push logs into one file
  the user saves and sends (`about_section.dart:271-277`).
- **What is clean:** no message text, link codes, passwords, phrases, PINs or keys reach the
  log. `handlePushWake` logs only whitelisted routing keys and warns never to add content
  (`push_notification_service.dart:297`); the kill-signal log says nothing identifying
  (`ws_client.rs:1636`); the NSE never logs decrypted JSON
  (`NotificationService.swift`, "PRIVACY: never log the decrypted JSON"); link codes are not
  logged by value on the claim/resolve path (`link_handler.rs:78,91,129`), though
  `ws_client.rs:1620` does log `Link code claimed: {code}` and `:1632` `resolved: {code}` —
  the 6-char rendezvous half plus the 4-char secret, which is Info-level since the code is
  single-use and dead after the handshake.
- **Why it breaks a claim:** C-37 ("Logs never contain message content, keys, codes or
  passphrases") holds literally (no content/keys/passphrases), but names and the link code
  are metadata a support recipient was not meant to see. CLAUDE.md's logging rule exempts
  comments/logs from the no-content rule, so this is a privacy-of-metadata note, not a C-37
  break.
- **Fix idea:** the export path (not the local log) should redact names and ids to short
  hashes, since that file is the one that leaves the device; and drop the `{code}` from the
  two `ws_client.rs` link lines.
- **Test idea:** a source-scan guard that the two link-code log lines carry no `{code}`, and
  a review of the export redaction.

### C-LOCAL-12: a disk copy plus the unlocked OS account reads the loopback media port and token (CONFIRMED; L-12 residual, already accepted)

- **Severity:** Info. **Attacker:** another local process as the same user. Class 13.
- **Where:** `node/at_rest_server.rs` binds `127.0.0.1` (`:62`), gates on a 32-byte
  per-process token compared in constant time (`:246`), confines to the canonicalised data
  root (`:251-256`), GET/HEAD only, 8 KiB head cap, 30 s idle, 64 connections. All four
  gates are present and correct. The residual is already written in security_write_gates
  §12: "another process running as the same user can read the port and, given the token,
  fetch a file. That process could already read the SQLCipher key material and the
  ciphertext itself." The token is not persisted; a web page cannot reach it (no CORS
  surface, path-prefix token, and a DNS-rebinding `Host` header is irrelevant because the
  first path segment must equal the random token, which a remote page cannot learn).
- **Verdict:** L-12 holds. No Host-header check is needed because the token, not the Host,
  is the gate and the bind is loopback-only. No action.

### C-LOCAL-13: loopback server has no `Host` header check (Info, defence-in-depth)

- **Severity:** Info. **Where:** `at_rest_server.rs:138` `parse_request` reads the request
  line and `Range`/`Connection` only; it ignores `Host`. As above, the unguessable path
  token is the real gate, so DNS rebinding from a browser cannot work (the page cannot
  supply the token). Noting only that if the token gate were ever weakened, a `Host` check
  would be the backstop. No action now.

### C-LOCAL-14: FFI exposes no remote-reachable authorisation-only-in-Dart decision (CONFIRMED, non-finding; F-90/TB-9)

- Walked the FFI surface for "a decision made only in Dart that a crafted frame could reach"
  (plan Q for F-90). The security-relevant gates all live in Rust: the auto-download gate is
  in Dart but only decides whether to PULL (`project_autodownload_gate`, pushes are refused
  in Rust); channel access reads `ChannelFfi.me_can_see/me_can_post` from Rust
  (`project_channel_access_labels_grants`); the destroy/duress decision is entirely in
  `node::destroy::judge_own_order`. The profile-erase gate and the wipe are Dart-driven but
  act only on the local user's own request, not a remote frame (authz_matrix identity:A-34).
  No candidate.

### C-LOCAL-15: helper process arguments are not built from remote input (CONFIRMED, non-finding; F-96)

- `screen_audio_capturer`/renderer args are pids and window handles the local app computes
  (`screen_audio_capturer.dart:95-118`); ffmpeg is fed ciphertext over stdin and reads
  `pipe:0`, never a remote-named path, with every flag constrained to the minimal build
  (`video_thumbnail_service.dart:175`, `.github/workflows/build-ffmpeg.yml` protocols
  file+pipe only); `reveal_in_folder`/`explorer.exe /select` take a local file path, not a
  remote string; the Windows `hollow://` registry self-heal runs `reg.exe` with fixed args
  (`deep_link_service.dart:295`). The Android launch `--unifiedpush-bg` arg is checked
  against intent extras, but `FlutterShellArgs.fromIntent` (Flutter engine) only maps a
  fixed allowlist of debug flags from a boolean extra, and `main(args)` only reads
  `--portable` and `--unifiedpush-bg`, so a crafted intent cannot inject an arbitrary arg.
  No candidate.

### C-LOCAL-16: Android backup / device-transfer are correctly disabled (CONFIRMED, non-finding)

- `allowBackup=false`, `fullBackupContent=false`, `dataExtractionRules` excludes every
  domain from cloud backup and device transfer (`AndroidManifest.xml:31-33`,
  `res/xml/data_extraction_rules.xml`). iOS App Group data is not excluded from iCloud
  backup, which is the next item.

### C-LOCAL-17: iOS does not mark the data dir no-backup, nor set file protection class (SUSPECTED)

- **Severity:** Low (Impact M: an iCloud/iTunes backup of the device carries the encrypted
  store and identity file; Exploitability L: the files are encrypted at rest when a
  password/keychain mode is on, but mode "none" ships plaintext). **Attacker:** P-11 / anyone
  with the device backup. Class 12 (cloning).
- **Where:** the iOS data dir is the App Group container `<AppGroup>/hollow_data`
  (`ios_data_dir_migration.dart:38`), with no `isExcludedFromBackup` resource value set and
  no explicit `NSFileProtectionComplete`. On Android the equivalent is handled by the backup
  rules above; iOS has no equivalent in the repo. Marked SUSPECTED: App Group containers may
  be excluded from backup by default on some iOS versions, and keychain items (the wrapping
  key) migrate per the `KeychainAccessibility.unlocked` default, which is the correct
  non-migrating-or-not question for C-05/C-06.
- **Why it matters:** C-06 ("A copy of my identity file is useless without my machine
  (keychain mode) or my password") depends on the keychain item not travelling in a backup.
  `flutter_secure_storage` 10.3.1 defaults to `KeychainAccessibility.unlocked`
  (`apple_options.dart:72`), which DOES migrate to a new device; `unlocked_this_device` and
  `first_unlock_this_device` do not. The app-lock launch secret and biometric secret use the
  default (`app_lock_service.dart:28` constructs `FlutterSecureStorage` with only
  `aOptions`, no `iOptions`/`mOptions`), so on iOS they are backup-and-migrate by default.
  The Rust-side keychain (identity wrapping key) on macOS uses `security_framework` generic
  passwords with no `kSecAttrAccessible` set (`platform_keystore.rs:210`), defaulting to a
  migrating class; on Windows it uses `CRED_PERSIST_LOCAL_MACHINE` (`platform_keystore.rs:84`),
  which is machine-local and does not roam.
- **Fix idea:** set `IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device)`
  (and the macOS equivalent) on the `AppLockService` secure storage and on the Rust macOS
  keychain item, and mark the iOS data dir `isExcludedFromBackup`. This makes C-06 true on
  iOS/macOS (the wrapping key cannot leave the device).
- **Test idea:** device-level; note for the mini pass. A source guard that the secure
  storage is constructed with a this-device accessibility class.

### C-LOCAL-18: notification content survives on the lock screen and in history on both phones (CONFIRMED, overlaps C-LOCAL-02)

- **Severity:** Low. **Where:** mobile push banners post the message preview with
  `InterruptionLevel.active`/`Importance.high` and no lock-screen visibility restriction
  (`push_notification_service.dart:1099-1135`); the iOS NSE rewrites the banner to the real
  decrypted text (`NotificationService.swift` Tier B). This is by design (the app's whole
  push value), and the OS lock screen is the user's own device policy, so it is not a Hollow
  bug the way the desktop toast (C-LOCAL-02) is. Noted so the STRIDE cell is closed: on a
  phone, content on the lock screen is the OS's call; C-35 is about the app's own App Lock,
  which these banners pre-date (they fire when the app is backgrounded, not locked).
  No separate action beyond C-LOCAL-02's decision on whether the App-Lock state should also
  suppress push content.

### C-LOCAL-19: the push-hints cache stores friend names and avatars in the clear in the App Group (CONFIRMED)

- **Severity:** Info. **Where:** `push_hints_cache.dart:76` writes `hints.json`
  (`{peerId: {name, avatar, relay}}`) plus per-friend `*.img` into
  `<AppGroup>/push_hints/`, plaintext. The file is documented as "Plaintext the user already
  displays, contained to the app-private group container, never iCloud-synced." The
  "never iCloud-synced" claim is the C-LOCAL-17 question (not independently enforced). This
  is the iOS mirror of the desktop avatar cache and is low-sensitivity, but it is friend
  display names and avatars at rest outside the encrypted store, and it is not cleared on
  wipe (C-LOCAL-05).
- **Fix idea:** fold the `push_hints` dir into the wipe; optionally mark it no-backup with
  the data dir.

### C-LOCAL-20: an unlocked running device reads everything (CONFIRMED, accepted AR-04)

- Out of scope by AR-04 ("a compromised unlocked running device"). The loopback token, the
  session wrapping key in process memory (`encryption.rs:13` `SESSION_KEY`), and the open
  SQLCipher handle are all reachable by code running as the user while Hollow is unlocked.
  Matches the AR's description. No action.

### C-LOCAL-21: no remote-triggered panic found in the local parsers walked (CONFIRMED, non-finding)

- The at-rest format parser rejects a short or bad header rather than panicking
  (`at_rest.rs:170,193`), uses `div_ceil`/`saturating_sub` for lengths, and
  `read_exact` errors are returned not unwrapped. The loopback server's `parse_request`
  and `parse_range` return `None`/416 on malformed input (`at_rest_server.rs:138,271`).
  The archive loader skips malformed entries with a log, never unwraps
  (`loader.rs:177,197`). The duress `probe` returns `None` on any mismatch
  (`duress.rs:125`). No `unwrap`/`expect`/slice-index on attacker-length-controlled local
  input found in these paths. (Remote-frame panics are other slices' territory.)

### C-LOCAL-22: the desktop tray and "Open in folder" act without the app lock (SUSPECTED, Info)

- **Severity:** Info. **Where:** the tray menu (`tray_service.dart:216` `onTrayMenuItemClick`)
  offers Mute/Deafen/Leave/Settings/Quit while the window is hidden; none check
  `appLockedProvider`. Open/Settings only restore the window and set a tab
  (`settings_place_provider.dart:31`, which sets the shell tab, not a route above the cover),
  so the cover still sits on top; Mute/Deafen/Leave act on a live call. These are not
  content disclosures and a call in progress blocks the lock anyway
  (`app_lock_provider.dart:49` `appLockBusyProvider`), so this is Info. Noted for
  completeness of the TB-8 surface.

### C-LOCAL-23: profile-erase of another profile is gated, but a keychain-mode profile on the same machine erases with no prompt (CONFIRMED, by design)

- **Where:** `profile_locations_card.dart:228` `_eraseChallengeFor`: a password-protected
  foreign profile needs its password; a keychain-only one erases if this machine can unwrap
  it (`verifyIdentityPasswordAt`), else needs the name typed. This is the documented design
  (the machine that can silently unlock it has proved as much as a prompt would). Correct;
  noted so the FFI `identity_protection_status_at` / `verify_identity_password_at` surface is
  walked. These two FFIs read a foreign profile's `identity.key` directly and never touch the
  session key or heal the keystore (`api/identity.rs:664,676`), which is the right isolation.

## Leads

- **L-07 (App Lock PIN vs offline search):** FINDING C-LOCAL-04. The secret is wrapped by
  Argon2id only; there is no hardware attempt limit and no lockout, and the PIN floor is 4
  digits. With a data-dir copy a short PIN falls to an offline search bounded only by the
  64 MiB-per-guess Argon2id cost. The identity-password KDF is the same Argon2id
  (`encryption.rs:102`); the SQLCipher key is the first 32 bytes of the master protobuf
  (`storage.rs:68`), so the DB inherits the identity file's protection rather than a separate
  KDF. C-36 is Undecided in claims.md; this finding is the input to that decision. Fix
  options in C-LOCAL-04.
- **L-12 (loopback media server):** HOLDS. `node/at_rest_server.rs` binds `127.0.0.1` only
  (never `0.0.0.0`/`::`), gates every request on a 32-byte per-process token compared in
  constant time, confines the path to the canonicalised data root with `Normal`-only
  components, allows GET/HEAD only, caps the head at 8 KiB, drops idle sockets at 30 s and
  caps at 64 connections, and logs nothing about a path. A web page cannot read the token, so
  DNS rebinding / CORS do not apply; a local process as the same user already outranks the
  server (AR-04 / §12 residual, C-LOCAL-12). One range per request, 416 on multi-range, body
  streamed a chunk at a time. Unit `at_rest_server_range_semantics` covers ranges, token and
  traversal. Residuals C-LOCAL-12/13 are Info, already accepted or defence-in-depth.

## Protocol checklist

No wire protocol (MLS/SFrame/Olm) is in this slice; those are other slices'. The applicable
checklist is OWASP MASVS v2 L2, applied to the local surface:

- **MASVS-STORAGE-1** (no sensitive data in unintended locations): partial. Content and the
  DB are HFE1/SQLCipher-encrypted (met, `at_rest.rs`, `storage.rs:508`). Gaps: OS-temp paste
  and thumbnail copies (C-LOCAL-07), push-hints plaintext (C-LOCAL-19), logs with names
  (C-LOCAL-11).
- **MASVS-STORAGE-2** (no sensitive data in backups / app-switcher): Android met
  (backup disabled, C-LOCAL-16); iOS no-backup not set (C-LOCAL-17); app-switcher snapshot
  not covered (C-LOCAL-09).
- **MASVS-CRYPTO-1/2** (strong keys, no hardcoded): met. AES-256-GCM per-file keys
  (`at_rest.rs`), Argon2id m=64 MiB wrapping (`encryption.rs:102`), random device keys
  (`device_key.rs`), no hardcoded secrets found.
- **MASVS-AUTH-1/2** (local auth bound to a hardware-backed mechanism with attempt limits):
  NOT met for the PIN (C-LOCAL-04); biometric unlock is a layer over the secret, correctly
  gated by `local_auth` with a live prompt (`app_lock_service.dart:128`), but the underlying
  secret is not hardware-rate-limited.
- **MASVS-NETWORK (local)**: met. Loopback cleartext is the only exception and is
  allowlisted exactly to `127.0.0.1` (`network_security_config.xml`, iOS/macOS
  `NSAllowsLocalNetworking`); everything else is TLS-only.
- **MASVS-PLATFORM-1/2/3** (IPC, WebViews, sensitive UI): no WebView in the app
  (none in pubspec); deep links go through one classifier (`classifyHollowLink`); the gap is
  the deep-link confirm over the mobile lock (C-LOCAL-03) and the unguarded screenshot
  surface (C-LOCAL-09).
- **MASVS-PRIVACY-1/2/3**: logs and clipboard leak metadata (C-LOCAL-10, 11); notifications
  show content while locked on desktop (C-LOCAL-02).

## The 13 bug classes, applied locally

1. **Authenticated but not authorised.** Local analogue: a UI action that should need the
   owner's secret. The duress-code change and the foreign-profile erase both gate on an
   owner proof (`owner_gate`, identity.rs:387; `_eraseChallengeFor`,
   profile_locations_card.dart:228). Nothing found that acts on another profile's data
   without a per-profile unlock proof. Clean.
2. **Infrastructure controls membership/device lists.** Not a local-store concern; the push
   fetch node and NSE warm the roster/blocklist before judging (transport:A-T00), so a
   locally-running fetch process does not treat relay data as authority. Clean here.
3. **Split view.** n/a locally (one device's own store).
4. **Withheld/rolled-back revocation.** The destroy/kill state is the local analogue; the
   applied stamp is in-process by design (`destroy.rs`, L-06 is another slice). The App Lock
   "stale secret self-heal" (`app_lock_service.dart`, `hollow_shell.dart:650`) deletes a
   stored secret that fails to unlock, which is the right direction. Clean.
5. **Identifier/key-type confusion.** The device key is always fresh-random and rotated if
   it ever equals the master (`device_key.rs:49`); the DB passphrase is master-derived and
   the WS/keychain use the device key, kept distinct (`push_enrich.rs:109-116`). No confusion
   of the two found in the local key derivations.
6. **Channel confusion.** Local analogue: a file read through one path that should go through
   another. `AtRest.read`/`read_range`/`export` are the one read primitive, and Dart is told
   never to open a data-root file with `dart:io`. One `Image.file` on a saved download
   (`download_manager_popup.dart:309`) reads a user-chosen save location outside the data
   root (plaintext by design, the Save-as copy), so it is not a bypass. Nothing reads an
   HFE1 file with raw `dart:io`. Clean.
7. **Unknown key-share / misbinding.** n/a to local stores.
8. **Replay/reorder/deletion.** The at-rest format binds uid, chunk index and a last flag in
   the AAD (`at_rest.rs:228`), so a chunk cannot be moved, duplicated or truncated
   undetected (`at_rest_tamper_in_any_chunk_is_detected`, `at_rest_truncation_is_detected`).
   The Writer refuses a differing rewrite of a sealed chunk (nonce reuse,
   `at_rest_writer_refuses_a_differing_rewrite_of_a_chunk`). Clean.
9. **Downgrade / length checks.** HFE1 pins `VERSION` and rejects a mismatch
   (`at_rest.rs:171`); the HKEYV1 identity format detects the plaintext protobuf header and
   the magic, with a length floor (`encryption.rs:52-57`). A file whose key row is gone is an
   error, never served as raw bytes (`at_rest.rs:275`, `read_all`). No "absent = legacy,
   accept" path found in the local formats.
10. **Unauthenticated metadata.** The HFE1 header's chunk_size and uid are not themselves
    authenticated, but they only select the key and chunk layout; a tampered header yields a
    wrong uid (missing key -> error) or a wrong chunk_size (chunk auth fails). The identity
    flags byte is outside the AES-GCM, but changing it only changes which unlock path is
    tried, not whether the ciphertext opens. Acceptable; noted.
11. **State/key lifecycle.** The wipe marker resumes a crashed wipe
    (`wipe_routine_is_idempotent_and_marker_resumes`); the file key row is written before any
    ciphertext so a crash leaves at worst an orphan row (`at_rest.rs:140`); the migration
    sweep is resumable by header inspection (`at_rest_migration_resumes_from_every_crash_point`).
    Gap: the wipe's name allowlist misses files outside the data root (C-LOCAL-05), and a
    crafted archive/snapshot name escapes the extraction dir (C-LOCAL-01, 06).
12. **Cloning via backup/export.** Android backup and device transfer are disabled
    (C-LOCAL-16); iOS no-backup and this-device keychain class are not set (C-LOCAL-17), so
    an iOS device backup can carry the keychain wrapping key and defeat C-06. The `.hollow`
    export and the link snapshot are the sanctioned clone paths and are passphrase/SPAKE2
    gated.
13. **What a stranger can trigger or observe.** A web page or local app can fire a
    `hollow://` link; the join/share/redeem handlers all require an on-screen confirm
    (`deep_link_service.dart:_handle`), EXCEPT the share link, which auto-runs its discover
    step on paste (`paste_link_dialog.dart:48-53` -> `_onOpen`) — this is a local discover
    (`shareDecodeLink` is local) and still requires a Download tap before bytes land, so it
    is not an unconfirmed action, but it does start a relay request from a link another app
    supplied. Noted (R-LOCAL-33). The deep-link dialog over the mobile lock is C-LOCAL-03.

## STRIDE grid

Processes get S,T,R,I,D,E; stores and flows get T,I,D; interactors get S,R.

**E-01 Flutter UI (process)**
- S: n/a (no network identity of its own; FFI only). | T: UI cannot be tampered remotely;
  TB-9 means Dart must not be the sole gate — walked, C-LOCAL-14 non-finding. | R: n/a. |
  I: content on the lock cover via OS toast (C-LOCAL-02), deep-link dialog over the mobile
  lock (C-LOCAL-03), clipboard (C-LOCAL-10), app-switcher snapshot (C-LOCAL-09). |
  D: a lock loop that never lifts — `_runLockFlow` re-prompts and a call blocks the lock
  (`app_lock_provider.dart:49`); clean. | E: the profile-erase and duress-change gates
  (met); no Dart-only authorisation of a remote action (C-LOCAL-14).

**E-02 Rust core (process)**
- S: relay auth is another slice; locally the session key gates every identity op
  (`unlock_identity`), met. | T: the at-rest format and identity format reject tampering
  (classes 8/9, met). | R: logs record who/what, with names (C-LOCAL-11). | I: the loopback
  server (L-12, holds); logs (C-LOCAL-11). | D: no remote-input panic in the local parsers
  (C-LOCAL-21). | E: the wipe/destroy decision is in Rust, not Dart (met).

**E-04 push extension (iOS NSE, Android isolate)**
- S: the NSE loads the existing identity only, never mints one (`push_enrich.rs:102`); DB
  passphrase master-derived, WS auth device-keyed, correct. | T: it decrypts on a forked Olm
  session without advancing the canonical ratchet (`olm_manager.rs:657` spike tests); clean.
  | R: NSE logs metrics, never decrypted JSON. | I: the NSE writes the decrypted banner to
  the lock screen by design; the heartbeat/metrics/hints files are plaintext and survive a
  wipe (C-LOCAL-05, 19). | D: the NSE respects the ~24 MB cap and the 30 s timer
  (`currentFootprintMB`, `serviceExtensionTimeWillExpire`). | E: it does not act on membership
  or wipe, only decrypts and renders; clean.

**E-10 SQLCipher DB** — T: AES, tamper = open failure (met). I: key is master-derived, no
independent KDF, so it inherits the identity file's protection (C-LOCAL-04 context); clean
at rest. D: delete = cryptographic loss, resumable wipe (met).

**E-11 identity / duress / device key files** — T: HKEYV1 AES-GCM, wrong key = failure
(met). I: password/keychain modes (C-06); PIN offline search (C-LOCAL-04); keychain backup
class on iOS/macOS (C-LOCAL-17). D: wipe zeroes then unlinks (met, wipe.rs:37).

**E-12 HFE1 content files** — T: per-chunk AAD binds uid/index/last (met). I: per-file key
in the DB, dies with the row (met); OS-temp plaintext copies (C-LOCAL-07). D: `remove`
drops the key row = crypto-erase (met).

**E-13 OS keystore** — T: n/a (OS-owned). I: Windows machine-local (`CRED_PERSIST_LOCAL_MACHINE`);
macOS/iOS default migrating accessibility class (C-LOCAL-17). D: `delete_key` on wipe (met).

**E-14 logs** — T: n/a. I: names, ids, server/channel/file names; shareable export
(C-LOCAL-11). D: 10 MiB rotation (`lib.rs:44`), push logs capped (met); not cleared on wipe
for the exe-adjacent Windows log (C-LOCAL-05).

**F-90 FFI** — T/I/D: no Dart-only authorisation of a remote action (C-LOCAL-14).
**F-91 core->DB/files/keystore** — covered by E-10..13.
**F-92 loopback server** — L-12, holds (C-LOCAL-12/13 Info).
**F-93 deep links** — I: dialog over the mobile lock (C-LOCAL-03); confirms present
otherwise (met); share auto-discover on paste noted (class 13).
**F-94 notifications/clipboard/screenshots** — C-LOCAL-02, 09, 10, 18.
**F-95 logs for support** — C-LOCAL-11.
**F-96 helper processes** — args not from remote input (C-LOCAL-15, met).

**X-1 user / holder (interactor)** — S: App Lock PIN vs offline search (C-LOCAL-04); duress
dummy slot indistinguishable (met, `duress_slot_dummy_when_unset_is_indistinguishable_in_size`).
R: n/a locally.
**X-8 other local apps / OS (interactor)** — S: a local app firing `hollow://` reaches only
confirm-gated handlers (met) except the mobile-lock case (C-LOCAL-03); clipboard readable by
other apps (C-LOCAL-10). R: n/a.

## Requirements

Each: a testable sentence, evidence, the guard test (or "no test").

- **R-LOCAL-01** A peer-authored archive cannot write a file outside Hollow's temp dir when
  opened. NOT MET (C-LOCAL-01, `loader.rs:224`). No test.
- **R-LOCAL-02** A `.hollow` snapshot import cannot write outside the data root. NOT MET
  (C-LOCAL-06, `storage.rs:1600`). No test.
- **R-LOCAL-03** With App Lock on, no message content or sender name reaches any OS surface.
  NOT MET on desktop (C-LOCAL-02). Guard: `lock_cover_test.dart` covers the cover, not the
  toast branch.
- **R-LOCAL-04** With App Lock on, no inline Reply can send a message. NOT MET on Windows
  (C-LOCAL-02). No test.
- **R-LOCAL-05** A deep link delivered while locked presents nothing until unlock. NOT MET
  on mobile, SUSPECTED (C-LOCAL-03). No test.
- **R-LOCAL-06** A short App Lock PIN is protected by a hardware attempt limit. NOT MET
  (C-LOCAL-04). No test (hardware).
- **R-LOCAL-07** A duress/destroy wipe leaves no readable Hollow file anywhere on the
  device. NOT MET for files outside the data root (C-LOCAL-05). Guard:
  `wipe_routine_is_idempotent_and_marker_resumes` (data-root only).
- **R-LOCAL-08** The recovery phrase cannot persist on the OS clipboard. NOT MET
  (C-LOCAL-10). No test.
- **R-LOCAL-09** The recovery phrase screen is not captured by the app-switcher or a
  screenshot. NOT MET, SUSPECTED (C-LOCAL-09). No test (device).
- **R-LOCAL-10** The debug-log export carries no display names or ids. NOT MET (C-LOCAL-11).
  No test.
- **R-LOCAL-11** The loopback media server binds loopback only. MET (`at_rest_server.rs:62`).
  Test `at_rest_server_range_semantics`.
- **R-LOCAL-12** The loopback server serves only under the data root, token-gated,
  traversal-proof. MET (`at_rest_server.rs:242-256`). Test `at_rest_server_range_semantics`.
- **R-LOCAL-13** An HFE1 chunk cannot be tampered, reordered or truncated undetected. MET
  (`at_rest.rs:228`). Tests `at_rest_tamper_in_any_chunk_is_detected`,
  `at_rest_truncation_is_detected`, `at_rest_out_of_order_chunk_writes_match_sequential`.
- **R-LOCAL-14** A sealed HFE1 chunk cannot be rewritten with different bytes (nonce reuse).
  MET. Test `at_rest_writer_refuses_a_differing_rewrite_of_a_chunk`.
- **R-LOCAL-15** A file whose key row is gone is an error, never served as raw bytes. MET
  (`at_rest.rs:275`). Test `at_rest_legacy_plaintext_passthrough_and_missing_row_refuses`.
- **R-LOCAL-16** A wipe is idempotent and resumes after a crash. MET. Test
  `wipe_routine_is_idempotent_and_marker_resumes`.
- **R-LOCAL-17** A password unlock costs the same whether the secret is the password, the
  duress code or wrong (timing). MET (both slots always derived, `identity.rs:137`,
  `duress.rs:123`). Test `duress_both_slots_always_derived`.
- **R-LOCAL-18** The duress slot exists and is byte-identical in size whether or not a code
  is set. MET. Test `duress_slot_dummy_when_unset_is_indistinguishable_in_size`.
- **R-LOCAL-19** A new password cannot silently disarm the duress code. MET
  (`identity.rs:294`). Test `change_password_refuses_the_duress_code`.
- **R-LOCAL-20** The identity-scope duress needs the recovery phrase once the identity has a
  recovery key. MET (`identity.rs:452`, `duress.rs`). Test
  `duress_everywhere_on_a_protected_identity_needs_the_phrase`.
- **R-LOCAL-21** A transport temp-file id cannot name a path outside the files dir. MET
  (`ws_stream_transfer.rs:526`, `wire_transfer_id.dart`). Tests `wire_file_id_and_ext_shapes`,
  `wire_transfer_id_test.dart`.
- **R-LOCAL-22** An inline FileHeader cannot be written to an attacker-chosen path. MET
  (`file_transfer.rs` `final_file_path`). Test `final_file_path_stays_inside_files_dir`.
- **R-LOCAL-23** A device key never equals the master key. MET (`device_key.rs:49`). Tests
  `fresh_and_distinct_from_master_when_absent`, `legacy_keystone_file_is_rotated`.
- **R-LOCAL-24** The DB passphrase is derived from the master, so a device-derived key opens
  nothing. MET (`storage.rs:68`, `push_enrich.rs:105`). Covered by the NSE spike tests.
- **R-LOCAL-25** The NSE never mints an identity and never logs decrypted content. MET
  (`push_enrich.rs:102`, `NotificationService.swift`). No Rust test for the no-log rule
  (source comment only).
- **R-LOCAL-26** An OS backup cannot carry Hollow data on Android. MET
  (`AndroidManifest.xml`, `data_extraction_rules.xml`). No test (manifest).
- **R-LOCAL-27** An OS backup cannot carry the iOS keychain wrapping key. NOT MET
  (C-LOCAL-17). No test.
- **R-LOCAL-28** Helper process args are never built from remote input. MET (C-LOCAL-15).
  No single test; by inspection.
- **R-LOCAL-29** No local parser panics on malformed input from a copied file or the
  loopback request. MET (C-LOCAL-21). Tests cover the at-rest and server parsers.
- **R-LOCAL-30** Dart never makes the sole authorisation decision for a remote action. MET
  (C-LOCAL-14, matrix identity:A-34, transport:A-T00). Tests
  `authz_a_fresh_push_process_knows_our_blocks`, `a_dm_wake_from_a_stranger_joins_nothing`.
- **R-LOCAL-31** The loopback URL token is per-process and not persisted. MET
  (`at_rest_server.rs:56`). Covered by `at_rest_server_range_semantics` (wrong token 404s).
- **R-LOCAL-32** Clipboard-paste and thumbnail temp files land under the swept data root or
  are deleted. NOT MET (C-LOCAL-07). No test.
- **R-LOCAL-33** A `hollow://` link from another app triggers no network action without a
  user tap. MET for join/room/conference/recovery/redeem (confirm dialog); the share link
  auto-runs a local discover then requires a Download tap (`paste_link_dialog.dart`). No test
  for the share auto-discover boundary.
- **R-LOCAL-34** The at-rest boot sweep never touches identity or DB files. MET
  (`at_rest.rs:650`, single-file targets, `is_transient` skips dotfiles). Covered by
  migration tests.
- **R-LOCAL-35** A profile other than the running one cannot be erased without its own
  unlock proof. MET (`profile_locations_card.dart:228`, `verify_identity_password_at` never
  touches the session key). No Rust test; `verify_*_at` has unit coverage
  (`status_reads_a_foreign_profile`).
- **R-LOCAL-36** The identity file in mode "none" is the only unprotected at-rest state, and
  it is opt-out by explicit user choice. MET by design (`project_identity_protection`,
  `auto_protect` removed). No test.
- **R-LOCAL-37** The portable-mode data root cannot be hijacked by an empty folder next to
  the exe. MET (`hollow_data_dir.dart:86`, requires identity data present). No unit test in
  this slice.
- **R-LOCAL-38** A pending wipe blocks a fresh identity from being minted mid-boot. MET
  (`identity/keys.rs:183`). Covered by the wipe test's marker branch.
- **R-LOCAL-39** The biometric unlock never trusts a stale stored secret into a loop. MET
  (`app_lock_service.dart` self-heal, `hollow_shell.dart:650`). No test.
- **R-LOCAL-40** The link-code value does not persist in the shareable log export. NOT MET
  (`ws_client.rs:1620,1632` log `{code}`). No test (Info, C-LOCAL-11).

## What I could not check

- Mobile behaviour at runtime: whether the deep-link confirm paints above the mobile lock
  cover (C-LOCAL-03), whether the iOS app-switcher snapshot captures a sensitive frame and
  whether Android's default already blurs it (C-LOCAL-09), and whether an iOS App Group
  container is excluded from iCloud backup by default and the keychain class actually roams
  (C-LOCAL-17). These need a device/simulator pass; I read only source.
- The exact set of files Apple includes in a device backup for an App Group container is an
  OS behaviour I could not confirm from the repo; C-LOCAL-17 is SUSPECTED on that basis.
- I did not run any test, so every "MET with a test" above is a claim that the named test
  exists and reads as covering the requirement, not that it passes at this HEAD.
