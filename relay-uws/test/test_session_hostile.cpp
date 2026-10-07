// Hostile tests of the session bounds (wave 2 review, RESUMABLE_SESSIONS_PLAN.md section
// 4): receivers that never ack, strangers filling rings, buffers reused at the address a
// freed one had, and the ring kept exact under any mix of pushes, gaps, acks and
// evictions. Each is a narrow "must hold" check; rs_bounds_review.md lists them.
//
// Needs the uWebSockets/uSockets headers (state.h includes App.h). From relay-uws/test:
//   g++ -std=c++20 -I../src -I../uWebSockets/src -I../uSockets/src
//       test_session_hostile.cpp -o test_session_hostile && ./test_session_hostile

#include "session_bounds.h"
#include "session_snapshot.h"

#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <map>
#include <new>
#include <optional>
#include <random>
#include <set>
#include <string>
#include <vector>

using session::Frame;
using session::Kind;
using session::Ring;
using session::Session;

static int failures = 0;
static constexpr size_t W = OfflineIndex::FRAME_OVERHEAD_BYTES;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static std::string peer(int i) {
    static const char* alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    std::string s = "12D3KooWHost" + std::string(36, 'x');
    for (int k = 0; k < 4; k++) {
        s.push_back(alphabet[i % 58]);
        i /= 58;
    }
    return s;
}

static Session& mint(RelayState& st, const std::string& p, uint64_t share) {
    Session& s = st.sessions[p];
    s.sid = std::string(32, 'a');
    s.peer_id = p;
    s.share = share;
    return s;
}

static Frame frame(std::shared_ptr<const std::string> bytes, uint64_t share) {
    Frame f;
    f.bytes = std::move(bytes);
    f.share = share;
    return f;
}

static std::shared_ptr<const std::string> buf(size_t n, char c = 'x') {
    return std::make_shared<const std::string>(n, c);
}

// The settle point as ws_handler.cpp runs it (evict_over_budget + drop_frame).
static void settle(RelayState& st) {
    while (st.buffer_index.bytes() > MAX_BUFFER_TOTAL_BYTES) {
        auto victim = st.buffer_index.victim();
        if (!victim) break;
        const uint64_t seq = victim->first;
        const auto& loc = victim->second;
        if (loc.is_topic) {
            auto it = st.topic_buffers.find(loc.key);
            if (it != st.topic_buffers.end()) {
                auto& tb = it->second;
                for (auto f = tb.frames.begin(); f != tb.frames.end(); ++f) {
                    if (f->seq != seq) continue;
                    tb.bytes -= std::min(tb.bytes, f->frame.size());
                    tb.frames.erase(f);
                    break;
                }
            }
        } else {
            auto it = st.offline_buffer.find(loc.key);
            if (it != st.offline_buffer.end()) {
                auto& q = it->second;
                for (auto m = q.begin(); m != q.end(); ++m) {
                    if (m->seq != seq) continue;
                    q.erase(m);
                    break;
                }
                if (q.empty()) st.offline_buffer.erase(it);
            }
        }
        st.buffer_index.released(seq);
    }
}

static void deposit_dm(RelayState& st, const std::string& target, uint64_t share, size_t n) {
    uint64_t seq = st.buffer_index.stamp(target, false, share, n);
    st.offline_buffer[target].push_back({"dmroom", std::string(n, 'd'), "sender", std::chrono::steady_clock::now(),
                                         false, false, seq, share});
}

static void deposit_topic(RelayState& st, const std::string& key, uint64_t share, size_t n) {
    uint64_t seq = st.buffer_index.stamp(key, true, share, n);
    auto& tb = st.topic_buffers[key];
    tb.frames.push_back({std::string(n, 't'), "sender", std::chrono::steady_clock::now(), seq, 3600, share});
    tb.bytes += n;
}

// Light shares, each well under any flood, filling the buffer budget to `headroom` of it.
static size_t fill_light(RelayState& st, size_t headroom) {
    const size_t each = (MAX_BUFFER_TOTAL_BYTES - headroom - st.buffer_index.bytes()) / 1000;
    for (int i = 0; i < 1000; i++) st.buffer_index.stamp("light-" + std::to_string(i), false, 5000 + i, each - W);
    return 1000;
}

