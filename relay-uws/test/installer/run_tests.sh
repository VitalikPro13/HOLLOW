#!/bin/bash
# Tests for install.sh's helpers: address and network classes, the answer
# file, the firewall rules, the rendered units and configs, the members-only
# keys, the SSH login gate, and a full dry run. Runs on any Ubuntu or Debian
# machine; changes nothing on it.
#
#   bash relay-uws/test/installer/run_tests.sh
#   sudo bash relay-uws/test/installer/run_tests.sh   (adds the dry runs that need root)
# The tests set variables the sourced libraries read, and define stand-ins
# the libraries call.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031
set -uo pipefail

T=$(cd "$(dirname "$0")" && pwd)
RELAY=$(cd "$T/../.." && pwd)
DEPLOY=$RELAY/deploy
HERE=$RELAY
REPO=$(cd "$RELAY/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WORK_DIR=$TMP

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
yes_() { if "$@"; then ok; else bad "expected true: $*"; fi; }
no_()  { if "$@"; then bad "expected false: $*"; else ok; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: missing [$3]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: should not contain [$3]"; else ok; fi; }

# Runs <function> in a subshell, so the stubs it defines stay there, and adds
# its counts. A subshell that dies counts as one failure.
in_sub() {
    local name=$1 out line got=0
    out=$( pass=0 fail=0; "$@"; echo "__COUNTS $pass $fail" )
    while IFS= read -r line; do
        # shellcheck disable=SC2086 # three words
        case "$line" in
        "__COUNTS "*) set -- $line; pass=$((pass + $2)); fail=$((fail + $3)); got=1 ;;
        *) printf '%s\n' "$line" ;;
        esac
    done <<<"$out"
    [ "$got" = 1 ] || bad "$name died before it finished"
}

# mkfake <dir> <name> <body>: an executable stand-in for a system command.
mkfake() {
    mkdir -p "$1"
    printf '#!/bin/sh\n%s\n' "$3" >"$1/$2"
    chmod +x "$1/$2"
}


# shellcheck source=../../deploy/lib/common.sh
. "$DEPLOY/lib/common.sh"
# shellcheck source=../../deploy/lib/ui.sh
. "$DEPLOY/lib/ui.sh"
# shellcheck source=../../deploy/lib/preflight.sh
. "$DEPLOY/lib/preflight.sh"
# shellcheck source=../../deploy/lib/address.sh
. "$DEPLOY/lib/address.sh"
# shellcheck source=../../deploy/lib/ssh_keys.sh
. "$DEPLOY/lib/ssh_keys.sh"
# shellcheck source=../../deploy/lib/native.sh
. "$DEPLOY/lib/native.sh"
# shellcheck source=../../deploy/lib/docker.sh
. "$DEPLOY/lib/docker.sh"
# shellcheck source=../../deploy/lib/manage.sh
. "$DEPLOY/lib/manage.sh"
# shellcheck source=../../deploy/lib/host.sh
. "$DEPLOY/lib/host.sh"
# shellcheck source=../../deploy/lib/questions.sh
. "$DEPLOY/lib/questions.sh"
# shellcheck source=../../deploy/lib/adopt.sh
. "$DEPLOY/lib/adopt.sh"
# shellcheck disable=SC2317 # called by the libraries
die() { printf 'DIE %s\n' "$*"; exit 99; }

shopt -s lastpipe
echo "file writes"
# A change written through a pipe must still reach the caller, or a settings
# change never restarts its service (install.sh runs with lastpipe for this).
DRY_RUN=0
put_file() { PUT_CHANGED=0; cat >/dev/null; PUT_CHANGED=1; }
RESTART_UNITS=()
printf 'x\n' | put_unit hollow-test.service
eq "a piped unit write marks its restart" "${RESTART_UNITS[*]}" hollow-test
# shellcheck source=../../deploy/lib/common.sh
. "$DEPLOY/lib/common.sh"
WORK_DIR=$TMP
# shellcheck disable=SC2317 # called by the libraries
die() { printf 'DIE %s\n' "$*"; exit 99; }
if grep -q 'shopt -s lastpipe' "$RELAY/install.sh"; then ok; else bad "install.sh lost shopt -s lastpipe"; fi

echo "network classes"
eq "public" "$(ip4_class 203.0.113.7)" public
eq "rfc1918 10" "$(ip4_class 10.1.2.3)" private
eq "rfc1918 172.16" "$(ip4_class 172.16.0.1)" private
eq "rfc1918 172.31" "$(ip4_class 172.31.255.255)" private
eq "172.32 is public" "$(ip4_class 172.32.0.1)" public
eq "rfc1918 192.168" "$(ip4_class 192.168.18.8)" private
eq "cgnat low" "$(ip4_class 100.64.0.1)" cgnat
eq "cgnat high" "$(ip4_class 100.127.255.254)" cgnat
eq "100.128 is public" "$(ip4_class 100.128.0.1)" public
eq "100.63 is public" "$(ip4_class 100.63.255.255)" public
eq "loopback" "$(ip4_class 127.0.0.1)" loopback
eq "linklocal" "$(ip4_class 169.254.1.1)" linklocal
eq "octet over 255" "$(ip4_class 1.2.3.256)" invalid
eq "multicast" "$(ip4_class 224.0.0.1)" invalid
eq "not an address" "$(ip4_class relay.example.com)" invalid
eq "v6 global" "$(ip6_class 2001:db8::1)" global
eq "v6 ula" "$(ip6_class fd12:3456::1)" ula
eq "v6 linklocal" "$(ip6_class fe80::1)" linklocal
eq "v6 loopback" "$(ip6_class ::1)" loopback

echo "supported systems"
yes_ os_supported ubuntu 22.04
yes_ os_supported ubuntu 24.04
yes_ os_supported ubuntu 26.04
no_ os_supported ubuntu 20.04
no_ os_supported ubuntu 21.10
yes_ os_supported debian 12
yes_ os_supported debian 13
no_ os_supported debian 11
no_ os_supported fedora 40
yes_ arch_supported x86_64
yes_ arch_supported aarch64
no_ arch_supported armv7l

echo "addresses"
eq "duckdns bare" "$(duckdns_name_norm MyRelay)" myrelay
eq "duckdns full" "$(duckdns_name_norm myrelay.duckdns.org)" myrelay
eq "duckdns first part" "$(duckdns_name_norm hollowtest)" hollowtest
eq "duckdns whole name" "$(duckdns_name_norm HollowTest.DuckDNS.org)" hollowtest
eq "duckdns pasted link" "$(duckdns_name_norm https://hollowtest.duckdns.org/)" hollowtest
eq "duckdns spaces around it" "$(duckdns_name_norm ' hollowtest.duckdns.org ')" hollowtest
eq "another domain is not a DuckDNS name" "$(duckdns_name_norm hollowtest.example.org)" ""
eq "duckdns bad" "$(duckdns_name_norm 'my relay')" ""
eq "duckdns hyphen edge" "$(duckdns_name_norm -relay)" ""
yes_ valid_duckdns_token a1b2c3d4-0000-1111-2222-333344445555
no_ valid_duckdns_token a1b2c3d4-0000-1111-2222-33334444555
no_ valid_duckdns_token 'a1b2c3d4-0000-1111-2222-333344445555&ip=1.2.3.4'
yes_ valid_domain relay.example.com
yes_ valid_domain a.b.example.co.uk
no_ valid_domain localhost
no_ valid_domain relay.example.com:8443
no_ valid_domain https://relay.example.com
no_ valid_domain 203.0.113.7

echo "keys"
k=$(gen_member_key)
yes_ is_member_key "$k"
no_ is_member_key "AB12-CD34-EF56-GH7"
no_ is_member_key "ab12-cd34-ef56-gh78"
if [ "$(gen_member_key)" != "$(gen_member_key)" ]; then ok; else bad "two member keys were equal"; fi
h=$(gen_hex 32)
eq "hex length" "${#h}" 64
keys_json true AAAA-BBBB-CCCC-DDDD EEEE-FFFF-0000-1111 >"$TMP/k.json"
yes_ python3 -c "import json,sys; d=json.load(open('$TMP/k.json')); assert d['enabled'] is True and len(d['keys'])==2"
keys_json false >"$TMP/k0.json"
yes_ python3 -c "import json; d=json.load(open('$TMP/k0.json')); assert d=={'enabled':False,'keys':[]}"
eq "keys read back" "$(member_keys_read "$TMP/k.json" | tr '\n' ' ')" "AAAA-BBBB-CCCC-DDDD EEEE-FFFF-0000-1111 "

# Topping up, removal and the forwarder's own key.
printf 'HOLLOW_FWD_LICENSE_KEY=EEEE-FFFF-0000-1111\n' >"$TMP/fwd.env"
CFG_MEMBERS_ONLY=yes CFG_FORWARDER=yes CFG_MEMBER_KEYS=3 REMOVE_KEY=""
plan_member_keys "$TMP/k.json" "$TMP/fwd.env" HOLLOW_FWD_LICENSE_KEY
eq "topped up to 3" "${#MEMBER_KEYS[@]}" 3
eq "first key kept" "${MEMBER_KEYS[0]}" AAAA-BBBB-CCCC-DDDD
eq "forwarder key kept apart" "$FWD_KEY" EEEE-FFFF-0000-1111
for x in "${MEMBER_KEYS[@]}"; do [ "$x" != "$FWD_KEY" ] || bad "the forwarder's key is on the member list"; done
REMOVE_KEY=AAAA-BBBB-CCCC-DDDD CFG_MEMBER_KEYS=0
plan_member_keys "$TMP/k.json" "$TMP/fwd.env" HOLLOW_FWD_LICENSE_KEY
eq "removed key gone" "${#MEMBER_KEYS[@]}" 0
REMOVE_KEY="" CFG_FORWARDER=no CFG_MEMBER_KEYS=1
plan_member_keys "$TMP/k.json" "$TMP/fwd.env" HOLLOW_FWD_LICENSE_KEY
eq "no forwarder, no forwarder key" "$FWD_KEY" ""
printf '' >"$TMP/none.env"
CFG_FORWARDER=yes
plan_member_keys "$TMP/k0.json" "$TMP/none.env" HOLLOW_FWD_LICENSE_KEY
yes_ is_member_key "$FWD_KEY"
CFG_MEMBERS_ONLY=no
plan_member_keys "$TMP/k0.json" "$TMP/none.env" HOLLOW_FWD_LICENSE_KEY
eq "open relay mints no keys" "${#MEMBER_KEYS[@]}" 0
eq "open relay mints no forwarder key" "$FWD_KEY" ""

echo "kv files"
printf 'A=1\n  B = "two words" \nA=3\nC='"'x'"'\n' >"$TMP/kv"
eq "last value wins" "$(kv_get "$TMP/kv" A)" 3
eq "quotes and spaces" "$(kv_get "$TMP/kv" B)" "two words"
eq "single quotes" "$(kv_get "$TMP/kv" C)" x
eq "missing" "$(kv_get "$TMP/kv" D)" ""
eq "missing file" "$(kv_get "$TMP/nofile" A)" ""

echo "answer file"
printf 'mode=native\n# a comment\nturn = no   # trailing\nduckdns_name="myrelay"\n' >"$TMP/a1"
ui_load_answers "$TMP/a1"
eq "mode" "${ANS[mode]}" native
eq "trailing comment" "${ANS[turn]}" no
eq "quoted" "${ANS[duckdns_name]}" myrelay
printf 'trun=no\n' >"$TMP/a2"
out=$(ui_load_answers "$TMP/a2" 2>&1)
has "unknown key refused" "$out" "does not know"
printf 'just words\n' >"$TMP/a3"
out=$(ui_load_answers "$TMP/a3" 2>&1)
has "not key=value refused" "$out" "not key=value"
UI_MODE=answers
ANS=([turn]=no)
if ui_yesno turn t x yes >/dev/null; then bad "turn=no answered yes"; else ok; fi
ANS=()
if ui_yesno turn t x yes >/dev/null; then ok; else bad "a missing key did not take the recommended yes"; fi
ANS=([address]=carrier-pigeon)
out=$(ui_menu address t x duckdns duckdns D ip I 2>&1)
has "menu refuses unknown" "$out" "takes one of: duckdns ip"
ANS=([duckdns_token_file]="$TMP/tok")
printf 'NAME=x\nTOKEN=a1b2c3d4-0000-1111-2222-333344445555\n' >"$TMP/tok"
ui_secret duckdns_token t x >"$TMP/secret.out"
eq "token from file" "$UI_REPLY" a1b2c3d4-0000-1111-2222-333344445555
lacks "token never printed" "$(cat "$TMP/secret.out")" a1b2c3d4

echo "firewall"
r=$(hollow_fw_rules no no no 22 | tr '\n' ' ')
eq "duckdns, nothing else" "$r" "22/tcp 443/tcp "
r=$(hollow_fw_rules yes yes yes 22 2222 | tr '\n' ' ')
eq "everything" "$r" "22/tcp 2222/tcp 443/tcp 80/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp 49152:65535/udp 40000:40199/udp "
r=$(hollow_fw_rules no yes no 22 | tr '\n' ' ')
lacks "no forwarder range without it" "$r" 40000
lacks "no port 80 for duckdns" "$r" 80/tcp
for rule in $(hollow_fw_rules yes yes yes); do
    [ "${rule%/tcp}" = "$rule" ] || [ "$rule" = 443/tcp ] || [[ " $HOLLOW_FW_OPTIONAL " == *" $rule "* ]] ||
        bad "rule $rule is not in HOLLOW_FW_OPTIONAL, so a settings change would never close it"
    [[ "$rule" == */udp ]] && { [[ " $HOLLOW_FW_OPTIONAL " == *" $rule "* ]] || bad "udp rule $rule not closable"; }
done
out=$(sh "$DEPLOY/harden-host.sh" --print --http no --turn no --forwarder yes --no-ssh 2>&1)
has "harden opens forwarder" "$out" "would run: ufw allow 40000:40199/udp"
has "harden closes TURN" "$out" "would run: ufw delete allow 3478/udp"
has "harden closes 80" "$out" "would run: ufw delete allow 80/tcp"
lacks "harden leaves SSH alone" "$out" "sshd_config.d"
out=$(sh "$DEPLOY/harden-host.sh" --print 2>&1)
has "default opens 80" "$out" "would run: ufw allow 80/tcp"
has "default opens TURN" "$out" "would run: ufw allow 49152:65535/udp"
lacks "default never deletes" "$out" "ufw delete"
lacks "default keeps the forwarder range alone" "$out" "40000"

echo "relay unit"
CFG_HOST=relay.example.org CFG_GRACE_SECS=120
u=$(render_relay_unit "")
has "domain" "$u" "--domain relay.example.org \\"
lacks "no forwarder flag" "$(grep -v '^#' <<<"$u")" "--forwarder-peer-id"
lacks "default grace leaves the flag out" "$u" "--session-grace-secs"
lacks "official id gone" "$u" "12D3KooWHtaftXh76r8hiwx6HzzSkKudx1rkjht1YYAjWSDjfeRH"
lacks "official domain gone" "$u" "--domain relay.anonlisten.com"
has "last flag has no backslash" "$u" "    --key-file /etc/hollow-relay/privkey.pem
"
CFG_GRACE_SECS=300
u=$(render_relay_unit 12D3KooWTestTestTest)
has "forwarder flag" "$u" "--forwarder-peer-id 12D3KooWTestTestTest \\"
has "grace flag last" "$u" "    --session-grace-secs 300
"
# Everything outside ExecStart is the official unit, sandbox included.
if diff <(sed '/^ExecStart=/,/[^\\]$/d; /^InaccessiblePaths=/d' "$DEPLOY/hollow-relay.service") \
     <(printf '%s\n' "$u" | sed '1d; /^ExecStart=/,/[^\\]$/d; /^InaccessiblePaths=/d') >"$TMP/unit.diff"; then
    ok
else
    bad "the rendered relay unit differs from deploy/hollow-relay.service outside ExecStart: $(head -5 "$TMP/unit.diff")"
fi
has "extra hidden dirs" "$u" "-/etc/hollow-turn -/etc/hollow-duckdns"
for line in NotifyAccess=main FileDescriptorStoreMax=1 LimitCORE=0 MemorySwapMax=0 SystemCallErrorNumber=EPERM \
    EnvironmentFile=/etc/hollow-relay/relay.env User=hollow-relay; do
    has "relay unit keeps $line" "$u" "$line"
done
if command -v systemd-analyze >/dev/null; then
    printf '%s\n' "$u" >"$TMP/hollow-relay.service"
    out=$(systemd-analyze verify "$TMP/hollow-relay.service" 2>&1 | grep -v -e 'Failed to resolve' -e 'Command /usr/local/bin' -e 'is not executable' || true)
    lacks "relay unit parses" "$out" "Unknown"
fi

echo "push unit"
p=$(render_push_unit "$REPO/push-sidecar/hollow-push.service")
lacks "no Firebase credential" "$p" "LoadCredential"
lacks "no Firebase path" "$p" "FIREBASE_KEY_PATH"
has "keeps its token file" "$p" "EnvironmentFile=/etc/hollow-push/push.env"
has "keeps its account" "$p" "User=hollow-push"
has "keeps the address wall" "$p" "IPAddressDeny=0.0.0.0/8"
has "keeps the identifier" "$p" "SyslogIdentifier=hollow-push"

echo "forwarder config"
CFG_HOST=relay.example.org CFG_PUBLIC_IP=198.51.100.9
c=$(render_forwarder_toml)
has "relay domain" "$c" 'relay_domain = "relay.example.org"'
has "public ip" "$c" 'public_ip = "198.51.100.9"'
lacks "no official address" "$c" "141.227.186.209"
lacks "no placeholder" "$(grep -v '^#' <<<"$c")" "203.0.113.7"
lacks "the example has no official address" "$(cat "$DEPLOY/forwarder.toml.example")" "141.227.186.209"
if command -v python3 >/dev/null && python3 -c 'import tomllib' 2>/dev/null; then
    printf '%s\n' "$c" >"$TMP/f.toml"
    yes_ python3 -c "import tomllib; d=tomllib.load(open('$TMP/f.toml','rb')); assert d['udp_port_min']==40000 and d['udp_port_max']==40199"
fi
# The forwarder's firewall range is the one its config uses.
eq "forwarder range" "$(sed -n 's/^udp_port_min = //p' "$DEPLOY/forwarder.toml.example"):$(sed -n 's/^udp_port_max = //p' "$DEPLOY/forwarder.toml.example")" "$FWD_PORTS"

echo "certbot choice"
# A Debian box without snapd gets a pinned certbot in a venv for IP certificates,
# never snapd; names use the distribution's certbot.
out=$(DRY_RUN=1 CFG_ADDRESS=ip; have() { [ "$1" != snap ] && command -v "$1" >/dev/null; }
      CERTBOT_VENV=$TMP/no-venv; [ -x /snap/bin/certbot ] && exit 0; certbot_install; echo "dir=$CERTBOT_DIR")
if [ -n "$out" ]; then
    has "venv for IP on a box without snap" "$out" "certbot==$CERTBOT_PIN"
    has "venv renew timer" "$out" "hollow-certbot-renew.timer"
    lacks "never installs snapd" "$out" "snapd"
    has "venv certbot is the one used" "$out" "dir=$TMP/no-venv/bin"
fi
out=$(DRY_RUN=1 CFG_ADDRESS=duckdns; CERTBOT_VENV=$TMP/no-venv; [ -x /snap/bin/certbot ] && exit 0; certbot_install; echo "dir=$CERTBOT_DIR")
if [ -n "$out" ]; then
    lacks "a name needs no snap" "$out" "snap install"
    has "a name uses the distribution's certbot" "$out" "dir=/usr/bin"
fi

