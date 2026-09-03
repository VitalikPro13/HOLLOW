// Unit tests for the two relay-side guards that bound attacker-supplied input:
//
//   is_peer_id_shape (validate.h)  — what may become a KEY in a relay map.
//   OfflineIndex     (offline_index.h) — who pays when the offline buffer is
//                                        full, and how the byte-budget evictor
//                                        finds the oldest frame in O(1).
//
// Both are header-only precisely so they can be tested without standing up a
// relay. The fair-share section drives a stand-in buffer that mirrors what
// buffer_offline_msg does with the index (plan -> free -> stamp); it tests the
// index's DECISIONS, which is where the fairness lives.
//
// Build + run from relay-uws/test (no uWebSockets needed, only libsodium):
//   g++ -std=c++17 -I../src test_relay_validators.cpp ../src/crypto.cpp \
//       -lsodium -lcrypto -o test_relay_validators && ./test_relay_validators

#include "crypto.h"
#include "offline_index.h"
#include "validate.h"

#include <cstdio>
#include <deque>
#include <map>
#include <string>
#include <utility>
#include <vector>

static int failures = 0;

static void check_bool(const std::string& label, bool got, bool want) {
    if (got == want) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n       got:  %s\n       want: %s\n",
               label.c_str(), got ? "true" : "false", want ? "true" : "false");
        failures++;
    }
}

static void check_size(const std::string& label, size_t got, size_t want) {
    if (got == want) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n       got:  %zu\n       want: %zu\n",
               label.c_str(), got, want);
        failures++;
    }
}

// ---------------------------------------------------------------------------
// is_peer_id_shape
// ---------------------------------------------------------------------------

// The same vector test_derive_peer_id.cpp pins, so "a real id passes" is
// checked against an id this relay actually derives rather than a literal
// somebody typed.
static const char kPubkeyB64[] = "CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c";
static const char kPeerId[] = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";

static void peer_id_shape_tests() {
    printf("is_peer_id_shape\n");

    const std::string derived = derive_peer_id(kPubkeyB64);
    check_bool("derive_peer_id still produces the pinned vector",
               derived == kPeerId, true);
    check_bool("a real derived peer id passes", is_peer_id_shape(derived), true);
    check_size("a real peer id is 52 characters", derived.size(), 52);

    check_bool("rejects empty", is_peer_id_shape(""), false);
    check_bool("rejects too short (39)", is_peer_id_shape(std::string(39, 'a')), false);
    check_bool("accepts the lower bound (40)", is_peer_id_shape(std::string(40, 'a')), true);
    check_bool("accepts the upper bound (64)", is_peer_id_shape(std::string(64, 'a')), true);
    check_bool("rejects too long (65)", is_peer_id_shape(std::string(65, 'a')), false);

    // The four characters base58btc omits, each spliced into an otherwise valid
    // id. Each one is a distinct way an id could be "nearly right".
    for (char bad : {'0', 'O', 'I', 'l'}) {
        std::string id = kPeerId;
        id[10] = bad;
        check_bool(std::string("rejects '") + bad + "' (not in the base58 alphabet)",
                   is_peer_id_shape(id), false);
    }

    // Path and separator characters: the whole point of the check is that a
    // target string never becomes something structural somewhere else.
    for (const char* bad : {"..", "/", "\\", ":", "-", "_", "+", " ", "\t", "\n", "%"}) {
        std::string id = kPeerId;
        id.replace(5, 1, bad);
        id.resize(52, '1');
        check_bool(std::string("rejects an id containing ") +
                       (bad[0] == '\t' ? "TAB" : bad[0] == '\n' ? "LF" : bad),
                   is_peer_id_shape(id), false);
    }

    {
        std::string id = kPeerId;
        id[20] = '\0';
        check_bool("rejects an embedded NUL", is_peer_id_shape(id), false);
    }
    {
        // High bytes: an id is never anything but ASCII base58.
        std::string id = kPeerId;
        id[20] = static_cast<char>(0xC3);
        check_bool("rejects a non-ASCII byte", is_peer_id_shape(id), false);
    }

    printf("\n");
}

// ---------------------------------------------------------------------------
// OfflineIndex — fair-share key accounting
// ---------------------------------------------------------------------------

