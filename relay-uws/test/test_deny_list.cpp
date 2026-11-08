// Unit tests for the operator denylist (src/deny_list.h): what the file may say, what
// one bad entry costs (the whole file), how addresses become the keys sockets carry,
// what changed between two lists, and the devices learned for a listed identity.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_deny_list.cpp -o test_deny_list && ./test_deny_list

#include "deny_list.h"

#include <fcntl.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <ctime>
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

static const std::string S40 = "3f2a0b1c2d3e4f5061728394a5b6c7d8e9f00112";
static const std::string S32 = "00112233445566778899aabbccddeeff";
static const std::string M1 = "12D3KooWAx1yGq5n7mCgS2kS8wYk7c2XQGtB4V3pX8XnZfnwq7mD";
static const std::string M2 = "12D3KooWBy2zHr6o8nDhT3mT9xZm8d3YRHuC5W4qY9YoAgoxr8nE";

static std::string file(const std::string& servers, const std::string& identities, const std::string& networks,
                        const std::string& version = "1") {
    return "{\"version\":" + version + ",\"servers\":" + servers + ",\"identities\":" + identities +
           ",\"networks\":" + networks + "}";
}

static bool refused(const std::string& text) {
    deny::Parsed p = deny::parse(text);
    return !p.list && !p.error.empty();
}

static std::set<std::string> nets(const std::string& entry) {
    deny::Parsed p = deny::parse(file("[]", "[]", "[" + entry + "]"));
    return p.list ? p.list->networks : std::set<std::string>{"<refused>"};
}

