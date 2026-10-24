#!/bin/bash
# The installer's units and root-only steps under a real systemd, inside the
# throwaway container run_systemd_tests.sh starts: coturn's address mapping,
# the push sender's resolver, SSH ports through ufw, fail2ban, the build
# account's outputs, backups through links, check-host's new checks, and the
# SSH steps against a real sshd: the setup's own key login and adding a key.
# Never on a real machine: it adds accounts, units and firewall rules.
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
trap 'rm -rf "$WORK_DIR"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: missing [$3]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: should not contain [$3]"; else ok "$1"; fi; }
yes_() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
no_()  { local n=$1; shift; if "$@"; then bad "$n"; else ok "$n"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }

for f in common ui preflight address ssh_keys native docker manage host questions adopt; do
    # shellcheck source=/dev/null
    . "$DEPLOY/lib/$f.sh"
done
shopt -s lastpipe
# shellcheck disable=SC2317 # called by the libraries
die() { printf 'DIE %s\n' "$*"; exit 99; }
DRY_RUN=0 UI_MODE=answers
ENABLE_UNITS=() RESTART_UNITS=()
. /etc/os-release
echo "box: $PRETTY_NAME"

# Kernel-wide settings a privileged container shares with its host: harden-host
# would turn the host's swap off and set its core pattern.
SAFE=$WORK_DIR/safe
mkdir -p "$SAFE"
for c in swapoff sysctl timedatectl; do printf '#!/bin/sh\nexit 0\n' >"$SAFE/$c"; chmod +x "$SAFE/$c"; done

echo "installer copy"
install_installer_copy
has "the installed install.sh can run" "$(stat -c %a "$INSTALLER_COPY/install.sh")" 755
yes_ "sudo hollow-relay-setup is a command" hollow-relay-setup --help

echo "ssh ports"
if [ "$ID" = ubuntu ]; then
    SSH_TEST_PORT=2222
    systemctl disable --now ssh.service >/dev/null 2>&1
    mkdir -p /etc/systemd/system/ssh.socket.d
    # Ubuntu's socket is BindIPv6Only=ipv6-only, so both families are named.
    printf '[Socket]\nListenStream=\nListenStream=0.0.0.0:%s\nListenStream=[::]:%s\n' "$SSH_TEST_PORT" "$SSH_TEST_PORT" \
        >/etc/systemd/system/ssh.socket.d/listen.conf
    systemctl daemon-reload
    systemctl enable ssh.socket >/dev/null 2>&1
    systemctl restart ssh.socket
else
    SSH_TEST_PORT=2200
    printf 'ListenAddress 0.0.0.0:%s\n' "$SSH_TEST_PORT" >/etc/ssh/sshd_config.d/00-box.conf
    systemctl restart ssh
fi
sleep 1
echo "$SSH_TEST_PORT" >/root/ssh_test_port
has "the port list holds the port SSH listens on" " $(hollow_ssh_ports) " " $SSH_TEST_PORT "
out=$(PATH="$SAFE:$PATH" sh "$DEPLOY/harden-host.sh" --http no --turn yes --forwarder no --no-ssh 2>&1)
has "ufw lets that port in" "$(ufw status)" "$SSH_TEST_PORT/tcp"
has "ufw is on" "$(ufw status)" "Status: active"

echo "daily security updates"
dump=$(apt-config dump)
has "apt's daily job fetches the lists" "$dump" 'APT::Periodic::Update-Package-Lists "1";'
has "and installs the updates" "$dump" 'APT::Periodic::Unattended-Upgrade "1";'
if [ "$ID" = debian ]; then
    has "from the security archive" "$(apt-config dump Unattended-Upgrade::Origins-Pattern)" "label=Debian-Security"
else
    has "from the security archive" "$(apt-config dump Unattended-Upgrade::Allowed-Origins)" '${distro_codename}-security'
fi
has "check-host passes them" "$(bash "$DEPLOY/check-host.sh" 2>&1)" "ok    unattended-upgrades installs security updates every day"
printf 'APT::Periodic::Unattended-Upgrade "0";\n' >/etc/apt/apt.conf.d/99box-off
has "check-host fails them switched off" "$(bash "$DEPLOY/check-host.sh" 2>&1)" "FAIL  unattended-upgrades is installed but apt never runs it"
out=$(PATH="$SAFE:$PATH" sh "$DEPLOY/harden-host.sh" --http no --turn yes --forwarder no --no-ssh 2>&1)
has "a second hardening says they are off" "$out" "switched OFF in apt's settings"
has "and leaves the 0 as it is" "$(apt-config dump)" 'APT::Periodic::Unattended-Upgrade "0";'
rm -f /etc/apt/apt.conf.d/99box-off
printf 'Unattended-Upgrade::Origins-Pattern {\n    "site=deb.nodesource.com";\n};\n' >/etc/apt/apt.conf.d/52hollow-nodesource
if [ "$ID" = debian ]; then
    has "the NodeSource origin adds to the distro's" "$(apt-config dump Unattended-Upgrade::Origins-Pattern)" "label=Debian-Security"
