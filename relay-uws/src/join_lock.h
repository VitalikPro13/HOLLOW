#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "fair_share.h"
#include "json.hpp"
#include "validate.h"

// The join lock chains: a notice board, nothing more. Each server's members keep a
// door key joiners seal requests to and a change key only its owner, admins and mods
// hold; the relay keeps the chain of public halves and takes a new lock only when
// the current change key signed it, so a joiner reading the newest one knows nobody
// removed since holds its door. The relay can withhold a chain, never forge one:
// every link is checked again by whoever reads it.
//
// Mirrors rust/hollow_core/src/node/join_lock.rs byte for byte (payload, shapes,
// chain rules, the put rule); test/test_join_lock.cpp pins the same vectors as the
// Rust test. Header-only and free of uWebSockets and libsodium: the three crypto
// operations come in through LockCrypto, and the relay's fold of an identity's
// rosters through LockCounted, so the rules are unit tested with stubs.
//
// Every 0.14 link names the device that made it (`dev`), signed by that device. The
// master key alone proves nothing here: an owner-signed link the relay does not hold
// is taken only from an owner device its fold counts, and a link whose proof names a
// device it no longer counts is DEAD: a counted device of the owner, or of the dead
// link's own identity, holding the change key before it may extend past it.

struct LockLink {
    uint64_t n = 0;
    std::string door;
    std::string change;
    std::string sig;
    std::string owner;
    std::string nonce;
    // The device that made the link: its key, the identity it names, its signature.
    std::string dev_device;
    std::string dev_master;
    std::string dev_sig;
    // Presence, not emptiness, is what the client's shape rule reads.
    bool has_owner = false;
    bool has_nonce = false;
    bool has_dev = false;

