// Unit tests for the relay circuit breaker (src/breaker.h): the buckets, the share cap,
// the stranger count, the device ladder, the fresh-start tiers, the room allowance, the
// pause rule and the work counter's guards. The published numbers and the client's
// prices come from breaker_vectors.json, which the Rust pacer (node/relay_pace.rs) reads.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_breaker.cpp -o test_breaker && ./test_breaker

#include "breaker.h"
#include "json.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <new>
#include <string>

// Live heap bytes, so the stranger tracker's bound is measured, not taken on its word.
static std::atomic<long long> g_heap{0};
void* operator new(size_t n) {
    void* p = std::malloc(n + 16);
    if (!p) throw std::bad_alloc();
    *static_cast<size_t*>(p) = n;
    g_heap += static_cast<long long>(n);
    return static_cast<char*>(p) + 16;
}
void operator delete(void* p) noexcept {
    if (!p) return;
    char* b = static_cast<char*>(p) - 16;
    g_heap -= static_cast<long long>(*reinterpret_cast<size_t*>(b));
    std::free(b);
}
void operator delete(void* p, size_t) noexcept { operator delete(p); }

using json = nlohmann::json;
using namespace breaker;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static uint64_t mix(uint64_t x) {
    x += 0x9e3779b97f4a7c15ull;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}

// The stranger trackers the judge and charge tests use.
static StrangerBook g_book;

static void test_vectors() {
    printf("vectors\n");
    std::ifstream f("breaker_vectors.json");
    const json v = json::parse(f, nullptr, false);
    check("breaker_vectors.json parses", v.is_object());
    if (!v.is_object()) return;
    const json& c = v["constants"];
    const Limits& l = DEFAULT;
    check("the W start", c["w_start"] == l.w_full.start);
    check("the floor tier", c["w_floor"] == l.w_floor);
    check("the low tier", c["w_low"] == l.w_low);
    check("the W cap", c["w_cap"] == l.w_full.cap);
    check("the W refill", c["w_refill_per_s"].get<int64_t>() * 1000 == l.w_full.refill_m);
    check("the joins", c["joins_start"] == l.joins_full.start && c["joins_cap"] == l.joins_full.cap &&
                           c["joins_refill_milli_per_s"] == l.joins_full.refill_m);
    check("the debt floor", c["debt_floor"] == l.debt_floor);
    check("the share cap and unit costs", c["share_cap"] == SHARE_CAP && c["sig_w"] == SIG_W && c["dh_w"] == DH_W &&
                                              c["ids_per_w"] == IDS_PER_W &&
                                              c["resume_w_per_room"] == RESUME_W_PER_ROOM);
    check("the stranger limit", c["distinct_limit"] == l.distinct);
    check("the client's reserve is the judge's margin", c["client_reserve"] == l.pace_reserve);
    check("the client stops new targets well below it",
          c["client_distinct_stop"].get<int64_t>() * 10 <= l.distinct * 8);
    // Every price covers the most the relay can charge for that frame: one delivery per
    // listed receiver, each from a group of its own (the share cap can only lower it).
    for (const auto& k : v["costs"]) {
        const int64_t n = k.value("relay_deliveries", 0);
        const std::string text = k.value("text", "");
        const int op = k.value("hex_op", 0);
        std::string type;
        if (!text.empty()) type = json::parse(text).value("type", "");
        int64_t relay = 2;
        if (op == 3 || op == 7 || op == 10 || type == "msg" || type == "leave") relay = 1 + n;
        if (op == 4 || op == 8 || op == 2) relay = (k.value("room", "").rfind("inbox:", 0) == 0 ? 2 : 1) + n;
        if (op == 9) relay = 1;
        if (type == "join") {
            size_t pos = 0;
            int64_t shown = 0;
            while ((pos = text.find("\"sig\"", pos)) != std::string::npos) {
                shown++;
                pos += 5;
            }
            relay = 2 + DH_W + (n + IDS_PER_W - 1) / IDS_PER_W + n + SIG_W * 2 * shown;
        }
        if (type == "topic_catchup") relay = 2 + 200;
        if (type == "check_peers") relay = 2 + CHECK_PEERS_SCAN_W;
        if (type == "hb" || type == "ack") relay = 1;
        check("the client's price covers the relay: " + k.value("name", ""), k["w"].get<int64_t>() >= relay);
    }
}

