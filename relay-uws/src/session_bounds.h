#pragma once
#include <algorithm>
#include <chrono>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "session.h"
#include "state.h"

// The seam between the session code in ws_handler.cpp and the relay's bounds: every ring
// mutation, every mint and every end goes through here, so the global buffer budget
// (OfflineIndex), the session table cap and the per-IP slots stay exact. The handshake
// and send sites call these; the bodies own the accounting.
//
// Nothing here touches offline_buffer or topic_buffers: ring_push runs inside handlers
// that loop over those buffers (a replay on join, a topic catch-up). When the budget's
// victim is one of their frames, the loop's settle point drops it (enforce_buffer_budget
// from main.cpp's post-iteration handler), or the next deposit does.
namespace session_bounds {

namespace detail {

// Whether `a` should go before `b` when a share must give up a session: one in grace
// before a live one, then the one closest to its end.
inline bool goes_first(const session::Session& a, const session::Session* b) {
    if (!b) return true;
    const bool ag = a.state == session::State::Grace;
    const bool bg = b->state == session::State::Grace;
    if (ag != bg) return ag;
    return ag && a.grace_until < b->grace_until;
}

// Lets the budget bury a ring frame it picked (OfflineIndex::released).
inline void attach(RelayState& st) {
    if (st.buffer_index.bury_session) return;
    st.buffer_index.bury_session = [&st](uint64_t seq, const std::string& peer) {
        auto it = st.sessions.find(peer);
        if (it != st.sessions.end()) it->second.ring.evict_budget_seq(seq);
    };
}

// Charge a frame `peer`'s ring is about to hold.
inline void charge(RelayState& st, const std::string& peer, session::Frame& f) {
    attach(st);
    f.budget_seq = st.buffer_index.stamp_session(peer, f.share, f.bytes.get(), f.size());
}

inline auto forget(RelayState& st) {
    return [&st](const session::Frame& f) { st.buffer_index.forget(f.budget_seq); };
}

// Over the budget, bury ring frames while the victim is one. A buffered frame victim
// waits for the settle point (see the namespace note).
inline void bury_over_budget(RelayState& st, size_t budget = MAX_BUFFER_TOTAL_BYTES) {
    while (st.buffer_index.bytes() > budget) {
        auto victim = st.buffer_index.victim();
        if (!victim || !victim->second.is_session) return;
        st.buffer_index.released(victim->first);
    }
}

}  // namespace detail

// Count `f` for `s`'s device before its socket write and keep it until acked. A frame
// larger than the ring cap is counted as a tombstone; past the per-session caps the
// heaviest sender share's oldest frame becomes one. Returns its number.
inline uint64_t ring_push(RelayState& st, session::Session& s, session::Frame f) {
    if (f.size() > session::RING_MAX_BYTES) return s.ring.push_gap();
    detail::charge(st, s.peer_id, f);
    const uint64_t seq = s.ring.push(std::move(f));
    s.ring.enforce(session::RING_MAX_BYTES, session::RING_MAX_FRAMES, detail::forget(st));
    detail::bury_over_budget(st);
    return seq;
}

// The device holds every frame up to `h`. False (and nothing changes) when `h` is out of
// range.
inline bool ring_ack(RelayState& st, session::Session& s, uint64_t h) {
    return s.ring.ack(h, detail::forget(st));
}

// The session ends (grace expiry, `end`, table eviction, a "new" over it): every real
// frame, oldest first, released from the budget. The caller hands the bufferable kinds
// to offline_buffer, which charges them again.
inline std::vector<session::Frame> ring_take_all(RelayState& st, session::Session& s) {
    std::vector<session::Frame> out = s.ring.take_all();
    for (auto& f : out) {
        st.buffer_index.forget(f.budget_seq);
        f.budget_seq = 0;
    }
    return out;
}

// Before a session is minted for an address `share`: the peer ids whose sessions must
// end first to keep the table within MAX_SESSIONS. The caller ends each one exactly as
// on grace expiry, then mints.
//
// The share holding the most sessions, the newcomer counted, gives one up: in grace
// before live, the one closest to its end first. Only a full table pays for the scan.
inline std::vector<std::string> make_room(RelayState& st, uint64_t share) {
    std::vector<std::string> out;
    if (st.sessions.size() < session::MAX_SESSIONS) return out;
    size_t need = st.sessions.size() + 1 - session::MAX_SESSIONS;
    while (need-- > 0) {
        struct Held {
            size_t count = 0;
            const std::string* peer = nullptr;
            const session::Session* best = nullptr;
        };
        std::unordered_map<uint64_t, Held> by_share;
        for (const auto& [peer, s] : st.sessions) {
            if (std::find(out.begin(), out.end(), peer) != out.end()) continue;
            Held& h = by_share[s.share];
            h.count++;
            if (detail::goes_first(s, h.best)) {
                h.best = &s;
                h.peer = &peer;
            }
        }
        by_share[share].count++;
        const Held* pick = nullptr;
        uint64_t pick_share = 0;
        for (const auto& [sh, h] : by_share) {
            if (!h.best) continue;
            bool better = !pick || h.count > pick->count;
            if (pick && h.count == pick->count) {
                if (sh == share || pick_share == share) {
                    better = sh == share;
                } else {
                    better = detail::goes_first(*h.best, pick->best);
                }
            }
            if (better) {
                pick = &h;
                pick_share = sh;
            }
        }
        if (!pick) break;
        out.push_back(*pick->peer);
    }
    return out;
}

// `s` is gone, or back on a socket that holds a slot of its own: free the held slot.
inline void release_ip_slot(RelayState& st, session::Session& s) {
    if (s.ip_key.empty()) return;
    auto it = st.ip_states.find(s.ip_key);
    if (it != st.ip_states.end()) {
        if (it->second.active_count > 0) it->second.active_count--;
        if (it->second.active_count == 0) st.ip_states.erase(it);
    }
    s.ip_key.clear();
}

// `s` enters grace: it keeps its closing socket's per-IP slot until it is gone. The
// close handler skips its own decrement for that socket. Call once per closing socket;
// a slot still held from before (a resume that never released it) is freed first.
inline void hold_ip_slot(RelayState& st, session::Session& s, const std::string& ip_key) {
    release_ip_slot(st, s);
    s.ip_key = ip_key;
}

// An address at MAX_CONNS_PER_IP whose slots include grace sessions: the one that gives
// its slot to a new socket (in grace, closest to its end), or none. The caller ends it
// as on expiry before admitting the socket, so a device coming back from a full address
// is not refused by the slot its own session holds.
inline std::optional<std::string> grace_slot_victim(const RelayState& st, const std::string& ip_key) {
    const std::string* pick = nullptr;
    const session::Session* best = nullptr;
    for (const auto& [peer, s] : st.sessions) {
        if (s.ip_key != ip_key || s.state != session::State::Grace) continue;
        if (detail::goes_first(s, best)) {
            best = &s;
            pick = &peer;
        }
    }
    if (!pick) return std::nullopt;
    return *pick;
}

}  // namespace session_bounds
