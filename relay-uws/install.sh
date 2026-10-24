#!/bin/bash
# Hollow relay setup: from a fresh Ubuntu or Debian machine to a hardened,
# running relay. Read it, then run it from your copy of the repository:
#
#   sudo bash install.sh                  guided setup, or the status screen on a re-run
#                                         (a relay set up some other way is offered for take over)
#   sudo bash install.sh --dry-run        what it would do, changing nothing
#   sudo bash install.sh --answers FILE   no questions, the answers come from FILE
#   sudo bash install.sh --plain          plain prompts instead of whiptail screens
#
# test/installer/answers.example lists every answer. Nothing changes before the
# plan screen, and every step can be run again after a failure.
set -euo pipefail
# `... | put_file` must set PUT_CHANGED in this shell, not in a pipeline's
# subshell, or a changed file would never restart its service.
shopt -s lastpipe

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DEPLOY=$HERE/deploy
REPO=$(cd "$HERE/.." && pwd)
RUN_START=$(date +%s)
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

# shellcheck source=deploy/lib/common.sh
. "$DEPLOY/lib/common.sh"
# shellcheck source=deploy/lib/ui.sh
. "$DEPLOY/lib/ui.sh"
# shellcheck source=deploy/lib/preflight.sh
. "$DEPLOY/lib/preflight.sh"
# shellcheck source=deploy/lib/address.sh
. "$DEPLOY/lib/address.sh"
# shellcheck source=deploy/lib/ssh_keys.sh
. "$DEPLOY/lib/ssh_keys.sh"
# shellcheck source=deploy/lib/native.sh
. "$DEPLOY/lib/native.sh"
# shellcheck source=deploy/lib/docker.sh
. "$DEPLOY/lib/docker.sh"
# shellcheck source=deploy/lib/manage.sh
. "$DEPLOY/lib/manage.sh"
# shellcheck source=deploy/lib/host.sh
. "$DEPLOY/lib/host.sh"
# shellcheck source=deploy/lib/questions.sh
. "$DEPLOY/lib/questions.sh"
# shellcheck source=deploy/lib/adopt.sh
. "$DEPLOY/lib/adopt.sh"

# Before a copy of the setup goes live, the run swapping it in starts it with
# --self-check: every library loaded, and every part the menu and an update's
# last step call is there. It reads and writes nothing.
setup_self_check() {
    local f
    feed_lib_load || return 1
    for f in manage_main manage_update after_update_main native_apply programs_prebuilt setup_copy_stage \
             setup_copy_swap setup_copy_repair update_settings_restore hollow_feed_check hollow_feed_fetch ui_init; do
        declare -F "$f" >/dev/null || return 1
    done
    printf '%s\n' "$SETUP_PROTOCOL"
}
if [ "${1:-}" = --self-check ]; then
    setup_self_check
    exit $?
fi

usage() {
    sed -n '2,/^[^#]/{/^#/p}' "$HERE/install.sh" | sed 's/^# \{0,1\}//'
}

ANSWERS_FILE=""
AFTER_UPDATE=0
while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --after-update) AFTER_UPDATE=1 UI_MODE=plain ;;
    --answers) ANSWERS_FILE=${2:-}; [ -n "$ANSWERS_FILE" ] || die "--answers needs a file."; shift ;;
    --plain) UI_MODE=plain ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1. See: bash install.sh --help" ;;
    esac
    shift
done

# An update's last step runs under the lock of the update that started it,
# handed down as descriptor 9; on its own it never starts.
if [ "$AFTER_UPDATE" = 1 ]; then
    [ "$(id -u)" = 0 ] && [ "$(readlink /proc/$$/fd/9 2>/dev/null)" = "$STATE_DIR/setup.lock" ] && flock -n 9 ||
        die "--after-update is the last step of a menu update and runs only from one."
fi

if [ "$(id -u)" != 0 ] && [ "$DRY_RUN" != 1 ]; then
    die "run it with sudo: sudo bash install.sh (or add --dry-run to see what it would do)."
fi

