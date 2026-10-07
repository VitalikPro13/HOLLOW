#pragma once
#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "session.h"
#include "session_bounds.h"
#include "snapshot_codec.h"
#include "state.h"
#include "validate.h"

// Resumable sessions across a relay restart (snapshot VERSION 9, section 9.7): every
// session comes back in grace, its timer starting at load, with its rings, rooms,
// subscriptions and the nickname and link code its device held. Door standing, the
// door nonce and the per-IP slot stay behind: the door key and the addresses belong to
// one process. Header-only so test/test_session_bounds.cpp drives it.
namespace session_snapshot {

namespace detail {

inline bool room_shape(std::string_view room) {
    if (room.empty() || room.size() > 128) return false;
    for (char c : room) {
        const auto u = static_cast<unsigned char>(c);
        if (!std::isalnum(u) && c != ':' && c != '-' && c != '_' && c != '.') return false;
    }
    return true;
}

inline bool nickname_shape(std::string_view nick) {
    if (nick.size() < 3 || nick.size() > 20) return false;
    for (char c : nick) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    }
    return true;
}

inline bool link_code_shape(std::string_view code) {
    if (code.size() != 6) return false;
    for (char c : code) {
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return false;
    }
    return true;
}

// A signed claim's key and signature are base64 of 36 and 64 bytes.
static constexpr size_t MAX_PROOF_FIELD = 256;

}  // namespace detail

// Every session, each fan-out buffer once however many rings share it.
inline void capture(const RelayState& st, snapshot::Data& d) {
    std::unordered_map<const std::string*, uint32_t> index;
    for (const auto& [peer, s] : st.sessions) {
        snapshot::SessionRec r;
        r.sid = s.sid;
        r.peer_id = peer;
        r.share = s.share;
        r.inactive = s.inactive;
        r.in_h = s.in_h;
        for (const auto& [room, owner] : s.rooms) r.rooms.push_back({room, owner});
        for (const auto& [room, topics] : s.subscriptions) {
            r.subscriptions.push_back({room, std::vector<std::string>(topics.begin(), topics.end())});
        }
        auto nick = st.peer_to_nickname.find(peer);
        if (nick != st.peer_to_nickname.end()) {
            auto holder = st.nickname_to_peer.find(nick->second);
            auto expiry = st.nickname_expiry.find(nick->second);
            if (holder != st.nickname_to_peer.end() && holder->second == peer && expiry != st.nickname_expiry.end()) {
                r.has_nickname = true;
                r.nickname.nickname = nick->second;
                r.nickname.expiry_unix = expiry->second;
                auto master = st.nickname_to_master.find(nick->second);
                if (master != st.nickname_to_master.end()) r.nickname.master = master->second;
                auto proof = st.nickname_proof.find(nick->second);
                if (proof != st.nickname_proof.end()) {
                    r.nickname.has_proof = true;
                    r.nickname.master_key = proof->second.master_key;
                    r.nickname.ts_ms = proof->second.ts_ms;
                    r.nickname.sig = proof->second.sig;
                }
            }
        }
        auto code = st.peer_to_linkcode.find(peer);
        if (code != st.peer_to_linkcode.end()) {
            auto holder = st.linkcode_to_peer.find(code->second);
            auto expiry = st.linkcode_expiry.find(code->second);
            if (holder != st.linkcode_to_peer.end() && holder->second == peer && expiry != st.linkcode_expiry.end()) {
                r.has_link_code = true;
                r.link_code = {code->second, expiry->second};
            }
        }
        r.sent = s.ring.sent();
        r.acked = s.ring.acked();
        for (const auto& f : s.ring.entries()) {
            snapshot::SessionFrame sf;
            sf.seq = f.seq;
            sf.gap = f.gap;
            if (!f.tombstone()) {
                auto [it, fresh] = index.try_emplace(f.bytes.get(), static_cast<uint32_t>(d.buffers.size()));
                if (fresh) d.buffers.push_back(*f.bytes);
                sf.buffer = it->second;
                sf.binary = f.binary;
                sf.share = f.share;
                sf.kind = static_cast<uint8_t>(f.kind);
                sf.room = f.room;
                sf.budget_seq = f.budget_seq;
            }
            r.frames.push_back(std::move(sf));
        }
        d.sessions.push_back(std::move(r));
    }
}

