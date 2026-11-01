# HOL-SEC-187 follow-up: where Apple keychain secrets live

Design for approval, revision 2 (after the hostile review
`HOL_SEC_187_KEYCHAIN_DESIGN_REVIEW.md` and Vitalik's answers of 2026-10-31). EMBARGOED
with HOL-SEC-187 (local branch `security/0.14-mac-dylib`, base `55a5c4f3`). No product
code is written until Vitalik approves.

Scope: the macOS identity key that every old signed build still opens without a prompt,
and the Apple team transfer (old team `NWPBHZX7DT` to new team `XMTJT2AV6F`), which
changes the keychain prefix on macOS and iOS. One design answers both.

## Open questions for Vitalik

None. Vitalik approved revision 2 on 2026-10-31 with the answers below; the build may start
(builder-secure, then the hostile review, per the 0.14 plan).

Decided (2026-10-31):

- **The design (was Q1): APPROVED.**
- **Certificates (was Q2): sign 0.14 with a FRESH old-team Developer ID certificate if the
  transfer is far off, and revoke the one that signed 0.5.0 to 0.13.0 early; otherwise
  revoke once Macs run new-team builds.** The old team's Account Holder is a relative of
  Vitalik's; Vitalik is an Admin with full access in the old team's App Store Connect, and
  arranges the Account Holder-only steps (Developer ID certificates, revocation, starting
  the transfer) through them.
- **Duress code (was Q3): accepted.** If enclave keys cannot change group, the one-time
  "set your duress code again" note ships, and an ignored note leaves a duress code that
  does nothing after the transfer.
- **Older Macs (was Q4): one recovery-phrase prompt at the team change** for macOS 12 and
  13 if they refuse the app group; the minimum stays. A runner may start headless macOS 12
  and 13 VMs on the mini for the drill.
- **Time Machine (was Q5): do NOT exclude the data folder.** After the move the key lives
  in this-device-only storage, which a backup does not carry to another Mac (the drill
  checks it); excluding the folder would remove people's only local history copy.
- **Transfer order (Vitalik):** the newest version published on the App Store (0.13 is in
  TestFlight, the App Store still has 0.12.2), then a notice that TestFlight closes in
  about a week (or remove its builds), then the Account Holder starts the transfer (it is
  refused while TestFlight is on), wait for it to finish, then announce the App Store
  availability on GitHub and the website.
- **This Mac only (was Q2): accepted.** A Mac moved with Migration Assistant or restored
  from Time Machine after it ran 0.14 shows the key-missing screen and comes back with the
  recovery phrase as a new device. Caveat (review F13): a move from a Mac still on 0.13
  carries the old login-keychain item along, the first 0.14 start on the new Mac moves it,
  and that clone of the device stays a clone. Finding clones is out of scope.
- **Revocation (was Q3): yes, and REQUIRED, not optional.** Until it happens, an old build
  can still run on the Mac with Hollow's privacy grants and can show phishing screens
  (section 2.2). U10 adds the question whether revocation also stops a revoked-certificate
  LIBRARY loading into a valid app, and the team-signed Debug bundles of review F3 count
  in the revocation case.
- **Automatic copy of `hollow_data` (was Q4): DROPPED.** About five testers; the signed
  status notice (save the phrase, make a `.hollow` backup) covers a lost container. Review
  F14 is moot.
- **The drill (was Q5): at the old Mac mini's visit** (the same visit as exporting the
  signing certificates and finishing the macOS and iOS release CI), on Vitalik's REAL
  iPhone, with the review's macOS additions. Section 4.3.
- **Sequencing (was Q7):** one concrete sequence in section 5: every mover and fallback is
  in 0.14, nothing security-relevant is left for a later old-team release.

Things to know, no decision needed: a local Debug build is always ad-hoc after this change
(review F3), so it can never open a keychain-protected identity (it shows the key-missing
screen and deletes nothing); development uses throwaway data roots anyway. In App Store
Connect, turn "iPhone and iPad Apps on Apple Silicon Macs" off (review F15, step 0).

## Recommendation

- macOS: the identity key moves from the file-based login keychain into the
  data-protection keychain, group `group.com.anonlisten.hollow.keys` (the team's app-ID
  group where a Mac refuses it), this device only, authorised by a Developer ID profile
  only fixed builds embed. Builds 0.5.0 to 0.13.0 carry no keychain entitlement and cannot
  see it. Before any read, the main executable proves every loaded library is this
  release's own, so old team-signed code cannot be swapped into the entitled process.
- Nothing Hollow builds ever writes the file-based keychain again. The move copies each
  item, reads it back, then deletes exactly the item it read, so a crash or a concurrent
  writer never loses a key (a missing key still deletes nothing).
- The same group is Apple's documented transfer vehicle (forum 706128). iOS App Lock
  entries and Secure Enclave keys move into it in 0.14 too, so 0.14 is both the fix and
  the transfer's migration release.
- Revoke the old team's Developer ID certificate after Macs run new-team builds; it is the
  only thing that ends the old builds' privacy grants and phishing screens.
- The drill (real iPhone, Developer ID Macs) gates the transfer. The status notice is the
  net.

| Option | Old build + injected dylib, before | After the move | Team change | Cost and risk |
|---|---|---|---|---|
| **A. Data-protection keychain, app-group access group, bundle self-check (recommended)** | reads the key (status quo) | reads nothing: no entitlement, and it cannot swap its code into 0.14 | survives if the group transfers (Apple recipe; macOS UNVERIFIED) | a profile becomes a launch dependency (F1), the self-check, the drill |
| A2. Same, team app-ID group only | same | same | lost: phrase on every Mac | simplest; no transfer value |
| B. File-based item, ACL requires a marker only fixed builds carry | same | no silent read, but a prompt can ask | needs a login-password prompt to admit the new team | private API for custom requirements, deprecated keychain, social-engineerable prompt, rides Time Machine |
| C. Revoke the old Developer ID certificate | same | old builds do not launch (online Macs) | not a storage answer | required complement of A, never a replacement |
| D. New macOS bundle identifier | same | prompt instead of silent read | not an answer | breaks updates, every grant, links |

## Review disposition

