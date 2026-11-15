#!/bin/bash
# Installs the pinned Flutter SDK into ~/flutter for CI and puts it on the PATH.
# The archive is checked against the SHA-256 pinned here, not one fetched beside it.
# Replaces subosito/flutter-action, which calls actions/cache by tag: the repository
# requires every action, nested ones included, pinned to a full commit SHA.
set -euo pipefail

FLUTTER_VERSION=3.47.9
FLUTTER_SHA256=25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a
ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
DIR="$HOME/flutter"

if [ ! -x "$DIR/bin/flutter" ]; then
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/$ARCHIVE" \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/$ARCHIVE"
    echo "$FLUTTER_SHA256  $tmp/$ARCHIVE" | sha256sum -c -
    tar -xJf "$tmp/$ARCHIVE" -C "$HOME"
    rm -rf "$tmp"
fi

git config --global --add safe.directory "$DIR"
echo "$DIR/bin" >> "${GITHUB_PATH:-/dev/null}"
"$DIR/bin/flutter" --version
