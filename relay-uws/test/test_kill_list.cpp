// Unit tests for the parked destroy-signal registry (src/kill_list.h): what
// the relay holds for a device that was not connected when its identity was
// destroyed, and hands over on that device's next auth.
//
// The properties that matter: one issuer never touches another's signal, a
// stale or future-dated re-deposit never lands, a cap EVICTS instead of
// refusing (the issuer past its share pays with its own oldest entry), and only
// the target's own ack removes one.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_kill_list.cpp -o test_kill_list && ./test_kill_list

#include "kill_list.h"

#include <cstdio>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

using Clock = KillList::Clock;

static std::string target_id(int n) { return "12D3KooWTarget" + std::to_string(n); }

// The address share every deposit below comes from unless a test says otherwise.
static constexpr uint64_t SHARE = 1;
static constexpr uint64_t FLOOD_SHARE = 9;

// The relay's wall clock in these tests; every stamp below sits well inside it.
static constexpr int64_t NOW_MS = 1'790'000'000'000;

static const KillList::Entry* signal_from(const KillList& kl, const std::string& target,
                                          const std::string& issuer) {
    const auto* list = kl.find(target);
    if (!list) return nullptr;
    for (const auto& e : *list) {
        if (e.issuer == issuer) return &e;
    }
    return nullptr;
}

