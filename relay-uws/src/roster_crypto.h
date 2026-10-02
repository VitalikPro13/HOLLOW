#pragma once
#include <string>

#include <sodium.h>

#include "crypto.h"
#include "roster.h"

// The relay's crypto for roster.h: libsodium, which refuses at least every signature
// the client's `verify_strict` refuses for these keys.
inline RosterCrypto roster_crypto() {
    RosterCrypto c;
    c.verify_by_id = [](const std::string& id, const std::string& sig, const std::string& msg) {
        unsigned char pk[32];
        return peer_id_key(id, pk) && verify_ed25519_raw(pk, sig, msg);
    };
    c.verify_by_key = [](const std::string& key_b64, const std::string& sig, const std::string& msg) {
        unsigned char pk[32];
        size_t len = 0;
        if (sodium_base642bin(pk, sizeof(pk), key_b64.c_str(), key_b64.size(), nullptr, &len, nullptr,
                              sodium_base64_VARIANT_ORIGINAL) != 0 ||
            len != sizeof(pk)) {
            return false;
        }
        return verify_ed25519_raw(pk, sig, msg);
    };
    c.is_key = [](const std::string& id) {
        unsigned char pk[32];
        return peer_id_key(id, pk);
    };
    c.sha256_hex = [](const std::string& msg) { return sha256_hex(msg); };
    return c;
}
