// Unit tests for the resumable-session core (src/session.h): which frames count, the
// auth v3 session field, and the ring that keeps what a device has not acked. The
// classification and shape cases come from session_vectors.json, which the client
// tests read too.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_session.cpp -o test_session && ./test_session

#include "json.hpp"
#include "session.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using json = nlohmann::json;
using session::Frame;
using session::Ring;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static Frame frame(const std::string& body, uint64_t share, uint64_t budget = 0) {
    Frame f;
    f.bytes = std::make_shared<const std::string>(body);
    f.share = share;
    f.budget_seq = budget;
    return f;
}

static auto ignore = [](const Frame&) {};

// What a client counts for one relay frame, the way section 9.3 reads.
static uint64_t relay_frame_counts(const json& c) {
    if (c.contains("binary_hex")) return 1;
    json j = json::parse(c["text"].get<std::string>(), nullptr, false);
    if (j.is_discarded() || !j.is_object() || !j.contains("type") || !j["type"].is_string()) return 1;
    const std::string type = j["type"];
    if (type == "gap") return j["n"].get<uint64_t>();
    return session::relay_type_counts(type) ? 1 : 0;
}

static uint64_t client_frame_counts(const json& c) {
    if (c.contains("binary_hex")) return 1;
    json j = json::parse(c["text"].get<std::string>(), nullptr, false);
    if (j.is_discarded() || !j.is_object() || !j.contains("type") || !j["type"].is_string()) return 1;
    return session::client_type_counts(j["type"].get<std::string>()) ? 1 : 0;
}

// The numbers a replay after `h` hands the device, gaps expanded.
static std::vector<std::string> replay(const Ring& r, uint64_t h) {
    std::vector<std::string> out;
    r.replay_after(h, [&out](const Frame& f, uint64_t n) {
        out.push_back(n ? session::gap_frame(n) : *f.bytes);
    });
    return out;
}

static uint64_t counted(const std::vector<std::string>& frames) {
    uint64_t n = 0;
    for (const auto& f : frames) {
        json j = json::parse(f, nullptr, false);
        n += (!j.is_discarded() && j.is_object() && j.value("type", "") == "gap") ? j["n"].get<uint64_t>() : 1;
    }
    return n;
}

