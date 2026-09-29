// Unit tests for the topic-ring eviction choice (src/ring_evict.h): an address
// share flooding a channel ring must evict its own frames, never everyone else's.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_ring_evict.cpp -o test_ring_evict && ./test_ring_evict

#include "ring_evict.h"

#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

// Each named sender below stands for its own address share.
struct Frame {
    std::string sender;
    int id;
    size_t bytes = 1;
    uint64_t share = std::hash<std::string>{}(sender);
};

static size_t size_of(const Frame& f) { return f.bytes; }

// Push `f` into a ring capped at `cap` frames and `cap_bytes` bytes the way the
// relay does.
static void push(std::deque<Frame>& ring, Frame f, size_t cap, size_t cap_bytes = SIZE_MAX) {
    ring.push_back(std::move(f));
    auto bytes = [&ring] {
        size_t n = 0;
        for (const auto& x : ring) n += x.bytes;
        return n;
    };
    while (!ring.empty() && (ring.size() > cap || bytes() > cap_bytes)) {
        ring.erase(ring.begin() + ring_victim(ring, size_of));
    }
}

static bool has(const std::deque<Frame>& ring, int id) {
    for (const auto& f : ring) if (f.id == id) return true;
    return false;
}

int main() {
    printf("ring eviction\n");

    // I7: honest parked frames survive a flood of 1000 junk frames into a ring of 200.
    {
        std::deque<Frame> ring;
        push(ring, {"joiner-a", 1}, 200);
        push(ring, {"member-b", 2}, 200);
        for (int i = 0; i < 1000; i++) push(ring, {"flooder", 100 + i}, 200);
        push(ring, {"joiner-c", 3}, 200);
        check("the ring stays at its cap", ring.size() == 200);
        check("the first honest frame survives", has(ring, 1));
        check("the second honest frame survives", has(ring, 2));
        check("a frame after the flood lands", has(ring, 3));
        check("the flooder keeps only its newest frames", has(ring, 1099) && !has(ring, 100));
    }

    // Among equals, the oldest frame goes first: plain traffic keeps FIFO order.
    {
        std::deque<Frame> ring;
        for (int i = 0; i < 4; i++) push(ring, {i % 2 ? "b" : "a", i}, 3);
        check("equal senders fall back to the oldest frame", ring.front().id == 1 && ring.size() == 3);
    }

    // A25: one frame just under the byte cap evicts its own sender, not everyone else.
    {
        std::deque<Frame> ring;
        const size_t cap_bytes = 1000;
        for (int i = 0; i < 10; i++) push(ring, {i % 2 ? "member-b" : "member-a", i, 40}, 200, cap_bytes);
        push(ring, {"flooder", 99, 990}, 200, cap_bytes);
        check("the big frame is the one that goes", !has(ring, 99));
        bool all_honest = true;
        for (int i = 0; i < 10; i++) all_honest = all_honest && has(ring, i);
        check("every honest frame stays", all_honest);
    }

    // Bytes, not frame counts: many small frames outweigh one mid-sized one only
    // when they hold more bytes.
    {
        std::deque<Frame> ring;
        push(ring, {"chatty", 1, 10}, 3);
        push(ring, {"chatty", 2, 10}, 3);
        push(ring, {"bulky", 3, 100}, 3);
        push(ring, {"quiet", 4, 5}, 3);
        check("the sender holding the most bytes loses its oldest", !has(ring, 3) && has(ring, 1) && has(ring, 4));
    }

    // Many identities on one address are one share: they flood only themselves.
    {
        std::deque<Frame> ring;
        push(ring, {"member", 1}, 10);
        for (int i = 0; i < 100; i++) {
            Frame f{"sybil" + std::to_string(i), 100 + i};
            f.share = 42;
            push(ring, f, 10);
        }
        check("throwaway identities on one address evict only each other", has(ring, 1) && ring.size() == 10);
    }

    check("a quarter megabyte is the ring frame limit", MAX_RING_FRAME_BYTES == 256 * 1024);

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