WORK_DIR=$(mktemp -d /dev/shm/hollow-setup.XXXXXX 2>/dev/null || mktemp -d)
chmod 0700 "$WORK_DIR"
# One run at a time: two would write the same files and units.
if [ "$AFTER_UPDATE" = 0 ] && [ "$(id -u)" = 0 ]; then
    install -d -m 0700 "$STATE_DIR"
    exec 9>"$STATE_DIR/setup.lock"
    flock -n 9 || die "another run of the setup is in progress on this machine. Wait for it to finish, then run it again."
fi
cleanup() {
    local rc=$?
    [ "$DRY_RUN" = 1 ] || build_swap_off
    # A take over that failed part of the way puts the old relay back.
    if [ "$rc" != 0 ] && [ "${ADOPT_ARMED:-0}" = 1 ]; then
        ADOPT_ARMED=0
        (adopt_rollback)
        rm -rf "$WORK_DIR"
        return
    fi
    rm -rf "$WORK_DIR"
    if [ "$rc" != 0 ] && [ "${APPLY_STARTED:-0}" = 1 ] && [ "$AFTER_UPDATE" = 0 ]; then
        printf '\nThe setup stopped part of the way. Run it again: every step checks what is already done and carries on from there.\n' >&2
    fi
}
trap cleanup EXIT

[ -n "$ANSWERS_FILE" ] && ui_load_answers "$ANSWERS_FILE"
ui_init
APPLY_STARTED=0
PF_BEHIND_NAT=0 PF_LOCAL_IP="" PF_PUBLIC_IP="" PF_PUBLIC_IPV6=""
SSH_PLAN=none SSH_RESULT="" CHECK_RESULT=""

# ---------------------------------------------------------------- questions

CFG_MODE="" CFG_BINARIES="" CFG_ADDRESS="" CFG_HOST="" CFG_DUCKDNS_NAME="" CFG_DUCKDNS_TOKEN=""
CFG_DUCKDNS_IP="" CFG_PUBLIC_IP="" CFG_PUBLIC_IP_FIXED=no CFG_PUBLIC_IPV6="" CFG_STAGING=no
CFG_TURN=yes CFG_PUSH=yes CFG_FORWARDER=yes CFG_MEMBERS_ONLY=no CFG_MEMBER_KEYS=0 CFG_GRACE_SECS=120
CFG_PUBLIC_STATS=on

fw_rules_now() {
    local http=no
    [ "$CFG_ADDRESS" = duckdns ] || http=yes
    # shellcheck disable=SC2046
    hollow_fw_rules "$http" "$CFG_TURN" "$CFG_FORWARDER" $(hollow_ssh_ports)
}

ports_text() {
    fw_rules_now | sed 's/^/  /; s/:/ to /'
}

# harden-host.sh refuses the same way; this says why on screen before the plan.
ssh_firewall_guard() {
    local why
    why=$(hollow_ssh_session_covered "$(fw_rules_now)" 2>&1) && return 0
    ui_msg "The firewall could lock you out" "$why

I stopped before changing anything. Check which port sshd listens on (sudo ss -ltnp shows it), then run the setup again."
    die "$why"
}

