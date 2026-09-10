// Unit tests for the TURN URI builder (src/turn_uris.h): what the relay hands
// a client that asks for TURN credentials.
//
// The property that matters is "the URIs name THIS relay". They were hardcoded
// to relay.anonlisten.com until 0.12, so TURN never worked on a self-hosted
// relay: every self-hoster's clients were handed the official host and were
// rejected there. The host also has to survive the four shapes a relay address
// arrives in, brackets and ports included, because a bare IPv6 literal or a
// dropped port produces a URI no ICE agent can use.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_turn_uris.cpp -o test_turn_uris && ./test_turn_uris

#include "turn_uris.h"

#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static void check_host(const std::string& in, const std::string& want) {
    std::string got = turn_host(in);
    check(in + " -> " + want + " (got " + got + ")", got == want);
}

int main() {
    printf("turn_host\n");
    check_host("relay.anonlisten.com", "relay.anonlisten.com");
    check_host("1.2.3.4", "1.2.3.4");
    check_host("host:8443", "host");
    check_host("[2001:db8::1]", "[2001:db8::1]");
    check_host("[2001:db8::1]:8443", "[2001:db8::1]");

    printf("turn_host edges\n");
    check_host("", "");
    check_host("myrelay.duckdns.org:443", "myrelay.duckdns.org");
    // A trailing colon with no digits is not a port, so nothing is stripped.
    check_host("host:", "host:");
    // A bare IPv6 literal has no port to strip and must survive intact.
    check_host("2001:db8::1", "2001:db8::1");

    printf("turn_uris\n");
    {
        std::vector<std::string> want = {
            "turn:myrelay.duckdns.org:3478",
            "turn:myrelay.duckdns.org:3478?transport=tcp",
            "turns:myrelay.duckdns.org:5349",
        };
        check("a name yields the three URIs", turn_uris("myrelay.duckdns.org") == want);
    }
    {
        std::vector<std::string> want = {
            "turn:1.2.3.4:3478",
            "turn:1.2.3.4:3478?transport=tcp",
            "turns:1.2.3.4:5349",
        };
        check("an IPv4 relay names itself", turn_uris("1.2.3.4") == want);
    }
    {
        std::vector<std::string> want = {
            "turn:[2001:db8::1]:3478",
            "turn:[2001:db8::1]:3478?transport=tcp",
            "turns:[2001:db8::1]:5349",
        };
        check("a bracketed IPv6 with a port keeps its brackets",
              turn_uris("[2001:db8::1]:8443") == want);
    }
    {
        // The regression this file exists for: a self-hosted relay must never
        // hand out the official host.
        std::vector<std::string> got = turn_uris("myrelay.duckdns.org");
        bool leaked = false;
        for (const auto& u : got) {
            if (u.find("anonlisten") != std::string::npos) leaked = true;
        }
        check("a self-hosted relay never advertises the official host", !leaked);
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