fi
has "and is there itself" "$(apt-config dump Unattended-Upgrade::Origins-Pattern)" "site=deb.nodesource.com"
rm -f /etc/apt/apt.conf.d/52hollow-nodesource

echo "fail2ban"
yes_ "fail2ban answers" sh -c 'fail2ban-client ping | grep -q pong'
yes_ "the sshd jail runs" fail2ban-client status sshd
has "harden-host says it runs" "$out" "fail2ban watching SSH logins on port"
has "the jail watches the SSH port" "$(fail2ban-client get sshd journalmatch 2>/dev/null; cat /etc/fail2ban/jail.d/hollow-relay.local)" "$SSH_TEST_PORT"

echo "rsyslog"
if [ -f /etc/rsyslog.d/00-hollow-privacy.conf ] && systemctl is-active --quiet rsyslog; then
    probe="box-$$-$RANDOM"
    systemd-cat -t hollow-relay echo "tagged $probe"
    systemd-cat -t box-other echo "plain $probe"
    sleep 3
    lacks "a hollow- journal line stays off the disk" "$(cat /var/log/syslog 2>/dev/null)" "tagged $probe"
    has "while other lines reach syslog" "$(cat /var/log/syslog 2>/dev/null)" "plain $probe"
else
    echo "skip  rsyslog is not running here"
fi

echo "coturn under its unit"
ensure_account hollow-relay
ensure_dir "$RELAY_ETC" 0750 root hollow-relay
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=box \
    -keyout "$RELAY_ETC/privkey.pem" -out "$RELAY_ETC/fullchain.pem" >/dev/null 2>&1
CFG_TURN=yes CFG_PUBLIC_IP=203.0.113.7 CFG_PUBLIC_IPV6="" TURN_SECRET_VALUE=$(gen_hex 32)
PF_LOCAL_IP=$(local_ipv4)
echo "  this box's own address: $PF_LOCAL_IP"
turn_apply >/dev/null
start_units >/dev/null
systemctl restart hollow-coturn
sleep 3
pid=$(systemctl show -p MainPID --value hollow-coturn)
cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
has "coturn runs as its own account" "$(ps -o user= -p "$pid" 2>/dev/null)" hollow-turn
has "coturn maps the public address to this box's own" "$cmd" "--external-ip=203.0.113.7/$PF_LOCAL_IP"
has "and lets the box's own address back through the peer lock" "$cmd" "--allowed-peer-ip=$PF_LOCAL_IP"

echo "push sender's resolver"
ensure_account hollow-push
ensure_dir "$PUSH_DIR" 0755 root root
ensure_dir "$PUSH_ETC" 0700 root root
printf 'PUSH_TOKEN=%s\n' "$(gen_hex 32)" | put_file "$PUSH_ETC/push.env" 0600 root root
render_push_unit "$REPO/push-sidecar/hollow-push.service" | put_unit hollow-push.service
grep '^nameserver' /etc/resolv.conf | sed 's/^/  resolv.conf: /'
mkdir -p "$UNIT_DIR/hollow-push.service.d"
# Same unit, sandbox and address wall; only the program is a name lookup.
printf '[Service]\nType=oneshot\nRestart=no\nExecStart=\nExecStart=/usr/bin/getent ahostsv4 ntfy.sh\n' \
    >"$UNIT_DIR/hollow-push.service.d/box-probe.conf"
systemctl daemon-reload
if [ -n "$(resolver_allow)" ]; then
    yes_ "the push unit looks names up through a private resolver" systemctl start hollow-push
else
    echo "skip  resolv.conf has no private nameserver here"
fi
check=$(bash "$DEPLOY/check-host.sh" 2>&1)
has "check-host sees the push sender's lookups work" "$check" "ok    the push sender can look up names through its address wall"
has "check-host checks fail2ban" "$check" "ok    fail2ban is running and watches SSH logins"
has "check-host passes coturn's peer lock" "$check" "ok    TURN relays only to this host"
# The same checks, each made to fail once.
if [ -n "$(resolver_allow)" ]; then
    RESOLV_CONF=/dev/null render_push_unit "$REPO/push-sidecar/hollow-push.service" | put_unit hollow-push.service
    systemctl daemon-reload
    has "check-host fails a wall that blocks the resolver" "$(bash "$DEPLOY/check-host.sh" 2>&1)" "FAIL  the push sender cannot look up names"
fi
systemctl stop fail2ban
has "check-host fails a stopped fail2ban" "$(bash "$DEPLOY/check-host.sh" 2>&1)" "FAIL  fail2ban is not running"
systemctl start fail2ban
rm -rf "$UNIT_DIR/hollow-push.service.d"
systemctl daemon-reload

