# HOL-SEC-187: The macOS app could load code from directories outside its bundle

```
ID:          HOL-SEC-187                 Status: Partially fixed on local branch
                                          security/0.14-mac-dylib (2026-10-31): load paths and
                                          the library validation waiver fixed; the keychain
                                          item old builds open moves to the data-protection
                                          keychain in 0.14 (design approved 2026-10-31, built
                                          on security/0.14-keychain 2026-11-01); retest on the
                                          signed build (release-apple.yml macos-keychain-check)
Severity:    High                        (Impact H: code running inside the signed app holds what
                                          the app holds: the keychain slot that opens without a
                                          prompt for Hollow's signature, the identity in memory,
                                          the database key, the camera, microphone and screen
                                          grants; Exploitability M: the attacker must already run
                                          code as the same user, and needs neither Homebrew nor
                                          admin rights)
Category:    Code integrity (library search path, library validation)
Component:   bundled mdk.framework (pod mdk via fvp), FlutterMacOS.framework and the Hollow
             executable (build-time LC_RPATHs); macos/Runner/Release.entitlements
             (disable-library-validation); scripts/build_macos_release.sh; the keychain item
             that holds the identity key (macOS)
Boundary:    TB-4 (Hollow and other apps on the device)
Traces to:   AS-01, AS-08, AS-09
Attacker:    another process running as the same macOS user
Found:       2026-10-31 (review of the installed 0.12.2 app, confirmed by the lead)
Affected:    every macOS release from 0.5.0, the first shipped macOS build (the macOS port,
             commit a7bb7ec0), through 0.13.0
```

## Description

The prebuilt mdk framework that plays video carries run path entries for `/opt/homebrew/lib`
and `/usr/local/lib`, and its two plugin libraries also name a directory on the vendor's
build machine. The framework also links about twenty libraries weakly by run path
(Vulkan, dav1d, the FFmpeg libraries, the RED and Blackmagic SDKs), none of which Hollow
ships, and it opens several more by bare name at run time. The Flutter engine framework
carries `/usr/local/lib/.`, and Xcode added the build machine's Swift toolchain directory
under `/Applications/Xcode.app` to the Hollow executable itself.

At launch the loader looked for each missing library in every one of those directories.
`/opt/homebrew/lib` belongs to the user on a Mac with Homebrew, `/usr/local/lib` does on an
Intel Mac with Homebrew, and an admin user can create the toolchain directory. The release
entitlements also turned library validation off, so a library of any signature found there
was mapped into the Developer ID signed app at its next start. It then ran with Hollow's
keychain access, its privacy grants and its memory, which the hardened runtime otherwise
keeps from other processes of the same user.

No attacker is needed for the first half: the framework names the FFmpeg and dav1d
versions Homebrew installs, so on a Mac with Homebrew's ffmpeg the app already loads
Homebrew's copies. On the review Mac, opening mdk from an unpatched build mapped 19
Homebrew libraries (FFmpeg 9, dav1d, OpenSSL and the codecs they pull in) into the process.

Three routes reach the same place, and two of them need neither Homebrew nor admin rights:

- The search paths above, where a directory on them is writable.
- Inside the bundle. A copy of Hollow in `/Applications` belongs to the user who dragged it
  there, so any process of that user can add a file inside it, and with library validation
  off the app loads a library placed there at its next start.
- Old builds. Every Hollow build we ever signed still meets the designated requirement of
  the keychain item that holds the identity key and holds the same privacy grants, and every
  one of them waives library validation. A process of the user can start an old build in
  place of the current one and reach the same keychain item and grants through it. A fixed
  new build does not close this route.

## Fix

- `scripts/macos_load_gate.sh strip` runs in the release script before anything is signed
  and deletes every run path that is absolute or climbs out of the bundle, in every
  Mach-O file in the app (found by its magic bytes, every architecture slice).
