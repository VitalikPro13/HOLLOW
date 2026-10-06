#!/bin/bash
# The end-to-end resume test (RESUMABLE_SESSIONS_PLAN.md section 6): the real relay,
# the zombie proxy (tools/zombie_proxy) and the real ws_client
# (rust/hollow_core/src/node/resume_e2e.rs), all on this machine. A and B join a room
# and send each other a counted stream of frames; B's path through the proxy is
# frozen for a window (no FIN, no RST: a silent dead path) and then thawed or
# dropped; the test counts what never arrived. Every window gets a fresh relay (its
# per-address budget is ten new sockets a minute) and a fresh proxy.
#
#   bash scripts/resume_e2e.sh --relay-src ~/Documents/HOLLOW/relay-uws --windows 5,30,120,600
#   bash scripts/resume_e2e.sh --relay-bin ./relay --windows 30 --end drop --rate 5
#   bash scripts/resume_e2e.sh --relay-port 18501 --windows 5   (a relay already listening on
#                                                                 127.0.0.1 with --domain 127.0.0.1)
#
# Options: --end thaw|drop|both (thaw), --rate frames/s each way (2), --settle s (120),
#   --port-base (18500), --out DIR (./e2e-out), --cargo-target DIR (./target),
#   --jobs N for cargo (4), --test-bin PATH (skip the cargo build), --crate DIR (the
#   hollow_core to build the test from, default this tree's: point it at a merged tree to run
#   the same test against its ws_client).
# The client dials ws:// and the proxy speaks TLS to the relay: the relay runs TLS
# exactly as in the live tests, and the client needs no trust in a throwaway
# certificate. Exit 1 when any window lost a frame. The relay build needs libsodium's
# headers; without root, `apt download libsodium-dev && dpkg -x libsodium-dev*.deb deps`
# and export CPATH=deps/usr/include LIBRARY_PATH=deps/usr/lib/x86_64-linux-gnu.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
relay_src=
relay_bin=
relay_port=
windows=5,30,120,600
ends=thaw
rate=2
settle=120
base=18500
out=$PWD/e2e-out
cargo_target=$PWD/target
jobs=4
test_bin=
crate=$repo/rust/hollow_core
while [ $# -gt 0 ]; do
    case $1 in
        --relay-src) relay_src=$2; shift 2 ;;
        --relay-bin) relay_bin=$2; shift 2 ;;
        --relay-port) relay_port=$2; shift 2 ;;
        --windows) windows=$2; shift 2 ;;
        --end) ends=$2; shift 2 ;;
        --rate) rate=$2; shift 2 ;;
        --settle) settle=$2; shift 2 ;;
        --port-base) base=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --cargo-target) cargo_target=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        --test-bin) test_bin=$2; shift 2 ;;
        --crate) crate=$2; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ "$ends" = both ] && ends="thaw drop"
ends=${ends//,/ }
[ -n "$relay_src$relay_bin$relay_port" ] || { echo "give --relay-src, --relay-bin or --relay-port" >&2; exit 2; }
mkdir -p "$out"
out=$(cd "$out" && pwd)

pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2> /dev/null; done
    sleep 0.5
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2> /dev/null; done
}
trap cleanup EXIT