| Finding | Decision | Where |
|---|---|---|
| F1 profile may stop old-team Mac builds launching at the transfer | Accepted. Drill pass criterion (delete group and App ID on the old team, launch after reboot and 48 h), a DTS question, and a contingency in the transfer steps | 2.1, 4.1, 4.3 (D3), 4.4 steps 2-3, U6 |
| F2 old build rewrites 0.14; old team-signed library runs attacker data inside the entitled process | Accepted. Main-executable check of every loaded image against a sealed cdhash list before any key read, plus a load callback; macOS 14+ library constraint as a second layer; revocation required; App Management text corrected | 2.2, 2.5, U10, U14 |
| F3 local Debug builds take the release identity | Accepted (verified: `macos/Flutter/Flutter-Debug.xcconfig:8`, `project.pbxproj:755`, `scripts/build_macos_release.sh:66-79`). Debug pinned to ad-hoc, gate refuses a JIT engine in a team-signed bundle, old Intel Mac swept, its Debug bundles count in revocation | 2.2, 2.4, 3.4, 4.4 step 0, 6 |
| F4 delete by name can erase a key rewritten during the move | Accepted. Delete by the persistent reference read at step 1; duplicate-on-add = compare | 3.2 |
| F5 runtime availability feeds the cached-key drop | Accepted (verified: `api/identity.rs:103-112`, `:1234-1240`, `:1407-1425`, `:347-385`). Three answers: may write, root eligible, unknown; the drop path reads only root eligibility | 3.1 rule 4 |
| F6 enclave calls naming only the keys group strand today's keys; `hwCreate` deletes in every group | Accepted (verified: `ios/Runner/AppDelegate.swift:482-494`). Lookup order keys group then app-ID group; create and remove name one group; guard checks "names a group"; sweep lists both | 4.2 |
| F7 fallback group: no read order, no promotion, the "same mover" claim false | Accepted. Two-group reads, every-launch promotion in 0.14, defined refusal status | 3.1 rules 3-4, 3.2b |
| F8 conflict copies never forgotten | Accepted. Copies named after the root, forget and heal delete them | 3.2, 3.3 |
| F9 lazy move can run inside a duress wipe | Accepted. One fixed point at launch (`settle_keychain_move`, after the pending wipe, before the launch prompt); wipes never trigger it | 3.2 |
| F10 planted accounts moved without limit | Accepted. Only our names with 32-byte values, capped per run | 3.2 |
| F11 iOS App Lock move cannot target the old group | Accepted. Both groups named explicitly; never delete before the copy reads back; wipes delete in both groups during the move | 4.2 |
| F12 duress note marker already set by 0.12.2 | Accepted (verified: `lib/src/ui/settings/duress_section.dart:146-151`). New marker, plus the line in the status notice | 4.2, 4.4 step 2 |
| F13 Migration Assistant from a 0.13 Mac | Accepted. Decided Q2 and the residual text corrected | Decided list, 7 |
| F14 the copy is torn or useless | Moot: the copy is dropped | Decided list |
| F15 the iOS app on Apple Silicon Macs claims the group | Accepted. Counted in 2.1; availability off at step 0 | 2.1, 4.4 step 0 |
| Citation and wording notes ("Claims checked") | Accepted: `Cargo.toml:133`; certificate checked at install, profile at every launch; 774831's technique was unsupported in 2025, the support is the 2026 rewrite of 706128; tmp3 still calls 841686 unanswered | 1.1, 2.1, 4.2, 7 |

Nothing in the review is refuted. One point is narrowed: F2's "a new certificate does not
change that" is right for library validation, and the design does not rely on a new
certificate for it; the self-check (2.5) is what closes the swap route in 0.14.

## 1. Today (file:line on `55a5c4f3`)

### 1.1 The macOS identity key

- The wrapping key of a keychain-protected identity (flags `0x02`, or a cached password
  key with `0x03`) is a generic password, service `com.hollow.identity`
  (`rust/hollow_core/src/identity/platform_keystore.rs:265-268`), written with
  `set_generic_password` after deleting the old item (`platform_keystore.rs:270-275`).
  Without `kSecUseDataProtectionKeychain` the SecItem API talks to the file-based keychain
  (forum 696431), so the item lands in the login keychain with an ACL that trusts the
  creating app's designated requirement, which names the bundle id and the team: every
  build we ever signed meets it (HOL-SEC-187, "Old builds").
- Slots: one per profile, `wrapping_key.<16 hex of SHA-256(root)>`
  (`platform_keystore.rs:36-52`), plus the machine-wide legacy slot `wrapping_key`, read
  as a fallback and never written (`platform_keystore.rs:1-9`, `:54-60`).
- Reads try the profile slot, the legacy slot, then a quiet scan of up to 16 other slots
  (`platform_keystore.rs:547-569`); the scan and every write run with keychain prompts
  off (`platform_keystore.rs:70-84`). The unlock heals the winner into the profile slot
  (`api/identity.rs:140-159`). No key = `keychain_key_missing`, nothing touched
  (`api/identity.rs:161-165`, `:316-320`).
- Forgetting deletes the profile slot always and the legacy slot only when its key opens
  the identity being forgotten (`platform_keystore.rs:614-648`); every wipe, profile
  erase, relink and destroy goes through `forget_key_at`/`forget_key_proven`
  (`api/identity.rs`, `api/recovery.rs`, `api/wipe.rs:401,493`).
- `is_available()` is a compile-time answer, true on every macOS build
  (`platform_keystore.rs:323-326`), and it feeds `password_keychain_allowed`
  (`api/identity.rs:103-112`), `default_eligible` (`:1234-1240`) and the Dart-visible
  `os_keychain_available` (`:1407-1425`). When `password_keychain_allowed` is false,
  `drop_cached_key_off_os_root` rewrites a `0x03` identity without the keychain flag and
  forgets the key (`api/identity.rs:347-385`).
- The typed-secret path (`api/identity.rs:176-223`) never reads the keychain; macOS
  registers no hardware key (`identity/hw_key.rs:10-13`).
- The Mac app carries no keychain, application-identifier or app-group entitlement and
  never did (`macos/Runner/Release.entitlements`, unchanged since `a7bb7ec0`); the release
  script signs a copy minus the waiver (`scripts/build_macos_release.sh:106-108`, `:149`)
  and embeds no profile.
- Local builds: `macos/Flutter/Flutter-Debug.xcconfig:8` includes `LocalSigning.xcconfig`,
  which the release script writes with the Developer ID identity
  (`build_macos_release.sh:66-79`), and the Runner Debug config takes its identity from it
  (`macos/Runner.xcodeproj/project.pbxproj:755`) with `DebugProfile.entitlements`
  (waiver on). On a Mac that ran a release, a `flutter run` build is team-signed.
- `security-framework = "3"` without the `OSX_10_15` feature
  (`rust/hollow_core/Cargo.toml:133`), so `use_protected_keychain` is not compiled in. Its
  `set_password_internal` adds, then updates on a duplicate, so update-in-place needs no
  new crate.

### 1.2 macOS App Lock entries

`AppLockService` keeps its entries in `flutter_secure_storage` with
`MacOsOptions(accessibility: unlocked_this_device)` and no group
(`lib/src/core/services/app_lock_service.dart:32-42`); on a computer only the launch
secret matters (`:381-401`). The plugin (darwin 0.3.2) uses the data-protection keychain
on macOS by default (`flutter_secure_storage-10.3.1/lib/options/macos_options.dart:24`,
`FlutterSecureStorage.swift:227-231`) and sets `kSecAttrAccessGroup` only on iOS
(`FlutterSecureStorage.swift:233-237`). With no entitlement the writes most likely fail
and are swallowed (`app_lock_service.dart:392-414`): UNVERIFIED (U9). With the 0.14
profile they start to work, in the app-ID group, a flow never exercised in production.

