#!/bin/bash
# Live tests of the relay's dispatch gates (test_relay_live.cpp): builds the real relay
# twice, with the compatibility switch (ACCEPT_RING1_CONTROL) on and off, runs each on
# 127.0.0.1 with a throwaway certificate and drives it over TLS.
# run_tests.sh calls it with its scratch directory; SANITIZE=1 builds the relay and the
# client with ASan and UBSan. Skips, saying why, when the vendored uWebSockets/uSockets
# sources or the openssl tool are missing.
#   bash run_live.sh [dir]
#   RELAY_LIVE_BUILD=<dir>    keep the relay's objects there between runs
#   RELAY_LIVE_VARIANTS=on    run one of the two builds
#   RELAY_LIVE_PORTS=lo-hi    pick the relay's port in this range (a machine others share)
#   RELAY_LIVE_JOBS=n         compile at most n objects at once
cd "$(dirname "$0")" || exit 1

skip() {
    echo "skip test_relay_live ($1)"
    exit 0
}
[ -f ../uWebSockets/src/App.h ] && [ -f ../uSockets/src/libusockets.h ] ||
    skip "no uWebSockets/uSockets sources; git submodule update --init"
command -v openssl > /dev/null || skip "no openssl tool"
command -v gcc > /dev/null || skip "no gcc"

dir=${1:-$(mktemp -d)}/live
flags="-O1"
flavor=plain
if [ "${SANITIZE:-0}" = 1 ]; then
    flags="$flags -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
    flavor=sanitize
fi
obj=${RELAY_LIVE_BUILD:-$dir}/$flavor
mkdir -p "$dir" "$obj"

relay_pid=
trap '[ -n "$relay_pid" ] && kill -KILL "$relay_pid" 2> /dev/null' EXIT

build_fail() {
    echo "BUILD FAIL test_relay_live ($1)"
    head -30 "$2"
    exit 1
}

