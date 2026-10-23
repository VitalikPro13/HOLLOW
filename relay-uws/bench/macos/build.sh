#!/usr/bin/env bash
# Build the relay on macOS for local load runs (bench only, never for deployment).
# Same sources as CMakeLists.txt, -O2, plus the test knobs the live tests use: listen on
# 127.0.0.1 only, accept loopback in HOLLOW_CONN_RATE_EXEMPT, and a per-address socket
# cap high enough for one machine to stand in for many clients.
#   [USOCKETS_DIR=..] [UWS_DIR=..] bash relay-uws/bench/macos/build.sh [out_dir]   (default: .team/relay/build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
relay=$(cd "$here/../.." && pwd)
out=${1:-$relay/../.team/relay/build}
mkdir -p "$out/obj"
# The submodules at the pinned commits; a fresh worktree has them empty, so
# USOCKETS_DIR / UWS_DIR may point at clones (git submodule status shows the commits).
us=${USOCKETS_DIR:-$relay/uSockets}
uws=${UWS_DIR:-$relay/uWebSockets}
# Empty submodules: clone the pinned commits beside the build, never into the tree.
fetch() {
    local name=$1 url=$2 dir=$out/deps/$1
    local pin
    pin=$(git -C "$relay" submodule status "$name" | sed 's/^[-+ ]//' | cut -d' ' -f1)
    if [ ! -d "$dir/src" ]; then
        rm -rf "$dir"
        git clone -q "$url" "$dir"
        git -C "$dir" checkout -q "$pin"
    fi
    echo "$dir"
}
[ -f "$us/src/bsd.c" ] || us=$(fetch uSockets https://github.com/uNetworking/uSockets.git)
[ -f "$uws/src/App.h" ] || uws=$(fetch uWebSockets https://github.com/uNetworking/uWebSockets.git)
brew_prefix=$(brew --prefix)
ssl=$(brew --prefix openssl@3)
inc="-I$ssl/include -I$brew_prefix/include"
lib="-L$ssl/lib -L$brew_prefix/lib"
flags="-O2 -DNDEBUG -DLIBUS_USE_OPENSSL"
conns=${BENCH_CONNS_PER_IP:-1000000}
relay_flags="$flags -DHOLLOW_RELAY_TEST_LOOPBACK=1 -DHOLLOW_RELAY_TEST_CONNS_PER_IP=$conns ${RELAY_EXTRA_FLAGS:-} -include $here/macos_shim.h"
objs=()
pids=()
for f in bsd context loop socket eventing/epoll_kqueue eventing/gcd eventing/libuv crypto/openssl; do
    o="$out/obj/us_${f//\//_}.o"
    clang -std=c11 $flags $inc -I"$us/src" -c "$us/src/$f.c" -o "$o" & pids+=($!)
    objs+=("$o")
done
o="$out/obj/us_sni_tree.o"
clang++ -std=c++20 $flags $inc -I"$us/src" -c "$us/src/crypto/sni_tree.cpp" -o "$o" & pids+=($!)
objs+=("$o")
for f in main crypto license reports http_handlers snapshot ws_handler; do
    o="$out/obj/$f.o"
    clang++ -std=c++20 $relay_flags $inc -I"$uws/src" -I"$us/src" -I"$relay/src" \
        -c "$relay/src/$f.cpp" -o "$o" & pids+=($!)
    objs+=("$o")
done
for p in "${pids[@]}"; do wait "$p"; done
clang++ "${objs[@]}" -o "$out/hollow-relay" $lib -lssl -lcrypto -lsodium -lz -lpthread
if [ ! -f "$out/cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=relay.bench.test \
        -keyout "$out/key.pem" -out "$out/cert.pem" 2>/dev/null
fi
echo "built $out/hollow-relay"
