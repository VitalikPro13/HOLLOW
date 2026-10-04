# Phase E+F slice: distribution (WP5, updater / release pipeline / feeds)

Agent "distribution". Worktree D:/dev/wt/s34-ef @ aa104d48. Read-only pass.
Slice: X-6 (update host, CDN, flatpak repo), TB-5 (Hollow and its
distribution), flows F-70..F-73, the release scripts, the installers (Inno on
Windows, Android APK, Linux tarball + flatpak, macOS), and .github/workflows.
Attacker P-10 (hostile update host / CDN / flatpak repo / network path, or a
PR author). Claims in scope: C-33, C-34, and the AS-10 half of F-71.

## Scope

- Elements: E-02 (Rust core: `api/updater.rs`), E-01 (Flutter UI:
  `updater_provider.dart`, `news_provider.dart`, `status_provider.dart`,
  `system_status_banner.dart`, `news_post_dialog.dart`), E-03 (helpers reached
  through the generated update/relaunch scripts), X-6, X-7 (the feed-link and
  markdown-image surface spills into third-party web).
- Flows: F-70 (manifest + detached sig + archive SHA-256 + install), F-71
  (news + status feeds, unsigned, display-only), F-72 (flatpak OSTree + GPG),
  F-73 (Linux apply: `update.sh`, `flatpak-spawn`).
- Boundaries: TB-5 (client vs distribution), TB-8 (Hollow process vs local
  helpers: the generated shell/bat scripts).
- Specs/standards: TUF attack list (plan 2.2 classes 8/9 and the checklist in
  the brief), SLSA Build L1/L2, OpenSSF Scorecard items touching CI.

## Summary

- STRIDE cells walked: 38 (processes E-02/E-01 full six; the four flows T/I/D;
  X-6/X-7 S/R). All covered or requirement-met except the candidates below.
- Candidates: 7. None Critical. 1 High, 3 Medium, 2 Low, 1 Info.
  - C-DIST-01 (High): unsigned status/news feed opens attacker-chosen URIs of
    any scheme, including `hollow://` deep-link actions (AS-10, F-71).
  - C-DIST-02 (Medium): news markdown body auto-fetches remote images from
    any host on render, so the update host deanonymises every desktop client
    (C-27-adjacent, F-71).
  - C-DIST-03 (Medium): Android APK is signed with the public Android debug
    key; anyone can forge an "update" APK that installs over a sideloaded
    Hollow (C-33 on Android, F-70).
  - C-DIST-04 (Medium): no indefinite-freeze defence. A host that serves the
    last valid signed manifest forever, or 404s it, silently pins every client
    to its current build with no floor, expiry, or signal (TUF freeze, F-70).
  - C-DIST-05 (Low): macOS/Windows in-app updater does not verify the OS code
    signature of the downloaded archive; trust rests on the manifest hash
    alone, and the manifest key has no revocation/rotation drill (C-33, F-70).
  - C-DIST-06 (Low): `apply_update` extracts and stages the archive before the
    Dart app-dir writability probe, and the Windows `update.bat` runs with the
    archive and staging paths interpolated with no shell-metachar guard
    (TOCTOU + injection surface, TB-8/F-73).
  - C-DIST-07 (Info): SLSA Build L0 in practice; releases are built and signed
    on developer machines with no provenance, no hermetic build, no SBOM.
- Requirements: R-DIST-01..R-DIST-12.
- Leads: none of plan section 7's L-01..L-12 are assigned to this slice (they
  are WP1/2/3/8/9). The TUF checklist is answered inline under "Protocol
  checklist".

The core manifest-and-hash chain is sound and well tested: the manifest is
Ed25519-verified with `verify_strict` against a baked-in key before Dart sees
a byte, every download is SHA-256-pinned against the signed manifest before it
is kept, non-https is refused, and only a strictly-newer `latest` reads as an
update. The gaps are at the edges the design already flagged as "display-only"
(the feeds), on Android where the signing key is public, and in the absence of
a freeze defence and build provenance.

---

## Candidates (most severe first)

### C-DIST-01 (High, CONFIRMED): the update host makes a client open any URL it likes, including a Hollow deep-link action, through the unsigned status and news feeds

Attacker: P-10 (anyone who controls `anonlisten.com`'s release folder or the
CDN in front of it, or a network attacker who can MITM that plain HTTPS GET if
the pin ever fails) and, for the self-hosted relay case, nobody (the feed is
official-relay only). Impact Medium, Exploitability High -> High.

