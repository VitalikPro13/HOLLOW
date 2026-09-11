#pragma once
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>

// Destroy signals parked for devices that are NOT connected. The relay is a
// courier and nothing else: the blob is opaque (a master-signed payload it
// cannot read), the master, the reason and the plaintext never reach it, and
// the only thing it knows is which device id to hand the blob to on that
// device's next auth. Header-only and free of uWebSockets so the semantics are
// unit tested standalone (test/test_kill_list.cpp), like offline_index.h.
//
// Caps EVICT, they never refuse (feedback_relay_rules): past its share the
// issuer's OWN oldest entry pays, so a flooder only ever evicts itself.
struct KillList {
    using Clock = std::chrono::steady_clock;

    // Opaque to the relay: base64 of the signed payload the target verifies.
    static constexpr size_t MAX_BLOB_BYTES = 2048;
    static constexpr size_t MAX_TARGETS_PER_DEPOSIT = 16;
    static constexpr size_t MAX_ENTRIES_PER_ISSUER = 64;
    static constexpr size_t MAX_ENTRIES = 10000;
    static constexpr int64_t MAX_AGE_SECS = 365 * 86400;

    struct Entry {
        std::string blob;
        int64_t issued_at_ms = 0;  // the signer's clock: compared, never trusted
        Clock::time_point stored_at{};
        std::string issuer;  // depositing DEVICE id
        uint64_t seq = 0;    // deposit order; the oldest is evicted first
    };

    // target device id -> the one signal waiting for it
    std::unordered_map<std::string, Entry> entries;
    // issuer -> the targets it currently holds entries for
    std::unordered_map<std::string, std::unordered_set<std::string>> by_issuer;
    uint64_t next_seq = 0;

    size_t size() const { return entries.size(); }

    size_t issuer_count(const std::string& issuer) const {
        auto it = by_issuer.find(issuer);
        return it == by_issuer.end() ? 0 : it->second.size();
    }

    // Delivery reads; only an ack removes, so an undelivered signal survives a
    // socket that dropped before it could act on it.
    const Entry* find(const std::string& target) const {
        auto it = entries.find(target);
        return it == entries.end() ? nullptr : &it->second;
    }

    // True when the signal was stored. A blob past the ceiling and a deposit
    // that is not strictly newer than the one already waiting are the only
    // "no"s a caller can produce.
    bool deposit(const std::string& target, const std::string& issuer,
                 const std::string& blob, int64_t issued_at_ms, Clock::time_point now) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return false;
        auto it = entries.find(target);
        if (it != entries.end() && issued_at_ms <= it->second.issued_at_ms) return false;
        insert(target, issuer, blob, issued_at_ms, now);
        return true;
    }

    // Restore from a snapshot. Pass entries oldest first so deposit order, and
    // with it eviction order, survives the restart.
    void restore(const std::string& target, const std::string& issuer,
                 const std::string& blob, int64_t issued_at_ms, Clock::time_point stored_at) {
        if (target.empty() || blob.empty() || blob.size() > MAX_BLOB_BYTES) return;
        insert(target, issuer, blob, issued_at_ms, stored_at);
    }

    // The target's own ack, and the only removal a client can ask for.
    bool ack(const std::string& target) {
        auto it = entries.find(target);
        if (it == entries.end()) return false;
        detach(it->second.issuer, target);
        entries.erase(it);
        return true;
    }

    size_t sweep(Clock::time_point now) {
        size_t dropped = 0;
        for (auto it = entries.begin(); it != entries.end();) {
            auto age = std::chrono::duration_cast<std::chrono::seconds>(now - it->second.stored_at).count();
            if (age >= MAX_AGE_SECS) {
                detach(it->second.issuer, it->first);
                it = entries.erase(it);
                dropped++;
            } else {
                ++it;
            }
        }
        return dropped;
    }

   private:
    void insert(const std::string& target, const std::string& issuer,
                const std::string& blob, int64_t issued_at_ms, Clock::time_point at) {
        auto it = entries.find(target);
        if (it != entries.end()) {
            detach(it->second.issuer, target);
            entries.erase(it);
        }
        if (issuer_count(issuer) >= MAX_ENTRIES_PER_ISSUER) evict_oldest_of(issuer);
        if (entries.size() >= MAX_ENTRIES) evict_oldest();
        entries[target] = Entry{blob, issued_at_ms, at, issuer, ++next_seq};
        by_issuer[issuer].insert(target);
    }

    void detach(const std::string& issuer, const std::string& target) {
        auto it = by_issuer.find(issuer);
        if (it == by_issuer.end()) return;
        it->second.erase(target);
        if (it->second.empty()) by_issuer.erase(it);
    }

    // Both scans are bounded by MAX_ENTRIES and run only when a cap is already
    // reached, which costs less than keeping an eviction index exact.
    void evict_oldest() {
        std::string oldest;
        uint64_t best = UINT64_MAX;
        for (const auto& [target, e] : entries) {
            if (e.seq < best) {
                best = e.seq;
                oldest = target;
            }
        }
        if (!oldest.empty()) ack(oldest);
    }

    void evict_oldest_of(const std::string& issuer) {
        auto it = by_issuer.find(issuer);
        if (it == by_issuer.end()) return;
        std::string oldest;
        uint64_t best = UINT64_MAX;
        for (const auto& target : it->second) {
            auto eit = entries.find(target);
            if (eit != entries.end() && eit->second.seq < best) {
                best = eit->second.seq;
                oldest = target;
            }
        }
        if (!oldest.empty()) ack(oldest);
    }
};