    bool is_base() const { return has_owner; }
    bool same_lock(const LockLink& o) const { return n == o.n && door == o.door && change == o.change; }
    bool operator==(const LockLink& o) const {
        return n == o.n && door == o.door && change == o.change && sig == o.sig && owner == o.owner &&
               nonce == o.nonce && has_owner == o.has_owner && has_nonce == o.has_nonce && has_dev == o.has_dev &&
               dev_device == o.dev_device && dev_master == o.dev_master && dev_sig == o.dev_sig;
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

// Whether the relay's fold of `master`'s rosters counts `device` a member of it.
using LockCounted = std::function<bool(const std::string& master, const std::string& device)>;

namespace join_lock {

static constexpr size_t MAX_CHAIN = 256;
static constexpr uint64_t MAX_N = (uint64_t{1} << 53) - 1;
// The furthest an owner-signed link may jump past the newest lock: 2^33 resets from
// the ceiling, so no master-key holder freezes a lock there.
static constexpr uint64_t RESET_STEP = uint64_t{1} << 20;
// A newest lock above this is frozen (no honest chain gets there): a counted owner
// device starts over.
static constexpr uint64_t FROZEN_FROM = MAX_N - RESET_STEP;

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
    if (l.has_dev && (!key_shape(l.dev_device) || !is_peer_id_shape(l.dev_master) || l.dev_sig.size() != 88 ||
                      !b64_chars(l.dev_sig, false))) {
        return false;
    }
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

inline std::string dev_payload(const std::string& server, const LockLink& l) {
    return "hollow-lock-dev1\n" + l.dev_master + "\n" + payload(server, l);
}

struct LinkDevice {
    std::string master;
    std::string device;
    bool empty() const { return device.empty(); }
};

// The device that made `l` and the identity it names, when its proof verifies. An
// owner-signed link's device must name the owner.
inline LinkDevice link_device(const std::string& server, const LockLink& l, const LockCrypto& c) {
    if (!l.has_dev || !well_formed(l)) return {};
    std::string device = c.peer_id(l.dev_device);
    if (device.empty()) return {};
    if (l.has_owner && c.peer_id(l.owner) != l.dev_master) return {};
    if (!c.verify(l.dev_device, l.dev_sig, dev_payload(server, l))) return {};
    return {l.dev_master, device};
}

// The owner an owner-signed link speaks for, or "".
inline std::string base_owner(const std::string& server, const LockLink& l, const LockCrypto& c) {
    if (!l.has_owner || !well_formed(l)) return "";
    std::string owner = c.peer_id(l.owner);
    if (owner.empty()) return "";
    if (is_genesis_id(server) && (!l.has_nonce || c.genesis_id(owner, l.nonce) != server)) return "";
    // A device proof that does not verify makes the link a forgery, never a 0.13 one.
    if (l.has_dev && link_device(server, l, c).empty()) return "";
    return c.verify(l.owner, l.sig, payload(server, l)) ? owner : "";
}

inline bool extends(const std::string& server, const LockLink& prev, const LockLink& next, const LockCrypto& c) {
    return !next.is_base() && well_formed(next) && prev.n < MAX_N && next.n == prev.n + 1 &&
           (!next.has_dev || !link_device(server, next, c).empty()) &&
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
// refused (the Rust mirror's doc names each rule):
// - the first valid extension of the newest lock wins; a link a counted device made
//   may extend an older held lock when every link after it is dead (its proof names a
//   device the fold no longer counts) and of the forker's identity, unless the forker
//   is the owner; a link without a proof is never dead;
// - an owner-signed link the relay does not hold needs a counted owner device, and
//   resets a fork by at most RESET_STEP past the newest;
// - a new link after one with a device proof, or with one, needs a counted device;
// - a shorter chain ending in the same lock compacts it; a frozen newest lock gives
//   way to a counted owner device's new start.
inline std::optional<std::vector<LockLink>> relay_put(const std::string& server,
                                                      const std::vector<LockLink>& held,
                                                      const std::vector<LockLink>& submitted,
                                                      const LockCrypto& c, const LockCounted& counted) {
    auto made_counted = [&](const LockLink& l) {
        LinkDevice d = link_device(server, l, c);
        return !d.empty() && counted(d.master, d.device);
    };
    if (submitted.empty()) return std::nullopt;
    if (!submitted[0].is_base()) {
        if (held.empty()) return std::nullopt;
        size_t at = held.size() - 1;
        if (!extends(server, held[at], submitted[0], c)) {
            bool found = false;
            for (size_t i = held.size() - 1; i-- > 0;) {
                if (extends(server, held[i], submitted[0], c)) {
                    at = i;
                    found = true;
                    break;
                }
            }
            if (!found) return std::nullopt;
            const LinkDevice forker = link_device(server, submitted[0], c);
            if (forker.empty() || !counted(forker.master, forker.device)) return std::nullopt;
            const std::string owner = base_owner(server, held.front(), c);
            for (size_t i = at + 1; i < held.size(); i++) {
                const LinkDevice dead = link_device(server, held[i], c);
                if (dead.empty() || counted(dead.master, dead.device) ||
                    (forker.master != owner && dead.master != forker.master)) {
                    return std::nullopt;
                }
            }
        }
        const LockLink* prev = &held[at];
        for (const auto& l : submitted) {
            if (!extends(server, *prev, l, c)) return std::nullopt;
            if ((prev->has_dev || l.has_dev) && !made_counted(l)) return std::nullopt;
            prev = &l;
        }
        if (at + 1 + submitted.size() > MAX_CHAIN) return std::nullopt;
        std::vector<LockLink> out(held.begin(), held.begin() + static_cast<std::ptrdiff_t>(at + 1));
        out.insert(out.end(), submitted.begin(), submitted.end());
        return out;
    }
    std::string owner = verify_chain(server, submitted, c);
    if (owner.empty()) return std::nullopt;
    static const std::vector<LockLink> none;
    const std::vector<LockLink>& stored = !held.empty() && held.back().n > FROZEN_FROM ? none : held;
    const uint64_t held_n = stored.empty() ? 0 : stored.back().n;
    for (size_t i = 0; i < submitted.size(); i++) {
        const LockLink& l = submitted[i];
        bool new_base = false;
        if (l.is_base()) {
            new_base = true;
            for (const auto& h : stored) new_base = new_base && !(h == l);
        }
        bool new_next = !l.is_base() && l.n > held_n && (l.has_dev || (i > 0 && submitted[i - 1].has_dev));
        if ((new_base || new_next) && !made_counted(l)) return std::nullopt;
    }
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
        if ((continues || reset) && newest.n - tip.n <= RESET_STEP) return submitted;
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
    if (auto it = j.find("dev"); it != j.end()) {
        if (!it->is_object()) return std::nullopt;
        auto field = [&it](const char* name, std::string& out) {
            auto f = it->find(name);
            if (f == it->end() || !f->is_string()) return false;
            out = f->get<std::string>();
            return true;
        };
        if (!field("device", l.dev_device) || !field("master", l.dev_master) || !field("sig", l.dev_sig)) {
            return std::nullopt;
        }
        l.has_dev = true;
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
        if (l.has_dev) o["dev"] = {{"device", l.dev_device}, {"master", l.dev_master}, {"sig", l.dev_sig}};
        arr.push_back(std::move(o));
    }
    return arr;
}

}  // namespace join_lock

// Every server's chain by record key, charged to the share of whoever last changed
// it. Anyone may file a chain (a joiner is not a member, a legacy id takes any
// owner), so the byte budget is what bounds the table (HOL-SEC-069): past it the
// share holding the most bytes loses its least recently used record, and a real
// server's members put a lost chain back the next time they connect.
struct JoinLocks {
    static constexpr size_t MAX_BYTES = 128ull * 1024 * 1024;

    size_t budget = MAX_BYTES;
    std::unordered_map<std::string, std::vector<LockLink>> records;
    FairShare<std::string> ledger;

    size_t size() const { return records.size(); }
    size_t bytes() const { return ledger.total(); }

    // What one record costs the relay, near enough to bound its RAM.
    static size_t record_bytes(const std::string& key, const std::vector<LockLink>& links) {
        size_t n = 256 + key.size();
        for (const auto& l : links) {
            n += sizeof(LockLink) + 64 + l.door.size() + l.change.size() + l.sig.size() + l.owner.size() +
                 l.nonce.size() + l.dev_device.size() + l.dev_master.size() + l.dev_sig.size();
        }
        return n;
    }

    const std::vector<LockLink>* get(const std::string& key) {
        auto it = records.find(key);
        if (it == records.end()) return nullptr;
        ledger.touch(key);
        return &it->second;
    }

    // Offer a chain for (server, owner) from `share`. `owner` keys a legacy id, so an
    // owner-signed link must name it; a self-certifying id names its owner itself.
    // Returns whether the submitted newest lock is now the relay's, and fills `current`.
    bool put(const std::string& server, const std::string& owner, const std::vector<LockLink>& submitted,
             const LockCrypto& c, const LockCounted& counted, std::vector<LockLink>& current, uint64_t share) {
        std::string key = join_lock::record_key(server, owner);
        auto it = records.find(key);
        std::vector<LockLink> stored = it == records.end() ? std::vector<LockLink>{} : it->second;
        current = stored;
        if (submitted.empty()) return false;
        if (submitted[0].is_base() && !join_lock::is_genesis_id(server) &&
            join_lock::base_owner(server, submitted[0], c) != owner) {
            return false;
        }
        auto next = join_lock::relay_put(server, stored, submitted, c, counted);
        if (!next) return false;
        if (it != records.end() && *next == stored) {
            ledger.touch(key);
        } else {
            size_t weight = record_bytes(key, *next);
            records[key] = std::move(*next);
            ledger.put(key, share, weight);
            enforce_budget();
        }
        auto held = records.find(key);
        if (held == records.end()) {
            current.clear();
            return false;
        }
        current = held->second;
        return !current.empty() && current.back().same_lock(submitted.back());
    }

    // Restore from a snapshot, least recently used first so eviction order survives.
    void restore(const std::string& key, std::vector<LockLink> links, uint64_t share) {
        if (links.empty() || links.size() > join_lock::MAX_CHAIN) return;
        size_t weight = record_bytes(key, links);
        records[key] = std::move(links);
        ledger.put(key, share, weight);
        enforce_budget();
    }

   private:
    void enforce_budget() {
        while (ledger.total() > budget) {
            auto victim = ledger.victim();
            if (!victim) break;
            records.erase(*victim);
            ledger.remove(*victim);
        }
    }
};
