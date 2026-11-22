#!/bin/bash
# The address follower (deploy/address-follow.sh, HOL-SEC-214) under a real systemd,
# inside the throwaway container run_systemd_tests.sh starts. The machine's DNS server
# is fake_dns.py on 127.0.0.1, and the far ends are TLS servers and TURN servers behind
# nat rules: the relay's key with this relay's coturn, an impostor's key, the relay's
# key alone (a passthrough proxy for 443), the relay's key with an echo on 3478, and
# the relay's key with a coturn that has another secret. The relay itself is a TLS
# server on 127.0.0.1:443 with the relay's key.
# Never on a real machine: it adds accounts, units, addresses and firewall rules.
# shellcheck disable=SC2034 # read by the sourced libraries
set -uo pipefail
[ "${HOLLOW_INSTALLER_TEST_BOX:-}" = 1 ] || { echo "Runs only inside the test container (run_systemd_tests.sh)." >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Runs as root." >&2; exit 2; }

T=$(cd "$(dirname "$0")" && pwd)
RELAY=$(cd "$T/../.." && pwd)
DEPLOY=$RELAY/deploy
HERE=$RELAY
REPO=$(cd "$RELAY/.." && pwd)
WORK_DIR=$(mktemp -d)
SERVERS=()
SHIM=/usr/local/lib/box-follow
cleanup() {
    local p
    for p in "${SERVERS[@]}"; do kill "$p" 2>/dev/null; done
    nft delete table ip box_follow 2>/dev/null
    nft delete table ip6 box_follow6 2>/dev/null
    ip -6 route del 2001:db8:5::5/128 dev lo 2>/dev/null
    rm -f "$SHIM/ip"
    ip addr del 2001:db8:1::5/128 dev lo 2>/dev/null
    ip addr del 2001:db8:1::7/128 dev lo 2>/dev/null
    [ -f "$WORK_DIR/resolv.conf" ] && cat "$WORK_DIR/resolv.conf" >/etc/resolv.conf
    rm -f "$UNIT_DIR/hollow-coturn.service.d/box-record.conf"
    rm -rf "$WORK_DIR" "$SHIM" /run/hollow-duckdns
}
trap cleanup EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: missing [$3] in [$2]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: should not contain [$3]"; else ok "$1"; fi; }
yes_() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
no_()  { local n=$1; shift; if "$@"; then bad "$n"; else ok "$n"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }

for f in common ui preflight address ssh_keys native docker manage host questions adopt; do
    # shellcheck source=/dev/null
    . "$DEPLOY/lib/$f.sh"
done
# shellcheck disable=SC2317 # called by the libraries
die() { printf 'DIE %s\n' "$*"; exit 99; }
DRY_RUN=0 UI_MODE=answers
ENABLE_UNITS=() RESTART_UNITS=()
# shellcheck source=/dev/null
. /etc/os-release
echo "box: $PRETTY_NAME"

NAME=relay.box.test
OLD=203.0.113.7 NEW=203.0.113.9 FAKE=203.0.113.10 NEW2=203.0.113.11
PROXY=203.0.113.12 ECHO=203.0.113.13 WRONG=203.0.113.14 GONE=203.0.113.15 HANG=203.0.113.16
L=$(local_ipv4)
FOLLOW_STATE=/run/hollow-address/state
echo "  this box's own address: $L"

echo "the address follower: setup"
install_installer_copy >/dev/null
for c in relay other; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=$NAME" \
        -keyout "$WORK_DIR/$c.key" -out "$WORK_DIR/$c.pem" >/dev/null 2>&1
done
# serve <address:port> <relay|other>: sets LAST_PID.
serve() {
    setsid openssl s_server -quiet -www -accept "$1" -cert "$WORK_DIR/$2.pem" -key "$WORK_DIR/$2.key" >/dev/null 2>&1 &
    LAST_PID=$!
    SERVERS+=("$LAST_PID")
}
# background <command...>: a helper server, stopped at the end.
background() {
    setsid "$@" >/dev/null 2>&1 &
    LAST_PID=$!
    SERVERS+=("$LAST_PID")
}
# Every probe a follower run makes is noted with the account it ran as.
install -d -m 0755 "$SHIM"
install -m 0666 /dev/null "$SHIM/who"
cat >"$SHIM/python3" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$(id -un)" "${3:-}" >>/usr/local/lib/box-follow/who 2>/dev/null
exec /usr/bin/python3 "$@"
EOF
cat >"$SHIM/openssl" <<'EOF'
#!/bin/bash
[ "${1:-}" = s_client ] && printf '%s s_client\n' "$(id -un)" >>/usr/local/lib/box-follow/who 2>/dev/null
exec /usr/bin/openssl "$@"
EOF
cat >"$SHIM/curl" <<'EOF'
#!/bin/bash
printf '%s curl\n' "$(id -un)" >>/usr/local/lib/box-follow/who 2>/dev/null
exec /usr/bin/curl "$@"
EOF
# A run told to die halfway through a rewrite, between mktemp and the rename.
cat >"$SHIM/chown" <<'EOF'
#!/bin/bash
[ -e /usr/local/lib/box-follow/turn-env-unwritable ] && [[ "$*" == *turn.env.follow.* ]] && exit 1
if [ -e /usr/local/lib/box-follow/kill-at-chown ]; then
    rm -f /usr/local/lib/box-follow/kill-at-chown
    kill -TERM "$PPID"
    sleep 1
fi
exec /usr/bin/chown "$@"
EOF
chmod 0755 "$SHIM/python3" "$SHIM/openssl" "$SHIM/curl" "$SHIM/chown"
who_ran() { sort -u "$SHIM/who"; }
# dns <A|AAAA> <address or NXDOMAIN, SERVFAIL, DROP>...: what this machine's DNS answers.
dns() {
    local t=$1
    shift
    printf '%s\n' "$@" >"$SHIM/dns-$t"
}

ensure_account hollow-relay
ensure_dir "$RELAY_ETC" 0750 root hollow-relay
install -m 0640 -g hollow-relay "$WORK_DIR/relay.pem" "$RELAY_ETC/fullchain.pem"
install -m 0640 -g hollow-relay "$WORK_DIR/relay.key" "$RELAY_ETC/privkey.pem"
printf '#!/bin/sh\nexec sleep 100000\n' >/usr/local/bin/hollow-forwarder
chmod 0755 /usr/local/bin/hollow-forwarder
CFG_MODE=native CFG_ADDRESS=domain CFG_HOST=$NAME CFG_TURN=yes CFG_FORWARDER=yes CFG_PUBLIC_IP=$OLD
CFG_PUBLIC_IP_FIXED=no CFG_PUBLIC_IPV6="" CFG_TURN_PUBLIC_IP="" CFG_TURN_PUBLIC_IPV6="" PF_LOCAL_IP=$L PF_PUBLIC_IPV6=""
TURN_SECRET_VALUE=$(gen_hex 32) FWD_KEY=""
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
ensure_account hollow-fwd
ensure_dir "$FWD_ETC" 0750 root hollow-fwd
render_forwarder_toml | put_file "$FWD_ETC/forwarder.toml" 0640 root hollow-fwd
put_unit hollow-forwarder.service < <(more_inaccessible <"$DEPLOY/hollow-forwarder.service")
ENABLE_UNITS+=(hollow-forwarder)
start_units >/dev/null
# What the TURN port lock holds each time coturn starts.
cat >"$SHIM/record.sh" <<EOF
#!/bin/sh
{ printf 'env: '; grep '^TURN_PEERS=' $LOCK_ENV; printf 'rule: '; nft list table inet hollow_turn | grep 'ip daddr {' | tr -s ' '; } >>$SHIM/at-coturn-start
EOF
chmod 0755 "$SHIM/record.sh"
mkdir -p "$UNIT_DIR/hollow-coturn.service.d"
printf '[Service]\nExecStartPre=+/bin/sh %s\n' "$SHIM/record.sh" >"$UNIT_DIR/hollow-coturn.service.d/box-record.conf"
systemctl daemon-reload
systemctl reset-failed hollow-coturn
systemctl restart hollow-coturn
# The lock's packages (nftables among them) came with turn_apply.
serve 127.0.0.1:443 relay
RELAY_PID=$LAST_PID
serve 0.0.0.0:8441 relay
serve 0.0.0.0:8442 other
# A coturn with another secret, and an echo that hands every packet back, away from
# the ports coturn itself takes (3478, its alternate 3479, 5349, 5350).
background turnserver -n --listening-ip="$L" --listening-port=3578 --use-auth-secret --static-auth-secret=not-this-relays \
    --realm=hollow --no-tls --no-dtls --no-cli --min-port=40000 --max-port=40100 --pidfile="$WORK_DIR/turn2.pid" \
    --log-file=/dev/null --simple-log
# The echo asks for credentials like coturn, then hands the signed request back.
background python3 -I -c '
import socket, struct
def attr(t, v):
    return struct.pack(">HH", t, len(v)) + v + b"\0" * ((4 - len(v) % 4) % 4)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 3590))
