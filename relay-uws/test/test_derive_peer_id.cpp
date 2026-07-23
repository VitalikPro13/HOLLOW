// Known-answer test for the relay's peer_id derivation.
//
// The relay binds an auth frame's claimed peer_id to its public key by
// recomputing the id (see derive_peer_id in ../src/crypto.cpp). That derivation
// MUST match the client's `NativeKeypair::peer_id()` byte for byte — if it ever
// drifts, every client fails authentication and the network goes dark.
//
// The vector below is pinned identically in the Rust test
// `identity::native_identity::tests::peer_id_derivation_known_answer`.
// Change both or neither.
//
// Build + run (no uWebSockets needed, only libsodium):
//   g++ -std=c++17 -I../src test_derive_peer_id.cpp ../src/crypto.cpp \
//       -lsodium -lcrypto -o test_derive_peer_id && ./test_derive_peer_id

#include "crypto.h"
#include <cstdio>
#include <string>

static int failures = 0;

static void check(const std::string& label,
                  const std::string& got,
                  const std::string& want) {
    if (got == want) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n       got:  \"%s\"\n       want: \"%s\"\n",
               label.c_str(), got.c_str(), want.c_str());
        failures++;
    }
}

int main() {
    printf("derive_peer_id known-answer test\n");

    // Secret key [1u8; 32] -> this public key protobuf (base64) and peer_id.
    const std::string kPubkeyB64 =
        "CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c";
    const std::string kPeerId =
        "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";

    check("matches the Rust vector", derive_peer_id(kPubkeyB64), kPeerId);

    // Malformed input must yield "" so a caller's `derived != claimed` compare
    // rejects rather than accidentally matching an empty claimed id.
    check("rejects empty input", derive_peer_id(""), "");
    check("rejects non-base64", derive_peer_id("!!!not base64!!!"), "");
    check("rejects wrong length",
          derive_peer_id("CAESIAtVUM/wUR56IESpc5PDNhV3xxatEmXDL8IE"), "");
    // Valid base64, 36 bytes, but the protobuf header is not Ed25519.
    check("rejects bad protobuf header",
          derive_peer_id("AAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c"), "");

    if (failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAILED (%d)\n", failures);
    return 1;
}
