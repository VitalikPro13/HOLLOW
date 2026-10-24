#!/bin/sh
# Host settings shared by harden-host.sh and install.sh. POSIX sh, because
# harden-host.sh runs under sh. Sourced, never executed.

# Every port rule a relay may need beyond SSH and 443. The installer removes
# the ones its chosen options do not use; anything else in ufw is left alone.
# shellcheck disable=SC2034 # read by harden-host.sh and install.sh
HOLLOW_FW_OPTIONAL="80/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp 49152:65535/udp 40000:40199/udp"

# Every TCP port SSH may be reached on, so the firewall never shuts anyone out:
# sshd's Port and ListenAddress settings, what sshd and its systemd sockets
# (Ubuntu 24.04 starts sshd from ssh.socket) listen on right now, and the port
# of the SSH session running this.
hollow_ssh_ports() {
    hsp_ports=$({
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2} $1 == "listenaddress" {n = split($2, a, ":"); print a[n]}'
        for hsp_u in ssh.socket sshd.socket; do
            systemctl show -p Listen --value "$hsp_u" 2>/dev/null | tr ' ' '\n' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'
        done
        ss -Hltnp 2>/dev/null | awk '/"sshd"|"sshd-session"/ {n = split($4, a, ":"); print a[n]}'
        hollow_session_ssh_port
    } | grep -xE '[0-9]{1,5}' | awk '$1 >= 1 && $1 <= 65535' | sort -un | tr '\n' ' ')
    [ -n "$hsp_ports" ] || hsp_ports=22
    echo "${hsp_ports% }"
}

# The server port of the SSH session this runs in. sudo drops SSH_CONNECTION,
# so the parent processes are asked for it too. Empty on a console.
hollow_session_ssh_port() {
    hsp_conn=${SSH_CONNECTION:-}
    hsp_pid=$$
    hsp_n=0
    while [ -z "$hsp_conn" ] && [ "$hsp_n" -lt 40 ]; do
        hsp_pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$hsp_pid/status" 2>/dev/null)
        case "$hsp_pid" in '' | 0 | 1 | *[!0-9]*) break ;; esac
        hsp_conn=$(2>/dev/null tr '\0' '\n' <"/proc/$hsp_pid/environ" | sed -n 's/^SSH_CONNECTION=//p' | head -n 1)
        hsp_n=$((hsp_n + 1))
    done
    # shellcheck disable=SC2086 # four fields: client, client port, server, server port
    set -- $hsp_conn
    case "${4:-}" in '' | *[!0-9]*) return 0 ;; esac
    echo "$4"
}

# Refuses, with the reason on stderr, when the SSH session running this is on
# a port the firewall rules would not open. <rules> is hollow_fw_rules' output.
hollow_ssh_session_covered() {
    hsc_port=$(hollow_session_ssh_port)
    [ -n "$hsc_port" ] || return 0
    case " $(echo "$1" | tr '\n' ' ') " in
    *" $hsc_port/tcp "*) return 0 ;;
    esac
    echo "You are logged in over SSH on port $hsc_port, and the firewall rules would not let that port in. Turning the firewall on could lock you out, so I left it as it is." >&2
    return 1
}

# hollow_fw_rules <http yes|no> <turn yes|no> <forwarder yes|no> <ssh port...>
# One ufw rule per line.
hollow_fw_rules() {
    http=$1 turn=$2 fwd=$3
    shift 3
    for p in "$@"; do echo "$p/tcp"; done
    echo 443/tcp
    [ "$http" = yes ] && echo 80/tcp
    if [ "$turn" = yes ]; then
        echo 3478/tcp
        echo 3478/udp
        echo 5349/tcp
        echo 5349/udp
        echo 49152:65535/udp
    fi
    [ "$fwd" = yes ] && echo 40000:40199/udp
    return 0
}

# apt's locks. A new server runs its automatic updates on first boot, and an
# apt-get that meets them fails at once.
HOLLOW_APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
HOLLOW_PROC_LOCKS=/proc/locks
HOLLOW_APT_WAIT_SECS=900
HOLLOW_APT_POLL=5

# The process holding one of apt's locks, nothing when all are free. Read from
# /proc/locks, because apt takes fcntl locks that flock(1) cannot see.
hollow_apt_holder() {
    for hal_f in $HOLLOW_APT_LOCKS; do
        [ -e "$hal_f" ] || continue
        hal_ino=$(stat -c %i "$hal_f" 2>/dev/null) || continue
        hal_pid=$(awk -v ino="$hal_ino" '$2 != "->" { n = split($6, a, ":"); if (a[n] == ino && $5 > 0) { print $5; exit } }' \
            "$HOLLOW_PROC_LOCKS" 2>/dev/null)
        [ -n "$hal_pid" ] && { echo "$hal_pid"; return 0; }
    done
    return 0
}