while True:
    d, a = s.recvfrom(4096)
    if len(d) < 20:
        continue
    if b"\x00\x08\x00\x14" in d[20:]:
        s.sendto(d, a)
        continue
    body = attr(0x0014, b"hollow") + attr(0x0015, b"nonce123") + attr(0x0009, b"\x00\x00\x04\x01")
    s.sendto(struct.pack(">HHI", 0x0113, len(body), 0x2112A442) + d[8:20] + body, a)'
# hang_on <address> <port>: accepts and never answers.
hang_on() {
    background python3 -I -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(16)
held = []
while True:
    held.append(s.accept()[0])' "$1" "$2"
}
hang_on 0.0.0.0 8450
# Which far end answers at each address; any other address in these ranges refuses at once.
nft -f - <<EOF
table ip box_follow {
    set relay443 { type ipv4_addr; elements = { $NEW, $NEW2, $PROXY, $ECHO, $WRONG } }
    set other443 { type ipv4_addr; elements = { $FAKE } }
    set turn3478 { type ipv4_addr; elements = { $NEW, $NEW2, $FAKE } }
    chain out {
        type nat hook output priority -100; policy accept;
        ip daddr @relay443 tcp dport 443 dnat to $L:8441
        ip daddr @other443 tcp dport 443 dnat to $L:8442
        ip daddr $HANG tcp dport 443 dnat to $L:8450
        ip daddr @turn3478 udp dport 3478 dnat to $L:3478
        ip daddr $ECHO udp dport 3478 dnat to $L:3590
        ip daddr $WRONG udp dport 3478 dnat to $L:3578
        ip daddr { 203.0.113.0/24, 198.51.100.0/24 } tcp dport 443 dnat to $L:8449
        ip daddr { 203.0.113.0/24, 198.51.100.0/24 } udp dport 3478 dnat to $L:3489
    }
}
EOF
# Ubuntu 22.04's systemd package runs systemd-resolved itself; this box is one
# without it until the section that stands one in.
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable --now systemd-resolved >/dev/null 2>&1
    rm -f /run/systemd/resolve/io.systemd.Resolve
fi
# From here on this machine's DNS server is fake_dns.py (apt needed the real one).
cp /etc/resolv.conf "$WORK_DIR/resolv.conf"
background python3 -I "$T/fake_dns.py" "$SHIM" 127.0.0.1 53
echo "nameserver 127.0.0.1" >/etc/resolv.conf
no_ "this box asks its DNS server directly, not through systemd-resolved" test -S /run/systemd/resolve/io.systemd.Resolve
sleep 1
far_end() { curl -q -s -o /dev/null -k --max-time 5 --resolve "$NAME:443:$1" "https://$NAME/health"; }
yes_ "the far end with the relay's key answers through its nat rule" far_end "$NEW"
yes_ "and the impostor's" far_end "$FAKE"
dns A "$OLD"
eq "the probe asks this machine's DNS server" "$(python3 -I "$DEPLOY/address-probe.py" dns "$NAME" A)" "rcode=0
$OLD"

conf_save >/dev/null
follow_apply >/dev/null
yes_ "a domain's relay gets the follower's timer" systemctl is-active --quiet hollow-address-follow.timer
yes_ "and it starts on boot" systemctl is-enabled --quiet hollow-address-follow.timer
yes_ "its lookups run as their own account" getent passwd hollow-addr
# The timer stays on for check-host, while its runs do nothing until the unit's own test.
mkdir -p "$UNIT_DIR/hollow-address-follow.service.d"
printf '[Service]\nExecStart=\nExecStart=/bin/true\n' >"$UNIT_DIR/hollow-address-follow.service.d/box.conf"
systemctl daemon-reload

