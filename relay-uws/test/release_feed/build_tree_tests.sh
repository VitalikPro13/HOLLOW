#!/bin/bash
# Tests for the tree checks in scripts/build_relay_binaries.sh: what gets built
# is exactly one commit. Each case runs `--check-only` in a throwaway git
# repository (made here, with its own two submodules), never in this checkout.
#   bash relay-uws/test/release_feed/build_tree_tests.sh
# BUILD_SCRIPT points the tests at another copy of the script (mutation runs).
set -u
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
script=${BUILD_SCRIPT:-$repo/scripts/build_relay_binaries.sh}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
g() { git -c user.name=test -c user.email=test@example.invalid -c protocol.file.allow=always -c init.defaultBranch=main "$@"; }

for sub in uSockets uWebSockets; do
    mkdir -p "$root/$sub" && echo "$sub" > "$root/$sub/README"
    g -C "$root/$sub" init -q && g -C "$root/$sub" add -A && g -C "$root/$sub" commit -qm one
done
# <dir>: a superproject with the script, version.h and both submodules, committed.
make_repo() {
    local d=$1
    mkdir -p "$d/scripts" "$d/relay-uws/src"
    cp "$script" "$d/scripts/build_relay_binaries.sh"
    cp "$repo/scripts/relay_binaries.Dockerfile" "$d/scripts/"
    printf '#define HOLLOW_RELAY_VERSION "0.12.2"\n' > "$d/relay-uws/src/version.h"
    g -C "$d" init -q
    g -C "$d" submodule --quiet add "$root/uSockets" relay-uws/uSockets
    g -C "$d" submodule --quiet add "$root/uWebSockets" relay-uws/uWebSockets
    g -C "$d" add -A && g -C "$d" commit -qm base
}
# <label> <expected rc 0|1> <text the output must hold> <setup run in the repo>
case_() {
    local d="$root/r.$RANDOM$RANDOM" out rc
    make_repo "$d"
    (cd "$d" && eval "$4") > /dev/null 2>&1
    out=$(SOURCE_DATE_EPOCH='' bash "$d/scripts/build_relay_binaries.sh" --check-only 2>&1)
    rc=$?
    [ "$rc" != 0 ] && rc=1
    if [ "$rc" = "$2" ] && [[ $out == *"$3"* ]]; then ok "$1"; else bad "$1" "rc $rc: $out"; fi
}

case_ "a clean checkout passes and names its commit" 0 "clean at " ':'
case_ "the commit time is the default SOURCE_DATE_EPOCH" 0 "SOURCE_DATE_EPOCH 1700000000" \
    'GIT_COMMITTER_DATE=@1700000000 git -c user.name=t -c user.email=t@e.invalid commit -q --amend --no-edit'
case_ "an edited tracked file refuses" 1 "not committed" 'echo x >> relay-uws/src/version.h'
case_ "a staged change refuses" 1 "not committed" 'echo x > new.txt && git add new.txt'
case_ "an untracked file refuses" 1 "not committed" 'echo x > relay-uws/src/extra.cpp'
case_ "an uninitialised submodule refuses" 1 "git submodule update --init" 'git submodule deinit -q -f relay-uws/uSockets'
# git status reports it too, so either check may be the one that refuses.
case_ "a submodule at another commit refuses" 1 "refusing to build" \
    'echo two >> relay-uws/uWebSockets/README && git -C relay-uws/uWebSockets -c user.name=t -c user.email=t@e.invalid commit -qam two'
case_ "an edited file inside a submodule refuses" 1 "not committed" 'echo x >> relay-uws/uSockets/README'
case_ "a submodule folder that is not a submodule refuses" 1 "is not a checked-out submodule" \
    'git rm -q --cached relay-uws/uSockets && rm -rf relay-uws/uSockets .gitmodules && git config -f .gitmodules submodule.relay-uws/uWebSockets.path relay-uws/uWebSockets && git config -f .gitmodules submodule.relay-uws/uWebSockets.url ../uWebSockets && mkdir -p relay-uws/uSockets && echo x > relay-uws/uSockets/README && git add -A && git -c user.name=t -c user.email=t@e.invalid commit -qm plain'
out=$(bash -c 'cd / && bash "$1" --check-only' _ "$script" 2>&1)
# The script's own checkout is used, wherever it is run from.
[[ $out == *"clean at "* || $out == *"not committed"* ]] && ok "the checks look at the script's own checkout" \
    || bad "the checks look at the script's own checkout" "$out"

