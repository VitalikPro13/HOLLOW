#pragma once
// The operator denylist (design t14-deny): server and meeting ids, master identities and
// network addresses this relay refuses, from one file only the operator writes. Every
// match is an exact compare on an id the relay already sees, so the list teaches the
// relay nothing new about anyone. Pure (no uWebSockets) so test/test_deny_list.cpp drives
// it; nothing here throws, and nothing here prints an id.
#include <arpa/inet.h>
#include <netinet/in.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <iterator>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "client_json.h"
#include "file_stamp.h"
#include "ip_key.h"
#include "join_lock.h"
#include "json.hpp"
#include "validate.h"

namespace deny {

static constexpr size_t MAX_FILE_BYTES = 8u * 1024 * 1024;
static constexpr size_t MAX_ENTRIES = 65536;
static constexpr int64_t FILE_VERSION = 1;
// The file is three flat lists of strings or small objects.
static constexpr size_t MAX_DEPTH = 4;
static constexpr std::string_view CONF_PREFIX = "conf:";

struct List {
    std::set<std::string> servers;
    std::set<std::string> identities;
    std::set<std::string> networks;

    bool operator==(const List& o) const {
        return servers == o.servers && identities == o.identities && networks == o.networks;
    }
    bool operator!=(const List& o) const { return !(*this == o); }
    bool empty() const { return servers.empty() && identities.empty() && networks.empty(); }
};

inline std::string lower(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

// A server room or meeting room as the list holds it: lower-cased (a room code may arrive
// in any case), a 32- or 40-hex server id or `conf:` and one.
inline std::optional<std::string> server_key(std::string_view id) {
    std::string key = lower(id);
    std::string_view bare = key;
    if (bare.substr(0, CONF_PREFIX.size()) == CONF_PREFIX) bare.remove_prefix(CONF_PREFIX.size());
    if (!join_lock::is_server_id_shape(bare)) return std::nullopt;
    return key;
}

// Server entries of 32 hex characters: an older server's id has the shape of a DM room and
// an identity's own room too, so one names whatever room has that code (review R7).
inline size_t legacy_shaped(const List& l) {
    return static_cast<size_t>(std::count_if(l.servers.begin(), l.servers.end(), [](const std::string& s) {
        return s.size() == 32 && s.find_first_not_of("0123456789abcdef") == std::string::npos;
    }));
}

inline std::optional<std::string> identity_key(std::string_view id) {
    if (!is_peer_id_shape(id)) return std::nullopt;
    return std::string(id);
}

// An address as the list holds it: the very key ip_limit_key gives a socket from it (a v4
// address, a v6 /64; a v4-mapped one unmapped). A v6 address with host bits names its /64;
// a written `/64` must have none. No other prefix, and no v4 range.
inline std::optional<std::string> network_key(std::string_view text) {
    std::string addr(text);
    bool slash64 = false;
    if (auto slash = addr.find('/'); slash != std::string::npos) {
        if (addr.substr(slash + 1) != "64") return std::nullopt;
        addr.resize(slash);
        slash64 = true;
    }
    // A zone (fe80::1%eth0) names an interface on one box, never a peer's address.
    if (addr.empty() || addr.size() >= INET6_ADDRSTRLEN || addr.find('%') != std::string::npos) return std::nullopt;
    struct in_addr v4 {};
    if (inet_pton(AF_INET, addr.c_str(), &v4) == 1) {
        if (slash64) return std::nullopt;
        char buf[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &v4, buf, sizeof(buf))) return std::nullopt;
        return std::string(buf);
    }
    struct in6_addr v6 {};
    if (inet_pton(AF_INET6, addr.c_str(), &v6) != 1) return std::nullopt;
    if (slash64) {
        if (IN6_IS_ADDR_V4MAPPED(&v6)) return std::nullopt;
        for (size_t i = 8; i < 16; i++) {
            if (v6.s6_addr[i] != 0) return std::nullopt;
        }
    }
    char buf[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, &v6, buf, sizeof(buf))) return std::nullopt;
    return ip_limit_key(buf);
}