// Stand-in for RelayState::offline_buffer: target -> frames, each frame being
// the sender that deposited it plus its index stamp. Deposit mirrors
// buffer_offline_msg: ask the index who pays, free that, then stamp and push.
struct FakeBuffer {
    OfflineIndex idx;
    std::map<std::string, std::deque<std::pair<std::string, uint64_t>>> queues;
    size_t max_targets = 4;
    size_t max_keys = 100;

    void release_oldest_target_of(const std::string& sender) {
        std::string target = idx.oldest_target(sender);
        if (target.empty()) return;
        auto it = queues.find(target);
        if (it == queues.end()) return;
        std::deque<std::pair<std::string, uint64_t>> kept;
        for (auto& f : it->second) {
            if (f.first == sender) {
                idx.released_dm(target, sender);
            } else {
                kept.push_back(f);
            }
        }
        it->second = std::move(kept);
        if (it->second.empty()) queues.erase(it);
    }

    void evict_oldest_key() {
        size_t start = idx.key_count();
        for (size_t i = 0; i < 1024 && !idx.order.empty(); i++) {
            OfflineIndex::EvictRef ref = idx.order.front();
            idx.order.pop_front();
            auto it = queues.find(ref.key);
            if (it == queues.end() || it->second.empty() ||
                it->second.front().second != ref.seq) {
                continue;  // stale ref
            }
            idx.released_dm(ref.key, it->second.front().first);
            it->second.pop_front();
            if (it->second.empty()) queues.erase(it);
            if (idx.key_count() < start) return;
        }
    }

    void deposit(const std::string& target, const std::string& sender) {
        switch (idx.plan(sender, target, max_targets, max_keys)) {
            case OfflineIndex::Admit::Ok: break;
            case OfflineIndex::Admit::FreeOwnOldest: release_oldest_target_of(sender); break;
            case OfflineIndex::Admit::FreeGlobalOldest: evict_oldest_key(); break;
        }
        uint64_t seq = idx.stamp_dm(target, sender);
        queues[target].push_back({sender, seq});
    }

    size_t frames_at(const std::string& target) const {
        auto it = queues.find(target);
        return it == queues.end() ? 0 : it->second.size();
    }
};

static void fair_share_tests() {
    printf("OfflineIndex fair share (per-sender target cap)\n");

    FakeBuffer b;
    b.max_targets = 4;

    // Three senders. `flood` sprays targets; `solo_a` and `solo_b` each hold a
    // single conversation, which is what the cap must never cost anything.
    for (const char* t : {"F1", "F2", "F3", "F4"}) b.deposit(t, "flood");
    b.deposit("S1", "solo_a");
    b.deposit("S2", "solo_b");
    // solo_a also has a message waiting at F1 — the target the flooder is about
    // to lose. Its message must survive: the flooder loses ITS OWN frames.
    b.deposit("F1", "solo_a");

    check_size("flooder holds 4 targets", b.idx.target_count("flood"), 4);
    check_size("solo_a holds 2 targets", b.idx.target_count("solo_a"), 2);
    check_bool("F1 holds two senders' frames", b.frames_at("F1") == 2, true);

    // The 5th target is past the flooder's share.
    check_bool("plan() bills the flooder for its own expansion",
               b.idx.plan("flood", "F5", b.max_targets, b.max_keys) ==
                   OfflineIndex::Admit::FreeOwnOldest, true);
    b.deposit("F5", "flood");

    check_bool("flooder lost its OLDEST target (F1)", b.idx.holds("flood", "F1"), false);
    check_bool("flooder kept F2", b.idx.holds("flood", "F2"), true);
    check_bool("flooder kept the new F5", b.idx.holds("flood", "F5"), true);
    check_size("flooder is back at its cap, not over it",
               b.idx.target_count("flood"), 4);
    check_bool("solo_a's frame at F1 survived", b.idx.holds("solo_a", "F1"), true);
    check_size("F1 now holds only solo_a's frame", b.frames_at("F1"), 1);

    // The single-target senders were never consulted and never charged.
    check_size("solo_a still holds S1", b.frames_at("S1"), 1);
    check_size("solo_b still holds S2", b.frames_at("S2"), 1);
    check_bool("a single-target sender is never billed",
               b.idx.plan("solo_b", "S2", b.max_targets, b.max_keys) ==
                   OfflineIndex::Admit::Ok, true);

    // Keep going: each further target costs the flooder its next-oldest.
    b.deposit("F6", "flood");
    check_bool("flooder then lost F2", b.idx.holds("flood", "F2"), false);
    check_size("flooder still capped at 4", b.idx.target_count("flood"), 4);
    check_size("solo_a untouched after a second eviction", b.frames_at("S1"), 1);
    check_size("solo_b untouched after a second eviction", b.frames_at("S2"), 1);

    printf("\n");
}

