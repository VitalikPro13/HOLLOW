#pragma once
#include <sodium.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

// What one socket may be told of a room's presence, and the digest of it a client
// compares with what it was told (`discover_peers` with `digest`). Every roster the
// relay sends and the digest read the same filter, or an honest client would see a
// difference that is not there and re-join for nothing.
//
// Header-only and generic over the socket type, so the rules are unit tested on their
// own (test/test_presence_view.cpp). `node/presence_audit.rs` pins the same tag.

namespace presence {

// The largest answer a client that does not ask for the digest (0.12.2) gets: a window
// of the room, so an ask costs the relay a bounded write.
inline constexpr size_t LEGACY_CAP = 64;

// A peer id's share of a digest: the first 8 bytes, little endian, of
// SHA-256("hollow-presence1\n" || id). Never 0 in practice; 0 marks "not cached yet".
inline uint64_t tag(std::string_view id) {
    static constexpr std::string_view TAG_DOMAIN = "hollow-presence1\n";
    crypto_hash_sha256_state st;
    crypto_hash_sha256_init(&st);
    crypto_hash_sha256_update(&st, reinterpret_cast<const unsigned char*>(TAG_DOMAIN.data()), TAG_DOMAIN.size());
    crypto_hash_sha256_update(&st, reinterpret_cast<const unsigned char*>(id.data()), id.size());
    unsigned char out[crypto_hash_sha256_BYTES];
    crypto_hash_sha256_final(&st, out);
    uint64_t t = 0;
    for (int i = 7; i >= 0; i--) t = (t << 8) | out[i];
    return t;
}

// An order-free summary of a set of ids: the wrapping sum of their tags, and how many.
struct Digest {
    uint64_t sum = 0;
    uint64_t count = 0;
    void add(uint64_t t) {
        sum += t;
        count++;
    }
};

// Whether a socket of `me` may see a room at all: an inbox only as an owner, a locked
// room only while its door proof stands.
inline bool viewer_sees(bool inbox, bool owner, bool locked, bool proved) {
    return (!inbox || owner) && (!locked || proved);
}

// One peer slot of a room as presence may name it to `me`: never `me`, a guest, a fetch
// socket or a hidden session, and only one `shares(pid)` admits.
template <typename Sock, typename Shares>
bool listed(const std::string& pid, Sock* sock, const std::string& me, const Shares& shares) {
    const auto* pd = sock->getUserData();
    return pid != me && !pd->is_guest && !pd->is_fetch && !pd->hidden && shares(pid);
}

// Every peer of `peers` presence may name to `me`; nobody unless `me_sees`.
template <typename Peers, typename Shares, typename Visit>
void for_each_visible(const Peers& peers, const std::string& me, bool me_sees, const Shares& shares, Visit&& visit) {
    if (!me_sees) return;
    for (const auto& [pid, sock] : peers) {
        if (listed(pid, sock, me, shares)) visit(pid, sock);
    }
}

// The digest of what `for_each_visible` names. A socket's tag is cached on it the first
// time it is counted.
template <typename Peers, typename Shares>
Digest digest_of(const Peers& peers, const std::string& me, bool me_sees, const Shares& shares) {
    Digest d;
    for_each_visible(peers, me, me_sees, shares, [&](const std::string& pid, auto* sock) {
        auto* pd = sock->getUserData();
        if (pd->presence_tag == 0) pd->presence_tag = tag(pid);
        d.add(pd->presence_tag);
    });
    return d;
}

// Up to `cap` of the peers `for_each_visible` names, walking the buckets from `start`
// and wrapping once: successive asks with random starts cover the room.
template <typename Peers, typename Shares, typename Visit>
void window_visible(const Peers& peers, const std::string& me, bool me_sees, const Shares& shares, size_t start,
                    size_t cap, Visit&& visit) {
    const size_t buckets = peers.bucket_count();
    if (!me_sees || buckets == 0 || cap == 0) return;
    size_t taken = 0;
    for (size_t i = 0; i < buckets; i++) {
        const size_t b = (start + i) % buckets;
        for (auto it = peers.begin(b); it != peers.end(b); ++it) {
            if (!listed(it->first, it->second, me, shares)) continue;
            visit(it->first);
            if (++taken == cap) return;
        }
    }
}

}  // namespace presence