echo "the TURN port lock"
# udp_probe <account> <address> <port>: got when a datagram sent as <account>
# reaches a listener on <port> here, none when nothing arrives in 3 seconds.
udp_probe() {
    local out=$WORK_DIR/probe.$3 lp
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
    setpriv --reuid="$1" --regid="$1" --init-groups python3 -I -c '
import socket, sys
socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"probe", (sys.argv[1], int(sys.argv[2])))
' "$2" "$3" 2>/dev/null
    wait "$lp"
    cat "$out" 2>/dev/null
}
turn_part() { bash "$DEPLOY/check-host.sh" 2>&1 | sed -n '/^TURN$/,/^[A-Za-z]/p'; }
reserved() { sysctl -n net.ipv4.ip_local_reserved_ports; }
part=$(turn_part)
eq "check-host passes every TURN check" "$(grep FAIL <<<"$part")" ""
has "the lock runs before any nat rule" "$part" "ok    the port lock sees where coturn sends before any nat rule rewrites it"
has "on every address of this box" "$part" "ok    on every ip address of this machine but loopback TURN reaches only ports 49152-65535"
has "and on the public address coturn allows back" "$part" "203.0.113.7 only on ports 49152-65535"
has "the ports are kept for TURN" "$part" "ok    no other program's ephemeral port lands in 49152-65535"
has "the lock loads again every minute" "$part" "ok    the TURN port lock loads again every minute"
eq "the lock's settings are root's alone" "$(stat -c '%a %U' "$LOCK_ENV")" "600 root"
eq "and name coturn's account" "$(sed -n 's/^TURN_USER=//p' "$LOCK_ENV")" hollow-turn
eq "the lock program is root's" "$(stat -c '%a %U' "$LOCK_BIN")" "755 root"
has "coturn needs the lock" "$(systemctl show -p Requires --value hollow-coturn)" hollow-turn-port-lock.service
yes_ "the lock starts on boot" systemctl is-enabled --quiet hollow-turn-port-lock
yes_ "and its timer" systemctl is-enabled --quiet hollow-turn-port-lock-refresh.timer
# the_port_lock_drops_coturns_datagrams_to_other_local_ports
eq "as coturn's account a datagram to another port of this box is dropped" "$(udp_probe hollow-turn "$PF_LOCAL_IP" 5399)" none
eq "one to coturn's relay ports gets through" "$(udp_probe hollow-turn "$PF_LOCAL_IP" 50001)" got
eq "loopback stays open" "$(udp_probe hollow-turn 127.0.0.1 5399)" got
eq "and other accounts are not held" "$(udp_probe root "$PF_LOCAL_IP" 5399)" got
ufw reload >/dev/null 2>&1
eq "a firewall reload leaves the lock in place" "$(grep FAIL <<<"$(turn_part)")" ""
nft delete table inet hollow_turn
systemctl start hollow-turn-port-lock-refresh.service
yes_ "the refresh puts a dropped lock back" nft list table inet hollow_turn
# a_forwarder_turned_on_reloads_the_port_lock
CFG_FORWARDER=yes
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
start_units >/dev/null
eq "the forwarder's ports join the lock's settings" "$(sed -n 's/^FORWARDER_PORTS=//p' "$LOCK_ENV")" 40000-40199
has "and the loaded rule" "$(nft list table inet hollow_turn)" "40000-40199"
has "and are kept for it" "$(reserved)" "40000-40199"
# check_host_finds_the_forwarders_ports_inside_its_container: under Docker the
# forwarder's settings live in its compose service's container, and it runs as
# that image's uid, not coturn's.
part=$(turn_part)
has "with no forwarder settings to read, check-host does not take the range" "$part" "FAIL  the ip port lock for this machine's own addresses does not match coturn"
install -d -m 0755 /opt/box-fwd
printf 'udp_port_min = 40000\nudp_port_max = 40199\n' >/opt/box-fwd/forwarder.toml
printf '#!/usr/bin/python3 -I\nimport socket, time\ns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\ns.bind(("0.0.0.0", 40001))\nwhile True:\n    time.sleep(1)\n' >/opt/box-fwd/hollow-forwarder
chmod 0755 /opt/box-fwd/hollow-forwarder
setpriv --reuid=999 --regid=999 --clear-groups /opt/box-fwd/hollow-forwarder --config /opt/box-fwd/forwarder.toml &
fwd_pid=$!
sleep 1
FDF=$WORK_DIR/fake_docker_fwd
mkdir -p "$FDF"
printf '#!/bin/sh\ncase "$*" in\n"ps -q --filter label=com.docker.compose.service=forwarder") echo fwd1 ;;\n"inspect -f {{.State.Pid}} fwd1") echo "$BOX_FWD_PID" ;;\nesac\n' >"$FDF/docker"
chmod +x "$FDF/docker"
part=$(PATH="$FDF:$PATH" BOX_FWD_PID=$fwd_pid turn_part)
eq "the forwarder's container hands check-host its range" "$(grep FAIL <<<"$part")" ""
has "and the lock covers it" "$part" "ports 40000-40199,49152-65535"
has "its socket on a TURN-reachable port is the forwarder's" "$part" "ok    only coturn and the forwarder listen on TURN-reachable ports"
part=$(PATH="$FDF:$PATH" BOX_FWD_PID="" turn_part)
has "a forwarder that is no compose service's hands check-host nothing" "$part" "FAIL  the ip port lock for this machine's own addresses does not match coturn"
kill "$fwd_pid" 2>/dev/null
wait "$fwd_pid" 2>/dev/null
rm -rf /opt/box-fwd "$FDF"
CFG_FORWARDER=no
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
start_units >/dev/null
lacks "turned off, they leave the rule" "$(nft list table inet hollow_turn)" "40000-40199"
lacks "and are given back" "$(reserved)" "40000-40199"
# an_address_change_reloads_the_port_lock
CFG_PUBLIC_IP=203.0.113.8
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
start_units >/dev/null
systemctl reset-failed hollow-coturn
systemctl restart hollow-coturn
sleep 2
has "a new address reaches the lock's settings" "$(cat "$LOCK_ENV")" "203.0.113.8"
has "and the loaded rule" "$(nft list table inet hollow_turn)" "203.0.113.8"
yes_ "coturn runs with the new address" systemctl is-active --quiet hollow-coturn
part=$(turn_part)
eq "and check-host agrees with coturn" "$(grep FAIL <<<"$part")" ""
has "on the new address" "$part" "203.0.113.8 only on ports 49152-65535"
# turning_turn_off_removes_the_port_lock
CFG_TURN=no
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
no_ "TURN off: the lock's rule is gone" nft list table inet hollow_turn
lacks "its ports are given back" "$(reserved)" "49152-65535"
for f in "$LOCK_BIN" "$LOCK_ENV" "$LOCK_DROPIN" "$UNIT_DIR/hollow-turn-port-lock.service" \
         "$UNIT_DIR/hollow-turn-port-lock-refresh.service" "$UNIT_DIR/hollow-turn-port-lock-refresh.timer"; do
    no_ "TURN off: $f is gone" test -e "$f"
