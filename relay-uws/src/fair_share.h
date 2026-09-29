#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <set>
#include <unordered_map>
#include <utility>

// Who gives way when a relay table that anyone can write to is full: the share
// holding the most of it, with its least recently used entry. A share is an
// address block hashed under a key the relay replaces every hour (`share_id`),
// never an identity: identities are free and address blocks are not, so a flood
// from throwaway accounts evicts only its own entries and nothing a real person
// left (feedback_relay_rules: reprioritise, never refuse).
//
// Header-only so test/test_fair_share.cpp drives it without a relay.
template <typename Key, typename Hash = std::hash<Key>>
class FairShare {
public:
    FairShare() = default;
    FairShare(const FairShare&) = delete;
    FairShare& operator=(const FairShare&) = delete;
    FairShare(FairShare&&) = default;
    FairShare& operator=(FairShare&&) = default;

    // Charge `key` to `share` at `weight`, as used now. A key already held moves to
    // `share` and takes the new weight.
    void put(const Key& key, uint64_t share, size_t weight) {
        auto [it, fresh] = entries_.try_emplace(key);
        if (!fresh) unlink(it);
        it->second = Entry{share, weight, ++tick_};
        link(it);
    }

    void touch(const Key& key) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return;
        auto& uses = shares_.at(it->second.share).by_use;
        uses.erase({it->second.tick, &it->first});
        it->second.tick = ++tick_;
        uses.insert({it->second.tick, &it->first});
    }

    // A new weight for `key`, keeping its share and when it was last used.
    void reweigh(const Key& key, size_t weight) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return;
        Share& s = shares_.at(it->second.share);
        by_held_.erase({s.held, it->second.share});
        s.held = s.held - it->second.weight + weight;
        total_ = total_ - it->second.weight + weight;
        it->second.weight = weight;
        by_held_.insert({s.held, it->second.share});
    }

    bool remove(const Key& key) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return false;
        unlink(it);
        entries_.erase(it);
        return true;
    }

    bool contains(const Key& key) const { return entries_.count(key) != 0; }

    std::optional<uint64_t> share_of(const Key& key) const {
        auto it = entries_.find(key);
        if (it == entries_.end()) return std::nullopt;
        return it->second.share;
    }

    // Recency order: a higher number was used later.
    uint64_t last_use(const Key& key) const {
        auto it = entries_.find(key);
        return it == entries_.end() ? 0 : it->second.tick;
    }

    // The entry to evict: the least recently used of the share holding the most.
    std::optional<Key> victim() const {
        if (by_held_.empty()) return std::nullopt;
        const Share& s = shares_.at(by_held_.rbegin()->second);
        return *s.by_use.begin()->second;
    }

    size_t total() const { return total_; }
    size_t size() const { return entries_.size(); }

    size_t held(uint64_t share) const {
        auto it = shares_.find(share);
        return it == shares_.end() ? 0 : it->second.held;
    }

private:
    struct Entry {
        uint64_t share = 0;
        size_t weight = 0;
        uint64_t tick = 0;
    };
    // `by_use` points at the keys of `entries_`, which stay put until erased.
    struct Share {
        size_t held = 0;
        std::set<std::pair<uint64_t, const Key*>> by_use;
    };
    using Iter = typename std::unordered_map<Key, Entry, Hash>::iterator;

    void link(Iter it) {
        const Entry& e = it->second;
        Share& s = shares_[e.share];
        if (!s.by_use.empty()) by_held_.erase({s.held, e.share});
        s.held += e.weight;
        s.by_use.insert({e.tick, &it->first});
        by_held_.insert({s.held, e.share});
        total_ += e.weight;
    }

    void unlink(Iter it) {
        const Entry& e = it->second;
        auto sit = shares_.find(e.share);
        Share& s = sit->second;
        by_held_.erase({s.held, e.share});
        s.held -= e.weight;
        s.by_use.erase({e.tick, &it->first});
        total_ -= e.weight;
        if (s.by_use.empty()) {
            shares_.erase(sit);
        } else {
            by_held_.insert({s.held, e.share});
        }
    }

    std::unordered_map<Key, Entry, Hash> entries_;
    std::unordered_map<uint64_t, Share> shares_;
    std::set<std::pair<size_t, uint64_t>> by_held_;
    uint64_t tick_ = 0;
    size_t total_ = 0;
};
