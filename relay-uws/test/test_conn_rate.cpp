// Unit tests for the new-connection rate window and the bounded book of addresses that
// hold no socket (src/conn_rate.h). test_session_bounds drives them through .open and
// .close (admit_socket, free_ip_slot); test_relay_live through the real relay.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_conn_rate.cpp -o t && ./t

#include "conn_rate.h"

#include <cstdio>
#include <string>

using conn_rate::Clock;
using conn_rate::IdleBook;
using conn_rate::share_of_key;
using conn_rate::Window;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static const Clock::time_point t0 = Clock::now();
static Clock::time_point at(int secs) { return t0 + std::chrono::seconds(secs); }

static void window_tests() {
    printf("window\n");
    Window<3> w;
    check("a new window is empty", w.empty() && !w.full() && w.size() == 0);
    w.push(at(0));
    w.push(at(10));
    w.push(at(20));
    check("three connects fill a window of three", w.full() && w.size() == 3);
    check("it ends a minute after the newest", w.ends() == at(80));
    w.prune(at(60));
    check("a connect exactly a minute old still counts", w.size() == 3);
    w.prune(at(61));
    check("one older than a minute is forgotten", w.size() == 2 && !w.full());
    w.push(at(61));
    w.push(at(62));
    check("a push past the size forgets the oldest", w.size() == 3 && w.ends() == at(122));
    w.prune(at(123));
    check("and all are forgotten past the newest's minute", w.empty());
}

static void share_tests() {
    printf("shares\n");
    check("a v4 address is a share of its own", share_of_key("192.0.2.1") != share_of_key("192.0.2.2"));
    check("the /64s of one /48 share", share_of_key("2001:db8:1:2::/64") == share_of_key("2001:db8:1:ffff::/64"));
    check("two /48s do not", share_of_key("2001:db8:1:2::/64") != share_of_key("2001:db8:2:2::/64"));
    check("v4 and v6 never meet", share_of_key("0.0.0.1") != share_of_key("::1/64") &&
                                      share_of_key("0.0.0.0") != share_of_key("::/64"));
    check("unparseable text is a share of its own", share_of_key("x") != share_of_key("y") &&
                                                        share_of_key("x") != share_of_key("0.0.0.0"));
}

static void book_tests() {
    printf("idle book\n");
    {
        IdleBook book(4);
        book.put("192.0.2.1", at(60));
        for (int i = 0; i < 6; i++) {
            auto gone = book.put("2001:db8:1:" + std::to_string(i) + "::/64", at(61 + i));
            if (i >= 3) {
                check("a full book forgets the oldest of the heaviest block (" + std::to_string(i) + ")",
                      gone.size() == 1 && gone[0] == "2001:db8:1:" + std::to_string(i - 3) + "::/64");
            }
        }
        check("the bound holds", book.size() == 4);
        check("a lone address survives a flood from one /48", book.contains("192.0.2.1"));
    }
    {
        IdleBook book(2);
        book.put("192.0.2.1", at(60));
        book.put("192.0.2.2", at(61));
        auto gone = book.put("192.0.2.3", at(62));
        check("among equal blocks one is forgotten, and only one", gone.size() == 1 && book.size() == 2);
        check("which the book no longer holds", !book.contains(gone.empty() ? "" : gone[0]));
    }
    {
        IdleBook book;
        size_t gone = 0;
        for (size_t i = 0; i < conn_rate::MAX_IDLE + 10; i++) {
            const unsigned v = static_cast<unsigned>(i);
            const std::string key = std::to_string(10 + (v >> 16)) + "." + std::to_string((v >> 8) & 255) + "." +
                                    std::to_string(v & 255) + ".1";
            gone += book.put(key, at(60)).size();
        }
        check("the real bound holds", book.size() == conn_rate::MAX_IDLE && gone == 10);
    }
    {
        IdleBook book(8);
        book.put("192.0.2.1", at(60));
        book.put("192.0.2.2", at(70));
        book.put("192.0.2.1", at(80));
        check("a key put again takes its new end", book.size() == 2);
        auto out = book.expired(at(70));
        check("an end not yet passed is kept", out.empty());
        out = book.expired(at(71));
        check("a passed one is taken out", out.size() == 1 && out[0] == "192.0.2.2" && !book.contains("192.0.2.2"));
        book.remove("192.0.2.1");
        check("a removed key never expires", book.expired(at(1000)).empty() && book.size() == 0);
        book.remove("192.0.2.1");
        check("removing it twice changes nothing", book.size() == 0);
    }
}

int main() {
    window_tests();
    share_tests();
    book_tests();
    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
