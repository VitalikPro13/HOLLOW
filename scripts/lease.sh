#!/usr/bin/env bash
# Shared test machines, leased first-come-first-served between parallel Claude
# sessions on this Mac (every remote machine is reached from here, so one
# local lock directory covers them all). A lease that outlives its holder is
# reclaimed, never killed: the job it named may still be running somewhere.
#
#   scripts/lease.sh run <resource> [--who NAME] [--wait SEC] [--slots N|half|all] [--heavy] [--tree DIR] -- <command...>
#   scripts/lease.sh acquire <resource> [--who NAME] [--ttl MIN] [--wait SEC] [--what TEXT] [--slots N|half|all] [--heavy] [--tree DIR]
#   scripts/lease.sh renew <resource> <lease-id> [--ttl MIN]
#   scripts/lease.sh release <resource> <lease-id>
#   scripts/lease.sh status
#   scripts/lease.sh pick rust [--suite|--heavy] [--unix] [--tree DIR] [--force]
#       prints pc-build, mac-build or cloud-build: the one with the most free
#       capacity per slot (why, on stderr). --suite = a full nextest suite (the
#       VM or the PC, never the Mac), --heavy = a mutation pass (the VM),
#       --unix = a unix-only crate (never the PC), --tree = the job's worktree.
#
# `run` holds the lease for the command's life (bound to this process, no TTL)
# and exits with the command's code. `acquire` prints a lease id bound to a TTL
# (default 60 min) for jobs that outlive one shell; renew or release it.
# --slots takes several slots at once (half = half the machine, all = the whole
# machine); the queue stays first come, first served. `run` exports LEASE_SLOTS
# and LEASE_CAP.
#   scripts/lease.sh busy <resource>   exit 0 when any lease is held or queued
# cloud-build starts itself: a lease while the VM is down asks
# scripts/cloud_vm.sh for a start and waits for it (about 70 s). It runs at
# AUTO_FLAVOR (scripts/cloud.conf); --heavy waits until it runs at HEAVY_FLAVOR:
# a down VM starts big, an idle one is resized, a busy one drains first (pick
# sends new jobs elsewhere, later tickets queue behind). The watchdog shrinks
# it back once no heavy lease is held or wanted and nothing is held.
# A file ~/.hollow-leases/<resource>.hold puts a machine on hold: `pick` skips
# it and run/acquire refuse with the file's text unless --force. A hold whose
# text names `--is-ancestor <commit>` lets through, without --force, a --tree
# whose HEAD contains that commit.
# Exit codes: 3 = gave up waiting (--wait), 4 = cloud-build cannot start
# (failed or over budget: pick rust again), 5 = on hold, 2 = usage.
# Bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
set -u

LEASE_DIR="${HOLLOW_LEASE_DIR:-$HOME/.hollow-leases}"
HERE_DIR=$(cd "$(dirname "$0")" && pwd)
AUTO_FLAVOR=c3-32-flex HEAVY_FLAVOR=c3-64-flex FAILED_HOLD_MIN=15 RESIZE_EST_S=180 MAC_MIN_FREE_GB=40 PC_MIN_FREE_GB=25
[ -f "${CLOUD_CONF:-$HERE_DIR/cloud.conf}" ] && . "${CLOUD_CONF:-$HERE_DIR/cloud.conf}"

