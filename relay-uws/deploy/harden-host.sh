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
#
# install.sh passes the options it chose, and then the firewall opens exactly
# those ports and closes the relay ports they do not use:
#   --http yes|no --turn yes|no --forwarder yes|no   (port 80, TURN, forwarder)
#   --no-ssh   leave SSH alone, because install.sh guides the key setup itself
#   --no-firewall   leave the firewall as it is, for a machine whose other
#              programs need ports the relay's rules would close
set -eu

LIB="$(cd "$(dirname "$0")" && pwd)/lib"
# shellcheck source=lib/host.sh
. "$LIB/host.sh"

DRY=0
MANAGED=0
HTTP=yes
TURN=yes
FWD=no
DO_SSH=1
DO_FW=1
while [ $# -gt 0 ]; do
    case "$1" in
    --print) DRY=1 ;;
    --http) HTTP=$2; MANAGED=1; shift ;;
    --turn) TURN=$2; MANAGED=1; shift ;;
    --forwarder) FWD=$2; MANAGED=1; shift ;;
    --no-ssh) DO_SSH=0 ;;
    --no-firewall) DO_FW=0 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$DRY" = 0 ] && [ "$(id -u)" != "0" ]; then
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
        sed 's/^/    | /'
    else
        mkdir -p "$(dirname "$path")"
        cat >"$path"
    fi
}

echo "Packages"
run hollow_apt update -qq
run hollow_apt install -y -qq ufw fail2ban python3-systemd unattended-upgrades
note "installed ufw, fail2ban and unattended-upgrades"

echo "Firewall"
if [ "$DO_FW" = 0 ]; then
    echo "  left as it is (--no-firewall)"
    note "firewall left as it was"
else
# shellcheck disable=SC2046 # one word per port
RULES=$(hollow_fw_rules "$HTTP" "$TURN" "$FWD" $(hollow_ssh_ports) | tr '\n' ' ')
# Checked before the first ufw command: on a box where ufw is already on,
# "default deny" takes effect at once.
hollow_ssh_session_covered "$RULES" || exit 3
run ufw default deny incoming
run ufw default allow outgoing
for rule in $RULES; do
    run ufw allow "$rule"
done
if [ "$MANAGED" = 1 ]; then
    for rule in $HOLLOW_FW_OPTIONAL; do
        case " $RULES " in
        *" $rule "*) ;;
        *) run_ok ufw delete allow "$rule" ;;
        esac
    done
fi
# A blocked packet's log line carries its sender's address, and the late
# packets of a closed relay connection are blocked too.
run ufw logging off
run ufw --force enable
note "firewall: everything denied except ${RULES% }; it logs nothing"
fi

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
if [ -d /etc/rsyslog.d ]; then
    # rsyslog copies the journal into files under /var/log.
    write_file /etc/rsyslog.d/00-hollow-privacy.conf <<'EOF'
# The Hollow services and coturn log to the journal, which lives in RAM for an
# hour. None of their lines may reach a file on the disk.
:programname, startswith, "hollow-" stop
:programname, isequal, "turnserver" stop
EOF
    run_ok systemctl restart rsyslog
fi
note "logs kept in memory only, one hour, 50 MB; no relay, push or TURN line reaches /var/log"

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
if systemctl list-unit-files 2>/dev/null | grep -q '^kdump-tools'; then
    # A kernel crash would write all memory, the relay's included, to /var/crash.
    run_ok systemctl disable --now kdump-tools.service
    if [ "$DRY" = "1" ]; then
        echo "  would write: /etc/default/kdump-tools (USE_KDUMP=0)"
    elif [ -f /etc/default/kdump-tools ]; then
        sed -i 's/^USE_KDUMP=.*/USE_KDUMP=0/' /etc/default/kdump-tools
    fi
    note "kdump disabled"
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
if [ "$DO_SSH" = 0 ]; then
    echo "  left to install.sh, which turns passwords off only after a key login"
elif [ -n "$SSH_HOME" ] && [ -s "$SSH_HOME/.ssh/authorized_keys" ]; then
    hollow_sshd_dropin "$SSH_USER" | write_file "$HOLLOW_SSHD_DROPIN"
    [ "$DRY" = "1" ] || rm -f /etc/ssh/sshd_config.d/90-hollow-relay.conf
    run_ok systemctl reload ssh
    run_ok systemctl reload sshd
    # A Match block can let a password back in for some logins, which the note
    # must name. The scan is the installer's own, in bash.
    if ! match=$(bash -c '. "$1" && ssh_match_list' hollow "$LIB/ssh_keys.sh" 2>/dev/null); then
        echo "  I could not read sshd's Match blocks, so passwords may still work where one allows them."
        note "SSH takes keys only, except maybe where a Match block allows passwords (I could not read them); root may log in only if that is the account you used"
    elif [ -n "$match" ]; then
        echo "  Passwords still work where a Match block allows them: $match. I leave that as it is."
        note "SSH takes keys only, except where a Match block allows passwords ($match); root may log in only if that is the account you used"
    else
        note "SSH takes keys only, never a password; root may log in only if that is the account you used"
    fi
else
    echo "  $SSH_USER has no SSH keys, leaving password logins on."
    note "password logins over SSH left ON, because $SSH_USER has no authorized_keys and turning them off would lock you out"
fi

echo "Services"
# Debian 12 has no /var/log/auth.log, so the sshd jail reads the journal, and
# it watches every port SSH listens on, not only 22.
SSH_PORTS_CSV=$(hollow_ssh_ports | tr ' ' ',')
write_file /etc/fail2ban/jail.d/hollow-relay.local <<EOF
# Written by the Hollow relay setup (deploy/harden-host.sh).
[sshd]
enabled = true
backend = systemd
port = $SSH_PORTS_CSV
EOF
run_ok systemctl enable fail2ban
run_ok systemctl restart fail2ban
run_ok systemctl enable --now unattended-upgrades
# The service alone installs nothing: apt's daily job runs it only when both
# periodic settings are on, and Debian sets neither.
UU_TEXT="unattended security updates running"
case "$(hollow_auto_upgrades)" in
unset)
    UU_FILE=$(hollow_auto_upgrades_file)
    echo "  switching unattended security updates on in $UU_FILE"
    hollow_auto_upgrades_dropin | write_file "$UU_FILE"
    note "unattended security updates switched on in $UU_FILE" ;;
off)
    UU_TEXT="unattended security updates are switched OFF in apt's settings (APT::Periodic::Update-Package-Lists or APT::Periodic::Unattended-Upgrade is 0), and I leave them that way. sudo dpkg-reconfigure -plow unattended-upgrades turns them on"
    echo "  $UU_TEXT" ;;
esac
if [ "$DRY" = "1" ]; then
    note "fail2ban and $UU_TEXT"
else
    f2b=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if fail2ban-client ping >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then f2b=1; break; fi
        sleep 1
    done
    if [ "$f2b" = 1 ]; then
        note "fail2ban watching SSH logins on port $SSH_PORTS_CSV, and $UU_TEXT"
    else
        note "fail2ban did NOT start (journalctl -u fail2ban says why); $UU_TEXT"
    fi
fi

if [ "$DRY" = "1" ]; then
    echo ""
    echo "Nothing was changed. Run it with sudo to apply."
else
    echo ""
    echo "Done:$CHANGES"
fi
