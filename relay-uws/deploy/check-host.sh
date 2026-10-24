#!/bin/bash
# Checks a relay host against what harden-host.sh and the unit files promise:
# the services run as accounts that cannot become root, no secret or private
# key is readable by other local accounts, every service sits in a sandbox,
# and nothing of theirs lands on the disk. Prints one line per check and exits
# 1 if any fails. Changes nothing. Units under other names can be added as
# arguments.
#
#   sudo bash deploy/check-host.sh [unit ...]
set -u

if [ "$(id -u)" != "0" ]; then
    echo "Run it with sudo: it reads unit settings and file permissions only root can see." >&2
    exit 2
fi

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

units=()
for u in hollow-relay hollow-push hollow-forwarder hollow-coturn coturn hollow-duckdns "$@"; do
    [ "$(systemctl show -p LoadState --value "$u" 2>/dev/null)" = loaded ] && units+=("$u")
done
if [ ${#units[@]} -eq 0 ]; then
    echo "No relay services found under systemd (a Docker setup is checked by its compose file)."
fi

echo "Service accounts"
for u in "${units[@]}"; do
    user=$(systemctl show -p User --value "$u")
    if [ -z "$user" ] || [ "$user" = root ]; then
        bad "$u runs as root"
    elif sudo -l -U "$user" 2>/dev/null | grep -q "may run"; then
        bad "$u runs as $user, who may use sudo"
    elif id -nG "$user" | grep -qwE "sudo|admin|wheel|adm|docker|lxd"; then
        bad "$u runs as $user, a member of $(id -nG "$user")"
    else
        ok "$u runs as $user, which cannot become root"
    fi
    exe=$(systemctl show -p ExecStart --value "$u" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
    if [ -n "$exe" ] && [ -n "$user" ] && [ "$user" != root ] && sudo -u "$user" test -w "$exe"; then
        bad "$u can rewrite its own program $exe"
    fi
done

# The accounts install.sh makes: none may log in or hold a password.
echo "Accounts"
for a in hollow-relay hollow-push hollow-fwd hollow-turn hollow-ddns hollow-build; do
    entry=$(getent passwd "$a") || continue
    shell=${entry##*:}
    pw=$(getent shadow "$a" | cut -d: -f2)
    case "$shell" in
    */nologin|*/false) ;;
    *) bad "the account $a has the login shell $shell"; continue ;;
    esac
    case "$pw" in
    '!'*|'*'*) ok "the account $a cannot log in and has no password" ;;
    *) bad "the account $a has a password set" ;;
    esac
done

echo "Secrets"
for u in "${units[@]}"; do
    if systemctl show -p Environment --value "$u" | grep -qE '(SECRET|TOKEN|PASSWORD|PRIVATE|LICENSE|CONN_RATE_EXEMPT)[A-Z_]*='; then
        bad "$u has a secret in Environment=, which any local account reads with systemctl show"
    else
        ok "$u keeps its secrets out of Environment="
    fi
    for f in $(systemctl show -p EnvironmentFiles --value "$u" | grep -oE '/[^ ]+'); do
        [ -e "$f" ] || continue
        mode=$(stat -c %a "$f")
        if [ "$(stat -c %U "$f")" != root ] || [ "${mode: -2}" != 00 ]; then
            bad "$f is $(stat -c '%a %U:%G' "$f"), should be 600 root"
        fi
    done
done
if pgrep -a turnserver | grep -q -- '--static-auth-secret'; then
    bad "coturn carries the TURN secret on its command line, where ps shows it to everyone"
elif pgrep turnserver >/dev/null; then
    ok "coturn keeps the TURN secret off its command line"
