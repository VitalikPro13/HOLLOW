#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <strings.h>

#include "breaker.h"
#include "json.hpp"

// /server-stats with the public activity turned off (PUBLIC_STATS=off, AR-32): the online
// count, the traffic rates and the delivery counters all step when one person connects or
// starts a call, which on a small relay tells a watcher who is on. Only what no single
// person moves stays; a field added later stays out unless it is added here.
namespace server_stats {

inline void keep_public(nlohmann::json& body, bool public_stats) {
    if (public_stats) return;
    nlohmann::json kept = nlohmann::json::object();
    for (const char* key : {"mem_total_kb", "bandwidth_cap_mbps"}) {
        auto it = body.find(key);
        if (it != body.end()) kept[key] = *it;
    }
    // Memory in use only in whole percent of the total: on an idle relay one person's
    // mailbox deposit moves the exact figure.
    auto total = body.find("mem_total_kb");
    auto used = body.find("mem_used_kb");
    if (total != body.end() && used != body.end() && total->is_number_integer() && used->is_number_integer()) {
        const int64_t t = total->get<int64_t>();
        const int64_t u = used->get<int64_t>();
        // kB figures of real memory: far below where `* 100` could overflow.
        if (t > 0 && u >= 0 && t <= INT64_MAX / 100 && u <= INT64_MAX / 100) {
            const int64_t pct = std::min<int64_t>(u * 100 / t, 100);
            kept["mem_used_kb"] = pct * t / 100;
        }
    }
    body = std::move(kept);
}

// The circuit breaker's block while the public stats are on; keep_public drops it when off.
inline nlohmann::json breaker_block(const breaker::Stats& st, bool enforced, size_t cooling_devices) {
    return {{"enforced", enforced},
            {"trips", st.trips},
            {"ladder_steps", st.ladder_steps},
            {"refused", st.refused},
            {"cooling_devices", cooling_devices}};
}

// PUBLIC_STATS from the relay's environment, trimmed and in any case: unset, empty, on,
// true, yes or 1 keep the public activity; off, false, no or 0 turn it off. Anything else
// turns it off too, with a line saying so: a typo must not leave a relay's activity public.
inline bool parse_public_stats(const char* text) {
    std::string v = text ? text : "";
    const auto first = v.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return true;
    v = v.substr(first, v.find_last_not_of(" \t\r\n") - first + 1);
    for (const char* on : {"on", "true", "yes", "1"}) {
        if (strcasecmp(v.c_str(), on) == 0) return true;
    }
    for (const char* off : {"off", "false", "no", "0"}) {
        if (strcasecmp(v.c_str(), off) == 0) return false;
    }
    fprintf(stderr, "[config] PUBLIC_STATS is on or off; turning the public stats off\n");
    return false;
}

}  // namespace server_stats
