#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>

#include "fair_share.h"

// Every buffered frame, DM and topic alike, charged to the address share of the
// socket that sent it (fair_share.h). Past the byte budget the share holding the
// most loses its oldest frame, so a flood from throwaway accounts fills and then
// churns only its own part of the budget and never pushes out what real people
// left for someone offline. Header-only so test/test_relay_validators.cpp drives
// it without a relay.
//
// Exact, not lazy: every path that removes a frame calls released(seq) (the
// enumeration lives in ws_handler.cpp), so bytes() is the live total.
struct OfflineIndex {
    // What holding one frame costs beyond its bytes: the queue entry and its
    // strings, a DM target's own queue, this index. Counting it bounds a flood of
    // tiny frames, which would otherwise weigh next to nothing.
    static constexpr size_t FRAME_OVERHEAD_BYTES = 1024;

    struct Loc {
        std::string key;  // an offline_buffer target, or a topic_buffers key
        bool is_topic = false;
    };

    uint64_t next_seq = 0;
    FairShare<uint64_t> frames;
    std::unordered_map<uint64_t, Loc> where;

    uint64_t stamp(const std::string& key, bool is_topic, uint64_t share, size_t bytes) {
        uint64_t seq = ++next_seq;
        frames.put(seq, share, bytes + FRAME_OVERHEAD_BYTES);
        where.emplace(seq, Loc{key, is_topic});
        return seq;
    }

    void released(uint64_t seq) {
        frames.remove(seq);
        where.erase(seq);
    }

    size_t live() const { return frames.size(); }
    size_t bytes() const { return frames.total(); }

    // The frame the budget drops next: the oldest of the share holding the most.
    std::optional<std::pair<uint64_t, Loc>> victim() const {
        auto seq = frames.victim();
        if (!seq) return std::nullopt;
        return std::make_pair(*seq, where.at(*seq));
    }
};
