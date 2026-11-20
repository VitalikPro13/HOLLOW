#!/usr/bin/env bash
# Shared test machines, leased first-come-first-served between parallel Claude
# sessions on this Mac (every remote machine is reached from here, so one
# local lock directory covers them all). A lease that outlives its holder is
# reclaimed, never killed: the job it named may still be running somewhere.
#
#   scripts/lease.sh run <resource> [--who NAME] [--wait SEC] -- <command...>
#   scripts/lease.sh acquire <resource> [--who NAME] [--ttl MIN] [--wait SEC] [--what TEXT]
#   scripts/lease.sh renew <resource> <lease-id> [--ttl MIN]
#   scripts/lease.sh release <resource> <lease-id>
#   scripts/lease.sh status
#   scripts/lease.sh pick rust   (prints pc-build or mac-build: the less loaded one)
#
# `run` holds the lease for the command's life (bound to this process, no TTL)
# and exits with the command's code. `acquire` prints a lease id bound to a TTL
# (default 60 min) for jobs that outlive one shell; renew or release it.
# Exit codes: 3 = gave up waiting (--wait), 2 = usage.
# Bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
set -u

LEASE_DIR="${HOLLOW_LEASE_DIR:-$HOME/.hollow-leases}"

# Slots per resource; the build slots stop two teams compiling at once from
# starving the mini (cargo builds, nextest, flutter test, Xcode builds).
capacity_of() {
    case "$1" in
        mac-build) echo 2 ;;
        mac-ios-sims|mac-android|mac-desktop-app) echo 1 ;;
        # The PC idles otherwise: two Rust jobs at `-j 7` each leave it two threads.
        pc-build) echo 2 ;;
        pc-fleet|linux-vm|hollowsrv|vps-relay-tests) echo 1 ;;
        *) echo 0 ;;
    esac
}
KNOWN="mac-build mac-ios-sims mac-android mac-desktop-app pc-fleet pc-build linux-vm hollowsrv vps-relay-tests"