echo "ssh login gate"
FAKE=$TMP/bin
mkdir -p "$FAKE"
# Like journalctl -o short-unix, honouring --since @<time>.
cat >"$FAKE/journalctl" <<'EOF'
#!/bin/sh
since=0
while [ $# -gt 0 ]; do [ "$1" = --since ] && since=${2#@}; shift; done
awk -v s="$since" 'int($1) >= s' "$FAKE_JOURNAL"
EOF
cat >"$FAKE/sshd" <<'EOF'
#!/bin/sh
cat "$FAKE_SSHD_T"
EOF
chmod +x "$FAKE/journalctl" "$FAKE/sshd"
export FAKE_JOURNAL=$TMP/journal FAKE_SSHD_T=$TMP/sshd_t
PATH="$FAKE:$PATH"
# jline <unix time> <message>: a journal line as sshd writes it.
jline() { printf '%s.000001 box sshd[%s]: %s\n' "$1" "$$" "$2" >>"$FAKE_JOURNAL"; }
: >"$FAKE_JOURNAL"
jline 1000 "Accepted password for alice from 192.0.2.1 port 50000 ssh2"
jline 1001 "Accepted publickey for alicex from 192.0.2.1 port 50001 ssh2: ED25519 SHA256:other"
jline 1002 "Accepted publickey for alice from 192.0.2.7 port 50002 ssh2: ED25519 SHA256:alicekey"
eq "logins are read with their kind, address and key" "$(ssh_logins alice 0 | tr '\n' ';')" "1000 password 192.0.2.1 -;1002 key 192.0.2.7 SHA256:alicekey;"
eq "another account's login is not this one's" "$(ssh_logins bob 0)" ""
eq "a login before <since> is left out" "$(ssh_logins alice 1001 | tr '\n' ';')" "1002 key 192.0.2.7 SHA256:alicekey;"
# Also when journalctl hands over more than asked, as its --since rounds.
mkdir -p "$TMP/loose"
printf '#!/bin/sh\ncat "$FAKE_JOURNAL"\n' >"$TMP/loose/journalctl"
chmod +x "$TMP/loose/journalctl"
eq "the reader drops what came before <since> itself" "$(PATH="$TMP/loose:$PATH" ssh_logins alice 1001 | tr '\n' ';')" "1002 key 192.0.2.7 SHA256:alicekey;"
# A long journal with the login near the top: the reader must not quit early,
# or journalctl dies of SIGPIPE and pipefail turns the match into a failure.
: >"$FAKE_JOURNAL"
jline 1 "Accepted publickey for alice from 192.0.2.1 port 1 ssh2: ED25519 SHA256:k"
seq 2 200000 | sed 's/$/.0 box noise: line/' >>"$FAKE_JOURNAL"
set -o pipefail
eq "a long journal" "$(ssh_logins alice 0)" "1 key 192.0.2.1 SHA256:k"

echo "ssh gate: whose login"
t_gate() {
    UI_MODE=plain
    local now
    now=$(date +%s)
    ssh_host_for_person() { echo relay.example.org; }
    ui_msg() { printf '%s\n' "$2" >>"$TMP/gate.screens"; }
    ui_yesno() { printf 'ASKED %s\n' "$3" >>"$TMP/gate.screens"; [ "$GATE_SAY" = yes ]; }
    ui_menu() { printf 'MENU %s\n' "$3" >>"$TMP/gate.screens"; UI_REPLY=$GATE_MENU; }
    # A backup job's key login just before the prompt counts for nothing.
    : >"$FAKE_JOURNAL" ; : >"$TMP/gate.screens"
    jline $((now - 5)) "Accepted publickey for alice from 10.0.0.9 port 1 ssh2: ED25519 SHA256:backupjob"
    GATE_SAY=yes GATE_MENU=stop
    if ssh_wait_login alice "$now" test; then bad "a key login from before the prompt counted"; else ok; fi
    lacks "and nobody is asked about it" "$(cat "$TMP/gate.screens")" "ASKED"
    # A password login after the prompt is named as one, never a success.
    : >"$FAKE_JOURNAL" ; : >"$TMP/gate.screens"
    jline "$now" "Accepted password for alice from 192.168.18.24 port 2 ssh2"
    if ssh_wait_login alice "$now" test; then bad "a password login counted as a key login"; else ok; fi
    has "the person hears it used the password" "$(cat "$TMP/gate.screens")" "from 192.168.18.24 at"
    has "plainly" "$(cat "$TMP/gate.screens")" "it used the password, not a key"
    # Another key after the prompt, and the person says no: it does not count.
    : >"$FAKE_JOURNAL" ; : >"$TMP/gate.screens"
    jline "$now" "Accepted publickey for alice from 10.0.0.9 port 3 ssh2: ED25519 SHA256:backupjob"
    GATE_SAY=no GATE_MENU=stop
    if ssh_wait_login alice "$now" test; then bad "a key the person refused counted"; else ok; fi
    has "the question names the key" "$(cat "$TMP/gate.screens")" "with the key SHA256:backupjob, from 10.0.0.9"
    has "and asks whose it is" "$(cat "$TMP/gate.screens")" "Was that you, from the computer you will use to manage this server?"
    has "a refused key is not asked about twice" "$(grep -c '^ASKED' "$TMP/gate.screens")" 1
    # The person's own key, confirmed: it counts, and names itself.
    : >"$FAKE_JOURNAL" ; : >"$TMP/gate.screens"
    jline "$now" "Accepted publickey for alice from 192.168.18.24 port 4 ssh2: ED25519 SHA256:windowskey"
    GATE_SAY=yes
    if ssh_wait_login alice "$now" test; then ok; else bad "a confirmed key login did not count"; fi
    eq "the confirmed key is kept for the summary" "$SSH_KEY_SEEN" "key SHA256:windowskey from 192.168.18.24"
    # The whole switch never counts a login from before its first prompt.
    : >"$FAKE_JOURNAL" ; : >"$TMP/gate.screens"
    jline $((now - 30)) "Accepted publickey for alice from 10.0.0.9 port 5 ssh2: ED25519 SHA256:backupjob"
    SUDO_USER=alice SSH_PLAN=guide DRY_RUN=0 RUN_START=0 GATE_MENU=stop
    ssh_has_key() { return 0; }
    ssh_run >/dev/null 2>&1
    has "a login since the setup began is not enough" "$SSH_RESULT" "never saw a key login for alice that you confirmed"
    # An answer file names the key; any other key never counts.
    UI_MODE=answers
    ANS=([ssh_wait_secs]=1)
    : >"$FAKE_JOURNAL"
    jline "$now" "Accepted publickey for alice from 10.0.0.9 port 6 ssh2: ED25519 SHA256:backupjob"
    ssh_run >/dev/null 2>&1
    has "an answer file without the key keeps passwords" "$SSH_RESULT" "has to name the key"
    ANS=([ssh_wait_secs]=1 [ssh_key_fingerprint]=SHA256:windowskey)
    no_ ssh_wait_login alice "$now" test
    jline "$now" "Accepted publickey for alice from 192.168.18.24 port 7 ssh2: ED25519 SHA256:windowskey"
    yes_ ssh_wait_login alice "$now" test
}
in_sub t_gate
printf 'passwordauthentication yes\nkbdinteractiveauthentication no\n' >"$FAKE_SSHD_T"
yes_ ssh_passwords_on
printf 'passwordauthentication no\nkbdinteractiveauthentication yes\n' >"$FAKE_SSHD_T"
yes_ ssh_passwords_on
printf 'passwordauthentication no\nkbdinteractiveauthentication no\n' >"$FAKE_SSHD_T"
no_ ssh_passwords_on
d=$(hollow_sshd_dropin alice)
has "dropin passwords off" "$d" "PasswordAuthentication no"
has "dropin kbd off" "$d" "KbdInteractiveAuthentication no"
has "dropin root off for a sudo user" "$d" "PermitRootLogin no"
has "root keeps key logins" "$(hollow_sshd_dropin root)" "PermitRootLogin prohibit-password"
case "$(basename "$HOLLOW_SSHD_DROPIN")" in
[0-4]*) ok ;;
*) bad "the sshd drop-in sorts after 50-cloud-init.conf, which would win" ;;
esac
# Answer-file waits poll the journal and give up on time.
UI_MODE=answers
ANS=([ssh_wait_secs]=1 [ssh_key_fingerprint]=SHA256:carol)
: >"$FAKE_JOURNAL"
t0=$(date +%s)
if ssh_wait_login carol 0 test >/dev/null; then bad "a wait with no login said yes"; else ok; fi
if [ $(( $(date +%s) - t0 )) -le 20 ]; then ok; else bad "the wait ran past its time"; fi
jline 5 "Accepted publickey for carol from 192.0.2.1 port 1 ssh2: ED25519 SHA256:carol"
yes_ ssh_wait_login carol 0 test
PATH=${PATH#"$FAKE:"}

echo "certbot scripts"
for f in "$DEPLOY"/certbot/*.sh "$DEPLOY"/coturn/*.sh "$DEPLOY"/forwarder/*.sh "$DEPLOY"/harden-host.sh "$DEPLOY"/lib/host.sh; do
    if sh -n "$f"; then ok; else bad "sh -n $f"; fi
done
for f in "$RELAY/install.sh" "$DEPLOY"/lib/*.sh "$DEPLOY"/check-host.sh "$T"/run_tests.sh; do
    if bash -n "$f"; then ok; else bad "bash -n $f"; fi
done
# The DuckDNS token never reaches curl's command line, where ps shows it to
# every local account: a fake curl records its arguments.
cat >"$FAKE/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_ARGS"
cat >/dev/null
echo OK
EOF
chmod +x "$FAKE/curl"
export FAKE_CURL_ARGS=$TMP/curl.args
: >"$FAKE_CURL_ARGS"
PATH="$FAKE:$PATH" duckdns_update myrelay SECRET-TOKEN-1 "" >/dev/null
PATH="$FAKE:$PATH" sh -c '. "$1/certbot/lib.sh"; http_get "https://www.duckdns.org/update?domains=x&token=SECRET-TOKEN-2&txt=y"' _ "$DEPLOY" >/dev/null
lacks "installer token off the command line" "$(cat "$FAKE_CURL_ARGS")" "SECRET-TOKEN-1"
lacks "hook token off the command line" "$(cat "$FAKE_CURL_ARGS")" "SECRET-TOKEN-2"
has "curl was called" "$(cat "$FAKE_CURL_ARGS")" "-K -"
# The hooks work wherever they are installed: certbot's renewal calls them by path.
lacks "no fixed /hooks path" "$(grep -h '^\. ' "$DEPLOY"/certbot/*.sh)" "/hooks/"

echo "user-facing text"
# Setting paths read Settings > Network, never with commas.
lacks "no comma-separated setting path" "$(cat "$RELAY/install.sh" "$DEPLOY"/lib/*.sh)" "Settings, "
# No em dash, ever, in what the person reads.
dash=$(printf '\342\200\224')
for f in "$RELAY/install.sh" "$DEPLOY"/lib/*.sh "$DEPLOY"/certbot/*.sh "$DEPLOY"/check-host.sh "$DEPLOY"/harden-host.sh; do
    lacks "em dash in $(basename "$f")" "$(cat "$f")" "$dash"
done

# The release feed's test seam, in one place: the lib's own hooks, replaced
# after loading it (nothing in the environment can reach them).
feed_test_point_at() {
    feed_lib_load
    # The baked floors rise every release; test/release_feed checks them.
    _HF_MIN_ISSUED=1 _HF_MIN_VERSION=0.0.0 _HF_MIN_BUILD=0
    FEED_T_BASE="file://$1" FEED_T_KEY=$2
    _hf_release_keys() { printf '%s\n' "$FEED_T_KEY"; }
    _hf_base() { printf '%s' "$FEED_T_BASE"; }
    _hf_protos() { printf '=file'; }
    hollow_feed_arch() { printf 'linux-x86_64\n'; }
}

# mkfeed <dir> <key.pem> <version> <build> <issued>: a signed relay feed.
mkfeed() {
    local d=$1 key=$2 v=$3 b=$4 i=$5 name
    mkdir -p "$d"
    if [ "$b" -gt 0 ]; then name="hollow-relay-$v-b$b-linux-x86_64.tar.gz"; else name="hollow-relay-$v-linux-x86_64.tar.gz"; fi
    printf '{\n  "feed": "relay",\n  "version": "%s",\n  "build": %s,\n  "issued": %s,\n  "commit": "%s",\n  "artifacts": {\n    "linux-x86_64": {\n      "url": "https://anonlisten.com/hollow/releases/%s",\n      "sha256": "%s",\n      "size": 1234\n    }\n  }\n}\n' \
        "$v" "$b" "$i" "$(printf '%040d' 0)" "$name" "$(printf '%064d' 0)" >"$d/relay.json"
    { printf 'hollow-feed-sig-v1\0relay\0'; cat "$d/relay.json"; } >"$d/msg"
    openssl pkeyutl -sign -inkey "$key" -rawin -in "$d/msg" -out "$d/sig.bin"
    { base64 -w0 "$d/sig.bin"; echo; } >"$d/relay.json.sig"
    rm -f "$d/msg" "$d/sig.bin"
}

if [ -r "$DEPLOY/lib/release_feed.sh" ] && command -v jq >/dev/null && command -v flock >/dev/null &&
   openssl genpkey -algorithm ed25519 -out "$TMP/feed.pem" 2>/dev/null; then
    echo "update check"
    pub=$(openssl pkey -in "$TMP/feed.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')
    feed_test_point_at "$TMP/feed" "$pub"
    VERSION_FILE=$TMP/VERSION BUILT_FROM_FILE=$TMP/BUILT_FROM STATE_DIR=$TMP/state CFG_MODE=native DRY_RUN=0
    printf 'version=0.12.2\nbuild=0\n' >"$VERSION_FILE"
    echo prebuilt >"$BUILT_FROM_FILE"
    ensure_dir() { mkdir -p "$1"; }
    apt_install() { :; }
    now=$(date +%s)
    mkfeed "$TMP/feed" "$TMP/feed.pem" 0.12.3 0 "$now"
    update_check 2>/dev/null
    eq "a newer signed feed offers the update" "$UPDATE_AVAILABLE" 1
    has "the status screen names it" "$UPDATE_TEXT" "version 0.12.3 (build 0) is available"
    mkfeed "$TMP/feed" "$TMP/feed.pem" 0.12.2 0 $((now + 1))
    update_check 2>/dev/null
    eq "the same release offers nothing" "$UPDATE_AVAILABLE" 0
    has "up to date" "$UPDATE_TEXT" "up to date"
    # The update installs only what the person confirmed, and only if newer.
    out=$(EXPECT_VERSION=0.12.3 EXPECT_BUILD=0 programs_prebuilt 2>&1)
    has "a changed feed is refused" "$out" "changed since the status screen"
    out=$(EXPECT_VERSION=0.12.2 EXPECT_BUILD=0 programs_prebuilt 2>&1)
    has "an equal release is refused" "$out" "is not newer"
    # Older than what runs here: offered only as a choice by name, never installed by an update.
    printf 'version=0.12.4\nbuild=0\n' >"$VERSION_FILE"
    mkfeed "$TMP/feed" "$TMP/feed.pem" 0.12.3 0 $((now + 2))
    update_check 2>/dev/null
    eq "an older feed is no update" "$UPDATE_AVAILABLE" 0
    eq "an older feed is offered as a downgrade" "$DOWNGRADE_AVAILABLE" 1
    has "the downgrade is named" "$UPDATE_TEXT" "older version 0.12.3 (build 0)"
    out=$(EXPECT_VERSION=0.12.3 EXPECT_BUILD=0 programs_prebuilt 2>&1)
    has "an update never downgrades" "$out" "refusing to downgrade"
    printf 'version=0.12.2\nbuild=0\n' >"$VERSION_FILE"
    openssl genpkey -algorithm ed25519 -out "$TMP/other.pem" 2>/dev/null
    mkfeed "$TMP/feed" "$TMP/other.pem" 0.12.3 0 $((now + 3))
    update_check 2>/dev/null
    eq "a feed signed by another key offers nothing" "$UPDATE_AVAILABLE" 0
    has "and says it could not check" "$UPDATE_TEXT" "cannot check right now"
fi

echo "the setup's own copy"
# A tree like the one a release carries, staged from this checkout.
setup_tree() { # <dir>
    rm -rf "$1"
    bash "$REPO/scripts/build_relay_binaries.sh" --stage-setup "$REPO" "$1" >/dev/null
}
# copy_paths <root>: the setup's copy, its stages and the launcher under <root>.
copy_paths() {
    LIB_DIR=$1 INSTALLER_COPY=$1/installer PREVIOUS_DIR=$1/previous
    SETUP_STAGE=$INSTALLER_COPY.stage SETUP_NEW=$INSTALLER_COPY.new SETUP_KEPT=$PREVIOUS_DIR/installer
    SETUP_LINK=$TMP/sbin/hollow-relay-setup DRY_RUN=0
}
COMMIT0=$(printf '%040d' 0)
t_setup_copy() {
    copy_paths "$TMP/lib"
    ensure_dir() { mkdir -p "$1"; }
    [ "$(id -u)" = 0 ] || chown() { :; }
    mkdir -p "$INSTALLER_COPY" && echo old >"$INSTALLER_COPY/install.sh"
    setup_tree "$TMP/st"
    printf '\n# NEWER\n' >>"$TMP/st/install.sh"
    yes_ setup_copy_stage "$TMP/st" release 0.12.3 2 "$COMMIT0"
    eq "the staged install.sh is runnable" "$(stat -c %a "$SETUP_NEW/install.sh")" 755
    eq "the staged libraries are plain" "$(stat -c %a "$SETUP_NEW/deploy/lib/native.sh")" 644
    eq "the staged copy names the release it came with" "$(cat "$SETUP_NEW/SOURCE")" "$(printf 'kind=release\nversion=0.12.3\nbuild=2\ncommit=%s' "$COMMIT0")"
    no_ test -e "$SETUP_STAGE"
    eq "the live copy is untouched while staged" "$(cat "$INSTALLER_COPY/install.sh")" old
    yes_ setup_copy_swap "$SETUP_KEPT"
    has "the new copy is live" "$(cat "$INSTALLER_COPY/install.sh")" "# NEWER"
    eq "the old one is kept for a rollback" "$(cat "$SETUP_KEPT/install.sh")" old
    no_ test -e "$SETUP_NEW"
    no_ test -L "$SETUP_LINK"
    yes_ cmp -s "$SETUP_LINK" "$INSTALLER_COPY/deploy/hollow-relay-setup"
    eq "hollow-relay-setup is the launcher, outside the copy" "$(stat -c %a "$SETUP_LINK")" 755
    SETUP_CHANGE=replaced
    yes_ setup_copy_rollback
    eq "a rollback puts the old copy back" "$(cat "$INSTALLER_COPY/install.sh")" old
    no_ test -e "$SETUP_KEPT"
    eq "and says so" "$SETUP_CHANGE" kept
    no_ setup_copy_rollback
    # A kept copy this run did not put there is never brought back.
    mkdir -p "$SETUP_KEPT" && echo stale >"$SETUP_KEPT/install.sh"
    SETUP_CHANGE=absent
    no_ setup_copy_rollback
    eq "a rollback after a release without the setup keeps the live copy" "$(cat "$INSTALLER_COPY/install.sh")" old
    rm -rf "$SETUP_KEPT"
    # Refusals: each leaves the live copy as it was and nothing staged.
    local bad
    for bad in link missing syntax device; do
        setup_tree "$TMP/st"
        case "$bad" in
        link) ln -s /etc/passwd "$TMP/st/deploy/lib/x.sh" ;;
        missing) rm "$TMP/st/deploy/lib/release_feed.sh" ;;
        syntax) printf 'if then\n' >>"$TMP/st/deploy/lib/common.sh" ;;
        device) mkfifo "$TMP/st/deploy/fifo" ;;
        esac
        no_ setup_copy_stage "$TMP/st" release 0.12.3 2 "$COMMIT0"
        eq "a staged copy with a $bad entry leaves the live one" "$(cat "$INSTALLER_COPY/install.sh")" old
        no_ test -e "$SETUP_NEW"
        no_ test -e "$SETUP_STAGE"
    done
    setup_tree "$TMP/st"
    local p
    for p in INSTALLER_COPY SETUP_KEPT PREVIOUS_DIR SETUP_STAGE; do
        rm -rf "${TMP:?}/lib" && mkdir -p "$TMP/lib/installer" "$TMP/elsewhere" && echo old >"$TMP/lib/installer/install.sh"
        case "$p" in
        INSTALLER_COPY) mv "$TMP/lib/installer" "$TMP/real" && ln -s "$TMP/real" "$TMP/lib/installer" ;;
        SETUP_KEPT) mkdir -p "$PREVIOUS_DIR" && ln -s "$TMP/elsewhere" "$SETUP_KEPT" ;;
        PREVIOUS_DIR) ln -s "$TMP/elsewhere" "$PREVIOUS_DIR" ;;
        SETUP_STAGE) ln -s "$TMP/elsewhere" "$SETUP_STAGE" ;;
        esac
        no_ setup_copy_stage "$TMP/st" release 0.12.3 2 "$COMMIT0"
        no_ setup_copy_swap "$SETUP_KEPT"
        eq "a link at $p moves nothing" "$(ls -A "$TMP/elsewhere")" ""
        rm -rf "$TMP/real" "$TMP/elsewhere"
    done
    # A second rename that fails puts the old copy back.
    rm -rf "${TMP:?}/lib" && mkdir -p "$INSTALLER_COPY" && echo old >"$INSTALLER_COPY/install.sh"
    no_ setup_copy_swap "$SETUP_KEPT"
    eq "a swap with nothing staged keeps the live copy" "$(cat "$INSTALLER_COPY/install.sh")" old
    has "the update says what happened to the setup" "$(SETUP_CHANGE=absent setup_change_text)" "does not carry a new version of the setup"
    has "and a downgrade keeps the newer one" "$(SETUP_CHANGE=none setup_change_text)" "keeps the newer setup"
}
in_sub t_setup_copy

echo "a staged setup that cannot start never replaces the live one"
# a_staged_setup_that_cannot_start_never_replaces_the_live_one: each copy
# below parses, but its install.sh --self-check fails, so it never goes live.
t_setup_cannot_start() {
    copy_paths "$TMP/lib2"
    ensure_dir() { mkdir -p "$1"; }
    [ "$(id -u)" = 0 ] || chown() { :; }
    local bad
    for bad in nolib failinglib noentry noselfcheck oldprotocol; do
        rm -rf "$TMP/lib2" && mkdir -p "$INSTALLER_COPY" && echo live >"$INSTALLER_COPY/install.sh"
        setup_tree "$TMP/st"
        case "$bad" in
        nolib) rm "$TMP/st/deploy/lib/ui.sh" ;;
        failinglib) printf 'false\n' >>"$TMP/st/deploy/lib/questions.sh" ;;
        noentry) printf 'unset -f manage_update\n' >>"$TMP/st/deploy/lib/adopt.sh" ;;
        noselfcheck) sed -i 's/^if \[ "${1:-}" = --self-check \]; then$/if false; then/' "$TMP/st/install.sh" ;;
        oldprotocol) sed -i 's/^SETUP_PROTOCOL=.*/SETUP_PROTOCOL="hollow-relay-setup self-check 0"/' "$TMP/st/deploy/lib/native.sh" ;;
        esac
        no_ setup_copy_stage "$TMP/st" release 0.12.3 2 "$COMMIT0"
        eq "a copy whose start fails ($bad) leaves the live one" "$(cat "$INSTALLER_COPY/install.sh")" live
        no_ test -e "$SETUP_NEW"
        no_ test -e "$SETUP_STAGE"
    done
    # The check alone, on a copy that holds every file and parses.
    setup_tree "$TMP/st"
    yes_ setup_new_check "$TMP/st"
    printf 'false\n' >>"$TMP/st/deploy/lib/host.sh"
    no_ setup_new_check "$TMP/st"
    setup_tree "$TMP/st"
    rm "$TMP/st/push-sidecar/package-lock.json"
    no_ setup_new_check "$TMP/st"
    # a_setup_copy_without_the_port_lock_never_goes_live
    setup_tree "$TMP/st"
    rm "$TMP/st/deploy/turn-port-lock.sh"
    no_ setup_new_check "$TMP/st"
    eq "what a copy needs: the next update's files and every library install.sh sources" \
        "$(setup_needs "$REPO/relay-uws" | LC_ALL=C sort | tr '\n' ' ')" \
        "$( { printf '%s\n' install.sh deploy/lib/release_feed.sh push-sidecar/package-lock.json push-sidecar/package.json \
                  deploy/turn-port-lock.sh deploy/hollow-turn-port-lock.service deploy/hollow-turn-port-lock-refresh.service \
                  deploy/hollow-turn-port-lock-refresh.timer deploy/coturn-port-lock.conf; \
              sed -n 's|^\. "\$DEPLOY/lib/\(.*\)"$|deploy/lib/\1|p' "$REPO/relay-uws/install.sh"; } | LC_ALL=C sort | tr '\n' ' ')"
    eq "the needs name release_feed.sh and the eleven libraries install.sh sources" "$(setup_needs "$REPO/relay-uws" | grep -c '^deploy/lib/')" 12
}
in_sub t_setup_cannot_start

