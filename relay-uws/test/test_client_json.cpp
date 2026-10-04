// Unit tests for the client JSON depth cap (src/client_json.h, C-RP-01). nlohmann
// parses any depth without recursing, but dump(), copies and comparisons recurse once
// per level: a frame nested past the cap must be refused before a value exists at all.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_client_json.cpp -o test_client_json && ./test_client_json

#include "client_json.h"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

using json = nlohmann::json;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static std::string arrays(size_t depth) { return std::string(depth, '[') + std::string(depth, ']'); }

static std::string objects(size_t depth) {
    std::string s;
    for (size_t i = 0; i < depth; i++) s += R"({"a":)";
    s += "1";
    return s + std::string(depth, '}');
}

static bool refused(const std::string& text) {
    try {
        return client_json::parse(text).is_discarded();
    } catch (...) {
        printf("  FAIL threw on a %zu-byte text\n", text.size());
        failures++;
        return false;
    }
}

static std::string read_file(const char* path) {
    std::ifstream f(path);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

int main() {
    printf("client JSON depth cap\n");
    const size_t cap = client_json::MAX_DEPTH;
    check("arrays at the cap parse", !refused(arrays(cap)));
    check("one array past the cap is refused", refused(arrays(cap + 1)));
    check("objects at the cap parse", !refused(objects(cap)));
    check("one object past the cap is refused", refused(objects(cap + 1)));
    check("arrays and objects count together", refused("[" + objects(cap) + "]"));

    const std::string hostile =
        R"({"type":"join","room":"inbox:x","inbox_roster":{"x":)" + arrays(200000) + "}}";
    check("a join with a roster nested 200,000 deep is refused", refused(hostile));
    check("a frame closing what it never opened stays within the cap", client_json::depth_within("]]]]}}[1]", 1));

    const std::string bracket_text = R"({"s":")" + std::string(1000, '[') + std::string(1000, '{') + R"("})";
    check("brackets inside a string do not count", !refused(bracket_text));
    check("an escaped quote does not end the string",
          !refused(R"({"s":"\")" + std::string(1000, '[') + R"("})"));
    check("an escaped backslash does end it, and what follows counts",
          refused(R"(["\\",)" + arrays(cap) + "]") && !refused(R"(["\\",)" + arrays(cap - 1) + "]"));

    check("text that is not JSON is refused", refused("not json") && refused("") && refused("{\"a\":"));
    const std::string frame = R"({"type":"subscribe","room":"r","topics":["a","b"]})";
    check("a real frame parses to what nlohmann alone gives", client_json::parse(frame) == json::parse(frame));

    const json rosters = json::parse(read_file("roster_vectors.json"), nullptr, false);
    size_t shown = 0, passed = 0;
    if (rosters.is_object() && rosters.contains("cases")) {
        for (const auto& c : rosters["cases"]) {
            if (!c.contains("shown") || c["shown"].is_null()) continue;
            shown++;
            json join = {{"type", "join"}, {"room", "inbox:" + c.value("master", "")}, {"inbox_roster", c["shown"]}};
            if (!refused(join.dump())) passed++;
        }
    }
    check("every roster the Rust vectors show passes inside a join (" + std::to_string(shown) + ")",
          shown > 0 && passed == shown);
    const json prefs = {{"type", "set_push_prefs"},
                        {"prefs", {{"srv", {{"level", "mentions"}, {"channels", {{"c", "nothing"}}}}}}}};
    check("push prefs, the deepest frame after a join, pass", !refused(prefs.dump()));

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
