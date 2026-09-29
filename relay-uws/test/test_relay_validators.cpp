// Unit tests for the two relay-side guards that bound attacker-supplied input:
//
//   is_peer_id_shape (validate.h)  — what may become a KEY in a relay map.
//   OfflineIndex     (offline_index.h) — which frame the byte budget drops when
//                                        the offline buffer is full: the oldest
//                                        of the address share holding the most.
//
// Both are header-only precisely so they can be tested without standing up a
// relay. The index section drives a stand-in buffer that mirrors what
// buffer_offline_msg and the ring tee do with it (stamp, then evict over budget).
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
// OfflineIndex — the byte budget, by address share
// ---------------------------------------------------------------------------

// Stand-in for the relay's two buffers: queue key -> the seqs it holds. Deposit
// mirrors buffer_offline_msg and the ring tee: stamp, push, then drop the index's
// victim while over `budget`.
struct FakeBuffer {
    OfflineIndex idx;
    std::map<std::string, std::deque<uint64_t>> queues;
    size_t budget;

    explicit FakeBuffer(size_t b) : budget(b) {}

    uint64_t deposit(const std::string& key, bool is_topic, uint64_t share, size_t bytes) {
        uint64_t seq = idx.stamp(key, is_topic, share, bytes);
        queues[key].push_back(seq);
        while (idx.bytes() > budget) {
            auto victim = idx.victim();
            if (!victim) break;
            auto& q = queues[victim->second.key];
            for (auto it = q.begin(); it != q.end(); ++it) {
                if (*it == victim->first) {
                    q.erase(it);
                    break;
                }
            }
            idx.released(victim->first);
        }
        return seq;
    }

    bool holds(const std::string& key, uint64_t seq) const {
        auto it = queues.find(key);
        if (it == queues.end()) return false;
        for (uint64_t s : it->second) if (s == seq) return true;
        return false;
    }
};

static constexpr size_t W = OfflineIndex::FRAME_OVERHEAD_BYTES;

static void budget_tests() {
    printf("OfflineIndex byte budget\n");

    // A flood into rings of its own, from one address, never pushes out the DMs
    // real people left for someone offline.
    {
        FakeBuffer b(100 * (100 + W));
        uint64_t dm1 = b.deposit("friend-inbox", false, 1, 100);
        uint64_t dm2 = b.deposit("other-inbox", false, 2, 100);
        uint64_t last = 0;
        for (int i = 0; i < 5000; i++) last = b.deposit("junk-ring-" + std::to_string(i % 40), true, 9, 100);
        check_bool("the budget holds", b.idx.bytes() <= b.budget, true);
        check_bool("the first real DM survives the flood", b.holds("friend-inbox", dm1), true);
        check_bool("the second real DM survives the flood", b.holds("other-inbox", dm2), true);
        check_bool("the flood keeps its newest frame", b.holds("junk-ring-" + std::to_string(4999 % 40), last), true);
        uint64_t dm3 = b.deposit("late-inbox", false, 3, 100);
        check_bool("a real DM after the flood lands", b.holds("late-inbox", dm3), true);
    }

    // A flood of tiny frames weighs its overhead: it cannot hold more frames than
    // the budget pays for.
    {
        FakeBuffer b(10 * W);
        for (int i = 0; i < 1000; i++) b.deposit("target-" + std::to_string(i), false, 9, 0);
        check_size("tiny frames are bounded by their overhead", b.idx.live(), 10);
    }

    // With one share, the budget drops plain oldest first.
    {
        FakeBuffer b(3 * (10 + W));
        uint64_t a = b.deposit("t", false, 1, 10);
        uint64_t c = b.deposit("t", false, 1, 10);
        uint64_t d = b.deposit("t", true, 1, 10);
        uint64_t e = b.deposit("t2", false, 1, 10);
        check_bool("the oldest frame went", b.holds("t", a), false);
        check_bool("the rest stayed", b.holds("t", c) && b.holds("t", d) && b.holds("t2", e), true);
    }

    // released() keeps the totals exact, whatever order frames leave in.
    {
        OfflineIndex idx;
        uint64_t a = idx.stamp("x", false, 1, 50);
        uint64_t c = idx.stamp("y", true, 2, 70);
        idx.released(a);
        check_size("one frame left", idx.live(), 1);
        check_size("its bytes and overhead are the total", idx.bytes(), 70 + W);
        auto v = idx.victim();
        check_bool("the victim names where it sits", v && v->first == c && v->second.key == "y" && v->second.is_topic,
                   true);
        idx.released(c);
        check_bool("an empty index has no victim", !idx.victim().has_value() && idx.bytes() == 0, true);
    }

    printf("\n");
}

// Pinned in rust/hollow_core/src/node/nick_claim.rs
// (nickname_claim_payload_matches_the_relays_pinned_vector).
static void nickname_claim_tests() {
    printf("nickname_claim_message\n");
    check_bool("the claim message matches the client's pinned vector",
               nickname_claim_message("vitalik_7", "12D3KooWDevice", "12D3KooWMaster", 1790000000000) ==
                   "hollow-nick1\nvitalik_7\n12D3KooWDevice\n12D3KooWMaster\n1790000000000",
               true);
    printf("\n");
}

int main() {
    printf("relay validators + offline index\n\n");
    peer_id_shape_tests();
    nickname_claim_tests();
    budget_tests();

    if (failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAILED (%d)\n", failures);
    return 1;
}
