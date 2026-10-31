#!/bin/bash
# Hollow — macOS release build.
#
#   bash scripts/build_macos_release.sh [--unsigned] [--stage STAGE] [VERSION]
#
# Does the whole macOS release end to end, as stages (default: all, in order):
#   build       screen_audio_capturer, the webcrypto patch, flutter build macos --release
#   sign        re-sign Hollow.app inside-out (timestamp + hardened runtime), notarize
#               it and staple it
#   package     the DMG from a staged folder (the app, an /Applications link and the
#               committed layout in scripts/macos_dmg), checked against that folder;
#               sign + notarize + staple the DMG; the auto-updater zip; the release checks
#   verify-dmg  only the DMG check, against an existing hollow-<ver>.dmg
# --unsigned skips every Developer ID and notary step: a local test build, or the CI
# dry run. .github/workflows/release-apple.yml runs build in a job with no secrets
# and sign + package in a job that runs nothing but Apple's tools and this script.
#
# Produces, under build/macos/Build/Products/Release:
#   hollow-<ver>.dmg          (new users, drag-install)
#   hollow-<ver>-macos.zip    (auto-updater)
#
# Signing config comes from the environment, else scripts/release.local.env:
#   MAC_TEAM_ID, MAC_SIGN_NAME   the "Developer ID Application" identity
#   MAC_SIGN_KEYCHAIN            optional: the keychain that holds it (CI's temporary one)
#   notarization, either         MAC_NOTARY_PROFILE (a notarytool keychain profile)
#                         or     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID
#                                (an App Store Connect API key, .p8)
# With the login keychain (identity or notary profile) run it in a GUI Terminal:
# over SSH codesign and notarytool fail with errSecInternalComponent.
#
# No secrets in here: a Team ID is public, the key lives in a keychain and the
# notary credential in a keychain profile or a file the caller deletes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STAGE=all
SIGNED=1
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) SIGNED=0 ;;
    --stage) STAGE="${2:-}"; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) VERSION="$1" ;;
  esac
  shift
done
case "$STAGE" in all|build|sign|package|verify-dmg) ;; *) echo "ERROR: unknown stage '$STAGE'" >&2; exit 2 ;; esac
runs() { [ "$STAGE" = all ] || [ "$STAGE" = "$1" ]; }

# --- Config ---------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/release.local.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [ -z "$VERSION" ]; then
  VERSION="$(grep '^version:' "$ROOT_DIR/pubspec.yaml" | head -1 | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version '$VERSION' is not X.Y.Z" >&2; exit 1; }

REL="$ROOT_DIR/build/macos/Build/Products/Release"
APP="$REL/Hollow.app"
ENT="$ROOT_DIR/macos/Runner/Release.entitlements"
DMG="$REL/hollow-$VERSION.dmg"
ZIP="$REL/hollow-$VERSION-macos.zip"
LAYOUT="$SCRIPT_DIR/macos_dmg/layout"
LAYOUT_SUMS="$SCRIPT_DIR/macos_dmg/layout.sha256"
# The committed .DS_Store finds its background through an alias that names this
# volume (scripts/macos_dmg/make_layout.py), so it never carries the version.
VOLNAME=Hollow
# A volume root with a custom icon: kHasCustomIcon in its Finder info.
FINDER_INFO_CUSTOM_ICON=0000000000000000040000000000000000000000000000000000000000000000
MTREE_KEYS=type,link,mode,sha256digest,flags,xattrsdigest

# shellcheck source=scripts/apple_macho.sh
. "$SCRIPT_DIR/apple_macho.sh"

ID=""
REQ=""
CODESIGN=(codesign)
NOTARY_AUTH=()
if [ "$SIGNED" = 1 ] && [ "$STAGE" != build ]; then
  : "${MAC_TEAM_ID:?MAC_TEAM_ID missing (environment or release.local.env)}"
  : "${MAC_SIGN_NAME:?MAC_SIGN_NAME missing (environment or release.local.env)}"
  [[ "$MAC_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: MAC_TEAM_ID is not a 10-character Team ID" >&2; exit 1; }
  [[ "$MAC_SIGN_NAME" =~ ^[^\"\\]+$ ]] || { echo "ERROR: MAC_SIGN_NAME is empty or holds a quote or backslash" >&2; exit 1; }
  ID="Developer ID Application: ${MAC_SIGN_NAME} (${MAC_TEAM_ID})"
  # Developer ID's own designated requirement, pinned to this certificate name:
  # an Apple-anchored chain through the Developer ID CA to a Developer ID
  # Application leaf of this team.
  REQ="=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.CN] = \"$ID\" and certificate leaf[subject.OU] = \"$MAC_TEAM_ID\""
  if [ -n "${MAC_SIGN_KEYCHAIN:-}" ]; then CODESIGN+=(--keychain "$MAC_SIGN_KEYCHAIN"); fi
fi
if [ "$SIGNED" = 1 ] && { runs sign || runs package; }; then
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID missing}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID missing}"
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  elif [ -n "${MAC_NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$MAC_NOTARY_PROFILE")
  else
    echo "ERROR: no notary credential: set MAC_NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID" >&2
    exit 1
  fi
fi

echo "==> Hollow macOS release, version $VERSION, stage $STAGE"
if [ "$SIGNED" = 1 ]; then echo "    identity: ${ID:-(not needed by this stage)}"; else echo "    UNSIGNED (no Developer ID, no notarization)"; fi
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
MNT="$WORK/mnt"
cleanup() {
  if [ -d "$MNT" ]; then hdiutil detach -quiet "$MNT" >/dev/null 2>&1 || hdiutil detach -force -quiet "$MNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

sign() { "${CODESIGN[@]}" --force --timestamp --sign "$ID" "$@"; }

# Every Mach-O under ROOT meets REQ, with a secure timestamp and the hardened
# runtime. No pipeline: a reader killed by SIGPIPE must not skip a file.
verify_macho_signatures() {
  local root="$1" f info count=0
  find "$root" -type f -print0 > "$WORK/files"
  while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    count=$((count + 1))
    codesign --verify --strict -R "$REQ" "$f" || { echo "ERROR: ${f#"$root"/} is not signed by $ID" >&2; exit 1; }
    info="$(codesign -dv "$f" 2>&1)"
    grep -q "^Timestamp=" <<<"$info" || { echo "ERROR: ${f#"$root"/} has no secure timestamp" >&2; exit 1; }
    grep -qE "^CodeDirectory .* flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)" <<<"$info" || { echo "ERROR: ${f#"$root"/} lacks the hardened runtime" >&2; exit 1; }
  done < "$WORK/files"
  # The app, the screen audio helper and the Flutter engine at least.
  [ "$count" -ge 3 ] || { echo "ERROR: only $count Mach-O files found in the app" >&2; exit 1; }
  echo "    $count Mach-O files signed by $ID"
}

notarize() {
  local file="$1" out="$WORK/notary.json" status sub_id
  xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json > "$out"
  status="$(plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  sub_id="$(plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  echo "    submission $sub_id: $status"
  if [ "$status" != "Accepted" ]; then
    if [ -n "$sub_id" ]; then xcrun notarytool log "$sub_id" "${NOTARY_AUTH[@]}" || true; fi
    echo "ERROR: notarization of $(basename "$file") $status" >&2
    exit 1
  fi
}

# Everything that decides what the DMG holds: the app, the /Applications link and
# the committed layout, refused unless the layout files are exactly the hashed ones.
make_stage() {
  local stage="$1" listed present
  [ -d "$APP" ] && [ ! -L "$APP" ] || { echo "ERROR: $APP is not a directory" >&2; exit 1; }
  listed="$(awk '{print $2}' "$LAYOUT_SUMS" | sort)"
  present="$(cd "$LAYOUT" && find . -mindepth 1 | sed 's|^\./||' | sort)"
  [ "$listed" = "$present" ] || { echo "ERROR: $LAYOUT holds other files than layout.sha256 lists" >&2; exit 1; }
  (cd "$LAYOUT" && shasum -a 256 -c --strict --quiet "$LAYOUT_SUMS") || { echo "ERROR: the DMG layout files differ from layout.sha256" >&2; exit 1; }
  mkdir -m 755 "$stage"
  ditto "$APP" "$stage/Hollow.app"
  ln -s /Applications "$stage/Applications"
  mkdir -m 755 "$stage/.background"
  cp -X "$LAYOUT/background.tiff" "$stage/.background/background.tiff"
  cp -X "$LAYOUT/DS_Store" "$stage/.DS_Store"
  cp -X "$LAYOUT/VolumeIcon.icns" "$stage/.VolumeIcon.icns"
  # Keeps fseventsd from writing its log into the image while it is mounted
  # read-write for the volume icon flag.
  mkdir -m 755 "$stage/.fseventsd"
  : > "$stage/.fseventsd/no_log"
  chmod 644 "$stage/.background/background.tiff" "$stage/.DS_Store" "$stage/.VolumeIcon.icns" "$stage/.fseventsd/no_log"
}

# Every entry below the root; the volume root is checked on its own (root_ok),
# since hdiutil gives it the volume's own attributes.
tree_spec() {
  mtree -c -k "$MTREE_KEYS" -p "$1" | grep -v '^#' \
    | awk 'skip { if ($0 !~ /\\$/) skip = 0; next } /^\.[[:space:]]/ { if ($0 ~ /\\$/) skip = 1; next } { print }'
}

# The volume root: a plain 755 directory whose only Finder info is the custom
# icon flag (com.apple.provenance is the system's own mark).
root_ok() {
  local m="$1" names info
  [ "$(stat -f '%HT %Lp %Sf' "$m")" = "Directory 755 -" ] || return 1
  names="$(xattr "$m" | grep -vxF com.apple.provenance | tr '\n' ' ')"
  [ "$names" = "com.apple.FinderInfo " ] || return 1
  info="$(xattr -px com.apple.FinderInfo "$m" | tr -d ' \n' | tr 'A-F' 'a-f')"
  [ "$info" = "$FINDER_INFO_CUSTOM_ICON" ]
}

# The DMG must hold the staged tree and nothing else: no extra or hidden entry, no
# changed byte, mode, link, flag or extended attribute. Then the app inside it is
# checked as a user will meet it.
verify_dmg() {
  local dmg="$1" expected="$2"
  echo "==> check $(basename "$dmg") holds exactly the staged tree"
  mkdir "$MNT"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$dmg" >/dev/null
  tree_spec "$MNT" > "$WORK/actual.mtree"
  root_ok "$MNT" || { echo "ERROR: the root of $(basename "$dmg") has unexpected attributes" >&2; exit 1; }
  if ! diff -u "$expected" "$WORK/actual.mtree" > "$WORK/mtree.diff"; then
    head -40 "$WORK/mtree.diff" >&2
    echo "ERROR: $(basename "$dmg") does not hold exactly the staged tree" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$MNT/Hollow.app"
  if [ "$SIGNED" = 1 ]; then
    xcrun stapler validate "$MNT/Hollow.app"
    spctl -a -t exec -vv "$MNT/Hollow.app"
    codesign --verify --strict -R "$REQ" "$MNT/Hollow.app" || { echo "ERROR: the app in the DMG is not signed by $ID" >&2; exit 1; }
  fi
  hdiutil detach -quiet "$MNT"
  rmdir "$MNT"
  echo "    identical"
}

# --- Stage: build -----------------------------------------------------------
if runs build; then
  # The Xcode project takes its identity and team from the gitignored
  # macos/Flutter/LocalSigning.xcconfig (committed defaults: ad-hoc, no team).
  # A local signed run writes it, so the Xcode Archive flow finds its team too.
  # A build-only stage (CI) stays ad-hoc: the sign stage re-signs every binary anyway.
  if [ "$SIGNED" = 1 ] && [ "$STAGE" = all ]; then
    LOCAL_SIGNING="$ROOT_DIR/macos/Flutter/LocalSigning.xcconfig"
    if ! grep -qs "^HOLLOW_DEVELOPMENT_TEAM = ${MAC_TEAM_ID}\$" "$LOCAL_SIGNING" \
       || ! grep -qs "^HOLLOW_CODE_SIGN_IDENTITY = Developer ID Application\$" "$LOCAL_SIGNING"; then
      echo "==> writing ${LOCAL_SIGNING#"$ROOT_DIR"/} (team ${MAC_TEAM_ID}, Developer ID Application)"
      {
        echo '// Written by scripts/build_macos_release.sh from release.local.env. Gitignored.'
        echo '// Delete it to build ad-hoc again (any clone does, without this file).'
        echo "HOLLOW_DEVELOPMENT_TEAM = ${MAC_TEAM_ID}"
        echo 'HOLLOW_CODE_SIGN_IDENTITY = Developer ID Application'
      } > "$LOCAL_SIGNING"
    fi
  fi

  echo "==> flutter pub get + webcrypto patch"
  flutter pub get --enforce-lockfile
  bash "$SCRIPT_DIR/patch_webcrypto_apple.sh"

  # The Xcode "Bundle screen audio capturer" phase only COPIES this binary; when
  # it is missing the release silently ships without screen-share audio.
  echo "==> screen_audio_capturer"
  bash "$SCRIPT_DIR/build_screen_audio.sh"

  echo "==> flutter build macos --release"
  flutter build macos --release

  [ -d "$APP" ] || { echo "ERROR: $APP not found" >&2; exit 1; }
  [ -f "$APP/Contents/Resources/screen_audio_capturer" ] || { echo "ERROR: screen_audio_capturer missing from the bundle (the release would ship without screen-share audio)" >&2; exit 1; }
  for bin in "$APP/Contents/MacOS/Hollow" "$APP/Contents/Resources/screen_audio_capturer"; do
    archs="$(lipo -archs "$bin")"
    [[ " $archs " == *" x86_64 "* && " $archs " == *" arm64 "* ]] || { echo "ERROR: ${bin#"$REL"/} is not universal ($archs)" >&2; exit 1; }
  done
fi

if [ "$STAGE" != verify-dmg ]; then
  [ -d "$APP" ] || { echo "ERROR: $APP not found (run the build stage first)" >&2; exit 1; }
fi
[ -f "$ENT" ] || { echo "ERROR: entitlements not found at $ENT" >&2; exit 1; }

# --- Stage: sign (inside-out, then notarize + staple the app) ---------------
if runs sign && [ "$SIGNED" = 1 ]; then
  echo "==> sign nested dylibs / framework binaries"
  find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) -print0 > "$WORK/nested"
  while IFS= read -r -d '' f; do
    if is_macho "$f"; then
      echo "    ${f#"$APP"/}"
      sign --options runtime "$f"
    fi
  done < "$WORK/nested"

  echo "==> sign .framework bundles"
  find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0 | while IFS= read -r -d '' fw; do
    echo "    ${fw#"$APP"/}"
    sign --options runtime "$fw"
  done

  echo "==> sign nested app / xpc bundles"
  find "$APP/Contents" -type d \( -name "*.app" -o -name "*.xpc" \) ! -path "$APP" -print0 | while IFS= read -r -d '' h; do
    echo "    ${h#"$APP"/}"
    sign --options runtime "$h"
  done

  # The Frameworks loops never reach Contents/Resources (screen_audio_capturer,
  # dropped there ad-hoc by an Xcode phase); its absence broke v0.7.1's notarization.
  echo "==> sign bare Mach-O helpers under Resources/"
  find "$APP/Contents/Resources" -type f -perm +111 -print0 > "$WORK/helpers"
  while IFS= read -r -d '' r; do
    if is_macho "$r"; then
      echo "    ${r#"$APP"/}"
      sign --options runtime "$r"
    fi
  done < "$WORK/helpers"

  echo "==> sign the app bundle (with entitlements)"
  sign --options runtime --entitlements "$ENT" "$APP"

  codesign --verify --deep --strict --verbose=2 "$APP"
  verify_macho_signatures "$APP"

  # Stapled before it goes into the DMG and the zip, so the app a user drags out
  # opens offline.
  echo "==> notarize + staple the app"
  ditto -c -k --keepParent "$APP" "$WORK/notary-app.zip"
  notarize "$WORK/notary-app.zip"
  rm -f "$WORK/notary-app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- Stage: package ---------------------------------------------------------
if runs package; then
  if [ "$SIGNED" = 1 ]; then xcrun stapler validate "$APP" >/dev/null || { echo "ERROR: $APP is not stapled (run the sign stage first)" >&2; exit 1; }; fi
  echo "==> stage the DMG contents"
  make_stage "$WORK/stage"
  tree_spec "$WORK/stage" > "$WORK/expected.mtree"

  echo "==> hdiutil create"
  rm -f "$DMG" "$ZIP" "$REL/SHA256SUMS"
  hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW "$WORK/rw.dmg"
  mkdir "$MNT"
  hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$WORK/rw.dmg"
  xattr -wx com.apple.FinderInfo "$FINDER_INFO_CUSTOM_ICON" "$MNT"
  hdiutil detach -quiet "$MNT"
  rmdir "$MNT"
  hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/hollow.dmg"
  rm -f "$WORK/rw.dmg"
  verify_dmg "$WORK/hollow.dmg" "$WORK/expected.mtree"

  if [ "$SIGNED" = 1 ]; then
    echo "==> sign + notarize + staple the DMG"
    sign "$WORK/hollow.dmg"
    notarize "$WORK/hollow.dmg"
    xcrun stapler staple "$WORK/hollow.dmg"
    xcrun stapler validate "$WORK/hollow.dmg"
    spctl -a -t open --context context:primary-signature -vv "$WORK/hollow.dmg"
    codesign --verify --strict "$WORK/hollow.dmg"
    verify_dmg "$WORK/hollow.dmg" "$WORK/expected.mtree"
  fi
  mv "$WORK/hollow.dmg" "$DMG"

  echo "==> updater zip"
  (cd "$REL" && ditto -c -k --keepParent Hollow.app "$ZIP")   # NEVER plain `zip`

  echo "==> verify"
  short="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
  [ "$short" = "$VERSION" ] || { echo "ERROR: Info.plist version $short, expected $VERSION" >&2; exit 1; }
  [ -f "$APP/Contents/Resources/screen_audio_capturer" ] || { echo "ERROR: screen_audio_capturer missing" >&2; exit 1; }
  codesign --verify --deep --strict "$APP"
  ditto -x -k "$ZIP" "$WORK/unzipped"
  codesign --verify --deep --strict "$WORK/unzipped/Hollow.app"
  if [ "$SIGNED" = 1 ]; then
    xcrun stapler validate "$WORK/unzipped/Hollow.app"
    spctl -a -t exec -vv "$APP"
    codesign --verify --strict -R "$REQ" "$APP" || { echo "ERROR: Hollow.app is not signed by $ID" >&2; exit 1; }
    verify_macho_signatures "$APP"
  fi

  (cd "$REL" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" | tee SHA256SUMS)
  echo ""
  echo "==== DONE, macOS $VERSION ($([ "$SIGNED" = 1 ] && echo signed + notarized || echo UNSIGNED)) ===="
  echo "  DMG: $DMG"
  echo "  Zip: $ZIP"
fi

# --- Stage: verify-dmg --------------------------------------------------------
if [ "$STAGE" = verify-dmg ]; then
  [ -f "$DMG" ] || { echo "ERROR: $DMG not found" >&2; exit 1; }
  make_stage "$WORK/stage"
  tree_spec "$WORK/stage" > "$WORK/expected.mtree"
  verify_dmg "$DMG" "$WORK/expected.mtree"
  if [ "$SIGNED" = 1 ]; then
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
  fi
fi
