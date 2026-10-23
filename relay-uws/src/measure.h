#pragma once
// Phase G (G2) measuring build only (-DHOLLOW_RELAY_MEASURE): anonymous per-connection
// peaks of what each socket makes the relay do, read by loopback HTTP on a test relay.
// No peer id, address or room name is kept; nothing reaches disk. A production build
// compiles every hook below to nothing.
#ifdef HOLLOW_RELAY_MEASURE
#include <array>
#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "json.hpp"

namespace measure {

using Clock = std::chrono::steady_clock;

// FRAMES..CTRL are counted from what the socket sends; WRITES..CPU_US are the relay
// work done while handling it (every socket write or held-ring push, signature checks,
// door DH checks, handler time).
enum C : int { FRAMES, BYTES, JOINS, LEAVES, DIRECTS, BCASTS, CTRL, LOCKPUTS, WRITES, WRITE_BYTES, VERIFIES, DH, CPU_US, N };
inline const char* name(int c) {
    static const char* names[N] = {"frames", "bytes", "joins", "leaves", "directs", "bcasts", "ctrl",
                                   "lockputs", "writes", "write_bytes", "verifies", "dh", "cpu_us"};
    return names[c];
}
constexpr int SECS = 600;
constexpr int NW = 4;
constexpr int WIN[NW] = {1, 10, 60, 600};

// Bumped by the hooks wherever the work happens; a Scope charges the difference.
inline uint64_t g[N] = {};
inline int depth = 0;

// Exact count of distinct keys seen in the last `span` seconds, and its peak.
class Distinct {
public:
    explicit Distinct(int64_t span) : span_(span) {}
    void see(uint64_t key, int64_t sec) {
        expire(sec);
        auto it = last_.find(key);
        if (it != last_.end() && it->second == sec) return;
        last_[key] = sec;
        order_.emplace_back(sec, key);
        if (last_.size() > peak_) peak_ = last_.size();
    }
    void expire(int64_t sec) {
        while (!order_.empty() && order_.front().first <= sec - span_) {
            auto [t, k] = order_.front();
            order_.pop_front();
            auto it = last_.find(k);
            if (it != last_.end() && it->second == t) last_.erase(it);
        }
    }
    uint64_t peak() const { return peak_; }

private:
    int64_t span_;
    std::unordered_map<uint64_t, int64_t> last_;
    std::deque<std::pair<int64_t, uint64_t>> order_;
    uint64_t peak_ = 0;
};

struct Meter {
    Clock::time_point start = Clock::now();
    int64_t cur = 0;
    std::array<std::array<uint32_t, SECS>, N> b{};
    uint64_t sum[NW][N] = {};
    uint64_t peak[NW][N] = {};
    uint64_t total[N] = {};
    Distinct targets10{10}, targets60{60}, rooms60{60};
    std::unordered_set<uint64_t> targets_ever;
    bool fetch = false, guest = false, session = false, resumed = false, authed = false;
    bool closed = false, recorded = false;

