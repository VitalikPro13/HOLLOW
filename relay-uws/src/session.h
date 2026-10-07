#pragma once
#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
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
    // The ring's next real frame from the same share, 0 for none. The ring's own.
    uint64_t next_of_share = 0;

    bool tombstone() const { return gap != 0; }
    size_t size() const { return bytes ? bytes->size() : 0; }
};

// The frames one session's device has not acked. Entries cover every number in
// (acked, sent] exactly once, in order: a real frame its own seq, a tombstone a run.
// Tombstones next to each other merge where that is cheap and at the next compaction
// otherwise; a replay sends every run of them as one gap either way.
//
// Every operation is logarithmic or amortized constant in the ring's size: a full ring
// takes each frame of a fan-out, so a linear step here is paid once per ring per frame.
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
        f.next_of_share = 0;
        bytes_ += f.size();
        real_++;
        entries_.push_back(std::move(f));
        hold(entries_.back());
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
            tombs_++;
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
    // of a run of tombstones after `h`, 0 for a real frame. Call can_resume_from first.
    template <typename Visit>
    void replay_after(uint64_t h, Visit&& visit) const {
        const Frame* run_end = nullptr;
        uint64_t run = 0;
        for (size_t i = first_after(h); i < entries_.size(); i++) {
            const Frame& f = entries_[i];
            if (f.tombstone()) {
                run += first_of(f) > h ? f.gap : f.seq - h;
                run_end = &f;
                continue;
            }
            if (run) visit(*run_end, run);
            run = 0;
            visit(f, 0);
        }
        if (run) visit(*run_end, run);
    }

    bool gap_after(uint64_t h) const {
        for (size_t i = first_after(h); i < entries_.size(); i++) {
            if (entries_[i].tombstone()) return true;
        }
        return false;
    }

    // Turn the oldest real frame of the sender share holding the most weight into a
    // tombstone: a flood into someone's ring evicts only the flooder. False when nothing
    // real is left.
    template <typename OnDrop>
    bool evict_one(OnDrop&& on_drop) {
        if (by_weight_.empty()) return false;
        const Held& h = held_.at(std::get<2>(*by_weight_.rbegin()));
        bury(index_of(h.head), on_drop);
        return true;
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
        held_.clear();
        by_weight_.clear();
        bytes_ = 0;
        real_ = 0;
        tombs_ = 0;
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
                r.tombs_++;
            } else {
                if (!f.bytes || f.seq != next) return std::nullopt;
                r.bytes_ += f.size();
                r.real_++;
            }
            next = f.seq + 1;
        }
        if (next != sent + 1) return std::nullopt;
        r.entries_ = std::move(entries);
        for (auto& f : r.entries_) {
            f.next_of_share = 0;
            if (!f.tombstone()) r.hold(f);
        }
        return r;
    }

