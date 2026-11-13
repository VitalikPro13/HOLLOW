// Unit tests for sibling push mutes (src/sib_mute.h): the frame's shape, the order of
// two writes, the push check, the device's own prefs carrying the marks, and the purge of
// marks whose writer the identity no longer counts.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_sib_mute.cpp -o test_sib_mute && ./test_sib_mute

#include "sib_mute.h"

#include <cstdio>
#include <set>
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

static constexpr int64_t NOW = 1'790'000'000'000;
static const std::string M = "12D3KooWMasterMasterMasterMasterMasterMasterMasterMa";
static const std::string S1 = "0123456789abcdef0123456789abcdef01234567";
static const std::string S2 = "abcdefabcdefabcdefabcdefabcdefab";

static json frame(int64_t at, int64_t set_at, json servers) {
    return {{"type", "mute_siblings"}, {"master", M}, {"at", at}, {"set_at", set_at}, {"servers", std::move(servers)}};
}

static sib::Frame parsed(int64_t at, int64_t set_at, json servers) {
    return *sib::parse(frame(at, set_at, std::move(servers)), NOW);
}

static void test_parse() {
    printf("parse: one bad field refuses the whole frame\n");
    check("a well formed frame", sib::parse(frame(NOW, NOW, {S1, S2}), NOW).has_value());
    check("an empty set (ON) is a frame", sib::parse(frame(NOW, NOW, json::array()), NOW).has_value());
    check("a stamp within ten minutes ahead", sib::parse(frame(NOW + sib::MAX_FUTURE_MS, NOW, {S1}), NOW).has_value());
    check("a choice stamp past ten minutes ahead", !sib::parse(frame(NOW + sib::MAX_FUTURE_MS + 1, NOW, {S1}), NOW));
    check("a flags stamp past ten minutes ahead", !sib::parse(frame(NOW, NOW + sib::MAX_FUTURE_MS + 1, {S1}), NOW));
    check("a zero stamp", !sib::parse(frame(0, NOW, {S1}), NOW));
    json text_at = frame(NOW, NOW, {S1});
    text_at["at"] = "1";
    check("a stamp that is no integer", !sib::parse(text_at, NOW));
    json many = json::array();
    for (int i = 0; i < 257; i++) many.push_back(S1);
    check("257 servers", !sib::parse(frame(NOW, NOW, many), NOW));
    check("an inbox room is no server", !sib::parse(frame(NOW, NOW, {S1, "inbox:" + M}), NOW));
    check("a DM room code is no server", !sib::parse(frame(NOW, NOW, {"dm-0123456789abcdef"}), NOW));
    check("an upper-case server id", !sib::parse(frame(NOW, NOW, {"0123456789ABCDEF0123456789abcdef01234567"}), NOW));
    json bad_master = frame(NOW, NOW, {S1});
    bad_master["master"] = "x";
    check("a master of the wrong shape", !sib::parse(bad_master, NOW));
    check("a missing set_at", !sib::parse(json{{"master", M}, {"at", NOW}, {"servers", {S1}}}, NOW));
}

static void test_order() {
    printf("order: a newer choice or a newer view of the flags replaces, equal stamps only add\n");
    Prefs p;
    check("a first write lands", sib::apply(p, parsed(100, 100, {S1, S2}), "d1"));
    check("it mutes both", sib::muted(p, S1) && sib::muted(p, S2));
    check("the same stamps again change nothing", !sib::apply(p, parsed(100, 100, {S1}), "d2"));
    check("(and the marks stand)", sib::muted(p, S2) && p.at(sib::KEY).channels.at(sib::BY) == "d1");
    check("an older choice changes nothing", !sib::apply(p, parsed(99, 500, json::array()), "d2"));
    check("an older view of the flags at the same choice changes nothing",
          !sib::apply(p, parsed(100, 99, {S1}), "d2") && sib::muted(p, S2));
    check("a newer view of the flags at the same choice replaces, empty included",
          sib::apply(p, parsed(100, 101, json::array()), "d2") && !sib::muted(p, S1) && !sib::muted(p, S2));
    check("a newer choice replaces", sib::apply(p, parsed(200, 1, {S2}), "d3") && sib::muted(p, S2) && !sib::muted(p, S1));
    check("the writer is kept", p.at(sib::KEY).channels.at(sib::BY) == "d3");
    check("equal stamps add a flag read late", sib::apply(p, parsed(200, 1, {S1}), "d4") && sib::muted(p, S1));
    check("and never lift one", sib::muted(p, S2) && p.at(sib::KEY).channels.at(sib::BY) == "d4");
}