static void test_parse() {
    {
        const std::string text =
            "{\"version\":1,\"note\":\"unknown keys are read past\",\n"
            " \"servers\":[\"" + S40 + "\",{\"id\":\"conf:" + S40 + "\",\"ref\":\"N-2026-014\",\"added\":\"2026-11-07\"},\"" +
            S32 + "\"],\n"
            " \"identities\":[{\"id\":\"" + M1 + "\",\"ref\":\"N-2026-015\",\"why\":{\"nested\":1}}],\n"
            " \"networks\":[\"203.0.113.7\",{\"ip\":\"2001:db8:1:2::/64\"}]}";
        deny::Parsed p = deny::parse(text);
        check("a file of bare and object entries reads", p.list.has_value());
        if (p.list) {
            check("every server and meeting id is kept",
                  p.list->servers == std::set<std::string>{S40, "conf:" + S40, S32});
            check("identities are kept", p.list->identities == std::set<std::string>{M1});
            check("networks are kept as socket keys",
                  p.list->networks == std::set<std::string>{"203.0.113.7", "2001:db8:1:2::/64"});
        }
    }
    {
        deny::Parsed p = deny::parse(file("[]", "[]", "[]"));
        check("an empty file is a valid empty list", p.list && p.list->empty());
    }
    {
        std::string upper = S40;
        for (char& c : upper) c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
        deny::Parsed p = deny::parse(file("[\"" + upper + "\",\"CONF:" + upper + "\"]", "[]", "[]"));
        check("server ids in any case are kept lower-cased",
              p.list && p.list->servers == std::set<std::string>{S40, "conf:" + S40});
    }
    {
        deny::Parsed p = deny::parse(file("[\"" + S40 + "\",{\"id\":\"" + S40 + "\"}]", "[\"" + M1 + "\",\"" + M1 + "\"]",
                                          "[\"10.0.0.1\",\"10.0.0.1\"]"));
        check("duplicates collapse", p.list && p.list->servers.size() == 1 && p.list->identities.size() == 1 &&
                                         p.list->networks.size() == 1);
    }
    // Every wrong shape refuses the whole file, never just the entry.
    check("a bad server id refuses the file", refused(file("[\"" + S40 + "\",\"xyz\"]", "[]", "[]")));
    check("a server id of the wrong length refuses the file", refused(file("[\"" + S40 + "0\"]", "[]", "[]")));
    check("a meeting id of the wrong shape refuses the file", refused(file("[\"conf:abc\"]", "[]", "[]")));
    check("a subgroup id refuses the file", refused(file("[\"" + S40 + "#general\"]", "[]", "[]")));
    check("a bad identity refuses the file", refused(file("[]", "[\"" + M1 + "\",\"0OIl\"]", "[]")));
    check("a garbled address refuses the file", refused(file("[]", "[]", "[\"10.0.0\"]")));
    check("a v4 range refuses the file", refused(file("[]", "[]", "[\"10.0.0.0/24\"]")));
    check("a v4 /32 refuses the file", refused(file("[]", "[]", "[\"10.0.0.1/32\"]")));
    check("a v6 /48 refuses the file", refused(file("[]", "[]", "[\"2001:db8:1::/48\"]")));
    check("a /64 with host bits refuses the file", refused(file("[]", "[]", "[\"2001:db8:1:2::9/64\"]")));
    check("a v4-mapped /64 refuses the file", refused(file("[]", "[]", "[\"::ffff:10.0.0.1/64\"]")));
    check("an address with a zone refuses the file", refused(file("[]", "[]", "[\"fe80::1%eth0\"]")));
    check("a number entry refuses the file", refused(file("[42]", "[]", "[]")));
    check("an object without its id refuses the file", refused(file("[{\"ref\":\"x\"}]", "[]", "[]")));
    check("an object whose id is not text refuses the file", refused(file("[{\"id\":5}]", "[]", "[]")));
    check("a network object names its address as ip", refused(file("[]", "[]", "[{\"id\":\"10.0.0.1\"}]")));
    check("a list that is not a list refuses the file", refused(file("\"" + S40 + "\"", "[]", "[]")));
    check("a missing list refuses the file", refused("{\"version\":1,\"servers\":[],\"identities\":[]}"));
    check("a misspelt list refuses the file",
          refused("{\"version\":1,\"server\":[\"" + S40 + "\"],\"identities\":[],\"networks\":[]}"));
    check("version 2 refuses the file", refused(file("[]", "[]", "[]", "2")));
    check("a version as text refuses the file", refused(file("[]", "[]", "[]", "\"1\"")));
    check("a missing version refuses the file", refused("{\"servers\":[],\"identities\":[],\"networks\":[]}"));
    check("a top-level list refuses the file", refused("[]"));
    check("text that is not JSON refuses the file", refused("{\"version\":1,"));
    check("an empty file refuses", refused(""));
    check("a NUL byte refuses the file", refused(file("[]", "[]", "[]") + std::string(1, '\0')));
    check("nesting past the shape refuses the file",
          refused("{\"version\":1,\"servers\":[{\"id\":\"" + S40 + "\",\"ref\":[[[1]]]}],\"identities\":[],\"networks\":[]}"));
    check("deep nesting refuses the file without walking it", refused(std::string(100000, '[')));
    {
        std::string big = "{\"version\":1,\"servers\":[],\"identities\":[],\"networks\":[],\"pad\":\"" +
                          std::string(deny::MAX_FILE_BYTES, 'x') + "\"}";
        check("a file over 8 MiB refuses", refused(big));
    }
    {
        std::string many = "[";
        for (size_t i = 0; i <= deny::MAX_ENTRIES; i++) many += std::string(i ? "," : "") + "\"10.0.0.1\"";
        many += "]";
        check("a list past 65536 entries refuses", refused(file("[]", "[]", many)));
    }
    {
        deny::Parsed p = deny::parse("{\"version\":1,\n\"servers\":[\n\"" + S40 + "\",\n\"bad-" + M1 + "\"],\"identities\":[],\"networks\":[]}");
        check("an error names the list and the entry", p.error.find("servers, entry 2") != std::string::npos);
        check("an error never repeats the entry", p.error.find(M1) == std::string::npos);
        deny::Parsed q = deny::parse("{\"version\":1,\n\"servers\":[\n\"" + S40 + "\" \"x\"]}");
        check("a JSON error names its line", q.error.find("line 3") != std::string::npos);
    }
}

static void test_networks() {
    check("a v4 address is its own key", nets("\"203.0.113.7\"") == std::set<std::string>{"203.0.113.7"});
    check("a v6 address keys to its /64", nets("\"2001:db8:1:2::9\"") == std::set<std::string>{"2001:db8:1:2::/64"});
    check("an explicit /64 is the same key", nets("\"2001:db8:1:2::/64\"") == std::set<std::string>{"2001:db8:1:2::/64"});
    check("a long-form v6 address keys canonically",
          nets("\"2001:0DB8:0001:0002:0000:0000:0000:0009\"") == std::set<std::string>{"2001:db8:1:2::/64"});
    check("a v4-mapped address keys as v4", nets("\"::ffff:198.51.100.4\"") == std::set<std::string>{"198.51.100.4"});
    // The key a listed address gets is the one a socket from it carries (ip_key.h).
    check("a v6 socket from the block carries the key",
          nets("\"2001:db8:1:2::/64\"").count(ip_limit_key("2001:0db8:0001:0002:abcd:0000:0000:0001")) == 1);
    check("a v4 client on the dual-stack listener carries the key",
          nets("\"198.51.100.4\"").count(ip_limit_key("0000:0000:0000:0000:0000:ffff:c633:6404")) == 1);
}

