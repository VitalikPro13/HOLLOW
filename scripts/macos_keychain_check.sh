#!/bin/bash
# HOL-SEC-187 signed checks of the macOS keychain move, for a throwaway GitHub macOS
# runner at the release build (release-apple.yml, job macos-keychain-check).
#
#   bash scripts/macos_keychain_check.sh NEW_APP OLD_APP   on a GitHub-hosted runner only
#   bash scripts/macos_keychain_check.sh --dry-run          anywhere: builds the fixtures and
#                                                            the probe, touches no keychain
#
# NEW_APP is the signed, notarized release; OLD_APP the signed 0.13 release. On the runner
# it seeds an identity whose key sits in the login keychain the way 0.13 wrote it, then:
#   1. 0.14 starts with entitlements validated, its seal passes, it moves the key into
#      the data-protection keychain and deletes the login keychain item, and opens
#   1b. the field case: the same key back in the login keychain beside its protected
#      copy; 0.14 deletes the login item (exactly "1 moved, 0 kept") and still opens,
#      so the protected copy survived the delete
#   2. 0.14 again: nothing left to move (no "Keychain move:" line at all), still opens
#   3. 0.13 cannot open it (key missing), and a library planted into 0.13 the HOL-SEC-187
#      way gets errSecMissingEntitlement for the keys group and finds no login item
#   4. 0.14 with one framework swapped for 0.13's, with its Info.plist edited after
#      signing, and with a framework of its own moved outside the bundle: each start
#      ends before the engine (the seal names why, Rust never logs), nothing is
#      deleted; the untouched 0.14 still opens afterwards
# It never runs on a person's Mac: it writes the login keychain and /opt/homebrew/lib.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY=0
if [ "${1:-}" = --dry-run ]; then
  DRY=1
else
  [ $# -eq 2 ] || { echo "usage: $0 NEW_APP OLD_APP | --dry-run" >&2; exit 2; }
  if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    echo "ERROR: this writes the login keychain; it runs only on a GitHub-hosted runner" >&2
    exit 2
  fi
  NEW_APP="$(cd "$1" && pwd -P)"
  OLD_APP="$(cd "$2" && pwd -P)"
fi

# Resolved: the seal logs real paths (/private/var, not /var).
W="$(cd "$(mktemp -d)" && pwd -P)"
STARTED=""
# Stops only the process this script started, by its pid.
cleanup() {
  if [ -n "$STARTED" ]; then kill "$STARTED" 2>/dev/null || true; fi
  rm -rf "$W"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- Fixtures: a keychain-only identity (flags 0x02) and its device file under one key.
cat > "$W/fixture.swift" <<'SWIFT'
import CryptoKit
import Foundation
// fixture OUT_DIR: writes identity.key, identity.device and key.hex (HKEYV1 files).
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let key = SymmetricKey(size: .bits256)
func sealed(_ seed: Curve25519.Signing.PrivateKey) throws -> Data {
  var plain = Data([0x08, 0x01, 0x12, 0x40])
  plain += seed.rawRepresentation + seed.publicKey.rawRepresentation
  let box = try AES.GCM.seal(plain, using: key)
  var file = Data("HKEYV1".utf8)
  file.append(0x02)
  file += Data(count: 16)
  file += Data(box.nonce) + box.ciphertext + box.tag
  return file
}
try sealed(Curve25519.Signing.PrivateKey()).write(to: out.appendingPathComponent("identity.key"))
try sealed(Curve25519.Signing.PrivateKey()).write(to: out.appendingPathComponent("identity.device"))
let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
try hex.write(to: out.appendingPathComponent("key.hex"), atomically: true, encoding: .utf8)
SWIFT
xcrun swiftc -O "$W/fixture.swift" -o "$W/fixture"
mkdir -p "$W/seed"
"$W/fixture" "$W/seed"
expect "the fixture is a keychain-only HKEYV1 identity" \
  '[ "$(head -c 7 "$W/seed/identity.key" | xxd -p)" = 484b4559563102 ] && [ "$(wc -c < "$W/seed/key.hex" | tr -d " ")" = 64 ]'

# --- The planted library: what HOL-SEC-187's attacker loads into 0.13.
cat > "$W/probe.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
static OSStatus ask(int protected_group) {
  CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(q, kSecAttrService, CFSTR("com.hollow.identity"));
  CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
  if (protected_group) {
    CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecAttrAccessGroup, CFSTR("group.com.anonlisten.hollow.keys"));
  }
  CFTypeRef out = NULL;
  OSStatus s = SecItemCopyMatching(q, &out);
  if (out) CFRelease(out);
  CFRelease(q);
  return s;
}
__attribute__((constructor)) static void probe(void) {
  FILE *f = fopen("/tmp/hollow-keychain-probe.txt", "w");
  if (!f) return;
  fprintf(f, "keys=%d login=%d\n", (int)ask(1), (int)ask(0));
  fclose(f);
}
C
clang -dynamiclib "$W/probe.c" -o "$W/probe.dylib" -framework Security -framework CoreFoundation
codesign -f -s - "$W/probe.dylib" 2>/dev/null
expect "the probe library builds" '[ -s "$W/probe.dylib" ]'

if [ $DRY = 1 ]; then
  echo
  echo "$pass passed, $fail failed (dry run: no keychain, no app launched)"
  [ $fail -eq 0 ]
  exit
fi

ROOT="$HOME/Library/Application Support/hollow"
LOG="$ROOT/hollow_debug.log"
SLOT="wrapping_key.$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-16)"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

seed() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
  cp "$W/seed/identity.key" "$W/seed/identity.device" "$ROOT/"
}
login_item() { security find-generic-password -s com.hollow.identity -a "$SLOT" "$LOGIN" >/dev/null 2>&1; }
# Starts APP's executable, waits, records procinfo, stops it. Its log lines go to $W/run.log.
run_app() { # run_app APP SECONDS
  local app="$1" secs="$2" pid start
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  : > "$W/run.log"
  [ -f "$LOG" ] && cp "$LOG" "$W/before.log" || : > "$W/before.log"
  "$app/Contents/MacOS/Hollow" > "$W/app.out" 2>&1 &
  pid=$!
  STARTED="$pid"
  sleep "$secs"
  sudo launchctl procinfo "$pid" > "$W/procinfo.txt" 2>&1 || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  STARTED=""
  # NSLog also writes stderr; the unified log may hold nothing for a process run this way.
  { grep -h "HOLLOW-SEAL" "$W/app.out"
    log show --style compact --start "$start" --predicate 'eventMessage CONTAINS "HOLLOW-SEAL"' 2>/dev/null | grep "HOLLOW-SEAL"
  } > "$W/seal.log" || true
  [ -f "$LOG" ] && diff "$W/before.log" "$LOG" | sed -n 's/^> //p' > "$W/run.log" || true
}

