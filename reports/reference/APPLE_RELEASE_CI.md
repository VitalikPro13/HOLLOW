# Apple release pipeline (GitHub Actions)

`.github/workflows/release-apple.yml` builds the macOS and iOS releases on GitHub's
macOS runners, so no Mac of ours holds a signing key or has to be online on release day.
It is started by hand: Actions > Release (Apple) > Run workflow.

## What it does

| Input | Meaning |
|---|---|
| `version` | `X.Y.Z`; the run fails unless it equals the version in `pubspec.yaml` |
| `platforms` | `macos-and-ios`, `macos` or `ios` |
| `sign` | macOS: Developer ID signing, notarization and stapling. `false` = unsigned dry run |
| `upload_ios` | iOS: sign with the App Store identity and upload to TestFlight. `false` = dry run |
| `ios_build` | iOS build number; empty takes the `+N` from `pubspec.yaml` |

`sign` and `upload_ios` work only from `main`. With both off nothing touches a secret,
an environment or an Apple account: that is the dry run that proves the pipeline.

### The rule the jobs follow

No job that holds a key runs code we did not write. Building runs pub packages,
CocoaPods podspecs (Ruby), cargo build scripts, Xcode script phases and CMake; any of
them could read a secret the job holds (a hosted runner gives every step passwordless
sudo, so step-scoped secrets are no wall). So every build runs in a job with no secret
and no environment, and a signing job runs only Apple's tools (`codesign`, `security`,
`hdiutil`, `notarytool`, `stapler`, `altool`, `plutil`, `ditto`, Apple's
`/usr/bin/python3`) and this repository's scripts, on a build it receives as a tar.
While a key is unlocked no format parser reads that build beyond what signing needs:
Mach-O files are told by their first bytes (`scripts/apple_macho.sh`), not by
libmagic's `file`, and the crash symbols are made in `ios-build` and only copied.

| Job | Holds | Does |
|---|---|---|
| `macos-build` | nothing | `build_macos_release.sh --stage build`: webcrypto patch, screen audio helper, universal `flutter build macos` (ad-hoc signed); hollow_core must name only the pinned rustc; the three lockfiles must not move |
| `macos-release` | `apple-developer-id` | inside-out Developer ID signing, the app notarized and stapled, the DMG built from a staged folder and checked, signed, notarized and stapled, the updater zip, the release checks |
| `macos-attest` | OIDC token | checks the two files against the hashes `macos-release` published, then a GitHub build provenance attestation |
| `ios-build` | nothing | `build_ios_release.sh archive`: `xcodebuild archive` with code signing OFF, against a placeholder Firebase config, and the crash symbols (`xcrun symbols`) from its dSYMs; hollow_core must name only the pinned rustc; the three lockfiles must not move |
| `ios-upload` | `apple-asc-upload` | `build_ios_release.sh export` + `upload`: the production Firebase config swapped in, inside-out signing with the Apple Distribution identity and the three App Store profiles, the `.ipa`, `altool --upload-package` |

The dry run replaces the two signing jobs with `macos-package-dry` (the unsigned DMG and
zip through the same staging and the same DMG check) and `ios-export-dry` (the same
export, signed ad-hoc with the same resolved entitlements and no profiles: it proves the
secretless archive, the bundle checks, the entitlements, the nested signing order and
the `.ipa` layout; only the identity, the profiles and the upload are left to the first
real run). The artifact `hollow-X.Y.Z-macos-UNSIGNED` holds the dry run's DMG and zip.

### iOS signing, step by step

The archive comes out of `ios-build` unsigned. `ios-upload` first refuses the copied app
if any symlink in it resolves outside it (or nowhere): the job writes the profiles and
the Firebase config into the app, and removes each destination before writing it. It
then checks the app embeds
exactly `PlugIns/NotificationService.appex` and `PlugIns/BroadcastExtension.appex`
(both ship: the push extension and the screen-share extension), that all three bundles
carry the release version and build and the expected bundle ids, then for each bundle:

1. `scripts/ios_entitlements.py` resolves the target's committed `.entitlements`
   (`ios/Runner/Runner.entitlements`, `ios/NotificationService/...`,
   `ios/BroadcastExtension/...`) from `ios/Flutter/Variant-prod.xcconfig` and the team,
   and adds `application-identifier`, the team identifier and `get-task-allow = false`.
2. The profile must be an App Store profile (no devices, no `get-task-allow`) of this
   team for exactly that bundle id, unexpired, holding the signing certificate, and must
   grant every one of those entitlements. Anything else stops the job.
3. Frameworks and dylibs are signed deepest first, then the two extensions and the app,
   each with its profile embedded and its entitlements; the entitlements read back from
   each signature must equal the computed ones, and every Mach-O in the app must pass
   `codesign --verify --strict -R '=anchor apple generic and certificate
   leaf[subject.CN] = "Apple Distribution: "* and certificate leaf[subject.OU] =
   "TEAM"'` (a chain to Apple's root, not a name: a self-signed certificate called
   "Apple Distribution" fails it). The dry run requires a valid ad-hoc signature made
   by the export, never the linker's. A file with a fat Mach-O magic that is not a
   plausible fat header stops the job rather than being skipped.
4. The `.ipa` (Payload + the archive job's `Symbols` folder, whose entries must be
   plain `<UUID>.symbols` files) is unzipped once more and verified, then `altool
   --upload-package` sends it. The build appears in TestFlight after Apple's
   processing.

macOS gets the same walk after signing and again in the release checks: every Mach-O
in `Hollow.app` must satisfy Developer ID's own requirement pinned to our certificate
(`anchor apple generic`, the Developer ID CA and Application markers, the exact
`Developer ID Application: NAME (TEAM)` common name and the team), with a secure
timestamp and the hardened runtime.

### The DMG

`hdiutil create -srcfolder` builds the DMG from a staged folder holding the stapled app,
an `/Applications` link and the committed layout in `scripts/macos_dmg/layout`
(`DS_Store`, `background.tiff`, `VolumeIcon.icns`, copied in under their dot names).
No npm, no create-dmg, nothing untrusted is ever mounted in a job holding a key. Before
staging, the layout files must be exactly the ones `scripts/macos_dmg/layout.sha256`
lists. After `hdiutil`, and again after signing and stapling, the DMG is mounted
read-only and its whole tree must equal the staged one (`mtree`: type, link, mode,
sha256, file flags, extended attributes); the volume root is checked on its own (a 755
directory whose only Finder info is the custom-icon flag). Then the app inside the final
DMG passes `codesign --verify --deep --strict`, `spctl` and `stapler validate`.

The volume name is always `Hollow` (no version): the committed `.DS_Store` reaches its
background through an alias that names the volume. To change the window, the background
or the icon, run `scripts/macos_dmg/make_layout.py` once on a Mac (its header says how)
and commit the three files and `layout.sha256` together. The background is create-dmg's
(MIT, `scripts/macos_dmg/NOTICE`).

### Handoffs between jobs