done
no_ "and its timer stopped" systemctl is-active --quiet hollow-turn-port-lock-refresh.timer
# Back on, as the rest of the box expects.
CFG_TURN=yes CFG_PUBLIC_IP=203.0.113.7
ENABLE_UNITS=() RESTART_UNITS=()
turn_apply >/dev/null
start_units >/dev/null
systemctl reset-failed hollow-coturn
systemctl restart hollow-coturn
sleep 2
yes_ "TURN on again: coturn runs" systemctl is-active --quiet hollow-coturn
part=$(turn_part)
eq "and every TURN check passes" "$(grep FAIL <<<"$part")" ""
has "with the lock back" "$part" "ok    the TURN port lock loads again every minute"

echo "check-host on a Docker setup"
FD=$WORK_DIR/fake_docker
mkdir -p "$FD"
cat >"$FD/docker" <<'FAKE'
#!/bin/sh
case "$1" in
ps) echo c1 ;;
inspect)
    case "$3" in
    *config_files*) echo "/opt/hollow-relay-docker/relay-uws/docker-compose.yml c1" ;;
    *LogConfig*) echo "/hollow-relay-relay-1 $BOX_LOG_TYPE $BOX_LOG_TAG" ;;
    *Config.Image*) echo hollow-relay-relay ;;
    esac ;;