# A running coturn answers an authenticated Allocate before a look starts: coturn
# 4.18 (Ubuntu 26.10) takes a moment after a restart, which a look five minutes
# later never sees.
turn_ready() {
    local cred _
    systemctl is-active --quiet hollow-coturn || return 0
    cred=$(/usr/bin/python3 -I "$INSTALLER_COPY/deploy/address-probe.py" turn-cred "$TURN_ETC/turn.env" 2>/dev/null) || return 0
    for _ in $(seq 1 50); do
        TURN_USER=${cred%%$'\n'*} TURN_PASS=${cred#*$'\n'} timeout 2 /usr/bin/python3 -I \
            "$INSTALLER_COPY/deploy/address-probe.py" turn "$L" 3478 >/dev/null 2>&1 && return 0
        sleep 0.2
    done
}
follow() { turn_ready; PATH="$SHIM:$PATH" bash "$INSTALLER_COPY/deploy/address-follow.sh" run 2>&1; }
inv() { systemctl show -p InvocationID --value "$1"; }
turn_ip() { kv_get "$TURN_ETC/turn.env" PUBLIC_IP; }
peers() { kv_get "$LOCK_ENV" TURN_PEERS; }
fwd_ip() { sed -n 's/^public_ip = "\(.*\)"$/\1/p' "$FWD_ETC/forwarder.toml"; }
conf_ip() { kv_get "$CONF_FILE" public_ip; }
follower_ip() { kv_get "$CONF_FILE" turn_public_ip; }
coturn_cmd() { tr '\0' ' ' <"/proc/$(systemctl show -p MainPID --value hollow-coturn)/cmdline" 2>/dev/null; }
modes() { stat -c '%n %a %U %G' "$TURN_ETC/turn.env" "$LOCK_ENV" "$FWD_ETC/forwarder.toml" "$CONF_FILE"; }
address_part() { PATH="$SHIM:$PATH" bash "$DEPLOY/check-host.sh" 2>&1 | sed -n '/^Public address$/,/^[A-Za-z]/p'; }
# stamp <key> <value>: the follower's own memory, as it keeps it in RAM.
stamp() {
    install -d -m 0700 "${FOLLOW_STATE%/*}"
    touch "$FOLLOW_STATE"
    sed -i "/^$1=/d" "$FOLLOW_STATE"
    printf '%s=%s\n' "$1" "$2" >>"$FOLLOW_STATE"
}
# window <looks> <start> <set> <current>: an old address already that long unconfirmed.
window() { stamp w4_looks "$1"; stamp w4_start "$2"; stamp w4_set "$3"; stamp w4_cur "$4"; }
looks() { sed -n 's/^w4_looks=//p' "$FOLLOW_STATE"; }
state_val() { sed -n "s/^$1=//p" "$FOLLOW_STATE"; }
long_ago=$(($(date +%s) - 3600))
eq "coturn starts on the old address" "$(turn_ip)" "$OLD"
modes_before=$(modes)

echo "the address follower: no change"
# no_change_restarts_nothing
stamp last_change "$long_ago"
c0=$(inv hollow-coturn) f0=$(inv hollow-forwarder) n0=$(nft list table inet hollow_turn)
out=$(follow)
eq "the name still pointing here restarts no coturn" "$(inv hollow-coturn)" "$c0"
eq "a look that cannot reach this relay at its own address notes nothing" "$(state_val loop4)" ""
eq "and no forwarder" "$(inv hollow-forwarder)" "$f0"
eq "and leaves the lock's rule" "$(nft list table inet hollow_turn)" "$n0"
eq "and coturn's address" "$(turn_ip)" "$OLD"
part=$(address_part)
eq "check-host passes the address" "$(grep FAIL <<<"$part")" ""
has "naming it" "$part" "$OLD"

echo "the address follower: far ends that are not this relay"
# an_impostor_address_rewrites_nothing: another key on 443, though this relay's own
# coturn answers on 3478 there.
dns A "$FAKE"
out=$(follow)
has "an address whose far end lacks the relay's key is not taken" "$out" "$FAKE, which did not prove"
eq "coturn keeps its address" "$(turn_ip)" "$OLD"
eq "the lock keeps its peers" "$(peers)" "$OLD $L"
eq "the forwarder keeps its address" "$(fwd_ip)" "$OLD"
eq "the answers keep theirs" "$(conf_ip) $(follower_ip)" "$OLD "
eq "and nothing restarted" "$(inv hollow-coturn) $(inv hollow-forwarder)" "$c0 $f0"
has "check-host names both addresses" "$(address_part)" "FAIL  coturn's settings ($TURN_ETC/turn.env) give $OLD, but $NAME points at $FAKE"
# a_passthrough_proxy_for_443_alone_is_not_taken: the relay's key answers there, coturn does not.
dns A "$PROXY"
out=$(follow)
eq "a far end that passes 443 through to this relay, with no TURN behind it, is not taken" "$(turn_ip) $(peers)" "$OLD $OLD $L"
# an_echo_of_our_own_turn_request_is_not_taken: our signed request handed back proves nothing.
dns A "$ECHO"
out=$(follow)
eq "a far end that echoes the signed TURN request back is not taken" "$(turn_ip) $(peers)" "$OLD $OLD $L"
# a_turn_server_without_this_relays_secret_is_not_taken
dns A "$WRONG"
out=$(follow)
eq "a coturn there with another secret is not taken" "$(turn_ip) $(peers)" "$OLD $OLD $L"
dns A 198.51.100.200
out=$(follow)
eq "an address nothing answers on is not taken either" "$(turn_ip) $(peers)" "$OLD $OLD $L"
# every_probe_has_a_time_limit: a far end that accepts and never answers.
dns A "$HANG"
t0=$(date +%s)
out=$(follow)
yes_ "a far end that never answers costs a look seconds, not forever" test $(($(date +%s) - t0)) -lt 40
eq "and is not taken" "$(turn_ip)" "$OLD"

echo "the address follower: a proven change"
# a_proven_change_rewrites_all_three_and_drops_the_old_peer
rm -f "$FOLLOW_STATE"
: >"$SHIM/who"
: >"$SHIM/at-coturn-start"
dns A "$NEW"
out=$(follow)
printf '%s\n' "$out" | sed 's/^/  | /'
has "it says both the TLS key and the TURN secret answered" "$out" "both this relay's TLS key and its TURN secret answered there"
eq "a handshake that proved the address notes that this machine reaches itself" "$(state_val loop4)" yes
eq "coturn's settings take the new address" "$(turn_ip)" "$NEW"
eq "the lock's peers drop the old one" "$(peers)" "$NEW $L"
eq "the forwarder takes it" "$(fwd_ip)" "$NEW"
eq "install.conf keeps the setup's answer" "$(conf_ip)" "$OLD"
eq "and notes the follower's own beside it, so an update keeps it" "$(follower_ip)" "$NEW"
eq "every file keeps its mode and owner" "$(modes)" "$modes_before"
sleep 2
no_ "coturn restarted" test "$(inv hollow-coturn)" = "$c0"
no_ "the forwarder restarted" test "$(inv hollow-forwarder)" = "$f0"
has "coturn runs on the new address" "$(coturn_cmd)" "--external-ip=$NEW/$L"
lacks "and no longer lets the old one through its peer lock" "$(coturn_cmd)" "$OLD"
has "the loaded rule holds the new address" "$(nft list table inet hollow_turn)" "$NEW"
lacks "and not the old" "$(nft list table inet hollow_turn)" "$OLD"
# the_lock_holds_old_and_new_peers_while_coturn_restarts
at_start=$(cat "$SHIM/at-coturn-start")
has "while coturn restarted the lock's settings held the new address" "$(grep '^env' <<<"$at_start")" "$NEW"
has "and the old" "$(grep '^env' <<<"$at_start")" "$OLD"
has "and so did the loaded rule: the new" "$(grep '^rule' <<<"$at_start")" "$NEW"
has "and the old" "$(grep '^rule' <<<"$at_start")" "$OLD"
# the_probes_run_as_hollow_addr
eq "every lookup, handshake and TURN probe ran as hollow-addr, the credential alone as root" "$(who_ran)" "hollow-addr curl
hollow-addr dns
hollow-addr s_client
hollow-addr turn
root turn-cred"
part=$(address_part)
eq "check-host passes the new address" "$(grep FAIL <<<"$part")" ""
has "naming it" "$part" "ok    coturn's settings ($TURN_ETC/turn.env) give $NEW, the address $NAME points at"
has "and the follower's address beside the setup's answer" "$part" "the follower's address in $CONF_FILE (your answer is $OLD) gives $NEW"
c1=$(inv hollow-coturn) f1=$(inv hollow-forwarder)
stamp loop4 ""
out=$(follow)
eq "a second look restarts nothing" "$(inv hollow-coturn) $(inv hollow-forwarder)" "$c1 $f1"
eq "and notes that its own address answers a pinned handshake from here" "$(state_val loop4)" yes

echo "the address follower: private and missing answers"
# a_private_address_is_never_taken: not even this machine's own LAN address.
stamp last_change "$long_ago"
dns A "$L"
out=$(follow)
eq "a name pointing at a private address moves nothing" "$(turn_ip)" "$NEW"
part=$(address_part)
# the_follower_says_once_that_it_cannot_follow_on_a_split_horizon_network
has "check-host says in one line that the follower can't follow on this network" "$part" "skip  this network's DNS answers $NAME with a LAN address, so the follower can't follow a new public address on this network"
lacks "and does not say it follows" "$part" "TURN and the forwarder follow a new address"
eq "and fails nothing for it" "$(grep FAIL <<<"$part")" ""
dns A "$GONE" "$L"
out=$(follow)
has "a public address beside a private one counts for nothing either" "$out" "a private address, which counts for nothing"
# etc_hosts_and_the_hosts_own_name_never_answer
dns A NXDOMAIN
printf '%s %s\n' "$NEW2" "$NAME" >>/etc/hosts
out=$(follow)
eq "a name only /etc/hosts knows moves nothing, though that address proves" "$(turn_ip)" "$NEW"
printf '127.0.1.1 %s\n' "$NAME" >>/etc/hosts
has "check-host skips it as no answer" "$(address_part)" "skip  no answer from this machine's DNS for where $NAME points"
sed -i "/ $NAME\$/d" /etc/hosts
rm -f "$FOLLOW_STATE"
stamp last_change "$(date +%s)"

echo "the address follower: flapping"
# a_second_change_within_ten_minutes_waits
dns A "$NEW2"
out=$(follow)
eq "a second change right after the first waits" "$(turn_ip)" "$NEW"
has "and says so" "$out" "waits"
stamp last_change "$long_ago"
out=$(follow)
eq "ten minutes on it is taken" "$(turn_ip) $(peers)" "$NEW2 $NEW2 $L"

echo "the address follower: a stale address"
# The name moves to an address that cannot be proven from in here, and NEW2 stops
# answering: a router without NAT loopback.
nft delete element ip box_follow relay443 "{ $NEW2 }"
nft delete element ip box_follow turn3478 "{ $NEW2 }"
dns A "$GONE"
rm -f "$FOLLOW_STATE"
stamp last_change "$long_ago"
# A pinned handshake to its own address worked here once, so a failed one means something.
stamp loop4 yes
out=$(follow)
eq "a first stale look drops nothing" "$(turn_ip)" "$NEW2"
eq "and starts the window" "$(looks)" 1
# a_stale_address_drops_only_after_six_looks_over_half_an_hour
window 4 "$long_ago" "$GONE" "$NEW2"
out=$(follow)
eq "five looks over an hour are not enough" "$(turn_ip)" "$NEW2"
window 5 $(($(date +%s) - 600)) "$GONE" "$NEW2"
out=$(follow)
eq "six looks over ten minutes are not enough" "$(turn_ip)" "$NEW2"
# Each look that does not agree starts the window again.
window 5 "$long_ago" "$GONE" "$NEW2"
dns A "$GONE" "$FAKE"
out=$(follow)
eq "a look naming another set does not drop" "$(turn_ip) $(looks)" "$NEW2 1"
for word in NXDOMAIN SERVFAIL DROP "$L" "$NEW2"; do
    window 5 "$long_ago" "$GONE" "$NEW2"
    dns A "$word"
    out=$(follow)
    eq "a look answering $word does not drop, and empties the window" "$(turn_ip) $(looks)" "$NEW2 "
done
dns A "$GONE"
window 5 "$long_ago" "$GONE" "$NEW2"
ip addr add "$NEW2/32" dev lo
out=$(follow)
ip addr del "$NEW2/32" dev lo
eq "an old address still on an interface is kept" "$(turn_ip) $(looks)" "$NEW2 "
window 5 "$long_ago" "$GONE" "$NEW2"
nft add element ip box_follow relay443 "{ $NEW2 }"
out=$(follow)
nft delete element ip box_follow relay443 "{ $NEW2 }"
eq "an old address where this relay's key still answers is kept" "$(turn_ip) $(looks)" "$NEW2 "
has "and it says why" "$out" "this relay's key still answers there"
# no_drop_without_an_address_of_its_own_to_fall_back_on
window 5 "$long_ago" "$GONE" "$NEW2"
gw=$(ip -4 route show default | head -n 1)
ip route del default
out=$(follow)
# shellcheck disable=SC2086 # the route's words
ip route add $gw
eq "with no address of its own to fall back on nothing drops" "$(turn_ip) $(looks)" "$NEW2 "
# a_domain_behind_a_router_without_loopback_is_not_dropped_on_dns_alone
window 5 "$long_ago" "$GONE" "$NEW2"
stamp loop4 ""
out=$(follow)
eq "a domain whose own address never answered a pinned handshake from here is not dropped on DNS alone" "$(turn_ip) $(looks)" "$NEW2 "
has "and it says why" "$out" "a router without NAT loopback"
has "check-host names both addresses" "$(address_part)" "FAIL  coturn's settings ($TURN_ETC/turn.env) give $NEW2, but $NAME points at $GONE"
stamp loop4 yes
# a_full_window_drops_the_old_address_and_leaves_the_setups_answer
window 5 "$long_ago" "$GONE" "$NEW2"
out=$(follow)
printf '%s\n' "$out" | sed 's/^/  | /'
eq "six agreeing looks over half an hour drop it from coturn" "$(turn_ip)" "$L"
eq "and from the lock" "$(peers)" "$L"
eq "and from the forwarder" "$(fwd_ip)" "$L"
eq "the setup's answer stays as it was" "$(conf_ip)" "$OLD"
eq "and the follower's own key says $L" "$(follower_ip)" "$L"
sleep 2
lacks "coturn no longer lets it through" "$(coturn_cmd)" "$NEW2"
lacks "nor maps it" "$(coturn_cmd)" "--external-ip"
has "check-host names what TURN uses and where the name points" "$(address_part)" "give $L, but $NAME points at $GONE"
# a_dropped_address_is_never_taken_back_on_dns_alone
dns A "$NEW2"
stamp last_change "$long_ago"
out=$(follow)
eq "the name naming the dropped address again does not bring it back unproven" "$(turn_ip)" "$L"
dns A "$OLD"
out=$(follow)
eq "nor the setup's own answer" "$(turn_ip) $(follower_ip)" "$L $L"

echo "the address follower: DuckDNS's own answer"
# duckdns_mode_drops_only_when_duckdns_saw_this_machine_move
NAME_SAVE=$NAME
NAME=relay.duckdns.org
sed -i "s/^address=.*/address=duckdns/; s/^host=.*/host=$NAME/; s/^turn_public_ip=.*/turn_public_ip=/; s/^public_ip=.*/public_ip=$NEW2/" "$CONF_FILE"
install -d -m 0755 /run/hollow-duckdns
seen() { printf '%s\n' "$1" >/run/hollow-duckdns/seen; touch -d "@${2:-$(date +%s)}" /run/hollow-duckdns/seen; }
rm -f /run/hollow-duckdns/seen
dns A "$GONE"
# DuckDNS's own answer is the evidence beyond DNS, with or without NAT loopback.
stamp loop4 ""
systemctl reset-failed hollow-coturn
window 5 "$long_ago" "$GONE" "$NEW2"
out=$(follow)
eq "without DuckDNS's answer nothing drops, and TURN goes back to the setup's answer" "$(turn_ip) $(looks) $(follower_ip)" "$NEW2  "
for s in "$NEW2" 198.51.100.7 "$L"; do
    window 5 "$long_ago" "$GONE" "$NEW2"
    seen "$s"
    out=$(follow)
    eq "DuckDNS having seen $s does not drop it" "$(turn_ip) $(looks)" "$NEW2 "
done
window 5 "$long_ago" "$GONE" "$NEW2"
seen "$GONE" "$long_ago"
out=$(follow)
eq "an hour-old answer from DuckDNS does not drop it" "$(turn_ip) $(looks)" "$NEW2 "
window 5 "$long_ago" "$GONE" "$NEW2"
seen "$GONE"
stamp last_change "$long_ago"
out=$(follow)
eq "DuckDNS having just seen this machine at the address the name names drops it" "$(turn_ip) $(follower_ip)" "$L $L"
eq "with the setup's answer kept" "$(conf_ip)" "$NEW2"

echo "the address follower: an update after a drop"
# an_update_after_a_drop_keeps_the_setups_answer: an update's native_apply runs
# duckdns_setup, turn_apply and the forwarder's settings from install.conf. DuckDNS
# itself is faked; the timers are not started.
eval "real_$(declare -f net_get)"
# shellcheck disable=SC2329 # called by the libraries
net_get() { cat >"$WORK_DIR/duckdns-url"; printf 'OK\n%s\n\nUPDATED' "$GONE"; }
# shellcheck disable=SC2329 # called by the libraries
systemctl() { :; }
for fixed in no yes; do
    sed -i "s/^public_ip_fixed=.*/public_ip_fixed=$fixed/" "$CONF_FILE"
    conf_load
    CFG_DUCKDNS_TOKEN=a1b2c3d4-0000-1111-2222-333344445555 PF_LOCAL_IP=$L
    if [ "$fixed" = yes ]; then dns A "$NEW2"; else dns A "$GONE"; fi
    ENABLE_UNITS=() RESTART_UNITS=()
    out=$( (duckdns_setup && echo SETUP-DONE) 2>&1)
    has "public_ip_fixed=$fixed: the DuckDNS step of an update completes" "$out" "SETUP-DONE"
    eq "public_ip_fixed=$fixed: and the DuckDNS settings never hold a private address" \
        "$(ip4_class "$(kv_get "$DDNS_ETC/duckdns.env" DUCKDNS_IP)")" "$([ "$fixed" = yes ] && echo public || echo invalid)"
    lacks "public_ip_fixed=$fixed: nor does what DuckDNS is told" "$(cat "$WORK_DIR/duckdns-url")" "ip=$L"
    turn_apply >/dev/null
    eq "public_ip_fixed=$fixed: coturn's settings keep the follower's address" "$(turn_ip)" "$L"
    eq "public_ip_fixed=$fixed: the forwarder's too" "$(render_forwarder_toml | sed -n 's/^public_ip = "\(.*\)"$/\1/p')" "$L"
    CFG_MODE=docker STACK_DIR=$WORK_DIR/stack
    mkdir -p "$STACK_DIR"
    docker_env >/dev/null 2>&1
    eq "public_ip_fixed=$fixed: the Docker setup's PUBLIC_IP keeps the follower's" "$(kv_get "$STACK_DIR/.env" PUBLIC_IP)" "$L"
    lacks "public_ip_fixed=$fixed: and its DUCKDNS_IP is never private" "$(cat "$STACK_DIR/.env")" "DUCKDNS_IP=$L"
    has "public_ip_fixed=$fixed: and it keeps DuckDNS's answer in RAM for the follower" "$(cat "$STACK_DIR/.env")" "DUCKDNS_SEEN_DIR=/run/hollow-duckdns"
    CFG_MODE=native STACK_DIR=/opt/hollow-relay-docker/relay-uws
done
unset -f systemctl
eval "$(declare -f real_net_get | sed '1s/^real_//')"
duckdns_remove >/dev/null 2>&1
NAME=$NAME_SAVE
sed -i "s/^public_ip_fixed=.*/public_ip_fixed=no/; s/^address=.*/address=domain/; s/^host=.*/host=$NAME/" "$CONF_FILE"
# a_setup_address_change_clears_the_followers_address
conf_load
eq "before: the follower's address is loaded" "$CFG_TURN_PUBLIC_IP" "$L"
declare -A ANS=([public_ip]="$NEW")
ask_public_ip
conf_save >/dev/null
eq "a new answer to the address question clears the follower's" "$(follower_ip) $(conf_ip)" " $NEW"
ANS=()
sed -i "s/^public_ip_fixed=.*/public_ip_fixed=no/" "$CONF_FILE"

echo "the address follower: IPv6"
# an_ipv6_address_this_machine_holds_is_proven_and_taken
ip addr add 2001:db8:1::5/128 dev lo
CFG_PUBLIC_IP=$NEW CFG_PUBLIC_IPV6=2001:db8:1::5 CFG_PUBLIC_IP_FIXED=no CFG_TURN_PUBLIC_IP="" CFG_TURN_PUBLIC_IPV6=""
ENABLE_UNITS=() RESTART_UNITS=()
systemctl reset-failed hollow-coturn
turn_apply >/dev/null
render_forwarder_toml | put_file "$FWD_ETC/forwarder.toml" 0640 root hollow-fwd
start_units >/dev/null
systemctl restart hollow-turn-port-lock hollow-coturn
conf_save >/dev/null
dns A "$NEW"
dns AAAA NXDOMAIN
rm -f "$FOLLOW_STATE"
stamp last_change "$long_ago"
out=$(follow)
eq "an IPv6 address this machine holds stays" "$(kv_get "$TURN_ETC/turn.env" PUBLIC_IPV6)" 2001:db8:1::5
ip addr del 2001:db8:1::5/128 dev lo
ip addr add 2001:db8:1::7/128 dev lo
dns AAAA 2001:db8:1::7
out=$(follow)
eq "one the name now names and this machine holds is taken" "$(kv_get "$TURN_ETC/turn.env" PUBLIC_IPV6)" 2001:db8:1::7
has "and the lock holds it" "$(peers)" "2001:db8:1::7"
eq "beside the follower's IPv4" "$(follower_ip) $(kv_get "$CONF_FILE" turn_public_ipv6)" "$NEW 2001:db8:1::7"
eq "with the setup's answer kept" "$(kv_get "$CONF_FILE" public_ipv6)" 2001:db8:1::5
# check-host judges the name's AAAA record against the addresses this machine holds (#153).
part=$(address_part)
has "check-host passes an AAAA record this machine holds" "$part" "ok    $NAME's IPv6 (AAAA) record names 2001:db8:1::7, which this machine holds."
has "and says how to test it from outside" "$part" "curl -6 -m 10 https://$NAME/health"
# a_v6_address_this_machine_no_longer_has_drops_after_the_window
ip addr del 2001:db8:1::7/128 dev lo
# The follower still names 2001:db8:1::7 (it keeps a lost address a while); the AAAA
# cases below judge the record without that proof, then the answers come back as they were.
cp "$CONF_FILE" "$WORK_DIR/conf.keep"
sed -i 's/^turn_public_ipv6=.*/turn_public_ipv6=/' "$CONF_FILE"
# check_host_fails_an_aaaa_outside_this_machines_ipv6_network: a stale prefix.
ip addr add 2001:db8:2::9/128 dev lo
part=$(address_part)
has "check-host fails an AAAA record outside this machine's IPv6 network" "$part" "FAIL  $NAME's IPv6 (AAAA) record names 2001:db8:1::7, which is not in this machine's IPv6 network (this machine has "
has "naming the addresses it holds" "$(grep 'AAAA' <<<"$part")" "2001:db8:2::9"
has "and what to do" "$part" "People on IPv6 can't reach the relay. Update the AAAA record or remove it"
ip addr del 2001:db8:2::9/128 dev lo
# check_host_skips_an_aaaa_it_cannot_judge: only a ULA here (NPTv6), or another
# address of this machine's own /64.
ip addr add fd00::5/128 dev lo
part=$(address_part)
has "an AAAA record this machine can't judge is a skip with the outside test" "$part" "skip  $NAME's IPv6 (AAAA) record names 2001:db8:1::7, which this machine doesn't hold and couldn't prove from here, so test it from another network with curl -6 -m 10 https://$NAME/health"
lacks "and no FAIL for a ULA-only machine" "$(grep 'AAAA' <<<"$part")" "FAIL"
ip addr add 2001:db8:1::9/128 dev lo
has "so is one in this machine's own /64" "$(address_part)" "skip  $NAME's IPv6 (AAAA) record names 2001:db8:1::7, which this machine doesn't hold"
ip addr del 2001:db8:1::9/128 dev lo
ip addr del fd00::5/128 dev lo
# check_host_passes_an_aaaa_the_follower_proved: not held, beside a global address of
# another /64, but proven: the follower's own address, or the relay's key answering there.
ip addr add 2001:db8:2::9/128 dev lo
sed -i 's/^turn_public_ipv6=.*/turn_public_ipv6=2001:db8:1::7/' "$CONF_FILE"
has "check-host passes an AAAA address the follower proved" "$(address_part)" "ok    $NAME's IPv6 (AAAA) record names 2001:db8:1::7, which reaches this relay."
sed -i 's/^turn_public_ipv6=.*/turn_public_ipv6=/' "$CONF_FILE"
serve "[::1]:8443" relay
nft -f - <<EOF
table ip6 box_follow6 {
    chain out {
        type nat hook output priority -100;
        ip6 daddr 2001:db8:5::5 tcp dport 443 dnat to [::1]:8443
    }
}
EOF
ip -6 route add 2001:db8:5::5/128 dev lo
dns AAAA 2001:db8:5::5
has "and one where the relay's key answers (a translated address)" "$(address_part)" "ok    $NAME's IPv6 (AAAA) record names 2001:db8:5::5, which reaches this relay."
ip addr del 2001:db8:2::9/128 dev lo
# an_address_that_failed_duplicate_detection_is_not_held: ip lists it, nothing answers there.
real_ip=$(command -v ip)
cat >"$SHIM/ip" <<EOF
#!/bin/bash
if [ "\$*" = "-o addr show" ]; then
    $real_ip -o addr show
    echo "1: lo    inet6 2001:db8:6::6/128 scope global dadfailed tentative valid_lft forever preferred_lft forever"
    exit 0
fi
exec $real_ip "\$@"
EOF
chmod 0755 "$SHIM/ip"
dns AAAA 2001:db8:6::6
has "an address that failed duplicate detection is not held" "$(address_part)" "skip  $NAME's IPv6 (AAAA) record names 2001:db8:6::6, which this machine doesn't hold"
rm -f "$SHIM/ip"
# check_host_skips_an_aaaa_lookup_that_failed: no verdict is never "IPv4 only".
dns AAAA SERVFAIL
has "check-host skips an AAAA lookup that failed" "$(address_part)" "skip  no answer from this machine's DNS for $NAME's IPv6 (AAAA) record, so it can't be checked from here"
dns AAAA DROP
has "and one that got no answer at all" "$(address_part)" "skip  no answer from this machine's DNS for $NAME's IPv6 (AAAA) record"
dns AAAA fd00::1
has "check-host skips an AAAA answer that is not public" "$(address_part)" "skip  this network's DNS answers $NAME's IPv6 (AAAA) record with an address that is not public"
dns AAAA
has "a name without AAAA records (NODATA) serves IPv4 only" "$(address_part)" "ok    $NAME has no IPv6 (AAAA) record, so the relay serves IPv4 only, which is fine"
dns AAAA NXDOMAIN
has "check-host passes a name without an AAAA record" "$(address_part)" "ok    $NAME has no IPv6 (AAAA) record, so the relay serves IPv4 only, which is fine"
cat "$WORK_DIR/conf.keep" >"$CONF_FILE"
stamp last_change "$long_ago"
out=$(follow)
eq "one it lost stays a while" "$(kv_get "$TURN_ETC/turn.env" PUBLIC_IPV6)" 2001:db8:1::7
stamp w6_looks 5
stamp w6_start "$long_ago"
stamp w6_cur 2001:db8:1::7
out=$(follow)
eq "then goes from coturn" "$(kv_get "$TURN_ETC/turn.env" PUBLIC_IPV6)" ""
eq "and from the lock" "$(peers)" "$NEW $L"
eq "and the follower's key says so" "$(kv_get "$CONF_FILE" turn_public_ipv6)" ""
CFG_PUBLIC_IPV6=""
sed -i 's/^public_ipv6=.*/public_ipv6=/; s/^turn_public_ip=.*/turn_public_ip=/; s/^turn_public_ipv6=.*/turn_public_ipv6=/' "$CONF_FILE"

echo "the address follower: the setup's lock and its files"
# the_follower_writes_nothing_while_the_setup_runs
install -d -m 0700 /var/lib/hollow-installer
touch /var/lib/hollow-installer/setup.lock
dns A "$NEW2"
nft add element ip box_follow relay443 "{ $NEW2 }"
nft add element ip box_follow turn3478 "{ $NEW2 }"
stamp last_change "$long_ago"
python3 -I -c 'import fcntl, sys, time; f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(120)' \
    /var/lib/hollow-installer/setup.lock &
holder=$!
sleep 1
before=$(md5sum "$TURN_ETC/turn.env" "$CONF_FILE" "$LOCK_ENV" "$FWD_ETC/forwarder.toml")
out=$(follow)
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
has "while the setup holds its lock a look writes nothing" "$out" "the setup is running"
eq "and no file changed" "$(md5sum "$TURN_ETC/turn.env" "$CONF_FILE" "$LOCK_ENV" "$FWD_ETC/forwarder.toml")" "$before"
# the_follower_reads_install_conf_again_once_it_holds_the_lock
printf 'echo "# changed by the setup" >>%s\n' "$CONF_FILE" >"$SHIM/hook"
out=$(follow)
has "a setup run that changed install.conf during the look wins" "$out" "changed $CONF_FILE during this look"
eq "and the look wrote nothing" "$(turn_ip)" "$NEW"
out=$(follow)
eq "the next look takes the proven address" "$(turn_ip)" "$NEW2"
# a_run_killed_mid_rewrite_leaves_no_temporary_and_old_ones_are_swept
dns A "$NEW"
stamp last_change "$long_ago"
touch "$SHIM/kill-at-chown"
out=$(follow)
eq "a run killed between mktemp and the rename leaves no temporary" \
    "$(find "$TURN_ETC" "$RELAY_ETC" "$FWD_ETC" -name '*.follow.*' | wc -l)" 0
touch "$TURN_ETC/turn.env.follow.AbC123" "$RELAY_ETC/install.conf.follow.XyZ789"
stamp last_change "$long_ago"
out=$(follow)
eq "and the next run sweeps any a power cut left" "$(find "$TURN_ETC" "$RELAY_ETC" "$FWD_ETC" -name '*.follow.*' | wc -l)" 0
eq "and finishes the change" "$(turn_ip)" "$NEW"
# hand_edits_of_the_address_fields_are_put_back
sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=$OLD/" "$TURN_ETC/turn.env"
out=$(follow)
eq "a hand edit of coturn's address is put back" "$(turn_ip)" "$NEW"
# a_relay_that_hangs_on_loopback_stops_no_look
kill "$RELAY_PID" 2>/dev/null
sleep 1
hang_on 127.0.0.1 443
hang_pid=$LAST_PID
sleep 1
dns A "$NEW2"
stamp last_change "$long_ago"
window 5 "$long_ago" "$NEW2" "$NEW"
t0=$(date +%s)
# shellcheck disable=SC2016 # expanded by the inner shell
out=$(timeout 90 bash -c 'PATH="$1:$PATH" bash "$2" run 2>&1' _ "$SHIM" "$INSTALLER_COPY/deploy/address-follow.sh")
yes_ "a relay that accepts on 127.0.0.1:443 and never answers does not hang the look" test $(($(date +%s) - t0)) -lt 60
eq "and nothing is taken or dropped, since nothing can be judged" "$(turn_ip) $(looks)" "$NEW "
kill "$hang_pid" 2>/dev/null
sleep 1
serve 127.0.0.1:443 relay
sleep 1

echo "the address follower: restarts that do not happen"
# A systemctl that fails coturn's restart or the lock's reload on demand, or is killed
# in the middle of coturn's, after the follower renamed its settings.
REAL_SYSTEMCTL=$(command -v systemctl)
cat >"$SHIM/systemctl" <<EOF
#!/bin/bash
case " \$* " in
*"restart hollow-coturn "*)
    [ -e $SHIM/coturn-restart-fails ] && exit 1
    if [ -e $SHIM/kill-at-restart ]; then rm -f $SHIM/kill-at-restart; kill -TERM "\$PPID"; sleep 1; exit 1; fi ;;