// A session read back and judged sound, its frames waiting for their stamps. Until
// stamped, a frame's budget_seq is the stamp it had before the restart.
struct Pending {
    session::Session s;
    uint64_t sent = 0;
    uint64_t acked = 0;
    std::deque<session::Frame> entries;
    std::optional<snapshot::SessionNickname> nickname;
    std::optional<snapshot::SessionLinkCode> link_code;
};

// One record as a session this relay could have held, or nothing.
inline std::optional<Pending> judge(snapshot::SessionRec&& r, std::vector<std::shared_ptr<const std::string>>& shared,
                                    std::vector<std::string>& buffers) {
    if (!session::is_sid_shape(r.sid) || !is_peer_id_shape(r.peer_id)) return std::nullopt;
    Pending p;
    session::Session& s = p.s;
    s.sid = std::move(r.sid);
    s.peer_id = std::move(r.peer_id);
    s.share = r.share;
    s.inactive = r.inactive;
    s.in_h = r.in_h;
    for (auto& [room, owner] : r.rooms) {
        if (!detail::room_shape(room) || !s.rooms.emplace(std::move(room), owner).second) return std::nullopt;
    }
    if (r.subscriptions.size() > MAX_SUBSCRIPTION_ROOMS) return std::nullopt;
    size_t topics = 0;
    for (auto& [room, list] : r.subscriptions) {
        topics += list.size();
        if (!detail::room_shape(room) || topics > MAX_SUBSCRIPTION_TOPICS) return std::nullopt;
        std::unordered_set<std::string> set;
        for (auto& t : list) {
            if (t.empty() || t.size() > 128 || !set.insert(std::move(t)).second) return std::nullopt;
        }
        if (!s.subscriptions.emplace(std::move(room), std::move(set)).second) return std::nullopt;
    }
    if (r.has_nickname) {
        const auto& n = r.nickname;
        if (!detail::nickname_shape(n.nickname) || (!n.master.empty() && !is_peer_id_shape(n.master)) ||
            n.master_key.size() > detail::MAX_PROOF_FIELD || n.sig.size() > detail::MAX_PROOF_FIELD) {
            return std::nullopt;
        }
        p.nickname = std::move(r.nickname);
    }
    if (r.has_link_code) {
        if (!detail::link_code_shape(r.link_code.code)) return std::nullopt;
        p.link_code = std::move(r.link_code);
    }
    for (auto& rf : r.frames) {
        session::Frame f;
        f.seq = rf.seq;
        f.gap = rf.gap;
        if (rf.gap == 0) {
            if (rf.buffer >= buffers.size() || rf.kind > static_cast<uint8_t>(session::Kind::ChannelCopy) ||
                (!rf.room.empty() && !detail::room_shape(rf.room))) {
                return std::nullopt;
            }
            const size_t size = shared[rf.buffer] ? shared[rf.buffer]->size() : buffers[rf.buffer].size();
            if (size > session::RING_MAX_BYTES) return std::nullopt;
            if (!shared[rf.buffer]) shared[rf.buffer] = std::make_shared<const std::string>(std::move(buffers[rf.buffer]));
            f.bytes = shared[rf.buffer];
            f.binary = rf.binary;
            f.share = rf.share;
            f.kind = static_cast<session::Kind>(rf.kind);
            f.room = std::move(rf.room);
            f.budget_seq = rf.budget_seq;
        }
        p.entries.push_back(std::move(f));
    }
    if (!session::Ring::restore(r.sent, r.acked, p.entries)) return std::nullopt;
    p.sent = r.sent;
    p.acked = r.acked;
    return p;
}

