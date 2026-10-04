// Unit tests for the forwarder room rule (src/fwd_room.h): in `fwd:{X}` only X and one
// other member are a pair; ws_handler.cpp asks it on every roster, presence, broadcast
// and direct (test_relay_live.cpp checks that it does).
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_fwd_room.cpp -o test_fwd_room && ./test_fwd_room

#include "fwd_room.h"

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

int main() {
    const std::string x = "12D3KooWForwarderAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const std::string a = "12D3KooWViewerAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const std::string b = "12D3KooWStrangerAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const std::string room = "fwd:" + x;

    printf("forwarder_of\n");
    check("a fwd room names its forwarder", fwd_room::forwarder_of(room) == std::optional<std::string_view>(x));
    check("an empty one names nobody", fwd_room::forwarder_of("fwd:") == std::optional<std::string_view>(""));
    check("a server room is no fwd room", !fwd_room::forwarder_of("0123456789abcdef0123456789abcdef01234567"));
    check("nor an inbox", !fwd_room::forwarder_of("inbox:" + x));
    check("the prefix is exact", !fwd_room::forwarder_of("FWD:" + x) && !fwd_room::forwarder_of("xfwd:" + x));

    printf("paired\n");
    check("the forwarder and a member", fwd_room::paired(room, x, a) && fwd_room::paired(room, a, x));
    check("two members are not", !fwd_room::paired(room, a, b) && !fwd_room::paired(room, b, a));
    check("the forwarder and itself", fwd_room::paired(room, x, x));
    check("nobody in a room naming nobody", !fwd_room::paired("fwd:", a, b) && !fwd_room::paired("fwd:", a, a));
    check("a member of another forwarder's room is not that room's forwarder",
          !fwd_room::paired("fwd:" + a, x, b));
    check("any two in any other room", fwd_room::paired("room-1", a, b) && fwd_room::paired("inbox:" + x, a, b));

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