static void backstop_tests() {
    printf("OfflineIndex global key backstop\n");

    FakeBuffer b;
    b.max_targets = 100;  // out of the way: this section is about max_keys
    b.max_keys = 4;

    b.deposit("A", "big");
    b.deposit("B", "big");
    b.deposit("C", "solo_c");
    b.deposit("D", "solo_d");
    check_size("four keys, at the cap", b.idx.key_count(), 4);

    // A sender that already holds keys pays for its own expansion.
    check_bool("plan() bills a multi-target sender at the backstop",
               b.idx.plan("big", "E", b.max_targets, b.max_keys) ==
                   OfflineIndex::Admit::FreeOwnOldest, true);
    b.deposit("E", "big");
    check_bool("big lost its own oldest (A)", b.idx.holds("big", "A"), false);
    check_size("solo_c untouched", b.frames_at("C"), 1);
    check_size("solo_d untouched", b.frames_at("D"), 1);
    check_size("still four keys", b.idx.key_count(), 4);

    // A sender holding nothing must not lose its one and only deposit, so the
    // backstop falls back to the globally oldest.
    check_bool("plan() spares a first-time sender",
               b.idx.plan("newcomer", "F", b.max_targets, b.max_keys) ==
                   OfflineIndex::Admit::FreeGlobalOldest, true);
    b.deposit("F", "newcomer");
    check_bool("the newcomer's deposit was admitted", b.idx.holds("newcomer", "F"), true);
    check_bool("the globally oldest key (B) went instead", b.idx.holds("big", "B"), false);
    check_size("still four keys after the backstop", b.idx.key_count(), 4);

    printf("\n");
}

static void eviction_index_tests() {
    printf("OfflineIndex eviction order\n");

    FakeBuffer b;
    b.max_targets = 100;
    b.max_keys = 100;

    b.deposit("T1", "s1");   // seq 1
    b.deposit("T2", "s2");   // seq 2
    b.deposit("T1", "s1");   // seq 3
    b.deposit("T3", "s3");   // seq 4

    check_size("one ref per deposit", b.idx.order.size(), 4);
    check_size("four live frames", b.idx.live, 4);
    check_bool("refs are in insertion order",
               b.idx.order[0].seq == 1 && b.idx.order[1].seq == 2 &&
                   b.idx.order[2].seq == 3 && b.idx.order[3].seq == 4, true);

    // Deliver T2 out of band, the way replay_buffered_msgs does: the frame
    // leaves the queue and the ref left behind is stale.
    b.idx.released_dm("T2", "s2");
    b.queues.erase("T2");

    // Compaction keeps live refs, in order, and drops only the stale one.
    b.idx.compact([&b](const OfflineIndex::EvictRef& r) {
        auto it = b.queues.find(r.key);
        if (it == b.queues.end()) return false;
        for (const auto& f : it->second) {
            if (f.second == r.seq) return true;
        }
        return false;
    });
    check_size("compaction dropped exactly the stale ref", b.idx.order.size(), 3);
    check_bool("compaction preserved order",
               b.idx.order[0].seq == 1 && b.idx.order[1].seq == 3 &&
                   b.idx.order[2].seq == 4, true);

    // Sequence numbers are never reused, so a stale ref can never be mistaken
    // for a later frame at the same key.
    uint64_t next = b.idx.stamp_dm("T2", "s2");
    check_bool("a new stamp is strictly newer than every retired one", next > 4, true);

    printf("\n");
}

int main() {
    printf("relay validators + offline index\n\n");
    peer_id_shape_tests();
    fair_share_tests();
    backstop_tests();
    eviction_index_tests();

    if (failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAILED (%d)\n", failures);
    return 1;
}