*" try-reload-or-restart hollow-turn-port-lock.service "*)
    [ -e $SHIM/lock-reload-fails ] && exit 1 ;;
esac
exec $REAL_SYSTEMCTL "\$@"
EOF
chmod 0755 "$SHIM/systemctl"
owed() { cat /run/hollow-address/pending 2>/dev/null; }
rule_has() { nft list table inet hollow_turn | grep 'daddr {' | grep -qwF -- "$1"; }
coturn_has() { grep -qwF -- "$1" <<<"$(coturn_cmd)"; }
# a_failed_coturn_restart_keeps_the_old_peer_locked_and_retries: coturn still runs with
# the old address as an allowed peer, so the lock has to keep covering it.
systemctl reset-failed hollow-coturn
c3=$(inv hollow-coturn)
dns A "$NEW2"
rm -f "$FOLLOW_STATE"
stamp last_change "$long_ago"
touch "$SHIM/coturn-restart-fails"
out=$(follow)
rc=$?
no_ "a look whose coturn restart failed ends in failure" test "$rc" = 0
has "and says so" "$out" "coturn did not restart with the new address"
eq "coturn's settings hold the new address" "$(turn_ip)" "$NEW2"
eq "while coturn runs on, not restarted" "$(inv hollow-coturn)" "$c3"
has "with the old address" "$(coturn_cmd)" "--external-ip=$NEW/$L"
eq "so the lock keeps the old peer beside the new" "$(peers)" "$NEW2 $L $NEW"
yes_ "and so does the loaded rule" rule_has "$NEW"
eq "the restart is owed" "$(owed)" coturn
has "check-host says coturn has not restarted" "$(address_part)" "FAIL  coturn has not restarted with the follower's new address yet, so the TURN port lock keeps the old one too"
out=$(follow)
eq "a second look that still cannot restart it keeps the old peer" "$(peers) $(inv hollow-coturn)" "$NEW2 $L $NEW $c3"
rm -f "$SHIM/coturn-restart-fails"
out=$(follow)
rc=$?
eq "the next look that can restart it ends well" "$rc" 0
no_ "and restarts coturn" test "$(inv hollow-coturn)" = "$c3"
sleep 2
has "which runs on the new address" "$(coturn_cmd)" "--external-ip=$NEW2/$L"
no_ "and no longer lets the old one through" coturn_has "$NEW"
eq "only then the lock lets the old peer go" "$(peers)" "$NEW2 $L"
no_ "from the loaded rule too" rule_has "$NEW"
eq "nothing is owed" "$(owed)" ""
eq "and check-host fails nothing" "$(grep FAIL <<<"$(address_part)")" ""
# a_run_killed_before_coturn_restarts_restarts_it_on_the_next_look
systemctl reset-failed hollow-coturn
c4=$(inv hollow-coturn)
dns A "$NEW"
stamp last_change "$long_ago"
touch "$SHIM/kill-at-restart"
out=$(follow)
eq "a run killed after the rename, before the restart, leaves the new settings" "$(turn_ip) $(inv hollow-coturn)" "$NEW $c4"
eq "with the old peer still locked" "$(peers)" "$NEW $L $NEW2"
out=$(follow)
no_ "the next look restarts coturn" test "$(inv hollow-coturn)" = "$c4"
eq "and only then drops the old peer" "$(peers)" "$NEW $L"
# a_lock_that_does_not_load_keeps_coturn_where_it_was
systemctl reset-failed hollow-coturn
c5=$(inv hollow-coturn)
dns A "$NEW2"
stamp last_change "$long_ago"
touch "$SHIM/lock-reload-fails"
out=$(follow)
eq "while the lock does not load the new peers, coturn keeps its address and runs on" "$(turn_ip) $(inv hollow-coturn)" "$NEW $c5"
yes_ "the loaded rule still holds it" rule_has "$NEW"
eq "the reload is owed" "$(owed)" lock
rm -f "$SHIM/lock-reload-fails"
out=$(follow)
eq "once the lock loads, coturn moves" "$(turn_ip) $(peers)" "$NEW2 $NEW2 $L"
no_ "and restarts" test "$(inv hollow-coturn)" = "$c5"
eq "with nothing owed" "$(owed)" ""
# a_settings_file_that_cannot_be_written_keeps_the_old_peer: coturn's settings stay old,
# so coturn is owed nothing and still allows the old peer.
systemctl reset-failed hollow-coturn
c6=$(inv hollow-coturn)
dns A "$NEW"
stamp last_change "$long_ago"
touch "$SHIM/turn-env-unwritable"
out=$(follow)
rc=$?
no_ "a look that could not write coturn's settings ends in failure" test "$rc" = 0
eq "coturn keeps its settings and runs on" "$(turn_ip) $(inv hollow-coturn)" "$NEW2 $c6"
eq "and the lock keeps the old peer" "$(peers)" "$NEW $L $NEW2"
rm -f "$SHIM/turn-env-unwritable"
out=$(follow)
eq "the next look writes them and drops it" "$(turn_ip) $(peers)" "$NEW $NEW $L"
# a_coturn_our_restart_left_failed_starts_again: a restart that stopped coturn and could
# not start it leaves the unit failed once systemd stops trying (here at once), which
# try-restart alone never starts.
printf '[Service]\nRestart=no\nExecStartPre=/bin/sh -c "! test -e %s/coturn-start-fails"\n' "$SHIM" >"$UNIT_DIR/hollow-coturn.service.d/box-fail.conf"
systemctl daemon-reload
systemctl reset-failed hollow-coturn
dns A "$NEW2"
stamp last_change "$long_ago"
touch "$SHIM/coturn-start-fails"
out=$(follow)
yes_ "a restart whose start fails leaves coturn failed" systemctl is-failed --quiet hollow-coturn
eq "with the old peer still locked" "$(peers)" "$NEW2 $L $NEW"
rm -f "$SHIM/coturn-start-fails"
out=$(follow)
yes_ "the next look starts it" systemctl is-active --quiet hollow-coturn
sleep 2
yes_ "on the new address" coturn_has "$NEW2"
eq "and only then drops the old peer" "$(peers)" "$NEW2 $L"
rm -f "$UNIT_DIR/hollow-coturn.service.d/box-fail.conf"
systemctl daemon-reload
rm -f "$SHIM/systemctl"
# Back where the unit's own test starts.
systemctl reset-failed hollow-coturn
dns A "$NEW"
stamp last_change "$long_ago"
out=$(follow)
eq "and a later change goes through as before" "$(turn_ip) $(peers)" "$NEW $NEW $L"

