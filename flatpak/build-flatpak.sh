#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
BUILD_DIR="$SCRIPT_DIR/.flatpak-builder"
FLUTTER_BUNDLE="$PROJECT_DIR/build/linux/x64/release/bundle"
REPO_PUBKEY="$SCRIPT_DIR/hollow-flatpak.gpg"

# --- Machine config ------------------------------------------------------
# scripts/release.local.env holds WHERE the OSTree repo lives, the URL it is
# published under and which key signs it. No secrets: the private half lives
# in FLATPAK_GPG_HOMEDIR, outside the repo, and is never read by git.
ENV_FILE="$PROJECT_DIR/scripts/release.local.env"
if [ -f "$ENV_FILE" ]; then
    # An explicit environment value beats the file, so a test build can point
    # FLATPAK_REPO_DIR at a scratch repo without editing machine config.
    # `set -a; . file` re-assigns every key in the file, so snapshot first and
    # put the environment back afterwards.
    _ENV_FLATPAK="$(export -p | grep -E '^(declare -x |export )FLATPAK_' || true)"
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
    eval "$_ENV_FLATPAK"
fi

# The export repo is PERSISTENT and lives outside the source tree: every
# release commit stays in it so `flatpak update` has a history to diff
# against and static deltas have a parent to be built from. Wiping it would
# turn every update into a full redownload.
FLATPAK_REPO_DIR="${FLATPAK_REPO_DIR:-$HOME/hollow-flatpak-repo}"
FLATPAK_REPO_URL="${FLATPAK_REPO_URL:-https://flatpak.anonlisten.com}"
FLATPAK_GPG_HOMEDIR="${FLATPAK_GPG_HOMEDIR:-$HOME/.hollow-release/gnupg}"
FLATPAK_GPG_KEY="${FLATPAK_GPG_KEY:-}"