// The receivers that hold a sender's frames are the ones that decide how long the relay
// keeps them. Holding them must never cost the sender what it left for offline friends.
static void hoarder_tests() {
    printf("receivers that never ack\n");

    // 34 sessions from one address (a full per-IP quota) sit in a busy room and never
    // ack. Its poster's DMs for an offline friend must not pay for what they hold.
    {
        RelayState st;
        for (int i = 0; i < 20; i++) deposit_dm(st, "friend", 100, 2000);
        fill_light(st, 40u * 1024 * 1024);
        std::vector<Session*> hoarders;
        for (int i = 0; i < 34; i++) hoarders.push_back(&mint(st, peer(i), 666));
        for (int f = 0; f < 1500; f++) {
            auto b = buf(100);
            for (auto* h : hoarders) session_bounds::ring_push(st, *h, frame(b, 100));
        }
        settle(st);
        check("a poster's waiting DMs survive receivers that hold its frames",
              st.offline_buffer.count("friend") && st.offline_buffer["friend"].size() == 20);
    }

    // The same for a channel's catch-up ring the poster's frames are kept in.
    {
        RelayState st;
        for (int i = 0; i < 20; i++) deposit_topic(st, std::string("srv\0general", 11), 100, 2000);
        fill_light(st, 40u * 1024 * 1024);
        std::vector<Session*> hoarders;
        for (int i = 0; i < 34; i++) hoarders.push_back(&mint(st, peer(i), 666));
        for (int f = 0; f < 1500; f++) {
            auto b = buf(100);
            for (auto* h : hoarders) session_bounds::ring_push(st, *h, frame(b, 100));
        }
        settle(st);
        auto it = st.topic_buffers.find(std::string("srv\0general", 11));
        check("its catch-up frames survive too", it != st.topic_buffers.end() && it->second.frames.size() == 20);
    }

    // A real device in grace and the hoarders hold the same frames: under pressure the
    // hoarders' copies give way, never the real device's.
    {
        RelayState st;
        fill_light(st, 40u * 1024 * 1024);
        Session& real = mint(st, peer(100), 5);
        real.state = session::State::Grace;
        std::vector<Session*> hoarders;
        for (int i = 0; i < 34; i++) hoarders.push_back(&mint(st, peer(i), 666));
        for (int f = 0; f < 1500; f++) {
            auto b = buf(100);
            session_bounds::ring_push(st, real, frame(b, 100));
            for (auto* h : hoarders) session_bounds::ring_push(st, *h, frame(b, 100));
        }
        settle(st);
        check("a real device's ring keeps every frame while hoarders hold the same ones",
              real.ring.real_frames() == 1500 && !real.ring.gap_after(0));
    }

    printf("\n");
}