echo "the address follower: a relay without TURN"
# a_forwarder_only_relay_moves_only_to_an_address_this_machine_holds: with no TURN secret
# to answer there, the TLS key alone (a 443 passthrough shows it too) moves nothing.
sed -i 's/^turn=.*/turn=no/' "$CONF_FILE"
f7=$(inv hollow-forwarder)
dns A "$NEW2"
stamp last_change "$long_ago"
out=$(follow)
eq "a relay without TURN does not move to an address where only its TLS key answers" "$(fwd_ip)" "$NEW"
has "and says why" "$out" "a relay without TURN takes only an address this machine holds"
eq "nor restarts the forwarder" "$(inv hollow-forwarder)" "$f7"
has "check-host names both addresses" "$(address_part)" "FAIL  the forwarder's settings ($FWD_ETC/forwarder.toml) give $NEW, but $NAME points at $NEW2. A relay without TURN moves the forwarder only to an address this machine holds"
ip addr add "$NEW2/32" dev lo
out=$(follow)
ip addr del "$NEW2/32" dev lo
eq "an address this machine holds is taken" "$(fwd_ip)" "$NEW2"
no_ "and the forwarder restarts" test "$(inv hollow-forwarder)" = "$f7"
sed -i 's/^turn=.*/turn=yes/' "$CONF_FILE"
dns A "$NEW"
stamp last_change "$long_ago"
out=$(follow)
eq "with TURN back the next proven change moves both again" "$(turn_ip) $(peers) $(fwd_ip)" "$NEW $NEW $L $NEW"

