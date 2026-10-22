// Unit tests for what /server-stats tells anyone when the operator turns the public
// activity off (PUBLIC_STATS=off, src/server_stats.h), and how the setting is read.
//   g++ -std=c++17 -I../src test_server_stats.cpp -o test_server_stats && ./test_server_stats

#include "server_stats.h"

#include <cstdio>
#include <set>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    printf(ok ? "  ok   %s\n" : "  FAIL %s\n", label.c_str());
    if (!ok) failures++;
}

static nlohmann::json full_body() {
    return {{"mem_total_kb", 8000000}, {"mem_used_kb", 1000000}, {"rx_mbps", 1.5},
            {"tx_mbps", 2.5},           {"bandwidth_cap_mbps", 950}, {"online_users", 3},
            {"send_backpressure", 1},   {"send_dropped", 0},        {"fwd_delivered", 7},
            {"fwd_buffered", 0},        {"ghost_left_suppressed", 2}, {"some_new_counter", 9}};
}

static std::set<std::string> keys(const nlohmann::json& j) {
    std::set<std::string> out;
    for (auto it = j.begin(); it != j.end(); ++it) out.insert(it.key());
    return out;
}

int main() {
    printf("server stats\n");
    nlohmann::json on = full_body();
    server_stats::keep_public(on, true);
    check("by default every field stays", on == full_body());

    nlohmann::json off = full_body();
    server_stats::keep_public(off, false);
    check("with the public stats off only memory and the cap are left",
          keys(off) == std::set<std::string>{"mem_total_kb", "mem_used_kb", "bandwidth_cap_mbps"});
    check("and the total and the cap are unchanged", off["mem_total_kb"] == 8000000 && off["bandwidth_cap_mbps"] == 950);
    check("memory in use is whole percent of the total", off["mem_used_kb"] == 960000);
    nlohmann::json before = full_body(), after = full_body();
    before["mem_used_kb"] = 1050000;
    after["mem_used_kb"] = 1050000 + 64 * 1024;
    server_stats::keep_public(before, false);
    server_stats::keep_public(after, false);
    check("so one 64 MiB deposit inside a percent does not move it",
          before["mem_used_kb"] == 1040000 && after["mem_used_kb"] == 1040000);
    nlohmann::json no_total = full_body();
    no_total.erase("mem_total_kb");
    server_stats::keep_public(no_total, false);
    check("without a total, memory in use is left out", !no_total.contains("mem_used_kb"));
    nlohmann::json zero_total = full_body();
    zero_total["mem_total_kb"] = 0;
    server_stats::keep_public(zero_total, false);
    check("and with a zero total too", !zero_total.contains("mem_used_kb"));
    nlohmann::json on_exact = full_body();
    server_stats::keep_public(on_exact, true);
    check("with the stats on, memory in use is exact", on_exact["mem_used_kb"] == 1000000);

    check("unset means on", server_stats::parse_public_stats(nullptr));
    check("empty means on", server_stats::parse_public_stats(""));
    check("on means on", server_stats::parse_public_stats("on"));
    check("off means off", !server_stats::parse_public_stats("off"));
    check("OFF means off", !server_stats::parse_public_stats("OFF"));
    for (const char* t : {"true", "1", "yes", "YES", " on ", "On\n"}) {
        check(std::string("'") + t + "' means on", server_stats::parse_public_stats(t));
    }
    for (const char* t : {"false", "0", "no", "No", " off", "\toff\n"}) {
        check(std::string("'") + t + "' means off", !server_stats::parse_public_stats(t));
    }
    check("anything else turns them off", !server_stats::parse_public_stats("maybe"));
    check("only spaces means on, as empty does", server_stats::parse_public_stats("   "));

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