### 1.3 iOS

- App Lock entries: same plugin, `IOSOptions(accessibility: unlocked_this_device)`, no
  group (`app_lock_service.dart:33-34`), so they sit in the default group, the first
  `keychain-access-groups` entry `$(AppIdentifierPrefix)$(HOLLOW_BUNDLE_ID)`
  (`ios/Runner/Runner.entitlements`). Default-group rule: Apple, "Sharing access to
  keychain items". The class migration reads, DELETES, then writes
  (`app_lock_service.dart:61-87`).
- Secure Enclave keys (B5): one P-256 key per profile, tag `hollow.applock.hw.<id>`,
  `WhenUnlockedThisDeviceOnly` + `privateKeyUsage`, created with no group
  (`ios/Runner/AppDelegate.swift:491-515`); every lookup, list and delete names no group
  (`AppDelegate.swift:441-488`), which matches every group the app has, and `hwCreate`
  starts with `remove(tag)` (`:492-493`), which deletes that tag in EVERY group. The
  identity slot and the duress slot both derive with this one key, one hardware operation
  each (`api/identity.rs:202-223`, `identity/duress.rs:144-170`); the dummy
  `identity.duress` takes the bound flag when the identity has it (`duress.rs:66-86`).
- The push extension has NO keychain: its entitlements claim only the app group
  (`ios/NotificationService/NotificationService.entitlements`) and its code makes no
  SecItem call; it reads the identity from the group container
  (`NotificationService.swift:382-391`). The "NSE shared keychain" in the transfer
  checklist does not exist. The screen-share extension likewise claims only the group.
- The whole data root is `<group.com.anonlisten.hollow>/hollow_data`
  (`ios/Flutter/Variant-prod.xcconfig:5`, `NotificationService.swift:386-387`), excluded
  from backup at every start (`AppDelegate.swift:337-358`).

### 1.4 What an attacker gets today

An old signed build (0.5.0 to 0.13.0, library validation waived) with a dylib injected
reads the legacy item silently, so it opens `identity.key` and `identity.device`, hence
the master key, the device key and the database key: the whole account, plus every privacy
grant the person gave Hollow. Old builds stay downloadable and notarized.

## 2. Where the macOS key moves (Q1)

### 2.1 The new home

Data-protection keychain, generic password, the same service and account names as today,
`kSecAttrAccessGroup = group.com.anonlisten.hollow.keys` (an iOS-style app group used as
an "AGI" keychain access group), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never
synchronizable, no user-presence flag (the unlock stays silent, as the person chose).

Why it holds: macOS builds the data-protection access-group list from the program's
entitlements, and those must be authorised by a provisioning profile (TN3137). An app-group
claim not authorised by a profile clears the "entitlements validated" flag, and the
data-protection keychain then refuses all of its entitlements (forum 721701). An app may
use an AGI group only if every entitlement claim is validated (forum 706128). Library code
gets the host executable's access (TN3137), so a dylib inside an old build has an empty
list. Programs that can claim the group validly: builds signed by the team that holds the
group registration with a profile naming it, that is fixed Mac builds and the iOS app (on
an Apple Silicon Mac too, if "iPhone and iPad Apps on Mac" stays on: review F15; its Rust
never reads `com.hollow.identity` since that store is compiled only for macOS, and step 0
turns the availability off). Section 2.5 keeps old code out of the fixed builds.

The shipped entitlements gain `com.apple.application-identifier`
(`<TEAM>.com.anonlisten.hollow`), `com.apple.developer.team-identifier` and
`com.apple.security.application-groups` = [`group.com.anonlisten.hollow.keys`], added by
the release sign stage to `ENT_SHIP` like the waiver removal, never to
`Release.entitlements` (an ad-hoc clone claiming a restricted entitlement traps at
launch). Gatekeeper checks the Developer ID certificate at install and the Developer ID
PROFILE at every launch; profiles made after 2017-02-22 are valid 18 years (Apple,
"Developer ID"). Expiry is covered; deletion of the profile's App ID or group from the
team is not (review F1): see U6 and the D3 drill case.

Fallback group: where a Mac refuses the keys group (status `errSecMissingEntitlement` on
the add, section 3.1), the item goes to `<TEAM>.com.anonlisten.hollow`. It still closes
HOL-SEC-187 there; it is lost at the team change.

### 2.2 The attacker: an old signed build with a dylib, at each stage

| Stage | What it reads or does |
|---|---|
| Before 0.14 starts | the legacy item, so the whole account (status quo) |
| During the move (milliseconds, at the first 0.14 launch) | the legacy item until its delete; the new item never |
| After the move | no keychain item: the legacy items are gone, the new one is outside every group it has (U2), and it cannot get its code into 0.14 (2.5). It gets `keychain_key_missing` |
| After the old team's certificate is revoked | nothing: it does not launch where revocation is checked (U10) |

Deleting the old item is enough for the keychain when: every legacy item of ours is moved
(all profiles); no build writes the file-based keychain again (source guard); an old build
cannot recreate a useful item (writing one needs the key). If the PERSON downgrades and
restores the phrase inside an old build, it writes a new legacy item for a new device;
the next 0.14 launch moves it.

What an old build can still do after the move, all residual until revocation:

- **Privacy grants.** TCC stores the client's designated requirement, which names the
  team, not a version, so camera, microphone and screen grants still apply to old builds.
  Revocation ends it. Whether a new-team re-grant replaces the stored requirement is
  UNVERIFIED (U7). The person can reset grants in System Settings.
- **Rewrite or replace the installed app.** App Management lets apps of the same team
  modify each other's bundles without a prompt (Apple, `NSUpdateSecurityPolicy`; WWDC22),
  so an old Hollow is exactly a process that may rewrite `/Applications/Hollow.app`, and
  any unquarantined copy launches (the updater itself clears quarantine,
  `api/updater.rs:926-927`). Replacing the main executable or `Info.plist` gives a process
  without the 0.14 entitlements; swapping a framework is what 2.5 refuses. Replacing the
  whole app with 0.13 leaves the phishing below.
- **Phishing.** It can show its own key-missing screen and ask for the phrase or the
  password.
- **Files.** It can read and damage the encrypted files (any process of the user can).
- **Items a quiet read cannot open.** An item written by a differently signed build asks
  the person before it opens; the move skips it, and an old build gets the same prompt.
- **Old backups.** A Time Machine copy of `login.keychain-db` made before the move still
  holds the key next to that day's `identity.key`, for anyone with the disk and the login
  password. New backups hold no usable key (U8). See open question 5.
- **Team-signed Debug bundles.** A Developer ID signed Debug build (review F3) has a JIT
  engine that runs Dart from a file and waives library validation. Before the move it opens
  the legacy item like any old build; after it, 2.5 keeps its frameworks out of 0.14, and
  revocation of the old team's certificate kills it.

### 2.3 Why not B (a stricter file-based ACL)

