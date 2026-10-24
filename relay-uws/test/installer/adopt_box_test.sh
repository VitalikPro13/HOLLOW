#!/bin/bash
# Taking over a relay set up by hand, under a real systemd: each scenario seeds
# one old setup the way SELF_HOSTING.md built it, then runs install.sh on it.
# Runs inside a throwaway container from run_systemd_tests.sh, never on a real
# machine: it adds accounts, units and firewall rules.
#
#   bash adopt_box_test.sh takeover|rollback|interrupted|fwdmismatch|odd|leave|docker
#
# /opt/hollow-test-relay/hollow-relay is a relay built from these sources (the
# box image builds it). Let's Encrypt is a staging-style lineage with a
# self-signed certificate, certbot a stand-in that renews nothing, and the
# media forwarder a stand-in whose id is a hash of its identity file.
# shellcheck disable=SC2034
set -uo pipefail
[ "${HOLLOW_INSTALLER_TEST_BOX:-}" = 1 ] || { echo "Runs only inside the test container (run_systemd_tests.sh)." >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Runs as root." >&2; exit 2; }

SCENARIO=${1:-takeover}
T=$(cd "$(dirname "$0")" && pwd)
RELAY=$(cd "$T/../.." && pwd)
SRC=$(cd "$RELAY/.." && pwd)
HOST=relay.box.test
BUILT=/opt/hollow-test-relay/hollow-relay
W=/root/adopt-test
mkdir -p "$W"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: missing [$3]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: should not contain [$3]"; else ok "$1"; fi; }
yes_() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
no_()  { local n=$1; shift; if "$@"; then bad "$n"; else ok "$n"; fi; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# The setup's output with its 76-column folds undone, so a phrase can be found
# wherever the screen broke its line.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
health() { curl -fsSk --max-time 3 --connect-to "$HOST:443:127.0.0.1:443" "https://$HOST/health" >/dev/null 2>&1; }
wait_health() { for _ in $(seq 1 40); do health && return 0; sleep 1; done; return 1; }
served_fp() { # [port]
    timeout 6 openssl s_client -connect "127.0.0.1:${1:-443}" -servername "$HOST" </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
}
unit_user() { systemctl show -p User --value "$1"; }
exe_of() { systemctl show -p ExecStart --value "$1" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1; }
journal_since() { journalctl -u "$1" --since "@$2" -o cat --no-pager 2>/dev/null; }
# uid_probe <uid> <address> <port>: got when a datagram sent as <uid> reaches a
# listener on <port> here, none when nothing arrives in 3 seconds.
uid_probe() {
    local out=$W/probe.$1.$3 lp
    rm -f "$out"
    python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.settimeout(3)
try:
    s.recvfrom(64)
    r = "got"
except socket.timeout:
    r = "none"
open(sys.argv[2], "w").write(r)
' "$3" "$out" &
    lp=$!
    sleep 0.5
    setpriv --reuid="$1" --regid="$1" --clear-groups python3 -I -c '
import socket, sys
socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"probe", (sys.argv[1], int(sys.argv[2])))
' "$2" "$3" 2>/dev/null
    wait "$lp"
    cat "$out" 2>/dev/null
}

. /etc/os-release
echo "box: $PRETTY_NAME, scenario $SCENARIO"

# Kernel-wide settings a privileged container shares with its host.
SAFE=$W/safe
mkdir -p "$SAFE"
for c in swapoff sysctl timedatectl; do printf '#!/bin/sh\nexit 0\n' >"$SAFE/$c"; chmod +x "$SAFE/$c"; done

# ---------------------------------------------------------------- stand-ins

# Media forwarder: mints an identity file on its first start; its id is a
# hash of that file, so the same id afterwards means the same file.
cat >/usr/local/bin/hollow-forwarder.fake <<'EOF'
#!/bin/sh
conf=/etc/hollow-forwarder.toml
print=0
while [ $# -gt 0 ]; do
    case "$1" in --config) conf=$2; shift ;; --print-peer-id) print=1 ;; esac
    shift
done
dir=$(sed -n 's/^data_dir *= *"\(.*\)"/\1/p' "$conf")
id() { printf '12D3KooW%s' "$(sha256sum "$dir/forwarder.key" | cut -c1-44 | tr 0 z)"; }
if [ "$print" = 1 ]; then
    [ -f "$dir/forwarder.key" ] || { echo "hollow-forwarder: no identity yet" >&2; exit 1; }
    id; echo; exit 0
fi
if [ ! -f "$dir/forwarder.key" ]; then
    head -c 68 /dev/urandom >"$dir/forwarder.key"; chmod 600 "$dir/forwarder.key"
    echo db >"$dir/forwarder.db"; chmod 600 "$dir/forwarder.db"
fi
echo "[HOLLOW-FWD] forwarder peer_id: $(id)" >&2
exec sleep infinity
EOF
chmod 0755 /usr/local/bin/hollow-forwarder.fake

# Node.js: only what the push sender's unit and the setup ask of it.
cat >/usr/bin/node <<'EOF'
#!/bin/sh
[ "${1:-}" = --version ] && { echo v22.11.0; exit 0; }
# Stays the process that was started, so its command line names the script.
while :; do sleep 3600; done
EOF
printf '#!/bin/sh\nexit 0\n' >/usr/bin/npm
chmod 0755 /usr/bin/node /usr/bin/npm

# certbot: the lineage exists and is not due, so nothing renews. A delete is
# recorded, since a take over must never discard the person's certificate.
mkdir -p /snap/bin
cat >/snap/bin/certbot <<'EOF'
#!/bin/sh
echo "certbot $*" >>/root/adopt-test/certbot.calls
case "$1" in
certonly) echo "Certificate not yet due for renewal; no action taken." ;;
delete) echo "DELETE $*" >>/root/adopt-test/certbot.deletes ;;
esac
exit 0
EOF
chmod 0755 /snap/bin/certbot

# ---------------------------------------------------------------- old setups

# A self-signed stand-in for the Let's Encrypt lineage the old guide made with
# certbot certonly --standalone --cert-name relay.
seed_lineage() {
    local le=/etc/letsencrypt
    mkdir -p "$le/archive/relay" "$le/live/relay" "$le/renewal" "$le/renewal-hooks/deploy"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 60 -subj "/CN=$HOST" \
        -addext "subjectAltName=DNS:$HOST" -keyout "$le/archive/relay/privkey1.pem" \
        -out "$le/archive/relay/cert1.pem" >/dev/null 2>&1
    cp "$le/archive/relay/cert1.pem" "$le/archive/relay/chain1.pem"
    cp "$le/archive/relay/cert1.pem" "$le/archive/relay/fullchain1.pem"
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
}

