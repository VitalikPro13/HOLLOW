#include "crypto.h"
#include <sodium.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <chrono>
#include <cstring>
#include <vector>

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

// Bitcoin base58 alphabet (no 0, O, I, l).
static const char* B58_ALPHABET =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Standard base58btc encode. Each leading zero byte maps to a literal '1'.
static std::string base58_encode(const unsigned char* data, size_t len) {
    size_t zeros = 0;
    while (zeros < len && data[zeros] == 0) zeros++;

    // log(256)/log(58) ~= 1.365; 138/100 is the usual safe over-allocation.
    std::vector<unsigned char> b58((len - zeros) * 138 / 100 + 1, 0);

    for (size_t i = zeros; i < len; i++) {
        int carry = data[i];
        for (size_t j = b58.size(); j-- > 0;) {
            carry += 256 * b58[j];
            b58[j] = static_cast<unsigned char>(carry % 58);
            carry /= 58;
        }
    }

    size_t it = 0;
    while (it < b58.size() && b58[it] == 0) it++;

    std::string result;
    result.reserve(zeros + (b58.size() - it));
    result.assign(zeros, '1');
    for (; it < b58.size(); it++) result += B58_ALPHABET[b58[it]];
    return result;
}

std::string derive_peer_id(const std::string& pubkey_b64) {
    unsigned char proto_bytes[36];
    size_t proto_len = 0;
    if (sodium_base642bin(proto_bytes, sizeof(proto_bytes),
                          pubkey_b64.c_str(), pubkey_b64.size(),
                          nullptr, &proto_len, nullptr,
                          sodium_base64_VARIANT_ORIGINAL) != 0 || proto_len != 36) {
        return "";
    }

    // Protobuf header: 08 01 12 20 (Ed25519 key type + 32-byte length).
    if (proto_bytes[0] != 0x08 || proto_bytes[1] != 0x01 ||
        proto_bytes[2] != 0x12 || proto_bytes[3] != 0x20) {
        return "";
    }

    // Identity multihash (code 0x00) wrapping the 36-byte protobuf key. libp2p
    // inlines rather than hashing because 36 <= the 42-byte threshold.
    unsigned char multihash[38];
    multihash[0] = 0x00;
    multihash[1] = 0x24;  // 36
    memcpy(multihash + 2, proto_bytes, sizeof(proto_bytes));

    return base58_encode(multihash, sizeof(multihash));
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
