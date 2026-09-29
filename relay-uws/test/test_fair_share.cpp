// Unit tests for the fair-share ledger (src/fair_share.h): when a table anyone can
// write to is full, the share holding the most gives way, so a flood from one
// address block evicts only itself.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_fair_share.cpp -o test_fair_share && ./test_fair_share

#include "fair_share.h"

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

using Table = FairShare<std::string>;

// Put `key` and evict until the table is back within `cap`, the way the relay does.
static void admit(Table& t, const std::string& key, uint64_t share, size_t weight, size_t cap) {
    t.put(key, share, weight);
    while (t.total() > cap) {
        auto v = t.victim();
        if (!v) break;
        t.remove(*v);
    }
}

int main() {
    printf("fair share\n");

    // A flood from one share evicts only itself, however much it sends.
    {
        Table t;
        admit(t, "alice", 1, 1, 100);
        admit(t, "bob", 2, 1, 100);
        for (int i = 0; i < 10000; i++) admit(t, "junk" + std::to_string(i), 9, 1, 100);
        admit(t, "carol", 3, 1, 100);
        check("the table stays at its cap", t.total() == 100);
        check("the first real entry survives", t.contains("alice"));
        check("the second real entry survives", t.contains("bob"));
        check("an entry after the flood lands", t.contains("carol"));
        check("the flood keeps only its newest entries",
              t.contains("junk9999") && !t.contains("junk0") && t.held(9) == 97);
    }

    // Weight, not count, decides who holds the most.
    {
        Table t;
        t.put("big", 1, 50);
        for (int i = 0; i < 10; i++) t.put("small" + std::to_string(i), 2, 1);
        check("the heavy share gives way first", t.victim() == std::optional<std::string>("big"));
    }

    // Within a share, the least recently used entry goes; touching keeps one.
    {
        Table t;
        t.put("a", 1, 1);
        t.put("b", 1, 1);
        t.put("c", 1, 1);
        t.touch("a");
        check("the least recently used goes", t.victim() == std::optional<std::string>("b"));
    }

    // Putting a held key moves it to the new share at the new weight.
    {
        Table t;
        t.put("x", 1, 5);
        t.put("x", 2, 3);
        check("the old share holds nothing", t.held(1) == 0);
        check("the new share holds the new weight", t.held(2) == 3 && t.total() == 3);
        check("the key names its new share", t.share_of("x") == std::optional<uint64_t>(2));
    }

    // Reweighing keeps the share and the recency.
    {
        Table t;
        t.put("a", 1, 1);
        t.put("b", 1, 1);
        t.reweigh("a", 10);
        check("the share holds the new weight", t.held(1) == 11 && t.total() == 11);
        check("reweighing is not a use", t.victim() == std::optional<std::string>("a"));
    }

    // Removal keeps the totals exact and drops an empty share.
    {
        Table t;
        t.put("a", 1, 4);
        t.put("b", 2, 6);
        check("remove answers true for a held key", t.remove("b"));
        check("remove answers false for a missing key", !t.remove("b"));
        check("totals follow", t.total() == 4 && t.held(2) == 0 && t.size() == 1);
        t.remove("a");
        check("an empty table has no victim", !t.victim().has_value() && t.total() == 0);
    }

    // Keys stay addressable across rehashing, which moves nothing a share points at.
    {
        FairShare<uint64_t> t;
        for (uint64_t i = 0; i < 5000; i++) t.put(i, i % 7, 1);
        for (uint64_t i = 0; i < 5000; i += 2) t.remove(i);
        size_t drained = 0;
        while (auto v = t.victim()) {
            t.remove(*v);
            drained++;
        }
        check("every entry drains through victim()", drained == 2500 && t.total() == 0);
    }

    // Two equal floods from two shares split the table between them.
    {
        Table t;
        for (int i = 0; i < 1000; i++) {
            admit(t, "a" + std::to_string(i), 1, 1, 100);
            admit(t, "b" + std::to_string(i), 2, 1, 100);
        }
        check("equal floods hold equal halves", t.held(1) == 50 && t.held(2) == 50);
    }

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