# The members-only keys, two for people and one for the forwarder.
seed_keys() { # seed_keys <file> <group>
    printf '{\n  "enabled": true,\n  "keys": ["AB12-CD32-BA30-LJ50", "QQ44-RT19-ZZ08-MN71", "FWDK-EY00-0000-0001"]\n}\n' >"$1"
    chown "root:$2" "$1"
    chmod 0640 "$1"
}

seed_forwarder() { # seed_forwarder <data dir>
    id hollow-fwd >/dev/null 2>&1 || useradd --system --user-group --no-create-home --shell /usr/sbin/nologin hollow-fwd
    install -m 0755 /usr/local/bin/hollow-forwarder.fake /usr/local/bin/hollow-forwarder
    install -d -m 0750 -g hollow-fwd /etc/hollow-forwarder
    printf 'relay_domain = "%s"\ndata_dir = "%s"\npublic_ip = "203.0.113.7"\nudp_port_min = 40000\nudp_port_max = 40199\n' "$HOST" "$1" \
        >/etc/hollow-forwarder/forwarder.toml
    chgrp hollow-fwd /etc/hollow-forwarder/forwarder.toml; chmod 0640 /etc/hollow-forwarder/forwarder.toml
    printf 'HOLLOW_FWD_LICENSE_KEY=FWDK-EY00-0000-0001\n' >/etc/hollow-forwarder/forwarder.env
    chmod 0600 /etc/hollow-forwarder/forwarder.env
    sed -e '/^#/d' "$RELAY/deploy/hollow-forwarder.service" >/etc/systemd/system/hollow-forwarder.service
    if [ "$1" != /var/lib/hollow-forwarder ]; then
        sed -i "s|^StateDirectory=.*|ReadWritePaths=$1|; s|^WorkingDirectory=.*|WorkingDirectory=$1|" /etc/systemd/system/hollow-forwarder.service
        install -d -m 0700 -o hollow-fwd -g hollow-fwd "$1"
    fi
    systemctl daemon-reload
    systemctl enable --now hollow-forwarder >/dev/null 2>&1
    for _ in $(seq 1 20); do [ -f "$1/forwarder.key" ] && break; sleep 0.5; done
    FWD_OLD_ID=$(runuser -u hollow-fwd -- /usr/local/bin/hollow-forwarder --config /etc/hollow-forwarder/forwarder.toml --print-peer-id)
}

# The relay unit of the 0.12 guide ("Run it as a service"), word for word but
# the address, the program's path and the forwarder's id.
relay_unit_012() { # relay_unit_012 <binary> <unit name>
    cat >"/etc/systemd/system/$2" <<EOF
[Unit]
Description=Hollow relay
After=network-online.target
Wants=network-online.target

[Service]
User=hollow
Group=hollow
ExecStart=$1 \\
    --port 443 \\
    --domain $HOST \\
    --keys-file /etc/hollow-relay/keys.json \\
    --reports-file /var/lib/hollow-relay/reports.json \\
    --cert-file /etc/hollow-relay/fullchain.pem \\
    --key-file /etc/hollow-relay/privkey.pem${FWD_OLD_ID:+ \\
    --forwarder-peer-id $FWD_OLD_ID}
EnvironmentFile=/etc/hollow-relay/relay.env
StateDirectory=hollow-relay
StateDirectoryMode=0700
WorkingDirectory=/var/lib/hollow-relay
Restart=always
RestartSec=3
LimitNOFILE=1048576
NotifyAccess=main
FileDescriptorStoreMax=1
LimitCORE=0

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateIPC=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
RemoveIPC=yes
UMask=0077
InaccessiblePaths=-/etc/letsencrypt -/etc/hollow-push

[Install]
WantedBy=multi-user.target
EOF
}

# The guide before 0.12: secrets in Environment= lines, the settings folder
# owned by the relay's own account, no sandbox.
relay_unit_011() { # relay_unit_011 <binary> <turn secret>
    cat >/etc/systemd/system/hollow-relay.service <<EOF
[Unit]
Description=Hollow relay
After=network-online.target
Wants=network-online.target

[Service]
User=hollow
ExecStart=$1 \\
    --port 443 \\
    --domain $HOST \\
    --keys-file /etc/hollow-relay/keys.json \\
    --reports-file /var/lib/hollow-relay/reports.json \\
    --cert-file /etc/hollow-relay/fullchain.pem \\
    --key-file /etc/hollow-relay/privkey.pem
Environment=TURN_SECRET=$2
AmbientCapabilities=CAP_NET_BIND_SERVICE
StateDirectory=hollow-relay
Restart=always
RestartSec=3
LimitNOFILE=1048576
NotifyAccess=main
FileDescriptorStoreMax=1
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
}

coturn_unit() { # coturn_unit <clone> <env line>
    systemctl disable --now coturn >/dev/null 2>&1 || true
    cat >/etc/systemd/system/hollow-coturn.service <<EOF
[Unit]
Description=coturn for the Hollow relay
After=network-online.target
Wants=network-online.target

[Service]
User=hollow
Group=hollow
$2
Environment=CERT_DIR=/etc/hollow-relay
RuntimeDirectory=hollow-coturn
RuntimeDirectoryMode=0700
ExecStart=/bin/sh $1/relay-uws/deploy/coturn/coturn-start.sh
Restart=always
RestartSec=3
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
}

push_unit() { # push_unit <clone>
    cat >/etc/systemd/system/hollow-push.service <<EOF
[Unit]
Description=Hollow push sender
After=network-online.target hollow-relay.service

[Service]
User=hollow-push
Group=hollow-push
WorkingDirectory=$1/push-sidecar
ExecStart=/usr/bin/node $1/push-sidecar/index.js
SyslogIdentifier=hollow-push
Environment=PUSH_PORT=3001
EnvironmentFile=/etc/hollow-push/push.env
Restart=always
RestartSec=3
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
}

