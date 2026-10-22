// The real crypto wrappers (src/crypto.cpp) on client text: the claimed key of an
// auth frame, peer ids a roster or lock names (base58 decoded by hand), base64
// signatures and blobs, door proofs, and the address keys. The base58 decoder and
// encoder must agree: a peer id that names a key must be the id that key derives.

#include <sodium.h>

#include <algorithm>
#include <cstring>
#include <string>

#include "auth_frame.h"
#include "crypto.h"
#include "fuzz_support.h"
#include "ip_key.h"
#include "validate.h"

namespace {

std::string b64(const unsigned char* data, size_t len) {
    std::string out(sodium_base64_encoded_len(len, sodium_base64_VARIANT_ORIGINAL), '\0');
    sodium_bin2base64(out.data(), out.size(), data, len, sodium_base64_VARIANT_ORIGINAL);
    out.pop_back();
    return out;
}

DoorKey relay_door_key() {
    unsigned char secret[32];
    for (int i = 0; i < 32; i++) secret[i] = static_cast<unsigned char>(i * 7 + 1);
    DoorKey key;
    door_key_from(key, secret);
    return key;
}

}  // namespace

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    if (sodium_init() < 0) abort();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    // Three fields split at the first two NULs: two texts and a message.
    const std::string_view text = fuzz::as_text(data, size);
    const size_t end_a = std::min(text.find('\0'), text.size());
    const size_t end_b = end_a < text.size() ? std::min(text.find('\0', end_a + 1), text.size()) : text.size();
    const std::string a(text.substr(0, end_a));
    const std::string b(end_a < text.size() ? text.substr(end_a + 1, end_b - end_a - 1) : std::string_view{});
    const std::string msg(end_b < text.size() ? text.substr(end_b + 1) : std::string_view{});

    unsigned char key[32];
    if (peer_id_key(a, key)) {
        FUZZ_CHECK(is_peer_id_shape(a));
        unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
        memcpy(proto + 4, key, 32);
        FUZZ_CHECK(derive_peer_id(b64(proto, sizeof(proto))) == a);
        (void)verify_ed25519_raw(key, b, msg);
    }
    const std::string derived = derive_peer_id(a);
    if (!derived.empty()) {
        FUZZ_CHECK(is_peer_id_shape(derived));
        unsigned char back[32];
        FUZZ_CHECK(peer_id_key(derived, back));
    }
    (void)verify_ed25519(a, b, msg);

    std::string decoded;
    if (base64_decode(a, decoded)) FUZZ_CHECK(decoded.size() <= a.size());

    static const DoorKey door_key = relay_door_key();
    (void)door_proof_opens(door_key, a, msg, b);

    for (const std::string& ip : {a, b}) {
        (void)ip_limit_key(ip);
        (void)share_block(ip);
    }
    (void)auth_domain(a);
    (void)genesis_server_id(a, b);
    return 0;
}
