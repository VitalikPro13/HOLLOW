#pragma once
#include "json.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

// The client's auth frame, read without one throwing accessor. It is the only
// frame any socket on the internet may send before proving anything, and an
// exception unwinding into uSockets' C frames ends the whole process, taking
// every offline buffer, ring, kill signal and push token with it (no snapshot
// runs on an abnormal exit). A field of the wrong JSON type makes the frame
// invalid, never a crash. Header-only so test/test_auth_frame.cpp drives it.
struct AuthFrame {
    std::string peer_id;
    std::string public_key;
    uint64_t timestamp = 0;
    std::string signature;
    std::string license_key;
    bool guest = false;
    bool fetch = false;
};

// Two orders of magnitude above any real auth frame (a peer id, a key, a
// signature, a license key), so an unauthenticated socket cannot make the relay
// parse megabytes.
static constexpr size_t MAX_AUTH_FRAME_BYTES = 16 * 1024;

inline std::optional<AuthFrame> parse_auth_frame(std::string_view message) {
    if (message.size() > MAX_AUTH_FRAME_BYTES) return std::nullopt;
    const nlohmann::json j = nlohmann::json::parse(message, nullptr, /*allow_exceptions=*/false);
    if (!j.is_object()) return std::nullopt;

    auto type = j.find("type");
    if (type == j.end() || !type->is_string() || type->get_ref<const std::string&>() != "auth") {
        return std::nullopt;
    }

    AuthFrame f;
    auto text = [&j](const char* key, std::string& out) {
        auto it = j.find(key);
        if (it == j.end()) return true;
        if (!it->is_string()) return false;
        out = it->get_ref<const std::string&>();
        return true;
    };
    auto flag = [&j](const char* key, bool& out) {
        auto it = j.find(key);
        if (it == j.end()) return true;
        if (!it->is_boolean()) return false;
        out = it->get<bool>();
        return true;
    };
    if (!text("peer_id", f.peer_id) || !text("public_key", f.public_key) ||
        !text("signature", f.signature) || !text("license_key", f.license_key) ||
        !flag("guest", f.guest) || !flag("fetch", f.fetch)) {
        return std::nullopt;
    }

    auto ts = j.find("timestamp");
    if (ts != j.end()) {
        if (ts->is_number_unsigned()) {
            f.timestamp = ts->get<uint64_t>();
        } else {
            return std::nullopt;
        }
    }
    return f;
}