private:
    // One sender share's real frames here: their weight and the oldest and newest of them,
    // linked oldest first through Frame::next_of_share.
    struct Held {
        size_t weight = 0;
        uint64_t head = 0;
        uint64_t tail = 0;
    };
    // Heaviest last; among equals the share whose oldest frame is oldest.
    using WeightKey = std::tuple<size_t, uint64_t, uint64_t>;

    // Merge a new tombstone into a neighbour only when the erase moves this few entries.
    static constexpr size_t MERGE_NEAR = 32;
    // Tombstone entries allowed beyond one per real frame before a compaction.
    static constexpr size_t COMPACT_SLACK = 64;

    static uint64_t first_of(const Frame& f) { return f.tombstone() ? f.seq - f.gap + 1 : f.seq; }
    static WeightKey key(const Held& h, uint64_t share) { return {h.weight, UINT64_MAX - h.head, share}; }
    static size_t weight_of(const Frame& f) { return f.size() + FRAME_WEIGHT_OVERHEAD; }

    // The first entry whose numbers reach past `h`.
    size_t first_after(uint64_t h) const {
        auto it = std::upper_bound(entries_.begin(), entries_.end(), h,
                                   [](uint64_t v, const Frame& f) { return v < f.seq; });
        return static_cast<size_t>(it - entries_.begin());
    }

    // The entry holding the real frame `seq`.
    size_t index_of(uint64_t seq) const {
        auto it = std::lower_bound(entries_.begin(), entries_.end(), seq,
                                   [](const Frame& f, uint64_t v) { return f.seq < v; });
        return static_cast<size_t>(it - entries_.begin());
    }

    // `f`, already in the ring and its newest real frame from its share, joins the index.
    void hold(Frame& f) {
        auto [it, fresh] = held_.try_emplace(f.share);
        Held& h = it->second;
        if (fresh) {
            h.head = f.seq;
        } else {
            by_weight_.erase(key(h, f.share));
            entries_[index_of(h.tail)].next_of_share = f.seq;
        }
        h.tail = f.seq;
        h.weight += weight_of(f);
        by_weight_.insert(key(h, f.share));
    }

    // The real frame `f` leaves the index, before it leaves the ring.
    void unhold(const Frame& f) {
        auto it = held_.find(f.share);
        Held& h = it->second;
        by_weight_.erase(key(h, f.share));
        h.weight -= weight_of(f);
        if (h.head == f.seq) {
            h.head = f.next_of_share;
        } else {
            // Only the budget picks a frame other than its share's oldest: walk to it.
            uint64_t prev = 0;
            for (uint64_t at = h.head; at != 0 && at != f.seq; at = entries_[index_of(at)].next_of_share) prev = at;
            if (prev != 0) entries_[index_of(prev)].next_of_share = f.next_of_share;
            if (h.tail == f.seq) h.tail = prev;
        }
        if (h.head == 0) h.tail = 0;
        if (h.head == 0) {
            held_.erase(it);
        } else {
            by_weight_.insert(key(h, f.share));
        }
    }

    template <typename OnDrop>
    void drop_front(OnDrop& on_drop) {
        const Frame& f = entries_.front();
        if (!f.tombstone()) {
            on_drop(f);
            unhold(f);
            bytes_ -= f.size();
            real_--;
        } else {
            tombs_--;
        }
        entries_.pop_front();
    }

    bool near_end(size_t i) const { return i < MERGE_NEAR || entries_.size() - i <= MERGE_NEAR; }

    // Entry `i` becomes a one-frame tombstone, merged into a run beside it where cheap.
    template <typename OnDrop>
    void bury(size_t i, OnDrop&& on_drop) {
        {
            Frame& v = entries_[i];
            on_drop(v);
            unhold(v);
            bytes_ -= v.size();
            real_--;
            v.bytes.reset();
            v.room.clear();
            v.kind = Kind::Other;
            v.share = 0;
            v.budget_seq = 0;
            v.next_of_share = 0;
            v.gap = 1;
            tombs_++;
        }
        if (i + 1 < entries_.size() && entries_[i + 1].tombstone() && near_end(i)) {
            entries_[i + 1].gap += entries_[i].gap;
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
            tombs_--;
        }
        if (i > 0 && i < entries_.size() && entries_[i - 1].tombstone() && entries_[i].tombstone() &&
            near_end(i - 1)) {
            entries_[i].gap += entries_[i - 1].gap;
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i - 1));
            tombs_--;
        }
        if (tombs_ > real_ + COMPACT_SLACK) compact();
    }

    // Every run of adjacent tombstones becomes one entry.
    void compact() {
        std::deque<Frame> out;
        for (auto& f : entries_) {
            if (f.tombstone() && !out.empty() && out.back().tombstone()) {
                out.back().seq = f.seq;
                out.back().gap += f.gap;
            } else {
                out.push_back(std::move(f));
            }
        }
        entries_ = std::move(out);
        tombs_ = 0;
        for (const auto& f : entries_) tombs_ += f.tombstone();
    }

    std::deque<Frame> entries_;
    std::unordered_map<uint64_t, Held> held_;
    std::set<WeightKey> by_weight_;
    uint64_t sent_ = 0;
    uint64_t acked_ = 0;
    size_t bytes_ = 0;
    size_t real_ = 0;
    size_t tombs_ = 0;  // tombstone entries
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

    // A stream frame from the device arrived at `now`. True when an ack must be queued for
    // it (RelayState::acks_due), due at `ack_due`. One is queued per session at a time: a
    // frame after an ack or a heartbeat while one waits rides that one, so the ack comes
    // early, never late, and frames between heartbeats cannot grow the queue.
    bool count_in(std::chrono::steady_clock::time_point now) {
        in_h++;
        if (++unacked_in != 1 || ack_due > now) return false;
        ack_due = now + std::chrono::milliseconds(ACK_AFTER_MS);
        return true;
    }
};

// Which session gives way when the session table is full, and which grace slot when an
// address is (session_bounds.h): kept beside RelayState::sessions as they change, so
// neither choice walks the table. At 262,144 sessions a walk costs tens of milliseconds
// of the relay's one thread, once per login.
class Book {
public:
    // A session whose turn to give way comes first sorts first: in grace before live,
    // then the earlier into grace (the grace is one length per process).
    struct Rank {
        bool live = true;
        uint64_t order = 0;
        bool operator<(const Rank& o) const { return live != o.live ? !live : order < o.order; }
    };

