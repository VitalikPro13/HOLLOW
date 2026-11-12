// Unit tests for the connected-socket budget (src/conn_book.h).
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -I../src test_conn_book.cpp -o t && ./t

#include "conn_book.h"

#include <cstdio>
#include <string>

using conn_book::Book;
using conn_book::Class;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

int main() {
    printf("connected budget\n");
    Book b(7);
    for (uintptr_t k = 1; k <= 6; k++) b.open(k, 1);
    b.reclass(1, Class::Held);
    b.reclass(6, Class::Held);
    b.reclass(2, Class::Loose);
    check("under the budget nothing gives way", !b.open(10, 2).has_value() && b.size() == 7);
    auto shed = b.open(20, 3);
    check("past it the heaviest share gives way", shed && !shed->refused && shed->key == 3 && shed->cls == Class::Pending);
    shed = b.open(21, 4);
    check("its pending sockets first, oldest first", shed && shed->key == 4);
    b.open(22, 5);
    shed = b.open(23, 6);
    check("then one holding no session", shed && shed->key == 2 && shed->cls == Class::Loose);
    shed = b.open(24, 7);
    check("a session socket last, the oldest, marked so it resumes", shed && shed->key == 1 && shed->cls == Class::Held);
    check("the bound holds", b.size() == 7);

    Book own(4);
    for (uintptr_t k = 1; k <= 4; k++) own.open(k, 7);
    shed = own.open(5, 7);
    check("a newcomer of the heaviest share is refused", shed && shed->refused && shed->key == 5 && !own.contains(5));
    check("and sheds nobody", own.size() == 4);
    Book tie(2);
    tie.open(1, 1);
    tie.open(2, 2);
    shed = tie.open(3, 3);
    check("a newcomer tied for the heaviest is refused", shed && shed->refused);
    Book bk(3);
    bk.open(1, 1);
    bk.close(1);
    bk.close(1);
    check("a close counts once and leaves nothing", bk.size() == 0 && bk.held(1) == 0);
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