// A parse: the list, or the first thing wrong with the file (where, never the entry's text).
struct Parsed {
    std::optional<List> list;
    std::string error;
};

namespace detail {

using Key = std::optional<std::string> (*)(std::string_view);

inline bool read_list(const nlohmann::json& root, const char* name, const char* field, Key key,
                      std::set<std::string>& out, std::string& error) {
    auto it = root.find(name);
    if (it == root.end()) {
        error = std::string(name) + " is missing (write [] for none)";
        return false;
    }
    if (!it->is_array()) {
        error = std::string(name) + " is not a list";
        return false;
    }
    if (it->size() > MAX_ENTRIES) {
        error = std::string(name) + " has more than 65536 entries";
        return false;
    }
    size_t n = 0;
    for (const auto& e : *it) {
        n++;
        const std::string where = std::string(name) + ", entry " + std::to_string(n) + ": ";
        const std::string* text = nullptr;
        if (e.is_string()) {
            text = &e.get_ref<const std::string&>();
        } else if (e.is_object()) {
            auto f = e.find(field);
            if (f == e.end() || !f->is_string()) {
                error = where + "an object needs \"" + field + "\" as text";
                return false;
            }
            text = &f->get_ref<const std::string&>();
        } else {
            error = where + "neither text nor an object";
            return false;
        }
        auto k = key(*text);
        if (!k) {
            error = where + (key == &server_key       ? "not a server or meeting id"
                             : key == &identity_key   ? "not an identity id"
                                                      : "not an address, or a prefix other than /64 on IPv6");
            return false;
        }
        out.insert(std::move(*k));
    }
    return true;
}

inline size_t line_of(std::string_view text, size_t byte) {
    byte = std::min(byte, text.size());
    return 1 + static_cast<size_t>(std::count(text.begin(), text.begin() + static_cast<std::ptrdiff_t>(byte), '\n'));
}

}  // namespace detail

// All or nothing: one entry that does not read rejects the whole file, so a typo never
// drops a block in silence. `ref`, `added` and any other key are read past and kept nowhere.
inline Parsed parse(std::string_view text) noexcept {
    Parsed out;
    try {
        if (text.size() > MAX_FILE_BYTES) {
            out.error = "the file is over 8 MiB";
            return out;
        }
        if (text.find('\0') != std::string_view::npos) {
            out.error = "the file holds a NUL byte";
            return out;
        }
        if (!client_json::depth_within(text, MAX_DEPTH)) {
            out.error = "the file nests deeper than three lists of entries";
            return out;
        }
        nlohmann::json root;
        try {
            root = nlohmann::json::parse(text);
        } catch (const nlohmann::json::parse_error& e) {
            out.error = "line " + std::to_string(detail::line_of(text, e.byte)) + ": not valid JSON";
            return out;
        }
        if (!root.is_object()) {
            out.error = "the file is not a JSON object";
            return out;
        }
        auto v = root.find("version");
        if (v == root.end() || !v->is_number_integer() || v->get<int64_t>() != FILE_VERSION) {
            out.error = "version must be 1";
            return out;
        }
        List list;
        if (!detail::read_list(root, "servers", "id", &server_key, list.servers, out.error) ||
            !detail::read_list(root, "identities", "id", &identity_key, list.identities, out.error) ||
            !detail::read_list(root, "networks", "ip", &network_key, list.networks, out.error)) {
            return out;
        }
        out.list = std::move(list);
    } catch (...) {
        out.list.reset();
        if (out.error.empty()) out.error = "the file could not be read";
    }
    return out;
}

enum class Read { Ok, Missing, Bad };

struct Loaded {
    Read read = Read::Missing;
    List list;
    std::string error;
    // Taken before the read: a write that lands meanwhile shows as a change next time.
    FileStamp stamp;
};

