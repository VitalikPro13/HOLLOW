// Unit tests for the parked destroy-signal registry (src/kill_list.h): what
// the relay holds for a device that was not connected when its identity was
// destroyed, and hands over on that device's next auth.
//
// The properties that matter: a stale re-deposit never overwrites a newer
// signal, a cap EVICTS instead of refusing (and the issuer past its share pays
// with its own oldest entry), and only the target's own ack removes one.
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

int main() {
    printf("kill list\n");
    const Clock::time_point t0 = Clock::now();

    // Deposit and delivery: reading a signal does not consume it, because a
    // socket can drop between the frame and the act.
    {
        KillList kl;
        check("deposit stores", kl.deposit(target_id(1), "issuerA", "blob-1", 1000, t0));
        const auto* e = kl.find(target_id(1));
        check("find returns the entry", e && e->blob == "blob-1" && e->issued_at_ms == 1000 &&
                                        e->issuer == "issuerA");
        check("find does not consume", kl.size() == 1 && kl.find(target_id(1)) != nullptr);
        check("an unknown target has nothing", kl.find(target_id(2)) == nullptr);
        check("an empty blob is refused", !kl.deposit(target_id(3), "issuerA", "", 1000, t0));
        check("a blob past the ceiling is refused",
              !kl.deposit(target_id(3), "issuerA", std::string(KillList::MAX_BLOB_BYTES + 1, 'x'), 1000, t0));
        check("a blob at the ceiling is stored",
              kl.deposit(target_id(3), "issuerA", std::string(KillList::MAX_BLOB_BYTES, 'x'), 1000, t0));
    }

    // Only a strictly newer issue stamp replaces what is waiting.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", "old", 1000, t0);
        check("an older deposit is refused", !kl.deposit(target_id(1), "issuerB", "older", 999, t0));
        check("an equal deposit is refused", !kl.deposit(target_id(1), "issuerB", "same", 1000, t0));
        check("the waiting blob is untouched", kl.find(target_id(1))->blob == "old");
        check("a newer deposit overwrites", kl.deposit(target_id(1), "issuerB", "new", 1001, t0));
        const auto* e = kl.find(target_id(1));
        check("the newer blob and issuer are stored", e->blob == "new" && e->issuer == "issuerB" &&
                                                      e->issued_at_ms == 1001);
        check("the previous issuer no longer holds it", kl.issuer_count("issuerA") == 0);
        check("the new issuer holds it", kl.issuer_count("issuerB") == 1);
        check("one target is still one entry", kl.size() == 1);
    }

    // Per-issuer cap: the issuer's OWN oldest pays, and the deposit is never
    // refused.
    {
        KillList kl;
        bool all_stored = true;
        for (size_t i = 0; i < KillList::MAX_ENTRIES_PER_ISSUER; i++) {
            if (!kl.deposit(target_id(int(i)), "flooder", "b", 1, t0)) all_stored = false;
        }
        check("every deposit up to the issuer share stores", all_stored);
        check("the issuer sits at its share", kl.issuer_count("flooder") == KillList::MAX_ENTRIES_PER_ISSUER);
        check("one past the share still stores",
              kl.deposit(target_id(9000), "flooder", "b", 1, t0));
        check("the share is held, not exceeded",
              kl.issuer_count("flooder") == KillList::MAX_ENTRIES_PER_ISSUER);
        check("the issuer's oldest entry is the one that paid", kl.find(target_id(0)) == nullptr);
        check("its second oldest survived", kl.find(target_id(1)) != nullptr);
        check("the new entry is there", kl.find(target_id(9000)) != nullptr);

        // A different issuer is unaffected by the flooder's share.
        check("another issuer still deposits", kl.deposit(target_id(9001), "quiet", "b", 1, t0));
        check("and keeps its own entry", kl.find(target_id(9001)) != nullptr);
        check("the flooder evicted only itself", kl.issuer_count("quiet") == 1);
    }

    // Global cap: oldest first, across issuers.
    {
        KillList kl;
        size_t issuers = 0;
        for (size_t i = 0; i < KillList::MAX_ENTRIES; i++) {
            if (i % KillList::MAX_ENTRIES_PER_ISSUER == 0) issuers++;
            kl.deposit(target_id(int(i)), "issuer" + std::to_string(issuers), "b", 1, t0);
        }
        check("the list fills to the global cap", kl.size() == KillList::MAX_ENTRIES);
        check("one past the cap still stores",
              kl.deposit(target_id(90000), "late-issuer", "b", 1, t0));
        check("the cap holds", kl.size() == KillList::MAX_ENTRIES);
        check("the globally oldest entry paid", kl.find(target_id(0)) == nullptr);
        check("the next oldest survived", kl.find(target_id(1)) != nullptr);
        check("the new entry is there", kl.find(target_id(90000)) != nullptr);
    }

    // Age: a signal nobody ever came back for is dropped after a year.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", "b", 1, t0);
        kl.deposit(target_id(2), "issuerA", "b", 1, t0 + std::chrono::hours(24 * 200));
        auto later = t0 + std::chrono::seconds(KillList::MAX_AGE_SECS);
        check("nothing is swept before the age", kl.sweep(t0 + std::chrono::hours(24)) == 0);
        check("the aged entry is swept", kl.sweep(later) == 1);
        check("the younger entry stays", kl.find(target_id(2)) != nullptr && kl.size() == 1);
        check("the swept entry's issuer accounting is released", kl.issuer_count("issuerA") == 1);
    }

    // Ack: the target's own, and nothing else.
    {
        KillList kl;
        kl.deposit(target_id(1), "issuerA", "b", 1, t0);
        kl.deposit(target_id(2), "issuerA", "b", 1, t0);
        check("an ack for a target with nothing waiting is a no-op", !kl.ack(target_id(3)));
        check("the ack deletes the entry", kl.ack(target_id(1)));
        check("only that entry went", kl.find(target_id(1)) == nullptr && kl.find(target_id(2)) != nullptr);
        check("the issuer accounting follows", kl.issuer_count("issuerA") == 1);
        check("a second ack is a no-op", !kl.ack(target_id(1)));
        check("the last ack empties the issuer", kl.ack(target_id(2)) && kl.issuer_count("issuerA") == 0);
        check("re-depositing after an ack works", kl.deposit(target_id(1), "issuerA", "b", 1, t0));
    }

    // Restore keeps deposit order, so eviction after a restart is still
    // oldest first.
    {
        KillList kl;
        kl.restore(target_id(1), "issuerA", "b", 1, t0 - std::chrono::hours(48));
        kl.restore(target_id(2), "issuerA", "b", 1, t0 - std::chrono::hours(1));
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
