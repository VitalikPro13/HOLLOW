// Unit tests for the topic-ring eviction choice (src/ring_evict.h): a sender
// flooding a channel ring must evict its own frames, never everyone else's.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_ring_evict.cpp -o test_ring_evict && ./test_ring_evict

#include "ring_evict.h"

#include <cstdio>
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

struct Frame {
    std::string sender;
    int id;
};

// Push `f` into a ring capped at `cap` frames the way the relay does.
static void push(std::deque<Frame>& ring, Frame f, size_t cap) {
    ring.push_back(std::move(f));
    while (ring.size() > cap) ring.erase(ring.begin() + ring_victim(ring));
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
        auto has = [&](int id) {
            for (const auto& f : ring) if (f.id == id) return true;
            return false;
        };
        check("the ring stays at its cap", ring.size() == 200);
        check("the first honest frame survives", has(1));
        check("the second honest frame survives", has(2));
        check("a frame after the flood lands", has(3));
        check("the flooder keeps only its newest frames", has(1099) && !has(100));
    }

    // Among equals, the oldest frame goes first: plain traffic keeps FIFO order.
    {
        std::deque<Frame> ring;
        for (int i = 0; i < 4; i++) push(ring, {i % 2 ? "b" : "a", i}, 3);
        check("equal senders fall back to the oldest frame", ring.front().id == 1 && ring.size() == 3);
    }

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
