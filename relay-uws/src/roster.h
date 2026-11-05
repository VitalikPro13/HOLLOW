#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <vector>

#include "json.hpp"

// An identity's roster (design ID-1): the signed statements that say which devices are
// one person's, each verifiable alone. The relay folds every roster shown on an
// `inbox:` join into one per master and lets a socket own the inbox only while its
// device is a member (design ID-1R).
//
// Mirrors rust/hollow_core/src/identity/roster.rs rule for rule: the JSON shape, every
// signed payload, verification, the merge, the compaction and the fold.
// test/test_roster.cpp checks this file against the vectors the Rust tests write
// (test/roster_vectors.json); change both or neither. Header-only and free of
// libsodium: the crypto comes in through RosterCrypto.

struct RosterCrypto {
    // Ed25519 over `msg` by the key a peer id names; false when it names none.
    std::function<bool(const std::string& peer_id, const std::string& sig_b64, const std::string& msg)> verify_by_id;
    // Ed25519 over `msg` by a raw 32-byte key in standard base64.
    std::function<bool(const std::string& key_b64, const std::string& sig_b64, const std::string& msg)> verify_by_key;
    // Whether a peer id names an Ed25519 key.
    std::function<bool(const std::string& peer_id)> is_key;
    // Lowercase hex SHA-256.
    std::function<std::string(const std::string& msg)> sha256_hex;
};

namespace roster {

inline const std::string LEGACY_BASE = "legacy";
static constexpr int64_t PENDING_MATURITY_MS = 7LL * 24 * 60 * 60 * 1000;
static constexpr int64_t MAX_FUTURE_SKEW_MS = 10LL * 60 * 1000;
static constexpr size_t MAX_ROSTER_BYTES = 256 * 1024;
static constexpr size_t MAX_VOUCHES = 128;
static constexpr size_t MAX_REMOVALS = 96;
// Removals kept outside MAX_REMOVALS: per standing target, the removal the walk counted
// first, the shallowest targets first (identity/roster.rs MAX_RESERVED).
static constexpr size_t MAX_RESERVED = 32;
static constexpr size_t MAX_REMOVAL_KEEP = 16;
static constexpr size_t MAX_KEEP = 64;
static constexpr size_t MAX_RECOVERY_TIES = 4;
static constexpr size_t MAX_PHRASE_ADMITS = 64;
static constexpr size_t MAX_LEGACY = 64;
static constexpr size_t MAX_PENDING = 16;
static constexpr size_t MAX_CONSENTS = 96;
static constexpr size_t MAX_UNNAMED_CONSENTS = 8;

using Ids = std::vector<std::string>;

// Field order is the Rust derive(Ord) order: every sort below depends on it.
struct Consent {
    std::string device, sig;
    auto tie() const { return std::tie(device, sig); }
    bool operator<(const Consent& o) const { return tie() < o.tie(); }
    bool operator==(const Consent& o) const { return tie() == o.tie(); }
};
struct Recovery {
    int64_t at_ms = 0;
    Ids keep;
    bool no_wait = false;
    std::string sig_r, sig_m;
    auto tie() const { return std::tie(at_ms, keep, no_wait, sig_r, sig_m); }
    bool operator<(const Recovery& o) const { return tie() < o.tie(); }
    bool operator==(const Recovery& o) const { return tie() == o.tie(); }
};
struct PhraseAdmit {
    int64_t at_ms = 0;
    std::string device, sig_r, sig_m;
    auto tie() const { return std::tie(at_ms, device, sig_r, sig_m); }
    bool operator<(const PhraseAdmit& o) const { return tie() < o.tie(); }
    bool operator==(const PhraseAdmit& o) const { return tie() == o.tie(); }
};
struct Vouch {
    std::string base, device, by, sig;
    auto tie() const { return std::tie(base, device, by, sig); }
    bool operator<(const Vouch& o) const { return tie() < o.tie(); }
    bool operator==(const Vouch& o) const { return tie() == o.tie(); }
};
struct Pending {
    std::string base, device, sig_m;
    auto tie() const { return std::tie(base, device, sig_m); }
    bool operator<(const Pending& o) const { return tie() < o.tie(); }
    bool operator==(const Pending& o) const { return tie() == o.tie(); }
};
struct LegacyClaim {
    std::string device, sig_m;
    auto tie() const { return std::tie(device, sig_m); }
    bool operator<(const LegacyClaim& o) const { return tie() < o.tie(); }
    bool operator==(const LegacyClaim& o) const { return tie() == o.tie(); }
};
struct Removal {
    std::string base, device, by;
    Ids keep_vouched;
    std::string sig;
    auto tie() const { return std::tie(base, device, by, keep_vouched, sig); }
    bool operator<(const Removal& o) const { return tie() < o.tie(); }
    bool operator==(const Removal& o) const { return tie() == o.tie(); }
};

// What a roster says at one moment, for one observer.
struct State {
    std::string base;
    bool is_protected = false;
    bool no_wait = false;
    std::set<std::string> members;
    std::map<std::string, std::string> removed;  // removed device -> the device that removed it
    std::set<std::string> pending;
    bool is_member(const std::string& d) const { return members.count(d) != 0; }
};

// Which devices write for an identity in server authority (identity/roster.rs
// `Authority`, without the digest): no clock, no maturity, no first sight.
struct Authority {
    std::string key, base;
    std::set<std::string> counted;
    std::map<std::string, std::string> removed;  // removed device -> the device whose removal counted first
    bool counts(const std::string& d) const { return counted.count(d) != 0; }
};

// A standing device's place: tier, depth, then its id.
using Rank = std::tuple<uint8_t, uint32_t, std::string>;

template <typename T>
inline void sort_cap(std::vector<T>& v, size_t cap) {
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    if (v.size() > cap) v.resize(cap);
}

template <typename T>
inline void push_unique(std::vector<T>& into, const std::vector<T>& from) {
    into.insert(into.end(), from.begin(), from.end());
    std::sort(into.begin(), into.end());
    into.erase(std::unique(into.begin(), into.end()), into.end());
}

inline Ids sorted_ids(Ids v) {
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v;
}

inline std::string csv(const Ids& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); i++) {
        if (i) out += ',';
        out += v[i];
    }
    return out;
}