fi
# The value a unit's environment files give a variable, the last file winning. Compared,
# never printed.
env_file_value() {
    local f x v=""
    for f in $(systemctl show -p EnvironmentFiles --value "$1" | grep -oE '/[^ ]+'); do
        [ -r "$f" ] || continue
        x=$(sed -n "s/^[[:space:]]*$2=//p" "$f" | tail -n 1)
        [ -n "$x" ] && v=$x
    done
    v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    printf '%s' "$v"
}
if [[ " ${units[*]} " == *" hollow-push "* ]]; then
    push_token=$(env_file_value hollow-push PUSH_TOKEN)
    if [ -z "$push_token" ]; then
        bad "the push sidecar has no PUSH_TOKEN: any local process can push to every phone with its credential"
    elif [[ " ${units[*]} " == *" hollow-relay "* ]] && [ "$(env_file_value hollow-relay HOLLOW_PUSH_TOKEN)" != "$push_token" ]; then
        bad "the relay's HOLLOW_PUSH_TOKEN is not the sidecar's PUSH_TOKEN, so the sidecar refuses every push"
    else
        ok "the push sidecar takes pushes only from the relay (PUSH_TOKEN set)"
    fi
fi

echo "Private keys"
open_keys=$(find /etc/letsencrypt/archive /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder \
    /etc/hollow-turn /etc/hollow-duckdns /var/lib/hollow-relay /var/lib/hollow-forwarder \
    /var/lib/hollow-installer -type f \
    \( -name 'privkey*' -o -name '*.key' -o -name 'service-account*.json' -o -name '*.env' \
       -o -name '*.toml' -o -name '*.db' \) \
    -perm /o+r 2>/dev/null)
if [ -z "$open_keys" ]; then
    ok "no private key or secret file is readable by every account"
else
    bad "readable by every account: $(echo "$open_keys" | tr '\n' ' ')"
fi
closed=1
for d in /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder /etc/hollow-turn /etc/hollow-duckdns \
    /var/lib/hollow-relay /var/lib/hollow-forwarder /var/lib/hollow-installer; do
    [ -d "$d" ] || continue
    mode=$(stat -c %a "$d")
    if [ "${mode: -1}" != 0 ]; then
        bad "$d is $(stat -c '%a %U:%G' "$d"), open to every account"
        closed=0
    fi
done
not_root=$(find /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder /etc/hollow-turn /etc/hollow-duckdns \
    ! -user root 2>/dev/null)
if [ -n "$not_root" ]; then
    bad "settings a service account owns, and so may rewrite: $(echo "$not_root" | tr '\n' ' ')"
    closed=0
fi
[ "$closed" = 1 ] && ok "the services' settings and state are root-owned and closed to other accounts"
# The report key lives only in memory and the restart snapshot; an older relay kept it here.
old_report_keys=$(find /var/lib/hollow-relay -maxdepth 2 -name 'reports*.key' 2>/dev/null)
if [ -z "$old_report_keys" ]; then
    ok "no report key on the disk beside the reports"
else
    bad "a report key on the disk lets a copy of it test who reported whom: $(echo "$old_report_keys" | tr '\n' ' ')"
fi
if [ -d /etc/letsencrypt/renewal-hooks ] && grep -rqE 'chmod[^;]*(644|o\+r|a\+r)' /etc/letsencrypt/renewal-hooks 2>/dev/null; then
    bad "a certbot renewal hook makes certificate files readable by everyone again"
fi

