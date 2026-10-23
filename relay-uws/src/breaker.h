#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "fair_share.h"

// The relay circuit breaker (phase G2, .team/G2_DESIGN_v2.md): every socket pays for the
// work its frames make the relay do, in work units W, from deterministic buckets that live
// on the device's session. A frame its bucket cannot pay for trips the breaker before it
// is counted: the socket closes 1013 with a reconnect hint and its session resumes after
// the pause, resending that frame. Pacing clients (node/relay_pace.rs) mirror these
// numbers and never trip.
//
// Compile-time numbers, not config: a self-hosted relay cannot lower them below what an
// honest member of ten 1,536-device servers needs. Shadow mode (the default) books every
// trip exactly as enforcement would and closes nothing; HOLLOW_BREAKER_ENFORCE=1 enforces.
//
// Header-only and free of uWebSockets and libsodium, so test/test_breaker.cpp drives it.
// Keys are 64-bit hashes the relay makes under a process-lifetime key: nothing here names
// a device, an address or a room, and nothing is logged or snapshotted.

#ifndef HOLLOW_BREAKER_ENFORCE
#define HOLLOW_BREAKER_ENFORCE 0
#endif

namespace breaker {

inline constexpr bool ENFORCE = HOLLOW_BREAKER_ENFORCE;

// One fan-out delivery costs a receiving address group (ip_limit_key: a v4 address or a
// v6 /64) at most this much per frame, so sockets a stranger piles into a room add 8 W to
// each post, not one per socket.
inline constexpr int64_t SHARE_CAP = 8;
inline constexpr int64_t SIG_W = 6;
inline constexpr int64_t DH_W = 4;
inline constexpr int64_t IDS_PER_W = 32;
inline constexpr int64_t RESUME_W_PER_ROOM = 4;
inline constexpr int64_t CHECK_PEERS_SCAN_W = 2048;
// Deposits to strangers are counted per payer over a sliding window of this many minutes.
inline constexpr int64_t DISTINCT_MINUTES = 10;
// All payers' stranger trackers together (StrangerBook): about 3,000 that sketch, or
// 100,000 that hold a few targets each.
inline constexpr size_t STRANGER_BYTES = 32u << 20;
// The ladder of device cooldowns, one level forgotten per LADDER_FORGET_MS without a trip.
inline constexpr std::array<int64_t, 5> LADDER_MS = {60'000, 300'000, 1'800'000, 7'200'000, 86'400'000};
// Entries in each table a stranger can fill (cooldowns, start pools, clean devices).
inline constexpr size_t TABLE_MAX = 65'536;
inline constexpr int64_t LADDER_SLOTS = 10;

// Every number a bucket uses. DEFAULT is what every relay runs; a relay built for the live
// tests may scale it down (HOLLOW_RELAY_TEST_LOOPBACK only).
struct Rates {
    int64_t start = 0;
    int64_t cap = 0;
    // Refill in thousandths of a unit per second (1,000 W/s = 1,000,000).
    int64_t refill_m = 0;
};

struct Limits {
    Rates w_full{400'000, 800'000, 1'000'000};
    // The two lower fresh-start tiers (section 4): the floor an ordinary fresh reconnect
    // needs, and what a block that keeps starting fresh sessions gets.
    int64_t w_floor = 100'000;
    int64_t w_low = 24'000;
    Rates w_fetch{20'000, 20'000, 200'000};
    Rates w_guest{5'000, 5'000, 50'000};
    Rates joins_full{2'500, 5'000, 2'000};
    Rates joins_fetch{2'500, 2'500, 2'000};
    Rates joins_guest{10, 10, 100};
    Rates allowance{50'000, 50'000, 500'000};
    Rates pool{1'200'000, 1'200'000, 2'000'000};
    int64_t debt_floor = -100'000;
    int64_t distinct = 50'000;
    // The mirror margin a pacing client keeps (relay_pace RESERVE): no frame is judged
    // above cap minus this.
    int64_t pace_reserve = 16'000;
    // Fresh full starts a block may make in FRESH_WINDOW_MS before it falls to w_low.
    int64_t fresh_window_ms = 60'000;
    size_t fresh_floor_starts = 10;
    // A device that held a clean session this recently keeps the floor tier (N6).
    int64_t clean_seen_ms = 86'400'000;
    std::array<int64_t, 5> ladder_ms = LADDER_MS;
    int64_t ladder_forget_ms = 6 * 3'600'000;
    // The ladder steps only for a full payer whose spend over this window passed
    // ladder_budget(): the most an honest bucket can pay in it (lead decision 3).
    int64_t ladder_window_ms = 600'000;
    // A fetch or guest socket's pause after a trip; it never cools the device.
    int64_t socket_pause_ms = 30'000;
    // What a pause adds beyond the refill it waits for (section 3).
    int64_t pause_slack_ms = 2'000;
};

inline const Limits DEFAULT{};

// A full bucket's cap plus its refill over the ladder window.
inline int64_t ladder_budget(const Limits& l) {
    return l.w_full.cap + l.w_full.refill_m * l.ladder_window_ms / 1'000'000;
}

// `l` with every budget divided by `wdiv` and every time by `tdiv` (live-test relays only).
inline Limits scaled(const Limits& l, int64_t wdiv, int64_t tdiv) {
    Limits o = l;
    if (wdiv > 1) {
        for (Rates* r : {&o.w_full, &o.w_fetch, &o.w_guest, &o.joins_full, &o.joins_fetch, &o.joins_guest,
                         &o.allowance, &o.pool}) {
            r->start = std::max<int64_t>(r->start / wdiv, 1);
            r->cap = std::max<int64_t>(r->cap / wdiv, 1);
            r->refill_m = std::max<int64_t>(r->refill_m / wdiv, 1);
        }
        o.w_floor = std::max<int64_t>(o.w_floor / wdiv, 1);
        o.w_low = std::max<int64_t>(o.w_low / wdiv, 1);
        o.debt_floor /= wdiv;
        o.distinct = std::max<int64_t>(o.distinct / wdiv, 2);
        o.pace_reserve = std::max<int64_t>(o.pace_reserve / wdiv, 1);
    }
    if (tdiv > 1) {
        for (auto& ms : o.ladder_ms) ms = std::max<int64_t>(ms / tdiv, 1);
        o.ladder_forget_ms = std::max<int64_t>(o.ladder_forget_ms / tdiv, 1);
        o.ladder_window_ms = std::max<int64_t>(o.ladder_window_ms / tdiv, LADDER_SLOTS);
        o.socket_pause_ms = std::max<int64_t>(o.socket_pause_ms / tdiv, 1);
        o.fresh_window_ms = std::max<int64_t>(o.fresh_window_ms / tdiv, 1);
        o.clean_seen_ms = std::max<int64_t>(o.clean_seen_ms / tdiv, 1);
        o.pause_slack_ms = std::max<int64_t>(o.pause_slack_ms / tdiv, 1);
    }
    return o;
}

// A bucket in millionths of a unit, so 0.1 joins/s refills exactly. Never below `floor`.
class Bucket {
public:
    void start(int64_t level, int64_t now_ms) {
        u_ = level * M;
        last_ms_ = now_ms;
    }
    void refill(int64_t now_ms, const Rates& r) {
        if (now_ms <= last_ms_) return;
        // Ten days of refill fills any bucket: the cap keeps the product far from overflow.
        const int64_t elapsed = std::min<int64_t>(now_ms - last_ms_, 864'000'000);
        u_ = std::min(u_ + elapsed * r.refill_m, r.cap * M);
        last_ms_ = now_ms;
    }
    // Whole units, rounded down (a level in debt rounds away from zero).
    int64_t level() const { return u_ >= 0 ? u_ / M : -((-u_ + M - 1) / M); }
    void spend(int64_t units, int64_t floor) { u_ = std::max(u_ - units * M, floor * M); }
    void add(int64_t units, const Rates& r) { u_ = std::min(u_ + units * M, r.cap * M); }
    // Milliseconds until the level reaches `target` at `r`'s refill.
    int64_t ms_until(int64_t target, const Rates& r) const {
        const int64_t need = target * M - u_;
        if (need <= 0 || r.refill_m <= 0) return 0;
        return (need + r.refill_m - 1) / r.refill_m;
    }

private:
    static constexpr int64_t M = 1'000'000;
    int64_t u_ = 0;
    int64_t last_ms_ = 0;
};

// What one fan-out costs: each receiving group pays at most SHARE_CAP.
class Tally {
public:
    void add(uint64_t group) { groups_.push_back(group); }
    size_t deliveries() const { return groups_.size(); }
    int64_t cost(int64_t cap = SHARE_CAP) {
        std::sort(groups_.begin(), groups_.end());
        int64_t total = 0;
        for (size_t i = 0; i < groups_.size();) {
            size_t j = i;
            while (j < groups_.size() && groups_[j] == groups_[i]) j++;
            total += std::min<int64_t>(static_cast<int64_t>(j - i), cap);
            i = j;
        }
        return total;
    }

private:
    std::vector<uint64_t> groups_;
};

// Distinct deposit targets of one payer in a sliding window of DISTINCT_MINUTES minutes,
// in a fixed size: the first SMALL targets exactly, then a HyperLogLog (p = 10) per minute,
// whose union is the estimate (sketches merge; a sliding HLL does not exist). A known
// target counts once. Keys must already be uniform 64-bit hashes.
class Distinct {
public:
    // Whether adding `key` at `now_ms` would put the window at `limit` or more.
    bool would_reach(uint64_t key, int64_t now_ms, int64_t limit) {
        roll(now_ms);
        if (!big_) {
            if (known_small(key)) return false;
            return static_cast<int64_t>(n_) + 1 >= limit;
        }
        int64_t bound = 1;
        for (size_t i = 0; i < SLOTS; i++) bound += slot_bound(i);
        if (bound < limit) return false;
        // A sketch cannot tell a known target from a new one: past the limit every
        // stranger deposit trips (the client stops new targets far below it).
        return hll_estimate(merge()) + 1 >= static_cast<double>(limit);
    }
    void add(uint64_t key, int64_t now_ms) {
        roll(now_ms);
        const int64_t m = minute(now_ms);
        if (!big_) {
            for (uint8_t i = 0; i < n_; i++) {
                if (small_[i].key == key) {
                    small_[i].minute = m;
                    return;
                }
            }
            if (n_ < SMALL) {
                small_[n_++] = Seen{key, m};
                return;
            }
            big_ = std::make_unique<Sketch>();
            for (uint8_t i = 0; i < n_; i++) put_big(small_[i].key, small_[i].minute);
            n_ = 0;
        }
        put_big(key, m);
    }
    double estimate(int64_t now_ms) {
        roll(now_ms);
        if (!big_) return static_cast<double>(n_);
        return hll_estimate(merge());
    }
    // Whether the window is empty at `now_ms` (the book forgets it).
    bool idle(int64_t now_ms) {
        roll(now_ms);
        if (!big_) return n_ == 0;
        for (int64_t m : big_->minute) {
            if (m != -1) return false;
        }
        return true;
    }
    // Heap and inline bytes this tracker holds.
    size_t bytes() const { return sizeof(Distinct) + (big_ ? sizeof(Sketch) : 0); }

private:
    static constexpr size_t REGISTERS = 1024;
    static constexpr size_t SLOTS = static_cast<size_t>(DISTINCT_MINUTES);
    static constexpr uint8_t SMALL = 16;
    struct Seen {
        uint64_t key = 0;
        int64_t minute = -1;
    };
    struct Sketch {
        std::array<int64_t, SLOTS> minute;
        std::array<int64_t, SLOTS> bound;
        std::array<std::array<uint8_t, REGISTERS>, SLOTS> regs{};
        Sketch() {
            minute.fill(-1);
            bound.fill(0);
        }
    };

    static int64_t minute(int64_t now_ms) { return now_ms / 60'000; }
    static size_t slot_of(int64_t m) { return static_cast<size_t>(m % DISTINCT_MINUTES); }

    void roll(int64_t now_ms) {
        const int64_t m = minute(now_ms);
        if (!big_) {
            uint8_t kept = 0;
            for (uint8_t i = 0; i < n_; i++) {
                if (small_[i].minute > m - DISTINCT_MINUTES) small_[kept++] = small_[i];
            }
            n_ = kept;
            return;
        }
        for (size_t i = 0; i < SLOTS; i++) {
            if (big_->minute[i] != -1 && big_->minute[i] <= m - DISTINCT_MINUTES) clear_slot(i);
        }
    }
    void clear_slot(size_t i) {
        big_->minute[i] = -1;
        big_->bound[i] = 0;
        big_->regs[i].fill(0);
    }
    bool known_small(uint64_t key) const {
        for (uint8_t i = 0; i < n_; i++) {
            if (small_[i].key == key) return true;
        }
        return false;
    }
    void put_big(uint64_t key, int64_t m) {
        const size_t i = slot_of(m);
        if (big_->minute[i] != m) {
            clear_slot(i);
            big_->minute[i] = m;
        }
        const auto [idx, rho] = place(key);
        if (big_->regs[i][idx] < rho) {
            big_->regs[i][idx] = rho;
            big_->bound[i] = 0;
        }
    }
    // A slot's own estimate, padded: the window cannot reach a limit above their sum.
    int64_t slot_bound(size_t i) {
        if (big_->minute[i] == -1) return 0;
        if (big_->bound[i] == 0) {
            big_->bound[i] = static_cast<int64_t>(std::ceil(hll_estimate(big_->regs[i]) * 1.05)) + 1;
        }
        return big_->bound[i];
    }
    std::array<uint8_t, REGISTERS> merge() const {
        std::array<uint8_t, REGISTERS> out{};
        for (size_t s = 0; s < SLOTS; s++) {
            if (big_->minute[s] == -1) continue;
            for (size_t i = 0; i < REGISTERS; i++) out[i] = std::max(out[i], big_->regs[s][i]);
        }
        return out;
    }
    static std::pair<size_t, uint8_t> place(uint64_t key) {
        const size_t idx = static_cast<size_t>(key >> 54);
        const uint64_t rest = key << 10;
        const uint8_t rho = rest == 0 ? 55 : static_cast<uint8_t>(__builtin_clzll(rest) + 1);
        return {idx, rho};
    }
    static double hll_estimate(const std::array<uint8_t, REGISTERS>& regs) {
        const double m = static_cast<double>(REGISTERS);
        double sum = 0;
        size_t zeros = 0;
        static const std::array<double, 65> inverse = [] {
            std::array<double, 65> t{};
            for (size_t i = 0; i < t.size(); i++) t[i] = std::ldexp(1.0, -static_cast<int>(i));
            return t;
        }();
        for (uint8_t r : regs) {
            sum += inverse[std::min<size_t>(r, 64)];
            zeros += r == 0;
        }
        const double alpha = 0.7213 / (1.0 + 1.079 / m);
        double e = alpha * m * m / sum;
        if (e <= 2.5 * m && zeros > 0) e = m * std::log(m / static_cast<double>(zeros));
        return e;
    }

    std::array<Seen, SMALL> small_{};
    uint8_t n_ = 0;
    std::unique_ptr<Sketch> big_;
};

// Every payer's stranger tracker, in one table with a byte budget (HIGH 1 of the G2 code
// review): each tracker is charged to its payer's address share, and a full table evicts
// the heaviest share's least recently used tracker. An evicted payer counts its strangers
// afresh, so a flood forgets its own counts first; its W still pays for every deposit.
class StrangerBook {
public:
    // What an entry costs beyond its tracker: its map node and its FairShare bookkeeping.
    static constexpr size_t ENTRY_OVERHEAD = 256;

    explicit StrangerBook(size_t budget = STRANGER_BYTES) : budget_(budget) {}

    bool would_reach(uint64_t payer, uint64_t key, int64_t now_ms, int64_t limit) {
        auto it = trackers_.find(payer);
        if (it == trackers_.end()) return 1 >= limit;
        return it->second.would_reach(key, now_ms, limit);
    }
    void add(uint64_t payer, uint64_t share, uint64_t key, int64_t now_ms) {
        auto [it, fresh] = trackers_.try_emplace(payer);
        it->second.add(key, now_ms);
        const size_t weight = it->second.bytes() + ENTRY_OVERHEAD;
        if (fresh || table_.share_of(payer) != share) {
            table_.put(payer, share, weight);
        } else {
            table_.reweigh(payer, weight);
            table_.touch(payer);
        }
        while (table_.total() > budget_) {
            auto victim = table_.victim_except(payer);
            if (!victim) break;
            trackers_.erase(*victim);
            table_.remove(*victim);
        }
    }
    // A payer starting over (a fresh session) counts from nothing, as its pacer does.
    void forget(uint64_t payer) {
        trackers_.erase(payer);
        table_.remove(payer);
    }
    // Forgets every tracker whose window is empty.
    void sweep(int64_t now_ms) {
        for (auto it = trackers_.begin(); it != trackers_.end();) {
            if (it->second.idle(now_ms)) {
                table_.remove(it->first);
                it = trackers_.erase(it);
            } else {
                ++it;
            }
        }
    }
    double estimate(uint64_t payer, int64_t now_ms) {
        auto it = trackers_.find(payer);
        return it == trackers_.end() ? 0 : it->second.estimate(now_ms);
    }
    size_t bytes() const { return table_.total(); }
    size_t size() const { return trackers_.size(); }

private:
    size_t budget_;
    std::unordered_map<uint64_t, Distinct> trackers_;
    FairShare<uint64_t> table_;
};

enum class Kind : uint8_t { Full, Fetch, Guest };

// What a payer spent over the last ladder window, in LADDER_SLOTS slots. The sum covers at
// most one window, so an honest bucket never exceeds ladder_budget() in it.
class RecentSpend {
public:
    void add(int64_t w, int64_t now_ms, const Limits& l) {
        const int64_t idx = now_ms / slot_ms(l);
        Slot& s = slots_[static_cast<size_t>(idx % LADDER_SLOTS)];
        if (s.idx != idx) s = Slot{idx, 0};
        s.w += w;
    }
    int64_t sum(int64_t now_ms, const Limits& l) const {
        const int64_t idx = now_ms / slot_ms(l);
        int64_t total = 0;
        for (const Slot& s : slots_) {
            if (s.idx >= 0 && s.idx <= idx && idx - s.idx < LADDER_SLOTS) total += s.w;
        }
        return total;
    }

private:
    struct Slot {
        int64_t idx = -1;
        int64_t w = 0;
    };
    static int64_t slot_ms(const Limits& l) { return std::max<int64_t>(l.ladder_window_ms / LADDER_SLOTS, 1); }
    std::array<Slot, LADDER_SLOTS> slots_{};
};

// One payer's buckets: a device's session, or a socket without one.
struct Account {
    bool ready = false;
    Kind kind = Kind::Full;
    Bucket w;
    Bucket joins;
    int64_t start_credit = 0;
    // Everything charged since the start (the live tests read it).
    int64_t spent = 0;
    RecentSpend recent;
    // Shadow mode: a would-be pause runs until then, its trip already counted.
    int64_t shadow_until_ms = 0;
    // Tripped (or would have, in shadow mode) since the start: not a clean session.
    bool tripped = false;

    const Rates& w_rates(const Limits& l) const {
        return kind == Kind::Full ? l.w_full : kind == Kind::Fetch ? l.w_fetch : l.w_guest;
    }
    const Rates& join_rates(const Limits& l) const {
        return kind == Kind::Full ? l.joins_full : kind == Kind::Fetch ? l.joins_fetch : l.joins_guest;
    }

    // `credit` is the W start (the fresh-start tier for a full payer).
    void begin(Kind k, int64_t credit, int64_t now_ms, const Limits& l) {
        kind = k;
        ready = true;
        start_credit = credit;
        spent = 0;
        recent = RecentSpend{};
        w.start(credit, now_ms);
        joins.start(join_rates(l).start, now_ms);
        shadow_until_ms = 0;
        tripped = false;
    }
    void refill(int64_t now_ms, const Limits& l) {
        w.refill(now_ms, w_rates(l));
        joins.refill(now_ms, join_rates(l));
    }
    // Every W charge goes through here, so the ladder window sees it.
    void spend_w(int64_t units, int64_t now_ms, const Limits& l) {
        w.spend(units, l.debt_floor);
        spent += units;
        recent.add(units, now_ms, l);
    }
};

// What the relay predicts one inbound frame costs, judged before the frame is counted.
struct Plan {
    // The W the frame is judged against (1 for the frame itself included).
    int64_t w = 2;
    // The handler runs uncharged and exactly `w` is charged: a fan-out whose walk used the
    // delivery predicate itself.
    bool exact = false;
    bool join = false;
    // hb, ack, inactive, active, end: charged, never tripped.
    bool control = false;
    // A deposit to a stranger, by the target's hash.
    std::optional<uint64_t> stranger;
    // A public frame's deliveries to sockets outside the room's audience, paid from the
    // room's allowance (each group at most SHARE_CAP); what it cannot cover is free.
    int64_t outside = 0;
    // The room whose allowance pays `outside`.
    std::string room;
    // For the memory budget's fan-out admission (track g13w3-oom): live recipients and the
    // bytes of each copy.
    size_t recipients = 0;
    uint64_t frame_bytes = 0;
};

enum class Verdict : uint8_t { Pass, Work, Joins, Distinct };

// The most a frame is judged at: what a pacing client's mirror, held RESERVE above the
// price it waits for, guarantees the bucket holds (LOW 6: a bigger price would wait
// forever, and a bigger judged W would trip forever).
inline int64_t judged_w(const Account& a, int64_t w, const Limits& l) {
    const int64_t cap = a.w_rates(l).cap;
    return std::clamp<int64_t>(w, 0, cap - std::min(l.pace_reserve, cap / 2));
}

// `payer` keys the payer's stranger tracker in `strangers`.
inline Verdict judge(Account& a, const Plan& p, int64_t now_ms, const Limits& l, StrangerBook& strangers,
                     uint64_t payer) {
    a.refill(now_ms, l);
    if (p.control) return Verdict::Pass;
    if (p.join && a.joins.level() < 1) return Verdict::Joins;
    if (p.stranger && strangers.would_reach(payer, *p.stranger, now_ms, l.distinct)) return Verdict::Distinct;
    if (a.w.level() - judged_w(a, p.w, l) < 0) return Verdict::Work;
    return Verdict::Pass;
}

// Charge what a handled frame cost. A level never goes below the debt floor; the next
// counted frame then trips. `share` is the payer's address share (socket_share).
inline void charge(Account& a, int64_t w, const Plan& p, int64_t now_ms, const Limits& l, StrangerBook& strangers,
                   uint64_t payer, uint64_t share) {
    a.spend_w(w, now_ms, l);
    if (p.join) a.joins.spend(1, 0);
    if (p.stranger) strangers.add(payer, share, *p.stranger, now_ms);
}

// Device cooldowns: the ladder per device key, with lazy forgetting. Bounded and fair:
// a full table evicts from the address share (socket_share) whose trips hold the most.
class CooldownBook {
public:
    // The cooldown left for `device`, 0 when none; forgets an entry that is over.
    int64_t remaining_ms(uint64_t device, int64_t now_ms, const Limits& l) {
        auto it = entries_.find(device);
        if (it == entries_.end()) return 0;
        if (it->second.until_ms > now_ms) return it->second.until_ms - now_ms;
        if (level_now(it->second, now_ms, l) == 0) erase(it);
        return 0;
    }
    // A trip of `device` that steps the ladder: the cooldown it starts.
    int64_t step(uint64_t device, uint64_t share, int64_t now_ms, const Limits& l) {
        auto [it, fresh] = entries_.try_emplace(device);
        Entry& e = it->second;
        const int level = fresh ? 0 : level_now(e, now_ms, l);
        e.level = static_cast<uint8_t>(std::min<int>(level + 1, static_cast<int>(l.ladder_ms.size())));
        e.last_trip_ms = now_ms;
        e.until_ms = now_ms + l.ladder_ms[e.level - 1];
        table_.put(device, share, 1);
        while (table_.size() > TABLE_MAX) {
            auto victim = table_.victim_except(device);
            if (!victim) break;
            entries_.erase(*victim);
            table_.remove(*victim);
        }
        return l.ladder_ms[e.level - 1];
    }
    int level(uint64_t device, int64_t now_ms, const Limits& l) const {
        auto it = entries_.find(device);
        return it == entries_.end() ? 0 : level_now(it->second, now_ms, l);
    }
    // Forgets every entry at level 0 and out of its cooldown.
    void sweep(int64_t now_ms, const Limits& l) {
        for (auto it = entries_.begin(); it != entries_.end();) {
            if (it->second.until_ms <= now_ms && level_now(it->second, now_ms, l) == 0) {
                table_.remove(it->first);
                it = entries_.erase(it);
            } else {
                ++it;
            }
        }
    }
    size_t size() const { return entries_.size(); }

private:
    struct Entry {
        uint8_t level = 0;
        int64_t last_trip_ms = 0;
        int64_t until_ms = 0;
    };
    static int level_now(const Entry& e, int64_t now_ms, const Limits& l) {
        const int64_t quiet = std::max<int64_t>(0, now_ms - e.last_trip_ms);
        const int64_t forgotten = l.ladder_forget_ms > 0 ? quiet / l.ladder_forget_ms : 0;
        return static_cast<int>(std::max<int64_t>(0, e.level - forgotten));
    }
    void erase(std::unordered_map<uint64_t, Entry>::iterator it) {
        table_.remove(it->first);
        entries_.erase(it);
    }

    std::unordered_map<uint64_t, Entry> entries_;
    FairShare<uint64_t> table_;
};

// Devices that held a clean session lately (N6): their fresh starts keep the floor tier
// even from a block that keeps starting sessions (a mobile carrier's /48).
class CleanSeen {
public:
    void note(uint64_t device, uint64_t share, int64_t now_ms) {
        seen_[device] = now_ms;
        table_.put(device, share, 1);
        while (table_.size() > TABLE_MAX) {
            auto victim = table_.victim_except(device);
            if (!victim) break;
            seen_.erase(*victim);
            table_.remove(*victim);
        }
    }
    bool recent(uint64_t device, int64_t now_ms, const Limits& l) const {
        auto it = seen_.find(device);
        return it != seen_.end() && now_ms - it->second < l.clean_seen_ms;
    }
    void forget(uint64_t device) {
        seen_.erase(device);
        table_.remove(device);
    }
    void sweep(int64_t now_ms, const Limits& l) {
        for (auto it = seen_.begin(); it != seen_.end();) {
            if (now_ms - it->second >= l.clean_seen_ms) {
                table_.remove(it->first);
                it = seen_.erase(it);
            } else {
                ++it;
            }
        }
    }
    size_t size() const { return seen_.size(); }

private:
    std::unordered_map<uint64_t, int64_t> seen_;
    FairShare<uint64_t> table_;
};

// The fresh-start credit of each address block (section 4): degrade, never refuse.
class StartPools {
public:
    // The W start a fresh full session from `block` gets now; `share` is its socket_share.
    int64_t take(uint64_t block, uint64_t share, bool clean_device, int64_t now_ms, const Limits& l) {
        auto [it, fresh] = pools_.try_emplace(block);
        Pool& p = it->second;
        if (fresh) p.credit.start(l.pool.start, now_ms);
        p.credit.refill(now_ms, l.pool);
        while (!p.starts.empty() && now_ms - p.starts.front() >= l.fresh_window_ms) p.starts.pop_front();
        int64_t tier;
        if (p.credit.level() >= l.w_full.start) {
            p.credit.spend(l.w_full.start, 0);
            tier = l.w_full.start;
        } else if (p.starts.size() < l.fresh_floor_starts || clean_device) {
            tier = l.w_floor;
        } else {
            tier = l.w_low;
        }
        p.starts.push_back(now_ms);
        if (p.starts.size() > l.fresh_floor_starts) p.starts.pop_front();
        table_.put(block, share, 1);
        while (table_.size() > TABLE_MAX) {
            auto victim = table_.victim_except(block);
            if (!victim) break;
            pools_.erase(*victim);
            table_.remove(*victim);
        }
        return tier;
    }
    // Forgets a block whose pool is full again and whose window is empty.
    void sweep(int64_t now_ms, const Limits& l) {
        for (auto it = pools_.begin(); it != pools_.end();) {
            Pool& p = it->second;
            p.credit.refill(now_ms, l.pool);
            while (!p.starts.empty() && now_ms - p.starts.front() >= l.fresh_window_ms) p.starts.pop_front();
            if (p.starts.empty() && p.credit.level() >= l.pool.cap) {
                table_.remove(it->first);
                it = pools_.erase(it);
            } else {
                ++it;
            }
        }
    }
    size_t size() const { return pools_.size(); }

private:
    struct Pool {
        Bucket credit;
        std::deque<int64_t> starts;
    };
    std::unordered_map<uint64_t, Pool> pools_;
    FairShare<uint64_t> table_;
};

// A room's allowance for public frames reaching sockets outside its audience (guests,
// non-provers): what a poster's 0x0A pays for them, at most what the allowance holds.
struct Allowance {
    Bucket b;
    bool ready = false;
    // Spends up to `w` now; returns what it covered.
    int64_t cover(int64_t w, int64_t now_ms, const Limits& l) {
        if (!ready) {
            b.start(l.allowance.start, now_ms);
            ready = true;
        }
        b.refill(now_ms, l.allowance);
        const int64_t covered = std::min(std::max<int64_t>(b.level(), 0), w);
        b.spend(covered, 0);
        return covered;
    }
};

// How long a tripped payer waits, and whether its device's ladder stepped.
struct Pause {
    int64_t wait_ms = 0;
    bool ladder = false;
};

// The pause one trip costs. A full payer's ladder steps only when its spend over the last
// ladder window passed what a full honest bucket can pay in it (N2 rule b, over a window so
// a long-lived honest session never climbs); any other trip is a pure pause lasting until
// the bucket can pay for the frame again, plus the slack.
inline Pause pause_for(Account& a, const Plan& p, Verdict v, CooldownBook& book, uint64_t device, uint64_t share,
                       int64_t now_ms, const Limits& l) {
    Pause out;
    if (a.kind != Kind::Full) {
        out.wait_ms = l.socket_pause_ms;
        return out;
    }
    int64_t refill = 0;
    switch (v) {
        case Verdict::Joins:
            refill = a.joins.ms_until(1, a.join_rates(l));
            break;
        case Verdict::Distinct:
            refill = 60'000;
            break;
        default: {
            const Rates& r = a.w_rates(l);
            refill = a.w.ms_until(judged_w(a, p.w, l), r);
            break;
        }
    }
    out.wait_ms = refill + l.pause_slack_ms;
    if (a.recent.sum(now_ms, l) > ladder_budget(l)) {
        out.ladder = true;
        out.wait_ms = std::max(out.wait_ms, book.step(device, share, now_ms, l));
    }
    return out;
}

// --- The process-global work counter (section 1) ---------------------------------
//
// Bumped wherever the relay does work (every socket write, held-ring push, offline
// deposit, signature and door check), so every handler, a future one too, is charged
// without knowing it. Uncharged makes the bumps go nowhere (self-replays, presence the
// breaker charges per room, the trip's own close); Fanout tallies writes per receiving
// group and charges the capped sum when it ends.
inline int64_t g_work = 0;
inline int g_uncharged = 0;
inline Tally* g_fanout = nullptr;

inline void bump(int64_t w) {
    if (g_uncharged == 0) g_work += w;
}

inline void bump_write(uint64_t group) {
    if (g_uncharged != 0) return;
    if (g_fanout) {
        g_fanout->add(group);
    } else {
        g_work += 1;
    }
}

struct Uncharged {
    Uncharged() { g_uncharged++; }
    ~Uncharged() { g_uncharged--; }
    Uncharged(const Uncharged&) = delete;
    Uncharged& operator=(const Uncharged&) = delete;
};

class Fanout {
public:
    Fanout() : prev_(g_fanout) { g_fanout = &tally_; }
    ~Fanout() {
        g_fanout = prev_;
        bump(tally_.cost());
    }
    Fanout(const Fanout&) = delete;
    Fanout& operator=(const Fanout&) = delete;

private:
    Tally tally_;
    Tally* prev_;
};

// The work done while it lives (one per inbound frame).
class Scope {
public:
    Scope() : start_(g_work) {}
    int64_t spent() const { return g_work - start_; }

private:
    int64_t start_;
};

// Anonymous counts of trips, by kind, never ids; nothing reaches disk. In shadow mode
// these are the trips enforcement would have made.
// Coarse totals only: a count split by socket kind or start tier would tell a watcher of a
// small relay more about one person (lead decision 1).
struct Stats {
    uint64_t trips = 0;
    uint64_t ladder_steps = 0;
    uint64_t refused = 0;

    void count_trip(Kind, Verdict, bool ladder) {
        trips++;
        if (ladder) ladder_steps++;
    }
    void count_refusal() { refused++; }
};

inline Stats g_stats;

}  // namespace breaker
