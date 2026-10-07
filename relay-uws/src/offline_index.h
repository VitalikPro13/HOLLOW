#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "fair_share.h"

// Every buffered frame, DM and topic alike, charged to the address share of the socket
// that sent it (fair_share.h). Past the byte budget the share holding the most loses its
// oldest frame, so a flood from throwaway accounts fills and then churns only its own
// part of the budget and never pushes out what real people left for someone offline.
// Header-only so test/test_relay_validators.cpp drives it without a relay.
//
// Session rings (session.h) keep a pool of their own beside it: how long a ring holds a
// frame is up to its device, so ring traffic never pushes out a waiting DM or topic frame,
// and those never push out a ring's. In the pool a frame's bytes are charged to its
// sender's share and its holding to the receiving session's share, so a flood pays for
// its bytes and a receiver that never acks pays for keeping them.
//
// Exact, not lazy: every path that removes a frame calls released(seq) (the
// enumeration lives in ws_handler.cpp) or, for a ring frame its ring let go,
// forget(seq) (session_bounds.h), so bytes() and ring_bytes() are the live totals.
struct OfflineIndex {
    // What holding one frame costs beyond its bytes: the queue entry and its
    // strings, a DM target's own queue, this index. Counting it bounds a flood of
    // tiny frames, which would otherwise weigh next to nothing.
    static constexpr size_t FRAME_OVERHEAD_BYTES = 1024;
    // The rings' pool, beside the buffers' budget (MAX_BUFFER_TOTAL_BYTES).
    static constexpr size_t RING_BUDGET_BYTES = 256ull * 1024 * 1024;

    struct Loc {
        std::string key;  // an offline_buffer target, a topic_buffers key, or a session's peer id
        bool is_topic = false;
        bool is_session = false;
    };

    uint64_t next_seq = 0;
    FairShare<uint64_t> frames;
    // Ring frames: the holding under each frame's seq, the bytes under a key of their own
    // (bytes_key) that names the buffer, which may be shared by the rings of one fan-out.
    FairShare<uint64_t> rings;
    size_t ring_budget = RING_BUDGET_BYTES;
    std::unordered_map<uint64_t, Loc> where;

    // Set by session_bounds.h, which owns the rings: turns a ring frame the budget
    // dropped into a tombstone in its ring, so its counters stay whole.
    std::function<void(uint64_t seq, const std::string& peer)> bury_session;

    static constexpr uint64_t BYTES_KEY = 1ull << 63;
    static bool is_bytes_key(uint64_t key) { return (key & BYTES_KEY) != 0; }

    uint64_t stamp(const std::string& key, bool is_topic, uint64_t share, size_t bytes) {
        uint64_t seq = ++next_seq;
        frames.put(seq, share, bytes + FRAME_OVERHEAD_BYTES);
        where.emplace(seq, Loc{key, is_topic, false});
        return seq;
    }

    // A frame in `peer`'s session ring, which belongs to the address share `holder`, sent
    // from the share `sender`. The rings of one fan-out share its buffer, which is RAM
    // once, so its bytes are charged once while any of them holds it.
    uint64_t stamp_session(const std::string& peer, uint64_t holder, uint64_t sender, const void* buffer,
                           size_t bytes) {
        uint64_t seq = ++next_seq;
        where.emplace(seq, Loc{peer, false, true});
        rings.put(seq, holder, FRAME_OVERHEAD_BYTES);
        ring_frames_++;
        if (!buffer) {
            if (bytes) rings.put(BYTES_KEY | seq, sender, bytes);
            return seq;
        }
        auto [it, fresh] = shared_.try_emplace(buffer);
        Shared& sh = it->second;
        if (fresh) {
            sh.id = seq;
            if (bytes) rings.put(BYTES_KEY | seq, sender, bytes);
            buffer_of_id_.emplace(seq, buffer);
        }
        sh.holders.insert(seq);
        buffer_of_.emplace(seq, buffer);
        return seq;
    }

    // The frame `seq` left its buffer, or the budget chose it. A ring frame cannot
    // leave by this path while its ring holds it, so it is buried there.
    void released(uint64_t seq) {
        auto it = where.find(seq);
        if (it != where.end() && it->second.is_session) {
            const std::string peer = std::move(it->second.key);
            forget(seq);
            if (bury_session) bury_session(seq, peer);
            return;
        }
        frames.remove(seq);
        if (it != where.end()) where.erase(it);
    }

    // A ring let its frame `seq` go: an ack, its own caps, the pool, the session's end.
    void forget(uint64_t seq) {
        auto w = where.find(seq);
        if (w == where.end() || !w->second.is_session) return;
        where.erase(w);
        ring_frames_--;
        rings.remove(seq);
        auto b = buffer_of_.find(seq);
        if (b == buffer_of_.end()) {
            rings.remove(BYTES_KEY | seq);
            return;
        }
        auto s = shared_.find(b->second);
        Shared& sh = s->second;
        sh.holders.erase(seq);
        if (sh.holders.empty()) {
            rings.remove(BYTES_KEY | sh.id);
            buffer_of_id_.erase(sh.id);
            shared_.erase(s);
        }
        buffer_of_.erase(b);
    }

    // The ring frames a pool key stands for: the one frame its holding names, or every
    // frame that holds the buffer its bytes name.
    std::vector<uint64_t> frames_of(uint64_t key) const {
        if (!is_bytes_key(key)) return {key};
        const uint64_t id = key & ~BYTES_KEY;
        auto b = buffer_of_id_.find(id);
        if (b == buffer_of_id_.end()) return {id};
        const Shared& sh = shared_.at(b->second);
        return std::vector<uint64_t>(sh.holders.begin(), sh.holders.end());
    }

    size_t live() const { return frames.size(); }
    size_t bytes() const { return frames.total(); }
    size_t ring_live() const { return ring_frames_; }
    size_t ring_bytes() const { return rings.total(); }
    // The distinct buffers ring frames hold, each charged once.
    size_t shared_buffers() const { return shared_.size(); }

    // The frame the budget drops next: the oldest of the share holding the most.
    std::optional<std::pair<uint64_t, Loc>> victim() const {
        auto seq = frames.victim();
        if (!seq) return std::nullopt;
        return std::make_pair(*seq, where.at(*seq));
    }

private:
    struct Shared {
        uint64_t id = 0;  // the seq of its first holder, which names its bytes key
        std::unordered_set<uint64_t> holders;
    };
    std::unordered_map<const void*, Shared> shared_;
    std::unordered_map<uint64_t, const void*> buffer_of_;
    std::unordered_map<uint64_t, const void*> buffer_of_id_;
    size_t ring_frames_ = 0;
};