The file-based keychain is "on the road to deprecation" (TN3137). A marker requirement
would stop the silent read, but trusted-application entries from arbitrary requirements
are not public API, the item still lets a prompt ask the person, partition lists are per
team and change only with the keychain password, and the item rides Migration Assistant
and Time Machine. A wins on every row.

### 2.4 Revocation (required)

Apple: "Any Developer ID app signed with a certificate that has been revoked can no longer
be installed nor launch if it's already installed." Decided: revoke the old team's
Developer ID Application certificate once Macs run builds signed by the new team. That
kills 0.5.0 to 0.13.0, 0.14 (old team) and any team-signed Debug bundle on the old Intel
Mac. Open: question 2 (earlier revocation with a fresh old-team certificate for 0.14 if
the transfer is far off), U10 (offline Macs; whether a revoked-certificate LIBRARY still
loads into a valid app; who revokes). The signed status notice tells anyone left on an old
build to download again.

### 2.5 The bundle self-check (review F2)

Library validation admits any Mach-O of the team, so an old Hollow framework (old Rust
core, old media and WebRTC code with public CVEs) swapped into the 0.14 bundle would run
inside the process that may read the keys group; a crafted file could then turn it into
attacker code. 0.14 refuses that in its main executable (Swift, `macos/Runner`), which
the attacker cannot swap without losing the entitlements:

- The release sign stage writes the cdhash of every Mach-O in the bundle into the app's
  `Info.plist` (key `HollowSealedImages`) before the main executable is signed, so the
  list is bound to the main signature.
- At start, before Rust touches any keychain item, Swift takes the list only from
  `Info.plist` bytes read once that hash to the Info.plist slot of the main executable's
  code directory, the in-memory one whose hash equals the cdhash the kernel validated the
  process against (`csops` `CS_OPS_CDHASH`); the main executable is the image dyld loaded
  as `MH_EXECUTE`, never `Bundle.main` (fix round: an `Info.plist` edited after signing
  re-sealed a swapped framework, review HIGH-1). Then it walks every loaded image
  (`_dyld_image_count`), and for each image inside the bundle compares the cdhash of its
  in-memory code directory with the list and checks page 0 and 31 random `__TEXT` pages in
  memory against that directory's page hashes (the directory mapping can change with the
  file after the load; `__TEXT` is what runs).
- A `_dyld_register_func_for_add_image` callback does the same for every image loaded
  later (mdk opens its plugin libraries at run time) and aborts the process on a mismatch.
- Only after the start check passes does Swift call a Rust switch (`hollow_bundle_checked`,
  registered like `hollow_hw_key_register`); the macOS protected store refuses every read
  and write until it is set, so a host where Swift never ran (a swapped core) reads nothing.
- Decided by Vitalik (2026-11-01): any start mismatch, and a build that claims keychain
  entitlements without a bound list or a team, ENDS the process before the Flutter engine
  exists: a native alert ("Hollow is damaged", download it again from
  hollow.anonlisten.com), then exit status 78. Never the key-missing screen, which would
  ask for the phrase inside a process running someone else's code, and never the App Lock
  launch secret (its macOS read also asks the check, `hollow/bundle_seal`). Ad-hoc and
  Debug builds (no team, no keychain entitlement, no list) still start, keychain shut.
- Second layer on macOS 14 and later: a library load constraint pinned to the team and the
  release's cdhashes (`codesign` library constraints; tooling UNVERIFIED, U14).
- Cost and the callback's timing before an image's initialisers run are UNVERIFIED (U14);
  measured on the signed runner.

## 3. The move on the first 0.14 launch (Q2)

### 3.1 Store rules (0.14 and later, macOS)

1. Writes go only to the data-protection keychain: the keys group, else the app-ID group.
   Never the file-based keychain.
2. A write updates in place, else adds; never delete then add (today's `mac::store`
   deletes first, `platform_keystore.rs:271-273`).
3. Reads name a group: the keys group first, then the app-ID group, by name. Every
   create and delete names exactly one group.
4. Three separate answers, never one boolean (review F5):
   - `protected_writable`: the keys group (or the app-ID group) accepted a probe add of a
     sentinel item. `errSecMissingEntitlement` (-34018) on the keys group = refused, try
     the app-ID group; refused there too = not writable (Debug builds, a broken profile).
   - `root_eligible`: today's root rule (`default_eligible_for`). It is the ONLY input of
     `drop_cached_key_off_os_root` and of the cached-password decisions; availability never
     is.
   - Unknown: any other status (an ssh session, a locked keychain, a transient error).
     Offer nothing new, write nothing, delete nothing, and do not cache it for the process.
   The onboarding default and `os_keychain_available` read `protected_writable`. Not
   writable or unknown: the legacy item stays readable for unlock and NOTHING is deleted.
5. The file-based keychain is reached only by the mover (quiet read, attribute list,
   delete by reference) and by the unlock fallback for an item not yet moved.

### 3.2 The move

Runs at ONE fixed point, a new FFI `settle_keychain_move()` that Dart calls at launch after
the pending wipe and `settle_relink`, before the launch unlock and any prompt (review F9).
Nothing else triggers it: wipes, forgets, unlocks and the typed-secret path never do, so a
duress wipe and the typed timing are untouched. It runs only where the keychain is ours to
touch: `root_eligible`, or a root whose identity already carries the keychain flag; never a
portable or override session. It runs only when `protected_writable` and the self-check
passed.

**a. File-based keychain to the protected keychain.** Only accounts named `wrapping_key`
or `wrapping_key.<16 hex>` with 32-byte values, at most 32 per run; anything else under the
service is left alone, never moved, never deleted (review F10). For each, prompts off:

| Step | Action | If it fails or the process dies here |
|---|---|---|
| 1 | Quiet read of bytes L and the item's persistent reference R. An item that would prompt is skipped. | nothing changed |
| 2 | In the target group: A absent, add A = L (an `errSecDuplicateItem` from a concurrent mover = present). A present and equal, go to 4. A present and different, add `A.m.<16 hex of SHA-256(L)>` = L instead, never touching A. | legacy untouched; retried next launch |
| 3 | Fresh read of what step 2 wrote; it must equal L byte for byte. | legacy untouched; the copy is harmless |
| 4 | Delete by R, the exact item read in step 1 (review F4). A rewrite in between made a new item, so R misses it and the newer key stays. | both hold L; the next launch sees "equal" and deletes |
| 5 | Attribute list; the item behind R must be gone. | logged; retried next launch |

Neither store is ever without L, a key written by another process during the move is never
deleted, and no identity file is rewritten, so the identity always opens from at least one
store. The key is not rotated: rotation adds a file rewrite window and buys nothing against
an attacker who already read it (the master secret is unchanged), nor against a Time
Machine copy (which carries the matching old file).

