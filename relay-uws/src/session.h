#pragma once
#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// Resumable sessions (RESUMABLE_SESSIONS_PLAN.md section 9): a device's session outlives
// its socket, both sides count the stream frames they handled, and the relay keeps every
// frame it sent until the device acks it, so a frame written into a dead socket is
// resent on resume instead of lost. This is the part both relay agents build on: the
// counted-frame classification, the auth v3 session field and the per-session ring.
// Header-only and free of uWebSockets, so test/test_session.cpp drives it.

namespace session {

static constexpr int64_t DEFAULT_GRACE_SECS = 120;
static constexpr int64_t MIN_GRACE_SECS = 30;
static constexpr int64_t MAX_GRACE_SECS = 600;
// Advertised in auth_ok/resumed; the client beats this often in the foreground.
static constexpr int HB_SECS = 15;
static constexpr size_t RING_MAX_BYTES = 8 * 1024 * 1024;
static constexpr size_t RING_MAX_FRAMES = 4096;
static constexpr size_t MAX_SESSIONS = 262144;
static constexpr size_t SID_HEX_LEN = 32;
static constexpr int64_t DRAIN_MIN_MS = 2000;
static constexpr int64_t DRAIN_MAX_MS = 10000;
// What keeping one frame costs beyond its bytes, as OfflineIndex weighs it: without it a
// flood of tiny frames would weigh next to nothing against real ones.
static constexpr size_t FRAME_WEIGHT_OVERHEAD = 1024;

// The relay acks what it received after this many stream frames, or this long after
// the first one it has not acked yet (section 9.4).
static constexpr uint32_t ACK_EVERY_FRAMES = 16;
static constexpr int64_t ACK_AFTER_MS = 2000;

// Whether two sids match, in a time that does not depend on where they first differ:
// a resume must not tell a guesser how much of a sid it got right.
inline bool sid_equal(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    volatile unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); i++) diff = diff | static_cast<unsigned char>(a[i] ^ b[i]);
    return diff == 0;
}

