#pragma once
#include <string>
#include <string_view>
#include <cstdint>

bool verify_ed25519(const std::string& pubkey_b64,
                    const std::string& sig_b64,
                    const std::string& message);

// Ed25519 over `message` by a raw 32-byte public key.
bool verify_ed25519_raw(const unsigned char* pubkey32,
                        const std::string& sig_b64,
                        const std::string& message);

// The raw Ed25519 key a peer id names, matching the client's
// `safety_number::pubkey_from_peer_id`: base58btc of
// [0x00, 0x24, 0x08, 0x01, 0x12, 0x20] || key. False when it names none.
bool peer_id_key(const std::string& peer_id, unsigned char out[32]);

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

// Standard padded base64 to bytes; false on anything else.
bool base64_decode(const std::string& text, std::string& out);

// Lowercase hex SHA-256 of `message`.
std::string sha256_hex(const std::string& message);

// `bytes` random bytes from libsodium, as lowercase hex.
std::string random_hex(size_t bytes);

// The self-certifying server id an owner peer id and a founding nonce hash to,
// matching the client's `anchor::derive_server_id`.
std::string genesis_server_id(const std::string& owner_peer_id, const std::string& nonce);

// A fair share's id (fair_share.h): `block` hashed under `key` (BLAKE2b), 8 bytes.
uint64_t share_id(const std::string& key, const std::string& block);

uint64_t now_unix_secs();

// The relay's X25519 key for door proofs (door_room.h): minted at start, RAM only,
// so a proof made for one relay process opens nothing on the next.
struct DoorKey {
    unsigned char sk[32];
    unsigned char pk[32];
    std::string text;  // the public half, URL-safe base64 without padding
};

void door_key_from(DoorKey& key, const unsigned char secret[32]);
void door_key_mint(DoorKey& key);

// Whether `proof_text` is the proof the holder of door `door_text`'s secret makes over
// `message` for `key`: HMAC-SHA256 under their X25519 shared secret, compared in
// constant time. A low-order door or a malformed text proves nothing.
bool door_proof_opens(const DoorKey& key, const std::string& door_text, const std::string& message,
                      const std::string& proof_text);

// The proof a door secret makes over `message` for relay key `relay_pk` (the client's
// side, for tests). "" when the shared secret is all zero.
std::string door_proof_make(const unsigned char door_sk[32], const unsigned char relay_pk[32], const std::string& message);