`status.json` and `news.json` are fetched with no signature
(`fetch_release_feed`, `updater.rs:81`), by design. Both feed a `link` /
markdown-link rendered as a tappable control that calls `launchUrl` with the
raw parsed URI and no scheme allowlist:

`lib/src/ui/shell/system_status_banner.dart:175`
```
  void _openLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
```
(identical at `system_status_banner.dart:400` for the Home card, and the status
`link`/`linkLabel` are read straight from the feed at
`status_provider.dart:104`.)

`lib/src/ui/dialogs/news_post_dialog.dart:37`
```
                  onTapLink: (text, href, title) {
                    final uri = href == null ? null : Uri.tryParse(href);
                    if (uri != null) {
                      launchUrl(uri, mode: LaunchMode.externalApplication)
                          .catchError((_) => false);
                    }
                  },
```

Because the scheme is unrestricted, a feed can carry `hollow://join/<serverid>`,
`hollow://conf/<id>`, `hollow://share/<...>`, `hollow://redeem/<code>` or
`hollow://recovery/<...>`. `LaunchMode.externalApplication` on the OS hands a
`hollow://` link straight back to this app's own registered protocol handler
(`DeepLinkService._handle`, `deep_link_service.dart:104`). The deep-link
dispatcher does gate the dangerous arms behind a confirm dialog
(`_confirmJoinServer` etc.), so this is not a one-tap takeover, but it lets the
distribution host (which the threat model treats as fully untrusted, AS-10)
inject a prompt that looks like it came from the app itself: a "System status"
notice whose Details button silently drops the user into a Join Server / Join
Conference / Redeem / Join recovery pool confirm, or a `file://` or other
local-scheme URL. The whole point of C-24/AS-10 is that the user's perception
is an asset; a notice styled as a first-party incident banner, carrying a link
the operator chose, is exactly a perception attack. `news.json`'s body is even
freer: arbitrary markdown links, same unrestricted `launchUrl`.

Why it breaks a requirement: threat_model AS-10 ("names, verification state,
notifications, links ... tricked into trusting the wrong party") and F-71's own
authority question ("Can a feed carry a link ... that misleads (AS-10)?"). The
feeds are stated as display-only in WP 23.4 line 1685; a link that invokes an
in-app action is not display-only.

Test: a Dart widget test feeding a `status.json` / `news.json` with
`link: "hollow://redeem/XXXX"` and `javascript:`/`file:` schemes, asserting the
UI refuses to launch anything but http/https (and mailto if wanted). No such
test exists today (`test/relay_status_test.dart` covers only parsing and the
self-hosted gate).

Fix: allowlist the scheme at both call sites to `http`/`https` (and whatever
else is deliberately wanted), before `launchUrl`; never let a feed-sourced URL
reach the `hollow://` handler without the same confirm path a pasted link gets.
Confidence CONFIRMED: traced both feed parsers, both link widgets, the deep
link dispatcher, and url_launcher usage.

### C-DIST-02 (Medium, CONFIRMED): the update host learns every desktop user's IP and online moment, because the news body auto-fetches remote images on render

Attacker: P-10 / P-12. Impact Low, Exploitability High -> Medium.

`news_post_dialog.dart:34` renders the feed-controlled body with
`MarkdownBody(data: post.body, ...)` and passes no `imageBuilder`, so the
package's default builder runs. In flutter_markdown_plus 1.0.7
(`_functions_io.dart:25`) the default builder fetches any `http`/`https` image
URL through `Image.network` the instant the widget builds:
```
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    return Image.network(
      uri.toString(), ...
```
So a news post containing `![x](https://tracker.example/p.gif)` makes every
client that opens the News post dialog issue a GET to an arbitrary host chosen
by whoever controls the feed file. The News card itself shows only a plain-text
excerpt (`plainNewsExcerpt`, `home_rail.dart:194`), so the fetch needs the user
to open the post, but the dialog is one tap from Home. This is the "reading a
message makes no request" promise (C-27) applied to the wrong surface: C-27 is
about link previews in chat; the news feed has no such guard and is read from
the untrusted distribution host. It is a confirmable deanonymisation and
online-presence oracle for P-10.

Why it breaks a requirement: the feed is "display-only ... nothing fetched
through them is executed" (WP 23.4) understates it; a rendered remote image is
a silent outbound request to an attacker-named host. threat_model AS-05
(metadata: IP, activity) and the spirit of C-27.

Test: a widget test that pumps `news_post_dialog` with a body containing a
remote image URL and asserts no network image widget is created (or that an
`imageBuilder` drops/!-fetches it).

Fix: pass an `imageBuilder` to `MarkdownBody` that renders nothing (or only
bundled assets) for remote schemes, or strip image nodes from feed bodies.
Confidence CONFIRMED: read the dialog and the package default builder.

### C-DIST-03 (Medium, CONFIRMED): any party can build an APK that upgrades a sideloaded Hollow, because the Android release is signed with the public debug key

Attacker: P-10 (anyone serving an APK, e.g. a mirror, a "download" site, or
the official host if compromised). Impact High, Exploitability High, but the
precondition (deliver the APK to the device and the user taps install) lowers
it -> Medium.

`android/app/build.gradle.kts:37`
```
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
```
Every shipped APK (confirmed 0.8.0..0.11.1 in memory
`reference_android_debug_keystore_signing`) carries the stock Android debug
certificate, whose keystore password is the public default `android` and whose
key is possession of a file that ships inside every Android SDK's
`~/.android/debug.keystore`. Android's update-signature-continuity check (the
only thing protecting a sideloaded app from a malicious update) therefore
protects nothing here: anyone can produce a debug-signed APK with the same
`applicationId` `com.anonlisten.hollow` and a higher `versionCode`, and it
installs over an existing Hollow as a legitimate update. The in-app updater
does not apply to Android (phones update "through their stores",
`updater_provider.dart:206`), so C-33's signature promise rests entirely on the
APK signature, which is forgeable.

