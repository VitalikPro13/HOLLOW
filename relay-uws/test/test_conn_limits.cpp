// Unit tests for the connection limits as settings (src/conn_limits.h).
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -I../src test_conn_limits.cpp -o t && ./t

#include "conn_limits.h"

#include <cstdio>
#include <map>
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

static conn_limits::Parsed parse(std::map<std::string, std::string> m, uint64_t ram = 8ull << 30, bool test = false) {
    return conn_limits::parse(
        [&m](const char* k) -> const char* {
            auto it = m.find(k);
            return it == m.end() ? nullptr : it->second.c_str();
        },
        ram, test);
}

int main() {
    printf("settings\n");
    auto d = parse({});
    check("defaults", d.limits.v4.cap == 512 && d.limits.v6.cap == 128 && d.limits.v4.rate_per_min == 120 &&
                          d.limits.v6.rate_per_min == 30 && d.limits.login_per_block == 256 &&
                          d.limits.login_total == 10'000 && d.limits.breaker_enforce && d.notes.empty());
    check("the burst is the open cap", d.limits.v4.burst() == 512 && d.limits.v6.burst() == 128);
    check("the connected budget is a quarter of RAM", d.limits.connected == (8ull << 30) / 4 / conn_limits::SOCKET_BYTES);
    check("held to its span", parse({}, 64ull << 20).limits.connected == 4'096);
    auto s = parse({{"CONN_LIMIT_IPV4", "1000"}, {"CONN_RATE_IPV6", "60"}, {"BREAKER_MODE", "shadow"}});
    check("values are taken", s.limits.v4.cap == 1000 && s.limits.v6.rate_per_min == 60 && !s.limits.breaker_enforce &&
                                  s.notes.empty());
    auto g = parse({{"CONN_LIMIT_IPV4", "lots"}, {"CONN_RATE_IPV4", "12x"}, {"BREAKER_MODE", "off"}});
    check("garbage keeps the default, loudly",
          g.limits.v4.cap == 512 && g.limits.v4.rate_per_min == 120 && g.limits.breaker_enforce && g.notes.size() == 3);
    auto r = parse({{"CONN_LIMIT_IPV6", "2"}, {"CONN_RATE_IPV4", "100000"}, {"CONNECTED_LIMIT", "9"}});
    check("out of range is held to the nearer end", r.limits.v6.cap == 8 && r.limits.v4.rate_per_min == 6'000 &&
                                                        r.limits.connected == 1'024 && r.notes.size() == 3);
    auto b = parse({{"LOGIN_WINDOW_PER_BLOCK", "5000"}, {"LOGIN_WINDOW_TOTAL", "1000"}});
    check("a block window above the total is held to it", b.limits.login_per_block == 1000 && b.notes.size() == 1);
    auto t = parse({{"CONN_LIMIT_IPV4", "3"}, {"HOLLOW_RELAY_TEST_CONN_BURST", "10"}}, 8ull << 30, true);
    check("a live-test relay may fill an address with three", t.limits.v4.cap == 3 && t.limits.v4.burst() == 10);
    check("only a live-test relay reads the burst", parse({{"HOLLOW_RELAY_TEST_CONN_BURST", "10"}}).limits.v4.burst() == 512);
    check("ipv6 keys pick the v6 family", &d.limits.family("2001:db8::/64") == &d.limits.v6 &&
                                              &d.limits.family("192.0.2.1") == &d.limits.v4);
    const auto v6_floor = s.limits.floor_rate("2001:db8:1::/48");
    const auto v4_floor = s.limits.floor_rate("192.0.2.1");
    check("a v6 /48 pool's floor takes the v6 rate and burst", v6_floor.first == 60 && v6_floor.second == 128);
    check("a v4 block's floor takes the v4 rate and burst", v4_floor.first == 120 && v4_floor.second == 1000);
    check("the start line names the mode", conn_limits::describe(s.limits).find("shadow") != std::string::npos);
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