# Slots per resource; the build slots stop two teams compiling at once from
# starving the mini (cargo builds, nextest, flutter test, Xcode builds).
capacity_of() {
    case "$1" in
        mac-build) echo 2 ;;
        mac-ios-sims|mac-android|mac-desktop-app) echo 1 ;;
        # The PC idles otherwise: two Rust jobs at `-j 7` each leave it two threads.
        pc-build) echo 2 ;;
        pc-fleet|linux-vm|hollowsrv|vps-relay-tests) echo 1 ;;
        # The rented OVH VM: scripts/cloud_vm.sh writes its slot count while an
        # instance is up and 0 once it is deleted, so nothing queues for a dead box.
        cloud-build) cat "$LEASE_DIR/cloud-build.slots" 2>/dev/null || echo 0 ;;
        *) echo 0 ;;
    esac
}
KNOWN="mac-build mac-ios-sims mac-android mac-desktop-app pc-fleet pc-build cloud-build linux-vm hollowsrv vps-relay-tests"
CLOUD_VM="${HOLLOW_CLOUD_VM:-$HERE_DIR/cloud_vm.sh}"
cloud_state() { sed -n 's/^state=//p' "$LEASE_DIR/cloud-state" 2>/dev/null | head -n 1; }
cloud_note() { sed -n 's/^note=//p' "$LEASE_DIR/cloud-state" 2>/dev/null | head -n 1; }
# The flavor the instance runs now (cloud_vm.sh writes it; a VM started before
# that file existed names it in its state note).
cloud_flavor() {
    local f
    f=$(head -n 1 "$LEASE_DIR/cloud-flavor" 2>/dev/null)
    if [ -z "$f" ] && [ "$(cloud_state)" = up ]; then
        f=$(cloud_note | awk '{print $1}'); case "$f" in *-flex) ;; *) f="" ;; esac
    fi
    echo "$f"
}
# Seconds a resize takes: the last one measured, else the configured guess.
resize_est() { local v; v=$(head -n 1 "$LEASE_DIR/cloud-resize.secs" 2>/dev/null); case "$v" in ''|*[!0-9]*) echo "$RESIZE_EST_S" ;; *) echo "$v" ;; esac; }
# Slots a flavor would get (c3-N-flex has N/2 vCPUs, 1 slot per 6): estimates only.
flavor_slots() { local n="${1#c3-}"; n="${n%-flex}"; case "$n" in ''|*[!0-9]*) echo 2; return ;; esac; n=$((n / 12)); [ "$n" -lt 1 ] && n=1; [ "$n" -gt 8 ] && n=8; echo "$n"; }

die() { echo "lease: $*" >&2; exit 2; }
now() { date +%s; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# A heavy lease runs at any size while a resize to HEAVY_FLAVOR failed lately.
heavy_degraded() {
    local at
    at=$(head -n 1 "$LEASE_DIR/cloud-heavy.failed" 2>/dev/null); [ -n "$at" ] || return 1
    [ $(( $(now) - at )) -lt $(( FAILED_HOLD_MIN * 60 )) ]
}
heavy_fits() { # 0 when a heavy lease may be granted at the VM's current size
    [ "$AUTO_FLAVOR" = "$HEAVY_FLAVOR" ] || [ "$(cloud_flavor)" = "$HEAVY_FLAVOR" ] || heavy_degraded
}
# The watchdog's shrink grace counts from the last heavy grant or release.
stamp_heavy() { now > "$LEASE_DIR/cloud-heavy.last.tmp.$$" && mv -f "$LEASE_DIR/cloud-heavy.last.tmp.$$" "$LEASE_DIR/cloud-heavy.last"; }

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

# The commit a hold lets through for --tree, when its text names one.
hold_commit() { grep -oE -- '--is-ancestor +[0-9a-f]{7,40}' "$1" 2>/dev/null | head -n 1 | awk '{print $2}'; }
tree_passes_hold() { # resource tree -> 0 when the tree's HEAD contains the commit the hold names
    local c
    [ -n "${2:-}" ] || return 1
    c=$(hold_commit "$LEASE_DIR/$1.hold"); [ -n "$c" ] || return 1
    git -C "$2" merge-base --is-ancestor "$c" HEAD 2>/dev/null
}
on_hold() { # resource [tree] -> 0 when the hold applies to this job
    [ -f "$LEASE_DIR/$1.hold" ] || return 1
    ! tree_passes_hold "$1" "${2:-}"
}

hold_check() { # resource; refuses a held machine unless --force or a --tree the hold lets through
    local f="$LEASE_DIR/$1.hold"
    [ -f "$f" ] || return 0
    if tree_passes_hold "$1" "${TREE:-}"; then echo "lease: $1 is on hold; $TREE contains $(hold_commit "$f"), so it may run" >&2; return 0; fi
    [ "${FORCE:-0}" = 1 ] && { echo "lease: $1 is on hold, taken anyway (--force)" >&2; return 0; }
    echo "lease: $1 is ON HOLD: $(cat "$f")" >&2
    echo "lease: run 'bash scripts/lease.sh pick rust --tree <worktree>' for another machine (or --force if you must)" >&2
    exit 5
}

check_resource() {
    [ -n "${1:-}" ] || die "name a resource: $KNOWN"
    case " $KNOWN " in *" $1 "*) ;; *) die "unknown resource '$1'; known: $KNOWN" ;; esac
    # cloud-build at 0 slots is down: the lease starts it.
    [ "$1" = cloud-build ] || [ "$(capacity_of "$1")" -gt 0 ] || die "'$1' has no slots now"
}