static void test_add_cap() {
    printf("add: equal stamps never grow the marks past the frame cap\n");
    Prefs p;
    json first = json::array(), more = json::array();
    char id[33];
    for (int i = 0; i < 300; i++) {
        snprintf(id, sizeof id, "%032x", i);
        (i < 200 ? first : more).push_back(std::string(id));
    }
    sib::apply(p, parsed(100, 100, first), "d1");
    sib::apply(p, parsed(100, 100, more), "d2");
    size_t marks = 0;
    for (const auto& [k, v] : p.at(sib::KEY).channels) marks += k[0] != '~';
    check("256 marks at most", marks == sib::MAX_SERVERS);
}

static void test_view() {
    printf("view: a device caught up to its siblings' marks lifts them for itself\n");
    Prefs held;
    sib::apply(held, parsed(100, 100, {S1}), "d1");
    Prefs older;
    sib::carry(held, older, false, sib::View{100, 99});
    check("an older view keeps the marks", sib::muted(older, S1));
    Prefs caught;
    sib::carry(held, caught, false, sib::View{100, 100});
    check("an equal view lifts them", !sib::muted(caught, S1));
    check("and keeps the stamps, so the same frame again adds what it names",
          sib::apply(caught, parsed(100, 100, {S2}), "d1") && sib::muted(caught, S2));
    Prefs past;
    sib::carry(held, past, false, sib::View{100, 150});
    check("a frame older than the view sets nothing", !sib::apply(past, parsed(100, 120, {S1}), "d1") && !sib::muted(past, S1));
    check("a newer one marks again", sib::apply(past, parsed(100, 151, {S1}), "d1") && sib::muted(past, S1));
    Prefs none, made;
    sib::carry(none, made, false, sib::View{100, 150});
    check("a view with nothing held keeps its stamps", !sib::apply(made, parsed(100, 120, {S1}), "d1"));
    check("a view refuses as a frame does", !sib::parse_view(json{{"at", NOW + sib::MAX_FUTURE_MS + 1}, {"set_at", 1}}, NOW) &&
                                                !sib::parse_view(json{{"at", 1}}, NOW) && sib::parse_view(json{{"at", 1}, {"set_at", 2}}, NOW));
}

static void test_writer() {
    printf("writer: owning the inbox is not enough; the fold must count it now\n");
    struct Fold {
        std::set<std::string> members;
        bool is_member(const std::string& d) const { return members.count(d) != 0; }
    };
    check("an owner the fold counts writes", sib::writer_counted(true, Fold{{"d1"}}, "d1"));
    check("an owner the fold stopped counting writes nothing", !sib::writer_counted(true, Fold{{"d2"}}, "d1"));
    check("a counted device that owns nothing writes nothing", !sib::writer_counted(false, Fold{{"d1"}}, "d1"));
}

static void test_forget() {
    printf("forget: an evicted record takes the marks its fold allowed\n");
    Prefs p;
    sib::apply(p, parsed(100, 100, {S1}), "d1");
    check("the marks go", sib::forget(p) && !sib::muted(p, S1) && p.count(sib::KEY) == 0);
    check("nothing twice", !sib::forget(p));
    Prefs local;
    sib::carry(Prefs{}, local, true);
    sib::apply(local, parsed(100, 100, {S1}), "d1");
    check("a device's own level stays", sib::forget(local) && local.at(sib::KEY).level == "all");
}

