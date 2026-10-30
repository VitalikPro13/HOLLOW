#!/bin/bash
# Tests for relay-uws/deploy/lib/release_feed.sh, the installer's check of the
# signed relay feed. A throwaway Ed25519 key signs every feed here; the release
# key is never used. Needs Linux with bash, openssl 3, jq, curl, python3, GNU
# tar, flock, sha256sum and coreutils.
#   bash relay-uws/test/release_feed/run_tests.sh
# The suite runs twice: with the library sourced under `set -u`, then under
# `set -euo pipefail` as install.sh sources it.
# RELEASE_FEED_LIB points the tests at another copy of the library (mutation runs).
set -u
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
lib=${RELEASE_FEED_LIB:-$repo/relay-uws/deploy/lib/release_feed.sh}
if [ "${RELEASE_FEED_STRICT:-}" = 1 ]; then opts="set -euo pipefail"; else opts="set -u"; fi
root=$(mktemp -d)
pids=()
cleanup() {
    local p
    for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done
    rm -rf "$root"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
now=$(date +%s)

# --- keys and signing ---------------------------------------------------------
raw_pubkey() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n'; }
openssl genpkey -algorithm ed25519 -out "$root/test.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$root/other.pem" 2>/dev/null
PK=$(raw_pubkey "$root/test.pem")
OTHER_PK=$(raw_pubkey "$root/other.pem")
RELEASE_PK=b6fcb5b64cd5317b470b31ac08892528b0d5c9e82c6cdaa13654a7c9e7f8b09c
COMMIT=0123456789abcdef0123456789abcdef01234567

# <key pem> <prefix: relay|status|news|bare> <file>: the base64 signature hollow-manifest writes.
sign() {
    local key=$1 name=$2 file=$3
    if [ "$name" = bare ]; then
        cp "$file" "$root/msg"
    else
        { printf 'hollow-feed-sig-v1\0%s\0' "$name"; cat "$file"; } > "$root/msg"
    fi
    openssl pkeyutl -sign -inkey "$key" -rawin -in "$root/msg" | base64 -w0
    echo
}

# --- fake binaries and tarballs -------------------------------------------------
# <out> <machine hex, 3e00 or b700>: a file that starts like a 64-bit ELF PIE.
fake_elf() {
    printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00' > "$1"
    printf '%b' "$(printf '%s' "$2" | sed 's/../\\x&/g')" >> "$1"
    head -c 4096 /dev/urandom >> "$1"
}

# The setup's copy a release carries: a few files where install.sh's copy has them.
SETUP_FILES=(setup/deploy/lib/common.sh setup/deploy/lib/release_feed.sh setup/install.sh setup/push-sidecar/index.js
    setup/push-sidecar/package-lock.json setup/push-sidecar/package.json setup/deploy/turn-port-lock.sh
    setup/deploy/hollow-turn-port-lock.service setup/deploy/hollow-turn-port-lock-refresh.service
    setup/deploy/hollow-turn-port-lock-refresh.timer setup/deploy/coturn-port-lock.conf)
stage_setup() { # <stage dir>
    local f
    for f in "${SETUP_FILES[@]}"; do
        mkdir -p "$1/${f%/*}"
        printf '# %s\n' "$f" > "$1/$f"
        chmod 0644 "$1/$f"
    done
    chmod 0755 "$1/setup/install.sh"
}

# <out tarball> <arch> <version> <build> [variant]
make_tarball() {
    local out=$1 arch=$2 v=$3 b=$4 variant=${5:-good} s="$root/stage.$RANDOM$RANDOM" m=3e00
    [ "$arch" = linux-aarch64 ] && m=b700
    local fm=$m
    [ "$variant" = wrongelf ] && { [ "$m" = 3e00 ] && m=b700 || m=3e00; } && fm=$m
    [ "$variant" = wrongelf-forwarder ] && { [ "$m" = 3e00 ] && fm=b700 || fm=3e00; }
    mkdir -p "$s"
    fake_elf "$s/hollow-relay" "$m"
    fake_elf "$s/hollow-forwarder" "$fm"
    printf 'version=%s\nbuild=%s\ncommit=%s\n' "$v" "$b" "$COMMIT" > "$s/VERSION"
    stage_setup "$s"
    local files=(VERSION hollow-forwarder hollow-relay "${SETUP_FILES[@]}") extra=()
    case "$variant" in
        good | wrongelf | wrongelf-forwarder) ;;
        oldstyle) files=(VERSION hollow-forwarder hollow-relay) ;;
        badversion) printf 'version=%s\nbuild=%s\ncommit=%s\n' "$v" "$((b + 1))" "$COMMIT" > "$s/VERSION" ;;
        badcommit) printf 'version=%s\nbuild=%s\ncommit=%s\n' "$v" "$b" "${COMMIT//0/1}" > "$s/VERSION" ;;
        nocommit) printf 'version=%s\nbuild=%s\n' "$v" "$b" > "$s/VERSION" ;;
        symlink) rm "$s/hollow-relay"; ln -s /etc/passwd "$s/hollow-relay" ;;
        hardlink) rm "$s/VERSION"; ln "$s/hollow-forwarder" "$s/VERSION" ;;
        extra) echo x > "$s/evil"; files+=(evil) ;;
        missing) files=(VERSION hollow-relay "${SETUP_FILES[@]}") ;;
        dir) rm "$s/hollow-relay"; mkdir "$s/hollow-relay"; echo x > "$s/hollow-relay/x" ;;
        dotslash) files=(./VERSION ./hollow-forwarder ./hollow-relay) ;;
        dup) files+=(hollow-relay) ;;
        dotdot) extra=(-P --transform 's,^VERSION$,../VERSION,') ;;
        owner) extra=(--owner=4242 --group=4242) ;;
        modes) chmod 0777 "$s/VERSION" "$s/hollow-relay"; chmod 0700 "$s/hollow-forwarder" ;;
        nested) extra=(-P --transform 's,^VERSION$,sub/VERSION,') ;;
        setup-*) rm -rf "$s"; craft_tarball "$out" "$v" "$b" "$m" "${variant#setup-}"; return ;;
        corpus-*) rm -rf "$s"; cp "$CORPUS/${variant#corpus-}.tar.gz" "$out"; return ;;
        *) echo "unknown variant $variant" >&2; return 1 ;;
    esac
    tar "${extra[@]}" -C "$s" -czf "$out" "${files[@]}"
    rm -rf "$s"
}

# Tarballs GNU tar cannot be asked to make from a folder: written entry by
# entry, the three programs and the setup's files plus one odd thing.
cat > "$root/craft.py" <<'PYEOF'
import io, sys, tarfile
out, version, build, commit, machine, kind = sys.argv[1:7]
elf = b"\x7fELF\x02\x01\x01" + b"\x00" * 9 + b"\x03\x00" + bytes.fromhex(machine) + b"\x00" * 4096
setup = ["setup/deploy/lib/common.sh", "setup/deploy/lib/release_feed.sh", "setup/install.sh", "setup/push-sidecar/index.js",
         "setup/push-sidecar/package-lock.json", "setup/push-sidecar/package.json", "setup/deploy/turn-port-lock.sh",
         "setup/deploy/hollow-turn-port-lock.service", "setup/deploy/hollow-turn-port-lock-refresh.service",
         "setup/deploy/hollow-turn-port-lock-refresh.timer", "setup/deploy/coturn-port-lock.conf"]
entries = [("VERSION", f"version={version}\nbuild={build}\ncommit={commit}\n".encode(), 0o644),
           ("hollow-forwarder", elf, 0o755), ("hollow-relay", elf, 0o755)]
entries += [(n, f"# {n}\n".encode(), 0o755 if n.endswith("install.sh") else 0o644) for n in setup]
odd = []
def drop(name):
    global entries
    entries = [e for e in entries if e[0] != name]