echo "the address follower: its own unit"
# the_follower_unit_follows_inside_its_sandbox
printf '[Service]\nEnvironment=PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nReadWritePaths=%s\n' "$SHIM" "$SHIM" \
    >"$UNIT_DIR/hollow-address-follow.service.d/box.conf"
systemctl daemon-reload
dns A "$NEW2"
rm -f "$FOLLOW_STATE"
: >"$SHIM/who"
# The sections above restarted coturn and the forwarder more often than systemd's start
# limit allows.
systemctl reset-failed hollow-coturn hollow-forwarder
systemctl restart hollow-coturn
c2=$(inv hollow-coturn)
# The unit's own TURN look must find coturn up, as follow() waits for it.
turn_ready
systemctl start hollow-address-follow.service
eq "the unit runs to the end in its sandbox" "$(systemctl show -p Result --value hollow-address-follow.service)" success
eq "and rewrites coturn's settings, the lock's and the forwarder's" "$(turn_ip) $(peers) $(fwd_ip)" "$NEW2 $NEW2 $L $NEW2"
eq "keeping every mode and owner" "$(modes)" "$modes_before"
no_ "and restarts coturn" test "$(inv hollow-coturn)" = "$c2"
eq "its probes ran as hollow-addr there too" "$(who_ran)" "hollow-addr curl
hollow-addr dns
hollow-addr s_client
hollow-addr turn
root turn-cred"
rm -rf "$UNIT_DIR/hollow-address-follow.service.d"
systemctl daemon-reload
has "check-host checks the follower's sandbox" "$(address_part)" "ok    hollow-address-follow runs as root in a sandbox"
mkdir -p "$UNIT_DIR/hollow-address-follow.service.d"
printf '[Service]\nNoNewPrivileges=no\n' >"$UNIT_DIR/hollow-address-follow.service.d/weak.conf"
systemctl daemon-reload
has "and fails a weakened one" "$(address_part)" "FAIL  hollow-address-follow runs as root without NoNewPrivileges=yes"
# check_host_fails_a_follower_given_another_capability
printf '[Service]\nCapabilityBoundingSet=CAP_DAC_OVERRIDE\n' >"$UNIT_DIR/hollow-address-follow.service.d/weak.conf"
systemctl daemon-reload
has "and one given a capability it does not need" "$(address_part)" "FAIL  hollow-address-follow keeps cap_dac_override, which it does not need"
rm -rf "$UNIT_DIR/hollow-address-follow.service.d"
systemctl daemon-reload
systemctl stop hollow-address-follow.timer
has "check-host fails a stopped follower" "$(address_part)" "FAIL  hollow-address-follow.timer is not running"
systemctl start hollow-address-follow.timer
sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=$OLD/" "$TURN_ETC/turn.env"
has "check-host fails coturn's settings left on an old address" "$(address_part)" "give $OLD, but $NAME points at $NEW2"
sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=$NEW2/" "$TURN_ETC/turn.env"