- `scripts/macos_load_gate.sh check` then fails the release on any run path other than
  `@executable_path` or `@loader_path` inside the bundle or `/usr/lib/swift`; any library
  load (weak and re-exported ones included) by an absolute path outside `/usr/lib` and
  `/System/Library` (the rest of `/System` holds `/System/Volumes/Data`, the user's own
  volume), by a bare relative path or by an @-path that leaves the bundle; any
  `LC_DYLD_ENVIRONMENT`; and any symlink in the bundle whose target is absolute or leaves the
  bundle. An @-path or symlink may climb (`..`) only before its first named part, since
  after a linked folder `..` goes wherever that link points.
- The build stage runs `strip` and `check` too, on a copy, so a pod that loads from
  outside fails every build and not only a signed release.
- The shipped signature keeps library validation on: the release script signs the app
  with `Release.entitlements` minus `disable-library-validation`, and after signing
  `macos_load_gate.sh signed` fails the release unless every Mach-O file's signature
  verifies (every architecture, so a file edited after signing fails), every one carries
  our team, and no executable in the bundle waives library validation. The file itself
  keeps the waiver because an ad-hoc signed build (a clone, the CI dry run) cannot load its
  own ad-hoc frameworks with validation on: macOS refuses them as "different Team IDs".

With the run paths gone, a hardened Hollow searches only its own bundle, `/usr/lib` and the
system for a missing library: the loader refuses relative paths in a hardened program, and
it skips `/usr/local/lib` for a process with entitlements. With validation on, anything not
signed by our team or Apple is refused even if it were found.

The identity key moves from the login keychain into the data-protection keychain, in an
access group only builds signed with Hollow's provisioning profile can claim, this device
only. At the first 0.14 launch each Hollow key in the login keychain is copied there, read
back, and only then deleted; nothing writes the login keychain again. Builds before 0.14
claim no keychain group and cannot see the new item. Before it reads a key, the app checks
that every library it loaded is the one this release shipped, so an old Hollow cannot put
its own older code into the new one. The certificate that signed the old builds is revoked
once Macs run builds of the new team.

- `identity/platform_keystore.rs`: keys go only to the data-protection keychain, group
  `group.com.anonlisten.hollow.keys` (the app-ID group where a Mac refuses it),
  `AfterFirstUnlockThisDeviceOnly`, never synchronizable, updated in place. Reads try the
  keys group, then the app-ID group, then (until the move) the login keychain. Every macOS
  keychain call waits for `hollow_bundle_checked`. `settle_move` (FFI
  `settle_keychain_move`, once per start after the pending wipe and `settle_relink`,
  before any unlock) moves only `wrapping_key` and `wrapping_key.<16 hex>` with 32-byte
  values, at most 32 a start, own slots first: quiet read with the item's persistent
  reference, add (never overwrite: a different value goes to `<slot>.m.<hash>`), read back
  byte for byte, delete by that reference. Where the keys group works it promotes app-ID
  items the same way. Writability is probed and answered three ways (yes, no, unknown);
  the cached-key drop path reads only the root rule. Wipes forget the slot and its copies
  in every keychain, and machine-slot items only where each opens the wiped identity.
- `macos/Runner/BundleSeal.swift`: before the Flutter engine exists, every loaded image
  inside the bundle must match `HollowSealedImages` (cdhash of each slice, written by
  `macos_load_gate.sh seal` before the main signature) by its in-memory code directory
  and a sample of its code pages in memory, and no image outside it may carry our team.
  The list counts only when the `Info.plist` bytes it was read from hash to the Info.plist
  slot of the main executable's code directory, the one whose hash is the cdhash the
  kernel validated the process against; the executable is the image dyld loaded, never
  `Bundle.main`. Any mismatch at start, or keychain entitlements without a bound list and
  a team, ends the process before the engine with a "Hollow is damaged, download it again"
  alert (decided 2026-11-01): never the key-missing screen, never the App Lock launch
  secret. A later image that fails ends the process too. Ad-hoc development builds (no
  list, no keychain entitlement) still start, with the keychain shut.
