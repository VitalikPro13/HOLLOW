#!/bin/bash
# Tests for macos/Runner/BundleSeal.swift (HOL-SEC-187) on a scratch bundle signed
# ad hoc: the list bound to the signature through Info.plist, the start check that
# ends the process before the engine would start, and the check of libraries loaded
# later. An ad-hoc host carries no team, so the keychain itself is never reached;
# the signed release run covers that half (scripts/macos_keychain_check.sh).
#
#   bash scripts/macos_bundle_seal_test.sh
set -u
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
SRC="$(cd "$(dirname "$0")/.." && pwd)/macos/Runner/BundleSeal.swift"
REFUSED=78
cd "$W"
printf 'int own_fn(void) { return 42; }\n' > own.c
# The stand-in for an old release's library: same name and symbol, other code.
printf 'int own_fn(void) { return 666; }\n' > old.c
# When asked, writes another file's tail over a loaded library in place before main
# runs: what an attacker does to put a sealed signature over old code after dyld
# registered the old one.
cat > other.c <<'C'
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
int other_fn(void) { return 7; }
__attribute__((constructor)) static void tamper(void) {
  const char *to = getenv("SEAL_TEST_TAMPER"), *from = getenv("SEAL_TEST_FROM"), *at = getenv("SEAL_TEST_AT");
  if (!to || !from || !at) return;
  int in = open(from, O_RDONLY), out = open(to, O_WRONLY);
  if (in < 0 || out < 0) return;
  char buf[65536];
  ssize_t n = pread(in, buf, sizeof buf, atol(at));
  if (n > 0) pwrite(out, buf, (size_t)n, atol(at));
  close(in);
  close(out);
}
C
app="$W/T.app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$W/old"
F="$app/Contents/Frameworks"
clang -dynamiclib own.c -o "$F/libown.dylib" -install_name @rpath/libown.dylib
clang -dynamiclib old.c -o "$W/old/libown.dylib" -install_name @rpath/libown.dylib
clang -dynamiclib other.c -o "$F/libother.dylib" -install_name @rpath/libother.dylib
codesign -f -s - "$F/libown.dylib" "$F/libother.dylib" "$W/old/libown.dylib" 2>/dev/null
cp "$F/libown.dylib" "$W/own.dylib"
cat > main.swift <<'SWIFT'
import Foundation
@_silgen_name("own_fn") func own_fn() -> Int32
@_silgen_name("other_fn") func other_fn() -> Int32
BundleSeal.enforceAtStart()
// Stands for the Flutter engine, which the app creates right after the check.
print("ENGINE STARTED")
_ = own_fn() + other_fn()
let args = CommandLine.arguments
// --pages FILE OFFSET SIZE: libown's code in memory against its own directory and
// against the directory of FILE's signature (another build of it).
if args.count == 5, args[1] == "--pages", let at = Int(args[3]), let size = Int(args[4]) {
  let image = (0..<_dyld_image_count()).first { String(cString: _dyld_get_image_name($0)).hasSuffix("/libown.dylib") }!
  let header = _dyld_get_image_header(image)!
  let file = try! Data(contentsOf: URL(fileURLWithPath: args[2])).subdata(in: at..<(at + size))
  let other = file.withUnsafeBytes { BundleSeal.directories(in: $0.baseAddress!, size: size) }
  let own = BundleSeal.codeDirectories(header)
  print("PAGES own=\(own.allSatisfy { BundleSeal.pagesMatch(header, $0) }) other=\(other.contains { BundleSeal.pagesMatch(header, $0) })")
  exit(0)
}
if args.count > 1 { _ = dlopen(args[1], RTLD_NOW); print("LATE LOAD SURVIVED") }
print("HOST DONE")
SWIFT
xcrun swiftc -O main.swift "$SRC" -o "$app/Contents/MacOS/host" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -L "$F" -lown -lother
hash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
write_plist() { # ENTRY... (no signing)
  { echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>host</string><key>CFBundleIdentifier</key><string>t.seal</string><key>HollowSealedImages</key><array>'
    for e in "$@"; do echo "<string>$e</string>"; done
    echo '</array></dict></plist>'; } > "$app/Contents/Info.plist"
}
seal() { write_plist "$@"; codesign -f -s - "$app/Contents/MacOS/host" 2>/dev/null; }
own="$(hash_of "$F/libown.dylib")"
other="$(hash_of "$F/libother.dylib")"
old="$(hash_of "$W/old/libown.dylib")"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (rc=$rc)"; echo "$out" | sed 's/^/       /'; fi; }
run() { out="$("$app/Contents/MacOS/host" "$@" 2>&1)"; rc=$?; }
stopped() { [ $rc -eq $REFUSED ] && ! grep -q "ENGINE STARTED" <<<"$out"; }