**b. App-ID group to the keys group (review F7).** Same steps, both ends in the protected
keychain, delete by reference, every launch while any of our accounts sits in the app-ID
group and the keys group is writable. It lets a Mac that refused the keys group (or a later
macOS that starts accepting it) promote its items before the transfer. In 0.14, so the
frozen tag carries it.

Conflict copies are named after the source account, so `A.m.<hash>` belongs to A's root
(`wrapping_key.<suffix>.m.<hash>`, or `wrapping_key.m.<hash>` for the machine slot). The
unlock's existing proof picks the copy that opens the identity (`key_that_opens`, profile
slot then that root's copies first, then the scan) and heals it into the profile slot
(`api/identity.rs:140-159`); after a proven heal the root's other copies are deleted
(review F8).

### 3.3 The special cases

- **Profiles.** All profiles' slots move together, so a profile not opened for months is
  out of reach of old builds too. Slots stay per profile.
- **The machine slot** `wrapping_key` moves byte for byte and stays read-only: nothing
  writes it; forget deletes it, and its `.m.` copies, only when the key opens the identity
  being forgotten.
- **Portable, `HOLLOW_DATA_DIR`, pinned roots.** Never move, never write.
  `drop_cached_key_off_os_root` keeps clearing an older build's cached key, now judged by
  `root_eligible` only; its forget covers both keychains.
- **Password installs.** `0x01` keeps nothing in the keychain. A `0x03` cached key is an
  item like any other.
- **Duress.** The typed secret still derives both slots and never meets the keychain;
  `identity.duress` is untouched. A duress wipe forgets in both keychains without prompts
  and never runs the move.
- **Wipes, erases, relinks, kept-aside data.** `forget_key_at`/`forget_key_proven` delete
  the profile slot and every `<slot>.m.*` in both protected groups and the file-based
  keychain; `legacy_key_opens` proves against all of them. `store_key_at` writes only to
  the protected keychain. One API, so every caller inherits it.
- **Downgrade by the person.** The old build shows the key-missing screen (deletes
  nothing); a phrase restore there makes a new device with a new legacy item; the next 0.14
  launch moves it.

### 3.4 What changes where (for the build after approval)

| Where | Change |
|---|---|
| `rust/hollow_core/Cargo.toml` | `security-framework` features `["OSX_10_15"]` (no new crate) |
| `identity/platform_keystore.rs` | protected store (two groups, accessibility, update in place, named reads, refuses before the bundle check); legacy reader (read with reference, list, delete by reference); both movers; the three answers of rule 4; forget covers both keychains and `.m.` copies; the fake backend gains a second store, a hook between steps and faults |
| `api/identity.rs` | `settle_keychain_move` FFI; `password_keychain_allowed`, `default_eligible`, the drop path and `os_keychain_available` read the split answers |
| `macos/Runner` (Swift) | the bundle self-check and load callback, the `hollow_bundle_checked` switch |
| `macos/Flutter/Flutter-Debug.xcconfig` | no `LocalSigning.xcconfig` include; Debug stays ad-hoc (review F3) |
| `scripts/build_macos_release.sh`, CI sign stage (`.team/b14/sign_stage.patch`) | embed `Contents/embedded.provisionprofile`; add the three entitlements to `ENT_SHIP`; write `HollowSealedImages` before the main signature |
| `scripts/macos_load_gate.sh signed` | also refuse: no profile, a profile not Developer ID, of another team, expired, or not authorising every claim; entitlements read back equal the computed set; a debug (JIT) Flutter engine; a `HollowSealedImages` list that misses or mismatches any Mach-O |
| `ios/Runner/Runner.entitlements`, `ios/Flutter/Variant-*.xcconfig`, `ios/Runner/Info.plist` | second app group `$(HOLLOW_APP_GROUP).keys` (Runner only); `HollowKeysGroup` and `HollowAppIdGroup` (`$(AppIdentifierPrefix)$(HOLLOW_BUNDLE_ID)`) for Swift and Dart |
| `ios/Runner/AppDelegate.swift` | enclave calls with explicit groups (4.2) |
| `lib/src/core/services/app_lock_service.dart` | explicit groups; the copy-then-delete move; a new duress transfer marker |
| `identity/hw_key.rs` | the re-bind path (runtime, if re-grouping is refused); `sweep_orphans` lists both groups and keeps both of a live id's keys |
| `lib/main.dart` launch order | `settle_keychain_move()` after `settle_relink`, before the launch unlock |

## 4. The team transfer (Q3)

### 4.1 macOS (Developer ID, no App Store transfer)

Only the signing team changes. The App ID `com.anonlisten.hollow` (the Mac bundle id is
the iOS one, `macos/Runner/Configs/AppInfo.xcconfig`) and both app groups move to the new
team with the iOS transfer ("its associated App ID is also transferred"; "the app group can
be deleted from the transferor's account and registered to the recipient's account", App
Store Connect Help). The new team makes a Developer ID certificate and profile naming the
keys group; its build reads what 0.14 wrote there (forum 721701: "should", untried, U1).
Items still in the app-ID group are lost: those Macs show the key-missing screen once.
The new build re-asks camera, microphone and screen access.

Risk F1: after the App ID and group leave the old team, an old-team 0.14 might fail its
launch-time profile check. The updater runs inside the app (`api/updater.rs:870-959`), so
it could not heal itself. D3 tests it and DTS is asked; until both answer, the transfer
steps assume the worst (4.4).

### 4.2 iOS

- **App Lock entries** move into the keys group in 0.14 with both groups named explicitly
  (review F11): read from `HollowAppIdGroup`, write to `HollowKeysGroup`, read back equal,
  then delete naming `HollowAppIdGroup` only. Never delete before the copy reads back (the
  old class-migration order, delete then write, is not the template). While any entry is
  still in the old group, wipes and `clearProfile` delete in both groups.
- **Secure Enclave keys** (review F6). Lookup order: the keys group, then the app-ID group,
  for the old tag only. Create and remove name exactly one group, so making a key never
  deletes one elsewhere. 0.14 first tries `SecItemUpdate` of `kSecAttrAccessGroup` from
  the app-ID group to the keys group (U3). If the system allows it, nothing on disk changes
  and the duress slot keeps working. If it refuses: at the next unlock with the secret in
  hand (typed, the biometric copy, the launch secret) make a new enclave key in the keys
  group under a new tag, re-wrap `identity.key` then `identity.device` through the
  existing `tie_to_hardware` order (any failure keeps the old wrap), and keep the old key
  while anything still needs it. The duress slot cannot re-bind (its code is never known):
  it stays on the old key, every try still costs one hardware operation per slot (timing
  unchanged), and a NEW one-time marker (`hollow_app_lock_duress_transfer_asked`; the
  0.12.2 marker is already set for most people and shows only in the Duress card, review
  F12) asks to set the code again, as does the status notice. After the transfer an
  un-reset code fires nothing (open question 3). `sweep_orphans` lists both groups.
- **The extensions** never claim the keys group, so moving App Lock secrets there widens
  nobody's access.
