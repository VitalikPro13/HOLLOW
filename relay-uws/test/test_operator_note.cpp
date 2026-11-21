// Unit tests for the operator's once-a-minute refusal lines (src/operator_note.h, #153).
//   g++ -std=c++17 -I../src test_operator_note.cpp -o test_operator_note && ./test_operator_note
#include "operator_note.h"

#include <cstdio>

static int failures = 0;
static void check(const char* label, bool ok) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main() {
    MinuteNote n;
    check("the first refusal gets a line naming one", n.count(1'000) == 1);
    check("the next in the minute gets none", n.count(2'000) == 0 && n.count(60'999) == 0);
    check("a minute on, the line names all since the last", n.count(61'000) == 3);
    check("and the count starts over", n.count(62'000) == 0 && n.count(121'000) == 2);
    MinuteNote late;
    check("a first refusal at any time gets its line", late.count(0) == 1);
    MinuteNote other;
    n.count(121'500);
    check("each kind keeps its own minute", other.count(121'500) == 1);
    printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