    void step() {
        for (int w = 0; w < NW; w++)
            for (int c = 0; c < N; c++)
                if (sum[w][c] > peak[w][c]) peak[w][c] = sum[w][c];
        cur++;
        for (int w = 0; w < NW; w++) {
            if (cur - WIN[w] < 0) continue;
            const int slot = static_cast<int>((cur - WIN[w]) % SECS);
            for (int c = 0; c < N; c++) sum[w][c] -= b[c][slot];
        }
        const int slot = static_cast<int>(cur % SECS);
        for (int c = 0; c < N; c++) b[c][slot] = 0;
    }
    void advance(Clock::time_point now) {
        const int64_t s = std::chrono::duration_cast<std::chrono::seconds>(now - start).count();
        if (s - cur > SECS + 1) {
            for (int w = 0; w < NW; w++)
                for (int c = 0; c < N; c++) {
                    if (sum[w][c] > peak[w][c]) peak[w][c] = sum[w][c];
                    sum[w][c] = 0;
                }
            for (auto& row : b) row.fill(0);
            cur = s;
            return;
        }
        while (cur < s) step();
    }
    void add(int c, uint64_t v, Clock::time_point now = Clock::now()) {
        if (v == 0) return;
        advance(now);
        b[c][cur % SECS] += static_cast<uint32_t>(v);
        for (int w = 0; w < NW; w++) sum[w][c] += v;
        total[c] += v;
    }
    void target(uint64_t h) {
        advance(Clock::now());
        targets10.see(h, cur);
        targets60.see(h, cur);
        if (targets_ever.size() < 1000000) targets_ever.insert(h);
    }
    void room(uint64_t h) {
        advance(Clock::now());
        rooms60.see(h, cur);
    }
    nlohmann::json record() {
        advance(Clock::now());
        nlohmann::json pk = nlohmann::json::object();
        for (int c = 0; c < N; c++) {
            nlohmann::json row = nlohmann::json::array();
            for (int w = 0; w < NW; w++) row.push_back(std::max(peak[w][c], sum[w][c]));
            pk[name(c)] = row;
        }
        nlohmann::json tot = nlohmann::json::object();
        for (int c = 0; c < N; c++) tot[name(c)] = total[c];
        const double secs = std::chrono::duration<double>(Clock::now() - start).count();
        return {{"secs", secs},           {"fetch", fetch},       {"guest", guest},  {"authed", authed},
                {"session", session},     {"resumed", resumed},   {"peaks", pk},
                {"totals", tot},          {"targets_peak10", targets10.peak()},
                {"targets_peak60", targets60.peak()},             {"rooms_peak60", rooms60.peak()},
                {"targets_ever", targets_ever.size()}};
    }
};

struct Book {
    std::vector<nlohmann::json> closed;
    uint64_t attributed[N] = {};
};
inline Book book;

// Meters of closed sockets, kept until no handler on the stack can still charge them
// (a close runs inside the closing socket's own message handler).
inline std::vector<std::unique_ptr<Meter>> graveyard;

inline void finish(Meter* m) {
    if (!m || m->recorded) return;
    m->recorded = true;
    if (book.closed.size() < 200000) book.closed.push_back(m->record());
}

inline void settle_graveyard() {
    for (auto& m : graveyard) finish(m.get());
    graveyard.clear();
}

inline uint64_t hash_of(std::string_view s) { return std::hash<std::string_view>{}(s); }

// Charges the relay work done while it lives to `m` (the outermost scope only).
class Scope {
public:
    explicit Scope(Meter* m) : m_(m), outer_(depth++ == 0) {
        if (!outer_ || !m_) return;
        for (int c = WRITES; c < N; c++) g0_[c] = g[c];
        t0_ = Clock::now();
    }
    ~Scope() {
        depth--;
        if (!outer_) return;
        if (!m_) {
            settle_graveyard();
            return;
        }
        const auto now = Clock::now();
        g[CPU_US] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now - t0_).count());
        for (int c = WRITES; c < N; c++) {
            const uint64_t d = g[c] - g0_[c];
            m_->add(c, d, now);
            book.attributed[c] += d;
        }
        settle_graveyard();
    }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;

private:
    Meter* m_;
    bool outer_;
    uint64_t g0_[N] = {};
    Clock::time_point t0_;
};

// A closing socket's meter: recorded now, or by the handler it closes inside.
inline void bury(std::unique_ptr<Meter> m) {
    if (!m) return;
    m->closed = true;
    Meter* raw = m.get();
    graveyard.push_back(std::move(m));
    (void)raw;
    if (depth == 0) settle_graveyard();
}

// The loopback report: every closed socket's record, every live one's so far, and the
// relay work no socket's handling did (timers, sweeps).
template <typename LiveFn>
inline std::string report(LiveFn&& live) {
    nlohmann::json out;
    out["closed"] = book.closed;
    nlohmann::json now = nlohmann::json::array();
    live([&](Meter* m) {
        if (m) now.push_back(m->record());
    });
    out["live"] = std::move(now);
    nlohmann::json bg = nlohmann::json::object();
    for (int c = WRITES; c < N; c++) bg[name(c)] = g[c] - book.attributed[c];
    out["background"] = std::move(bg);
    return out.dump();
}

inline void reset() {
    book.closed.clear();
    for (int c = 0; c < N; c++) book.attributed[c] = g[c];
}

}  // namespace measure

#define MEASURE_BUMP(c, v) (::measure::g[::measure::c] += (v))
#else
#define MEASURE_BUMP(c, v) ((void)0)
#endif