echo "Sandbox"
for u in "${units[@]}"; do
    score=$(systemd-analyze security "$u" --no-pager 2>/dev/null | tail -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$score" ] && awk -v s="$score" 'BEGIN { exit !(s <= 2.0) }'; then
        ok "$u is sandboxed (exposure $score)"
    else
        bad "$u exposure ${score:-unknown}, above 2.0"
    fi
    [ "$(systemctl show -p LimitCORE --value "$u")" = 0 ] || bad "$u may write a core dump (LimitCORE is not 0)"
done
# The relay advertises the forwarder that runs here, or nothing would use it.
if [[ " ${units[*]} " == *" hollow-forwarder "* ]] && [[ " ${units[*]} " == *" hollow-relay "* ]]; then
    fwd_conf=$(systemctl show -p ExecStart --value hollow-forwarder | sed -n 's/.*--config \([^ ;]*\).*/\1/p' | head -n 1)
    fwd_exe=$(systemctl show -p ExecStart --value hollow-forwarder | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
    fwd_user=$(systemctl show -p User --value hollow-forwarder)
    # Both streams in a variable: a file under a guessable name in a shared
    # folder could be planted by any local account.
    fwd_out=$(runuser -u "${fwd_user:-hollow-fwd}" -- "$fwd_exe" --config "${fwd_conf:-/etc/hollow-forwarder/forwarder.toml}" \
        --print-peer-id 2>&1) || true
    fwd_id=$(printf '%s\n' "$fwd_out" | sed -n '/^12D3KooW[1-9A-HJ-NP-Za-km-z]*$/{p;q}')
    fwd_old=0
    case "$fwd_out" in *'unknown arg --print-peer-id'*) fwd_old=1 ;; esac
    # A forwarder from before --print-peer-id names its id only in the journal, on each start.
    [[ "$fwd_id" =~ ^12D3KooW[1-9A-HJ-NP-Za-km-z]+$ ]] || fwd_id=$(journalctl -u hollow-forwarder -o cat 2>/dev/null |
        sed -n 's/.*forwarder peer_id: \(12D3KooW[1-9A-HJ-NP-Za-km-z]*\).*/\1/p' | tail -n 1)
    if [ -z "$fwd_id" ] && [ "$fwd_old" = 1 ]; then
        echo "  skip  the forwarder's id: this forwarder is older than --print-peer-id and names its id only in the journal when it starts"
    elif [ -z "$fwd_id" ]; then
        bad "the forwarder has no identity yet (it has never started)"
    elif systemctl show -p ExecStart --value hollow-relay | grep -q -- "--forwarder-peer-id $fwd_id"; then
        ok "the relay advertises the forwarder that runs here"
    else
        bad "the relay does not advertise this forwarder ($fwd_id): set --forwarder-peer-id"
    fi
fi
# The push sender's IP wall must still let it reach this machine's resolver,
# or no wake-up ever leaves. The lookup runs under the unit's own address rules.
if [[ " ${units[*]} " == *" hollow-push "* ]]; then
    probe_name=ntfy.sh
    if ! getent ahosts "$probe_name" >/dev/null 2>&1; then
        echo "  skip  the push sender's name lookups: this machine cannot look up $probe_name either"
    elif systemd-run --quiet --wait --pipe --collect \
            -p User="$(systemctl show -p User --value hollow-push)" \
            -p IPAddressAllow="$(systemctl show -p IPAddressAllow --value hollow-push)" \
            -p IPAddressDeny="$(systemctl show -p IPAddressDeny --value hollow-push)" \
            getent ahosts "$probe_name" </dev/null >/dev/null 2>&1; then
        ok "the push sender can look up names through its address wall"
    else
        bad "the push sender cannot look up names: its IPAddressDeny blocks the resolver in /etc/resolv.conf (run the setup again to allow it)"
    fi
fi
if [[ " ${units[*]} " == *" hollow-relay "* ]]; then
    if [ "$(systemctl show -p NotifyAccess --value hollow-relay)" = main ] &&
       [ "$(systemctl show -p FileDescriptorStoreMax --value hollow-relay)" -ge 1 ]; then
        ok "the relay hands its buffers across a restart (NotifyAccess, FileDescriptorStoreMax)"
    else
        bad "the relay has no restart handoff: buffers and push tokens end with every restart"
    fi
fi

echo "Disk"
if [ -z "$(swapon --noheadings 2>/dev/null)" ]; then ok "no swap"; else bad "swap is on: relay memory can be paged to the disk"; fi
case "$(sysctl -n kernel.core_pattern)" in
    "|/bin/false") ok "core dumps off" ;;
    *) bad "kernel.core_pattern is $(sysctl -n kernel.core_pattern), not |/bin/false" ;;
esac
# kdump writes ALL memory, the relay's buffers and its restart snapshot included.
if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = 1 ]; then
    bad "a crash kernel is loaded (kdump): a kernel crash writes all memory to /var/crash"
