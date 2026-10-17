// Unit tests for the failed link-code guess table (src/link_guess.h): a table a
// stranger fills, so a full one gives way from the address share holding the most
// records, never by age.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_link_guess.cpp -o test_link_guess && ./test_link_guess

#include "link_guess.h"

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

static constexpr uint64_t HONEST = 1;
static constexpr uint64_t OTHER = 2;
static constexpr uint64_t FLOOD = 3;

static void guess(LinkGuesses& t, const std::string& key, uint64_t share, LinkGuesses::Clock::time_point now) {
    auto& g = t.note(key, share);
    g.failures++;
    g.last_failure = now;
}

static void test_link_guess_flood_keeps_others() {
    printf("a flood keeps others\n");
    const auto now = LinkGuesses::Clock::now();
    LinkGuesses t(8);
    guess(t, "honest/64", HONEST, now);
    t.note("honest/64", HONEST).block_until = now + std::chrono::seconds(900);
    guess(t, "other-a/64", OTHER, now);
    guess(t, "other-b/64", OTHER, now);
    for (int i = 0; i < 1000; i++) guess(t, "flood-" + std::to_string(i) + "/64", FLOOD, now);

    check("the table stays at its cap", t.size() == 8);
    const auto* h = t.find("honest/64");
    check("a flood from one address block keeps another block's record", h != nullptr);
    check("with its count and its block", h && h->failures == 1 && h->block_until == now + std::chrono::seconds(900));
    check("and a third block's records", t.find("other-a/64") && t.find("other-b/64"));
    check("the flood keeps only its newest records", t.find("flood-999/64") && !t.find("flood-0/64"));
}

static void test_heaviest_share_gives_way() {
    printf("the heaviest share gives way\n");
    const auto now = LinkGuesses::Clock::now();
    LinkGuesses t(4);
    guess(t, "a1", HONEST, now);
    guess(t, "a2", HONEST, now);
    guess(t, "a3", HONEST, now);
    guess(t, "b1", OTHER, now);
    guess(t, "a1", HONEST, now);  // used again: a2 is now its share's oldest
    guess(t, "c1", FLOOD, now);
    check("the share holding the most loses its least recently used record",
          !t.find("a2") && t.find("a1") && t.find("a3") && t.find("b1") && t.find("c1"));
}

static void test_cleared_records_leave_the_ledger() {
    printf("cleared records leave the ledger\n");
    const auto now = LinkGuesses::Clock::now();
    LinkGuesses t(3);
    guess(t, "a", HONEST, now);
    guess(t, "b", OTHER, now);
    guess(t, "c", FLOOD, now);
    t.erase("c");
    guess(t, "d", FLOOD, now);
    check("a cleared record frees its place", t.size() == 3 && t.find("a") && t.find("b") && t.find("d"));

    t.erase_if([](const std::string& key, const LinkGuess&) { return key == "d"; });
    check("a swept record frees its place", t.size() == 2 && !t.find("d"));
    guess(t, "e", FLOOD, now);
    check("and the next one takes it without an eviction", t.size() == 3 && t.find("a") && t.find("b") && t.find("e"));
    t.erase("nobody");
    check("clearing an unknown key changes nothing", t.size() == 3);
}

int main() {
    test_link_guess_flood_keeps_others();
    test_heaviest_share_gives_way();
    test_cleared_records_leave_the_ledger();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
