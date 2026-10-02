#pragma once
#include <cstddef>
#include <cstdint>
#include <set>
#include <string>
#include <unordered_map>

#include "fair_share.h"
#include "roster.h"

// Every identity's roster as the relay holds it (design ID-1R): each roster shown on an
// `inbox:{master}` join is folded into the one held for that master, so nothing shown
// later can take back a removal or a newer recovery, and the first recovery key held
// stays pinned. A socket owns the inbox only while the fold counts its device a member.
// Pending joins mature on the relay's own clock, from when it first saw them.
//
// Anyone may show a roster (its statements verify alone), so the byte budget is what
// bounds the table: past it the address share holding the most bytes loses its least
// recently used record, and the identity's devices put it back on their next join.
struct RosterBook {
    static constexpr size_t MAX_BYTES = 128ull * 1024 * 1024;

    struct Held {
        roster::Roster roster;
        std::unordered_map<std::string, int64_t> seen_ms;  // pending device -> first seen
    };

    struct Shown {
        bool member = false;
        // The held roster changed: owners it no longer counts lose the inbox.
        bool changed = false;
        roster::State state;
    };

    size_t budget = MAX_BYTES;
    std::unordered_map<std::string, Held> records;
    FairShare<std::string> ledger;

    size_t size() const { return records.size(); }

    // What one record costs the relay, near enough to bound its RAM.
    static size_t record_bytes(const std::string& master, const Held& h) {
        return 512 + master.size() + roster::to_json(h.roster).dump().size() * 2 + h.seen_ms.size() * 96;
    }

    const Held* get(const std::string& master) const {
        auto it = records.find(master);
        return it == records.end() ? nullptr : &it->second;
    }

    roster::State fold(const Held& h, int64_t now_ms, const RosterCrypto& c) const {
        return h.roster.fold(
            [&](const std::string& d) -> std::optional<int64_t> {
                auto it = h.seen_ms.find(d);
                if (it == h.seen_ms.end()) return std::nullopt;
                return it->second;
            },
            now_ms, c);
    }

    // Fold `shown` (as parsed, unverified) into the record for `master` and judge
    // `device`. A roster for another master, or one past any ceiling, changes nothing
    // and counts nobody. The record is charged to `share` when `device` turns out a
    // member, so a stranger showing it first never makes it theirs to lose.
    Shown show(const std::string& master, const roster::Roster& shown, const std::string& device, uint64_t share,
               int64_t now_ms, const RosterCrypto& c) {
        Shown out;
        if (shown.master != master || !shown.within_caps()) return out;
        auto it = records.find(master);
        const bool fresh = it == records.end();
        Held held;
        if (!fresh) held = it->second;
        if (fresh) held.roster = roster::Roster::named(master);
        roster::Roster merged = held.roster.merged(shown.verified(now_ms, c, fresh ? nullptr : &held.roster), c);
        out.changed = merged != held.roster;
        held.roster = std::move(merged);
        // First sight of each pending join; a device that stopped asking is forgotten.
        std::unordered_map<std::string, int64_t> seen;
        for (const auto& p : held.roster.pendings) {
            auto s = held.seen_ms.find(p.device);
            seen[p.device] = s == held.seen_ms.end() ? now_ms : s->second;
        }
        out.changed = out.changed || seen != held.seen_ms;
        held.seen_ms = std::move(seen);
        out.state = fold(held, now_ms, c);
        out.member = out.state.is_member(device);

        const size_t weight = record_bytes(master, held);
        records[master] = std::move(held);
        if (fresh || out.member) {
            ledger.put(master, share, weight);
        } else if (out.changed) {
            ledger.reweigh(master, weight);
            ledger.touch(master);
        } else {
            ledger.touch(master);
        }
        enforce_budget();
        return out;
    }

    // Restore from a snapshot, least recently used first so eviction order survives.
    // The relay wrote it, so it is taken as held, not verified again.
    void restore(const std::string& master, roster::Roster r, std::unordered_map<std::string, int64_t> seen_ms,
                 uint64_t share) {
        if (r.master != master) return;
        Held h{std::move(r), std::move(seen_ms)};
        const size_t weight = record_bytes(master, h);
        records[master] = std::move(h);
        ledger.put(master, share, weight);
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
