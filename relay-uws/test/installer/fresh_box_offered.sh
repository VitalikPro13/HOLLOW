#!/bin/bash
# Prints "offered" when this system has or offers every library the official
# ready-made programs link to, "forwarder only: <why>" when only the
# forwarder's, else "not offered: <why>". The first
# PREBUILT_NEEDS in native.sh is the official list; fresh_box_test.sh appends
# its stand-in relay's own below it. Run by fresh_box_test.sh in a test box.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
D=$(cd "$(dirname "$0")/../../deploy/lib" && pwd)
. "$D/common.sh"
. "$D/host.sh"
. "$D/native.sh"
PREBUILT_NEEDS=$(awk 'index($0, "PREBUILT_NEEDS=\"") == 1 { f = 1; sub(/^[^"]*"/, "") }
    f { l = $0; e = sub(/".*$/, "", l); print l; if (e) exit }' "$D/native.sh" | tr '\n' ' ')
if ! prebuilt_libs_offered; then echo "not offered: $PREBUILT_LIBS_WHY"
elif [ "$PREBUILT_RELAY_ONLY" = 1 ]; then echo "forwarder only: $PREBUILT_LIBS_WHY"
else echo offered; fi