echo "a swap cut short between its renames"
# a_run_after_a_kill_between_the_swap_renames_restores_a_working_copy (the
# box test kills a real run; this is the repair alone).
t_setup_repair() {
    copy_paths "$TMP/lib3"
    reset() { rm -rf "$TMP/lib3" && mkdir -p "$PREVIOUS_DIR"; }
    reset; mkdir -p "$SETUP_NEW" "$SETUP_KEPT"; echo new >"$SETUP_NEW/install.sh"; echo old >"$SETUP_KEPT/install.sh"
    yes_ setup_copy_repair
    eq "the checked new copy goes live" "$(cat "$INSTALLER_COPY/install.sh")" new
    eq "and the old one stays kept" "$(cat "$SETUP_KEPT/install.sh")" old
    no_ test -e "$SETUP_NEW"
    reset; mkdir -p "$SETUP_KEPT"; echo old >"$SETUP_KEPT/install.sh"
    yes_ setup_copy_repair
    eq "with no new copy, the kept one goes back" "$(cat "$INSTALLER_COPY/install.sh")" old
    reset; mkdir -p "$INSTALLER_COPY" "$SETUP_NEW"; echo live >"$INSTALLER_COPY/install.sh"; echo new >"$SETUP_NEW/install.sh"
    yes_ setup_copy_repair
    eq "a copy in place is never touched" "$(cat "$INSTALLER_COPY/install.sh")" live
    reset; mkdir -p "$SETUP_STAGE"; echo half >"$SETUP_STAGE/install.sh"; mkdir -p "$SETUP_KEPT"; echo old >"$SETUP_KEPT/install.sh"
    yes_ setup_copy_repair
    eq "a copy still being staged never goes live" "$(cat "$INSTALLER_COPY/install.sh")" old
    reset; mkdir -p "$TMP/elsewhere"; echo evil >"$TMP/elsewhere/install.sh"; ln -s "$TMP/elsewhere" "$SETUP_NEW"
    no_ setup_copy_repair
    no_ test -e "$INSTALLER_COPY"
    rm -rf "$TMP/elsewhere"
    reset
    yes_ setup_copy_repair
    no_ test -e "$INSTALLER_COPY"
    DRY_RUN=1; reset; mkdir -p "$SETUP_NEW"; echo new >"$SETUP_NEW/install.sh"
    yes_ setup_copy_repair
    no_ test -e "$INSTALLER_COPY"
}
in_sub t_setup_repair

echo "an older clone and the setup a release installed"
# a_stale_clone_never_silently_replaces_a_release_copy
t_clone_gate() {
    copy_paths "$TMP/lib4"
    local clone=$TMP/clone
    rm -rf "$clone" && mkdir -p "$clone/relay-uws/src" "$INSTALLER_COPY"
    stamp() { printf 'kind=%s\nversion=%s\nbuild=4\ncommit=%s\n' "$1" "$2" "${3:-$COMMIT0}" >"$INSTALLER_COPY/SOURCE"; }
    clone_at() { printf '#define HOLLOW_RELAY_VERSION "%s"\n' "$1" >"$clone/relay-uws/src/version.h"; }
    source_commit() { printf '%s' "${CLONE_COMMIT:-}"; }
    HERE=$clone/relay-uws REPO=$clone
    stamp release 0.13.0; clone_at 0.12.2
    eq "an older clone" "$(setup_clone_verdict)" older
    clone_at 0.13.1
    eq "a newer clone" "$(setup_clone_verdict)" newer
    clone_at 0.13.0
    eq "the same version from an unknown commit" "$(setup_clone_verdict)" unknown
    CLONE_COMMIT=$COMMIT0
    eq "the same version and commit" "$(setup_clone_verdict)" same
    CLONE_COMMIT=""
    rm "$clone/relay-uws/src/version.h"
    eq "a clone without a version" "$(setup_clone_verdict)" unknown
    stamp clone 0.13.0
    eq "a copy from a clone is no release's" "$(setup_clone_verdict)" free
    rm "$INSTALLER_COPY/SOURCE"
    eq "nor is an unstamped copy" "$(setup_clone_verdict)" free
    stamp release 0.13.0; clone_at 0.12.2
    HERE=$INSTALLER_COPY
    eq "the installed copy itself" "$(setup_clone_verdict)" free
    HERE=$clone/relay-uws
    # The write itself refuses without the person's yes.
    echo release >"$INSTALLER_COPY/install.sh"
    WORK_DIR=$TMP/wd4; mkdir -p "$WORK_DIR"
    local out
    out=$(install_installer_copy 2>&1)
    has "install_installer_copy keeps a newer release's copy" "$out" "so I kept it"
    eq "and the copy is untouched" "$(cat "$INSTALLER_COPY/install.sh")" release
    no_ setup_clone_may_replace
    SETUP_REPLACE_OK=1
    yes_ setup_clone_may_replace
    SETUP_REPLACE_OK=0
    # The question, unattended: the default keeps everything.
    UI_MODE=answers
    ans_get() { case "$1" in replace_setup) printf '%s' "${ANS_REPLACE:-${2:-}}" ;; *) printf '%s' "${2:-}" ;; esac; }
    out=$( (setup_clone_gate; echo "WENT ON $SETUP_REPLACE_OK") 2>&1)
    has "the question's default leaves it" "$out" "Nothing changed. Run sudo hollow-relay-setup"
    lacks "and stops there" "$out" "WENT ON"
    out=$( (ANS_REPLACE=yes; setup_clone_gate; echo "WENT ON $SETUP_REPLACE_OK") 2>&1)
    has "a yes lets this copy replace it" "$out" "WENT ON 1"
    clone_at 0.14.0
    out=$( (setup_clone_gate; echo "WENT ON ${SETUP_REPLACE_OK:-0}") 2>&1)
    has "a newer clone asks nothing" "$out" "WENT ON 0"
}
in_sub t_clone_gate

if [ -r "$DEPLOY/lib/release_feed.sh" ] && command -v jq >/dev/null && command -v flock >/dev/null &&
   openssl genpkey -algorithm ed25519 -out "$TMP/feed2.pem" 2>/dev/null; then