# Derive the version from the single source of truth (updater.rs APP_VERSION)
# so the bundle filename never has to be hand-edited per release.
VERSION="$(grep -oP 'APP_VERSION: &str = "\K[^"]+' "$PROJECT_DIR/rust/hollow_core/src/api/updater.rs")"
VERSION="${VERSION:-0.0.0}"
FLATPAK_OUT="$SCRIPT_DIR/hollow-${VERSION}-linux-x86_64.flatpak"

echo "=== Hollow Flatpak Build (v${VERSION}) ==="

# --- Signing -------------------------------------------------------------
# A signed build is the only kind that can carry a live origin: the bundle
# embeds --repo-url plus the public key, so installing it registers the
# `hollow` remote and `flatpak update` works from then on. An unsigned build
# is a local dev artifact and gets NO repo URL, because a URL whose summary
# is signed by a key the client does not have fails on the first update.
SIGN_ARGS=()
SIGNED=1
if [ -z "$FLATPAK_GPG_KEY" ]; then
    SIGNED=0
    echo "***********************************************************************"
    echo "WARNING: FLATPAK_GPG_KEY is not set."
    echo "WARNING: this build will be UNSIGNED and will carry no origin remote,"
    echo "WARNING: so 'flatpak update' will do nothing for anyone who installs it."
    echo "WARNING: that is a dev build. Set FLATPAK_GPG_KEY in"
    echo "WARNING: scripts/release.local.env before building a release."
    echo "***********************************************************************"
elif [ ! -f "$REPO_PUBKEY" ]; then
    echo "ERROR: FLATPAK_GPG_KEY is set but the public key $REPO_PUBKEY is missing."
    echo "       Export it with:"
    echo "         gpg --homedir $FLATPAK_GPG_HOMEDIR --export $FLATPAK_GPG_KEY > $REPO_PUBKEY"
    exit 1
else
    SIGN_ARGS=(--gpg-sign="$FLATPAK_GPG_KEY" --gpg-homedir="$FLATPAK_GPG_HOMEDIR")
    echo "Signing with $FLATPAK_GPG_KEY (homedir $FLATPAK_GPG_HOMEDIR)"
fi

# Check prerequisites
if ! command -v flatpak &>/dev/null; then
    echo "ERROR: flatpak not installed. Run: sudo apt install flatpak"
    exit 1
fi

if ! command -v flatpak-builder &>/dev/null; then
    echo "ERROR: flatpak-builder not installed. Run: sudo apt install flatpak-builder"
    exit 1
fi

if ! command -v ostree &>/dev/null; then
    echo "ERROR: ostree not installed. Run: sudo apt install ostree"
    exit 1
fi

# Install runtime and SDK if needed
echo "Ensuring Flatpak runtime is installed..."
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08 || true

# Check that Flutter build exists
if [ ! -f "$FLUTTER_BUNDLE/hollow" ]; then
    echo "ERROR: Flutter Linux build not found at $FLUTTER_BUNDLE"
    echo "Run 'flutter build linux' first."
    exit 1
fi

# Prepare bundle directory
echo "Preparing bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/syslibs"

# Copy Flutter build output
cp "$FLUTTER_BUNDLE/hollow" "$BUNDLE_DIR/"
cp -r "$FLUTTER_BUNDLE/lib" "$BUNDLE_DIR/"
cp -r "$FLUTTER_BUNDLE/data" "$BUNDLE_DIR/"

# Screen audio capturer/renderer (out-of-process Opus exe for screen share
# audio, send AND receive). Lands in the Flutter bundle via linux/CMakeLists.txt
# when it was built (scripts/build_screen_audio.sh) before 'flutter build linux'.
if [ -f "$FLUTTER_BUNDLE/screen_audio_capturer" ]; then
    cp "$FLUTTER_BUNDLE/screen_audio_capturer" "$BUNDLE_DIR/"
    chmod +x "$BUNDLE_DIR/screen_audio_capturer"
    echo "  Bundled: screen_audio_capturer"
else
    echo "WARNING: screen_audio_capturer not in the Flutter bundle."
    echo "         Run scripts/build_screen_audio.sh, then 'flutter build linux'."
    echo "         Screen share audio will be unavailable in this flatpak."
fi

# Icon (Flatpak max 512x512)
if command -v convert &>/dev/null; then
    convert "$FLUTTER_BUNDLE/data/flutter_assets/assets/hollow_logo_rounded.png" \
        -resize 512x512 "$BUNDLE_DIR/com.anonlisten.hollow.png"
elif command -v magick &>/dev/null; then
    magick "$FLUTTER_BUNDLE/data/flutter_assets/assets/hollow_logo_rounded.png" \
        -resize 512x512 "$BUNDLE_DIR/com.anonlisten.hollow.png"
else
    # Fallback: use ffmpeg to resize (we know it's available)
    ffmpeg -y -i "$FLUTTER_BUNDLE/data/flutter_assets/assets/hollow_logo_rounded.png" \
        -vf scale=512:512 "$BUNDLE_DIR/com.anonlisten.hollow.png" 2>/dev/null \
    || cp "$FLUTTER_BUNDLE/data/flutter_assets/assets/hollow_logo_rounded.png" \
          "$BUNDLE_DIR/com.anonlisten.hollow.png"
fi

# Desktop file and metainfo
cp "$SCRIPT_DIR/com.anonlisten.Hollow.desktop" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/com.anonlisten.Hollow.metainfo.xml" "$BUNDLE_DIR/"

# Stamp this build's version into the metainfo COPY that ships in the flatpak.
# The committed flatpak/com.anonlisten.Hollow.metainfo.xml is never touched:
# it carries the release notes we write by hand, and nobody remembers to bump
# it every build, so `flatpak list`, GNOME Software and KDE Discover used to
# report whatever version was last hand-edited (0.9.4 for six releases).
META="$BUNDLE_DIR/com.anonlisten.Hollow.metainfo.xml"
if grep -q "<release version=\"$VERSION\"" "$META"; then
    echo "  metainfo already lists $VERSION"
elif grep -q "<releases>" "$META"; then
    TODAY="$(date +%F)"
    sed -i "s|<releases>|<releases>\n    <release version=\"$VERSION\" date=\"$TODAY\">\n      <description>\n        <p>Hollow $VERSION</p>\n      </description>\n    </release>|" "$META"
    echo "  metainfo: inserted release $VERSION ($TODAY)"
else
    echo "  WARNING: no <releases> block in $META, the reported version stays stale"
fi

# Bundle system libraries that aren't in the Freedesktop 24.08 runtime.
# These are resolved from the build host (Ubuntu 24.04).
echo "Bundling system libraries..."
SYSLIBS=(
    # AppIndicator (tray_manager_plugin dependency)
    libayatana-appindicator3.so.1
    libayatana-indicator3.so.7
    libayatana-ido3-0.4.so.0
    libdbusmenu-glib.so.4
    libdbusmenu-gtk3.so.4
    # libsecret (flutter_secure_storage_linux — OS keychain identity protection).
    # Not in the Freedesktop runtime; without it the dynamic loader fails before
    # main() with "libsecret-1.so.0: cannot open shared object file" (issue #16).
    libsecret-1.so.0
)

for lib in "${SYSLIBS[@]}"; do
    # Match the lib at a word/path boundary so e.g. "libsecret-1.so.0" can't
    # also match an unrelated longer soname (the '.' in the name is a regex
    # wildcard otherwise).
    path=$(ldconfig -p 2>/dev/null | grep -F "$lib" | head -1 | awk '{print $NF}')
    if [ -z "$path" ]; then
        path=$(find /usr/lib /lib -name "$lib*" 2>/dev/null | head -1)
    fi
    if [ -n "$path" ] && [ -f "$path" ]; then
        # Copy the actual file, not the symlink
        real=$(readlink -f "$path")
        cp "$real" "$BUNDLE_DIR/syslibs/$lib"
        echo "  Bundled: $lib ($real)"
    else
        echo "  WARNING: $lib not found on host, Flatpak may fail at runtime"
    fi
done

# --- Dependency audit -------------------------------------------------------
# The bundle ships three lib sources: the Freedesktop runtime, the libs Flutter
# plugins self-bundle into lib/ (fvp's libmdk/ffmpeg, etc.), and our hand-picked
# syslibs/ above. Any NEEDED soname not covered by one of those crashes the app
# before main() with "cannot open shared object file" (issue #16, libsecret).
# Catch that HERE on the build host instead of on a user's machine: ldd every
# ELF in the bundle against a sandbox-like search path and fail on "not found".
echo "Auditing bundled libraries for unresolved dependencies..."
AUDIT_LIBPATH="$BUNDLE_DIR/lib:$BUNDLE_DIR/syslibs"
missing_any=0
while IFS= read -r elf; do
    # Only inspect actual ELF objects (the binary + .so files).
    file "$elf" 2>/dev/null | grep -q "ELF" || continue
    while IFS= read -r dep; do
        echo "  MISSING: $(basename "$dep") (needed by $(basename "$elf"))"
        missing_any=1
    done < <(LD_LIBRARY_PATH="$AUDIT_LIBPATH" ldd "$elf" 2>/dev/null \
                | awk '/not found/ {print $1}')
done < <(find "$BUNDLE_DIR" -type f \( -name 'hollow' -o -name '*.so' -o -name '*.so.*' \))

if [ "$missing_any" -ne 0 ]; then
    echo ""
    echo "NOTE: 'not found' here means the host is missing the lib too; libs that"
    echo "      live ONLY in the Freedesktop runtime (not on the host) are expected"
    echo "      to appear and are fine. Review the list, add genuinely-missing"
    echo "      sonames to SYSLIBS above. Continuing build."
fi
# ----------------------------------------------------------------------------

# --- Export repository ------------------------------------------------------
if [ ! -f "$FLATPAK_REPO_DIR/config" ]; then
    echo "Creating OSTree repository at $FLATPAK_REPO_DIR"
    mkdir -p "$FLATPAK_REPO_DIR"
    ostree init --repo="$FLATPAK_REPO_DIR" --mode=archive
fi

# ONE flatpak-builder run that builds AND exports. Building twice (once bare,
# once with --repo) doubled the slowest step of the release for nothing.
echo "Building and exporting Flatpak to $FLATPAK_REPO_DIR ..."
flatpak-builder --user --force-clean --install-deps-from=flathub \
    --repo="$FLATPAK_REPO_DIR" "${SIGN_ARGS[@]}" \
    "$BUILD_DIR/build" "$SCRIPT_DIR/com.anonlisten.Hollow.yml"

# Static deltas make an update a few MB instead of the whole 57 MB app.
# --prune-depth=5 keeps the five most recent commits reachable, so anyone up
# to five releases behind still gets a delta rather than a full pull.
echo "Updating repository metadata (static deltas, prune)..."
flatpak build-update-repo --generate-static-deltas "${SIGN_ARGS[@]}" \
    --prune --prune-depth=5 "$FLATPAK_REPO_DIR"

# --- Remote description files ----------------------------------------------
# These are published WITH the repo, so a user can add the remote with one
# click (.flatpakrepo) or install straight from the web (.flatpakref).
if [ "$SIGNED" -eq 1 ]; then
    GPG_B64="$(base64 -w0 "$REPO_PUBKEY")"

    cat > "$FLATPAK_REPO_DIR/hollow.flatpakrepo" <<REPOFILE
[Flatpak Repo]
Title=Hollow
Url=$FLATPAK_REPO_URL
Homepage=https://hollow.anonlisten.com
Comment=Encrypted distributed messaging
Description=Hollow is a fully distributed, end-to-end encrypted messaging platform. There are no central servers, the members host it. This is the official Hollow repository, published by AnonListen.
Icon=https://hollow.anonlisten.com/hollow_icon.png
GPGKey=$GPG_B64
REPOFILE

    cat > "$FLATPAK_REPO_DIR/hollow.flatpakref" <<REFFILE
[Flatpak Ref]
Title=Hollow
Name=com.anonlisten.Hollow
Branch=master
Url=$FLATPAK_REPO_URL
SuggestRemoteName=hollow
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=$GPG_B64
REFFILE

    echo "  Wrote hollow.flatpakrepo and hollow.flatpakref"
fi

# --- Single file bundle -----------------------------------------------------
# --repo-url plus --gpg-keys is what makes an installed bundle carry a LIVE
# origin: flatpak creates the remote from them, so the very first
# `flatpak update` after a bundle install finds our repo.
echo "Creating distributable bundle..."
rm -f "$FLATPAK_OUT"
if [ "$SIGNED" -eq 1 ]; then
    # --runtime-repo lets a bundle install on a machine with NO flathub remote
    # still fetch org.freedesktop.Platform//24.08 (the .flatpakref carries the
    # same RuntimeRepo; a bare bundle would otherwise fail on the runtime).
    flatpak build-bundle --repo-url="$FLATPAK_REPO_URL" --gpg-keys="$REPO_PUBKEY" \
        --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
        "${SIGN_ARGS[@]}" \
        "$FLATPAK_REPO_DIR" "$FLATPAK_OUT" com.anonlisten.Hollow
else
    flatpak build-bundle "$FLATPAK_REPO_DIR" "$FLATPAK_OUT" com.anonlisten.Hollow
fi

echo ""
echo "=== Done! ==="
echo "Flatpak bundle: $FLATPAK_OUT"
echo "OSTree repo:    $FLATPAK_REPO_DIR"
if [ "$SIGNED" -eq 1 ]; then
    echo "Publish it:     bash scripts/publish_flatpak_repo.sh"
fi
echo ""
echo "To install:  flatpak install --user $FLATPAK_OUT"
echo "To run:      flatpak run com.anonlisten.Hollow"
echo "To remove:   flatpak uninstall com.anonlisten.Hollow"
