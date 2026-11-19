#pragma once
#include <cstddef>
#include <string>

#include "json.hpp"
#include "sib_mute.h"

// The channel push filters a phone registers for itself (`set_push_prefs`): per server a
// level and channel overrides, plus reserved entries no room code can name (room codes
// never start with `~`): `~dm` (muted DM senders by device id), `~default` (the level of
// every server the device never set) and `~sib` (its siblings' marks, sib_mute.h, which
// only the relay writes). The relay filters here because an iOS alert push cannot be
// suppressed after delivery.
//
// Header-only so test/test_push_pref.cpp drives it without a relay.
namespace push_pref {

inline constexpr const char* DM_KEY = "~dm";
inline constexpr const char* DEFAULT_KEY = "~default";
inline constexpr size_t MAX_SERVERS = 256;
inline constexpr size_t MAX_CHANNELS = 1024;

inline bool is_level(const std::string& s) { return s == "all" || s == "mentions" || s == "nothing"; }

template <typename Pref>
Pref read_entry(const nlohmann::json& val, bool with_channels) {
    Pref p;
    auto level = val.find("level");
    p.level = level != val.end() && level->is_string() ? level->template get<std::string>() : "all";
    if (!is_level(p.level)) p.level = "all";
    auto ch = val.find("channels");
    if (!with_channels || ch == val.end() || !ch->is_object()) return p;
    size_t n = 0;
    for (auto& [cid, lv] : ch->items()) {
        if (++n > MAX_CHANNELS) break;
        if (!lv.is_string() || cid.empty() || cid.size() > 128) continue;
        const std::string& s = lv.template get_ref<const std::string&>();
        if (is_level(s)) p.channels[cid] = s;
    }
    return p;
}

// The filters a `prefs` object names: a key that is neither a room code nor a reserved
// entry is skipped alone, never the whole set (so a relay older than `~default` keeps the
// rest). The reserved entries are read past the server cap: a device in many servers
// keeps its default and its muted DMs.
template <typename Prefs, typename ValidRoom>
Prefs parse(const nlohmann::json& prefs, const ValidRoom& valid_room) {
    using Pref = typename Prefs::mapped_type;
    Prefs out;
    if (!prefs.is_object()) return out;
    size_t servers = 0;
    for (auto& [server, val] : prefs.items()) {
        if (++servers > MAX_SERVERS) break;
        if (!val.is_object() || !valid_room(server)) continue;
        out[server] = read_entry<Pref>(val, true);
    }
    if (auto dm = prefs.find(DM_KEY); dm != prefs.end() && dm->is_object()) out[DM_KEY] = read_entry<Pref>(*dm, true);
    // A channel id means something only inside its server.
    if (auto d = prefs.find(DEFAULT_KEY); d != prefs.end() && d->is_object()) {
        out[DEFAULT_KEY] = read_entry<Pref>(*d, false);
    }
    return out;
}

// The level a channel wake of `server` meets on a device holding `prefs` (null = none
// registered): the server's own entry wins, else the device's `~default`, else every post
// (a device that never said, an older client).
template <typename Prefs>
std::string level_for(const Prefs* prefs, const std::string& server, const std::string& channel) {
    if (!prefs) return "all";
    // A sibling's mark silences mentions too: the server is one the device hides.
    if (sib::muted(*prefs, server)) return "nothing";
    auto sit = prefs->find(server);
    if (sit == prefs->end()) {
        auto dit = prefs->find(DEFAULT_KEY);
        return dit == prefs->end() ? "all" : dit->second.level;
    }
    auto cit = sit->second.channels.find(channel);
    return cit != sit->second.channels.end() ? cit->second : sit->second.level;
}

}  // namespace push_pref
