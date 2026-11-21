#pragma once
#include <cstdint>
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
// One key admits up to MAX_DEVICES_PER_KEY devices at once. A person's linked
// devices share one key (a linked device inherits it with the imported database)
// and the relay keeps a dead socket for up to its idle timeout, so a cap of one
// refused every second device and every reconnect that raced its own ghost.
//
// A seat belongs to the SOCKET that took it (#153): validate() takes it, and only that
// socket's close gives it back, whatever ends the socket. A refusal after the key was
// judged (cooldown, ip_limit, anything added later) can no longer keep a seat with no
// socket, and a device holds its seat while any of its sockets is open, so a relogin
// that supersedes its own ghost keeps it.
using SeatToken = uintptr_t;

struct LicensePool {
    static constexpr size_t MAX_DEVICES_PER_KEY = 5;

    bool enabled = false;
    std::unordered_set<std::string> keys;
    // key -> device -> its sockets holding a seat; a key's devices are its seats.
    std::unordered_map<std::string, std::unordered_map<std::string, std::unordered_set<SeatToken>>> holders;
    // Each socket holding a seat, with the key and device it holds it for.
    std::unordered_map<SeatToken, std::pair<std::string, std::string>> seats;
    // Logins refused because every seat of their key was taken, for /server-stats.
    uint64_t seats_full_refused = 0;

    // Judges `key` for `peer_id`'s socket `token`; Ok with the gate on means the socket
    // now holds a seat until release(token).
    LicenseResult validate(const std::string* key, const std::string& peer_id, SeatToken token) {
        if (!enabled) return LicenseResult::NotRequired;
        if (!key || key->empty()) return LicenseResult::KeyRequired;
        if (keys.find(*key) == keys.end()) return LicenseResult::InvalidKey;

        auto it = holders.find(*key);
        const bool held = it != holders.end() && it->second.count(peer_id);
        if (!held && it != holders.end() && it->second.size() >= MAX_DEVICES_PER_KEY) {
            seats_full_refused++;
            return LicenseResult::KeyInUse;
        }
        release(token);
        holders[*key][peer_id].insert(token);
        seats[token] = {*key, peer_id};
        return LicenseResult::Ok;
    }

    // The socket is gone: its seat goes with it, and its device's with its last socket.
    void release(SeatToken token) {
        auto s = seats.find(token);
        if (s == seats.end()) return;
        auto k = holders.find(s->second.first);
        if (k != holders.end()) {
            auto d = k->second.find(s->second.second);
            if (d != k->second.end()) {
                d->second.erase(token);
                if (d->second.empty()) k->second.erase(d);
            }
            if (k->second.empty()) holders.erase(k);
        }
        seats.erase(s);
    }

    // How many devices hold a seat of `key`.
    size_t seats_of(const std::string& key) const {
        auto it = holders.find(key);
        return it == holders.end() ? 0 : it->second.size();
    }

    // A reload of keys.json from `text`: false, changing nothing, when it does not read;
    // else the keys are swapped and `kicked` names the sockets holding keys that went.
    bool reload_text(std::string_view text, std::vector<SeatToken>& kicked) {
        std::optional<KeysFile> file = parse_keys_file(text);
        if (!file) return false;
        kicked = replace_keys(std::move(file->keys), file->enabled);
        return true;
    }

    // Swap in the reloaded file. Returns every socket holding a key that vanished (fetch
    // and guest sockets too), in no particular order, their seats forgotten.
    std::vector<SeatToken> replace_keys(std::unordered_set<std::string> new_keys, bool new_enabled) {
        std::vector<SeatToken> kicked;
        for (auto it = holders.begin(); it != holders.end(); ) {
            if (new_keys.find(it->first) == new_keys.end()) {
                for (const auto& [peer, tokens] : it->second) {
                    for (SeatToken t : tokens) {
                        kicked.push_back(t);
                        seats.erase(t);
                    }
                }
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