static void test_push_check() {
    printf("push check: only a marked server is silenced, never the device's own entries\n");
    Prefs p;
    p[S1] = Pref{"all", {}};
    check("no entry mutes nothing", !sib::muted(p, S1));
    sib::apply(p, parsed(100, 100, {S2}), "d1");
    check("a marked server is silenced", sib::muted(p, S2));
    check("an unmarked one is not", !sib::muted(p, S1));
    check("a reserved key is no server", !sib::muted(p, sib::AT) && !sib::muted(p, sib::BY));
    check("the device's own entry is untouched", p.at(S1).level == "all");
    p.at(sib::KEY).level = "all";
    check("a device that does not follow its siblings is woken", !sib::muted(p, S2));
}

static void test_carry() {
    printf("carry: the device's own prefs keep its siblings' marks\n");
    Prefs held;
    sib::apply(held, parsed(100, 100, {S1}), "d1");
    Prefs fresh;
    fresh[S1] = Pref{"all", {}};
    fresh[sib::KEY] = Pref{"all", {}};  // never taken from a client
    sib::carry(held, fresh, false);
    check("a phone's stale prefs never undo the mark", sib::muted(fresh, S1));
    check("its own entry is its own", fresh.at(S1).level == "all");
    Prefs local;
    sib::carry(held, local, true);
    check("its own local yes lifts the marks for it alone", !sib::muted(local, S1) && local.at(sib::KEY).channels.count(S1));
    Prefs back;
    sib::carry(local, back, false);
    check("and its own no puts them back", sib::muted(back, S1));
    Prefs none, out;
    sib::carry(none, out, false);
    check("nothing held, nothing made", out.count(sib::KEY) == 0);
    Prefs opt;
    sib::carry(none, opt, true);
    check("a local yes with nothing held is remembered", opt.at(sib::KEY).level == "all");
    sib::apply(opt, parsed(100, 100, {S1}), "d1");
    check("and a later mark keeps it", opt.at(sib::KEY).level == "all" && !sib::muted(opt, S1));
}

static void test_purge() {
    printf("purge: a writer the identity no longer counts takes its marks with it\n");
    Prefs p;
    sib::apply(p, parsed(5'000, 5'000, {S1}), "gone");
    auto counted = [](const std::string& d) { return d != "gone"; };
    check("a counted writer keeps its marks", !sib::purge(p, [](const std::string&) { return true; }) && sib::muted(p, S1));
    check("an uncounted writer's marks go", sib::purge(p, counted) && !sib::muted(p, S1));
    check("stamps and all, so a remaining computer's older choice is taken again",
          sib::apply(p, parsed(100, 100, {S2}), "stays") && sib::muted(p, S2));
    Prefs local;
    sib::carry(Prefs{}, local, true);
    sib::apply(local, parsed(5'000, 5'000, {S1}), "gone");
    sib::purge(local, counted);
    check("a purge keeps the device's own level", local.at(sib::KEY).level == "all" && local.at(sib::KEY).channels.empty());
}

static void test_weight() {
    printf("weight: the entry weighs what charge_registrations counts\n");
    Prefs p;
    check("no entry weighs nothing", sib::entry_weight(p) == 0);
    sib::apply(p, parsed(100, 100, {S1}), "d1");
    const auto& e = p.at(sib::KEY);
    size_t w = 96 + std::string(sib::KEY).size() + e.level.size();
    for (const auto& [k, v] : e.channels) w += 96 + k.size() + v.size();
    check("the same count", sib::entry_weight(p) == w);
}

int main() {
    test_parse();
    test_order();
    test_add_cap();
    test_view();
    test_writer();
    test_forget();
    test_push_check();
    test_carry();
    test_purge();
    test_weight();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