if kind == "link": odd.append(("setup/deploy/lib/x.sh", tarfile.SYMTYPE, b"", 0o777, "/etc/passwd"))
elif kind == "hardlink": odd.append(("setup/deploy/lib/x.sh", tarfile.LNKTYPE, b"", 0o644, "hollow-relay"))
elif kind == "device": odd.append(("setup/deploy/lib/x.sh", tarfile.CHRTYPE, b"", 0o644, ""))
elif kind == "fifo": odd.append(("setup/deploy/lib/x.sh", tarfile.FIFOTYPE, b"", 0o644, ""))
elif kind == "direntry": odd.append(("setup/deploy", tarfile.DIRTYPE, b"", 0o755, ""))
elif kind == "dotdot": odd.append(("setup/deploy/../../evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "dotpart": odd.append(("setup/deploy/../evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "absolute": odd.append(("/etc/cron.d/evil", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "otherroot": odd.append(("setup/bin/evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "rootfile": odd.append(("setup/evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "hidden": odd.append(("setup/deploy/.evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "dash": odd.append(("setup/deploy/-evil.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "space": odd.append(("setup/deploy/a b.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "newline": odd.append(("setup/deploy/a\nb.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "wildcard": odd.append(("setup/deploy/*.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "deep": odd.append(("setup/deploy/a/b/c/d/e/f.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "longpart": odd.append(("setup/deploy/" + "a" * 65, tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "mode777": odd.append(("setup/deploy/m.sh", tarfile.REGTYPE, b"x", 0o777, ""))
elif kind == "setuid": odd.append(("setup/deploy/m.sh", tarfile.REGTYPE, b"x", 0o4755, ""))
elif kind == "mode600": odd.append(("setup/deploy/m.sh", tarfile.REGTYPE, b"x", 0o600, ""))
elif kind == "big": odd.append(("setup/deploy/big.sh", tarfile.REGTYPE, b"#" * (1048576 + 1), 0o644, ""))
elif kind == "bigok": odd.append(("setup/deploy/big.sh", tarfile.REGTYPE, b"#" * 1048576, 0o644, ""))
elif kind == "total":
    for i in range(8): odd.append((f"setup/deploy/big{i}.sh", tarfile.REGTYPE, b"#" * 1048576, 0o644, ""))
elif kind == "many":
    for i in range(513 - len(setup)): odd.append((f"setup/deploy/f{i}.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "manyok":
    for i in range(512 - len(setup)): odd.append((f"setup/deploy/f{i}.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "dup": odd.append(("setup/install.sh", tarfile.REGTYPE, b"x", 0o755, ""))
elif kind == "fifoprogram":
    drop("hollow-relay"); odd.append(("hollow-relay", tarfile.FIFOTYPE, b"", 0o755, ""))
elif kind == "noinstall": drop("setup/install.sh")
elif kind == "nofeedlib": drop("setup/deploy/lib/release_feed.sh")
elif kind == "nolock": drop("setup/deploy/turn-port-lock.sh")
elif kind == "plain": odd.append(("setup/deploy/lib/x.sh", tarfile.REGTYPE, b"x", 0o644, ""))
elif kind == "deepok": odd.append(("setup/deploy/a/b/c/d/f.sh", tarfile.REGTYPE, b"x", 0o644, ""))
else: sys.exit("unknown kind " + kind)
with tarfile.open(out, "w:gz", format=tarfile.GNU_FORMAT) as t:
    for name, data, mode in entries:
        i = tarfile.TarInfo(name); i.size = len(data); i.mode = mode; i.mtime = 1700000000
        t.addfile(i, io.BytesIO(data))
    for name, typ, data, mode, link in odd:
        i = tarfile.TarInfo(name); i.type = typ; i.size = len(data); i.mode = mode; i.linkname = link; i.mtime = 1700000000
        if typ == tarfile.CHRTYPE: i.devmajor, i.devminor = 1, 3
        t.addfile(i, io.BytesIO(data) if data else None)
PYEOF
craft_tarball() { # <out> <version> <build> <machine hex> <kind>
    python3 -I "$root/craft.py" "$1" "$2" "$3" "$COMMIT" "$4" "$5"
}

tarball_name() {
    if [ "$2" -gt 0 ]; then echo "hollow-relay-$1-b$2-$3.tar.gz"; else echo "hollow-relay-$1-$3.tar.gz"; fi
}

SRV="$root/srv"
mkdir -p "$SRV"

# publish [key=..] [name=relay] [issued=N] [version=..] [build=..] [variant=..]
#         [arches="linux-x86_64 linux-aarch64"] [url_host=..] [pad=N]
# Writes relay.json, its signature and the tarballs into $SRV.
publish() {
    local key="$root/test.pem" name=relay issued=1761134400 version=0.12.2 build=0 variant=good
    local arches="linux-x86_64 linux-aarch64" url_host="https://anonlisten.com/hollow/releases" pad=0 kv
    for kv in "$@"; do
        case "$kv" in
            key=*) key=${kv#key=} ;; name=*) name=${kv#name=} ;; issued=*) issued=${kv#issued=} ;;
            version=*) version=${kv#version=} ;; build=*) build=${kv#build=} ;;
            variant=*) variant=${kv#variant=} ;; arches=*) arches=${kv#arches=} ;;
            url_host=*) url_host=${kv#url_host=} ;; pad=*) pad=${kv#pad=} ;;
        esac
    done
    rm -f "$SRV"/*
    local arts='{}' arch t
    for arch in $arches; do
        t=$(tarball_name "$version" "$build" "$arch")
        make_tarball "$SRV/$t" "$arch" "$version" "$build" "$variant"
        arts=$(jq -c --arg a "$arch" --arg u "$url_host/$t" --arg h "$(sha256sum "$SRV/$t" | cut -d' ' -f1)" \
            --argjson s "$(stat -c %s "$SRV/$t")" '. + {($a): {url: $u, sha256: $h, size: $s}}' <<< "$arts")
    done
    jq --arg v "$version" --argjson b "$build" --argjson i "$issued" --arg c "$COMMIT" --argjson a "$arts" \
        -n '{feed: "relay", version: $v, build: $b, issued: $i, commit: $c, artifacts: $a}' > "$SRV/relay.json"
    [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' ' ' >> "$SRV/relay.json"
    sign "$key" "$name" "$SRV/relay.json" > "$SRV/relay.json.sig"
}

# Re-sign the current relay.json after a test edited it.
resign() { sign "$root/test.pem" relay "$SRV/relay.json" > "$SRV/relay.json.sig"; }

# Tests point the library at the throwaway key, the local folder and a chosen
# machine by redefining its functions after sourcing it; the floors drop to
# nothing unless a test asks for the baked ones (T_FLOORS=real) or its own
# ("<issued> <version> <build>").
cat > "$root/prelude.sh" <<'EOF'
_hf_release_keys() { printf '%s\n' $T_KEYS; }
_hf_base() { printf '%s' "$T_BASE"; }
_hf_protos() { printf '=http,https,file'; }
hollow_feed_arch() { printf '%s\n' "$T_ARCH"; }
case "$T_FLOORS" in
    real) ;;
    low) _HF_MIN_ISSUED=1 _HF_MIN_VERSION=0.0.0 _HF_MIN_BUILD=0 ;;
    *) read -r _HF_MIN_ISSUED _HF_MIN_VERSION _HF_MIN_BUILD <<< "$T_FLOORS" ;;
esac
EOF

STATE="$root/state"
DEST="$root/dest"
export TMPDIR="$root/tmp"
mkdir -p "$TMPDIR"
# <bash snippet>: runs in a fresh shell with the library and the prelude sourced.
run_lib() {
    rm -rf "$DEST"
    mkdir -p "$DEST"
    T_KEYS="${TEST_KEYS:-$PK}" T_BASE="${TEST_BASE:-file://$SRV}" T_ARCH="${TEST_ARCH:-linux-x86_64}" \
        T_FLOORS="${TEST_FLOORS:-low}" \
        timeout 60 bash -c "$opts"'; source "$1"; source "$2"; eval "$3"' _ "$lib" "$root/prelude.sh" "$1" 2> "$root/err"
}
no_partials() {
    [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ] && [ -z "$(find "$TMPDIR" -mindepth 1 2>/dev/null)" ]
}
# <label> <reason substring> <snippet>: the snippet fails, says why, and leaves nothing behind.
expect_refused() {
    local label=$1 reason=$2 snippet=$3
    if run_lib "$snippet"; then
        bad "$label" "was accepted"
    elif ! grep -qF -- "$reason" "$root/err"; then
        bad "$label" "refused for another reason: $(tr '\n' ' ' < "$root/err")"
    elif ! no_partials; then
        bad "$label" "left files behind: $(find "$DEST" "$TMPDIR" -mindepth 1 | tr '\n' ' ')"
    else
        ok "$label"
    fi
}
expect_ok() {
    local label=$1 snippet=$2
    if run_lib "$snippet"; then ok "$label"; else bad "$label" "$(tr '\n' ' ' < "$root/err")"; fi
}
CHECK_FETCH='hollow_feed_check "'"$STATE"'" && hollow_feed_fetch "'"$DEST"'"'
# <port>: waits until something listens there.
wait_port() {
    local i
    for i in $(seq 1 50); do
        (exec 3<> "/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# Sourced before the library's own rm calls: records the size of every file it removes.
PEAK_RM='rm() { local a; for a in "$@"; do if [ -f "$a" ]; then stat -c %s -- "$a" >> "'"$root"'/peak"; fi; done; command rm "$@"; }'
peak() { sort -n "$root/peak" 2>/dev/null | tail -1; }

echo "release_feed.sh tests (library: $lib, sourced under: $opts)"
openssl version
curl --version | head -1

# --- the accepted path ------------------------------------------------------------
rm -rf "$STATE"
publish issued=1761134400
expect_ok "a signed feed is accepted, fetched and recorded" "$CHECK_FETCH"' && hollow_feed_accept "'"$STATE"'" &&
    [ "$FEED_VERSION $FEED_BUILD $FEED_ISSUED $FEED_COMMIT" = "0.12.2 0 1761134400 '"$COMMIT"'" ] &&
    [ "$FEED_URL" = https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz ] &&
    [ "$FEED_SIZE" = "$(stat -c %s '"$SRV"'/hollow-relay-0.12.2-linux-x86_64.tar.gz)" ] &&
    [[ $FEED_SHA256 =~ ^[0-9a-f]{64}$ ]]'
SETUP_LISTING="./setup ./setup/deploy ./setup/deploy/coturn-port-lock.conf ./setup/deploy/hollow-turn-port-lock-refresh.service ./setup/deploy/hollow-turn-port-lock-refresh.timer ./setup/deploy/hollow-turn-port-lock.service ./setup/deploy/lib ./setup/deploy/lib/common.sh ./setup/deploy/lib/release_feed.sh ./setup/deploy/turn-port-lock.sh ./setup/install.sh ./setup/push-sidecar ./setup/push-sidecar/index.js ./setup/push-sidecar/package-lock.json ./setup/push-sidecar/package.json "
if [ "$(cd "$DEST" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')" = "./VERSION ./hollow-forwarder ./hollow-relay $SETUP_LISTING" ] \
    && [ "$(stat -c %a "$DEST/hollow-relay" "$DEST/hollow-forwarder" "$DEST/VERSION" | tr '\n' ' ')" = "755 755 644 " ] \
    && [ "$(cat "$DEST/VERSION")" = "$(printf 'version=0.12.2\nbuild=0\ncommit=%s' "$COMMIT")" ]; then
    ok "the fetch leaves exactly the three files and the setup's copy, binaries executable"
else
    bad "the fetch leaves exactly the three files and the setup's copy, binaries executable" "$(ls -laR "$DEST")"
fi
# Under a tight umask the copy still comes out readable and runnable.
expect_ok "a fetch under umask 077 normalises the setup's modes" 'umask 077; '"$CHECK_FETCH"' &&
    [ "$(cd "'"$DEST"'/setup" && stat -c "%a" install.sh deploy deploy/lib/common.sh | tr "\n" " ")" = "755 755 644 " ]'
if [ "$(cd "$DEST/setup" && stat -c '%a %n' install.sh deploy deploy/lib/common.sh | tr '\n' ' ')" = "755 install.sh 755 deploy 644 deploy/lib/common.sh " ]; then
    ok "the setup's copy keeps install.sh runnable and the rest plain"
else
    bad "the setup's copy keeps install.sh runnable and the rest plain" "$(ls -laR "$DEST/setup")"
fi
if [ "$(cat "$STATE/relay_feed_issued")" = 1761134400 ] && [ "$(stat -c %a "$STATE/relay_feed_issued")" = 600 ] \
    && [ "$(stat -c %a "$STATE")" = 700 ] && [ "$(ls -A "$STATE")" = relay_feed_issued ]; then
    ok "accept records issued in an owner-only file and nothing else"
else
    bad "accept records issued in an owner-only file and nothing else" "$(ls -la "$STATE")"
fi
expect_ok "the same feed passes again after accept" 'hollow_feed_check "'"$STATE"'"'
expect_ok "the FEED variables come from the checked feed" 'hollow_feed_check "'"$STATE"'" && [ "$FEED_ISSUED" = 1761134400 ]'
if [ -z "$(find "$TMPDIR" -mindepth 1)" ]; then ok "a check leaves no temporary files"; else bad "a check leaves no temporary files"; fi

# --- rollback ---------------------------------------------------------------------------
publish issued=1761134399
expect_refused "an older issued is refused after a newer one was accepted" "older than one this server already accepted" \
    'hollow_feed_check "'"$STATE"'"'
publish issued=1761134500
expect_ok "a newer issued passes and accept raises the mark" 'hollow_feed_check "'"$STATE"'" && hollow_feed_accept "'"$STATE"'"'
[ "$(cat "$STATE/relay_feed_issued")" = 1761134500 ] && ok "the mark moved to the newer issued" || bad "the mark moved to the newer issued"
publish issued=1761134400
expect_refused "the first feed is refused once a newer one was accepted" "older than one" 'hollow_feed_check "'"$STATE"'"'
printf '1761134600\n' > "$STATE/relay_feed_issued"
publish issued=1761134500
expect_ok "accept never lowers a higher mark" 'hollow_feed_check "'"$root/state2"'" && hollow_feed_accept "'"$STATE"'"'
[ "$(cat "$STATE/relay_feed_issued")" = 1761134600 ] && ok "the higher mark stayed" || bad "the higher mark stayed"
printf 'a[$(touch %s/pwned)]\n' "$root" > "$STATE/relay_feed_issued"
expect_refused "a damaged mark refuses, and is never run as code" "is damaged" 'hollow_feed_check "'"$STATE"'"'
[ -e "$root/pwned" ] && bad "the damaged mark ran a command" || ok "the damaged mark ran nothing"
rm -rf "$STATE"
mkdir -p "$STATE/relay_feed_issued"
expect_refused "a mark that is not a file refuses" "is damaged" 'hollow_feed_check "'"$STATE"'"'
rm -rf "$STATE"
mkdir -p "$STATE" && mkfifo "$STATE/relay_feed_issued"
expect_refused "a mark that is a pipe refuses without waiting on it" "is damaged" 'hollow_feed_check "'"$STATE"'"'
rm -rf "$STATE"

# Two runs at once: the lower stamp reads the mark first and is slow to write
# it; the higher one must still be the mark at the end.
rm -rf "$root/cstate" "$root/go" "$root/l.checked"
publish issued=1000000100
T_KEYS=$PK T_BASE="file://$SRV" T_ARCH=linux-x86_64 T_FLOORS=low timeout 60 bash -c "$opts"'; source "$1"; source "$2"
    hollow_feed_check "$3"
    touch "$4/l.checked"
    while [ ! -e "$4/go" ]; do sleep 0.05; done
    eval "$(declare -f _hf_accepted_issued | sed "1s/_hf_accepted_issued/_hf_read_mark_now/")"
    _hf_accepted_issued() { _hf_read_mark_now "$@"; local r=$?; sleep 2; return $r; }
    hollow_feed_accept "$3"' _ "$lib" "$root/prelude.sh" "$root/cstate" "$root" 2> "$root/err.slow" &
slow=$!
for _ in $(seq 1 200); do [ -e "$root/l.checked" ] && break; sleep 0.05; done
publish issued=1000000200
T_KEYS=$PK T_BASE="file://$SRV" T_ARCH=linux-x86_64 T_FLOORS=low timeout 60 bash -c "$opts"'; source "$1"; source "$2"
    hollow_feed_check "$3"
    touch "$4/go"
    sleep 0.5
    hollow_feed_accept "$3"' _ "$lib" "$root/prelude.sh" "$root/cstate" "$root" 2> "$root/err.fast"
fast_rc=$?
wait "$slow"
slow_rc=$?
if [ "$fast_rc" = 0 ] && [ "$slow_rc" = 0 ] && [ "$(cat "$root/cstate/relay_feed_issued" 2>/dev/null)" = 1000000200 ]; then
    ok "two accepts at once never move the mark backwards"
else
    bad "two accepts at once never move the mark backwards" \
        "mark $(cat "$root/cstate/relay_feed_issued" 2>/dev/null), rc $fast_rc/$slow_rc: $(cat "$root/err.fast" "$root/err.slow" | tr '\n' ' ')"
fi

# --- the clock and the floors baked into the library --------------------------------
publish issued=$((now + 2 * 86400))
expect_refused "a feed dated two days past this clock is refused" "more than a day after this server's clock" \
    'hollow_feed_check "'"$STATE"'"'
[ -e "$STATE/relay_feed_issued" ] && bad "a feed from the future left a mark" || ok "a feed from the future left no mark"
publish issued=$((now + 23 * 3600))
expect_ok "a feed dated less than a day ahead passes" 'hollow_feed_check "'"$STATE"'"'
rm -rf "$STATE"

read -r baked_issued baked_version baked_build < <(bash -c 'source "$1"; echo "$_HF_MIN_ISSUED $_HF_MIN_VERSION $_HF_MIN_BUILD"' _ "$lib")
publish issued=1600000000 version=0.9.0
TEST_FLOORS=real expect_refused "with no mark, a feed older than the library's own release is refused" \
    "older than this installer" 'hollow_feed_check "'"$STATE"'"'
publish issued=$((baked_issued - 1)) version="$baked_version" build="$baked_build"
TEST_FLOORS=real expect_refused "with no mark, an issued below the baked floor is refused" "older than this installer" \
    'hollow_feed_check "'"$STATE"'"'
publish issued="$now" version="$baked_version" build="$baked_build"
TEST_FLOORS=real expect_ok "the baked release itself passes" 'hollow_feed_check "'"$STATE"'"'
publish issued="$now" version=0.12.2 build=2
TEST_FLOORS="1 0.12.2 3" expect_refused "a build below the version floor is refused" "older than this installer" \
    'hollow_feed_check "'"$STATE"'"'
TEST_FLOORS="1 0.12.1 9" expect_ok "a newer version over a higher floor build passes" 'hollow_feed_check "'"$STATE"'"'
TEST_FLOORS="1 0.13.0 0" expect_refused "a version below the floor is refused" "older than this installer" \
    'hollow_feed_check "'"$STATE"'"'
TEST_FLOORS="$((now + 10)) 0.0.0 0" expect_refused "an issued below the issued floor is refused" "older than this installer" \
    'hollow_feed_check "'"$STATE"'"'
version_h=$(sed -nE 's/^#define HOLLOW_RELAY_VERSION "([0-9.]+)"$/\1/p' "$repo/relay-uws/src/version.h")
if [[ $baked_issued =~ ^[1-9][0-9]{9}$ ]] && [ "$baked_issued" -le $((now + 86400)) ] && [[ $baked_build =~ ^[0-9]{1,4}$ ]] \
    && [ "$(printf '%s\n%s\n' "$baked_version" "$version_h" | sort -V | tail -1)" = "$version_h" ]; then
    ok "the baked floors are sane ($baked_version build $baked_build, issued $baked_issued; version.h $version_h)"
else
    bad "the baked floors are sane" "$baked_version build $baked_build issued $baked_issued, version.h $version_h"
fi
if [ -f "$repo/legal/relay.json" ]; then
    live=$(jq -r '"\(.issued) \(.version) \(.build)"' "$repo/legal/relay.json")
    [ "$live" = "$baked_issued $baked_version $baked_build" ] && ok "the baked floors are legal/relay.json ($live)" \
        || bad "the baked floors are legal/relay.json" "legal: $live, library: $baked_issued $baked_version $baked_build"
else
    ok "no legal/relay.json yet; the first relay release step sets the floors"
fi

# --- the installed relay ----------------------------------------------------------------
publish issued=1761134400 version=0.12.2 build=1
installed_check() { # <label> <marker printf format or "none"> <args after the state dir> <expected rc> [reason]
    rm -f "$root/VERSION"
    [ "$2" = none ] || printf "$2" > "$root/VERSION"
    run_lib 'hollow_feed_check "'"$STATE"'" '"$3"' && [ "$FEED_BUILD" = 1 ]'
    local rc=$?
    if [ "$rc" != "$4" ]; then
        bad "$1" "rc $rc, want $4: $(tr '\n' ' ' < "$root/err")"
    elif [ -n "${5:-}" ] && ! grep -qF -- "$5" "$root/err"; then
        bad "$1" "no '$5' in: $(tr '\n' ' ' < "$root/err")"
    elif ! no_partials; then
        bad "$1" "left files behind"
    else
        ok "$1"
    fi
}
V="\"$root/VERSION\""
installed_check "the same release as installed passes" "version=0.12.2\nbuild=1\ncommit=$COMMIT\n" "$V" 0
installed_check "an older installed relay passes" 'version=0.12.2\nbuild=0\n' "$V" 0
installed_check "a release older than the installed one returns 3" "version=0.12.2\nbuild=2\ncommit=$COMMIT\n" "$V" 3 \
    "older than the installed 0.12.2 build 2"
installed_check "a release older than a source build returns 3" 'version=0.13.0\nbuild=0\n' "$V" 3 "refusing to downgrade"
installed_check "a downgrade asked for by name passes" 'version=0.13.0\nbuild=0\n' "$V allow-downgrade" 0 "as asked"
installed_check "no marker yet means nothing to compare" none "$V" 0
installed_check "a damaged marker refuses" 'version=0.13\nbuild=0\n' "$V" 1 "cannot tell which relay is installed"
installed_check "a downgrade flag spelled any other way is a usage error" 'version=0.13.0\nbuild=0\n' "$V yes" 2 "usage"
installed_check "a fourth argument is a usage error" 'version=0.12.2\nbuild=0\n' "$V allow-downgrade x" 2 "usage"
installed_check "without the marker argument nothing installed is compared" 'version=0.13.0\nbuild=0\n' "" 0
run_lib 'FEED_URL=stale; hollow_feed_check "'"$STATE"'" "'"$root/VERSION"'" || [ $? = 3 ] && [ -z "${FEED_URL+x}" ] && [ -z "${_HF_OK:-}" ]
    hollow_feed_fetch "'"$DEST"'" && exit 9; exit 0'
[ $? = 0 ] && grep -qF "before hollow_feed_fetch" "$root/err" && ok "a refused downgrade sets nothing and fetches nothing" \
    || bad "a refused downgrade sets nothing and fetches nothing" "$(tr '\n' ' ' < "$root/err")"

# --- the signature --------------------------------------------------------------------------
publish key="$root/other.pem"
expect_refused "a feed signed by another key is refused" "not signed by Hollow's release key" "$CHECK_FETCH"
TEST_KEYS="$OTHER_PK $PK" expect_ok "any listed key may sign (rotation)" 'hollow_feed_check "'"$STATE"'"'
publish
sed -i 's/"build": 0/"build": 1/' "$SRV/relay.json"
expect_refused "one edited byte after signing is refused" "not signed by Hollow's release key" "$CHECK_FETCH"
publish
printf ' ' >> "$SRV/relay.json"
expect_refused "one appended byte after signing is refused" "not signed by Hollow's release key" "$CHECK_FETCH"
for other in status news bare; do
    publish name=$other
    expect_refused "a $other signature over relay.json never passes as the relay feed" "not signed by Hollow's release key" "$CHECK_FETCH"
done
publish
sig=$(cat "$SRV/relay.json.sig")
for form in "${sig%==}" "${sig}x" " $sig" "${sig:0:85}B==" "${sig}"$'\n' "-${sig:1}"; do
    [ "$form" = "$sig" ] && continue
    printf '%s\n' "$form" > "$SRV/relay.json.sig"
    expect_refused "a signature not in canonical base64 is refused (${form:0:6}..${form: -4})" "not a signature in the expected form" "$CHECK_FETCH"
done
printf '%s' "$sig" > "$SRV/relay.json.sig"
expect_ok "a signature without its trailing newline is accepted" 'hollow_feed_check "'"$STATE"'"'
rm -f "$SRV/relay.json.sig"
expect_refused "a missing signature is refused" "could not download" "$CHECK_FETCH"
publish
TEST_KEYS="nothex" expect_refused "a malformed trusted key trusts nothing" "not signed by Hollow's release key" "$CHECK_FETCH"

# The vector rust/hollow_manifest pins in relay_feed_signature_kat.
printf '{"feed":"relay","issued":1}' > "$root/kat.json"
printf 'cGsGP+rCzQDH24xftW/HWjMdNr5odVcpCUfNCv6WxngahE4jfW74Ltcw0MZvEqAQ41dWumAY57A2/D+d6bibDQ==\n' > "$root/kat.sig"
mkdir -p "$root/katwork"
KAT='_hf_verify_sig "'"$root/kat.json"'" "'"$root/kat.sig"'" "'"$root/katwork"'"'
TEST_KEYS=fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618 expect_ok "the signer's known-answer vector verifies" "$KAT"
printf '{"feed":"relay","issued":2}' > "$root/kat.json"
TEST_KEYS=fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618 expect_refused \
    "the known-answer vector over other bytes does not" "not signed" "$KAT"

# An openssl that exits 0 on a failed verification is still refused.
mkdir -p "$root/fakebin"
printf '#!/bin/sh\necho "Signature Verification Failure"\nexit 0\n' > "$root/fakebin/openssl"
chmod +x "$root/fakebin/openssl"
publish
PATH="$root/fakebin:$PATH" expect_refused "an openssl that exits 0 on failure does not pass the feed" "not signed by" "$CHECK_FETCH"
printf '#!/bin/sh\necho "Signature Verified Successfully"\nexit 1\n' > "$root/fakebin/openssl"
PATH="$root/fakebin:$PATH" expect_refused "an openssl that fails while printing success does not pass the feed" "not signed by" "$CHECK_FETCH"
rm -f "$root/fakebin/openssl"

# --- the trusted key list and the origin --------------------------------------------------------
app_keys=$(awk '/^const MANIFEST_SIGNING_PUBKEYS/,/^\];/' "$repo/rust/hollow_core/src/api/updater.rs" \
    | grep -oE '"[0-9a-f]{64}"' | tr -d '"' | sort)
lib_keys=$(bash -c 'source "$1"; _hf_release_keys' _ "$lib" | sort)
if [ -n "$app_keys" ] && [ "$app_keys" = "$lib_keys" ]; then
    ok "the library trusts exactly MANIFEST_SIGNING_PUBKEYS"
else
    bad "the library trusts exactly MANIFEST_SIGNING_PUBKEYS" "app: $app_keys / lib: $lib_keys"
fi
# Neither the old test variables nor an exported function reach the trust path.
prod=$(env HOLLOW_FEED_TEST_PUBKEYS="$PK" HOLLOW_FEED_TEST_BASE="file://$SRV" HOLLOW_FEED_TEST_ARCH=linux-aarch64 \
    "BASH_FUNC__hf_release_keys%%=() { echo $PK; }" "BASH_FUNC__hf_base%%=() { echo file://$SRV; }" \
    "BASH_FUNC__hf_protos%%=() { echo =file; }" \
    bash -c 'source "$1"; _hf_release_keys; _hf_base; echo; _hf_protos; echo' _ "$lib" 2>/dev/null | tr '\n' ' ')
if [ "$prod" = "$RELEASE_PK https://anonlisten.com/hollow/releases =https " ]; then
    ok "nothing in the environment changes the keys, the origin or the protocols"
else
    bad "nothing in the environment changes the keys, the origin or the protocols" "got: $prod"
fi
publish
# The check may pass against the live production feed; it must never take the test one.
took=$(env HOLLOW_FEED_TEST_PUBKEYS="$PK" HOLLOW_FEED_TEST_BASE="file://$SRV" HOLLOW_FEED_TEST_ARCH=linux-x86_64 \
    bash -c "$opts"'; source "$1"; hollow_feed_check "$2" && echo "$FEED_ISSUED"' _ "$lib" "$root/envstate" 2> "$root/err")
rc=$?
if { [ $rc != 0 ] && [ ! -e "$root/envstate" ]; } || { [ $rc = 0 ] && [ "$took" != 1761134400 ]; }; then
    ok "the old test variables never make a check take the test feed"
else
    bad "the old test variables never make a check take the test feed" "rc $rc, issued $took: $(tr '\n' ' ' < "$root/err")"
fi
if bash -c 'source "$1"; _hf_get "file://$2" "$3" 1000 5' _ "$lib" "$SRV/relay.json" "$root/got" 2>/dev/null; then
    bad "production fetches refuse a file URL"
else
    ok "production fetches refuse a file URL"
fi

# --- shape ------------------------------------------------------------------------------------
publish
jq '.feed = "status"' "$SRV/relay.json" > "$root/j" && mv "$root/j" "$SRV/relay.json" && resign
expect_refused "a relay-signed body that is not the relay feed is refused" "not the relay feed" "$CHECK_FETCH"
for edit in '.build = "0"' '.build = 1.5' '.build = 10000' '.issued = "1761134400"' '.issued = 0' '.version = "0.12"' \
    '.version = "0.12.2+1"' '.artifacts["linux-x86_64"].sha256 |= ascii_upcase' '.artifacts["linux-x86_64"].size = 0' \
    '.artifacts["linux-x86_64"].size = 268435457' '.artifacts["linux-x86_64"].size = "5"' 'del(.artifacts["linux-x86_64"].sha256)' \
    '.artifacts = []' '.issued = 1e15' 'del(.commit)' '.commit = 5' '.commit |= ascii_upcase' '.commit = "0123abc"' \
    '.commit += "\n"'; do
    publish
    jq "$edit" "$SRV/relay.json" > "$root/j" && mv "$root/j" "$SRV/relay.json" && resign
    expect_refused "a feed with $edit is refused" "relay update list" "$CHECK_FETCH"
done
for url in "https://evil.example/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz" \
    "http://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz" \
    "https://anonlisten.com/hollow/releases/hollow-relay-0.12.1-linux-x86_64.tar.gz" \
    "https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-aarch64.tar.gz" \
    "https://anonlisten.com/hollow/releases/x/../hollow-relay-0.12.2-linux-x86_64.tar.gz"; do
    publish
    jq --arg u "$url" '.artifacts["linux-x86_64"].url = $u' "$SRV/relay.json" > "$root/j" && mv "$root/j" "$SRV/relay.json" && resign
    expect_refused "a feed naming $url is refused" "expected https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz" "$CHECK_FETCH"
done
for v in 0.12 0.12.2.1 1e2.0.0 0.123456.0; do
    publish
    jq --arg v "$v" '.version = $v | .artifacts["linux-x86_64"].url = "https://anonlisten.com/hollow/releases/hollow-relay-\($v)-linux-x86_64.tar.gz"' \
        "$SRV/relay.json" > "$root/j" && mv "$root/j" "$SRV/relay.json" && resign
    expect_refused "a feed whose version is $v, with a URL to match, is refused" "malformed version" "$CHECK_FETCH"
done
publish build=3
expect_ok "a patch build names its tarball with -b3" "$CHECK_FETCH"' && [ "$FEED_BUILD" = 3 ] && [ "${FEED_URL##*/}" = hollow-relay-0.12.2-b3-linux-x86_64.tar.gz ]'

# --- machine --------------------------------------------------------------------------------
publish arches=linux-aarch64
expect_refused "a feed with no build for this machine is refused" "no relay build for linux-x86_64" "$CHECK_FETCH"
TEST_ARCH=linux-aarch64 expect_ok "the aarch64 entry is used on aarch64" "$CHECK_FETCH"
publish variant=wrongelf
expect_refused "x86_64 binaries refuse binaries built for another machine" "not built for linux-x86_64" "$CHECK_FETCH"
TEST_ARCH=linux-aarch64 expect_refused "aarch64 refuses binaries built for another machine" "not built for linux-aarch64" "$CHECK_FETCH"
publish variant=wrongelf-forwarder
expect_refused "a forwarder built for another machine is refused" "not built for linux-x86_64" "$CHECK_FETCH"
TEST_ARCH=linux-riscv64 expect_refused "a machine the library does not know is refused" "no prebuilt relay for linux-riscv64" "$CHECK_FETCH"
case "$(uname -m)" in
    x86_64) want=linux-x86_64 ;; aarch64) want=linux-aarch64 ;; *) want=none ;;
esac
got=$(bash -c 'source "$1"; hollow_feed_arch' _ "$lib" 2>/dev/null)
[ "$got" = "$want" ] && ok "hollow_feed_arch names this machine ($got)" || bad "hollow_feed_arch names this machine" "got $got, want $want"
# <label> <reason or "" for accepted> <fake dpkg arch> <fake uname -s> <fake uname -m>
arch_case() {
    rm -rf "$root/archbin" && mkdir -p "$root/archbin"
    printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; *) echo Linux ;; esac\n' "$4" "$5" > "$root/archbin/uname"
    printf '#!/bin/sh\necho %s\n' "$3" > "$root/archbin/dpkg"
    chmod +x "$root/archbin"/*
    if PATH="$root/archbin:$PATH" bash -c "$opts"'; source "$1"; hollow_feed_arch' _ "$lib" > "$root/out" 2> "$root/err"; then
        if [ -z "$2" ]; then ok "$1"; else bad "$1" "accepted as $(cat "$root/out")"; fi
    elif [ -n "$2" ] && grep -qF -- "$2" "$root/err"; then
        ok "$1"
    else
        bad "$1" "$(cat "$root/err")"
    fi
}
arch_case "a 32-bit system on a 64-bit arm kernel gets no prebuilt relay" "this system is armhf" armhf Linux aarch64
arch_case "a 32-bit x86 system on a 64-bit kernel gets no prebuilt relay" "this system is i386" i386 Linux x86_64
arch_case "arm64 on aarch64 is linux-aarch64" "" arm64 Linux aarch64
arch_case "another kernel gets no prebuilt relay" "for Linux only" amd64 Darwin x86_64
arch_case "another machine gets no prebuilt relay" "no prebuilt relay for riscv64" riscv64 Linux riscv64

# --- sizes --------------------------------------------------------------------------------------
publish pad=16384
expect_refused "a feed over 16 KiB is refused" "larger than 16384 bytes" "$CHECK_FETCH"
publish
head -c 2000 /dev/zero | tr '\0' 'A' > "$SRV/relay.json.sig"
expect_refused "a signature file over 1 KiB is refused" "larger than 1024 bytes" "$CHECK_FETCH"
publish
t="$SRV/hollow-relay-0.12.2-linux-x86_64.tar.gz"
printf 'x' >> "$t"
expect_refused "a tarball larger than the signed size is refused" "larger than" "$CHECK_FETCH"
publish
truncate -s -1 "$t"
expect_refused "a tarball smaller than the signed size is refused" "wrong size" "$CHECK_FETCH"
# A curl that stops on the size cap (exit 63) after writing the file.
real_curl=$(command -v curl)
printf '#!/bin/sh\n"%s" "$@"\nexit 63\n' "$real_curl" > "$root/fakebin/curl"
chmod +x "$root/fakebin/curl"
publish
PATH="$root/fakebin:$PATH" expect_refused "a download curl stopped at the size cap is refused" "larger than" "$CHECK_FETCH"
# A curl that ignores --max-filesize and sends 64 MiB: the library stops it at the cap.
printf '#!/bin/sh\nhead -c 67108864 /dev/zero\n' > "$root/fakebin/curl"
chmod +x "$root/fakebin/curl"
rm -f "$root/peak"
PATH="$root/fakebin:$PATH" expect_refused "a download over the cap is refused even if curl ignores the cap" "larger than 16384" \
    "ulimit -f 65536; $PEAK_RM; $CHECK_FETCH"
p=$(peak)
[ -n "$p" ] && [ "$p" -le 16385 ] && ok "a curl ignoring the cap writes at most the cap plus one byte ($p)" \
    || bad "a curl ignoring the cap writes at most the cap plus one byte" "wrote ${p:-?} bytes"
rm -f "$root/fakebin/curl"
# A real host that streams forever without Content-Length (curl 7.x ignores --max-filesize then).
port=$((20000 + RANDOM % 20000))
python3 "$here/endless_server.py" "$port" & pids+=($!)
if wait_port "$port"; then
    rm -f "$root/peak"
    start=$(date +%s)
    TEST_BASE="http://127.0.0.1:$port" expect_refused "a host that never stops sending is cut at the cap" "larger than 16384" \
        "ulimit -f 65536; $PEAK_RM; $CHECK_FETCH"
    p=$(peak)
    [ -n "$p" ] && [ "$p" -le 16385 ] && [ $(($(date +%s) - start)) -lt 30 ] \
        && ok "an endless chunked relay.json writes at most the cap plus one byte ($p)" \
        || bad "an endless chunked relay.json writes at most the cap plus one byte" "wrote ${p:-?} bytes in $(($(date +%s) - start)) s"
else
    bad "a host that never stops sending is cut at the cap" "the test server did not start (python3 missing?)"
fi
# The tarball download is capped at the signed size the same way.
publish
cp "$SRV/relay.json" "$SRV/relay.json.sig" "$root/"
port2=$((port + 1))
cat > "$root/half.py" <<'EOF'
import http.server, sys
srv_dir, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        name = self.path.split("?")[0].lstrip("/")
        if name.startswith("relay.json"):
            body = open(srv_dir + "/" + name, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body); return
        self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        frame = b"%x\r\n" % 65536 + b"\0" * 65536 + b"\r\n"
        try:
            while True: self.wfile.write(frame)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
python3 "$root/half.py" "$SRV" "$port2" & pids+=($!)
if wait_port "$port2"; then
    rm -f "$root/peak"
    size=$(stat -c %s "$t")
    TEST_BASE="http://127.0.0.1:$port2" expect_refused "an endless tarball is cut at its signed size" "larger than $size" \
        "ulimit -f 65536; $PEAK_RM; $CHECK_FETCH"
    p=$(peak)
    [ -n "$p" ] && [ "$p" -le $((size + 1)) ] && ok "an endless tarball writes at most its size plus one byte ($p)" \
        || bad "an endless tarball writes at most its size plus one byte" "wrote ${p:-?} bytes, size $size"
else
    bad "an endless tarball is cut at its signed size" "the test server did not start"
fi
# curl never reads a .curlrc: root's, or one `sudo -E` brought along.
port3=$((port + 2))
(cd "$SRV" && exec python3 -m http.server "$port3" --bind 127.0.0.1 > /dev/null 2>&1) & pids+=($!)
mkdir -p "$root/home"
printf 'dump-header = "%s/written-by-curlrc"\n' "$root" > "$root/home/.curlrc"
if wait_port "$port3"; then
    HOME="$root/home" TEST_BASE="http://127.0.0.1:$port3" expect_ok "a check over http passes (control for the .curlrc test)" \
        'hollow_feed_check "'"$STATE"'"'
    [ -e "$root/written-by-curlrc" ] && bad "curl ignores ~/.curlrc" "a .curlrc in HOME made curl write a file" \
        || ok "curl ignores ~/.curlrc"
else
    bad "curl ignores ~/.curlrc" "the test server did not start"
fi
publish
size=$(stat -c %s "$t")
make_tarball "$t" linux-x86_64 0.12.2 0
truncate -s "$size" "$t"
expect_refused "a tarball of the signed size with other bytes is refused" "does not match its sha256" "$CHECK_FETCH"

# --- the tarball's contents ---------------------------------------------------------------------
for variant in symlink hardlink extra missing dir dotslash dup dotdot nested; do
    publish variant=$variant
    expect_refused "a tarball with a $variant entry is refused" "other than the expected files" "$CHECK_FETCH"
done
# The setup's copy: plain files with plain names under install.sh, deploy/ and
# push-sidecar/, bounded, and never one without the files the next update needs.
SETUP_REFUSED="fifoprogram link hardlink device fifo direntry dotdot dotpart absolute otherroot rootfile hidden dash space newline wildcard deep longpart mode777 setuid mode600 big total many dup noinstall nofeedlib nolock"
for kind in $SETUP_REFUSED; do
    publish variant=setup-$kind
    expect_refused "a setup copy with a $kind entry is refused" "other than the expected files" "$CHECK_FETCH"
done
for kind in plain deepok bigok manyok; do
    publish variant=setup-$kind
    expect_ok "a setup copy at its bounds ($kind) is accepted" "$CHECK_FETCH"' && [ -f "'"$DEST"'/setup/install.sh" ]'
done
publish variant=oldstyle
expect_ok "a release without the setup's copy still installs its programs" "$CHECK_FETCH"' &&
    [ "$(ls -A "'"$DEST"'" | tr "\n" " ")" = "VERSION hollow-forwarder hollow-relay " ]'
publish
KEEP_SETUP='mkdir "'"$DEST"'/setup" && echo keep > "'"$DEST"'/setup/k" || exit 9
if '"$CHECK_FETCH"'; then rc=0; else rc=1; fi
[ "$(cat "'"$DEST"'/setup/k")" = keep ] && [ "$(ls -A "'"$DEST"'")" = setup ] && rm -rf "'"$DEST"'/setup"
[ "$rc" = 0 ]'
expect_refused "a fetch into a folder that already holds a setup entry replaces nothing" "already holds a setup entry" "$KEEP_SETUP"
for variant in badversion badcommit nocommit; do
    publish variant=$variant
    expect_refused "a tarball whose VERSION differs from the feed ($variant) is refused" "VERSION does not match" "$CHECK_FETCH"
done
publish variant=modes
expect_ok "modes in the tarball are replaced" "$CHECK_FETCH"' && [ "$(stat -c %a "'"$DEST"'/hollow-relay" "'"$DEST"'/hollow-forwarder" "'"$DEST"'/VERSION" | tr "\n" " ")" = "755 755 644 " ]'
if [ "$(id -u)" = 0 ]; then
    publish variant=owner
    expect_ok "as root, the tarball's owner is not kept" "$CHECK_FETCH"' && [ "$(stat -c %u:%g "'"$DEST"'/hollow-relay" "'"$DEST"'/VERSION" | tr "\n" " ")" = "0:0 0:0 " ]'
else
    echo "  (skipped: the owner test needs root)"
fi
# A tar that leaves an extra file while unpacking: the unpack check alone catches it.
real_tar=$(command -v tar)
printf '#!/bin/bash\n"%s" "$@" || exit $?\nif [ "$1" = -xzf ]; then\n    while [ $# -gt 0 ]; do [ "$1" = -C ] && touch "$2/evil"; shift; done\nfi\n' "$real_tar" > "$root/fakebin/tar"
chmod +x "$root/fakebin/tar"
publish
PATH="$root/fakebin:$PATH" expect_refused "an unpack that leaves anything else is refused" "did not unpack to the expected files" "$CHECK_FETCH"
rm -f "$root/fakebin/tar"
# A tar whose listing hides an extra member: only the three named files are unpacked.
printf '#!/bin/bash\nif [ "$1" = -tzf ] || [ "$1" = -tvzf ]; then "%s" "$@" | grep -v evil; exit 0; fi\nexec "%s" "$@"\n' "$real_tar" "$real_tar" > "$root/fakebin/tar"
chmod +x "$root/fakebin/tar"
publish variant=extra
PATH="$root/fakebin:$PATH" expect_ok "a member the listing missed is never unpacked" "$CHECK_FETCH"' && [ "$(ls -A "'"$DEST"'" | tr "\n" " ")" = "VERSION hollow-forwarder hollow-relay setup " ]'
rm -f "$root/fakebin/tar"
# A tar whose long listing alone hides a member: the two listings disagree.
printf '#!/bin/bash\nif [ "$1" = -tvzf ]; then "%s" "$@" | grep -v evil; exit 0; fi\nexec "%s" "$@"\n' "$real_tar" "$real_tar" > "$root/fakebin/tar"
chmod +x "$root/fakebin/tar"
publish variant=extra
PATH="$root/fakebin:$PATH" expect_refused "a member only one listing shows is refused" "other than the expected files" "$CHECK_FETCH"
make_tarball "$root/v.tgz" linux-x86_64 0.12.2 0 extra
if PATH="$root/fakebin:$PATH" bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$root/v.tgz"; then
    bad "the listing check alone refuses listings that disagree"
else
    ok "the listing check alone refuses listings that disagree"
fi
rm -f "$root/fakebin/tar"

# Each layer alone: the listing check, then what extraction left.
make_tarball "$root/good.tgz" linux-x86_64 0.12.2 0
for variant in symlink hardlink extra missing dir dotslash dup dotdot nested; do
    make_tarball "$root/v.tgz" linux-x86_64 0.12.2 0 "$variant"
    if bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$root/v.tgz"; then
        bad "the listing check alone refuses a $variant entry"
    else
        ok "the listing check alone refuses a $variant entry"
    fi
done
for kind in $SETUP_REFUSED; do
    make_tarball "$root/v.tgz" linux-x86_64 0.12.2 0 "setup-$kind"
    if bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$root/v.tgz"; then
        bad "the listing check alone refuses a setup copy with a $kind entry"
    else
        ok "the listing check alone refuses a setup copy with a $kind entry"
    fi
done
bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$root/good.tgz" && ok "the listing check passes the good tarball" \
    || bad "the listing check passes the good tarball"
make_tarball "$root/v.tgz" linux-x86_64 0.12.2 0 oldstyle
bash -c 'source "$1"; _hf_tar_listing_ok "$2" && [ -z "$_HF_SETUP_LIST" ]' _ "$lib" "$root/v.tgz" \
    && ok "the listing check passes a release without the setup's copy" || bad "the listing check passes a release without the setup's copy"
# One past each bound, with the bound lowered, so the comparison itself is what refuses.
make_tarball "$root/v.tgz" linux-x86_64 0.12.2 0
for bound in "_HF_UNPACKED_CAP=8000" "_HF_SETUP_MAX_FILES=3" "_HF_SETUP_MAX_BYTES=60" "_HF_SETUP_MAX_FILE=30"; do
    if bash -c 'source "$1"; '"$bound"'; _hf_tar_listing_ok "$2"' _ "$lib" "$root/v.tgz"; then
        bad "the listing check refuses a tarball one past $bound"
    else
        ok "the listing check refuses a tarball one past $bound"
    fi
done
extracted_case() { # <label> <expect 0|1> <setup snippet>
    rm -rf "$root/x" && mkdir -p "$root/x" && (cd "$root/x" && eval "$3")
    bash -c 'source "$1"; _hf_extracted_ok "$2"' _ "$lib" "$root/x"
    local rc=$?
    if { [ "$2" = 0 ] && [ "$rc" = 0 ]; } || { [ "$2" = 1 ] && [ "$rc" != 0 ]; }; then ok "$1"; else bad "$1"; fi
}
extracted_case "the unpack check passes three regular files" 0 'touch VERSION hollow-forwarder hollow-relay'
extracted_case "the unpack check refuses a symlink" 1 'touch VERSION hollow-forwarder; ln -s /etc/passwd hollow-relay'
extracted_case "the unpack check refuses a folder" 1 'touch VERSION hollow-forwarder; mkdir hollow-relay'
extracted_case "the unpack check refuses an extra file" 1 'touch VERSION hollow-forwarder hollow-relay evil'
extracted_case "the unpack check refuses a missing file" 1 'touch VERSION hollow-relay'
extracted_case "the unpack check refuses a hidden extra file" 1 'touch VERSION hollow-forwarder hollow-relay .evil'
LISTED='_HF_SETUP_LIST=$'"'"'setup/install.sh\nsetup/deploy/lib/x.sh\n'"'"
setup_case() { # <label> <expect 0|1> <setup snippet>
    rm -rf "$root/x" && mkdir -p "$root/x/setup/deploy/lib" && (cd "$root/x" && touch VERSION hollow-forwarder hollow-relay setup/install.sh setup/deploy/lib/x.sh && eval "$3")
    bash -c 'source "$1"; '"$LISTED"'; _hf_extracted_ok "$2"' _ "$lib" "$root/x"
    local rc=$?
    if { [ "$2" = 0 ] && [ "$rc" = 0 ]; } || { [ "$2" = 1 ] && [ "$rc" != 0 ]; }; then ok "$1"; else bad "$1"; fi
}
setup_case "the unpack check passes the listed setup files" 0 ':'
setup_case "the unpack check refuses an unlisted setup file" 1 'touch setup/deploy/lib/y.sh'
setup_case "the unpack check refuses a setup file that became a link" 1 'rm setup/deploy/lib/x.sh && ln -s /etc/passwd setup/deploy/lib/x.sh'
setup_case "the unpack check refuses a missing setup file" 1 'rm setup/install.sh'
setup_case "the unpack check refuses a folder outside setup/" 1 'mkdir other'
extracted_case "without a setup copy, any folder is refused" 1 'touch VERSION hollow-forwarder hollow-relay && mkdir setup'

# --- the corpus the signer's tests read too -----------------------------------------------------
# Each case gets the verdict cases.txt names, from the whole check and fetch
# and from the listing and unpack checks alone, as the signer gives it
# (feeds.rs: the_signer_gives_every_shared_corpus_case_the_installers_verdict).
CORPUS="$here/corpus"
corpus_n=0
saved_commit=$COMMIT
COMMIT=$(printf 'a%.0s' $(seq 40))
while read -r case want why; do
    case "$case" in "#"* | "") continue ;; esac
    corpus_n=$((corpus_n + 1))
    publish version=0.12.2 build=0 arches=linux-x86_64 variant="corpus-$case"
    if [ "$want" = accept ]; then
        expect_ok "corpus $case is installed: $why" "$CHECK_FETCH"
    else
        expect_refused "corpus $case is refused: $why" "refusing it" "$CHECK_FETCH"
    fi
    rm -rf "$root/x" && mkdir -p "$root/x"
    # shellcheck disable=SC2016
    if bash -c 'source "$1"; _hf_tar_listing_ok "$2" && tar -xzf "$2" -C "$3" --no-same-owner --no-same-permissions -- $_HF_FILES $_HF_SETUP_LIST 2>/dev/null && _hf_extracted_ok "$3"' \
        _ "$lib" "$CORPUS/$case.tar.gz" "$root/x"; then got=accept; else got=refuse; fi
    [ "$got" = "$want" ] && ok "the tarball checks alone $want corpus $case" || bad "the tarball checks alone $want corpus $case" "they $got it"
done < "$CORPUS/cases.txt"
COMMIT=$saved_commit
[ "$corpus_n" -ge 20 ] && ok "the corpus has its $corpus_n cases" || bad "the corpus has its cases" "only $corpus_n"
# The named findings of review D, one line each.
for case in pax_size_over_cap trailing_bytes second_member_link second_member_file mtime_unlistable missing_sourced_lib missing_lockfile; do
    mkdir -p "$root/x2"
    bash -c 'source "$1"; _hf_tar_listing_ok "$2" && tar -xzf "$2" -C "$3" --no-same-owner --no-same-permissions -- $_HF_FILES $_HF_SETUP_LIST 2>/dev/null && _hf_extracted_ok "$3"' \
        _ "$lib" "$CORPUS/$case.tar.gz" "$root/x2" && bad "release_feed refuses corpus $case" || ok "release_feed refuses corpus $case"
    rm -rf "$root/x2"
done
# Each new rule alone: the gzip check, the listing's time bound, the sourced libraries.
for case in trailing_zeros second_member_file empty_last_member; do
    bash -c 'source "$1"; _hf_gzip_ok "$2"' _ "$lib" "$CORPUS/$case.tar.gz" && bad "the gzip check alone refuses $case" || ok "the gzip check alone refuses $case"
done
bash -c 'source "$1"; _hf_gzip_ok "$2"' _ "$lib" "$CORPUS/empty_first_member.tar.gz" && ok "the gzip check passes an empty first member" || bad "the gzip check passes an empty first member"
for case in mtime_first_over pax_mtime_over; do
    bash -c 'source "$1"; _hf_gzip_ok() { return 0; }; _hf_tar_listing_ok "$2"' _ "$lib" "$CORPUS/$case.tar.gz" && bad "the listing's time bound alone refuses $case" || ok "the listing's time bound alone refuses $case"
done
bash -c 'source "$1"; _hf_tar_listing_ok "$2"' _ "$lib" "$CORPUS/mtime_last_ok.tar.gz" && ok "the listing passes the last second" || bad "the listing passes the last second"
# The verbose listing's parse alone: a line it cannot read is refused even
# when the name lists still agree.
# shellcheck disable=SC2016
bash -c 'source "$1"; tar() { command tar "$@"; case " $* " in *" -tvzf "*) echo "?????????? an unreadable line" ;; esac; }; _hf_tar_listing_ok "$2"' _ "$lib" "$CORPUS/control.tar.gz" \
    && bad "the listing refuses a line it cannot parse" || ok "the listing refuses a line it cannot parse"
rm -rf "$root/x" && mkdir -p "$root/x" && tar -xzf "$CORPUS/missing_sourced_lib.tar.gz" -C "$root/x"
LISTED_ALL='_HF_SETUP_LIST=$(cd "$2" && find setup -type f | LC_ALL=C sort)$'"'"'\n'"'"
bash -c 'source "$1"; '"$LISTED_ALL"'; _hf_extracted_ok "$2"' _ "$lib" "$root/x" && bad "the unpack check alone refuses a setup missing a sourced library" \
    || ok "the unpack check alone refuses a setup missing a sourced library"
printf '# ui\n' > "$root/x/setup/deploy/lib/ui.sh"
bash -c 'source "$1"; '"$LISTED_ALL"'; _hf_extracted_ok "$2"' _ "$lib" "$root/x" && ok "and passes it with the library" \
    || bad "and passes it with the library"

# --- a fetch that cannot finish leaves dest as it was ------------------------------------------
publish version=0.12.4
# <label> <setup run in dest> <expected listing after> <expected hollow-relay content or "">
partial_case() {
    run_lib '(cd "'"$DEST"'" && '"$2"') && hollow_feed_check "'"$STATE"'" && hollow_feed_fetch "'"$DEST"'"'
    local rc=$? listing relay=""
    listing=$(cd "$DEST" && find . -mindepth 1 | sort | tr '\n' ' ')
    [ -f "$DEST/hollow-relay" ] && relay=$(cat "$DEST/hollow-relay")
    if [ "$rc" = 0 ]; then
        bad "$1" "the fetch succeeded"
    elif ! grep -qF "nothing was replaced" "$root/err"; then
        bad "$1" "refused for another reason: $(tr '\n' ' ' < "$root/err")"
    elif [ "$listing" != "$3" ] || [ "$relay" != "$4" ]; then
        bad "$1" "dest now: $listing hollow-relay='${relay:0:20}'"
    else
        ok "$1"
    fi
}
partial_case "a first move that fails leaves dest as it was" \
    'mkdir hollow-relay && printf "version=0.12.3\nbuild=0\n" > VERSION' "./VERSION ./hollow-relay " ""
partial_case "a last move that fails puts back the binaries it replaced" \
    'echo OLD > hollow-relay && mkdir -p VERSION/keep' "./VERSION ./VERSION/keep ./hollow-relay " "OLD"
partial_case "a middle move that fails removes the binary it added" \
    'mkdir -p hollow-forwarder/keep' "./hollow-forwarder ./hollow-forwarder/keep " ""

# A run cut short between moves (no undo): VERSION, moved last, still names the old binaries.
run_lib '(cd "'"$DEST"'" && printf "version=0.12.3\nbuild=0\n" > VERSION && mkdir -p hollow-forwarder/keep) &&
    _hf_undo() { return 1; } && hollow_feed_check "'"$STATE"'" && hollow_feed_fetch "'"$DEST"'"'
[ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$(printf 'version=0.12.3\nbuild=0')" ] \
    && ok "a fetch cut short never leaves a VERSION naming binaries that did not land" \
    || bad "a fetch cut short never leaves a VERSION naming binaries that did not land" "$(ls -A "$DEST" | tr '\n' ' ')"

# --- order of calls and cleanup ------------------------------------------------------------------
expect_refused "fetch before any check is refused" "before hollow_feed_fetch" 'hollow_feed_fetch "'"$DEST"'"'
publish key="$root/other.pem"
expect_refused "fetch after a failed check is refused" "before hollow_feed_fetch" \
    'hollow_feed_check "'"$STATE"'" || true; hollow_feed_fetch "'"$DEST"'"'
expect_ok "a failed check leaves no FEED variables" \
    'FEED_URL=stale; hollow_feed_check "'"$STATE"'" || true; [ -z "${FEED_URL+x}" ]'
expect_refused "accept after a failed check records nothing" "before hollow_feed_accept" \
    'hollow_feed_check "'"$STATE"'" || true; hollow_feed_accept "'"$STATE"'"'
[ -e "$STATE/relay_feed_issued" ] && bad "a failed check recorded a mark" || ok "a failed check recorded no mark"
publish
expect_ok "fetch uses the checked values, not FEED variables changed after the check" \
    'hollow_feed_check "'"$STATE"'" && FEED_SHA256=0000000000000000000000000000000000000000000000000000000000000000 FEED_URL=https://evil.example/x && hollow_feed_fetch "'"$DEST"'"'
expect_refused "fetch into a missing folder is refused" "usage: hollow_feed_fetch" \
    'hollow_feed_check "'"$STATE"'" && hollow_feed_fetch "'"$root/nowhere"'"'

# --- newer and installed --------------------------------------------------------------------------
publish version=0.12.2 build=1
newer_case() { # <installed version> <build> <expected rc>
    run_lib 'hollow_feed_check "'"$STATE"'" >/dev/null; hollow_feed_newer "'"$1"'" "'"$2"'"'
    local rc=$?
    [ "$rc" = "$3" ] && ok "feed 0.12.2+1 vs installed $1+$2 returns $3" || bad "feed 0.12.2+1 vs installed $1+$2 returns $3" "got $rc"
}
newer_case 0.12.2 0 0
newer_case 0.12.1 9 0
newer_case 0.9.99 0 0
newer_case 0.12.2 1 1
newer_case 0.12.2 2 1
newer_case 0.13.0 0 1
newer_case 0.012.2 1 1
newer_case 1.0.0 0 1
newer_case "0.12" 0 2
newer_case "0.12.2" "x" 2
export INJ='a[$(touch '"$root"'/pwned2)].0.0'
run_lib 'hollow_feed_check "'"$STATE"'" >/dev/null; hollow_feed_newer "$INJ" 0'
[ $? = 2 ] && ok "hollow_feed_newer refuses a version that is not x.y.z" || bad "hollow_feed_newer refuses a version that is not x.y.z"
[ -e "$root/pwned2" ] && bad "hollow_feed_newer ran a command" || ok "hollow_feed_newer ran nothing"
installed_case() { # <label> <file content (printf format)> <expected "version build commit" or "">
    printf "$2" > "$root/VERSION"
    local got
    got=$(bash -c 'source "$1"; hollow_feed_installed "$2" && echo "$INSTALLED_VERSION $INSTALLED_BUILD $INSTALLED_COMMIT"' _ "$lib" "$root/VERSION" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || bad "$1" "got '$got'"
}
installed_case "a version marker reads" 'version=0.12.2\nbuild=3\n' "0.12.2 3 "
installed_case "a marker with its commit reads" "version=0.12.2\nbuild=3\ncommit=$COMMIT\n" "0.12.2 3 $COMMIT"
installed_case "a marker with an extra line is refused" 'version=0.12.2\nbuild=3\nx\n' ""
installed_case "a marker with a line after its commit is refused" "version=0.12.2\nbuild=3\ncommit=$COMMIT\nx\n" ""
installed_case "a marker with a short commit is refused" 'version=0.12.2\nbuild=3\ncommit=abc\n' ""
installed_case "a marker without its build is refused" 'version=0.12.2\n' ""
installed_case "a marker with a bad version is refused" 'version=0.12\nbuild=0\n' ""

echo "release_feed ($opts): $pass passed, $fail failed"
rc=0
[ "$fail" = 0 ] || rc=1
if [ "${RELEASE_FEED_STRICT:-}" != 1 ]; then
    RELEASE_FEED_STRICT=1 bash "$0" || rc=1
fi
exit "$rc"
