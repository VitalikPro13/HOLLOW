#pragma once
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "join_lock.h"
#include "json.hpp"
#include "validate.h"

// Sibling push mutes (`mute_siblings`, t14-iospush DESIGN_AGEMUTE.md): a computer of an
// identity silences the channel wakes of named servers for that identity's other devices
// (the 18+ servers its phones hide), so a phone asleep through the choice is not woken.
// The marks live in the reserved `~sib` entry of each sibling's push prefs (beside `~dm`;
// no room code starts with `~`), so the snapshot carries them unchanged. A sibling only
// adds marks or replaces marks siblings made; the device's own entries are never touched.
//
// Header-only so test/test_sib_mute.cpp drives it without a relay.
namespace sib {

inline constexpr const char* KEY = "~sib";
// Reserved channel keys inside the entry; every other key is a server id.
inline constexpr const char* AT = "~at";
inline constexpr const char* SET_AT = "~set";
inline constexpr const char* BY = "~by";
inline constexpr size_t MAX_SERVERS = 256;
// roster.h MAX_FUTURE_SKEW_MS: a stamp further ahead pins the order and is refused whole.
inline constexpr int64_t MAX_FUTURE_MS = 10LL * 60 * 1000;

struct Frame {
    std::string master;
    int64_t at = 0;
    int64_t set_at = 0;
    std::set<std::string> servers;
};

inline bool stamp_ok(const nlohmann::json& v, int64_t now_ms, int64_t& out) {
    if (!v.is_number_integer()) return false;
    out = v.get<int64_t>();
    return out > 0 && out <= now_ms + MAX_FUTURE_MS;
}

// The frame, or nothing: one bad field refuses it whole, never a clipped set (a clipped
// set would open the servers it left out).
inline std::optional<Frame> parse(const nlohmann::json& j, int64_t now_ms) {
    if (!j.is_object()) return std::nullopt;
    Frame f;
    auto m = j.find("master");
    auto at = j.find("at");
    auto set_at = j.find("set_at");
    auto servers = j.find("servers");
    if (m == j.end() || !m->is_string() || at == j.end() || set_at == j.end() || servers == j.end() ||
        !servers->is_array() || servers->size() > MAX_SERVERS) {
        return std::nullopt;
    }
    f.master = m->get<std::string>();
    if (!is_peer_id_shape(f.master) || !stamp_ok(*at, now_ms, f.at) || !stamp_ok(*set_at, now_ms, f.set_at)) {
        return std::nullopt;
    }
    for (const auto& s : *servers) {
        if (!s.is_string() || !join_lock::is_server_id_shape(s.get_ref<const std::string&>())) return std::nullopt;
        f.servers.insert(s.get<std::string>());
    }
    return f;
}

inline int64_t stamp_of(const std::unordered_map<std::string, std::string>& channels, const char* key) {
    auto it = channels.find(key);
    if (it == channels.end()) return 0;
    int64_t v = 0;
    const auto& s = it->second;
    if (std::from_chars(s.data(), s.data() + s.size(), v).ec != std::errc()) return 0;
    return v;
}

// What one entry of a device's push prefs weighs in the registration ledger
// (`charge_registrations` uses the same count).
template <typename Pref>
size_t pref_weight(const std::string& server, const Pref& p) {
    size_t w = 96 + server.size() + p.level.size();
    for (const auto& [cid, level] : p.channels) w += 96 + cid.size() + level.size();
    return w;
}

template <typename Prefs>
size_t entry_weight(const Prefs& prefs) {
    auto it = prefs.find(KEY);
    return it == prefs.end() ? 0 : pref_weight(it->first, it->second);
}

// A writer owns the identity's inbox and the fold just computed counts it: a fold can
// stop counting a device by time alone (a restored backup's join matures), with no show
// to take its inbox away.
template <typename State>
bool writer_counted(bool owns_inbox, const State& fold, const std::string& writer) {
    return owns_inbox && fold.is_member(writer);
}

// Equal stamps are one view of the flags as far as the order can tell, yet a flag read
// late (an older op caught up after a newer one) leaves the stamp where it was: such a
// frame only adds marks, up to the cap, and never lifts one.
template <typename Prefs>
bool add_marks(Prefs& prefs, const Frame& f, const std::string& writer) {
    auto& ch = prefs.find(KEY)->second.channels;
    size_t held = 0;
    for (const auto& [k, v] : ch) held += k.empty() || k[0] != '~';
    bool added = false;
    for (const auto& s : f.servers) {
        if (held >= MAX_SERVERS) break;
        if (ch.try_emplace(s, "nothing").second) {
            held++;
            added = true;
        }
    }
    if (added) ch[BY] = writer;
    return added;
}

// Write `f` from `writer` into one sibling's prefs. A newer choice (`at`) replaces the
// marks, as does a newer view of the flags at the same choice (`set_at`); equal stamps
// only add (`add_marks`). Returns whether anything changed.
template <typename Prefs>
bool apply(Prefs& prefs, const Frame& f, const std::string& writer) {
    auto it = prefs.find(KEY);
    if (it != prefs.end()) {
        const int64_t at = stamp_of(it->second.channels, AT), set_at = stamp_of(it->second.channels, SET_AT);
        if (f.at < at || (f.at == at && f.set_at < set_at)) return false;
        if (f.at == at && f.set_at == set_at) return add_marks(prefs, f, writer);
    } else {
        it = prefs.try_emplace(KEY).first;
        it->second.level = "nothing";
    }
    auto& ch = it->second.channels;
    ch.clear();
    for (const auto& s : f.servers) ch[s] = "nothing";
    ch[AT] = std::to_string(f.at);
    ch[SET_AT] = std::to_string(f.set_at);
    ch[BY] = writer;
    return true;
}

// Whether a channel wake of `server` is silenced by a sibling's mark.
template <typename Prefs>
bool muted(const Prefs& prefs, const std::string& server) {
    auto it = prefs.find(KEY);
    if (it == prefs.end() || it->second.level == "all") return false;
    auto m = it->second.channels.find(server);
    return m != it->second.channels.end() && m->second == "nothing";
}

// The (`at`, `set_at`) view of the flags a device says it has caught up to.
struct View {
    int64_t at = 0;
    int64_t set_at = 0;
};

// A device's `sib_view`, or nothing (then it lifts nothing): both stamps as a frame's.
inline std::optional<View> parse_view(const nlohmann::json& j, int64_t now_ms) {
    if (!j.is_object()) return std::nullopt;
    auto at = j.find("at");
    auto set_at = j.find("set_at");
    View v;
    if (at == j.end() || set_at == j.end() || !stamp_ok(*at, now_ms, v.at) || !stamp_ok(*set_at, now_ms, v.set_at)) {
        return std::nullopt;
    }
    return v;
}

// The device's own wholesale prefs replace everything but the held `~sib` entry, whose
// level only the device itself sets: "all" = it does not follow its siblings' marks. A
// view at or past the marks' stamps lifts them, since the device's own prefs mute what it
// hides; the entry keeps the view's stamps, so no older frame sets them again.
template <typename Prefs>
void carry(const Prefs& held, Prefs& fresh, bool own_local, const std::optional<View>& view = std::nullopt) {
    fresh.erase(KEY);
    auto it = held.find(KEY);
    if (it != held.end()) fresh[KEY] = it->second;
    if (view) {
        auto& ch = fresh[KEY].channels;
        const int64_t at = stamp_of(ch, AT), set_at = stamp_of(ch, SET_AT);
        if (view->at > at || (view->at == at && view->set_at >= set_at)) {
            ch.clear();
            ch[AT] = std::to_string(view->at);
            ch[SET_AT] = std::to_string(view->set_at);
        }
    }
    if (fresh.find(KEY) == fresh.end() && !own_local) return;
    fresh[KEY].level = own_local ? "all" : "nothing";
}

// A device's marks and their stamps, gone with the record the relay held for its
// identity, so no mark outlives the fold that let it be written. Returns whether anything
// went.
template <typename Prefs>
bool forget(Prefs& prefs) {
    auto it = prefs.find(KEY);
    if (it == prefs.end() || it->second.channels.empty()) return false;
    if (it->second.level == "all") {
        it->second.channels.clear();
    } else {
        prefs.erase(it);
    }
    return true;
}

// Marks whose writer the identity's fold no longer counts go at once, stamps and all, so
// a remaining computer's re-send (an older stamp) is taken again. Returns whether anything
// went.
template <typename Prefs, typename Counted>
bool purge(Prefs& prefs, const Counted& counted) {
    auto it = prefs.find(KEY);
    if (it == prefs.end()) return false;
    auto by = it->second.channels.find(BY);
    if (by == it->second.channels.end() || counted(by->second)) return false;
    if (it->second.level == "all") {
        it->second.channels.clear();
    } else {
        prefs.erase(it);
    }
    return true;
}

}  // namespace sib