# 1. The first 0.14 start moves the key.
seed
security add-generic-password -s com.hollow.identity -a "$SLOT" -X "$(cat "$W/seed/key.hex")" \
  -T "$NEW_APP" -T "$OLD_APP" "$LOGIN"
expect "(the seeded item is in the login keychain)" login_item
run_app "$NEW_APP" 30
expect "0.14 runs with its entitlements validated" 'grep -q "entitlements validated" "$W/procinfo.txt"'
expect "0.14's seal passes and opens the keychain" 'grep -q "keychain open" "$W/seal.log"'
expect "0.14 moves the key, none kept for later" 'grep -Eq "Keychain move: [1-9][0-9]* moved, 0 kept" "$W/run.log"'
expect "the login keychain item is gone" '! login_item'
expect "0.14 opens the identity" '! grep -q "did not unlock at launch" "$W/run.log"'
grep -h "start check took" "$W/seal.log" | sed 's/^/     U14 /' || true

# 1b. The field case (a Mac where 0.13 kept its login item after an earlier 0.14 start):
# the same key goes back into the login keychain the way stage 1 seeded it, beside the
# protected copy. A file-based delete that reached the protected copy would leave the
# identity unopenable; a delete that missed the login item would leave it, or count it.
security add-generic-password -s com.hollow.identity -a "$SLOT" -X "$(cat "$W/seed/key.hex")" \
  -T "$NEW_APP" -T "$OLD_APP" "$LOGIN"
expect "(the login item is back beside the protected copy)" login_item
run_app "$NEW_APP" 20
expect "0.14 moves exactly that item, none kept" \
  'grep -q "Keychain move: 1 moved, 0 kept for the next start, 0 left alone" "$W/run.log"'
expect "no item logged as kept or left alone" '[ "$(grep -c "Keychain move:" "$W/run.log")" = 1 ]'
expect "the login keychain item is gone again" '! login_item'
expect "0.14 still opens: the protected copy survived the delete" '! grep -q "did not unlock at launch" "$W/run.log"'