static void test_bucket() {
    printf("bucket\n");
    const Rates r{100, 200, 10'000};  // 10 a second
    Bucket b;
    b.start(100, 0);
    check("starts at its start", b.level() == 100);
    b.refill(1'000, r);
    check("refills by the second", b.level() == 110);
    b.refill(1'000'000, r);
    check("never past its cap", b.level() == 200);
    b.spend(250, -100);
    check("goes into debt", b.level() == -50);
    b.spend(1'000, -100);
    check("never below the debt floor", b.level() == -100);
    check("knows when it is back to zero", b.ms_until(0, r) == 10'000);
    const Rates slow{0, 10, 100};  // 0.1 a second
    Bucket j;
    j.start(0, 0);
    j.refill(9'999, slow);
    check("a tenth a second has not made one in 9.999 s", j.level() == 0);
    j.refill(10'000, slow);
    check("and has at 10 s", j.level() == 1);
    Bucket back;
    back.start(5, 1'000);
    back.refill(500, r);
    check("a clock going back adds nothing", back.level() == 5);
}

static void test_tally() {
    printf("share cap\n");
    Tally t;
    for (int i = 0; i < 8'700; i++) t.add(42);
    check("8,700 deliveries to one group cost 8", t.cost() == 8);
    Tally u;
    for (uint64_t g = 0; g < 100; g++) u.add(g);
    for (int i = 0; i < 20; i++) u.add(7);
    check("100 groups, one with 21 sockets, cost 107", u.cost() == 107);
    Tally none;
    check("no delivery costs nothing", none.cost() == 0);
}

static void test_distinct() {
    printf("strangers\n");
    Distinct d;
    const int64_t t0 = 600'000'000;
    for (uint64_t i = 0; i < 12; i++) d.add(mix(i), t0);
    check("exact while few", d.estimate(t0) == 12);
    check("a known target never reaches the limit", !d.would_reach(mix(5), t0, 13));
    check("a new one at the limit does", d.would_reach(mix(10'000), t0, 13));
    for (uint64_t i = 0; i < 400; i++) d.add(mix(i), t0);
    for (uint64_t i = 0; i < 400; i++) d.add(mix(i), t0 + 60'000);
    const double twice = d.estimate(t0 + 60'000);
    check("the same targets next minute count once", twice > 380 && twice < 420);
    Distinct big;
    for (uint64_t i = 0; i < 30'000; i++) big.add(mix(i), t0 + static_cast<int64_t>(i % 10) * 60'000);
    const double e = big.estimate(t0 + 9 * 60'000);
    check("30,000 targets over ten minutes estimate within 5%", e > 28'500 && e < 31'500);
    check("below 50,000 nothing trips", !big.would_reach(mix(999'999), t0 + 9 * 60'000, 50'000));
    for (uint64_t i = 30'000; i < 60'000; i++) big.add(mix(i), t0 + 9 * 60'000);
    check("past 50,000 a new target trips", big.would_reach(mix(999'999), t0 + 9 * 60'000, 50'000));
    check("ten minutes later the window has moved on",
          !big.would_reach(mix(999'999), t0 + 9 * 60'000 + 600'000, 50'000));
    check("and the tracker is idle", big.idle(t0 + 9 * 60'000 + 600'000));
}

// One payer depositing to 512 new strangers a minute for ten minutes (the review's
// distinct_mem.cpp): its tracker stays a fixed few KB, never a set per target.
static void test_stranger_tracker_bytes() {
    printf("stranger tracker bytes\n");
    const Limits& l = DEFAULT;
    const long long before = g_heap;
    {
        StrangerBook book;
        Account a;
        a.begin(Kind::Full, 400'000, 0, l);
        uint64_t k = 0x9e3779b97f4a7c15ULL;
        bool passed = true;
        for (int minute = 0; minute < 10; minute++) {
            for (int i = 0; i < 512; i++) {
                k = k * 6364136223846793005ULL + 1442695040888963407ULL;
                Plan p;
                p.w = 3;
                p.stranger = k;
                const int64_t now = minute * 60'000 + i;
                passed &= judge(a, p, now, l, book, 77) == Verdict::Pass;
                charge(a, 3, p, now, l, book, 77, 5);
            }
        }
        const long long held = g_heap - before;
        printf("       one payer after 10 x 512 strangers: %lld bytes\n", held);
        check("5,120 strangers in ten minutes stay under the limit", passed);
        check("one payer's tracker holds at most 11 KB", held <= 11 * 1024);
        check("and the book counts what it holds", book.bytes() >= static_cast<size_t>(held) - 1024);
        book.sweep(10 * 60'000 + 600'000);
        check("a tracker whose window passed is forgotten", book.size() == 0 && book.bytes() == 0);
    }
    check("and frees it", g_heap == before);
}

// Every payer's tracker shares one byte budget (HIGH 1): a flood of payers that each
// sketch thousands of strangers stays inside it, measured on the heap, and gives up its
// own trackers first, never an honest payer's from another share.
static void test_stranger_book_bound() {
    printf("stranger book bound\n");
    const size_t budget = 2u << 20;
    const long long before = g_heap;
    {
        StrangerBook book(budget);
        book.add(1, 1, mix(1), 0);
        book.add(2, 2, mix(2), 0);
        size_t peak = 0;
        long long heap_peak = 0;
        uint64_t k = 99;
        for (uint64_t payer = 1000; payer < 3000; payer++) {
            // 64 /64s of one abusive share, 40 strangers each: past the exact few.
            for (int i = 0; i < 40; i++) book.add(payer, 66, mix(k++), 1'000 + static_cast<int64_t>(payer));
            peak = std::max(peak, book.bytes());
            heap_peak = std::max(heap_peak, g_heap - before);
        }
        printf("       2,000 sketching payers: book %zu bytes (budget %zu), heap peak %lld\n", peak, budget, heap_peak);
        check("the book never holds more than its budget and one tracker", peak <= budget + 11 * 1024);
        check("nor does the heap, bookkeeping included", heap_peak <= static_cast<long long>(budget + 64 * 1024));
        check("the honest payers of other shares keep their counts",
              book.estimate(1, 5'000) == 1 && book.estimate(2, 5'000) == 1);
        check("the flood gave up its own", book.size() < 2'000);
    }
    check("and the heap is back", g_heap == before);
}

// The newcomer's own share can top the table: payers of equal weight under share ids that
// only grow tie at the top, and the largest id, the newcomer's, wins the tie. The book
// evicts the next candidate then, never stops evicting.
static void stranger_book_stays_bounded_when_the_newcomer_holds_the_top_share() {
    printf("stranger book, the newcomer on top\n");
    const size_t budget = 64u << 10;
    StrangerBook book(budget);
    size_t peak = 0;
    for (uint64_t payer = 1; payer <= 5'000; payer++) {
        book.add(payer, /*share=*/payer, mix(payer), 0);
        peak = std::max(peak, book.bytes());
    }
    printf("       5,000 payers, one share each: book %zu bytes at most (budget %zu)\n", peak, budget);
    check("the book stays within its budget", peak <= budget);
    check("and keeps the newest payer's count", book.estimate(5'000, 1) == 1);
}

// The same for the tables bounded by entries: cooldowns, clean devices, start pools.
static void tables_stay_bounded_when_the_newcomer_holds_the_top_share() {
    printf("tables, the newcomer on top\n");
    const Limits& l = DEFAULT;
    CooldownBook cooldowns;
    CleanSeen clean;
    StartPools pools;
    for (uint64_t i = 1; i <= TABLE_MAX + 1'000; i++) {
        cooldowns.step(i, /*share=*/i, 0, l);
        clean.note(i, /*share=*/i, 0);
        pools.take(i, /*share=*/i, false, 0, l);
    }
    check("the cooldown table keeps its size", cooldowns.size() == TABLE_MAX);
    check("and the newcomer's cooldown", cooldowns.level(TABLE_MAX + 1'000, 0, l) == 1);
    check("the clean devices keep their size", clean.size() == TABLE_MAX);
    check("and the newcomer", clean.recent(TABLE_MAX + 1'000, 0, l));
    check("the start pools keep their size", pools.size() == TABLE_MAX);
}

static void test_judge() {
    printf("judge\n");
    const Limits& l = DEFAULT;
    Account a;
    a.begin(Kind::Full, 1'000, 0, l);
    Plan p;
    p.w = 1'000;
    check("a frame the level covers passes", judge(a, p, 0, l, g_book, 1) == Verdict::Pass);
    p.w = 1'001;
    check("one W more trips", judge(a, p, 0, l, g_book, 1) == Verdict::Work);
    p.control = true;
    check("a control frame never trips", judge(a, p, 0, l, g_book, 1) == Verdict::Pass);
    Plan j;
    j.join = true;
    j.w = 10;
    a.joins.start(0, 0);
    check("a join with no join left trips", judge(a, j, 0, l, g_book, 1) == Verdict::Joins);
    check("half a second later it still does", judge(a, j, 499, l, g_book, 1) == Verdict::Joins);
    check("and passes once one refilled", judge(a, j, 500, l, g_book, 1) == Verdict::Pass);
    Account debt;
    debt.begin(Kind::Full, 0, 0, l);
    Plan two;
    charge(debt, 500'000, two, 0, l, g_book, 1, 1);
    check("a charge stops at the debt floor", debt.w.level() == l.debt_floor);
    check("and counts in full toward the spend", debt.spent == 500'000);
    Plan cheap;
    cheap.w = 1;
    check("a level in debt trips every counted frame", judge(debt, cheap, 1'000, l, g_book, 1) == Verdict::Work);
    // LOW 6: a frame dearer than a full bucket less the client's reserve is judged at that,
    // so the bucket it waits for can pay it (else it trips on every resume).
    Account full;
    full.begin(Kind::Full, l.w_full.cap - l.pace_reserve, 0, l);
    Plan huge;
    huge.w = 5'000'000;
    check("a frame above the cap passes a bucket the reserve below full",
          judge(full, huge, 0, l, g_book, 1) == Verdict::Pass);
    CooldownBook none;
    Account empty;
    empty.begin(Kind::Full, 0, 0, l);
    const Pause wait = pause_for(empty, huge, Verdict::Work, none, 1, 1, 0, l);
    check("and its pause ends when the bucket can pay it",
          wait.wait_ms == (l.w_full.cap - l.pace_reserve) + l.pause_slack_ms);
    Account guest;
    guest.begin(Kind::Guest, l.w_guest.cap, 0, l);
    check("a small bucket is judged at half its cap at most", judge(guest, huge, 0, l, g_book, 1) == Verdict::Pass);
}

static void test_pause() {
    printf("pause and ladder\n");
    const Limits& l = DEFAULT;
    CooldownBook book;
    Account a;
    a.begin(Kind::Full, l.w_full.start, 0, l);
    Plan p;
    p.w = 2;
    charge(a, 450'000, p, 0, l, g_book, 1, 1);  // level -50k, spent 450k < 1.2M
    Pause first = pause_for(a, p, Verdict::Work, book, 1, 9, 0, l);
    check("a burst inside the honest budget is a pure pause", !first.ladder && book.level(1, 0, l) == 0);
    check("lasting until the level pays for the frame, plus the slack", first.wait_ms == 50'002 + l.pause_slack_ms);
    check("the window budget is the cap plus ten minutes of refill", ladder_budget(l) == 1'400'000);
    // A long honest session spends far more than start + cap over its life: only a recent
    // window that overspends the whole honest budget steps the ladder (lead decision 3).
    Account honest;
    honest.begin(Kind::Full, l.w_full.start, 0, l);
    int64_t t = 0;
    for (; t < 3 * 3'600'000; t += 1'000) {
        honest.refill(t, l);
        charge(honest, 1'000, p, t, l, g_book, 1, 1);
    }
    check("three hours at the refill rate leave the level near full", honest.w.level() == l.w_full.start - 1'000);
    Plan big;
    big.w = l.w_full.start + 1;
    check("one oversized frame trips it", judge(honest, big, t, l, g_book, 1) == Verdict::Work);
    Pause once = pause_for(honest, big, Verdict::Work, book, 4, 9, t, l);
    check("a long honest session that trips once does not step", !once.ladder && book.level(4, t, l) == 0);
    Account burst;
    burst.begin(Kind::Full, l.w_full.start, 0, l);
    charge(burst, ladder_budget(l) + 1, p, 30'000, l, g_book, 1, 1);
    Pause stale = pause_for(burst, p, Verdict::Work, book, 5, 9, 30'000 + l.ladder_window_ms + 60'000, l);
    check("an overspend that left the window is a pure pause", !stale.ladder && book.level(5, 0, l) == 0);
    Account heavy;
    heavy.begin(Kind::Full, l.w_full.start, 0, l);
    charge(heavy, ladder_budget(l) / 2, p, 0, l, g_book, 1, 1);
    check("half the window budget does not step",
          !pause_for(heavy, p, Verdict::Work, book, 2, 9, 0, l).ladder && book.level(2, 0, l) == 0);
    const int64_t T = l.ladder_window_ms - 1;
    charge(heavy, ladder_budget(l) / 2 + 1, p, T, l, g_book, 1, 1);
    Pause second = pause_for(heavy, p, Verdict::Work, book, 2, 9, T, l);
    check("overspending the window budget inside the window steps", second.ladder && book.level(2, 0, l) == 1);
    check("and the pause is at least the first cooldown", second.wait_ms >= l.ladder_ms[0]);
    check("the cooldown is booked", book.remaining_ms(2, T + 1'000, l) == l.ladder_ms[0] - 1'000);
    for (int i = 0; i < 6; i++) pause_for(heavy, p, Verdict::Work, book, 2, 9, T, l);
    check("the ladder stops at 24 h", book.level(2, T, l) == 5 && book.remaining_ms(2, T, l) == l.ladder_ms[4]);
    check("six quiet hours forget a level", book.level(2, T + l.ladder_forget_ms, l) == 4);
    check("thirty forget them all", book.level(2, T + 5 * l.ladder_forget_ms, l) == 0);
    book.sweep(T + 5 * l.ladder_forget_ms, l);
    check("and the sweep drops the entry", book.size() == 0);
    Account fetch;
    fetch.begin(Kind::Fetch, l.w_fetch.start, 0, l);
    charge(fetch, 10'000'000, p, 0, l, g_book, 1, 1);
    Pause f = pause_for(fetch, p, Verdict::Work, book, 3, 9, 0, l);
    check("a fetch socket pauses 30 s and never cools its device", f.wait_ms == 30'000 && !f.ladder &&
                                                                       book.level(3, 0, l) == 0);
}

static void test_cooldown_table_fair() {
    printf("cooldown table\n");
    const Limits& l = DEFAULT;
    CooldownBook book;
    for (uint64_t i = 0; i < TABLE_MAX; i++) book.step(i, 1, 0, l);
    book.step(TABLE_MAX + 1, 2, 1, l);
    check("a full table keeps its size", book.size() == TABLE_MAX);
    check("the newcomer of another group is kept", book.level(TABLE_MAX + 1, 1, l) == 1);
    check("the heaviest group gave one up", book.level(0, 1, l) == 0);
}

static void test_start_pools() {
    printf("fresh-start tiers\n");
    const Limits& l = DEFAULT;
    StartPools pools;
    check("a fresh block gives 400k", pools.take(7, 7, false, 0, l) == 400'000);
    check("three times", pools.take(7, 7, false, 1, l) == 400'000 && pools.take(7, 7, false, 2, l) == 400'000);
    int64_t t = pools.take(7, 7, false, 3, l);
    check("then the floor once the pool is empty", t == 100'000);
    for (int i = 4; i < 10; i++) pools.take(7, 7, false, i, l);
    check("ten starts a minute fall to the low tier", pools.take(7, 7, false, 11, l) == 24'000);
    check("but a device seen clean keeps the floor", pools.take(7, 7, true, 12, l) == 100'000);
    check("another block is untouched", pools.take(8, 8, false, 13, l) == 400'000);
    check("a minute later the floor is back", pools.take(7, 7, false, 12 + 60'000 + 1, l) == 100'000);
    check("the pool refills at 2,000 W/s", pools.take(7, 7, false, 12 + 60'000 + 1 + 200'000, l) == 400'000);
    pools.sweep(10'000'000, l);
    check("a full idle pool is forgotten", pools.size() == 0);
    CleanSeen seen;
    seen.note(5, 1, 0);
    check("clean within a day", seen.recent(5, l.clean_seen_ms - 1, l) && !seen.recent(5, l.clean_seen_ms, l));
}

static void test_allowance() {
    printf("room allowance\n");
    const Limits& l = DEFAULT;
    Allowance a;
    check("covers what it holds", a.cover(30'000, 0, l) == 30'000);
    check("then only the rest", a.cover(30'000, 0, l) == 20'000);
    check("then nothing", a.cover(10, 0, l) == 0);
    check("and refills at 500 W/s", a.cover(1'000, 2'000, l) == 1'000);
}

static void test_guards() {
    printf("work counter\n");
    g_work = 0;
    {
        Scope s;
        bump(SIG_W);
        bump_write(1);
        {
            Uncharged u;
            bump(100);
            bump_write(1);
        }
        {
            Fanout f;
            for (int i = 0; i < 50; i++) bump_write(3);
            bump_write(4);
        }
        check("signatures, writes and a capped fan-out are charged, uncharged work not", s.spent() == 6 + 1 + 8 + 1);
    }
    {
        Scope s;
        Uncharged u;
        Fanout f;
        bump_write(1);
        (void)s;
    }
    check("a fan-out inside uncharged work costs nothing", g_work == 16);
}

int main() {
    printf("breaker\n");
    test_vectors();
    test_bucket();
    test_tally();
    test_distinct();
    test_stranger_tracker_bytes();
    test_stranger_book_bound();
    stranger_book_stays_bounded_when_the_newcomer_holds_the_top_share();
    tables_stay_bounded_when_the_newcomer_holds_the_top_share();
    test_judge();
    test_pause();
    test_cooldown_table_fair();
    test_start_pools();
    test_allowance();
    test_guards();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
