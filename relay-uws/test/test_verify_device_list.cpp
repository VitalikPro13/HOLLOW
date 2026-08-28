// Known-answer test for the relay's SignedDeviceList verification.
//
// The relay opens a master's inbox mailbox only to a socket that carries that
// master's signed device list (see maybe_replay_inbox_mailbox in
// ../src/ws_handler.cpp). The signed-payload bytes MUST match the client's
// `device_list_signing_payload` byte for byte. If they ever drift, either
// every real device is locked out of its own mailbox, or (far worse) a list
// the client would reject starts verifying here.
//
// The vector below is pinned identically in the Rust test over
// `crypto_handler::verify_device_list`. Change both or neither.
//
// Build + run from relay-uws/test (no uWebSockets needed, only libsodium):
//   g++ -std=c++17 -I../src test_verify_device_list.cpp ../src/device_list.cpp
//       ../src/crypto.cpp -lsodium -lcrypto -o test_verify_device_list
//   ./test_verify_device_list

#include "device_list.h"
#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

static void check_str(const std::string& label,
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

static void check_bool(const std::string& label, bool got, bool want) {
    if (got == want) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n       got:  %s\n       want: %s\n",
               label.c_str(), got ? "true" : "false", want ? "true" : "false");
        failures++;
    }
}

// ---------------------------------------------------------------------------
// TODO(vector): the pinned cross-language vector.
//
// PLACEHOLDERS. Filling THIS BLOCK is the whole remaining work in this file;
// nothing below it needs to change. The Rust unit produces the vector from a
// fixed master seed and pins the identical values in its own test, which is
// what makes this a cross-language KAT rather than a self-consistency check.
//
// Needed from the Rust side:
//   master seed        - the fixed master secret key the vector was built
//                        from, recorded as a comment so it can be regenerated
//                        (never used by this test).
//   kMasterPubkeyB64   - base64 protobuf Ed25519 public key of that master.
//   kMasterPeerId      - NativeKeypair::peer_id() of that master.
//   kDevices/kRevoked  - the device ids the list was signed over, in ANY order
//                        (both sides sort before signing).
//   kVersion           - the list version that was signed.
//   kSigB64            - base64 master signature over kSignedPayload.
//   kSignedPayload     - the exact byte string the Rust
//                        `device_list_signing_payload` produced.
// ---------------------------------------------------------------------------
static const char kVectorSentinel[] = "TODO_VECTOR";

// Produced by the Rust `build_signed_device_list` from a fixed master seed and
// pinned identically in the Rust test. The master pubkey is the 36-byte libp2p
// protobuf form (08 01 12 20 + 32 raw Ed25519), base64 STANDARD with padding;
// the signature is raw Ed25519 (64 bytes), base64 STANDARD.
static const char kMasterPubkeyB64[] =
    "CAESILpCRY6DunkmuouPPpq5yq8PHEkY3ajFUQhPeusQZbdL";
static const char kMasterPeerId[] =
    "12D3KooWNMScRmLVQ8m6RpKzYepQKpuDsDgGAD4LmvgxixuRQ1eJ";
static const char kSigB64[] =
    "KTqIMbGWsxJYuVDkEvxG/oni7qjkH13pEZC+iKcuIOwd/9EVOKcmvvU3KDUzRWpYDwaU9lJa49scpWZv444TDQ==";
static const char kSignedPayload[] =
    "hollow-devices:12D3KooWNMScRmLVQ8m6RpKzYepQKpuDsDgGAD4LmvgxixuRQ1eJ:3:"
    "12D3KooWBr7cTGxmMhdiGNcbesEusWMR1VG26jEQQgFr6wwZkNNf,"
    "12D3KooWKotfq8vQBbZwwFXJRibXBsfjxMqqUgWTKqCHLNuTWpmC:"
    "12D3KooWHQybjJddHJE61nFuqKGVPSasS2zDmrBAUiCwpXkYFE4m";
static const uint64_t kVersion = 3;

// Deliberately in the SORTED order the payload above carries. The reversed-order
// check in pinned_vector_tests proves the verifier sorts before hashing.
static std::vector<std::string> vector_devices() {
    return {"12D3KooWBr7cTGxmMhdiGNcbesEusWMR1VG26jEQQgFr6wwZkNNf",
            "12D3KooWKotfq8vQBbZwwFXJRibXBsfjxMqqUgWTKqCHLNuTWpmC"};
}
static std::vector<std::string> vector_revoked() {
    return {"12D3KooWHQybjJddHJE61nFuqKGVPSasS2zDmrBAUiCwpXkYFE4m"};
}
// ---------------------------------------------------------------------------

static bool vector_filled() {
    return std::string(kMasterPubkeyB64) != kVectorSentinel &&
           std::string(kMasterPeerId) != kVectorSentinel &&
           std::string(kSigB64) != kVectorSentinel &&
           std::string(kSignedPayload) != kVectorSentinel;
}

static SignedDeviceList vector_list() {
    SignedDeviceList dl;
    dl.master_pubkey_b64 = kMasterPubkeyB64;
    dl.master_peer_id = kMasterPeerId;
    dl.devices = vector_devices();
    dl.revoked = vector_revoked();
    dl.version = kVersion;
    dl.sig_b64 = kSigB64;
    return dl;
}

// Flip one character of a base64 string to a DIFFERENT valid base64 character,
// so the result still decodes to 64 bytes and the test exercises signature
// verification rather than base64 parsing.
static std::string tamper_b64(std::string s) {
    if (s.size() < 12) return s;
    s[10] = (s[10] == 'A') ? 'B' : 'A';
    return s;
}