echo "the address follower: the Docker setup"
# the_docker_setup_follows_through_compose (with a stand-in docker; adopt_box_test.sh
# docker runs a real one under the real unit)
FD=$WORK_DIR/fake_docker
mkdir -p "$FD" "$STACK_DIR"
printf '#!/bin/sh\necho "$*" >>%s/calls\n' "$FD" >"$FD/docker"
chmod 0755 "$FD/docker"
printf 'RELAY_HOST=%s\nTURN_SECRET=%s\nPUBLIC_IP=%s\nPUBLIC_IPV6=\nLOCAL_IP=%s\nCOMPOSE_PROFILES=turn,forwarder\n' "$NAME" "$TURN_SECRET_VALUE" "$NEW2" "$L" |
    install -m 0600 /dev/stdin "$STACK_DIR/.env"
CFG_MODE=docker CFG_PUBLIC_IP=$NEW2 CFG_TURN_PUBLIC_IP="" CFG_TURN_PUBLIC_IPV6=""
conf_save >/dev/null
dns A "$NEW"
rm -f "$FOLLOW_STATE"
out=$(PATH="$FD:$SHIM:$PATH" bash "$INSTALLER_COPY/deploy/address-follow.sh" run 2>&1)
eq "the stack's settings take the new address" "$(kv_get "$STACK_DIR/.env" PUBLIC_IP)" "$NEW"
eq "the lock's too" "$(peers)" "$NEW $L"
eq "with .env still root's alone" "$(stat -c '%a %U' "$STACK_DIR/.env")" "600 root"
has "coturn and the forwarder are recreated with it" "$(cat "$FD/calls" 2>/dev/null)" "compose --project-name hollow-relay --project-directory $STACK_DIR -f $STACK_DIR/docker-compose.yml up -d --no-deps --no-build coturn forwarder"
: >"$FD/calls"
out=$(PATH="$FD:$SHIM:$PATH" bash "$INSTALLER_COPY/deploy/address-follow.sh" run 2>&1)
eq "and a second look calls nothing" "$(cat "$FD/calls")" ""
# a_failed_compose_up_keeps_the_old_peer_locked_and_retries
printf '#!/bin/sh\necho "$*" >>%s/calls\n[ ! -e %s/fails ]\n' "$FD" "$FD" >"$FD/docker"
touch "$FD/fails"
dns A "$NEW2"
stamp last_change "$long_ago"
out=$(PATH="$FD:$SHIM:$PATH" bash "$INSTALLER_COPY/deploy/address-follow.sh" run 2>&1)
eq "the stack's settings take the next address" "$(kv_get "$STACK_DIR/.env" PUBLIC_IP)" "$NEW2"
eq "but while compose fails the lock keeps the old peer" "$(peers)" "$NEW2 $L $NEW"
eq "and the restart is owed" "$(cat /run/hollow-address/pending 2>/dev/null)" compose
rm -f "$FD/fails"
: >"$FD/calls"
out=$(PATH="$FD:$SHIM:$PATH" bash "$INSTALLER_COPY/deploy/address-follow.sh" run 2>&1)
has "the next look runs compose again" "$(cat "$FD/calls")" "up -d --no-deps --no-build coturn forwarder"
eq "and only then drops the old peer" "$(peers)" "$NEW2 $L"
no_ "with nothing owed" test -e /run/hollow-address/pending
rm -rf "$DOCKER_DIR"
CFG_MODE=native

