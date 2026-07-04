#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
BUILD_DIR="$SCRIPT_DIR/.flatpak-builder"
REPO_DIR="$SCRIPT_DIR/repo"
FLUTTER_BUNDLE="$PROJECT_DIR/build/linux/x64/release/bundle"

# Derive the version from the single source of truth (updater.rs APP_VERSION)
# so the bundle filename never has to be hand-edited per release.
VERSION="$(grep -oP 'APP_VERSION: &str = "\K[^"]+' "$PROJECT_DIR/rust/hollow_core/src/api/updater.rs")"
VERSION="${VERSION:-0.0.0}"
FLATPAK_OUT="$SCRIPT_DIR/hollow-${VERSION}-linux-x86_64.flatpak"

echo "=== Hollow Flatpak Build (v${VERSION}) ==="

# Check prerequisites
if ! command -v flatpak &>/dev/null; then
    echo "ERROR: flatpak not installed. Run: sudo apt install flatpak"
    exit 1
fi

if ! command -v flatpak-builder &>/dev/null; then
    echo "ERROR: flatpak-builder not installed. Run: sudo apt install flatpak-builder"
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
        echo "  WARNING: $lib not found on host — Flatpak may fail at runtime"
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
    echo "      to appear and are fine. Review the list — add genuinely-missing"
    echo "      sonames to SYSLIBS above. Continuing build."
fi
# ----------------------------------------------------------------------------

# Build the Flatpak
echo "Building Flatpak..."
flatpak-builder --user --force-clean --install-deps-from=flathub \
    "$BUILD_DIR/build" "$SCRIPT_DIR/com.anonlisten.Hollow.yml"

# Export to repo and create single-file bundle
echo "Creating distributable bundle..."
rm -rf "$REPO_DIR"
flatpak-builder --user --repo="$REPO_DIR" --force-clean \
    "$BUILD_DIR/build" "$SCRIPT_DIR/com.anonlisten.Hollow.yml"

flatpak build-bundle "$REPO_DIR" "$FLATPAK_OUT" \
    com.anonlisten.Hollow

echo ""
echo "=== Done! ==="
echo "Flatpak bundle: $FLATPAK_OUT"
echo ""
echo "To install:  flatpak install --user $FLATPAK_OUT"
echo "To run:      flatpak run com.anonlisten.Hollow"
echo "To remove:   flatpak uninstall com.anonlisten.Hollow"
