#!/bin/bash
# Live tests of the relay's dispatch gates (test_relay_live.cpp): builds the real relay
# twice, with the four release-day switches on (the binary today) and off (once 0.12
# ships), runs each on 127.0.0.1 with a throwaway certificate and drives it over TLS.
# run_tests.sh calls it with its scratch directory; SANITIZE=1 builds the relay and the
# client with ASan and UBSan. Skips, saying why, when the vendored uWebSockets/uSockets
# sources or the openssl tool are missing.
#   bash run_live.sh [dir]
#   RELAY_LIVE_BUILD=<dir>    keep the relay's objects there between runs
#   RELAY_LIVE_VARIANTS=on    run one of the two builds
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
relay_cxx="g++ -std=c++20 $flags -DLIBUS_USE_OPENSSL -DHOLLOW_RELAY_TEST_LOOPBACK=1 -I../uWebSockets/src -I../uSockets/src -I../src"
# Both builds set every switch, so flipping a default on release day changes neither.
switches() {
    local s
    for s in AUTH_V1 UNSIGNED_RING_CONTROL UNSIGNED_NICKNAME_CLAIMS DEVICE_LIST_INBOX_PROOF; do
        printf -- "-DHOLLOW_ACCEPT_%s=%s " "$s" "$1"
    done
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
for f in main crypto device_list license reports http_handlers snapshot; do
    compile "$f" "../src/$f.cpp" "$obj/$f.o" $relay_cxx
    objects+=("$obj/$f.o")
done
for v in $variants; do
    if [ "$v" = on ]; then bit=1; else bit=0; fi
    compile "ws_handler_$v" ../src/ws_handler.cpp "$obj/ws_handler_$v.o" $relay_cxx $(switches $bit)
done
g++ -std=c++17 $flags -I../src test_relay_live.cpp ../src/crypto.cpp ../src/device_list.cpp \
    -o "$dir/client" -lssl -lcrypto -lsodium > "$dir/client.build" 2>&1 &
pids+=($!)
names+=(client)
wait_all
for v in $variants; do
    g++ $flags "${objects[@]}" "$obj/ws_handler_$v.o" -o "$dir/relay_$v" -lssl -lcrypto -lsodium -lz -pthread \
        > "$dir/link_$v.build" 2>&1 || build_fail "link $v" "$dir/link_$v.build"
done
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=relay.live.test \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" > "$dir/cert.build" 2>&1 || build_fail certificate "$dir/cert.build"

domain=relay.live.test
fail=0
run_variant() {
    local v=$1 port tries=0 log=$dir/relay_$v.log
    while :; do
        port=$((20000 + RANDOM % 12000))
        # Never under a systemd fd store, never near the real push sidecar's token.
        env -u NOTIFY_SOCKET -u LISTEN_PID -u LISTEN_FDS -u LISTEN_FDNAMES -u HOLLOW_PUSH_TOKEN \
            TURN_SECRET=live-test "$dir/relay_$v" --port "$port" --domain "$domain" \
            --cert-file "$dir/cert.pem" --key-file "$dir/key.pem" \
            --keys-file "$dir/no-keys.json" --reports-file "$dir/reports_$v.json" > "$log" 2>&1 &
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
            echo "FAIL test_relay_live/$v (the relay never listened)"
            tail -20 "$log"
            fail=1
            return
        fi
    done

    timeout 120 "$dir/client" "$port" "$domain" "$v" > "$dir/client_$v.log" 2>&1
    local rc=$?
    # A relay that does not exit on SIGTERM is down until systemd kills it.
    kill -TERM "$relay_pid"
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

    local checks
    checks=$(grep -c '  ok' "$dir/client_$v.log")
    if [ $rc = 0 ] && [ $exited = 1 ] && [ $relay_rc = 0 ] &&
        ! grep -qE "AddressSanitizer|LeakSanitizer|runtime error:" "$log"; then
        echo "pass test_relay_live/$v ($checks checks)"
        return
    fi
    if [ $rc = 124 ]; then
        echo "FAIL test_relay_live/$v (hung, killed after 120 s)"
    elif [ $exited = 0 ]; then
        echo "FAIL test_relay_live/$v (the relay ignored SIGTERM)"
    else
        echo "FAIL test_relay_live/$v (client $rc, relay $relay_rc)"
    fi
    grep -v '  ok' "$dir/client_$v.log" | head -30
    grep -E -A12 "AddressSanitizer|LeakSanitizer|runtime error:" "$log" | head -40
    fail=1
}

for v in $variants; do
    run_variant "$v"
done
exit $fail
