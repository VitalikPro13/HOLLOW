#pragma once
#include <algorithm>
#include <cstddef>
#include <deque>
#include <string>
#include <unordered_map>

// Which frame a full topic ring drops: the oldest frame of the sender holding the
// most frames in it. Anyone in a server's room may post to its rings, so plain
// FIFO let one sender flush every parked join and catch-up frame; this way a
// flooder evicts only itself (feedback_relay_rules: reprioritise, never refuse).
// Header-only so test/test_ring_evict.cpp drives it. Call on a non-empty ring.
template <typename Frame>
size_t ring_victim(const std::deque<Frame>& frames) {
    std::unordered_map<std::string, size_t> held;
    size_t most = 0;
    for (const auto& f : frames) most = std::max(most, ++held[f.sender]);
    for (size_t i = 0; i < frames.size(); i++) {
        if (held[frames[i].sender] == most) return i;
    }
    return 0;
}
