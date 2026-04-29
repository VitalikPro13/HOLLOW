#include "crypto.h"
#include <sodium.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <chrono>
#include <cstring>

bool verify_ed25519(const std::string& pubkey_b64,
                    const std::string& sig_b64,
                    const std::string& message) {
    unsigned char proto_bytes[36];
    size_t proto_len = 0;
    if (sodium_base642bin(proto_bytes, sizeof(proto_bytes),
                          pubkey_b64.c_str(), pubkey_b64.size(),
                          nullptr, &proto_len, nullptr,
                          sodium_base64_VARIANT_ORIGINAL) != 0 || proto_len != 36) {
        return false;
    }

    // Protobuf header: 08 01 12 20 (Ed25519 key type + 32-byte length)
    if (proto_bytes[0] != 0x08 || proto_bytes[1] != 0x01 ||
        proto_bytes[2] != 0x12 || proto_bytes[3] != 0x20) {
        return false;
    }

    const unsigned char* ed25519_key = proto_bytes + 4;

    unsigned char sig_bytes[64];
    size_t sig_len = 0;
    if (sodium_base642bin(sig_bytes, sizeof(sig_bytes),
                          sig_b64.c_str(), sig_b64.size(),
                          nullptr, &sig_len, nullptr,
                          sodium_base64_VARIANT_ORIGINAL) != 0 || sig_len != 64) {
        return false;
    }

    return crypto_sign_verify_detached(
        sig_bytes,
        reinterpret_cast<const unsigned char*>(message.c_str()),
        message.size(),
        ed25519_key
    ) == 0;
}

std::string hmac_sha1_base64(const std::string& secret,
                             const std::string& message) {
    unsigned char result[20];
    unsigned int result_len = 0;
    HMAC(EVP_sha1(),
         secret.data(), static_cast<int>(secret.size()),
         reinterpret_cast<const unsigned char*>(message.data()),
         message.size(),
         result, &result_len);

    char b64[64];
    sodium_bin2base64(b64, sizeof(b64), result, result_len,
                      sodium_base64_VARIANT_ORIGINAL);
    return std::string(b64);
}

std::string hex_encode(const uint8_t* data, size_t len) {
    std::string result;
    result.reserve(len * 2);
    for (size_t i = 0; i < len; i++) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", data[i]);
        result.append(buf, 2);
    }
    return result;
}

uint64_t now_unix_secs() {
    auto now = std::chrono::system_clock::now();
    auto epoch = now.time_since_epoch();
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(epoch).count()
    );
}
