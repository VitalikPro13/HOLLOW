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
for u in hollow-relay hollow-push hollow-forwarder hollow-coturn coturn "$@"; do
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

echo "Secrets"
for u in "${units[@]}"; do
    if systemctl show -p Environment --value "$u" | grep -qE '(SECRET|TOKEN|PASSWORD|PRIVATE|LICENSE)[A-Z_]*='; then
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
    /var/lib/hollow-relay /var/lib/hollow-forwarder -type f \
    \( -name 'privkey*' -o -name '*.key' -o -name 'service-account*.json' -o -name '*.env' \
       -o -name '*.toml' -o -name '*.db' \) \
    -perm /o+r 2>/dev/null)
if [ -z "$open_keys" ]; then
    ok "no private key or secret file is readable by every account"
else
    bad "readable by every account: $(echo "$open_keys" | tr '\n' ' ')"
fi
closed=1
for d in /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder /var/lib/hollow-relay /var/lib/hollow-forwarder; do
    [ -d "$d" ] || continue
    mode=$(stat -c %a "$d")
    if [ "${mode: -1}" != 0 ]; then
        bad "$d is $(stat -c '%a %U:%G' "$d"), open to every account"
        closed=0
    fi
done
not_root=$(find /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder ! -user root 2>/dev/null)
if [ -n "$not_root" ]; then
    bad "settings a service account owns, and so may rewrite: $(echo "$not_root" | tr '\n' ' ')"
    closed=0
fi
[ "$closed" = 1 ] && ok "the services' settings and state are root-owned and closed to other accounts"
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
    tag="hollow-check-$$"
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
        stray=""
        for a in $(sed -n 's/^allowed-peer-ip=//p' <<<"$settings"); do
            [[ "$own_addrs" == *" $a "* ]] || stray="$stray $a"
        done
        if [ -z "$stray" ]; then
            ok "TURN relays only to this host (peer lock)"
        else
            bad "TURN may relay to addresses that are not this host's:$stray"
        fi
    else
        bad "TURN may relay anywhere: the peer lock (deny every address, allow this host back) is missing"
    fi
done

echo "SSH"
sshd_t=$(sshd -T 2>/dev/null)
echo "$sshd_t" | grep -qx "passwordauthentication no" && ok "password logins off" || bad "SSH password logins are on"
echo "$sshd_t" | grep -qx "permitrootlogin yes" && bad "root may log in over SSH with a password" || ok "no root password login"

echo ""
if [ "$fail" = 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit $fail
