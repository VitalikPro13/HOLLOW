// Unit tests for channel push filters (src/push_pref.h): what a `set_push_prefs` frame
// leaves the relay holding, and the level a channel wake meets, `~default` included; and
// the push sidecar's port (src/push_port.h).
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_push_pref.cpp -o test_push_pref && ./test_push_pref

#include "push_pref.h"
#include "push_port.h"

#include <cctype>
#include <cstdio>
#include <string>
#include <unordered_map>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

struct Pref {
    std::string level;
    std::unordered_map<std::string, std::string> channels;
};
using Prefs = std::unordered_map<std::string, Pref>;
using json = nlohmann::json;

// ws_handler.cpp's is_valid_room_code.
static bool room_code(const std::string& room) {
    if (room.empty() || room.size() > 128) return false;
    for (char c : room) {
        if (!std::isalnum(static_cast<unsigned char>(c)) && c != ':' && c != '-' && c != '_' && c != '.') return false;
    }
    return true;
}

static Prefs parse(const json& prefs) { return push_pref::parse<Prefs>(prefs, room_code); }

static std::string level(const Prefs& p, const std::string& server, const std::string& channel = "c") {
    return push_pref::level_for(&p, server, channel);
}

static const std::string A = "0123456789abcdef0123456789abcdef01234567";
static const std::string B = "fedcba9876543210fedcba9876543210fedcba98";

static void test_default() {
    printf("~default: the level of every server the device never set\n");
    const Prefs p = parse({{"~default", {{"level", "mentions"}, {"channels", json::object()}}}});
    check("the entry is kept", p.count("~default") == 1 && p.at("~default").level == "mentions");
    check("a server it never named wakes on mentions only", level(p, A) == "mentions");

    const Prefs q = parse({{"~default", {{"level", "mentions"}}}, {A, {{"level", "all"}}}});
    check("a server set to every message keeps it", level(q, A) == "all");
    check("while another follows the default", level(q, B) == "mentions");

    const Prefs r = parse({{"~default", {{"level", "nothing"}}},
                           {A, {{"level", "mentions"}, {"channels", {{"loud", "all"}}}}}});
    check("a channel's own level beats its server's", level(r, A, "loud") == "all");
    check("its server's beats the default", level(r, A, "quiet") == "mentions");
    check("a never-set server's channel meets the default", level(r, B, "loud") == "nothing");

    check("a device that sent no default (an older client) is woken by every post",
          level(parse({{A, {{"level", "mentions"}}}}), B) == "all");
    check("a device that registered nothing is woken by every post",
          push_pref::level_for<Prefs>(nullptr, A, "c") == "all");
}

static void test_default_shape() {
    printf("~default: one level and nothing else\n");
    const Prefs p = parse({{"~default", {{"level", "nothing"}, {"channels", {{"loud", "all"}}}}}});
    check("it names no channel", p.count("~default") == 1 && p.at("~default").channels.empty());
    check("so no channel of a never-set server escapes it", level(p, B, "loud") == "nothing");
    check("a level the relay does not know reads as every post",
          level(parse({{"~default", {{"level", "loud"}}}}), B) == "all");
    check("an entry that is no object is skipped", parse({{"~default", "mentions"}}).count("~default") == 0);
    const Prefs n = parse({{"~default", {{"level", 5}}}, {A, {{"level", "nothing"}}}});
    check("a level that is no string reads as every post, the rest kept",
          level(n, B) == "all" && level(n, A) == "nothing");
}

static void test_reserved_entries() {
    printf("reserved entries: read whatever else the frame holds\n");
    json big = json::object();
    for (int i = 0; i < 300; i++) big["srv" + std::to_string(1000 + i)] = {{"level", "all"}};
    big["~default"] = {{"level", "mentions"}};
    big["~dm"] = {{"level", "all"}, {"channels", {{"12D3KooWMuted", "nothing"}}}};
    const Prefs p = parse(big);
    size_t servers = 0;
    for (const auto& [k, v] : p) servers += k[0] != '~';
    check("server entries stay capped at 256", servers == push_pref::MAX_SERVERS);
    check("the default survives a full set", p.count("~default") == 1 && p.at("~default").level == "mentions");
    check("so does the muted-DM entry", p.count("~dm") == 1 && p.at("~dm").channels.count("12D3KooWMuted") == 1);
    check("a server past the cap follows the default", level(p, "srv1299") == "mentions");

    const Prefs q = parse({{"~dm", {{"level", "nothing"}, {"channels", {{A, "nothing"}}}}}});
    check("the muted-DM entry is never a server's level", level(q, A) == "all");
}

static void test_unknown_keys() {
    printf("unknown keys: skipped alone (what a relay older than ~default does with it)\n");
    const Prefs p = parse({{"~future", {{"level", "nothing"}}},
                           {"bad room!", {{"level", "nothing"}}},
                           {A, {{"level", "mentions"}}}});
    check("the rest of the set is kept", p.size() == 1 && p.count(A) == 1);
    check("a server it never named wakes on every post", level(p, B) == "all");
    check("the client never writes siblings' marks",
          parse({{"~sib", {{"level", "nothing"}, {"channels", {{A, "nothing"}}}}}}).empty());
    check("prefs that are no object hold nothing", parse(json::array({A})).empty());
}

static void test_sibling_marks() {
    printf("siblings' marks: beat every level the device set, the default too\n");
    Prefs p = parse({{"~default", {{"level", "all"}}}, {B, {{"level", "all"}}}});
    sib::Frame f;
    f.master = "12D3KooWMaster";
    f.at = 1;
    f.set_at = 1;
    f.servers = {A, B};
    sib::apply(p, f, "12D3KooWDesk");
    check("a marked never-set server stays silent", level(p, A) == "nothing");
    check("a marked server set to every message stays silent", level(p, B) == "nothing");
    check("an unmarked one follows the default", level(p, "srv-other") == "all");
}

static void test_push_port() {
    printf("push port: HOLLOW_PUSH_PORT moves the sidecar, unset keeps 3001\n");
    check("unset is 3001", push_port::parse(nullptr) == std::optional<uint16_t>(3001));
    check("empty is 3001", push_port::parse("") == std::optional<uint16_t>(3001));
    check("a port is taken as written", push_port::parse("40123") == std::optional<uint16_t>(40123));
    check("1 and 65535 are ports", push_port::parse("1") == std::optional<uint16_t>(1) &&
                                       push_port::parse("65535") == std::optional<uint16_t>(65535));
    bool refused = true;
    for (const char* bad : {"0", "65536", "-1", "+3001", " 3001", "3001 ", "3001x", "abc", "99999999999999999999"}) {
        refused = refused && !push_port::parse(bad);
    }
    check("anything else is no port", refused);
}

int main() {
    test_push_port();
    test_default();
    test_default_shape();
    test_reserved_entries();
    test_unknown_keys();
    test_sibling_marks();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
