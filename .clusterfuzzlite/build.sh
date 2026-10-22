#!/bin/bash -eu
# Runs inside the ClusterFuzzLite image with CXX, CXXFLAGS, LIB_FUZZING_ENGINE and
# OUT set; the relay's own script builds every target, seed corpus and dictionary.
libdir=/usr/lib/$(gcc -dumpmachine)
FUZZ_LIBS="$libdir/libsodium.a $libdir/libcrypto.a -lpthread -ldl" bash relay-uws/fuzz/build.sh