int main() {
    printf("session core\n");

    // The vectors both languages read.
    {
        std::ifstream f("session_vectors.json");
        std::stringstream ss;
        ss << f.rdbuf();
        json v = json::parse(ss.str(), nullptr, false);
        const bool loaded = v.is_object() && v["counted"].is_array() && v["counted"].size() >= 40 &&
                            v["auth_v3_shape"].is_array();
        check("the vectors load", loaded);
        if (!loaded) v = json{{"counted", json::array()}, {"auth_v3_shape", json::array()}};
        size_t ok = 0, total = 0;
        for (const auto& c : v["counted"]) {
            total++;
            const uint64_t want = c["counts"];
            const uint64_t got = c["dir"] == "relay_to_client" ? relay_frame_counts(c) : client_frame_counts(c);
            if (got == want) {
                ok++;
            } else {
                printf("    mismatch %s %s: want %llu got %llu\n", c["dir"].get<std::string>().c_str(),
                       c.value("text", c.value("binary_hex", "")).c_str(), (unsigned long long)want,
                       (unsigned long long)got);
            }
        }
        check("every frame counts the way the vectors say (" + std::to_string(ok) + "/" + std::to_string(total) + ")",
              ok == total);
        size_t shapes_ok = 0;
        for (const auto& s : v["auth_v3_shape"]) {
            if (session::auth_session_ok(s["mode"].get<std::string>(), s["session"].get<std::string>()) == s["ok"].get<bool>()) {
                shapes_ok++;
            }
        }
        check("the auth v3 session field reads the way the vectors say", shapes_ok == v["auth_v3_shape"].size());
    }

    check("a gap frame names its count", session::gap_frame(3) == R"({"type":"gap","n":3})");
    check("a sid is 32 lowercase hex", session::is_sid_shape("00112233445566778899aabbccddeeff") &&
                                           !session::is_sid_shape("00112233445566778899AABBCCDDEEFF") &&
                                           !session::is_sid_shape("0011"));

    // Counting and acks: the first frame is 1, an ack forgets what it covers.
    {
        Ring r;
        check("a new ring has sent nothing", r.sent() == 0 && r.acked() == 0 && r.entries().empty());
        r.push(frame("a", 1));
        r.push(frame("b", 1));
        r.push(frame("c", 1));
        check("three frames count to three", r.sent() == 3 && r.real_frames() == 3 && r.bytes() == 3);
        check("a device with nothing resumes from 0", r.can_resume_from(0));
        check("a device claiming more than was sent cannot resume", !r.can_resume_from(4));
        check("the replay after 1 is the last two", replay(r, 1) == std::vector<std::string>{"b", "c"});
        std::vector<std::string> dropped;
        check("an ack in range is taken", r.ack(2, [&](const Frame& f) { dropped.push_back(*f.bytes); }));
        check("the ack drops exactly what it covers", dropped == std::vector<std::string>{"a", "b"} &&
                                                           r.real_frames() == 1 && r.bytes() == 1);
        check("a device behind its own ack cannot resume", !r.can_resume_from(1));
        check("an ack going backwards changes nothing", !r.ack(1, ignore) && r.acked() == 2);
        check("an ack past what was sent changes nothing", !r.ack(9, ignore) && r.acked() == 2);
        check("the replay after the ack is the rest", replay(r, 2) == std::vector<std::string>{"c"});
        check("a device holding everything gets nothing", replay(r, 3).empty());
    }

    // A flood into someone's ring evicts only the flooder, and the gap keeps the count.
    {
        Ring r;
        r.push(frame("friend-1", 1));
        for (int i = 0; i < 50; i++) r.push(frame("junk-" + std::to_string(i), 2));
        r.push(frame("friend-2", 1));
        r.enforce(SIZE_MAX, 10, ignore);
        check("the ring holds its cap", r.real_frames() == 10);
        auto out = replay(r, 0);
        check("both honest frames survive", std::count(out.begin(), out.end(), "friend-1") == 1 &&
                                                std::count(out.begin(), out.end(), "friend-2") == 1);
        check("the evicted run replays as one gap", out.size() == 11 && out[1] == session::gap_frame(42));
        check("the replay still counts every frame", counted(out) == r.sent() && r.sent() == 52);
        check("the replay after 0 has a gap", r.gap_after(0));
    }

    // Weight, not count: a share of many tiny frames still pays for each one.
    {
        Ring r;
        r.push(frame(std::string(3000, 'x'), 1));
        for (int i = 0; i < 4; i++) r.push(frame("t", 2));
        r.enforce(SIZE_MAX, 4, ignore);
        check("one tiny frame went, the big honest one stayed", replay(r, 0)[0] == std::string(3000, 'x'));
    }

    // Byte cap: one huge frame from a stranger goes before many small honest ones.
    {
        Ring r;
        for (int i = 0; i < 5; i++) r.push(frame("m" + std::to_string(i), 1));
        r.push(frame(std::string(10000, 'z'), 2));
        r.enforce(9000, SIZE_MAX, ignore);
        auto out = replay(r, 0);
        check("the huge frame is the one buried", out.size() == 6 && out[5] == session::gap_frame(1) &&
                                                      r.bytes() == 10);
    }

    // Tombstones merge with their neighbours on both sides.
    {
        Ring s;
        s.push(frame("1", 1, 11));
        s.push(frame("2", 1, 12));
        s.push(frame("3", 1, 13));
        s.push(frame("4", 1, 14));
        check("an unknown budget stamp buries nothing", !s.evict_budget_seq(99) && s.real_frames() == 4);
        s.evict_budget_seq(12);
        s.evict_budget_seq(14);
        s.evict_budget_seq(13);
        auto out = replay(s, 0);
        check("three neighbouring burials are one run", out == std::vector<std::string>{"1", session::gap_frame(3)});
        check("the run sits where its frames were", s.entries().size() == 2 && s.entries()[1].seq == 4 &&
                                                        s.entries()[1].gap == 3);
        check("no budget stamp buries a tombstone", !s.evict_budget_seq(0) && s.real_frames() == 1);
    }

    // A replay or an ack that starts inside a run takes only the run's tail.
    {
        Ring r;
        for (int i = 1; i <= 6; i++) r.push(frame(std::to_string(i), 1, static_cast<uint64_t>(i)));
        for (uint64_t b = 2; b <= 5; b++) r.evict_budget_seq(b);
        check("the ring is 1, a run of four, 6", replay(r, 0) == std::vector<std::string>{"1", session::gap_frame(4), "6"});
        check("a device that saw 3 gets the run's last two", replay(r, 3) == std::vector<std::string>{session::gap_frame(2), "6"});
        r.ack(3, ignore);
        check("an ack inside the run shortens it", r.entries().size() == 2 && r.entries()[0].gap == 2 &&
                                                       r.entries()[0].seq == 5);
        check("the shortened ring replays the same", replay(r, 3) == std::vector<std::string>{session::gap_frame(2), "6"});
    }

    // Every real frame leaves the budget exactly once, whichever way it leaves.
    {
        Ring r;
        for (uint64_t i = 1; i <= 20; i++) r.push(frame("f" + std::to_string(i), i % 3, 100 + i));
        std::multiset<uint64_t> released;
        auto release = [&released](const Frame& f) { released.insert(f.budget_seq); };
        r.enforce(SIZE_MAX, 15, release);
        r.ack(8, release);
        for (const auto& f : r.take_all()) released.insert(f.budget_seq);
        bool once = released.size() == 20;
        for (uint64_t i = 101; i <= 120; i++) once = once && released.count(i) == 1;
        check("each budget stamp is released once", once);
        check("a taken ring is empty and acks all it counted", r.entries().empty() && r.acked() == 20 &&
                                                                   r.bytes() == 0 && r.real_frames() == 0);
    }

    // A frame too big to keep still counts, as a gap.
    {
        Ring r;
        r.push(frame("a", 1));
        r.push_gap();
        r.push_gap();
        r.push(frame("b", 1));
        check("two unkept frames are one run of two", replay(r, 0) ==
                                                         std::vector<std::string>{"a", session::gap_frame(2), "b"});
        check("and the count holds", r.sent() == 4);
    }

    // The take-all hand-off keeps the frames' order and their direct metadata.
    {
        Ring r;
        Frame d = frame("dm", 1);
        d.kind = session::Kind::Direct;
        d.room = "room-a";
        r.push(frame("bcast", 2));
        r.push(std::move(d));
        auto all = r.take_all();
        check("the hand-off is in order with its metadata", all.size() == 2 && *all[0].bytes == "bcast" &&
                                                                all[1].kind == session::Kind::Direct &&
                                                                all[1].room == "room-a");
    }

    // A snapshot's ring comes back only when it is whole.
    {
        Ring r;
        for (int i = 1; i <= 5; i++) r.push(frame(std::to_string(i), 1, static_cast<uint64_t>(i)));
        r.evict_budget_seq(3);
        r.ack(1, ignore);
        auto back = Ring::restore(r.sent(), r.acked(), r.entries());
        check("a whole ring restores", back && back->sent() == 5 && back->acked() == 1 && back->real_frames() == 3 &&
                                           replay(*back, 1) == replay(r, 1));
        auto entries = r.entries();
        entries.pop_back();
        check("a ring missing its last frame is refused", !Ring::restore(r.sent(), r.acked(), entries));
        entries = r.entries();
        entries[0].bytes.reset();
        check("a real frame without bytes is refused", !Ring::restore(r.sent(), r.acked(), entries));
        entries = r.entries();
        entries[1].gap = 5;
        check("a run reaching below the ack is refused", !Ring::restore(r.sent(), r.acked(), entries));
        entries = r.entries();
        entries[2].seq = 3;
        check("a real frame numbered out of order is refused", !Ring::restore(r.sent(), r.acked(), entries));
        check("an ack above what was sent is refused", !Ring::restore(1, 2, {}));
        check("an empty ring with everything acked restores", Ring::restore(7, 7, {}).has_value());
        check("an empty ring missing frames is refused", !Ring::restore(7, 5, {}));
    }

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