echo "the address follower: a machine with systemd-resolved"
# a_resolved_machine_is_asked_without_hosts_cache_or_synthesis: a stand-in resolvectl
# behind a stand-in resolved socket answers with what /etc/hosts or the cache would
# give unless the probe turns them off.
mkdir -p /run/systemd/resolve
background python3 -I -c '
import socket, time
s = socket.socket(socket.AF_UNIX)
s.bind("/run/systemd/resolve/io.systemd.Resolve")
time.sleep(100000)'
resolved_pid=$LAST_PID
cat >"$SHIM/resolvectl" <<EOF
#!/bin/bash
[ -e $SHIM/resolvectl-fails ] && exit 1
case " \$* " in *" --synthesize=no "*) ;; *) echo "$NAME IN A 127.0.1.1"; exit 0 ;; esac
case " \$* " in *" --cache=no "*) ;; *) echo "$NAME IN A $OLD"; exit 0 ;; esac
case " \$* " in *" --protocol=dns "*) ;; *) echo "$NAME IN A $FAKE"; exit 0 ;; esac
echo "$NAME IN CNAME other.box.test"
echo "other.box.test IN A $NEW2                 -- link: eth0"
EOF
chmod 0755 "$SHIM/resolvectl"
sleep 1
eq "it asks resolved with its cache, /etc/hosts and synthesized names off, as DNS only" \
    "$(PATH="$SHIM:$PATH" python3 -I "$DEPLOY/address-probe.py" dns "$NAME" A)" "rcode=0
$NEW2"
touch "$SHIM/resolvectl-fails"
eq "and a failed lookup there is no answer" "$(PATH="$SHIM:$PATH" python3 -I "$DEPLOY/address-probe.py" dns "$NAME" A)" "rcode=fail"
kill "$resolved_pid" 2>/dev/null
rm -f /run/systemd/resolve/io.systemd.Resolve "$SHIM/resolvectl" "$SHIM/resolvectl-fails"

echo "the address follower: who gets one"
# no_follower_for_a_bare_ip_or_a_lan_relay
w() { bash "$DEPLOY/address-follow.sh" wanted "$@"; }
yes_ "a DuckDNS name gets one" w duckdns yes yes "$NEW" no
yes_ "a domain with only the forwarder gets one" w domain no yes "$NEW" no
yes_ "an address typed in that is public gets one" w domain yes no "$NEW" yes
no_ "a bare IP address gets none" w ip yes yes "$NEW" no
no_ "a relay with neither TURN nor the forwarder gets none" w domain no no "$NEW" no
no_ "a LAN address typed in for a home-only relay gets none" w duckdns yes yes 192.168.1.20 yes
CFG_ADDRESS=ip
follow_apply >/dev/null
no_ "a bare IP relay has no timer" test -e "$UNIT_DIR/hollow-address-follow.timer"
no_ "and no service" test -e "$UNIT_DIR/hollow-address-follow.service"
CFG_ADDRESS=domain
follow_apply >/dev/null
yes_ "back to a domain, it is on again" systemctl is-active --quiet hollow-address-follow.timer

echo "the address follower: removal"
# uninstall_removes_the_follower
out=$(native_uninstall no 2>&1)
no_ "uninstall stops its timer" systemctl is-active --quiet hollow-address-follow.timer
no_ "and removes its units" test -e "$UNIT_DIR/hollow-address-follow.service"
no_ "and its account" getent passwd hollow-addr

echo ""
echo "address follower box $ID $VERSION_ID: $pass passed, $fail failed"
[ "$fail" = 0 ]
