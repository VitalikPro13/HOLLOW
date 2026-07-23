#pragma once
#include <string>
#include <string_view>
#include <cstdint>

bool verify_ed25519(const std::string& pubkey_b64,
                    const std::string& sig_b64,
                    const std::string& message);

// Derive the canonical peer_id from a base64 protobuf-encoded Ed25519 public
// key, matching the client's `NativeKeypair::peer_id()` exactly:
//   bs58btc( [0x00, 0x24] || [0x08, 0x01, 0x12, 0x20] || pubkey32 )
//
// SECURITY: a peer_id is NOT a free-form claim — it is a pure function of the
// public key. Callers MUST compare this against the peer_id an auth frame
// claims; verifying the signature against the SUPPLIED public key alone proves
// only that the sender holds SOME key, not that they own the identity they are
// claiming. Returns "" if the key is malformed.
std::string derive_peer_id(const std::string& pubkey_b64);

std::string hmac_sha1_base64(const std::string& secret,
                             const std::string& message);

std::string hex_encode(const uint8_t* data, size_t len);

uint64_t now_unix_secs();
