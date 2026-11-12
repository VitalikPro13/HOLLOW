#pragma once
// Sockets that have not logged in yet, bounded per address block (soft) and in all. An
// honest login takes a step every round trip (its first auth_hello, then auth), so a socket
// that took none for STALL_MS is the first to give way (a repeated hello is no step), and
// among those the share holding the most of them: never age across addresses, never an
// identity (fair_share.h). A step can be delayed up to STALL_MS each, so a paced attacker
// stays fresh until the 10 s auth timeout (AR-36 counts that). A fresh
// burst from one carrier NAT is never cut while anyone is stalled. RAM only, never logged.
//
// Header-only so test/test_login_window.cpp drives it without a relay.
#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "fair_share.h"

namespace login_window {

inline constexpr int64_t STALL_MS = 5'000;

using Key = uintptr_t;

// How far a login got: only a later stage counts as progress.
enum class Stage : uint8_t { Open = 0, Challenged = 1, Signed = 2 };

class Window {
public:
    // `key` opens from `share` (its socket_share) in `block` (ip_key.h login_block). Returns
    // the sockets that give way for it, already taken out; never `key` itself.
    std::vector<Key> open(Key key, uint64_t share, const std::string& block, int64_t now_ms, size_t per_block,
                          size_t total, int64_t stall_ms = STALL_MS) {
        std::vector<Key> out;
        if (entries_.count(key)) return out;
        entries_.emplace(key, Entry{share, block, now_ms, false, Stage::Open});
        fresh_.put(key, share, 1);
        by_progress_.insert({now_ms, key});
        blocks_[block].count++;
        settle(now_ms, stall_ms);
        Block& b = blocks_[block];
        if (b.count > per_block) {
            if (auto victim = b.stalled.victim()) {
                take(*victim);
                out.push_back(*victim);
            }
        }
        if (entries_.size() > total) {
            std::optional<Key> victim = stalled_.victim();
            if (!victim) victim = fresh_.victim_except(key);
            if (victim) {
                take(*victim);
                out.push_back(*victim);
            }
        }
        return out;
    }

    // A pre-auth frame from `key` that reached `stage`: progress only past the stage it held.
    void progress(Key key, Stage stage, int64_t now_ms) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return;
        Entry& e = it->second;
        if (stage <= e.stage) return;
        e.stage = stage;
        if (e.stalled) {
            stalled_.remove(key);
            blocks_[e.block].stalled.remove(key);
            e.stalled = false;
            fresh_.put(key, e.share, 1);
        } else {
            by_progress_.erase({e.last_ms, key});
            fresh_.touch(key);
        }
        e.last_ms = now_ms;
        by_progress_.insert({now_ms, key});
    }

    // Logged in, refused or closed.
    void leave(Key key) { take(key); }

    bool contains(Key key) const { return entries_.count(key) != 0; }
    size_t size() const { return entries_.size(); }
    size_t in_block(const std::string& block) const {
        auto it = blocks_.find(block);
        return it == blocks_.end() ? 0 : it->second.count;
    }

private:
    struct Entry {
        uint64_t share;
        std::string block;
        int64_t last_ms;
        bool stalled;
        Stage stage;
    };
    struct Block {
        size_t count = 0;
        FairShare<Key> stalled;
    };

    // Entries that made no progress for `stall_ms` move to the stalled tables.
    void settle(int64_t now_ms, int64_t stall_ms) {
        while (!by_progress_.empty() && now_ms - by_progress_.begin()->first >= stall_ms) {
            const Key key = by_progress_.begin()->second;
            by_progress_.erase(by_progress_.begin());
            Entry& e = entries_.at(key);
            fresh_.remove(key);
            stalled_.put(key, e.share, 1);
            blocks_[e.block].stalled.put(key, e.share, 1);
            e.stalled = true;
        }
    }

    void take(Key key) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return;
        Entry& e = it->second;
        if (e.stalled) {
            stalled_.remove(key);
        } else {
            fresh_.remove(key);
            by_progress_.erase({e.last_ms, key});
        }
        auto b = blocks_.find(e.block);
        if (b != blocks_.end()) {
            b->second.stalled.remove(key);
            if (--b->second.count == 0) blocks_.erase(b);
        }
        entries_.erase(it);
    }

    std::unordered_map<Key, Entry> entries_;
    FairShare<Key> fresh_;
    FairShare<Key> stalled_;
    std::set<std::pair<int64_t, Key>> by_progress_;
    std::unordered_map<std::string, Block> blocks_;
};

}  // namespace login_window
