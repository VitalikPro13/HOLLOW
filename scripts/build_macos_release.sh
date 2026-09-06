#!/bin/bash
# Hollow — macOS release build. RUN IN A GUI TERMINAL ON THE MAC.
#
#   bash scripts/build_macos_release.sh [VERSION]
#
# Does the whole macOS release end to end:
#   1. flutter build macos --release
#   2. re-sign inside-out (timestamp + hardened runtime) — fixes notarization
#   3. build + sign the DMG (create-dmg)
#   4. notarize + staple the DMG
#   5. staple the .app + build the auto-updater zip
#
# Produces, under $MAC_REPO/build/macos/Build/Products/Release:
#   hollow-<ver>.dmg          (new users, drag-install)
#   hollow-<ver>-macos.zip    (auto-updater)
#
# The Windows orchestrator (build_release.ps1) scp-pulls both into
# installer/Output/. This script does NOT scp anything itself.
#
# MUST run in a GUI Terminal: codesign + notarytool need the unlocked login
# keychain; over SSH they fail with errSecInternalComponent.
#
# No secrets in here: the signing key is in the keychain, the notary password is
# in a keychain profile, and a Team ID is public. Reads scripts/release.local.env.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load machine config -------------------------------------------------
ENV_FILE="$SCRIPT_DIR/release.local.env"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy release.local.env.example)"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${MAC_TEAM_ID:?MAC_TEAM_ID missing in release.local.env}"
: "${MAC_SIGN_NAME:?MAC_SIGN_NAME missing in release.local.env}"
: "${MAC_NOTARY_PROFILE:?MAC_NOTARY_PROFILE missing in release.local.env}"

ID="Developer ID Application: ${MAC_SIGN_NAME} (${MAC_TEAM_ID})"

# --- Resolve version ----------------------------------------------------
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(grep '^version:' "$ROOT_DIR/pubspec.yaml" | head -1 | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
fi
[ -n "$VERSION" ] || { echo "ERROR: could not resolve version; pass it explicitly"; exit 1; }

REL="$ROOT_DIR/build/macos/Build/Products/Release"
APP="$REL/Hollow.app"
ENT="$ROOT_DIR/macos/Runner/Release.entitlements"

echo "==> Hollow macOS release — version $VERSION"
echo "    identity: $ID"

cd "$ROOT_DIR"

# --- 0a. Local signing config -------------------------------------------
# The Xcode project resolves its identity and team from the gitignored
# macos/Flutter/LocalSigning.xcconfig; the committed defaults are ad-hoc and
# no team, so any clone builds and runs. A release needs both set, and this
# file already knows them, so the config is written here rather than
# remembered: a publishing Mac that never had the file (or has an older one
# with only the team) signs with the Developer ID on its next run, and the
# Xcode Archive flow finds its team as well.
LOCAL_SIGNING="$ROOT_DIR/macos/Flutter/LocalSigning.xcconfig"
if ! grep -qs "^HOLLOW_DEVELOPMENT_TEAM = ${MAC_TEAM_ID}\$" "$LOCAL_SIGNING" \
   || ! grep -qs "^HOLLOW_CODE_SIGN_IDENTITY = Developer ID Application\$" "$LOCAL_SIGNING"; then
  echo "==> 0a. writing ${LOCAL_SIGNING#$ROOT_DIR/} (team ${MAC_TEAM_ID}, Developer ID Application)"
  {
    echo '// Written by scripts/build_macos_release.sh from release.local.env. Gitignored.'
    echo '// Delete it to build ad-hoc again (any clone does, without this file).'
    echo "HOLLOW_DEVELOPMENT_TEAM = ${MAC_TEAM_ID}"
    echo 'HOLLOW_CODE_SIGN_IDENTITY = Developer ID Application'
  } > "$LOCAL_SIGNING"
else
  echo "==> 0a. ${LOCAL_SIGNING#$ROOT_DIR/} already names team ${MAC_TEAM_ID} + Developer ID Application"
fi

# --- 0b. Screen-share audio helper ---------------------------------------
# The Xcode "Bundle screen audio capturer" phase only COPIES the binary that
# scripts/build_screen_audio.sh produces; it never builds it, and when the
# binary is missing the phase prints a warning and the release ships without
# screen-share audio. Build it first, the way the Linux script does.
echo "==> 0b. screen_audio_capturer"
bash "$ROOT_DIR/scripts/build_screen_audio.sh"

# --- 0. Build -----------------------------------------------------------
echo "==> 0. flutter build macos --release"
flutter build macos --release

[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }
[ -f "$ENT" ] || { echo "ERROR: entitlements not found at $ENT"; exit 1; }
[ -f "$APP/Contents/Resources/screen_audio_capturer" ] || { echo "ERROR: screen_audio_capturer missing from the bundle (the release would ship without screen-share audio)"; exit 1; }
cd "$REL"

# --- 1. Sign nested dylibs / framework executables (inside-out) ----------
echo "==> 1. Sign nested dylibs / framework binaries (timestamp + runtime)"
find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) | while read -r f; do
  [ -L "$f" ] && continue
  if file "$f" | grep -q "Mach-O"; then
    echo "    signing: ${f#$APP/}"
    codesign --force --timestamp --options runtime --sign "$ID" "$f"
  fi