- **The data container** depends on the group transfer. Quinn (forum 841686, August 2026,
  accepted): the transferred app keeps the files already in the container ("Yes. Or at
  least it should"), and installed old-team builds keep working. Forum 774831 (February
  2025): about 25% of one app's users lost their shared container data; Quinn then called
  that technique "not something we support", and the support is new with the 2026 rewrite
  of 706128. No automatic copy (decided); the net is the status notice (phrase and
  `.hollow` backup) and peers' history (catch-up sync refills DMs and servers after a
  phrase restore).
- **Firebase.** Its installation id lives under the team prefix; expect a new token and
  check the app re-registers it (U13). The new team's APNs key goes to Firebase first
  (`reports/reference/APPLE_RELEASE_CI.md:285-287`).
- **The group registration is a key.** Whoever registers `group.com.anonlisten.hollow.keys`
  can sign an app that reads its items. Between the old team's delete and the new team's
  register another team could take it (r. 171616887, forum 706128). Do both steps back to
  back, confirm the registration before any new-team build ships, never delete the group
  afterwards; if it is lost, new builds stop using it (phrase fallback). Proposed
  accepted-risk row.

### 4.3 The drill (at the old Mac mini's visit, before the transfer)

What Apple has not confirmed: the keys group on macOS (U1), re-grouping an enclave key
(U3), container files across a transfer (U4), old-team Developer ID builds after their App
ID and group leave (U6). The real transfer cannot be rehearsed with Hollow's own bundle id
(iOS refuses an install whose application-identifier changed; only the App Store transfer
bypasses that), so the drill has three parts.

- **D1, baseline on the real iPhone.** The production build (old team, from TestFlight or
  Xcode) and the dev variant `com.anonlisten.hollow.dev` (new team) side by side, both a
  0.14 candidate. Shows what does NOT carry over between teams today: the dev build sees
  none of the production build's App Lock entries, enclave keys or group container, and its
  missing-key paths delete nothing. On the production build alone: App Lock entries move
  into the keys group, the enclave key re-groups (or re-binds), and App Lock still opens
  after a restart. This is the negative half and the 0.14 migration on real hardware; it
  cannot show the positive half because the two builds can never share a group.
- **D2, a throwaway group moved between the teams, real iPhone.** Old team registers App ID
  `com.anonlisten.kcdrill.a` and `group.com.anonlisten.kcdrill`; a tiny test app (kept in
  `.team/`, never shipped) writes a this-device-only password into the group, creates an
  enclave key in its app-ID group and re-groups it, creates a second key directly in the
  group, records both keys' ECDH outputs over a fixed point, and writes a file into the
  group container. Then the old team deletes the group and the new team registers it; a
  new-team app `com.anonlisten.kcdrill.b` claiming the group reads the password, gets the
  same two ECDH outputs and reads the file. The old-team app, still installed, must keep
  working. Optional D2b: release the throwaway app on the App Store and run Apple's real
  transfer step on it (it needs one approved version first).
- **D3, the Mac half.** The same with Developer ID profiles: a `kcdrill` Mac app signed by
  each team, on GitHub macOS runners (14, 15, 26) and on the old Mac mini. Pass criteria:
  `sudo launchctl procinfo <pid>` shows "entitlements validated"; an ad-hoc copy gets
  `errSecMissingEntitlement`; the new-team app reads the old-team item after the group
  moved; and review F1's case
  `old_team_app_launches_after_its_group_and_app_id_leave_the_team`: the old team deletes
  the group and then the throwaway App ID, and the installed old-team app must still launch
  and read its item, online, after a reboot and after 48 hours. Also a written DTS
  question on F1.
- **macOS 12 and 13.** GitHub has no runners for them. If a runner may start headless
  macOS 12 and 13 virtual machines on the mini (open question 4), D3 runs there too. Without
  them, U1 stays open for 12 and 13: 0.14's runtime fallback still writes wherever the OS
  accepts, and at the team change those Macs at worst ask for the phrase once, which the
  status notice already prepares.
- **B4 hand drill** (tmp3) on the real phones: wipe Hollow Dev, restore a `.hollow` backup,
  phrase restore with no other device. It proves the net.

What only the real transfer shows: the app's private container and UserDefaults across a
team change of the same bundle id, and the group container at scale. Step 4 checks it on
Vitalik's phone.

### 4.4 The plan, tied to tmp3 (1)-(4)

| Step | What | Who |
|---|---|---|
| 0 | register the keys group on the old team (and `group.com.anonlisten.hollow.dev.keys` on the new team), add it to the App IDs, remake the three iOS profiles, create the Developer ID profile; turn "iPhone and iPad Apps on Apple Silicon Macs" off; sweep the old Intel Mac for team-signed Debug bundles and delete its `LocalSigning.xcconfig` | Vitalik (portal), old Mac visit |
| 1 = tmp3 (1) | **0.14**, old team: the macOS move and promotion, the self-check, iOS App Lock entries and enclave keys into the keys group, all with runtime fallbacks | release |
| D | the drill D1 to D3 (same visit as the certificate export; before or after 0.14 ships) | Vitalik, runners |
| 2 = tmp3 (2) | signed status notice: save the phrase, make a `.hollow` backup, set the duress code again (if D2 showed re-grouping fails), and for Macs: "after the move you may have to download Hollow again" until D3 and DTS clear F1 | release |
| 3 = tmp3 (3) | only after D passes: App Store version approved, TestFlight ended, transfer the app; delete and re-register BOTH groups on the new team back to back; confirm; the first new-team Mac build and the website download go live the same day | Vitalik, release |
| 4 = tmp3 (4) | first new-team release (iOS and Mac); on his phone: history, App Lock opens without the phrase, a push arrives; on a Mac: opens silently | Vitalik |
| 5 | once Macs run new-team builds: revoke the old team's Developer ID certificate (decided) | old team Account Holder |

## 5. Sequencing (was Q7)

One concrete sequence, robust to the drill landing after the 0.14 freeze: **0.14 contains
every mover and every fallback, and the drill gates only the transfer.**

- 0.14 writes the keys group wherever the OS accepts it and the app-ID group elsewhere,
  promotes app-ID items on every launch (3.2b), tries to re-group enclave keys and re-binds
  when refused, and carries the duress transfer note dormant until the re-bind path runs.
  Each branch is chosen at run time from Apple's answer, so no outcome of the drill needs
  new security code.
- The drill (D1 to D3) can run before or after 0.14 ships; its results decide whether and
  when step 3 happens and what the status notice says. If it shows the keys group does not
  survive a move at all, the transfer waits (or the team change goes without it, with the
  phrase), and nothing in 0.14 has to change.
- After 0.14 the only old-team work is the status notice (signed feed content, not code).
  The automatic copy is dropped, so no wipe path changes after the frozen tag.

The prerequisite is step 0 before the 0.14 build: the keys group and the Developer ID
profile must exist on the old team, which needs the same old-Mac visit as the certificate
export the CI route already needs.

## 6. Tests (Q5)