# Compiles in the background unless the object is newer than its source and every
# relay header. Each job's name keys its log.
pids=()
names=()
compile() {
    local name=$1 src=$2 out=$3
    shift 3
    local newest
    newest=$(ls -t "$src" ../src/*.h | head -1)
    if [ -f "$out" ] && [ "$out" -nt "$newest" ]; then return; fi
    while [ "${RELAY_LIVE_JOBS:-0}" -gt 0 ] && [ "$(jobs -rp | wc -l)" -ge "$RELAY_LIVE_JOBS" ]; do sleep 0.2; done
    "$@" -c "$src" -o "$out" > "$dir/$name.build" 2>&1 &
    pids+=($!)
    names+=("$name")
}
wait_all() {
    local i
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            rm -f "$obj/${names[$i]}.o"
            build_fail "${names[$i]}" "$dir/${names[$i]}.build"
        fi
    done
    pids=()
    names=()
}

us_c="gcc -std=c11 $flags -DLIBUS_USE_OPENSSL -I../uSockets/src"
# A session grace of seconds, so the tests watch one run out; three sockets fill an
# address, so they fill one under its rate of ten new sockets a minute.
relay_cxx="g++ -std=c++20 $flags -DLIBUS_USE_OPENSSL -DHOLLOW_RELAY_TEST_LOOPBACK=1 -DHOLLOW_RELAY_TEST_GRACE_SECS=5 -DHOLLOW_RELAY_TEST_CONNS_PER_IP=3 -I../uWebSockets/src -I../uSockets/src -I../src"
# Both builds set the switch, so flipping its default on release day changes neither.
switches() {
    printf -- "-DHOLLOW_ACCEPT_RING1_CONTROL=%s " "$1"
}
variants=${RELAY_LIVE_VARIANTS:-on off}

objects=()
for f in bsd context loop socket eventing/epoll_kqueue eventing/gcd eventing/libuv crypto/openssl; do
    name=us_${f//\//_}
    compile "$name" "../uSockets/src/$f.c" "$obj/$name.o" $us_c
    objects+=("$obj/$name.o")
done
compile us_sni_tree ../uSockets/src/crypto/sni_tree.cpp "$obj/us_sni_tree.o" \
    g++ -std=c++20 $flags -DLIBUS_USE_OPENSSL -I../uSockets/src
objects+=("$obj/us_sni_tree.o")
for f in main crypto license reports http_handlers snapshot; do
    compile "$f" "../src/$f.cpp" "$obj/$f.o" $relay_cxx
    objects+=("$obj/$f.o")
done
for v in $variants; do
    if [ "$v" = on ]; then bit=1; else bit=0; fi
    compile "ws_handler_$v" ../src/ws_handler.cpp "$obj/ws_handler_$v.o" $relay_cxx $(switches $bit)
done
# The circuit breaker enforced (breaker.h); every other build runs it in shadow mode.
compile ws_handler_enforce ../src/ws_handler.cpp "$obj/ws_handler_enforce.o" $relay_cxx $(switches 1) \
    -DHOLLOW_BREAKER_ENFORCE=1
g++ -std=c++17 $flags -I../src test_relay_live.cpp ../src/crypto.cpp \
    -o "$dir/client" -lssl -lcrypto -lsodium > "$dir/client.build" 2>&1 &
pids+=($!)
names+=(client)
wait_all
for v in $variants enforce; do
    g++ $flags "${objects[@]}" "$obj/ws_handler_$v.o" -o "$dir/relay_$v" -lssl -lcrypto -lsodium -lz -pthread \
        > "$dir/link_$v.build" 2>&1 || build_fail "link $v" "$dir/link_$v.build"
done
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=relay.live.test \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" > "$dir/cert.build" 2>&1 || build_fail certificate "$dir/cert.build"

domain=relay.live.test
fail=0
# The measuring hooks (measure.h) leave no trace in a relay built without HOLLOW_RELAY_MEASURE:
# no line of any translation unit names them once preprocessed.
for f in main crypto license reports http_handlers snapshot ws_handler; do
    traces=$($relay_cxx -E "../src/$f.cpp" 2> "$dir/pp_$f.err" | grep -v '^#' | grep -cE 'measure::|namespace measure|g2-measure|MeasureClose|measure_[a-z]' || true)
    if [ ! -s "$dir/pp_$f.err" ] && [ "$traces" = 0 ]; then
        echo "  ok   a plain build of $f.cpp carries no measuring code"
    else
        echo "  FAIL a plain build of $f.cpp carries measuring code ($traces lines)"
        fail=1
    fi
done
# A third argument is HOLLOW_CONN_RATE_EXEMPT for that run, which runs only the rate cases;
# a fourth the relay's send buffer in bytes, which runs only the dropped-write case; a fifth
# (shadow or enforce) scales the breaker down and runs only its cases; a sixth is the
# relay's send-buffer memory budget in bytes, which runs only the OOM-budget case.
run_variant() {
    local v=$1 name=${2:-$1} exempt=${3-} backpressure=${4-} breaker=${5-} budget=${6-} port tries=0 log=$dir/relay_${2:-$1}.log
    local extra=() args=() only=${RELAY_LIVE_ONLY-} client_v=$1 stall=
    [ "$v" = enforce ] && client_v=on
    if [ -n "$breaker" ]; then
        # Budgets / 100 and times / 60: the numbers test_relay_live.cpp's BRK_W and BRK_T name.
        extra=(HOLLOW_RELAY_TEST_BREAKER_W=100 HOLLOW_RELAY_TEST_BREAKER_T=60)
        args=(--forwarder-peer-id 12D3KooWC4T1AXU2s2YBgGJ2FeaYVtsKoHZWJeubnWe9SnuSE7Zb)
        only=breaker_$breaker
    elif [ -n "$exempt" ]; then
        extra=(HOLLOW_CONN_RATE_EXEMPT="$exempt")
        only=rate_exempt
    elif [ -n "$backpressure" ]; then
        extra=(HOLLOW_RELAY_TEST_BACKPRESSURE="$backpressure")
        only=dropped_write
    elif [ -n "$budget" ]; then
        # A short stall window so the test watches a non-reading receiver get closed.
        stall=5000
        extra=(HOLLOW_RELAY_TEST_SEND_BUDGET="$budget" HOLLOW_RELAY_TEST_STALL_MS=$stall)
        only=oom
    fi
    while :; do
        if [ -n "$RELAY_LIVE_PORTS" ]; then
            port=$((${RELAY_LIVE_PORTS%-*} + RANDOM % (${RELAY_LIVE_PORTS#*-} - ${RELAY_LIVE_PORTS%-*} + 1)))
        else
            port=$((20000 + RANDOM % 12000))
        fi
        # Never under a systemd fd store, never near the real push sidecar's token.
        env -u NOTIFY_SOCKET -u LISTEN_PID -u LISTEN_FDS -u LISTEN_FDNAMES -u HOLLOW_PUSH_TOKEN \
            -u HOLLOW_CONN_RATE_EXEMPT -u HOLLOW_RELAY_TEST_BACKPRESSURE -u HOLLOW_RELAY_TEST_BREAKER_W \
            -u HOLLOW_RELAY_TEST_BREAKER_T -u HOLLOW_RELAY_TEST_SEND_BUDGET -u HOLLOW_RELAY_TEST_STALL_MS \
            "${extra[@]}" TURN_SECRET=live-test "$dir/relay_$v" "${args[@]}" --port "$port" --domain "$domain" \
            --cert-file "$dir/cert.pem" --key-file "$dir/key.pem" \
            --keys-file "$dir/no-keys.json" --reports-file "$dir/reports_$name.json" > "$log" 2>&1 &
        relay_pid=$!
        for _ in $(seq 100); do
            grep -q "Listening on port" "$log" && break
            kill -0 "$relay_pid" 2> /dev/null || break
            sleep 0.1
        done
        grep -q "Listening on port" "$log" && break
        kill -KILL "$relay_pid" 2> /dev/null
        wait "$relay_pid" 2> /dev/null
        relay_pid=
        tries=$((tries + 1))
        if [ $tries -ge 5 ]; then
            echo "FAIL test_relay_live/$name (the relay never listened)"
            tail -20 "$log"
            fail=1
            return
        fi
    done

    # The client's last case sends the relay SIGTERM itself (the drain hint); its pid
    # also lets a probe read the relay's memory. Under ASan the run takes about 96 s.
    RELAY_LIVE_ONLY=$only RELAY_LIVE_BACKPRESSURE=$backpressure RELAY_LIVE_SEND_BUDGET=$budget RELAY_LIVE_STALL_MS=$stall RELAY_LIVE_SANITIZED=${SANITIZE:-0} RELAY_LIVE_PID=$relay_pid timeout 240 "$dir/client" "$port" "$domain" "$client_v" \
        > "$dir/client_$name.log" 2>&1
    local rc=$?
    # A relay that does not exit on SIGTERM is down until systemd kills it.
    kill -TERM "$relay_pid" 2> /dev/null
    local exited=0
    for _ in $(seq 100); do
        if ! kill -0 "$relay_pid" 2> /dev/null; then
            exited=1
            break
        fi
        sleep 0.1
    done
    [ $exited = 1 ] || kill -KILL "$relay_pid" 2> /dev/null
    wait "$relay_pid"
    local relay_rc=$?
    relay_pid=

    # The list is announced by its counts alone, and only when it is set.
    local said=ok
    if [ -n "$exempt" ]; then
        grep -qxF "[config] New-connection rate exemption: 1 address block(s), 3 entry(s) ignored" "$log" ||
            said="no count line"
        ! grep -qF "127.0.241" "$log" || said="the log names an address"
    elif grep -qF "rate exemption" "$log"; then
        said="an exemption line without a list"
    fi
    local checks
    checks=$(grep -c '  ok' "$dir/client_$name.log")
    if [ $rc = 0 ] && [ $exited = 1 ] && [ $relay_rc = 0 ] && [ "$said" = ok ] &&
        ! grep -qE "AddressSanitizer|LeakSanitizer|runtime error:" "$log"; then
        echo "pass test_relay_live/$name ($checks checks)"
        return
    fi
    if [ $rc = 124 ]; then
        echo "FAIL test_relay_live/$name (hung, killed after 120 s)"
    elif [ $exited = 0 ]; then
        echo "FAIL test_relay_live/$name (the relay ignored SIGTERM)"
    elif [ "$said" != ok ]; then
        echo "FAIL test_relay_live/$name (startup log: $said)"
    else
        echo "FAIL test_relay_live/$name (client $rc, relay $relay_rc)"
    fi
    grep -v '  ok' "$dir/client_$name.log" | head -30
    grep -E -A12 "AddressSanitizer|LeakSanitizer|runtime error:" "$log" | head -40
    fail=1
}

for v in $variants; do
    run_variant "$v"
done
# The exemption list: a v4 address written v4-mapped, beside three entries it ignores.
run_variant "${variants%% *}" exempt "::ffff:127.0.241.3, not-an-address,127.0.241, 0.0.0.0"
# A 1 MiB send buffer: a test drains it and writes again inside one session tick.
run_variant "${variants%% *}" backpressure "" 1048576
# The circuit breaker scaled down: shadow mode (every build's default), then enforced.
run_variant "${variants%% *}" breaker_shadow "" "" shadow
run_variant enforce breaker_enforce "" "" enforce
# A 32 MiB send-buffer memory budget and a 5 s stall window: honest traffic passes, effects stay bounded.
run_variant "${variants%% *}" oom "" "" "" 33554432
exit $fail
