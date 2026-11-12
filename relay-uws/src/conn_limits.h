#pragma once
// The relay's connection limits as operator settings (SELF_HOSTING.md "Connection limits"):
// read once at start from the environment (the one .env / relay.env), each held to its
// range, never logged per address. `hollow-relay --check-limits` reads them the same way.
//
// Header-only so test/test_conn_limits.cpp drives it without a relay.
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace conn_limits {

// What a socket's address family allows: open sockets, and new ones a minute with a burst
// of the open cap (a token bucket, conn_rate::Gcra).
struct Family {
    size_t cap = 0;
    size_t rate_per_min = 0;
    // 0 = the open cap. Only a live-test relay sets it apart (HOLLOW_RELAY_TEST_CONN_BURST).
    size_t burst_override = 0;
    size_t burst() const { return burst_override ? burst_override : cap; }
};

struct Limits {
    Family v4{512, 120};
    // Per /64.
    Family v6{128, 30};
    // Sockets that have not logged in yet: per v4 /24 or v6 /48 (soft), and in all.
    size_t login_per_block = 256;
    size_t login_total = 10'000;
    // Open sockets of every kind (conn_book.h), shed by share past it.
    size_t connected = 65'536;
    bool breaker_enforce = true;

    // The family of an ip_limit_key: v6 keys carry a ':' (v4-mapped ones were unmapped).
    const Family& family(const std::string& ip_key) const {
        return ip_key.find(':') == std::string::npos ? v4 : v6;
    }

    // The rate and burst the fresh-start floor of a share block refills at: its family's
    // (a v6 /48 pool by the /64 numbers), never the compiled default.
    std::pair<size_t, size_t> floor_rate(const std::string& share_block) const {
        const Family& f = family(share_block);
        return {f.rate_per_min, f.burst()};
    }
};

struct Range {
    const char* name;
    size_t lo;
    size_t hi;
};

inline constexpr Range CONN_LIMIT_IPV4{"CONN_LIMIT_IPV4", 8, 65'536};
inline constexpr Range CONN_LIMIT_IPV6{"CONN_LIMIT_IPV6", 8, 65'536};
inline constexpr Range CONN_RATE_IPV4{"CONN_RATE_IPV4", 6, 6'000};
inline constexpr Range CONN_RATE_IPV6{"CONN_RATE_IPV6", 6, 6'000};
inline constexpr Range LOGIN_WINDOW_PER_BLOCK{"LOGIN_WINDOW_PER_BLOCK", 16, 65'536};
inline constexpr Range LOGIN_WINDOW_TOTAL{"LOGIN_WINDOW_TOTAL", 256, 1'000'000};
inline constexpr Range CONNECTED_LIMIT{"CONNECTED_LIMIT", 1'024, 4'194'304};

// What one open socket is budgeted at: its TLS state, uWS buffers and PerSocketData measured
// 13 to 26 KB.
inline constexpr size_t SOCKET_BYTES = 32 * 1024;

// The default connected budget for a box with `ram_bytes`: a quarter of it (the send budget
// takes another), held to a sane span.
inline size_t connected_default(uint64_t ram_bytes) {
    const uint64_t n = ram_bytes / 4 / SOCKET_BYTES;
    if (n < 4'096) return 4'096;
    if (n > 1'048'576) return 1'048'576;
    return static_cast<size_t>(n);
}

struct Parsed {
    Limits limits;
    // One line per value that was not taken as written (a held or ignored value).
    std::vector<std::string> notes;
};

// `text` for `r`: unset or empty keeps `fallback`; not a whole number keeps it with a note;
// outside the range is held to the nearer end with a note.
inline size_t parse_one(const char* text, Range r, size_t fallback, std::vector<std::string>& notes,
                        bool test_build = false) {
    if (!text || !*text) return fallback;
    // A live-test relay fills an address with a few sockets.
    if (test_build) r.lo = 1;
    char* end = nullptr;
    errno = 0;
    const long long v = strtoll(text, &end, 10);
    if (end == text || *end != '\0' || errno == ERANGE) {
        notes.push_back(std::string(r.name) + " is not a whole number, using " + std::to_string(fallback));
        return fallback;
    }
    if (v < static_cast<long long>(r.lo) || v > static_cast<long long>(r.hi)) {
        const size_t held = v < static_cast<long long>(r.lo) ? r.lo : r.hi;
        notes.push_back(std::string(r.name) + " " + std::to_string(v) + " is outside " + std::to_string(r.lo) +
                        " to " + std::to_string(r.hi) + ", using " + std::to_string(held));
        return held;
    }
    return static_cast<size_t>(v);
}

// The limits `env` names (getenv, or a test's map). `ram_bytes` sizes the connected default.
inline Parsed parse(const std::function<const char*(const char*)>& env, uint64_t ram_bytes, bool test_build = false) {
    Parsed p;
    Limits& l = p.limits;
    const bool t = test_build;
    l.connected = connected_default(ram_bytes);
    l.v4.cap = parse_one(env(CONN_LIMIT_IPV4.name), CONN_LIMIT_IPV4, l.v4.cap, p.notes, t);
    l.v6.cap = parse_one(env(CONN_LIMIT_IPV6.name), CONN_LIMIT_IPV6, l.v6.cap, p.notes, t);
    l.v4.rate_per_min = parse_one(env(CONN_RATE_IPV4.name), CONN_RATE_IPV4, l.v4.rate_per_min, p.notes, t);
    l.v6.rate_per_min = parse_one(env(CONN_RATE_IPV6.name), CONN_RATE_IPV6, l.v6.rate_per_min, p.notes, t);
    l.login_total = parse_one(env(LOGIN_WINDOW_TOTAL.name), LOGIN_WINDOW_TOTAL, l.login_total, p.notes, t);
    l.login_per_block =
        parse_one(env(LOGIN_WINDOW_PER_BLOCK.name), LOGIN_WINDOW_PER_BLOCK, l.login_per_block, p.notes, t);
    if (t) {
        const size_t burst = parse_one(env("HOLLOW_RELAY_TEST_CONN_BURST"), {"HOLLOW_RELAY_TEST_CONN_BURST", 1, 65'536},
                                       0, p.notes, t);
        l.v4.burst_override = l.v6.burst_override = burst;
    }
    if (l.login_per_block > l.login_total) {
        p.notes.push_back("LOGIN_WINDOW_PER_BLOCK " + std::to_string(l.login_per_block) +
                          " is above LOGIN_WINDOW_TOTAL, using " + std::to_string(l.login_total));
        l.login_per_block = l.login_total;
    }
    l.connected = parse_one(env(CONNECTED_LIMIT.name), CONNECTED_LIMIT, l.connected, p.notes, t);
    const char* mode = env("BREAKER_MODE");
    if (mode && *mode) {
        const std::string m(mode);
        if (m == "shadow") {
            l.breaker_enforce = false;
        } else if (m != "enforce") {
            p.notes.push_back("BREAKER_MODE " + m + " is neither enforce nor shadow, using enforce");
        }
    }
    return p;
}

// The one start line naming what is in force (numbers only).
inline std::string describe(const Limits& l) {
    return "connections per IPv4 address " + std::to_string(l.v4.cap) + " (" + std::to_string(l.v4.rate_per_min) +
           " new a minute), per IPv6 /64 " + std::to_string(l.v6.cap) + " (" + std::to_string(l.v6.rate_per_min) +
           " new a minute), logging in at once " + std::to_string(l.login_per_block) + " per block and " +
           std::to_string(l.login_total) + " in all, connected in all " + std::to_string(l.connected) +
           ", breaker " + (l.breaker_enforce ? "enforced" : "in shadow mode");
}

}  // namespace conn_limits