// -- The removal walk and the vouch cap's judge (identity/roster.rs, HOL-SEC-189) --

// What counted removals void: a removed voucher's vouches count only for the vouchees
// EVERY counted removal of it keeps (HOL-SEC-080).
struct Voids {
    std::map<std::string, std::set<std::string>> kept_by;

    static Voids of(const std::vector<const Removal*>& counted) {
        Voids out;
        for (const Removal* r : counted) {
            std::set<std::string> keep(r->keep_vouched.begin(), r->keep_vouched.end());
            auto it = out.kept_by.find(r->device);
            if (it == out.kept_by.end()) {
                out.kept_by.emplace(r->device, std::move(keep));
                continue;
            }
            for (auto k = it->second.begin(); k != it->second.end();) {
                k = keep.count(*k) ? std::next(k) : it->second.erase(k);
            }
        }
        return out;
    }
    bool allows(const Vouch& v) const {
        auto it = kept_by.find(v.by);
        return it == kept_by.end() || it->second.count(v.device) != 0;
    }
};

// Rank by (tier, depth, id) over (voucher, vouchee) edges: tier 0 grows from seeds[0],
// tier 1 from seeds[1] among what tier 0 did not reach.
inline std::map<std::string, Rank> rank_over(const std::set<std::string> (&seeds)[2],
                                             const std::vector<std::pair<std::string, std::string>>& edges) {
    std::map<std::string, std::set<std::string>> vouchees;
    for (const auto& [by, d] : edges) vouchees[by].insert(d);
    std::map<std::string, std::pair<uint8_t, uint32_t>> rank;
    for (uint8_t tier = 0; tier < 2; tier++) {
        std::set<std::string> frontier;
        for (const auto& d : seeds[tier]) {
            if (!rank.count(d)) frontier.insert(d);
        }
        uint32_t depth = 0;
        while (!frontier.empty()) {
            for (const auto& d : frontier) rank[d] = {tier, depth};
            std::set<std::string> next;
            for (const auto& by : frontier) {
                auto it = vouchees.find(by);
                if (it == vouchees.end()) continue;
                for (const auto& d : it->second) {
                    if (!rank.count(d)) next.insert(d);
                }
            }
            frontier = std::move(next);
            depth++;
        }
    }
    std::map<std::string, Rank> out;
    for (const auto& [d, td] : rank) out.emplace(d, Rank{td.first, td.second, d});
    return out;
}

// `seed` and every device a member of the result vouched for where `voids` allows it,
// each mapped to the vouch that reached it first in a breadth-first pass (seeds: null).
inline std::map<std::string, const Vouch*> valid_closure(const std::set<std::string>& seed,
                                                         const std::vector<const Vouch*>& vouches,
                                                         const Voids& voids) {
    std::map<std::string, std::vector<const Vouch*>> next;
    for (const Vouch* v : vouches) {
        if (voids.allows(*v)) next[v->by].push_back(v);
    }
    for (auto& [by, list] : next) {
        std::sort(list.begin(), list.end(), [](const Vouch* a, const Vouch* b) { return *a < *b; });
    }
    std::map<std::string, const Vouch*> reached;
    std::deque<std::string> queue;
    for (const auto& d : seed) {
        reached.emplace(d, nullptr);
        queue.push_back(d);
    }
    while (!queue.empty()) {
        const std::string d = std::move(queue.front());
        queue.pop_front();
        auto it = next.find(d);
        if (it == next.end()) continue;
        for (const Vouch* v : it->second) {
            if (reached.emplace(v->device, v).second) queue.push_back(v->device);
        }
    }
    return reached;
}

// What the removal walk counted, and its support: for each alive signer, the vouches of
// the path that made it valid at its turn.
struct Walk {
    std::vector<const Removal*> counted;
    std::set<Vouch> support;

    // Per removed device, the counted removal that removed it first.
    std::map<std::string, const Removal*> first() const {
        std::map<std::string, const Removal*> out;
        for (const Removal* r : counted) out.emplace(r->device, r);
        return out;
    }
};

// The removal walk (DEVICE_PROOF_DESIGN section 4): signers in rank order; a signer is
// alive at its turn unless a removal counted for an earlier signer removed it, or it is
// outside its tier's valid closure as it stands then. Every removal of a standing
// target `target_ok` takes, by an alive signer, counts.
inline Walk removal_walk(const std::vector<const Removal*>& removals, const std::map<std::string, Rank>& rank,
                         const std::function<bool(const std::string&)>& target_ok,
                         const std::set<std::string>& roots, const std::set<std::string>& pending,
                         const std::vector<const Vouch*>& vouches) {
    std::vector<std::pair<const Rank*, const Removal*>> cands;
    for (const Removal* r : removals) {
        auto by = rank.find(r->by);
        if (by != rank.end() && target_ok(r->device)) cands.emplace_back(&by->second, r);
    }
    auto less = [](const std::pair<const Rank*, const Removal*>& a, const std::pair<const Rank*, const Removal*>& b) {
        return *a.first != *b.first ? *a.first < *b.first : *a.second < *b.second;
    };
    auto same = [](const std::pair<const Rank*, const Removal*>& a, const std::pair<const Rank*, const Removal*>& b) {
        return *a.first == *b.first && *a.second == *b.second;
    };
    std::sort(cands.begin(), cands.end(), less);
    cands.erase(std::unique(cands.begin(), cands.end(), same), cands.end());
    std::set<std::string> seeds[2] = {roots, roots};
    seeds[1].insert(pending.begin(), pending.end());
    Walk walk;
    std::optional<std::tuple<size_t, uint8_t, std::map<std::string, const Vouch*>>> closure;
    size_t i = 0;
    while (i < cands.size()) {
        const std::string& by = cands[i].second->by;
        size_t j = i;
        while (j < cands.size() && cands[j].second->by == by) j++;
        const uint8_t tier = std::min<uint8_t>(std::get<0>(*cands[i].first), 1);
        bool removed_earlier = false;
        for (const Removal* r : walk.counted) {
            if (r->device == by && r->by != by) removed_earlier = true;
        }
        const size_t n = walk.counted.size();
        if (!closure || std::get<0>(*closure) != n || std::get<1>(*closure) != tier) {
            closure.emplace(n, tier, valid_closure(seeds[tier], vouches, Voids::of(walk.counted)));
        }
        const auto& parents = std::get<2>(*closure);
        if (!removed_earlier && parents.count(by)) {
            for (auto at = parents.find(by); at != parents.end() && at->second != nullptr;
                 at = parents.find(at->second->by)) {
                walk.support.insert(*at->second);
            }
            for (size_t k = i; k < j; k++) walk.counted.push_back(cands[k].second);
        }
        i = j;
    }
    return walk;
}

