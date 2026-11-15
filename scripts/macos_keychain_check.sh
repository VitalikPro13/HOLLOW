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
#   1. 0.14 starts with entitlements validated, its seal passes, it copies the key into
#      the data-protection keychain, and opens. macOS lets only the app that made a
#      login item delete it (field report: errSecInvalidOwnerEdit). The seeded item is
#      made by a helper of this script (SecItemAdd, an access list trusting both apps),
#      so 0.14 may read it and may not delete it: the field case. The item MUST stay,
#      0.14 MUST log the re-key, and the key it holds MUST open neither identity file;
#      an item 0.14 could delete means the field case was not reproduced, a FAIL
#   1b. a downgrade: new files under a new key, written to the login item again (what
#      a phrase restore in 0.13 does); 0.14 re-keys off that key too and still opens
#   2. 0.14 again: no "Keychain move:" and no "Keychain re-key" line at all, still opens
#   3. 0.13 cannot open it (key missing), and a library planted into 0.13 the HOL-SEC-187
#      way gets errSecMissingEntitlement for the keys group and reads the login item
#      that stayed, whose key opens nothing
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
// fixture opens KEY_HEX FILE: exits 0 when the key opens the HKEYV1 file, else 1.
if CommandLine.arguments[1] == "opens" {
  let hex = Array(CommandLine.arguments[2].utf8)
  let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16) }
  let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
  guard bytes.count == 32, file.count > 35 + 16,
    let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: file[23..<35]), ciphertext: file[35..<(file.count - 16)], tag: file[(file.count - 16)...]),
    (try? AES.GCM.open(box, using: SymmetricKey(data: bytes))) != nil
  else { exit(1) }
  exit(0)
}
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
mkdir -p "$W/seed" "$W/seed2"
"$W/fixture" "$W/seed"
"$W/fixture" "$W/seed2"
expect "the fixture is a keychain-only HKEYV1 identity" \
  '[ "$(head -c 7 "$W/seed/identity.key" | xxd -p)" = 484b4559563102 ] && [ "$(wc -c < "$W/seed/key.hex" | tr -d " ")" = 64 ]'
# opens KEY_HEX FILE
opens() { "$W/fixture" opens "$1" "$2"; }
expect "the opener knows its key from another" \
  'opens "$(cat "$W/seed/key.hex")" "$W/seed/identity.key" && ! opens "$(cat "$W/seed2/key.hex")" "$W/seed/identity.key"'

# --- The planted library: what HOL-SEC-187's attacker loads into 0.13.
cat > "$W/probe.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
static char found[65];
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
  if (s == 0 && out && CFGetTypeID(out) == CFDataGetTypeID() && CFDataGetLength(out) == 32) {
    for (int i = 0; i < 32; i++) sprintf(found + 2 * i, "%02x", CFDataGetBytePtr(out)[i]);
  }
  if (out) CFRelease(out);
  CFRelease(q);
  return s;
}
__attribute__((constructor)) static void probe(void) {
  FILE *f = fopen("/tmp/hollow-keychain-probe.txt", "w");
  if (!f) return;
  int keys = (int)ask(1);
  int login = (int)ask(0);
  fprintf(f, "keys=%d login=%d value=%s\n", keys, login, found);
  fclose(f);
}
C
clang -dynamiclib "$W/probe.c" -o "$W/probe.dylib" -framework Security -framework CoreFoundation
codesign -f -s - "$W/probe.dylib" 2>/dev/null
expect "the probe library builds" '[ -s "$W/probe.dylib" ]'

# --- The maker of the seeded login item: another program, as 0.13 was to 0.14.
cat > "$W/maker.swift" <<'SWIFT'
import Foundation
import Security
// maker add SERVICE ACCOUNT KEY_HEX APP...: adds a file-based login keychain item whose
//   access list trusts this program and each APP to read it; this program is its maker.
// maker delete SERVICE ACCOUNT: deletes it (only its maker may).
let a = CommandLine.arguments
let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: a[2], kSecAttrAccount: a[3],
                             kSecUseDataProtectionKeychain: false]
