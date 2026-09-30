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

echo "Private keys"
open_keys=$(find /etc/letsencrypt/archive /etc/hollow-relay /etc/hollow-push -type f \
    \( -name 'privkey*' -o -name '*.key' -o -name 'service-account*.json' -o -name '*.env' \) \
    -perm /o+r 2>/dev/null)
if [ -z "$open_keys" ]; then
    ok "no private key or secret file is readable by every account"
else
    bad "readable by every account: $(echo "$open_keys" | tr '\n' ' ')"
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
if systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^Storage=' | tail -n 1 | grep -q volatile; then
    ok "the journal lives in memory only"
else
    bad "the journal is not Storage=volatile"
fi
if systemctl is-active --quiet rsyslog && [ -f /var/log/syslog ]; then
    tag="hollow-check-$$"
    logger -t "$tag" "check-host probe"
    sleep 2
    if grep -q "$tag" /var/log/syslog; then
        bad "rsyslog writes hollow-* lines to /var/log/syslog"
    else
        ok "rsyslog keeps hollow-* lines off the disk"
    fi
fi
if command -v ufw >/dev/null 2>&1; then
    if ufw status verbose | grep -q "Logging: off"; then
        ok "the firewall logs nothing (its log records client addresses)"
    else
        bad "ufw logging is on: blocked packets, client addresses included, go to /var/log/ufw.log"
    fi
fi

echo "SSH"
sshd_t=$(sshd -T 2>/dev/null)
echo "$sshd_t" | grep -qx "passwordauthentication no" && ok "password logins off" || bad "SSH password logins are on"
echo "$sshd_t" | grep -qx "permitrootlogin yes" && bad "root may log in over SSH with a password" || ok "no root password login"

echo ""
if [ "$fail" = 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit $fail