- The release sign stage embeds the Developer ID profile and adds the application
  identifier, the team identifier and the keys group to the shipped entitlements;
  `macos_load_gate.sh signed` refuses a missing, foreign, expired or non-Developer-ID
  profile, an unauthorised claim, entitlements other than the computed set, a debug (JIT)
  engine and an inexact seal. Debug builds are always ad-hoc.
- iOS: App Lock entries and the Secure Enclave key move into the keys app group (every
  call names its group); a key the system will not regroup is replaced at the next unlock
  by a new keys-group key (`FLAG_GROUP_KEY`), the duress slot keeping the first key until
  its code is set again.

## Residual risk

- Until the old team's certificate is revoked, old builds keep the privacy grants (camera,
  microphone, screen) and can show phishing screens. An item a quiet read cannot open
  stays where it is. A Time Machine copy of the login keychain from before 0.14 still
  holds the key. Whoever holds the keys group registration can read the items (the signing
  team's power). A Mac moved by Migration Assistant after 0.14 asks for the phrase; one
  moved from a 0.13 Mac stays a clone of it.
- Library validation admits any Mach-O signed by our team, old Hollow libraries included.
  Nothing that loads code from a data path, a download or a plug-in folder may ever be
  signed with this team.
- Builds that never pass through the release script's sign stage (local `flutter build
  macos`, the unsigned CI artifact) keep the vendor run paths and the waiver. They are not
  distributed.
- With library validation on, legacy camera plug-ins (DAL) cannot load into Hollow. macOS
  turned those off in 14.1 for every app; on macOS 12 and 13 an old virtual camera that has
  no Camera Extension will not show in Hollow's camera list.
- iOS is not affected: the iOS mdk has no absolute run paths, and iOS validates the
  signature of every library it loads. One iOS run path, `@executable_path/../Frameworks`,
  points above the app in the main process; it can never find a library signed for Hollow.
- The local proof uses ad-hoc signatures. That a Developer ID build launches and plays
  video with validation on is proven by the first signed build (CI or the release Mac).

## Test

`scripts/macos_load_gate_test.sh` (cases on scratch bundles built with clang: absolute,
climbing and toolchain run paths fail and are stripped while in-bundle ones stay; absolute,
`/usr/lib/..`, `/System/Volumes/Data`, `/System/Library/..`, bare and `@rpath/..` loads and
`LC_DYLD_ENVIRONMENT` fail and cannot be stripped; a symlink out of the bundle that
satisfies an `@rpath` load (absolute or climbing), a symlink or @-path with `..` after a
named part, and a symlink target hiding a `..` after a newline fail; framework links pass;
a Mach-O without extension or exec bit is found; a fat file whose slices disagree is fixed
per slice; a fat magic it cannot classify stops the gate; an ad-hoc bundle, a waiver of
library validation and a Mach-O edited after signing (one slice or both) fail `signed`; a
stripped and re-signed binary still runs). 43 cases; against a gate that passes
everything, 27 fail; the 9 cases of the review fix round fail on the gate before it.
Mutants: 16 of 16 of the first round and 10 of 11 of the fix round are killed; the
survivor drops `--all-architectures`, which changes nothing on current macOS (codesign
already verifies every slice; an x86_64-only edit fails without the flag).
`test/macos_load_gate_guard_test.dart` reads the release script in CI: strip then check
after the build and before the sign stage, strip and check of the app before its first
signature, `signed` with a team after the app's last signature, and every signature with
entitlements using the copy minus the waiver; 11 of 11 script mutants fail it.
Keychain move (Rust, fake two-keychain backend with a hook between steps and faults):
`a_legacy_key_moves_into_the_protected_keychain_then_leaves`,
`a_move_cut_short_keeps_both_and_finishes_at_the_next_start`,
`a_protected_copy_that_does_not_read_back_keeps_the_legacy_key`,
`a_legacy_key_rewritten_during_the_move_is_never_deleted`, `two_movers_at_once_keep_every_key`,
`a_conflicting_legacy_key_never_overwrites_the_protected_one`,
`heal_leaves_no_conflict_copy_behind`, `a_wipe_forgets_the_conflict_copies_too`,
`planted_legacy_items_are_not_moved`, `a_flood_of_planted_slots_never_holds_back_our_own`,
`every_profiles_slot_moves_not_only_the_running_one`,
`the_machine_slot_moves_once_and_is_never_written`,
`a_wipe_takes_only_the_machine_items_that_open_its_identity`,
`an_item_in_the_app_id_group_opens_and_moves_once_the_keys_group_works`,
`no_flow_writes_the_legacy_keychain`, `no_source_writes_the_legacy_keychain`,
`a_missing_entitlement_keeps_the_legacy_key_and_deletes_nothing` (store and identity level),
`a_failed_probe_never_drops_the_cached_key_on_the_os_root`, `an_unknown_probe_is_not_cached`,
`a_portable_or_override_session_moves_nothing`, `an_unlock_never_moves_a_key`,
`a_duress_wipe_moves_nothing`, `a_wipe_forgets_the_key_in_both_keychains`,
`a_keychain_store_never_asks_the_person`, `a_protected_write_never_deletes_first`,
`a_typed_unlock_reads_no_keychain`, `the_protected_store_reads_nothing_before_the_bundle_check`,
`only_our_groups_open_the_keychain`. Enclave keys: `a_key_the_system_regroups_stays_the_same_key`,
`a_key_left_in_the_app_id_group_still_opens_until_it_moves`,
`a_bound_identity_moves_to_the_group_key_at_the_next_unlock`,
`a_move_to_the_group_key_cut_between_the_files_heals`,
`the_duress_slot_keeps_its_old_key_until_the_code_is_set_again`,
`setting_the_code_again_moves_it_and_frees_the_first_key`,
`every_try_costs_the_same_hardware_operations_with_two_keys`,
`making_a_key_never_deletes_one_in_another_group`, `a_sweep_keeps_both_keys_of_the_live_profile`.
Dart: `test/app_lock_keychain_groups_test.dart` (the cut-short move, never a delete before
the copy reads back, a delete of the old entry leaves the new one, every call names a
group, a build without the keys group, the transfer note's own marker),
`the_transfer_note_shows_even_after_the_0122_note`, `test/keychain_groups_guard_test.dart`
(every iOS keychain query names a group, only the app claims the keys group, one launch
point for the move before the unlock, the macOS self-check before the engine) and
`flutter_debug_config_never_takes_the_release_identity` with the seal, profile and
entitlement cases in `test/macos_load_gate_guard_test.dart`. Gate: 13 more cases in
`macos_load_gate_test.sh` (missing, foreign, expired and non-Developer-ID profiles, an
unauthorised group or app id, entitlements other than the computed set, a Mach-O missing
from or mismatching `HollowSealedImages`, a JIT engine, seal never listing the main
executable). Self-check: `scripts/macos_bundle_seal_test.sh` (ad-hoc scratch bundle: a
sealed bundle passes, a sealed library loaded later is accepted, an unsealed one ends the
process, a swapped library and an Info.plist edited after signing each end the process
before the engine, old code under a sealed directory fails the page check, a development
build without a list starts, a build claiming keychain groups without a list ends).
Signed run: `scripts/macos_keychain_check.sh` on throwaway macOS 14, 15 and 26 runners
(the move with the login item gone, 0.13 and a library planted in it refused, a framework
swapped for 0.13's, an edited Info.plist and this team's framework moved outside the
bundle each ending the start before the engine).

`check` fails on the installed 0.12.2 app and on a fresh unsigned release build (nine run
paths each) and passes after `strip`. A probe placed inside that build, signed with the
release entitlements, opens every bundled framework: before `strip` dyld also mapped 19
Homebrew libraries, after it none, and every framework still loads. The same build signed
ad-hoc without the waiver cannot open its own mdk ("different Team IDs").