seal "$own Contents/Frameworks/libown.dylib" "$other Contents/Frameworks/libother.dylib"
run
check "a sealed bundle passes the start check" '[ $rc -eq 0 ] && grep -q "every library is sealed" <<<"$out" && grep -q "ENGINE STARTED" <<<"$out"'
run "$F/libother.dylib"
check "a sealed library loaded later is accepted" '[ $rc -eq 0 ] && grep -q "LATE LOAD SURVIVED" <<<"$out"'

seal "$own Contents/Frameworks/libown.dylib"
run "$F/libother.dylib"
check "an unsealed library loaded at start ends the process before the engine starts" 'stopped && grep -q "not sealed: Contents/Frameworks/libother.dylib" <<<"$out"'

seal "$own Contents/Frameworks/libown.dylib" "$other Contents/Frameworks/libother.dylib"
cp "$W/old/libown.dylib" "$F/libown.dylib"
run
check "a swapped library ends the process before the engine starts" 'stopped && grep -q "not sealed: Contents/Frameworks/libown.dylib" <<<"$out"'

# The reviewer's case: the swap plus a list naming the old library, the main
# executable not signed again (codesign --verify calls Info.plist invalid).
write_plist "$old Contents/Frameworks/libown.dylib" "$other Contents/Frameworks/libother.dylib"
run
check "an Info.plist edited after signing keeps the process from starting" 'stopped && grep -q "Info.plist changed after signing" <<<"$out"'
cp "$W/own.dylib" "$F/libown.dylib"

# A late load the list does not name: sealed at start without libother's entry is
# covered above; here libother is sealed and a stranger arrives later.
seal "$own Contents/Frameworks/libown.dylib" "$other Contents/Frameworks/libother.dylib"
cp "$W/old/libown.dylib" "$W/stranger.dylib"; mkdir -p "$F/late"; cp "$W/old/libown.dylib" "$F/late/libstranger.dylib"
run "$F/late/libstranger.dylib"
check "an unsealed library loaded later ends the process" '[ $rc -ne 0 ] && ! grep -q "LATE LOAD SURVIVED" <<<"$out" && grep -q "loaded after start" <<<"$out"'

# The old library loads; libother's constructor then writes the sealed library's
# signature over it in place. The directory in memory now carries the sealed hash,
# the code in memory is still the old code.
sig_of() { otool -l "$1" | awk '/LC_CODE_SIGNATURE/ {f=1} f && /dataoff/ {print $2; exit}'; }
cp "$W/old/libown.dylib" "$F/libown.dylib"
at="$(sig_of "$W/own.dylib")"
same=0; [ "$at" = "$(sig_of "$F/libown.dylib")" ] && [ "$(stat -f %z "$W/own.dylib")" = "$(stat -f %z "$F/libown.dylib")" ] && same=1
out="$(SEAL_TEST_TAMPER="$F/libown.dylib" SEAL_TEST_FROM="$W/own.dylib" SEAL_TEST_AT="$at" "$app/Contents/MacOS/host" 2>&1)"; rc=$?
# The kernel itself kills this on macOS 26; the page check below is the layer that
# does not depend on it.
check "a sealed signature written over old code after loading never reaches the engine" '[ $same -eq 1 ] && [ $rc -ne 0 ] && ! grep -q "ENGINE STARTED" <<<"$out"'
cp "$W/own.dylib" "$F/libown.dylib"
out="$("$app/Contents/MacOS/host" --pages "$W/old/libown.dylib" "$at" "$(( $(stat -f %z "$W/own.dylib") - at ))" 2>&1)"; rc=$?
check "old code under the sealed directory fails the page check" 'grep -q "PAGES own=true other=false" <<<"$out"'


# No list at all: what an ad-hoc development build looks like. It starts, keychain shut.
{ echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>host</string><key>CFBundleIdentifier</key><string>t.seal</string></dict></plist>'; } > "$app/Contents/Info.plist"
codesign -f -s - "$app/Contents/MacOS/host" 2>/dev/null
run
check "a development build without a list still starts" '[ $rc -eq 0 ] && grep -q "development build" <<<"$out" && grep -q "ENGINE STARTED" <<<"$out"'

# The same, claiming a keychain group: a release with its list stripped.
cat > "$W/groups.entitlements" <<'X'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>group.t.seal.keys</string></array></dict></plist>
X
codesign -f -s - --entitlements "$W/groups.entitlements" "$app/Contents/MacOS/host" 2>/dev/null
run
check "a build claiming keychain groups without a bound list ends the process" 'stopped && grep -q "no sealed image list bound to the signature" <<<"$out"'
echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
