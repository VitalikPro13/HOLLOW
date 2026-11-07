#!/usr/bin/env bash
# The Rust wire-parser fuzz targets (cargo-fuzz, libFuzzer + ASan, debug assertions on).
# Fuzzing never runs in public CI: a public repo's workflow artifacts would publish
# every crash input.
#
#   run.sh build                          build every target
#   run.sh seeds                          write the seed corpora and dictionaries
#   run.sh run [--secs N] [--par P] [--targets "a b"]
#                                         each target N s (default 300), P at once (default 4)
#   run.sh list                           the targets
#
# Everything lives under $FUZZ_RUST_ROOT (default ~/dev/fuzz-rust): target/ (cargo),
# seeds/<target>/ and dicts/ (rewritten by `seeds`), corpus/<target>/ (kept and
# minimized run to run), crashes/<stamp>/<target>/, logs/<stamp>/, summary.txt.
# A crash input that matters goes to fuzz/regressions/<target>/ with its fix, where
# `fuzz_entry::tests::fuzz_regressions_stay_fixed` replays it on every suite.
set -u
here=$(cd "$(dirname "$0")" && pwd)
crate=$(cd "$here/.." && pwd)
ROOT=${FUZZ_RUST_ROOT:-$HOME/dev/fuzz-rust}
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
TRIPLE=$(rustc +nightly -vV | sed -n 's/^host: //p')
BIN=${FUZZ_BIN:-$TARGET_DIR/$TRIPLE/release}
TARGETS=(relay_frames frame_seal haven_message message_envelope crdt_ops crdt_fold crdt_digest roster
    kill_order join_lock file_names message_sig link_preview hollowpack snapshot_zip archive_zip push_wake
    profile_card mls_message peer_images peer_ids share_wire image_check)

build() {
    mkdir -p "$ROOT"
    (cd "$crate" && CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4} cargo +nightly fuzz build -O -a --target-dir "$TARGET_DIR")
}

seeds() {
    rm -rf "$ROOT/seeds" "$ROOT/dicts"
    mkdir -p "$ROOT/seeds"
    python3 "$here/make_dicts.py" "$ROOT/dicts"
    (cd "$crate" && HOLLOW_FUZZ_SEEDS="$ROOT/seeds" CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4} \
        cargo test --lib --target-dir "$TARGET_DIR/seeds" -- --ignored --exact fuzz_entry::seeds::write_fuzz_seeds)
}

run_target() {
    local t=$1 secs=$2 logs=$3 crashes=$4 corpus=$ROOT/corpus/$1
    mkdir -p "$corpus" "$crashes/$t"
    local extra=()
    [ -d "$ROOT/seeds/$t" ] && extra+=("$ROOT/seeds/$t")
    [ -d "$here/regressions/$t" ] && extra+=("$here/regressions/$t")
    local dict=()
    [ -f "$ROOT/dicts/$t.dict" ] && dict=(-dict="$ROOT/dicts/$t.dict")
    # A crash ends a libFuzzer run, so the target runs again until its time is spent.
    # detect_leaks=0: libFuzzer's RSS thread leaks once at exit on macOS.
    local end=$((SECONDS + secs)) rc=0 run=0
    while [ $((end - SECONDS)) -gt 5 ] && [ "$run" -lt 50 ]; do
        run=$((run + 1))
        ASAN_OPTIONS=detect_leaks=0 nice -n 10 "$BIN/$t" ${dict[@]+"${dict[@]}"} -max_total_time=$((end - SECONDS)) \
            -timeout=25 -rss_limit_mb=2560 -max_len=65536 -print_final_stats=1 -artifact_prefix="$crashes/$t/" \
            "$corpus" ${extra[@]+"${extra[@]}"} >> "$logs/$t.log" 2>&1 || rc=$?
    done
    local merged=$ROOT/corpus/.$t.merge
    rm -rf "$merged" && mkdir -p "$merged"
    if ASAN_OPTIONS=detect_leaks=0 "$BIN/$t" -merge=1 -timeout=25 -rss_limit_mb=2560 "$merged" "$corpus" \
        > "$logs/$t.merge.log" 2>&1 && [ -n "$(ls -A "$merged")" ]; then
        rm -rf "$corpus" && mv "$merged" "$corpus"
    else
        rm -rf "$merged"
    fi
    local execs cov
    execs=$(grep -oE 'stat::number_of_executed_units: [0-9]+' "$logs/$t.log" | grep -oE '[0-9]+$' | paste -sd+ - | bc)
    cov=$(grep -E '^#[0-9]+' "$logs/$t.log" | grep -oE 'cov: [0-9]+ ft: [0-9]+' | tail -1)
    echo "$t rc=$rc runs=$run secs=$secs execs=${execs:-?} ${cov:-cov: ?} corpus=$(ls "$corpus" | wc -l | tr -d ' ')" \
        "crashes=$(ls "$crashes/$t" | wc -l | tr -d ' ')"
}

run_all() {
    local secs=300 par=4 only=""
    while [ $# -gt 0 ]; do
        case $1 in
            --secs) secs=$2; shift 2 ;;
            --par) par=$2; shift 2 ;;
            --targets) only=$2; shift 2 ;;
            *) echo "unknown option $1"; exit 2 ;;
        esac
    done
    local list=("${TARGETS[@]}")
    [ -n "$only" ] && read -r -a list <<< "$only"
    local stamp
    stamp=$(date '+%Y-%m-%d_%H%M')
    local logs=$ROOT/logs/$stamp crashes=$ROOT/crashes/$stamp
    mkdir -p "$logs"
    export -f run_target
    export ROOT BIN here
    printf '%s\n' "${list[@]}" |
        xargs -P "$par" -I{} bash -c 'run_target "$1" "$2" "$3" "$4"' _ {} "$secs" "$logs" "$crashes" > "$logs/summary.txt"
    sort -o "$logs/summary.txt" "$logs/summary.txt"
    { echo "$stamp rev=$(git -C "$crate" rev-parse --short HEAD 2> /dev/null) per_target=${secs}s"; cat "$logs/summary.txt"; } \
        > "$ROOT/summary.txt"
    cat "$ROOT/summary.txt"
    local found
    found=$(find "$crashes" -type f 2> /dev/null | wc -l | tr -d ' ')
    if [ "$found" = 0 ]; then
        rm -rf "$crashes"
    else
        echo "$found crash input(s) in $crashes"
        return 1
    fi
}

case ${1:-} in
    build) build ;;
    seeds) seeds ;;
    run) shift; run_all "$@" ;;
    list) printf '%s\n' "${TARGETS[@]}" ;;
    *) sed -n '2,16p' "$0"; exit 2 ;;
esac
