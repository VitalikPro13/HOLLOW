# HOL-SEC-187: The macOS app could load code from directories outside its bundle

```
ID:          HOL-SEC-187                 Status: Partially fixed on local branch
                                          security/0.14-mac-dylib (2026-10-31): load paths and
                                          the library validation waiver fixed, ship with 0.14;
                                          the keychain slot old builds open is not (design
                                          track pending); retest on the signed build
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

## Residual risk

The finding is only partly fixed.

- Old signed builds still open the keychain slot. They meet the keychain item's designated
  requirement, and they waive library validation. This stays open until the identity key
  moves to storage only fixed builds can read (a separate design track, pending).
- Privacy grants (camera, microphone, screen) cannot be limited to a version. An old build
  keeps them for as long as the user granted them to Hollow.
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
`check` fails on the installed 0.12.2 app and on a fresh unsigned release build (nine run
paths each) and passes after `strip`. A probe placed inside that build, signed with the
release entitlements, opens every bundled framework: before `strip` dyld also mapped 19
Homebrew libraries, after it none, and every framework still loads. The same build signed
ad-hoc without the waiver cannot open its own mdk ("different Team IDs").
