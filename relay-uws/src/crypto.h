#pragma once
#include <string>
#include <string_view>
#include <cstdint>

bool verify_ed25519(const std::string& pubkey_b64,
                    const std::string& sig_b64,
                    const std::string& message);

std::string hmac_sha1_base64(const std::string& secret,
                             const std::string& message);

std::string hex_encode(const uint8_t* data, size_t len);

uint64_t now_unix_secs();
