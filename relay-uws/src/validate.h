#pragma once
#include <cstddef>
#include <string_view>

// Shape validation for CLIENT-SUPPLIED peer ids.
//
// A peer_id is base58btc of the identity multihash wrapping a 36-byte libp2p
// protobuf Ed25519 public key (derive_peer_id, crypto.cpp), so every id in
// service measures exactly 52 characters drawn from the Bitcoin base58
// alphabet. This check proves NOTHING about ownership — only handle_auth's
// derive_peer_id comparison does that. Its single job is to keep free-form
// attacker text out of the maps the relay KEYS on: the offline buffer is keyed
// by the 0x04/0x09 target string exactly as it arrived on the wire, which is
// what turned an unbounded key space into the RELAY-1 memory-growth primitive.
//
// An id that fails this is dropped in silence — no error frame, no log line, so
// a prober learns nothing it did not already know about its own input.
//
// The accepted length is deliberately wider than the 52 characters real ids
// measure: base58 output length is value-dependent and a future key type would
// shift it, so 40..64 keeps every plausible libp2p identity id while still
// refusing a megabyte of garbage. Widen only against a real derived id.
static constexpr size_t PEER_ID_MIN_LEN = 40;
static constexpr size_t PEER_ID_MAX_LEN = 64;

// Bitcoin base58 alphabet, spelled as ranges: the four characters it omits are
// exactly the visually ambiguous ones — '0', 'O', 'I', 'l'.
// ("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
inline bool is_base58btc_char(char c) {
    return (c >= '1' && c <= '9') ||
           (c >= 'A' && c <= 'H') || (c >= 'J' && c <= 'N') ||
           (c >= 'P' && c <= 'Z') ||
           (c >= 'a' && c <= 'k') || (c >= 'm' && c <= 'z');
}

inline bool is_peer_id_shape(std::string_view id) {
    if (id.size() < PEER_ID_MIN_LEN || id.size() > PEER_ID_MAX_LEN) return false;
    for (char c : id) {
        if (!is_base58btc_char(c)) return false;
    }
    return true;
}