// Under the rings' own pool: whoever holds the most gives way, and in a ring the flood
// gives way before what others sent.
static void pool_tests() {
    printf("the rings' pool under pressure\n");

    // A stranger floods one device's ring with tiny frames; the pool runs short.
    {
        RelayState st;
        st.buffer_index.ring_budget = 3 * 1024 * 1024;
        Session& v = mint(st, peer(1), 5);
        v.state = session::State::Grace;
        for (int i = 0; i < 10; i++) session_bounds::ring_push(st, v, frame(buf(1000, 'f'), 9));
        for (int i = 0; i < 4000; i++) session_bounds::ring_push(st, v, frame(buf(100, 's'), 66));
        size_t friend_frames = 0;
        for (const auto& f : v.ring.entries()) friend_frames += !f.tombstone() && f.share == 9;
        check("a flood into a ring under a short pool buries the flood, not what a friend sent",
              friend_frames == 10 && st.buffer_index.ring_bytes() <= st.buffer_index.ring_budget);
    }

    // The same with big frames: their bytes outweigh every holding, so they go first.
    {
        RelayState st;
        st.buffer_index.ring_budget = 6 * 1024 * 1024;
        std::vector<Session*> victims;
        for (int i = 0; i < 4; i++) {
            victims.push_back(&mint(st, peer(10 + i), 50 + i));
            session_bounds::ring_push(st, *victims.back(), frame(buf(2000, 'f'), 9));
        }
        for (int i = 0; i < 40; i++) {
            auto b = buf(1024 * 1024, 's');
            for (auto* v : victims) session_bounds::ring_push(st, *v, frame(b, 66));
        }
        bool kept = true;
        for (auto* v : victims) kept = kept && !v->ring.entries().empty() && v->ring.entries().front().share == 9;
        check("a flood of big frames to many rings goes before any friend's frame", kept);
    }

    // Hoarders and a real device in grace hold the same frames; the pool runs short.
    {
        RelayState st;
        st.buffer_index.ring_budget = 30 * 1024 * 1024;
        Session& real = mint(st, peer(100), 5);
        real.state = session::State::Grace;
        std::vector<Session*> hoarders;
        for (int i = 0; i < 34; i++) hoarders.push_back(&mint(st, peer(i), 666));
        for (int f = 0; f < 1500; f++) {
            auto b = buf(100);
            session_bounds::ring_push(st, real, frame(b, 100));
            for (auto* h : hoarders) session_bounds::ring_push(st, *h, frame(b, 100));
        }
        size_t hoarded = 0;
        for (auto* h : hoarders) hoarded += h->ring.real_frames();
        check("the hoarders' copies give way, the real device keeps all of its own",
              real.ring.real_frames() == 1500 && hoarded < 34u * 1500 &&
                  st.buffer_index.ring_bytes() <= st.buffer_index.ring_budget);
    }

    printf("\n");
}

// A buffer freed and a new one allocated at the same address: the index keys shared
// fan-out buffers by address, so a holder it never forgot would charge the new buffer
// as already paid for.
alignas(std::string) static unsigned char g_slot[sizeof(std::string)];

static std::shared_ptr<const std::string> at_slot(size_t n, char c) {
    auto* s = new (g_slot) std::string(n, c);
    return std::shared_ptr<const std::string>(s, [](const std::string* p) { p->~basic_string(); });
}

// What the index holds for rings: their own pool where there is one, else the one
// budget (these cases deposit nothing else).
template <typename T>
static auto ring_live(const T& ix, int) -> decltype(ix.ring_live()) {
    return ix.ring_live();
}
template <typename T>
static size_t ring_live(const T& ix, long) {
    return ix.live();
}
template <typename T>
static auto ring_bytes(const T& ix, int) -> decltype(ix.ring_bytes()) {
    return ix.ring_bytes();
}
template <typename T>
static size_t ring_bytes(const T& ix, long) {
    return ix.bytes();
}

static bool charged_once(const RelayState& st, size_t expect_bytes, size_t expect_frames) {
    const size_t live = ring_live(st.buffer_index, 0), bytes = ring_bytes(st.buffer_index, 0);
    const bool ok = live == expect_frames && bytes == expect_bytes;
    if (!ok) printf("    ring index %zu frames / %zu bytes, expected %zu / %zu\n", live, bytes, expect_frames, expect_bytes);
    return ok;
}