# --- packing: the setup's copy rides along, and the same files give the same bytes ---
lib=$repo/relay-uws/deploy/lib/release_feed.sh
pack_case() { # <stage dir> <umask>: stages the setup from this checkout plus stand-in programs
    local s=$1
    rm -rf "$s" && mkdir -p "$s"
    (umask "$2" && bash "$script" --stage-setup "$repo" "$s/setup") || return 1
    printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x3e\x00' > "$s/hollow-relay"
    cp "$s/hollow-relay" "$s/hollow-forwarder"
    chmod 0755 "$s/hollow-relay" "$s/hollow-forwarder"
    printf 'version=0.12.2\nbuild=0\ncommit=%s\n' "$(printf '%040d' 0)" > "$s/VERSION"
    chmod 0644 "$s/VERSION"
}
pack_case "$root/p1" 022 && SOURCE_DATE_EPOCH=1700000000 bash "$script" --pack "$root/p1" "$root/t1.tar.gz"
pack_case "$root/p2" 077 && find "$root/p2" -exec touch -d @1800000000 {} + && sleep 1 &&
    SOURCE_DATE_EPOCH=1700000000 bash "$script" --pack "$root/p2" "$root/t2.tar.gz"
if [ -s "$root/t1.tar.gz" ] && cmp -s "$root/t1.tar.gz" "$root/t2.tar.gz"; then
    ok "the same files pack to the same bytes, whatever their times and the umask"
else
    bad "the same files pack to the same bytes, whatever their times and the umask"
fi
listing=$(TZ=UTC tar -tvzf "$root/t1.tar.gz" --numeric-owner --full-time 2>&1)
names=$(tar -tzf "$root/t1.tar.gz")
[ "$names" = "$(printf '%s\n' "$names" | LC_ALL=C sort)" ] && ok "members are sorted" || bad "members are sorted" "$names"
[ -z "$(printf '%s\n' "$listing" | awk '$2 != "0/0"')" ] && ok "every member is root's" || bad "every member is root's" "$listing"
[ -z "$(printf '%s\n' "$listing" | grep -v ' 2023-11-14 22:13:20 ')" ] && ok "every member carries SOURCE_DATE_EPOCH" \
    || bad "every member carries SOURCE_DATE_EPOCH" "$(printf '%s\n' "$listing" | head -3)"
[ -z "$(printf '%s\n' "$listing" | grep -v '^-')" ] && ok "only files, no folder entries" || bad "only files, no folder entries"
[ "$(od -An -tx1 -j4 -N4 "$root/t1.tar.gz" | tr -d ' ')" = 00000000 ] && ok "gzip carries no time" || bad "gzip carries no time"
want=$( (cd "$repo/relay-uws" && find deploy -type f | sed 's|^|setup/|'; echo setup/install.sh) | LC_ALL=C sort)
got=$(printf '%s\n' "$names" | grep '^setup/' | grep -v '^setup/push-sidecar/')
[ "$got" = "$want" ] && ok "the setup's copy holds install.sh and all of deploy/" || bad "the setup's copy holds install.sh and all of deploy/" "$(diff <(echo "$want") <(echo "$got") | head)"
for f in index.js fcm.js unifiedpush.js package.json package-lock.json hollow-push.service; do
    printf '%s\n' "$names" | grep -qx "setup/push-sidecar/$f" && ok "it holds push-sidecar/$f" || bad "it holds push-sidecar/$f"
done
[ -z "$(printf '%s\n' "$names" | grep -E '^setup/push-sidecar/(test|node_modules|Dockerfile)')" ] && ok "and none of the push sender's tests or image files" \
    || bad "and none of the push sender's tests or image files"
tar -tvzf "$root/t1.tar.gz" | grep -q -- '-rwxr-xr-x .* setup/install.sh$' && ok "install.sh stays runnable" || bad "install.sh stays runnable"
if bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$root/t1.tar.gz"; then ok "the installers' check takes the packed tarball"
else bad "the installers' check takes the packed tarball"; fi
b=$(sed -n 's/^SETUP_PUSH_FILES="\(.*\)"$/\1/p' "$script")
n=$(sed -n 's/^SETUP_PUSH_FILES="\(.*\)"$/\1/p' "$repo/relay-uws/deploy/lib/native.sh")
[ -n "$b" ] && [ "$b" = "$n" ] && ok "the build and the installer copy the same push files" || bad "the build and the installer copy the same push files" "[$b] [$n]"

# A setup that cannot start is never packed: every box would refuse it.
bad_repo="$root/badrepo"
mkdir -p "$bad_repo" && cp -R "$repo/relay-uws" "$bad_repo/" 2>/dev/null; cp -R "$repo/push-sidecar" "$bad_repo/"
rm -rf "$bad_repo/relay-uws/uWebSockets" "$bad_repo/relay-uws/uSockets" "$bad_repo/relay-uws/build"
if out=$(bash "$script" --stage-setup "$bad_repo" "$root/okstage" 2>&1); then ok "a setup that starts is staged"
else bad "a setup that starts is staged" "$out"; fi
printf 'false\n' >> "$bad_repo/relay-uws/deploy/lib/questions.sh"
if out=$(bash "$script" --stage-setup "$bad_repo" "$root/badstage" 2>&1); then
    bad "a setup that cannot start is never staged for packing"
else
    [[ $out == *"does not start"* ]] && ok "a setup that cannot start is never staged for packing" \
        || bad "a setup that cannot start is never staged for packing" "$out"
fi

echo "build_tree: $pass passed, $fail failed"
[ "$fail" = 0 ]
