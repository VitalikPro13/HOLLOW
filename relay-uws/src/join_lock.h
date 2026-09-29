#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "json.hpp"

// The join lock chains: a notice board, nothing more. Each server's members keep a
// door key joiners seal requests to and a change key only its owner, admins and mods
// hold; the relay keeps the chain of public halves and takes a new lock only when
// the current change key signed it, so a joiner reading the newest one knows nobody
// removed since holds its door. The relay can withhold a chain, never forge one:
// every link is checked again by whoever reads it.
//
// Mirrors rust/hollow_core/src/node/join_lock.rs byte for byte (payload, shapes,
// chain rules, the put rule); test/test_join_lock.cpp pins the same vector as the
// Rust test. Header-only and free of uWebSockets and libsodium: the three crypto
// operations come in through LockCrypto, so the rules are unit tested with stubs.

struct LockLink {
    uint64_t n = 0;
    std::string door;
    std::string change;
    std::string sig;
    std::string owner;
    std::string nonce;
    // Presence, not emptiness, is what the client's shape rule reads.
    bool has_owner = false;
    bool has_nonce = false;

    bool is_base() const { return has_owner; }
    bool same_lock(const LockLink& o) const { return n == o.n && door == o.door && change == o.change; }
    bool operator==(const LockLink& o) const {
        return n == o.n && door == o.door && change == o.change && sig == o.sig && owner == o.owner &&
               nonce == o.nonce && has_owner == o.has_owner && has_nonce == o.has_nonce;
    }
};

struct LockCrypto {
    // Ed25519 over `msg` by the protobuf-encoded key, base64 like the auth frame's.
    std::function<bool(const std::string& key_b64, const std::string& sig_b64, const std::string& msg)> verify;
    // The peer id a protobuf-encoded key derives, "" when it is not one.
    std::function<std::string(const std::string& key_b64)> peer_id;
    // The self-certifying server id an owner and a founding nonce hash to.
    std::function<std::string(const std::string& owner, const std::string& nonce)> genesis_id;
};