plan_text() {
    local how parts accounts="hollow-relay"
    if [ "$CFG_MODE" = docker ]; then how="Docker containers, built here from this copy of the repository"
    elif [ "$CFG_BINARIES" = source ]; then how="the full setup, with programs built here from source"
    else how="the full setup, with the ready-made programs"; fi
    parts="the relay"
    [ "$CFG_TURN" = yes ] && { parts="$parts, TURN"; accounts="$accounts, hollow-turn"; }
    [ "$CFG_PUSH" = yes ] && { parts="$parts, the push sender"; accounts="$accounts, hollow-push"; }
    [ "$CFG_FORWARDER" = yes ] && { parts="$parts, the media forwarder"; accounts="$accounts, hollow-fwd"; }
    [ "$CFG_ADDRESS" = duckdns ] && accounts="$accounts, hollow-ddns"
    [ "$CFG_BINARIES" = source ] && [ "$CFG_MODE" = native ] && accounts="$accounts, hollow-build"
    cat <<EOF
This is what I will do. Nothing has changed yet.

Address: $CFG_HOST$( [ "$CFG_STAGING" = yes ] && echo " (staging certificate, for testing only)")
How: $how
Running: $parts
Members-only: $( [ "$CFG_MEMBERS_ONLY" = yes ] && echo "yes, $CFG_MEMBER_KEYS keys" || echo "no, anyone with the address can connect")
Public stats page: $(public_stats_text)
Wait for dropped connections: $CFG_GRACE_SECS seconds

On this machine:
- The firewall turns on and lets in only these ports:
$(ports_text)
- Swap turns off, now and after every reboot, and core dumps go off, so relay memory never reaches the disk.
- The system journal is kept in memory only, for one hour.
- The clock is kept synchronised, and fail2ban and automatic security updates are installed.
$( [ "$CFG_TURN" = yes ] && echo "- TURN gets a port lock, a firewall rule that lets it reach only coturn's own ports$( [ "$CFG_FORWARDER" = yes ] && echo " and the forwarder's") on this machine.")
$( [ "$CFG_MODE" = native ] && echo "- New service accounts, none of which can log in: $accounts.")
$( [ "$CFG_ADDRESS" = duckdns ] && echo "- DuckDNS points $CFG_HOST at ${CFG_DUCKDNS_IP:-this machine}.")
- Let's Encrypt is asked for a certificate for $CFG_HOST.
$( [ "${SSH_PLAN:-none}" = guide ] && echo "- At the end I wait for you to log in with your SSH key, then turn password logins off.")
$( [ "$PF_BEHIND_NAT" = 1 ] && echo "
This machine is behind NAT. Forward the ports above to ${PF_LOCAL_IP} on your router, or open them in your provider's firewall.")
Continue?
EOF
}

# The summary, in screens that each fit 80x24.
summary_running() {
    local running="the relay"
    [ "$CFG_TURN" = yes ] && running="$running, TURN"
    [ "$CFG_PUSH" = yes ] && running="$running, the push sender"
    [ "$CFG_FORWARDER" = yes ] && running="$running, the media forwarder"
    cat <<EOF
The address to type into the app:

  $CFG_HOST

In the app, open Settings > Network, press Change next to the relay, then Add a relay. Type the address, press Add, then Switch and restart (Switch and close on a phone). On a fresh install, the welcome screen takes it before an identity exists. Tap the button at the bottom that shows relay.anonlisten.com and type the address into the Relay address field.

Running: $running.
Members-only: $( [ "$CFG_MEMBERS_ONLY" = yes ] && echo "yes, $(member_count) keys." || echo "no, anyone with the address can connect.")
Public stats page: $(public_stats_text).
EOF
}

summary_ports() {
    cat <<EOF
Ports open in this machine's firewall:
$(ports_text)

If your provider has its own firewall in front of this machine, open the same ports there.$( [ "$PF_BEHIND_NAT" = 1 ] && echo " Behind a router, forward them to $PF_LOCAL_IP.")
EOF
}

summary_backup() {
    echo "Back these up somewhere safe, off this machine:"
    if [ "$CFG_MODE" = docker ]; then
        echo "  the Docker volumes ${COMPOSE_PROJECT}_data (the report counts) and ${COMPOSE_PROJECT}_fwd-data (the forwarder's identity)"
    else
        echo "  /var/lib/hollow-relay/reports.json, the report counts"
        [ "$CFG_FORWARDER" = yes ] &&
            echo "  /var/lib/hollow-forwarder/forwarder.key and forwarder.db, the forwarder's identity. With a new one, every viewer's app has to learn it again."
    fi
    # Only once SSH takes keys alone does losing the key lock anyone out.
    if [ "$DRY_RUN" != 1 ] && ! ssh_passwords_on; then
        printf '\n%s\n' "$(ssh_backup_note)"
    fi
    return 0
}

summary_end() {
    cat <<EOF
SSH: ${SSH_RESULT:-unchanged.}

Checks: ${CHECK_RESULT:-not run.}

To see the status, update, change a setting or remove the relay, run the setup again:
  sudo hollow-relay-setup
EOF
}

summary_screen() {
    run_checks
    ui_msg "Your relay is running" "$(summary_running)"
    [ "$CFG_MEMBERS_ONLY" = yes ] && ui_msg_keys "Members-only keys" "$(member_keys_shown)"
    ui_msg "Ports to open" "$(summary_ports)"
    ui_msg "What to back up" "$(summary_backup)"
    ui_msg "SSH and checks" "$(summary_end)"
    # whiptail clears its screens, so the whole summary is printed once more to
    # stay in the scrollback. The members-only keys stay out of it.
    if [ "$UI_MODE" = whiptail ]; then
        clear 2>/dev/null || true
        plain_header "Your relay is running" "$(summary_running)"
        [ "$CFG_MEMBERS_ONLY" = yes ] && printf '%s\n' "Run sudo hollow-relay-setup to see the keys to hand out again."
        plain_header "Ports to open" "$(summary_ports)"
        plain_header "What to back up" "$(summary_backup)"
        plain_header "SSH and checks" "$(summary_end)"
    fi
    return 0
}

run_checks() {
    [ "$DRY_RUN" = 1 ] && { CHECK_RESULT="not run in a dry run."; return 0; }
    step "Checking the machine (deploy/check-host.sh)"
    local out rc=0
    out=$(bash "$DEPLOY/check-host.sh" 2>&1) || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" = 0 ]; then
        CHECK_RESULT="all passed (sudo bash $INSTALLER_COPY/deploy/check-host.sh runs them again)."
    else
        CHECK_RESULT="some failed:
$(printf '%s\n' "$out" | grep FAIL | sed 's/^ *FAIL */  /')"
    fi
}

apply_all() {
    if [ "$CFG_MODE" = docker ]; then docker_apply; else native_apply; fi
}

# ---------------------------------------------------------------- main

# An update's last step: the new copy applies every setting again.
if [ "$AFTER_UPDATE" = 1 ]; then
    after_update_main
    exit 0
fi

# A swap of the setup's copy that was cut short is finished first.
[ "$(id -u)" = 0 ] && { setup_copy_repair || die "the setup's copy in $INSTALLER_COPY could not be put back in place."; }

# A take over that was killed part of the way comes first, whatever it wrote.
if adopt_interrupted; then
    adopt_resume_main
    exit 0
fi

if [ -r "$CONF_FILE" ]; then
    manage_main
    exit 0
fi

# A relay this setup did not install is never set up over: it is shown, then
# taken over or left alone.
adopt_detect
if [ "$ADOPT_KIND" != none ]; then
    adopt_main
    exit 0
fi

ui_msg "Hollow relay setup" \
"This sets up a Hollow relay on this machine. A relay is the server your group's apps connect to. It passes encrypted messages between people and briefly buffers them, encrypted and in memory only, for whoever is offline. It cannot read any of it.

First I check whether this machine can host a relay. Then I ask a few questions, one screen each, and show you the whole plan before anything changes. Until then you can stop at any point. Setting up takes about 5 to 10 minutes on a new server, longer if you build the programs here.

You can run the setup again whenever you like. It then shows what is running and lets you update or change things.$( [ "$DRY_RUN" = 1 ] && echo "

This is a dry run: I only show what I would do.")"

draft_offer
console_notice

step "Checking this machine"
preflight_run
# Two screens where one would not fit a standard terminal: the verdict and
# what needs doing, then what was found.
case "$PF_VERDICT" in
no)
    ui_msg "This machine cannot host a relay" "$PF_HEAD"
    ui_msg "What I found" "$PF_FOUND"
    exit 1 ;;
steps)
    ui_msg "Can this machine host a relay?" "$PF_HEAD"
    ui_yesno continue_anyway "What I found" "$PF_FOUND

Go on with the setup?" yes || { say "Stopped. Nothing was changed."; exit 0; } ;;
ok)
    ui_msg "Can this machine host a relay?" "$PF_TEXT" ;;
esac

ask_mode
if [ "$CFG_MODE" = native ]; then ask_binaries; else CFG_BINARIES=source; fi
ask_address
cert_answers
ask_turn
ask_push
ask_forwarder
ask_members
ask_public_stats
ask_grace
ssh_question
address_prepare
ssh_firewall_guard

ui_yesno confirm "Ready to set up" "$(plan_text)" yes || { say "Stopped. Nothing was changed."; exit 0; }

apply_all
draft_clear
ssh_run
summary_screen