static void test_diff() {
    deny::List a, b;
    a.servers = {S40, S32};
    a.identities = {M1};
    a.networks = {"10.0.0.1"};
    b.servers = {S40};
    b.identities = {M1, M2};
    b.networks = {"10.0.0.2"};
    deny::Diff d = deny::diff(a, b);
    check("what was added", d.added.servers.empty() && d.added.identities == std::set<std::string>{M2} &&
                                d.added.networks == std::set<std::string>{"10.0.0.2"});
    check("what was removed", d.removed.servers == std::set<std::string>{S32} && d.removed.identities.empty() &&
                                  d.removed.networks == std::set<std::string>{"10.0.0.1"});
    check("a list against itself changes nothing", deny::diff(a, a).empty());
    deny::Diff start = deny::diff(deny::List{}, a);
    check("a start adds everything", start.added == a && start.removed.empty());
}

static std::string dev(int i) {
    std::string s = "12D3KooWDevice";
    s += std::to_string(i);
    while (s.size() < 52) s += 'x';
    return s;
}

static void test_learned() {
    deny::Learned l;
    auto fresh = l.learn(M1, {dev(1), dev(2)});
    check("learning names what is new", fresh.size() == 2 && l.has(dev(1)) && l.has(dev(2)));
    fresh = l.learn(M1, {dev(1)});
    check("a device learned again is not new", fresh.empty());
    check("a device the next roster leaves out stays learned", l.has(dev(2)));
    l.learn(M2, {dev(1), dev(3)});
    l.forget(M1);
    check("forgetting one identity keeps a device another still names", l.has(dev(1)) && !l.has(dev(2)));
    check("and drops its own", l.size() == 2 && !l.holds(M1, dev(1)));
    l.forget(M2);
    check("forgetting every identity leaves nothing", l.size() == 0 && !l.has(dev(1)));

    // The bound is the identity's own: past it its least recently confirmed devices go,
    // and a fold just learned is never among them.
    deny::Learned c;
    std::set<std::string> fold;
    for (int i = 0; i < 300; i++) fold.insert(dev(10000 + i));
    for (int round = 0; round < 10; round++) {
        std::set<std::string> extra;
        for (int i = 0; i < 100; i++) extra.insert(dev(round * 100 + i));
        c.learn(M1, extra);
        c.learn(M1, fold);
    }
    bool fold_kept = true;
    for (const auto& d : fold) fold_kept = fold_kept && c.has(d);
    check("an identity holds at most its bound", c.size() == deny::Learned::PER_IDENTITY);
    check("the devices its rosters still name are never the ones that go", fold_kept);
    check("the oldest of the rest went first", !c.has(dev(0)) && c.has(dev(999)));

    // Restore order: entries come out least recently confirmed first.
    auto e = c.devices_of(M1);
    check("entries list the least recently confirmed first", !e.empty() && e.back() == *fold.rbegin());
}

static void test_state() {
    deny::State st;
    st.list.servers = {S40, "conf:" + S32};
    st.list.identities = {M1};
    st.list.networks = {"10.0.0.1"};
    std::string upper = S40;
    for (char& c : upper) c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
    check("a listed server room is denied", st.server_denied(S40));
    check("in any case", st.server_denied(upper));
    check("a listed meeting room is denied", st.server_denied("conf:" + S32) && st.server_denied("CONF:" + S32));
    check("an unlisted room is not", !st.server_denied(S32) && !st.server_denied("inbox:" + M1));
    check("a listed master is denied", st.peer_denied(M1));
    check("its devices only once learned", !st.peer_denied(dev(1)));
    auto fresh = st.learn_fold(M1, {dev(1)}, {dev(2)});
    check("a fold teaches members and consented pending joins", fresh.size() == 2 && st.peer_denied(dev(1)) &&
                                                                    st.peer_denied(dev(2)));
    check("a fold of an unlisted identity teaches nothing", st.learn_fold(M2, {dev(3)}, {}).empty() &&
                                                                !st.peer_denied(dev(3)));
    check("a listed network is denied by its key", st.network_denied("10.0.0.1") && !st.network_denied("10.0.0.2"));
}

