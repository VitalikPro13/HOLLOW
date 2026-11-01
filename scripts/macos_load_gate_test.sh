#!/bin/bash
# Tests for scripts/macos_load_gate.sh (HOL-SEC-187) on scratch bundles built with clang.
#
#   bash scripts/macos_load_gate_test.sh
#
# Needs a Mac with the Xcode command line tools; signs only ad-hoc, never with a keychain
# (the test profiles are signed with a throwaway openssl key in the scratch folder).
set -euo pipefail

GATE="${GATE:-$(cd "$(dirname "$0")" && pwd)/macos_load_gate.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# A fail must come from the gate naming a file (a FAIL line), never from a crash or usage error.
expect() { # expect pass|fail NAME CMD...
  local want="$1" name="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if { [ "$want" = pass ] && [ $rc -eq 0 ]; } \
     || { [ "$want" = fail ] && [ $rc -ne 0 ] && printf '%s\n' "$out" | grep '^FAIL ' >/dev/null; }; then
    ok "$name"
  else
    bad "$name (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

rpaths() { otool -arch all -l "$1" | awk '/^ +cmd /{c=$2} c=="LC_RPATH" && /^ +path /{print $2}' | sort -u; }

printf 'int own_fn(void) { return 42; }\n' > "$W/own.c"
printf 'extern int own_fn(void);\nint main(void) { return own_fn() == 42 ? 0 : 1; }\n' > "$W/main.c"
printf 'int x_fn(void) { return 1; }\n' > "$W/x.c"

# A clean bundle: an executable that finds its one dylib through @executable_path/../Frameworks.
new_app() { # new_app DIR [extra clang flags for the executable...]
  local app="$1"
  shift
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  clang -dynamiclib "$W/own.c" -o "$app/Contents/Frameworks/libown.dylib" \
    -install_name @rpath/libown.dylib -Wl,-rpath,@loader_path
  clang "$W/main.c" -o "$app/Contents/MacOS/host" "$app/Contents/Frameworks/libown.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks "$@"
}

# 1. The clean bundle passes, and /usr/lib/swift is an allowed rpath.
new_app "$W/clean.app" -Wl,-rpath,/usr/lib/swift
expect pass "clean bundle passes check" bash "$GATE" check "$W/clean.app"

# 2. The mdk shape: an absolute rpath into a user-writable directory plus a weak @rpath load
#    of a library the bundle does not ship. check fails; strip removes exactly the bad rpaths.
clang -dynamiclib "$W/x.c" -o "$W/libmissing.dylib" -install_name @rpath/libmissing.dylib
new_app "$W/mdk.app"
clang -dynamiclib "$W/own.c" -o "$W/mdk.app/Contents/Frameworks/libown.dylib" \
  -install_name @rpath/libown.dylib -Wl,-weak_library,"$W/libmissing.dylib" \
  -Wl,-rpath,@loader_path -Wl,-rpath,/opt/homebrew/lib -Wl,-rpath,/usr/local/lib \
  -Wl,-rpath,/Users/runner/work/sdk/lib
expect fail "absolute rpaths fail check" bash "$GATE" check "$W/mdk.app"
expect pass "strip succeeds" bash "$GATE" strip "$W/mdk.app"
expect pass "check passes after strip" bash "$GATE" check "$W/mdk.app"
if [ "$(rpaths "$W/mdk.app/Contents/Frameworks/libown.dylib")" = "@loader_path" ]; then
  ok "strip kept @loader_path and removed the three absolute rpaths"
else
  bad "rpaths after strip: $(rpaths "$W/mdk.app/Contents/Frameworks/libown.dylib" | tr '\n' ' ')"
fi
codesign -f -s - "$W/mdk.app/Contents/Frameworks/libown.dylib" 2>/dev/null
codesign -f -s - "$W/mdk.app/Contents/MacOS/host" 2>/dev/null
expect pass "a stripped, re-signed bundle still runs" "$W/mdk.app/Contents/MacOS/host"

# 3. The main executable's toolchain rpath (Xcode adds one) is stripped too.
new_app "$W/xcode.app" -Wl,-rpath,/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx
expect fail "toolchain rpath on the executable fails check" bash "$GATE" check "$W/xcode.app"
expect pass "strip + check clears it" bash -c "bash '$GATE' strip '$W/xcode.app' && bash '$GATE' check '$W/xcode.app'"

# 4. An absolute weak load outside /usr/lib and /System: strip cannot fix it, so both fail.
clang -dynamiclib "$W/x.c" -o "$W/libabs.dylib" -install_name /opt/homebrew/lib/libabs.dylib
new_app "$W/abs.app" -Wl,-weak_library,"$W/libabs.dylib"
expect fail "absolute weak load fails check" bash "$GATE" check "$W/abs.app"
expect fail "absolute weak load fails strip" bash "$GATE" strip "$W/abs.app"

# 5. A load that only looks like /usr/lib.
clang -dynamiclib "$W/x.c" -o "$W/libdots.dylib" -install_name /usr/lib/../local/lib/libdots.dylib
new_app "$W/dots.app" -Wl,-weak_library,"$W/libdots.dylib"
expect fail "/usr/lib/../local/lib load fails check" bash "$GATE" check "$W/dots.app"

# 6. A bare relative load name and an @rpath name that climbs out.
clang -dynamiclib "$W/x.c" -o "$W/librel.dylib" -install_name librel.dylib
new_app "$W/rel.app" -Wl,-weak_library,"$W/librel.dylib"
expect fail "bare relative load fails check" bash "$GATE" check "$W/rel.app"
clang -dynamiclib "$W/x.c" -o "$W/libup.dylib" -install_name @rpath/../../../../lib/libup.dylib
new_app "$W/up.app" -Wl,-weak_library,"$W/libup.dylib"
expect fail "@rpath/.. load fails check" bash "$GATE" check "$W/up.app"

# 7. Relative rpaths that climb out of the bundle are stripped like absolute ones.
new_app "$W/climb.app" -Wl,-rpath,@executable_path/../../.. -Wl,-rpath,@loader_path/../../../lib
expect fail "climbing rpaths fail check" bash "$GATE" check "$W/climb.app"
expect pass "strip + check clears them" bash -c "bash '$GATE' strip '$W/climb.app' && bash '$GATE' check '$W/climb.app'"
if [ "$(rpaths "$W/climb.app/Contents/MacOS/host")" = "@executable_path/../Frameworks" ]; then
  ok "strip kept the in-bundle rpath"
else
  bad "rpaths after strip: $(rpaths "$W/climb.app/Contents/MacOS/host" | tr '\n' ' ')"
fi

# 8. LC_DYLD_ENVIRONMENT.
new_app "$W/env.app" -Wl,-dyld_env,DYLD_LIBRARY_PATH=/opt/homebrew/lib
expect fail "LC_DYLD_ENVIRONMENT fails check" bash "$GATE" check "$W/env.app"

# 9. Found by magic bytes: no extension, no exec bit, under Resources.
new_app "$W/hidden.app"
clang -dynamiclib "$W/x.c" -o "$W/hidden.app/Contents/Resources/data" -Wl,-rpath,/opt/homebrew/lib
chmod 644 "$W/hidden.app/Contents/Resources/data"
expect fail "a Mach-O named like data fails check" bash "$GATE" check "$W/hidden.app"
expect pass "strip + check clears it" bash -c "bash '$GATE' strip '$W/hidden.app' && bash '$GATE' check '$W/hidden.app'"

# 10. A fat file whose slices disagree (install_name_tool refuses such a file whole).
new_app "$W/mixed.app"
clang -arch arm64 -dynamiclib "$W/x.c" -o "$W/s_arm.dylib" -Wl,-rpath,/opt/homebrew/lib -Wl,-rpath,@loader_path
clang -arch x86_64 -dynamiclib "$W/x.c" -o "$W/s_x86.dylib" -Wl,-rpath,@loader_path
lipo -create "$W/s_arm.dylib" "$W/s_x86.dylib" -output "$W/mixed.app/Contents/Frameworks/libmixed.dylib"
expect fail "rpath in one slice fails check" bash "$GATE" check "$W/mixed.app"
expect pass "strip + check clears it" bash -c "bash '$GATE' strip '$W/mixed.app' && bash '$GATE' check '$W/mixed.app'"
if [ "$(lipo -archs "$W/mixed.app/Contents/Frameworks/libmixed.dylib")" = "x86_64 arm64" ] \
   && [ "$(rpaths "$W/mixed.app/Contents/Frameworks/libmixed.dylib")" = "@loader_path" ]; then
  ok "both slices kept, only the bad rpath gone"
else
  bad "mixed file after strip: $(lipo -archs "$W/mixed.app/Contents/Frameworks/libmixed.dylib")"
fi

# 11. A fat magic the gate cannot classify (a Java class file) stops it; plain data does not.
new_app "$W/java.app"
head -c 64 /dev/urandom | LC_ALL=C tr -d '\312\376\317\316\276' > "$W/java.app/Contents/Resources/blob.bin"
printf 'not a binary' > "$W/java.app/Contents/Resources/notes.txt"
expect pass "data files are not Mach-O" bash "$GATE" check "$W/java.app"
printf '\xca\xfe\xba\xbe\x00\x00\x00\x34rest-of-a-class-file' > "$W/java.app/Contents/Resources/A.class"
out="$(bash "$GATE" check "$W/java.app" 2>&1 || true)"
if printf '%s\n' "$out" | grep -F "names 52 slices" >/dev/null; then
  ok "an unclassifiable fat magic stops the gate"
else
  bad "a Java class file passed the gate"
fi

# 12. iOS layout: an app extension's own @executable_path/../../Frameworks stays inside.
mkdir -p "$W/ios.app/Frameworks" "$W/ios.app/PlugIns/Ext.appex"
clang -dynamiclib "$W/own.c" -o "$W/ios.app/Frameworks/libown.dylib" -install_name @rpath/libown.dylib
clang "$W/main.c" -o "$W/ios.app/Runner" "$W/ios.app/Frameworks/libown.dylib" -Wl,-rpath,@executable_path/Frameworks
clang "$W/main.c" -o "$W/ios.app/PlugIns/Ext.appex/Ext" "$W/ios.app/Frameworks/libown.dylib" \
  -Wl,-rpath,@executable_path/../../Frameworks
expect pass "extension rpath relative to its own executable passes" bash "$GATE" check "$W/ios.app"
# The same rpath in a library loaded by the main executable climbs out of the bundle.
clang -dynamiclib "$W/x.c" -o "$W/ios.app/Frameworks/libx.dylib" -Wl,-rpath,@executable_path/../Frameworks
expect fail "a library's @executable_path rpath must stay inside for every executable" bash "$GATE" check "$W/ios.app"

# 13. signed: an ad-hoc bundle has no team, and DLV on an executable is refused.
new_app "$W/adhoc.app"
codesign -f -s - "$W/adhoc.app/Contents/Frameworks/libown.dylib" 2>/dev/null
codesign -f -s - "$W/adhoc.app/Contents/MacOS/host" 2>/dev/null
expect fail "signed refuses a bundle without our team" bash "$GATE" signed "$W/adhoc.app" ABCDE12345
cat > "$W/dlv.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
EOF
codesign -f -s - --entitlements "$W/dlv.plist" "$W/adhoc.app/Contents/MacOS/host" 2>/dev/null
out="$(bash "$GATE" signed "$W/adhoc.app" ABCDE12345 2>&1 || true)"
if printf '%s\n' "$out" | grep -F "disable library validation" >/dev/null; then
  ok "signed names an executable that disables library validation"
else
  bad "signed did not flag disable-library-validation"
  printf '%s\n' "$out" | sed 's/^/       /'
fi
if printf '%s\n' "$(bash "$GATE" signed "$W/adhoc.app" ABCDE12345 2>&1 || true)" | grep -F "does not verify" >/dev/null; then
  bad "a freshly signed bundle reported a signature that does not verify"
else
  ok "a freshly signed bundle verifies"
fi

# 14. Absolute loads: /System/Library is the OS, the rest of /System is not (Data is the
#     user's volume under another name).
new_app "$W/sys.app" -framework CoreFoundation
expect pass "a /System/Library framework load passes" bash "$GATE" check "$W/sys.app"
clang -dynamiclib "$W/x.c" -o "$W/libdata.dylib" -install_name /System/Volumes/Data/opt/homebrew/lib/libdata.dylib
new_app "$W/data.app" -Wl,-weak_library,"$W/libdata.dylib"
expect fail "a /System/Volumes/Data load fails check" bash "$GATE" check "$W/data.app"
clang -dynamiclib "$W/x.c" -o "$W/libsysdots.dylib" -install_name /System/Library/../../usr/lib/libsysdots.dylib
new_app "$W/sysdots.app" -Wl,-weak_library,"$W/libsysdots.dylib"
expect fail "a /System/Library/.. load fails check" bash "$GATE" check "$W/sysdots.app"

# 15. Symlinks: the @rpath load is satisfied by a link that points out of the bundle.
mkdir -p "$W/planted"
new_app "$W/link.app"
mv "$W/link.app/Contents/Frameworks/libown.dylib" "$W/planted/libown.dylib"
ln -s "$W/planted/libown.dylib" "$W/link.app/Contents/Frameworks/libown.dylib"
expect pass "(the outward link really loads)" "$W/link.app/Contents/MacOS/host"
expect fail "an absolute symlink out of the bundle fails check" bash "$GATE" check "$W/link.app"
expect fail "and strip cannot fix it" bash "$GATE" strip "$W/link.app"
rm "$W/link.app/Contents/Frameworks/libown.dylib"
ln -s ../../../planted/libown.dylib "$W/link.app/Contents/Frameworks/libown.dylib"
expect pass "(the relative outward link really loads)" "$W/link.app/Contents/MacOS/host"
expect fail "a relative symlink climbing out fails check" bash "$GATE" check "$W/link.app"
# A framework's usual links stay inside; a .. after a named part is refused even when its
# text lands inside, since the named part may itself be a link.
new_app "$W/fw.app"
fw="$W/fw.app/Contents/Frameworks/Foo.framework"
mkdir -p "$fw/Versions/A/Resources"
cp "$W/fw.app/Contents/Frameworks/libown.dylib" "$fw/Versions/A/Foo"
ln -s A "$fw/Versions/Current"
ln -s Versions/Current/Foo "$fw/Foo"
ln -s Versions/Current/Resources "$fw/Resources"
ln -s ../.. "$W/fw.app/Contents/MacOS/up"
expect pass "framework links and a leading .. inside the bundle pass" bash "$GATE" check "$W/fw.app"
ln -s Versions/../Versions/A "$fw/Mid"
expect fail "a symlink with .. after a named part fails check" bash "$GATE" check "$W/fw.app"
rm "$fw/Mid"
mkdir "$fw/Versions/A/n"
ln -s "A/n"$'\n'"/../../../../../../../planted" "$fw/Versions/Nl"
expect fail "a symlink whose target hides a .. after a newline fails check" bash "$GATE" check "$W/fw.app"

# 16. The same for @-paths: @loader_path/sub/../.. reads as inside but is refused.
new_app "$W/mid.app"
clang -dynamiclib "$W/x.c" -o "$W/mid.app/Contents/Frameworks/libmid.dylib" -Wl,-rpath,@loader_path/sub/../..
expect fail "an @-path with .. after a named part fails check" bash "$GATE" check "$W/mid.app"
expect pass "strip + check clears it" bash -c "bash '$GATE' strip '$W/mid.app' && bash '$GATE' check '$W/mid.app'"

# 17. signed: a Mach-O edited after signing (strip ran after the sign, or the sign skipped it).
new_app "$W/stale.app"
clang -dynamiclib "$W/own.c" -o "$W/stale.app/Contents/Frameworks/libown.dylib" \
  -install_name @rpath/libown.dylib -Wl,-rpath,@loader_path -Wl,-rpath,/opt/homebrew/lib
# Every slice is verified, not only this Mac's: here only the x86_64 one goes stale.
clang -arch arm64 -dynamiclib "$W/x.c" -o "$W/f_arm.dylib"
clang -arch x86_64 -dynamiclib "$W/x.c" -o "$W/f_x86.dylib" -Wl,-rpath,/opt/homebrew/lib
lipo -create "$W/f_arm.dylib" "$W/f_x86.dylib" -output "$W/stale.app/Contents/Frameworks/libfat.dylib"
for f in Frameworks/libown.dylib Frameworks/libfat.dylib MacOS/host; do
  codesign -f -s - "$W/stale.app/Contents/$f" 2>/dev/null
done
bash "$GATE" strip "$W/stale.app" >/dev/null
out="$(bash "$GATE" signed "$W/stale.app" ABCDE12345 2>&1 || true)"
if printf '%s\n' "$out" | grep -E "^FAIL Contents/Frameworks/libown.dylib: its signature does not verify" >/dev/null \
   && printf '%s\n' "$out" | grep -E "^FAIL Contents/Frameworks/libfat.dylib: its signature does not verify" >/dev/null \
   && ! printf '%s\n' "$out" | grep -E "^FAIL Contents/MacOS/host: its signature" >/dev/null; then
  ok "signed names the Mach-O whose signature no longer verifies"
else
  bad "signed did not flag the stale signature"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# 18. HOL-SEC-187 (signed): the Developer ID profile, the entitlements, the sealed image
#     list and the Flutter engine. Ad-hoc bundles carry no team, so each case asserts the
#     one FAIL line it is about; the profiles are signed with a throwaway openssl key.
T=ABCDE12345
KEYS=group.com.anonlisten.hollow.keys
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/pk.pem" -out "$W/pc.pem" -days 2 -subj "/CN=gate-test" 2>/dev/null
make_profile() { # make_profile OUT TEAM ALLDEVICES EXPIRES APPID GROUP...
  local out="$1" team="$2" all="$3" expires="$4" appid="$5" g groups=""
  shift 5
  for g in "$@"; do groups="$groups<string>$g</string>"; done
  cat > "$W/profile.xml" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>$team</string></array>
<key>Platform</key><array><string>OSX</string></array>
$([ "$all" = true ] && echo '<key>ProvisionsAllDevices</key><true/>')
<key>ExpirationDate</key><date>$expires</date>
<key>Entitlements</key><dict>
<key>com.apple.application-identifier</key><string>$appid</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>com.apple.security.application-groups</key><array>$groups</array>
</dict>
<key>DeveloperCertificates</key><array/>
</dict></plist>
PLIST
  openssl smime -sign -signer "$W/pc.pem" -inkey "$W/pk.pem" -in "$W/profile.xml" -outform der -nodetach -binary -out "$out"
}
cat > "$W/ship.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$T.com.anonlisten.hollow</string>
<key>com.apple.developer.team-identifier</key><string>$T</string>
<key>com.apple.security.application-groups</key><array><string>$KEYS</string></array>
</dict></plist>
PLIST
# A shipped-shape bundle: nested code signed, sealed, the profile in, then the host.
new_shipped() { # new_shipped APP [PROFILE]
  local app="$1"
  new_app "$app"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>host</string><key>CFBundleIdentifier</key><string>com.anonlisten.hollow</string></dict></plist>' > "$app/Contents/Info.plist"
  codesign -f -s - "$app/Contents/Frameworks/libown.dylib" 2>/dev/null
  bash "$GATE" seal "$app" >/dev/null
  if [ -n "${2:-}" ]; then cp "$2" "$app/Contents/embedded.provisionprofile"; fi
  codesign -f -s - --entitlements "$W/ship.plist" "$app/Contents/MacOS/host" 2>/dev/null
}
names() { # names NAME PATTERN CMD...: the gate prints a FAIL line matching PATTERN
  local name="$1" pattern="$2" out
  shift 2
  out="$("$@" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -E "^FAIL .*$pattern" >/dev/null; then ok "$name"; else bad "$name"; printf '%s\n' "$out" | sed 's/^/       /'; fi
}
never() { # never NAME PATTERN CMD...: no FAIL line matches PATTERN
  local name="$1" pattern="$2" out
  shift 2
  out="$("$@" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -E "^FAIL .*$pattern" >/dev/null; then bad "$name"; printf '%s\n' "$out" | sed 's/^/       /'; else ok "$name"; fi
}
LATER=2044-01-01T00:00:00Z
make_profile "$W/good.provisionprofile" "$T" true "$LATER" "$T.com.anonlisten.hollow" "$KEYS"
new_shipped "$W/ship.app" "$W/good.provisionprofile"
SHIPPED='provisionprofile|HollowSealedImages|entitlements|JIT'
never "a shipped bundle with a valid profile and an exact seal passes the new checks" "$SHIPPED" \
  bash "$GATE" signed "$W/ship.app" "$T" "$W/ship.plist"
new_shipped "$W/noprof.app"
names "no profile is refused" "embedded.provisionprofile: missing" bash "$GATE" signed "$W/noprof.app" "$T"
make_profile "$W/team.provisionprofile" ZZZZZ99999 true "$LATER" "$T.com.anonlisten.hollow" "$KEYS"
new_shipped "$W/team.app" "$W/team.provisionprofile"
names "a profile of another team is refused" "the profile is for team 'ZZZZZ99999'" bash "$GATE" signed "$W/team.app" "$T"
make_profile "$W/old.provisionprofile" "$T" true 2020-01-01T00:00:00Z "$T.com.anonlisten.hollow" "$KEYS"
new_shipped "$W/old.app" "$W/old.provisionprofile"
names "an expired profile is refused" "the profile expired" bash "$GATE" signed "$W/old.app" "$T"
make_profile "$W/dev.provisionprofile" "$T" false "$LATER" "$T.com.anonlisten.hollow" "$KEYS"
new_shipped "$W/dev.app" "$W/dev.provisionprofile"
names "a profile that is not Developer ID is refused" "not a Developer ID profile" bash "$GATE" signed "$W/dev.app" "$T"
make_profile "$W/nogroup.provisionprofile" "$T" true "$LATER" "$T.com.anonlisten.hollow" group.com.anonlisten.hollow
new_shipped "$W/nogroup.app" "$W/nogroup.provisionprofile"
names "a claim the profile does not authorise is refused" "does not authorise the app group $KEYS" bash "$GATE" signed "$W/nogroup.app" "$T"
make_profile "$W/appid.provisionprofile" "$T" true "$LATER" "$T.com.anonlisten.other" "$KEYS"
new_shipped "$W/appid.app" "$W/appid.provisionprofile"
names "another app's profile is refused" "does not authorise com.apple.application-identifier" bash "$GATE" signed "$W/appid.app" "$T"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$W/empty.plist"
names "entitlements other than the computed set are refused" "entitlements differ" bash "$GATE" signed "$W/ship.app" "$T" "$W/empty.plist"
new_shipped "$W/late.app" "$W/good.provisionprofile"
clang -dynamiclib "$W/x.c" -o "$W/late.app/Contents/Frameworks/libx.dylib"
codesign -f -s - "$W/late.app/Contents/Frameworks/libx.dylib" 2>/dev/null
names "a Mach-O missing from HollowSealedImages is refused" "libx.dylib: not in HollowSealedImages" bash "$GATE" signed "$W/late.app" "$T"
new_shipped "$W/swap.app" "$W/good.provisionprofile"
clang -dynamiclib "$W/x.c" -o "$W/swap.app/Contents/Frameworks/libown.dylib" -install_name @rpath/libown.dylib
codesign -f -s - "$W/swap.app/Contents/Frameworks/libown.dylib" 2>/dev/null
names "a swapped Mach-O is refused" "libown.dylib: not in HollowSealedImages under its hash" bash "$GATE" signed "$W/swap.app" "$T"
names "and its stale hash is named" "libown.dylib: HollowSealedImages names a hash it does not have" bash "$GATE" signed "$W/swap.app" "$T"
new_shipped "$W/jit.app" "$W/good.provisionprofile"
mkdir -p "$W/jit.app/Contents/Frameworks/App.framework/Resources/flutter_assets"
: > "$W/jit.app/Contents/Frameworks/App.framework/Resources/flutter_assets/kernel_blob.bin"
names "a debug (JIT) Flutter engine is refused" "debug \(JIT\) Flutter engine" bash "$GATE" signed "$W/jit.app" "$T"
if /usr/libexec/PlistBuddy -c "Print :HollowSealedImages" "$W/ship.app/Contents/Info.plist" | grep -E '^ +[0-9a-f]{40} Contents/Frameworks/libown.dylib$' >/dev/null \
   && ! /usr/libexec/PlistBuddy -c "Print :HollowSealedImages" "$W/ship.app/Contents/Info.plist" | grep -F "MacOS/host" >/dev/null; then
  ok "seal lists every nested Mach-O and never the main executable"
else
  bad "seal wrote: $(/usr/libexec/PlistBuddy -c "Print :HollowSealedImages" "$W/ship.app/Contents/Info.plist" 2>&1 | tr '\n' ' ')"
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