    size_t size() const { return where_.size(); }
    bool has(const std::string& peer) const { return where_.count(peer) != 0; }

    // A fresh session of `share`.
    void add(const std::string& peer, uint64_t share) {
        if (has(peer)) drop(peer);
        where_[peer] = Place{share, Rank{true, 0}, std::string()};
        link(peer);
    }

    // `peer`'s session went into grace, holding a slot of the address `ip_key` ("" for none).
    void to_grace(const std::string& peer, const std::string& ip_key) {
        auto it = where_.find(peer);
        if (it == where_.end()) return;
        unlink(peer);
        it->second.rank = Rank{false, ++next_order_};
        it->second.ip = ip_key;
        link(peer);
    }

    // `peer`'s session is live again.
    void to_live(const std::string& peer) {
        auto it = where_.find(peer);
        if (it == where_.end() || it->second.rank.live) return;
        unlink(peer);
        it->second.rank = Rank{true, 0};
        it->second.ip.clear();
        link(peer);
    }

    void drop(const std::string& peer) {
        if (!has(peer)) return;
        unlink(peer);
        where_.erase(peer);
    }

    // The session the table cap ends for a newcomer of `share`: the share holding the
    // most gives one up, the newcomer counted and a tie going against the newcomer's own.
    std::optional<std::string> table_victim(uint64_t share) const {
        if (by_count_.empty()) return std::nullopt;
        const auto& top = *by_count_.rbegin();
        uint64_t pick = std::get<3>(top);
        auto own = shares_.find(share);
        if (own != shares_.end() && pick != share && own->second.size() + 1 >= std::get<0>(top)) pick = share;
        return shares_.at(pick).begin()->second;
    }

    // How many grace slots the address `ip_key` holds, and the one closest to its end.
    size_t grace_slots(const std::string& ip_key) const {
        auto it = by_ip_.find(ip_key);
        return it == by_ip_.end() ? 0 : it->second.size();
    }
    std::optional<std::string> grace_slot_victim(const std::string& ip_key) const {
        auto it = by_ip_.find(ip_key);
        if (it == by_ip_.end()) return std::nullopt;
        return it->second.begin()->second;
    }

private:
    struct Place {
        uint64_t share = 0;
        Rank rank;
        std::string ip;
    };
    struct ByRank {
        bool operator()(const std::pair<Rank, std::string>& a, const std::pair<Rank, std::string>& b) const {
            if (a.first < b.first) return true;
            if (b.first < a.first) return false;
            return a.second < b.second;
        }
    };
    using Members = std::set<std::pair<Rank, std::string>, ByRank>;
    // A share's place among shares: by how many sessions it holds, then by how soon its
    // first session would give way.
    using CountKey = std::tuple<size_t, bool, uint64_t, uint64_t>;

    static CountKey count_key(uint64_t share, const Members& m) {
        const Rank& r = m.begin()->first;
        return {m.size(), !r.live, r.live ? 0 : UINT64_MAX - r.order, share};
    }

    void link(const std::string& peer) {
        const Place& p = where_.at(peer);
        Members& m = shares_[p.share];
        if (!m.empty()) by_count_.erase(count_key(p.share, m));
        m.insert({p.rank, peer});
        by_count_.insert(count_key(p.share, m));
        if (!p.rank.live && !p.ip.empty()) by_ip_[p.ip].insert({p.rank.order, peer});
    }

    void unlink(const std::string& peer) {
        const Place& p = where_.at(peer);
        auto sit = shares_.find(p.share);
        Members& m = sit->second;
        by_count_.erase(count_key(p.share, m));
        m.erase({p.rank, peer});
        if (m.empty()) {
            shares_.erase(sit);
        } else {
            by_count_.insert(count_key(p.share, m));
        }
        if (!p.rank.live && !p.ip.empty()) {
            auto iit = by_ip_.find(p.ip);
            iit->second.erase({p.rank.order, peer});
            if (iit->second.empty()) by_ip_.erase(iit);
        }
    }

    std::unordered_map<std::string, Place> where_;
    std::unordered_map<uint64_t, Members> shares_;
    std::set<CountKey> by_count_;
    std::unordered_map<std::string, std::set<std::pair<uint64_t, std::string>>> by_ip_;
    uint64_t next_order_ = 0;
};

}  // namespace session
