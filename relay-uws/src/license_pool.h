#pragma once
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

enum class LicenseResult {
    Ok,
    NotRequired,
    InvalidKey,
    KeyInUse,
    KeyRequired,
};

// The key registry and who holds each key right now. Pure, so test/ can build it
// without uWebSockets.
//
// One key admits up to MAX_DEVICES_PER_KEY sockets at once. A person's linked
// devices share one key (a linked device inherits it with the imported database)
// and the relay keeps a dead socket for up to its idle timeout, so a cap of one
// refused every second device and every reconnect that raced its own ghost.
struct LicensePool {
    static constexpr size_t MAX_DEVICES_PER_KEY = 5;

    bool enabled = false;
    std::unordered_set<std::string> keys;
    std::unordered_map<std::string, std::unordered_set<std::string>> holders; // key -> peer_ids

    LicenseResult validate(const std::string* key, const std::string& peer_id) {
        if (!enabled) return LicenseResult::NotRequired;
        if (!key || key->empty()) return LicenseResult::KeyRequired;
        if (keys.find(*key) == keys.end()) return LicenseResult::InvalidKey;

        auto it = holders.find(*key);
        if (it != holders.end()) {
            if (it->second.count(peer_id)) return LicenseResult::Ok;
            if (it->second.size() >= MAX_DEVICES_PER_KEY) return LicenseResult::KeyInUse;
            it->second.insert(peer_id);
            return LicenseResult::Ok;
        }
        holders[*key].insert(peer_id);
        return LicenseResult::Ok;
    }

    void release(const std::string& peer_id) {
        for (auto it = holders.begin(); it != holders.end(); ) {
            it->second.erase(peer_id);
            if (it->second.empty()) it = holders.erase(it);
            else ++it;
        }
    }

    // Swap in the reloaded file. Returns every holder of a key that vanished, in
    // no particular order, and forgets them.
    std::vector<std::string> replace_keys(std::unordered_set<std::string> new_keys, bool new_enabled) {
        std::vector<std::string> kicked;
        for (auto it = holders.begin(); it != holders.end(); ) {
            if (new_keys.find(it->first) == new_keys.end()) {
                kicked.insert(kicked.end(), it->second.begin(), it->second.end());
                it = holders.erase(it);
            } else {
                ++it;
            }
        }
        enabled = new_enabled;
        keys = std::move(new_keys);
        return kicked;
    }
};