Why it breaks a claim: C-33 ("The app installs only updates signed by Hollow's
offline release key") is false on Android; there is no offline release key
there, and the key that is used is public. AT-5 ("run code on Alice's machine:
a malicious update").

Note this is a known, documented state (memory says a real release keystore is
a deliberate breaking migration, sequenced with Play Store). It belongs in the
report as a finding so the audit record is honest; whether to accept it (as a
pre-Play-Store posture) or fix it is Vitalik's call. If accepted it needs an
`accepted_risks.md` row; today it is neither in `claims.md` as a caveat nor in
`accepted_risks.md`.

Test: an `apksigner verify --print-certs` assertion in the release pipeline (or
CI) that the release cert is NOT `CN=Android Debug` / SHA-256 `b18fce37...`.
No such check exists. Confidence CONFIRMED.

### C-DIST-04 (Medium, CONFIRMED): a host can freeze every client on its current build forever, because there is no manifest expiry and no "latest seen" floor

Attacker: P-10. Impact Medium (users never learn about a security release),
Exploitability High -> Medium.

TUF's indefinite-freeze attack: the download host serves an old-but-valid,
correctly-signed manifest (or simply 404s/stalls the manifest) indefinitely, so
clients never discover a newer release, including one that fixes a security
bug. Hollow's manifest has:
- no `expires` / freshness field. The signature covers the JSON bytes
  (`updater.rs:121`) but the JSON has only `latest`/`versions` (`legal/manifest.json`).
- no monotonic floor: nothing persists the highest `latest` ever seen, so
  re-serving an older signed manifest is undetectable. `isNewerVersion`
  (`version_compare.dart:9`) only compares the served `latest` against the
  running `currentVersion`; a host that keeps serving the manifest for the
  running version just reads as "up to date" (`hasUpdateProvider`,
  `updater_provider.dart:437`).
- a failed check is swallowed (`checkForUpdates` background branch returns
  silently, `updater_provider.dart:238`), so a host that drops the manifest
  produces no signal at all.

The downgrade direction is covered (C-DIST note: `version_compare` refuses a
strictly-older `latest`, class-9 downgrade handled, see below), but freeze is
the un-handled TUF case. Because the git history confirms older signed
manifests still verify under the current key (I verified `e004db41` /
`15a11884` / `65be7514` all `verify_strict` OK against the baked key), any one
of those is a ready-made freeze payload.

Why it matters: WP 23.4 promises integrity, not freshness, so strictly this is
a gap against the TUF checklist the brief names rather than a broken published
claim. It is the right severity for "accepted risk with a reason" if a timestamp
role is judged too heavy for a single-key hobby updater, but it should be
recorded, not silent. The practical partial mitigation already present: the news
feed and the website are separate surfaces, so a frozen manifest does not also
freeze the user's awareness; and self-hosters are unaffected (updater points at
the official host regardless, `kManifestUrl` is hardcoded).

Fix idea (short): add a signed `generated_at` / `expires` to the manifest and
refuse one older than a small window; persist the highest `latest` ever
accepted and refuse a lower one (a "latest seen" floor). Confidence CONFIRMED.

### C-DIST-05 (Low, CONFIRMED): the desktop updater trusts the manifest hash alone and never checks the OS code signature of what it is about to run; the manifest key has no revocation story

Attacker: P-10 with the manifest signing key compromised, OR P-10 serving an
archive whose hash matches a manifest an attacker got signed. Impact High if the
key leaks, Exploitability Low (needs key compromise) -> Low.

The downloaded zip/dmg/tarball is verified only by SHA-256 against the signed
manifest (`download_inner`, `updater.rs:243`). The archive is then extracted and
run (`apply_update` -> `update.bat` / `update.sh` / `flatpak install`) with no
check that the contained `hollow.exe` / `Hollow.app` carries Hollow's
Authenticode / Developer ID signature. On macOS the installed-from-DMG path gets
Gatekeeper, but the in-app updater path strips quarantine
(`update.sh` ... `xattr -dr com.apple.quarantine`, `updater.rs:496`), so a
notarization/Gatekeeper check is actively removed; on Windows nothing checks the
binary's signature at all. So the entire client-side trust in an update reduces
to one Ed25519 key held on the release engineer's machine
(`MANIFEST_SIGNING_KEY`, `C:\Users\Jabun\.hollow-release\manifest_signing.key`).
`MANIFEST_SIGNING_PUBKEYS` is a list to allow rotation (`updater.rs:18`), but
there is no revocation: a leaked key stays valid in every shipped binary until
users install a new build that drops it, and that new build is itself delivered
over the channel the leaked key controls.

Why it matters: defence in depth. C-33 holds as written (updates are signed by
the offline key), but the single point of failure deserves a second,
independent gate (the platform code signature the installers already use). The
Certum/Developer ID signatures exist (`sign_release.ps1`, `build_macos_release.sh`)
but the updater never consults them.

Fix idea: on Windows call `WinVerifyTrust` on the extracted `hollow.exe` before
launching `update.bat`; on macOS `codesign --verify` / `spctl` the staged app
before the swap and do not strip quarantine on a bundle that fails. Longer term
a documented key-rotation-and-revocation runbook. Confidence CONFIRMED
(no signature-verification call exists anywhere in the client, grepped
`WinVerifyTrust|codesign|spctl|Authenticode`).

### C-DIST-06 (Low, SUSPECTED on impact): archive is extracted/staged before the writability probe, and the Windows update.bat interpolates paths with no shell-metachar guard

Attacker: P-10 who already passed the signature+hash gate (so needs the signing
key), OR a local attacker who can write the staging dir. Impact Low,
Exploitability Low -> Low.

Two smaller edges on the apply path (TB-8, F-73):

1. Ordering / TOCTOU. Dart probes app-dir writability
   (`_dirWritable`, `updater_provider.dart:378`) only AFTER `downloadVersion`
   has already streamed the archive to `<dataDir>/updates/` and is about to call
   `applyUpdate`, which on Windows extracts into `<dataDir>/updates/staging-<ver>`
   (`updater.rs:346`). The staging and download dirs are under the data root; on
   a shared Windows box `%APPDATA%\Hollow\updates` is user-owned, so the classic
   "another local user swaps the staged files between verify and copy" needs a
   same-user attacker, which is out of P-10's reach. Lower risk than it looks,
   but the hash is checked on the downloaded archive, not re-checked on the
   extracted tree before `xcopy`, so anything that can write the staging dir
   between extract and the batch's `xcopy` lands in the app dir. Flagging for
   completeness; the real fix is to make the data-root perms the guarantee
   (covered by WP5 local-storage, TB-4).

2. `update.bat` interpolation. `apply_update` builds the Windows batch with
   `{staging_str}`, `{app_dir}`, `{zip_path_str}` and `{version}` interpolated
   straight into `xcopy`/`rd`/`del`/`start` lines (`updater.rs:388`-427) with no
   quoting beyond the literal `"`, and no rejection of a `"` or `&` in the path.
   `app_dir` is `Platform.resolvedExecutable`'s parent (trusted), `version`
   comes from the signed manifest (so an attacker needs the key), and
   `staging`/`zip` are under the data root. So this is not remotely reachable
   today, but it is the one place a manifest field (`version`) reaches a shell,
   and the Linux/macOS sides deliberately `sh_quote` every interpolated value
   (`updater.rs:548`) while Windows does not. A `version` like
   `9.9.9" & calc & "` would break out. The manifest key is the gate, so Low,
   but it is an asymmetry worth closing.

Why it matters: F-73's authority question is "Arguments built from manifest
fields?" - yes, `version` is, and only the Windows path is unquoted. Class 11
(state/lifecycle, attacker-chosen strings reaching a sink).

Fix idea: validate `version` against `^[0-9.]+$` before it reaches
`apply_update` (Dart already parses it numerically for comparison, so reuse
that), and re-hash the extracted tree or extract-then-verify. Confidence
CONFIRMED on the code shape, SUSPECTED on exploitability (I did not build a
hostile manifest+key to drive it, since that needs the signing key).

### C-DIST-07 (Info): no build provenance (SLSA Build L0 in practice)

The plan's standards row targets SLSA Build L1 today, L2 goal
(plan line 558). The release is built on three developer machines (Windows box,
Mac, Linux VM), signed with keys held on those machines, and uploaded by hand;
`.github/workflows/` builds and tests but produces no release artifact and no
provenance attestation. There is no SBOM, no hermetic/reproducible build, no
signed provenance linking an artifact to a source commit. This is Build L0/L1
at best (scripted but not provenanced). Not a vulnerability; recorded because
the brief asks for the SLSA status and because the updater makes the build
pipeline part of the trust base (plan 558). The mitigations that do exist:
pinned action SHAs, least-privilege `GITHUB_TOKEN`, `persist-credentials: false`,
and a release-only writable token in the ffmpeg workflow are all good L1 hygiene.

---

## Leads

No plan-section-7 leads (L-01..L-12) are assigned to this slice; they live in
WP1/2/3/8/9. The TUF attack list from the brief is answered under the protocol
checklist below.

---

## Protocol checklist: TUF attack classes applied to our updater, + SLSA

- **Arbitrary installation** (serve a package the client should not install):
  MET. The manifest is Ed25519 `verify_strict` against a baked-in key before
  Dart parses it (`updater.rs:73`, `135`), and every download is SHA-256-pinned
  to the signed manifest before it is kept (`updater.rs:243`). The host can
  serve bytes, not a signature. Residual: on Android the "signature" is the
  public debug key (C-DIST-03).
- **Rollback / downgrade** (class 9): MET on the client. `isNewerVersion`
  refuses anything not strictly newer (`version_compare.dart`,
  `hasUpdateProvider` at `updater_provider.dart:437`), so a replayed older
  signed manifest is not an update. The "Earlier versions" list
  (`updates_section.dart:216`) lets the USER install an older build on purpose,
  which is a deliberate choice, not an attacker lever. Tested
  (`version_compare_test.dart`: "a replayed older manifest is never an update").
- **Indefinite freeze** (serve an old valid manifest forever / stall): NOT MET.
  No expiry, no "latest seen" floor, failed checks swallowed. C-DIST-04.
- **Endless data / slow retrieval** (DoS the client with an infinite or
  trickled download): PARTIAL. `fetch_version_manifest` has a 10s client
  timeout (`updater.rs:64`); `download_update` has NO overall timeout and
  streams to disk with progress, but the user can cancel
  (`cancelDownload`) and nothing is installed until the hash matches, so a
  trickle wastes bandwidth only. `content_length` is attacker-controlled but
  used only for the progress ratio, never to allocate. Acceptable; a
  belt-and-braces max-size/stall-timeout would close it fully.
- **Extraneous dependencies / mix-and-match** (combine files from different
  releases): MET. One manifest entry names all per-platform URLs and hashes
  together, signed as one blob; the client only ever reads the entry whose
  `version == latest` (`_latestEntry`, `updates_section.dart:230`) and the hash
  for its own platform (`platformSha256`). No independent metadata files to mix.
- **Malicious mirror** (a rogue CDN edge): MET for integrity (sig+hash), and the
  code uses one hardcoded `kManifestUrl`; the known CDN edge weakness
  (`hcdn` challenge, memory) is availability, not integrity, and the
  cache-buster + sig-then-manifest upload order handle the stale-pair race.
- **Key compromise and rotation**: PARTIAL. `MANIFEST_SIGNING_PUBKEYS` is a list
  so a new key can be added for rotation (`updater.rs:18`), and the key is
  outside the repo (confirmed: `.gitignore:117` `*.key`,
  `release.local.env.example` documents the external path, `sign_manifest.ps1`
  reads it from the gitignored env and cross-checks against the pubkeys parsed
  out of `updater.rs` so key and constant cannot drift). But there is no
  revocation and no second independent gate (OS code signature), C-DIST-05.
  Flatpak side (C-34) is independent: GPG-signed OSTree, key embedded in every
  bundle and `.flatpakrepo` (`build-flatpak.sh:244`), an unsigned bundle refused
  over a repo-origin install; the private GPG key lives in `FLATPAK_GPG_HOMEDIR`
  outside the repo and only the public `flatpak/hollow-flatpak.gpg` is committed
  (confirmed it is a public-key packet).
- **SLSA Build L1/L2**: L0/L1. Scripted builds, pinned CI actions, least-priv
  tokens; no provenance, SBOM, or hermetic build. C-DIST-07.

## 13 bug classes, asked of this slice

1. **Authenticated but not authorised.** The manifest signer is also the
   authority over what it says (it names versions, URLs, hashes); there is no
   separate "who may say this version is latest" question beyond "holds the
   signing key". Fine for a single-publisher updater. Nothing found.
2. **Infrastructure controls membership/lists.** The distribution host is pure
   transport for integrity (sig+hash); it cannot forge a manifest. The one place
   infra decides content is the UNSIGNED feeds (C-DIST-01/02). Flatpak origin is
   GPG-pinned.
3. **Split view.** A host can serve client A a real manifest and client B a
   frozen one (C-DIST-04); nothing detects divergence. Noted under freeze; a
   transparency log is the heavy fix, out of scope.
4. **Withheld / rolled-back revocation.** Directly the freeze case
   (C-DIST-04) and the no-key-revocation case (C-DIST-05). Both recorded.
5. **Identifier / key-type confusion.** The manifest sig is a plain detached
   Ed25519 over the exact JSON bytes with no domain tag, and the flatpak uses a
   separate GPG key: no shared construction to confuse. The APK debug key is a
   different class (C-DIST-03). Nothing new found.
6. **Channel confusion.** The security-bearing manifest goes through the signed
   `fetch_version_manifest`; the display-only feeds go through
   `fetch_release_feed` (plain GET). They are deliberately split and a 2026-09
   regression (news reusing the signed path) was fixed. The risk is the reverse:
   display-only content reaching an ACTION channel (C-DIST-01). Recorded.
7. **Unknown key-share / misbinding.** N/A to a file updater (no group).
8. **Replay / reorder / deletion** (class 8): a replayed old manifest is the
   freeze/downgrade case. Downgrade blocked, freeze open (C-DIST-04).
9. **Downgrade / length checks** (class 9): downgrade blocked
   (`version_compare`). Length: `normalise_expected_sha256` requires exactly 64
   hex (`updater.rs:151`) so a truncated/empty hash is refused and
   `platformSha256.isEmpty` fails closed in Dart before the download
   (`updater_provider.dart:254`). The signature is `verify_strict` (rejects
   non-canonical/malleable), base64 and `Signature::from_slice` errors are
   caught and never panic (tested). No "absent means legacy accept" path. Good.
10. **Unauthenticated metadata.** The feeds in whole (C-DIST-01/02). Inside the
    manifest, `date`/`notes` are cosmetic and inside the signed blob. The flatpak
    metainfo version is stamped into the shipped copy, not security-bearing.
11. **State / key lifecycle.** The apply path crashing between steps: the Linux
    tarball swap has an explicit rollback (`tarball_update_script`, restores
    `.old` if the new binary dies in 8s, tested); Windows `xcopy` over the live
    dir has no rollback but kills the running exe first via the `tasklist` wait.
    Attacker-chosen strings reaching the batch shell: C-DIST-06. The staging dir
    is wiped and recreated each run (`updater.rs:348`), so a stale staging tree
    cannot be reused.
12. **Device linking / cloning.** N/A (that is WP1).
13. **What a stranger can trigger or observe.** A stranger who controls the host
    can: make a client fetch a remote image / open a URL (C-DIST-01/02); freeze
    it (C-DIST-04). A stranger with no infra access can do nothing to the signed
    channel. The updater check runs automatically every 2h and on each News
    fetch (`updater_provider.dart:193`, `news_provider.dart:48`), so the host
    sees each client's IP and poll cadence regardless (AS-05, already implied by
    the client talking to the host at all; not new).

