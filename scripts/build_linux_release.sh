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
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

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
echo "==> 1. flutter build linux (release)"
flutter build linux

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

echo ""
echo "==== DONE — Linux $VERSION ===="
echo "  Tarball: $REL/$TARBALL"
echo "  Flatpak: $ROOT_DIR/flatpak/$FLATPAK"
echo "  (Pull both with the Windows orchestrator: build_release.ps1)"
