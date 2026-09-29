#pragma once
#include "json.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

// The client's pre-auth frames, read without one throwing accessor. They are the
// only frames any socket on the internet may send before proving anything, and an
// exception unwinding into uSockets' C frames ends the whole process, taking every
// offline buffer, ring, kill signal and push token with it (no snapshot runs on an
// abnormal exit). A field of the wrong JSON type makes the frame invalid, never a
// crash. Header-only so test/test_auth_frame.cpp drives it.
//
// Auth v2 (0.12): the client asks for a challenge (`auth_hello`), the relay answers
// with a fresh nonce (`auth_challenge`), and the client signs the nonce, the relay's
// domain and every flag the relay acts on. A v1 frame signs only the peer id and a
// timestamp, so one captured frame replays to any relay within a minute, and its
// `fetch`, `guest` and license key ride unsigned.
struct AuthFrame {
    // 1 = the pre-0.12 frame (no `v`), 2 = the challenge frame.
    int version = 1;
    std::string peer_id;
    std::string public_key;
    uint64_t timestamp = 0;
    std::string signature;
    std::string license_key;
    bool guest = false;
    bool fetch = false;
    // v2 only.
    std::string nonce;
    std::string domain;
};

// Two orders of magnitude above any real auth frame (a peer id, a key, a
// signature, a license key), so an unauthenticated socket cannot make the relay
// parse megabytes.
static constexpr size_t MAX_AUTH_FRAME_BYTES = 16 * 1024;

// 32 random bytes as lowercase hex.
static constexpr size_t AUTH_NONCE_HEX_LEN = 64;

namespace auth_detail {

inline bool frame_of_type(const nlohmann::json& j, const char* want) {
    if (!j.is_object()) return false;
    auto type = j.find("type");
    return type != j.end() && type->is_string() && type->get_ref<const std::string&>() == want;
}

inline nlohmann::json parse_small(std::string_view message) {
    if (message.size() > MAX_AUTH_FRAME_BYTES) return nlohmann::json();
    return nlohmann::json::parse(message, nullptr, /*allow_exceptions=*/false);
}

}  // namespace auth_detail

// `{"type":"auth_hello"}`: the client wants a challenge before it signs.
inline bool is_auth_hello(std::string_view message) {
    return auth_detail::frame_of_type(auth_detail::parse_small(message), "auth_hello");
}

inline std::optional<AuthFrame> parse_auth_frame(std::string_view message) {
    const nlohmann::json j = auth_detail::parse_small(message);
    if (!auth_detail::frame_of_type(j, "auth")) return std::nullopt;

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
        !flag("guest", f.guest) || !flag("fetch", f.fetch) ||
        !text("nonce", f.nonce) || !text("domain", f.domain)) {
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

    auto v = j.find("v");
    if (v != j.end()) {
        if (!v->is_number_unsigned() || v->get<uint64_t>() != 2) return std::nullopt;
        f.version = 2;
    }
    return f;
}

// What the socket will be, as the v2 signature names it. A frame claiming both a
// guest and a fetch socket is no mode at all.
inline std::optional<std::string> auth_mode(bool guest, bool fetch) {
    if (guest && fetch) return std::nullopt;
    if (guest) return std::string("guest");
    if (fetch) return std::string("fetch");
    return std::string("full");
}

// The relay's host as a v2 signature names it: lowercase, no port. `--domain` may
// carry the WSS port; the client signs the host of the URL it dialled.
inline std::string auth_domain(std::string_view configured) {
    std::string host(configured);
    if (!host.empty() && host.front() == '[') {
        size_t close = host.find(']');
        if (close != std::string::npos) host = host.substr(0, close + 1);
    } else {
        size_t colon = host.find(':');
        if (colon != std::string::npos && host.find(':', colon + 1) == std::string::npos) {
            host = host.substr(0, colon);
        }
    }
    for (char& c : host) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return host;
}

// The exact bytes a v2 auth signature covers. `license_digest` is the lowercase hex
// SHA-256 of the license key, or empty when the frame carries none. Pinned in both
// languages (test_auth_frame.cpp, ws_client.rs).
inline std::string auth_v2_message(const std::string& domain, const std::string& nonce,
                                   const std::string& peer_id, uint64_t timestamp,
                                   const std::string& mode, const std::string& license_digest) {
    return "hollow-ws-auth2\n" + domain + "\n" + nonce + "\n" + peer_id + "\n" +
           std::to_string(timestamp) + "\n" + mode + "\n" + license_digest;
}

inline bool is_auth_nonce_shape(const std::string& nonce) {
    if (nonce.size() != AUTH_NONCE_HEX_LEN) return false;
    for (char c : nonce) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}
