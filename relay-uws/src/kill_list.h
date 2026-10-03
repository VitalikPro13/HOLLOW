#pragma once
#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "fair_share.h"

// Destroy signals parked for devices that are NOT connected, handed over on the
// device's next auth. Header-only and free of uWebSockets so the semantics are
// unit tested standalone (test/test_kill_list.cpp), like offline_index.h.
//
// An order the target identity's own phrase stands behind (kill_order.h) waits in
// that target's PROVEN slot, which only a newer proven order replaces: junk never
// reaches it. Every other blob is opaque to the relay, so one issuer never touches
// another's signal: each holds its own slot per target and the target is handed
// every slot. Caps EVICT, they never refuse (feedback_relay_rules): past its own
// cap the issuer's oldest entry pays, and past a target's or the whole list's cap
// the address share holding the most (fair_share.h) pays. An ack names the issuer
// and the stamp, so turning junk away never takes an order sharing its stamp.
struct KillList {
    using Clock = std::chrono::steady_clock;

    // Opaque to the relay: base64 of the signed payload the target verifies.
    static constexpr size_t MAX_BLOB_BYTES = 2048;
    static constexpr size_t MAX_TARGETS_PER_DEPOSIT = 16;
    static constexpr size_t MAX_ENTRIES_PER_ISSUER = 64;
    // A device's own identity has a handful of siblings; the rest is headroom.
    static constexpr size_t MAX_ISSUERS_PER_TARGET = 8;
    static constexpr size_t MAX_ENTRIES = 10000;
    // Proven slots, list-wide. Only a phrase holder fills one, but phrases are free.
    static constexpr size_t MAX_PROVEN = 10000;
    static constexpr int64_t MAX_AGE_SECS = 365 * 86400;
    // A stamp this far past the relay's clock is refused: dated years ahead, one
    // deposit would outrank every later order from the same issuer.
    static constexpr int64_t MAX_FUTURE_MS = 10 * 60 * 1000;

    struct Entry {
        std::string blob;
        int64_t issued_at_ms = 0;  // the signer's clock: compared, never trusted
        Clock::time_point stored_at{};
        std::string issuer;  // depositing DEVICE id
        uint64_t seq = 0;    // deposit order; the oldest is evicted first
        uint64_t share = 0;  // the depositor's address share
    };

    // target device id -> the signals waiting for it, one per issuer
    std::unordered_map<std::string, std::vector<Entry>> entries;
    // issuer -> the targets it currently holds entries for
    std::unordered_map<std::string, std::unordered_set<std::string>> by_issuer;
    // Every entry by seq, for the list-wide cap.
    FairShare<uint64_t> ledger;
    std::unordered_map<uint64_t, std::string> target_of;
    uint64_t next_seq = 0;
    // target device id -> the newest proven order waiting for it
    std::unordered_map<std::string, Entry> proven;
    FairShare<std::string> proven_ledger;

    size_t size() const { return ledger.size() + proven.size(); }

    size_t issuer_count(const std::string& issuer) const {
        auto it = by_issuer.find(issuer);
        return it == by_issuer.end() ? 0 : it->second.size();
    }

    // Delivery reads; only an ack removes, so an undelivered signal survives a
    // socket that dropped before it could act on it.
    const std::vector<Entry>* find(const std::string& target) const {
        auto it = entries.find(target);
        return it == entries.end() ? nullptr : &it->second;
    }

    const Entry* find_proven(const std::string& target) const {
        auto it = proven.find(target);
        return it == proven.end() ? nullptr : &it->second;
    }

    // Everything the target is handed on auth, its proven order first.
    std::vector<const Entry*> waiting(const std::string& target) const {
        std::vector<const Entry*> out;
        if (const Entry* p = find_proven(target)) out.push_back(p);
        if (const auto* list = find(target)) {
            for (const auto& e : *list) out.push_back(&e);
        }
        return out;
    }