echo "an update brings the setup's copy"
# <dir> <key.pem> <version> <variant: setup|old|extra|link|dotdot|big>: a signed
# feed and its tarball, programs as stand-ins.
mkfeed_tar() {
    local d=$1 key=$2 v=$3 kind=$4 s=$TMP/pk.$RANDOM name sha size
    rm -rf "$d" "$s" && mkdir -p "$d" "$s"
    name="hollow-relay-$v-linux-x86_64.tar.gz"
    printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x3e\x00' >"$s/hollow-relay"
    cp "$s/hollow-relay" "$s/hollow-forwarder"
    chmod 0755 "$s/hollow-relay" "$s/hollow-forwarder"
    printf 'version=%s\nbuild=0\ncommit=%s\n' "$v" "$(printf '%040d' 0)" >"$s/VERSION"
    chmod 0644 "$s/VERSION"
    [ "$kind" = old ] || setup_tree "$s/setup"
    printf '\n# RELEASE %s\n' "$v" >>"$s/setup/install.sh" 2>/dev/null || true
    case "$kind" in
    extra) echo x >"$s/setup/evil.sh" ;;
    link) ln -s /etc/passwd "$s/setup/deploy/lib/evil.sh" ;;
    big) head -c 1048577 /dev/zero | tr '\0' '#' >"$s/setup/deploy/lib/big.sh" ;;
    cannotstart) printf 'false\n' >>"$s/setup/deploy/lib/questions.sh" ;;
    esac
    if [ "$kind" = dotdot ] || [ "$kind" = link ]; then
        # The build packs files only, so these come from tar by hand.
        local tf=()
        [ "$kind" = dotdot ] && tf=(-P --transform 's,^setup/deploy/lib/common.sh$,setup/../common.sh,')
        (cd "$s" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort |
            tar --owner=0 --group=0 --no-recursion "${tf[@]}" -T - -czf "$d/$name")
    else
        bash "$REPO/scripts/build_relay_binaries.sh" --pack "$s" "$d/$name"
    fi
    sha=$(sha256sum "$d/$name" | cut -d' ' -f1)
    size=$(stat -c %s "$d/$name")
    printf '{"feed":"relay","version":"%s","build":0,"issued":%s,"commit":"%s","artifacts":{"linux-x86_64":{"url":"https://anonlisten.com/hollow/releases/%s","sha256":"%s","size":%s}}}\n' \
        "$v" "$(date +%s)" "$(printf '%040d' 0)" "$name" "$sha" "$size" >"$d/relay.json"
    { printf 'hollow-feed-sig-v1\0relay\0'; cat "$d/relay.json"; } >"$d/msg"
    openssl pkeyutl -sign -inkey "$key" -rawin -in "$d/msg" -out "$d/sig.bin"
    { base64 -w0 "$d/sig.bin"; echo; } >"$d/relay.json.sig"
    rm -rf "$s" "$d/msg" "$d/sig.bin"
}
t_update_setup() {
    local pub kind out
    pub=$(openssl pkey -in "$TMP/feed2.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')
    feed_test_point_at "$TMP/feed2" "$pub"
    copy_paths "$TMP/ulib"
    VERSION_FILE=$TMP/ulib/VERSION STATE_DIR=$TMP/ustate CFG_MODE=native UI_MODE=answers
    UPDATE_MARK=$STATE_DIR/update_pending UPDATE_SNAP=$STATE_DIR/update-snapshot
    ensure_dir() { mkdir -p "$1"; }
    apt_install() { :; }
    [ "$(id -u)" = 0 ] || chown() { :; }
    install_programs() { cp "$1/VERSION" "$VERSION_FILE"; mkdir -p "$PREVIOUS_DIR"; echo installed >>"$TMP/ustate/programs"; }
    reset_copy() { rm -rf "$TMP/ulib" "$TMP/ustate"; mkdir -p "$INSTALLER_COPY"; echo live >"$INSTALLER_COPY/install.sh"; printf 'version=0.12.2\nbuild=0\n' >"$VERSION_FILE"; }
    reset_copy
    mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 setup
    prebuilt_available "$VERSION_FILE"
    SETUP_CHANGE=none SETUP_FROM_RELEASE=1 EXPECT_VERSION=0.12.3 EXPECT_BUILD=0
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "the update installs" "$out" "CHANGE=replaced"
    has "and the release's setup is live" "$(cat "$INSTALLER_COPY/install.sh")" "# RELEASE 0.12.3"
    eq "the copy it replaced is kept" "$(cat "$SETUP_KEPT/install.sh")" live
    for kind in extra link dotdot big; do
        reset_copy
        mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 "$kind"
        prebuilt_available "$VERSION_FILE"
        out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
        has "a release whose setup has a $kind entry is refused" "$out" "DIE the download did not pass its checks"
        eq "and the setup's copy is untouched ($kind)" "$(cat "$INSTALLER_COPY/install.sh")" live
        eq "and nothing installed ($kind)" "$(cat "$VERSION_FILE")" "$(printf 'version=0.12.2\nbuild=0')"
    done
    # The release's own setup cannot start: nothing at all is installed.
    reset_copy
    mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 cannotstart
    prebuilt_available "$VERSION_FILE"
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "a release whose setup cannot start is refused" "$out" "DIE the copy of the setup in this release is not complete or does not start"
    eq "and its setup never goes live" "$(cat "$INSTALLER_COPY/install.sh")" live
    eq "and no program was installed" "$(cat "$VERSION_FILE")" "$(printf 'version=0.12.2\nbuild=0')"
    no_ test -e "$TMP/ustate/programs"
    no_ test -e "$SETUP_NEW"
    reset_copy
    mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 old
    prebuilt_available "$VERSION_FILE"
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "a release without the setup still updates the programs" "$out" "CHANGE=absent"
    eq "and keeps the setup's copy" "$(cat "$INSTALLER_COPY/install.sh")" live
    reset_copy
    mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 setup
    prebuilt_available "$VERSION_FILE"
    SETUP_FROM_RELEASE=0
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    eq "a downgrade or a first install never takes the release's setup" "$(cat "$INSTALLER_COPY/install.sh")" live
    no_ test -e "$SETUP_NEW"
}
in_sub t_update_setup

echo "an update that stopped part of the way"
t_update_pending() {
    local pub out
    pub=$(openssl pkey -in "$TMP/feed2.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')
    feed_test_point_at "$TMP/feed2" "$pub"
    copy_paths "$TMP/plib"
    VERSION_FILE=$TMP/plib/VERSION STATE_DIR=$TMP/pstate CFG_MODE=native UI_MODE=answers
    UPDATE_MARK=$STATE_DIR/update_pending UPDATE_SNAP=$STATE_DIR/update-snapshot
    ensure_dir() { mkdir -p "$1"; }
    apt_install() { :; }
    [ "$(id -u)" = 0 ] || chown() { :; }
    install_programs() { cp "$1/VERSION" "$VERSION_FILE"; echo installed >>"$STATE_DIR/programs"; }
    update_settings_keep() { echo kept >>"$STATE_DIR/settings"; mkdir -p "$UPDATE_SNAP"; }
    rm -rf "$TMP/plib" "$STATE_DIR" && mkdir -p "$INSTALLER_COPY" "$STATE_DIR" && echo live >"$INSTALLER_COPY/install.sh"
    printf 'version=0.12.2\nbuild=0\n' >"$VERSION_FILE"
    mkfeed_tar "$TMP/feed2" "$TMP/feed2.pem" 0.12.3 setup
    prebuilt_available "$VERSION_FILE"
    SETUP_FROM_RELEASE=1 EXPECT_VERSION=0.12.3 EXPECT_BUILD=0 UPDATE_RUNNING=1
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "an update installs" "$out" "CHANGE=replaced"
    eq "the mark names the release until it is done" "$(kv_get "$UPDATE_MARK" version) $(kv_get "$UPDATE_MARK" build) $(kv_get "$UPDATE_MARK" setup)" "0.12.3 0 release"
    eq "with what it kept" "$(kv_get "$UPDATE_MARK" kept)" "settings setup"
    eq "the settings were kept once" "$(cat "$STATE_DIR/settings")" kept
    eq "the copy it replaced is kept" "$(cat "$SETUP_KEPT/install.sh")" live
    has "the live copy is the release's" "$(cat "$INSTALLER_COPY/SOURCE")" "version=0.12.3"
    # The run died before its last step; the next one finishes it.
    update_check
    eq "the next run offers to finish it" "$UPDATE_AVAILABLE $FINISH_PENDING" "1 1"
    has "and says why" "$UPDATE_TEXT" "stopped part of the way"
    has "the menu names it" "$(HERE="$INSTALLER_COPY"; ui_menu() { printf '%s\n' "$@"; UI_REPLY="exit"; }; ui_msg() { :; }; local_ipv4() { :; }
        local_get() { :; }; served_cert_expiry() { :; }; ssh_passwords_on() { return 1; }; manage_main 2>&1)" "Finish the update to version 0.12.3"
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "finishing installs the same release again" "$out" "CHANGE=replaced"
    eq "never keeping the settings twice" "$(cat "$STATE_DIR/settings")" kept
    eq "nor the copy it already put in place" "$(cat "$SETUP_KEPT/install.sh")" live
    no_ test -e "$SETUP_NEW"
    # A change waits for the update: its rollback would undo it.
    out=$(apply_all() { echo APPLIED; }; ui_msg() { echo "$1: $2"; }; manage_change 2>&1)
    has "a change waits for the update" "$out" "Finish the update first"
    lacks "and changes nothing" "$out" "APPLIED"
    update_done
    no_ update_pending
    no_ test -e "$UPDATE_SNAP"
    update_check
    eq "a finished update offers nothing" "$UPDATE_AVAILABLE ${FINISH_PENDING:-0}" "0 0"
    # Killed between its programs and the setup's swap: the mark keeps the
    # rollback state of the first run, and finishing swaps the setup in.
    rm -rf "$TMP/plib" "$STATE_DIR" && mkdir -p "$INSTALLER_COPY" "$SETUP_KEPT" "$STATE_DIR"
    echo live >"$INSTALLER_COPY/install.sh"; echo stale >"$SETUP_KEPT/install.sh"
    printf 'version=0.12.3\nbuild=0\ncommit=%s\n' "$(printf '%040d' 0)" >"$VERSION_FILE"
    printf 'version=0.12.3\nbuild=0\nsetup=release\nkept=settings programs\n' >"$UPDATE_MARK"
    update_check
    eq "the relay is new, the setup old: the next run finishes it" "$UPDATE_AVAILABLE $FINISH_PENDING" "1 1"
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "the release's setup goes live" "$(cat "$INSTALLER_COPY/SOURCE" 2>/dev/null)" "version=0.12.3"
    eq "the copy it replaced is kept" "$(cat "$SETUP_KEPT/install.sh")" live
    eq "and the settings stay as first kept" "$(cat "$STATE_DIR/settings" 2>/dev/null)" ""
    eq "the ledger adds the setup" "$(kv_get "$UPDATE_MARK" kept)" "settings programs setup"
    # Killed after the swap moved the old copy aside, before the ledger said
    # so, and the copy repaired: the release's setup is live, the old one kept.
    rm -rf "$TMP/plib" "$STATE_DIR" && mkdir -p "$INSTALLER_COPY" "$SETUP_KEPT" "$STATE_DIR"
    echo target >"$INSTALLER_COPY/install.sh"; printf 'kind=release\nversion=0.12.3\nbuild=0\n' >"$INSTALLER_COPY/SOURCE"
    echo pre >"$SETUP_KEPT/install.sh"
    printf 'version=0.12.3\nbuild=0\ncommit=%s\n' "$(printf '%040d' 0)" >"$VERSION_FILE"
    printf 'version=0.12.3\nbuild=0\nsetup=release\nkept=settings programs\n' >"$UPDATE_MARK"
    update_check
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "finishing it with the setup already live" "$out" "CHANGE=replaced"
    eq "keeps the copy from before the update" "$(cat "$SETUP_KEPT/install.sh")" pre
    eq "and the release's copy live" "$(cat "$INSTALLER_COPY/install.sh")" target
    eq "and the ledger notes the setup as kept" "$(kv_get "$UPDATE_MARK" kept)" "settings programs setup"
    # A newer release over an unfinished update that already kept the setup:
    # the rollback still goes to the setup from before the first one.
    rm -rf "$TMP/plib" "$STATE_DIR" && mkdir -p "$INSTALLER_COPY" "$SETUP_KEPT" "$STATE_DIR"
    echo unfinished >"$INSTALLER_COPY/install.sh"; printf 'kind=release\nversion=0.12.2\nbuild=5\n' >"$INSTALLER_COPY/SOURCE"
    echo pre >"$SETUP_KEPT/install.sh"
    printf 'version=0.12.2\nbuild=5\ncommit=%s\n' "$(printf '%040d' 0)" >"$VERSION_FILE"
    printf 'version=0.12.2\nbuild=5\nsetup=release\nkept=settings programs setup\n' >"$UPDATE_MARK"
    update_check
    eq "a newer release is offered as an update" "$UPDATE_AVAILABLE ${FINISH_PENDING:-0}" "1 0"
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "it installs" "$out" "CHANGE=replaced"
    has "its setup goes live" "$(cat "$INSTALLER_COPY/SOURCE")" "version=0.12.3"
    eq "the copy from before the first update stays kept" "$(cat "$SETUP_KEPT/install.sh")" pre
    eq "the mark names the newer release, with the same ledger" "$(kv_get "$UPDATE_MARK" version) $(kv_get "$UPDATE_MARK" kept)" "0.12.3 settings programs setup"
    eq "and the settings were never kept again" "$(cat "$STATE_DIR/settings" 2>/dev/null)" ""
    # A swap whose second rename failed put the old copy back after the
    # ledger noted it: the next run keeps that copy, never drops it.
    rm -rf "$TMP/plib" "$STATE_DIR" && mkdir -p "$INSTALLER_COPY" "$PREVIOUS_DIR" "$STATE_DIR"
    echo pre >"$INSTALLER_COPY/install.sh"
    printf 'version=0.12.3\nbuild=0\ncommit=%s\n' "$(printf '%040d' 0)" >"$VERSION_FILE"
    printf 'version=0.12.3\nbuild=0\nsetup=release\nkept=settings programs setup\n' >"$UPDATE_MARK"
    update_check
    out=$( (programs_prebuilt && echo "CHANGE=$SETUP_CHANGE") 2>&1)
    has "the release's setup goes live after a failed swap" "$(cat "$INSTALLER_COPY/SOURCE")" "version=0.12.3"
    eq "and the copy the failed swap put back is kept" "$(cat "$SETUP_KEPT/install.sh" 2>/dev/null)" pre
}
in_sub t_update_pending
fi

echo "the menu's update and downgrade"
t_update_takes_setup() {
    programs_prebuilt() { echo "FROM_RELEASE=$SETUP_FROM_RELEASE"; }
    ui_yesno() { return 0; }
    UPDATE_AVAILABLE=1 FEED_VERSION=0.12.3 FEED_BUILD=0 DRY_RUN=1
    has "an update takes the release's setup" "$(DOWNGRADE=0 manage_update)" "FROM_RELEASE=1"
    has "a downgrade never does" "$(DOWNGRADE=1 manage_update)" "FROM_RELEASE=0"
}
in_sub t_update_takes_setup

echo "an update applies every setting again, or puts everything back"
t_update_orchestration() {
    local calls=$TMP/calls out
    ui_yesno() { return 0; }
    ui_msg() { echo "SCREEN $1: $2" >>"$calls"; }
    programs_prebuilt() { echo prebuilt >>"$calls"; SETUP_CHANGE=replaced; }
    restore_previous_programs() { echo programs-back >>"$calls"; }
    setup_copy_rollback() { echo setup-back >>"$calls"; }
    update_settings_restore() { echo settings-back >>"$calls"; }
    restart_relay_pair() { echo restart >>"$calls"; }
    wait_for_relay() { echo wait >>"$calls"; }
    update_done() { echo "done" >>"$calls"; }
    systemctl() { [ "$1" = reset-failed ] && echo "$*" >>"$calls"; return 0; }
    local_get() { :; }
    UPDATE_AVAILABLE=1 FEED_VERSION=0.12.3 FEED_BUILD=0 DRY_RUN=0 DOWNGRADE=0 FINISH_PENDING=0
    : >"$calls"
    update_after() { echo after >>"$calls"; return 0; }
    manage_update >/dev/null 2>&1
    eq "an update that applies its settings is done" "$(tr '\n' ' ' <"$calls")" "prebuilt after done "
    : >"$calls"
    update_after() { echo after >>"$calls"; return 1; }
    manage_update >/dev/null 2>&1
    has "one that cannot puts back the programs, the setup and the settings, then restarts" "$(tr '\n' ' ' <"$calls")" \
        "prebuilt after programs-back setup-back settings-back reset-failed hollow-relay hollow-forwarder restart wait done SCREEN Update undone"
    # a_rollback_restarts_the_relay_once_and_clears_a_start_limit: a refused
    # restart never stops the rollback before it says what happened.
    restart_relay_pair() { echo restart >>"$calls"; return 1; }
    : >"$calls"
    # install.sh runs with set -e, where a bare failed restart would end the run.
    (set -e; manage_update) >/dev/null 2>&1
    has "a refused restart still waits for the relay" "$(tr '\n' ' ' <"$calls")" "restart wait done SCREEN Update undone"
    # a_rollback_whose_relay_does_not_start_forgets_the_update
    wait_for_relay() { echo wait >>"$calls"; return 1; }
    : >"$calls"
    out=$( (manage_update) 2>&1)
    has "a previous version that does not start either still forgets the update" "$(tr '\n' ' ' <"$calls")" "restart wait done "
    has "and says so" "$out" "DIE the previous version does not start either"
    wait_for_relay() { echo wait >>"$calls"; }
    restart_relay_pair() { echo restart >>"$calls"; }
    : >"$calls"
    DRY_RUN=1
    manage_update >/dev/null 2>&1
    eq "a dry run stops before the last step" "$(tr '\n' ' ' <"$calls")" "prebuilt "
}
in_sub t_update_orchestration
# an_update_never_falls_back_to_a_build_from_source: it would run without the
# snapshot its rollback puts back.
t_update_no_source_fallback() {
    apt_install() { :; }
    prebuilt_available() { PREBUILT_WHY="this release has no prebuilt relay for linux-armv7l"; return 1; }
    programs_source() { echo SOURCE-BUILD; }
    DRY_RUN=0
    out=$(UPDATE_RUNNING=1 programs_prebuilt 2>&1)
    has "an update with no programs for this machine stops" "$out" "DIE the release list has no programs for this machine now"
    lacks "and builds nothing" "$out" SOURCE-BUILD
    has "a first install still builds them" "$(UPDATE_RUNNING=0 programs_prebuilt 2>&1)" SOURCE-BUILD
}
in_sub t_update_no_source_fallback
t_update_last_step() {
    # The last step runs the new copy, which applies everything with the new programs.
    INSTALLER_COPY=$TMP/ocopy
    mkdir -p "$INSTALLER_COPY" && printf 'echo "RAN $*"\n' >"$INSTALLER_COPY/install.sh"
    has "the last step is the new copy's own run" "$(update_after 2>&1)" "RAN --after-update"
    CONF_FILE=$TMP/oconf
    printf 'mode=native\nforwarder=yes\n' >"$CONF_FILE"
    has "which applies every setting with the programs marked changed" \
        "$(native_apply() { echo "APPLY changed=$PROGRAMS_CHANGED"; }; after_update_main 2>&1)" "APPLY changed=1"
    RESTART_UNITS=()
    PROGRAMS_CHANGED=1 CFG_FORWARDER=yes programs_changed_restarts
    eq "the new programs restart with the new units" "${RESTART_UNITS[*]}" "hollow-relay hollow-forwarder"
    RESTART_UNITS=()
    PROGRAMS_CHANGED=0 programs_changed_restarts
    eq "a settings change alone restarts nothing for them" "${RESTART_UNITS[*]:-}" ""
    printf 'mode=docker\n' >"$CONF_FILE"
    has "and is for the full setup only" "$(native_apply() { echo APPLY; }; (after_update_main) 2>&1)" "DIE an update's last step is for the full setup only"
}
in_sub t_update_last_step

# Run by hand, the last step refuses: it holds no update's lock.
out=$(cd "$TMP" && bash "$RELAY/install.sh" --after-update 2>&1); rc=$?
has "install.sh --after-update alone refuses" "$out" "is the last step of a menu update and runs only from one"
eq "and fails" "$rc" 1

echo "the settings an update keeps for its rollback"
t_update_settings() {
    local root=$TMP/snap log=$TMP/snap.log
    rm -rf "$root" && mkdir -p "$root/units" "$root/etc/hollow-relay" "$root/opt/hollow-push/node_modules/x" "$root/etc/hook"
    UNIT_DIR=$root/units STATE_DIR=$root/state UPDATE_SNAP=$root/state/update-snapshot
    UPDATE_SNAP_PATHS="$root/etc/hollow-relay $root/etc/hollow-turn $root/opt/hollow-push $root/etc/hook/hollow-relay.sh"
    mkdir -p "$STATE_DIR"
    echo old-conf >"$root/etc/hollow-relay/install.conf"
    chmod 0600 "$root/etc/hollow-relay/install.conf"
    echo old-index >"$root/opt/hollow-push/index.js"
    echo lib >"$root/opt/hollow-push/node_modules/x/a.js"
    echo old-hook >"$root/etc/hook/hollow-relay.sh"
    echo old-relay-unit >"$root/units/hollow-relay.service"
    echo old-coturn-unit >"$root/units/hollow-coturn.service"
    echo old-timer >"$root/units/hollow-duckdns.timer"
    mkfake "$TMP/snapbin" systemctl 'echo "systemctl $*" >>"'"$log"'"
case "$1 $2" in
"is-active --quiet") case "$3" in hollow-relay.service|hollow-duckdns.timer) exit 0 ;; *) exit 3 ;; esac ;;
"is-enabled --quiet") case "$3" in hollow-relay.service|hollow-coturn.service) exit 0 ;; *) exit 1 ;; esac ;;
esac
exit 0'
    PATH="$TMP/snapbin:$PATH"
    yes_ update_settings_keep
    eq "each unit's state is noted" "$(cat "$UPDATE_SNAP/units")" "$(printf 'hollow-coturn.service inactive enabled\nhollow-relay.service active enabled\nhollow-duckdns.timer active disabled')"
    has "a path that was absent is noted" "$(cat "$UPDATE_SNAP/absent")" "$root/etc/hollow-turn"
    # What a new setup's settings run may do.
    echo new-conf >"$root/etc/hollow-relay/install.conf"
    echo extra >"$root/etc/hollow-relay/new.json"
    rm -rf "$root/opt/hollow-push/node_modules"
    echo new-index >"$root/opt/hollow-push/index.js"
    mkdir -p "$root/etc/hollow-turn" && echo turn >"$root/etc/hollow-turn/turn.env"
    echo new-hook >"$root/etc/hook/hollow-relay.sh"
    echo new-relay-unit >"$root/units/hollow-relay.service"
    echo brand-new >"$root/units/hollow-newthing.service"
    : >"$log"
    yes_ update_settings_restore
    eq "the settings are back" "$(cat "$root/etc/hollow-relay/install.conf")" old-conf
    eq "with their modes" "$(stat -c %a "$root/etc/hollow-relay/install.conf")" 600
    no_ test -e "$root/etc/hollow-relay/new.json"
    eq "the push sender's files and packages are back" "$(cat "$root/opt/hollow-push/index.js") $(cat "$root/opt/hollow-push/node_modules/x/a.js")" "old-index lib"
    no_ test -e "$root/etc/hollow-turn"
    eq "the hook is back" "$(cat "$root/etc/hook/hollow-relay.sh")" old-hook
    eq "the units are back" "$(cat "$root/units/hollow-relay.service")" old-relay-unit
    no_ test -e "$root/units/hollow-newthing.service"
    local l
    l=$(cat "$log")
    has "a unit the update added is stopped" "$l" "systemctl disable --now hollow-newthing.service"
    has "a unit that ran runs again" "$l" "systemctl restart hollow-duckdns.timer"
    has "past any start limit the failed release left" "$l" "systemctl reset-failed hollow-duckdns.timer"
    lacks "the relay waits for the one restart update_rollback gives it" "$l" "restart hollow-relay.service"
    has "but starts on boot as it did" "$l" "systemctl enable --quiet hollow-relay.service"
    has "one that was stopped stays stopped" "$l" "systemctl stop hollow-coturn.service"
    has "one that started on boot still does" "$l" "systemctl enable --quiet hollow-coturn.service"
    has "systemd rereads them" "$l" "systemctl daemon-reload"
    ln -s /etc "$root/units/hollow-link.service"
    no_ update_settings_keep
    rm -f "$root/units/hollow-link.service"
    eq "the kept copies are root's alone" "$(stat -c %a "$UPDATE_SNAP")" 700
}
in_sub t_update_settings

echo "the push sender installs only from its lockfile"
# push_sender_installs_only_from_its_lockfile
t_push_lockfile() {
    local log=$TMP/npm.log out
    PUSH_SRC=$TMP/pushsrc
    PUSH_DIR=$TMP/opt-push PUSH_ETC=$TMP/etc-push UNIT_DIR=$TMP/push-units DRY_RUN=0 CFG_PUSH=yes PUSH_TOKEN_VALUE=t
    rm -rf "$PUSH_SRC" "$PUSH_DIR" && mkdir -p "$PUSH_SRC" "$UNIT_DIR"
    cp "$REPO/push-sidecar/"* "$PUSH_SRC/" 2>/dev/null
    push_source_dir() { printf '%s' "$PUSH_SRC"; }
    node_install() { :; }
    ensure_account() { :; }
    ensure_dir() { mkdir -p "$1"; }
    put_file() { mkdir -p "$(dirname "$1")"; cat >"$1"; PUT_CHANGED=1; }
    render_push_unit() { cat "$1"; }
    run_logged() { echo "$*" >>"$log"; }
    chown() { :; }
    : >"$log"
    out=$(push_apply 2>&1)
    has "npm installs exactly the lockfile's versions" "$(cat "$log")" "npm ci --omit=optional --omit=dev --ignore-scripts"
    lacks "and never resolves ranges" "$(cat "$log")" "npm install"
    yes_ test -f "$PUSH_DIR/package-lock.json"
    rm "$PUSH_SRC/package-lock.json" && : >"$log"
    out=$( (push_apply) 2>&1)
    has "without the lockfile nothing installs" "$out" "DIE the push sender's lockfile (push-sidecar/package-lock.json) is missing"
    eq "and npm never runs" "$(cat "$log")" ""
    yes_ test -f "$REPO/push-sidecar/package-lock.json"
    eq "the lockfile pins web-push as package.json does" "$(jq -r '.packages["node_modules/web-push"].version' "$REPO/push-sidecar/package-lock.json")" \
        "$(jq -r '.dependencies["web-push"]' "$REPO/push-sidecar/package.json")"
    has "the push sender's image installs from it too" "$(cat "$REPO/push-sidecar/Dockerfile")" "npm ci --omit=optional --omit=dev --ignore-scripts"
}
command -v jq >/dev/null && in_sub t_push_lockfile