inline bool is_sid_shape(std::string_view s) {
    if (s.size() != SID_HEX_LEN) return false;
    for (char c : s) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

// The auth v3 `session` field for a socket of `mode`: only a full socket has a session.
inline bool auth_session_ok(std::string_view mode, std::string_view session) {
    if (mode == "full") return session == "new" || is_sid_shape(session);
    return (mode == "fetch" || mode == "guest") && session == "none";
}

// Whether a relay-to-client JSON frame of `type` is a stream frame. Presence and kill
// signals are state, re-read on resume, never replayed.
inline bool relay_type_counts(std::string_view type) {
    static constexpr std::string_view uncounted[] = {
        "auth_challenge", "auth_ok", "auth_failed", "resumed", "hb_ack", "ack",
        "reconnect", "members", "peer_joined", "peer_left", "kill_signal",
    };
    for (auto u : uncounted) {
        if (type == u) return false;
    }
    return true;
}

// Whether a client-to-relay JSON frame of `type` is a stream frame.
inline bool client_type_counts(std::string_view type) {
    static constexpr std::string_view uncounted[] = {
        "auth_hello", "auth", "hb", "ack", "inactive", "active", "end",
    };
    for (auto u : uncounted) {
        if (type == u) return false;
    }
    return true;
}

// What a tombstone replays as: one stream frame that counts as `n`.
inline std::string gap_frame(uint64_t n) {
    return "{\"type\":\"gap\",\"n\":" + std::to_string(n) + "}";
}

// What grace expiry may hand to offline_buffer: the 0x06 frames it takes today, each kind
// under its own cap there. Everything else stays with the topic rings, sync and file asks.
enum class Kind : uint8_t { Other = 0, Direct = 1, DirectImage = 2, ChannelCopy = 3 };

struct Frame {
    // The device's number for this frame; for a tombstone, the last number it stands for.
    uint64_t seq = 0;
    // Non-zero: a tombstone standing for `gap` evicted frames ending at `seq`, no bytes.
    uint64_t gap = 0;
    // Shared across the rings of one fan-out.
    std::shared_ptr<const std::string> bytes;
    bool binary = true;
    // The sender's address share (fair_share.h).
    uint64_t share = 0;
    Kind kind = Kind::Other;
    std::string room;  // the room of a direct kind, for the expiry hand-off
    uint64_t budget_seq = 0;  // its OfflineIndex stamp, 0 = not charged

    bool tombstone() const { return gap != 0; }
    size_t size() const { return bytes ? bytes->size() : 0; }
};

// The frames one session's device has not acked. Entries cover every number in
// (acked, sent] exactly once, in order: a real frame its own seq, a tombstone a run.
class Ring {
public:
    uint64_t sent() const { return sent_; }
    uint64_t acked() const { return acked_; }
    size_t bytes() const { return bytes_; }
    size_t real_frames() const { return real_; }
    const std::deque<Frame>& entries() const { return entries_; }

    // Count `f` for the device and keep it until acked; its seq is assigned here.
    uint64_t push(Frame f) {
        f.seq = ++sent_;
        f.gap = 0;
        bytes_ += f.size();
        real_++;
        entries_.push_back(std::move(f));
        return sent_;
    }

    // Count a frame the ring cannot keep (larger than the ring): it replays as a gap.
    uint64_t push_gap() {
        ++sent_;
        if (!entries_.empty() && entries_.back().tombstone()) {
            entries_.back().seq = sent_;
            entries_.back().gap++;
        } else {
            Frame t;
            t.seq = sent_;
            t.gap = 1;
            entries_.push_back(std::move(t));
        }
        return sent_;
    }

    // Whether a device holding every frame up to `h` can resume here.
    bool can_resume_from(uint64_t h) const { return h >= acked_ && h <= sent_; }

    // The device holds every frame up to `h`. `on_drop(const Frame&)` sees each real frame
    // that leaves. An `h` out of range changes nothing and returns false.
    template <typename OnDrop>
    bool ack(uint64_t h, OnDrop&& on_drop) {
        if (!can_resume_from(h)) return false;
        while (!entries_.empty() && entries_.front().seq <= h) {
            drop_front(on_drop);
        }
        if (!entries_.empty() && entries_.front().tombstone()) {
            Frame& t = entries_.front();
            if (first_of(t) <= h) t.gap = t.seq - h;
        }
        acked_ = h;
        return true;
    }

    // Every entry after `h`, in order: `visit(const Frame&, uint64_t n)` with `n` the part
    // of a tombstone after `h`, 0 for a real frame. Call can_resume_from first.
    template <typename Visit>
    void replay_after(uint64_t h, Visit&& visit) const {
        for (const auto& f : entries_) {
            if (f.seq <= h) continue;
            if (!f.tombstone()) {
                visit(f, 0);
            } else {
                visit(f, first_of(f) > h ? f.gap : f.seq - h);
            }
        }
    }

    bool gap_after(uint64_t h) const {
        for (const auto& f : entries_) {
            if (f.seq > h && f.tombstone()) return true;
        }
        return false;
    }

    // Turn the oldest real frame of the sender share holding the most weight into a
    // tombstone: a flood into someone's ring evicts only the flooder. False when nothing
    // real is left.
    template <typename OnDrop>
    bool evict_one(OnDrop&& on_drop) {
        std::unordered_map<uint64_t, size_t> held;
        size_t most = 0;
        for (const auto& f : entries_) {
            if (!f.tombstone()) most = std::max(most, held[f.share] += f.size() + FRAME_WEIGHT_OVERHEAD);
        }
        if (most == 0) return false;
        for (size_t i = 0; i < entries_.size(); i++) {
            const Frame& f = entries_[i];
            if (!f.tombstone() && held[f.share] == most) {
                bury(i, on_drop);
                return true;
            }
        }
        return false;
    }

    // Evict until the ring is within `max_bytes` and `max_frames` real frames.
    template <typename OnDrop>
    void enforce(size_t max_bytes, size_t max_frames, OnDrop&& on_drop) {
        while ((bytes_ > max_bytes || real_ > max_frames) && evict_one(on_drop)) {
        }
    }

    // The global buffer budget picked the frame charged as `budget_seq`: bury it here. It
    // is the caller who releases the stamp.
    bool evict_budget_seq(uint64_t budget_seq) {
        if (budget_seq == 0) return false;
        for (size_t i = 0; i < entries_.size(); i++) {
            if (!entries_[i].tombstone() && entries_[i].budget_seq == budget_seq) {
                bury(i, [](const Frame&) {});
                return true;
            }
        }
        return false;
    }

    // Every real frame, oldest first, for the hand-off when the session ends; the ring is
    // empty afterwards and acks everything it counted.
    std::vector<Frame> take_all() {
        std::vector<Frame> out;
        for (auto& f : entries_) {
            if (!f.tombstone()) out.push_back(std::move(f));
        }
        entries_.clear();
        bytes_ = 0;
        real_ = 0;
        acked_ = sent_;
        return out;
    }

    // A ring as a snapshot wrote it, or nothing when the entries do not cover (acked, sent]
    // exactly once in order, or a real frame has no bytes.
    static std::optional<Ring> restore(uint64_t sent, uint64_t acked, std::deque<Frame> entries) {
        if (acked > sent) return std::nullopt;
        Ring r;
        r.sent_ = sent;
        r.acked_ = acked;
        uint64_t next = acked + 1;
        for (const auto& f : entries) {
            if (f.tombstone()) {
                if (f.bytes || f.gap > f.seq || f.seq - f.gap + 1 != next) return std::nullopt;
            } else {
                if (!f.bytes || f.seq != next) return std::nullopt;
                r.bytes_ += f.size();
                r.real_++;
            }
            next = f.seq + 1;
        }
        if (next != sent + 1) return std::nullopt;
        r.entries_ = std::move(entries);
        return r;
    }

private:
    static uint64_t first_of(const Frame& f) { return f.tombstone() ? f.seq - f.gap + 1 : f.seq; }

    template <typename OnDrop>
    void drop_front(OnDrop& on_drop) {
        const Frame& f = entries_.front();
        if (!f.tombstone()) {
            on_drop(f);
            bytes_ -= f.size();
            real_--;
        }
        entries_.pop_front();
    }

    // Entry `i` becomes a one-frame tombstone, merged into the runs on either side.
    template <typename OnDrop>
    void bury(size_t i, OnDrop&& on_drop) {
        Frame& v = entries_[i];
        on_drop(v);
        bytes_ -= v.size();
        real_--;
        v.bytes.reset();
        v.room.clear();
        v.kind = Kind::Other;
        v.share = 0;
        v.budget_seq = 0;
        v.gap = 1;
        if (i + 1 < entries_.size() && entries_[i + 1].tombstone()) {
            entries_[i + 1].gap += v.gap;
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
        }
        if (i > 0 && i < entries_.size() && entries_[i - 1].tombstone() && entries_[i].tombstone()) {
            entries_[i].gap += entries_[i - 1].gap;
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i - 1));
        }
    }

    std::deque<Frame> entries_;
    uint64_t sent_ = 0;
    uint64_t acked_ = 0;
    size_t bytes_ = 0;
    size_t real_ = 0;
};

