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

bool verify_ed25519_raw(const unsigned char* pubkey32,
                        const std::string& sig_b64,
                        const std::string& message) {
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
        pubkey32
    ) == 0;
}

// Bitcoin base58 alphabet (no 0, O, I, l).
static const char* B58_ALPHABET =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Standard base58btc decode; each leading '1' is one zero byte. False on any
// character outside the alphabet.
static bool base58_decode(const std::string& s, std::vector<unsigned char>& out) {
    size_t zeros = 0;
    while (zeros < s.size() && s[zeros] == '1') zeros++;
    // log(58)/log(256) ~= 0.732.
    std::vector<unsigned char> b256((s.size() - zeros) * 733 / 1000 + 1, 0);
    for (size_t i = zeros; i < s.size(); i++) {
        const char* p = strchr(B58_ALPHABET, s[i]);
        if (s[i] == '\0' || p == nullptr) return false;
        int carry = static_cast<int>(p - B58_ALPHABET);
        for (size_t j = b256.size(); j-- > 0;) {
            carry += 58 * b256[j];
            b256[j] = static_cast<unsigned char>(carry % 256);
            carry /= 256;
        }
        if (carry != 0) return false;
    }
    size_t it = 0;
    while (it < b256.size() && b256[it] == 0) it++;
    out.assign(zeros, 0);
    out.insert(out.end(), b256.begin() + static_cast<std::ptrdiff_t>(it), b256.end());
    return true;
}

bool peer_id_key(const std::string& peer_id, unsigned char out[32]) {
    // A 38-byte value takes at most 53 characters; anything longer names no key, and
    // the decode below is quadratic in the length.
    if (peer_id.size() > 64) return false;
    std::vector<unsigned char> d;
    if (!base58_decode(peer_id, d)) return false;
    static const unsigned char prefix[6] = {0x00, 0x24, 0x08, 0x01, 0x12, 0x20};
    if (d.size() != 38 || memcmp(d.data(), prefix, sizeof(prefix)) != 0) return false;
    memcpy(out, d.data() + 6, 32);
    return true;
}

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

std::string sha256_hex(const std::string& message) {
    unsigned char digest[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest, reinterpret_cast<const unsigned char*>(message.data()), message.size());
    return hex_encode(digest, sizeof(digest));
}

std::string random_hex(size_t bytes) {
    std::vector<unsigned char> buf(bytes);
    randombytes_buf(buf.data(), buf.size());
    return hex_encode(buf.data(), buf.size());
}

std::string genesis_server_id(const std::string& owner_peer_id, const std::string& nonce) {
    return sha256_hex("hollow-server1:" + owner_peer_id + ":" + nonce).substr(0, 40);
}

uint64_t share_id(const std::string& key, const std::string& block) {
    unsigned char out[crypto_generichash_BYTES_MIN];
    crypto_generichash(out, sizeof(out), reinterpret_cast<const unsigned char*>(block.data()), block.size(),
                       reinterpret_cast<const unsigned char*>(key.data()), key.size());
    uint64_t id = 0;
    for (int i = 0; i < 8; i++) id |= static_cast<uint64_t>(out[i]) << (8 * i);
    return id;
}

uint64_t now_unix_secs() {
    auto now = std::chrono::system_clock::now();
    auto epoch = now.time_since_epoch();
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(epoch).count()
    );
}

static std::string b64url(const unsigned char* data, size_t len) {
    std::string out(sodium_base64_encoded_len(len, sodium_base64_VARIANT_URLSAFE_NO_PADDING), '\0');
    sodium_bin2base64(out.data(), out.size(), data, len, sodium_base64_VARIANT_URLSAFE_NO_PADDING);
    out.resize(strlen(out.c_str()));
    return out;
}

static bool b64url_32(const std::string& text, unsigned char out[32]) {
    size_t len = 0;
    return text.size() == 43 &&
           sodium_base642bin(out, 32, text.c_str(), text.size(), nullptr, &len, nullptr,
                             sodium_base64_VARIANT_URLSAFE_NO_PADDING) == 0 &&
           len == 32;
}

void door_key_from(DoorKey& key, const unsigned char secret[32]) {
    memcpy(key.sk, secret, 32);
    crypto_scalarmult_base(key.pk, key.sk);
    key.text = b64url(key.pk, 32);
}

void door_key_mint(DoorKey& key) {
    unsigned char secret[32];
    randombytes_buf(secret, sizeof(secret));
    door_key_from(key, secret);
    sodium_memzero(secret, sizeof(secret));
}

static bool door_mac(const unsigned char sk[32], const unsigned char pk[32], const std::string& message,
                     unsigned char out[crypto_auth_hmacsha256_BYTES]) {
    unsigned char shared[crypto_scalarmult_BYTES];
    if (crypto_scalarmult(shared, sk, pk) != 0) return false;
    crypto_auth_hmacsha256(out, reinterpret_cast<const unsigned char*>(message.data()), message.size(), shared);
    sodium_memzero(shared, sizeof(shared));
    return true;
}

bool door_proof_opens(const DoorKey& key, const std::string& door_text, const std::string& message,
                      const std::string& proof_text) {
    unsigned char door[32];
    unsigned char proof[32];
    unsigned char expected[crypto_auth_hmacsha256_BYTES];
    if (!b64url_32(door_text, door) || !b64url_32(proof_text, proof)) return false;
    if (!door_mac(key.sk, door, message, expected)) return false;
    return crypto_verify_32(expected, proof) == 0;
}

std::string door_proof_make(const unsigned char door_sk[32], const unsigned char relay_pk[32], const std::string& message) {
    unsigned char mac[crypto_auth_hmacsha256_BYTES];
    if (!door_mac(door_sk, relay_pk, message, mac)) return "";
    return b64url(mac, sizeof(mac));
}