Each rule gets a test that fails without it; the mutation pass covers the store rules, the
mover order, delete by reference, the split answers and the forget paths, in every layer
that enforces them (Rust store, Swift self-check, load gate).

| Property | Test | Where |
|---|---|---|
| a legacy item moves byte for byte, then leaves | `a_legacy_key_moves_into_the_protected_keychain_then_leaves` | Rust, fake two-store backend |
| a cut-short move finishes next launch | `a_move_cut_short_keeps_both_and_finishes_at_the_next_start` | Rust |
| a copy that does not read back keeps the legacy item | `a_protected_copy_that_does_not_read_back_keeps_the_legacy_key` (faults ReadBackMissing, ReadBackWrong, StoreFails) | Rust |
| a key rewritten during the move survives; two movers keep everything | `a_legacy_key_rewritten_during_the_move_is_never_deleted`, `two_movers_at_once_keep_every_key` | Rust, hook between steps |
| a different protected value is never overwritten; heal leaves no copy; a wipe forgets copies | `a_conflicting_legacy_key_never_overwrites_the_protected_one`, `heal_leaves_no_conflict_copy_behind`, `a_wipe_forgets_the_conflict_copies_too` | Rust |
| only our names move | `planted_legacy_items_are_not_moved` | Rust |
| every profile and the machine slot move, the machine slot stays read-only | `every_profiles_slot_moves_not_only_the_running_one`, `the_machine_slot_moves_once_and_is_never_written` | Rust |
| app-ID items open and promote | `an_item_in_the_app_id_group_opens_and_moves_once_the_keys_group_works` | Rust |
| nothing writes the file-based keychain | `no_flow_writes_the_legacy_keychain` + CI source scan (no `set_generic_password` without protected options in `hollow_core`) | Rust |
| a refused or unknown probe deletes nothing and never drops a cached key | `a_missing_entitlement_keeps_the_legacy_key_and_deletes_nothing` (with a typed `0x03` unlock and a password change), `a_failed_probe_never_drops_the_cached_key_on_the_os_root`, `an_unknown_probe_is_not_cached` | Rust |
| portable and override sessions touch nothing | `a_portable_or_override_session_moves_nothing` | Rust |
| the move runs once, at launch, never in a wipe | `the_move_runs_before_the_launch_prompt`, `a_duress_wipe_moves_nothing` | Rust |
| wipes forget both keychains, quietly; writes update in place; the typed secret reads no keychain | `a_wipe_forgets_the_key_in_both_keychains`, `a_keychain_store_never_asks_the_person` (extended), `a_protected_write_never_deletes_first`, `a_typed_unlock_reads_no_keychain` | Rust |
| no read before the bundle check | `the_protected_store_reads_nothing_before_the_bundle_check` | Rust |
| enclave keys: old key still opens until moved; making a key deletes none elsewhere; re-bind keeps the old wrap on failure; equal cost per try | `a_key_left_in_the_app_id_group_still_opens_until_it_moves`, `making_a_key_never_deletes_one_in_another_group`, `a_bound_identity_moves_to_the_group_key_at_the_next_unlock`, `the_duress_slot_keeps_its_old_key_until_the_code_is_set_again`, `every_try_costs_the_same_hardware_operations_with_two_keys` | Rust fake oracle; Swift on D1 |
| App Lock entries move safely | Dart `app lock entries move into the keys group and survive a cut-short move`, `a delete of the old entry leaves the new one` | `flutter test` |
| the transfer note shows even after the 0.12.2 note | Dart `the_transfer_note_shows_even_after_the_0122_note` | `flutter test` |
| every Apple keychain call names a group; the extensions never claim the keys group; Debug never takes the release identity | Dart source guards over `AppDelegate.swift`, `app_lock_service.dart`, the iOS entitlements, `macos/Flutter/*.xcconfig` (`flutter_debug_config_never_takes_the_release_identity`) | `flutter test` |
| the shipped Mac app embeds a valid profile, a complete sealed-image list and no debug engine | `macos_load_gate_test.sh` new cases (missing, wrong team, expired, unauthorised claim, a Mach-O missing from or mismatching `HollowSealedImages`, a JIT engine) + `macos_load_gate_guard_test.dart` | CI, scratch bundles |
| signed 0.14 moves the key; signed 0.13 cannot read it, even with a dylib; a swapped framework reads nothing | install 0.13, make a throwaway keychain identity, install 0.14, launch (legacy gone, identity opens), relaunch 0.13 (key-missing in the log), an injected dylib's protected query returns `errSecMissingEntitlement`; copy signed 0.14, swap one framework for 0.13's, launch: no protected read, the log names the refusal, nothing deleted; the macOS launch secret reads back after a restart (U9); `launchctl procinfo` shows "entitlements validated" | GitHub macOS runner, throwaway user keychain (U11) |
| transfer mechanics, history across the real transfer | D1 to D3; step 4 | Vitalik's iPhone, runners, the old Mac |

Agents never run keychain, codesign or notarytool commands on the mini or the PC (the
macOS 12 and 13 virtual machines, if approved, are headless and their keychains are their
own); every signed check is a GitHub runner job, a VM job or Vitalik's own hands.

## 7. Text changes (Q6)

**HOL-SEC-187 header status**, until the build lands: "Partially fixed on local branch
security/0.14-mac-dylib (2026-10-31): load paths and the library validation waiver fixed;
the keychain item old builds open moves to the data-protection keychain in 0.14 (design
approved <date>); retest on the signed build". When it lands: "Fixed in 0.14 (the old
builds' privacy grants end with the certificate revocation)".

**Fix**, add: "The identity key moves from the login keychain into the data-protection
keychain, in an access group only builds signed with Hollow's provisioning profile can
claim, this device only. At the first 0.14 launch each Hollow key in the login keychain is
copied there, read back, and only then deleted; nothing writes the login keychain again.
Builds before 0.14 claim no keychain group and cannot see the new item. Before it reads a
key, the app checks that every library it loaded is the one this release shipped, so an
old Hollow cannot put its own older code into the new one. The certificate that signed the
old builds is revoked once Macs run builds of the new team."

**Residual risk**, replace the first bullet with: until the revocation, old builds keep
the privacy grants and can show phishing screens; an item a quiet read cannot open stays
where it is; a Time Machine copy of the login keychain from before 0.14 still holds the
key; whoever holds the keys group registration can read the items (the signing team's
power); a Mac moved by Migration Assistant after 0.14 asks for the phrase, one moved from
a 0.13 Mac stays a clone of it.

**Test**, add the section 6 Rust names, the gate cases and the signed-runner checks.

**HOL-SEC-158**, residual "The macOS Rust keychain item keeps its class (the
data-protection keychain needs a signing change)": resolved (this-device class in 0.14).

