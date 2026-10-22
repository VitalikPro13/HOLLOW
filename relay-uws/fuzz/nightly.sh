#!/usr/bin/env bash
# The relay fuzz targets, nightly on the Mac mini. Fuzzing never runs in public CI:
# a public repo's workflow artifacts would publish every crash input.
#
#   nightly.sh run [--budget SECS] [--src DIR] [--par N]   one run (default 3600 s, ~/src/HOLLOW)
#   nightly.sh install [--seed-corpus DIR]                 copy this script to ~/dev/fuzz-nightly,
#                                                          load the 03:30 launchd agent
#   nightly.sh uninstall                                   unload and remove the agent
#
# The source tree is only read: it is copied to a snapshot first, and everything else
# lives under ~/dev/fuzz-nightly: build/ (targets), corpus/<target>/ (kept and minimized
# run to run), crashes/<date>/<target>/, logs/<date>/ (7 days), summary.txt (the last
# run), history.txt (a line per run), CRASH_<date>.txt (written only when a target
# crashed, with a macOS notification).
set -u
ROOT=${FUZZ_NIGHTLY_ROOT:-$HOME/dev/fuzz-nightly}
LABEL=com.anonlisten.hollow.fuzz-nightly
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
TARGETS=(fuzz_auth_frame fuzz_binary_frame fuzz_client_json fuzz_ring_auth fuzz_join_lock fuzz_roster
    fuzz_kill_order fuzz_snapshot_codec fuzz_crypto_inputs)
here=$(cd "$(dirname "$0")" && pwd)

notify() {
    osascript -e "display notification \"$1\" with title \"Hollow relay fuzz\"" > /dev/null 2>&1 || true
}

install_agent() {
    local seed=""
    [ "${1:-}" = --seed-corpus ] && seed=${2:-}
    mkdir -p "$ROOT" "$HOME/Library/LaunchAgents"
    cp "$here/nightly.sh" "$ROOT/nightly.sh"
    chmod +x "$ROOT/nightly.sh"
    if [ -n "$seed" ]; then
        for t in "${TARGETS[@]}"; do
            [ -d "$seed/$t" ] || continue
            mkdir -p "$ROOT/corpus/$t"
            cp -Rn "$seed/$t/." "$ROOT/corpus/$t/" 2> /dev/null || true
        done
    fi
    sed -e "s|__HOME__|$HOME|g" "$here/$LABEL.plist" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "loaded $LABEL (03:30 daily), runs $ROOT/nightly.sh"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    rm -f "$PLIST"
    echo "unloaded $LABEL; $ROOT kept"
}

run_target() {
    local t=$1 secs=$2 out=$3 logs=$4 crashes=$5 corpus=$ROOT/corpus/$1
    mkdir -p "$corpus" "$crashes/$t"
    if [ -f "$out/${t}_seed_corpus.zip" ]; then
        (cd "$corpus" && unzip -qn "$out/${t}_seed_corpus.zip" 2> /dev/null)
    fi
    local dict=()
    [ -f "$out/$t.dict" ] && dict=(-dict="$out/$t.dict")
    # detect_leaks=0: libFuzzer's RSS thread leaks once at exit on macOS.
    ASAN_OPTIONS=detect_leaks=0 "$out/$t" ${dict[@]+"${dict[@]}"} -max_total_time="$secs" -timeout=25 \
        -rss_limit_mb=2560 -max_len=65536 -print_final_stats=1 -artifact_prefix="$crashes/$t/" "$corpus" \
        > "$logs/$t.log" 2>&1
    local rc=$?
    # Keep only the inputs that add coverage.
    local merged=$ROOT/corpus/.$t.merge
    rm -rf "$merged" && mkdir -p "$merged"
    if ASAN_OPTIONS=detect_leaks=0 "$out/$t" -merge=1 -timeout=25 -rss_limit_mb=2560 "$merged" "$corpus" \
        > "$logs/$t.merge.log" 2>&1 && [ -n "$(ls -A "$merged")" ]; then
        rm -rf "$corpus" && mv "$merged" "$corpus"
    else
        rm -rf "$merged"
    fi
    local execs cov
    execs=$(grep -oE 'stat::number_of_executed_units: [0-9]+' "$logs/$t.log" | grep -oE '[0-9]+$')
    cov=$(grep -E '^#[0-9]+' "$logs/$t.log" | grep -oE 'cov: [0-9]+ ft: [0-9]+' | tail -1)
    echo "$t rc=$rc secs=$secs execs=${execs:-?} ${cov:-cov: ?} corpus=$(ls "$corpus" | wc -l | tr -d ' ')" \
        "crashes=$(ls "$crashes/$t" | wc -l | tr -d ' ')"
}

