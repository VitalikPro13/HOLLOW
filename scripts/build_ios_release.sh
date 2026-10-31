#!/bin/bash
# Hollow — iOS release build for .github/workflows/release-apple.yml.
#
#   bash scripts/build_ios_release.sh archive             VERSION BUILD
#   bash scripts/build_ios_release.sh export [--unsigned] VERSION BUILD
#   bash scripts/build_ios_release.sh upload              VERSION BUILD
#
# archive  the App Store archive with code signing OFF (no team, no key, no
#          account): pub packages, CocoaPods, cargo and Xcode's script phases run
#          here and never next to a secret. Output build/ios_release/Runner.xcarchive.
# export   signs that archive's app inside-out with the Apple Distribution identity
#          and the App Store profiles, swaps in the production Firebase config and
#          writes build/ios_release/Runner.ipa. Only Apple's tools and this repo's
#          scripts run. --unsigned (the CI dry run) signs ad-hoc with the same
#          entitlements and no profiles, which proves everything but the identity.
# upload   sends the .ipa to App Store Connect (TestFlight) with altool.
#
# export reads MAC_TEAM_ID, IOS_SIGN_KEYCHAIN (holding exactly one "Apple
# Distribution: ... (TEAM)" identity), IOS_PROFILE_DIR (app.mobileprovision,
# NotificationService.mobileprovision, BroadcastExtension.mobileprovision) and
# FIREBASE_PLIST. upload reads ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_APP_APPLE_ID. App Store submission stays a manual step.
#
# Device builds and archives never run on the Mac mini (memory
# feedback_no_ios_build_command): this script is for the CI runner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-}"; shift || true
SIGNED=1
if [ "${1:-}" = --unsigned ]; then SIGNED=0; shift; fi
VERSION="${1:-}"; BUILD="${2:-}"
case "$MODE" in archive|export|upload) ;; *) echo "usage: $0 archive|export [--unsigned]|upload VERSION BUILD" >&2; exit 2 ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version '$VERSION' is not X.Y.Z" >&2; exit 1; }
[[ "$BUILD" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: build number '$BUILD' is not a positive integer" >&2; exit 1; }

cd "$ROOT_DIR"
OUT="$ROOT_DIR/build/ios_release"
ARCHIVE="$OUT/Runner.xcarchive"
IPA="$OUT/Runner.ipa"
XCCONFIG="$ROOT_DIR/ios/Flutter/Variant-prod.xcconfig"
BUNDLE_ID="$(sed -nE 's/^HOLLOW_BUNDLE_ID = (.+)$/\1/p' "$XCCONFIG")"
# Every target that ships, with the entitlements it is signed with. Runner's
# "Embed Foundation Extensions" phase puts both extensions in PlugIns.
EXTENSIONS=(NotificationService BroadcastExtension)
FIREBASE_PLACEHOLDER_PROJECT=ci-placeholder

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=scripts/apple_macho.sh
. "$SCRIPT_DIR/apple_macho.sh"

plist() { plutil -extract "$2" raw -o - "$1"; }

# The export writes into the copied app; a symlink leading out of it would carry
# those writes (the profiles, the Firebase config) anywhere on the runner.
refuse_outside_links() {
  local root real l t
  root="$1"; real="$(cd "$root" && pwd -P)"
  find "$root" -type l -print0 > "$WORK/links"
  while IFS= read -r -d '' l; do
    t="$(/bin/realpath -- "$l" 2>/dev/null)" || { echo "ERROR: ${l#"$root"/} is a dangling symlink" >&2; exit 1; }
    case "$t" in "$real"/*) ;; *) echo "ERROR: ${l#"$root"/} points outside the app" >&2; exit 1 ;; esac
  done < "$WORK/links"
}

# The app and both extensions carry this version and build and the expected ids,
# and nothing else is embedded as a bundle.
check_app() {
  local app="$1" appex name found
  [ "$(plist "$app/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "ERROR: app bundle id is not $BUNDLE_ID" >&2; exit 1; }
  found="$(cd "$app" && find . -mindepth 1 \( -name '*.appex' -o -name '*.app' \) | sort | tr '\n' ' ')"
  [ "$found" = "./PlugIns/BroadcastExtension.appex ./PlugIns/NotificationService.appex " ] \
    || { echo "ERROR: the app embeds other bundles than the two extensions: $found" >&2; exit 1; }
  for name in "${EXTENSIONS[@]}"; do
    appex="$app/PlugIns/$name.appex"
    [ "$(plist "$appex/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID.$name" ] || { echo "ERROR: $name.appex is not $BUNDLE_ID.$name" >&2; exit 1; }
  done
  for bundle in "$app" "$app/PlugIns/NotificationService.appex" "$app/PlugIns/BroadcastExtension.appex"; do
    local short build
    short="$(plist "$bundle/Info.plist" CFBundleShortVersionString)"
    build="$(plist "$bundle/Info.plist" CFBundleVersion)"
    [ "$short" = "$VERSION" ] && [ "$build" = "$BUILD" ] \
      || { echo "ERROR: $(basename "$bundle") is $short ($build), expected $VERSION ($BUILD)" >&2; exit 1; }
  done
  if find "$app" -name 'libswift*.dylib' | grep -q .; then
    echo "ERROR: the app embeds Swift runtime libraries; the export would need a SwiftSupport folder" >&2; exit 1
  fi
}

# --- archive -----------------------------------------------------------------
if [ "$MODE" = archive ]; then
  FIREBASE="ios/GoogleService-Info.plist"
  [ -f "$FIREBASE" ] || { echo "ERROR: $FIREBASE missing (CI writes the placeholder)" >&2; exit 1; }
  [ "$(plist "$FIREBASE" PROJECT_ID)" = "$FIREBASE_PLACEHOLDER_PROJECT" ] \
    || { echo "ERROR: the archive is built with the placeholder Firebase config; export swaps the real one in" >&2; exit 1; }
  rm -rf "$OUT"
  mkdir -p "$OUT"
  flutter pub get --enforce-lockfile
  # Writes Generated.xcconfig (version + build) and runs pod install; the archive
  # below runs the Flutter and cargokit build phases itself.
  flutter build ios --config-only --release --no-codesign --build-name "$VERSION" --build-number "$BUILD"
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
    archive
  check_app "$ARCHIVE/Products/Applications/Runner.app"
  # Made here, so the keyed export job only copies files and never runs a parser
  # over the dSYMs.
  if compgen -G "$ARCHIVE/dSYMs/*.dSYM" >/dev/null; then
    echo "==> crash symbols"
    mkdir "$ARCHIVE/Symbols"
    xcrun symbols -noTextInSOD -noDaemon -arch all -symbolsPackageDir "$ARCHIVE/Symbols" "$ARCHIVE"/dSYMs/*.dSYM >/dev/null
  fi
  echo "==== DONE, iOS $VERSION ($BUILD) archived UNSIGNED: $ARCHIVE ===="
  exit 0
fi

# --- export ------------------------------------------------------------------
if [ "$MODE" = export ]; then
  [ -d "$ARCHIVE/Products/Applications/Runner.app" ] || { echo "ERROR: no archive at $ARCHIVE" >&2; exit 1; }
  if [ "$SIGNED" = 1 ]; then
    : "${MAC_TEAM_ID:?MAC_TEAM_ID missing}"
    : "${IOS_SIGN_KEYCHAIN:?IOS_SIGN_KEYCHAIN missing}"
    : "${IOS_PROFILE_DIR:?IOS_PROFILE_DIR missing}"
    : "${FIREBASE_PLIST:?FIREBASE_PLIST missing}"
    TEAM="$MAC_TEAM_ID"
    ids="$(security find-identity -v -p codesigning "$IOS_SIGN_KEYCHAIN" | grep -E "\"Apple Distribution: .+ \\($TEAM\\)\"" || true)"
    [ "$(grep -c . <<<"$ids")" = 1 ] || { echo "ERROR: need exactly one \"Apple Distribution: ... ($TEAM)\" identity in the keychain" >&2; exit 1; }
    IDENT="$(awk '{print $2}' <<<"$ids")"
    [[ "$IDENT" =~ ^[0-9A-F]{40}$ ]] || { echo "ERROR: could not read the identity's SHA-1" >&2; exit 1; }
    echo "    identity: $(grep -oE '"[^"]+"' <<<"$ids") ($IDENT)"
    CODESIGN=(codesign --keychain "$IOS_SIGN_KEYCHAIN")
  else
    # The dry run resolves the same entitlements under a made-up team.
    TEAM="${MAC_TEAM_ID:-DRYRUN0000}"
    IDENT=-
    CODESIGN=(codesign)
  fi
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: MAC_TEAM_ID is not a 10-character Team ID" >&2; exit 1; }
  sign() { "${CODESIGN[@]}" --force --sign "$IDENT" --timestamp=none --generate-entitlement-der "$@"; }

  # Every Mach-O under ROOT satisfies the release requirement (Apple-anchored
  # chain, an Apple Distribution leaf of this team; the prefix wildcard sits
  # outside the quotes or it matches literally); the dry run, a valid ad-hoc
  # signature of ours, not the linker's. No pipeline: a reader killed by SIGPIPE
  # must not skip a file.
  verify_macho_signatures() {
    local root="$1" f info count=0
    local req="=anchor apple generic and certificate leaf[subject.CN] = \"Apple Distribution: \"* and certificate leaf[subject.OU] = \"$TEAM\""
    find "$root" -type f -print0 > "$WORK/files"
    while IFS= read -r -d '' f; do
      is_macho "$f" || continue
      count=$((count + 1))
      if [ "$SIGNED" = 1 ]; then
        codesign --verify --strict -R "$req" "$f" || { echo "ERROR: ${f#"$root"/} is not signed by the release identity" >&2; exit 1; }
      else
        codesign --verify --strict "$f" || { echo "ERROR: ${f#"$root"/} has no valid signature" >&2; exit 1; }
        info="$(codesign -dv "$f" 2>&1)"
        if ! grep -qx "Signature=adhoc" <<<"$info" || grep -q "linker-signed" <<<"$info"; then
          echo "ERROR: ${f#"$root"/} is not ad-hoc signed by this export" >&2; exit 1
        fi
      fi
    done < "$WORK/files"
    # The app and its two extensions at least.
    [ "$count" -ge 3 ] || { echo "ERROR: only $count Mach-O files found in the app" >&2; exit 1; }
    echo "    $count Mach-O files"
  }

  # The archive job's symbols folder holds only <UUID>.symbols files; nothing in
  # this job reads them.
  copy_symbols() {
    local from="$1" to="$2" f
    [ -d "$from" ] && [ ! -L "$from" ] || { echo "ERROR: the archive's Symbols is not a directory" >&2; exit 1; }
    find "$from" -mindepth 1 -print0 > "$WORK/symbols"
    while IFS= read -r -d '' f; do
      [[ "${f#"$from"/}" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.symbols$ ]] && [ -f "$f" ] && [ ! -L "$f" ] \
        || { echo "ERROR: the archive's Symbols holds an unexpected entry: ${f#"$from"/}" >&2; exit 1; }
    done < "$WORK/symbols"
    ditto "$from" "$to"
  }

  rm -f "$IPA"
  mkdir -p "$WORK/ipa/Payload"
  APP="$WORK/ipa/Payload/Runner.app"
  ditto "$ARCHIVE/Products/Applications/Runner.app" "$APP"
  refuse_outside_links "$APP"
  check_app "$APP"
  find "$APP" -name embedded.mobileprovision \( -type f -o -type l \) -delete

  if [ "$SIGNED" = 1 ]; then
    [ "$(plist "$APP/GoogleService-Info.plist" PROJECT_ID)" = "$FIREBASE_PLACEHOLDER_PROJECT" ] \
      || { echo "ERROR: the archived app does not hold the placeholder Firebase config" >&2; exit 1; }
    [ "$(plist "$FIREBASE_PLIST" BUNDLE_ID)" = "$BUNDLE_ID" ] || { echo "ERROR: FIREBASE_PLIST belongs to another app" >&2; exit 1; }
    rm -f "$APP/GoogleService-Info.plist"
    cp -X "$FIREBASE_PLIST" "$APP/GoogleService-Info.plist"
    chmod 644 "$APP/GoogleService-Info.plist"
  fi

  # entitlements_for TARGET_DIR BUNDLE PROFILE OUT: the target's committed
  # entitlements, resolved, and (signed) checked against its decoded profile.
  entitlements_for() {
    local src="$ROOT_DIR/ios/$1/$1.entitlements" bundle="$2" profile="$3" out="$4"
    if [ "$SIGNED" = 1 ]; then
      security cms -D -i "$profile" > "$WORK/profile.plist"
      /usr/bin/python3 -I "$SCRIPT_DIR/ios_entitlements.py" "$src" "$XCCONFIG" "$TEAM" "$bundle" "$out" "$WORK/profile.plist" "$IDENT"
    else
      /usr/bin/python3 -I "$SCRIPT_DIR/ios_entitlements.py" "$src" "$XCCONFIG" "$TEAM" "$bundle" "$out"
    fi
  }

  echo "==> sign nested code, deepest first"
  find "$APP" -name '*.dylib' -type f -print0 | while IFS= read -r -d '' f; do
    echo "    ${f#"$APP"/}"; sign "$f"
  done
  find "$APP" -name '*.framework' -type d | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2- | while IFS= read -r fw; do
    echo "    ${fw#"$APP"/}"; sign "$fw"
  done

  echo "==> sign the extensions and the app"
  for name in "${EXTENSIONS[@]}" Runner; do
    if [ "$name" = Runner ]; then target="$APP"; bundle="$BUNDLE_ID"; profile_name=app
    else target="$APP/PlugIns/$name.appex"; bundle="$BUNDLE_ID.$name"; profile_name="$name"; fi
    profile="${IOS_PROFILE_DIR:-}/$profile_name.mobileprovision"
    entitlements_for "$name" "$bundle" "$profile" "$WORK/$name.entitlements"
    if [ "$SIGNED" = 1 ]; then
      rm -f "$target/embedded.mobileprovision"
      cp -X "$profile" "$target/embedded.mobileprovision"
    fi
    echo "    ${target#"$WORK/ipa/"} ($bundle)"
    sign --entitlements "$WORK/$name.entitlements" "$target"
    codesign -d --entitlements - --xml "$target" 2>/dev/null > "$WORK/$name.signed.plist"
    /usr/bin/python3 -I -c 'import plistlib,sys; a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.load(open(sys.argv[2],"rb")); sys.exit(0 if a==b else "ERROR: %s was signed with other entitlements" % sys.argv[3])' \
      "$WORK/$name.entitlements" "$WORK/$name.signed.plist" "$name"
  done

  echo "==> verify every Mach-O is signed by the release identity"
  codesign --verify --deep --strict --verbose=2 "$APP"
  verify_macho_signatures "$APP"

  if [ -e "$ARCHIVE/Symbols" ] || [ -L "$ARCHIVE/Symbols" ]; then
    echo "==> crash symbols (made by the archive job)"
    copy_symbols "$ARCHIVE/Symbols" "$WORK/ipa/Symbols"
  fi
  ditto -c -k --norsrc "$WORK/ipa" "$IPA"
  ditto -x -k "$IPA" "$WORK/check"
  codesign --verify --deep --strict "$WORK/check/Payload/Runner.app"
  shasum -a 256 "$IPA"
  echo "==== DONE, iOS $VERSION ($BUILD) $([ "$SIGNED" = 1 ] && echo signed || echo "ad-hoc (dry run)"): $IPA ===="
  exit 0
fi

# --- upload ------------------------------------------------------------------
: "${ASC_KEY_PATH:?ASC_KEY_PATH missing}"
: "${ASC_KEY_ID:?ASC_KEY_ID missing}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID missing}"
: "${ASC_APP_APPLE_ID:?ASC_APP_APPLE_ID missing}"
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: ASC_KEY_ID is not a key id" >&2; exit 1; }
[[ "$ASC_APP_APPLE_ID" =~ ^[0-9]+$ ]] || { echo "ERROR: ASC_APP_APPLE_ID is not the app's numeric Apple ID" >&2; exit 1; }
[ -f "$IPA" ] || { echo "ERROR: no $IPA (run export first)" >&2; exit 1; }
# altool finds the key as ./private_keys/AuthKey_<id>.p8 under its working directory.
mkdir -m 700 "$WORK/asc" "$WORK/asc/private_keys"
cp "$ASC_KEY_PATH" "$WORK/asc/private_keys/AuthKey_$ASC_KEY_ID.p8"
chmod 600 "$WORK/asc/private_keys/AuthKey_$ASC_KEY_ID.p8"
unset API_PRIVATE_KEYS_DIR
(cd "$WORK/asc" && xcrun altool --upload-package "$IPA" -t ios \
  --apple-id "$ASC_APP_APPLE_ID" --bundle-id "$BUNDLE_ID" \
  --bundle-version "$BUILD" --bundle-short-version-string "$VERSION" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
echo "==== DONE, iOS $VERSION ($BUILD) uploaded to App Store Connect; it shows in TestFlight after processing ===="
