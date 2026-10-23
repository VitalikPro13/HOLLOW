#pragma once
#include <algorithm>
#include <cstdint>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "fair_share.h"

// The relay's memory-safety budget for the bytes uWebSockets holds per socket: unsent
// frames (WebSocket::send over maxBackpressure still appends up to one frame past the
// limit) and inbound frames that span reads (kept whole, up to maxPayloadLength, with
// their capacity kept after the message). Unbounded, sockets that do not read or that
// send big frames can hold gigabytes at once and OOM-kill the box, which skips the
// restart snapshot and loses every buffer. This is NOT a volume quota: nothing counts
// bytes over time (volume fairness lives below the relay in CAKE). It bounds the bytes
// held AT ONCE.
//
// Every socket holding bytes is one entry, charged to its OWN address share (a v4
// address or a v6 /48, fair_share.h) at the weight of what it holds: the socket that
// refuses to read is the one charged, never the sender fanning to it. Past the budget the
// share holding the most gives way first; while the box holds over half its budget one
// share also keeps to a share cap. Either way the share's socket that last REALLY made
// progress the longest ago is closed first (a session resumes from its ring), so an
// honest phone sharing a carrier address with a non-reader never pays for it. Header-only
// so test/test_send_budget.cpp drives it without a relay.
namespace send_budget {

static constexpr uint64_t MiB = 1024ull * 1024;
// The biggest honest fan-out the relay must never drop: an MLS remove commit (about
// 134 KB) to every device of a 512-identity server (1,536 devices) is about 206 MB.
static constexpr uint64_t HONEST_FANOUT_BYTES = 206 * MiB;
// The budget a fan-out is admitted against, and the line a frame can never cross (a
// fan-out past the WHOLE budget can never be held at once). Where the box has the RAM it
// is at least this, well above the honest maximum, so an honest fan-out always passes on
// an empty budget and is never counted-dropped.
static constexpr uint64_t MIN_LIMIT = 512 * MiB;
static_assert(MIN_LIMIT >= 2 * HONEST_FANOUT_BYTES, "an honest fan-out passes with headroom");
// A socket holding bytes that has not REALLY drained them (PROGRESS_BYTES, or half of a
// smaller buffer) for this long is not reading, and an inbound frame that has not grown
// by as much is not arriving: the socket is closed and its session resumes from its ring.
// A frame larger than the ring keeps (RING_MAX_BYTES) replays as a gap, so the receiver
// learns it lost that frame. Long, because uWS reports a drain only when a third of the
// kernel's send buffer frees up, which a slow honest link takes a while to do.
static constexpr int64_t STALL_MS = 120000;
static constexpr uint64_t PROGRESS_BYTES = 64 * 1024;
// One socket may buffer at most one max frame. maxBackpressure (64 MB) lets a socket at
// 60 MB still take a 64 MB frame (~124 MB); this refuses a write that would push a
// socket already holding bytes past a single frame.
static constexpr uint64_t SOCKET_CAP = 64 * MiB;
// One address share holds at most this part of the budget while the box holds over half of it.
static constexpr uint64_t SHARE_DIVISOR = 8;
// A fan-out counts at most this many recipients per connection block (ip_limit_key, as
// the work breaker keys it) and per address share: recipients a stranger piles into a
// room cannot make an honest frame trip or be refused. A write to a recipient past the
// count goes out only while the budget holds it; else that receiver is refused, never
// the sender.
static constexpr uint32_t BLOCK_RECIPIENTS = 8;
static constexpr uint32_t SHARE_RECIPIENTS = 64;
// uWS end() runs the close handler (which drops the charge) but keeps the socket's unsent
// buffer until it drains, and a finished inbound message keeps its buffer's capacity:
// past this either is released at once instead of held unseen.
static constexpr uint64_t ENDED_KEEP_BYTES = 64 * 1024;
// A WebSocket binary frame header is at most this many bytes on the wire.
static constexpr uint64_t FRAME_HEADER_BYTES = 14;

struct Limits {
    uint64_t limit = MIN_LIMIT;                 // fan-outs admitted against this; also the never-fits line
    uint64_t hard = MIN_LIMIT + MIN_LIMIT / 4;  // no single write past this (uncounted replays/answers headroom)
    uint64_t socket_cap = SOCKET_CAP;           // no socket holds more, but for one frame into an empty buffer
    uint64_t share_cap = MIN_LIMIT / SHARE_DIVISOR;
    uint32_t block_recipients = BLOCK_RECIPIENTS;
    uint32_t share_recipients = SHARE_RECIPIENTS;
};

// The limits for a budget of `limit` bytes. `test`: a relay built only for the live tests
// may set a tiny budget, with the per-socket and share caps below it as in production
// and two recipients per block (its address takes three sockets).
inline Limits limits_for(uint64_t limit, bool test = false) {
    Limits l;
    l.limit = std::max<uint64_t>(limit, 1);
    l.hard = l.limit + l.limit / 4;
    l.socket_cap = test ? std::max<uint64_t>(l.limit / 2, 1) : SOCKET_CAP;
    l.share_cap = test ? std::max<uint64_t>(l.limit / 2, 1) : std::max(l.limit / SHARE_DIVISOR, SOCKET_CAP);
    if (test) l.block_recipients = 2;
    return l;
}

// The least budget a box with `mem_total` bytes of RAM (0 = unknown) runs with: the
// honest floor, but never more than a third of a small box.
inline uint64_t floor_for(uint64_t mem_total) {
    return mem_total ? std::min(MIN_LIMIT, mem_total / 3) : MIN_LIMIT;
}

// The default budget for a box with `mem_total` bytes of RAM: a quarter of it, floored.
inline uint64_t default_limit(uint64_t mem_total) {
    return std::max(mem_total / 4, floor_for(mem_total));
}

// Pass: fits now. Trip: over budget now but would fit on an empty budget, so the sender is
// closed UNCOUNTED and re-sends on resume (it passes once buffers drain). Refuse: larger
// than the WHOLE budget, so it can never be held at once, so it is COUNTED and dropped
// once (the client advances past it on resume) rather than reconnecting forever (N7). A
// session-less sender (guest, forwarder) has nothing to re-send from: a Trip loses its
// frame. A Refuse is unreachable by any legitimate broadcast on a box sized to the
// honest maximum.
enum class Admit { Pass, Trip, Refuse };

// Counts one fan-out's recipients per connection block and per address share, for the
// prediction and again for the delivery (the same walk in the same order). In the
// delivery it also keeps what the counted recipients not yet written still need of the
// budget (`reserved`, the prediction), which an uncounted recipient may not take.
class Recipients {
public:
    explicit Recipients(const Limits& l, uint64_t reserved = 0)
        : block_max_(l.block_recipients), share_max_(l.share_recipients), reserved_(reserved) {}
    // Whether this recipient is within its block's and its share's count (and counts it,
    // its copy of `bytes` leaving the reservation).
    bool take(const std::string& block, uint64_t share, uint64_t bytes = 0) {
        uint32_t& b = blocks_[block];
        uint32_t& s = shares_[share];
        if (b >= block_max_ || s >= share_max_) return false;
        b++;
        s++;
        reserved_ -= std::min(reserved_, bytes);
        return true;
    }
    uint64_t reserved() const { return reserved_; }

private:
    uint32_t block_max_, share_max_;
    uint64_t reserved_;
    std::unordered_map<std::string, uint32_t> blocks_;
    std::unordered_map<uint64_t, uint32_t> shares_;
};

// What `copies` copies of a `per_copy`-byte frame hold in send buffers, headers included.
inline uint64_t held_bytes(uint64_t copies, uint64_t per_copy) {
    return copies * (per_copy + FRAME_HEADER_BYTES);
}

// The bytes a fan-out holds at once: `per_copy` plus a frame header for each peer
// `reaches` picks (it answers the peer's connection block and share, or nullopt), at most
// so many per block and per share.
template <typename Peers, typename Reaches>
uint64_t predict(const Peers& peers, uint64_t per_copy, const Limits& l, Reaches reaches) {
    Recipients counted(l);
    uint64_t copies = 0;
    for (const auto& p : peers) {
        const std::optional<std::pair<std::string, uint64_t>> r = reaches(p);
        if (r && counted.take(r->first, r->second)) copies++;
    }
    return held_bytes(copies, per_copy);
}

// `used` of `limit` in whole tens of percent, at most 100: what the relay publishes, never
// the live byte count (an attacker would tune its fill under the line).
inline uint64_t used_pct(uint64_t used, uint64_t limit) {
    if (limit == 0) return 0;
    const uint64_t pct = used >= limit ? 100 : static_cast<uint64_t>(static_cast<double>(used) * 100 / limit);
    return std::min<uint64_t>(pct, 100) / 10 * 10;
}

template <typename Key, typename Hash = std::hash<Key>>
class Ledger {
public:
    Limits limits;