echo "what the setup says about messages"
# The relay buffers messages for offline people in memory, encrypted; it never
# keeps, holds or stores them (wiki: relay storage wording).
wiz_text=$(cat "$RELAY/install.sh" "$DEPLOY"/lib/*.sh | grep -v '^\s*#')
lacks "no screen says the relay holds messages" "$wiz_text" "holds them for whoever"
if grep -inE '(keeps|stores|holds|saves) (the )?(encrypted )?messages' <<<"$wiz_text" >/dev/null; then
    bad "no screen says the relay keeps, stores, holds or saves messages: $(grep -inE '(keeps|stores|holds|saves) (the )?(encrypted )?messages' <<<"$wiz_text" | head -n 3)"
else ok; fi
mem_words='what (the |the old )?(relay|it) (holds|held|keeps|kept|stores|stored)|saved for its restart'
if grep -inE "$mem_words" <<<"$wiz_text" >/dev/null; then
    bad "what the relay has in memory is buffered, never held, kept, stored or saved: $(grep -inE "$mem_words" <<<"$wiz_text" | head -n 3)"
else ok; fi
has "the welcome screen says how it buffers them" "$(cat "$RELAY/install.sh")" "briefly buffers them, encrypted and in memory only, for whoever is offline"

echo "ssh ports"
t_ssh_ports() {
    local F=$TMP/fake_ports
    mkfake "$F" sshd '[ "$1" = -T ] && printf "port 22\nlistenaddress 0.0.0.0:2200\nlistenaddress [::]:2200\nport 99999\n"'
    mkfake "$F" systemctl 'case "$*" in *"Listen --value ssh.socket"*) echo "[::]:2222 (Stream)" ;; esac; exit 0'
    mkfake "$F" ss 'printf "LISTEN 0 128 0.0.0.0:2022 0.0.0.0:* users:((\"sshd\",pid=5,fd=3))\nLISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"nginx\",pid=6,fd=3))\n"'
    PATH="$F:$PATH"
    eq "sshd -T, ListenAddress, ssh.socket, ss and the session" \
        "$(SSH_CONNECTION="198.51.100.1 50000 192.0.2.5 2345" hollow_ssh_ports)" "22 2022 2200 2222 2345"
    lacks "another program's port stays shut" "$(SSH_CONNECTION="1 2 3 22" hollow_ssh_ports)" 8080
    # sudo drops SSH_CONNECTION; a parent process still has it.
    eq "the session port from a parent process" \
        "$(SSH_CONNECTION="198.51.100.1 50000 192.0.2.5 4567" bash -c 'env -u SSH_CONNECTION sh -c ". \"\$1\"; hollow_session_ssh_port" _ "$0"; true' "$DEPLOY/lib/host.sh")" 4567
    mkfake "$F" sshd 'exit 1'
    mkfake "$F" systemctl 'exit 0'
    mkfake "$F" ss 'exit 0'
    eq "nothing found means 22" "$(SSH_CONNECTION="1 2 3 22" hollow_ssh_ports)" 22
}
in_sub t_ssh_ports

t_ssh_refusal() {
    if SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2345" hollow_ssh_session_covered "$(printf '22/tcp\n443/tcp\n')" 2>"$TMP/why"; then
        bad "a session on a port the rules leave shut was let through"
    else
        has "the refusal says why" "$(cat "$TMP/why")" "port 2345"
    fi
    yes_ env SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2345" sh -c '. "$1"; hollow_ssh_session_covered "22/tcp 2345/tcp 443/tcp"' _ "$DEPLOY/lib/host.sh"
    # harden-host.sh refuses before any ufw command, even when the port list
    # comes out wrong.
    rm -rf "$TMP/hh"
    cp -R "$DEPLOY" "$TMP/hh"
    printf '\nhollow_ssh_ports() { echo 22; }\n' >>"$TMP/hh/lib/host.sh"
    local out rc=0
    out=$(SSH_CONNECTION="1.2.3.4 5 6.7.8.9 2345" sh "$TMP/hh/harden-host.sh" --print --no-ssh 2>&1) || rc=$?
    eq "harden-host refuses" "$rc" 3
    has "harden-host says why" "$out" "would not let that port in"
    lacks "and touches no ufw rule" "$out" "ufw default deny"
    out=$(SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" sh "$TMP/hh/harden-host.sh" --print --no-ssh 2>&1)
    has "a covered session goes on" "$out" "would run: ufw default deny incoming"
}
in_sub t_ssh_refusal

echo "coturn start"
t_coturn_start() {
    local F=$TMP/fake_turn out
    mkfake "$F" ip 'echo "Failed to drop capabilities" >&2; exit 1'
    mkfake "$F" hostname '[ "$1" = -I ] && echo "10.0.0.5 172.17.0.1 "'
    mkfake "$F" turnserver 'printf "%s\n" "$@"'
    mkdir -p "$TMP/rt"
    run_turn() { env -i PATH="$F:/usr/bin:/bin" TURN_SECRET=s RUNTIME_DIRECTORY="$TMP/rt" "$@" sh "$DEPLOY/coturn/coturn-start.sh" 2>&1; }
    out=$(run_turn PUBLIC_IP=203.0.113.7 LOCAL_IP=10.0.0.5)
    has "LOCAL_IP maps the public address" "$out" "--external-ip=203.0.113.7/10.0.0.5"
    has "and the private one is allowed back" "$out" "--allowed-peer-ip=10.0.0.5"
    out=$(run_turn PUBLIC_IP=203.0.113.7)
    lacks "without LOCAL_IP, ip(8) failing leaves no mapping" "$out" "--external-ip"
    out=$(run_turn PUBLIC_IP=203.0.113.7 LOCAL_IP=10.0.0.9)
    has "a LOCAL_IP this machine lost is named" "$out" "no longer an address of this machine"
    lacks "and never used" "$out" "--allowed-peer-ip=10.0.0.9"
    out=$(run_turn PUBLIC_IP=203.0.113.7 PUBLIC_IPV6=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff)
    has "a v6 range is refused" "$out" "takes one IPv6 address"
    lacks "before coturn starts" "$out" "--realm"
    out=$(run_turn PUBLIC_IP=0.0.0.0-255.255.255.255)
    has "a v4 range is refused" "$out" "take one IPv4 address"
    CFG_PUBLIC_IP=203.0.113.7 CFG_PUBLIC_IPV6="" PF_LOCAL_IP=10.0.0.5 TURN_SECRET_VALUE=x
    has "turn.env carries LOCAL_IP" "$(render_turn_env)" "LOCAL_IP=10.0.0.5"
}
in_sub t_coturn_start

# docker_coturn_reloads_a_renewed_pair: under Docker nothing may restart coturn,
# so coturn-start.sh stays its parent and has it reload a pair that changed.
echo "coturn certificate watch"
t_coturn_cert_watch() {
    local F=$TMP/fake_watch D=$TMP/watch w rc
    mkdir -p "$D/certs" "$D/rt"
    : >"$D/signals"
    mkfake "$F" hostname '[ "$1" = -I ] && echo "10.0.0.5 "'
    mkfake "$F" ip 'exit 1'
    # A coturn that notes each reload, ends on TERM, and ends by itself with 3
    # once told to.
    mkfake "$F" turnserver "echo \$\$ >\"$D/pid\"
trap 'echo reload >>\"$D/signals\"' USR2
trap 'echo term >>\"$D/signals\"; exit 0' TERM
while [ ! -e \"$D/die\" ]; do /bin/sleep 0.05; done
exit 3"
    # The watcher's wait between looks: it lasts until the test takes one.
    mkfake "$F" sleep "touch \"$D/asleep\"; i=0
while [ -e \"$D/asleep\" ] && [ \$i -lt 600 ]; do /bin/sleep 0.05; i=\$((i + 1)); done"
    asleep() { local i; for i in $(seq 1 200); do [ -e "$D/asleep" ] && return 0; /bin/sleep 0.05; done; return 1; }
    # tick: the watcher looks at the pair exactly once.
    tick() { asleep && rm -f "$D/asleep" && /bin/sleep 0.1 && asleep; }
    reloads() { /bin/sleep 0.3; grep -c reload "$D/signals"; }
    # put <name> <content>: lands the way install_pair lands a file, in one rename.
    put() { printf '%s\n' "$2" >"$D/certs/$1.pem.new" && mv "$D/certs/$1.pem.new" "$D/certs/$1.pem"; }
    # start [VAR=value...]: replaces the calling (sub)shell, so its pid is the script's.
    start() { exec env -i PATH="$F:/usr/bin:/bin" TURN_SECRET=s RUNTIME_DIRECTORY="$D/rt" CERT_DIR="$D/certs" \
        PUBLIC_IP=203.0.113.7 "$@" sh "$DEPLOY/coturn/coturn-start.sh" >"$D/out" 2>&1; }
    put fullchain A
    put privkey A

    touch "$D/die"
    start &
    w=$!
    wait "$w"
    eq "without CERT_WATCH_SECS the script becomes coturn itself" "$(cat "$D/pid")" "$w"
    rm -f "$D/die" "$D/pid"

    start CERT_WATCH_SECS=30 &
    w=$!
    tick && tick && tick
    eq "an unchanged pair never reloads coturn" "$(reloads)" 0
    rm "$D/certs/fullchain.pem"
    tick && tick
    eq "nor does a pair with a file missing" "$(reloads)" 0
    put fullchain A
    tick && tick
    eq "nor the same pair back" "$(reloads)" 0
    put privkey B
    tick
    eq "a new key beside the old chain is not a pair yet" "$(reloads)" 0
    put fullchain B
    tick
    eq "a new pair waits for a second look" "$(reloads)" 0
    tick
    eq "then coturn reloads it" "$(reloads)" 1
    tick && tick
    eq "once" "$(reloads)" 1
    put privkey C
    put fullchain C
    tick && tick
    eq "and each renewal after it" "$(reloads)" 2
    eq "coturn itself kept running" "$(kill -0 "$(cat "$D/pid")" 2>/dev/null && echo up)" up
    kill -TERM "$w"
    rc=0
    wait "$w" || rc=$?
    has "a stop reaches coturn" "$(cat "$D/signals")" term
    eq "and the script ends with it" "$rc" 0
    rm -f "$D/asleep"

    start CERT_WATCH_SECS=30 &
    w=$!
    asleep
    touch "$D/die"
    rc=0
    wait "$w" || rc=$?
    eq "coturn ending by itself ends the script with its status" "$rc" 3
    rm -f "$D/asleep" "$D/die"

    rc=0
    touch "$D/die"
    (start CERT_WATCH_SECS=1m) || rc=$?
    eq "a watch that is not a number of seconds is refused" "$rc" 1
    has "and named" "$(cat "$D/out")" "CERT_WATCH_SECS takes a number of seconds"
    has "the Docker coturn watches its pair" "$(cat "$RELAY/docker-compose.yml")" "- CERT_WATCH_SECS="
    lacks "the host unit leaves that to the certbot hook" "$(cat "$DEPLOY/hollow-coturn.service")" CERT_WATCH_SECS
}
in_sub t_coturn_cert_watch

echo "push resolver"
t_push_resolver() {
    RESOLV_CONF=$TMP/resolv.conf
    printf 'search lan\nnameserver 10.0.0.2\nnameserver 8.8.8.8\nnameserver 127.0.0.53\nnameserver fe80::1%%eth0\n' >"$RESOLV_CONF"
    local p
    p=$(render_push_unit "$REPO/push-sidecar/hollow-push.service")
    has "a private resolver is let through the wall" "$p" "IPAddressAllow=10.0.0.2/32 fe80::1/128"
    lacks "a public resolver needs nothing" "$(grep '^IPAddressAllow=' <<<"$p")" "8.8.8.8"
    has "after localhost" "$(grep -A1 '^IPAddressAllow=localhost' <<<"$p")" "IPAddressAllow=10.0.0.2/32"
    printf 'nameserver 127.0.0.53\n' >"$RESOLV_CONF"
    eq "systemd-resolved needs nothing" "$(render_push_unit "$REPO/push-sidecar/hollow-push.service" | grep -c '^IPAddressAllow=')" 1
    has "the push unit never swaps" "$(cat "$REPO/push-sidecar/hollow-push.service")" "MemorySwapMax=0"
}
in_sub t_push_resolver

echo "ssh summary"
t_ssh_truth() {
    local F=$TMP/fake_ssh2
    export DROPIN=$TMP/sshd.d/10-hollow-relay.conf
    mkdir -p "$TMP/sshd.d"
    mkfake "$F" sshd 'if [ "$1" = -T ]; then if [ -e "$DROPIN" ]; then printf "passwordauthentication no\nkbdinteractiveauthentication no\n"; else printf "passwordauthentication yes\n"; fi; fi; exit 0'
    mkfake "$F" systemctl 'exit 0'
    mkfake "$F" systemd-run 'exit 0'
    PATH="$F:$PATH"
    HOLLOW_SSHD_DROPIN=$DROPIN UI_MODE=answers SUDO_USER=alice DRY_RUN=0 RUN_START=0 SSH_PLAN=guide
    put_file() { cat >"$1"; PUT_CHANGED=1; }
    sleep() { :; }
    ssh_has_key() { return 0; }
    # The undo timer fires during the second login: the next round puts the
    # change back and asks again.
    n=0
    ssh_wait_login() { n=$((n + 1)); SSH_KEY_SEEN="key SHA256:mine from 192.0.2.4"; [ "$n" = 2 ] && rm -f "$DROPIN"; return 0; }
    rm -f "$DROPIN"
    ssh_run >/dev/null
    has "keys only once a second login sees the change" "$SSH_RESULT" "keys only"
    has "the summary names the confirmed key" "$SSH_RESULT" "key SHA256:mine from 192.0.2.4"
    yes_ test -e "$DROPIN"
    eq "it asked again" "$n" 3
    has "root logins go off for a sudo user" "$SSH_RESULT" "Root cannot log in"
    n=0
    ssh_wait_login() { n=$((n + 1)); [ "$n" -ge 2 ] && rm -f "$DROPIN"; return 0; }
    rm -f "$DROPIN"
    ssh_run >/dev/null
    lacks "never keys only while passwords are back" "$SSH_RESULT" "keys only"
    no_ test -e "$DROPIN"
    n=0
    ssh_wait_login() { n=$((n + 1)); [ "$n" = 1 ] && return 0; return 2; }
    rm -f "$DROPIN"
    ssh_run >/dev/null
    has "a second login past the deadline undoes it" "$SSH_RESULT" "within 10 minutes"
    no_ test -e "$DROPIN"
    # The answer-file wait stops before the timer would fire.
    unset -f ssh_wait_login sleep
    # shellcheck source=../../deploy/lib/ssh_keys.sh
    . "$DEPLOY/lib/ssh_keys.sh"
    ssh_logins() { :; }
    ANS=([ssh_wait_secs]=20 [ssh_key_fingerprint]=SHA256:x)
    sleep() { :; }
    local t0
    t0=$(date +%s)
    local rc=0
    ssh_wait_login alice 0 test $((t0 + 2)) >"$TMP/w.out" || rc=$?
    eq "the deadline wins over ssh_wait_secs" "$rc" 2
    lacks "and ssh_wait_secs never stretches it" "$(cat "$TMP/w.out")" "up to 20 seconds"
}
in_sub t_ssh_truth
lacks "MaxAuthTries left at sshd's default" "$(hollow_sshd_dropin alice)" "MaxAuthTries"

echo "build outputs"
t_build_outputs() {
    BUILD_USER=$(id -un)
    local B
    B=$(readlink -f "$TMP")/bld
    mkdir -p "$B/out" "$B/real" "$TMP/st"
    echo x >"$B/real/f"
    ln -s /etc/passwd "$B/out/link"
    ln -s "$B/real" "$B/linkdir"
    echo z >"$B/out/h1"
    ln "$B/out/h1" "$B/out/h2"
    yes_ plain_file "$B/real/f" "$BUILD_USER"
    no_ plain_file "$B/out/link" "$BUILD_USER"
    no_ plain_file "$B/linkdir/f" "$BUILD_USER"
    no_ plain_file "$B/out/h1" "$BUILD_USER"
    no_ plain_file "$B/out" "$BUILD_USER"
    [ "$(id -u)" = 0 ] || no_ plain_file "$B/real/f" root
    has "a linked output is refused" "$( (stage_build_output "$B/out/link" "$TMP/st") 2>&1)" "something other than a plain file"
    has "a hard-linked output is refused" "$( (stage_build_output "$B/out/h1" "$TMP/st") 2>&1)" "something other than a plain file"
    no_ test -e "$TMP/st/link"
}
in_sub t_build_outputs

echo "fail2ban"
out=$(sh "$DEPLOY/harden-host.sh" --print --no-ssh 2>&1)
has "the sshd jail reads the journal" "$out" "| backend = systemd"
has "the jail file" "$out" "would write: /etc/fail2ban/jail.d/hollow-relay.local"
has "the systemd backend's package" "$out" "python3-systemd"

echo "downloads on a fresh system"
# A stock Debian server has wget and python3 but no curl, and nothing may be
# installed before the plan screen.
t_net_get() {
    local F=$TMP/fake_net log=$TMP/net.log
    mkdir -p "$F"
    : >"$log"
    mkfake "$F" curl 'echo "curl $*" >>"'"$log"'"; cat >>"'"$log"'"; echo 203.0.113.7'
    mkfake "$F" wget 'echo "wget $*" >>"'"$log"'"; [ -t 0 ] || cat >>"'"$log"'"; echo 203.0.113.8'
    have() { case "$1" in curl) [ "${NO_CURL:-0}" = 0 ] ;; wget) [ "${NO_WGET:-0}" = 0 ] ;; python3) [ "${NO_PY:-0}" = 0 ] ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    PATH="$F:$PATH"
    eq "curl first" "$(net_tool)" curl
    eq "it fetches" "$(net_get -4 https://api.ipify.org 6 </dev/null)" 203.0.113.7
    has "over IPv4" "$(cat "$log")" "curl -q -fsS -4 --proto =https"
    NO_CURL=1
    eq "wget when there is no curl" "$(net_tool)" wget
    : >"$log"
    eq "wget fetches the same" "$(net_get -4 https://api.ipify.org 6 </dev/null)" 203.0.113.8
    has "over IPv4" "$(cat "$log")" "--inet4-only"
    has "with a header when asked" "$(net_get -H 'accept: application/dns-json' https://dns.google/resolve 8 </dev/null; cat "$log")" "--header=accept: application/dns-json"
    : >"$log"
    eq "the DuckDNS check works through wget" "$(duckdns_check_token myrelay a1b2c3d4-0000-1111-2222-333344445555)" 203.0.113.8
    lacks "and its token stays off wget's command line" "$(grep '^wget' "$log")" "a1b2c3d4-0000-1111-2222-333344445555"
    has "it reads the URL from stdin" "$(cat "$log")" "token=a1b2c3d4-0000-1111-2222-333344445555&txt=&clear=true"
    no_ net_get http://example.org/ 6
    # net_get_refuses_a_redirect_to_http_with_every_program: the box test
    # follows a real redirect; here each program is asked to refuse any.
    has "wget follows no redirect" "$(cat "$log")" "--max-redirect=0"
    NO_CURL=0 && : >"$log" && net_get -4 https://api.ipify.org 6 </dev/null >/dev/null
    has "nor does curl" "$(cat "$log")" "-L --max-redirs 0"
    NO_CURL=1
    has "nor python" "$(declare -f net_fetch)" 'raise urllib.error.HTTPError(req.full_url, code, "redirect refused"'
    mkfake "$F" wget 'exit 0'
    no_ net_get -4 https://api.ipify.org 6 </dev/null
    mkfake "$F" wget 'printf "\n"'
    eq "a body of only a newline is still a body" "$(net_get -4 https://api.ipify.org 6 </dev/null | od -An -c | tr -d ' ')" '\n'
    mkfake "$F" wget 'echo 203.0.113.8; exit 8'
    no_ net_get -4 https://api.ipify.org 6 </dev/null
    NO_CURL=0
    mkfake "$F" curl 'exit 0'
    no_ net_get -4 https://api.ipify.org 6 </dev/null
    mkfake "$F" curl 'exit 47'
    no_ net_get -4 https://api.ipify.org 6 </dev/null
    NO_CURL=1
    NO_WGET=1
    eq "python3 when there is neither" "$(net_tool)" python3
    NO_PY=1
    no_ net_tool
    net_get https://api.ipify.org 6 </dev/null
    eq "with none, net_get says so with 127" "$?" 127
    no_ net_get http://example.org/ 6
    # The machine check names the missing program, never a missing internet.
    local_ipv4() { echo 192.0.2.10; }
    public_ipv6() { return 1; }
    port_busy() { return 1; }
    clock_synced() { return 0; }
    preflight_run >/dev/null 2>&1 || true
    has "the machine check names the missing program" "$PF_HEAD" "none of curl, wget or python3"
    lacks "and does not blame the internet" "$PF_HEAD" "could not reach the internet"
}
in_sub t_net_get
# Before the plan, nothing downloads with curl directly: it is not on a stock Debian.
pre=$(cat "$DEPLOY/lib/preflight.sh" "$DEPLOY/lib/address.sh" "$DEPLOY/lib/questions.sh" | grep -v '^\s*#')
lacks "the machine check and the address checks never call curl" "$pre" "curl -"

echo "duckdns"
t_duckdns() {
    local F=$TMP/fake_dd
    export FAKE_CURL_CFG=$TMP/dd.cfg
    : >"$FAKE_CURL_CFG"
    mkfake "$F" curl 'cat >>"$FAKE_CURL_CFG"; echo OK'
    PATH="$F:$PATH"
    eq "the token check answers" "$(duckdns_check_token myrelay a1b2c3d4-0000-1111-2222-333344445555)" OK
    has "the check clears TXT" "$(cat "$FAKE_CURL_CFG")" "&txt=&clear=true"
    lacks "and leaves the address alone" "$(cat "$FAKE_CURL_CFG")" "&ip="
    : >"$FAKE_CURL_CFG"
    dns_points_at() { return 0; }
    ensure_account() { :; }
    ensure_dir() { :; }
    put_file() { cat >/dev/null; PUT_CHANGED=0; }
    put_unit() { cat >/dev/null; }
    run() { :; }
    CFG_HOST=myrelay.duckdns.org CFG_DUCKDNS_TOKEN=a1b2c3d4-0000-1111-2222-333344445555 CFG_DUCKDNS_IP="" CFG_PUBLIC_IP=203.0.113.7 DRY_RUN=0
    duckdns_setup >/dev/null
    has "the apply step points the name" "$(cat "$FAKE_CURL_CFG")" "update?domains=myrelay&token="
    has "at the address DuckDNS sees" "$(cat "$FAKE_CURL_CFG")" "&ip=\""
}
in_sub t_duckdns
lacks "the token question never moves the record" "$(sed -n '/^ask_duckdns()/,/^}/p' "$DEPLOY/lib/questions.sh")" "duckdns_update"

echo "docker re-run"
t_docker_rerun() {
    REPO=$TMP/no-sources DOCKER_DIR=$TMP/dk STACK_DIR=$TMP/dk/relay-uws CFG_FORWARDER=no DRY_RUN=0
    mkdir -p "$STACK_DIR"
    has "no stack and no sources stops" "$( (docker_copy_stack) 2>&1)" "no Docker setup in"
    : >"$STACK_DIR/docker-compose.yml"
    docker_copy_stack >/dev/null
    eq "the installed copy keeps the stack and builds nothing" "$DOCKER_REBUILD" 0
    CFG_FORWARDER=yes
    has "a new forwarder needs the sources" "$( (docker_copy_stack) 2>&1)" "Run install.sh from your copy"
}
in_sub t_docker_rerun

echo "compose"
out=$(python3 - "$RELAY/docker-compose.yml" <<'PY'
import re, sys
blocks, svc, inside = {}, None, False
for l in open(sys.argv[1]).read().split('\n'):
    if l.startswith('services:'):
        inside = True
        continue
    if inside and re.match(r'^\S', l):
        inside = False
    if inside:
        m = re.match(r'^  ([a-z0-9-]+):\s*$', l)
        if m:
            svc = m.group(1)
            blocks[svc] = []
        elif svc:
            blocks[svc].append(l)
bad = []
for s, b in blocks.items():
    t = '\n'.join(b)
    tag = re.search(r'^\s+tag: (\S+)', t, re.M)
    if 'driver: journald' not in t or not tag or not tag.group(1).startswith('hollow-'):
        bad.append(s + ':log')
    ml = re.search(r'mem_limit: (\S+)', t)
    ms = re.search(r'memswap_limit: (\S+)', t)
    if not ml or not ms or ml.group(1) != ms.group(1):
        bad.append(s + ':swap')
print(' '.join(bad) or 'ok', len(blocks))
PY
)
eq "every service logs as hollow-* to the journal and never swaps" "$out" "ok 7"

echo "rebuild from a clone"
t_rebuild() {
    VERSION_FILE=$TMP/V BUILT_FROM_FILE=$TMP/BF CFG_MODE=native
    echo source >"$BUILT_FROM_FILE"
    printf 'version=0.0.1\nbuild=0\n' >"$VERSION_FILE"
    yes_ source_differs
    update_check
    eq "an older build offers the rebuild" "$REBUILD_AVAILABLE" 1
    has "and says what this copy holds" "$UPDATE_TEXT" "so you can rebuild from it"
    if have git; then
        local G=$TMP/g
        mkdir -p "$G/relay-uws/src"
        cp "$RELAY/src/version.h" "$G/relay-uws/src/"
        : >"$G/relay-uws/src/main.cpp"
        git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@t -c user.name=t commit -qm t
        REPO=$G
        source_version_marker "$G" >"$VERSION_FILE"
        no_ source_differs
        update_check
        eq "the same commit offers nothing" "$REBUILD_AVAILABLE" 0
        if [ -r "$DEPLOY/lib/release_feed.sh" ]; then
            feed_lib_load
            yes_ hollow_feed_installed "$VERSION_FILE"
        fi
        printf 'x\n' >>"$G/relay-uws/src/main.cpp"
        git -C "$G" -c user.email=t@t -c user.name=t commit -qam t2
        yes_ source_differs
    fi
    REPO=$TMP/no-sources
    update_check
    has "the installed copy says where to rebuild from" "$UPDATE_TEXT" "run sudo bash relay-uws/install.sh from it"
}
in_sub t_rebuild

echo "downgrade copy"
t_downgrade() {
    yes_ version_older 0.12.2 0.12.10
    no_ version_older 0.12.10 0.12.2
    no_ version_older 0.12.2 0.12.2
    yes_ version_older 0.9.9 0.12.0
    installed_version() { echo 0.12.3; }
    ui_yesno() { printf '%s' "$3" >"$TMP/dg.txt"; return 1; }
    FEED_VERSION=0.12.2 FEED_BUILD=0
    manage_downgrade
    has "going back warns about the handoff" "$(cat "$TMP/dg.txt")" "may be lost"
    has "and names both versions" "$(cat "$TMP/dg.txt")" "older than the 0.12.3"
    lacks "nothing claims the messages carried across" "$(cat "$DEPLOY/lib/manage.sh")" "carry across.\""
    lacks "nor after an undone update" "$(cat "$DEPLOY/lib/manage.sh")" "carried across both restarts"
}
in_sub t_downgrade

echo "members-only keys"
t_member_keys() {
    member_list() { echo AAAA-BBBB-CCCC-DDDD; }
    UI_MODE=answers DRY_RUN=1
    out=$(member_keys_shown)
    lacks "an unattended run never prints a key" "$out" "AAAA-BBBB"
    has "it names the root-only file" "$out" "$MEMBER_KEYS_OUT"
    UI_MODE=plain
    has "a person at the screen sees them" "$(member_keys_shown)" "AAAA-BBBB-CCCC-DDDD"
}
in_sub t_member_keys

echo "console"
t_console() {
    local tty=/dev/tty1 port=""
    ui_tty_name() { echo "$tty"; }
    hollow_session_ssh_port() { echo "$port"; }
    unset SSH_TTY
    yes_ on_local_console
    tty=/dev/ttyS0
    yes_ on_local_console
    tty=/dev/hvc0
    yes_ on_local_console
    tty=/dev/pts/0
    no_ on_local_console
    # sudo's use_pty: the setup on a fresh pts, the person's shell on tty1.
    tty=$'/dev/pts/4\n/dev/pts/4\n/dev/tty1'
    yes_ on_local_console
    tty=/dev/tty1 port=22
    no_ on_local_console
    port=""
    SSH_TTY=/dev/pts/3 no_ on_local_console
    # The screen names the command and stops when asked.
    SUDO_USER=alice
    local_ipv4() { echo 192.168.18.8; }
    ui_menu() { printf '%s' "$3" >"$TMP/console.txt"; UI_REPLY=$CONSOLE_PICK; }
    UI_MODE=plain CONSOLE_PICK=ssh
    out=$( (console_notice; echo "went on") 2>&1)
    has "the console screen gives the SSH command" "$(cat "$TMP/console.txt")" "ssh alice@192.168.18.8"
    has "and says why" "$(cat "$TMP/console.txt")" "Pasting usually does not work"
    lacks "stopping stops" "$out" "went on"
    has "and says nothing changed" "$out" "Stopped. Nothing was changed."
    CONSOLE_PICK=here
    has "going on goes on" "$( (console_notice; echo "went on") 2>&1)" "went on"
    rm -f "$TMP/console.txt"
    UI_MODE=answers
    console_notice
    no_ test -e "$TMP/console.txt"
    tty=/dev/pts/0 UI_MODE=plain
    console_notice
    no_ test -e "$TMP/console.txt"
}
in_sub t_console

echo "token from a file"
t_token_file() {
    local tok=a1b2c3d4-0000-1111-2222-333344445555 f=$TMP/tok_file
    printf '%s\n' "$tok" >"$f"
    chmod 600 "$f"
    ui_secret_file "$f" 2>"$TMP/tf.err"
    eq "the token comes from the file" "$UI_REPLY" "$tok"
    eq "a root-only file draws no warning" "$UI_SECRET_FILE_OPEN" 0
    chmod 644 "$f"
    ui_secret_file "$f" 2>"$TMP/tf.err"
    eq "an open file is flagged" "$UI_SECRET_FILE_OPEN" 1
    has "and warned about" "$(cat "$TMP/tf.err")" "chmod 600 $f"
    lacks "the warning never shows the token" "$(cat "$TMP/tf.err")" "$tok"
    no_ ui_secret_file "$TMP/no-such-file"
    no_ ui_secret_file "$TMP"
    # An empty token answer brings up the file question.
    UI_MODE=plain
    ui_secret() { UI_REPLY=""; }
    PATHS=("$TMP/no-such-file" "$f")
    asked=0
    ui_input() { UI_REPLY=${PATHS[$asked]}; asked=$((asked + 1)); }
    ui_msg() { printf '%s\n' "$1" >>"$TMP/tf.msgs"; }
    : >"$TMP/tf.msgs"
    duckdns_token_prompt >"$TMP/tf.out" 2>&1
    eq "an empty paste falls back to the file" "$UI_REPLY" "$tok"
    eq "a wrong path asks again" "$asked" 2
    has "it said the path was wrong" "$(cat "$TMP/tf.msgs")" "No such file"
    has "and that the file is open" "$(cat "$TMP/tf.msgs")" "Anyone here can read that file"
    lacks "the token is never printed" "$(cat "$TMP/tf.out" "$TMP/tf.msgs")" "$tok"
    PATHS=("")
    asked=0
    duckdns_token_prompt >/dev/null 2>&1
    eq "an empty path goes back to the token screen" "$UI_REPLY" ""
    ui_secret() { UI_REPLY=pasted; }
    asked=0
    duckdns_token_prompt >/dev/null 2>&1
    eq "a pasted token needs no file" "$asked" 0
}
in_sub t_token_file

echo "terminal type"
t_term() {
    local F=$TMP/fake_term
    mkfake "$F" infocmp 'case "$1" in xterm|vt100) exit 0 ;; *) echo "infocmp: couldn'"'"'t open terminfo file for $1" >&2; exit 1 ;; esac'
    PATH="$F:$PATH"
    TERM=xterm-ghostty
    out=$(ui_fix_term 2>&1; echo "TERM=$TERM OK=$UI_TERM_OK")
    eq "an unknown terminal takes the nearest known one" "$out" "TERM=xterm OK=1"
    TERM=vt100
    ui_fix_term
    eq "a known terminal stays" "$TERM" vt100
    mkfake "$F" infocmp 'echo "'"'"'$1'"'"': unknown terminal type." >&2; exit 1'
    TERM=xterm-kitty
    out=$(ui_fix_term 2>&1; echo "OK=$UI_TERM_OK")
    eq "no known terminal at all means plain prompts, quietly" "$out" "OK=0"
}
in_sub t_term

echo "preflight screens"
t_preflight_text() {
    local F=$TMP/fake_pf
    mkfake "$F" tput 'case "$1" in cols) echo 80 ;; lines) echo 24 ;; esac'
    mkfake "$F" findmnt 'echo /dev/mapper/ubuntu--vg-ubuntu--lv'
    PATH="$F:$PATH"
    port_busy() { return 1; }
    clock_synced() { return 0; }
    mem_mb() { echo 1987; }
    disk_free_mb() { echo 9500; }
    # A home box behind NAT, as on Ubuntu Server's installer with its spare LVM space.
    mkfake "$F" vgs 'echo "  10240.00m"'
    disk_free_mb() { echo 6000; }
    public_ipv4() { echo 203.0.113.7; }
    public_ipv6() { return 1; }
    local_ipv4() { echo 192.168.18.8; }
    preflight_run
    eq "a home box needs a step" "$PF_VERDICT" steps
    has "the first screen says what to forward" "$PF_HEAD" "forward those ports on your router"
    lacks "and leaves the findings to the second" "$PF_HEAD" "Disk:"
    has "the second has them" "$PF_FOUND" "Disk:"
    ui_size "$PF_HEAD" 7
    eq "its steps fit 80x24 in a box" "$UI_FITS" 1
    ui_size "$PF_FOUND

Go on with the setup?" 8
    eq "what it found fits 80x24 with the question" "$UI_FITS" 1
    has "the LVM hint is there" "$PF_FOUND" "lvextend"
    eq "a blank line before What I found" "$(grep -B1 '^What I found:' <<<"$PF_TEXT" | head -n 1)" ""
    # A plain VPS with its own public addresses and port 80 taken.
    mkfake "$F" vgs 'exit 5'
    disk_free_mb() { echo 20000; }
    local_ipv4() { echo 203.0.113.7; }
    public_ipv6() { echo 2001:db8::7; }
    port_busy() { [ "$1" = 80 ]; }
    port_owner() { echo nginx; }
    preflight_run
    eq "a VPS needs nothing" "$PF_VERDICT" ok
    ui_size "$PF_TEXT" 7
    eq "its one screen fits 80x24 in a box" "$UI_FITS" 1
    # Carrier-grade NAT stops it, in a box too.
    local_ipv4() { echo 100.64.3.4; }
    preflight_run
    eq "CGNAT cannot host" "$PF_VERDICT" no
    ui_size "$PF_HEAD" 7
    eq "the CGNAT screen fits 80x24" "$UI_FITS" 1
}
in_sub t_preflight_text

echo "a wrong answer is asked again"
# feed <line...>: what a person types at the plain prompts, in order.
feed() {
    exec 3< <(printf '%s\n' "$@")
    UI_TTY=/dev/fd/3
}
t_reask() {
    UI_MODE=plain DRY_RUN=1
    feed 700 120
    ask_grace >"$TMP/q.out" 2>&1
    eq "grace: the good answer counts" "$CFG_GRACE_SECS" 120
    has "grace: the bad one is named on the screen" "$(cat "$TMP/q.out")" "700 does not work here. Type a whole number of seconds from 30 to 600."
    feed y 0 7
    ask_members >"$TMP/q.out" 2>&1
    eq "key count" "$CFG_MEMBER_KEYS" 7
    has "key count: asked again" "$(cat "$TMP/q.out")" "0 does not work here. Type a whole number from 1 to 200."
    feed "my relay" hollowtest.duckdns.org
    ask_valid duckdns_name t x "" is_duckdns_name "w" >/dev/null 2>&1
    eq "duckdns name" "$(duckdns_name_norm "$UI_REPLY")" hollowtest
    PF_BEHIND_NAT=0 PF_PUBLIC_IP=203.0.113.7 PF_PUBLIC_IPV6="" CFG_HOST=""
    feed 3 relay.example.com:8443 Relay.Example.com
    ask_address >"$TMP/q.out" 2>&1
    eq "domain" "$CFG_HOST" relay.example.com
    has "domain: asked again" "$(cat "$TMP/q.out")" "relay.example.com:8443 does not work here"
    feed 2 192.168.1.20 198.51.100.4
    ask_address >"$TMP/q.out" 2>&1
    eq "bare IP" "$CFG_HOST" 198.51.100.4
    has "bare IP: a private one is refused" "$(cat "$TMP/q.out")" "192.168.1.20 does not work here"
    PF_BEHIND_NAT=1 PF_PUBLIC_IP=203.0.113.7 PF_PUBLIC_IPV6=""
    feed 192.168.1.300 192.168.1.30
    ask_public_ip >"$TMP/q.out" 2>&1
    eq "public_ip" "$CFG_PUBLIC_IP" 192.168.1.30
    has "public_ip: asked again" "$(cat "$TMP/q.out")" "192.168.1.300 does not work here"
    # The token: a bad one, then a good one; a token is never filled back in.
    PF_BEHIND_NAT=0
    feed 1 myrelay not-a-token a1b2c3d4-0000-1111-2222-333344445555
    ask_address >"$TMP/q.out" 2>&1
    eq "token" "$CFG_DUCKDNS_TOKEN" a1b2c3d4-0000-1111-2222-333344445555
    has "token: what was wrong shows on the token screen" "$(cat "$TMP/q.out")" "That was not a DuckDNS token."
    lacks "token: the bad one is never shown" "$(cat "$TMP/q.out")" "not-a-token"
    # An answer file still stops on a bad value.
    UI_MODE=answers
    ANS=([grace_secs]=700)
    has "an answer file stops" "$( (ask_grace) 2>&1)" "DIE the answer file gives grace_secs=700"
    # DNS that does not point here yet: check again instead of ending the run.
    UI_MODE=plain CFG_ADDRESS=domain CFG_MODE=docker CFG_HOST=relay.example.com DRY_RUN=0
    n=0
    dns_points_at() { n=$((n + 1)); DNS_SEEN=192.0.2.9; [ "$n" -ge 2 ]; }
    feed 1
    address_prepare >"$TMP/q.out" 2>&1
    eq "the DNS check runs again" "$n" 2
    has "and says what it saw" "$(cat "$TMP/q.out")" "points at 192.0.2.9"
    # A terminal that closes ends the run instead of asking forever.
    feed 700
    has "a closed terminal stops" "$( (ask_grace) 2>&1)" "DIE the terminal closed before an answer came"
}
in_sub t_reask

echo "answers from last time"
t_draft() {
    DRAFT_FILE=$TMP/answers.draft DRY_RUN=0 UI_MODE=plain
    rm -f "$DRAFT_FILE"
    id() { if [ "$1" = -u ]; then echo 0; else command id "$@"; fi; }
    draft_offer
    eq "a first run with no draft starts keeping answers" "$DRAFT_ON" 1
    feed 300
    ask_grace >/dev/null 2>&1
    feed "" myrelay a1b2c3d4-0000-1111-2222-333344445555
    CFG_DUCKDNS_NAME="" DRY_RUN=1
    ask_duckdns >/dev/null 2>&1
    DRY_RUN=0
    ui_remember confirm yes
    ui_remember continue_anyway yes
    has "the draft keeps the wait" "$(cat "$DRAFT_FILE")" "grace_secs=300"
    lacks "but not the plan's yes" "$(cat "$DRAFT_FILE")" "confirm="
    lacks "nor any other key it was not told to keep" "$(cat "$DRAFT_FILE")" "continue_anyway="
    has "and the DuckDNS name" "$(cat "$DRAFT_FILE")" "duckdns_name=myrelay"
    lacks "never the token" "$(cat "$DRAFT_FILE")" "a1b2c3d4"
    eq "root only" "$(stat -c %a "$DRAFT_FILE")" 600
    # The next run: yes fills the screens, and Enter keeps each answer.
    DRAFT_ON=0 DRAFT=() DRAFT_NOW=() CFG_GRACE_SECS=120
    feed y ""
    draft_offer >/dev/null 2>&1
    ask_grace >/dev/null 2>&1
    eq "Enter keeps last time's answer" "$CFG_GRACE_SECS" 300
    # No: the draft goes, and the screens show the usual choices.
    DRAFT_ON=0 DRAFT=() DRAFT_NOW=() CFG_GRACE_SECS=120
    feed n ""
    draft_offer >/dev/null 2>&1
    no_ test -e "$DRAFT_FILE"
    ask_grace >/dev/null 2>&1
    eq "without it the default stands" "$CFG_GRACE_SECS" 120
    # An unattended or dry run keeps nothing.
    rm -f "$DRAFT_FILE"
    DRAFT_ON=0 UI_MODE=answers
    draft_offer
    eq "answer files keep no draft" "$DRAFT_ON" 0
    DRAFT_ON=0 UI_MODE=plain DRY_RUN=1
    draft_offer
    eq "dry runs keep no draft" "$DRAFT_ON" 0
}
in_sub t_draft
has "a finished install drops the draft" "$(sed -n '/^apply_all$/,/^summary_screen$/p' "$RELAY/install.sh")" "draft_clear"
lacks "a draft key is never a secret" "$(sed -n 's/^DRAFT_KEYS=//p' "$DEPLOY/lib/ui.sh")" "token"

echo "apt locks"
t_apt_locks() {
    command -v python3 >/dev/null || return 0
    local L=$TMP/lists.lock F=$TMP/fake_apt holder
    : >"$L"
    HOLLOW_APT_LOCKS="$TMP/missing.lock $L" HOLLOW_APT_POLL=1
    eq "a free lock holds nothing up" "$(hollow_apt_holder)" ""
    # An fcntl lock like apt's, held for a few seconds.
    python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(float(sys.argv[2]))' "$L" 4 &
    holder=$!
    sleep 1
    eq "the holder is found" "$(hollow_apt_holder)" "$holder"
    hollow_apt_wait >"$TMP/aw.out" 2>&1
    eq "the wait ends when the lock is free" "$?" 0
    has "and says what it waits for" "$(cat "$TMP/aw.out")" "Waiting for the system's automatic updates to finish"
    wait "$holder" 2>/dev/null
    python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(float(sys.argv[2]))' "$L" 6 &
    holder=$!
    sleep 1
    local rc=0
    HOLLOW_APT_WAIT_SECS=2 hollow_apt_wait >/dev/null 2>"$TMP/aw.err" || rc=$?
    eq "it gives up in the end" "$rc" 1
    has "and says why, plainly" "$(cat "$TMP/aw.err")" "still hold the package lock"
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    # A lock lost to an update starting at that moment is tried again.
    export FAKE_APT_N=$TMP/apt.n
    echo 0 >"$FAKE_APT_N"
    mkfake "$F" apt-get 'n=$(($(cat "$FAKE_APT_N") + 1)); echo "$n" >"$FAKE_APT_N"; case "$*" in *"DPkg::Lock::Timeout=600"*) ;; *) exit 3 ;; esac; [ "$n" -ge 2 ] || { echo "E: Could not get lock /var/lib/apt/lists/lock" >&2; exit 100; }; exit 0'
    PATH="$F:$PATH"
    yes_ hollow_apt update -q
    eq "after one lock miss" "$(cat "$FAKE_APT_N")" 2
    mkfake "$F" apt-get 'exit 1'
    no_ hollow_apt update -q
}
in_sub t_apt_locks
lacks "every apt-get goes through the lock wait" "$(grep -n 'apt-get' "$DEPLOY"/lib/common.sh "$DEPLOY"/lib/native.sh "$DEPLOY"/lib/docker.sh "$DEPLOY"/harden-host.sh | grep -v '^[^:]*:[0-9]*: *#')" "apt-get"
lacks "systemctl enable stays quiet" "$(grep -hE 'run systemctl (enable|mask)' "$DEPLOY"/lib/*.sh | grep -v -- '--quiet')" "systemctl"

echo "reinstall restores"
t_restore_wiring() {
    ensure_account() { :; }
    ensure_dir() { :; }
    put_file() { cat >/dev/null; PUT_CHANGED=0; }
    put_unit() { cat >/dev/null; }
    restore_state() { echo "$*" >>"$TMP/rs.calls"; return 1; }
    : >"$TMP/rs.calls"
    CFG_TURN=no CFG_PUSH=no CFG_MEMBERS_ONLY=no CFG_FORWARDER=yes CFG_MEMBER_KEYS=0 DRY_RUN=1
    RELAY_ETC=$TMP/re TURN_ETC=$TMP/te PUSH_ETC=$TMP/pe FWD_ETC=$TMP/fe REMOVE_KEY=""
    relay_settings >/dev/null 2>&1
    forwarder_apply >/dev/null 2>&1
    eq "the report counts come back, without a key" "$(grep hollow-relay "$TMP/rs.calls")" "/var/lib/hollow-relay hollow-relay reports.json"
    has "and the forwarder's identity" "$(cat "$TMP/rs.calls")" "/var/lib/hollow-forwarder hollow-fwd forwarder.key forwarder.db"
}
in_sub t_restore_wiring

echo "progress"
t_progress() {
    DRY_RUN=0 UI_MODE=plain WORK_DIR=$TMP
    run_logged sh -c 'echo "Saving debug log to /var/log/letsencrypt"; sleep 1' >"$TMP/prog.out" 2>&1
    lacks "a step's own output stays off the screen" "$(cat "$TMP/prog.out")" "Saving debug log"
    if LC_ALL=C grep -q "$(printf '[\r\033]')" "$TMP/prog.out"; then bad "output that is not a terminal holds control characters"; else ok; fi
    has "it lands in the run log" "$(cat "$TMP/run.log")" "Saving debug log"
    run_logged sh -c 'echo "the reason it failed"; exit 4' >"$TMP/prog.out" 2>&1
    has "a failed step shows its last lines" "$(cat "$TMP/prog.out")" "the reason it failed"
    # certbot's banner and debug-log lines stay off the screen too.
    certbot_install() { :; }
    ensure_dir() { :; }
    run() { :; }
    INSTALLER_COPY=$TMP/ic CFG_HOST=relay.example.org CFG_EMAIL="" CFG_STAGING=no
    mkdir -p "$INSTALLER_COPY/deploy/certbot"
    printf 'echo "If you like Certbot, please consider supporting our work"\necho "Saving debug log to /var/log/letsencrypt/letsencrypt.log"\n' \
        >"$INSTALLER_COPY/deploy/certbot/issue.sh"
    cert_issue >"$TMP/prog.out" 2>&1
    lacks "certbot's banner stays off the screen" "$(cat "$TMP/prog.out")" "consider supporting"
    if command -v script >/dev/null; then
        script -qec "bash -c '. \"$DEPLOY/lib/common.sh\"; WORK_DIR=$TMP; run_logged sleep 1'" "$TMP/tty.out" >/dev/null 2>&1 </dev/null
        has "on a terminal a spinner shows the time" "$(tr '\r' '\n' <"$TMP/tty.out")" "0:00"
    fi
}
in_sub t_progress
eq "the console screen comes before the machine check" "$(grep -nE '^(console_notice|preflight_run)$' "$RELAY/install.sh" | cut -d: -f2 | tr '\n' ' ')" "console_notice preflight_run "
has "the welcome screen says how long it takes" "$(cat "$RELAY/install.sh")" "about 5 to 10 minutes on a new server"

# load_fn <file> <function...>: defines those functions from a script that
# cannot be sourced, like install.sh, which runs as soon as it is read.
load_fn() {
    local f=$1 fn
    shift
    for fn in "$@"; do
        eval "$(awk -v n="$fn() {" '$0 == n {on = 1} on {print} on && $0 == "}" {exit}' "$f")"
    done
}

# fits <name> <text> <extra rows>: the screen fits a standard 80x24 terminal.
FIT=$TMP/fake_fit
mkfake "$FIT" tput 'case "$1" in cols) echo 80 ;; lines) echo 24 ;; esac'
fits() {
    local saved=$PATH
    PATH="$FIT:$PATH"
    ui_size "$2" "${3:-7}"
    PATH=$saved
    eq "$1 fits 80x24 in a box" "$UI_FITS" 1
}

echo "no email for Let's Encrypt"
# Let's Encrypt keeps no account email any more, so the setup neither asks for
# nor stores one, and an older answer file or install.conf that has one still works.
t_email() {
    UI_MODE=plain
    : >"$TMP/em.asked"
    ui_input() { printf 'ASKED %s\n' "$1" >>"$TMP/em.asked"; UI_REPLY=""; }
    cert_answers
    eq "a first install asks for no email" "$(cat "$TMP/em.asked")" ""
    printf 'email=ops@example.org\nstaging=no\n' >"$TMP/em.answers"
    has "an answer file with an email still loads" "$(ui_load_answers "$TMP/em.answers" 2>&1; echo "rc=$?")" "rc=0"
    UI_MODE=answers
    ANS=([email]=not-an-email)
    eq "and its email is ignored, whatever it holds" "$(cert_answers 2>&1; echo "rc=$?")" "rc=0"
    printf 'mode=native\nemail=old@example.org\nstaging=no\nturn=yes\n' >"$TMP/em.conf.old"
    CONF_FILE=$TMP/em.conf.old DDNS_ETC=$TMP/em.none
    conf_load
    put_file() { cat >"$TMP/em.conf.new"; }
    ensure_dir() { :; }
    conf_save
    has "an old install.conf with an email loads" "$(cat "$TMP/em.conf.new")" "turn=yes"
    lacks "and the next one keeps no email" "$(cat "$TMP/em.conf.new")" "email"
    lacks "install.sh asks no email" "$(sed -n '/^# -* main/,$p' "$RELAY/install.sh")" "ask_email"
    lacks "nothing hands certbot an email" "$(grep -rn 'EMAIL' "$RELAY/install.sh" "$DEPLOY/lib" "$DEPLOY/certbot")" "EMAIL"
}
in_sub t_email

echo "the change menu has no email"
t_email_change() {
    UI_MODE=plain DRY_RUN=0 CFG_MODE=native CFG_STAGING=no CFG_MEMBERS_ONLY=no
    CFG_TURN=yes CFG_PUSH=yes CFG_FORWARDER=yes CFG_GRACE_SECS=120 CFG_HOST=relay.example.org
    ui_menu() { printf '%s\n' "$@" >"$TMP/ch.items"; UI_REPLY=turn; }
    ask_turn() { :; }
    ssh_firewall_guard() { :; }
    apply_all() { :; }
    summary_screen() { :; }
    manage_change >/dev/null
    has "the change menu is shown" "$(cat "$TMP/ch.items")" "TURN for calls: yes"
    lacks "without an email in it" "$(cat "$TMP/ch.items")" "mail"
}
in_sub t_email_change

echo "ssh key steps"
t_key_steps() {
    CFG_HOST="a-rather-long-relay-name.duckdns.org"
    local steps
    steps=$(ssh_key_steps_text alice)
    key_steps_check "the login steps" "$steps"
    has "the last step copies the key" "$steps" "ssh-copy-id alice@a-rather-long-relay-name.duckdns.org"
    steps=$(ssh_print_key_text)
    key_steps_check "the paste steps" "$steps"
    has "the last step prints the key" "$steps" "cat ~/.ssh/id_ed25519.pub"
    plain_fits "the paste steps" "Add another computer's key" "$steps"
    plain_fits "the login steps" "Make a key on your computer" "$(ssh_key_steps_text alice)"
    plain_fits "the second computer's login steps" "Add another computer's key" \
        "$(ssh_key_steps_text alice | sed '1s/.*/Do this on the new computer that should log in too. Not on this machine./')"
}
# plain_fits <label> <title> <text>: the plain screen, wrapped at 80 columns,
# plus its Enter prompt, fits 24 rows.
plain_fits() {
    local rows
    rows=$(plain_header "$2" "$3" | awk '{ n += (length($0) > 80) ? int((length($0) + 79) / 80) : 1 } END { print n + 1 }')
    if [ "$rows" -le 24 ]; then ok; else bad "$1 fits 80x24 as plain text: $rows rows"; fi
}
# key_steps_check <label> <text>: every system looks for a key before making
# one, an existing key is never replaced, and nothing tells anyone to say y.
key_steps_check() {
    local os look
    for os in "Windows (PowerShell):" "macOS or Linux (Terminal):"; do
        look=$(printf '%s\n' "$2" | sed -n "/^$os\$/,/^\$/p" | sed -n '2,3p' | tr -d ' ')
        case "$os" in
        Windows*) eq "$1, $os looks first" "$look" "$(printf 'dir$env:USERPROFILE\\.ssh\\id_ed25519.pub\nssh-keygen-ted25519')" ;;
        *) eq "$1, $os looks first" "$look" "$(printf 'ls~/.ssh/id_ed25519.pub\nssh-keygen-ted25519')" ;;
        esac
    done
    has "$1: a key that is there is kept" "$2" "If the first command lists the file, you have a key already, so skip ssh-keygen."
    has "$1: an existing key, answer n" "$2" "If it says the key already exists, answer n."
    has "$1: and why" "$2" "Answering y would replace your key."
    has "$1: how to make one" "$2" "press Enter when ssh-keygen asks where to save it"
    lacks "$1: never answer y" "$2" "answer y"
    lacks "$1: never overwrite it" "$2" "ssh-keygen -t ed25519 -f"
    lacks "$1: nor with yes piped in" "$2" "| ssh-keygen"
}
in_sub t_key_steps