# 2. Again: nothing to move (stage 1b's next start), still opens.
run_app "$NEW_APP" 20
expect "a second start moves nothing" '! grep -q "Keychain move:" "$W/run.log"'
expect "and still opens" '! grep -q "did not unlock at launch" "$W/run.log"'

# 3. 0.13 sees nothing, even with a planted library.
run_app "$OLD_APP" 20
expect "0.13 finds no key" 'grep -q "keychain_key_missing" "$W/run.log"'
planted=""
while IFS= read -r name; do
  [ -e "$OLD_APP/Contents/Frameworks/$name" ] && continue
  planted="$name"
  break
done < <(find "$OLD_APP/Contents/Frameworks" -type f -perm +111 -exec otool -l {} \; 2>/dev/null \
  | awk '/cmd LC_LOAD_WEAK_DYLIB/{w=1;next} w && /name @rpath\//{sub(/.*@rpath\//,"");sub(/ \(offset.*/,"");print;w=0}')
if [ -n "$planted" ]; then
  mkdir -p /opt/homebrew/lib
  cp "$W/probe.dylib" "/opt/homebrew/lib/$planted"
  rm -f /tmp/hollow-keychain-probe.txt
  run_app "$OLD_APP" 20
  rm -f "/opt/homebrew/lib/$planted"
  expect "a library planted in 0.13 is refused the keys group" 'grep -q "keys=-34018" /tmp/hollow-keychain-probe.txt'
  expect "and finds no login keychain item" 'grep -q "login=-25300" /tmp/hollow-keychain-probe.txt'
else
  bad "no weak @rpath load in 0.13 to plant into (the probe did not run)"
fi

# 4. A framework swapped for 0.13's: the seal refuses, nothing is deleted.
ditto "$NEW_APP" "$W/swap/Hollow.app"
swapped=""
# hollow_core first: linked at launch (the start check judges it) and the old Rust core
# is the swap that matters most; a framework dlopened later ends the process instead.
for fw in "$W/swap/Hollow.app/Contents/Frameworks/hollow_core.framework" "$W/swap/Hollow.app/Contents/Frameworks/"*.framework; do
  name="$(basename "$fw")"
  [ -d "$OLD_APP/Contents/Frameworks/$name" ] || continue
  rm -rf "$fw"
  ditto "$OLD_APP/Contents/Frameworks/$name" "$fw"
  swapped="$name"
  break
done
expect "(a framework of 0.13 is in the copy: ${swapped:-none})" '[ -n "$swapped" ]'
run_app "$W/swap/Hollow.app" 20
expect "the swapped copy's seal names the stranger" 'grep -q "not sealed: Contents/Frameworks/$swapped" "$W/seal.log"'
# The refusal shows its alert and waits for Quit; the engine, and with it Rust, never starts.
stopped() { grep -q "stopping before the app starts" "$W/seal.log" && ! grep -q "keychain open" "$W/seal.log" && [ ! -s "$W/run.log" ]; }
expect "and ends before the engine starts" stopped

ditto "$NEW_APP" "$W/plist/Hollow.app"
/usr/libexec/PlistBuddy -c "Set :HollowSealedImages:0 0000000000000000000000000000000000000000 Contents/x" \
  "$W/plist/Hollow.app/Contents/Info.plist"
run_app "$W/plist/Hollow.app" 20
expect "an Info.plist edited after signing ends the start" 'grep -q "Info.plist changed after signing" "$W/seal.log" && stopped'

ditto "$NEW_APP" "$W/outside/Hollow.app"
mkdir -p "$W/elsewhere"
mv "$W/outside/Hollow.app/Contents/Frameworks/hollow_core.framework" "$W/elsewhere/"
ln -s "$W/elsewhere/hollow_core.framework" "$W/outside/Hollow.app/Contents/Frameworks/hollow_core.framework"
run_app "$W/outside/Hollow.app" 20
expect "this team's code loaded from outside the bundle ends the start" \
  'grep -q "code of this team outside the bundle: $W/elsewhere/hollow_core.framework" "$W/seal.log" && stopped'
run_app "$NEW_APP" 20
expect "the untouched 0.14 still opens: nothing was deleted" '! grep -q "did not unlock at launch" "$W/run.log"'

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