run_nightly() {
    local budget=3600 src=$HOME/src/HOLLOW par=5
    local args=("$@")
    while [ $# -gt 0 ]; do
        case $1 in
            --budget) budget=$2; shift 2 ;;
            --src) src=$2; shift 2 ;;
            --par) par=$2; shift 2 ;;
            *) echo "unknown option $1"; exit 2 ;;
        esac
    done
    # The installed copy runs the source tree's script when that one changed.
    local current=$src/relay-uws/fuzz/nightly.sh
    if [ -z "${FUZZ_NIGHTLY_REEXEC:-}" ] && [ -f "$current" ] && ! cmp -s "$current" "$0"; then
        FUZZ_NIGHTLY_REEXEC=1 exec bash "$current" run ${args[@]+"${args[@]}"}
    fi
    mkdir -p "$ROOT"
    # One run at a time: launchd never starts a running job twice, a manual run might.
    if ! mkdir "$ROOT/run.lock" 2> /dev/null; then
        if kill -0 "$(cat "$ROOT/run.lock/pid" 2> /dev/null)" 2> /dev/null; then
            echo "$(date '+%F %T') skipped: a previous run is still going" >> "$ROOT/history.txt"
            exit 0
        fi
        rm -rf "$ROOT/run.lock" && mkdir "$ROOT/run.lock"
    fi
    echo $$ > "$ROOT/run.lock/pid"
    trap 'rm -rf "$ROOT/run.lock"' EXIT

    local stamp
    stamp=$(date '+%Y-%m-%d_%H%M')
    local logs=$ROOT/logs/$stamp crashes=$ROOT/crashes/$stamp snap=$ROOT/src
    mkdir -p "$logs"
    find "$ROOT/logs" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2> /dev/null

    if [ ! -f "$src/relay-uws/fuzz/build.sh" ]; then
        echo "$stamp skipped: no relay-uws/fuzz in $src" | tee -a "$ROOT/history.txt" > "$ROOT/summary.txt"
        exit 0
    fi
    rm -rf "$snap" && mkdir -p "$snap/relay-uws"
    cp -R "$src/relay-uws/src" "$src/relay-uws/test" "$src/relay-uws/fuzz" "$snap/relay-uws/"
    local rev
    rev=$(git -C "$src" rev-parse --short HEAD 2> /dev/null || echo "?")

    local out=$ROOT/build
    rm -rf "$out"
    if ! env -u OUT bash "$snap/relay-uws/fuzz/build.sh" "$out" > "$logs/build.log" 2>&1; then
        echo "$stamp BUILD FAILED at $rev (logs/$stamp/build.log)" | tee -a "$ROOT/history.txt" > "$ROOT/summary.txt"
        notify "Nightly relay fuzz build failed, see ~/dev/fuzz-nightly/summary.txt"
        exit 1
    fi

    # Every target gets the same time; the waves of PAR targets fill the budget.
    local n=${#TARGETS[@]}
    local waves=$(((n + par - 1) / par))
    local secs=$((budget / waves))
    [ "$secs" -lt 10 ] && secs=10
    export -f run_target
    export ROOT
    printf '%s\n' "${TARGETS[@]}" |
        xargs -P "$par" -I{} bash -c 'run_target "$1" "$2" "$3" "$4" "$5"' _ {} "$secs" "$out" "$logs" "$crashes" \
            > "$logs/summary.txt"
    sort -o "$logs/summary.txt" "$logs/summary.txt"
    { echo "$stamp rev=$rev budget=${budget}s per_target=${secs}s"; cat "$logs/summary.txt"; } > "$ROOT/summary.txt"

    local found
    found=$(find "$crashes" -type f 2> /dev/null | wc -l | tr -d ' ')
    local failed
    failed=$(grep -vc ' rc=0 ' "$logs/summary.txt")
    if [ "$found" != 0 ] || [ "$failed" != 0 ]; then
        local report=$ROOT/CRASH_$stamp.txt
        {
            echo "Relay fuzz run $stamp at $rev: $found crash input(s), $failed target(s) not rc=0."
            echo "Replay one: $out/<target> <input>; inputs in $crashes/; logs in $logs/."
            echo
            cat "$logs/summary.txt"
            for f in $(find "$crashes" -type f); do
                local t
                t=$(basename "$(dirname "$f")")
                echo
                echo "== $t: $f"
                grep -m1 -A15 -E 'ERROR|invariant failed|runtime error|deadly signal' "$logs/$t.log"
            done
        } > "$report"
        echo "$stamp rev=$rev CRASH ($found inputs) -> $report" >> "$ROOT/history.txt"
        notify "Relay fuzzing found $found crash input(s): ~/dev/fuzz-nightly/CRASH_$stamp.txt"
    else
        echo "$stamp rev=$rev ok ($n targets x ${secs}s)" >> "$ROOT/history.txt"
        rmdir "$crashes"/* "$crashes" 2> /dev/null
    fi
}

case ${1:-} in
    run) shift; run_nightly "$@" ;;
    install) shift; install_agent "$@" ;;
    uninstall) uninstall_agent ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