echo "the setup's own key login"
SJ=$TMP/fake_sj
mkdir -p "$SJ"
# Like journalctl -o short-unix with --since @<time> and one _PID= match.
cat >"$SJ/journalctl" <<'EOF'
#!/bin/sh
since=0 pid=""
while [ $# -gt 0 ]; do
    case "$1" in --since) since=${2#@}; shift ;; _PID=*) pid=${1#_PID=} ;; esac
    shift
done
awk -v s="$since" -v p="$pid" 'int($1) >= s && (p == "" || index($3, "[" p "]:") > 0)' "$FAKE_SJ"
EOF
chmod +x "$SJ/journalctl"
export FAKE_SJ=$TMP/sj
# sjline <unix time> <pid> <message>
sjline() { printf '%s.000001 box sshd[%s]: %s\n' "$1" "$2" "$3" >>"$FAKE_SJ"; }
t_session_key() {
    PATH="$SJ:$PATH"
    SESSION_CONN="192.0.2.4 50123"
    SESSION_PIDS="4242 1000"
    ssh_session_conn() { [ -z "$SESSION_CONN" ] || echo "$SESSION_CONN"; }
    ssh_session_pids() { [ -z "$SESSION_PIDS" ] || echo "$SESSION_PIDS"; }
    : >"$FAKE_SJ"
    sjline 1003 777 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:otherpid"
    sjline 1005 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:mine"
    ssh_session_key alice
    eq "this session's key login is found" "$SSH_SESSION_KEY" "1005 192.0.2.4 SHA256:mine"
    eq "and the check is marked done" "$SSH_SESSION_CHECKED" 1
    ssh_session_key bob
    eq "never for another account" "$SSH_SESSION_KEY" ""
    SESSION_CONN="192.0.2.4 50999"
    ssh_session_key alice
    eq "never from another port" "$SSH_SESSION_KEY" ""
    SESSION_CONN="192.0.2.5 50123"
    ssh_session_key alice
    eq "never from another address" "$SSH_SESSION_KEY" ""
    SESSION_CONN="192.0.2.4 50123"
    SESSION_PIDS="5555 1000"
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:mine"
    ssh_session_key alice
    eq "never from an sshd that is not a parent" "$SSH_SESSION_KEY" ""
    SESSION_PIDS="4242 1000"
    : >"$FAKE_SJ"
    sjline 990 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:old"
    ssh_session_key alice
    eq "never a line from before that sshd started" "$SSH_SESSION_KEY" ""
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted password for alice from 192.0.2.4 port 50123 ssh2"
    ssh_session_key alice
    eq "never a password login" "$SSH_SESSION_KEY" ""
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:first"
    sjline 1006 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:mine"
    ssh_session_key alice
    eq "never when two logins could be it" "$SSH_SESSION_KEY" ""
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted hostbased for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:hostkey"
    ssh_session_key alice
    eq "never a host's key" "$SSH_SESSION_KEY" ""
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2"
    ssh_session_key alice
    eq "never a key it cannot name" "$SSH_SESSION_KEY" ""
    # Also when journalctl hands over more than asked, as its --since rounds.
    : >"$FAKE_SJ"
    sjline 990 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:old"
    mkdir -p "$TMP/sjloose"
    sed 's/int(\$1) >= s \&\& //' "$SJ/journalctl" >"$TMP/sjloose/journalctl"
    chmod +x "$TMP/sjloose/journalctl"
    PATH="$TMP/sjloose:$PATH" ssh_session_key alice
    eq "the reader drops what came before that sshd itself" "$SSH_SESSION_KEY" ""
    # install.sh runs under set -e: a journal that cannot be read ends nothing.
    mkdir -p "$TMP/sjfail"
    printf '#!/bin/sh\nexit 1\n' >"$TMP/sjfail/journalctl"
    chmod +x "$TMP/sjfail/journalctl"
    has "an unreadable journal is no match, under set -e too" "$(PATH="$TMP/sjfail:$PATH"; set -e; ssh_session_key alice; echo "went on [$SSH_SESSION_KEY]")" "went on []"
    : >"$FAKE_SJ"
    sjline 1005 4242 "Accepted publickey for alice from 192.0.2.4 port 50123 ssh2: ED25519 SHA256:mine"
    SESSION_CONN=""
    ssh_session_key alice
    eq "never on a console" "$SSH_SESSION_KEY" ""
    SESSION_CONN="192.0.2.4 50123" SESSION_PIDS=""
    ssh_session_key alice
    eq "never without an sshd parent" "$SSH_SESSION_KEY" ""
    # This process's own start time, read from /proc.
    local st now
    st=$(ssh_proc_started $$) || st=0
    now=$(date +%s)
    if [ "$st" -le "$now" ] && [ "$st" -ge $((now - 3600)) ]; then ok; else bad "a process start time came out as [$st], now is $now"; fi
}
in_sub t_session_key

echo "the setup's own key login is read before the hardening"
t_session_early() {
    ssh_passwords_on() { return 0; }
    ssh_session_key() { SSH_SESSION_CHECKED=1; SSH_SESSION_KEY="1005 192.0.2.4 SHA256:mine"; }
    ui_yesno() { printf '%s' "$3" >"$TMP/se.text"; return 0; }
    SUDO_USER=alice SSH_SESSION_CHECKED=0
    ssh_question
    eq "the switch's question reads it" "$SSH_SESSION_CHECKED" 1
    has "and says it will ask" "$(cat "$TMP/se.text")" "You logged in to this setup with an SSH key."
}
in_sub t_session_early

echo "the setup's own key login counts once confirmed"
t_session_offer() {
    local F=$TMP/fake_so
    export DROPIN=$TMP/so.d/10-hollow-relay.conf
    mkdir -p "$TMP/so.d"
    mkfake "$F" sshd 'if [ "$1" = -T ]; then if [ -e "$DROPIN" ]; then printf "passwordauthentication no\nkbdinteractiveauthentication no\n"; else printf "passwordauthentication yes\n"; fi; fi; exit 0'
    mkfake "$F" systemctl 'exit 0'
    mkfake "$F" systemd-run 'exit 0'
    PATH="$F:$PATH"
    HOLLOW_SSHD_DROPIN=$DROPIN UI_MODE=plain SUDO_USER=alice DRY_RUN=0 RUN_START=0 SSH_PLAN=guide
    put_file() { cat >"$1"; PUT_CHANGED=1; }
    sleep() { :; }
    ssh_has_key() { return 1; }
    ui_msg() { printf 'MSG %s\n' "$1" >>"$TMP/so.screens"; }
    ui_yesno() { printf 'ASK %s %s\n' "$1" "$4" >>"$TMP/so.screens"; printf '%s\n' "$3" >>"$TMP/so.text"; [ "$OWN_SAY" = yes ]; }
    ssh_wait_login() { printf 'WAIT %s\n' "$3" >>"$TMP/so.screens"; SSH_KEY_SEEN="key SHA256:mine from 192.0.2.4"; return 0; }
    # Yes: no steps and no first window, but the second login still guards.
    SSH_SESSION_KEY="1005 192.0.2.4 SHA256:mine" SSH_SESSION_CHECKED=1 OWN_SAY=yes
    : >"$TMP/so.screens"
    rm -f "$DROPIN"
    ssh_run >/dev/null
    has "the question names the key, address and time" "$(cat "$TMP/so.text")" "You logged in to this setup with the key SHA256:mine from 192.0.2.4 at"
    has "and defaults to no" "$(cat "$TMP/so.screens")" "ASK ssh_own no"
    lacks "yes skips making a key" "$(cat "$TMP/so.screens")" "MSG Make a key"
    lacks "and the first window" "$(cat "$TMP/so.screens")" "WAIT before the change"
    has "the second login after the change is still asked" "$(cat "$TMP/so.screens")" "WAIT after the change"
    has "keys only once it worked" "$SSH_RESULT" "keys only"
    # No: today's steps and both logins.
    OWN_SAY=no
    : >"$TMP/so.screens"
    rm -f "$DROPIN"
    ssh_run >/dev/null
    has "no shows the steps" "$(cat "$TMP/so.screens")" "MSG Make a key"
    has "and waits for a new login" "$(cat "$TMP/so.screens")" "WAIT before the change"
    # Nothing matched: no question.
    SSH_SESSION_KEY=""
    : >"$TMP/so.screens"
    rm -f "$DROPIN"
    ssh_run >/dev/null
    lacks "no match asks nothing" "$(cat "$TMP/so.screens")" "ASK ssh_own"
    has "and waits as before" "$(cat "$TMP/so.screens")" "WAIT before the change"
    # An answer file never counts the session: it names its key.
    SSH_SESSION_KEY="1005 192.0.2.4 SHA256:mine" UI_MODE=answers OWN_SAY=yes
    ANS=([ssh_key_fingerprint]=SHA256:mine)
    : >"$TMP/so.screens"
    rm -f "$DROPIN"
    ssh_run >/dev/null
    lacks "an answer file is never asked" "$(cat "$TMP/so.screens")" "ASK ssh_own"
    has "and waits for the named key" "$(cat "$TMP/so.screens")" "WAIT before the change"
}
in_sub t_session_offer

echo "a pasted public key"
t_pubkey() {
    WORK_DIR=$TMP
    local K=$TMP/keys
    mkdir -p "$K"
    ssh-keygen -q -t ed25519 -N '' -C 'alice@laptop' -f "$K/ed"
    ssh-keygen -q -t rsa -b 2048 -N '' -C 'alice@desktop' -f "$K/rsa"
    ssh-keygen -q -t ecdsa -N '' -f "$K/ec"
    local ed rsa ec blob
    ed=$(cat "$K/ed.pub") rsa=$(cat "$K/rsa.pub") ec=$(cat "$K/ec.pub")
    yes_ ssh_pubkey_ok "$ed"
    yes_ ssh_pubkey_ok "$rsa"
    yes_ ssh_pubkey_ok "$ec"
    yes_ ssh_pubkey_ok "$(cut -d' ' -f1,2 <<<"$ed")"
    eq "a pasted line loses its line end" "$(ssh_pubkey_clean "  $ed"$'\r\n')" "$ed"
    no_ ssh_pubkey_ok ""
    no_ ssh_pubkey_ok "$ed"$'\n'"$rsa"
    no_ ssh_pubkey_ok "from=\"10.0.0.1\" $ed"
    no_ ssh_pubkey_ok "command=\"/bin/sh\" $ed"
    no_ ssh_pubkey_ok "$(head -n 1 "$K/ed")"
    no_ ssh_pubkey_ok "ssh-dss AAAAB3NzaC1kc3MAAACBAP"
    no_ ssh_pubkey_ok "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBroken"
    blob=$(cut -d' ' -f2 <<<"$ed")
    no_ ssh_pubkey_ok "ssh-rsa $blob"
    no_ ssh_pubkey_ok "ssh-ed25519 $blob bad$(printf '\033')[2Jname"
    no_ ssh_pubkey_ok "ssh-ed25519 $blob"$'\t'"tab"
    yes_ ssh_pubkey_or_empty ""
    no_ ssh_pubkey_or_empty "garbage"
    eq "its fingerprint is the one sshd logs" "$(ssh_pubkey_fp "$ed")" "$(ssh-keygen -l -E sha256 -f "$K/ed.pub" | awk '{print $2}')"
}
in_sub t_pubkey

echo "adding a key to authorized_keys"
t_append_key() {
    WORK_DIR=$TMP
    local K=$TMP/keys2 H=$TMP/home_ak
    mkdir -p "$K" "$H"
    ssh-keygen -q -t ed25519 -N '' -C new -f "$K/new"
    ssh-keygen -q -t ed25519 -N '' -C old -f "$K/old"
    ssh_as() { shift; "$@"; }
    ssh_home() { echo "$AK_HOME"; }
    AK_HOME=$H
    yes_ ssh_append_key me "$(cat "$K/new.pub")"
    eq "the folder is the account's alone" "$(stat -c %a "$H/.ssh")" 700
    eq "and so is the file" "$(stat -c %a "$H/.ssh/authorized_keys")" 600
    eq "it holds the key" "$(cat "$H/.ssh/authorized_keys")" "$(cat "$K/new.pub")"
    # A file without its last line end keeps every line whole.
    printf '%s' "$(cat "$K/old.pub")" >"$H/.ssh/authorized_keys"
    yes_ ssh_append_key me "$(cat "$K/new.pub")"
    eq "the old key stays, the new one follows" "$(cat "$H/.ssh/authorized_keys")" "$(cat "$K/old.pub" "$K/new.pub")"
    yes_ ssh_key_listed "$H" "$(ssh_pubkey_fp "$(cat "$K/new.pub")")"
    no_ ssh_key_listed "$H" SHA256:notthere
    # Links are refused and nothing reaches their target.
    local H2=$TMP/home_link T=$TMP/target_dir
    mkdir -p "$H2" "$T"
    ln -s "$T" "$H2/.ssh"
    AK_HOME=$H2
    no_ ssh_append_key me "$(cat "$K/new.pub")"
    has "a linked .ssh is named" "$SSH_KEYS_WHY" "is a link or not a folder"
    eq "and nothing lands behind it" "$(ls -A "$T")" ""
    local H3=$TMP/home_link2
    mkdir -p "$H3/.ssh"
    echo target >"$TMP/target_file"
    ln -s "$TMP/target_file" "$H3/.ssh/authorized_keys"
    AK_HOME=$H3
    no_ ssh_append_key me "$(cat "$K/new.pub")"
    has "a linked authorized_keys is named" "$SSH_KEYS_WHY" "is a link or not a plain file"
    eq "and its target is untouched" "$(cat "$TMP/target_file")" target
    local H4=$TMP/home_dir
    mkdir -p "$H4/.ssh/authorized_keys"
    AK_HOME=$H4
    no_ ssh_append_key me "$(cat "$K/new.pub")"
    # The writer refuses a link on its own too, should one appear after the check.
    ssh_keys_file_ok() { SSH_KEYS_WHY=""; return 0; }
    AK_HOME=$H3
    no_ ssh_append_key me "$(cat "$K/new.pub")"
    eq "the writer itself never follows the link" "$(cat "$TMP/target_file")" target
    AK_HOME=$H2
    no_ ssh_append_key me "$(cat "$K/new.pub")"
    eq "nor a linked .ssh" "$(ls -A "$T")" ""
}
in_sub t_append_key

echo "another computer's key"
t_add_key() {
    WORK_DIR=$TMP
    local K=$TMP/keys3 H=$TMP/home_add
    mkdir -p "$K" "$H/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C new -f "$K/new"
    ssh-keygen -q -t ed25519 -N '' -C old -f "$K/old"
    cp "$K/old.pub" "$H/.ssh/authorized_keys"
    chmod 700 "$H/.ssh"
    chmod 600 "$H/.ssh/authorized_keys"
    eval "$(declare -f ssh_passwords_surely_on | sed '1s/^ssh_passwords_surely_on/real_surely_on/')"
    ssh_as() { shift; "$@"; }
    ssh_home() { echo "$H"; }
    ssh_host_for_person() { echo relay.example.org; }
    SUDO_USER=alice UI_MODE=plain DRY_RUN=0
    ui_msg() { printf 'MSG %s\n%s\n' "$1" "$2" >>"$TMP/ak.screens"; }
    PASTES=("not a key" "$(cat "$K/new.pub")")
    n=0
    ui_input() { printf 'INPUT %s\n%s\n' "$1" "$3" >>"$TMP/ak.screens"; UI_REPLY=${PASTES[$n]}; n=$((n + 1)); }
    WAIT_RC=0
    ssh_wait_login() { printf 'WAIT want=%s open=%s\n' "$SSH_WANT_FP" "$SSH_OPEN" >>"$TMP/ak.screens"; SSH_KEY_SEEN="key $SSH_WANT_FP from 192.0.2.9"; return "$WAIT_RC"; }
    # The switch's parts must never run here.
    ssh_change_once() { echo CHANGE >>"$TMP/ak.screens"; }
    ssh_undo_now() { echo UNDO >>"$TMP/ak.screens"; }
    hollow_reload_sshd() { echo RELOAD >>"$TMP/ak.screens"; }
    local fp
    fp=$(ssh_pubkey_fp "$(cat "$K/new.pub")")
    # Passwords off: the key is pasted here.
    ssh_passwords_surely_on() { return 1; }
    : >"$TMP/ak.screens"
    ssh_add_key_run >/dev/null
    has "it shows how to print the new key" "$(cat "$TMP/ak.screens")" "cat ~/.ssh/id_ed25519.pub"
    has "a wrong paste is asked again" "$(cat "$TMP/ak.screens")" "not a key does not work here"
    eq "the pasted key is added after the old one" "$(cat "$H/.ssh/authorized_keys")" "$(cat "$K/old.pub" "$K/new.pub")"
    has "only a login with the pasted key counts" "$(cat "$TMP/ak.screens")" "WAIT want=$fp open=Open a terminal on the new computer"
    has "the result names the key" "$SSH_RESULT" "logged in with the key $fp from 192.0.2.9"
    lacks "passwords never come back" "$(cat "$TMP/ak.screens")" "UNDO"
    lacks "and nothing else changes in sshd" "$(cat "$TMP/ak.screens")" "RELOAD"
    lacks "nor is the switch run" "$(cat "$TMP/ak.screens")" "CHANGE"
    eq "the wait goes back to its usual wording" "$SSH_OPEN" "Open a second window on your own computer"
    # The same key again is not added twice.
    PASTES=("$(cat "$K/new.pub")")
    n=0
    ssh_add_key_run >/dev/null
    eq "a key already there is not added twice" "$(grep -c . "$H/.ssh/authorized_keys")" 2
    # No confirmed login: the key stays, nothing is removed.
    WAIT_RC=1
    PASTES=("$(cat "$K/new.pub")")
    n=0
    ssh_add_key_run >/dev/null
    has "an unconfirmed login says so" "$SSH_RESULT" "did not confirm"
    eq "and removes nothing" "$(grep -c . "$H/.ssh/authorized_keys")" 2
    WAIT_RC=0
    # An empty paste stops with nothing changed.
    PASTES=("")
    n=0
    : >"$TMP/ak.screens"
    ssh_add_key_run >/dev/null
    eq "an empty paste changes nothing" "$SSH_RESULT" "Nothing changed."
    lacks "and waits for nothing" "$(cat "$TMP/ak.screens")" "WAIT"
    # A linked authorized_keys is refused before anything is written.
    rm -f "$H/.ssh/authorized_keys"
    echo target >"$TMP/ak_target"
    ln -s "$TMP/ak_target" "$H/.ssh/authorized_keys"
    PASTES=("$(cat "$K/new.pub")")
    n=0
    ssh_add_key_run >/dev/null
    has "a link is refused" "$SSH_RESULT" "I added nothing"
    eq "and its target is untouched" "$(cat "$TMP/ak_target")" target
    rm -f "$H/.ssh/authorized_keys"
    cp "$K/old.pub" "$H/.ssh/authorized_keys"
    # Passwords on: the new computer copies its key itself, as in the setup.
    ssh_passwords_surely_on() { return 0; }
    n=0
    : >"$TMP/ak.screens"
    ssh_add_key_run >/dev/null
    has "the steps are the setup's" "$(cat "$TMP/ak.screens")" "ssh-copy-id alice@relay.example.org"
    has "made on the new computer" "$(cat "$TMP/ak.screens")" "Do this on the new computer"
    lacks "nothing is pasted" "$(cat "$TMP/ak.screens")" "INPUT"
    eq "nothing is written here" "$(cat "$H/.ssh/authorized_keys")" "$(cat "$K/old.pub")"
    has "any key confirmed after the prompt counts" "$(cat "$TMP/ak.screens")" "WAIT want= open=Open a terminal on the new computer"
    lacks "passwords stay as they are" "$(cat "$TMP/ak.screens")" "UNDO"
    # When sshd cannot say, the paste works either way.
    ssh_passwords_surely_on() { real_surely_on; }
    mkfake "$TMP/fake_nosshd" sshd 'exit 255'
    PATH="$TMP/fake_nosshd:$PATH"
    PASTES=("")
    n=0
    : >"$TMP/ak.screens"
    ssh_add_key_run >/dev/null
    has "an sshd that cannot say gets the paste" "$(cat "$TMP/ak.screens")" "INPUT ssh_public_key"
}
in_sub t_add_key

echo "the wait with a pasted key"
t_wait_want() {
    PATH="$FAKE:$PATH"
    UI_MODE=plain
    local now
    now=$(date +%s)
    ssh_host_for_person() { echo relay.example.org; }
    ui_msg() { :; }
    ui_yesno() { printf 'ASKED %s\n' "$3" >>"$TMP/ww.screens"; return 0; }
    ui_menu() { UI_REPLY=stop; }
    : >"$FAKE_JOURNAL"
    : >"$TMP/ww.screens"
    jline "$now" "Accepted publickey for alice from 10.0.0.9 port 3 ssh2: ED25519 SHA256:otherkey"
    SSH_WANT_FP=SHA256:pasted
    if ssh_wait_login alice "$now" test; then bad "a login with another key counted"; else ok; fi
    eq "nobody is asked about another key" "$(cat "$TMP/ww.screens")" ""
    jline "$now" "Accepted publickey for alice from 192.0.2.9 port 4 ssh2: ED25519 SHA256:pasted"
    yes_ ssh_wait_login alice "$now" test
    has "the pasted key's login is asked about" "$(cat "$TMP/ww.screens")" "with the key SHA256:pasted"
}
in_sub t_wait_want

echo "the re-run menu"
t_menu() {
    conf_load() { CFG_MODE=native CFG_MEMBERS_ONLY=no; }
    local_ipv4() { echo 203.0.113.7; }
    update_check() { UPDATE_AVAILABLE=0; }
    status_text() { echo status; }
    ui_msg() { :; }
    ui_menu() { [ "$1" = action ] && printf '%s\n' "$@" >"$TMP/menu.items"; UI_REPLY="exit"; }
    UI_MODE=plain
    ssh_passwords_on() { return 1; }
    manage_main >/dev/null
    has "keys only: a second computer's key can be added" "$(cat "$TMP/menu.items")" "Add another computer's SSH key"
    ssh_passwords_on() { return 0; }
    manage_main >/dev/null
    has "passwords on: too" "$(cat "$TMP/menu.items")" "Add another computer's SSH key"
    has "beside turning them off" "$(cat "$TMP/menu.items")" "Turn SSH password logins off"
    # The SSH result after a switch carries the backup note.
    SSH_RESULT="SSH takes keys only now."
    ssh_run() { :; }
    ui_menu() { UI_REPLY=ssh; }
    ui_msg() { printf '%s\n' "$2" >"$TMP/menu.ssh"; }
    ssh_passwords_on() { return 1; }
    DRY_RUN=0
    manage_main >/dev/null
    has "a switch from the menu says to keep a copy of the key" "$(cat "$TMP/menu.ssh")" "If the SSH key file on your computer is lost"
}
in_sub t_menu

echo "the summary"
t_summary() {
    load_fn "$RELAY/install.sh" fw_rules_now ports_text summary_running summary_ports summary_backup summary_end summary_screen
    run_checks() { CHECK_RESULT="all passed (sudo bash /usr/local/lib/hollow-relay/deploy/check-host.sh runs them again)."; }
    hollow_ssh_ports() { echo 22 2222; }
    member_list() { printf '%s\n' AAAA-BBBB-CCCC-DDDD EEEE-FFFF-GGGG-HHHH IIII-JJJJ-KKKK-LLLL MMMM-NNNN-OOOO-PPPP QQQQ-RRRR-SSSS-TTTT; }
    clear() { :; }
    put_file() { cat >/dev/null; }
    # The tallest summary: every option on, a domain (port 80), behind NAT,
    # members-only, keys only with the longest result.
    CFG_MODE=native CFG_ADDRESS=domain CFG_HOST=relay.some-long-domain-name.example.org
    CFG_TURN=yes CFG_PUSH=yes CFG_FORWARDER=yes CFG_MEMBERS_ONLY=yes
    PF_BEHIND_NAT=1 PF_LOCAL_IP=192.168.188.123 DRY_RUN=0 COMPOSE_PROJECT=hollow-relay
    SSH_RESULT="SSH takes keys only now. Your key login worked after the change, with the key SHA256:AbCdEf0123456789AbCdEf0123456789AbCdEf01234 from 2001:db8:1234:5678:9abc:def0:1234:5678. That computer holds the key to this server. Root cannot log in over SSH either."
    ssh_passwords_on() { return 1; }
    UI_MODE=whiptail
    ui_msg() { printf '%s\n' "$1" >>"$TMP/sum.titles"; printf '%s' "$2" >"$TMP/sum.$(wc -l <"$TMP/sum.titles")"; }
    : >"$TMP/sum.titles"
    summary_screen >"$TMP/sum.out"
    eq "the summary's screens" "$(tr '\n' '|' <"$TMP/sum.titles")" "Your relay is running|Members-only keys|Ports to open|What to back up|SSH and checks|"
    local i
    for i in 1 2 3 4 5; do fits "summary screen $i ($(sed -n "${i}p" "$TMP/sum.titles"))" "$(cat "$TMP/sum.$i")"; done
    has "screen 1: the address" "$(cat "$TMP/sum.1")" "  relay.some-long-domain-name.example.org"
    has "screen 1: what runs" "$(cat "$TMP/sum.1")" "Running: the relay, TURN, the push sender, the media forwarder."
    has "screen 1: members-only" "$(cat "$TMP/sum.1")" "Members-only: yes, 5 keys."
    has "the keys on their own screen" "$(cat "$TMP/sum.2")" "QQQQ-RRRR-SSSS-TTTT"
    has "screen 2: the ports" "$(cat "$TMP/sum.3")" "49152 to 65535/udp"
    has "and the router" "$(cat "$TMP/sum.3")" "forward them to 192.168.188.123"
    has "screen 3: the report counts" "$(cat "$TMP/sum.4")" "/var/lib/hollow-relay/reports.json, the report counts"
    lacks "and no report key" "$(cat "$TMP/sum.4")" "reports.json.key"
    has "the forwarder's identity" "$(cat "$TMP/sum.4")" "forwarder.key and forwarder.db"
    # shellcheck disable=SC2088 # the text the person reads
    has "the SSH key's usual file" "$(cat "$TMP/sum.4")" "~/.ssh/id_ed25519"
    has "kept somewhere safe" "$(cat "$TMP/sum.4")" "such as a password manager"
    has "or a second computer's key" "$(cat "$TMP/sum.4")" "add a second computer's key with sudo hollow-relay-setup"
    has "and the way back in" "$(cat "$TMP/sum.4")" "your provider's web console, or a screen and keyboard on the machine itself"
    has "screen 4: SSH" "$(cat "$TMP/sum.5")" "That computer holds the key to this server."
    has "the checks" "$(cat "$TMP/sum.5")" "Checks: all passed"
    has "and the re-run" "$(cat "$TMP/sum.5")" "sudo hollow-relay-setup"
    # After the screens, the whole summary stays in the scrollback, without the keys.
    local out
    out=$(cat "$TMP/sum.out")
    has "printed: the address" "$out" "relay.some-long-domain-name.example.org"
    has "printed: the ports" "$out" "40000 to 40199/udp"
    has "printed: the backups" "$out" "/var/lib/hollow-relay/reports.json, the report counts"
    has "printed: SSH" "$out" "SSH takes keys only now"
    has "printed: the re-run" "$out" "sudo hollow-relay-setup"
    lacks "never the members-only keys" "$out" "AAAA-BBBB-CCCC-DDDD"
    # While passwords still work, a lost key locks nobody out.
    ssh_passwords_on() { return 0; }
    lacks "no key note while passwords work" "$(summary_backup)" "If the SSH key file on your computer is lost"
    # Plain and answer-file runs print each screen once, and nothing after.
    for UI_MODE in plain answers; do
        : >"$TMP/sum.titles"
        summary_screen >"$TMP/sum.out"
        eq "$UI_MODE: nothing printed twice" "$(cat "$TMP/sum.out")" ""
    done
    # A Docker setup names its volumes.
    CFG_MODE=docker
    has "Docker backs up its volumes" "$(summary_backup)" "hollow-relay_data"
}
in_sub t_summary

# Taking over a relay this setup did not install.
# shellcheck source=adopt_tests.sh
. "$T/adopt_tests.sh"
# The rules that keep the setup safe on someone's server.
# shellcheck source=safety_tests.sh
. "$T/safety_tests.sh"
# shellcheck source=screens_tests.sh
. "$T/screens_tests.sh"

if [ "$(id -u)" = 0 ] && [ -r /etc/os-release ]; then
    echo "dry run"
    cat >"$TMP/ans" <<EOF
mode=native
binaries=source
address=domain
domain=relay.invalid-example.org
public_ip=198.51.100.9
staging=yes
turn=yes
push=yes
forwarder=yes
members_only=yes
member_keys=2
grace_secs=200
ssh_keys=no
continue_anyway=yes
confirm=yes
EOF
    out=$(bash "$RELAY/install.sh" --dry-run --answers "$TMP/ans" 2>&1)
    rc=$?
    eq "dry run exit" "$rc" 0
    has "dry run plan" "$out" "This is what I will do"
    lacks "a first install asks for no email" "$out" "Email for Let's Encrypt"
    has "dry run harden" "$out" "harden-host.sh"
    has "dry run forwarder range" "$out" "40000 to 40199/udp"
    has "dry run cert" "$out" "would run deploy/certbot/issue.sh for relay.invalid-example.org (staging"
    has "dry run relay unit" "$out" "would write: /etc/systemd/system/hollow-relay.service"
    has "dry run forwarder" "$out" "would write: /etc/hollow-forwarder/forwarder.toml"
    has "dry run push" "$out" "would write: /etc/hollow-push/push.env"
    has "dry run keys" "$out" "would write: /etc/hollow-relay/keys.json"
    if [ -e /etc/systemd/system/hollow-relay.service ]; then bad "a dry run wrote the relay unit"; else ok; fi
    if [ -e /etc/hollow-relay/install.conf ]; then bad "a dry run left install.conf behind"; else ok; fi
    sed -i 's/^address=domain/address=carrier-pigeon/' "$TMP/ans"
    out=$(bash "$RELAY/install.sh" --dry-run --answers "$TMP/ans" 2>&1)
    has "dry run refuses a bad answer" "$out" "takes one of"
    sed -i 's/^address=carrier-pigeon/address=domain/; $a public_ipv6=2001:db8::/32' "$TMP/ans"
    out=$(bash "$RELAY/install.sh" --dry-run --answers "$TMP/ans" 2>&1)
    has "a v6 range is refused" "$out" "is not one public IPv6 address"
fi

# A real run up to the plan screen, answered no. Only on a throwaway test box:
# it takes the setup's lock in /var/lib/hollow-installer.
if [ "$(id -u)" = 0 ] && [ "${HOLLOW_INSTALLER_TEST_BOX:-}" = 1 ]; then
    echo "nothing changes before the plan"
    F=$TMP/fake_e2e
    export FAKE_CURL_CFG=$TMP/e2e.cfg
    : >"$FAKE_CURL_CFG"
    mkfake "$F" curl 'for a; do case "$a" in https://api.ipify.org|https://ipv4.icanhazip.com|https://ifconfig.me/ip) echo 203.0.113.7; exit 0 ;; https://api6.ipify.org|https://ipv6.icanhazip.com) exit 7 ;; esac; done
case "$*" in *"-K -"*) cat >>"$FAKE_CURL_CFG"; echo OK; exit 0 ;; esac
exit 7'
    printf 'mode=native\nbinaries=source\naddress=duckdns\nduckdns_name=myrelay\nduckdns_token=a1b2c3d4-0000-1111-2222-333344445555\nssh_keys=no\ncontinue_anyway=yes\nconfirm=no\n' >"$TMP/ans_dd"
    out=$(PATH="$F:$PATH" bash "$RELAY/install.sh" --answers "$TMP/ans_dd" 2>&1)
    has "the run stops at the plan" "$out" "Stopped. Nothing was changed."
    has "the token was checked" "$(cat "$FAKE_CURL_CFG")" "token=a1b2c3d4-0000-1111-2222-333344445555&txt=&clear=true"
    lacks "and DuckDNS still points where it did" "$(cat "$FAKE_CURL_CFG")" "&ip="
    has "the plan names the change to come" "$out" "DuckDNS points myrelay.duckdns.org at this machine"
    # A box behind NAT gets two screens: the steps first, then the findings
    # with the question.
    found=$(sed -n '/^----- What I found -----$/,/^Answer from the file (continue_anyway)/p' <<<"$out")
    has "the findings have a screen of their own" "$found" "Disk:"
    lacks "without the steps" "$found" "with a step or two from you"
    has "which come first" "$(sed -n '/^----- Can this machine host a relay? -----$/,/^-----/p' <<<"$out")" "with a step or two from you"
    # The plan screen refuses a firewall that would shut this session out,
    # even if the port list came out wrong.
    rm -rf "$TMP/inst"
    mkdir -p "$TMP/inst/relay-uws"
    cp -R "$RELAY/install.sh" "$DEPLOY" "$TMP/inst/relay-uws/"
    printf '\nhollow_ssh_ports() { echo 22; }\n' >>"$TMP/inst/relay-uws/deploy/lib/host.sh"
    out=$(PATH="$F:$PATH" SSH_CONNECTION="198.51.100.1 50000 192.0.2.5 2345" bash "$TMP/inst/relay-uws/install.sh" --answers "$TMP/ans_dd" 2>&1)
    has "the setup stops before a lockout" "$out" "The firewall could lock you out"
    lacks "before the plan" "$out" "This is what I will do"
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