inline Loaded load(const std::string& path) noexcept {
    Loaded out;
    try {
        out.stamp = file_stamp(path);
        FILE* f = fopen(path.c_str(), "rb");
        if (!f) {
            out.read = out.stamp.exists ? Read::Bad : Read::Missing;
            if (out.read == Read::Bad) out.error = "the file cannot be opened";
            return out;
        }
        std::string text;
        char buf[65536];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
            text.append(buf, n);
            if (text.size() > MAX_FILE_BYTES) break;
        }
        const bool failed = ferror(f) != 0;
        fclose(f);
        if (failed) {
            out.read = Read::Bad;
            out.error = "the file cannot be read";
            return out;
        }
        Parsed p = parse(text);
        if (!p.list) {
            out.read = Read::Bad;
            out.error = std::move(p.error);
            return out;
        }
        out.read = Read::Ok;
        out.list = std::move(*p.list);
    } catch (...) {
        out.read = Read::Bad;
        out.error = "the file could not be read";
    }
    return out;
}

struct Diff {
    List added;
    List removed;
    bool empty() const { return added.empty() && removed.empty(); }
};

inline Diff diff(const List& from, const List& to) {
    Diff d;
    auto sides = [](const std::set<std::string>& a, const std::set<std::string>& b, std::set<std::string>& only_b) {
        std::set_difference(b.begin(), b.end(), a.begin(), a.end(), std::inserter(only_b, only_b.end()));
    };
    sides(from.servers, to.servers, d.added.servers);
    sides(from.identities, to.identities, d.added.identities);
    sides(from.networks, to.networks, d.added.networks);
    sides(to.servers, from.servers, d.removed.servers);
    sides(to.identities, from.identities, d.removed.identities);
    sides(to.networks, from.networks, d.removed.networks);
    return d;
}

// The devices the relay learned belong to a listed identity, from the fold of the rosters
// shown for it (members and consented pending joins, never a pending the device itself did
// not sign). Only someone holding that identity's keys can add one, so the bound is against
// the identity itself: past it its least recently confirmed device goes, which a device in
// the fold just learned never is (a fold holds far fewer than PER_IDENTITY).
class Learned {
public:
    static constexpr size_t PER_IDENTITY = 512;
    static constexpr size_t TOTAL = 262144;

    // Learns `devices` for `master`, each confirmed afresh; returns the ones it did not hold.
    std::vector<std::string> learn(const std::string& master, const std::set<std::string>& devices) {
        Held& h = held_[master];
        std::vector<std::string> fresh;
        for (const auto& d : devices) {
            auto it = h.stamp_of.find(d);
            if (it != h.stamp_of.end()) {
                h.by_stamp.erase(it->second);
                it->second = ++next_;
                h.by_stamp.emplace(it->second, d);
                continue;
            }
            const uint64_t s = ++next_;
            h.stamp_of.emplace(d, s);
            h.by_stamp.emplace(s, d);
            refs_[d]++;
            total_++;
            fresh.push_back(d);
        }
        while (h.stamp_of.size() > PER_IDENTITY) drop_oldest(h);
        while (total_ > TOTAL) {
            auto heaviest = held_.end();
            for (auto it = held_.begin(); it != held_.end(); ++it) {
                if (heaviest == held_.end() || it->second.stamp_of.size() > heaviest->second.stamp_of.size()) {
                    heaviest = it;
                }
            }
            if (heaviest == held_.end() || heaviest->second.stamp_of.empty()) break;
            drop_oldest(heaviest->second);
            if (heaviest->second.stamp_of.empty()) held_.erase(heaviest);
        }
        auto mit = held_.find(master);
        if (mit == held_.end()) return {};
        if (mit->second.stamp_of.empty()) {
            held_.erase(mit);
            return {};
        }
        fresh.erase(std::remove_if(fresh.begin(), fresh.end(),
                                   [&](const std::string& d) { return !mit->second.stamp_of.count(d); }),
                    fresh.end());
        return fresh;
    }

    bool has(const std::string& device) const { return refs_.count(device) != 0; }
    bool holds(const std::string& master, const std::string& device) const {
        auto it = held_.find(master);
        return it != held_.end() && it->second.stamp_of.count(device) != 0;
    }

    void forget(const std::string& master) {
        auto it = held_.find(master);
        if (it == held_.end()) return;
        for (const auto& [d, s] : it->second.stamp_of) unref(d);
        total_ -= it->second.stamp_of.size();
        held_.erase(it);
    }

