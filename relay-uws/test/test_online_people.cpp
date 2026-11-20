// Unit tests for the people /server-stats counts online (src/online_people.h, #150).
//   g++ -std=c++17 -I../src test_online_people.cpp -o test_online_people && ./test_online_people

#include "online_people.h"

#include <cstdio>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    printf(ok ? "  ok   %s\n" : "  FAIL %s\n", label.c_str());
    if (!ok) failures++;
}

int main() {
    using online_people::Seat;
    using online_people::Tally;
    printf("online people\n");
    const std::string fwd = "fwd-peer", m = "master-m", d1 = "device-1", d2 = "device-2", lone = "device-lone",
                      g = "guest-peer", h = "device-hidden", n = "master-n";

    {
        Tally t(fwd);
        t.add(Seat{d1, false, false, &m});
        t.add(Seat{d2, false, false, &m});
        check("two devices of one identity are one person", t.people() == 1);
    }
    {
        Tally t(fwd);
        t.add(Seat{fwd, false, false, nullptr});
        check("the configured forwarder is nobody", t.people() == 0);
        t.add(Seat{d1, false, false, &m});
        check("and a device beside it is one", t.people() == 1);
    }
    {
        const std::string none;
        Tally t(none);
        t.add(Seat{fwd, false, false, nullptr});
        check("with no forwarder configured every device counts", t.people() == 1);
    }
    {
        Tally t(fwd);
        t.add(Seat{h, false, true, &n});
        check("a hidden session is nobody", t.people() == 0);
        t.add(Seat{g, true, false, nullptr});
        check("and so is a guest", t.people() == 0);
    }
    {
        Tally t(fwd);
        t.add(Seat{d1, false, false, &m});
        t.add(Seat{d2, false, true, &m});
        check("an identity with one device on screen is one person", t.people() == 1);
    }
    {
        Tally t(fwd);
        t.add(Seat{lone, false, false, nullptr});
        t.add(Seat{d1, false, false, &m});
        check("a device the fold places nowhere is a person of its own", t.people() == 2);
    }
    {
        Tally t(fwd);
        t.add(Seat{m, false, false, nullptr});
        t.add(Seat{d1, false, false, &m});
        check("a bare master login adds nobody to its identity", t.people() == 1);
    }
    {
        Tally t(fwd);
        t.add(Seat{d1, false, false, &m});
        t.add(Seat{d2, false, false, &n});
        check("devices of two identities are two people", t.people() == 2);
    }

    if (failures) printf("%d FAILED\n", failures);
    return failures ? 1 : 0;
}
