#!/bin/sh
# Set a fresh Ubuntu or Debian box up the way relay.anonlisten.com runs: only
# the ports a relay needs are open, nothing that passes through memory can end
# up on the disk, and the clock is right.
#
# Run it with sudo. Run it again whenever you like, it changes only what is not
# already set. Pass --print to see what it would do and change nothing.
#
#   sudo sh deploy/harden-host.sh
#   sh deploy/harden-host.sh --print
set -eu

DRY=0
if [ "${1:-}" = "--print" ]; then
    DRY=1
elif [ "$(id -u)" != "0" ]; then
    echo "Run this with sudo, or pass --print to see what it would do." >&2
    exit 1
fi

CHANGES=""

note() {
    CHANGES="$CHANGES
  $1"
}

run() {
    if [ "$DRY" = "1" ]; then
        echo "  would run: $*"
    else
        "$@"
    fi
}

# Same as run, but the command is allowed to fail and its output is noise.
run_ok() {
    if [ "$DRY" = "1" ]; then
        echo "  would run: $*"
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

write_file() {
    # write_file <path> <<'EOF' ... EOF
    path=$1
    if [ "$DRY" = "1" ]; then
        echo "  would write: $path"
        cat >/dev/null
    else
        mkdir -p "$(dirname "$path")"
        cat >"$path"
    fi
}

echo "Packages"
run apt-get update -qq
run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw fail2ban unattended-upgrades
note "installed ufw, fail2ban and unattended-upgrades"

echo "Firewall"
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow 22/tcp
run ufw allow 80/tcp
run ufw allow 443/tcp
run ufw allow 3478/tcp
run ufw allow 3478/udp
run ufw allow 5349/tcp
run ufw allow 5349/udp
run ufw allow 49152:65535/udp
run ufw --force enable
note "firewall: everything denied except 22, 80, 443, TURN on 3478 and 5349, and the TURN media range 49152 to 65535"

echo "Logging"
write_file /etc/systemd/journald.conf.d/hollow-privacy.conf <<'EOF'
# The relay holds ciphertext and peer addresses in memory. Logs that survive a
# reboot, and logs large enough to be paged out, both undo that.
[Journal]
Storage=volatile
MaxRetentionSec=1h
RuntimeMaxUse=50M
EOF
run systemctl restart systemd-journald
note "logs kept in memory only, one hour, 50 MB"

echo "Crash dumps"
if [ -f /etc/default/apport ] || systemctl list-unit-files 2>/dev/null | grep -q '^apport'; then
    run_ok systemctl disable --now apport.service
    if [ "$DRY" = "1" ]; then
        echo "  would write: /etc/default/apport (enabled=0)"
    else
        echo "enabled=0" >/etc/default/apport
    fi
    note "apport disabled"
fi
write_file /etc/sysctl.d/90-hollow-relay.conf <<'EOF'
# A core dump would write the relay's whole heap, buffered messages included,
# to the disk.
fs.suid_dumpable=0
kernel.core_pattern=|/bin/false
EOF
run sysctl -q --system
note "core dumps off"

echo "Swap"
run swapoff -a
if [ "$DRY" = "1" ]; then
    echo "  would comment out any swap line in /etc/fstab"
else
    # Swap lets the kernel write relay memory to the disk, which is the one
    # thing the relay promises never happens.
    sed -i 's/^\([^#].*[[:space:]]swap[[:space:]]\)/#\1/' /etc/fstab
fi
note "swap off, and off again after a reboot"

echo "Clock"
run timedatectl set-ntp true
note "clock synchronised (relay logins carry a 60 second timestamp window, so a wrong clock fails every login)"

echo "SSH"
SSH_USER=${SUDO_USER:-$(id -un)}
SSH_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
if [ -n "$SSH_HOME" ] && [ -s "$SSH_HOME/.ssh/authorized_keys" ]; then
    write_file /etc/ssh/sshd_config.d/90-hollow-relay.conf <<'EOF'
PasswordAuthentication no
EOF
    run_ok systemctl reload ssh
    run_ok systemctl reload sshd
    note "password logins over SSH turned off for $SSH_USER (key logins only)"
else
    echo "  $SSH_USER has no SSH keys, leaving password logins on."
    note "password logins over SSH left ON, because $SSH_USER has no authorized_keys and turning them off would lock you out"
fi

echo "Services"
run_ok systemctl enable --now fail2ban
run_ok systemctl enable --now unattended-upgrades
note "fail2ban and unattended security updates running"

if [ "$DRY" = "1" ]; then
    echo ""
    echo "Nothing was changed. Run it with sudo to apply."
else
    echo ""
    echo "Done:$CHANGES"
fi
