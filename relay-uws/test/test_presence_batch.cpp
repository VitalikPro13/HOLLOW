// Unit tests for the room presence log (src/presence_batch.h) and the guard that keeps
// every presence announcement on the one path through it (ws_handler.cpp).
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -I../src test_presence_batch.cpp -o t && ./t

#include "presence_batch.h"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using presence_batch::Log;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static std::vector<std::string> ev(std::initializer_list<const char*> xs) { return {xs.begin(), xs.end()}; }

static void log_tests() {
    printf("log\n");
    Log log;
    bool now = false;
    log.append(true, "A", 1000, now);
    check("the first event after a quiet window flushes at once", now);
    log.clear(1000);
    log.append(true, "B", 1050, now);
    check("an event inside the window waits", !now);
    check("it is due a window after it was logged", log.due_ms() == 1050 + presence_batch::WINDOW_MS);
    log.append(false, "C", 1060, now);
    check("a second event waits too", !now);
    check("a viewer is sent every event in order", log.slice("V") == ev({"+B", "-C"}));
    check("a subject is not told of itself", log.slice("B") == ev({"-C"}));
    check("subjects are known", log.about("B") && log.about("C") && !log.about("V"));
    check("a viewer with nothing sent shares the rendering", log.plain_viewer("V") && !log.plain_viewer("B"));

    log.stamp("W");
    check("a stamped viewer has no slice", log.slice("W").empty() && !log.plain_viewer("W"));
    log.append(true, "C", 1070, now);
    check("a stamped viewer gets only what came after", log.slice("W") == ev({"+C"}));
    check("others still get everything, a flap stays a flap", log.slice("V") == ev({"+B", "-C", "+C"}));

    const uint64_t seq = log.seq();
    log.clear(1100);
    check("a clear keeps the sequence", log.seq() == seq && log.empty() && log.bytes() == 0);
    check("a clear forgets stamps and subjects", log.slice("W").empty() && !log.about("B") && log.plain_viewer("W"));
    log.append(true, "D", 1150, now);
    check("an event within the window of the last flush waits", !now);
    check("after a clear every viewer starts from the clear", log.slice("W") == ev({"+D"}));
    log.stamp("V");
    log.append(false, "D", 1160, now);
    check("a stamp after a clear counts from there", log.slice("V") == ev({"-D"}));
}

static void bound_tests() {
    printf("bounds\n");
    Log log;
    bool now = false;
    log.append(true, "first", 0, now);
    log.clear(0);
    size_t held = 0;
    for (size_t i = 0; i + 1 < presence_batch::MAX_EVENTS; i++) {
        held += log.append(true, "p" + std::to_string(i), 10, now);
        if (now) break;
    }
    check("a log below its bound waits", !now && log.size() == presence_batch::MAX_EVENTS - 1);
    check("the bytes it holds are counted", log.bytes() == held && held > 0);
    log.append(true, "last", 10, now);
    check("a full log flushes at once", now && log.size() == presence_batch::MAX_EVENTS);
}

static void frame_tests() {
    printf("frames\n");
    std::vector<std::string> events;
    for (size_t i = 0; i < presence_batch::MAX_EVENTS + 3; i++) events.push_back("+p" + std::to_string(i));
    auto fs = presence_batch::frames("room-1", events);
    check("a slice past the bound is split", fs.size() == 2);
    auto a = nlohmann::json::parse(fs[0]);
    auto b = nlohmann::json::parse(fs[1]);
    check("each frame names its room and type", a["type"] == "presence" && a["room"] == "room-1" && b["room"] == "room-1");
    check("in order, nothing lost", a["ev"].size() == presence_batch::MAX_EVENTS && b["ev"].size() == 3 &&
                                        a["ev"][0] == "+p0" && b["ev"][2] == events.back());
    check("an empty slice is no frame", presence_batch::frames("r", {}).empty());
}

// Every peer_joined/peer_left the relay writes goes through announce_door_change, which
// logs it for batching viewers: a direct write could overtake a batched event about the
// same peer (review F4).
static void guard_tests() {
    printf("guard\n");
    std::ifstream f("../src/ws_handler.cpp");
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string src = ss.str();
    check("the handler source is readable", src.size() > 10000);
    const std::string open = "static void announce_door_change(";
    // The definition, after its forward declaration.
    const size_t begin = src.rfind(open);
    const size_t end = begin == std::string::npos ? std::string::npos : src.find("\n}\n", begin);
    check("announce_door_change exists", begin != std::string::npos && end != std::string::npos);
    size_t outside = 0;
    for (const char* lit : {"\"peer_joined\"", "\"peer_left\""}) {
        for (size_t at = src.find(lit); at != std::string::npos; at = src.find(lit, at + 1)) {
            const bool inside = at > begin && at < end;
            // A call naming which announcement it wants is the one path, not a write.
            const size_t line = src.rfind('\n', at);
            const std::string head = src.substr(line + 1, at - line - 1);
            const bool caller = head.find("announce_door_change(") != std::string::npos ||
                                head.find("? \"peer_left\"") != std::string::npos ||
                                src.substr(line + 1, src.find('\n', at) - line - 1).find("announce_door_change(") !=
                                    std::string::npos ||
                                src.substr(line + 1, src.find('\n', at) - line - 1).find("hide ?") != std::string::npos;
            if (!inside && !caller) {
                outside++;
                printf("    a presence literal outside the one path: %s\n",
                       src.substr(line + 1, src.find('\n', at) - line - 1).c_str());
            }
        }
    }
    check("no presence frame is written outside announce_door_change", outside == 0);
}

int main() {
    log_tests();
    bound_tests();
    frame_tests();
    guard_tests();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