elif systemctl is-enabled --quiet kdump-tools 2>/dev/null; then
    bad "kdump-tools is enabled: the next boot loads a crash kernel that writes all memory to /var/crash"
else
    ok "no kernel crash dumps (kdump off)"
fi
if [ -n "$(find /var/crash -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
    bad "/var/crash is not empty: a crash report or dump already sits on the disk"
fi
if systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^Storage=' | tail -n 1 | grep -q volatile; then
    ok "the journal lives in memory only"
else
    bad "the journal is not Storage=volatile"
fi
if systemctl is-active --quiet rsyslog && [ -f /var/log/syslog ]; then
    tag="hollow-check-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    logger -t "$tag" "check-host probe"
    logger -t turnserver "check-host probe $tag"
    sleep 2
    if grep -q "$tag:" /var/log/syslog; then
        bad "rsyslog writes hollow-* lines to /var/log/syslog"
    else
        ok "rsyslog keeps hollow-* lines off the disk"
    fi
    if grep -q "turnserver: check-host probe $tag" /var/log/syslog; then
        bad "rsyslog writes coturn's lines (client addresses) to /var/log/syslog"
    else
        ok "rsyslog keeps coturn's lines off the disk"
    fi
fi
turn_logs=$(find /var/log /var/tmp /tmp -maxdepth 3 -type f \( -name 'turn_*.log' -o -name 'turnserver*.log' \) 2>/dev/null)
if [ -z "$turn_logs" ]; then
    ok "no TURN log file on the disk"
else
    bad "TURN log files on the disk: $(echo "$turn_logs" | tr '\n' ' ')"
fi
if command -v ufw >/dev/null 2>&1; then
    if ufw status verbose | grep -q "Logging: off"; then
        ok "the firewall logs nothing (its log records client addresses)"
    else
        bad "ufw logging is on: blocked packets, client addresses included, go to /var/log/ufw.log"
    fi
fi

echo "TURN"
# What coturn runs with: its config file, then its command line. Never printed, the
# file holds the TURN secret.
turn_settings() {
    local pid=$1 conf="" i arg next
    local -a args
    mapfile -d '' -t args < "/proc/$pid/cmdline"
    for ((i = 1; i < ${#args[@]}; i++)); do
        arg=${args[$i]}
        case "$arg" in
            -c) conf=${args[$((i + 1))]:-}; i=$((i + 1)) ;;
            --conf-file=*) conf=${arg#--conf-file=} ;;
            --*=*) echo "${arg#--}" ;;
            --*)
                next=${args[$((i + 1))]:-}
                if [ -n "$next" ] && [ "${next#-}" = "$next" ]; then
                    echo "${arg#--}=$next"
                    i=$((i + 1))
                else
                    echo "${arg#--}"
                fi ;;
        esac
    done
    # Through the process's own root, so a container's file is read too.
    conf=/proc/$pid/root${conf:-/etc/turnserver.conf}
    [ -r "$conf" ] && sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^\([^ =]*\)[[:space:]]*=[[:space:]]*/\1=/' -e 's/^\([^ =]*\)[[:space:]]\{1,\}/\1=/' "$conf"
}
turn_pids=$(pgrep -x turnserver)
[ -n "$turn_pids" ] || echo "  (coturn is not running)"
own_addrs=" $(ip -o addr show | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ') "
for pid in $turn_pids; do
    settings=$(turn_settings "$pid")
    has() { grep -qxF -- "$1" <<<"$settings"; }
    if has no-cli; then ok "coturn has no admin console"; else bad "coturn's admin console is on (no-cli is missing)"; fi
    if has log-file=/dev/null; then
        ok "coturn writes no log file"
    else
        bad "coturn writes a log file (log-file is not /dev/null): TURN sessions and client addresses reach the disk"
    fi
    if has denied-peer-ip=0.0.0.0-255.255.255.255 && has denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff; then
        # Behind 1:1 NAT the host's public address is coturn's external-ip.
        mapped=" $(sed -n 's/^external-ip=\([^/]*\).*/\1/p' <<<"$settings" | tr '\n' ' ') "
        stray=""
        while read -r a; do
            [ -n "$a" ] || continue
            [[ "$own_addrs" == *" $a "* ]] || [[ "$mapped" == *" $a "* ]] || stray="$stray $a"
        done < <(sed -n 's/^allowed-peer-ip=//p' <<<"$settings")
        if [ -z "$stray" ]; then
            ok "TURN relays only to this host (peer lock)"
        else
            bad "TURN may relay to addresses that are not this host's:$stray"
        fi
    else
        bad "TURN may relay anywhere: the peer lock (deny every address, allow this host back) is missing"
    fi
    if has no-tcp-relay; then ok "TURN relays no TCP"; else bad "TURN relays TCP (no-tcp-relay is missing)"; fi

    # The port lock (turn-port-lock.sh): on this host's own address TURN reaches coturn's
    # relay ports and the forwarder's, nothing else listening there.
    lock=/usr/local/sbin/hollow-turn-port-lock
    [ -x "$lock" ] || lock=$(dirname "$0")/turn-port-lock.sh
    min=$(sed -n 's/^min-port=//p' <<<"$settings" | tail -n 1)
    max=$(sed -n 's/^max-port=//p' <<<"$settings" | tail -n 1)
    fwd_ports=""
    fwd_user=hollow-fwd
    turn_uid=$(awk '/^Uid:/ { print $2 }' "/proc/$pid/status")
    fwd_conf=/etc/hollow-forwarder/forwarder.toml
    if [ ! -r "$fwd_conf" ] && command -v docker >/dev/null 2>&1; then
        # Under Docker the forwarder writes its settings inside its compose service's
        # container, read through its own root, and runs as that image's uid.
        for cid in $(docker ps -q --filter label=com.docker.compose.service=forwarder 2>/dev/null); do
            fpid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null)
            [[ $fpid =~ ^[1-9][0-9]*$ ]] || continue
            fcfg=$(tr '\0' '\n' < "/proc/$fpid/cmdline" 2>/dev/null | sed -n '/^--config$/{n;p;q;}')
            if [ -n "$fcfg" ]; then
                fwd_conf=/proc/$fpid/root$fcfg
                fwd_user=$(awk '/^Uid:/ { print $2 }' "/proc/$fpid/status")
                break
            fi
        done
    fi
    if [ -r "$fwd_conf" ]; then
        fmin=$(sed -n 's/^udp_port_min *= *\([0-9]*\).*/\1/p' "$fwd_conf")
        fmax=$(sed -n 's/^udp_port_max *= *\([0-9]*\).*/\1/p' "$fwd_conf")
        fwd_ports="${fmin:-40000}-${fmax:-40199}"
    fi
    lock_out=$(TURN_USER=$turn_uid \
               TURN_PEERS="$(sed -n 's/^allowed-peer-ip=//p' <<<"$settings" | tr '\n' ' ')" \
               TURN_PORTS="${min:-49152}-${max:-65535}" FORWARDER_PORTS="$fwd_ports" FORWARDER_USER="$fwd_user" \
               bash "$lock" check 2>&1)
    lock_rc=$?
    lock_failed=0
    while read -r line; do
        case "$line" in
            "ok "*) ok "${line#ok    }" ;;
            "FAIL "*) bad "${line#FAIL  }"; lock_failed=1 ;;
            done) ;;
            ?*) bad "$line"; lock_failed=1 ;;
        esac
    done <<<"$lock_out"
    # A check that died part way printed only its first lines, every one of them ok.
    if [ "$(tail -n 1 <<<"$lock_out")" != "done" ]; then
        bad "the TURN port lock check stopped before its end (exit $lock_rc)"
    elif [ "$lock_rc" != 0 ] && [ "$lock_failed" = 0 ]; then
        bad "the TURN port lock check failed (exit $lock_rc)"
    fi
    if [ "$(systemctl is-active hollow-turn-port-lock-refresh.timer 2>/dev/null)" = active ]; then
        ok "the TURN port lock loads again every minute"
    else
        bad "hollow-turn-port-lock-refresh.timer is not running: a flushed firewall leaves TURN unlocked"
    fi
