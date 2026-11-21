#pragma once
#include <cstdint>

// One stderr line for the operator about a kind of refusal, at most once a minute per
// kind (#153): how many happened since the last line, never who or from where, since the
// relay keeps no connection metadata. Pure, so test/ can build it.
struct MinuteNote {
    static constexpr int64_t EVERY_MS = 60'000;

    bool said = false;
    int64_t last_ms = 0;
    uint64_t since = 0;

    // Counts one refusal at `now_ms`; returns how many the line due now names, 0 for none.
    uint64_t count(int64_t now_ms) {
        since++;
        if (said && now_ms - last_ms < EVERY_MS) return 0;
        said = true;
        last_ms = now_ms;
        const uint64_t n = since;
        since = 0;
        return n;
    }
};
