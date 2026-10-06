#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "fair_share.h"

// Every buffered frame, DM, topic and session ring alike, charged to the address
// share of the socket that sent it (fair_share.h). Past the byte budget the share
// holding the most loses its oldest frame, so a flood from throwaway accounts fills
// and then churns only its own part of the budget and never pushes out what real
// people left for someone offline. Header-only so test/test_relay_validators.cpp
// drives it without a relay.
//
// Exact, not lazy: every path that removes a frame calls released(seq) (the
// enumeration lives in ws_handler.cpp) or, for a ring frame its ring let go,
// forget(seq) (session_bounds.h), so bytes() is the live total.
struct OfflineIndex {
    // What holding one frame costs beyond its bytes: the queue entry and its
    // strings, a DM target's own queue, this index. Counting it bounds a flood of
    // tiny frames, which would otherwise weigh next to nothing.
    static constexpr size_t FRAME_OVERHEAD_BYTES = 1024;

    struct Loc {
        std::string key;  // an offline_buffer target, a topic_buffers key, or a session's peer id
        bool is_topic = false;
        bool is_session = false;
    };

    uint64_t next_seq = 0;
    FairShare<uint64_t> frames;
    std::unordered_map<uint64_t, Loc> where;

    // Set by session_bounds.h, which owns the rings: turns a ring frame the budget
    // dropped into a tombstone in its ring, so its counters stay whole.
    std::function<void(uint64_t seq, const std::string& peer)> bury_session;

    uint64_t stamp(const std::string& key, bool is_topic, uint64_t share, size_t bytes) {
        uint64_t seq = ++next_seq;
        frames.put(seq, share, bytes + FRAME_OVERHEAD_BYTES);
        where.emplace(seq, Loc{key, is_topic, false});
        return seq;
    }

    // A frame in `peer`'s session ring. The rings of one fan-out share its buffer,
    // which is RAM once, so its bytes are charged once, to one of its holders; every
    // holder pays its own overhead.
    uint64_t stamp_session(const std::string& peer, uint64_t share, const void* buffer, size_t bytes) {
        uint64_t seq = ++next_seq;
        where.emplace(seq, Loc{peer, false, true});
        if (!buffer) {
            frames.put(seq, share, bytes + FRAME_OVERHEAD_BYTES);
            return seq;
        }
        auto [it, fresh] = shared_.try_emplace(buffer);
        Shared& sh = it->second;
        sh.holders.insert(seq);
        buffer_of_.emplace(seq, buffer);
        if (fresh) {
            sh.bytes = bytes;
            sh.charged = seq;
            frames.put(seq, share, bytes + FRAME_OVERHEAD_BYTES);
        } else {
            frames.put(seq, share, FRAME_OVERHEAD_BYTES);
        }
        return seq;
    }

    // The frame `seq` left its buffer, or the budget chose it. A ring frame cannot
    // leave by this path while its ring holds it, so it is buried there.
    void released(uint64_t seq) {
        auto it = where.find(seq);
        if (it != where.end() && it->second.is_session) {
            const std::string peer = std::move(it->second.key);
            forget(seq);
            if (bury_session) bury_session(seq, peer);
            return;
        }
        frames.remove(seq);
        if (it != where.end()) where.erase(it);
    }

    // A ring let its frame `seq` go: an ack, its own caps, the session's end.
    void forget(uint64_t seq) {
        auto b = buffer_of_.find(seq);
        if (b != buffer_of_.end()) {
            auto s = shared_.find(b->second);
            Shared& sh = s->second;
            sh.holders.erase(seq);
            if (sh.holders.empty()) {
                shared_.erase(s);
            } else if (sh.charged == seq) {
                sh.charged = *sh.holders.begin();
                frames.reweigh(sh.charged, sh.bytes + FRAME_OVERHEAD_BYTES);
            }
            buffer_of_.erase(b);
        }
        frames.remove(seq);
        where.erase(seq);
    }

    size_t live() const { return frames.size(); }
    size_t bytes() const { return frames.total(); }
    // The distinct buffers ring frames hold, each charged once.
    size_t shared_buffers() const { return shared_.size(); }

    // The frame the budget drops next: the oldest of the share holding the most.
    std::optional<std::pair<uint64_t, Loc>> victim() const {
        auto seq = frames.victim();
        if (!seq) return std::nullopt;
        return std::make_pair(*seq, where.at(*seq));
    }

private:
    struct Shared {
        size_t bytes = 0;
        uint64_t charged = 0;  // the holder its bytes are charged to
        std::unordered_set<uint64_t> holders;
    };
    std::unordered_map<const void*, Shared> shared_;
    std::unordered_map<uint64_t, const void*> buffer_of_;
};