run)
    tag=""; msg=""
    for a; do case "$a" in tag=*) tag=${a#tag=} ;; "check-host probe "*) msg=$a ;; esac; done
    systemd-cat -t "$tag" echo "$msg" ;;
esac
FAKE
chmod +x "$FD/docker"
check=$(PATH="$FD:$PATH" BOX_LOG_TYPE=json-file BOX_LOG_TAG="" bash "$DEPLOY/check-host.sh" 2>&1)
has "a container logging to json-file fails" "$check" "FAIL  hollow-relay-relay-1 logs through json-file"
check=$(PATH="$FD:$PATH" BOX_LOG_TYPE=journald BOX_LOG_TAG="" bash "$DEPLOY/check-host.sh" 2>&1)
has "an untagged journal line fails" "$check" "FAIL  hollow-relay-relay-1's journal lines carry no hollow- tag"
check=$(PATH="$FD:$PATH" BOX_LOG_TYPE=journald BOX_LOG_TAG=hollow-relay bash "$DEPLOY/check-host.sh" 2>&1)
has "a tagged container passes" "$check" "ok    hollow-relay-relay-1 logs to the journal as hollow-relay"
if systemctl is-active --quiet rsyslog; then
    has "a Docker-tagged probe line stays off the disk" "$check" "ok    rsyslog keeps the containers' lines off the disk"
fi

echo "an older forwarder in check-host"
ensure_account hollow-fwd
cat >/usr/local/bin/hollow-forwarder <<'EOF'
#!/bin/sh
for a; do [ "$a" = --print-peer-id ] && { echo "unknown arg --print-peer-id" >&2; exit 2; }; done
exec sleep 600
EOF
chmod 0755 /usr/local/bin/hollow-forwarder
ensure_dir "$FWD_ETC" 0750 root hollow-fwd
: | put_file "$FWD_ETC/forwarder.toml" 0640 root hollow-fwd
more_inaccessible <"$DEPLOY/hollow-forwarder.service" | put_unit hollow-forwarder.service
CFG_HOST=box.invalid CFG_GRACE_SECS=120
render_relay_unit 12D3KooWBoxBoxBox | put_unit hollow-relay.service
systemctl daemon-reload
check=$(bash "$DEPLOY/check-host.sh" 2>&1)
has "an older forwarder is a skip" "$check" "skip  the forwarder's id"
lacks "never a failure" "$check" "FAIL  the forwarder has no identity"

echo "check-host ignores a planted temp file"
# check_host_ignores_a_planted_temp_file: a forwarder that never started is a
# failure, whatever a local account left under the names check-host's process
# would use.
printf '#!/bin/sh\nexit 1\n' >/usr/local/bin/hollow-forwarder
last=$(cat /proc/sys/kernel/ns_last_pid)
runuser -u nobody -- sh -c 'i=$1; while [ "$i" -lt $(($1 + 400)) ]; do echo "unknown arg --print-peer-id" >"/dev/shm/hollow-check-fwd.$i"; i=$((i + 1)); done' _ "$((last + 1))"
check=$(bash "$DEPLOY/check-host.sh" 2>&1)
has "a forwarder without an identity fails the check" "$check" "FAIL  the forwarder has no identity yet"
lacks "a planted file never turns it into a skip" "$check" "skip  the forwarder's id"
rm -f /dev/shm/hollow-check-fwd.*

echo "the build account"
ensure_account "$BUILD_USER"
install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$BUILD_DIR"
rc=0
as_builder /bin/sh -c "ln -s /etc/shadow $BUILD_DIR/out-link; echo built >$BUILD_DIR/out-file; setsid sleep 300 >/dev/null 2>&1 & exit 7" || rc=$?
has "a build step's exit code comes back" "$rc" 7
if pgrep -u "$BUILD_USER" >/dev/null; then bad "a build process outlived its step"; else ok "no build process outlives its step"; fi
has "a link the build left is refused" "$( (stage_build_output "$BUILD_DIR/out-link" "$WORK_DIR") 2>&1)" "something other than a plain file"
if [ -e "$WORK_DIR/out-link" ]; then bad "root copied through the build's link"; else ok "root copied nothing through the link"; fi
(stage_build_output "$BUILD_DIR/out-file" "$WORK_DIR") >/dev/null 2>&1
has "a plain output is staged as root's" "$(stat -c '%U %a' "$WORK_DIR/out-file" 2>/dev/null)" "root 755"
rm -f "$BUILD_DIR/out-link" "$BUILD_DIR/out-file"
if [ "${BOX_BUILD_RELAY:-1}" = 1 ]; then
    CFG_FORWARDER=no
    log=$( (programs_source) 2>&1)
    if [ -x /usr/local/bin/hollow-relay ] && grep -q "^version=" "$VERSION_FILE"; then
        ok "the relay builds inside the build unit's sandbox"
    else
        bad "the relay did not build: $(tail -n 8 <<<"$log")"
    fi
    if pgrep -u "$BUILD_USER" >/dev/null; then bad "the build left processes behind"; else ok "the build left nothing running"; fi
fi

echo "uninstall keeps plain files only"
systemctl stop hollow-forwarder hollow-relay >/dev/null 2>&1
install -d -m 0700 -o hollow-fwd -g hollow-fwd /var/lib/hollow-forwarder
install -d -m 0700 -o hollow-relay -g hollow-relay /var/lib/hollow-relay
runuser -u hollow-fwd -- sh -c 'ln -s /etc/shadow /var/lib/hollow-forwarder/forwarder.key; echo db >/var/lib/hollow-forwarder/forwarder.db'
runuser -u hollow-relay -- sh -c 'echo key >/var/lib/hollow-relay/reports.json.key; echo "{}" >/var/lib/hollow-relay/reports.json'
mkdir -p /etc/letsencrypt/renewal
echo "# box" >/etc/letsencrypt/renewal/relay.conf
rm -rf "$BACKUP_DIR"
# An older uninstall kept a report key, which no relay since 0.13 reads.
install -d -m 0700 "$BACKUP_DIR"
install -m 0600 /dev/null "$BACKUP_DIR/reports.json.key"
echo oldkey >"$BACKUP_DIR/reports.json.key"
out=$(native_uninstall yes 2>&1)
if [ -e "$BACKUP_DIR/forwarder.key" ]; then bad "a key that was a link to /etc/shadow was backed up"; else ok "a linked key is not backed up"; fi
has "and the uninstall says so" "$out" "is not a plain file of hollow-fwd's"
# uninstall_keeps_the_report_counts_without_their_key
eq "the plain files are kept, the report key never" "$(find "$BACKUP_DIR" -mindepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')" "forwarder.db reports.json "
# uninstall_removes_the_turn_port_lock
no_ "the uninstall took the TURN port lock's rule" nft list table inet hollow_turn
lacks "and gave its ports back" "$(sysctl -n net.ipv4.ip_local_reserved_ports)" "49152-65535"
for f in "$LOCK_BIN" "$LOCK_ENV" "$LOCK_DROPIN" "$UNIT_DIR/hollow-turn-port-lock.service" "$UNIT_DIR/hollow-turn-port-lock-refresh.timer"; do
    no_ "uninstall: $f is gone" test -e "$f"
done
yes_ "the certificate's renewal is off" test -e /etc/letsencrypt/renewal/relay.conf.hollow-off
if [ -e /etc/letsencrypt/renewal/relay.conf ]; then bad "certbot still renews it"; else ok "certbot no longer renews it"; fi
ensure_account hollow-relay
if restore_state /var/lib/hollow-relay hollow-relay reports.json; then
    has "a reinstall gets the report counts back" "$(stat -c '%U %a' /var/lib/hollow-relay/reports.json)" "hollow-relay 600"
else
    bad "the report counts were not restored"
fi
if restore_state /var/lib/hollow-relay hollow-relay reports.json; then
    bad "a restore wrote into a state directory that already exists"
else
    ok "a restore never writes into an existing state directory"
fi
ensure_account hollow-fwd
if restore_state /var/lib/hollow-forwarder hollow-fwd forwarder.key forwarder.db; then
    bad "a forwarder identity without its key was restored"
else
    ok "nothing restores without the forwarder's key"
fi

echo "this setup's own SSH login"
P=$(cat /root/ssh_test_port)
useradd -m -s /bin/bash boxu >/dev/null 2>&1
usermod -p '*' boxu
printf 'boxu ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/boxu
chmod 0440 /etc/sudoers.d/boxu
for k in k1 k2 k3 k4; do ssh-keygen -q -t ed25519 -N '' -C "box-$k" -f "$WORK_DIR/$k"; done
chmod 0755 "$WORK_DIR"
boxfp() { ssh-keygen -l -E sha256 -f "$WORK_DIR/$1.pub" | awk '{print $2}'; }
boxu_keys() {
    rm -rf /home/boxu/.ssh
    install -d -m 0700 -o boxu -g boxu /home/boxu/.ssh
    for k in "$@"; do cat "$WORK_DIR/$k.pub"; done >/home/boxu/.ssh/authorized_keys
    chown boxu:boxu /home/boxu/.ssh/authorized_keys
    chmod 0600 /home/boxu/.ssh/authorized_keys
}
# sshu <key> [ssh options] -- <command...>
sshu() {
    local k=$1 opts=()
    shift
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    ssh -i "$WORK_DIR/$k" -p "$P" "${opts[@]}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR boxu@127.0.0.1 "$@"
}
cat >/usr/local/bin/hollow-box-probe <<EOF
#!/bin/bash
. $DEPLOY/lib/common.sh
. $DEPLOY/lib/host.sh
. $DEPLOY/lib/ssh_keys.sh
ssh_session_key "\$1"
printf '%s\n' "\$SSH_SESSION_KEY"
EOF
chmod 0755 /usr/local/bin/hollow-box-probe
boxu_keys k1 k2
got=$(sshu k1 -- sudo -n /usr/local/bin/hollow-box-probe boxu)
has "a session that logged in with a key finds that key" "$got" " 127.0.0.1 $(boxfp k1)"
# A second session of the same account, with another key, at the same time.
sshu k2 -- sleep 20 &
other=$!
sleep 2
got=$(sshu k1 -- sudo -n /usr/local/bin/hollow-box-probe boxu)
has "with another session open, still this session's key" "$got" "$(boxfp k1)"
lacks "never the other session's" "$got" "$(boxfp k2)"
got=$(sshu k2 -- sudo -n /usr/local/bin/hollow-box-probe boxu)
has "and the other session finds its own" "$got" "$(boxfp k2)"
got=$(sshu k1 -tt -- sudo -n /usr/local/bin/hollow-box-probe boxu | tr -d '\r')
has "through a terminal and sudo's own pty too" "$got" "$(boxfp k1)"
kill "$other" 2>/dev/null
wait "$other" 2>/dev/null
got=$(sshu k1 -- sudo -n /usr/local/bin/hollow-box-probe root)
eq_box() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }
eq_box "never for another account" "$got" ""
got=$(/usr/local/bin/hollow-box-probe boxu)
eq_box "nothing without an SSH session" "$got" ""
# The whole question in a real run of the switch: the session's key counts
# once confirmed, the change is made and the second login still guards it.
cat >/usr/local/bin/hollow-box-switch <<EOF
#!/bin/bash
for f in common ui preflight address ssh_keys native docker manage host questions; do . $DEPLOY/lib/\$f.sh; done
UI_MODE=plain DRY_RUN=0 SSH_PLAN=guide WORK_DIR=\$(mktemp -d)
ui_yesno() { printf 'ASK %s\n' "\$1"; [ "\$1" = ssh_own ]; }
ui_msg() { printf 'MSG %s\n' "\$1"; }
ssh_wait_login() { printf 'WAIT %s\n' "\$3"; SSH_KEY_SEEN="key x from y"; return 0; }
ssh_change_once() { return 0; }
ssh_passwords_on() { [ "\${SWITCHED:-0}" = 1 ] && return 1; SWITCHED=1; return 0; }
ssh_run
printf 'RESULT %s\n' "\$SSH_RESULT"
EOF
chmod 0755 /usr/local/bin/hollow-box-switch
got=$(sshu k1 -- sudo -n /usr/local/bin/hollow-box-switch)
has "a real session is offered as the first key login" "$got" "ASK ssh_own"
lacks "and skips the first window" "$got" "WAIT before the change"
has "while the second login still guards the change" "$got" "WAIT after the change"