done

if command -v docker >/dev/null 2>&1; then
    hollow_cids=$(docker ps -q --filter label=com.docker.compose.service 2>/dev/null | while read -r c; do
        docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}} {{.ID}}' "$c" 2>/dev/null
    done | awk '$1 ~ /relay-uws\/docker-compose\.yml/ {print $2}')
    if [ -n "$hollow_cids" ]; then
        echo "Docker"
        for c in $hollow_cids; do
            read -r cname ltype ltag < <(docker inspect -f '{{.Name}} {{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config "tag"}}' "$c")
            cname=${cname#/}
            if [ "$ltype" != journald ]; then
                bad "$cname logs through $ltype, which keeps its lines on the disk"
            elif [ "${ltag#hollow-}" = "$ltag" ]; then
                bad "$cname's journal lines carry no hollow- tag, so rsyslog copies them to /var/log"
            else
                ok "$cname logs to the journal as $ltag"
            fi
        done
        if systemctl is-active --quiet rsyslog && [ -f /var/log/syslog ]; then
            dtag="hollow-check-docker-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
            # shellcheck disable=SC2086 # one word per container
            dimage=$(docker inspect -f '{{.Config.Image}}' $hollow_cids 2>/dev/null | head -n 1)
            if docker run --rm --log-driver journald --log-opt tag="$dtag" --entrypoint /bin/echo "$dimage" \
                    "check-host probe $dtag" >/dev/null 2>&1; then
                sleep 2
                if grep -q "check-host probe $dtag" /var/log/syslog; then
                    bad "rsyslog writes the containers' hollow-* lines to /var/log/syslog"
                else
                    ok "rsyslog keeps the containers' lines off the disk"
                fi
            else
                echo "  skip  the Docker log probe: no container could start from $dimage"
            fi
        fi
    fi
fi

if command -v fail2ban-client >/dev/null 2>&1; then
    echo "fail2ban"
    if fail2ban-client ping 2>/dev/null | grep -q pong && fail2ban-client status sshd >/dev/null 2>&1; then
        ok "fail2ban is running and watches SSH logins"
    else
        bad "fail2ban is not running or has no sshd jail (journalctl -u fail2ban says why)"
    fi
fi

# Installed is not enough: apt's daily job runs it only when both periodic
# settings are on (hollow_auto_upgrades in lib/host.sh), and Debian sets neither.
if command -v unattended-upgrade >/dev/null 2>&1; then
    echo "Security updates"
    periodic() { apt-config dump 2>/dev/null | sed -n "s/^APT::Periodic::$1 \"\(.*\)\";\$/\1/p" | tail -n 1; }
    lists=$(periodic Update-Package-Lists)
    upgrade=$(periodic Unattended-Upgrade)
    if [ -n "$lists" ] && [ "$lists" != 0 ] && [ "$lists" != 0d ] && [ -n "$upgrade" ] && [ "$upgrade" != 0 ] && [ "$upgrade" != 0d ]; then
        ok "unattended-upgrades installs security updates every day"
    else
        bad "unattended-upgrades is installed but apt never runs it (APT::Periodic::Update-Package-Lists \"${lists:-unset}\", Unattended-Upgrade \"${upgrade:-unset}\"); sudo dpkg-reconfigure -plow unattended-upgrades turns it on"
    fi
fi

echo "SSH"
sshd_t=$(sshd -T 2>/dev/null)
if echo "$sshd_t" | grep -qx "passwordauthentication no"; then ok "password logins off"; else bad "SSH password logins are on"; fi
if echo "$sshd_t" | grep -qx "permitrootlogin yes"; then bad "root may log in over SSH with a password"; else ok "no root password login"; fi

echo ""
if [ "$fail" = 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit $fail