# Waits until apt's locks are free, saying so once a minute. Returns 1 with the
# reason on stderr after HOLLOW_APT_WAIT_SECS.
hollow_apt_wait() {
    haw_t0=$(date +%s)
    haw_next=0
    while :; do
        haw_pid=$(hollow_apt_holder)
        [ -n "$haw_pid" ] || return 0
        haw_s=$(( $(date +%s) - haw_t0 ))
        if [ "$haw_s" -ge "$HOLLOW_APT_WAIT_SECS" ]; then
            haw_name=$(cat "/proc/$haw_pid/comm" 2>/dev/null || echo "process $haw_pid")
            echo "The system's automatic updates ($haw_name) still hold the package lock after $((haw_s / 60)) minutes, so I stopped. Wait until they finish, or restart the machine, then run the setup again. It carries on where it stopped." >&2
            return 1
        fi
        if [ "$haw_next" = 0 ]; then
            echo "  Waiting for the system's automatic updates to finish. This can take a few minutes on a new server."
            haw_next=60
        elif [ "$haw_s" -ge "$haw_next" ]; then
            echo "  Still waiting for the automatic updates ($((haw_s / 60)) min so far)."
            haw_next=$((haw_s + 60))
        fi
        sleep "$HOLLOW_APT_POLL"
    done
}

# hollow_apt <apt-get arguments>: apt-get once the locks are free. A lock it
# still loses to a starting update is waited for again, never final.
hollow_apt() {
    ha_rc=0
    for ha_try in 1 2 3; do
        hollow_apt_wait || return 1
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@" && return 0
        ha_rc=$?
        [ "$ha_rc" = 100 ] || return "$ha_rc"
        [ "$ha_try" = 3 ] || sleep "$HOLLOW_APT_POLL"
    done
    return "$ha_rc"
}

# The sshd drop-in that turns password logins off. Sorted before the cloud
# images' own drop-ins (50-cloud-init.conf), because sshd keeps the first value
# it reads.
# shellcheck disable=SC2034 # read by harden-host.sh and install.sh
HOLLOW_SSHD_DROPIN=/etc/ssh/sshd_config.d/10-hollow-relay.conf

# hollow_sshd_dropin <login account>
hollow_sshd_dropin() {
    if [ "$1" = root ]; then root_login=prohibit-password; else root_login=no; fi
    cat <<EOF
# Written by the Hollow relay setup. Keys only, never a password.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin $root_login
X11Forwarding no
LoginGraceTime 30
EOF
}

hollow_reload_sshd() {
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
}

# What apt's daily job reads for APT::Periodic::<name>, empty when nothing sets
# it. Debian ships unattended-upgrades without these, and then the daily job
# never upgrades anything.
hollow_apt_periodic() {
    apt-config dump 2>/dev/null | sed -n "s/^APT::Periodic::$1 \"\(.*\)\";\$/\1/p" | tail -n 1
}

# on, off (someone set a value to 0) or unset: whether the daily job fetches
# the package lists and installs the security updates.
hollow_auto_upgrades() {
    hau_l=$(hollow_apt_periodic Update-Package-Lists)
    hau_u=$(hollow_apt_periodic Unattended-Upgrade)
    case "$hau_l" in 0|0d) echo off; return 0 ;; esac
    case "$hau_u" in 0|0d) echo off; return 0 ;; esac
    if [ -z "$hau_l" ] || [ -z "$hau_u" ]; then echo unset; else echo on; fi
}

# The lines a drop-in needs so both run daily: only the settings nothing sets
# yet, so a value someone chose stays theirs.
hollow_auto_upgrades_dropin() {
    echo "// Written by the Hollow relay setup: install security updates every day."
    [ -n "$(hollow_apt_periodic Update-Package-Lists)" ] || echo 'APT::Periodic::Update-Package-Lists "1";'
    [ -n "$(hollow_apt_periodic Unattended-Upgrade)" ] || echo 'APT::Periodic::Unattended-Upgrade "1";'
}

# Where that drop-in goes: the file dpkg-reconfigure unattended-upgrades
# writes, unless one is there already.
HOLLOW_APT_CONF_D=/etc/apt/apt.conf.d
hollow_auto_upgrades_file() {
    if [ -e "$HOLLOW_APT_CONF_D/20auto-upgrades" ] || [ -L "$HOLLOW_APT_CONF_D/20auto-upgrades" ]; then
        echo "$HOLLOW_APT_CONF_D/21hollow-auto-upgrades"
    else
        echo "$HOLLOW_APT_CONF_D/20auto-upgrades"
    fi
}