## STRIDE grid

Processes get S,T,R,I,D,E; flows and stores get T,I,D; external interactors get
S,R. One line per cell.

### E-02 Rust core (`api/updater.rs`), the update engine

- S (spoof the source): requirement met - manifest sig + per-file hash bind the
  content to the key, not the host (`updater.rs:73,243`).
- T (tamper with the update in flight): met - https-only
  (`updater.rs:193`), hash-pinned, sig over exact bytes.
- R (repudiation): n/a - no multi-party action; a signed manifest is itself the
  non-repudiable record.
- I (info disclosure): the engine leaks nothing itself; the calling providers'
  auto-poll reveals IP/cadence to the host (AS-05, accepted by design).
- D (DoS): `download_update` has no overall timeout/size cap -> candidate-adjacent
  (endless-data, judged acceptable, see checklist). No unbounded allocation:
  streamed to disk, hashed incrementally. `content_length` not used to allocate.
- E (elevation): the generated scripts run as the user; the shell-metachar
  asymmetry on Windows is C-DIST-06.

### E-01 Flutter UI (updater/news/status providers + widgets)

- S: n/a (no principal to spoof in-process). The FEED content is attacker data,
  handled below.
- T: feed JSON is attacker-tamperable by design; parsing is defensive
  (every field defaulted, `StatusLevel.fromString` fails safe to operational,
  `status_provider.dart:44`). Met for crashes; see I/E for the link surface.
