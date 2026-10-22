// Unit tests for what presence may name to one socket (src/presence_view.h): the filter
// every roster and the digest share, the digest itself (pinned against
// node/presence_audit.rs), and the capped window an old client's ask gets.
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -I../src test_presence_view.cpp -lsodium -o test_presence_view && ./test_presence_view

#include "presence_view.h"

#include <cstdio>
#include <random>
#include <set>
#include <string>
#include <unordered_map>
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

struct Data {
    bool is_guest = false;
    bool is_fetch = false;
    bool hidden = false;
    uint64_t presence_tag = 0;
};

struct Sock {
    Data d;
    Data* getUserData() { return &d; }
};

using Peers = std::unordered_map<std::string, Sock*>;

static std::set<std::string> visible(const Peers& peers, const std::string& me, bool sees,
                                     const std::set<std::string>& unshared = {}) {
    std::set<std::string> out;
    presence::for_each_visible(peers, me, sees, [&](const std::string& p) { return !unshared.count(p); },
                               [&](const std::string& p, Sock*) { out.insert(p); });
    return out;
}

static void test_tag_kat() {
    printf("tag (pinned with node/presence_audit.rs)\n");
    check("A", presence::tag("12D3KooWPresenceKatA") == 11532386673268010517ULL);
    check("B", presence::tag("12D3KooWPresenceKatB") == 16287333660574689903ULL);
    check("C", presence::tag("12D3KooWPresenceKatC") == 10475476554576081470ULL);
    presence::Digest d;
    for (const char* id : {"12D3KooWPresenceKatA", "12D3KooWPresenceKatB", "12D3KooWPresenceKatC"}) d.add(presence::tag(id));
    check("the sum wraps", d.sum == 1401708740999678658ULL && d.count == 3);
    check("the phase input", presence::tag("room\ndev") == 2571280644734662145ULL);
}

static void test_filter() {
    printf("for_each_visible\n");
    Sock me, a, guest, fetch, hidden, b;
    guest.d.is_guest = true;
    fetch.d.is_fetch = true;
    hidden.d.hidden = true;
    Peers peers{{"me", &me}, {"a", &a}, {"guest", &guest}, {"fetch", &fetch}, {"hidden", &hidden}, {"b", &b}};
    check("names the others only", visible(peers, "me", true) == std::set<std::string>{"a", "b"});
    check("nobody to a viewer who does not see the room", visible(peers, "me", false).empty());
    check("not one the room does not pair with me", visible(peers, "me", true, {"b"}) == std::set<std::string>{"a"});
    check("an inbox: owners only", !presence::viewer_sees(true, false, false, true) && presence::viewer_sees(true, true, false, true));
    check("a locked room: provers only", !presence::viewer_sees(false, false, true, false) && presence::viewer_sees(false, false, true, true));
    check("an open room: anyone in it", presence::viewer_sees(false, false, false, false));
}

static void test_digest() {
    printf("digest_of\n");
    Sock me, a, b, hidden;
    hidden.d.hidden = true;
    Peers peers{{"me", &me}, {"12D3KooWPresenceKatA", &a}, {"12D3KooWPresenceKatB", &b}, {"h", &hidden}};
    auto all = [](const std::string&) { return true; };
    const presence::Digest d = presence::digest_of(peers, "me", true, all);
    check("the tag sum of what the filter names", d.sum == presence::tag("12D3KooWPresenceKatA") + presence::tag("12D3KooWPresenceKatB") && d.count == 2);
    check("a tag is cached on the socket", a.d.presence_tag == presence::tag("12D3KooWPresenceKatA"));
    check("not one for a socket it did not count", hidden.d.presence_tag == 0 && me.d.presence_tag == 0);
    const presence::Digest none = presence::digest_of(peers, "me", false, all);
    check("a viewer who does not see the room: the empty digest", none.sum == 0 && none.count == 0);

    // Property: over random rooms, the digest equals the tag sum of the ids the filter
    // names, which is what every roster sends.
    std::mt19937 rng(7);
    bool same = true;
    for (int round = 0; round < 200; round++) {
        std::vector<Sock> socks(1 + rng() % 40);
        Peers room;
        std::set<std::string> unshared;
        for (size_t i = 0; i < socks.size(); i++) {
            socks[i].d.is_guest = rng() % 7 == 0;
            socks[i].d.is_fetch = rng() % 7 == 0;
            socks[i].d.hidden = rng() % 5 == 0;
            const std::string id = "12D3KooW" + std::to_string(round) + "x" + std::to_string(i);
            room[id] = &socks[i];
            if (rng() % 6 == 0) unshared.insert(id);
        }
        const std::string me = room.begin()->first;
        auto shares = [&](const std::string& p) { return !unshared.count(p); };
        presence::Digest want;
        for (const auto& id : visible(room, me, true, unshared)) want.add(presence::tag(id));
        const presence::Digest got = presence::digest_of(room, me, true, shares);
        same = same && got.sum == want.sum && got.count == want.count;
    }
    check("random rooms: digest == tag sum of the named ids", same);
}

static void test_window() {
    printf("window_visible\n");
    std::vector<Sock> socks(200);
    Peers peers;
    for (size_t i = 0; i < socks.size(); i++) {
        socks[i].d.hidden = i % 10 == 0;
        peers["p" + std::to_string(i)] = &socks[i];
    }
    auto all = [](const std::string&) { return true; };
    const std::set<std::string> truth = visible(peers, "p1", true);
    std::set<std::string> seen;
    bool capped = true, subset = true;
    for (size_t start = 0; start < 400; start += 7) {
        std::vector<std::string> got;
        presence::window_visible(peers, "p1", true, all, start, presence::LEGACY_CAP, [&](const std::string& p) { got.push_back(p); });
        capped = capped && got.size() == presence::LEGACY_CAP;
        for (const auto& p : got) {
            subset = subset && truth.count(p);
            seen.insert(p);
        }
    }
    check("each answer is exactly the cap", capped);
    check("and names only what the filter names", subset);
    check("starts spread over the buckets cover the room", seen == truth);
    std::vector<std::string> small;
    Peers few{{"p1", &socks[1]}, {"p2", &socks[2]}, {"p3", &socks[3]}};
    presence::window_visible(few, "p1", true, all, 12345, presence::LEGACY_CAP, [&](const std::string& p) { small.push_back(p); });
    check("a small room is named whole", std::set<std::string>(small.begin(), small.end()) == std::set<std::string>{"p2", "p3"});
    std::vector<std::string> hiddenroom;
    presence::window_visible(peers, "p1", false, all, 0, presence::LEGACY_CAP, [&](const std::string& p) { hiddenroom.push_back(p); });
    check("nothing to a viewer who does not see the room", hiddenroom.empty());
}

int main() {
    if (sodium_init() < 0) return 2;
    test_tag_kat();
    test_filter();
    test_digest();
    test_window();
    if (failures) printf("%d FAILED\n", failures);
    return failures ? 1 : 0;
}
