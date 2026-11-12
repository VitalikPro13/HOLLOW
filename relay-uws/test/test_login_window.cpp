// Unit tests for the pre-login window (src/login_window.h): stalled sockets give way first,
// by the heaviest share among them, never by age across addresses, and a fresh burst from
// one carrier NAT is never cut.
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -I../src test_login_window.cpp -o t && ./t

#include "login_window.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

using login_window::Key;
using login_window::Stage;
using login_window::Window;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static constexpr int64_t S = login_window::STALL_MS;

static void block_tests() {
    printf("per block (soft)\n");
    Window w;
    // An attacker address (share 1) and an honest slow client (share 2) in one /24.
    for (Key k = 1; k <= 4; k++) w.open(k, 1, "10.0.0", 0, 6, 1000);
    w.open(100, 2, "10.0.0", 0, 6, 1000);
    // The honest client's network takes seconds between its two steps; the attacker never steps.
    w.progress(100, Stage::Challenged, 600);
    w.progress(100, Stage::Signed, S);
    auto gone = w.open(5, 1, "10.0.0", S + 600, 6, 1000);
    check("under the block's window nobody gives way", gone.empty());
    gone = w.open(6, 1, "10.0.0", S + 700, 6, 1000);
    check("past it a stalled socket gives way", gone.size() == 1);
    check("the attacker's, never the slow honest login", gone.size() == 1 && gone[0] >= 1 && gone[0] <= 4);
    check("the honest login stays", w.contains(100));
    check("the newcomer is in", w.contains(6));

    Window fresh;
    for (Key k = 1; k <= 300; k++) fresh.open(k, 7, "100.64.0", 0, 256, 10'000);
    check("a fresh carrier-NAT burst past the block's window is never cut", fresh.size() == 300);

    Window heavy;
    heavy.open(1, 1, "b", 0, 3, 1000);
    heavy.open(2, 2, "b", 0, 3, 1000);
    heavy.open(3, 2, "b", 0, 3, 1000);
    gone = heavy.open(4, 3, "b", S, 3, 1000);
    check("the block's heaviest stalled share gives way", gone.size() == 1 && (gone[0] == 2 || gone[0] == 3));
}

static void total_tests() {
    printf("total\n");
    // 30 honest logins from one address (share 9) progressing, 4 x 12 silent from four /24s.
    Window w;
    Key k = 1;
    for (int i = 0; i < 30; i++) w.open(k++, 9, "100.64.0", 0, 10'000, 50);
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 12; i++) w.open(k++, 100 + b, "10.0." + std::to_string(b), 0, 10'000, 1000);
    for (Key h = 1; h <= 30; h++) w.progress(h, Stage::Challenged, S);
    size_t honest_lost = 0, gone_total = 0;
    for (int i = 0; i < 40; i++) {
        auto gone = w.open(k++, 9, "100.64.0", S + 10, 10'000, 78);
        gone_total += gone.size();
        for (Key g : gone) honest_lost += g <= 30 ? 1 : 0;
    }
    check("past the total, stalled sockets give way", gone_total > 0);
    check("a progressing carrier-NAT pool loses nothing while anyone is stalled", honest_lost == 0);

    Window none;
    for (Key j = 1; j <= 5; j++) none.open(j, 1, "a", 0, 100, 8);
    for (Key j = 6; j <= 8; j++) none.open(j, 2, "b", 0, 100, 8);
    auto gone = none.open(9, 3, "c", 1, 100, 8);
    check("with nothing stalled the heaviest share gives way", gone.size() == 1 && gone[0] >= 1 && gone[0] <= 5);
    gone = none.open(10, 1, "a", 2, 100, 8);
    check("a newcomer of the heaviest share pushes out its own, never itself",
          gone.size() == 1 && gone[0] != 10 && gone[0] <= 5 && none.contains(10));
}

static void bound_tests() {
    printf("bookkeeping\n");
    Window w;
    w.open(1, 1, "a", 0, 10, 10);
    w.open(2, 1, "a", 0, 10, 10);
    w.leave(1);
    w.leave(2);
    check("nothing is held past the last pending socket", w.size() == 0 && w.in_block("a") == 0);
    w.open(3, 1, "a", 0, 10, 10);
    w.open(3, 1, "a", 0, 10, 10);
    check("a socket counts once", w.size() == 1 && w.in_block("a") == 1);
    w.open(4, 1, "a", S, 10, 10);
    w.progress(3, Stage::Challenged, 2 * S);
    w.leave(3);
    w.leave(4);
    check("a stalled socket that progressed and left leaves nothing", w.size() == 0 && w.in_block("a") == 0);
    Window big;
    for (Key j = 1; j <= 2000; j++) big.open(j, j % 7, "b" + std::to_string(j % 3), int64_t(j), 100, 500);
    check("the total holds", big.size() <= 500);
}

// Review C5: only a later stage is progress, so a socket repeating auth_hello still stalls
// five seconds after its first one and gives way like a silent one.
static void stage_tests() {
    printf("stages\n");
    Window w;
    w.open(1, 1, "a", 0, 2, 1000);
    w.progress(1, Stage::Challenged, 100);
    for (int64_t t = 1100; t <= S + 100; t += 1000) w.progress(1, Stage::Challenged, t);
    w.open(2, 2, "a", 0, 2, 1000);
    w.progress(2, Stage::Challenged, 100);
    w.progress(2, Stage::Signed, S - 1000);
    w.progress(2, Stage::Open, S);
    auto gone = w.open(3, 3, "a", S + 200, 2, 1000);
    check("a socket repeating its hello gives way 5 s after the first one", gone.size() == 1 && gone[0] == 1);
    check("one that reached the next stage stays", w.contains(2) && w.contains(3));
}

int main() {
    block_tests();
    stage_tests();
    total_tests();
    bound_tests();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