namespace join_lock {

static constexpr size_t MAX_CHAIN = 256;
static constexpr uint64_t MAX_N = (uint64_t{1} << 53) - 1;

inline bool is_genesis_id(std::string_view id) {
    if (id.size() != 40) return false;
    for (char c : id) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

// A server id as a map key: a legacy 32-hex id or a self-certifying 40-hex one.
inline bool is_server_id_shape(std::string_view id) {
    if (id.size() != 32 && id.size() != 40) return false;
    for (char c : id) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

inline bool b64_chars(std::string_view s, bool url_safe) {
    for (size_t i = 0; i < s.size(); i++) {
        char c = s[i];
        bool alnum = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        bool extra = url_safe ? (c == '-' || c == '_') : (c == '+' || c == '/');
        if (!alnum && !extra) {
            // Standard base64 of 64 bytes ends in exactly "==".
            if (!url_safe && c == '=' && i + 2 >= s.size() && s.size() == 88) continue;
            return false;
        }
    }
    return true;
}

// Every field within the one shape the client stores, before any signature is read.
inline bool well_formed(const LockLink& l) {
    auto key_shape = [](const std::string& k) { return k.size() == 48 && b64_chars(k, false); };
    if (l.n > MAX_N) return false;
    if (l.door.size() != 43 || !b64_chars(l.door, true)) return false;
    if (!key_shape(l.change)) return false;
    if (l.sig.size() != 88 || !b64_chars(l.sig, false)) return false;
    if (l.has_owner && !key_shape(l.owner)) return false;
    if (l.has_nonce) {
        if (l.nonce.size() > 64) return false;
        for (char c : l.nonce) {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
        }
    }
    return l.has_owner || !l.has_nonce;
}

inline std::string payload(const std::string& server, const LockLink& l) {
    std::string head = "hollow-lock1\n" + server + "\n" + std::to_string(l.n) + "\n" + l.door + "\n" + l.change + "\n";
    if (l.has_owner) return head + "base\n" + l.owner + "\n" + l.nonce;
    return head + "next";
}

// The owner an owner-signed link speaks for, or "".
inline std::string base_owner(const std::string& server, const LockLink& l, const LockCrypto& c) {
    if (!l.has_owner || !well_formed(l)) return "";
    std::string owner = c.peer_id(l.owner);
    if (owner.empty()) return "";
    if (is_genesis_id(server) && (!l.has_nonce || c.genesis_id(owner, l.nonce) != server)) return "";
    return c.verify(l.owner, l.sig, payload(server, l)) ? owner : "";
}

inline bool extends(const std::string& server, const LockLink& prev, const LockLink& next, const LockCrypto& c) {
    return !next.is_base() && well_formed(next) && prev.n < MAX_N && next.n == prev.n + 1 &&
           c.verify(prev.change, next.sig, payload(server, next));
}

// The owner a whole chain speaks for, or "".
inline std::string verify_chain(const std::string& server, const std::vector<LockLink>& links, const LockCrypto& c) {
    if (links.empty() || links.size() > MAX_CHAIN) return "";
    std::string owner = base_owner(server, links[0], c);
    if (owner.empty()) return "";
    for (size_t i = 1; i < links.size(); i++) {
        const LockLink& prev = links[i - 1];
        const LockLink& next = links[i];
        bool ok = next.is_base() ? (next.n > prev.n && base_owner(server, next, c) == owner)
                                 : extends(server, prev, next, c);
        if (!ok) return "";
    }
    return owner;
}

inline std::string record_key(const std::string& server, const std::string& owner) {
    return is_genesis_id(server) ? server : server + "|" + owner;
}

// The chain held after `submitted` is offered against `stored`, or nullopt when
// refused: the first valid extension wins, an owner-signed link past the newest
// resets a fork, a shorter chain ending in the same lock compacts it.
inline std::optional<std::vector<LockLink>> relay_put(const std::string& server,
                                                      const std::vector<LockLink>& stored,
                                                      const std::vector<LockLink>& submitted,
                                                      const LockCrypto& c) {
    if (submitted.empty()) return std::nullopt;
    if (!submitted[0].is_base()) {
        if (stored.empty()) return std::nullopt;
        const LockLink* prev = &stored.back();
        for (const auto& l : submitted) {
            if (!extends(server, *prev, l, c)) return std::nullopt;
            prev = &l;
        }
        if (stored.size() + submitted.size() > MAX_CHAIN) return std::nullopt;
        std::vector<LockLink> out = stored;
        out.insert(out.end(), submitted.begin(), submitted.end());
        return out;
    }
    std::string owner = verify_chain(server, submitted, c);
    if (owner.empty()) return std::nullopt;
    if (stored.empty()) return submitted;
    if (base_owner(server, stored.front(), c) != owner) return std::nullopt;
    const LockLink& tip = stored.back();
    const LockLink& newest = submitted.back();
    if (newest.n > tip.n) {
        bool continues = false;
        for (const auto& l : submitted) continues = continues || l.same_lock(tip);
        bool reset = false;
        for (auto it = submitted.rbegin(); it != submitted.rend(); ++it) {
            if (it->is_base()) {
                reset = it->n > tip.n;
                break;
            }
        }
        if (continues || reset) return submitted;
        return std::nullopt;
    }
    if (newest.same_lock(tip)) return submitted.size() < stored.size() ? submitted : stored;
    return std::nullopt;
}

inline std::optional<LockLink> link_from_json(const nlohmann::json& j) {
    if (!j.is_object()) return std::nullopt;
    LockLink l;
    auto n = j.find("n");
    if (n == j.end() || !n->is_number_unsigned()) return std::nullopt;
    l.n = n->get<uint64_t>();
    auto text = [&j](const char* field, std::string& out) {
        auto it = j.find(field);
        if (it == j.end() || !it->is_string()) return false;
        out = it->get<std::string>();
        return true;
    };
    if (!text("door", l.door) || !text("change", l.change) || !text("sig", l.sig)) return std::nullopt;
    if (auto it = j.find("owner"); it != j.end()) {
        if (!it->is_string()) return std::nullopt;
        l.owner = it->get<std::string>();
        l.has_owner = true;
    }
    if (auto it = j.find("nonce"); it != j.end()) {
        if (!it->is_string()) return std::nullopt;
        l.nonce = it->get<std::string>();
        l.has_nonce = true;
    }
    return l;
}

// The whole array or nothing: a chain with one unreadable link is not a chain.
inline std::optional<std::vector<LockLink>> links_from_json(const nlohmann::json& j) {
    if (!j.is_array() || j.size() > MAX_CHAIN) return std::nullopt;
    std::vector<LockLink> out;
    for (const auto& e : j) {
        auto l = link_from_json(e);
        if (!l) return std::nullopt;
        out.push_back(std::move(*l));
    }
    return out;
}

inline nlohmann::json links_to_json(const std::vector<LockLink>& links) {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& l : links) {
        nlohmann::json o = {{"n", l.n}, {"door", l.door}, {"change", l.change}, {"sig", l.sig}};
        if (l.has_owner) o["owner"] = l.owner;
        if (l.has_nonce) o["nonce"] = l.nonce;
        arr.push_back(std::move(o));
    }
    return arr;
}

}  // namespace join_lock

// Every server's chain by record key. A chain is at most MAX_CHAIN links (owners
// compact it); past MAX_RECORDS the least recently read or written record goes,
// and its members put it back the next time they connect.
struct JoinLocks {
    static constexpr size_t MAX_RECORDS = 100000;