static void reuse_tests() {
    printf("a buffer at the address a freed one had\n");

    // Every way a ring frame leaves: an ack, the frame cap, the byte cap, the budget,
    // the session's end. After each, a new buffer at the same address is charged whole.
    const char* paths[] = {"an ack", "the frame cap", "the byte cap", "the budget", "the session's end"};
    for (int path = 0; path < 5; path++) {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        Session& b = mint(st, peer(2), 1);
        {
            auto x = at_slot(path == 2 ? 5 * 1024 * 1024 : 900, 'x');
            session_bounds::ring_push(st, a, frame(x, 7));
            session_bounds::ring_push(st, b, frame(x, 7));
        }
        switch (path) {
            case 0:
                session_bounds::ring_ack(st, a, 1);
                session_bounds::ring_ack(st, b, 1);
                break;
            case 1:
                for (size_t i = 0; i < session::RING_MAX_FRAMES; i++) {
                    session_bounds::ring_push(st, a, frame(buf(1), 7));
                    session_bounds::ring_push(st, b, frame(buf(1), 7));
                }
                break;
            case 2:
                session_bounds::ring_push(st, a, frame(buf(4 * 1024 * 1024), 7));
                session_bounds::ring_push(st, b, frame(buf(4 * 1024 * 1024), 7));
                break;
            case 3:
                st.buffer_index.released(a.ring.entries().front().budget_seq);
                st.buffer_index.released(b.ring.entries().front().budget_seq);
                break;
            case 4:
                for (const std::string p : {peer(1), peer(2)}) {
                    session_bounds::ring_take_all(st, st.sessions[p]);
                    st.sessions.erase(p);
                }
                break;
        }
        // Whatever stayed in the two rings, then the fresh buffer in a third.
        size_t kept_bytes = 0, kept_frames = 0;
        std::set<const void*> seen;
        for (const auto& [p, s] : st.sessions) {
            for (const auto& f : s.ring.entries()) {
                if (f.tombstone()) continue;
                kept_frames++;
                kept_bytes += W;
                if (seen.insert(f.bytes.get()).second) kept_bytes += f.size();
            }
        }
        if (seen.count(g_slot) != 0) {
            check("after " + std::string(paths[path]) + ", the freed buffer is gone from every ring", false);
            continue;
        }
        const bool slot_free = true;
        Session& c = mint(st, peer(3), 2);
        session_bounds::ring_push(st, c, frame(at_slot(700, 'y'), 8));
        check("after " + std::string(paths[path]) + ", the reused address is charged in full",
              slot_free && charged_once(st, kept_bytes + 700 + W, kept_frames + 1));
        session_bounds::ring_take_all(st, c);
        st.sessions.erase(peer(3));
        for (auto& [p, s] : st.sessions) session_bounds::ring_take_all(st, s);
        check("  and nothing is left charged once every ring lets go",
              ring_live(st.buffer_index, 0) == 0 && ring_bytes(st.buffer_index, 0) == 0 &&
                  st.buffer_index.shared_buffers() == 0);
    }

    printf("\n");
}

// A reference model of one ring: each number in (acked, sent] is a real frame (its
// bytes) or lost (a gap). The ring must replay exactly this, every lost run as one gap.
struct Model {
    uint64_t acked = 0, sent = 0;
    std::map<uint64_t, std::string> real;  // number -> bytes; the rest of (acked, sent] is lost

    std::vector<std::string> replay(uint64_t h) const {
        std::vector<std::string> out;
        uint64_t lost = 0;
        for (uint64_t n = std::max(h, acked) + 1; n <= sent; n++) {
            auto it = real.find(n);
            if (it == real.end()) {
                lost++;
                continue;
            }
            if (lost) out.push_back(session::gap_frame(lost));
            lost = 0;
            out.push_back(it->second);
        }
        if (lost) out.push_back(session::gap_frame(lost));
        return out;
    }
};

static std::vector<std::string> replay(const Ring& r, uint64_t h) {
    std::vector<std::string> out;
    r.replay_after(h, [&out](const Frame& f, uint64_t n) { out.push_back(n ? session::gap_frame(n) : *f.bytes); });
    return out;
}