# The relay, as run_live.sh builds it: loopback only, objects kept between runs.
build_relay() {
    local src=$1 obj=$out/relay-build
    [ -f "$src/uWebSockets/src/App.h" ] && [ -f "$src/uSockets/src/libusockets.h" ] ||
        { echo "no uWebSockets/uSockets sources under $src" >&2; exit 1; }
    mkdir -p "$obj"
    local flags="-O2 -DLIBUS_USE_OPENSSL"
    local us_c="gcc -std=c11 $flags -I$src/uSockets/src"
    local cxx="g++ -std=c++20 $flags -DHOLLOW_RELAY_TEST_LOOPBACK=1 -I$src/uWebSockets/src -I$src/uSockets/src -I$src/src"
    local objects=() running=0 f name
    compile() {
        local out_o=$1 src_f=$2
        shift 2
        if [ -f "$out_o" ] && [ "$out_o" -nt "$src_f" ] && [ "$out_o" -nt "$(ls -t "$src"/src/*.h | head -1)" ]; then return; fi
        "$@" -c "$src_f" -o "$out_o" > "$out_o.log" 2>&1 || { echo "BUILD FAIL $src_f" >&2; head -20 "$out_o.log" >&2; exit 1; } &
        running=$((running + 1))
        if [ $running -ge 3 ]; then wait -n; running=$((running - 1)); fi
    }
    for f in bsd context loop socket eventing/epoll_kqueue eventing/gcd eventing/libuv crypto/openssl; do
        name=us_${f//\//_}
        compile "$obj/$name.o" "$src/uSockets/src/$f.c" $us_c
        objects+=("$obj/$name.o")
    done
    compile "$obj/us_sni_tree.o" "$src/uSockets/src/crypto/sni_tree.cpp" g++ -std=c++20 $flags -I"$src/uSockets/src"
    objects+=("$obj/us_sni_tree.o")
    for f in main crypto device_list license reports http_handlers snapshot ws_handler; do
        compile "$obj/$f.o" "$src/src/$f.cpp" $cxx
        objects+=("$obj/$f.o")
    done
    wait
    for f in "${objects[@]}"; do [ -s "$f" ] || { echo "BUILD FAIL $f" >&2; cat "$f.log" >&2; exit 1; }; done
    g++ "${objects[@]}" -o "$obj/relay" -lssl -lcrypto -lsodium -lz -pthread > "$obj/link.log" 2>&1 ||
        { echo "LINK FAIL" >&2; head -30 "$obj/link.log" >&2; exit 1; }
    relay_bin=$obj/relay
}

if [ -n "$relay_src" ]; then
    echo "[e2e] building the relay from $relay_src"
    build_relay "$relay_src"
fi

if [ -z "$test_bin" ]; then
    echo "[e2e] building the test binary (cargo -j $jobs)"
    # The committed cargo config names Windows OpenSSL paths; the system's win here.
    export OPENSSL_DIR=/usr OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu OPENSSL_INCLUDE_DIR=/usr/include
    test_bin=$(cd "$crate" && CARGO_TARGET_DIR=$cargo_target cargo test --lib --no-run -j "$jobs" \
        --message-format=json 2> "$out/cargo.log" |
        python3 -c 'import json, sys
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("executable") and m.get("profile", {}).get("test"):
        print(m["executable"])' | tail -1)
    [ -n "$test_bin" ] && [ -x "$test_bin" ] || { echo "cargo build failed, see $out/cargo.log" >&2; tail -30 "$out/cargo.log" >&2; exit 1; }
fi
echo "[e2e] test binary $test_bin"

cert=$out/cert.pem
key=$out/key.pem
if [ ! -s "$cert" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=127.0.0.1 \
        -keyout "$key" -out "$cert" > "$out/cert.log" 2>&1 || { echo "openssl failed" >&2; exit 1; }
fi

start_relay() {
    local port=$1 log=$2
    env -u NOTIFY_SOCKET -u LISTEN_PID -u LISTEN_FDS -u LISTEN_FDNAMES -u HOLLOW_PUSH_TOKEN \
        TURN_SECRET=e2e-test "$relay_bin" --port "$port" --domain 127.0.0.1 \
        --cert-file "$cert" --key-file "$key" --keys-file "$out/no-keys.json" \
        --reports-file "$out/reports.json" > "$log" 2>&1 &
    relay_pid=$!
    pids+=("$relay_pid")
    local _
    for _ in $(seq 100); do
        grep -q "Listening on port" "$log" && return 0
        kill -0 "$relay_pid" 2> /dev/null || break
        sleep 0.1
    done
    echo "the relay never listened:" >&2
    tail -20 "$log" >&2
    exit 1
}

stop_pid() {
    local pid=$1 _
    kill -TERM "$pid" 2> /dev/null
    for _ in $(seq 50); do kill -0 "$pid" 2> /dev/null || return 0; sleep 0.1; done
    kill -KILL "$pid" 2> /dev/null
}

relay_listen=$((base + 1))
route_a=$((base + 10))
route_b=$((base + 11))
control=$((base + 49))
summary=$out/summary.md
{
    echo "| window s | end | A->B sent | A->B lost | B->A sent | B->A lost | first A->B frame after the window (ms) | B's events |"
    echo "|---|---|---|---|---|---|---|---|"
} > "$summary"
failed=0
for window in ${windows//,/ }; do
    for end in $ends; do
        tag=w${window}-$end
        echo "[e2e] window ${window}s, $end"
        relay_pid=
        upstream=$relay_port
        if [ -z "$relay_port" ]; then
            start_relay "$relay_listen" "$out/relay-$tag.log"
            upstream=$relay_listen
        fi
        rm -f "$out/proxy-ready.json"
        python3 "$repo/tools/zombie_proxy/zombie_proxy.py" serve --control "127.0.0.1:$control" \
            --ready-file "$out/proxy-ready.json" --log "$out/proxy-$tag.log" \
            --route "a=127.0.0.1:$route_a=127.0.0.1:$upstream:tls" \
            --route "b=127.0.0.1:$route_b=127.0.0.1:$upstream:tls" 2> "$out/proxy-$tag.err" &
        proxy_pid=$!
        pids+=("$proxy_pid")
        for _ in $(seq 100); do [ -s "$out/proxy-ready.json" ] && break; sleep 0.1; done
        [ -s "$out/proxy-ready.json" ] || { echo "the proxy never became ready" >&2; cat "$out/proxy-$tag.err" >&2; exit 1; }

        data=$out/data-$tag
        rm -rf "$data"
        mkdir -p "$data"
        HOLLOW_DATA_DIR=$data HOLLOW_E2E_URL_A="ws://127.0.0.1:$route_a/ws" HOLLOW_E2E_URL_B="ws://127.0.0.1:$route_b/ws" \
            HOLLOW_E2E_PROXY_CTL="127.0.0.1:$control" HOLLOW_E2E_ROUTE_B=b HOLLOW_E2E_WINDOW_SECS=$window \
            HOLLOW_E2E_END=$end HOLLOW_E2E_RATE=$rate HOLLOW_E2E_SETTLE_SECS=$settle \
            HOLLOW_E2E_REPORT="$out/report-$tag.json" \
            timeout $((window + settle + 180)) "$test_bin" --ignored --exact node::resume_e2e::no_frame_is_lost_across_a_dead_path \
            --nocapture > "$out/test-$tag.log" 2>&1
        rc=$?
        python3 "$repo/tools/zombie_proxy/zombie_proxy.py" ctl --control "127.0.0.1:$control" quit > /dev/null 2>&1
        stop_pid "$proxy_pid"
        [ -n "$relay_pid" ] && stop_pid "$relay_pid"
        if [ -s "$out/report-$tag.json" ]; then
            python3 - "$out/report-$tag.json" "$window" "$end" >> "$summary" << 'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ab, ba = r["a_to_b"], r["b_to_a"]
events = " ".join(f'{e["side"]}:{e["event"]}@{e["ms"]}' for e in r["events"] if e["side"] == "b")
first = ab["first_arrival_after_window_ms"]
print(f'| {sys.argv[2]} | {sys.argv[3]} | {ab["sent"]} | {ab["lost"]} ({ab["missing"] or "-"}) | {ba["sent"]} | {ba["lost"]} ({ba["missing"] or "-"}) | {first if first is not None else "-"} | {events} |')
PY
        else
            echo "| $window | $end | - | - | - | - | - | the test wrote no report (exit $rc), see test-$tag.log |" >> "$summary"
        fi
        [ $rc -eq 0 ] || failed=1
        echo "[e2e] window ${window}s, $end: exit $rc"
    done
done
echo
cat "$summary"
exit $failed
