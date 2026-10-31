#!/bin/bash
# webcrypto 0.6.1 leaves BoringSSL's fiat_p256_adx_{mul,sqr}.S out of its apple
# x86_64 source list (the linux x86_64 list has them), so the Intel slice of a
# universal macOS release fails to link with undefined _fiat_p256_adx_* symbols.
# This adds the two lines to the package as `flutter pub get` resolved it.
# Idempotent; run after `flutter pub get`, before any build.
# Memory feedback_webcrypto_boringssl_native_assets.
#
#   bash scripts/patch_webcrypto_apple.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT_DIR/.dart_tool/package_config.json"
[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG missing; run flutter pub get first" >&2; exit 1; }

# The file as webcrypto 0.6.1 ships it, and as this script leaves it. Anything
# else is a different package or a hand edit: accepted only if the edit is the fix.
PRISTINE_SHA=152514a5707401ccf23b4640faa3f942f21c81e4dc28707437b760d08af02002
PATCHED_SHA=86f8acab37613b09d2a78a1c84561e408f7bc0f0cabe9da67c730f271d617988

PKG="$(python3 -I - "$CONFIG" <<'PY'
import json, sys
from urllib.parse import urlparse, unquote
for p in json.load(open(sys.argv[1]))["packages"]:
    if p["name"] == "webcrypto":
        u = urlparse(p["rootUri"])
        print(unquote(u.path) if u.scheme == "file" else "")
PY
)"
[ -n "$PKG" ] && [ -d "$PKG" ] || { echo "ERROR: webcrypto is not in $CONFIG" >&2; exit 1; }
VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+).*/\1/p' "$PKG/pubspec.yaml" | head -1)"
SOURCES="$PKG/third_party/boringssl/sources.cmake"

if [ "$VERSION" != "0.6.1" ]; then
  echo "ERROR: webcrypto is $VERSION, this patch is for 0.6.1." >&2
  echo "       Check whether $SOURCES lists fiat_p256_adx_*.S under crypto_sources_apple_x86_64," >&2
  echo "       then update or drop this script." >&2
  exit 1
fi

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Both .S files inside the apple x86_64 list (a hand patch on the old Mac counts).
apple_list_has_adx() {
  python3 -I - "$SOURCES" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = lines.index("set(crypto_sources_apple_x86_64")
block = lines[start:lines.index(")", start)]
want = ("third_party/fiat/asm/fiat_p256_adx_mul.S", "third_party/fiat/asm/fiat_p256_adx_sqr.S")
sys.exit(0 if all(any(l.strip().endswith(w) for l in block) for w in want) else 1)
PY
}

case "$(sha "$SOURCES")" in
  "$PATCHED_SHA")
    echo "webcrypto $VERSION: already patched ($SOURCES)"
    ;;
  "$PRISTINE_SHA")
    python3 -I - "$SOURCES" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
start = lines.index("set(crypto_sources_apple_x86_64")
end = lines.index(")", start)
anchor = "  ${BORINGSSL_ROOT}gen/test_support/trampoline-x86_64-apple.S"
at = lines.index(anchor, start, end)
lines[at + 1:at + 1] = [
    "  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_p256_adx_mul.S",
    "  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_p256_adx_sqr.S",
]
open(path, "w").write("\n".join(lines))
PY
    [ "$(sha "$SOURCES")" = "$PATCHED_SHA" ] || { echo "ERROR: the patched file's hash is not the expected one" >&2; exit 1; }
    echo "webcrypto $VERSION: patched $SOURCES"
    ;;
  *)
    if apple_list_has_adx; then
      echo "webcrypto $VERSION: patched by hand earlier ($SOURCES)"
    else
      echo "ERROR: $SOURCES matches neither the 0.6.1 original nor a patched file." >&2
      echo "       Restore it with: dart pub cache repair (or delete the package and pub get)." >&2
      exit 1
    fi
    ;;
esac

apple_list_has_adx || { echo "ERROR: the apple x86_64 list in $SOURCES still lacks fiat_p256_adx" >&2; exit 1; }
COUNT="$(grep -c fiat_p256_adx "$SOURCES")"
[ "$COUNT" = 4 ] || { echo "ERROR: expected 4 fiat_p256_adx lines in $SOURCES, found $COUNT" >&2; exit 1; }
echo "webcrypto $VERSION: fiat_p256_adx lines = $COUNT"