    // A socket's unsent buffer (`out`) or its inbound partial frame (`in`) is now
    // `amount` bytes, charged to `share` (the socket's share never changes while it
    // lives). `now_ms` judges the stall sweep: only a real drain (or real inbound
    // growth) counts as progress.
    void out(const Key& k, uint64_t amount, int64_t now_ms, uint64_t share) {
        Use* u = use(k, amount, share, now_ms);
        if (!u) return;
        if (amount < u->out) {
            // Drains add up only within half a window: a trickle never makes progress.
            if (now_ms - u->drain_from >= STALL_MS / 2) {
                u->drain_from = now_ms;
                u->drained = 0;
            }
            u->drained += u->out - amount;
            if (u->drained >= std::min(PROGRESS_BYTES, std::max<uint64_t>(u->out / 2, 1))) {
                u->out_at = u->drain_from = now_ms;
                u->drained = 0;
            }
        } else if (u->out == 0) {
            u->out_at = u->drain_from = now_ms;  // began buffering
            u->drained = 0;
        }
        u->out = amount;
        settle(k, *u);
    }
    // `held` is what the inbound frame's buffer holds (its reserved capacity), `filled`
    // how much of the frame has arrived, `messages` how many messages the socket has
    // finished in all: only arrival or a finished message counts as progress.
    void in(const Key& k, uint64_t held, uint64_t filled, uint64_t messages, int64_t now_ms, uint64_t share) {
        Use* u = use(k, held, share, now_ms);
        if (!u) return;
        if (u->in == 0 || messages != u->in_msgs || filled >= u->in_mark + PROGRESS_BYTES) {
            u->in_at = now_ms;  // began, finished one, or grew for real
            u->in_mark = filled;
        } else if (filled < u->in_mark) {
            u->in_mark = filled;  // a control frame's tip left
        }
        u->in = held;
        u->in_msgs = messages;
        if (held == 0) u->in_mark = 0;
        settle(k, *u);
    }

