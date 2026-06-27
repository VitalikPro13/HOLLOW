#!/bin/bash
# Build the screen audio capturer/renderer binary for macOS/Linux and bundle it
# into the Flutter app (if a Release build is present).
#
# Build it BEFORE `flutter build macos` / `flutter build linux` so the produced
# binary is available; the macOS Runner has a "Bundle screen audio capturer" run
# script phase that copies it into Contents/Resources during the Xcode build, and
# this script also copies it directly when a Release bundle already exists.
#
# Run from the project root.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_APP_DIR="$ROOT_DIR/packages/flutter_webrtc/test_apps/screen_audio_test"
BUILD_DIR="$TEST_APP_DIR/build"

echo "=== Building screen_audio_test ==="

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure
if [ ! -f "CMakeCache.txt" ]; then
    echo "Configuring CMake..."
    # -DCMAKE_POLICY_VERSION_MINIMUM=3.5: libogg's CMakeLists declares a
    # cmake_minimum_required below 3.5, which CMake 4.x rejects outright.
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
fi

echo "Building..."
cmake --build . --config Release

EXE="$BUILD_DIR/screen_audio_test"
if [ ! -f "$EXE" ]; then
    echo "ERROR: Build output not found at $EXE"
    exit 1
fi
echo "Built: $EXE"
ls -lh "$EXE"

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo ""
    file "$EXE" | sed 's/^/  /'
    APP_RES="$ROOT_DIR/build/macos/Build/Products/Release/Hollow.app/Contents/Resources"
    if [ -d "$APP_RES" ]; then
        echo "Bundling into Hollow.app..."
        cp "$EXE" "$APP_RES/screen_audio_capturer"
        chmod +x "$APP_RES/screen_audio_capturer"
        echo "  -> $APP_RES/screen_audio_capturer"
        echo "NOTE: re-run scripts/macos_resign_and_dmg.sh so the binary is signed."
    else
        echo "No Release Hollow.app yet — the Xcode 'Bundle screen audio capturer'"
        echo "run-script phase will copy it on the next 'flutter build macos'."
    fi
elif [[ "$OSTYPE" == "linux"* ]]; then
    echo ""
    BUNDLE="$ROOT_DIR/build/linux/x64/release/bundle"
    if [ -d "$BUNDLE" ]; then
        echo "Bundling into Linux bundle..."
        cp "$EXE" "$BUNDLE/screen_audio_capturer"
        chmod +x "$BUNDLE/screen_audio_capturer"
        echo "  -> $BUNDLE/screen_audio_capturer"
    else
        echo "To bundle into the Linux app after 'flutter build linux':"
        echo "  cp $EXE $BUNDLE/screen_audio_capturer"
        echo "  chmod +x $BUNDLE/screen_audio_capturer"
    fi
fi

echo ""
echo "=== Done ==="