echo "another computer's key, with password logins off"
boxu_keys k1
hollow_sshd_dropin boxu >"$HOLLOW_SSHD_DROPIN"
hollow_reload_sshd
sleep 1
if ssh_passwords_on; then bad "password logins did not go off in the box"; else ok "password logins are off"; fi
if sshu k3 -- true 2>/dev/null; then bad "k3 logged in before it was added"; else ok "the new key cannot log in yet"; fi
declare -A ANS=([ssh_public_key]="$(cat "$WORK_DIR/k3.pub")" [ssh_wait_secs]=40)
UI_MODE=answers SUDO_USER=boxu
( ssh_add_key_run >"$WORK_DIR/add.out" 2>&1; printf 'RESULT %s\n' "$SSH_RESULT" >>"$WORK_DIR/add.out" ) &
adder=$!
for _ in $(seq 1 20); do grep -q box-k3 /home/boxu/.ssh/authorized_keys 2>/dev/null && break; sleep 0.5; done
sleep 2
if sshu k3 -- true; then ok "the new computer's key logs in once added"; else bad "the added key could not log in"; fi
wait "$adder"
has "the flow saw and named that login" "$(cat "$WORK_DIR/add.out")" "RESULT The new computer logged in with the key $(boxfp k3) from 127.0.0.1"
has "the old key stays first" "$(head -n 1 /home/boxu/.ssh/authorized_keys)" "box-k1"
has "the new one follows" "$(sed -n 2p /home/boxu/.ssh/authorized_keys)" "box-k3"
has "authorized_keys is the account's, 0600" "$(stat -c '%U %G %a' /home/boxu/.ssh/authorized_keys)" "boxu boxu 600"
has ".ssh is the account's, 0700" "$(stat -c '%U %G %a' /home/boxu/.ssh)" "boxu boxu 700"
if ssh_passwords_on; then bad "adding a key turned password logins back on"; else ok "password logins stay off"; fi
yes_ "the switch's own setting is untouched" test -e "$HOLLOW_SSHD_DROPIN"
if sshu k1 -- true; then ok "the old key still logs in"; else bad "the old key no longer logs in"; fi
# An account with no .ssh yet gets one of its own.
rm -rf /home/boxu/.ssh
ANS=([ssh_public_key]="$(cat "$WORK_DIR/k4.pub")" [ssh_wait_secs]=1)
ssh_add_key_run >"$WORK_DIR/add2.out" 2>&1
[ -d /home/boxu/.ssh ] || { echo "  result: $SSH_RESULT"; tail -n 5 "$WORK_DIR/add2.out"; sshd -T 2>&1 >/dev/null | head -n 2; }
has "a missing .ssh is made by the account, 0700" "$(stat -c '%U %G %a' /home/boxu/.ssh 2>/dev/null)" "boxu boxu 700"
has "with authorized_keys 0600" "$(stat -c '%U %G %a' /home/boxu/.ssh/authorized_keys 2>/dev/null)" "boxu boxu 600"
# Nobody logged in with it: the result names it and the line to delete.
has "the unconfirmed key is named by its label" "$SSH_RESULT" "the key box-k4 ($(boxfp k4))"
has "with the line that holds it" "$SSH_RESULT" "delete line 1 of /home/boxu/.ssh/authorized_keys, the one that ends in box-k4"