done

# --- 2. Sign each .framework bundle -------------------------------------
echo "==> 2. Sign .framework bundles"
find "$APP/Contents/Frameworks" -type d -name "*.framework" | while read -r fw; do
  echo "    signing framework: ${fw#$APP/}"
  codesign --force --timestamp --options runtime --sign "$ID" "$fw"
done

# --- 3. Sign nested app/xpc bundles -------------------------------------
echo "==> 3. Sign nested app / xpc bundles (if present)"
find "$APP/Contents" -type d \( -name "*.app" -o -name "*.xpc" \) ! -path "$APP" | while read -r h; do
  echo "    signing nested bundle: ${h#$APP/}"
  codesign --force --timestamp --options runtime --sign "$ID" "$h"
done

# --- 3b. Sign bare Mach-O helpers under Resources (screen_audio_capturer) -
# The Xcode "Bundle screen audio capturer" phase drops this helper into
# Contents/Resources/ ad-hoc signed; the Frameworks loops never reach it, so
# notarization rejects it. (This was missing and broke v0.7.1 notarization.)
echo "==> 3b. Sign bare Mach-O helpers under Resources/"
find "$APP/Contents/Resources" -type f -perm +111 | while read -r r; do
  [ -L "$r" ] && continue
  if file "$r" | grep -q "Mach-O"; then
    echo "    signing helper: ${r#$APP/}"
    codesign --force --timestamp --options runtime --sign "$ID" "$r"
  fi
done

# --- 4. Sign the app bundle LAST (with entitlements) --------------------
echo "==> 4. Sign the app bundle (with entitlements)"
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$ID" "$APP"

echo "==> 5. Verify (must satisfy Developer ID + timestamp)"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -iE "Authority|Timestamp|Runtime|TeamIdentifier" | head -8

# --- 6. Build + sign the DMG --------------------------------------------
echo "==> 6. Build the DMG (create-dmg)"
rm -f "Hollow $VERSION.dmg"
create-dmg --overwrite --identity="$ID" Hollow.app . || echo "(create-dmg exit non-zero — check if only its DMG-sign step failed)"
if [ -f "Hollow $VERSION.dmg" ]; then
  codesign --force --timestamp --sign "$ID" "Hollow $VERSION.dmg"
fi

# --- 7. Notarize + staple the DMG (keychain) ----------------------------
echo "==> 7. Notarize the DMG (notarytool, profile $MAC_NOTARY_PROFILE)"
xcrun notarytool submit "Hollow $VERSION.dmg" --keychain-profile "$MAC_NOTARY_PROFILE" --wait
xcrun stapler staple "Hollow $VERSION.dmg"
xcrun stapler validate "Hollow $VERSION.dmg"

# --- 8. Staple the .app + build the auto-updater zip --------------------
echo "==> 8. Staple the app + build the updater zip"
xcrun stapler staple "$APP"   # notarytool does NOT staple the loose .app
rm -f "hollow-$VERSION-macos.zip"
ditto -c -k --keepParent Hollow.app "hollow-$VERSION-macos.zip"   # NEVER plain `zip`

# --- 9. Normalize the DMG name to the release convention ----------------
mv -f "Hollow $VERSION.dmg" "hollow-$VERSION.dmg"

echo ""
echo "==== DONE — macOS $VERSION ===="
echo "  DMG: $REL/hollow-$VERSION.dmg"
echo "  Zip: $REL/hollow-$VERSION-macos.zip"
echo "  (Pull both with the Windows orchestrator: build_release.ps1)"