// Which vouches the vouch cap ranks first: a vouch is VALID when its signer is in the
// valid closure the walk leaves and no counted removal of the signer voids it.
struct CapJudge {
    std::map<std::string, Rank> valid_rank;
    Voids voids;
    std::set<Vouch> support;        // what the walk needs to come out the same once compacted
    std::vector<Removal> reserved;  // each removed device's first counted removal
    bool counts(const Vouch& v) const { return valid_rank.count(v.by) != 0 && voids.allows(v); }
};

// -- Payloads (byte for byte the Rust format! strings) --

inline std::string consent_payload(const std::string& m, const std::string& d) {
    return "hollow-id1-join:" + m + ":" + d;
}
inline std::string recovery_payload(const std::string& m, const std::string& r_pub, int64_t at, const Ids& keep,
                                    bool no_wait) {
    return "hollow-id1-recovery:" + m + ":" + r_pub + ":" + std::to_string(at) + ":" + csv(sorted_ids(keep)) +
           (no_wait ? ":nowait" : "");
}
inline std::string phrase_admit_payload(const std::string& m, const std::string& r_pub, int64_t at,
                                        const std::string& d) {
    return "hollow-id1-radmit:" + m + ":" + r_pub + ":" + std::to_string(at) + ":" + d;
}
inline std::string vouch_payload(const std::string& m, const std::string& base, const std::string& d) {
    return "hollow-id1-admit:" + m + ":" + base + ":" + d;
}
inline std::string pending_payload(const std::string& m, const std::string& base, const std::string& d) {
    return "hollow-id1-pending:" + m + ":" + base + ":" + d;
}
inline std::string legacy_payload(const std::string& m, const std::string& d) {
    return "hollow-id1-legacy:" + m + ":" + d;
}
inline std::string removal_payload(const std::string& m, const std::string& base, const std::string& d,
                                   const Ids& keep) {
    return "hollow-id1-remove:" + m + ":" + base + ":" + d + ":" + csv(sorted_ids(keep));
}