// Gone is not a state: a gone session is erased from RelayState::sessions.
enum class State : uint8_t { Live = 0, Grace = 1 };

// One device's session (section 9.7), kept in RelayState::sessions under its peer id.
// Ring mutations, minting and ending go through session_bounds.h, never Ring directly.
struct Session {
    std::string sid;  // never logged, never on disk outside the memfd snapshot
    std::string peer_id;
    State state = State::Live;
    // Every room it holds; true = an owner of that `inbox:` room as last proven.
    std::unordered_map<std::string, bool> rooms;
    // As PerSocketData::subscriptions: room -> topics; a room with no entry gets every topic.
    std::unordered_map<std::string, std::unordered_set<std::string>> subscriptions;
    bool inactive = false;
    uint64_t in_h = 0;  // stream frames received from the device
    Ring ring;          // stream frames sent to it and not acked
    // The nonce it was minted with, its door-proof nonce within this process.
    std::string door_nonce;
    // The per-IP slot it holds while in grace, "" when its socket holds the slot.
    std::string ip_key;
    uint64_t share = 0;  // the address share that minted it
    std::chrono::steady_clock::time_point grace_until{};
    // Back from a snapshot: door standing is gone, so its resume answers reprove:true.
    bool restored = false;
    // Stream frames received since the relay last told the device its count, and when
    // that count is due at the latest. Live only, never snapshotted.
    uint32_t unacked_in = 0;
    std::chrono::steady_clock::time_point ack_due{};
};

}  // namespace session