if a[1] == "delete" {
  let s = SecItemDelete(base as CFDictionary)
  print("delete \(s)")
  exit(s == errSecSuccess || s == errSecItemNotFound ? 0 : 1)
}
let hex = Array(a[4].utf8)
let key = Data(stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16) })
var apps: [SecTrustedApplication] = []
for path in [CommandLine.arguments[0]] + a.dropFirst(5) {
  var app: SecTrustedApplication?
  guard SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app else { print("no app \(path)"); exit(1) }
  apps.append(app)
}
var access: SecAccess?
guard SecAccessCreate("Hollow" as CFString, apps as CFArray, &access) == errSecSuccess, let access else { exit(1) }
var add = base
add[kSecValueData] = key
add[kSecAttrAccess] = access
let s = SecItemAdd(add as CFDictionary, nil)
print("add \(s)")
exit(s == errSecSuccess && key.count == 32 ? 0 : 1)
SWIFT
xcrun swiftc -O -suppress-warnings "$W/maker.swift" -o "$W/maker"
codesign -f -s - "$W/maker" 2>/dev/null
expect "the item maker builds" '[ -x "$W/maker" ]'

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

seed() { # seed DIR
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
  cp "$1/identity.key" "$1/identity.device" "$ROOT/"
}
# The key a login item would hand an old build opens neither identity file now.
inert() { # inert KEY_HEX
  ! opens "$1" "$ROOT/identity.key" && ! opens "$1" "$ROOT/identity.device"
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

# 1. The first 0.14 start copies the key and re-keys off the login item it may not delete.
seed "$W/seed"
"$W/maker" add com.hollow.identity "$SLOT" "$(cat "$W/seed/key.hex")" "$NEW_APP" "$OLD_APP"
expect "(the seeded item is in the login keychain)" login_item
run_app "$NEW_APP" 30
expect "0.14 runs with its entitlements validated" 'grep -q "entitlements validated" "$W/procinfo.txt"'
expect "0.14's seal passes and opens the keychain" 'grep -q "keychain open" "$W/seal.log"'
expect "0.14 copies the key and may not delete the item (the field case; else not reproduced)" \
  'grep -q "Keychain move: 0 moved, 0 kept for the next start, 0 left alone, 1 stay in the login keychain" "$W/run.log"'
REKEYED="Keychain re-key: this identity now opens only with a new key in the protected keychain"
expect "the login item stays (else the field case was not reproduced)" login_item
expect "0.14 re-keyed off it" 'grep -q "$REKEYED; 1 old login item(s) stay but no longer open it" "$W/run.log"'
expect "the login item's key opens neither file" 'inert "$(cat "$W/seed/key.hex")"'
expect "0.14 opens the identity" '! grep -q "did not unlock at launch" "$W/run.log"'
grep -h "start check took" "$W/seal.log" | sed 's/^/     U14 /' || true

# 1b. A downgrade: 0.13 restored by phrase writes new files under a new key and that
# key to the login item (here the item is replaced the way stage 1 seeded it). The next
# 0.14 start re-keys off it too.
seed "$W/seed2"
"$W/maker" delete com.hollow.identity "$SLOT"
"$W/maker" add com.hollow.identity "$SLOT" "$(cat "$W/seed2/key.hex")" "$NEW_APP" "$OLD_APP"
expect "(the login item holds the downgrade's key)" login_item
run_app "$NEW_APP" 20
expect "the downgrade's login item stays" login_item
expect "0.14 re-keys off the downgrade's key" 'grep -q "$REKEYED; 1 old login item(s) stay but no longer open it" "$W/run.log"'
expect "the downgrade's key opens neither file" 'inert "$(cat "$W/seed2/key.hex")"'
expect "0.14 still opens" '! grep -q "did not unlock at launch" "$W/run.log"'

# 2. Again: nothing to move or re-key (stage 1b's next start), still opens.
run_app "$NEW_APP" 20
expect "a second start moves nothing" '! grep -q "Keychain move:" "$W/run.log"'
expect "and re-keys nothing" '! grep -q "Keychain re-key" "$W/run.log"'
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
  probe_key="$(sed -n 's/.*value=\([0-9a-f]*\).*/\1/p' /tmp/hollow-keychain-probe.txt)"
  expect "and reads the login item that stayed, whose key opens nothing" \
    'grep -q "login=0 " /tmp/hollow-keychain-probe.txt && [ ${#probe_key} = 64 ] && inert "$probe_key"'
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

"$W/maker" delete com.hollow.identity "$SLOT" >/dev/null || true

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
