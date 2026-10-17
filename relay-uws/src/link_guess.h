#pragma once
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>

#include "fair_share.h"

// Failed link-code guesses per ip_limit_key (RELAY-5). Anyone can add records, so a
// full table gives way from the address share holding the most (fair_share.h): a
// flood from one block never clears another block's count or block.
//
// Header-only so test/test_link_guess.cpp drives it without a relay.

struct LinkGuess {
    uint32_t failures = 0;
    std::chrono::steady_clock::time_point block_until{};
    std::chrono::steady_clock::time_point last_failure{};
};

class LinkGuesses {
public:
    using Clock = std::chrono::steady_clock;

    explicit LinkGuesses(size_t cap) : cap_(cap) {}

    // The record for `key`, made if new, charged to `share` as used now.
    LinkGuess& note(const std::string& key, uint64_t share) {
        auto it = records_.find(key);
        if (it == records_.end()) {
            while (records_.size() >= cap_) {
                auto victim = ledger_.victim();
                if (!victim) break;
                records_.erase(*victim);
                ledger_.remove(*victim);
            }
            it = records_.emplace(key, LinkGuess{}).first;
        }
        ledger_.put(key, share, 1);
        return it->second;
    }

    const LinkGuess* find(const std::string& key) const {
        auto it = records_.find(key);
        return it == records_.end() ? nullptr : &it->second;
    }

    void erase(const std::string& key) {
        records_.erase(key);
        ledger_.remove(key);
    }

    template <typename Pred>
    void erase_if(Pred stale) {
        for (auto it = records_.begin(); it != records_.end();) {
            if (stale(it->first, it->second)) {
                ledger_.remove(it->first);
                it = records_.erase(it);
            } else {
                ++it;
            }
        }
    }

    size_t size() const { return records_.size(); }

private:
    size_t cap_;
    std::unordered_map<std::string, LinkGuess> records_;
    FairShare<std::string> ledger_;
};