- R: n/a.
- I: C-DIST-02 (news markdown auto-fetches remote images).
- D: a malformed feed cannot crash the UI (jsonDecode wrapped, catch -> stay
  healthy/empty, `news_provider.dart:71`, `status_provider.dart:273`). Met.
- E: C-DIST-01 (feed link -> arbitrary URI / hollow:// action).

### X-6 Update host / CDN / flatpak repo (external interactor)

- S (spoof being the real publisher): met for the signed manifest and the GPG
  flatpak; NOT met for the Android APK (public debug key, C-DIST-03) and for the
  unsigned feeds (C-DIST-01/02).
- R: n/a (no action attributed to the host).

### X-7 Third-party web (reached via feed links/images)

- S/R: the feeds let the host designate X-7 targets (C-DIST-01/02). Covered.

### Flow F-70 (manifest + sig + archive hash + install)

- T: met (sig + hash). I: n/a (public release files). D: endless-data partial
  (checklist). Freeze is the un-handled class (C-DIST-04).

### Flow F-71 (news + status feeds)

- T: parsing is safe; the content itself is unauthenticated and reaches an
  action/fetch surface -> C-DIST-01, C-DIST-02. I: C-DIST-02. D: met (defensive).

### Flow F-72 (flatpak OSTree + GPG)

- T: met - GPG-signed commits+summary, key embedded in bundle, unsigned bundle
  refused over a repo-origin install (`build-flatpak.sh`, WP 23.4). I: n/a.
  D: availability only (the hcdn edge, memory), not integrity.

### Flow F-73 (Linux apply: update.sh, flatpak-spawn)

- T: met - hash verified before apply; every interpolated path is `sh_quote`d
  (`updater.rs:548`), the `sh -n` test proves the generated recipe is valid
  shell even with a quote in the instance id (`updater.rs:1548`). The tarball
  bundle shape is validated (bundle/hollow present and executable,
  `updater.rs:641`). flatpak scope read off the live deployment, not guessed.
- I: n/a. D: rollback on a dead new build (tested). E: the Windows sibling path
  is the un-quoted one (C-DIST-06); Linux/macOS are quoted.

## Requirements

- R-DIST-01: An attacker controlling the update host cannot make a client
  install an archive it did not sign. MET: `updater.rs:73` (sig),
  `updater.rs:243` (hash). Test: `manifest_signature_accepts_only_a_listed_key_over_exact_bytes`,
  `expected_checksum_must_be_64_hex` (Rust `integrity_tests`), `hollow_manifest::tests::sign_then_verify_roundtrip_and_tamper`.
- R-DIST-02: An attacker serving an older, still-validly-signed manifest cannot
  downgrade a client. MET: `version_compare.dart`. Test:
  `version_compare_test.dart` "a replayed older manifest is never an update".
- R-DIST-03: An attacker serving the current/old manifest forever, or stalling
  it, cannot indefinitely hide a newer (security) release with no signal. NOT
  MET (C-DIST-04). No test.
- R-DIST-04: The unsigned status/news feeds cannot cause the client to perform
  an in-app action or open a non-web URI. NOT MET (C-DIST-01). No test.
- R-DIST-05: Rendering a news post makes no network request to a host the feed
  chose. NOT MET (C-DIST-02). No test.
- R-DIST-06: An attacker cannot build an Android package that the OS accepts as
  an update to an installed Hollow. NOT MET on sideloaded installs (C-DIST-03,
  public debug key). No test / release-time cert check.
- R-DIST-07: The manifest signing private key never appears in the repository.
  MET: `.gitignore:117` `*.key`, external path in `release.local.env`,
  `sign_manifest.ps1` reads it from the gitignored env. (History scan is another
  agent's job per the brief.) Guard: `the_baked_in_keys_are_well_formed` only
  checks the PUBLIC key shape; no test asserts the private key is absent.
- R-DIST-08: The flatpak client accepts only bundles signed by Hollow's GPG key.
  MET by construction (`build-flatpak.sh` + OSTree gpg-verify; WP 23.4). Test:
  none in-repo (verified on the VM per memory, not in CI).
- R-DIST-09: A value from the signed manifest reaching a generated install
  script cannot inject a shell command. MET on Linux/macOS (`sh_quote`), NOT on
  the Windows `update.bat` `version` field (C-DIST-06, gated by needing the
  signing key). Test: `flatpak_relaunch_script_waits_on_instance_id` proves sh
  quoting; nothing covers the bat.
- R-DIST-10: A hostile zip entry cannot write outside the staging dir. MET:
  `extract_zip_to` rejects `..` and the zip crate sanitizes
  (`updater.rs:1048`). Test: `rejects_path_traversal_entries`,
  `extracts_compress_archive_style_backslash_entries`.
- R-DIST-11: A malformed/hostile feed cannot crash the app or produce a scary
  banner. MET: defensive parsing, fail-safe to operational
  (`status_provider.dart:44`, `news_provider.dart:71`). Test:
  `relay_status_test.dart` parse cases (status feed), none for `news.json`
  specifically.
- R-DIST-12: CI workflows do not expose repository write or secrets to
  untrusted PR input. MET: `permissions: contents: read` default, actions pinned
  by SHA, `persist-credentials: false`, the sonar job gated off forks/dependabot
  (`ci.yml:227`), the only `contents: write` job (ffmpeg release) is `main`-only
  and runs no checked-out third-party code (`build-ffmpeg.yml:173`). No
  `pull_request_target`. Guard: `.github/dependabot.yml` keeps the pins fresh.
  Nothing found.

## Notes for the lead

- C-DIST-01 and C-DIST-02 are the clearest actionable client-side bugs and both
  have cheap fixes (scheme allowlist; a no-remote-image `imageBuilder`). They
  turn the "display-only" feed promise into something true.
- C-DIST-03 (debug-signed APK) is documented as a known migration, not an
  oversight; it needs either an `accepted_risks.md` row with C-33's Android
  caveat written down, or the release-keystore migration. Right now C-33 reads
  as unconditionally true and is not.
- C-DIST-04 (freeze) is the one TUF class genuinely unhandled; a signed
  `expires` + a persisted "latest seen" floor is the standard answer.
- The core sig+hash+no-downgrade chain is solid and well tested; I verified the
  committed historical manifests verify under the current baked key (so they are
  usable freeze payloads but not forgeries), and that the client has no OS
  code-signature check anywhere.

Could not check (no build/run per the brief): I did not drive the Dart UI to
confirm the `hollow://` feed-link reaches `DeepLinkService` at runtime (traced
statically: `launchMode: externalApplication` + the registered protocol
handler), nor did I mint a hostile signing key to drive the Windows `update.bat`
injection. Both are CONFIRMED on code shape, SUSPECTED on live exploit. The
flatpak GPG-verify enforcement and the Android cert are confirmed from code and
memory, not re-run here.
