# Review: HOL-SEC-187 keychain design

Hostile design review of `HOL_SEC_187_KEYCHAIN_DESIGN.md`, on `55a5c4f3`, 2026-10-31.
EMBARGOED with HOL-SEC-187. No product code changed.

## Verdict

**Approve with changes.** Direction A (data-protection keychain, app group as the access
group, a Developer ID profile, a verified byte move) is right, and B is worse on every row,
as the design says. These block 0.14: F1 (the profile becomes a launch dependency that the
transfer may break, and the drill does not test it), F2 and F3 (an old build can still get
attacker code into the entitled 0.14 process), and F4 to F6 (crash and fallback paths that
lose a key or delete one).

## Findings, most severe first

### F1 (High, availability). The Developer ID profile can stop every old-team Mac build launching at the transfer, and nothing tests it

- **Flaw.** From 0.14 on, every Mac build embeds a Developer ID profile for App ID
  `com.anonlisten.hollow` (Mac bundle id = iOS bundle id, `macos/Runner/Configs/AppInfo.xcconfig:11`)
  that authorises `group.com.anonlisten.hollow.keys`. Apple checks "the validity of your
  Developer ID provisioning profile at every app launch" (Developer ID page). At step 3 the
  App ID moves to the new team ("its associated App ID is also transferred", App Store
  Connect, Overview of app transfer), and the old team DELETES the keys group. Nobody has
  said that a profile whose App ID or group has left the team still counts as valid at
  launch.
- **Why it matters.** If it does not, every Mac on 0.14 up to the last old-team build stops
  launching at step 3, before a new-team build exists. The updater runs inside the app
  (`api/updater.rs:870-959`), so nothing self-heals. Meanwhile 0.5 to 0.13, which carry no
  profile, keep launching. The identity survives (data root plus keys group, if U1 holds),
  but every Mac user has to find and download the new build by hand.
- **Evidence.** The design lists this as U6 and assigns it to D-M, but D-M (section 4.3)
  never deletes the group or the App ID on the old team for the Mac half. Only D-I checks
  "the old-team app, still installed, keeps working", and on iOS an App Store or development
  install is checked differently. The table's "launch depends on the profile (valid 18
  years)" covers expiry only, not deletion.
- **Fix.** Make it a D-M pass criterion: install the old-team Developer ID drill app, delete
  its group and then its throwaway App ID on the old team, and confirm it still launches and
  still reads its item, online, after a reboot and after 48 hours. Also ask DTS directly.
  Until both answer, plan the contingency: the step 2 status notice tells Mac users that
  the new build may have to be downloaded, the first new-team Mac build ships the same day
  as step 3, and the website download moves at once.
- **Test.** D-M case `old_team_app_launches_after_its_group_and_app_id_leave_the_team`.

### F2 (High impact, low exploitability). An old build can rewrite the installed 0.14 bundle, and an old team-signed library can run attacker data as code inside the entitled process

- **Flaw.** The design files team-signed old libraries as a residual that "runs our own old
  code, not the attacker's", reachable only by "a process that can write into the installed
  bundle". Two things are wrong.
  1. App Management exempts the same team: apps of one team may modify each other's
     bundles without a prompt. So the old injectable builds are exactly the processes that
     CAN rewrite `/Applications/Hollow.app` 0.14. They can also replace it with 0.13 (the
     "sharp phishing" case section 2.2 says App Management guards). An attacker does not
     even need the installed copy: any unquarantined copy of the bundle launches, and the
     updater itself strips quarantine (`api/updater.rs`, `xattr -dr com.apple.quarantine`).
  2. "Our own old code" includes old third-party native code with public memory-safety
     CVEs (the media stack, WebRTC). Library validation compares Team ID only, so a
     0.5-era framework loads into a 0.14 host. Feed it a crafted file and the attacker's
     code runs in a process whose entitlements are validated and which can read the keys
     group. A new certificate does not change that, because library validation ignores the
     certificate.
- **Why it matters.** This is the HOL-SEC-187 attacker (same-user code, an old team-signed
  build) reaching the identity key after the move. Only revocation (question 3) ends it,
  and the design calls revocation optional.
- **Fix.** (a) Before the first keychain read, the MAIN executable (Runner, Swift, never the
  swappable Rust or Dart frameworks) validates its own bundle (`SecCodeCopySelf` plus
  `SecCodeCheckValidity` with strict and nested-code checks, which compare each nested
  framework's sealed cdhash). On failure it exits, or tells Rust to read no keychain. (b) On
  macOS 14 and later, add a library load constraint pinned to this release's cdhashes.
  (c) Make revocation (Q3) required and put it in U10: does Gatekeeper or AMFI refuse a
  revoked-certificate LIBRARY loaded into a valid host? (d) Correct the App Management text
  in 2.2.
- **Test.** A signed-runner case: copy signed 0.14, swap one framework for the 0.13 copy,
  launch, and assert that no protected read happens (the log names the refusal) and nothing
  is deleted.

### F3 (Medium). Local Debug builds are signed with the team's Developer ID wherever the release script has run

- **Flaw.** `macos/Flutter/Flutter-Debug.xcconfig` ends with `#include? "LocalSigning.xcconfig"`.
  `scripts/build_macos_release.sh:66-79` writes that file with
  `HOLLOW_CODE_SIGN_IDENTITY = Developer ID Application`, and the Runner Debug config takes
  its identity from it (`project.pbxproj:755`). After one release run, every
  `flutter run -d macos` on that Mac is team-signed. That build has a JIT Dart engine that
  runs Dart from a file, and its signature keeps the library-validation waiver
  (`DebugProfile.entitlements`).
- **Why it matters.** It breaks the design's own rule that nothing which loads code from
  data is ever signed with the team. Such a debug engine plus its App.framework, swapped
  into 0.14, is a ready-made F2 chain: the shipped signature has `allow-jit` and
  `allow-unsigned-executable-memory`. Before 0.14 such a build also opens the legacy item
  quietly. The mini has no LocalSigning file today (checked: the Debug build there is
  "TeamIdentifier=not set"), but the old Intel publishing Mac had one.
- **Fix.** Include LocalSigning only from the Release and Profile configs. Pin Debug to `-`.
  Have the load gate refuse a debug Flutter engine in a team-signed bundle. Check the old
  Intel Mac for team-signed Debug bundles, and add them to the revocation case.
- **Test.** Guard `flutter_debug_config_never_takes_the_release_identity` (a source scan of
  the xcconfig includes).

### F4 (Medium, key loss). Mover step 4 deletes by name and can erase a key an old build wrote after step 1

- **Flaw.** Step 4 deletes legacy A by service and account. If another Hollow process
  rewrites A between step 1 and step 4 (`mac::store` deletes and re-adds), the delete
  removes the NEW value L', which no store holds. One case is an old build open on another
  profile, since the mover moves every profile's slot. Another is two processes at once.
  "At no step does neither store hold L" is true for L, not for L'.
- **Why it matters.** If L' is the only key of a keychain-only identity (old-build
  `switch_to_keychain` with a fresh key, a relink `keep_key_at`), the identity shows
  key-missing and only the phrase brings it back, as a new device.
- **Fix.** Delete the exact item read in step 1: take its persistent ref (or its
  modification date) at step 1 and delete by that ref. A rewrite always makes a new item,
  so a stale ref misses. Treat `errSecDuplicateItem` at step 2 as "present, compare"
  (a concurrent mover).
- **Test.** `a_legacy_key_rewritten_during_the_move_is_never_deleted`,
  `two_movers_at_once_keep_every_key` (the fake backend gains a hook between steps).

### F5 (Medium, deletes a key). A runtime `is_available()` feeds the existing cached-key drop path, which then deletes the key on the OS root

- **Flaw.** Rule 4 turns `is_available()` into a probe and promises "Not available ...
  NOTHING is deleted". But `password_keychain_allowed` (`api/identity.rs:103-112`) is
  `is_available() && default_eligible_for(...)`. When it is false,
  `drop_cached_key_off_os_root` (`api/identity.rs:347-385`) rewrites `identity.key` without
  the keychain flag and calls `forget_key_at` at the next typed unlock of a `0x03` identity.
  The same input decides `keep_keychain` on a password change, the onboarding default
  (`:1236-1240`) and the Dart-visible `os_keychain_available` (`:1407-1425`). The probe
  defines only "not found" and `errSecMissingEntitlement`. An ssh session (the fleet runs
  Mac peers over ssh), a locked keychain or a transient error has no defined answer, and
  the result is cached for the whole process.
- **Why it matters.** One bad probe on a signed 0.14 silently and permanently strips silent
  unlock from the OS root. It is the opposite of the rule the design states.
- **Fix.** Split it three ways: `protected_available` (may write), `root_eligible` (today's
  root rule, the only input to the drop path) and Unknown (any other status: offer nothing,
  write nothing, delete nothing, and do not cache it). The drop path must never read
  availability.
- **Test.** `a_failed_probe_never_drops_the_cached_key_on_the_os_root`, and extend
  `a_missing_entitlement_keeps_the_legacy_key_and_deletes_nothing` with a typed `0x03`
  unlock and a password change.

### F6 (Medium, key unreachable). iOS: "every enclave call names the keys group" makes the old key unreachable before it can be re-grouped or re-bound

- **Flaw.** Section 3.4 and the Dart source guard (section 6) say every Secure Enclave
  create, lookup, list and delete names the keys group. The keys bound today sit in the
  app-ID group. A lookup restricted to the keys group misses them, so the re-bind, which
  needs the old key to open the identity, can never run. Also, `hwCreate` begins with
  `HollowHwKey.remove(tag)` with no group (`AppDelegate.swift:482-488`, `:491-494`), which
  deletes that tag in EVERY group.
- **Why it matters.** Implemented as written, every iOS App Lock identity (bound since B5)
  would answer `hw_key::MISSING`, and only the phrase brings it back. The duress slot loses
  its key at once, not at the transfer.
- **Fix.** Spell out the order: keys group, then the app-ID group, for the old tag only.
  Creation and removal name exactly one group. The source guard checks "names a group",
  not "names the keys group". `sweep_orphans` lists both groups.
- **Test.** `a_key_left_in_the_app_id_group_still_opens_until_it_moves`,
  `making_a_key_never_deletes_one_in_another_group`.

### F7 (Medium). The fallback group is chosen at runtime, but nothing says how it is read, promoted or moved, and the "same mover" claim is false

- **Flaw.** Section 2.1 writes to the app-ID group "where a Mac refuses the AGI group", but
  nothing says how a refusal is detected (which status, which call) or whether it is decided
  per item or per process. Rule 3 says reads name one group. After a macOS upgrade that
  starts honouring AGI groups, a reader that names the AGI group misses the item in the
  app-ID group (key-missing), and the item stays in the group lost at the transfer. Section
  5 and Q7 say a later release moves app-ID items into the keys group "with the same
  mover", but the mover handles file keychain to data-protection keychain. A move between
  two data-protection groups is new code, with its own crash-safety questions.
- **Fix.** Reads try the keys group, then the app-ID group, by name. Every start promotes an
  app-ID item into the keys group through a byte-verified copy, read back, then delete by
  ref (as in F4). Define the refusal status. Put this mover into 0.14 so the frozen tag
  carries it.
- **Test.** `an_item_in_the_app_id_group_opens_and_moves_once_the_keys_group_works`.

### F8 (Medium, wipe leftover). Conflict copies `wrapping_key.m.<hash>` are never deleted, and no forget can find them

- **Flaw.** Step 2 names the conflict copy after the hash of the key, not after the root.
  `forget_key_proven` deletes only the profile slot and the proven legacy slot
  (`platform_keystore.rs:640-648`). Heal promotes the winner into the profile slot and
  leaves the `.m.` copy. Copies pile up and count against `SCAN_LIMIT` (16).
- **Why it matters.** After a duress wipe or a remote destroy, the keychain still holds a
  key that opens every surviving copy of the wiped identity (a Time Machine copy of the
  root, section 9). That breaks "the wipe leaves nothing that opens it".
- **Fix.** Name the copy `wrapping_key.<root suffix>.m.<hash>`. Forget deletes every
  `.<suffix>.m.*`. After heal proves a winner, delete the copies of that root. Limit the
  scan to the profile's own copies first.
- **Test.** `a_wipe_forgets_the_conflict_copies_too`,
  `heal_leaves_no_conflict_copy_behind`.

### F9 (Medium-Low). The move runs lazily "before the first keychain read", which can fall inside a duress wipe or a typed unlock

- **Flaw.** On a root with "Ask before Hollow starts" (`0x01`), the first keychain read of
  the process can be `legacy_key_opens`, called from the duress wipe (`forget_key_at`,
  `api/wipe.rs:401,493`). Or it can be `password_keychain_allowed`, called after a typed
  unlock. The move then writes keychain items in the middle of a wipe and adds
  milliseconds to it. That contradicts "runs before any prompt, so the typed-secret path,
  its timing and the duress code are untouched".
- **Fix.** Run the move at one fixed point, at process start before the launch prompt, from
  `unlock_identity`'s caller. Wipe and forget paths never trigger it.
- **Test.** `a_duress_wipe_moves_nothing`, `the_move_runs_before_the_launch_prompt`.

### F10 (Low-Medium). The mover moves any account an attacker plants, with no limit

- **Flaw.** "For every account A of service `com.hollow.identity`". Any same-user process
  can add legacy items of any name and size. Each becomes a protected item, and with a
  `wrapping_key.` prefix it crowds the 16-slot scan.
- **Fix.** Move only names matching `wrapping_key` or `wrapping_key.<16 hex>` with 32-byte
  values. Cap the number per run. Leave the rest alone (never delete them).
- **Test.** `planted_legacy_items_are_not_moved`.

### F11 (Low-Medium). The iOS App Lock move cannot target "the old group" through flutter_secure_storage

- **Flaw.** The plugin sets `kSecAttrAccessGroup` only from `groupId`
  (`FlutterSecureStorage.swift:233-237`). The old items sit in
  `<prefix>.com.anonlisten.hollow`. A read or delete with no group matches every group,
  so "delete the old one" also deletes the new copy. The model named, `migrateAccessibility`
  (`app_lock_service.dart:61-87`), deletes BEFORE it writes, so it is not a safe template.
- **Why it matters.** The biometric copy and the launch secret are lost: biometrics stop
  working until they are turned on again, and Hollow no longer starts on its own. A lost
  lock-type marker falls back to password-style entry, which is harmless.
- **Fix.** Swift hands Dart the full prefixed old group, and the move names it for read and
  delete. Or do the move in Swift. During the move, wipes and `clearProfile` delete in both
  groups.
- **Test.** Extend the Dart test: after a cut-short move, a delete of the old entry leaves
  the new one.

### F12 (Low). The duress note reuses a marker that 0.12.2 already set, and shows only in the Duress card

- **Flaw.** `_kDuressRebindAsked` (`app_lock_service.dart:166`) is already set for everyone
  who saw the 0.12.2 note, and the note shows only when the person opens the Duress card
  (`duress_section.dart:146-151`).
- **Fix.** Use a new marker. Put "set your duress code again" in the step 2 signed notice.
- **Test.** `the_transfer_note_shows_even_after_the_0122_note`.

### F13 (Low). The Q2 text on Migration Assistant holds only for a source Mac that already ran 0.14

- **Flaw.** A Mac moved from a 0.13 source brings its legacy item along. The first 0.14
  start on the new Mac moves it silently, and the cloned device stays a clone, now pinned to
  the new Mac.
- **Fix.** Correct Q2 and the residual text. Detecting a clone is out of scope.

### F14 (Low). The optional clone (Q4) is torn if taken live, and useless if taken before the enclave key moves

- **Flaw.** A copy-on-write clone of an open SQLCipher database with its WAL is not a
  consistent copy. A clone taken before the re-group or re-bind holds a wrap tied to the
  app-ID-group enclave key that is lost at the transfer, so it is useless for App Lock users.
  Quinn says as much in 841686: a container copy "isn't an option for you" because the key
  lives in the keychain. For users with no lock, it is a second plaintext identity.
- **Fix.** Take it with the database closed or through the backup API, and only after the
  enclave key sits in the keys group. Say plainly that it helps only identities whose wrap
  depends on nothing but the keys group.

### F15 (Low). The iOS app on Apple Silicon Macs also claims the keys group

- **Flaw.** If "iPhone and iPad apps on Mac" is available, the iOS build runs on a Mac,
  claims the keys group and shares that Mac's data-protection keychain. Service names do
  not collide today. Still, the claim "the only programs that can claim our group" should
  count it.
- **Fix.** Confirm that availability is off, or add a line to the design.

## Claims checked

**Code (on `55a5c4f3`).** These are accurate: 1.1 (`platform_keystore.rs` 265-275, 36-60,
70-84, 547-569, 614-648, 323-326; `api/identity.rs` 99-112, 140-165, 176-223, 347-385;
`hw_key.rs` 10-13; ENT_SHIP at `build_macos_release.sh:106-108,149`;
`Release.entitlements` untouched since `a7bb7ec0`; no profile), 1.2, and 1.3
(`AppDelegate.swift` 441-515 and 337-358, the extension entitlements). One line is off:
`security-framework` sits at `Cargo.toml:133`, not 131-132. In security-framework 3.7.0,
`use_protected_keychain` and `ignore_legacy_keychains` exist only under `OSX_10_15`. Its
`set_password_internal` adds, then updates on a duplicate, so update-in-place needs no new
crate.

**Apple.**
- "Revoked ... can no longer be installed nor launch if it's already installed": verbatim
  on the Developer ID page.
- "18 years": true for profiles generated after 2017-02-22.
- The certificate is checked at install and the PROFILE at every launch (the design blurs
  the two).
- 706128 (2026 rewrite): an AGI group works on macOS only in the data-protection keychain
  and only with every entitlement validated; the group-steal window, r. 171616887. It says
  nothing about Secure Enclave keys (U3 rightly unverified). It adds that "Mac apps that
  have ever used an app group can't be transferred" (the App Store route only; note it for
  the future).
- 721701: Quinn "should ... not actually tried it" (U1 correct). The February 2025 change
  is a website change, not an OS one, so macOS 12 to 13 remain the real unknown, and
  GitHub has no runner for them.
- 841686: Quinn, August 2026, accepted, "Yes. Or at least it should", and old builds "Yes".
  tmp3 still calls it unanswered.
- 774831: the 25% figure is correct, but in February 2025 Quinn called that technique "not
  something we support". Say that the support is new.

## The three out-of-scope findings

1. **macOS App Lock never stored: consistent with the code, still U9.** The plugin uses the
   data-protection keychain on macOS by default (`macos_options.dart:24`,
   `FlutterSecureStorage.swift:227-231`). The Mac app has no keychain or app-ID
   entitlement, and every write or read error is swallowed (`app_lock_service.dart:405-414`,
   `:392-399`). New point: the 0.14 profile silently STARTS storing the launch secret on
   Macs, a flow never exercised in production, so the signed-runner check must drive it.
2. **`mac::store` deletes before it adds: confirmed** (`platform_keystore.rs:270-275`). In
   today's callers a crash in that gap costs silent unlock, not the identity: every store
   comes before the file rewrite and something else still opens it (the password for
   `0x03` and `tie_to_hardware`, plaintext files during `switch_to_keychain`, the source
   slot for `keep_key_at`). Low. Rule 2 fixes it.
3. **The data root rides Time Machine: confirmed.** The only exclusion is iOS
   (`AppDelegate.swift:353`). After 0.14 a backed-up keychain root opens nowhere (U8), but a
   plaintext identity remains exposed. Excluding the root also removes the person's only
   local history backup (`project_local_history_storage`); weigh that in the decision.

## Open questions the findings change

- **Q1:** approve only with F2a (the self-check in the main executable) and with F6 and F7
  folded into the store rules.
- **Q3:** revocation becomes REQUIRED, not a complement. Until it happens, an old build can
  rewrite the installed 0.14 (F2). Add "does revocation stop library loads" to U10. Add the
  Debug bundles from F3 to the revocation case.
- **Q5:** the drill gains the F1 case (an old-team Mac app after its group and App ID
  leave) and a macOS 12 or 13 machine. Without them, U1 and U6 stay open at the freeze.
- **Q6:** (a) also needs F6 and F12. (b) needs F7's two-group reads and promotion.
- **Q7:** the "later old-team release" carries a new mover between data-protection groups,
  and the Q4 clone touches every wipe path. Both are security code outside the frozen
  OSTIF tag. Either finish the drill before the freeze, or put the second mover and the
  clone into 0.14, dormant and behind the drill's result.
- **Q8:** the text is wrong twice. A build whose probe fails reads the legacy item before
  the move, and with F5 unfixed it deletes keys. On a Mac where the release script ran, a
  `flutter run` build is team-signed (F3).
- **Q2:** correct it for a source Mac still on 0.13 (F13).
- **Q4:** a yes depends on F14.