    // The socket is gone, its buffers freed with it.
    void forget(const Key& k) {
        auto it = uses_.find(k);
        if (it != uses_.end()) {
            unrank(k, it->second);
            uses_.erase(it);
        }
        table_.remove(k);
        doomed_.erase(k);
    }

    // Whether a write of `bytes` to socket `k`, already holding `buffered` and charged to
    // `share`, stays within the per-socket cap (one frame into an empty buffer always
    // passes) and the ceiling (`strict`: the budget itself less what the fan-out still
    // `reserved`, for a recipient past its fan-out's count; else the hard line). Under
    // pressure a share past its cap dooms its sockets that progressed least recently until
    // the write fits; the receiver is refused only when it is next in that order itself.
    // Nothing is closed here: a write runs inside fan-out loops.
    bool write_fits(const Key& k, uint64_t buffered, uint64_t bytes, uint64_t share, bool strict = false,
                    uint64_t reserved = 0) {
        if (buffered > 0 && buffered + bytes > limits.socket_cap) return false;
        if (strict ? total() + bytes + reserved > limits.limit : total() + bytes > limits.hard) return false;
        if (buffered == 0 || !pressed(bytes)) return true;
        if (doomed_.count(k)) return false;
        uint64_t live = table_.held(share);
        for (const Key& d : doomed_) {
            auto it = uses_.find(d);
            if (it != uses_.end() && it->second.share == share) live -= std::min(live, weight(it->second));
        }
        auto o = order_.find(share);
        if (o == order_.end()) return live + bytes <= limits.share_cap;
        for (const Rank& r : o->second) {
            if (live + bytes <= limits.share_cap) return true;
            if (doomed_.count(r.key)) continue;
            if (r.key == k) return false;
            doomed_.insert(r.key);
            live -= std::min(live, r.weight);
        }
        return live + bytes <= limits.share_cap;
    }

