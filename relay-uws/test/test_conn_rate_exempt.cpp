// Unit tests for the per-address keys (src/ip_key.h) and the new-connection rate
// exemption list (src/conn_rate_exempt.h, HOLLOW_CONN_RATE_EXEMPT).
//
// An entry must land on the SAME key the cap counts a socket under, or it exempts
// nothing (a v4 client arrives v4-mapped on the dual-stack listener) or too much
// (a malformed entry kept as raw text). Test-run test_relay_live covers the handler.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_conn_rate_exempt.cpp -o t && ./t

#include "conn_rate_exempt.h"
#include "ip_key.h"

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

static void check_key(const std::string& in, const std::string& want) {
    const std::string got = ip_limit_key(in);
    check("ip_limit_key " + in + " -> " + want + " (got " + got + ")", got == want);
}

// Whether `list` exempts a socket whose remote address uWS prints as `remote`.
static bool exempts(const conn_rate_exempt::List& list, const std::string& remote) {
    return list.contains(ip_limit_key(remote));
}

int main() {
    printf("ip_limit_key\n");
    check_key("192.0.2.7", "192.0.2.7");
    // uWS prints a v4-mapped peer as uncompressed v6 hex.
    check_key("0000:0000:0000:0000:0000:ffff:c000:0207", "192.0.2.7");
    check_key("::ffff:192.0.2.7", "192.0.2.7");
    check_key("2001:0db8:0001:0002:aaaa:bbbb:cccc:dddd", "2001:db8:1:2::/64");
    check_key("2001:db8:1:2::1", "2001:db8:1:2::/64");
    check("share_block keeps a v6 /48", share_block("2001:db8:1:2::1") == "2001:db8:1::/48");
    check("share_block unmaps a v4-mapped peer", share_block("::ffff:192.0.2.7") == "192.0.2.7");

    printf("absent and empty\n");
    {
        auto none = conn_rate_exempt::parse(nullptr);
        check("an absent value exempts nothing", none.keys.empty() && none.ignored == 0);
        check("and no v4 address", !exempts(none, "192.0.2.7"));
        auto empty = conn_rate_exempt::parse("");
        check("an empty value exempts nothing", empty.keys.empty() && empty.ignored == 0);
        auto blank = conn_rate_exempt::parse(" , ,\t");
        check("separators alone exempt nothing and count nothing", blank.keys.empty() && blank.ignored == 0);
        check("an empty list holds no empty key", !blank.contains("") && !none.contains(""));
    }

    printf("v4\n");
    {
        auto list = conn_rate_exempt::parse("192.0.2.7");
        check("a listed v4 address is exempt", exempts(list, "192.0.2.7"));
        check("also when it arrives v4-mapped", exempts(list, "0000:0000:0000:0000:0000:ffff:c000:0207"));
        check("its neighbour is not", !exempts(list, "192.0.2.8"));
        check("nor the v6 zero block", !exempts(list, "::1"));
        auto mapped = conn_rate_exempt::parse("::ffff:192.0.2.7");
        check("a v4-mapped entry exempts the v4 address", exempts(mapped, "192.0.2.7") && mapped.keys.size() == 1);
    }

    printf("v6\n");
    {
        auto list = conn_rate_exempt::parse("2001:db8:1:2::5");
        check("a listed v6 address exempts its /64", exempts(list, "2001:0db8:0001:0002:ffff:0000:0000:0001"));
        check("but not the next /64", !exempts(list, "2001:db8:1:3::5"));
        auto block = conn_rate_exempt::parse("2001:db8:1:2::/64");
        check("a /64 entry is taken", block.keys.size() == 1 && block.ignored == 0);
        check("and exempts that /64", exempts(block, "2001:db8:1:2:9::9"));
        auto both = conn_rate_exempt::parse("2001:db8:1:2::5, 2001:db8:1:2::6");
        check("two addresses of one /64 are one block", both.keys.size() == 1 && both.ignored == 0);
    }

    printf("lists and malformed entries\n");
    {
        auto list = conn_rate_exempt::parse(" 192.0.2.7 ,198.51.100.1\t2001:db8:9::1,,");
        check("commas, spaces and tabs separate entries", list.keys.size() == 3 && list.ignored == 0);
        check("each is exempt", exempts(list, "192.0.2.7") && exempts(list, "198.51.100.1") &&
                                    exempts(list, "2001:db8:9::77"));

        const char* bad[] = {"192.0.2", "192.0.2.256", "192.0.2.7/24", "192.0.2.7/64", "2001:db8::/48",
                             "2001:db8::/", "::ffff:192.0.2.7/64", "fe80::1%eth0", "192.0.2.7:443",
                             "relay.example", "*", "0x7f000001", "192.0.2.07x"};
        for (const char* b : bad) {
            auto one = conn_rate_exempt::parse(b);
            check(std::string("ignored: ") + b, one.keys.empty() && one.ignored == 1);
        }
        auto mixed = conn_rate_exempt::parse("nonsense,192.0.2.7,192.0.2.300");
        check("a malformed entry leaves the good ones", mixed.keys.size() == 1 && mixed.ignored == 2 &&
                                                            exempts(mixed, "192.0.2.7"));
        check("and exempts no raw text", !mixed.contains("nonsense") && !exempts(mixed, "nonsense"));
    }

    printf("addresses no client connects from\n");
    {
        const char* never[] = {"0.0.0.0", "0.1.2.3", "::", "::1", "0:0:0:0:0:0:0:1", "::/64", "::a00:1",
                               "::ffff:0.0.0.0", "::ffff:127.0.0.1", "127.0.0.1", "127.0.241.3",
                               "255.255.255.255", "224.0.0.1", "239.255.255.250", "240.0.0.1",
                               "ff02::1", "ff05::1:3", "ff00::/64"};
        for (const char* n : never) {
            auto one = conn_rate_exempt::parse(n);
            check(std::string("ignored and counted: ") + n, one.keys.empty() && one.ignored == 1);
        }
        const char* kept[] = {"1.0.0.1", "126.255.255.255", "128.0.0.1", "223.255.255.254",
                              "2001:db8::1", "fe00::1", "0:0:0:1::1"};
        for (const char* k : kept) {
            auto one = conn_rate_exempt::parse(k);
            check(std::string("kept: ") + k, one.keys.size() == 1 && one.ignored == 0);
        }
        auto mixed = conn_rate_exempt::parse("::1, 192.0.2.7, 0.0.0.0, 255.255.255.255");
        check("a list keeps its real address beside them", mixed.keys.size() == 1 && mixed.ignored == 3 &&
                                                               exempts(mixed, "192.0.2.7"));
        check("and exempts no loopback client", !exempts(mixed, "::1") && !exempts(mixed, "127.0.0.1"));

        // The test relay hears only loopback (HOLLOW_RELAY_TEST_LOOPBACK), so its list may
        // name a v4 loopback address; nothing else on the list changes.
        auto test_build = conn_rate_exempt::parse("::ffff:127.0.241.3, 127.0.0.2, ::1, 0.0.0.0", true);
        check("a test build keeps v4 loopback entries", test_build.keys.size() == 2 && test_build.ignored == 2 &&
                                                            exempts(test_build, "127.0.241.3"));
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