echo "never through a link"
cp -a /root/.ssh/authorized_keys "$WORK_DIR/root_keys.before"
boxu_keys k1
rm -f /home/boxu/.ssh/authorized_keys
runuser -u boxu -- ln -s /root/.ssh/authorized_keys /home/boxu/.ssh/authorized_keys
ANS=([ssh_public_key]="$(cat "$WORK_DIR/k2.pub")" [ssh_wait_secs]=1)
ssh_add_key_run >/dev/null 2>&1
has "a linked authorized_keys is refused" "${SSH_RESULT:-}" "I added nothing"
yes_ "root's own keys are untouched" cmp -s /root/.ssh/authorized_keys "$WORK_DIR/root_keys.before"
rm -rf /home/boxu/.ssh
runuser -u boxu -- ln -s /root/.ssh /home/boxu/.ssh
ssh_add_key_run >/dev/null 2>&1
has "a linked .ssh is refused" "${SSH_RESULT:-}" "I added nothing"
yes_ "root's own keys are still untouched" cmp -s /root/.ssh/authorized_keys "$WORK_DIR/root_keys.before"
# Even with the check skipped, the account itself writes, so a link it made
# reaches nothing it could not write anyway.
( ssh_keys_file_ok() { SSH_KEYS_WHY=""; return 0; }
  if ssh_append_key boxu "$(cat "$WORK_DIR/k2.pub")"; then echo WROTE; fi ) >"$WORK_DIR/raw.out" 2>&1
