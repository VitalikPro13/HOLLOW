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
// mutation, every mint and every end goes through here, so the rings' pool (OfflineIndex),
// the session table cap and the per-IP slots stay exact. The handshake and send sites call
// these; the bodies own the accounting.
//
// Nothing here touches offline_buffer or topic_buffers: ring_push runs inside handlers
// that loop over those buffers (a replay on join, a topic catch-up), and the rings' pool
// is apart from their budget, so a ring push never has to drop one of their frames.
namespace session_bounds {

namespace detail {

// Lets the budget bury a ring frame it picked (OfflineIndex::released).
inline void attach(RelayState& st) {
    if (st.buffer_index.bury_session) return;
    st.buffer_index.bury_session = [&st](uint64_t seq, const std::string& peer) {
        auto it = st.sessions.find(peer);
        if (it != st.sessions.end()) it->second.ring.evict_budget_seq(seq);
    };
}

// Charge a frame `s`'s ring is about to hold: its bytes to its sender's share, its
// holding to the share that minted `s`.
inline void charge(RelayState& st, const session::Session& s, session::Frame& f) {
    attach(st);
    f.budget_seq = st.buffer_index.stamp_session(s.peer_id, s.share, f.share, f.bytes.get(), f.size());
}

inline auto forget(RelayState& st) {
    return [&st](const session::Frame& f) { st.buffer_index.forget(f.budget_seq); };
}

// Over the rings' pool, the share holding the most gives way. Where it holds frames, its
// ring loses the oldest frame of the heaviest sender there, so a flood into a ring buries
// the flood and not what others sent; where it sent the bytes, that buffer goes from every
// ring holding it.
inline void bury_over_pool(RelayState& st) {
    auto& ix = st.buffer_index;
    while (ix.ring_bytes() > ix.ring_budget) {
        auto key = ix.rings.victim();
        if (!key) return;
        const size_t before = ix.ring_bytes();
        if (OfflineIndex::is_bytes_key(*key)) {
            for (uint64_t seq : ix.frames_of(*key)) ix.released(seq);
        } else {
            auto w = ix.where.find(*key);
            auto it = w == ix.where.end() ? st.sessions.end() : st.sessions.find(w->second.key);
            if (it == st.sessions.end() || !it->second.ring.evict_one(forget(st))) ix.released(*key);
        }
        // An entry no ring answers for would keep this loop from ever ending.
        if (ix.ring_bytes() == before) ix.rings.remove(*key);
    }
}

}  // namespace detail

// Count `f` for `s`'s device before its socket write and keep it until acked. A frame
// larger than the ring cap is counted as a tombstone; past the per-session caps the
// heaviest sender share's oldest frame becomes one. Returns its number.
inline uint64_t ring_push(RelayState& st, session::Session& s, session::Frame f) {
    if (f.size() > session::RING_MAX_BYTES) return s.ring.push_gap();
    detail::charge(st, s, f);
    const uint64_t seq = s.ring.push(std::move(f));
    s.ring.enforce(session::RING_MAX_BYTES, session::RING_MAX_FRAMES, detail::forget(st));
    detail::bury_over_pool(st);
    return seq;
}

// The device holds every frame up to `h`. False (and nothing changes) when `h` is out of
// range.
inline bool ring_ack(RelayState& st, session::Session& s, uint64_t h) {
    return s.ring.ack(h, detail::forget(st));
}

// The session ends (grace expiry, `end`, table eviction, a "new" over it): every real
// frame, oldest first, released from the pool. The caller hands the bufferable kinds
// to offline_buffer, which charges them again.
inline std::vector<session::Frame> ring_take_all(RelayState& st, session::Session& s) {
    st.session_book.drop(s.peer_id);
    std::vector<session::Frame> out = s.ring.take_all();
    for (auto& f : out) {
        st.buffer_index.forget(f.budget_seq);
        f.budget_seq = 0;
    }
    return out;
}

namespace detail {

// The book, rebuilt from the table if they disagree: every path that adds or ends a
// session keeps it in step, and a path that forgot would otherwise hide sessions from
// the caps. A rebuild walks the table once.
inline session::Book& book(RelayState& st) {
    if (st.session_book.size() == st.sessions.size()) return st.session_book;
    st.session_book = session::Book();
    std::vector<std::pair<std::chrono::steady_clock::time_point, const session::Session*>> grace;
    for (const auto& [peer, s] : st.sessions) {
        st.session_book.add(peer, s.share);
        if (s.state == session::State::Grace) grace.push_back({s.grace_until, &s});
    }
    std::sort(grace.begin(), grace.end(), [](const auto& a, const auto& b) {
        return a.first != b.first ? a.first < b.first : a.second->peer_id < b.second->peer_id;
    });
    for (const auto& [until, s] : grace) st.session_book.to_grace(s->peer_id, s->ip_key);
    return st.session_book;
}

}  // namespace detail

// Before a session is minted for `peer` from an address `share`: the peer ids whose
// sessions must end first to keep the table within MAX_SESSIONS. The caller ends each one
// exactly as on grace expiry, then mints; the book counts `peer` from here on.
//
// The share holding the most sessions, the newcomer counted, gives one up: in grace
// before live, the one closest to its end first; a tie goes against the newcomer's share.
inline std::vector<std::string> make_room(RelayState& st, uint64_t share, const std::string& peer,
                                          size_t max_sessions = session::MAX_SESSIONS) {
    session::Book& book = detail::book(st);
    book.drop(peer);
    std::vector<std::string> out;
    size_t held = st.sessions.size() - (st.sessions.count(peer) ? 1 : 0);
    while (held + 1 > max_sessions) {
        auto victim = book.table_victim(share);
        if (!victim) break;
        book.drop(*victim);
        out.push_back(*victim);
        held--;
    }
    book.add(peer, share);
    return out;
}

// `s` is gone, or back on a socket that holds a slot of its own: free the held slot.
inline void release_ip_slot(RelayState& st, session::Session& s) {
    st.session_book.to_live(s.peer_id);
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
    st.session_book.to_grace(s.peer_id, ip_key);
}

// The grace slots the address `ip_key` holds.
inline size_t grace_slots(RelayState& st, const std::string& ip_key) {
    return detail::book(st).grace_slots(ip_key);
}

// The grace session at the address `ip_key` that gives its slot up for a newcomer there:
// the one closest to its end, or none.
inline std::optional<std::string> grace_slot_victim(RelayState& st, const std::string& ip_key) {
    return detail::book(st).grace_slot_victim(ip_key);
}

// Whether a new socket from `ip_key` may come in: under the cap, or over it by fewer
// sockets than the address has grace slots for the logins to settle (settle_victim).
inline bool admits(RelayState& st, const std::string& ip_key, size_t cap = MAX_CONNS_PER_IP) {
    auto it = st.ip_states.find(ip_key);
    const size_t count = it == st.ip_states.end() ? 0 : it->second.active_count;
    return count < cap || count < cap + grace_slots(st, ip_key);
}

// A login from `ip_key` is through, its own session resumed or ended: while the address
// is still over the cap, the grace session there closest to its end gives its slot up.
// Only now, once the device is known, so a device coming back takes back its own slot
// instead of costing another device its session.
inline std::optional<std::string> settle_victim(RelayState& st, const std::string& ip_key,
                                                size_t cap = MAX_CONNS_PER_IP) {
    auto it = st.ip_states.find(ip_key);
    if (it == st.ip_states.end() || it->second.active_count <= cap) return std::nullopt;
    return grace_slot_victim(st, ip_key);
}

}  // namespace session_bounds