    // True when the signal was stored. A blob past the ceiling, a stamp past the
    // clock bound, and a re-deposit by the same issuer that is not strictly newer
    // are the only "no"s a caller can produce.
    bool deposit(const std::string& target, const std::string& issuer, uint64_t share,
                 const std::string& blob, int64_t issued_at_ms, Clock::time_point now,
                 int64_t now_wall_ms) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return false;
        if (issued_at_ms > now_wall_ms + MAX_FUTURE_MS) return false;
        if (const Entry* own = slot(target, issuer); own && issued_at_ms <= own->issued_at_ms) {
            return false;
        }
        insert(target, issuer, share, blob, issued_at_ms, now);
        return true;
    }

    // An order the caller proved is the target identity's own (kill_order.h). It
    // replaces the target's proven order only when strictly newer, and no opaque
    // deposit can evict it.
    bool deposit_proven(const std::string& target, const std::string& issuer, uint64_t share,
                        const std::string& blob, int64_t issued_at_ms, Clock::time_point now,
                        int64_t now_wall_ms) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return false;
        if (issued_at_ms > now_wall_ms + MAX_FUTURE_MS) return false;
        if (const Entry* held = find_proven(target); held && issued_at_ms <= held->issued_at_ms) return false;
        insert_proven(target, issuer, share, blob, issued_at_ms, now);
        return true;
    }

    // Restore from a snapshot. Pass entries oldest first so deposit order, and
    // with it eviction order, survives the restart.
    void restore(const std::string& target, const std::string& issuer, uint64_t share,
                 const std::string& blob, int64_t issued_at_ms, Clock::time_point stored_at) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return;
        insert(target, issuer, share, blob, issued_at_ms, stored_at);
    }

    void restore_proven(const std::string& target, const std::string& issuer, uint64_t share,
                        const std::string& blob, int64_t issued_at_ms, Clock::time_point stored_at) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return;
        insert_proven(target, issuer, share, blob, issued_at_ms, stored_at);
    }

    // The target's own bare ack, after its wipe: every signal waiting for it.
    bool ack(const std::string& target) {
        bool any = drop_proven(target);
        auto it = entries.find(target);
        if (it == entries.end()) return any;
        for (const auto& e : it->second) forget(e, target);
        entries.erase(it);
        return true;
    }

    // The target's ack for the one signal it turned away.
    bool ack(const std::string& target, const std::string& issuer, int64_t issued_at_ms) {
        bool any = false;
        if (const Entry* p = find_proven(target); p && p->issuer == issuer && p->issued_at_ms == issued_at_ms) {
            any = drop_proven(target);
        }
        return remove_if(target, [&](const Entry& e) {
                   return e.issuer == issuer && e.issued_at_ms == issued_at_ms;
               }) ||
               any;
    }

    size_t sweep(Clock::time_point now) {
        auto aged = [&](const Entry& e) {
            return std::chrono::duration_cast<std::chrono::seconds>(now - e.stored_at).count() >= MAX_AGE_SECS;
        };
        size_t dropped = 0;
        std::vector<std::string> targets;
        for (const auto& [target, list] : entries) targets.push_back(target);
        for (const auto& [target, e] : proven) {
            if (aged(e)) targets.push_back(target);
        }
        for (const auto& target : targets) {
            size_t before = size();
            remove_if(target, aged);
            if (const Entry* p = find_proven(target); p && aged(*p)) drop_proven(target);
            dropped += before - size();
        }
        return dropped;
    }

   private:
    const Entry* slot(const std::string& target, const std::string& issuer) const {
        auto it = entries.find(target);
        if (it == entries.end()) return nullptr;
        for (const auto& e : it->second) {
            if (e.issuer == issuer) return &e;
        }
        return nullptr;
    }

    template <typename Pred>
    bool remove_if(const std::string& target, Pred pred) {
        auto it = entries.find(target);
        if (it == entries.end()) return false;
        auto& list = it->second;
        size_t before = list.size();
        for (auto e = list.begin(); e != list.end();) {
            if (pred(*e)) {
                forget(*e, target);
                e = list.erase(e);
            } else {
                ++e;
            }
        }
        size_t removed = before - list.size();
        if (list.empty()) entries.erase(it);
        return removed > 0;
    }

    void insert(const std::string& target, const std::string& issuer, uint64_t share,
                const std::string& blob, int64_t issued_at_ms, Clock::time_point at) {
        remove_if(target, [&](const Entry& e) { return e.issuer == issuer; });
        if (issuer_count(issuer) >= MAX_ENTRIES_PER_ISSUER) evict_oldest_of(issuer);
        if (auto it = entries.find(target); it != entries.end() && it->second.size() >= MAX_ISSUERS_PER_TARGET) {
            evict_heaviest_at(target);
        }
        while (ledger.size() >= MAX_ENTRIES) {
            auto victim = ledger.victim();
            if (!victim) break;
            // A copy: dropping the entry erases the string `target_of` holds.
            const std::string victim_target = target_of.at(*victim);
            drop(victim_target, *victim);
        }
        uint64_t seq = ++next_seq;
        entries[target].push_back(Entry{blob, issued_at_ms, at, issuer, seq, share});
        by_issuer[issuer].insert(target);
        ledger.put(seq, share, 1);
        target_of.emplace(seq, target);
    }

    void insert_proven(const std::string& target, const std::string& issuer, uint64_t share,
                       const std::string& blob, int64_t issued_at_ms, Clock::time_point at) {
        proven[target] = Entry{blob, issued_at_ms, at, issuer, ++next_seq, share};
        proven_ledger.put(target, share, 1);
        while (proven_ledger.size() > MAX_PROVEN) {
            auto victim = proven_ledger.victim();
            if (!victim) break;
            // A copy: dropping the slot erases the key `victim` names.
            const std::string victim_target = *victim;
            drop_proven(victim_target);
        }
    }

    bool drop_proven(const std::string& target) {
        proven_ledger.remove(target);
        return proven.erase(target) != 0;
    }

    void forget(const Entry& e, const std::string& target) {
        ledger.remove(e.seq);
        target_of.erase(e.seq);
        auto it = by_issuer.find(e.issuer);
        if (it == by_issuer.end()) return;
        it->second.erase(target);
        if (it->second.empty()) by_issuer.erase(it);
    }

    void drop(const std::string& target, uint64_t seq) {
        remove_if(target, [seq](const Entry& e) { return e.seq == seq; });
    }

    // A full target drops the oldest entry of the share holding the most of its
    // slots; among equals, the oldest entry.
    void evict_heaviest_at(const std::string& target) {
        auto it = entries.find(target);
        if (it == entries.end() || it->second.empty()) return;
        std::unordered_map<uint64_t, size_t> held;
        size_t most = 0;
        for (const auto& e : it->second) most = std::max(most, ++held[e.share]);
        const Entry* victim = nullptr;
        for (const auto& e : it->second) {
            if (held[e.share] == most && (!victim || e.seq < victim->seq)) victim = &e;
        }
        drop(target, victim->seq);
    }

    void evict_oldest_of(const std::string& issuer) {
        auto it = by_issuer.find(issuer);
        if (it == by_issuer.end()) return;
        std::string oldest;
        uint64_t best = UINT64_MAX;
        for (const auto& target : it->second) {
            if (const Entry* e = slot(target, issuer); e && e->seq < best) {
                best = e->seq;
                oldest = target;
            }
        }
        if (!oldest.empty()) drop(oldest, best);
    }
};