# Slots a held or queued file takes: its slots= field (1 when absent), "all" =
# the whole capacity, "half" = half of it, never more than the capacity, at least 1.
weight_of() { # file cap
    local w
    w=$(field "$1" slots); w=${w:-1}
    [ "$w" = all ] && w=$2
    [ "$w" = half ] && w=$(( $2 / 2 ))
    [ "$w" -gt "$2" ] 2>/dev/null && w=$2
    [ "$w" -lt 1 ] 2>/dev/null && w=1
    echo "$w"
}
slots_held() { # resource cap
    local f n=0
    for f in "$LEASE_DIR/$1"/held/*; do [ -f "$f" ] && n=$((n + $(weight_of "$f" "$2"))); done
    echo "$n"
}
slots_used() { # resource cap: held plus queued
    local f n
    n=$(slots_held "$1" "$2")
    for f in "$LEASE_DIR/$1"/queue/*; do [ -f "$f" ] && n=$((n + $(weight_of "$f" "$2"))); done
    echo "$n"
}
# "held_heavy queued_heavy held queued oldest_heavy_queued_epoch" of cloud-build; caller holds the mutex.
heavy_counts() {
    local f hh=0 qh=0 h=0 q=0 old="" t
    for f in "$LEASE_DIR/cloud-build"/held/*; do
        [ -f "$f" ] || continue; h=$((h + 1)); [ "$(field "$f" heavy)" = 1 ] && hh=$((hh + 1))
    done
    for f in "$LEASE_DIR/cloud-build"/queue/*; do
        [ -f "$f" ] || continue; q=$((q + 1))
        if [ "$(field "$f" heavy)" = 1 ]; then
            qh=$((qh + 1)); t=$(field "$f" queued); t=${t:-$(now)}
            if [ -z "$old" ] || [ "$t" -lt "$old" ]; then old=$t; fi
        fi
    done
    echo "$hh $qh $h $q ${old:-0}"
}

# What a heavy ticket still waits for while the VM runs at the normal size.
heavy_wait_line() {
    local f n=0 oldest="" s
    for f in "$LEASE_DIR/cloud-build"/held/*; do
        [ -f "$f" ] || continue; n=$((n + 1)); s=$(field "$f" since); s=${s:-$(now)}
        if [ -z "$oldest" ] || [ "$s" -lt "$oldest" ]; then oldest=$s; fi
    done
    if [ "$n" -gt 0 ]; then
        echo "draining $n running lease(s), the oldest $(( ($(now) - oldest) / 60 )) min old ($(holders_line cloud-build)); new jobs go elsewhere"
    else
        echo "no lease left; the watchdog resizes within a minute (once no build or test runs on the VM)"
    fi
}

# acquire <resource> <who> <what> <wait> <pid> <pstart> <expires> [slots] [heavy]; prints the lease id
do_acquire() {
    local r="$1" who="$2" what="$3" wait="$4" pid="$5" pstart="$6" expires="$7" want="${8:-1}" heavy="${9:-0}"
    local cap ticket qf started held free rank t id last_note=0 ahead w ok asked=0 kicked=0 cst msg fits blocked tf
    mkdir -p "$LEASE_DIR/$r/held" "$LEASE_DIR/$r/queue"
    [ "$r" = cloud-build ] || heavy=0
    started=$(now)
    lock
    ticket=$(next_seq)
    qf="$LEASE_DIR/$r/queue/$ticket"
    printf 'who=%s\nwhat=%s\npid=%s\npstart=%s\nbeat=%s\nslots=%s\nqueued=%s\n' "$who" "$what" "$pid" "$pstart" "$(now)" "$want" "$(now)" > "$qf"
    [ "$heavy" = 1 ] && echo "heavy=1" >> "$qf"
    unlock
    while :; do
        cap=$(capacity_of "$r")
        if [ "$r" = cloud-build ] && [ "$cap" -le 0 ]; then
            # Down: ask for a start (single flight in cloud_vm.sh), at most every 30 s.
            cst=$(cloud_state)
            if [ "$cst" = failed ] || [ $(( $(now) - asked )) -ge 30 ]; then
                asked=$(now)
                if ! msg=$(bash "$CLOUD_VM" request-start 2>&1); then
                    lock; rm -f "$qf"; unlock
                    echo "lease: ${msg:-cloud-build cannot start}; run 'bash scripts/lease.sh pick rust' for pc-build or mac-build" >&2
                    return 4
                fi
            fi
        elif [ "$heavy" = 1 ] && ! heavy_fits && [ $(( $(now) - kicked )) -ge 30 ]; then
            # Up at the normal size: the watchdog resizes once nothing is held; wake it now.
            kicked=$(now)
            bash "$CLOUD_VM" kick > /dev/null 2>&1
        fi
        lock
        reap "$r"
        if [ ! -f "$qf" ]; then unlock; die "our queue ticket vanished"; fi
        # Re-read under the mutex: a resize or a delete zeroes the slots under it.
        cap=$(capacity_of "$r")
        held=$(slots_held "$r" "$cap")
        free=$((cap - held))
        rank=$(ls "$LEASE_DIR/$r/queue" | sort | grep -n "^$ticket\$" | cut -d: -f1)
        # Granted when the slots of every ticket ahead plus ours fit in what is
        # free, and no heavy ticket (ours or one ahead) still waits for the big size.
        ok=0; ahead=0; blocked=0; fits=1
        if [ "$r" = cloud-build ] && ! heavy_fits; then fits=0; fi
        if [ "$cap" -gt 0 ]; then
            for t in $(ls "$LEASE_DIR/$r/queue" | sort); do
                tf="$LEASE_DIR/$r/queue/$t"
                [ "$fits" = 0 ] && [ "$(field "$tf" heavy)" = 1 ] && blocked=1
                ahead=$((ahead + $(weight_of "$tf" "$cap")))
                if [ "$t" = "$ticket" ]; then [ "$blocked" = 0 ] && [ "$ahead" -le "$free" ] && ok=1; break; fi
            done
        fi
        if [ "$ok" = 1 ]; then
            id="$ticket"
            w=$(weight_of "$qf" "$cap")
            printf 'who=%s\nwhat=%s\npid=%s\npstart=%s\nexpires=%s\nsince=%s\nslots=%s\n' \
                "$who" "$what" "$pid" "$pstart" "$expires" "$(now)" "$w" > "$LEASE_DIR/$r/held/$id"
            if [ "$heavy" = 1 ]; then echo "heavy=1" >> "$LEASE_DIR/$r/held/$id"; stamp_heavy; fi
            rm -f "$qf"
            unlock
            if [ "$heavy" = 1 ] && [ "$AUTO_FLAVOR" != "$HEAVY_FLAVOR" ] && [ "$(cloud_flavor)" != "$HEAVY_FLAVOR" ]; then
                echo "lease: the resize to $HEAVY_FLAVOR failed lately; this heavy job runs at $(cloud_flavor)" >&2
            fi
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
            if [ "$r" = cloud-build ] && [ "$cap" -le 0 ]; then
                case "$(cloud_note)" in
                    resize*) echo "lease: waiting for cloud-build: $(cloud_note) (~$(resize_est) s; $((t - started)) s so far)" >&2 ;;
                    *) echo "lease: waiting for cloud-build: starting (~70 s; $((t - started)) s so far)" >&2 ;;
                esac
            elif [ "$r" = cloud-build ] && [ "$blocked" = 1 ]; then
                echo "lease: waiting for cloud-build at $HEAVY_FLAVOR (now $(cloud_flavor)): $(heavy_wait_line), then a resize (~$(resize_est) s); $((t - started)) s so far" >&2
            else
                echo "lease: waiting for $r ($(holders_line "$r"); place $rank in queue)" >&2
            fi
            last_note=$t
        fi
        sleep 2
    done
}

holders_line() {
    local r="$1" f out="" s h
    for f in "$LEASE_DIR/$r"/held/*; do
        [ -f "$f" ] || continue
        s=$(field "$f" slots); h=""; [ "$(field "$f" heavy)" = 1 ] && h=", heavy"
        out="$out${out:+, }$(field "$f" who)${s:+ [$s slot(s)$h]}: $(field "$f" what)"
    done
    echo "held by ${out:-nobody}"
}

parse_opts() { # sets WHO TTL WAIT WHAT SLOTSREQ FORCE HEAVY TREE; stops at --
    WHO="${HOLLOW_LEASE_WHO:-$(whoami)}"; TTL=60; WAIT=-1; WHAT=""; SLOTSREQ=1; FORCE=0; HEAVY=0; TREE=""
    REST=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --who) WHO="$2"; shift 2 ;;
            --ttl) TTL="$2"; shift 2 ;;
            --wait) WAIT="$2"; shift 2 ;;
            --what) WHAT="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            --heavy) HEAVY=1; shift ;;
            --tree) TREE="$2"; shift 2 ;;
            --slots) SLOTSREQ="$2"; shift 2
                case "$SLOTSREQ" in all|half|[1-9]|[1-9][0-9]) ;; *) die "--slots takes a number, half or all" ;; esac ;;
            --) shift; REST=("$@"); return ;;
            *) die "unknown option '$1'" ;;
        esac
    done
}

mac_free_gb() {
    if [ -n "${HOLLOW_MAC_FREE_GB:-}" ]; then echo "$HOLLOW_MAC_FREE_GB"; return; fi
    df -k "$HOME" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'
}

# Free GB on the PC's D: (empty when the PC does not answer within a few seconds).
# A full D: failed builds with os error 112 twice on Nov 23 while pick kept choosing it.
pc_free_gb() {
    if [ -n "${HOLLOW_PC_FREE_GB:-}" ]; then echo "$HOLLOW_PC_FREE_GB"; return; fi
    # DriveInfo, not Get-PSDrive: over ssh Get-PSDrive reports 0 free.
    ssh -o ConnectTimeout=5 -o BatchMode=yes pc "powershell -NoProfile -Command \"[int]((New-Object System.IO.DriveInfo('D')).AvailableFreeSpace/1GB)\"" 2>/dev/null | tr -dc '0-9'
}

# pick rust: each machine becomes a row "name cap used avoid" (avoid 1 = the VM
# is down or oversized: only when the others are full; 2 = draining for a heavy
# job: only when nothing else is left), then the awk below chooses.
cmd_pick() {
    local kind="${1:-}" mode=normal unix=0 tree="" force=0 r c u fl hh qh h q old note="" g avoid cands rows best
    local ccap cstart=0 cwhy=""
    [ "$kind" = rust ] || die "pick knows one kind: rust"
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --suite) mode=suite; shift ;;
            --heavy) mode=heavy; shift ;;
            --unix) unix=1; shift ;;
            --tree) tree="${2:-}"; shift 2 ;;
            --force) force=1; shift ;;
            *) die "pick rust takes --suite, --heavy, --unix, --tree DIR, --force" ;;
        esac
    done
    mkdir -p "$LEASE_DIR"
    cands="cloud-build pc-build mac-build"
    [ "$mode" = normal ] || cands="cloud-build pc-build"
    [ "$unix" = 1 ] && cands=$(echo "$cands" | sed 's/ *pc-build//')
    local pcg=""
    case " $cands " in *" pc-build "*) pcg=$(pc_free_gb) ;; esac
    ccap=$(capacity_of cloud-build)
    if ! [ "$ccap" -gt 0 ] 2>/dev/null; then
        if cwhy=$(bash "$CLOUD_VM" startable 2>&1); then cstart=1; fi
    fi
    lock
    rows=""
    for r in $cands; do
        if [ "$force" = 0 ] && on_hold "$r" "$tree"; then
            note="$note; $r on hold"
            if [ -n "$(hold_commit "$LEASE_DIR/$r.hold")" ]; then
                if [ -z "$tree" ]; then note="$note (pass --tree <worktree>: a tree containing $(hold_commit "$LEASE_DIR/$r.hold") may use it)"
                else note="$note ($tree lacks $(hold_commit "$LEASE_DIR/$r.hold"))"; fi
            fi
            continue
        fi
        if [ "$r" = mac-build ]; then
            g=$(mac_free_gb)
            if [ "${g:-0}" -lt "$MAC_MIN_FREE_GB" ] 2>/dev/null; then note="$note; mac-build skipped: the Mac has ${g:-?} GB free (< $MAC_MIN_FREE_GB)"; continue; fi
        fi
        if [ "$r" = pc-build ] && ! [ "${pcg:-0}" -ge "$PC_MIN_FREE_GB" ] 2>/dev/null; then
            note="$note; pc-build skipped: D: has ${pcg:-?} GB free (< $PC_MIN_FREE_GB)"; continue
        fi
        avoid=0
        if [ "$r" = cloud-build ]; then
            if [ "$ccap" -gt 0 ] 2>/dev/null; then
                c=$ccap; reap "$r" 2>/dev/null; u=$(slots_used "$r" "$c")
                fl=$(cloud_flavor)
                read -r hh qh h q old <<< "$(heavy_counts)"
                if [ "$qh" -gt 0 ] && ! heavy_fits && [ "$mode" != heavy ]; then
                    avoid=2; note="$note; cloud-build is draining for a heavy job"
                elif [ "$mode" = normal ] && [ "$fl" = "$HEAVY_FLAVOR" ] && [ "$fl" != "$AUTO_FLAVOR" ] && [ "$hh" = 0 ] && [ "$qh" = 0 ]; then
                    avoid=1; note="$note; cloud-build still runs at $fl with no heavy job (it shrinks once empty)"
                fi
            else
                if [ "$cstart" = 0 ]; then note="$note; cloud-build cannot start now ($cwhy)"; continue; fi
                # Down or (re)starting: count the slots it would bring.
                if [ "$mode" = heavy ]; then c=$(flavor_slots "$HEAVY_FLAVOR"); else c=$(flavor_slots "$AUTO_FLAVOR"); fi
                u=$(find "$LEASE_DIR/$r/queue" -type f 2>/dev/null | wc -l | tr -d ' ')
                [ "$mode" = normal ] && avoid=1
            fi
        else
            c=$(capacity_of "$r"); reap "$r" 2>/dev/null; u=$(slots_used "$r" "$c")
        fi
        rows="$rows$r $c $u $avoid
"
    done
    unlock
    best=$(printf '%s' "$rows" | awk -v mode="$mode" '
        NF == 4 { n++; name[n] = $1; cap[n] = $2; used[n] = $3; av[n] = $4 }
        END {
            b = 0
            # A mutation pass goes to the VM whenever it can run there.
            if (mode == "heavy") for (i = 1; i <= n; i++) if (name[i] == "cloud-build") b = i
            # 1. The most free capacity per slot among machines we are glad to use;
            #    row order breaks ties (the VM bills while up, then the PC, then the
            #    Mac). A full suite takes the VM first whenever it has room.
            if (!b) for (i = 1; i <= n; i++) {
                if (av[i] != 0 || used[i] >= cap[i]) continue
                f = (cap[i] - used[i]) / cap[i]
                if (mode == "suite" && name[i] == "cloud-build") f += 10
                if (!b || f > bf) { b = i; bf = f }
            }
            # 2. Others full: a down or oversized VM with room.
            if (!b) for (i = 1; i <= n; i++) if (av[i] == 1 && used[i] < cap[i]) { b = i; break }
            # 3. Everyone full: the shortest queue per slot, never the draining VM.
            if (!b) for (i = 1; i <= n; i++) {
                if (av[i] == 2) continue
                l = used[i] / cap[i]
                if (!b || l < bl) { b = i; bl = l }
            }
            if (!b && n > 0) b = 1
            if (b) print name[b]
        }')
    [ -n "$note" ] && echo "pick:${note#;}" >&2
    if [ -z "$best" ]; then echo "lease: pick found no machine (all on hold or out of disk)" >&2; exit 1; fi
    echo "$best"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    run)
        r="${1:-}"; check_resource "$r"; shift
        parse_opts "$@"
        hold_check "$r"
        [ ${#REST[@]} -gt 0 ] || die "run needs -- <command>"
        [ -n "$WHAT" ] || WHAT="${REST[*]}"
        id=$(do_acquire "$r" "$WHO" "$WHAT" "$WAIT" "$$" "$(proc_start $$)" "" "$SLOTSREQ" "$HEAVY") || exit $?
        trap 'lock; rm -f "$LEASE_DIR/$r/held/$id"; unlock; if [ "$HEAVY" = 1 ]; then stamp_heavy; fi' EXIT
        # What the command was granted, so it can size its threads to its share.
        LEASE_SLOTS=$(field "$LEASE_DIR/$r/held/$id" slots); LEASE_CAP=$(capacity_of "$r")
        export LEASE_SLOTS="${LEASE_SLOTS:-1}" LEASE_CAP
        trap 'exit 130' INT TERM
        echo "lease: holding $r ($id)" >&2
        "${REST[@]}"
        exit $?
        ;;
    acquire)
        r="${1:-}"; check_resource "$r"; shift
        parse_opts "$@"
        hold_check "$r"
        do_acquire "$r" "$WHO" "${WHAT:-unnamed job}" "$WAIT" "" "" "$(( $(now) + TTL * 60 ))" "$SLOTSREQ" "$HEAVY"
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
        lock
        if [ "$(field "$LEASE_DIR/$r/held/$id" heavy)" = 1 ]; then stamp_heavy; fi
        rm -f "$LEASE_DIR/$r/held/$id"; unlock
        ;;
    busy)
        r="${1:-}"; check_resource "$r"
        lock; reap "$r" 2>/dev/null
        n=$(find "$LEASE_DIR/$r/held" "$LEASE_DIR/$r/queue" -type f 2>/dev/null | wc -l | tr -d ' ')
        unlock
        [ "$n" -gt 0 ]
        ;;
    heavy)
        # For cloud_vm.sh: "held_heavy queued_heavy held queued oldest_heavy_queued_epoch".
        mkdir -p "$LEASE_DIR/cloud-build/held" "$LEASE_DIR/cloud-build/queue"
        lock; reap cloud-build 2>/dev/null; out=$(heavy_counts); unlock
        echo "$out"
        ;;
    pick)
        cmd_pick "$@"
        ;;
    status)
        mkdir -p "$LEASE_DIR"
        # Printed after unlock: a reader that quits early (| head, grep -q) must
        # not kill us while we hold the mutex.
        lock
        out=$(for r in $KNOWN; do
            reap "$r" 2>/dev/null
            printf '%-16s %s/%s  ' "$r" "$(slots_held "$r" "$(capacity_of "$r")")" "$(capacity_of "$r")"
            line=$(holders_line "$r")
            [ -f "$LEASE_DIR/$r.hold" ] && line="ON HOLD ($(head -c 80 "$LEASE_DIR/$r.hold")...); $line"
            if [ "$r" = cloud-build ]; then
                cst=$(cloud_state)
                case "$cst" in
                    (starting) since=$(sed -n 's/^since=//p' "$LEASE_DIR/cloud-state"); since=${since:-$(now)}
                        case "$(cloud_note)" in
                            (resize*) line="cloud-build $(cloud_note) (~$(resize_est) s; $(( $(now) - since )) s so far); $line" ;;
                            (*) line="cloud-build starting (~70 s; $(( $(now) - since )) s so far); $line" ;;
                        esac ;;
                    (failed) line="cloud-build failed to start: $(sed -n 's/^note=//p' "$LEASE_DIR/cloud-state"); $line" ;;
                    (''|down) [ "$(capacity_of cloud-build)" -gt 0 ] 2>/dev/null || line="down (a lease starts it); $line" ;;
                esac
                if [ "$(capacity_of cloud-build)" -gt 0 ] 2>/dev/null; then
                    read -r hh qh h q old <<< "$(heavy_counts)"
                    fl=$(cloud_flavor); extra="${fl:-?}"
                    if [ "$qh" -gt 0 ] && ! heavy_fits; then extra="$extra; heavy wanted: $(heavy_wait_line), then a resize to $HEAVY_FLAVOR (~$(resize_est) s)"
                    elif [ "$fl" = "$HEAVY_FLAVOR" ] && [ "$fl" != "$AUTO_FLAVOR" ] && [ "$hh" = 0 ] && [ "$qh" = 0 ]; then extra="$extra; no heavy job: shrinks to $AUTO_FLAVOR once empty"
                    fi
                    heavy_degraded && extra="$extra; the resize to $HEAVY_FLAVOR failed lately, heavy jobs run at any size"
                    line="[$extra] $line"
                fi
            fi
            q=$(ls "$LEASE_DIR/$r/queue" 2>/dev/null | sort | while read -r t; do hv=""; [ "$(field "$LEASE_DIR/$r/queue/$t" heavy)" = 1 ] && hv="(heavy)"; printf '%s%s ' "$(field "$LEASE_DIR/$r/queue/$t" who)" "$hv"; done)
            echo "$line${q:+; queue: $q}"
        done)
        unlock
        echo "$out"
        ;;
    *)
        sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