int main() {
    printf("kill list\n");
    const Clock::time_point t0 = Clock::now();

    // Deposit and delivery: reading a signal does not consume it, because a
    // socket can drop between the frame and the act.
    {
        KillList kl;
        check("deposit stores", kl.deposit(target_id(1), "issuerA", SHARE, "blob-1", 1000, t0, NOW_MS));
        const auto* e = signal_from(kl, target_id(1), "issuerA");
        check("find returns the entry", e && e->blob == "blob-1" && e->issued_at_ms == 1000);
        check("find does not consume", kl.size() == 1 && kl.find(target_id(1)) != nullptr);
        check("an unknown target has nothing", kl.find(target_id(2)) == nullptr);
        check("an empty blob is refused", !kl.deposit(target_id(3), "issuerA", SHARE, "", 1000, t0, NOW_MS));
        check("a blob past the ceiling is refused",
              !kl.deposit(target_id(3), "issuerA", SHARE, std::string(KillList::MAX_BLOB_BYTES + 1, 'x'), 1000, t0, NOW_MS));
        check("a blob at the ceiling is stored",
              kl.deposit(target_id(3), "issuerA", SHARE, std::string(KillList::MAX_BLOB_BYTES, 'x'), 1000, t0, NOW_MS));
    }

    // I2: a stranger's deposit for the same device neither replaces nor
    // pre-empts the genuine order, and turning the junk away keeps the order.
    {
        KillList kl;
        check("a stamp past the clock bound is refused",
              !kl.deposit(target_id(1), "stranger", SHARE, "junk", NOW_MS + KillList::MAX_FUTURE_MS + 1, t0, NOW_MS));
        check("the genuine order lands after a future-dated attempt",
              kl.deposit(target_id(1), "issuerA", SHARE, "order", 1000, t0, NOW_MS));
        check("a newer deposit by someone else lands beside it",
              kl.deposit(target_id(1), "stranger", SHARE, "junk", 5000, t0, NOW_MS));
        check("the genuine order is untouched", signal_from(kl, target_id(1), "issuerA") &&
                                                signal_from(kl, target_id(1), "issuerA")->blob == "order");
        check("the target is handed both", kl.find(target_id(1))->size() == 2);
        check("acking the junk by its stamp", kl.ack(target_id(1), 5000));
        check("keeps the genuine order", signal_from(kl, target_id(1), "issuerA") != nullptr &&
                                         kl.size() == 1);
        check("the stranger no longer holds it", kl.issuer_count("stranger") == 0);
    }

    // Only a strictly newer stamp replaces an issuer's own signal.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", SHARE, "old", 1000, t0, NOW_MS);
        check("an older re-deposit is refused", !kl.deposit(target_id(1), "issuerA", SHARE, "older", 999, t0, NOW_MS));
        check("an equal re-deposit is refused", !kl.deposit(target_id(1), "issuerA", SHARE, "same", 1000, t0, NOW_MS));
        check("the waiting blob is untouched", signal_from(kl, target_id(1), "issuerA")->blob == "old");
        check("a newer re-deposit replaces it", kl.deposit(target_id(1), "issuerA", SHARE, "new", 1001, t0, NOW_MS));
        check("one slot per issuer", kl.size() == 1 && signal_from(kl, target_id(1), "issuerA")->blob == "new");
    }

    // Per-target cap: the target's oldest signal pays, the deposit is stored.
    {
        KillList kl;
        for (size_t i = 0; i < KillList::MAX_ISSUERS_PER_TARGET; i++) {
            kl.deposit(target_id(1), "issuer" + std::to_string(i), SHARE, "b", 1, t0, NOW_MS);
        }
        check("a target holds up to its cap", kl.find(target_id(1))->size() == KillList::MAX_ISSUERS_PER_TARGET);
        check("one past the cap still stores", kl.deposit(target_id(1), "late", SHARE, "b", 1, t0, NOW_MS));
        check("the cap holds", kl.find(target_id(1))->size() == KillList::MAX_ISSUERS_PER_TARGET);
        check("the target's oldest signal paid", signal_from(kl, target_id(1), "issuer0") == nullptr);
        check("the newest is there", signal_from(kl, target_id(1), "late") != nullptr);
    }

    // Per-issuer cap: the issuer's OWN oldest pays, and the deposit is never
    // refused.
    {
        KillList kl;
        bool all_stored = true;
        for (size_t i = 0; i < KillList::MAX_ENTRIES_PER_ISSUER; i++) {
            if (!kl.deposit(target_id(int(i)), "flooder", SHARE, "b", 1, t0, NOW_MS)) all_stored = false;
        }
        check("every deposit up to the issuer share stores", all_stored);
        check("the issuer sits at its share", kl.issuer_count("flooder") == KillList::MAX_ENTRIES_PER_ISSUER);
        check("one past the share still stores", kl.deposit(target_id(9000), "flooder", SHARE, "b", 1, t0, NOW_MS));
        check("the share is held, not exceeded",
              kl.issuer_count("flooder") == KillList::MAX_ENTRIES_PER_ISSUER);
        check("the issuer's oldest entry is the one that paid", kl.find(target_id(0)) == nullptr);
        check("its second oldest survived", kl.find(target_id(1)) != nullptr);
        check("another issuer still deposits", kl.deposit(target_id(9001), "quiet", SHARE, "b", 1, t0, NOW_MS));
        check("the flooder evicted only itself", kl.issuer_count("quiet") == 1);
    }

    // Global cap: oldest first, across issuers.
    {
        KillList kl;
        size_t issuers = 0;
        for (size_t i = 0; i < KillList::MAX_ENTRIES; i++) {
            if (i % KillList::MAX_ENTRIES_PER_ISSUER == 0) issuers++;
            kl.deposit(target_id(int(i)), "issuer" + std::to_string(issuers), SHARE, "b", 1, t0, NOW_MS);
        }
        check("the list fills to the global cap", kl.size() == KillList::MAX_ENTRIES);
        check("one past the cap still stores", kl.deposit(target_id(90000), "late-issuer", SHARE, "b", 1, t0, NOW_MS));
        check("the cap holds", kl.size() == KillList::MAX_ENTRIES);
        check("the globally oldest entry paid", kl.find(target_id(0)) == nullptr);
        check("the next oldest survived", kl.find(target_id(1)) != nullptr);
    }

    // Junk from throwaway issuers on one address never pushes out a real order
    // waiting at the same target.
    {
        KillList kl;
        kl.deposit(target_id(1), "owner-device", SHARE, "order", 1, t0, NOW_MS);
        for (int i = 0; i < 40; i++) {
            kl.deposit(target_id(1), "sybil" + std::to_string(i), FLOOD_SHARE, "junk", 1, t0, NOW_MS);
        }
        check("the target stays at its cap", kl.find(target_id(1))->size() == KillList::MAX_ISSUERS_PER_TARGET);
        check("the real order survives the junk", signal_from(kl, target_id(1), "owner-device") != nullptr);
        check("the junk keeps only its newest", signal_from(kl, target_id(1), "sybil39") != nullptr &&
                                                    signal_from(kl, target_id(1), "sybil0") == nullptr);
    }

    // A flood filling the whole list from one address evicts only itself.
    {
        KillList kl;
        kl.deposit(target_id(1), "real-a", SHARE, "order", 1, t0, NOW_MS);
        kl.deposit(target_id(2), "real-b", 2, "order", 1, t0, NOW_MS);
        size_t issuers = 0;
        for (size_t i = 0; i < 2 * KillList::MAX_ENTRIES; i++) {
            if (i % KillList::MAX_ENTRIES_PER_ISSUER == 0) issuers++;
            kl.deposit(target_id(int(100 + i)), "sybil" + std::to_string(issuers), FLOOD_SHARE, "junk", 1, t0, NOW_MS);
        }
        check("the list holds its cap", kl.size() == KillList::MAX_ENTRIES);
        check("the first real order survives", signal_from(kl, target_id(1), "real-a") != nullptr);
        check("the second real order survives", signal_from(kl, target_id(2), "real-b") != nullptr);
        check("a real order after the flood lands",
              kl.deposit(target_id(3), "real-c", 3, "order", 1, t0, NOW_MS) && signal_from(kl, target_id(3), "real-c"));
    }

    // Age: a signal nobody ever came back for is dropped after a year.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", SHARE, "b", 1, t0, NOW_MS);
        kl.deposit(target_id(2), "issuerA", SHARE, "b", 1, t0 + std::chrono::hours(24 * 200), NOW_MS);
        auto later = t0 + std::chrono::seconds(KillList::MAX_AGE_SECS);
        check("nothing is swept before the age", kl.sweep(t0 + std::chrono::hours(24)) == 0);
        check("the aged entry is swept", kl.sweep(later) == 1);
        check("the younger entry stays", kl.find(target_id(2)) != nullptr && kl.size() == 1);
        check("the swept entry's issuer accounting is released", kl.issuer_count("issuerA") == 1);
    }

    // Bare ack: every signal for the target, and nothing else.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", SHARE, "b", 1, t0, NOW_MS);
        kl.deposit(target_id(1), "issuerB", SHARE, "b", 2, t0, NOW_MS);
        kl.deposit(target_id(2), "issuerA", SHARE, "b", 1, t0, NOW_MS);
        check("an ack for a target with nothing waiting is a no-op", !kl.ack(target_id(3)));
        check("a stamp ack that matches nothing is a no-op", !kl.ack(target_id(1), 99));
        check("the bare ack deletes every signal for it", kl.ack(target_id(1)));
        check("only that target's signals went", kl.find(target_id(1)) == nullptr &&
                                                   kl.find(target_id(2)) != nullptr && kl.size() == 1);
        check("the issuer accounting follows", kl.issuer_count("issuerA") == 1 && kl.issuer_count("issuerB") == 0);
        check("re-depositing after an ack works", kl.deposit(target_id(1), "issuerA", SHARE, "b", 1, t0, NOW_MS));
    }

    // Restore keeps deposit order, so eviction after a restart is still
    // oldest first.
    {
        KillList kl;
        kl.restore(target_id(1), "issuerA", SHARE, "b", 1, t0 - std::chrono::hours(48));
        kl.restore(target_id(2), "issuerA", SHARE, "b", 1, t0 - std::chrono::hours(1));
        check("restored entries are present", kl.size() == 2);
        check("a restored entry keeps its stored_at",
              kl.sweep(t0 - std::chrono::hours(48) + std::chrono::seconds(KillList::MAX_AGE_SECS)) == 1);
        check("the newer restored entry stays", kl.find(target_id(2)) != nullptr);
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