// Format checks that never need the pinned vector: they pin the SHAPE of the
// signed payload, which is the half of this KAT most likely to drift.
static void payload_format_tests() {
    printf("signed-payload format\n");

    check_str("mirrors the Rust format literal",
              device_list_signing_payload("MASTER", 7, {"devA", "devB"}, {"devC"}),
              "hollow-devices:MASTER:7:devA,devB:devC");

    // The trailing revoked segment is present even when empty. A 4-segment
    // payload is the PRE-Step-7 shape and must never be produced here.
    check_str("keeps the trailing empty revoked segment",
              device_list_signing_payload("MASTER", 1, {"devA"}, {}),
              "hollow-devices:MASTER:1:devA:");

    check_str("empty on both sides still has both separators",
              device_list_signing_payload("MASTER", 0, {}, {}),
              "hollow-devices:MASTER:0::");

    // Both arrays are sorted before signing, so wire order cannot change the
    // bytes: an attacker must not be able to reorder a signed list.
    check_str("sorts devices and revoked",
              device_list_signing_payload("MASTER", 2, {"devB", "devA"}, {"z", "a"}),
              "hollow-devices:MASTER:2:devA,devB:a,z");

    check_str("version renders as plain decimal",
              device_list_signing_payload("M", 18446744073709551615ULL, {}, {}),
              "hollow-devices:M:18446744073709551615::");
}

// Rejection paths that never need the pinned vector.
static void rejection_tests() {
    printf("rejects malformed lists\n");

    SignedDeviceList empty;
    check_bool("rejects an empty list", verify_signed_device_list(empty), false);

    SignedDeviceList bad_key;
    bad_key.master_pubkey_b64 = "!!!not base64!!!";
    bad_key.master_peer_id = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";
    bad_key.sig_b64 = "AA==";
    check_bool("rejects a non-base64 master key",
               verify_signed_device_list(bad_key), false);

    // The known-good key from test_derive_peer_id.cpp paired with a peer_id it
    // does NOT derive to: the pubkey to claimed-id binding must reject even
    // before any signature work.
    SignedDeviceList wrong_id;
    wrong_id.master_pubkey_b64 = "CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c";
    wrong_id.master_peer_id = "12D3KooWSomeoneElsesMasterIdEntirely";
    wrong_id.sig_b64 = "AA==";
    check_bool("rejects a master_peer_id the key does not derive to",
               verify_signed_device_list(wrong_id), false);

    printf("active-device membership\n");
    SignedDeviceList dl;
    dl.devices = {"devA", "devB"};
    dl.revoked = {"devC"};
    check_bool("device in the list is an owner",
               device_list_owns_device(dl, "devA"), true);
    check_bool("device absent from the list is not an owner",
               device_list_owns_device(dl, "devZ"), false);
    check_bool("revoked device is not an owner",
               device_list_owns_device(dl, "devC"), false);
    check_bool("empty device id is never an owner",
               device_list_owns_device(dl, ""), false);
    // Fails closed: an id in BOTH arrays is revoked, never active.
    dl.devices.push_back("devC");
    check_bool("an id in both arrays counts as revoked",
               device_list_owns_device(dl, "devC"), false);
}

// The pinned cross-language checks. Skipped (loudly) until the vector lands.
static void pinned_vector_tests() {
    printf("pinned vector\n");

    SignedDeviceList dl = vector_list();

    check_str("payload matches the Rust vector",
              device_list_signing_payload(dl.master_peer_id, dl.version,
                                          dl.devices, dl.revoked),
              kSignedPayload);

    check_bool("verifies the known-good list",
               verify_signed_device_list(dl), true);

    // Wire order must not matter: the verifier sorts before hashing, so a list
    // whose devices arrive reversed still covers the same signed bytes.
    SignedDeviceList reversed = dl;
    std::reverse(reversed.devices.begin(), reversed.devices.end());
    check_bool("verifies with the devices array reversed",
               verify_signed_device_list(reversed), true);

    SignedDeviceList tampered_sig = dl;
    tampered_sig.sig_b64 = tamper_b64(tampered_sig.sig_b64);
    check_bool("rejects a tampered signature",
               verify_signed_device_list(tampered_sig), false);

    // Post-signing mutations of the covered fields must all fail.
    SignedDeviceList added_device = dl;
    added_device.devices.push_back("12D3KooWAttackerDeviceSmuggledIn");
    check_bool("rejects a device smuggled in after signing",
               verify_signed_device_list(added_device), false);

    SignedDeviceList dropped_revoked = dl;
    if (!dropped_revoked.revoked.empty()) dropped_revoked.revoked.pop_back();
    check_bool("rejects a revocation stripped after signing",
               verify_signed_device_list(dropped_revoked), false);

    SignedDeviceList bumped = dl;
    bumped.version = dl.version + 1;
    check_bool("rejects a bumped version", verify_signed_device_list(bumped), false);
}

int main() {
    printf("SignedDeviceList known-answer test\n");
    payload_format_tests();
    rejection_tests();

    if (!vector_filled()) {
        printf("\nPENDING VECTOR: the TODO(vector) block in this file still\n"
               "holds placeholders. The format and rejection checks above ran;\n"
               "the cross-language pinned checks did not.\n");
        if (failures == 0) return 2;
        printf("FAILED (%d)\n", failures);
        return 1;
    }

    pinned_vector_tests();

    if (failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAILED (%d)\n", failures);
    return 1;
}