# The old guide's certbot deploy hook, then its first run.
old_hook() { # old_hook <owner> <group>
    cat >/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh <<EOF
#!/bin/sh
set -eu
live=/etc/letsencrypt/live/relay
install -o $1 -g $2 -m 0644 "\$live/fullchain.pem" /etc/hollow-relay/fullchain.pem
install -o $1 -g $2 -m $( [ "$1" = root ] && echo 0640 || echo 0600 ) "\$live/privkey.pem" /etc/hollow-relay/privkey.pem
systemctl try-restart hollow-coturn || true
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
    /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
}

# Report counts the relay loads at start.
seed_reports() {
    local f=/var/lib/hollow-relay/reports.json
    printf '{"version":2,"salt_id":"","keys":[],"counts":{"12D3KooWBoxReportedPeerAAAAAAAAAAAAAAAAAAAAAAAAAA":{"spam":2},"12D3KooWBoxReportedPeerBBBBBBBBBBBBBBBBBBBBBBBBBB":{"harassment":1}}}\n' >"$f"
    chown "$(stat -c '%U:%G' "${f%/*}")" "$f"
    chmod 0600 "$f"
}

# The report key a relay before 0.13 kept beside <reports.json>. The relay
# built here erases one when it starts, so it is laid down after the start.
seed_old_report_key() {
    head -c 32 /dev/urandom >"$1.key"
    chown "$(stat -c '%U:%G' "$1")" "$1.key"
    chmod 0600 "$1.key"
}

# check-host on the result: the TURN port lock in place, no report key on the disk.
check_host_after() {
    local c part
    c=$(bash "$RELAY/deploy/check-host.sh" 2>&1)
    part=$(sed -n '/^TURN$/,/^[A-Za-z]/p' <<<"$c")
    has "check-host finds no report key on the disk" "$c" "ok    no report key on the disk beside the reports"
    eq "check-host passes every TURN check" "$(grep FAIL <<<"$part")" ""
    has "the TURN port lock is in place" "$part" "ok    on every ip address of this machine but loopback TURN reaches only ports"
    has "and loads again every minute" "$part" "ok    the TURN port lock loads again every minute"
}

# docker_turn_checks <coturn's uid>: coturn's container alone is held by the lock.
docker_turn_checks() {
    local tuid=$1 own pid
    own=$(hostname -I | awk '{ print $1 }')
    for _ in $(seq 1 30); do
        pid=$(docker inspect -f '{{.State.Pid}}' hollow-relay-coturn-1 2>/dev/null)
        [ "${pid:-0}" != 0 ] && break
        sleep 1
    done
    eq "the TURN port lock names coturn's uid" "$(sed -n 's/^TURN_USER=//p' /etc/hollow-relay/turn-port-lock.env)" "$tuid"
    eq "coturn's container runs as that uid" "$(awk '/^Uid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)" "$tuid"
    eq "which no account here has" "$(getent passwd "$tuid" | cut -d: -f1)" ""
    eq "the account here with uid 999 sends to this machine's own address freely" "$(uid_probe 999 "$own" 5399)" got
    eq "coturn's uid reaches no other port of this machine" "$(uid_probe "$tuid" "$own" 5399)" none
    eq "only TURN's" "$(uid_probe "$tuid" "$own" 50001)" got
    local fp=""
    for _ in $(seq 1 20); do fp=$(served_fp 5349); [ -n "$fp" ] && break; sleep 1; done
    eq "coturn reads its certificate and serves it on 5349" "$fp" "$CERT_FP"
    check_host_after
}

# seed_native <012|011> <clone> <relay unit name>: the old guide's hand setup.
seed_native() {
    local guide=$1 clone=$2 unit=$3 turn push
    echo "seeding the hand setup of the $guide guide in $clone ($unit)"
    mkdir -p "$clone"
    tar -C "$SRC" --exclude=relay-uws/build -cf - relay-uws push-sidecar | tar -C "$clone" -xf -
    install -D -m 0755 "$BUILT" "$clone/relay-uws/build/hollow-relay"
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin hollow
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin hollow-push
    seed_lineage
    turn=$(openssl rand -hex 32)
    push=$(openssl rand -hex 32)
    TURN_OLD=$turn PUSH_OLD=$push
    if [ "$guide" = 012 ]; then
        install -d -o root -g hollow -m 0750 /etc/hollow-relay
        old_hook root hollow
        install -m 0600 /dev/null /etc/hollow-relay/relay.env
        printf 'TURN_SECRET=%s\nHOLLOW_PUSH_TOKEN=%s\n' "$turn" "$push" >/etc/hollow-relay/relay.env
        seed_keys /etc/hollow-relay/keys.json hollow
        seed_forwarder /var/lib/hollow-forwarder
        relay_unit_012 "$clone/relay-uws/build/hollow-relay" "$unit"
        coturn_unit "$clone" "EnvironmentFile=/etc/hollow-relay/relay.env"
        install -d -m 0700 /etc/hollow-push
        install -m 0600 /dev/null /etc/hollow-push/push.env
        printf 'PUSH_TOKEN=%s\n' "$push" >/etc/hollow-push/push.env
        push_unit "$clone"
    else
        install -d -o hollow -g hollow -m 0750 /etc/hollow-relay
        old_hook hollow hollow
        seed_keys /etc/hollow-relay/keys.json hollow
        chown hollow:hollow /etc/hollow-relay/keys.json
        relay_unit_011 "$clone/relay-uws/build/hollow-relay" "$turn"
        coturn_unit "$clone" "Environment=TURN_SECRET=$turn"
        FWD_OLD_ID=""
        install -d -m 0700 /etc/hollow-push
        install -m 0600 /dev/null /etc/hollow-push/push.env
        printf 'PUSH_TOKEN=%s\n' "$push" >/etc/hollow-push/push.env
        push_unit "$clone"
    fi
    systemctl daemon-reload
    systemctl enable --now "$unit" hollow-coturn hollow-push >/dev/null 2>&1
    wait_health || { bad "the old relay did not start"; journalctl -u "$unit" -o cat --no-pager | tail -n 20; }
    seed_reports
    # A restart loads the counts, and proves the handoff works under the old unit.
    systemctl restart "$unit"
    wait_health
    seed_old_report_key /var/lib/hollow-relay/reports.json
    REPORTS_SHA=$(sha /var/lib/hollow-relay/reports.json)
    REPORTKEY_SHA=$(sha /var/lib/hollow-relay/reports.json.key)
    CERT_FP=$(served_fp)
    RENEWAL_SHA=$(sha /etc/letsencrypt/renewal/relay.conf)
    FWD_KEY_SHA=$(sha /var/lib/hollow-forwarder/forwarder.key)
    for f in /etc/systemd/system/"$unit" /etc/systemd/system/hollow-coturn.service /etc/systemd/system/hollow-push.service \
             /etc/systemd/system/hollow-forwarder.service /etc/hollow-relay/relay.env /etc/hollow-relay/keys.json \
             /etc/hollow-relay/fullchain.pem /etc/hollow-relay/privkey.pem /etc/hollow-push/push.env \
             /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh /etc/hollow-forwarder/forwarder.toml; do
        [ -f "$f" ] && echo "$(sha "$f") $(stat -c '%a %U %G' "$f") $f"
    done >"$W/before.sums"
    stat -c '%a %U %G' /etc/hollow-relay >"$W/before.etcdir"
    has "the old relay answers" "$(curl -fsSk --connect-to "$HOST:443:127.0.0.1:443" "https://$HOST/relay-status")" '"version"'
}

# The programs a take over installs, staged as a build from this copy so the
# test needs no download.
stage_programs() {
    install -d -m 0755 /usr/local/lib/hollow-relay
    install -m 0755 "$BUILT" /usr/local/bin/hollow-relay
    install -m 0755 /usr/local/bin/hollow-forwarder.fake /usr/local/bin/hollow-forwarder
    printf 'version=%s\nbuild=0\n' "$(sed -n 's/^#define HOLLOW_RELAY_VERSION "\(.*\)"/\1/p' "$RELAY/src/version.h")" \
        >/usr/local/lib/hollow-relay/VERSION
    echo source >/usr/local/lib/hollow-relay/BUILT_FROM
}

answers() { # answers <adopt> [<key=value>...]
    {
        echo "adopt=$1"
        shift
        echo "binaries=source"
        echo "public_ip=203.0.113.7"
        echo "ssh_keys=no"
        echo "confirm=yes"
        printf '%s\n' "$@"
    } >"$W/answers"
}

run_setup() {
    PATH="$SAFE:$PATH" bash "$RELAY/install.sh" --answers "$W/answers" >"$W/setup.out" 2>&1
    echo $?
}

# ---------------------------------------------------------------- checks

check_taken_over() { # check_taken_over <old unit> <since>
    local old=$1 since=$2 out
    out=$(flat "$W/setup.out")
    has "the found screen came first" "$out" "This setup did not install the relay that runs here."
    has "the take over was planned" "$out" "What take over does"
    eq "install.conf says native" "$(sed -n 's/^mode=//p' /etc/hollow-relay/install.conf)" native
    eq "the relay runs as its own account" "$(unit_user hollow-relay)" hollow-relay
    eq "from the setup's program" "$(exe_of hollow-relay)" /usr/local/bin/hollow-relay
    yes_ "and answers" health
    eq "the same certificate is served" "$(served_fp)" "$CERT_FP"
    eq "certbot's settings are untouched" "$(sha /etc/letsencrypt/renewal/relay.conf)" "$RENEWAL_SHA"
    if [ -s "$W/certbot.deletes" ]; then bad "certbot was asked to delete the certificate"; else ok "the certificate was never deleted"; fi
    has "the renewal hook is the setup's" "$(cat /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh)" "copy_pair /etc/hollow-relay hollow-relay"
    eq "the relay reads its copy through its group" "$(stat -c '%a %U %G' /etc/hollow-relay/privkey.pem)" "640 root hollow-relay"
    eq "the report counts are the same" "$(sha /var/lib/hollow-relay/reports.json)" "$REPORTS_SHA"
    eq "owned by the new account" "$(stat -c %U /var/lib/hollow-relay/reports.json)" hollow-relay
    # a_take_over_never_carries_the_report_key: the new relay erased the old
    # one in place, and the backup keeps it for a rollback.
    no_ "the old relay's report key is off the disk" test -e /var/lib/hollow-relay/reports.json.key
    has "the new relay erased it where the old one kept it" "$(journal_since hollow-relay "$since")" "Erased the report key an older relay kept on disk"
    local k
    for k in AB12-CD32-BA30-LJ50 QQ44-RT19-ZZ08-MN71 FWDK-EY00-0000-0001; do
        has "member key $k kept" "$(cat /etc/hollow-relay/keys.json)" "\"$k\""
    done
    has "members-only stays on" "$(cat /etc/hollow-relay/keys.json)" '"enabled": true'
    eq "the TURN secret is the same for the relay" "$(sed -n 's/^TURN_SECRET=//p' /etc/hollow-relay/relay.env)" "$TURN_OLD"
    eq "and for coturn" "$(sed -n 's/^TURN_SECRET=//p' /etc/hollow-turn/turn.env)" "$TURN_OLD"
    eq "coturn runs as its own account" "$(unit_user hollow-coturn)" hollow-turn
    yes_ "coturn runs" systemctl is-active --quiet hollow-coturn
    lacks "and nothing printed a secret" "$out" "$TURN_OLD"
    if [ -n "${FWD_OLD_ID:-}" ]; then
        eq "the forwarder's identity file is the same" "$(sha /var/lib/hollow-forwarder/forwarder.key)" "$FWD_KEY_SHA"
        has "the relay names the same forwarder" "$(systemctl show -p ExecStart --value hollow-relay)" "--forwarder-peer-id $FWD_OLD_ID"
        yes_ "the forwarder runs" systemctl is-active --quiet hollow-forwarder
    fi
    has "the relay took the old one's buffers across the restart" "$(journal_since hollow-relay "$since")" "[snapshot] restored"
    local bk
    bk=$(ls -d /root/hollow-relay-adopt-* 2>/dev/null | head -n 1)
    yes_ "a backup was made" test -d "$bk"
    eq "only root reads it" "$(stat -c '%a %U' "$bk")" "700 root"
    yes_ "with the old relay unit" test -f "$bk/files/etc/systemd/system/$old"
    yes_ "and the old renewal hook" test -f "$bk/files/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh"
    eq "and the old relay's report key, for a rollback" "$(sha "$bk/files/var/lib/hollow-relay/reports.json.key")" "$REPORTKEY_SHA"
    # a_take_over_with_turn_puts_the_port_lock_in_place
    eq "the TURN port lock names coturn's new account" "$(sed -n 's/^TURN_USER=//p' /etc/hollow-relay/turn-port-lock.env)" hollow-turn
    has "coturn starts only with it" "$(systemctl show -p Requires --value hollow-coturn)" hollow-turn-port-lock.service
    check_host_after
    # Running the setup again is the status screen.
    printf 'action=status\n' >"$W/answers.rerun"
    out=$(bash "$RELAY/install.sh" --answers "$W/answers.rerun" 2>&1)
    has "a re-run shows the status screen" "$out" "Hollow relay status"
    lacks "and never the take over again" "$out" "This setup did not install"
}

# ---------------------------------------------------------------- scenarios

case "$SCENARIO" in
takeover)
    echo "== the 0.12 guide's hand setup, taken over"
    seed_native 012 /opt/HOLLOW hollow-relay.service
    stage_programs
    answers takeover
    since=$(date +%s)
    rc=$(run_setup)
    eq "the setup finished" "$rc" 0
    [ "$rc" = 0 ] || tail -n 40 "$W/setup.out"
    check_taken_over hollow-relay.service "$since"
    eq "the push sender runs as its own account" "$(unit_user hollow-push)" hollow-push
    eq "from the setup's copy" "$(systemctl show -p WorkingDirectory --value hollow-push)" /opt/hollow-push
    eq "with the same token" "$(sed -n 's/^PUSH_TOKEN=//p' /etc/hollow-push/push.env)" "$PUSH_OLD"
    eq "which the relay has too" "$(sed -n 's/^HOLLOW_PUSH_TOKEN=//p' /etc/hollow-relay/relay.env)" "$PUSH_OLD"
    has "the summary names what was left" "$(flat "$W/setup.out")" "the account hollow"
    ;;

rollback)
    echo "== the guide before 0.12, taken over by a relay that does not start, then put back"
    seed_native 011 /opt/HOLLOW hollow-relay.service
    stage_programs
    printf '#!/bin/sh\nexit 1\n' >/usr/local/bin/hollow-relay
    answers takeover
    since=$(date +%s)
    rc=$(run_setup)
    no_ "the setup failed" test "$rc" = 0
    has "and said it put the old relay back" "$(flat "$W/setup.out")" "The old relay runs again, as it did before."
    yes_ "the old relay answers" wait_health
    eq "as its old account" "$(unit_user hollow-relay)" hollow
    eq "from its old program" "$(exe_of hollow-relay)" /opt/HOLLOW/relay-uws/build/hollow-relay
    has "and took its buffers back" "$(journal_since hollow-relay "$since")" "[snapshot] restored"
    eq "the same certificate" "$(served_fp)" "$CERT_FP"
    while read -r s mode owner group f; do
        eq "$f is back" "$(sha "$f") $(stat -c '%a %U %G' "$f" 2>/dev/null)" "$s $mode $owner $group"
    done <"$W/before.sums"
    eq "the settings folder has its old owner again" "$(stat -c '%a %U %G' /etc/hollow-relay)" "$(cat "$W/before.etcdir")"
    for f in /etc/hollow-relay/relay.env /etc/hollow-relay/install.conf /etc/hollow-turn /opt/hollow-push \
             /usr/local/lib/hollow-relay/installer /usr/local/sbin/hollow-relay-setup; do
        no_ "$f is gone" test -e "$f"
    done
    no_ "the account hollow-turn is gone" getent passwd hollow-turn
    no_ "and hollow-relay" getent passwd hollow-relay
    eq "coturn runs as before" "$(unit_user hollow-coturn)" hollow
    yes_ "and runs" systemctl is-active --quiet hollow-coturn
    # The processes, not only their units: each runs the old setup again.
    eq "the running relay is the old program" "$(readlink "/proc/$(systemctl show -p MainPID --value hollow-relay)/exe")" /opt/HOLLOW/relay-uws/build/hollow-relay
    eq "the running coturn is the old account's" "$(ps -o user= -p "$(systemctl show -p MainPID --value hollow-coturn)" | tr -d ' ')" hollow
    has "the running push sender is the old one" "$(tr '\0' ' ' <"/proc/$(systemctl show -p MainPID --value hollow-push)/cmdline")" /opt/HOLLOW/push-sidecar/index.js
    eq "the report counts are the same" "$(sha /var/lib/hollow-relay/reports.json)" "$REPORTS_SHA"
    # The old relay here is built from this tree, so it erased the key the
    # rollback put back as soon as it started again.
    bk=$(ls -d /root/hollow-relay-adopt-* 2>/dev/null | head -n 1)
    eq "the backup keeps the old relay's report key" "$(sha "$bk/files/var/lib/hollow-relay/reports.json.key")" "$REPORTKEY_SHA"
    # a_take_over_rollback_removes_the_port_lock_it_added
    no_ "the port lock the take over added is gone" test -e /etc/systemd/system/hollow-turn-port-lock.service
    no_ "with its rule" nft list table inet hollow_turn
    no_ "and its program" test -e /usr/local/sbin/hollow-turn-port-lock
    # A second run finds the same relay and offers the take over again.
    answers leave harden=none
    rc=$(run_setup)
    has "a second run finds it again" "$(flat "$W/setup.out")" "This setup did not install the relay that runs here."
    ;;

interrupted)
    echo "== the 0.12 guide's hand setup, its take over killed once the relay's unit was rewritten, then put back"
    seed_native 012 /opt/HOLLOW hollow-relay.service
    stage_programs
    answers takeover
    since=$(date +%s)
    # setsid: its own process group, so one SIGKILL takes the whole run and no exit trap runs.
    PATH="$SAFE:$PATH" setsid bash "$RELAY/install.sh" --answers "$W/answers" >"$W/setup.out" 2>&1 &
    run=$!
    for _ in $(seq 1 600); do
        head -n 1 /etc/systemd/system/hollow-relay.service 2>/dev/null | grep -q '^# Written by install.sh' && break
        sleep 0.2
    done
    kill -9 -- "-$run" 2>/dev/null
    wait "$run" 2>/dev/null
    yes_ "the run was killed after the unit was rewritten" sh -c 'head -n 1 /etc/systemd/system/hollow-relay.service | grep -q "^# Written by install.sh"'
    bk=$(ls -d /root/hollow-relay-adopt-* 2>/dev/null | head -n 1)
    yes_ "its backup says it is still running" test -f "$bk/running"
    answers takeover interrupted=rollback
    rc=$(run_setup)
    eq "the next run finished" "$rc" 0
    out=$(flat "$W/setup.out")
    has "it found the take over that did not finish" "$out" "A take over did not finish"
    lacks "and never started a new install over it" "$out" "Ready to set up"
    lacks "nor a second take over" "$out" "Ready to take over"
    has "it put the old relay back" "$out" "The old relay runs again, as it did before."
    yes_ "the old relay answers" wait_health
    eq "as its old account" "$(unit_user hollow-relay)" hollow
    eq "from its old program" "$(exe_of hollow-relay)" /opt/HOLLOW/relay-uws/build/hollow-relay
    while read -r s mode owner group f; do
        eq "$f is back" "$(sha "$f") $(stat -c '%a %U %G' "$f" 2>/dev/null)" "$s $mode $owner $group"
    done <"$W/before.sums"
    no_ "install.conf is gone" test -e /etc/hollow-relay/install.conf
    no_ "the backup no longer says running" test -e "$bk/running"
    answers leave harden=none
    rc=$(run_setup)
    has "a third run finds the old relay again" "$(flat "$W/setup.out")" "This setup did not install the relay that runs here."
    ;;

fwdmismatch)
    echo "== the 0.12 guide's hand setup, taken over by a forwarder that comes up with another id"
    seed_native 012 /opt/HOLLOW hollow-relay.service
    stage_programs
    # The new forwarder program reads the same identity file and names another id.
    sed -i 's/cut -c1-44/cut -c2-45/' /usr/local/bin/hollow-forwarder
    answers takeover
    since=$(date +%s)
    rc=$(run_setup)
    no_ "the setup failed" test "$rc" = 0
    has "on the forwarder's id" "$(flat "$W/setup.out")" "the forwarder came up as"
    has "and put the old relay back" "$(flat "$W/setup.out")" "The old relay runs again, as it did before."
    # It stopped before the relay changed, so the relay never restarted.
    lacks "the relay never restarted" "$(journal_since hollow-relay "$since")" "[snapshot] handed"
    eq "it still runs as its old account" "$(unit_user hollow-relay)" hollow
    yes_ "and answers" health
    eq "the forwarder's identity is the same" "$(sha /var/lib/hollow-forwarder/forwarder.key)" "$FWD_KEY_SHA"
    yes_ "and the old forwarder runs again" systemctl is-active --quiet hollow-forwarder
    eq "the relay still names it" "$(systemctl show -p ExecStart --value hollow-relay | grep -o -- "--forwarder-peer-id [^ ]*" | cut -d' ' -f2)" "$FWD_OLD_ID"
    ;;

odd)
    echo "== a hand setup with its own names: another clone path, another unit name, coturn stopped, no push"
    seed_native 012 /srv/hollow-src hollow.service
    # The report counts in a folder of its own choosing.
    install -d -m 0700 -o hollow -g hollow /srv/hollow-data
    mv /var/lib/hollow-relay/reports.json /var/lib/hollow-relay/reports.json.key /srv/hollow-data/
    sed -i 's|--reports-file /var/lib/hollow-relay/reports.json|--reports-file /srv/hollow-data/reports.json|; s|^ProtectSystem=strict|ProtectSystem=strict\nReadWritePaths=/srv/hollow-data|' \
        /etc/systemd/system/hollow.service
    systemctl disable --now hollow-push >/dev/null 2>&1; rm -f /etc/systemd/system/hollow-push.service
    systemctl stop hollow-coturn
    systemctl daemon-reload
    systemctl restart hollow.service
    wait_health || bad "the old relay did not come back with its reports elsewhere"
    seed_old_report_key /srv/hollow-data/reports.json
    REPORTKEY_SHA=$(sha /srv/hollow-data/reports.json.key)
    stage_programs
    answers takeover
    since=$(date +%s)
    rc=$(run_setup)
    eq "the setup finished" "$rc" 0
    [ "$rc" = 0 ] || tail -n 40 "$W/setup.out"
    eq "the report counts came along" "$(sha /var/lib/hollow-relay/reports.json)" "$REPORTS_SHA"
    eq "the old folder keeps its copy" "$(sha /srv/hollow-data/reports.json.key)" "$REPORTKEY_SHA"
    has "it said the buffers would not carry" "$(flat "$W/setup.out")" "Its service gets a new name"
    has "and that the old unit stops" "$(flat "$W/setup.out")" "stay off: hollow.service"
    eq "the old unit is off" "$(systemctl is-active hollow.service)" inactive
    eq "and stays off on boot" "$(systemctl is-enabled hollow.service 2>/dev/null)" disabled
    eq "the relay runs as its own account" "$(unit_user hollow-relay)" hollow-relay
    yes_ "and answers" health
    eq "the same certificate" "$(served_fp)" "$CERT_FP"
    no_ "the report key was never copied" test -e /var/lib/hollow-relay/reports.json.key
    lacks "so the new relay found none to erase" "$(journal_since hollow-relay "$since")" "Erased the report key"
    eq "the forwarder's identity is the same" "$(sha /var/lib/hollow-forwarder/forwarder.key)" "$FWD_KEY_SHA"
    no_ "no push sender was added" test -e /etc/systemd/system/hollow-push.service
    yes_ "TURN runs again" systemctl is-active --quiet hollow-coturn
    check_host_after
    has "the summary names the old program" "$(flat "$W/setup.out")" "/srv/hollow-src/relay-uws/build/hollow-relay, the old relay program"
    ;;

leave)
    echo "== a hand setup left alone, the machine hardened without the firewall, then with it"
    seed_native 012 /opt/HOLLOW hollow-relay.service
    # Another program on a port the relay's firewall would close.
    systemd-run --unit=box-other --quiet python3 -m http.server 8088 --bind 0.0.0.0
    sleep 1
    answers leave harden=nofw
    rc=$(run_setup)
    eq "the setup finished" "$rc" 0
    out=$(flat "$W/setup.out")
    has "the machine was described" "$out" "How this machine is set up"
    has "the other program was named" "$out" "python3 on 8088/tcp"
    has "and why the firewall is best left out" "$out" "so we recommend leaving it out"
    has "it ended with the checks" "$out" "Nothing about the relay changed."
    while read -r s mode owner group f; do
        eq "$f is unchanged" "$(sha "$f") $(stat -c '%a %U %G' "$f" 2>/dev/null)" "$s $mode $owner $group"
    done <"$W/before.sums"
    no_ "no install.conf" test -e /etc/hollow-relay/install.conf
    yes_ "core dumps are off" test -f /etc/sysctl.d/90-hollow-relay.conf
    yes_ "the journal is in memory" test -f /etc/systemd/journald.conf.d/hollow-privacy.conf
    lacks "the firewall stayed off" "$(ufw status)" "Status: active"
    eq "the relay still runs as before" "$(unit_user hollow-relay)" hollow
    yes_ "and answers" health
    answers leave harden=all
    rc=$(run_setup)
    eq "the second run finished" "$rc" 0
    has "now the firewall is on" "$(ufw status)" "Status: active"
    has "with the relay's port" "$(ufw status)" "443/tcp"
    has "and port 80 for its renewal" "$(ufw status)" "80/tcp"
    has "and TURN" "$(ufw status)" "3478/udp"
    has "and the forwarder" "$(ufw status)" "40000:40199/udp"
    yes_ "the relay still answers" health
    ;;

docker|docker-rollback)
    echo "== a plain docker compose up from the 0.12.2 compose file, taken over$( [ "$SCENARIO" = docker-rollback ] && echo " by containers that do not start, then put back")"
    have_docker() { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; }
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    have_docker || { echo "skip  no Docker with compose in this box"; exit 0; }
    clone=/home/op/HOLLOW
    mkdir -p "$clone"
    tar -C "$SRC" --exclude=relay-uws/build -cf - relay-uws push-sidecar | tar -C "$clone" -xf -
    cp "$T/fixtures/docker-compose.0.12.2.yml" "$clone/relay-uws/docker-compose.yml"
    # Its own certificate, which the app would trust: this box trusts it.
    mkdir -p /srv/relay-certs
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 60 -subj "/CN=$HOST" \
        -addext "subjectAltName=DNS:$HOST" -keyout /srv/relay-certs/privkey.pem -out /srv/relay-certs/fullchain.pem >/dev/null 2>&1
    cp /srv/relay-certs/fullchain.pem /usr/local/share/ca-certificates/relay-box.crt
    update-ca-certificates >/dev/null 2>&1
    TURN_OLD=$(openssl rand -hex 32)
    cat >"$clone/relay-uws/.env" <<EOF
RELAY_HOST=$HOST
DUCKDNS_TOKEN=
TURN_SECRET=$TURN_OLD
CERTBOT_EMAIL=
COMPOSE_PROFILES=turn
PUBLIC_IP=
PUBLIC_IPV6=
OWN_CERT_DIR=/srv/relay-certs
SESSION_GRACE_SECS=150
HOLLOW_CONN_RATE_EXEMPT=
CERTBOT_STAGING=
EOF
    # A host account with uid 999, the first one Debian and Ubuntu hand a system account.
    getent passwd 999 >/dev/null || useradd --system --uid 999 --no-create-home --shell /usr/sbin/nologin box999
    mkdir -p "$clone/relay-uws/keys"
    printf '{\n  "enabled": true,\n  "keys": ["AB12-CD32-BA30-LJ50", "QQ44-RT19-ZZ08-MN71"]\n}\n' >"$clone/relay-uws/keys/keys.json"
    echo "building and starting the old stack (a few minutes)"
    (cd "$clone/relay-uws" && docker compose up -d >"$W/old-up.log" 2>&1) || { bad "the old stack did not start"; tail -n 30 "$W/old-up.log"; }
    wait_health || { sleep 30; wait_health; } || bad "the old relay did not answer"
    data=$(docker volume inspect -f '{{.Mountpoint}}' relay-uws_data)
    printf '{"version":2,"salt_id":"","keys":[],"counts":{"12D3KooWBoxReportedPeerAAAAAAAAAAAAAAAAAAAAAAAAAA":{"spam":2}}}\n' >"$data/reports.json"
    chown 999:999 "$data/reports.json"
    (cd "$clone/relay-uws" && docker compose restart relay >/dev/null 2>&1)
    wait_health
    seed_old_report_key "$data/reports.json"
    REPORTKEY_SHA=$(sha "$data/reports.json.key")
    REPORTS_SHA=$(sha "$data/reports.json")
    CERT_FP=$(served_fp)
    ENV_SHA=$(sha "$clone/relay-uws/.env")
    has "the old relay answers" "$(curl -fsS --connect-to "$HOST:443:127.0.0.1:443" "https://$HOST/relay-status")" '"turn":true'
    if [ "$SCENARIO" = docker-rollback ]; then
        # The new relay listens where nothing is mapped, so it never answers.
        sed -i '0,/- "443"$/s//- "444"/' "$RELAY/docker-compose.yml"
    fi
    answers takeover
    rc=$(run_setup)
    out=$(flat "$W/setup.out")
    has "the found screen named the containers" "$out" "Docker containers from $clone/relay-uws"
    has "it said what Docker loses" "$out" "Docker cannot carry what is in the relay's memory"
    if [ "$SCENARIO" = docker ]; then
        eq "the setup finished" "$rc" 0
        [ "$rc" = 0 ] || tail -n 40 "$W/setup.out"
        eq "install.conf says docker" "$(sed -n 's/^mode=//p' /etc/hollow-relay/install.conf)" docker
        eq "the new relay runs" "$(docker inspect -f '{{.State.Status}}' hollow-relay-relay-1 2>/dev/null)" running
        eq "the old one is stopped" "$(docker inspect -f '{{.State.Status}}' relay-uws-relay-1 2>/dev/null)" exited
        yes_ "the relay answers" health
        eq "with the same certificate" "$(served_fp)" "$CERT_FP"
        newdata=$(docker volume inspect -f '{{.Mountpoint}}' hollow-relay_data)
        eq "the counts went along" "$(sha "$newdata/reports.json")" "$REPORTS_SHA"
        no_ "never their key" test -e "$newdata/reports.json.key"
        eq "the old volume keeps its key" "$(sha "$data/reports.json.key")" "$REPORTKEY_SHA"
        eq "the new volume is the relay's to write" "$(stat -c '%u %a' "$newdata")" "$(stat -c '%u %a' "$data")"
        # a_docker_take_over_with_turn_puts_the_port_lock_in_place
        # docker_coturn_runs_as_a_uid_no_host_account_has
        tuid=$(sed -n 's/^TURN_UID=//p' "$RELAY/deploy/certbot/lib.sh")
        docker_turn_checks "$tuid"
        no_ "with no drop-in under Docker" test -e /etc/systemd/system/hollow-coturn.service.d/hollow-port-lock.conf
        has "the lock starts before Docker" "$(systemctl show -p Before --value hollow-turn-port-lock)" docker.service
        check_host_after
        eq "the old .env is unchanged" "$(sha "$clone/relay-uws/.env")" "$ENV_SHA"
        env=/opt/hollow-relay-docker/relay-uws/.env
        eq "the TURN secret went along" "$(sed -n 's/^TURN_SECRET=//p' "$env")" "$TURN_OLD"
        eq "the own certificate's folder too" "$(sed -n 's/^OWN_CERT_DIR=//p' "$env")" /srv/relay-certs
        eq "and the wait for dropped connections" "$(sed -n 's/^SESSION_GRACE_SECS=//p' "$env")" 150
        eq "the new .env is root's alone" "$(stat -c '%a %U' "$env")" "600 root"
        for k in AB12-CD32-BA30-LJ50 QQ44-RT19-ZZ08-MN71; do
            has "member key $k kept" "$(cat /opt/hollow-relay-docker/relay-uws/keys/keys.json)" "\"$k\""
        done
        has "TURN runs" "$(docker ps --format '{{.Names}}')" hollow-relay-coturn-1
        lacks "no secret was printed" "$out" "$TURN_OLD"
        printf 'action=status\n' >"$W/answers.rerun"
        out=$(bash "$RELAY/install.sh" --answers "$W/answers.rerun" 2>&1)
        has "a re-run shows the status screen" "$out" "Setup: Docker"
        # an_older_docker_setup_moves_coturn_to_its_own_uid: the setup before
        # ran coturn as 999 off the relay's certificate, and the lock on 999.
        echo "-- a Docker setup from before coturn had its own uid, rebuilt"
        stack=/opt/hollow-relay-docker/relay-uws
        sed -i "s/^    user: \"$tuid:$tuid\"\$/    user: \"999:999\"/; s|CERT_DIR=/certs/turn\$|CERT_DIR=/certs|" "$stack/docker-compose.yml"
        rm -rf "$(docker volume inspect -f '{{.Mountpoint}}' hollow-relay_certs)/turn"
        sed -i 's/^TURN_USER=.*/TURN_USER=999/' /etc/hollow-relay/turn-port-lock.env
        systemctl restart hollow-turn-port-lock
        docker compose --project-name hollow-relay --project-directory "$stack" -f "$stack/docker-compose.yml" up -d --no-deps coturn >/dev/null 2>&1
        sleep 3
        pid=$(docker inspect -f '{{.State.Pid}}' hollow-relay-coturn-1 2>/dev/null)
        eq "the old setup ran coturn as 999" "$(awk '/^Uid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)" 999
        eq "and held the account with that uid here" "$(uid_probe 999 "$(hostname -I | awk '{ print $1 }')" 5399)" none
        printf 'action=rebuild\nconfirm=yes\n' >"$W/answers.rebuild"
        PATH="$SAFE:$PATH" bash "$RELAY/install.sh" --answers "$W/answers.rebuild" >"$W/rebuild.out" 2>&1
        rc=$?
        eq "the rebuild finished" "$rc" 0
        [ "$rc" = 0 ] || tail -n 40 "$W/rebuild.out"
        eq "with coturn's own uid in the compose file" "$(grep -c "^    user: \"$tuid:$tuid\"\$" "$stack/docker-compose.yml")" 1
        docker_turn_checks "$tuid"
        yes_ "the relay answers" health
        # docker_coturn_serves_a_renewed_certificate: renew-loop.sh's copy lands
        # in coturn's own folder, and coturn serves it within two of its looks
        # (CERT_WATCH_SECS=30) with no restart.
        echo "-- a renewed certificate"
        turn_pid=$(docker inspect -f '{{.State.Pid}}' hollow-relay-coturn-1 2>/dev/null)
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 6 -subj "/CN=$HOST" \
            -addext "subjectAltName=DNS:$HOST" -keyout /srv/relay-certs/privkey.pem.new \
            -out /srv/relay-certs/fullchain.pem.new >/dev/null 2>&1
        mv /srv/relay-certs/privkey.pem.new /srv/relay-certs/privkey.pem
        mv /srv/relay-certs/fullchain.pem.new /srv/relay-certs/fullchain.pem
        new_fp=$(openssl x509 -noout -fingerprint -sha256 -in /srv/relay-certs/fullchain.pem | sed 's/.*=//')
        no_ "the renewal is a new certificate" test "$new_fp" = "$CERT_FP"
        yes_ "the renewal loop copies it" docker exec hollow-relay-certbot-renew-1 sh -c '. /hooks/lib.sh && install_own_certs'
        renewed=$(date +%s)
        fp=""
        for _ in $(seq 1 30); do fp=$(served_fp 5349); [ "$fp" = "$new_fp" ] && break; sleep 3; done
        eq "coturn serves the renewed certificate on 5349" "$fp" "$new_fp"
        yes_ "within 75 seconds" test $(($(date +%s) - renewed)) -le 75
        eq "without a restart" "$(docker inspect -f '{{.State.Pid}} {{.RestartCount}}' hollow-relay-coturn-1 2>/dev/null)" "$turn_pid 0"
        check_host_after
    else
        no_ "the setup failed" test "$rc" = 0
        has "and said it put the old relay back" "$out" "The old relay runs again, as it did before."
        eq "the old relay runs again" "$(docker inspect -f '{{.State.Status}}' relay-uws-relay-1 2>/dev/null)" running
        yes_ "and answers" wait_health
        no_ "the new containers are gone" docker inspect hollow-relay-relay-1
        no_ "and their volumes" docker volume inspect hollow-relay_data
        no_ "install.conf is gone" test -e /etc/hollow-relay/install.conf
        no_ "the setup's folder is gone" test -e /opt/hollow-relay-docker
        # The old relay here is built from this tree: started again, it erased
        # the key a relay before 0.13 left, and kept the counts.
        eq "the old volume keeps its counts" "$(sha "$data/reports.json")" "$REPORTS_SHA"
        no_ "the port lock the take over added is gone" test -e /etc/systemd/system/hollow-turn-port-lock.service
        no_ "with its rule" nft list table inet hollow_turn
    fi
    ;;

*) echo "unknown scenario $SCENARIO" >&2; exit 2 ;;
esac

echo ""
echo "adopt box $SCENARIO on $ID $VERSION_ID: $pass passed, $fail failed"
[ "$fail" = 0 ]