static void ring_model_tests() {
    printf("the ring against a model, under any mix of operations\n");
    std::mt19937_64 rng(2026);
    auto pick = [&rng](uint64_t n) { return n ? rng() % n : 0; };
    bool ok = true;
    int ops = 0;
    size_t worst_entries = 0;
    for (int run = 0; run < 20 && ok; run++) {
        Ring r;
        Model m;
        uint64_t next_budget = 1;
        size_t peak = 0;  // the most real frames held since the ring was last emptied
        auto none = [](const Frame&) {};
        for (int i = 0; i < 3000 && ok; i++, ops++) {
            const uint64_t op = pick(100);
            if (op < 45) {
                const std::string body = std::to_string(m.sent + 1) + std::string(pick(64), 'b');
                Frame f;
                f.bytes = std::make_shared<const std::string>(body);
                f.share = pick(5);
                f.budget_seq = next_budget++;
                r.push(std::move(f));
                m.sent++;
                m.real[m.sent] = body;
            } else if (op < 50) {
                r.push_gap();
                m.sent++;
            } else if (op < 62) {
                const uint64_t h = m.acked + pick(m.sent - m.acked + 1);
                r.ack(h, none);
                m.acked = h;
                m.real.erase(m.real.begin(), m.real.upper_bound(h));
            } else if (op < 80) {
                // The frame the ring picks is its business; the model learns which by the
                // frame it hands its on_drop.
                uint64_t gone = 0;
                if (r.evict_one([&gone](const Frame& f) { gone = f.seq; })) m.real.erase(gone);
            } else if (op < 92) {
                std::vector<uint64_t> live;
                for (const auto& f : r.entries()) {
                    if (!f.tombstone()) live.push_back(f.budget_seq);
                }
                if (!live.empty()) {
                    const uint64_t b = live[pick(live.size())];
                    uint64_t seq = 0;
                    for (const auto& f : r.entries()) {
                        if (!f.tombstone() && f.budget_seq == b) seq = f.seq;
                    }
                    if (r.evict_budget_seq(b)) m.real.erase(seq);
                }
            } else if (op < 98) {
                r.enforce(1500, 40, [&m](const Frame& f) { m.real.erase(f.seq); });
            } else {
                auto all = r.take_all();
                bool same = all.size() == m.real.size();
                size_t k = 0;
                for (const auto& [n, body] : m.real) same = same && k < all.size() && *all[k++].bytes == body;
                ok = ok && same;
                m.real.clear();
                m.acked = m.sent;
                peak = 0;
            }
            peak = std::max(peak, m.real.size());
            worst_entries = std::max(worst_entries, r.entries().size());
            size_t bytes = 0;
            for (const auto& [n, body] : m.real) bytes += body.size();
            ok = ok && r.sent() == m.sent && r.acked() == m.acked && r.real_frames() == m.real.size() &&
                 r.bytes() == bytes && r.entries().size() <= m.real.size() + peak + 66;
            if (ok && pick(10) == 0) {
                const uint64_t h = m.acked + pick(m.sent - m.acked + 1);
                const auto want = m.replay(h);
                bool gap = false;
                for (const auto& s : want) gap = gap || s.rfind("{\"type\":\"gap\"", 0) == 0;
                ok = replay(r, h) == want && r.gap_after(h) == gap;
            }
            if (ok && pick(50) == 0) {
                std::deque<Frame> copy(r.entries().begin(), r.entries().end());
                auto back = Ring::restore(r.sent(), r.acked(), copy);
                ok = back && replay(*back, r.acked()) == replay(r, r.acked());
            }
            if (!ok) printf("    diverged at run %d, op %d (kind %llu)\n", run, i, static_cast<unsigned long long>(op));
        }
    }
    check("the ring replays exactly what the model holds (" + std::to_string(ops) + " operations)", ok);
    check("and its tombstones never outnumber the most real frames it held, plus a margin (worst " +
              std::to_string(worst_entries) + " entries)",
          ok);

    // A ring held at a small cap, every push evicting: senders of uneven weight bury
    // frames from the middle, which is where tombstones pile up between compactions.
    ok = true;
    ops = 0;
    worst_entries = 0;
    size_t worst_tombs = 0;
    for (int run = 0; run < 6 && ok; run++) {
        Ring r;
        Model m;
        for (int i = 0; i < 20000 && ok; i++, ops++) {
            const uint64_t share = pick(4);
            const std::string body = std::to_string(m.sent + 1) + std::string(share * 40 + pick(8), 'w');
            Frame f;
            f.bytes = std::make_shared<const std::string>(body);
            f.share = share;
            r.push(std::move(f));
            m.sent++;
            m.real[m.sent] = body;
            r.enforce(SIZE_MAX, 300, [&m](const Frame& x) { m.real.erase(x.seq); });
            if (pick(400) == 0) {
                const uint64_t h = m.acked + pick(m.sent - m.acked + 1);
                r.ack(h, [](const Frame&) {});
                m.acked = h;
                m.real.erase(m.real.begin(), m.real.upper_bound(h));
            }
            size_t tombs = 0;
            for (const auto& e : r.entries()) tombs += e.tombstone();
            worst_tombs = std::max(worst_tombs, tombs);
            worst_entries = std::max(worst_entries, r.entries().size());
            ok = r.real_frames() == m.real.size() && r.real_frames() <= 300 && tombs <= 300 + 66;
            if (ok && pick(200) == 0) ok = replay(r, r.acked()) == m.replay(r.acked());
            if (!ok) printf("    diverged at run %d, op %d\n", run, i);
        }
    }
    check("a ring at its cap under uneven senders replays exactly (" + std::to_string(ops) + " pushes)", ok);
    check("its tombstones stay bounded (worst " + std::to_string(worst_tombs) + " beside " +
              std::to_string(worst_entries) + " entries)",
          ok && worst_tombs <= 300 + 66);
    printf("\n");
}