    size_t size() const { return total_; }

    // Every identity's devices, least recently confirmed first: the order a restore keeps.
    std::vector<std::pair<std::string, std::vector<std::string>>> entries() const {
        std::vector<std::pair<std::string, std::vector<std::string>>> out;
        for (const auto& [master, h] : held_) {
            std::vector<std::string> ds;
            for (const auto& [s, d] : h.by_stamp) ds.push_back(d);
            out.push_back({master, std::move(ds)});
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    std::vector<std::string> devices_of(const std::string& master) const {
        std::vector<std::string> ds;
        auto it = held_.find(master);
        if (it == held_.end()) return ds;
        for (const auto& [s, d] : it->second.by_stamp) ds.push_back(d);
        return ds;
    }

private:
    struct Held {
        std::map<uint64_t, std::string> by_stamp;
        std::unordered_map<std::string, uint64_t> stamp_of;
    };

    void unref(const std::string& d) {
        auto r = refs_.find(d);
        if (r != refs_.end() && --r->second == 0) refs_.erase(r);
    }

    void drop_oldest(Held& h) {
        auto it = h.by_stamp.begin();
        if (it == h.by_stamp.end()) return;
        unref(it->second);
        h.stamp_of.erase(it->second);
        h.by_stamp.erase(it);
        total_--;
    }

    std::unordered_map<std::string, Held> held_;
    std::unordered_map<std::string, size_t> refs_;
    size_t total_ = 0;
    uint64_t next_ = 0;
};

// What the relay holds of the list. `list` is what every refusal reads; `applied` is the
// list whose consequences (rooms dropped, sockets closed, buffers emptied) have all run,
// so an apply cut short runs again on the next tick (review D10).
struct State {
    List list;
    List applied;
    Learned learned;
    // The file as it was when last judged: a clean apply or a refusal to read it.
    FileStamp judged;
    bool judged_once = false;
    // What the previous process held (restart snapshot), read before the file is judged
    // at start: a file missing or unreadable then keeps it (review D8, D9).
    std::optional<List> carried;
    std::vector<std::pair<std::string, std::vector<std::string>>> carried_learned;
    // Devices learned since the last settle, whose sockets, sessions and data still wait.
    std::vector<std::string> purge_due;
    // Of those, the ones whose frames in other people's buffers still wait for a scan.
    std::set<std::string> scan_due;

    bool server_denied(std::string_view room) const {
        if (list.servers.empty() || room.size() > 128) return false;
        return list.servers.count(lower(room)) != 0;
    }
    bool peer_denied(const std::string& peer) const {
        return list.identities.count(peer) != 0 || learned.has(peer);
    }
    bool network_denied(const std::string& ip_key) const { return list.networks.count(ip_key) != 0; }

    // Learns what a fold of `master`'s rosters counts (members and consented pending joins)
    // when `master` is listed; returns the devices it did not know.
    std::vector<std::string> learn_fold(const std::string& master, const std::set<std::string>& members,
                                        const std::set<std::string>& pending) {
        if (!list.identities.count(master)) return {};
        std::set<std::string> all = members;
        all.insert(pending.begin(), pending.end());
        all.erase(master);
        return learned.learn(master, all);
    }
};

// Whether the file changed since it was last judged (or never was).
inline bool due(const State& st, const FileStamp& now) { return !st.judged_once || now != st.judged; }

// One judged reading of the file: a good one becomes the list every refusal reads, a bad
// or missing one keeps the list in force. Whatever the list gained or lost since the
// last full apply is applied, and only once that returns do the list count as applied
// and the file as judged, so an apply cut short by a throw runs again (review D10).
template <typename Apply>
inline void take(State& st, const Loaded& l, Apply&& apply) {
    if (l.read == Read::Ok) st.list = l.list;
    if (st.applied != st.list) {
        apply(diff(st.applied, st.list));
        st.applied = st.list;
    }
    st.judged = l.stamp;
    st.judged_once = true;
}

}  // namespace deny
