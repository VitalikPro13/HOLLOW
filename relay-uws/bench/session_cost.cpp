// What the session bounds cost the relay's one thread at their caps (session_bounds.h,
// session.h): a mint at a full session table, a socket at a full address, and a fan-out
// into rings that are full. Prints microseconds per operation.
//
// Build + run from relay-uws/bench (needs the uWebSockets/uSockets headers):
//   g++ -std=c++20 -O2 -I../src -I../uWebSockets/src -I../uSockets/src session_cost.cpp -o session_cost
//   ./session_cost

#include "session_bounds.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;

static std::string peer(size_t i) {
    std::string s = "12D3KooW" + std::string(36, 'x');
    for (int k = 0; k < 8; k++) {
        s.push_back(static_cast<char>('a' + i % 26));
        i /= 26;
    }
    return s;
}

static double us_since(Clock::time_point t0, size_t ops) {
    return std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / static_cast<double>(ops);
}

static void fill_table(RelayState& st, size_t n) {
    const auto now = Clock::now();
    for (size_t i = 0; i < n; i++) {
        session::Session& s = st.sessions[peer(i)];
        s.peer_id = peer(i);
        s.sid = std::string(32, 'a');
        s.share = i % 7919;
        if (i % 3 == 0) {
            s.state = session::State::Grace;
            s.grace_until = now + std::chrono::seconds(i % 120);
            s.ip_key = "10.0." + std::to_string((i / 34) % 256) + "." + std::to_string(i / 8704);
        }
    }
}

// One 64-byte frame from one sender into each of `rings` rings already holding
// `held` frames apiece.
static void fan_out(size_t rings, size_t held) {
    RelayState st;
    std::vector<session::Session*> sessions;
    for (size_t i = 0; i < rings; i++) {
        session::Session& s = st.sessions[peer(i)];
        s.peer_id = peer(i);
        s.share = 1;
        sessions.push_back(&s);
    }
    auto push_all = [&](char c) {
        auto b = std::make_shared<const std::string>(64, c);
        for (auto* s : sessions) {
            session::Frame fr;
            fr.bytes = b;
            fr.share = 77;
            session_bounds::ring_push(st, *s, std::move(fr));
        }
    };
    for (size_t f = 0; f < held; f++) push_all('x');
    const int frames = 20;
    auto t0 = Clock::now();
    for (int f = 0; f < frames; f++) push_all('y');
    const double per_frame = us_since(t0, frames);
    printf("one frame into %zu rings of %zu frames: %.0f us (%.2f us per ring), pool %zu MiB in %zu frames\n",
           rings, sessions.front()->ring.real_frames(), per_frame, per_frame / static_cast<double>(rings),
           st.buffer_index.ring_bytes() >> 20, st.buffer_index.ring_live());
}

// Rings at their frame cap where the heaviest sender's oldest frame sits mid-ring: an
// older light share in front, a heavier one behind it, every push burying from the middle.
static void mid_ring(size_t rings) {
    RelayState st;
    std::vector<session::Session*> sessions;
    for (size_t i = 0; i < rings; i++) {
        session::Session& s = st.sessions[peer(i)];
        s.peer_id = peer(i);
        s.share = 1;
        sessions.push_back(&s);
    }
    auto push_all = [&](uint64_t share, size_t n) {
        auto b = std::make_shared<const std::string>(n, 'z');
        for (auto* s : sessions) {
            session::Frame fr;
            fr.bytes = b;
            fr.share = share;
            session_bounds::ring_push(st, *s, std::move(fr));
        }
    };
    for (size_t f = 0; f < session::RING_MAX_FRAMES / 2; f++) push_all(5, 16);
    for (size_t f = 0; f < session::RING_MAX_FRAMES / 2; f++) push_all(6, 64);
    const int frames = 200;
    auto t0 = Clock::now();
    for (int f = 0; f < frames; f++) push_all(6, 64);
    const double per_frame = us_since(t0, frames);
    printf("one frame into %zu full rings burying mid-ring: %.0f us (%.2f us per ring)\n", rings, per_frame,
           per_frame / static_cast<double>(rings));
}

int main() {
    {
        RelayState st;
        fill_table(st, session::MAX_SESSIONS);
        // The first call finds the book empty and builds it from the table, once.
        auto t0 = Clock::now();
        session_bounds::make_room(st, 12345, peer(999999));
        printf("first make_room, building the book over %zu sessions: %.0f us\n", st.sessions.size(), us_since(t0, 1));
        const int ops = 2000;
        t0 = Clock::now();
        size_t named = 0;
        for (int i = 0; i < ops; i++) named += session_bounds::make_room(st, 12345, peer(1000000 + i)).size();
        printf("make_room at a full table of %zu: %.2f us per mint (%zu named)\n", st.sessions.size(),
               us_since(t0, ops), named);

        t0 = Clock::now();
        size_t found = 0;
        for (int i = 0; i < ops; i++) found += session_bounds::grace_slot_victim(st, "10.0.5.3").has_value();
        printf("grace_slot_victim over %zu sessions: %.2f us per socket at a full address (%zu found)\n",
               st.sessions.size(), us_since(t0, ops), found);
    }

    fan_out(60, session::RING_MAX_FRAMES);
    fan_out(1000, 400);
    fan_out(10000, 40);
    mid_ring(60);
    return 0;
}