// Every record of `d` judged sound, in grace from `now`; `dropped` counts the rest,
// the codec's included. Past `max_sessions` the share holding the most gives way. Takes
// `d`'s sessions and buffers and leaves the rest of it alone.
inline std::vector<Pending> prepare(snapshot::Data& d, std::chrono::steady_clock::time_point now, int64_t grace_secs,
                                    size_t& dropped, size_t max_sessions = session::MAX_SESSIONS) {
    dropped = d.sessions_dropped;
    std::vector<std::shared_ptr<const std::string>> shared(d.buffers.size());
    std::vector<Pending> out;
    std::unordered_set<std::string> seen;
    for (auto& r : d.sessions) {
        auto p = judge(std::move(r), shared, d.buffers);
        if (!p || !seen.insert(p->s.peer_id).second) {
            dropped++;
            continue;
        }
        p->s.state = session::State::Grace;
        p->s.grace_until = now + std::chrono::seconds(grace_secs);
        p->s.restored = true;
        out.push_back(std::move(*p));
    }
    while (out.size() > max_sessions) {
        std::unordered_map<uint64_t, size_t> count;
        for (const auto& p : out) count[p.s.share]++;
        uint64_t heaviest = 0;
        size_t most = 0;
        for (const auto& [share, n] : count) {
            if (n > most) {
                most = n;
                heaviest = share;
            }
        }
        for (size_t i = out.size(); i-- > 0;) {
            if (out[i].s.share != heaviest) continue;
            out.erase(out.begin() + static_cast<std::ptrdiff_t>(i));
            dropped++;
            break;
        }
    }
    return out;
}

// Charge every real frame of `pending` to the rings' pool, in the order the old process
// charged them, so the pool's eviction order survives the restart.
inline void stamp(RelayState& st, std::vector<Pending>& pending) {
    std::vector<std::pair<uint64_t, std::pair<const session::Session*, session::Frame*>>> order;
    for (auto& p : pending) {
        for (auto& f : p.entries) {
            if (!f.tombstone()) order.push_back({f.budget_seq, {&p.s, &f}});
        }
    }
    std::sort(order.begin(), order.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });
    for (auto& [old, at] : order) session_bounds::detail::charge(st, *at.first, *at.second);
}

// Put the stamped sessions in place, then hold the rings' pool to this build's budget. A
// nickname or link code comes back while it has not expired at `now_unix` and nobody else
// holds it.
inline void place(RelayState& st, std::vector<Pending>&& pending, uint64_t now_unix) {
    session_bounds::detail::attach(st);
    for (auto& p : pending) {
        const std::string peer = p.s.peer_id;
        auto ring = session::Ring::restore(p.sent, p.acked, std::move(p.entries));
        if (!ring || st.sessions.count(peer)) {
            if (ring) {
                for (const auto& f : ring->entries()) st.buffer_index.forget(f.budget_seq);
            }
            continue;
        }
        p.s.ring = std::move(*ring);
        p.s.ring.enforce(session::RING_MAX_BYTES, session::RING_MAX_FRAMES, session_bounds::detail::forget(st));
        st.session_book.add(peer, p.s.share);
        st.session_book.to_grace(peer, std::string());
        st.sessions.emplace(peer, std::move(p.s));
        if (p.nickname && now_unix <= p.nickname->expiry_unix && !st.nickname_to_peer.count(p.nickname->nickname) &&
            !st.peer_to_nickname.count(peer)) {
            const auto& n = *p.nickname;
            st.nickname_to_peer[n.nickname] = peer;
            st.peer_to_nickname[peer] = n.nickname;
            st.nickname_expiry[n.nickname] = n.expiry_unix;
            if (!n.master.empty()) st.nickname_to_master[n.nickname] = n.master;
            if (n.has_proof) st.nickname_proof[n.nickname] = {n.master_key, n.ts_ms, n.sig};
        }
        if (p.link_code && now_unix <= p.link_code->expiry_unix && !st.linkcode_to_peer.count(p.link_code->code) &&
            !st.peer_to_linkcode.count(peer)) {
            st.linkcode_to_peer[p.link_code->code] = peer;
            st.peer_to_linkcode[peer] = p.link_code->code;
            st.linkcode_expiry[p.link_code->code] = p.link_code->expiry_unix;
        }
    }
    session_bounds::detail::bury_over_pool(st);
}

// The whole restore on its own. snapshot.cpp interleaves the stamps with the buffers'.
// Returns how many records were dropped.
inline size_t restore(RelayState& st, snapshot::Data&& d, std::chrono::steady_clock::time_point now,
                      int64_t grace_secs, uint64_t now_unix, size_t max_sessions = session::MAX_SESSIONS) {
    size_t dropped = 0;
    auto pending = prepare(d, now, grace_secs, dropped, max_sessions);
    stamp(st, pending);
    place(st, std::move(pending), now_unix);
    return dropped;
}

}  // namespace session_snapshot