// What a walk of the table names, as the caps choose: the share holding the most gives
// one up (the newcomer counted, a tie on the newcomer's share), in grace before live, the
// one closest to its end first; any of equals will do.
static std::set<std::string> walk_table_victims(const RelayState& st, uint64_t share) {
    std::map<uint64_t, std::vector<const Session*>> by;
    for (const auto& [p, s] : st.sessions) by[s.share].push_back(&s);
    size_t most = 0;
    for (const auto& [sh, v] : by) most = std::max(most, v.size() + (sh == share ? 1 : 0));
    std::vector<uint64_t> tied;
    for (const auto& [sh, v] : by) {
        if (v.size() + (sh == share ? 1 : 0) == most) tied.push_back(sh);
    }
    if (std::find(tied.begin(), tied.end(), share) != tied.end()) tied = {share};
    const Session* first_grace = nullptr;
    for (uint64_t sh : tied) {
        for (const Session* s : by[sh]) {
            if (s->state == session::State::Grace && (!first_grace || s->grace_until < first_grace->grace_until)) {
                first_grace = s;
            }
        }
    }
    if (first_grace) return {first_grace->peer_id};
    std::set<std::string> out;
    for (uint64_t sh : tied) {
        for (const Session* s : by[sh]) out.insert(s->peer_id);
    }
    return out;
}

static std::optional<std::string> walk_slot_victim(const RelayState& st, const std::string& ip) {
    const Session* pick = nullptr;
    for (const auto& [p, s] : st.sessions) {
        if (s.state != session::State::Grace || s.ip_key != ip) continue;
        if (!pick || s.grace_until < pick->grace_until) pick = &s;
    }
    if (!pick) return std::nullopt;
    return pick->peer_id;
}

