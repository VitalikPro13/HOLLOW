#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>

// Fair-share bookkeeping for the offline buffer (RELAY-1). Header-only and
// storage-agnostic so it can be unit tested without a relay
// (test/test_relay_validators.cpp).
//
// Two jobs, both O(1) amortised, because both run on the event loop:
//
//  1. EVICTION INDEX. `order` is the insertion order of every buffered frame,
//     DM and topic alike. The byte-budget evictor pops its front and drops that
//     queue's front only when the stamped `seq` still matches; a mismatch means
//     the frame already left by delivery, expiry or a per-kind cap, so the ref
//     is stale and is skipped. Same oldest-first semantics as the old
//     scan-every-queue-per-drop loop, without the scan. Sequence numbers are
//     never reused, so a stale ref can never collide with a later frame.
//
//  2. KEY ACCOUNTING. `holders` / `targets` / `touch_order` answer "how many
//     distinct offline targets does this sender hold deposits for, and which of
//     them did it touch first". That is what makes the key cap FAIR: a sender
//     past the cap frees one of its OWN oldest targets, so a flooder evicts
//     only itself. Nothing in here can refuse a deposit — `plan()` returns who
//     pays, never "no".
//
// `holders` doubles as the authoritative set of offline_buffer keys, so
// key_count() is the live key total and holders.count(t) answers "is this a new
// key". Keeping that exact is why every path that removes an entry must call
// released_dm()/released_topic() — the enumeration lives in ws_handler.cpp.
struct OfflineIndex {
    struct EvictRef {
        std::string key;   // offline_buffer target, or a topic_buffers key
        uint64_t seq = 0;
        bool is_topic = false;
    };

    // Who pays for admitting a deposit that would create a new buffer key.
    // Never "reject": refusing a deposit is the message-loss class of bug the
    // relay does not introduce (feedback_relay_rules).
    enum class Admit {
        Ok,               // room to spare
        FreeOwnOldest,    // the sender is past its own share: free ITS oldest target
        FreeGlobalOldest  // global backstop, and this sender holds nothing else
    };

    uint64_t next_seq = 0;
    size_t live = 0;                 // frames currently buffered (DM + topic)
    std::deque<EvictRef> order;      // oldest first

    // target -> sender -> how many of that sender's frames are pending there
    std::unordered_map<std::string, std::unordered_map<std::string, size_t>> holders;
    // sender -> the targets it currently holds deposits for
    std::unordered_map<std::string, std::unordered_set<std::string>> targets;
    // sender -> those targets in first-touched order (pruned lazily on read)
    std::unordered_map<std::string, std::deque<std::string>> touch_order;

    uint64_t stamp_topic(const std::string& key) {
        uint64_t seq = ++next_seq;
        order.push_back(EvictRef{key, seq, true});
        live++;
        return seq;
    }

    uint64_t stamp_dm(const std::string& target, const std::string& sender) {
        uint64_t seq = ++next_seq;
        order.push_back(EvictRef{target, seq, false});
        live++;
        auto& n = holders[target][sender];
        if (n == 0) {
            targets[sender].insert(target);
            touch_order[sender].push_back(target);
        }
        n++;
        return seq;
    }

    void released_topic() {
        if (live) live--;
    }

    void released_dm(const std::string& target, const std::string& sender) {
        if (live) live--;
        auto tit = holders.find(target);
        if (tit == holders.end()) return;
        auto sit = tit->second.find(sender);
        if (sit == tit->second.end()) return;
        if (sit->second > 1) {
            sit->second--;
            return;
        }
        tit->second.erase(sit);
        if (tit->second.empty()) holders.erase(tit);
        auto st = targets.find(sender);
        if (st != targets.end()) {
            st->second.erase(target);
            if (st->second.empty()) {
                targets.erase(st);
                touch_order.erase(sender);
            }
        }
    }

    size_t key_count() const { return holders.size(); }

    size_t target_count(const std::string& sender) const {
        auto it = targets.find(sender);
        return it == targets.end() ? 0 : it->second.size();
    }

    bool holds(const std::string& sender, const std::string& target) const {
        auto it = targets.find(sender);
        return it != targets.end() && it->second.count(target) != 0;
    }

    bool has_key(const std::string& target) const {
        return holders.count(target) != 0;
    }

    // The sender's first-touched target that it STILL holds, or "" when it
    // holds none. Drains fronts the sender has already emptied, so the deque
    // never outgrows the target set it shadows.
    std::string oldest_target(const std::string& sender) {
        auto oit = touch_order.find(sender);
        if (oit == touch_order.end()) return {};
        auto& fifo = oit->second;
        while (!fifo.empty() && !holds(sender, fifo.front())) fifo.pop_front();
        if (fifo.empty()) {
            touch_order.erase(oit);
            return {};
        }
        return fifo.front();
    }

    // Who pays for this deposit. Pure: it decides nothing about the frame
    // itself, only about which EXISTING entries make room for a new key.
    Admit plan(const std::string& sender, const std::string& target,
               size_t max_targets_per_sender, size_t max_keys) const {
        if (!holds(sender, target) &&
            target_count(sender) >= max_targets_per_sender) {
            // Past its own share. target_count is already >= the cap here, so
            // this sender demonstrably holds more than one target and freeing
            // its oldest can never be "the deposit of a single-target sender".
            return Admit::FreeOwnOldest;
        }
        if (!has_key(target) && key_count() >= max_keys) {
            // A sender that already holds other targets pays for its own
            // expansion; one whose only pending target is this one must not be
            // made to drop its single conversation, so the backstop falls back
            // to the globally oldest deposit.
            return target_count(sender) >= 2 ? Admit::FreeOwnOldest
                                             : Admit::FreeGlobalOldest;
        }
        return Admit::Ok;
    }

    // Drop refs whose frame has already left the buffer. `alive(ref)` answers
    // "does the queue named by ref.key still have this exact seq at its front".
    // Without this `order` would grow by one entry per deposit forever, since
    // delivery and expiry take frames out from under it: a leak in the shape of
    // the leak this whole index exists to close.
    template <class AliveFn>
    void compact(AliveFn alive) {
        std::deque<EvictRef> kept;
        for (auto& r : order) {
            if (alive(r)) kept.push_back(std::move(r));
        }
        order.swap(kept);
    }

    // Compact when the stale refs outnumber the live frames. The +1024 floor
    // keeps a near-empty buffer from compacting on every deposit.
    bool needs_compaction() const { return order.size() > 2 * live + 1024; }
};
