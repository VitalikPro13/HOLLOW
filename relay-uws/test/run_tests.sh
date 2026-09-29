#!/bin/bash
# Builds and runs every relay unit test. SANITIZE=1 builds them with AddressSanitizer
# and UBSan, which is how the kill list's use-after-free (HOL-SEC-070 follow-up) was
# caught; run both before a relay deploy.
#   bash run_tests.sh            (from relay-uws/test, needs g++, libsodium, OpenSSL)
#   SANITIZE=1 bash run_tests.sh
cd "$(dirname "$0")" || exit 1
out=$(mktemp -d)
flags="-std=c++17 -O1"
if [ "${SANITIZE:-0}" = 1 ]; then
    flags="$flags -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
fi
fail=0
run() {
    local name=$1
    shift
    if ! g++ $flags -I../src "$name.cpp" "$@" -o "$out/$name" 2> "$out/$name.build"; then
        echo "BUILD FAIL $name"
        head -20 "$out/$name.build"
        fail=1
        return
    fi
    if "$out/$name" > "$out/$name.log" 2>&1; then
        echo "pass $name ($(grep -c '  ok' "$out/$name.log") checks)"
    else
        echo "FAIL $name"
        grep -v '  ok' "$out/$name.log" | head -30
        fail=1
    fi
}
LIBS="-lsodium -lcrypto"
run test_auth_frame
run test_derive_peer_id ../src/crypto.cpp $LIBS
run test_fair_share
run test_join_lock ../src/crypto.cpp $LIBS
run test_kill_list
run test_license_pool
run test_relay_validators ../src/crypto.cpp $LIBS
run test_reports ../src/reports.cpp ../src/crypto.cpp $LIBS
run test_ring_auth
run test_ring_evict
run test_snapshot_codec
run test_turn_uris
run test_verify_device_list ../src/device_list.cpp ../src/crypto.cpp $LIBS
rm -rf "$out"
exit $fail
