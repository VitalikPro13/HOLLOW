#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

#include "session.h"
#include "state.h"

// Before a restart the relay tells every device holding a live session to come back
// after a spread wait (section 9.7), so a deploy is a staggered resume and not a
// reconnect storm. Header-only so test/test_session_bounds.cpp drives the order.
namespace drain {

// Uncounted (session::relay_type_counts), so it never enters a ring.
inline std::string hint(int64_t after_ms) {
    return "{\"type\":\"reconnect\",\"after_ms\":" + std::to_string(after_ms) + "}";
}

// A wait uniform in [DRAIN_MIN_MS, DRAIN_MAX_MS]; `draw(n)` is uniform in [0, n).
template <typename Draw>
int64_t pick(Draw&& draw) {
    const auto span = static_cast<uint32_t>(session::DRAIN_MAX_MS - session::DRAIN_MIN_MS + 1);
    return session::DRAIN_MIN_MS + static_cast<int64_t>(draw(span));
}

// Every live session's socket gets its own wait; `socket_of(peer, session)` names the
// socket carrying that session, or null. Returns how many were told.
template <typename SocketOf, typename Send, typename Draw>
size_t hint_sessions(const RelayState& st, SocketOf&& socket_of, Send&& send, Draw&& draw) {
    size_t told = 0;
    for (const auto& [peer, s] : st.sessions) {
        if (s.state != session::State::Live) continue;
        SSLWebSocket* ws = socket_of(peer, s);
        if (!ws) continue;
        send(ws, hint(pick(draw)));
        told++;
    }
    return told;
}

// The SIGTERM tick: the hints, then the snapshot, then the close, in one call on the
// loop thread, so the snapshot holds every frame counted so far and nothing counted
// is written after it.
template <typename SocketOf, typename Send, typename Draw, typename Snapshot, typename Close>
void shutdown(const RelayState& st, SocketOf&& socket_of, Send&& send, Draw&& draw, Snapshot&& snapshot,
              Close&& close) {
    hint_sessions(st, socket_of, send, draw);
    snapshot();
    close();
}

}  // namespace drain