static void book_tests() {
    printf("the book that spares the caps a walk of the table\n");
    RelayState st;
    std::mt19937_64 rng(77);
    auto pick = [&rng](uint64_t n) { return n ? rng() % n : 0; };
    const auto now = std::chrono::steady_clock::now();
    const size_t cap = 40;
    int tick = 0, minted = 0, named = 0;
    bool ok = true, in_step = true;
    auto random_session = [&](auto&& want) -> Session* {
        std::vector<Session*> v;
        for (auto& [p, s] : st.sessions) {
            if (want(s)) v.push_back(&s);
        }
        return v.empty() ? nullptr : v[pick(v.size())];
    };
    auto end = [&](const std::string& p) {
        session_bounds::ring_take_all(st, st.sessions[p]);
        session_bounds::release_ip_slot(st, st.sessions[p]);
        st.sessions.erase(p);
    };
    for (int op = 0; op < 30000 && ok; op++) {
        const uint64_t r = pick(100);
        if (r < 40) {
            const std::string p = "dev-" + std::to_string(minted++);
            const uint64_t share = pick(6);
            const auto want = st.sessions.size() + 1 > cap ? walk_table_victims(st, share) : std::set<std::string>{};
            const auto out = session_bounds::make_room(st, share, p, cap);
            ok = want.empty() ? out.empty() : out.size() == 1 && want.count(out[0]) != 0;
            named += static_cast<int>(out.size());
            for (const auto& v : out) end(v);
            mint(st, p, share);
        } else if (r < 65) {
            if (Session* s = random_session([](const Session& x) { return x.state == session::State::Live; })) {
                s->state = session::State::Grace;
                s->grace_until = now + std::chrono::milliseconds(++tick);
                session_bounds::hold_ip_slot(st, *s, "10.0.0." + std::to_string(pick(3)));
            }
        } else if (r < 80) {
            if (Session* s = random_session([](const Session& x) { return x.state == session::State::Grace; })) {
                session_bounds::release_ip_slot(st, *s);
                s->state = session::State::Live;
            }
        } else if (r < 90) {
            if (Session* s = random_session([](const Session&) { return true; })) end(s->peer_id);
        } else {
            for (int i = 0; i < 3 && ok; i++) {
                const std::string ip = "10.0.0." + std::to_string(i);
                ok = session_bounds::grace_slot_victim(st, ip) == walk_slot_victim(st, ip);
            }
        }
        in_step = in_step && st.session_book.size() == st.sessions.size();
        if (!ok) printf("    differs from the walk at operation %d (kind %llu)\n", op, static_cast<unsigned long long>(r));
    }
    check("the table cap and the grace slot name what a walk names (" + std::to_string(named) + " named)", ok);
    check("every add, grace, resume and end kept the book in step without a rebuild", in_step);
    printf("\n");
}

// A client that sends a counted frame between heartbeats (each heartbeat resets the
// count the relay acks): the queue of acks owed must not grow with it.
static void ack_queue_tests() {
    printf("acks owed to a client that beats between frames\n");
    Session s;
    auto now = std::chrono::steady_clock::now();
    const auto first = now;
    int queued = 0;
    for (int i = 0; i < 100000; i++) {
        queued += s.count_in(now);
        s.unacked_in = 0;  // the heartbeat's answer carried the count
        now += std::chrono::microseconds(10);
    }
    check("a hundred thousand frames within the ack delay queue one ack", queued == 1 && s.in_h == 100000);
    check("due no later than the delay after the first",
          s.ack_due == first + std::chrono::milliseconds(session::ACK_AFTER_MS));
    s.count_in(now);
    check("a frame while one is queued rides it", s.unacked_in == 1 && s.ack_due <= now + std::chrono::seconds(1));
    now = s.ack_due + std::chrono::milliseconds(1);
    s.unacked_in = 0;
    check("once that one is due, the next frame queues another", s.count_in(now) &&
                                                                     s.ack_due == now + std::chrono::milliseconds(session::ACK_AFTER_MS));
    printf("\n");
}

// Sessions back from a snapshot hold no per-IP slot, yet the table cap still sees them.
static void restored_book_tests() {
    printf("sessions back from a snapshot and the book\n");
    snapshot::Data d;
    for (int i = 0; i < 5; i++) {
        snapshot::SessionRec r;
        r.sid = std::string(31, 'a') + static_cast<char>('0' + i);
        r.peer_id = peer(200 + i);
        r.share = i < 3 ? 9 : 10 + i;
        d.sessions.push_back(r);
    }
    RelayState st;
    session_snapshot::restore(st, std::move(d), std::chrono::steady_clock::now(), 120, 1800000000);
    check("every restored session is in the book", st.session_book.size() == 5 && st.sessions.size() == 5);
    check("none holds a slot of any address", session_bounds::grace_slots(st, "") == 0);
    auto out = session_bounds::make_room(st, 77, peer(300), 5);
    check("the table cap takes one of the share holding the most",
          out.size() == 1 && st.sessions.count(out[0]) && st.sessions[out[0]].share == 9);
    printf("\n");
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("session bounds, hostile\n\n");
    hoarder_tests();
    pool_tests();
    reuse_tests();
    ring_model_tests();
    book_tests();
    ack_queue_tests();
    restored_book_tests();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
