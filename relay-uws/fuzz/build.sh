#!/usr/bin/env bash
# Builds every relay fuzz target (libFuzzer + ASan + UBSan) with its seed corpus
# and dictionary, in the layout ClusterFuzzLite expects in $OUT:
#   <target>, <target>_seed_corpus.zip, <target>.dict
# Locally (clang with libFuzzer; on macOS Homebrew llvm, Apple clang has none):
#   bash relay-uws/fuzz/build.sh [out_dir]          (default: .team/fuzz/out)
#   .team/fuzz/out/fuzz_auth_frame -dict=.team/fuzz/out/fuzz_auth_frame.dict corpus/
# ClusterFuzzLite (.clusterfuzzlite/build.sh) sets CXX, CXXFLAGS, LIB_FUZZING_ENGINE
# and OUT itself, and FUZZ_LIBS to link libsodium and OpenSSL statically.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here/../src
out=${OUT:-${1:-$here/../../.team/fuzz/out}}
mkdir -p "$out"

if [ -z "${CXX:-}" ]; then
    if [ "$(uname)" = Darwin ] && [ -x "$(brew --prefix 2>/dev/null)/opt/llvm/bin/clang++" ]; then
        CXX="$(brew --prefix)/opt/llvm/bin/clang++"
    else
        CXX=clang++
    fi
fi
CXXFLAGS=${CXXFLAGS:--g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined}
LIB_FUZZING_ENGINE=${LIB_FUZZING_ENGINE:--fsanitize=fuzzer}
inc=(-I"$src")
libs=(-lsodium -lcrypto)
if [ "$(uname)" = Darwin ]; then
    prefix=$(brew --prefix)
    ssl=$(brew --prefix openssl@3)
    inc+=(-I"$prefix/include" -I"$ssl/include")
    libs=(-L"$prefix/lib" -L"$ssl/lib" "${libs[@]}")
fi
if [ -n "${FUZZ_LIBS:-}" ]; then
    # shellcheck disable=SC2206
    libs=($FUZZ_LIBS)
fi

# target -> needs crypto.cpp (libsodium, OpenSSL), dictionary
targets=(
    "fuzz_auth_frame crypto json"
    "fuzz_binary_frame - binary_frame"
    "fuzz_client_json - json"
    "fuzz_ring_auth - json"
    "fuzz_join_lock - json"
    "fuzz_roster - json"
    "fuzz_kill_order - json"
    "fuzz_snapshot_codec - snapshot_codec"
    "fuzz_crypto_inputs crypto -"
)

# crypto.cpp once, with the same flags but without the fuzzer's main.
obj=$(mktemp -d)
trap 'rm -rf "$obj"' EXIT
# shellcheck disable=SC2086
$CXX -std=c++17 $CXXFLAGS "${inc[@]}" -c "$src/crypto.cpp" -o "$obj/crypto.o"

for entry in "${targets[@]}"; do
    read -r name crypto dict <<< "$entry"
    extra=()
    if [ "$crypto" = crypto ]; then extra=("$obj/crypto.o" "${libs[@]}"); fi
    # shellcheck disable=SC2086
    $CXX -std=c++17 $CXXFLAGS "${inc[@]}" "$here/$name.cpp" $LIB_FUZZING_ENGINE ${extra[@]+"${extra[@]}"} -o "$out/$name"
    if [ "$dict" != - ]; then cp "$here/$dict.dict" "$out/$name.dict"; fi
done

# Seed corpora, zipped the way ClusterFuzzLite picks them up.
seeds=$obj/seeds
python3 "$here/make_seeds.py" "$seeds"
mkdir -p "$seeds/fuzz_snapshot_codec"
# The generator is a plain program: built without sanitizers or the fuzzer.
$CXX -std=c++17 -O1 "${inc[@]}" "$here/gen_snapshot_seeds.cpp" -o "$obj/gen_snapshot_seeds"
"$obj/gen_snapshot_seeds" "$seeds/fuzz_snapshot_codec"
for dir in "$seeds"/*/; do
    name=$(basename "$dir")
    python3 - "$dir" "$out/${name}_seed_corpus.zip" <<'EOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(src)):
        z.write(os.path.join(src, name), name)
EOF
done
echo "built ${#targets[@]} fuzz targets in $out"