lacks "the writer alone refuses the link" "$(cat "$WORK_DIR/raw.out")" "WROTE"
yes_ "and root's keys are untouched by it" cmp -s /root/.ssh/authorized_keys "$WORK_DIR/root_keys.before"
rm -f /home/boxu/.ssh
rm -f "$HOLLOW_SSHD_DROPIN"
hollow_reload_sshd
UI_MODE=answers
unset SUDO_USER

echo "ssh logins: only lines root's sshd wrote"
# forge <account> <process name> <message>: a syslog line any process can
# send, named sshd, from a process that lives on while journald reads it.
forge() {
    runuser -u "$1" -- python3 -c '
import ctypes, socket, sys, time
ctypes.CDLL(None).prctl(15, sys.argv[1].encode(), 0, 0, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(("<38>sshd[%d]: %s" % (1000 + len(sys.argv[2]), sys.argv[2])).encode(), "/dev/log")
time.sleep(3)' "$2" "$3" &
}
boxu_keys k1
since=$(date +%s)
sleep 1
acc() { printf 'Accepted publickey for boxu from 192.0.2.66 port 4242 ssh2: ED25519 SHA256:%s' "$1"; }
forge boxu logger "$(acc forgedA)"
forge boxu sshd "$(acc forgedB)"
forge boxu sshd-session "$(acc forgedC)"
forge root logger "$(acc forgedD)"
# A stranger picks the user name sshd writes into its own line.
# (Given in a config file: ssh refuses such a name on its command line.)
printf 'Host forge\n    HostName 127.0.0.1\n    Port %s\n    User "Accepted publickey for boxu from 192.0.2.77 port 1 ssh2: ED25519 forgedE"\n' "$P" >"$WORK_DIR/forge.conf"
ssh -F "$WORK_DIR/forge.conf" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    forge true 2>/dev/null
sshu k1 -- sleep 2
wait
sleep 1
got=$(ssh_logins boxu "$since")
for f in A B C D; do
    lacks "a forged line ($f) is no login" "$got" "SHA256:forged$f"
done
# sshd cuts a user name at its first colon, so this one names an address only.
lacks "a user name a stranger typed is no login" "$got" "192.0.2.77"
has "while the real key login is found" "$got" " key 127.0.0.1 $(boxfp k1)"
journalctl --since "@$since" -o short-unix --no-pager 2>/dev/null | grep -cE 'SHA256:forged|from 192.0.2.77 port 1 ssh2' |
    { read -r n; if [ "$n" -ge 5 ]; then ok "all five forged lines reached the journal ($n)"; else bad "only $n forged lines reached the journal"; fi; }

echo "ssh: a Match block that keeps passwords"
hollow_sshd_dropin boxu >"$HOLLOW_SSHD_DROPIN"
printf 'Match User boxu\n    PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/99-box-match.conf
if sshd -t 2>/dev/null; then
    eq_box "sshd -T alone says passwords are off" "$(ssh_password_state)" off
    has "while sshd itself lets boxu use a password" "$(sshd -T -C user=boxu,host=x,addr=203.0.113.9 2>/dev/null)" "passwordauthentication yes"
    eq_box "the block is found" "$(ssh_match_passwords)" "/etc/ssh/sshd_config.d/99-box-match.conf line 1 (Match User boxu)"
    SUDO_USER=boxu
    audit_collect
    has "the audit never says keys only" "${AUD_LINES[0]}" "keys only except where a Match block allows passwords"
    SSH_PLAN=none
    ssh_run
    has "nor does the result" "$SSH_RESULT" "Match User boxu"
    unset SUDO_USER
else
    bad "sshd refused the Match block"
fi
rm -f /etc/ssh/sshd_config.d/99-box-match.conf "$HOLLOW_SSHD_DROPIN"

echo "adopt: a program that only shares the relay's name"
mkdir -p /opt/box-stray
cp /bin/sleep /opt/box-stray/hollow-relay
chmod 0755 /opt/box-stray/hollow-relay
runuser -u boxu -- /opt/box-stray/hollow-relay 60 &
stray=$!
sleep 1
have() { [ "$1" != docker ] && command -v "$1" >/dev/null 2>&1; }
adopt_detect
eq_box "another account's program is no relay" "$ADOPT_KIND" none
has "and is noted" "${ADOPT_NOTES[*]}" "runs as boxu"
kill "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
/opt/box-stray/hollow-relay 60 &
stray=$!
sleep 1
adopt_detect
eq_box "root's own is one this setup cannot stop" "$ADOPT_KIND" other
kill "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
unset -f have
have() { command -v "$1" >/dev/null 2>&1; }
rm -rf /opt/box-stray

echo ""
echo "box $ID $VERSION_ID: $pass passed, $fail failed"
[ "$fail" = 0 ]