    struct Record {
        std::vector<LockLink> links;
        uint64_t touched = 0;
    };

    std::unordered_map<std::string, Record> records;
    uint64_t clock = 0;

    size_t size() const { return records.size(); }

    const std::vector<LockLink>* get(const std::string& key) {
        auto it = records.find(key);
        if (it == records.end()) return nullptr;
        it->second.touched = ++clock;
        return &it->second.links;
    }

    // Offer a chain for (server, owner). `owner` keys a legacy id, so an owner-signed
    // link must name it; a self-certifying id names its owner itself. Returns
    // whether the submitted newest lock is now the relay's, and fills `current`.
    bool put(const std::string& server, const std::string& owner, const std::vector<LockLink>& submitted,
             const LockCrypto& c, std::vector<LockLink>& current) {
        std::string key = join_lock::record_key(server, owner);
        auto it = records.find(key);
        std::vector<LockLink> stored = it == records.end() ? std::vector<LockLink>{} : it->second.links;
        current = stored;
        if (submitted.empty()) return false;
        if (submitted[0].is_base() && !join_lock::is_genesis_id(server) &&
            join_lock::base_owner(server, submitted[0], c) != owner) {
            return false;
        }
        auto next = join_lock::relay_put(server, stored, submitted, c);
        if (!next) return false;
        if (it == records.end() && records.size() >= MAX_RECORDS) evict_oldest();
        Record& rec = records[key];
        rec.links = std::move(*next);
        rec.touched = ++clock;
        current = rec.links;
        return !current.empty() && current.back().same_lock(submitted.back());
    }

    // Restore from a snapshot, oldest first so eviction order survives.
    void restore(const std::string& key, std::vector<LockLink> links) {
        if (links.empty() || links.size() > join_lock::MAX_CHAIN) return;
        if (records.find(key) == records.end() && records.size() >= MAX_RECORDS) evict_oldest();
        Record& rec = records[key];
        rec.links = std::move(links);
        rec.touched = ++clock;
    }

   private:
    // Only at the cap, so the scan costs less than keeping an eviction index.
    void evict_oldest() {
        auto oldest = records.end();
        for (auto it = records.begin(); it != records.end(); ++it) {
            if (oldest == records.end() || it->second.touched < oldest->second.touched) oldest = it;
        }
        if (oldest != records.end()) records.erase(oldest);
    }
};