inline bool is_base_shape(const std::string& base) {
    if (base == LEGACY_BASE) return true;
    if (base.size() != 32) return false;
    for (char c : base) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

struct Current {
    std::string base;
    int64_t at = 0;
    std::set<std::string> keep;
    bool no_wait = false;
};

struct Roster {
    std::string master;
    std::string r_pub;
    std::vector<Recovery> recoveries;
    std::vector<PhraseAdmit> phrase_admits;
    std::vector<Consent> consents;
    std::vector<Vouch> vouches;
    std::vector<Pending> pendings;
    std::vector<LegacyClaim> legacy;
    std::vector<Removal> removals;

    bool operator==(const Roster& o) const {
        return master == o.master && r_pub == o.r_pub && recoveries == o.recoveries &&
               phrase_admits == o.phrase_admits && consents == o.consents && vouches == o.vouches &&
               pendings == o.pendings && legacy == o.legacy && removals == o.removals;
    }
    bool operator!=(const Roster& o) const { return !(*this == o); }

    static Roster named(const std::string& m) {
        Roster r;
        r.master = m;
        return r;
    }

    // Whether every kind fits its ceiling, as any roster a client compacted does. The
    // relay verifies nothing from one that does not.
    bool within_caps() const {
        return recoveries.size() <= MAX_RECOVERY_TIES && phrase_admits.size() <= MAX_PHRASE_ADMITS &&
               consents.size() <= MAX_CONSENTS && vouches.size() <= MAX_VOUCHES && pendings.size() <= MAX_PENDING &&
               legacy.size() <= MAX_LEGACY && removals.size() <= MAX_REMOVALS + MAX_RESERVED;
    }

    std::string base_id(const Recovery& rec, const RosterCrypto& c) const {
        return c.sha256_hex(recovery_payload(master, r_pub, rec.at_ms, rec.keep, rec.no_wait)).substr(0, 32);
    }

    std::optional<Current> current_recovery(const RosterCrypto& c) const {
        if (recoveries.empty()) return std::nullopt;
        int64_t at = recoveries[0].at_ms;
        for (const auto& r : recoveries) at = std::max(at, r.at_ms);
        Current cur;
        cur.at = at;
        bool first = true;
        for (const auto& r : recoveries) {
            if (r.at_ms != at) continue;
            std::string id = base_id(r, c);
            if (first || id < cur.base) cur.base = id;
            first = false;
            cur.keep.insert(r.keep.begin(), r.keep.end());
            cur.no_wait = cur.no_wait || r.no_wait;
        }
        return cur;
    }

    std::string base(const RosterCrypto& c) const {
        auto cur = current_recovery(c);
        return cur ? cur->base : LEGACY_BASE;
    }

    // The current base, and the devices the phrase (or, in a legacy base, the master)
    // roots in it, consent not yet checked.
    std::pair<std::optional<Current>, std::set<std::string>> base_roots(const RosterCrypto& c) const {
        auto cur = current_recovery(c);
        std::set<std::string> roots;
        if (cur) {
            roots = cur->keep;
            for (const auto& p : phrase_admits) {
                if (p.at_ms > cur->at) roots.insert(p.device);
            }
        } else {
            for (const auto& l : legacy) roots.insert(l.device);
            for (const auto& p : phrase_admits) roots.insert(p.device);
        }
        return {cur, roots};
    }

    std::set<std::string> consented() const {
        std::set<std::string> out;
        for (const auto& k : consents) out.insert(k.device);
        return out;
    }

    // Every device with an admission path in the current base, removals ignored and
    // every pending join counted, ranked by (tier, depth, id).
    std::map<std::string, Rank> standing(const RosterCrypto& c) const { return ranked(c, true); }

    // `standing`; without `with_pending`, nothing a pending join seeds ranks.
    std::map<std::string, Rank> ranked(const RosterCrypto& c, bool with_pending) const {
        const auto cons = consented();
        const auto roots = base_roots(c).second;
        std::vector<std::pair<std::string, std::string>> edges;
        for (const auto& v : vouches) {
            if (cons.count(v.device)) edges.emplace_back(v.by, v.device);
        }
        std::set<std::string> seeds[2];
        for (const auto& r : roots) {
            if (cons.count(r)) seeds[0].insert(r);
        }
        for (const auto& p : pendings) {
            if (with_pending && cons.count(p.device)) seeds[1].insert(p.device);
        }
        return rank_over(seeds, edges);
    }

    // Server authority's verdict (identity/roster.rs `authority`) over verified statements:
    // signers are tier 0 of `ranked`, the walk decides which removals count, pending joins
    // never count but a removal of one does.
    Authority authority(const RosterCrypto& c) const {
        const auto cons = consented();
        auto [cur, all_roots] = base_roots(c);
        Authority out;
        out.key = r_pub;
        out.base = cur ? cur->base : LEGACY_BASE;
        std::set<std::string> roots, asked;
        for (const auto& d : all_roots) {
            if (cons.count(d)) roots.insert(d);
        }
        for (const auto& p : pendings) {
            if (p.base == out.base && cons.count(p.device)) asked.insert(p.device);
        }
        std::vector<const Vouch*> vs;
        for (const auto& v : vouches) {
            if (v.base == out.base && cons.count(v.device)) vs.push_back(&v);
        }
        std::vector<const Removal*> rms;
        for (const auto& x : removals) {
            if (x.base == out.base) rms.push_back(&x);
        }
        const auto founded = ranked(c, false);
        auto target_ok = [&](const std::string& t) { return founded.count(t) != 0 || asked.count(t) != 0; };
        Walk walk = removal_walk(rms, founded, target_ok, roots, {}, vs);
        for (const auto& [d, r] : walk.first()) out.removed[d] = r->by;
        for (const auto& [d, via] : valid_closure(roots, vs, Voids::of(walk.counted))) {
            if (!out.removed.count(d)) out.counted.insert(d);
        }
        return out;
    }

    // standing() over the consents the cap keeps (identity/roster.rs `capped_standing`):
    // past MAX_CONSENTS standing devices only the best ranked keep theirs, ranked again.
    std::map<std::string, Rank> capped_standing(const RosterCrypto& c) const {
        auto all = standing(c);
        if (all.size() <= MAX_CONSENTS) return all;
        std::vector<std::pair<Rank, std::string>> best;
        for (const auto& [d, k] : all) best.emplace_back(k, d);
        std::sort(best.begin(), best.end());
        std::set<std::string> kept;
        for (size_t i = 0; i < MAX_CONSENTS; i++) kept.insert(best[i].second);
        Roster view = *this;
        view.consents.erase(std::remove_if(view.consents.begin(), view.consents.end(),
                                           [&](const Consent& k) { return all.count(k.device) && !kept.count(k.device); }),
                            view.consents.end());
        return view.standing(c);
    }

    // The vouch cap's judge over every held statement of the current base
    // (identity/roster.rs `cap_judge`): the walk over removals by tier-0 signers voids
    // vouches, the walk over every standing signer picks the reserved slots, then the
    // valid closure of the roots plus the consented pending joins.
    CapJudge cap_judge(const std::map<std::string, Rank>& stand, const RosterCrypto& c) const {
        const auto cons = consented();
        auto [cur, all_roots] = base_roots(c);
        const std::string base = cur ? cur->base : LEGACY_BASE;
        std::set<std::string> roots, pending;
        for (const auto& d : all_roots) {
            if (cons.count(d)) roots.insert(d);
        }
        for (const auto& p : pendings) {
            if (p.base == base && cons.count(p.device)) pending.insert(p.device);
        }
        std::vector<const Vouch*> vs;
        for (const auto& v : vouches) {
            if (v.base == base && cons.count(v.device)) vs.push_back(&v);
        }
        std::vector<const Removal*> rms;
        for (const auto& x : removals) {
            if (x.base == base) rms.push_back(&x);
        }
        CapJudge out;
        const auto target_ok = [&](const std::string& t) { return stand.count(t) != 0; };
        Walk wide = removal_walk(rms, stand, target_ok, roots, pending, vs);
        for (const auto& [d, r] : wide.first()) out.reserved.push_back(*r);
        std::vector<const Removal*> tier0;
        for (const Removal* x : rms) {
            auto by = stand.find(x->by);
            if (by != stand.end() && std::get<0>(by->second) == 0) tier0.push_back(x);
        }
        Walk walk = removal_walk(tier0, stand, target_ok, roots, pending, vs);
        out.voids = Voids::of(walk.counted);
        out.support = std::move(walk.support);
        out.support.insert(wide.support.begin(), wide.support.end());
        std::vector<std::pair<std::string, std::string>> edges;
        for (const Vouch* v : vs) {
            if (out.voids.allows(*v)) edges.emplace_back(v->by, v->device);
        }
        const std::set<std::string> seeds[2] = {roots, pending};
        out.valid_rank = rank_over(seeds, edges);
        return out;
    }

    // Everything superseded by the current base dropped, statements sorted, and the
    // ceilings applied (identity/roster.rs `compacted`).
    Roster compacted(const RosterCrypto& c) const {
        Roster r = *this;
        if (!r.recoveries.empty()) {
            int64_t at = r.recoveries[0].at_ms;
            for (const auto& x : r.recoveries) at = std::max(at, x.at_ms);
            r.recoveries.erase(std::remove_if(r.recoveries.begin(), r.recoveries.end(),
                                              [&](const Recovery& x) { return x.at_ms != at; }),
                               r.recoveries.end());
        }
        sort_cap(r.recoveries, MAX_RECOVERY_TIES);
        auto cur = r.current_recovery(c);
        const std::string base = cur ? cur->base : LEGACY_BASE;
        if (cur) {
            const int64_t at = cur->at;
            r.phrase_admits.erase(std::remove_if(r.phrase_admits.begin(), r.phrase_admits.end(),
                                                 [&](const PhraseAdmit& p) { return !(p.at_ms > at); }),
                                  r.phrase_admits.end());
            r.legacy.clear();
        }
        r.vouches.erase(std::remove_if(r.vouches.begin(), r.vouches.end(),
                                       [&](const Vouch& v) { return v.base != base; }),
                        r.vouches.end());
        r.pendings.erase(std::remove_if(r.pendings.begin(), r.pendings.end(),
                                        [&](const Pending& p) { return p.base != base; }),
                         r.pendings.end());
        r.removals.erase(std::remove_if(r.removals.begin(), r.removals.end(),
                                        [&](const Removal& x) { return x.base != base; }),
                         r.removals.end());
        sort_cap(r.phrase_admits, MAX_PHRASE_ADMITS);
        sort_cap(r.legacy, MAX_LEGACY);
        sort_cap(r.pendings, MAX_PENDING);
        std::sort(r.consents.begin(), r.consents.end());
        r.consents.erase(std::unique(r.consents.begin(), r.consents.end(),
                                     [](const Consent& a, const Consent& b) { return a.device == b.device; }),
                         r.consents.end());

        const auto stand = r.capped_standing(c);

        std::vector<Vouch> vouches;
        for (auto& v : r.vouches) {
            if (stand.count(v.by)) vouches.push_back(v);
        }
        std::sort(vouches.begin(), vouches.end());
        vouches.erase(std::unique(vouches.begin(), vouches.end()), vouches.end());
        // Kept first, so a compacted roster folds, ranks and walks as the whole set did:
        // each standing device's vouch from its nearest VALID voucher (HOL-SEC-189), the
        // walk's support, and each standing device's vouch from its best-ranked voucher.
        // The rest give way by validity, then signer rank.
        const CapJudge judge = r.cap_judge(stand, c);
        auto rank_of = [](const std::map<std::string, Rank>& m, const std::string& d) -> std::optional<Rank> {
            auto it = m.find(d);
            return it == m.end() ? std::nullopt : std::optional<Rank>(it->second);
        };
        // Each standing device's first vouch by (the signer's rank in `m`, the vouch).
        auto first_per_device = [&](std::vector<const Vouch*> order, const std::map<std::string, Rank>& m) {
            std::sort(order.begin(), order.end(), [&](const Vouch* a, const Vouch* b) {
                auto ra = rank_of(m, a->by), rb = rank_of(m, b->by);
                return ra != rb ? ra < rb : *a < *b;
            });
            std::set<std::string> seen;
            std::set<const Vouch*> out;
            for (const Vouch* v : order) {
                if (stand.count(v->device) && seen.insert(v->device).second) out.insert(v);
            }
            return out;
        };
        std::vector<const Vouch*> all, valid;
        for (const auto& v : vouches) {
            all.push_back(&v);
            if (judge.counts(v)) valid.push_back(&v);
        }
        const auto valid_tree = first_per_device(valid, judge.valid_rank);
        const auto rank_tree = first_per_device(all, stand);
        using Key = std::tuple<uint8_t, bool, std::optional<Rank>, const Vouch*>;
        std::vector<Key> order;
        for (const Vouch* v : all) {
            const uint8_t klass = valid_tree.count(v) ? 0 : judge.support.count(*v) ? 1 : rank_tree.count(v) ? 2 : 3;
            order.emplace_back(klass, !judge.counts(*v), rank_of(stand, v->by), v);
        }
        std::sort(order.begin(), order.end(), [](const Key& a, const Key& b) {
            if (std::get<0>(a) != std::get<0>(b)) return std::get<0>(a) < std::get<0>(b);
            if (std::get<1>(a) != std::get<1>(b)) return std::get<1>(a) < std::get<1>(b);
            if (std::get<2>(a) != std::get<2>(b)) return std::get<2>(a) < std::get<2>(b);
            return *std::get<3>(a) < *std::get<3>(b);
        });
        std::vector<Vouch> kept;
        for (const auto& k : order) kept.push_back(*std::get<3>(k));
        if (kept.size() > MAX_VOUCHES) kept.resize(MAX_VOUCHES);
        std::sort(kept.begin(), kept.end());
        r.vouches = std::move(kept);

        std::vector<Removal> removals;
        for (auto& x : r.removals) {
            if (stand.count(x.by)) removals.push_back(x);
        }
        std::sort(removals.begin(), removals.end());
        removals.erase(std::unique(removals.begin(), removals.end()), removals.end());
        std::vector<Removal> reserved = judge.reserved;
        std::sort(reserved.begin(), reserved.end(), [&](const Removal& a, const Removal& b) {
            const Rank& ra = stand.at(a.device);
            const Rank& rb = stand.at(b.device);
            return ra != rb ? ra < rb : a < b;
        });
        if (reserved.size() > MAX_RESERVED) reserved.resize(MAX_RESERVED);
        const std::set<Removal> held(reserved.begin(), reserved.end());
        std::vector<Removal> general;
        for (auto& x : removals) {
            if (!held.count(x)) general.push_back(x);
        }
        std::sort(general.begin(), general.end(), [&](const Removal& a, const Removal& b) {
            const Rank& ra = stand.at(a.by);
            const Rank& rb = stand.at(b.by);
            return ra != rb ? ra < rb : a < b;
        });
        if (general.size() > MAX_REMOVALS) general.resize(MAX_REMOVALS);
        removals = reserved;
        removals.insert(removals.end(), general.begin(), general.end());
        std::sort(removals.begin(), removals.end());
        r.removals = std::move(removals);

        std::set<std::string> mentioned;
        for (const auto& x : r.recoveries) mentioned.insert(x.keep.begin(), x.keep.end());
        for (const auto& p : r.phrase_admits) mentioned.insert(p.device);
        for (const auto& p : r.pendings) mentioned.insert(p.device);
        for (const auto& l : r.legacy) mentioned.insert(l.device);
        for (const auto& v : r.vouches) mentioned.insert(v.device);
        for (const auto& x : r.removals) mentioned.insert(x.device);
        // (class, rank): standing devices by rank, then named ones, then unnamed ones.
        auto klass = [&](const Consent& k) -> std::pair<uint8_t, std::optional<Rank>> {
            auto it = stand.find(k.device);
            if (it != stand.end()) return {0, it->second};
            if (mentioned.count(k.device)) return {1, std::nullopt};
            return {2, std::nullopt};
        };
        std::vector<Consent> consents = r.consents;
        std::stable_sort(consents.begin(), consents.end(), [&](const Consent& a, const Consent& b) {
            auto ka = klass(a), kb = klass(b);
            return ka != kb ? ka < kb : a < b;
        });
        std::vector<Consent> keep;
        size_t unnamed = 0;
        for (auto& k : consents) {
            if (klass(k).first == 2 && ++unnamed > MAX_UNNAMED_CONSENTS) continue;
            keep.push_back(k);
        }
        if (keep.size() > MAX_CONSENTS) keep.resize(MAX_CONSENTS);
        std::sort(keep.begin(), keep.end());
        r.consents = std::move(keep);
        return r;
    }

    // Only the statements that verify for this master (identity/roster.rs `verified`).
    // A statement equal to one in `known` (already verified for this master) skips its
    // signature check; phrase statements only while `known` pins the same key.
    Roster verified(int64_t now_ms, const RosterCrypto& c, const Roster* known = nullptr) const {
        if (!c.is_key(master)) return Roster{};
        const std::string& m = master;
        Roster out = named(m);
        auto fresh = [&](int64_t at) { return at <= now_ms + MAX_FUTURE_SKEW_MS; };
        auto id_ok = [&](const std::string& d) { return c.is_key(d); };
        auto in = [](const auto& list, const auto& item) {
            return std::find(list.begin(), list.end(), item) != list.end();
        };
        const bool phrase_known = known && known->r_pub == r_pub;

        for (const auto& rec : recoveries) {
            Ids keep = sorted_ids(rec.keep);
            bool shape = fresh(rec.at_ms) && keep == rec.keep && !keep.empty() && keep.size() <= MAX_KEEP &&
                         std::all_of(keep.begin(), keep.end(), id_ok);
            if (!shape) continue;
            if (phrase_known && in(known->recoveries, rec)) {
                out.recoveries.push_back(rec);
                continue;
            }
            std::string p = recovery_payload(m, r_pub, rec.at_ms, keep, rec.no_wait);
            if (c.verify_by_key(r_pub, rec.sig_r, p) && c.verify_by_id(m, rec.sig_m, p)) out.recoveries.push_back(rec);
        }
        for (const auto& pa : phrase_admits) {
            if (!fresh(pa.at_ms) || !id_ok(pa.device)) continue;
            if (phrase_known && in(known->phrase_admits, pa)) {
                out.phrase_admits.push_back(pa);
                continue;
            }
            std::string p = phrase_admit_payload(m, r_pub, pa.at_ms, pa.device);
            if (c.verify_by_key(r_pub, pa.sig_r, p) && c.verify_by_id(m, pa.sig_m, p)) out.phrase_admits.push_back(pa);
        }
        if (!out.recoveries.empty() || !out.phrase_admits.empty()) out.r_pub = r_pub;

        for (const auto& k : consents) {
            if ((known && in(known->consents, k)) || c.verify_by_id(k.device, k.sig, consent_payload(m, k.device))) {
                out.consents.push_back(k);
            }
        }
        for (const auto& v : vouches) {
            if (!is_base_shape(v.base) || !id_ok(v.device) || v.device == v.by) continue;
            if ((known && in(known->vouches, v)) || c.verify_by_id(v.by, v.sig, vouch_payload(m, v.base, v.device))) {
                out.vouches.push_back(v);
            }
        }
        for (const auto& p : pendings) {
            if (!is_base_shape(p.base) || !id_ok(p.device)) continue;
            if ((known && in(known->pendings, p)) ||
                c.verify_by_id(m, p.sig_m, pending_payload(m, p.base, p.device))) {
                out.pendings.push_back(p);
            }
        }
        for (const auto& l : legacy) {
            if (!id_ok(l.device)) continue;
            if ((known && in(known->legacy, l)) || c.verify_by_id(m, l.sig_m, legacy_payload(m, l.device))) {
                out.legacy.push_back(l);
            }
        }
        for (const auto& x : removals) {
            Ids keep = sorted_ids(x.keep_vouched);
            bool shape = is_base_shape(x.base) && id_ok(x.device) && keep == x.keep_vouched &&
                         keep.size() <= MAX_REMOVAL_KEEP && std::all_of(keep.begin(), keep.end(), id_ok);
            if (!shape) continue;
            if ((known && in(known->removals, x)) ||
                c.verify_by_id(x.by, x.sig, removal_payload(m, x.base, x.device, keep))) {
                out.removals.push_back(x);
            }
        }
        return out.compacted(c);
    }

    // Fold `incoming` (verified) into this one (verified). The first recovery key seen
    // stays: phrase statements under any other are dropped.
    Roster merged(const Roster& incoming, const RosterCrypto& c) const {
        if (!master.empty() && incoming.master != master) return *this;
        Roster out = *this;
        out.master = incoming.master;
        bool same_key = out.r_pub.empty() || out.r_pub == incoming.r_pub;
        if (same_key && !incoming.r_pub.empty()) {
            out.r_pub = incoming.r_pub;
            push_unique(out.recoveries, incoming.recoveries);
            push_unique(out.phrase_admits, incoming.phrase_admits);
        }
        push_unique(out.consents, incoming.consents);
        push_unique(out.vouches, incoming.vouches);
        push_unique(out.pendings, incoming.pendings);
        push_unique(out.legacy, incoming.legacy);
        push_unique(out.removals, incoming.removals);
        return out.compacted(c);
    }

    // `merged` for a holder that keeps a clock of pending joins (identity/roster.rs
    // `merged_by_first_sight`): past their ceiling, asks give way by when this holder
    // first saw them, an unseen one after every seen one, so a later flood of asks under
    // ids the master key picks pushes out no earlier ask.
    Roster merged_by_first_sight(
        const Roster& incoming, const RosterCrypto& c,
        const std::function<std::optional<int64_t>(const std::string& base, const std::string& device)>& first_seen)
        const {
        Roster out = merged(incoming, c);
        if (!master.empty() && incoming.master != master) return out;
        const std::string b = out.base(c);
        std::vector<Pending> asks;
        for (const auto* list : {&pendings, &incoming.pendings}) {
            for (const auto& p : *list) {
                if (p.base == b) asks.push_back(p);
            }
        }
        std::sort(asks.begin(), asks.end());
        asks.erase(std::unique(asks.begin(), asks.end()), asks.end());
        if (asks.size() <= MAX_PENDING) return out;
        auto seen = [&](const Pending& p) {
            auto s = first_seen(p.base, p.device);
            return s ? *s : INT64_MAX;
        };
        std::stable_sort(asks.begin(), asks.end(), [&](const Pending& x, const Pending& y) { return seen(x) < seen(y); });
        const std::set<Pending> kept(asks.begin(), asks.begin() + MAX_PENDING);
        auto trim = [&](Roster r) {
            r.pendings.erase(std::remove_if(r.pendings.begin(), r.pendings.end(),
                                            [&](const Pending& p) { return p.base == b && !kept.count(p); }),
                             r.pendings.end());
            return r;
        };
        return trim(*this).merged(trim(incoming), c);
    }

    // Who belongs to this identity now, for one observer: `first_seen` is when it first
    // saw a device's pending join. The roster must already be verified.
    State fold(const std::function<std::optional<int64_t>(const std::string&)>& first_seen, int64_t now_ms,
               const RosterCrypto& c) const {
        const auto cons = consented();
        auto [cur, roots] = base_roots(c);
        State s;
        s.base = cur ? cur->base : LEGACY_BASE;
        s.is_protected = cur.has_value();
        s.no_wait = cur && cur->no_wait;
        for (auto it = roots.begin(); it != roots.end();) {
            it = cons.count(*it) ? std::next(it) : roots.erase(it);
        }
        std::vector<const Vouch*> vs;
        for (const auto& v : vouches) {
            if (v.base == s.base && cons.count(v.device)) vs.push_back(&v);
        }
        std::vector<const Pending*> ps;
        for (const auto& p : pendings) {
            if (p.base == s.base && cons.count(p.device)) ps.push_back(&p);
        }
        auto vouch_closure = [&](std::set<std::string> seed) {
            for (;;) {
                size_t before = seed.size();
                for (const auto* v : vs) {
                    if (seed.count(v->by)) seed.insert(v->device);
                }
                if (seed.size() == before) return seed;
            }
        };
        // A join refused by a device that belongs without anyone waiting never matures:
        // waiting must not hand its removals to whoever holds the master key.
        const std::set<std::string> founded = vouch_closure(roots);
        std::set<std::string> refused;
        for (const auto& x : removals) {
            if (x.base == s.base && founded.count(x.by)) refused.insert(x.device);
        }
        std::set<std::string> matured;
        for (const auto* p : ps) {
            if (s.no_wait || refused.count(p->device)) continue;
            auto seen = first_seen(p->device);
            if (seen && *seen <= now_ms - PENDING_MATURITY_MS) matured.insert(p->device);
        }

        std::set<std::string> with_matured = roots;
        with_matured.insert(matured.begin(), matured.end());
        const std::set<std::string> rooted = vouch_closure(std::move(with_matured));

        std::set<std::string> asked;
        for (const auto* p : ps) asked.insert(p->device);
        std::map<std::string, std::set<std::string>> kept_by;
        for (const auto& x : removals) {
            if (x.base != s.base || !rooted.count(x.by)) continue;
            if (!rooted.count(x.device) && !asked.count(x.device)) continue;
            s.removed.emplace(x.device, x.by);
            std::set<std::string> keep(x.keep_vouched.begin(), x.keep_vouched.end());
            auto it = kept_by.find(x.device);
            if (it == kept_by.end()) {
                kept_by.emplace(x.device, std::move(keep));
            } else {
                std::set<std::string> both;
                for (const auto& d : it->second) {
                    if (keep.count(d)) both.insert(d);
                }
                it->second = std::move(both);
            }
        }

        std::set<std::string> valid = roots;
        valid.insert(matured.begin(), matured.end());
        for (;;) {
            size_t before = valid.size();
            for (const auto* v : vs) {
                if (!valid.count(v->by)) continue;
                bool ok = !s.removed.count(v->by);
                if (!ok) {
                    auto it = kept_by.find(v->by);
                    ok = it != kept_by.end() && it->second.count(v->device);
                }
                if (ok) valid.insert(v->device);
            }
            if (valid.size() == before) break;
        }
        for (const auto& d : valid) {
            if (!s.removed.count(d)) s.members.insert(d);
        }
        for (const auto& d : asked) {
            if (!valid.count(d) && !s.removed.count(d)) s.pending.insert(d);
        }
        return s;
    }
};

// -- JSON, in the serde shape. Strict like serde: a field of the wrong type refuses
// the whole roster; a missing one takes its default; unknown ones are ignored. --

namespace detail {

inline bool text(const nlohmann::json& o, const char* key, std::string& out) {
    auto it = o.find(key);
    if (it == o.end()) return true;
    if (!it->is_string()) return false;
    out = it->get<std::string>();
    return true;
}

inline bool number(const nlohmann::json& o, const char* key, int64_t& out) {
    auto it = o.find(key);
    if (it == o.end()) return true;
    if (it->is_number_unsigned()) {
        uint64_t u = it->get<uint64_t>();
        if (u > static_cast<uint64_t>(INT64_MAX)) return false;
        out = static_cast<int64_t>(u);
        return true;
    }
    if (!it->is_number_integer()) return false;
    out = it->get<int64_t>();
    return true;
}

inline bool flag(const nlohmann::json& o, const char* key, bool& out) {
    auto it = o.find(key);
    if (it == o.end()) return true;
    if (!it->is_boolean()) return false;
    out = it->get<bool>();
    return true;
}

inline bool ids(const nlohmann::json& o, const char* key, Ids& out) {
    auto it = o.find(key);
    if (it == o.end()) return true;
    if (!it->is_array()) return false;
    for (const auto& e : *it) {
        if (!e.is_string()) return false;
        out.push_back(e.get<std::string>());
    }
    return true;
}

template <typename T, typename F>
inline bool list(const nlohmann::json& o, const char* key, std::vector<T>& out, F read) {
    auto it = o.find(key);
    if (it == o.end()) return true;
    if (!it->is_array()) return false;
    for (const auto& e : *it) {
        if (!e.is_object()) return false;
        T item;
        if (!read(e, item)) return false;
        out.push_back(std::move(item));
    }
    return true;
}

}  // namespace detail

inline std::optional<Roster> from_json(const nlohmann::json& j) {
    using namespace detail;
    if (!j.is_object()) return std::nullopt;
    Roster r;
    bool ok = text(j, "master", r.master) && text(j, "r_pub", r.r_pub) &&
              list(j, "recoveries", r.recoveries,
                   [](const nlohmann::json& e, Recovery& x) {
                       return number(e, "at_ms", x.at_ms) && ids(e, "keep", x.keep) && flag(e, "no_wait", x.no_wait) &&
                              text(e, "sig_r", x.sig_r) && text(e, "sig_m", x.sig_m);
                   }) &&
              list(j, "phrase_admits", r.phrase_admits,
                   [](const nlohmann::json& e, PhraseAdmit& x) {
                       return number(e, "at_ms", x.at_ms) && text(e, "device", x.device) &&
                              text(e, "sig_r", x.sig_r) && text(e, "sig_m", x.sig_m);
                   }) &&
              list(j, "consents", r.consents,
                   [](const nlohmann::json& e, Consent& x) {
                       return text(e, "device", x.device) && text(e, "sig", x.sig);
                   }) &&
              list(j, "vouches", r.vouches,
                   [](const nlohmann::json& e, Vouch& x) {
                       return text(e, "base", x.base) && text(e, "device", x.device) && text(e, "by", x.by) &&
                              text(e, "sig", x.sig);
                   }) &&
              list(j, "pendings", r.pendings,
                   [](const nlohmann::json& e, Pending& x) {
                       return text(e, "base", x.base) && text(e, "device", x.device) && text(e, "sig_m", x.sig_m);
                   }) &&
              list(j, "legacy", r.legacy,
                   [](const nlohmann::json& e, LegacyClaim& x) {
                       return text(e, "device", x.device) && text(e, "sig_m", x.sig_m);
                   }) &&
              list(j, "removals", r.removals, [](const nlohmann::json& e, Removal& x) {
                  return text(e, "base", x.base) && text(e, "device", x.device) && text(e, "by", x.by) &&
                         ids(e, "keep_vouched", x.keep_vouched) && text(e, "sig", x.sig);
              });
    if (!ok) return std::nullopt;
    return r;
}

// The JSON serde writes for the same roster, key for key and in its order.
inline nlohmann::ordered_json to_json(const Roster& r) {
    using J = nlohmann::ordered_json;
    J out;
    out["master"] = r.master;
    out["r_pub"] = r.r_pub;
    out["recoveries"] = J::array();
    for (const auto& x : r.recoveries) {
        J o;
        o["at_ms"] = x.at_ms;
        o["keep"] = x.keep;
        if (x.no_wait) o["no_wait"] = true;
        o["sig_r"] = x.sig_r;
        o["sig_m"] = x.sig_m;
        out["recoveries"].push_back(std::move(o));
    }
    out["phrase_admits"] = J::array();
    for (const auto& x : r.phrase_admits) {
        out["phrase_admits"].push_back(J{{"at_ms", x.at_ms}, {"device", x.device}, {"sig_r", x.sig_r}, {"sig_m", x.sig_m}});
    }
    out["consents"] = J::array();
    for (const auto& x : r.consents) out["consents"].push_back(J{{"device", x.device}, {"sig", x.sig}});
    out["vouches"] = J::array();
    for (const auto& x : r.vouches) {
        out["vouches"].push_back(J{{"base", x.base}, {"device", x.device}, {"by", x.by}, {"sig", x.sig}});
    }
    out["pendings"] = J::array();
    for (const auto& x : r.pendings) {
        out["pendings"].push_back(J{{"base", x.base}, {"device", x.device}, {"sig_m", x.sig_m}});
    }
    out["legacy"] = J::array();
    for (const auto& x : r.legacy) out["legacy"].push_back(J{{"device", x.device}, {"sig_m", x.sig_m}});
    out["removals"] = J::array();
    for (const auto& x : r.removals) {
        J o;
        o["base"] = x.base;
        o["device"] = x.device;
        o["by"] = x.by;
        o["keep_vouched"] = x.keep_vouched;
        o["sig"] = x.sig;
        out["removals"].push_back(std::move(o));
    }
    return out;
}

}  // namespace roster