A producing job publishes its upload's `artifact-id` and the sha256 of what it packed as
job outputs; the next job downloads by that id into a fresh directory (the action also
checks the artifact's own digest) and `scripts/apple_ci_unpack.sh` refuses the tar unless
it hashes to the published value, holds nothing outside its one top-level directory, and
that directory does not exist yet. Nothing is ever checked against a hash list that
travelled with the files.

**Take release files only from a run where every job is green and whose attestation
verifies** (below). A red or cancelled run's artifacts are never published, whatever
their names.

## Checking what you downloaded

```bash
REPO=VitalikPro13/HOLLOW   # or the private mirror, see "The embargo"
for f in hollow-X.Y.Z.dmg hollow-X.Y.Z-macos.zip; do
  gh attestation verify "$f" --repo "$REPO" \
    --signer-workflow "$REPO/.github/workflows/release-apple.yml" \
    --source-ref refs/heads/main --deny-self-hosted-runners
done
```

Both must print a verified result naming the run. Also compare `shasum -a 256` of both
files with the two hashes `macos-release` wrote to the run's summary page.

## Pinned inputs

| Input | Pin |
|---|---|
| Xcode | `/Applications/Xcode_26.6.app` on `macos-26` (the `XCODE_APP` env) |
| Flutter | tag `3.47.0`, checked against commit `4cf24164...` (`FLUTTER_COMMIT`) |
| Rust | `HOLLOW_RUST_TOOLCHAIN = 1.99.1`: the job installs exactly it and checks `rustc --version`; cargokit (`rust_builder/cargokit`) builds hollow_core with it (an installed exact version counts as installed, so it is never fetched again); after the build `scripts/apple_ci_rustc_check.sh` requires every `/rustc/<commit>/` path in the built hollow_core to name that rustc's commit |
| Dart packages | `flutter pub get --enforce-lockfile`, then `git diff --exit-code pubspec.lock` |
| Crates | `--locked` on release builds (`rust/hollow_core/cargokit.yaml`), then `git diff --exit-code Cargo.lock` |
| mdk, WebRTC-SDK pods | `third_party/apple_pods/*.podspec.json`: tagged release assets with `sha256` (mdk = the v0.36.0 release); `Podfile.lock` must not move |
| opus, libogg (screen audio helper) | `URL_HASH SHA256` in its CMakeLists |
| Apple intermediates | Developer ID G2 + Developer ID CA (macOS), WWDR G3 (iOS): sha256 in `scripts/apple_ci_keychain.sh` |
| DMG layout | `scripts/macos_dmg/layout.sha256`; `make_layout.py`'s two pip packages are pinned by hash in `make_layout.requirements.txt` (offline tool, never CI) |
| Actions | commit SHAs |

Two plugins (super_native_extensions, irondash) carry their own cargokit, which
downloads their prebuilt binaries checked against the public key in their
`cargokit.yaml`, and builds from source with the runner's `stable` only if none fits.
Nothing is cached between runs. To bump Rust: change `HOLLOW_RUST_TOOLCHAIN` in the
workflow after the new version passed `ci.yml`.

## Environments, secrets and variables

Two GitHub ENVIRONMENTS, never repository or organisation secrets: the dry-run jobs run
without an environment and must find nothing.

| Environment | Used by | Holds |
|---|---|---|
| `apple-developer-id` | `macos-release` | the Developer ID .p12 and a notary-only API key (Developer role) |
| `apple-asc-upload` | `ios-upload` | the Apple Distribution .p12, the three App Store profiles, the Firebase config and an upload API key (Developer role) |

No Admin key exists anywhere in this pipeline.

**Settings for BOTH environments** (Settings > Environments > the environment):
- Required reviewers: Vitalik. (Leave "Prevent self-review" off while he is the only reviewer.)
- Deployment branches and tags: "Selected branches and tags", exactly one rule, branch
  `main`. No tag rules.
- "Allow administrators to bypass configured protection rules": OFF.

**Repository settings:**
- Settings > Secrets and variables > Actions: no repository or organisation secret or
  variable with any name below (an environment secret of the same name would be
  shadowed for nothing, and a repository one is readable by every job).
- Settings > Actions > General > Actions permissions: allow only actions created by
  GitHub (plus any named ones `ci.yml` needs), and turn on "Require actions to be pinned
  to a full-length commit SHA".
- Never register a self-hosted runner on this repository; the workflow asks only for
  `macos-26` and `ubuntu-latest`, and the attestation check refuses self-hosted runs.
- If an environment called `release` or an App Store Connect key with the Admin or App
  Manager role was made for an earlier draft of this pipeline: delete that environment
  and revoke the key.

**A ruleset on `main`** (Settings > Rules > Rulesets > New branch ruleset, target the
default branch, enforcement Active): the environments trust `main`, so whoever can
move `main` can sign.
- Restrict deletions, and Block force pushes.
- Require signed commits (GitHub checks them against the signing keys on the pusher's
  account; turn on vigilant mode there), and "Restrict updates" with only the
  repository admin on the bypass list.
- Bypass list: nobody else. No GitHub App or deploy key with write access.

**Tokens.** A fine-grained personal access token for this repository never gets
Actions, Deployments, Environments, Administration or Workflows write (any one of them
can start this workflow, approve its deployment or change the gate), and Contents
write only where a script must push. No classic token with the `repo` or `workflow`
scope.

**The single reviewer.** Vitalik is the only required reviewer and the only one who
can push to `main`, and "Prevent self-review" is off. Whoever holds his GitHub session
(or a token as above) can therefore push a commit, start the run and approve both
environments alone: the reviewer gate protects against everyone but him. What stands
in the way: a hardware security key as his only second factor, signed commits (a
stolen session can add a signing key, so watch the security log for one), short-lived
tokens without the scopes above, and reading the run's summary hashes before
publishing. A second reviewer with "Prevent self-review" on removes this, once there
is one.

### `apple-developer-id`

| Name | Kind | What it is and where it comes from |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | secret | Keychain Access on the Mac that holds "Developer ID Application: NAME (TEAM)": export the certificate WITH its private key as a .p12 (only that one identity), then `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | secret | the password typed at that export |
| `NOTARY_KEY_ID` | secret | App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > "+", name "Hollow notary", Access **Developer**: the new key's Key ID |
| `NOTARY_ISSUER_ID` | secret | the Issuer ID shown above that key list |
| `NOTARY_KEY_P8_BASE64` | secret | that key's `AuthKey_<id>.p8` (downloadable once): `base64 -i AuthKey_<id>.p8 \| pbcopy` |
| `MAC_TEAM_ID` | variable | the 10-character Team ID (developer.apple.com > Membership) |
| `MAC_SIGN_NAME` | variable | the NAME part of the Developer ID certificate's common name (`security find-identity -v -p codesigning` on that Mac) |

### `apple-asc-upload`

| Name | Kind | What it is and where it comes from |
|---|---|---|
| `DISTRIBUTION_P12_BASE64` | secret | an "Apple Distribution" certificate (Xcode > Settings > Accounts > the team > Manage Certificates > "+" > Apple Distribution, or developer.apple.com > Certificates), exported from Keychain Access WITH its private key as a .p12 holding only that identity, base64 as above |
| `DISTRIBUTION_P12_PASSWORD` | secret | the password typed at that export |
| `IOS_PROFILE_APP_BASE64` | secret | developer.apple.com > Profiles > "+" > Distribution: **App Store Connect**, App ID `com.anonlisten.hollow`, that Apple Distribution certificate; download the `.mobileprovision`, base64 it |
| `IOS_PROFILE_NOTIFICATION_SERVICE_BASE64` | secret | the same for `com.anonlisten.hollow.NotificationService` |
| `IOS_PROFILE_BROADCAST_EXTENSION_BASE64` | secret | the same for `com.anonlisten.hollow.BroadcastExtension` |
| `GOOGLE_SERVICE_INFO_PLIST_BASE64` | secret | the production `ios/GoogleService-Info.plist` (Firebase project `hollow-push`, app `com.anonlisten.hollow`), base64 |
| `ASC_UPLOAD_KEY_ID` | secret | a second Team Key, name "Hollow upload", Access **Developer**: its Key ID. Apple's role table gives Developer "Upload builds" (developer.apple.com/support/roles); App Manager would add submitting for review, prices and TestFlight groups, which this job never does. If the first real upload is refused for the role, make the key App Manager and note it here |
| `ASC_UPLOAD_ISSUER_ID` | secret | the Issuer ID (the same team-wide value as above) |
| `ASC_UPLOAD_KEY_P8_BASE64` | secret | that key's `.p8`, base64 |
| `MAC_TEAM_ID` | variable | the Team ID, as above |
| `ASC_APP_APPLE_ID` | variable | App Store Connect > the app > App Information > Apple ID (the number) |

The App IDs already carry what the entitlements need (App Groups
`group.com.anonlisten.hollow` on all three, Push Notifications on the app); a profile
made after a capability change must be downloaded again. Profiles expire after a year;
the job names the expired one.

Delete the local .p12, .p8, .mobileprovision and base64 copies once the secrets are
saved; the password manager keeps the originals.

How the jobs handle them: each secret reaches one step as an environment variable; a
.p12 is decoded into a 0600 temporary file, imported NON-extractable into a keychain
whose random password never leaves the import script, and removed before the step
ends; the keychain locks itself after 15 minutes idle for iOS and 60 for macOS (the DMG
is signed after the app's notarization wait), and must hold exactly one identity of the
expected kind and team;
a .p8 lives in a 0600 file deleted by the step's own trap; profiles and the Firebase
config live in a 0700 directory removed by an `always()` step together with the keychain.
No third-party action sees a secret.

## The embargo

A security release must not show its fixes before the binaries exist, and this workflow
builds a commit GitHub can see. Two ways, Vitalik picks:

1. **Short public window.** Windows, Linux and Android are built and signed locally as
   before; then the release commit is pushed to `main` and this workflow runs at once.
   The fixes are public for the length of the run (about 1 to 1.5 hours, mostly
   notarization) before the Apple files exist. Everything works as written, including
   the attestation.
2. **Private mirror.** A private repository (for example `VitalikPro13/HOLLOW-release`)
   receives the release commit on its own `main`, holds the two environments and their
   secrets (the public repository then holds none), and runs this workflow unchanged:
   nothing in it names the repository. Costs: macOS runner minutes on a private
   repository count ten times against the plan's included minutes, so a release run is
   billed; and attestations for a private repository need GitHub Enterprise Cloud, so
   `macos-attest` skips itself there and the files carry only the run's hash outputs
   and our own `release_provenance.py` record. With Enterprise, it attests and the check
   above runs with `REPO=` the mirror.

## Rotation, and the move to the new Apple team

Nothing tracked names the team, so a rotation changes only secrets and variables:

1. New team: set `MAC_TEAM_ID` in both environments.
2. New Developer ID certificate (only the Account Holder can create one): replace
   `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`, set `MAC_SIGN_NAME`.
3. New Apple Distribution certificate: replace `DISTRIBUTION_P12_*` and make the three
   profiles again with it (a profile names its certificate).
4. New API keys in the new team's App Store Connect (both Developer: one for notary, one
   for upload): replace the `NOTARY_*` and `ASC_UPLOAD_*` secrets, revoke the old keys.
5. `ASC_APP_APPLE_ID` stays across an app transfer. The Firebase plist changes only if
   the iOS app is registered again in Firebase; after the transfer, upload the new
   team's APNs auth key to Firebase.
6. Run once with `sign: true` and `upload_ios: true` and read the checks.

A leaked key: revoke the API key in App Store Connect, or revoke the certificate in the
developer portal (notarized apps already shipped keep working), then replace the secrets.

The iOS project still names the old team literally on its two extensions; CI signs
outside Xcode, so it does not care. An Xcode GUI archive after the transfer needs those
six lines changed.

## The manual App Store step

The workflow stops at TestFlight. To ship to the App Store: App Store Connect > the app >
the new version > Build > pick the uploaded build, fill in "What's New", answer the export
compliance question (already answered by `ITSAppUsesNonExemptEncryption = NO` in
Info.plist), keep the review notes, age rating and privacy answers consistent with the
last submission (memory `project_ios_app_store_submission_2026_09`), then Submit for Review.

## How it fits the rest of the release

`release_provenance.py` (SLSA L1, run on the Windows PC before `sign_manifest.ps1`) is
unchanged: it still hashes all seven artifacts into `hollow-X.Y.Z.provenance.json`, which
ships next to them and on the GitHub release. The workflow adds a stronger record for the
two macOS files: a Sigstore-signed GitHub attestation tying their sha256 to the
repository, this workflow file, `main` and a GitHub-hosted runner. The two agree when the
dmg and zip in `installer\Output` are the ones the run produced (compare with the hashes
on the run's summary page).