die() { echo "lease: $*" >&2; exit 2; }
now() { date +%s; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# The start time pins a pid against reuse.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

alive() { # file -> 0 if its holder or waiter still counts
    local f="$1" pid pstart exp beat
    pid=$(field "$f" pid)
    if [ -n "$pid" ]; then
        pstart=$(field "$f" pstart)
        [ -n "$(proc_start "$pid")" ] && [ "$(proc_start "$pid")" = "$pstart" ]
        return
    fi
    exp=$(field "$f" expires)
    beat=$(field "$f" beat)
    if [ -n "$exp" ]; then [ "$exp" -gt "$(now)" ]; return; fi
    [ -n "$beat" ] && [ $(( $(now) - beat )) -lt 180 ]
}

MUTEX="$LEASE_DIR/.mutex"
lock() {
    local tries=0
    mkdir -p "$LEASE_DIR"
    until mkdir "$MUTEX" 2>/dev/null; do
        tries=$((tries + 1))
        # A holder dies between mkdir and rmdir only on a kill -9; 30 s is far past any critical section.
        if [ "$tries" -gt 300 ]; then rmdir "$MUTEX" 2>/dev/null; tries=0; fi
        sleep 0.1
    done
}
unlock() { rmdir "$MUTEX" 2>/dev/null; }

next_seq() {
    local f="$LEASE_DIR/.seq" n
    n=$(cat "$f" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$f"
    printf '%012d' "$n"
}

reap() { # resource; caller holds the mutex
    local r="$1" f
    for f in "$LEASE_DIR/$r"/held/* "$LEASE_DIR/$r"/queue/*; do
        [ -f "$f" ] || continue
        if ! alive "$f"; then
            case "$f" in
                */held/*) echo "lease: reclaimed $r from $(field "$f" who) ($(field "$f" what)): holder gone or TTL passed; its job was NOT stopped" >&2 ;;
            esac
            rm -f "$f"
        fi
    done
}

check_resource() {
    [ -n "${1:-}" ] || die "name a resource: $KNOWN"
    [ "$(capacity_of "$1")" -gt 0 ] || die "unknown resource '$1'; known: $KNOWN"
}

# acquire <resource> <who> <what> <wait> <pid> <pstart> <expires>; prints the lease id
do_acquire() {
    local r="$1" who="$2" what="$3" wait="$4" pid="$5" pstart="$6" expires="$7"
    local cap ticket qf started held free rank t id last_note=0
    cap=$(capacity_of "$r")
    mkdir -p "$LEASE_DIR/$r/held" "$LEASE_DIR/$r/queue"
    started=$(now)
    lock
    ticket=$(next_seq)
    qf="$LEASE_DIR/$r/queue/$ticket"
    printf 'who=%s\nwhat=%s\npid=%s\npstart=%s\nbeat=%s\n' "$who" "$what" "$pid" "$pstart" "$(now)" > "$qf"
    unlock
    while :; do
        lock
        reap "$r"
        if [ ! -f "$qf" ]; then unlock; die "our queue ticket vanished"; fi
        held=$(find "$LEASE_DIR/$r/held" -type f | wc -l | tr -d ' ')
        free=$((cap - held))
        rank=$(ls "$LEASE_DIR/$r/queue" | sort | grep -n "^$ticket\$" | cut -d: -f1)
        if [ "$free" -gt 0 ] && [ "$rank" -le "$free" ]; then
            id="$ticket"
            printf 'who=%s\nwhat=%s\npid=%s\npstart=%s\nexpires=%s\nsince=%s\n' \
                "$who" "$what" "$pid" "$pstart" "$expires" "$(now)" > "$LEASE_DIR/$r/held/$id"
            rm -f "$qf"
            unlock
            echo "$id"
            return 0
        fi
        # Waiters without a pid stay alive by heartbeat.
        sed -i '' "s/^beat=.*/beat=$(now)/" "$qf" 2>/dev/null || sed -i "s/^beat=.*/beat=$(now)/" "$qf"
        unlock
        t=$(now)
        if [ "$wait" -ge 0 ] && [ $((t - started)) -ge "$wait" ]; then
            lock; rm -f "$qf"; unlock
            echo "lease: gave up on $r after ${wait}s" >&2
            return 3
        fi
        if [ $((t - last_note)) -ge 60 ]; then
            echo "lease: waiting for $r ($(holders_line "$r"); place $rank in queue)" >&2
            last_note=$t
        fi
        sleep 2
    done
}

holders_line() {
    local r="$1" f out=""
    for f in "$LEASE_DIR/$r"/held/*; do
        [ -f "$f" ] || continue
        out="$out${out:+, }$(field "$f" who): $(field "$f" what)"
    done
    echo "held by ${out:-nobody}"
}

parse_opts() { # sets WHO TTL WAIT WHAT; stops at --
    WHO="${HOLLOW_LEASE_WHO:-$(whoami)}"; TTL=60; WAIT=-1; WHAT=""
    REST=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --who) WHO="$2"; shift 2 ;;
            --ttl) TTL="$2"; shift 2 ;;
            --wait) WAIT="$2"; shift 2 ;;
            --what) WHAT="$2"; shift 2 ;;
            --) shift; REST=("$@"); return ;;
            *) die "unknown option '$1'" ;;
        esac
    done
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    run)
        r="${1:-}"; check_resource "$r"; shift
        parse_opts "$@"
        [ ${#REST[@]} -gt 0 ] || die "run needs -- <command>"
        [ -n "$WHAT" ] || WHAT="${REST[*]}"
        id=$(do_acquire "$r" "$WHO" "$WHAT" "$WAIT" "$$" "$(proc_start $$)" "") || exit $?
        trap 'lock; rm -f "$LEASE_DIR/$r/held/$id"; unlock' EXIT
        trap 'exit 130' INT TERM
        echo "lease: holding $r ($id)" >&2
        "${REST[@]}"
        exit $?
        ;;
    acquire)
        r="${1:-}"; check_resource "$r"; shift
        parse_opts "$@"
        do_acquire "$r" "$WHO" "${WHAT:-unnamed job}" "$WAIT" "" "" "$(( $(now) + TTL * 60 ))"
        ;;
    renew)
        r="${1:-}"; id="${2:-}"; check_resource "$r"; [ -n "$id" ] || die "renew needs a lease id"
        shift 2; parse_opts "$@"
        lock
        f="$LEASE_DIR/$r/held/$id"
        if [ ! -f "$f" ]; then unlock; echo "lease: $r $id is not held (reclaimed?)" >&2; exit 1; fi
        sed -i '' "s/^expires=.*/expires=$(( $(now) + TTL * 60 ))/" "$f"
        unlock
        ;;
    release)
        r="${1:-}"; id="${2:-}"; check_resource "$r"; [ -n "$id" ] || die "release needs a lease id"
        lock; rm -f "$LEASE_DIR/$r/held/$id"; unlock
        ;;
    pick)
        # Load = (held + queued) per slot; the PC wins a tie, since the Mac is
        # Vitalik's workstation and also runs every Flutter and Xcode job.
        [ "${1:-}" = rust ] || die "pick knows one kind: rust"
        mkdir -p "$LEASE_DIR"
        lock
        best=""; best_load=""
        for r in pc-build mac-build; do
            reap "$r" 2>/dev/null
            n=$(( $(find "$LEASE_DIR/$r/held" "$LEASE_DIR/$r/queue" -type f 2>/dev/null | wc -l) ))
            load=$(( n * 1000 / $(capacity_of "$r") ))
            if [ -z "$best" ] || [ "$load" -lt "$best_load" ]; then best=$r; best_load=$load; fi
        done
        unlock
        echo "$best"
        ;;
    status)
        mkdir -p "$LEASE_DIR"
        lock
        for r in $KNOWN; do
            reap "$r" 2>/dev/null
            printf '%-16s %s/%s  ' "$r" "$(find "$LEASE_DIR/$r/held" -type f 2>/dev/null | wc -l | tr -d ' ')" "$(capacity_of "$r")"
            line=$(holders_line "$r")
            q=$(ls "$LEASE_DIR/$r/queue" 2>/dev/null | sort | while read -r t; do printf '%s ' "$(field "$LEASE_DIR/$r/queue/$t" who)"; done)
            echo "$line${q:+; queue: $q}"
        done
        unlock
        ;;
    *)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