**CLAUDE.md**, the identity at-rest line, after "the legacy slot is read-only": "macOS
keys live ONLY in the data-protection keychain (group `group.com.anonlisten.hollow.keys`,
this device only, never synchronizable), read only after the bundle self-check; nothing
writes the file-based keychain; a legacy item is copied, read back, THEN deleted by
reference. Every Apple keychain call names its group; the extensions never claim it
(HOL-SEC-187)." About 330 characters.

**Wiki `security_write_gates.md`**: a new local-only section beside §43 with rows for the
two movers, protected-store writes, the split availability answers, forget in both
keychains with conflict copies, the bundle self-check, the App Lock entry move, and the
enclave key re-group or re-bind. Nothing here is remote-reachable.

**Memory and tmp3**: correct `project_app_store_ugc_1_2_rejection` and
`reference_apple_teams` (the push extension has no keychain; the keys group plan); tmp3's
"forum 841686 unanswered" is out of date (accepted answer, August 2026).

## 8. Unverified claims and how to verify them

| # | Claim | How |
|---|---|---|
| U1 | macOS accepts an iOS-style app group as a data-protection keychain group with a Developer ID profile, on 12 to 26 | D3: PASS on macOS 15.7.4 only (2026-11-01 drill, old iMac, write and read, procinfo "entitlements validated"); 12, 13, 14 and 26 not run, the runtime fallback covers them |
| U2 | an old build (no entitlements) gets `errSecMissingEntitlement` for our group, a dylib inside it too | D3: PASS (an ad-hoc copy claiming the group got -34018; an ad-hoc copy claiming the full set was killed at launch). The signed runner repeats it for the real 0.13 with a planted library |
| U3 | `SecItemUpdate` can re-group an enclave key, and it then works from another team's app | D2: PASS on iOS 18.7.8 (2026-11-01, Vitalik's iPhone 13 mini): status 0, same ECDH before and after, and a new-team app got identical ECDH outputs after the group moved teams; a key made directly in the group survived the move too. Other iOS versions stay on the runtime fallback (re-bind) |
| U4 | group container files survive the group transfer | D2/D3 (file): PASS on iOS 18.7.8 and macOS 15.7.4 (2026-11-01), the new-team app read the file and the old-team app kept reading everything; step 4 still checks the real app |
| U5 | the portal offers App Groups for a Developer ID profile of `com.anonlisten.hollow` | PASS (2026-11-01 drill) |
| U6 | an old-team Developer ID app keeps launching after its App ID and group leave the team | D3 F1 case: PASS at 0 h only on macOS 15.7.4 (launch, read, file; Gatekeeper "accepted, source=Developer ID") and on iOS (ad-hoc A); the restart and 48 h cases were NOT run (the old Mac could not restart). DTS question still open |
| (drill) | the new team can register a group name the old team deleted | accepted at once, no waiting window (2026-11-01); the back-to-back rule of 4.2 still holds |
| U7 | a new-team re-grant replaces TCC's stored requirement | after step 4 |
| U8 | `AfterFirstUnlockThisDeviceOnly` items on macOS survive a locked-screen restart and do not restore elsewhere | signed runner; Migration Assistant if a spare Mac exists |
| U9 | macOS App Lock writes fail today, and work with the profile | signed 0.13, then 0.14 on the runner |
| U10 | revocation stops installed apps offline too; whether a revoked-certificate library still loads into a valid app; who revokes | Apple Developer Support |
| U11 | GitHub macOS runners have a working data-protection keychain | the first runner job |
| U12 | the app's private container and UserDefaults survive the real transfer | step 4 |
| U13 | push re-registers after the transfer | step 4 |
| U14 | the in-memory cdhash check and the add-image callback run before an image's code, at an acceptable cost; macOS 14 library constraints pin cdhashes | Partly answered (fix round, 2026-11-01): initialisers of libraries linked at launch run BEFORE the check (dyld runs them before the executable's code), so the check stops a swapped library from reaching the keychain, the engine or the person, not from running its constructors; library constraints stay the only layer that stops those. Cost on an M4 mini: the whole start check on the real release bundle (38 sealed slices, ad-hoc dry run with the hardened runtime) took 11.9 and 17.5 ms; a full static validation of every image would add about 300 ms per start (hollow_core alone 239 MB, 240 ms), so the check samples 32 `__TEXT` pages per image in memory instead. Signed runner still measures the signed bundle |

## 9. Found on the way (outside this scope)

- **macOS App Lock store has no keychain to write to (UNVERIFIED, U9).** Flaw: the plugin
  uses the data-protection keychain on macOS and the Mac app has no keychain entitlement,
  so the launch secret is probably never kept. Fix: rides this design; the plugin ignores
  `groupId` on macOS, so the entries land in the app-ID group and are lost once at the
  team change (the person types the PIN once). Test: the signed-runner check reads the
  launch secret back after a restart.
- **The macOS store deletes before it adds** (`platform_keystore.rs:270-275`). Low: in
  today's callers a crash in that gap costs the silent unlock, not the identity (something
  else still opens it). Fix: store rule 2. Test: `a_protected_write_never_deletes_first`.
- **The App Lock class migration deletes before it writes**
  (`app_lock_service.dart:72-75`). Low: a crash between loses the biometric copy or the
  launch secret (biometrics off, Hollow asks at launch; nothing that opens the identity).
  Fix: write the new class under a staging key, read back, then delete, or fold it into
  the 0.14 group move. Test: `a_class_migration_cut_short_keeps_the_entry`.
- **The macOS data root rides Time Machine** (the only exclusion is iOS,
  `AppDelegate.swift:353`). After 0.14 a keychain-protected backup opens nowhere (U8), but
  a plaintext identity stays exposed; excluding the root also removes the person's only
  local history backup. Open question 5. Test, if chosen:
  `the_macos_data_root_is_excluded_from_time_machine`.

## Sources

- Apple DTS, "App ID Prefix Change and Keychain Access", forum 706128 (rewritten
  2026-03-31, testing section 2026-04-07): https://developer.apple.com/forums/thread/706128
- Apple DTS on group container files after a transfer, forum 841686 (August 2026):
  https://developer.apple.com/forums/thread/841686
- Shared container data lost after an app group move, forum 774831 (February 2025):
  https://developer.apple.com/forums/thread/774831
- "App Groups: macOS vs iOS: Working Towards Harmony", forum 721701:
  https://developer.apple.com/forums/thread/721701
- TN3137, On Mac keychain APIs and implementations:
  https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- "On Mac Keychains", forum 696431: https://developer.apple.com/forums/thread/696431
- Sharing access to keychain items among a collection of apps:
  https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
- App Store Connect Help, Overview of app transfer and App transfer criteria:
  https://developer.apple.com/help/app-store-connect/transfer-an-app/overview-of-app-transfer,
  https://developer.apple.com/help/app-store-connect/transfer-an-app/app-transfer-criteria
- Apple, Developer ID (certificate at install, profile at every launch, 18-year profiles,
  revocation): https://developer.apple.com/support/developer-id/
- Apple, `NSUpdateSecurityPolicy` (same-team apps may modify each other's bundles):
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsupdatesecuritypolicy
