#!/bin/bash
# Hollow — Linux release build. RUN ON THE LINUX VM.
#
#   bash scripts/build_linux_release.sh [VERSION]
#
# Produces, under $LINUX_REPO:
#   build/linux/x64/release/hollow-<ver>-linux.tar.gz   (portable tarball)
#   flatpak/hollow-<ver>-linux-x86_64.flatpak           (flatpak bundle)
#
# The Windows orchestrator (build_release.ps1) scp-pulls both into
# installer/Output/. This script does NOT scp anything itself.
#
# No secrets. Reads scripts/release.local.env for machine paths.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load machine config -------------------------------------------------
ENV_FILE="$SCRIPT_DIR/release.local.env"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy release.local.env.example)"; exit 1; }
# An explicit FLATPAK_* environment value beats the file, so a test build can
# aim at a scratch OSTree repo without editing machine config. `set -a` would
# otherwise overwrite it with the file's value.
_ENV_FLATPAK="$(export -p | grep -E '^(declare -x |export )FLATPAK_' || true)"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
eval "$_ENV_FLATPAK"

# PATH for non-interactive shells (flutter + cargo).
export PATH="${LINUX_FLUTTER_BIN}:$HOME/.cargo/bin:$PATH"

# --- Resolve version from pubspec ---------------------------------------
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(grep '^version:' "$ROOT_DIR/pubspec.yaml" | head -1 | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
fi
[ -n "$VERSION" ] || { echo "ERROR: could not resolve version; pass it explicitly"; exit 1; }
echo "==> Hollow Linux release — version $VERSION"

cd "$ROOT_DIR"

# --- 1. Build -----------------------------------------------------------
# Screen audio exe FIRST — linux/CMakeLists.txt installs it into the bundle
# during `flutter build linux`, and that install is warning-not-fatal: wrong
# order silently ships a release without screen-share audio (send AND receive).
echo "==> 1a. screen_audio_capturer"
bash "$ROOT_DIR/scripts/build_screen_audio.sh"

echo "==> 1b. flutter build linux (release)"
flutter build linux

if [ ! -f "$ROOT_DIR/build/linux/x64/release/bundle/screen_audio_capturer" ]; then
  echo "ERROR: screen_audio_capturer missing from the bundle — release would ship without screen-share audio"
  exit 1
fi

# --- 1c. Split debug symbols out of the Rust library ---------------------
# `[profile.release] debug = "line-tables-only"` (rust/hollow_core/Cargo.toml)
# is free on Windows: symbols go to a SEPARATE .pdb that hollow.iss and
# build_release.ps1 already exclude. On ELF there is no separate file, so the
# DWARF lands INSIDE libhollow_core.so — it went 67 MB -> 310 MB in 0.10.1,
# taking the tarball from 74 MB to 118 MB. Keep the symbols (profiling them is
# WHY that profile line exists) but ship them beside the bundle, not in it.
# The flatpak needs no such step: flatpak-builder already splits debug info
# into the com.anonlisten.Hollow.Debug extension.
echo "==> 1c. Split debug symbols"
SO="$ROOT_DIR/build/linux/x64/release/bundle/lib/libhollow_core.so"
DBG_DIR="$ROOT_DIR/build/linux/x64/release/debug-symbols"
DBG="$DBG_DIR/libhollow_core-$VERSION.so.debug"
if readelf -S "$SO" | grep -q debug_info; then
  mkdir -p "$DBG_DIR"
  # Prove the strip touches no code: .text must be byte-identical afterwards.
  objcopy -O binary --only-section=.text "$SO" /tmp/hollow_text_pre.bin
  objcopy --only-keep-debug "$SO" "$DBG"
  strip --strip-debug "$SO"
  objcopy --add-gnu-debuglink="$DBG" "$SO"
  objcopy -O binary --only-section=.text "$SO" /tmp/hollow_text_post.bin
  if ! cmp -s /tmp/hollow_text_pre.bin /tmp/hollow_text_post.bin; then
    echo "ERROR: stripping changed .text — refusing to ship this bundle"
    exit 1
  fi
  rm -f /tmp/hollow_text_pre.bin /tmp/hollow_text_post.bin
  echo "    -> stripped: $(du -h "$SO" | cut -f1)  symbols: $DBG"
else
  echo "    (no debug_info present, nothing to split)"
fi

# --- 2. Tarball ---------------------------------------------------------
echo "==> 2. Tarball"
REL="$ROOT_DIR/build/linux/x64/release"
TARBALL="hollow-$VERSION-linux.tar.gz"
cd "$REL"
rm -f "$TARBALL"
tar czf "$TARBALL" bundle/
echo "    -> $REL/$TARBALL"

# --- 3. Flatpak ---------------------------------------------------------
echo "==> 3. Flatpak"
cd "$ROOT_DIR/flatpak"
# Stale caches from a prior version's build make `set -e` + build-flatpak.sh
# exit non-zero silently — wipe them first, and run in the foreground.
rm -rf .flatpak-builder repo bundle
bash build-flatpak.sh
FLATPAK="hollow-$VERSION-linux-x86_64.flatpak"
[ -f "$ROOT_DIR/flatpak/$FLATPAK" ] || { echo "ERROR: flatpak bundle not produced: $FLATPAK"; exit 1; }
echo "    -> $ROOT_DIR/flatpak/$FLATPAK"

# --- 4. Publish the flatpak repository (opt in) --------------------------
# build-flatpak.sh has already committed this version into the persistent
# OSTree repo (FLATPAK_REPO_DIR) and signed it. Pushing that repo LIVE is a
# separate decision the release orchestrator makes, so it stays off here
# unless FLATPAK_PUBLISH=1 is exported.
if [ "${FLATPAK_PUBLISH:-0}" = "1" ]; then
  echo "==> 4. Publish flatpak repository"
  bash "$ROOT_DIR/scripts/publish_flatpak_repo.sh"
else
  echo "==> 4. Publish skipped (export FLATPAK_PUBLISH=1 to push the repo live)"
fi

echo ""
echo "==== DONE — Linux $VERSION ===="
echo "  Tarball: $REL/$TARBALL"
echo "  Flatpak: $ROOT_DIR/flatpak/$FLATPAK"
echo "  (Pull both with the Windows orchestrator: build_release.ps1)"