// Review D10: the file counts as judged, and the list as applied, only once the apply
// returns; an apply cut short by a throw runs again on the next reading of the same file.
static void test_take() {
    deny::State st;
    deny::Loaded l;
    l.read = deny::Read::Ok;
    l.list.servers = {S40};
    l.stamp.exists = true;
    l.stamp.sec = 7;
    check("a file never judged is due", deny::due(st, l.stamp));
    int calls = 0;
    bool threw = false;
    try {
        deny::take(st, l, [&](const deny::Diff& d) {
            calls++;
            if (d.added.servers.count(S40)) throw std::runtime_error("cut short");
        });
    } catch (const std::exception&) {
        threw = true;
    }
    check("an apply cut short leaves the list in force", threw && st.server_denied(S40));
    check("but neither applied nor judged", st.applied.empty() && !st.judged_once && deny::due(st, l.stamp));
    std::vector<deny::Diff> seen;
    deny::take(st, l, [&](const deny::Diff& d) { seen.push_back(d); });
    check("the next reading applies it again", seen.size() == 1 && seen[0].added.servers.count(S40) == 1);
    check("and then it is applied and judged", st.applied == l.list && st.judged_once && !deny::due(st, l.stamp));
    deny::Loaded bad;
    bad.read = deny::Read::Bad;
    bad.stamp.exists = true;
    bad.stamp.sec = 8;
    seen.clear();
    deny::take(st, bad, [&](const deny::Diff& d) { seen.push_back(d); });
    check("an unreadable file keeps the list and applies nothing", st.server_denied(S40) && seen.empty() &&
                                                                       !deny::due(st, bad.stamp));
    deny::Loaded cleared;
    cleared.read = deny::Read::Ok;
    cleared.stamp.exists = true;
    cleared.stamp.sec = 9;
    deny::take(st, cleared, [&](const deny::Diff& d) { seen.push_back(d); });
    check("a valid empty file lifts what was listed", !st.server_denied(S40) && seen.size() == 1 &&
                                                          seen[0].removed.servers.count(S40) == 1);
    (void)calls;
}

static std::string scratch(const char* name) {
    const char* tmp = getenv("TMPDIR");
    std::string dir = tmp && *tmp ? tmp : "/tmp";
    return dir + "/deny_list_test_" + std::to_string(getpid()) + "_" + name;
}

static void write_text(const std::string& path, const std::string& text) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    fwrite(text.data(), 1, text.size(), f);
    fclose(f);
}

static void test_load() {
    const std::string path = scratch("denylist.json");
    unlink(path.c_str());
    check("a missing file says so", deny::load(path).read == deny::Read::Missing);
    write_text(path, "{");
    deny::Loaded bad = deny::load(path);
    check("an unreadable file says so", bad.read == deny::Read::Bad && !bad.error.empty());
    write_text(path, file("[\"" + S40 + "\"]", "[]", "[]"));
    deny::Loaded good = deny::load(path);
    check("a good file reads", good.read == deny::Read::Ok && good.list.servers.count(S40) == 1 && good.stamp.exists);

    // Two writes of the same size in the same second, and a rename onto the path, all show.
    struct timespec t[2] = {{1790000000, 100}, {1790000000, 100}};
    utimensat(AT_FDCWD, path.c_str(), t, 0);
    FileStamp a = file_stamp(path);
    t[0].tv_nsec = t[1].tv_nsec = 200;
    utimensat(AT_FDCWD, path.c_str(), t, 0);
    FileStamp b = file_stamp(path);
    check("an edit inside the same second shows", a != b);
    const std::string next = scratch("denylist.next");
    write_text(next, file("[\"" + S32 + "\"]", "[]", "[]"));
    t[0].tv_nsec = t[1].tv_nsec = 200;
    utimensat(AT_FDCWD, next.c_str(), t, 0);
    rename(next.c_str(), path.c_str());
    FileStamp c = file_stamp(path);
    check("a rename onto the path shows", c != b);
    unlink(path.c_str());
    check("a removed file shows", !file_stamp(path).exists);
}

// An older server's 32-hex id has the shape of a DM room and an identity's own room (R7).
static void test_legacy_shaped() {
    deny::Parsed p = deny::parse(file("[\"" + S40 + "\",\"" + deny::lower("00112233445566778899AABBCCDDEEFF") +
                                          "\",\"conf:" + S32 + "\",\"conf:" + S40 + "\"]",
                                      "[]", "[]"));
    check("a list reads with a 32-hex server entry", p.list.has_value());
    check("which alone is counted as shaped like a direct room", p.list && deny::legacy_shaped(*p.list) == 1);
    deny::Parsed upper = deny::parse(file("[\"00112233445566778899AABBCCDDEEFF\"]", "[]", "[]"));
    check("written in capitals too", upper.list && deny::legacy_shaped(*upper.list) == 1);
    deny::Parsed none = deny::parse(file("[\"" + S40 + "\",\"conf:" + S32 + "\"]", "[]", "[]"));
    check("a 40-hex id and a meeting id are not", none.list && deny::legacy_shaped(*none.list) == 0);
}

int main() {
    test_parse();
    test_legacy_shaped();
    test_networks();
    test_diff();
    test_learned();
    test_state();
    test_take();
    test_load();
    if (failures) printf("%d FAILED\n", failures);
    return failures ? 1 : 0;
}
