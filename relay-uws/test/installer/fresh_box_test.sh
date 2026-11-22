#!/bin/bash
# A first install on a box with only what a stock server install has (no curl,
# jq, git or rsync on Debian), from a throwaway signed feed, net_get against
# redirects, then updates of that relay: one whose release carries a newer
# setup and units, a run from the older clone, tampered setups, setups that
# cannot start, one from before the setup rode along, runs killed around the
# setup's swap and finished by the next one, and updates whose relay does not
# start or whose settings fail, each put back whole. Runs inside a throwaway
# container from run_systemd_tests.sh, never on a real machine.
#
#   bash fresh_box_test.sh
#
# /root/relay.bin is a relay built for this box's system. Let's Encrypt is a
# self-signed staging-style lineage and certbot a stand-in that renews nothing.
# FRESH_ONLY=libs runs only a first install whose release needs a library this
# system does not offer, which the setup builds from source instead (#153).
# FRESH_ONLY=fwdsrc runs only such a first install with the forwarder, built
# from source to the end (an hour or two). FRESH_ONLY=mixed runs a first
# install and updates where only the relay's library is missing, so the
# official signed forwarder (fetched for this machine) is installed and the
# relay is built here.
# shellcheck disable=SC2034
set -uo pipefail
[ "${HOLLOW_INSTALLER_TEST_BOX:-}" = 1 ] || { echo "Runs only inside the test container (run_systemd_tests.sh)." >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Runs as root." >&2; exit 2; }

SRC=/src
FEED=/root/feed
W=/root/fresh-test
# The fake releases carry the version the setup's floor names: an older one is refused.
REL=$(sed -n 's/^_HF_MIN_VERSION=//p' "$SRC/relay-uws/deploy/lib/release_feed.sh")
LIB=/usr/local/lib/hollow-relay
mkdir -p "$W" "$FEED"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: missing [$3]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: should not contain [$3]"; else ok "$1"; fi; }
yes_() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
no_()  { local n=$1; shift; if "$@"; then bad "$n"; else ok "$n"; fi; }
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
tree_sum() { (cd "$1" && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -c1-16); }
finish() {
    echo ""
    echo "fresh box: $pass passed, $fail failed"
    [ "$fail" = 0 ]
    exit $?
}

. /etc/os-release
echo "box: $PRETTY_NAME (stock packages)"

echo "a stock server"
if [ "$ID" = debian ]; then
    no_ "Debian has no curl" command -v curl
fi
no_ "nor jq" command -v jq
no_ "nor git" command -v git
yes_ "it has whiptail" command -v whiptail
yes_ "and a program to download with" sh -c 'command -v curl || command -v wget || command -v python3' >/dev/null

# Kernel-wide settings a privileged container shares with its host.
SAFE=$W/safe
mkdir -p "$SAFE"
for c in swapoff sysctl timedatectl; do printf '#!/bin/sh\nexit 0\n' >"$SAFE/$c"; chmod +x "$SAFE/$c"; done

# ---------------------------------------------------------------- stand-ins

# The address the internet sees, through the same helper the setup uses.
. "$SRC/relay-uws/deploy/lib/common.sh"
. "$SRC/relay-uws/deploy/lib/preflight.sh"
PUBLIC_IP=$(public_ipv4) || { bad "this box reaches the internet over IPv4 with $(net_tool)"; finish; }
ok "the public address comes through $(net_tool): $PUBLIC_IP"
# Each program net_get can use reaches the internet the same way.
for FORCE_TOOL in curl wget python3; do
    command -v "$FORCE_TOOL" >/dev/null || { echo "skip  no $FORCE_TOOL here"; continue; }
    got=$(net_tool() { echo "$FORCE_TOOL"; }; net_get -4 https://api.ipify.org 8 | tr -d '[:space:]')
    eq "net_get through $FORCE_TOOL sees the same address" "$got" "$PUBLIC_IP"
done

mkdir -p /snap/bin
cat >/snap/bin/certbot <<'EOF'
#!/bin/sh
echo "certbot $*" >>/root/fresh-test/certbot.calls
case "$1" in certonly) echo "Certificate not yet due for renewal; no action taken." ;; esac
exit 0
EOF
chmod 0755 /snap/bin/certbot
le=/etc/letsencrypt
mkdir -p "$le/archive/relay" "$le/live/relay" "$le/renewal" "$le/renewal-hooks/deploy"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 6 -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP" -keyout "$le/archive/relay/privkey1.pem" \
    -out "$le/archive/relay/cert1.pem" >/dev/null 2>&1
for f in chain fullchain; do cp "$le/archive/relay/cert1.pem" "$le/archive/relay/${f}1.pem"; done
chmod 0600 "$le/archive/relay/privkey1.pem"
for f in cert chain fullchain privkey; do ln -sfn "../../archive/relay/${f}1.pem" "$le/live/relay/$f.pem"; done
cat >"$le/renewal/relay.conf" <<EOF
version = 5.8.0
archive_dir = $le/archive/relay
cert = $le/live/relay/cert.pem
privkey = $le/live/relay/privkey.pem
chain = $le/live/relay/chain.pem
fullchain = $le/live/relay/fullchain.pem

[renewalparams]
account = 0123456789abcdef
authenticator = standalone
server = https://acme-staging-v02.api.letsencrypt.org/directory
key_type = ecdsa
EOF

# ---------------------------------------------------------------- the test feed

openssl genpkey -algorithm ed25519 -out "$W/feed.pem" 2>/dev/null
# One key per line, as the library reads its list.
printf '%s\n' "$(openssl pkey -in "$W/feed.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')" >"$FEED/pubkey.hex"
# The box's copy of the feed library reads the throwaway feed; the copies the
# releases below carry are made from it, so every later update does too.
cat >>"$SRC/relay-uws/deploy/lib/release_feed.sh" <<'EOF'
_hf_release_keys() { cat /root/feed/pubkey.hex; }
_hf_base() { printf 'file:///root/feed'; }
_hf_protos() { printf '=file'; }
EOF
# The stand-in relay links to this system's own libraries, not the official
# build's (scripts/build_relay_binaries.sh), so the setup judges by its list.
RELAY_NEEDS=$(LC_ALL=C ldd /root/relay.bin | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => .*/\1/p' | grep -v '^linux-vdso' | tr '\n' ' ')
printf '\nPREBUILT_NEEDS="%s"\n' "$RELAY_NEEDS" >>"$SRC/relay-uws/deploy/lib/native.sh"
# The same relay asking for a libsodium no system has.
python3 -I -c 'import re, sys; b = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(re.sub(rb"libsodium\.so\.\d\d", b"libsodium.so.99", b))' \
    /root/relay.bin "$W/relay99.bin"
chmod 0755 "$W/relay99.bin"
# The setup a release carries, marked so a run shows which copy it is.
setup_tree() { # <dir> <mark>
    rm -rf "$1"
    bash "$SRC/scripts/build_relay_binaries.sh" --stage-setup "$SRC" "$1" || return 1
    sed -i "2i # SETUP MARK $2" "$1/install.sh"
    # Its units carry the mark too, so a run shows which setup wrote them.
    sed -i "1i # SETUP MARK $2" "$1/deploy/hollow-coturn.service"
}
ISSUED=$(date +%s)
# The feed names a release per machine type; this box's is the one the setup asks for.
case "$(uname -m)" in aarch64 | arm64) ARCH=linux-aarch64 ;; *) ARCH=linux-x86_64 ;; esac
# publish <build> <kind>: kind setup (a release with its setup, marked
# b<build>), old (programs only), extra, link, dotdot, big (a tampered setup),
# noui or cannotstart (a setup that cannot start), badsettings (a setup whose
# settings run fails), dead (a relay that does not start, with its setup) or
# nolib (a relay that needs a library no system offers, with its setup).
# FWD_BIN names the forwarder a release carries (the stand-in relay otherwise).
publish() {
    local b=$1 kind=$2 s=$W/stage name sha size relay=/root/relay.bin
    rm -rf "$s" "$FEED"/*.tar.gz && mkdir -p "$s"
    [ "$kind" = dead ] && relay=/bin/false
    [ "$kind" = nolib ] && relay=$W/relay99.bin
    install -m 0755 "$relay" "$s/hollow-relay"
    install -m 0755 "${FWD_BIN:-/root/relay.bin}" "$s/hollow-forwarder"
    printf 'version=%s\nbuild=%s\ncommit=%s\n' "$REL" "$b" "$(printf '%040d' 0)" >"$s/VERSION"
    chmod 0644 "$s/VERSION"
    [ "$kind" = old ] || setup_tree "$s/setup" "b$b"
    case "$kind" in
    extra) echo 'echo evil' >"$s/setup/evil.sh" ;;
    link) ln -s /etc/shadow "$s/setup/deploy/lib/evil.sh" ;;
    big) head -c 1048577 /dev/zero | tr '\0' '#' >"$s/setup/deploy/lib/big.sh" ;;
    noui) rm "$s/setup/deploy/lib/ui.sh" ;;
    cannotstart) printf 'false\n' >>"$s/setup/deploy/lib/questions.sh" ;;
    badsettings) printf '#!/bin/sh\nexit 7\n' >"$s/setup/deploy/harden-host.sh" ;;
    esac
    name="hollow-relay-$REL-b$b-$ARCH.tar.gz"
    case "$kind" in
    link | dotdot)
        local tf=()
        [ "$kind" = dotdot ] && tf=(-P --transform 's,^setup/deploy/lib/common.sh$,setup/../../etc/cron.d/evil,')
        (cd "$s" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort |
            tar --owner=0 --group=0 --no-recursion "${tf[@]}" -T - -czf "$FEED/$name") ;;
    *) bash "$SRC/scripts/build_relay_binaries.sh" --pack "$s" "$FEED/$name" ;;
    esac
    sha=$(sha256sum "$FEED/$name" | cut -d' ' -f1)
    size=$(stat -c %s "$FEED/$name")
    ISSUED=$((ISSUED + 1))
    printf '{"feed":"relay","version":"%s","build":%s,"issued":%s,"commit":"%s","artifacts":{"%s":{"url":"https://anonlisten.com/hollow/releases/%s","sha256":"%s","size":%s}}}\n' \
        "$REL" "$b" "$ISSUED" "$(printf '%040d' 0)" "$ARCH" "$name" "$sha" "$size" >"$FEED/relay.json"
    { printf 'hollow-feed-sig-v1\0relay\0'; cat "$FEED/relay.json"; } >"$W/msg"
    openssl pkeyutl -sign -inkey "$W/feed.pem" -rawin -in "$W/msg" -out "$W/sig.bin"
    { base64 -w0 "$W/sig.bin"; echo; } >"$FEED/relay.json.sig"
    rm -rf "$s" "$W/msg" "$W/sig.bin"
}

relay_up() { for _ in $(seq 1 30); do systemctl is-active --quiet hollow-relay && return 0; sleep 1; done; return 1; }

# a_first_install_builds_from_source_where_the_release_needs_a_missing_library
# (#153): the download is checked before anything is installed.
if [ "${FRESH_ONLY:-}" = libs ]; then
    echo "first install, the release needs a library this system does not offer"
    publish 1 nolib
    cat >"$W/ans_libs" <<EOF
mode=native
binaries=prebuilt
address=ip
public_ip=$PUBLIC_IP
ip=$PUBLIC_IP
staging=yes
turn=no
push=no
forwarder=no
members_only=no
ssh_keys=no
continue_anyway=yes
confirm=yes
EOF
    PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_libs" >"$W/libs.out" 2>&1
    rc=$?
    eq "the install finishes" "$rc" 0
    out=$(flat "$W/libs.out")
    [ "$rc" = 0 ] || { tail -n 40 "$W/libs.out"; finish; }
    has "it says why it builds here" "$out" "there are no ready-made programs for this machine (they need libsodium.so.99, which $PRETTY_NAME does not offer), so I build them from source instead"
    has "and builds" "$out" "Building the relay from source"
    lacks "the download was never installed" "$out" "signature and checksum verified"
    eq "the programs are a build from here" "$(head -n 1 "$LIB/BUILT_FROM")" source
    eq "and remembered as one" "$(sed -n 's/^binaries=//p' /etc/hollow-relay/install.conf)" source
    lacks "the relay is not the download" "$(LC_ALL=C ldd /usr/local/bin/hollow-relay)" libsodium.so.99
    yes_ "the relay runs" relay_up
    # An operator with SSH keys turns password logins off (ssh_keys=no left them).
    mkdir -p /etc/ssh/sshd_config.d && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/00-box-keys.conf
    # sshd -T needs the folder sshd makes at its first login, which a socket-started sshd (24.04) has not had.
    install -d -m 0755 /run/sshd
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
    echo "--- check-host after the build from source"
    printf '%s\n' "$check"
    echo "--- end of check-host"
    # kernel.core_pattern is the box host's, which the stand-in sysctl leaves alone.
    eq "check-host prints only ok and skip" "$(grep -vE '^  (ok|skip)  |^  \(|^[^ ]' <<<"$check" | grep -v 'kernel.core_pattern is ')" ""
    has "the relay finds its libraries" "$check" "ok    hollow-relay's program /usr/local/bin/hollow-relay finds every library it needs"
    # check_host_names_a_library_the_relay_lost: a release upgrade can take one away.
    so=$(LC_ALL=C ldd /usr/local/bin/hollow-relay | sed -n 's/^[[:space:]]*\(libsodium[^[:space:]]*\) => \(\/[^[:space:]]*\).*/\1 \2/p' | head -n 1)
    lib=${so#* } so=${so%% *}
    if [ -n "$lib" ] && [ -f "$(readlink -f "$lib")" ]; then
        real=$(readlink -f "$lib")
        # Out of the library folder: ldconfig links any lib*.so* file it finds there.
        mv "$real" /root/hidden-libsodium && ldconfig
        has "check-host names the missing library" "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)" \
            "FAIL  hollow-relay cannot start: /usr/local/bin/hollow-relay needs $so, which this system does not have"
        mv /root/hidden-libsodium "$real" && ldconfig
        has "and passes once it is back" "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)" \
            "ok    hollow-relay's program /usr/local/bin/hollow-relay finds every library it needs"
    else
        bad "the relay links to a libsodium this check can find ($so $lib)"
    fi
    # The official build's own list, judged by this system's real package lists:
    # Ubuntu 26.10 offers only libsodium.so.26, and still the forwarder's libcrypto.so.3.
    out=$(cd / && bash "$SRC/relay-uws/test/installer/fresh_box_offered.sh")
    if apt-cache policy libsodium23 | grep 'Candidate: [0-9]' >/dev/null; then
        eq "this system offers what the official programs need" "$out" offered
    else
        eq "this system offers only the official forwarder's libraries" "$out" "forwarder only: they need libsodium.so.23, which $PRETTY_NAME does not offer"
    fi
    finish
fi

# a_first_install_keeps_the_signed_forwarder_and_builds_the_relay (#153):
# Ubuntu 26.10 offers the official forwarder's libraries but not the relay's,
# and the updates of such a relay: from the menu, from the clone, one whose
# relay does not start, and one whose relay runs here at last.
if [ "${FRESH_ONLY:-}" = mixed ]; then
    echo "first install, the release's relay needs a library this system does not offer and its forwarder runs"
    # The official forwarder for this machine, as the public release list names it.
    python3 -I - "$ARCH" "$W/official.tar.gz" <<'PY' || { bad "the official release for this machine could be fetched"; finish; }
import hashlib, json, sys, urllib.request
feed = json.load(urllib.request.urlopen("https://anonlisten.com/hollow/releases/relay.json", timeout=60))
art = feed["artifacts"][sys.argv[1]]
data = urllib.request.urlopen(art["url"], timeout=300).read()
assert hashlib.sha256(data).hexdigest() == art["sha256"], "checksum"
open(sys.argv[2], "wb").write(data)
PY
    mkdir -p "$W/official" && tar -C "$W/official" -xzf "$W/official.tar.gz" hollow-forwarder
    FWD_BIN=$W/official/hollow-forwarder
    yes_ "the official forwarder is a program for this machine" test -x "$FWD_BIN"
    # The release is this clone's version: only then is the relay built beside it.
    REL=$(sed -n 's/^#define HOLLOW_RELAY_VERSION "\(.*\)"/\1/p' "$SRC/relay-uws/src/version.h")
    publish 1 nolib
    cat >"$W/ans_mixed" <<EOF
mode=native
binaries=prebuilt
address=ip
public_ip=$PUBLIC_IP
ip=$PUBLIC_IP
staging=yes
turn=no
push=no
forwarder=yes
members_only=no
ssh_keys=no
continue_anyway=yes
confirm=yes
EOF
    PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_mixed" >"$W/mixed.out" 2>&1
    rc=$?
    eq "the install finishes" "$rc" 0
    [ "$rc" = 0 ] || { tail -n 40 "$W/mixed.out"; finish; }
    out=$(flat "$W/mixed.out")
    has "it says what it does" "$out" "the release's relay cannot run here (they need libsodium.so.99, which $PRETTY_NAME does not offer), so I build the relay from this copy of the repository and install the release's signed forwarder"
    has "and how it ended" "$out" "the forwarder from the signed release, signature and checksum verified, and the relay built here"
    lacks "it never builds the forwarder" "$out" "compiling the media forwarder"
    eq "the forwarder is the signed release's" "$(cmp /usr/local/bin/hollow-forwarder "$FWD_BIN" && echo same)" same
    lacks "the relay is a build from here" "$(LC_ALL=C ldd /usr/local/bin/hollow-relay)" libsodium.so.99
    eq "BUILT_FROM says mixed" "$(head -n 1 "$LIB/BUILT_FROM")" mixed
    has "and what the relay was built from" "$(sed -n 2p "$LIB/BUILT_FROM")" "the copy of the repository at $SRC"
    eq "VERSION is the release's" "$(sed -n 's/^build=//p' "$LIB/VERSION")" 1
    eq "the choice stays the ready-made programs" "$(sed -n 's/^binaries=//p' /etc/hollow-relay/install.conf)" prebuilt
    yes_ "the relay runs" relay_up
    fwd_up() { for _ in $(seq 1 30); do systemctl is-active --quiet hollow-forwarder && return 0; sleep 1; done; return 1; }
    yes_ "the forwarder runs" fwd_up
    mkdir -p /etc/ssh/sshd_config.d && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/00-box-keys.conf
    # sshd -T needs the folder sshd makes at its first login, which a socket-started sshd (24.04) has not had.
    install -d -m 0755 /run/sshd
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
    echo "--- check-host after the mixed install"
    printf '%s\n' "$check"
    echo "--- end of check-host"
    eq "check-host prints only ok and skip" "$(grep -vE '^  (ok|skip)  |^  \(|^[^ ]' <<<"$check" | grep -v 'kernel.core_pattern is ')" ""
    has "the forwarder finds its libraries" "$check" "ok    hollow-forwarder's program /usr/local/bin/hollow-forwarder finds every library it needs"
    has "the status screen says how" "$(printf 'action=status\n' >"$W/ans_mstatus"; hollow-relay-setup --answers "$W/ans_mstatus" 2>&1 | tr '\n' ' ' | tr -s ' ')" "built here from source, beside the ready-made forwarder"
    # mixed_counts_as_the_ready_made_choice: a settings change rebuilds nothing.
    printf 'action=change\nchange=grace\ngrace_secs=150\nconfirm=yes\n' >"$W/ans_mgrace"
    PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_mgrace" >"$W/mgrace.out" 2>&1
    eq "a settings change finishes" "$?" 0
    has "keeping the programs" "$(flat "$W/mgrace.out")" "the relay programs are already installed"
    lacks "building nothing" "$(flat "$W/mgrace.out")" "compiling the relay"
    eq "the pair stays mixed" "$(head -n 1 "$LIB/BUILT_FROM")" mixed

    printf 'action=update\nconfirm=yes\n' >"$W/ans_update"
    mupdate() { # <label> <how>: the menu's update from the installed setup, or from the clone
        local rc=0
        if [ "$2" = clone ]; then
            PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_update" >"$W/$1.out" 2>&1 || rc=$?
        else
            PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_update" >"$W/$1.out" 2>&1 || rc=$?
        fi
        return "$rc"
    }
    echo "an update of the mixed pair from the menu"
    publish 2 nolib
    mupdate m2 menu
    out=$(flat "$W/m2.out")
    has "the installed setup cannot build the relay, so it stops" "$out" "it cannot be built here either, because this copy of the setup has no relay sources next to it. Nothing was installed."
    has "and says where to update from" "$out" "check out the release's tag in your copy of the repository and run sudo bash relay-uws/install.sh from it"
    eq "the relay is build 1 still" "$(sed -n 's/^build=//p' "$LIB/VERSION")" 1
    no_ "the update left no mark" test -e /var/lib/hollow-installer/update_pending
    echo "the same update from the clone"
    mupdate m2c clone
    rc=$?
    out=$(flat "$W/m2c.out")
    eq "it finishes" "$rc" 0
    [ "$rc" = 0 ] || tail -n 30 "$W/m2c.out"
    has "building only the relay" "$out" "so I build the relay from this copy of the repository and install the release's signed forwarder"
    eq "to build 2" "$(sed -n 's/^build=//p' "$LIB/VERSION")" 2
    eq "mixed again" "$(head -n 1 "$LIB/BUILT_FROM")" mixed
    eq "the pair it replaced is kept for a rollback" "$(head -n 1 "$LIB/previous/BUILT_FROM")" mixed
    yes_ "the relay runs" relay_up
    yes_ "the forwarder runs" fwd_up
    echo "a release whose relay runs here but does not start"
    publish 3 dead
    mupdate m3 menu
    has "the update is undone" "$(flat "$W/m3.out")" "Update undone"
    eq "the relay is build 2 again" "$(sed -n 's/^build=//p' "$LIB/VERSION")" 2
    eq "the mixed pair is back" "$(head -n 1 "$LIB/BUILT_FROM")" mixed
    lacks "with the relay built here" "$(LC_ALL=C ldd /usr/local/bin/hollow-relay)" libsodium.so.99
    yes_ "the relay runs" relay_up
    echo "a release whose relay runs here at last"
    publish 4 setup
    mupdate m4 menu
    rc=$?
    eq "the update finishes" "$rc" 0
    [ "$rc" = 0 ] || tail -n 30 "$W/m4.out"
    has "with the signed pair" "$(flat "$W/m4.out")" "installed version $REL (build 4), signature and checksum verified"
    eq "BUILT_FROM says prebuilt" "$(cat "$LIB/BUILT_FROM")" prebuilt
    eq "the relay is the release's" "$(cmp /usr/local/bin/hollow-relay /root/relay.bin && echo same)" same
    yes_ "the relay runs" relay_up
    yes_ "the forwarder runs" fwd_up
    has "the status screen says ready-made" "$(printf 'action=status\n' >"$W/ans_mstatus"; hollow-relay-setup --answers "$W/ans_mstatus" 2>&1 | tr '\n' ' ' | tr -s ' ')" "(ready-made, build 4"
    finish
fi

# a_first_install_builds_the_forwarder_from_source (#153): the whole build,
# cargo's two-name output included, to a running forwarder. Takes an hour or two.
if [ "${FRESH_ONLY:-}" = fwdsrc ]; then
    echo "first install, relay and forwarder built from source"
    publish 1 setup
    cat >"$W/ans_fwd" <<EOF
mode=native
binaries=source
address=ip
public_ip=$PUBLIC_IP
ip=$PUBLIC_IP
staging=yes
turn=no
push=no
forwarder=yes
members_only=no
ssh_keys=no
continue_anyway=yes
confirm=yes
EOF
    t0=$(date +%s)
    PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_fwd" >"$W/fwd.out" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "the install took $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"
    grep -E 'built in|peak memory|^Stopped' "$W/fwd.out"
    eq "the install finishes" "$rc" 0
    [ "$rc" = 0 ] || { tail -n 40 "$W/fwd.out"; finish; }
    out=$(flat "$W/fwd.out")
    has "it builds the forwarder" "$out" "compiling the media forwarder"
    eq "the programs are a build from here" "$(head -n 1 "$LIB/BUILT_FROM")" source
    no_ "the forwarder is the build's, not the download" cmp -s /usr/local/bin/hollow-forwarder /root/relay.bin
    no_ "the build leaves no copies behind" test -e /var/cache/hollow-build/out
    yes_ "cargo's files stay for the next build" test -f /var/cache/hollow-build/target/release/hollow-forwarder
    yes_ "the relay runs" relay_up
    fwd_up() { for _ in $(seq 1 30); do systemctl is-active --quiet hollow-forwarder && return 0; sleep 1; done; return 1; }
    yes_ "the forwarder runs" fwd_up
    mkdir -p /etc/ssh/sshd_config.d && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/00-box-keys.conf
    # sshd -T needs the folder sshd makes at its first login, which a socket-started sshd (24.04) has not had.
    install -d -m 0755 /run/sshd
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
    echo "--- check-host after the build from source"
    printf '%s\n' "$check"
    echo "--- end of check-host"
    eq "check-host prints only ok and skip" "$(grep -vE '^  (ok|skip)  |^  \(|^[^ ]' <<<"$check" | grep -v 'kernel.core_pattern is ')" ""
    has "the forwarder finds its libraries" "$check" "ok    hollow-forwarder's program /usr/local/bin/hollow-forwarder finds every library it needs"
    # a_rebuild_reuses_the_forwarders_compiled_parts: cargo's target folder stays.
    printf 'action=rebuild\nconfirm=yes\n' >"$W/ans_rebuild"
    t0=$(date +%s)
    PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_rebuild" >"$W/rebuild.out" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "the rebuild took $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"
    grep -E 'built in' "$W/rebuild.out"
    eq "a rebuild from the same copy finishes" "$rc" 0
    [ "$rc" = 0 ] || tail -n 30 "$W/rebuild.out"
    yes_ "the forwarder runs after it" fwd_up
    finish
fi

# ---------------------------------------------------------------- first install

echo "first install, nothing preinstalled"
printf 'action=status\n' >"$W/ans_status0"
# The TURN section of check-host's output <text>.
turn_part() { sed -n '/^TURN$/,/^[A-Za-z]/p' <<<"$1"; }
publish 1 setup
cat >"$W/ans_install" <<EOF
mode=native
binaries=prebuilt
address=ip
public_ip=$PUBLIC_IP
ip=$PUBLIC_IP
staging=yes
turn=yes
push=no
forwarder=no
members_only=no
ssh_keys=no
continue_anyway=yes
confirm=yes
EOF
PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_install" >"$W/install.out" 2>&1
rc=$?
eq "the first install finishes" "$rc" 0
out=$(flat "$W/install.out")
lacks "the machine check reaches the internet without curl" "$out" "could not reach the internet"
lacks "and never names a missing download program" "$out" "none of curl, wget or python3"
has "the plan was confirmed" "$out" "Answer from the file (confirm): yes"
has "the signed programs were installed" "$out" "installed version $REL (build 1), signature and checksum verified"
[ "$rc" = 0 ] || { tail -n 40 "$W/install.out"; finish; }
yes_ "the relay runs" relay_up
yes_ "curl came with the setup, after the plan" command -v curl
yes_ "and jq" command -v jq
has "the setup's copy is the clone's" "$(sed -n 2p "$LIB/installer/install.sh")" "# Hollow relay setup"
has "hollow-relay-setup runs it" "$(hollow-relay-setup --help)" "sudo bash install.sh"
# An operator with SSH keys turns password logins off (ssh_keys=no left them).
mkdir -p /etc/ssh/sshd_config.d && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/00-box-keys.conf
# sshd -T needs the folder sshd makes at its first login, which a socket-started sshd (24.04) has not had.
install -d -m 0755 /run/sshd
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "daily security updates"
dump=$(apt-config dump)
has "apt's daily job fetches the lists" "$dump" 'APT::Periodic::Update-Package-Lists "1";'
has "and installs the updates" "$dump" 'APT::Periodic::Unattended-Upgrade "1";'
if [ "$ID" = debian ]; then
    yes_ "Debian gets the file dpkg-reconfigure writes" test -f /etc/apt/apt.conf.d/20auto-upgrades
    has "from Debian's security archive" "$(apt-config dump Unattended-Upgrade::Origins-Pattern)" "label=Debian-Security"
else
    has "from Ubuntu's security archive" "$(apt-config dump Unattended-Upgrade::Allowed-Origins)" '${distro_codename}-security'
fi
check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
has "check-host passes them" "$check" "ok    unattended-upgrades installs security updates every day"

# a_first_install_with_turn_puts_the_port_lock_in_place
echo "the TURN port lock on a stock server"
yes_ "nftables came with the setup" command -v nft
part=$(turn_part "$check")
eq "check-host passes every TURN check" "$(grep FAIL <<<"$part")" ""
has "with the port lock in front of every address" "$part" "ok    on every ip address of this machine but loopback TURN reaches only ports 49152-65535"
has "and loaded again every minute" "$part" "ok    the TURN port lock loads again every minute"
has "coturn starts only with the lock" "$(systemctl show -p Requires --value hollow-coturn)" hollow-turn-port-lock.service
has "check-host finds no report key on the disk" "$check" "ok    no report key on the disk beside the reports"
has "the status screen shows the lock" "$(hollow-relay-setup --answers "$W/ans_status0" 2>&1)" "TURN port lock: on"
has "and the public stats page" "$(hollow-relay-setup --answers "$W/ans_status0" 2>&1)" "Public stats page: on"
eq "relay.env names it" "$(sed -n 's/^PUBLIC_STATS=//p' /etc/hollow-relay/relay.env)" on

# a_first_install_shares_the_upload_fairly (AR-01): on by default, from an
# answer file that never names it.
echo "the fair-share shaper on a stock server"
echo "--- check-host after the first install"
printf '%s\n' "$check"
echo "--- end of check-host"
# check_host_prints_only_ok_after_a_first_install; kernel.core_pattern is the
# box host's, which the stand-in sysctl leaves alone.
eq "check-host prints only ok and skip" "$(grep -vE '^  (ok|skip)  |^  \(|^[^ ]' <<<"$check" | grep -v 'kernel.core_pattern is ')" ""
fair_part() { sed -n '/^Fair share$/,/^[A-Za-z]/p' <<<"$1"; }
stats() {
    local out
    for _ in $(seq 1 15); do
        out=$(curl -sk --max-time 5 --connect-to "$PUBLIC_IP:443:127.0.0.1:443" "https://$PUBLIC_IP/server-stats") && [ -n "$out" ] &&
            { printf '%s' "$out"; return 0; }
        sleep 1
    done
}
cake_dev=$(sed -n 's/^HOLLOW_CAKE_DEV=//p' /etc/hollow-relay/cake.env)
cake_mbit=$(sed -n 's/^HOLLOW_CAKE_MBIT=//p' /etc/hollow-relay/cake.env)
part=$(fair_part "$check")
eq "check-host passes the shaper" "$(grep FAIL <<<"$part")" ""
has "CAKE shares the upload of the default route's device" "$part" "ok    the upload is shared fairly between the hosts this machine sends to (CAKE, $cake_mbit Mbit/s on $cake_dev)"
has "the shaper sits in its sandbox" "$check" "ok    hollow-cake is sandboxed"
has "as no account that can become root" "$check" "ok    hollow-cake runs as hollow-cake, which cannot become root"
eq "its settings are root's alone" "$(stat -c '%a %U' /etc/hollow-relay/cake.env)" "600 root"
speed=$(cat "/sys/class/net/$cake_dev/speed" 2>/dev/null)
if [[ "$speed" =~ ^[0-9]{2,6}$ ]]; then
    eq "at 90 percent of the line" "$cake_mbit" $((speed * 9 / 10))
else
    eq "at the 1 Gbit/s guess for a card with no speed" "$cake_mbit" 900
fi
has "the relay names the shaper's cap" "$(stats)" "\"bandwidth_cap_mbps\":$cake_mbit"
has "the status screen shows it" "$(hollow-relay-setup --answers "$W/ans_status0" 2>&1)" "Fair share of the upload: on, $cake_mbit Mbit/s on $cake_dev"
systemctl stop hollow-cake
part=$(fair_part "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)")
echo "--- check-host's fair share with the shaper stopped"
printf '%s\n' "$part"
has "a stopped shaper fails check-host" "$part" "FAIL  the fair-share shaper (CAKE) is not on $cake_dev"
systemctl start hollow-cake
# turning_the_shaper_off_from_the_menu_is_an_ok_line
printf 'action=change\nchange=cake\ncake=off\nconfirm=yes\n' >"$W/ans_cake_off"
PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_cake_off" >"$W/cake_off.out" 2>&1
rc=$?
eq "the menu turns it off" "$rc" 0
[ "$rc" = 0 ] || tail -n 30 "$W/cake_off.out"
check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
has "off is an ok line" "$(fair_part "$check")" "ok    the fair-share shaper (CAKE) is off by the operator's choice"
eq "with nothing failing there" "$(grep FAIL <<<"$(fair_part "$check")")" ""
lacks "its queue is gone" "$(tc qdisc show dev "$cake_dev" root)" "qdisc cake"
no_ "and its unit" test -e /etc/systemd/system/hollow-cake.service
relay_up
lacks "the relay names no cap" "$(stats)" "bandwidth_cap_mbps"
printf 'action=change\nchange=cake\ncake=on\ncake_mbit=%s\nconfirm=yes\n' "$cake_mbit" >"$W/ans_cake_on"
PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_cake_on" >"$W/cake_on.out" 2>&1
rc=$?
eq "and back on" "$rc" 0
[ "$rc" = 0 ] || tail -n 30 "$W/cake_on.out"
has "with its queue back" "$(tc qdisc show dev "$cake_dev" root)" "qdisc cake"
relay_up
has "and the cap" "$(stats)" "\"bandwidth_cap_mbps\":$cake_mbit"

# ---------------------------------------------------------------- downloads

# net_get_refuses_a_redirect_to_http_with_every_program: a host that answers
# with a redirect, to plain http or to https, gives net_get nothing, and an
# empty answer is never a success.
echo "net_get and redirects"
# Key usage on the CA: Python 3.13 (Debian 13) verifies strictly and refuses a CA without it.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/ca.key" -out "$W/ca.crt" -days 2 -subj /CN=hollow-test-ca \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$W/srv.key" -out "$W/srv.csr" -subj /CN=ipcheck.test >/dev/null 2>&1
# And an authority key id on the server's: Python on OpenSSL 4 (Ubuntu 26.10) refuses one without.
printf 'subjectAltName=DNS:ipcheck.test\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n' >"$W/ext"
openssl x509 -req -in "$W/srv.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" -CAcreateserial -out "$W/srv.crt" -days 2 \
    -extfile "$W/ext" >/dev/null 2>&1
cp "$W/ca.crt" /usr/local/share/ca-certificates/hollow-test-ca.crt && update-ca-certificates >/dev/null 2>&1
grep -q ipcheck.test /etc/hosts || echo "127.0.0.1 ipcheck.test" >>/etc/hosts
cat >"$W/redir.py" <<'PYEOF'
import http.server, ssl, sys, threading
w = sys.argv[1]
class S(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/to-http":
            self.send_response(302); self.send_header("Location", "http://ipcheck.test:18080/ip"); self.end_headers()
        elif self.path == "/to-https":
            self.send_response(301); self.send_header("Location", "https://ipcheck.test:18443/ip"); self.end_headers()
        elif self.path == "/empty":
            self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
        else:
            b = b"203.0.113.9\n"; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 18443), S)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(w + "/srv.crt", w + "/srv.key")
s.socket = ctx.wrap_socket(s.socket, server_side=True)
threading.Thread(target=s.serve_forever, daemon=True).start()
http.server.HTTPServer(("127.0.0.1", 18080), S).serve_forever()
PYEOF
python3 "$W/redir.py" "$W" &
redir_pid=$!
for _ in $(seq 1 20); do (exec 3<>/dev/tcp/127.0.0.1/18443) 2>/dev/null && break; sleep 0.5; done
for FORCE_TOOL in curl wget python3; do
    command -v "$FORCE_TOOL" >/dev/null || { bad "$FORCE_TOOL is here after the install"; continue; }
    got=$(net_tool() { echo "$FORCE_TOOL"; }; net_get https://ipcheck.test:18443/ip 6)
    eq "net_get through $FORCE_TOOL reads a plain answer (control)" "$got" "203.0.113.9"
    got=$(net_tool() { echo "$FORCE_TOOL"; }; net_get https://ipcheck.test:18443/to-http 6; echo "rc=$?")
    eq "net_get through $FORCE_TOOL gives nothing for a redirect to http" "$got" "rc=1"
    got=$(net_tool() { echo "$FORCE_TOOL"; }; net_get https://ipcheck.test:18443/to-https 6; echo "rc=$?")
    eq "net_get through $FORCE_TOOL gives nothing for a redirect to https either" "$got" "rc=1"
    got=$(net_tool() { echo "$FORCE_TOOL"; }; net_get https://ipcheck.test:18443/empty 6; echo "rc=$?")
    eq "net_get through $FORCE_TOOL fails on an empty answer" "$got" "rc=1"
done
kill "$redir_pid" 2>/dev/null
rm -f /usr/local/share/ca-certificates/hollow-test-ca.crt && update-ca-certificates --fresh >/dev/null 2>&1
sed -i '/ipcheck.test/d' /etc/hosts

# ---------------------------------------------------------------- updates

printf 'action=update\nconfirm=yes\n' >"$W/ans_update"
printf 'action=status\n' >"$W/ans_status"
update() { # <label>: runs the menu's update, output in $W/<label>.out
    local rc=0
    # An update applies every setting again, the hardening included.
    PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_update" >"$W/$1.out" 2>&1 || rc=$?
    [ "${SHOW_UPDATES:-0}" = 1 ] && { echo "--- $1 (rc $rc)"; tail -n 25 "$W/$1.out"; }
    return "$rc"
}
installed_build() { sed -n 's/^build=//p' "$LIB/VERSION"; }
copy_mark() { sed -n 's/^# SETUP MARK //p' "$1/install.sh" | head -n 1; }
unit_mark() { sed -n 's/^# SETUP MARK //p' /etc/systemd/system/hollow-coturn.service | head -n 1; }
status() { hollow-relay-setup --answers "$W/ans_status" 2>&1 | tr '\n' ' '; }

yes_ "hollow-relay-setup is a launcher outside the copy" test -f /usr/local/sbin/hollow-relay-setup
no_ "not a link into it" test -L /usr/local/sbin/hollow-relay-setup
eq "the copy names where it came from" "$(sed -n 's/^kind=//p' "$LIB/installer/SOURCE")" clone
check=$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)
has "coturn keeps its sandbox with the repair step" "$check" "ok    hollow-coturn is sandboxed"

echo "an update brings the release's setup and its settings"
# an_update_puts_the_port_lock_in_place: the relay as a setup from before the
# lock left it, then the menu's update.
systemctl disable --now hollow-turn-port-lock-refresh.timer hollow-turn-port-lock.service >/dev/null 2>&1
rm -f /etc/systemd/system/hollow-turn-port-lock.service /etc/systemd/system/hollow-turn-port-lock-refresh.service \
    /etc/systemd/system/hollow-turn-port-lock-refresh.timer /etc/hollow-relay/turn-port-lock.env /usr/local/sbin/hollow-turn-port-lock
rm -rf /etc/systemd/system/hollow-coturn.service.d
systemctl daemon-reload
systemctl start hollow-coturn
has "a setup from before the lock fails check-host" "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)" "FAIL  TURN can reach every UDP port on this machine's own address"
publish 2 setup
update u2
rc=$?
eq "the update finishes" "$rc" 0
[ "$rc" = 0 ] || tail -n 40 "$W/u2.out"
out=$(flat "$W/u2.out")
has "it says the setup was updated" "$out" "the setup itself was updated too"
has "and the new setup applied the settings" "$out" "Applying this relay's settings with the new setup"
eq "the relay is build 2" "$(installed_build)" 2
eq "the release's setup is live" "$(copy_mark "$LIB/installer")" b2
has "and is what hollow-relay-setup runs next" "$(hollow-relay-setup --help)" "SETUP MARK b2"
has "the clone's copy is kept for a rollback" "$(sed -n 2p "$LIB/previous/installer/install.sh")" "# Hollow relay setup"
eq "the units are the new setup's" "$(unit_mark)" b2
eq "the copy names the release" "$(sed -n 's/^kind=//p;s/^build=//p' "$LIB/installer/SOURCE" | tr '\n' ' ')" "release 2 "
eq "install.sh stays runnable" "$(stat -c '%a %U' "$LIB/installer/install.sh")" "755 root"
eq "nothing in the copy is writable by others" "$(find "$LIB/installer" -perm /022 | wc -l)" 0
yes_ "the relay runs" relay_up
yes_ "the units still find their scripts" test -f "$LIB/installer/deploy/coturn/coturn-start.sh"
yes_ "coturn runs from the new copy" systemctl is-active --quiet hollow-coturn
no_ "the update left no mark" test -e /var/lib/hollow-installer/update_pending
no_ "nor its kept settings" test -e /var/lib/hollow-installer/update-snapshot
part=$(turn_part "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)")
eq "the update put the port lock in place" "$(grep FAIL <<<"$part")" ""
has "loaded" "$part" "ok    on every ip address of this machine but loopback TURN reaches only ports 49152-65535"
has "with its timer" "$part" "ok    the TURN port lock loads again every minute"
has "and coturn needs it again" "$(systemctl show -p Requires --value hollow-coturn)" hollow-turn-port-lock.service

# a_stale_clone_never_silently_replaces_a_release_copy: the clone the first
# install ran from holds the same version, without a commit to compare.
echo "a run from the clone after a release's setup went live"
before=$(tree_sum "$LIB/installer")
printf 'action=change\nchange=grace\ngrace_secs=150\nconfirm=yes\n' >"$W/ans_change"
PATH="$SAFE:$PATH" bash "$SRC/relay-uws/install.sh" --answers "$W/ans_change" >"$W/clone.out" 2>&1
eq "the clone's run stops" "$?" 0
has "and says to use the installed setup" "$(flat "$W/clone.out")" "Nothing changed. Run sudo hollow-relay-setup to use the setup installed here."
eq "the release's setup is untouched" "$(tree_sum "$LIB/installer")" "$before"
lacks "and nothing was applied" "$(cat /etc/hollow-relay/install.conf)" "grace_secs=150"

for kind in extra link dotdot big noui; do
    echo "a release whose setup has a $kind entry"
    publish 3 "$kind"
    update "t-$kind"
    rc=$?
    no_ "the $kind update stops" test "$rc" = 0
    has "and says the download failed its checks ($kind)" "$(flat "$W/t-$kind.out")" "the download did not pass its checks. Nothing was installed."
    eq "the setup's copy is untouched ($kind)" "$(tree_sum "$LIB/installer")" "$before"
    eq "the relay is still build 2 ($kind)" "$(installed_build)" 2
    no_ "nothing lands outside ($kind)" test -e /etc/cron.d/evil
    no_ "and nothing is left staged ($kind)" test -e "$LIB/installer.new"
done

# a_staged_setup_that_cannot_start_never_replaces_the_live_one
echo "a release whose setup cannot start"
publish 3 cannotstart
update t-cannotstart
no_ "the update stops" test "$?" = 0
has "and says its setup does not start" "$(flat "$W/t-cannotstart.out")" "the copy of the setup in this release is not complete or does not start. Nothing was installed."
eq "the setup's copy is untouched" "$(tree_sum "$LIB/installer")" "$before"
eq "the relay is still build 2" "$(installed_build)" 2
no_ "nothing is left staged" test -e "$LIB/installer.new"
no_ "nor half staged" test -e "$LIB/installer.stage"
has "the setup still starts" "$(hollow-relay-setup --help)" "SETUP MARK b2"
yes_ "the relay still runs" relay_up

echo "a release from before the setup rode along"
publish 3 old
update u3
eq "the update finishes" "$?" 0
has "it says the setup stays" "$(flat "$W/u3.out")" "does not carry a new version of the setup"
eq "the relay is build 3" "$(installed_build)" 3
eq "and the setup is the same copy" "$(tree_sum "$LIB/installer")" "$before"

# A run killed at the swap's first rename (an mv on PATH stands in for the
# crash): just before it, or just after it.
mkdir -p "$W/killmv"
cat >"$W/killmv/mv" <<'SHEOF'
#!/bin/bash
if [ "$*" = "-T -- /usr/local/lib/hollow-relay/installer /usr/local/lib/hollow-relay/previous/installer" ]; then
    if [ "$KILL_AT" = before ]; then kill -9 "$PPID"; exit 1; fi
    /usr/bin/mv "$@"; rc=$?
    [ "$KILL_AT" = between ] && kill -9 "$PPID"
    exit "$rc"
fi
exec /usr/bin/mv "$@"
SHEOF
chmod 0755 "$W/killmv/mv"

# a_run_after_a_kill_between_the_swap_renames_restores_a_working_copy
echo "a run killed between the swap's two renames"
publish 4 setup
KILL_AT=between PATH="$W/killmv:$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_update" >"$W/k4.out" 2>&1
no_ "the run was killed" test "$?" = 0
no_ "it left no copy in place" test -e "$LIB/installer"
yes_ "the checked new copy waits beside it" test -f "$LIB/installer.new/install.sh"
has "hollow-relay-setup runs" "$(hollow-relay-setup --help)" "SETUP MARK b4"
eq "and its start put the new copy in place" "$(copy_mark "$LIB/installer")" b4
# The same state again, met first by a unit that runs a script from the copy.
cp -a "$LIB/installer" "$LIB/installer.new" && mv "$LIB/installer" "$W/stash"
systemctl restart hollow-coturn
yes_ "coturn starts anyway" systemctl is-active --quiet hollow-coturn
eq "its start put the new copy in place" "$(copy_mark "$LIB/installer")" b4
rm -rf "$W/stash"
has "the status says the update stopped part of the way" "$(status)" "stopped part of the way"
update f4
eq "finishing it works" "$?" 0
eq "the relay is build 4" "$(installed_build)" 4
eq "the setup is b4" "$(copy_mark "$LIB/installer")" b4
eq "and so are the units" "$(unit_mark)" b4
eq "the copy before the update is kept" "$(copy_mark "$LIB/previous/installer")" b2
eq "and so are the programs" "$(sed -n 's/^build=//p' "$LIB/previous/VERSION")" 3
no_ "the update is done" test -e /var/lib/hollow-installer/update_pending
yes_ "the relay runs" relay_up

echo "a run killed after the programs, before the setup's swap"
publish 5 setup
KILL_AT=before PATH="$W/killmv:$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_update" >"$W/k5.out" 2>&1
no_ "the run was killed" test "$?" = 0
eq "the relay programs are build 5" "$(installed_build)" 5
eq "the setup is still b4" "$(copy_mark "$LIB/installer")" b4
has "the status does not call it up to date" "$(status)" "the update to version $REL (build 5) stopped part of the way"
update f5
eq "finishing it works" "$?" 0
eq "the setup is b5" "$(copy_mark "$LIB/installer")" b5
eq "and so are the units" "$(unit_mark)" b5
eq "the setup before the update is kept" "$(copy_mark "$LIB/previous/installer")" b4
eq "and the programs the first run kept" "$(sed -n 's/^build=//p' "$LIB/previous/VERSION")" 4
no_ "the update is done" test -e /var/lib/hollow-installer/update_pending
yes_ "the relay runs" relay_up

before=$(tree_sum "$LIB/installer")
echo "a release whose relay does not start"
publish 6 dead
update u6
out=$(flat "$W/u6.out")
has "the update is undone" "$out" "Update undone"
has "with the setup" "$out" "The setup is back to its earlier version too."
eq "the relay is build 5 again" "$(installed_build)" 5
eq "and the setup the copy it was" "$(tree_sum "$LIB/installer")" "$before"
eq "the units the new setup wrote are put back" "$(unit_mark)" b5
has "which hollow-relay-setup runs" "$(hollow-relay-setup --help)" "SETUP MARK b5"
no_ "the update is forgotten" test -e /var/lib/hollow-installer/update_pending
yes_ "the relay runs" relay_up
yes_ "and coturn" systemctl is-active --quiet hollow-coturn

echo "a release whose setup cannot apply the settings"
publish 7 badsettings
# a_rollback_restarts_the_relay_once_and_clears_a_start_limit: the relay has
# used up its starts for this window, as after a release that kept failing, so
# only a rollback that clears the limit starts it again. The drop-in stays out
# of the update's snapshot, so the rollback meets it too.
limit=/etc/systemd/system/hollow-relay.service.d/zz-box-start-limit.conf
mkdir -p "${limit%/*}"
printf '[Unit]\nStartLimitIntervalSec=900\nStartLimitBurst=2\n' >"$limit"
systemctl daemon-reload
systemctl reset-failed hollow-relay
systemctl restart hollow-relay
systemctl restart hollow-relay
no_ "the relay has no start left in this window" systemctl restart hollow-relay
systemctl reset-failed hollow-relay
systemctl restart hollow-relay
systemctl restart hollow-relay
update u7
out=$(flat "$W/u7.out")
has "the update is undone" "$out" "Update undone"
eq "the relay is build 5 again" "$(installed_build)" 5
eq "and the setup the copy it was" "$(tree_sum "$LIB/installer")" "$before"
eq "with its units" "$(unit_mark)" b5
no_ "the update is forgotten" test -e /var/lib/hollow-installer/update_pending
yes_ "the relay runs" relay_up
rm -f "$limit"
systemctl daemon-reload
systemctl reset-failed hollow-relay
part=$(turn_part "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)")
eq "the port lock passes after the rollbacks" "$(grep FAIL <<<"$part")" ""

# an_update_never_installs_programs_that_cannot_start_here (#153)
echo "a release whose relay needs a library this system does not offer"
publish 8 nolib
update u8
out=$(flat "$W/u8.out")
has "the update stops" "$out" "the release list has no programs for this machine now (they need libsodium.so.99, which $PRETTY_NAME does not offer). Nothing was installed."
eq "the relay is build 5 still" "$(installed_build)" 5
eq "and the setup the copy it was" "$(tree_sum "$LIB/installer")" "$before"
no_ "the update left no mark" test -e /var/lib/hollow-installer/update_pending
yes_ "the relay runs" relay_up

# a_rerun_puts_back_what_a_release_upgrade_took (#153): the relay's libsodium
# goes, check-host names it, and the next run of the setup installs it again.
echo "a library the relay lost"
sofile=$(LC_ALL=C ldd /usr/local/bin/hollow-relay | sed -n 's/^[[:space:]]*libsodium[^[:space:]]* => \(\/[^[:space:]]*\).*/\1/p' | head -n 1)
sodium=$(dpkg-query -S "$(readlink -f "$sofile")" 2>/dev/null | cut -d: -f1)
if [ -n "$sodium" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "$sodium" >/dev/null 2>&1
    has "check-host names it" "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)" \
        "FAIL  hollow-relay cannot start: /usr/local/bin/hollow-relay needs libsodium"
    publish 9 setup
    printf 'action=change\nchange=grace\ngrace_secs=160\nconfirm=yes\n' >"$W/ans_heal"
    PATH="$SAFE:$PATH" hollow-relay-setup --answers "$W/ans_heal" >"$W/heal.out" 2>&1
    rc=$?
    eq "the next run finishes" "$rc" 0
    [ "$rc" = 0 ] || tail -n 30 "$W/heal.out"
    eq "with $sodium back" "$(dpkg-query -W -f='${Status}' "$sodium" 2>/dev/null)" "install ok installed"
    has "check-host passes again" "$(bash "$LIB/installer/deploy/check-host.sh" 2>&1)" \
        "ok    hollow-relay's program /usr/local/bin/hollow-relay finds every library it needs"
    yes_ "the relay runs" relay_up
else
    bad "the relay's libsodium belongs to a package"
fi

finish
