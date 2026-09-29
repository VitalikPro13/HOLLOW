#pragma once
#include <cstdint>
#include <cstdlib>
#include <string>
#include <string_view>
#include <vector>

#include "join_lock.h"
#include "json.hpp"

// Who may change a server's catch-up rings (create one, set its retention, stop it):
// whoever holds the change key of the server's newest join lock on this relay,
// which is its owner, admins and mods (join_lock.h). Anyone in the room could before,
// so a stranger with the server id could stretch retention to a week or stop the
// rings every late joiner and parked join depends on. An unsigned request may only
// keep existing rings from idling out.
//
// Mirrors rust/hollow_core/src/node/ring_auth.rs; test/test_ring_auth.cpp pins the
// same vector as the Rust test. Header-only; the signature check comes in through
// LockCrypto so the rules are unit tested with stubs.

namespace ring_auth {

// A signed control older or newer than this is refused: it names a lock that may
// already have moved, and a relay keeps no nonce list for these.
static constexpr int64_t MAX_SKEW_MS = 10 * 60 * 1000;
static constexpr size_t MAX_CHANNEL_LEN = 128;

// A channel id or the join topic: the payload joins them by newline.
inline bool is_channel_shape(std::string_view c) {
    if (c.empty() || c.size() > MAX_CHANNEL_LEN) return false;
    for (char ch : c) {
        bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
                  ch == '-' || ch == '_' || ch == '~' || ch == '.';
        if (!ok) return false;
    }
    return true;
}

struct Control {
    std::string room;
    // Keys a legacy (32-hex) server's lock record; empty or ignored for a
    // self-certifying id, which names its owner itself.
    std::string owner;
    int64_t ts_ms = 0;
    int64_t retention_secs = 0;
    bool clear = false;
    std::vector<std::string> channels;
    std::string sig;
};

inline std::string payload(const Control& c) {
    std::string p = "hollow-ring1\n" + c.room + "\n" + c.owner + "\n" + std::to_string(c.ts_ms) + "\n" +
                    std::to_string(c.retention_secs) + "\n" + (c.clear ? "clear" : "keep");
    for (const auto& ch : c.channels) p += "\n" + ch;
    return p;
}

// Reads `set_topic_buffer`. A malformed signed request is no request at all, never
// an unsigned one: `signed_out` says which it claimed to be.
inline bool parse(const nlohmann::json& j, Control& out, bool& signed_out) {
    if (!j.is_object()) return false;
    auto text = [&j](const char* key, std::string& dst) {
        auto it = j.find(key);
        if (it == j.end()) return true;
        if (!it->is_string()) return false;
        dst = it->get<std::string>();
        return true;
    };
    if (!text("room", out.room) || !text("owner", out.owner) || !text("sig", out.sig)) return false;
    signed_out = j.contains("sig");
    if (auto it = j.find("clear"); it != j.end()) {
        if (!it->is_boolean()) return false;
        out.clear = it->get<bool>();
    }
    if (auto it = j.find("retention_secs"); it != j.end()) {
        if (!it->is_number_integer()) return false;
        out.retention_secs = it->get<int64_t>();
    }
    if (auto it = j.find("ts"); it != j.end()) {
        if (!it->is_number_integer()) return false;
        out.ts_ms = it->get<int64_t>();
    }
    if (auto it = j.find("channels"); it != j.end()) {
        if (!it->is_array()) return false;
        for (const auto& c : *it) {
            if (!c.is_string()) return false;
            out.channels.push_back(c.get<std::string>());
        }
    }
    return true;
}

// Whether a signed control counts: fresh, well formed, and signed by the change key
// of the newest link of `chain` (the relay's chain for this server, null if none).
inline bool authorized(const Control& c, const std::vector<LockLink>* chain, int64_t now_ms,
                       const LockCrypto& crypto) {
    if (!chain || chain->empty() || c.sig.empty()) return false;
    if (c.ts_ms <= 0) return false;
    int64_t skew = now_ms > c.ts_ms ? now_ms - c.ts_ms : c.ts_ms - now_ms;
    if (skew > MAX_SKEW_MS) return false;
    for (const auto& ch : c.channels) {
        if (!is_channel_shape(ch)) return false;
    }
    return crypto.verify(chain->back().change, c.sig, payload(c));
}

}  // namespace ring_auth