    // Whether a write to recipient `k` goes out: `fanout` (null outside one) counts it, and
    // a recipient past its block's or share's count gets only what the budget holds beyond
    // the counted recipients' reservation.
    bool write_ok(const Key& k, uint64_t buffered, uint64_t bytes, uint64_t share, Recipients* fanout,
                  const std::string& block) {
        const bool counted = !fanout || fanout->take(block, share, bytes);
        return write_fits(k, buffered, bytes, share, !counted, fanout ? fanout->reserved() : 0);
    }

    // How a fan-out of `bytes` in all from `sender` in `own_share` is judged. Over the
    // budget, `close` is handed the socket of the share holding the most that progressed
    // least recently until it fits; never the sender, which trips instead when it is next
    // in its own share's order (a co-tenant's bytes are closed before the sender trips,
    // else the trip frees nothing and the sender loops).
    Admit admit(uint64_t bytes, const Key& sender, uint64_t own_share,
                const std::function<void(const Key&)>& close) {
        if (bytes > limits.limit) return Admit::Refuse;
        while (total() + bytes > limits.limit) {
            const auto h = heaviest();
            if (!h) return Admit::Trip;
            const auto v = first(*h);
            if (!v || !table_.contains(*v) || (*h == own_share && *v == sender)) return Admit::Trip;
            const Key victim = *v;
            forget(victim);
            close(victim);
        }
        return Admit::Pass;
    }

    // What the sweep closes to bring the budget (and, under pressure, every share) back
    // under its line: the heaviest share's socket that progressed least recently, again
    // and again. Each is forgotten here (its close frees what it held).
    std::vector<Key> over_budget() {
        std::vector<Key> out;
        for (;;) {
            const auto h = heaviest();
            if (!h) break;
            if (total() <= limits.limit && (!pressed(0) || table_.held(*h) <= limits.share_cap)) break;
            const auto v = first(*h);
            if (!v || !table_.contains(*v)) break;
            out.push_back(*v);
            forget(*v);
        }
        return out;
    }

    // A socket a write was refused on: closed on the next sweep.
    void doom(const Key& k) { doomed_.insert(k); }
    std::vector<Key> doomed() const { return {doomed_.begin(), doomed_.end()}; }

    // Sockets whose unsent buffer has not really drained, or whose inbound frame has not
    // really grown, for `stall_ms` (STALL_MS in the relay): to be closed.
    std::vector<Key> stalled(int64_t now_ms, int64_t stall_ms = STALL_MS) const {
        std::vector<Key> out;
        for (const auto& [k, u] : uses_) {
            if ((u.out > 0 && now_ms - u.out_at >= stall_ms) || (u.in > 0 && now_ms - u.in_at >= stall_ms)) {
                out.push_back(k);
            }
        }
        return out;
    }

