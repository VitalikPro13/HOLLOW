#pragma once
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "client_json.h"
#include "json.hpp"

// What keys.json says. A field of the wrong JSON type reads as nothing at all, never a
// throw: the reload runs in a uSockets timer, where an exception ends the process with no
// restart snapshot (HOL-SEC-203). Missing fields keep their defaults (off, no keys);
// non-text keys are skipped as before.
struct KeysFile {
    bool enabled = false;
    std::unordered_set<std::string> keys;
};

inline std::optional<KeysFile> parse_keys_file(std::string_view text) noexcept {
    try {
        if (text.find('\0') != std::string_view::npos || !client_json::depth_within(text, 8)) return std::nullopt;
        nlohmann::json j = nlohmann::json::parse(text, nullptr, /*allow_exceptions=*/false);
        if (!j.is_object()) return std::nullopt;
        KeysFile out;
        if (auto e = j.find("enabled"); e != j.end()) {
            if (!e->is_boolean()) return std::nullopt;
            out.enabled = e->get<bool>();
        }
        if (auto ks = j.find("keys"); ks != j.end()) {
            if (!ks->is_array()) return std::nullopt;
            for (const auto& k : *ks) {
                if (k.is_string()) out.keys.insert(k.get<std::string>());
            }
        }
        return out;
    } catch (...) {
        return std::nullopt;
    }
}

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

    // A reload of keys.json from `text`: false, changing nothing, when it does not read;
    // else the keys are swapped and `kicked` names the holders of keys that went.
    bool reload_text(std::string_view text, std::vector<std::string>& kicked) {
        std::optional<KeysFile> file = parse_keys_file(text);
        if (!file) return false;
        kicked = replace_keys(std::move(file->keys), file->enabled);
        return true;
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
