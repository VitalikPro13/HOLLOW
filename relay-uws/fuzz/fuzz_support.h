#pragma once
// Shared by the fuzz targets: an invariant check that crashes (so libFuzzer keeps
// the input), and stand-in crypto for the rules that take theirs from outside. A
// fuzzer cannot forge Ed25519, so with the real checks every input stops at the
// first signature; the stand-ins accept any signature that is not empty and does
// not start with '!' (never a base64 character), which lets inputs reach the merge,
// fold and chain rules behind the signatures in both outcomes. fuzz_crypto_inputs
// drives the real ones.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>

#include "join_lock.h"
#include "roster.h"
#include "validate.h"

#define FUZZ_CHECK(cond)                                                                   \
    do {                                                                                   \
        if (!(cond)) {                                                                     \
            fprintf(stderr, "fuzz invariant failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            abort();                                                                       \
        }                                                                                  \
    } while (0)

namespace fuzz {

inline bool stub_sig_ok(const std::string& sig) { return !sig.empty() && sig[0] != '!'; }

// 64 lowercase hex characters, deterministic, not a hash anyone relies on.
inline std::string stub_hex(const std::string& msg) {
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : msg) h = (h ^ c) * 1099511628211ull;
    static const char* digits = "0123456789abcdef";
    std::string out(64, '0');
    for (size_t i = 0; i < out.size(); i++) {
        out[i] = digits[(h >> ((i % 16) * 4)) & 0xf];
        if (i % 16 == 15) h = (h ^ i) * 1099511628211ull;
    }
    return out;
}

inline RosterCrypto roster_crypto() {
    RosterCrypto c;
    c.verify_by_id = [](const std::string& id, const std::string& sig, const std::string&) {
        return is_peer_id_shape(id) && stub_sig_ok(sig);
    };
    c.verify_by_key = [](const std::string& key, const std::string& sig, const std::string&) {
        return !key.empty() && stub_sig_ok(sig);
    };
    c.is_key = [](const std::string& id) { return is_peer_id_shape(id); };
    c.sha256_hex = [](const std::string& msg) { return stub_hex(msg); };
    return c;
}

// A key's peer id is the key itself, and a founding nonce names the server it starts
// with, so an input can line both up.
inline LockCrypto lock_crypto() {
    LockCrypto c;
    c.verify = [](const std::string& key, const std::string& sig, const std::string&) {
        return !key.empty() && stub_sig_ok(sig);
    };
    c.peer_id = [](const std::string& key) { return key; };
    c.genesis_id = [](const std::string&, const std::string& nonce) {
        std::string id = nonce.substr(0, 40);
        for (char& ch : id) {
            if (ch >= 'A' && ch <= 'F') ch = static_cast<char>(ch - 'A' + 'a');
        }
        return id;
    };
    return c;
}

inline std::string_view as_text(const uint8_t* data, size_t size) {
    return std::string_view(reinterpret_cast<const char*>(data), size);
}

}  // namespace fuzz