    uint64_t total() const { return table_.total(); }
    size_t sockets() const { return table_.size(); }
    bool holds(const Key& k) const { return table_.contains(k); }
    uint64_t held_by(uint64_t share) const { return table_.held(share); }

private:
    struct Use {
        uint64_t share = 0;
        uint64_t out = 0;
        uint64_t drained = 0;  // drained since drain_from
        int64_t drain_from = 0;
        int64_t out_at = 0;    // last real drain (or buffering start)
        uint64_t in = 0;
        uint64_t in_mark = 0;  // inbound size at the last progress mark
        uint64_t in_msgs = 0;  // messages finished as of the last sweep
        int64_t in_at = 0;
        bool ranked = false;   // the rank below is in order_
        int64_t rank_at = 0;
        uint64_t rank_weight = 0;
    };

    // A socket's place in its share's victim order: the oldest real progress on what it
    // holds goes first (a byte trickle is no progress), and of equals the one holding more.
    struct Rank {
        int64_t at;
        uint64_t weight;
        Key key;
    };
    struct RankLess {
        bool operator()(const Rank& a, const Rank& b) const {
            if (a.at != b.at) return a.at < b.at;
            if (a.weight != b.weight) return a.weight > b.weight;
            return std::less<Key>()(a.key, b.key);
        }
    };

    static uint64_t weight(const Use& u) { return u.out + u.in; }

    // When the socket last REALLY progressed on everything it holds: a socket holding an
    // unsent buffer and an inbound frame is as stale as the staler of the two.
    static int64_t progress_at(const Use& u) {
        if (u.out > 0 && u.in > 0) return std::min(u.out_at, u.in_at);
        return u.out > 0 ? u.out_at : u.in_at;
    }

    // Whether the box holds more than half its budget once `extra` more is written: only
    // then does a share keep to its cap.
    bool pressed(uint64_t extra) const { return total() + extra > limits.limit / 2; }

    std::optional<uint64_t> heaviest() const {
        const auto v = table_.victim();
        return v ? table_.share_of(*v) : std::nullopt;
    }

    std::optional<Key> first(uint64_t share) const {
        auto o = order_.find(share);
        if (o == order_.end() || o->second.empty()) return std::nullopt;
        return o->second.begin()->key;
    }

    void unrank(const Key& k, Use& u) {
        if (!u.ranked) return;
        auto o = order_.find(u.share);
        if (o != order_.end()) {
            o->second.erase(Rank{u.rank_at, u.rank_weight, k});
            if (o->second.empty()) order_.erase(o);
        }
        u.ranked = false;
    }

    void rank(const Key& k, Use& u) {
        unrank(k, u);
        u.rank_at = progress_at(u);
        u.rank_weight = weight(u);
        order_[u.share].insert(Rank{u.rank_at, u.rank_weight, k});
        u.ranked = true;
    }

    // The entry for `k`, made when it begins to hold bytes; null when it holds none and
    // has no entry (nothing to do).
    Use* use(const Key& k, uint64_t amount, uint64_t share, int64_t now_ms) {
        auto it = uses_.find(k);
        if (it != uses_.end()) return &it->second;
        if (amount == 0) return nullptr;
        Use& u = uses_[k];
        u.share = share;
        u.out_at = u.in_at = u.drain_from = now_ms;
        return &u;
    }

    void settle(const Key& k, Use& u) {
        const uint64_t w = weight(u);
        if (w == 0) {  // a doomed socket stays doomed
            unrank(k, u);
            table_.remove(k);
            uses_.erase(k);
            return;
        }
        if (table_.contains(k)) {
            table_.reweigh(k, static_cast<size_t>(w));
        } else {
            table_.put(k, u.share, static_cast<size_t>(w));
        }
        rank(k, u);
    }

    FairShare<Key, Hash> table_;
    std::unordered_map<Key, Use, Hash> uses_;
    std::unordered_map<uint64_t, std::set<Rank, RankLess>> order_;
    std::unordered_set<Key, Hash> doomed_;
};

}  // namespace send_budget
