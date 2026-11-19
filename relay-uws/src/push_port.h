#pragma once
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <optional>

// Where the relay posts wakes: the push sidecar on 127.0.0.1. HOLLOW_PUSH_PORT moves it,
// so a test relay gets a port of its own and never posts to a real sidecar (or has a
// real wake land in a test's listener).
//
// Header-only so test/test_push_pref.cpp drives it without a relay.
namespace push_port {

inline constexpr uint16_t DEFAULT = 3001;

// The port `env` names: the default when unset or empty, nothing when it is not a whole
// number from 1 to 65535 (the relay then refuses to start rather than guess).
inline std::optional<uint16_t> parse(const char* env) {
    if (!env || !*env) return DEFAULT;
    if (!std::isdigit(static_cast<unsigned char>(env[0]))) return std::nullopt;
    char* end = nullptr;
    errno = 0;
    const long v = std::strtol(env, &end, 10);
    if (*end != '\0' || errno == ERANGE || v < 1 || v > 65535) return std::nullopt;
    return static_cast<uint16_t>(v);
}

}  // namespace push_port
