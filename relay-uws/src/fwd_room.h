#pragma once
#include <optional>
#include <string_view>

// A media forwarder's room `fwd:{X}`: X serves the sharers and viewers of every
// server that routes a stream through it, and anyone can join, so the room pairs each
// member with X alone. X sees and reaches everyone in it; the others only X.
//
// Header-only, so the rule is unit tested on its own (test/test_fwd_room.cpp).

namespace fwd_room {

inline constexpr std::string_view PREFIX = "fwd:";

// The forwarder a `fwd:` room names (empty names nobody), or nothing for any other room.
inline std::optional<std::string_view> forwarder_of(std::string_view room) {
    if (room.substr(0, PREFIX.size()) != PREFIX) return std::nullopt;
    return room.substr(PREFIX.size());
}

// Whether `a` and `b` may know of and reach each other in `room`.
inline bool paired(std::string_view room, std::string_view a, std::string_view b) {
    const auto x = forwarder_of(room);
    return !x || a == *x || b == *x;
}

}  // namespace fwd_room
