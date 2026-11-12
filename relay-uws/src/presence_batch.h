#pragma once
// One room's presence changes the relay has not yet told its batching viewers (sockets
// whose first join said `pv:2`), coalesced for up to WINDOW_MS. The log holds exactly
// the `peer_joined`/`peer_left` sequence a per-peer viewer gets, in order and never
// cancelled, so a viewer that reads a batch sees what single frames would have shown.
// RAM only, never persisted, never logged; nothing outlives a flush.
//
// Header-only so test/test_presence_batch.cpp drives it without a relay.
#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "json.hpp"

namespace presence_batch {

// Events per frame and per room log: a full log flushes at once.
inline constexpr size_t MAX_EVENTS = 256;
inline constexpr int64_t WINDOW_MS = 100;
// All logs together; past it every log flushes.
inline constexpr size_t TOTAL_BYTES = 32u << 20;
// What one logged event costs beyond its peer id.
inline constexpr size_t EVENT_OVERHEAD = 48;

// The `presence` frames for `room` carrying `events` ("+id" / "-id"), at most MAX_EVENTS each.
inline std::vector<std::string> frames(const std::string& room, const std::vector<std::string>& events) {
    std::vector<std::string> out;
    for (size_t at = 0; at < events.size(); at += MAX_EVENTS) {
        const size_t end = std::min(events.size(), at + MAX_EVENTS);
        nlohmann::json ev = nlohmann::json::array();
        for (size_t i = at; i < end; i++) ev.push_back(events[i]);
        out.push_back(nlohmann::json{{"type", "presence"}, {"room", room}, {"ev", std::move(ev)}}.dump());
    }
    return out;
}

class Log {
public:
    // Appends one event; returns the bytes it holds. `flush_now` says the caller flushes the
    // room before returning: the first event after a quiet window (an isolated join costs no
    // latency) or a full log.
    size_t append(bool joined, const std::string& peer, int64_t now_ms, bool& flush_now) {
        const bool leading = events_.empty() && now_ms - last_flush_ms_ >= WINDOW_MS;
        if (events_.empty()) first_at_ms_ = now_ms;
        events_.push_back(Event{joined, peer});
        subjects_.insert(peer);
        const size_t cost = peer.size() + EVENT_OVERHEAD;
        bytes_ += cost;
        flush_now = leading || events_.size() >= MAX_EVENTS;
        return cost;
    }

    bool empty() const { return events_.empty(); }
    size_t size() const { return events_.size(); }
    size_t bytes() const { return bytes_; }
    uint64_t seq() const { return base_ + events_.size(); }
    // When the window of the oldest pending event ends; only while not empty.
    int64_t due_ms() const { return first_at_ms_ + WINDOW_MS; }
    const std::unordered_set<std::string>& subjects() const { return subjects_; }
    bool about(const std::string& peer) const { return subjects_.count(peer) != 0; }

    // The events `viewer` was not sent yet, minus those about itself.
    std::vector<std::string> slice(const std::string& viewer) const {
        std::vector<std::string> out;
        auto a = ahead_.find(viewer);
        const size_t from = a == ahead_.end() ? 0 : static_cast<size_t>(a->second - base_);
        for (size_t i = from; i < events_.size(); i++) {
            if (events_[i].peer == viewer) continue;
            out.push_back((events_[i].joined ? "+" : "-") + events_[i].peer);
        }
        return out;
    }

    // Whether `viewer`'s slice is every event: it was sent nothing this window and no event
    // is about it, so it may share one rendering with every such viewer.
    bool plain_viewer(const std::string& viewer) const { return !ahead_.count(viewer) && !subjects_.count(viewer); }

    // `viewer` now knows everything logged so far: a `members` it was sent, or its slice.
    void stamp(const std::string& viewer) {
        if (!events_.empty()) ahead_[viewer] = seq();
    }

    // The room told every viewer: what stays is the sequence, so a later stamp stays exact.
    void clear(int64_t now_ms) {
        base_ = seq();
        events_.clear();
        ahead_.clear();
        subjects_.clear();
        bytes_ = 0;
        last_flush_ms_ = now_ms;
    }

private:
    struct Event {
        bool joined;
        std::string peer;
    };
    uint64_t base_ = 0;
    std::vector<Event> events_;
    // Viewers sent everything up to their sequence this window.
    std::unordered_map<std::string, uint64_t> ahead_;
    std::unordered_set<std::string> subjects_;
    size_t bytes_ = 0;
    int64_t first_at_ms_ = 0;
    int64_t last_flush_ms_ = INT64_MIN / 2;
};

}  // namespace presence_batch
